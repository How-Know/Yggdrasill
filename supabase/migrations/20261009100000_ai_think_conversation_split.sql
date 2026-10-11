-- 20261009100000: Think 대화 나누기 (주제 전환 → 나누기 제안 → 사용자 승인 → 새 대화)
-- - 제안(ai_conversation_split_propose): ai_think가 이번 턴의 사용자 메시지 id만 넘긴다. 범위는 서버가 정한다:
--   그 사용자 메시지 + 그 턴의 완료된 답변(제안에 붙는 message_id). 승인 전에는 대화·복사·폴더·기억을 만들지 않는다.
-- - 승인(ai_action_apply → ai_conversation_split_apply): 원본 대화 행을 먼저 잠근다. 메시지 저장 트리거도 같은 행을
--   먼저 잠그므로 승인과 새 메시지 저장이 한 줄로 선다. 새 대화·두 메시지 복사(출처 연결)·요약·폴더 배치·승인 기록이
--   한 트랜잭션이고, 실패하면 모두 되돌린다. 다시 눌러도 이미 만든 대화를 돌려준다.
-- - 거절: 그 대화의 자동 나누기 제안을 끈다(auto_split_suggestions). 사용자가 직접 나누자고 하면 제안할 수 있고,
--   앱에서 다시 켤 수 있다. 다른 대화에는 영향이 없다.
-- - 만료: 제안 뒤 같은 대화에 사용자 메시지가 저장되면 대기 중 나누기 제안은 expired가 된다(다른 메시지를 복사하지 않는다).
-- - ai_think_db_features: 읽기 전용 기능 확인(ai_think가 요청마다 부른다). ai_runs.features: 그때 계산한 기능 상태.
-- - ai_attachment_paths_in_use: 복사한 메시지는 원본과 같은 첨부 파일을 가리킨다. 대화를 지울 때 남은 참조를 확인한다.
-- 설계: docs/architecture/ai-think-actions.md §7

-- ---------------------------------------------------------------------------
-- 1) 열·제약
-- ---------------------------------------------------------------------------
alter table public.ai_conversations
  add column if not exists split_from_conversation_id uuid references public.ai_conversations(id) on delete set null,
  add column if not exists split_from_action_id uuid references public.ai_actions(id) on delete set null,
  add column if not exists split_summary jsonb
    check (split_summary is null or (jsonb_typeof(split_summary) = 'object' and octet_length(split_summary::text) <= 20000)),
  add column if not exists auto_split_suggestions boolean not null default true;

create unique index if not exists uq_ai_conversations_split_action
  on public.ai_conversations (split_from_action_id) where split_from_action_id is not null;
create index if not exists idx_ai_conversations_split_from
  on public.ai_conversations (split_from_conversation_id) where split_from_conversation_id is not null;

alter table public.ai_messages
  add column if not exists source_message_id uuid references public.ai_messages(id) on delete set null;
create index if not exists idx_ai_messages_source
  on public.ai_messages (source_message_id) where source_message_id is not null;

alter table public.ai_runs add column if not exists features jsonb;

alter table public.ai_actions drop constraint if exists ai_actions_kind_check;
alter table public.ai_actions add constraint ai_actions_kind_check
  check (kind in (
    'code_request', 'code_change', 'code_plan', 'place_conversation', 'delete_code_request', 'delete_folder',
    'delete_conversation', 'split_conversation'
  ));
alter table public.ai_actions drop constraint if exists ai_actions_status_check;
alter table public.ai_actions add constraint ai_actions_status_check
  check (status in ('proposed', 'applied', 'rejected', 'failed', 'undone', 'expired'));

-- ---------------------------------------------------------------------------
-- 2) 요약 정리 (내부)
-- ---------------------------------------------------------------------------
-- 목록은 빈 줄을 빼고 12줄, 줄마다 500자까지.
create or replace function public.ai_split_list(p jsonb)
returns jsonb
language sql
immutable
set search_path = public
as $$
  select coalesce(jsonb_agg(s.v order by s.n), '[]'::jsonb)
  from (
    select left(btrim(e.v), 500) as v, e.n
      from jsonb_array_elements_text(case when jsonb_typeof(p) = 'array' then p else '[]'::jsonb end) with ordinality as e(v, n)
     where btrim(e.v) <> ''
     order by e.n
     limit 12
  ) s
$$;

-- 요약은 다섯 칸(목적·이어받을 배경·확정한 것·정하지 않은 것·다음 할 일)만 남긴다.
create or replace function public.ai_split_summary_clean(p jsonb)
returns jsonb
language sql
immutable
set search_path = public
as $$
  select jsonb_build_object(
    'purpose', left(btrim(coalesce(j ->> 'purpose', '')), 2000),
    'background', left(btrim(coalesce(j ->> 'background', '')), 4000),
    'decided', public.ai_split_list(j -> 'decided'),
    'open', public.ai_split_list(j -> 'open'),
    'next', public.ai_split_list(j -> 'next')
  )
  from (select case when jsonb_typeof(p) = 'object' then p else '{}'::jsonb end as j) src
$$;

-- ---------------------------------------------------------------------------
-- 3) 제안 (ai_think의 propose_conversation_split 도구, 사용자 JWT)
-- ---------------------------------------------------------------------------
-- p_start_message_id: 이번 턴의 사용자 메시지(ai_think가 저장한 id). 모델이 고른 값이 아니다.
-- p_user_requested: 사용자가 이번 메시지에서 직접 나누자고 했는지(ai_think가 메시지 글로 판단). 거절 뒤에도 제안할 수 있다.
create or replace function public.ai_conversation_split_propose(
  p_conversation_id uuid,
  p_start_message_id uuid,
  p_payload jsonb,
  p_preview jsonb default '{}'::jsonb,
  p_user_requested boolean default false
)
returns public.ai_actions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_conv public.ai_conversations;
  v_start public.ai_messages;
  v_payload jsonb := coalesce(p_payload, '{}'::jsonb);
  v_title text := left(btrim(coalesce(p_payload ->> 'title', '')), 120);
  v_summary jsonb;
  v_folder uuid;
  v_row public.ai_actions;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into v_conv from public.ai_conversations where id = p_conversation_id for update;
  if not found then
    raise exception 'conversation_not_found' using errcode = 'P0002';
  end if;
  select * into v_start from public.ai_messages where id = p_start_message_id and conversation_id = p_conversation_id;
  if not found or v_start.role <> 'user' then
    raise exception 'split_range_invalid' using errcode = '22023';
  end if;
  if exists (
    select 1 from public.ai_messages m
     where m.conversation_id = p_conversation_id and m.role = 'user' and m.created_at > v_start.created_at
  ) then
    raise exception 'split_expired' using errcode = '22023';
  end if;
  if not exists (
    select 1 from public.ai_messages m
     where m.conversation_id = p_conversation_id and m.created_at < v_start.created_at
  ) then
    raise exception 'split_nothing_before' using errcode = '22023';
  end if;
  if not v_conv.auto_split_suggestions and not coalesce(p_user_requested, false) then
    raise exception 'split_suppressed' using errcode = '22023';
  end if;
  if v_title = '' then
    raise exception 'split_title_required' using errcode = '22023';
  end if;
  v_summary := public.ai_split_summary_clean(v_payload -> 'summary');
  if v_summary ->> 'purpose' = '' then
    raise exception 'split_summary_required' using errcode = '22023';
  end if;
  v_folder := nullif(v_payload ->> 'folder_id', '')::uuid;
  if v_folder is not null and not exists (select 1 from public.ai_tree_nodes where id = v_folder and kind = 'folder') then
    raise exception 'tree_folder_not_found' using errcode = 'P0002';
  end if;

  update public.ai_actions
     set status = 'rejected', superseded = true, decided_at = now()
   where conversation_id = p_conversation_id
     and kind = 'split_conversation'
     and status = 'proposed';
  insert into public.ai_actions (conversation_id, kind, payload, preview)
  values (
    p_conversation_id,
    'split_conversation',
    jsonb_build_object(
      'title', v_title,
      'reason', left(btrim(coalesce(v_payload ->> 'reason', '')), 500),
      'summary', v_summary,
      'folder_id', v_folder,
      'start_message_id', v_start.id,
      'user_requested', coalesce(p_user_requested, false)
    ),
    coalesce(p_preview, '{}'::jsonb) || jsonb_build_object(
      'title', v_title,
      'start_preview', left(regexp_replace(btrim(v_start.content), '\s+', ' ', 'g'), 160)
    )
  )
  returning * into v_row;
  return v_row;
end
$$;

-- ---------------------------------------------------------------------------
-- 4) 승인 (ai_action_apply가 부른다. 앱이 직접 부르지 않는다)
-- ---------------------------------------------------------------------------
-- p_overrides: 사용자가 카드에서 고친 값만. {title, summary, folder_id(null = 미분류)}
create or replace function public.ai_conversation_split_apply(p_id uuid, p_overrides jsonb)
returns public.ai_actions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_over jsonb := coalesce(p_overrides, '{}'::jsonb);
  v_conv_id uuid;
  v_src public.ai_conversations;
  v_row public.ai_actions;
  v_start public.ai_messages;
  v_end public.ai_messages;
  v_title text;
  v_summary jsonb;
  v_folder uuid;
  v_new uuid;
  v_actions integer;
  v_requests integer;
  v_nodes integer;
  v_others integer;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select conversation_id into v_conv_id from public.ai_actions where id = p_id and kind = 'split_conversation';
  if not found then
    raise exception 'action_not_found' using errcode = 'P0002';
  end if;
  -- 원본 대화 → 제안 순서로 잠근다. 메시지 저장 트리거도 대화 행을 먼저 잠그므로 승인과 새 메시지가 한 줄로 선다.
  select * into v_src from public.ai_conversations where id = v_conv_id for update;
  if not found then
    raise exception 'conversation_not_found' using errcode = 'P0002';
  end if;
  select * into v_row from public.ai_actions where id = p_id for update;
  if not found then
    raise exception 'action_not_found' using errcode = 'P0002';
  end if;
  if v_row.status = 'applied' then
    return v_row;
  end if;
  if v_row.status = 'expired' then
    raise exception 'split_expired' using errcode = '22023';
  end if;
  if v_row.status <> 'proposed' then
    raise exception 'action_not_pending' using errcode = '22023';
  end if;
  if v_row.message_id is null then
    raise exception 'split_answer_pending' using errcode = '22023';
  end if;

  select * into v_start from public.ai_messages
   where id = nullif(v_row.payload ->> 'start_message_id', '')::uuid and conversation_id = v_conv_id;
  select * into v_end from public.ai_messages
   where id = v_row.message_id and conversation_id = v_conv_id;
  if v_start.id is null or v_end.id is null or v_start.role <> 'user' or v_end.role <> 'assistant'
     or v_end.created_at < v_start.created_at then
    raise exception 'split_range_invalid' using errcode = '22023';
  end if;
  if v_end.status <> 'complete' then
    raise exception 'split_answer_incomplete' using errcode = '22023';
  end if;
  if exists (
    select 1 from public.ai_messages m
     where m.conversation_id = v_conv_id and m.role = 'user' and m.created_at > v_start.created_at
  ) then
    raise exception 'split_expired' using errcode = '22023';
  end if;

  v_title := left(btrim(coalesce(nullif(btrim(v_over ->> 'title'), ''), v_row.payload ->> 'title', '')), 120);
  if v_title = '' then
    raise exception 'split_title_required' using errcode = '22023';
  end if;
  v_summary := public.ai_split_summary_clean(
    case when jsonb_typeof(v_over -> 'summary') = 'object' then v_over -> 'summary' else v_row.payload -> 'summary' end
  );
  if v_summary ->> 'purpose' = '' then
    raise exception 'split_summary_required' using errcode = '22023';
  end if;
  if v_over ? 'folder_id' then
    v_folder := nullif(v_over ->> 'folder_id', '')::uuid;
  else
    v_folder := nullif(v_row.payload ->> 'folder_id', '')::uuid;
  end if;
  if v_folder is not null and not exists (select 1 from public.ai_tree_nodes where id = v_folder and kind = 'folder') then
    raise exception 'tree_folder_not_found' using errcode = 'P0002';
  end if;

  insert into public.ai_conversations (
    title, scope_type, scope_id, split_from_conversation_id, split_from_action_id, split_summary
  )
  values (v_title, v_src.scope_type, v_src.scope_id, v_conv_id, p_id, v_summary)
  returning id into v_new;

  -- 원래 시각을 그대로 둔다(한 트랜잭션 안의 now()는 모두 같아 순서가 흔들린다). 실행 기록(run_id)은 원본에만 남긴다.
  insert into public.ai_messages (
    conversation_id, role, content, status, attachments, sources, tool_calls, commentary, model,
    context_excluded, source_message_id, created_by, created_at
  )
  select v_new, m.role, m.content, m.status, m.attachments, m.sources, m.tool_calls, m.commentary, m.model,
         m.context_excluded, m.id, m.created_by, m.created_at
    from public.ai_messages m
   where m.id in (v_start.id, v_end.id)
   order by m.created_at;

  update public.ai_conversations set last_message_at = now() where id = v_new;
  if v_folder is not null then
    perform public.ai_tree_place_conversation(v_new, v_folder, 2147483647);
  end if;

  -- 복사하지 않은 것을 결과에 남긴다: 두 메시지에 붙은 다른 제안 카드, 그 메시지로 만든 코드 요청·발췌·문서,
  -- 시작 메시지 뒤에 저장됐지만 이 문답이 아닌 메시지(예: 코드 조사 검토 답변).
  select count(*) into v_actions from public.ai_actions a
   where a.message_id in (v_start.id, v_end.id) and a.id <> p_id;
  select count(*) into v_requests from public.ai_code_requests r
   where r.source_message_ids && array[v_start.id, v_end.id];
  select count(distinct s.node_id) into v_nodes from public.ai_tree_node_sources s
   where s.message_id in (v_start.id, v_end.id);
  select count(*) into v_others from public.ai_messages m
   where m.conversation_id = v_conv_id and m.created_at >= v_start.created_at and m.id not in (v_start.id, v_end.id);

  update public.ai_actions
     set status = 'applied',
         error = null,
         decided_at = now(),
         decided_by = auth.uid(),
         result = jsonb_build_object(
           'conversation_id', v_new,
           'title', v_title,
           'folder_id', v_folder,
           'copied_message_ids', jsonb_build_array(v_start.id, v_end.id),
           'edited', v_over <> '{}'::jsonb,
           'not_copied', jsonb_build_object(
             'actions', v_actions, 'code_requests', v_requests, 'tree_nodes', v_nodes, 'other_messages', v_others
           )
         )
   where id = p_id
  returning * into v_row;
  return v_row;
end
$$;

-- ---------------------------------------------------------------------------
-- 5) 기존 제안 RPC 다시 정의
-- ---------------------------------------------------------------------------
-- 나누기는 전용 RPC로만 제안한다(범위 확인을 건너뛰지 못하게).
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
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_kind = 'split_conversation' then
    raise exception 'split_use_dedicated_rpc' using errcode = '22023';
  end if;
  if not exists (select 1 from public.ai_conversations where id = p_conversation_id) then
    raise exception 'conversation_not_found' using errcode = 'P0002';
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

-- 나누기를 거절하면 그 대화에서는 자동으로 다시 제안하지 않는다.
create or replace function public.ai_action_reject(p_id uuid)
returns public.ai_actions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.ai_actions;
  v_conv uuid;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  -- 나누기는 승인·메시지 저장과 같은 순서(대화 → 제안)로 잠근다.
  select conversation_id into v_conv from public.ai_actions where id = p_id and kind = 'split_conversation';
  if v_conv is not null then
    perform 1 from public.ai_conversations where id = v_conv for update;
  end if;
  update public.ai_actions
     set status = 'rejected', decided_at = now(), decided_by = auth.uid()
   where id = p_id and status = 'proposed'
  returning * into v_row;
  if not found then
    raise exception 'action_not_pending' using errcode = '22023';
  end if;
  if v_row.kind = 'split_conversation' then
    update public.ai_conversations set auto_split_suggestions = false where id = v_row.conversation_id;
  end if;
  return v_row;
end
$$;

-- 승인. 대상을 다시 확인하고 실행한 뒤 결과를 남긴다. 실패하면 예외로 전체를 되돌리고 제안은 대기 상태로 남는다.
-- p_overrides: 사용자가 카드에서 고친 값만. code_*: {title, spec}, place_conversation: {folder_id},
-- split_conversation: {title, summary, folder_id}
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
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  -- 나누기는 원본 대화를 먼저 잠가야 해서 따로 처리한다.
  if exists (select 1 from public.ai_actions where id = p_id and kind = 'split_conversation') then
    return public.ai_conversation_split_apply(p_id, v_over);
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
      insert into public.ai_tree_nodes (kind, parent_id, title, created_via, sort_order)
      values ('folder', v_parent, left(btrim(v_row.payload ->> 'new_folder_title'), 120), 'ai', 2147483647)
      returning id into v_new_folder;
      perform public.ai_tree_renumber(v_parent);
      v_folder := v_new_folder;
    elsif v_folder is null then
      v_folder := nullif(v_row.payload ->> 'folder_id', '')::uuid;
    end if;
    if v_folder is null or not exists (select 1 from public.ai_tree_nodes where id = v_folder and kind = 'folder') then
      raise exception 'tree_folder_not_found' using errcode = 'P0002';
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

-- ---------------------------------------------------------------------------
-- 6) 메시지 저장 트리거: 대화가 이어지면 대기 중 나누기 제안을 만료시킨다
-- ---------------------------------------------------------------------------
create or replace function public.ai_messages_after_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.ai_conversations
     set last_message_at = new.created_at,
         message_count = message_count + 1
   where id = new.conversation_id;
  -- 범위가 더는 "이번 문답"이 아니다. 조용히 다른 메시지를 복사하지 않도록 제안을 닫는다.
  if new.role = 'user' and new.source_message_id is null then
    update public.ai_actions
       set status = 'expired', decided_at = now(), error = 'conversation_continued'
     where conversation_id = new.conversation_id
       and kind = 'split_conversation'
       and status = 'proposed';
  end if;
  return null;
end
$$;

-- ---------------------------------------------------------------------------
-- 7) 기능 확인·첨부 참조 (읽기 전용)
-- ---------------------------------------------------------------------------
-- 이 DB에 반영된 Think 기능과 버전. 데이터를 읽거나 바꾸지 않고 함수·열이 있는지만 본다.
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
    end
  );
end
$$;

-- p_paths 중 다른 대화의 메시지가 아직 가리키는 파일 경로.
create or replace function public.ai_attachment_paths_in_use(p_paths text[], p_except_conversation_id uuid)
returns text[]
language sql
stable
security invoker
set search_path = public
as $$
  select coalesce(array_agg(distinct a ->> 'path'), '{}'::text[])
    from public.ai_messages m
   cross join lateral jsonb_array_elements(
     case when jsonb_typeof(m.attachments) = 'array' then m.attachments else '[]'::jsonb end
   ) a
   where m.conversation_id <> p_except_conversation_id
     and a ->> 'path' = any(coalesce(p_paths, '{}'::text[]))
$$;

revoke all on function public.ai_split_list(jsonb) from public, anon, authenticated, service_role;
revoke all on function public.ai_split_summary_clean(jsonb) from public, anon, authenticated, service_role;
revoke all on function public.ai_conversation_split_propose(uuid, uuid, jsonb, jsonb, boolean) from public, anon, service_role;
revoke all on function public.ai_conversation_split_apply(uuid, jsonb) from public, anon, authenticated, service_role;
revoke all on function public.ai_think_db_features() from public, anon, service_role;
revoke all on function public.ai_attachment_paths_in_use(text[], uuid) from public, anon, service_role;
grant execute on function public.ai_conversation_split_propose(uuid, uuid, jsonb, jsonb, boolean) to authenticated;
grant execute on function public.ai_think_db_features() to authenticated;
grant execute on function public.ai_attachment_paths_in_use(text[], uuid) to authenticated;
