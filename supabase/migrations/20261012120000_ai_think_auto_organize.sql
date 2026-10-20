-- 20261012120000: Think 자동 정리 제안 (운영자 결정 2026-10-12)
-- - Think가 답변 중에 정리안을 먼저 제안하고, 운영자가 고르고 고쳐서 승인한다. 승인된 정리의 실행은 기존 ai_action_apply가 한다.
--   새 제안 종류: exclude_context(맥락 제외), mark_important(중요 표시), progress_summary(진행 요약·다음 행동),
--   department_criteria_change(부서 기준 변경). 대화 삭제·코드 작업은 자동 정리 대상이 아니다.
-- - ai_messages.marked_important: 화면에서 눈여겨볼 표시일 뿐, AI가 지켜야 할 원칙의 권한이 아니다.
-- - ai_conversations.progress_summary: 대화마다 하나인 승인된 진행 요약. 다음 답변부터 참고 자료로 들어간다.
-- - ai_department_criteria: 부서마다 우선 확인할 질문·놓치면 안 되는 위험·우선 참고할 승인 기억.
--   바꾸려면 Think의 제안을 승인하거나 운영자가 직접 고친다. 고칠 때마다 판(version)이 오르고 기록이 남는다.
-- - ai_platform_settings.auto_organize_enabled: 자동 제안 켜기/끄기(기본 켜짐). 꺼도 운영자가 직접 요청하면 제안한다.
-- - ai_action_apply_batch: 정리 패널의 "선택한 항목 승인". 항목마다 기존 ai_action_apply를 따로 실행하고 결과를 따로 돌려준다.
--   부서 넘기기 → 분류 → 맥락 제외 → 중요 표시 → 나누기 → 기억 → 진행 요약 → 부서 기준 순서로 실행한다.
-- - place_conversation 승인: 폴더 부서가 지금 대화 부서와 다르면 충돌로 막는다(제안 뒤 부서가 바뀐 경우).
-- 설계: docs/architecture/ai-think-actions.md §11

-- ---------------------------------------------------------------------------
-- 1) 데이터
-- ---------------------------------------------------------------------------
alter table public.ai_messages add column if not exists marked_important boolean not null default false;

alter table public.ai_conversations add column if not exists progress_summary jsonb;
alter table public.ai_conversations drop constraint if exists ai_conversations_progress_summary_check;
alter table public.ai_conversations add constraint ai_conversations_progress_summary_check
  check (progress_summary is null or (jsonb_typeof(progress_summary) = 'object' and octet_length(progress_summary::text) <= 60000));

alter table public.ai_platform_settings add column if not exists auto_organize_enabled boolean not null default true;

create table if not exists public.ai_department_criteria (
  department text primary key check (department in ('lead', 'education', 'product', 'engineering')),
  questions text[] not null default '{}'::text[],
  risks text[] not null default '{}'::text[],
  priority_memory_ids uuid[] not null default '{}'::uuid[],
  version integer not null default 0,
  -- 'owner'(운영자가 직접 고침) 또는 'action:<제안 id>'(Think 제안을 승인)
  updated_via text,
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

insert into public.ai_department_criteria (department)
values ('lead'), ('education'), ('product'), ('engineering')
on conflict (department) do nothing;

create table if not exists public.ai_department_criteria_revisions (
  id uuid primary key default gen_random_uuid(),
  department text not null,
  version integer not null,
  questions text[] not null,
  risks text[] not null,
  priority_memory_ids uuid[] not null,
  updated_via text,
  changed_by uuid references auth.users(id) on delete set null,
  changed_at timestamptz not null default now()
);

create index if not exists idx_ai_department_criteria_revisions
  on public.ai_department_criteria_revisions (department, version);

create or replace function public.ai_department_criteria_after_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.ai_department_criteria_revisions (department, version, questions, risks, priority_memory_ids, updated_via, changed_by)
  values (new.department, new.version, new.questions, new.risks, new.priority_memory_ids, new.updated_via, new.updated_by);
  return null;
end
$$;

drop trigger if exists trg_ai_department_criteria_after_update on public.ai_department_criteria;
create trigger trg_ai_department_criteria_after_update
  after update on public.ai_department_criteria
  for each row execute function public.ai_department_criteria_after_update();

alter table public.ai_department_criteria enable row level security;
alter table public.ai_department_criteria_revisions enable row level security;
revoke all on public.ai_department_criteria from anon;
revoke all on public.ai_department_criteria_revisions from anon;
revoke insert, update, delete on public.ai_department_criteria from authenticated;
revoke insert, update, delete on public.ai_department_criteria_revisions from authenticated;

drop policy if exists ai_department_criteria_superadmin_select on public.ai_department_criteria;
create policy ai_department_criteria_superadmin_select on public.ai_department_criteria
  for select to authenticated
  using ((select public.is_superadmin()));

drop policy if exists ai_department_criteria_revisions_superadmin_select on public.ai_department_criteria_revisions;
create policy ai_department_criteria_revisions_superadmin_select on public.ai_department_criteria_revisions
  for select to authenticated
  using ((select public.is_superadmin()));

alter table public.ai_actions drop constraint if exists ai_actions_kind_check;
alter table public.ai_actions add constraint ai_actions_kind_check
  check (kind in (
    'code_request', 'code_change', 'code_plan', 'place_conversation', 'delete_code_request', 'delete_folder',
    'delete_conversation', 'split_conversation', 'save_memory', 'memory_card_change', 'handover_department',
    'exclude_context', 'mark_important', 'progress_summary', 'department_criteria_change'
  ));

-- ---------------------------------------------------------------------------
-- 2) 내부 도우미
-- ---------------------------------------------------------------------------
-- jsonb 문자열 배열을 순서대로 text[]로.
create or replace function public.ai_jsonb_text_array(p jsonb)
returns text[]
language sql
immutable
set search_path = public
as $$
  select coalesce(array_agg(x order by o), '{}'::text[])
    from jsonb_array_elements_text(case when jsonb_typeof(p) = 'array' then p else '[]'::jsonb end) with ordinality as t(x, o)
$$;

-- id 목록(jsonb 배열). 중복은 하나로 줄이고, 형식이 틀리거나 너무 많으면 막는다.
create or replace function public.ai_organize_uuid_list(p jsonb, p_max integer)
returns uuid[]
language plpgsql
immutable
set search_path = public
as $$
declare
  v_out uuid[] := '{}'::uuid[];
  v_text text;
begin
  if p is null or jsonb_typeof(p) <> 'array' then
    return v_out;
  end if;
  for v_text in select x from jsonb_array_elements_text(p) with ordinality as t(x, o) order by o loop
    if v_text !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception 'organize_id_invalid' using errcode = '22023';
    end if;
    if not (v_text::uuid = any(v_out)) then
      v_out := v_out || v_text::uuid;
    end if;
  end loop;
  if cardinality(v_out) > p_max then
    raise exception 'organize_too_many' using errcode = '22023';
  end if;
  return v_out;
end
$$;

-- 카드에서 일부만 고른 대상. 제안에 없던 메시지는 더할 수 없다. 고르지 않았으면 제안 그대로.
create or replace function public.ai_organize_pick(p_proposed jsonb, p_override jsonb, p_max integer)
returns uuid[]
language plpgsql
immutable
set search_path = public
as $$
declare
  v_all uuid[] := public.ai_organize_uuid_list(p_proposed, p_max);
  v_pick uuid[];
begin
  if p_override is null or jsonb_typeof(p_override) <> 'array' then
    return v_all;
  end if;
  v_pick := public.ai_organize_uuid_list(p_override, p_max);
  if cardinality(v_pick) = 0 then
    raise exception 'organize_targets_invalid' using errcode = '22023';
  end if;
  if not (v_all @> v_pick) then
    raise exception 'organize_target_not_proposed' using errcode = '22023';
  end if;
  return v_pick;
end
$$;

-- 카드에 보일 대상 메시지(시간순). 제외·삭제와 무관하게 제안 당시의 모습이 카드에 남는다.
create or replace function public.ai_organize_targets(p_conversation_id uuid, p_ids uuid[])
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', m.id,
           'role', m.role,
           'created_at', m.created_at,
           'excerpt', left(regexp_replace(btrim(m.content), '\s+', ' ', 'g'), 160)
         ) order by m.created_at, m.id), '[]'::jsonb)
    from public.ai_messages m
   where m.conversation_id = p_conversation_id
     and m.id = any(p_ids)
$$;

-- 대상 메시지에서 만든 발췌·종합 문서와, 그 답변에 붙은 제안으로 저장한 확정 기억.
-- 맥락에서 빼도 이것들은 그대로 남는다(따로 판단할 대상으로 알린다).
create or replace function public.ai_organize_linked(p_conversation_id uuid, p_ids uuid[])
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'documents', coalesce((
      select jsonb_agg(distinct jsonb_build_object('id', n.id, 'kind', n.kind, 'title', n.title))
        from public.ai_tree_node_sources s
        join public.ai_tree_nodes n on n.id = s.node_id
       where s.message_id = any(p_ids)
    ), '[]'::jsonb),
    'memories', coalesce((
      select jsonb_agg(distinct jsonb_build_object('id', mem.id, 'title', mem.title))
        from public.ai_actions a
        join public.ai_memories mem on mem.id = nullif(a.result ->> 'memory_id', '')::uuid
       where a.conversation_id = p_conversation_id
         and a.kind = 'save_memory'
         and a.status = 'applied'
         and a.message_id = any(p_ids)
         and mem.status = 'active'
    ), '[]'::jsonb)
  )
$$;

-- 진행 요약: 목적·확정·미결·진행 상태·다음 행동. 다음 행동의 담당은 사용자가 정한 것만 들어온다(프롬프트 규칙).
create or replace function public.ai_progress_summary_clean(p jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  v jsonb := case when jsonb_typeof(p) = 'object' then p else '{}'::jsonb end;
  v_purpose text := left(btrim(coalesce(v ->> 'purpose', '')), 1000);
  v_next jsonb := '[]'::jsonb;
  v_item jsonb;
  v_what text;
begin
  if v_purpose = '' then
    raise exception 'summary_purpose_required' using errcode = '22023';
  end if;
  for v_item in
    select e
      from jsonb_array_elements(case when jsonb_typeof(v -> 'next') = 'array' then v -> 'next' else '[]'::jsonb end)
           with ordinality as t(e, o)
     order by o
     limit 10
  loop
    if jsonb_typeof(v_item) = 'string' then
      v_item := jsonb_build_object('what', v_item #>> '{}');
    elsif jsonb_typeof(v_item) <> 'object' then
      continue;
    end if;
    v_what := left(btrim(coalesce(v_item ->> 'what', '')), 300);
    continue when v_what = '';
    v_next := v_next || jsonb_build_array(jsonb_build_object(
      'what', v_what,
      'owner', left(btrim(coalesce(v_item ->> 'owner', '')), 60),
      'prerequisite', left(btrim(coalesce(v_item ->> 'prerequisite', '')), 300),
      'done_when', left(btrim(coalesce(v_item ->> 'done_when', '')), 300)
    ));
  end loop;
  return jsonb_build_object(
    'purpose', v_purpose,
    'decided', to_jsonb(public.ai_memory_text_list(v -> 'decided', 12, 500)),
    'open', to_jsonb(public.ai_memory_text_list(v -> 'open', 12, 500)),
    'status', left(btrim(coalesce(v ->> 'status', '')), 1000),
    'next', v_next
  );
end
$$;

-- 부서 기준. 우선 참고 기억은 그 부서 대화가 볼 수 있는 확정 기억만(공통·레거시·철학, 자기 부서, 총괄은 모든 부서).
-- 우선순위일 뿐 권한을 넓히지 않는다. 실제로 넣을 때도 대화의 자료 범위를 한 번 더 거친다(Edge).
create or replace function public.ai_department_criteria_clean(p jsonb, p_department text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v jsonb := case when jsonb_typeof(p) = 'object' then p else '{}'::jsonb end;
  v_ids uuid[];
  v_bad uuid;
begin
  if p_department is null or p_department not in ('lead', 'education', 'product', 'engineering') then
    raise exception 'criteria_department_invalid' using errcode = '22023';
  end if;
  v_ids := public.ai_organize_uuid_list(v -> 'priority_memory_ids', 8);
  select t.id into v_bad
    from unnest(v_ids) as t(id)
   where not exists (
     select 1
       from public.ai_memories m
      where m.id = t.id
        and m.status = 'active'
        and (
          m.kind = 'identity'
          or coalesce(m.memory_scope, 'legacy_unscoped') in ('legacy_unscoped', 'common')
          or (m.memory_scope = 'department' and (p_department = 'lead' or m.scope_department = p_department))
        )
   )
   limit 1;
  if v_bad is not null then
    raise exception 'criteria_memory_not_allowed:%', v_bad using errcode = '22023';
  end if;
  return jsonb_build_object(
    'questions', to_jsonb(public.ai_memory_text_list(v -> 'questions', 8, 200)),
    'risks', to_jsonb(public.ai_memory_text_list(v -> 'risks', 8, 200)),
    'priority_memory_ids', to_jsonb(v_ids)
  );
end
$$;

-- 카드에 보일 부서 기준(우선 참고 기억은 제목과 함께).
create or replace function public.ai_department_criteria_view(p_questions text[], p_risks text[], p_ids uuid[])
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'questions', to_jsonb(coalesce(p_questions, '{}'::text[])),
    'risks', to_jsonb(coalesce(p_risks, '{}'::text[])),
    'priority_memories', coalesce((
      select jsonb_agg(jsonb_build_object('id', m.id, 'title', m.title) order by array_position(p_ids, m.id))
        from public.ai_memories m
       where m.id = any(coalesce(p_ids, '{}'::uuid[]))
    ), '[]'::jsonb)
  )
$$;

create or replace function public.ai_department_label(p_department text)
returns text
language sql
immutable
set search_path = public
as $$
  select case p_department
    when 'lead' then '총괄'
    when 'education' then '교육'
    when 'product' then '문제 풀이'
    when 'engineering' then '개발'
    else coalesce(p_department, '')
  end
$$;

-- ---------------------------------------------------------------------------
-- 3) 제안 (전용 RPC로만 만든다)
-- ---------------------------------------------------------------------------
-- 20261011100000 정의 + 전용 RPC가 있는 종류(부서 넘기기와 새 종류 네 개)는 범용 제안으로 만들 수 없게 막는다.
create or replace function public.ai_action_propose(
  p_conversation_id uuid,
  p_kind text,
  p_payload jsonb,
  p_preview jsonb default '{}'::jsonb
)
returns public.ai_actions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.ai_actions;
  v_mem jsonb;
  v_reason text := nullif(left(btrim(coalesce(p_payload ->> 'reason', '')), 500), '');
  v_target public.ai_actions;
  v_target_id uuid;
  v_op text;
  v_id uuid;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_kind = 'split_conversation' then
    raise exception 'split_use_dedicated_rpc' using errcode = '22023';
  end if;
  if p_kind in ('handover_department', 'exclude_context', 'mark_important', 'progress_summary', 'department_criteria_change') then
    raise exception 'action_use_dedicated_rpc' using errcode = '22023';
  end if;
  if not exists (select 1 from public.ai_conversations where id = p_conversation_id) then
    raise exception 'conversation_not_found' using errcode = 'P0002';
  end if;

  -- 기억 카드는 기한 없이 남고 서로 대체하지 않는다. 같은 기억인지 검사한 뒤 넣는다.
  if p_kind = 'save_memory' then
    v_mem := public.ai_memory_proposal_clean(p_payload -> 'memory');
    perform public.ai_memory_proposal_guard(v_mem, null);
    insert into public.ai_actions (conversation_id, kind, payload, preview)
    values (
      p_conversation_id, 'save_memory',
      jsonb_build_object('memory', v_mem, 'reason', v_reason),
      public.ai_memory_proposal_preview(v_mem, v_reason)
    )
    returning * into v_row;
    return v_row;
  end if;

  if p_kind = 'memory_card_change' then
    v_op := btrim(coalesce(p_payload ->> 'op', ''));
    if v_op not in ('revise', 'replace', 'withdraw') then
      raise exception 'memory_card_op_invalid' using errcode = '22023';
    end if;
    begin
      v_target_id := nullif(btrim(coalesce(p_payload ->> 'target_action_id', '')), '')::uuid;
    exception when invalid_text_representation then
      raise exception 'memory_card_not_pending' using errcode = '22023';
    end;
    select * into v_target from public.ai_actions where id = v_target_id;
    if not found or v_target.kind <> 'save_memory' or v_target.status <> 'proposed' then
      raise exception 'memory_card_not_pending' using errcode = '22023';
    end if;
    select id into v_id
      from public.ai_actions
     where kind = 'memory_card_change' and status = 'proposed' and payload ->> 'target_action_id' = v_target.id::text
     limit 1;
    if v_id is not null then
      raise exception 'memory_card_change_pending:%', v_id using errcode = '23505';
    end if;
    if v_op <> 'withdraw' then
      v_mem := public.ai_memory_proposal_clean(p_payload -> 'memory');
      perform public.ai_memory_proposal_guard(v_mem, v_target.id);
    end if;
    insert into public.ai_actions (conversation_id, kind, payload, preview)
    values (
      p_conversation_id, 'memory_card_change',
      jsonb_build_object('target_action_id', v_target.id, 'op', v_op, 'memory', v_mem, 'reason', v_reason),
      jsonb_build_object(
        'op', v_op,
        'title', coalesce(v_mem ->> 'title', v_target.preview ->> 'title'),
        'target_title', v_target.preview ->> 'title',
        'target_conversation_id', v_target.conversation_id,
        'memory_kind', v_mem ->> 'kind',
        'memory_scope', v_mem ->> 'memory_scope',
        'scope_department', v_mem ->> 'scope_department',
        'reason', v_reason
      )
    )
    returning * into v_row;
    return v_row;
  end if;

  update public.ai_actions
     set status = 'rejected', superseded = true, decided_at = now()
   where conversation_id = p_conversation_id
     and kind = p_kind
     and status = 'proposed';
  insert into public.ai_actions (conversation_id, kind, payload, preview)
  values (p_conversation_id, p_kind, coalesce(p_payload, '{}'::jsonb), coalesce(p_preview, '{}'::jsonb))
  returning * into v_row;
  return v_row;
end
$$;

-- 맥락 제외: 이 대화의 메시지 중 아직 제외되지 않은 것만. 같은 메시지 묶음을 거절했으면 사용자가 직접 요청하지 않는 한
-- 다시 제안하지 않는다. 이 대화의 대기 중인 제외 제안은 새 제안으로 대체된다.
create or replace function public.ai_context_exclusion_propose(
  p_conversation_id uuid,
  p_message_ids uuid[],
  p_reason text,
  p_impact text,
  p_user_requested boolean default false
)
returns public.ai_actions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ids uuid[];
  v_reason text := left(btrim(coalesce(p_reason, '')), 500);
  v_impact text := left(btrim(coalesce(p_impact, '')), 500);
  v_found integer;
  v_row public.ai_actions;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if not exists (select 1 from public.ai_conversations where id = p_conversation_id) then
    raise exception 'conversation_not_found' using errcode = 'P0002';
  end if;
  v_ids := public.ai_organize_uuid_list(to_jsonb(coalesce(p_message_ids, '{}'::uuid[])), 20);
  if cardinality(v_ids) = 0 then
    raise exception 'organize_targets_invalid' using errcode = '22023';
  end if;
  if v_reason = '' then
    raise exception 'exclusion_reason_required' using errcode = '22023';
  end if;
  select count(*) into v_found from public.ai_messages where conversation_id = p_conversation_id and id = any(v_ids);
  if v_found <> cardinality(v_ids) then
    raise exception 'organize_target_missing' using errcode = 'P0002';
  end if;
  if exists (select 1 from public.ai_messages where id = any(v_ids) and context_excluded) then
    raise exception 'exclusion_already_excluded' using errcode = '22023';
  end if;
  if not coalesce(p_user_requested, false) and exists (
    select 1
      from public.ai_actions a
     where a.conversation_id = p_conversation_id
       and a.kind = 'exclude_context'
       and a.status = 'rejected'
       and not a.superseded
       and public.ai_jsonb_text_array(a.payload -> 'message_ids')::uuid[] @> v_ids
  ) then
    raise exception 'organize_rejected_before' using errcode = '22023';
  end if;
  update public.ai_actions
     set status = 'rejected', superseded = true, decided_at = now()
   where conversation_id = p_conversation_id
     and kind = 'exclude_context'
     and status = 'proposed';
  insert into public.ai_actions (conversation_id, kind, payload, preview)
  values (
    p_conversation_id,
    'exclude_context',
    jsonb_build_object('message_ids', to_jsonb(v_ids), 'reason', v_reason, 'impact', nullif(v_impact, '')),
    jsonb_build_object(
      'title', format('메시지 %s개', cardinality(v_ids)),
      'count', cardinality(v_ids),
      'targets', public.ai_organize_targets(p_conversation_id, v_ids),
      'reason', v_reason,
      'impact', nullif(v_impact, ''),
      'linked', public.ai_organize_linked(p_conversation_id, v_ids),
      'has_summary', exists (select 1 from public.ai_conversations where id = p_conversation_id and progress_summary is not null)
    )
  )
  returning * into v_row;
  return v_row;
end
$$;

-- 중요 표시: 이 대화의 메시지 중 제외되지 않았고 아직 표시하지 않은 것만. 거절·대체 규칙은 맥락 제외와 같다.
create or replace function public.ai_importance_mark_propose(
  p_conversation_id uuid,
  p_message_ids uuid[],
  p_reason text,
  p_user_requested boolean default false
)
returns public.ai_actions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ids uuid[];
  v_reason text := left(btrim(coalesce(p_reason, '')), 500);
  v_found integer;
  v_row public.ai_actions;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if not exists (select 1 from public.ai_conversations where id = p_conversation_id) then
    raise exception 'conversation_not_found' using errcode = 'P0002';
  end if;
  v_ids := public.ai_organize_uuid_list(to_jsonb(coalesce(p_message_ids, '{}'::uuid[])), 10);
  if cardinality(v_ids) = 0 then
    raise exception 'organize_targets_invalid' using errcode = '22023';
  end if;
  if v_reason = '' then
    raise exception 'importance_reason_required' using errcode = '22023';
  end if;
  select count(*) into v_found from public.ai_messages where conversation_id = p_conversation_id and id = any(v_ids);
  if v_found <> cardinality(v_ids) then
    raise exception 'organize_target_missing' using errcode = 'P0002';
  end if;
  if exists (select 1 from public.ai_messages where id = any(v_ids) and context_excluded) then
    raise exception 'importance_target_excluded' using errcode = '22023';
  end if;
  if exists (select 1 from public.ai_messages where id = any(v_ids) and marked_important) then
    raise exception 'importance_already_marked' using errcode = '22023';
  end if;
  if not coalesce(p_user_requested, false) and exists (
    select 1
      from public.ai_actions a
     where a.conversation_id = p_conversation_id
       and a.kind = 'mark_important'
       and a.status = 'rejected'
       and not a.superseded
       and public.ai_jsonb_text_array(a.payload -> 'message_ids')::uuid[] @> v_ids
  ) then
    raise exception 'organize_rejected_before' using errcode = '22023';
  end if;
  update public.ai_actions
     set status = 'rejected', superseded = true, decided_at = now()
   where conversation_id = p_conversation_id
     and kind = 'mark_important'
     and status = 'proposed';
  insert into public.ai_actions (conversation_id, kind, payload, preview)
  values (
    p_conversation_id,
    'mark_important',
    jsonb_build_object('message_ids', to_jsonb(v_ids), 'reason', v_reason),
    jsonb_build_object(
      'title', format('메시지 %s개', cardinality(v_ids)),
      'count', cardinality(v_ids),
      'targets', public.ai_organize_targets(p_conversation_id, v_ids),
      'reason', v_reason
    )
  )
  returning * into v_row;
  return v_row;
end
$$;

-- 진행 요약: 대화마다 하나. 제안할 때의 승인된 요약(base_action_id)이 승인 시점에도 같아야 한다(바뀌었으면 충돌).
-- p_through_message_id: 이 요약이 반영한 마지막 메시지(이번 질문). 다음 제안에서 이미 처리한 범위를 알 수 있다.
create or replace function public.ai_progress_summary_propose(
  p_conversation_id uuid,
  p_summary jsonb,
  p_reason text,
  p_through_message_id uuid
)
returns public.ai_actions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_summary jsonb;
  v_reason text := left(btrim(coalesce(p_reason, '')), 500);
  v_prev jsonb;
  v_row public.ai_actions;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select progress_summary into v_prev from public.ai_conversations where id = p_conversation_id;
  if not found then
    raise exception 'conversation_not_found' using errcode = 'P0002';
  end if;
  v_summary := public.ai_progress_summary_clean(p_summary);
  if p_through_message_id is not null
     and not exists (select 1 from public.ai_messages where id = p_through_message_id and conversation_id = p_conversation_id) then
    raise exception 'organize_target_missing' using errcode = 'P0002';
  end if;
  update public.ai_actions
     set status = 'rejected', superseded = true, decided_at = now()
   where conversation_id = p_conversation_id
     and kind = 'progress_summary'
     and status = 'proposed';
  insert into public.ai_actions (conversation_id, kind, payload, preview)
  values (
    p_conversation_id,
    'progress_summary',
    jsonb_build_object(
      'summary', v_summary,
      'reason', nullif(v_reason, ''),
      'base_action_id', v_prev ->> 'action_id',
      'through_message_id', p_through_message_id
    ),
    jsonb_build_object(
      'title', left(v_summary ->> 'purpose', 80),
      'summary', v_summary,
      'previous', v_prev,
      'reason', nullif(v_reason, '')
    )
  )
  returning * into v_row;
  return v_row;
end
$$;

-- 부서 기준 변경: 바꾼 뒤의 기준 전체를 제안한다. 제안할 때의 판(base_version)이 승인 시점에도 같아야 한다.
-- 같은 대화에서 같은 부서의 대기 중인 제안은 새 제안으로 대체된다.
create or replace function public.ai_department_criteria_propose(
  p_conversation_id uuid,
  p_department text,
  p_criteria jsonb,
  p_reason text
)
returns public.ai_actions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_clean jsonb;
  v_reason text := left(btrim(coalesce(p_reason, '')), 500);
  v_cur public.ai_department_criteria;
  v_row public.ai_actions;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if not exists (select 1 from public.ai_conversations where id = p_conversation_id) then
    raise exception 'conversation_not_found' using errcode = 'P0002';
  end if;
  v_clean := public.ai_department_criteria_clean(p_criteria, p_department);
  if v_reason = '' then
    raise exception 'criteria_reason_required' using errcode = '22023';
  end if;
  select * into v_cur from public.ai_department_criteria where department = p_department;
  if not found then
    raise exception 'criteria_not_found' using errcode = 'P0002';
  end if;
  if v_clean -> 'questions' = to_jsonb(v_cur.questions)
     and v_clean -> 'risks' = to_jsonb(v_cur.risks)
     and v_clean -> 'priority_memory_ids' = to_jsonb(v_cur.priority_memory_ids) then
    raise exception 'criteria_unchanged' using errcode = '22023';
  end if;
  update public.ai_actions
     set status = 'rejected', superseded = true, decided_at = now()
   where conversation_id = p_conversation_id
     and kind = 'department_criteria_change'
     and status = 'proposed'
     and payload ->> 'department' = p_department;
  insert into public.ai_actions (conversation_id, kind, payload, preview)
  values (
    p_conversation_id,
    'department_criteria_change',
    jsonb_build_object('department', p_department, 'criteria', v_clean, 'reason', v_reason, 'base_version', v_cur.version),
    jsonb_build_object(
      'title', public.ai_department_label(p_department) || ' 부서 기준',
      'department', p_department,
      'before', public.ai_department_criteria_view(v_cur.questions, v_cur.risks, v_cur.priority_memory_ids),
      'after', public.ai_department_criteria_view(
        public.ai_jsonb_text_array(v_clean -> 'questions'),
        public.ai_jsonb_text_array(v_clean -> 'risks'),
        public.ai_jsonb_text_array(v_clean -> 'priority_memory_ids')::uuid[]
      ),
      'reason', v_reason,
      'base_version', v_cur.version
    )
  )
  returning * into v_row;
  return v_row;
end
$$;

-- 운영자가 부서 기준을 직접 고친다. 화면을 연 뒤 다른 곳에서 바뀌었으면(판이 다르면) 충돌로 막는다.
create or replace function public.ai_department_criteria_save(p_department text, p_criteria jsonb, p_base_version integer)
returns public.ai_department_criteria
language plpgsql
security definer
set search_path = public
as $$
declare
  v_crit public.ai_department_criteria;
  v_clean jsonb;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into v_crit from public.ai_department_criteria where department = p_department for update;
  if not found then
    raise exception 'criteria_not_found' using errcode = 'P0002';
  end if;
  if v_crit.version <> coalesce(p_base_version, -1) then
    raise exception 'criteria_changed' using errcode = '22023';
  end if;
  v_clean := public.ai_department_criteria_clean(p_criteria, p_department);
  update public.ai_department_criteria
     set questions = public.ai_jsonb_text_array(v_clean -> 'questions'),
         risks = public.ai_jsonb_text_array(v_clean -> 'risks'),
         priority_memory_ids = public.ai_jsonb_text_array(v_clean -> 'priority_memory_ids')::uuid[],
         version = version + 1,
         updated_via = 'owner',
         updated_by = auth.uid(),
         updated_at = now()
   where department = p_department
  returning * into v_crit;
  return v_crit;
end
$$;

-- ---------------------------------------------------------------------------
-- 4) 승인 (20261012100000 정의 + 새 종류 네 개 + 분류의 부서 충돌 검사)
-- ---------------------------------------------------------------------------
-- p_overrides: 사용자가 카드에서 고친 값만. code_*: {title, spec}, place_conversation: {folder_id},
-- split_conversation: {title, summary, folder_id}, save_memory·memory_card_change: {memory},
-- exclude_context·mark_important: {message_ids}(제안한 메시지 중 일부), progress_summary: {summary},
-- department_criteria_change: {criteria}
create or replace function public.ai_action_apply(p_id uuid, p_overrides jsonb default '{}'::jsonb)
returns public.ai_actions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.ai_actions;
  v_over jsonb := coalesce(p_overrides, '{}'::jsonb);
  v_result jsonb;
  v_target uuid;
  v_req_id uuid;
  v_title text;
  v_spec jsonb;
  v_folder uuid;
  v_new_folder uuid;
  v_parent uuid;
  v_node public.ai_tree_nodes;
  v_prev jsonb;
  v_prev_index integer;
  v_deleted_self boolean := false;
  v_to text;
  v_ids uuid[];
  v_already uuid[];
  v_n integer;
  v_conv public.ai_conversations;
  v_summary jsonb;
  v_edited boolean;
  v_dept text;
  v_crit public.ai_department_criteria;
  v_clean jsonb;
  v_ver integer;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  -- 나누기는 원본 대화를 먼저 잠가야 해서 따로 처리한다.
  if exists (select 1 from public.ai_actions where id = p_id and kind = 'split_conversation') then
    return public.ai_conversation_split_apply(p_id, v_over);
  end if;
  if exists (select 1 from public.ai_actions where id = p_id and kind in ('save_memory', 'memory_card_change')) then
    return public.ai_memory_action_apply(p_id, v_over);
  end if;
  select * into v_row from public.ai_actions where id = p_id for update;
  if not found then
    raise exception 'action_not_found' using errcode = 'P0002';
  end if;
  if v_row.status <> 'proposed' then
    raise exception 'action_not_pending' using errcode = '22023';
  end if;

  if v_row.kind in ('code_request', 'code_change') then
    v_title := btrim(coalesce(nullif(v_over ->> 'title', ''), v_row.payload ->> 'title', ''));
    v_spec := case when jsonb_typeof(v_over -> 'spec') = 'object' then v_over -> 'spec' else v_row.payload -> 'spec' end;
    if v_title = '' then
      raise exception 'code_request_title_required' using errcode = '22023';
    end if;
    if v_spec is null or jsonb_typeof(v_spec) <> 'object' then
      raise exception 'code_request_goal_required' using errcode = '22023';
    end if;
    insert into public.ai_code_requests (conversation_id, source_message_ids, title, request, mode)
    values (
      v_row.conversation_id,
      array_remove(array[v_row.message_id], null),
      left(v_title, 200),
      v_spec,
      case when v_row.kind = 'code_change' then 'change' else 'investigate' end
    )
    returning id into v_req_id;
    perform public.ai_code_request_submit(v_req_id);
    v_result := jsonb_build_object('code_request_id', v_req_id);

  elsif v_row.kind = 'place_conversation' then
    v_folder := nullif(v_over ->> 'folder_id', '')::uuid;
    if v_folder is null and nullif(btrim(coalesce(v_row.payload ->> 'new_folder_title', '')), '') is not null then
      v_parent := nullif(v_row.payload ->> 'new_folder_parent_id', '')::uuid;
      if v_parent is not null and not exists (select 1 from public.ai_tree_nodes where id = v_parent and kind = 'folder') then
        raise exception 'tree_parent_not_folder' using errcode = '22023';
      end if;
      insert into public.ai_tree_nodes (kind, parent_id, title, created_via, sort_order, department)
      values (
        'folder', v_parent, left(btrim(v_row.payload ->> 'new_folder_title'), 120), 'ai', 2147483647,
        (select think_role_id from public.ai_conversations where id = v_row.conversation_id)
      )
      returning id into v_new_folder;
      perform public.ai_tree_renumber(v_parent);
      v_folder := v_new_folder;
    elsif v_folder is null then
      v_folder := nullif(v_row.payload ->> 'folder_id', '')::uuid;
    end if;
    if v_folder is null or not exists (select 1 from public.ai_tree_nodes where id = v_folder and kind = 'folder') then
      raise exception 'tree_folder_not_found' using errcode = 'P0002';
    end if;
    -- 제안 뒤 대화 부서가 바뀌었으면(예: 같은 승인에서 부서 넘기기가 먼저 실행됨) 다른 부서 폴더에 넣지 않는다.
    if (select department from public.ai_tree_nodes where id = v_folder)
       is distinct from (select think_role_id from public.ai_conversations where id = v_row.conversation_id) then
      raise exception 'place_department_mismatch' using errcode = '22023';
    end if;

    select * into v_node from public.ai_tree_nodes
     where kind = 'conversation' and conversation_id = v_row.conversation_id;
    if found then
      select count(*) into v_prev_index
        from public.ai_tree_nodes
       where parent_id is not distinct from v_node.parent_id
         and id <> v_node.id
         and (sort_order, created_at, id) < (v_node.sort_order, v_node.created_at, v_node.id);
      v_prev := jsonb_build_object('placed', true, 'parent_id', v_node.parent_id, 'index', v_prev_index);
    else
      v_prev := jsonb_build_object('placed', false);
    end if;
    perform public.ai_tree_place_conversation(v_row.conversation_id, v_folder, 2147483647);
    v_result := jsonb_build_object('folder_id', v_folder, 'created_folder_id', v_new_folder, 'previous', v_prev);

  elsif v_row.kind = 'delete_code_request' then
    v_target := nullif(v_row.payload ->> 'target_id', '')::uuid;
    delete from public.ai_code_requests
     where id = v_target
       and status in ('draft', 'ready', 'needs_review', 'failed', 'cancelled', 'applied', 'apply_failed', 'reverted', 'revert_failed');
    if not found then
      raise exception 'code_request_not_deletable' using errcode = '22023';
    end if;
    v_result := jsonb_build_object('deleted_id', v_target);

  elsif v_row.kind = 'delete_folder' then
    v_target := nullif(v_row.payload ->> 'target_id', '')::uuid;
    perform public.ai_tree_delete_folder(v_target);
    v_result := jsonb_build_object('deleted_id', v_target);

  elsif v_row.kind = 'delete_conversation' then
    v_target := nullif(v_row.payload ->> 'target_id', '')::uuid;
    v_deleted_self := v_target = v_row.conversation_id;
    delete from public.ai_conversations where id = v_target;
    if not found then
      raise exception 'conversation_not_found' using errcode = 'P0002';
    end if;
    v_result := jsonb_build_object('deleted_id', v_target, 'deleted_self', v_deleted_self);

  elsif v_row.kind = 'handover_department' then
    v_to := v_row.payload ->> 'to_department';
    if exists (select 1 from public.ai_conversations where id = v_row.conversation_id and think_role_id = v_to) then
      raise exception 'handover_same_department' using errcode = '22023';
    end if;
    v_result := public.ai_conversation_change_department(v_row.conversation_id, v_to, true);

  elsif v_row.kind in ('exclude_context', 'mark_important') then
    v_ids := public.ai_organize_pick(
      v_row.payload -> 'message_ids',
      v_over -> 'message_ids',
      case when v_row.kind = 'exclude_context' then 20 else 10 end
    );
    perform 1 from public.ai_messages where id = any(v_ids) and conversation_id = v_row.conversation_id for update;
    select count(*) into v_n from public.ai_messages where id = any(v_ids) and conversation_id = v_row.conversation_id;
    if v_n <> cardinality(v_ids) then
      raise exception 'organize_target_missing' using errcode = 'P0002';
    end if;
    if v_row.kind = 'exclude_context' then
      select coalesce(array_agg(id), '{}'::uuid[]) into v_already
        from public.ai_messages where id = any(v_ids) and context_excluded;
      update public.ai_messages
         set context_excluded = true
       where id = any(v_ids) and conversation_id = v_row.conversation_id and not context_excluded;
      v_result := jsonb_build_object(
        'excluded_ids', to_jsonb(array(select x from unnest(v_ids) as x where not (x = any(v_already)))),
        'already_excluded_ids', to_jsonb(v_already),
        'linked', public.ai_organize_linked(v_row.conversation_id, v_ids),
        'summary_may_include', exists (
          select 1 from public.ai_conversations where id = v_row.conversation_id and progress_summary is not null
        )
      );
    else
      select coalesce(array_agg(id), '{}'::uuid[]) into v_already
        from public.ai_messages where id = any(v_ids) and marked_important;
      update public.ai_messages
         set marked_important = true
       where id = any(v_ids) and conversation_id = v_row.conversation_id and not marked_important;
      v_result := jsonb_build_object(
        'marked_ids', to_jsonb(array(select x from unnest(v_ids) as x where not (x = any(v_already)))),
        'already_marked_ids', to_jsonb(v_already)
      );
    end if;

  elsif v_row.kind = 'progress_summary' then
    select * into v_conv from public.ai_conversations where id = v_row.conversation_id for update;
    if coalesce(v_conv.progress_summary ->> 'action_id', '') <> coalesce(v_row.payload ->> 'base_action_id', '') then
      raise exception 'progress_summary_changed' using errcode = '22023';
    end if;
    v_edited := coalesce(jsonb_typeof(v_over -> 'summary') = 'object', false);
    v_summary := public.ai_progress_summary_clean(
      case when v_edited then v_over -> 'summary' else v_row.payload -> 'summary' end
    );
    update public.ai_conversations
       set progress_summary = v_summary || jsonb_build_object(
             'action_id', v_row.id,
             'approved_at', now(),
             'approved_by', auth.uid(),
             'through_message_id', v_row.payload -> 'through_message_id',
             'edited', v_edited
           )
     where id = v_row.conversation_id;
    v_result := jsonb_build_object('previous_action_id', nullif(v_row.payload ->> 'base_action_id', ''), 'edited', v_edited);

  elsif v_row.kind = 'department_criteria_change' then
    v_dept := v_row.payload ->> 'department';
    select * into v_crit from public.ai_department_criteria where department = v_dept for update;
    if not found then
      raise exception 'criteria_not_found' using errcode = 'P0002';
    end if;
    if v_crit.version <> coalesce(nullif(v_row.payload ->> 'base_version', '')::integer, -1) then
      raise exception 'criteria_changed' using errcode = '22023';
    end if;
    v_edited := coalesce(jsonb_typeof(v_over -> 'criteria') = 'object', false);
    v_clean := public.ai_department_criteria_clean(
      case when v_edited then v_over -> 'criteria' else v_row.payload -> 'criteria' end,
      v_dept
    );
    update public.ai_department_criteria
       set questions = public.ai_jsonb_text_array(v_clean -> 'questions'),
           risks = public.ai_jsonb_text_array(v_clean -> 'risks'),
           priority_memory_ids = public.ai_jsonb_text_array(v_clean -> 'priority_memory_ids')::uuid[],
           version = version + 1,
           updated_via = 'action:' || v_row.id,
           updated_by = auth.uid(),
           updated_at = now()
     where department = v_dept
    returning version into v_ver;
    v_result := jsonb_build_object(
      'department', v_dept,
      'version', v_ver,
      'before', jsonb_build_object(
        'questions', to_jsonb(v_crit.questions),
        'risks', to_jsonb(v_crit.risks),
        'priority_memory_ids', to_jsonb(v_crit.priority_memory_ids)
      ),
      'edited', v_edited
    );

  else
    raise exception 'action_kind_not_appliable' using errcode = '22023';
  end if;

  if v_deleted_self then
    -- 제안이 속한 대화가 지워져 행도 함께 사라졌다. 결과만 돌려준다.
    v_row.status := 'applied';
    v_row.result := v_result;
    v_row.decided_at := now();
    v_row.decided_by := auth.uid();
    return v_row;
  end if;

  update public.ai_actions
     set status = 'applied', result = v_result, error = null, decided_at = now(), decided_by = auth.uid()
   where id = p_id
  returning * into v_row;
  return v_row;
end
$$;

-- 되돌리기: 분류(20260930100000 정의 그대로) + 맥락 제외·중요 표시(이 승인으로 바뀐 메시지만 되돌린다).
create or replace function public.ai_action_undo(p_id uuid)
returns public.ai_actions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.ai_actions;
  v_prev jsonb;
  v_node uuid;
  v_created uuid;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into v_row from public.ai_actions where id = p_id for update;
  if not found then
    raise exception 'action_not_found' using errcode = 'P0002';
  end if;
  if v_row.status <> 'applied' or v_row.kind not in ('place_conversation', 'exclude_context', 'mark_important') then
    raise exception 'action_not_undoable' using errcode = '22023';
  end if;

  if v_row.kind = 'exclude_context' then
    update public.ai_messages
       set context_excluded = false
     where conversation_id = v_row.conversation_id
       and id = any(public.ai_jsonb_text_array(v_row.result -> 'excluded_ids')::uuid[])
       and context_excluded;
  elsif v_row.kind = 'mark_important' then
    update public.ai_messages
       set marked_important = false
     where conversation_id = v_row.conversation_id
       and id = any(public.ai_jsonb_text_array(v_row.result -> 'marked_ids')::uuid[])
       and marked_important;
  else
    v_prev := coalesce(v_row.result -> 'previous', '{}'::jsonb);
    select id into v_node from public.ai_tree_nodes where kind = 'conversation' and conversation_id = v_row.conversation_id;
    if v_node is not null then
      if coalesce((v_prev ->> 'placed')::boolean, false) then
        if nullif(v_prev ->> 'parent_id', '') is not null
           and not exists (select 1 from public.ai_tree_nodes where id = (v_prev ->> 'parent_id')::uuid and kind = 'folder') then
          perform public.ai_tree_move(v_node, null, coalesce((v_prev ->> 'index')::integer, 0));
        else
          perform public.ai_tree_move(v_node, nullif(v_prev ->> 'parent_id', '')::uuid, coalesce((v_prev ->> 'index')::integer, 0));
        end if;
      else
        delete from public.ai_tree_nodes where id = v_node;
      end if;
    end if;
    v_created := nullif(v_row.result ->> 'created_folder_id', '')::uuid;
    if v_created is not null and not exists (select 1 from public.ai_tree_nodes where parent_id = v_created) then
      perform public.ai_tree_delete_folder(v_created);
    end if;
  end if;

  update public.ai_actions set status = 'undone', decided_at = now(), decided_by = auth.uid()
   where id = p_id
  returning * into v_row;
  return v_row;
end
$$;

-- ---------------------------------------------------------------------------
-- 5) 정리 패널의 일괄 승인
-- ---------------------------------------------------------------------------
-- p_items: [{id, overrides?}] (최대 20). 항목마다 ai_action_apply를 따로(저장점 안에서) 실행해 하나가 실패해도 나머지는 그대로 둔다.
-- 실패한 항목은 대기 상태로 남는다. 이미 승인된 항목(재시도)은 다시 실행하지 않고 already로 돌려준다.
-- 코드 작업·삭제는 여기서 승인할 수 없다(각 카드에서만).
-- 반환: [{id, ok, already?, code?, message?, action}] (실행한 순서)
create or replace function public.ai_action_apply_batch(p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_items jsonb := case when jsonb_typeof(p_items) = 'array' then p_items else '[]'::jsonb end;
  v_out jsonb := '[]'::jsonb;
  r record;
  v_row public.ai_actions;
  v_msg text;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if jsonb_array_length(v_items) = 0 or jsonb_array_length(v_items) > 20 then
    raise exception 'batch_items_invalid' using errcode = '22023';
  end if;
  for r in
    with given as (
      select distinct on (x.id) x.id, x.over, x.ord
        from (
          select case when e ->> 'id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                      then (e ->> 'id')::uuid end as id,
                 case when jsonb_typeof(e -> 'overrides') = 'object' then e -> 'overrides' else '{}'::jsonb end as over,
                 o as ord
            from jsonb_array_elements(v_items) with ordinality as t(e, o)
        ) x
       order by x.id, x.ord
    )
    select g.id, g.over, g.ord, a.kind, a.status
      from given g
      left join public.ai_actions a on a.id = g.id
     order by case a.kind
                when 'handover_department' then 1
                when 'place_conversation' then 2
                when 'exclude_context' then 3
                when 'mark_important' then 4
                when 'split_conversation' then 5
                when 'save_memory' then 6
                when 'memory_card_change' then 7
                when 'progress_summary' then 8
                when 'department_criteria_change' then 9
                else 10
              end,
              g.ord
  loop
    if r.id is null or r.kind is null then
      v_out := v_out || jsonb_build_array(jsonb_build_object('id', r.id, 'ok', false, 'code', 'action_not_found'));
      continue;
    end if;
    if r.kind not in (
      'handover_department', 'place_conversation', 'exclude_context', 'mark_important', 'split_conversation',
      'save_memory', 'memory_card_change', 'progress_summary', 'department_criteria_change'
    ) then
      v_out := v_out || jsonb_build_array(jsonb_build_object('id', r.id, 'ok', false, 'code', 'action_kind_not_in_batch'));
      continue;
    end if;
    if r.status = 'applied' then
      select * into v_row from public.ai_actions where id = r.id;
      v_out := v_out || jsonb_build_array(jsonb_build_object('id', r.id, 'ok', true, 'already', true, 'action', to_jsonb(v_row)));
      continue;
    end if;
    begin
      v_row := public.ai_action_apply(r.id, r.over);
      v_out := v_out || jsonb_build_array(jsonb_build_object('id', r.id, 'ok', true, 'action', to_jsonb(v_row)));
    exception when others then
      get stacked diagnostics v_msg = message_text;
      select * into v_row from public.ai_actions where id = r.id;
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'id', r.id,
        'ok', false,
        'code', split_part(v_msg, ':', 1),
        'message', left(v_msg, 300),
        'action', case when v_row.id is null then null else to_jsonb(v_row) end
      ));
    end;
  end loop;
  return v_out;
end
$$;

-- ---------------------------------------------------------------------------
-- 6) 기능 확인 (20261012100000 정의에 auto_organize 추가)
-- ---------------------------------------------------------------------------
create or replace function public.ai_think_db_features()
returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'conversation_split',
    case
      when to_regprocedure('public.ai_conversation_split_propose(uuid, uuid, jsonb, jsonb, boolean)') is not null
       and to_regprocedure('public.ai_conversation_split_apply(uuid, jsonb)') is not null
       and exists (
         select 1 from pg_attribute
          where attrelid = 'public.ai_conversations'::regclass and attname = 'split_summary' and not attisdropped
       )
       and exists (
         select 1 from pg_attribute
          where attrelid = 'public.ai_messages'::regclass and attname = 'source_message_id' and not attisdropped
       )
      then 1
      else 0
    end,
    'think_roles',
    case
      when exists (
         select 1 from pg_attribute
          where attrelid = 'public.ai_conversations'::regclass and attname = 'think_role_id' and not attisdropped
       )
       and to_regprocedure('public.ai_conversation_set_think_role(uuid, text, text[], text)') is not null
       and to_regprocedure('public.ai_search_memories_scoped(text[], integer, text, text[], uuid[])') is not null
       and to_regclass('public.ai_conversation_memory_links') is not null
       and to_regclass('public.ai_conversation_document_links') is not null
       and to_regclass('public.ai_message_context_snapshots') is not null
      then 1
      else 0
    end,
    'memory_proposals',
    case
      when to_regprocedure('public.ai_memory_action_apply(uuid, jsonb)') is not null
       and to_regprocedure('public.ai_memory_proposal_clean(jsonb)') is not null
       and to_regprocedure('public.ai_memory_proposal_guard(jsonb, uuid)') is not null
      then 1
      else 0
    end,
    'department_work',
    case
      when exists (
         select 1 from pg_attribute
          where attrelid = 'public.ai_tree_nodes'::regclass and attname = 'department' and not attisdropped
       )
       and to_regprocedure('public.ai_tree_move_department(uuid, uuid, uuid, integer, text)') is not null
       and to_regprocedure('public.ai_conversation_move_department(uuid, text)') is not null
       and to_regprocedure('public.ai_department_handover_propose(uuid, text, text)') is not null
      then 1
      else 0
    end,
    'auto_organize',
    case
      when exists (
         select 1 from pg_attribute
          where attrelid = 'public.ai_messages'::regclass and attname = 'marked_important' and not attisdropped
       )
       and exists (
         select 1 from pg_attribute
          where attrelid = 'public.ai_conversations'::regclass and attname = 'progress_summary' and not attisdropped
       )
       and exists (
         select 1 from pg_attribute
          where attrelid = 'public.ai_platform_settings'::regclass and attname = 'auto_organize_enabled' and not attisdropped
       )
       and to_regclass('public.ai_department_criteria') is not null
       and to_regprocedure('public.ai_context_exclusion_propose(uuid, uuid[], text, text, boolean)') is not null
       and to_regprocedure('public.ai_importance_mark_propose(uuid, uuid[], text, boolean)') is not null
       and to_regprocedure('public.ai_progress_summary_propose(uuid, jsonb, text, uuid)') is not null
       and to_regprocedure('public.ai_department_criteria_propose(uuid, text, jsonb, text)') is not null
       and to_regprocedure('public.ai_department_criteria_save(text, jsonb, integer)') is not null
       and to_regprocedure('public.ai_action_apply_batch(jsonb)') is not null
      then 1
      else 0
    end
  );
end
$$;

-- ---------------------------------------------------------------------------
-- 7) 권한
-- ---------------------------------------------------------------------------
revoke all on function public.ai_department_criteria_after_update() from public, anon, authenticated, service_role;
revoke all on function public.ai_organize_targets(uuid, uuid[]) from public, anon, authenticated, service_role;
revoke all on function public.ai_organize_linked(uuid, uuid[]) from public, anon, authenticated, service_role;
revoke all on function public.ai_department_criteria_clean(jsonb, text) from public, anon, authenticated, service_role;
revoke all on function public.ai_department_criteria_view(text[], text[], uuid[]) from public, anon, authenticated, service_role;
revoke all on function public.ai_context_exclusion_propose(uuid, uuid[], text, text, boolean) from public, anon;
revoke all on function public.ai_importance_mark_propose(uuid, uuid[], text, boolean) from public, anon;
revoke all on function public.ai_progress_summary_propose(uuid, jsonb, text, uuid) from public, anon;
revoke all on function public.ai_department_criteria_propose(uuid, text, jsonb, text) from public, anon;
revoke all on function public.ai_department_criteria_save(text, jsonb, integer) from public, anon;
revoke all on function public.ai_action_apply_batch(jsonb) from public, anon;
grant execute on function public.ai_context_exclusion_propose(uuid, uuid[], text, text, boolean) to authenticated;
grant execute on function public.ai_importance_mark_propose(uuid, uuid[], text, boolean) to authenticated;
grant execute on function public.ai_progress_summary_propose(uuid, jsonb, text, uuid) to authenticated;
grant execute on function public.ai_department_criteria_propose(uuid, text, jsonb, text) to authenticated;
grant execute on function public.ai_department_criteria_save(text, jsonb, integer) to authenticated;
grant execute on function public.ai_action_apply_batch(jsonb) to authenticated;
