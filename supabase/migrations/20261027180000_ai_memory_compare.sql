-- 기억 제안은 이번 요청에서 서버가 실제로 읽힌 원문 판에만 기대게 한다.
-- 검색 발췌·모델이 적은 version·비교 완료 표식은 근거가 아니다.
-- 전달 기록은 기억 저장소가 아니다. 확정 기억은 계속 ai_memories, 이력은 ai_memory_revisions.
-- 버전 없는 대기 카드는 지우거나 최신 판으로 채우지 않고, 승인만 거절한다.
-- 직접 편집·피드백·의존 묶음 승인은 이 파일에서 바꾸지 않는다.

-- ---------------------------------------------------------------------------
-- 1) 이번 요청의 조회 기록
-- ---------------------------------------------------------------------------
create table if not exists public.ai_memory_read_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  conversation_id uuid not null references public.ai_conversations(id) on delete cascade,
  created_at timestamptz not null default now()
);

create index if not exists idx_ai_memory_read_sessions_conversation
  on public.ai_memory_read_sessions (conversation_id, created_at desc);

create table if not exists public.ai_memory_deliveries (
  id bigserial primary key,
  session_id uuid not null references public.ai_memory_read_sessions(id) on delete cascade,
  kind text not null check (kind in ('search', 'read')),
  status text not null check (status in (
    'ok', 'empty', 'truncated', 'not_found', 'forbidden', 'timeout', 'error', 'version_changed'
  )),
  memory_id uuid,
  version integer,
  query text,
  hit_count integer,
  scope text,
  offset_chars integer not null default 0,
  delivered_chars integer not null default 0,
  content_chars integer not null default 0,
  title text,
  created_at timestamptz not null default now()
);

create index if not exists idx_ai_memory_deliveries_session
  on public.ai_memory_deliveries (session_id, kind, memory_id);

alter table public.ai_memory_read_sessions enable row level security;
alter table public.ai_memory_deliveries enable row level security;
drop policy if exists ai_memory_read_sessions_superadmin on public.ai_memory_read_sessions;
create policy ai_memory_read_sessions_superadmin on public.ai_memory_read_sessions
  for all using (public.is_superadmin()) with check (public.is_superadmin());
drop policy if exists ai_memory_deliveries_superadmin on public.ai_memory_deliveries;
create policy ai_memory_deliveries_superadmin on public.ai_memory_deliveries
  for all using (public.is_superadmin()) with check (public.is_superadmin());

-- ---------------------------------------------------------------------------
-- 2) 대화 역할로 기억을 볼 수 있는지. 모델이 넘긴 범위 값은 쓰지 않는다.
-- ---------------------------------------------------------------------------
create or replace function public.ai_memory_visible_to_conversation(p_conversation uuid, p_memory uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_role text;
  v_refs text[];
  v_linked uuid[];
  v_mem public.ai_memories;
begin
  select think_role_id, extra_ref_departments into v_role, v_refs
    from public.ai_conversations where id = p_conversation;
  if not found then
    return false;
  end if;
  select * into v_mem from public.ai_memories where id = p_memory;
  if not found or v_mem.status <> 'active' then
    return false;
  end if;
  select coalesce(array_agg(memory_id), '{}'::uuid[]) into v_linked
    from public.ai_conversation_memory_links where conversation_id = p_conversation;
  if v_mem.kind = 'identity'
     or coalesce(v_mem.memory_scope, 'legacy_unscoped') in ('legacy_unscoped', 'common') then
    return true;
  end if;
  if v_mem.memory_scope = 'department' and (
       v_role = 'lead'
       or v_mem.scope_department = v_role
       or v_mem.scope_department = any(coalesce(v_refs, '{}'::text[]))
       or v_mem.id = any(coalesce(v_linked, '{}'::uuid[]))
     ) then
    return true;
  end if;
  return false;
end
$$;

create or replace function public.ai_memory_document(p_memory public.ai_memories)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'content', coalesce(p_memory.content, ''),
    'decision_context', p_memory.decision_context,
    'decision_reason', p_memory.decision_reason,
    'alternatives', to_jsonb(p_memory.alternatives),
    'tags', to_jsonb(p_memory.tags)
  )::text
$$;

create or replace function public.ai_memory_read_covered(
  p_session uuid,
  p_memory uuid,
  p_version integer,
  p_total integer
)
returns boolean
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_end integer := 0;
  r record;
begin
  for r in
    select offset_chars, delivered_chars
      from public.ai_memory_deliveries
     where session_id = p_session
       and memory_id = p_memory
       and kind = 'read'
       and version = p_version
       and status in ('ok', 'truncated')
     order by offset_chars, id
  loop
    if r.offset_chars > v_end then
      return false;
    end if;
    v_end := greatest(v_end, r.offset_chars + r.delivered_chars);
  end loop;
  return v_end >= p_total and p_total >= 0;
end
$$;

create or replace function public.ai_memory_session(p_session uuid, p_conversation uuid)
returns public.ai_memory_read_sessions
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_row public.ai_memory_read_sessions;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into v_row from public.ai_memory_read_sessions where id = p_session;
  if not found or v_row.user_id is distinct from auth.uid() or v_row.conversation_id is distinct from p_conversation then
    raise exception 'memory_read_session_invalid' using errcode = '22023';
  end if;
  return v_row;
end
$$;

create or replace function public.ai_memory_read_open(p_conversation_id uuid)
returns uuid
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if auth.uid() is null then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if not exists (select 1 from public.ai_conversations where id = p_conversation_id) then
    raise exception 'conversation_not_found' using errcode = 'P0002';
  end if;
  insert into public.ai_memory_read_sessions (user_id, conversation_id)
  values (auth.uid(), p_conversation_id)
  returning id into v_id;
  return v_id;
end
$$;

-- 성공(ok·empty)과 이어 읽기 완료는 이 함수들만 남긴다. 클라이언트의 "비교함"은 받지 않는다.
create or replace function public.ai_memory_note_outcome(
  p_session uuid,
  p_kind text,
  p_status text,
  p_memory_id uuid default null
)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_session public.ai_memory_read_sessions;
begin
  if p_kind not in ('search', 'read') or p_status not in ('error', 'timeout') then
    raise exception 'memory_outcome_invalid' using errcode = '22023';
  end if;
  select * into v_session from public.ai_memory_read_sessions where id = p_session;
  if not found or v_session.user_id is distinct from auth.uid() or not public.is_superadmin() then
    raise exception 'memory_read_session_invalid' using errcode = '22023';
  end if;
  insert into public.ai_memory_deliveries (session_id, kind, status, memory_id)
  values (p_session, p_kind, p_status, p_memory_id);
end
$$;

create or replace function public.ai_memory_search(p_session uuid, p_query text, p_terms text[])
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_session public.ai_memory_read_sessions;
  v_role text;
  v_refs text[];
  v_linked uuid[];
  v_query text := left(btrim(coalesce(p_query, '')), 200);
  v_terms text[] := '{}'::text[];
  v_hits jsonb := '[]'::jsonb;
  v_count integer := 0;
  v_status text;
  r record;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into v_session from public.ai_memory_read_sessions where id = p_session;
  if not found or v_session.user_id is distinct from auth.uid() then
    raise exception 'memory_read_session_invalid' using errcode = '22023';
  end if;
  select think_role_id, extra_ref_departments into v_role, v_refs
    from public.ai_conversations where id = v_session.conversation_id;
  select coalesce(array_agg(memory_id), '{}'::uuid[]) into v_linked
    from public.ai_conversation_memory_links where conversation_id = v_session.conversation_id;
  select coalesce(array_agg(distinct left(btrim(t), 80)), '{}'::text[]) into v_terms
    from unnest(coalesce(p_terms, '{}'::text[])) as t
   where length(btrim(t)) >= 2;
  v_terms := coalesce(v_terms, '{}'::text[]);
  if cardinality(v_terms) = 0 then
    insert into public.ai_memory_deliveries (session_id, kind, status, query, hit_count, scope)
    values (p_session, 'search', 'error', nullif(v_query, ''), 0, v_role);
    return jsonb_build_object(
      'status', 'error', 'error', 'memory_search_terms_empty', 'hit_count', 0,
      'scope', v_role, 'excerpt_only', true, 'hits', '[]'::jsonb
    );
  end if;
  for r in
    select s.id, s.kind, s.title, left(s.content, 500) as excerpt, m.version
      from public.ai_search_memories_scoped(v_terms, 10, v_role, coalesce(v_refs, '{}'::text[]), coalesce(v_linked, '{}'::uuid[])) s
      join public.ai_memories m on m.id = s.id
  loop
    v_count := v_count + 1;
    v_hits := v_hits || jsonb_build_array(jsonb_build_object(
      'id', r.id, 'kind', r.kind, 'title', r.title, 'excerpt', r.excerpt, 'version', r.version
    ));
  end loop;
  v_status := case when v_count = 0 then 'empty' else 'ok' end;
  insert into public.ai_memory_deliveries (session_id, kind, status, query, hit_count, scope)
  values (p_session, 'search', v_status, nullif(v_query, ''), v_count, v_role);
  return jsonb_build_object(
    'status', v_status, 'hit_count', v_count, 'scope', v_role, 'excerpt_only', true,
    'query', nullif(v_query, ''), 'hits', v_hits
  );
end
$$;

create or replace function public.ai_memory_read(p_session uuid, p_memory_id uuid, p_offset integer)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_session public.ai_memory_read_sessions;
  v_mem public.ai_memories;
  v_prev integer;
  v_doc text;
  v_total integer;
  v_off integer := greatest(coalesce(p_offset, 0), 0);
  v_slice text;
  v_take integer;
  v_id bigint;
  v_complete boolean := false;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into v_session from public.ai_memory_read_sessions where id = p_session;
  if not found or v_session.user_id is distinct from auth.uid() then
    raise exception 'memory_read_session_invalid' using errcode = '22023';
  end if;
  select * into v_mem from public.ai_memories where id = p_memory_id;
  if not found or v_mem.status <> 'active' then
    insert into public.ai_memory_deliveries (session_id, kind, status, memory_id)
    values (p_session, 'read', 'not_found', p_memory_id);
    return jsonb_build_object('status', 'not_found', 'id', p_memory_id, 'complete', false);
  end if;
  if not public.ai_memory_visible_to_conversation(v_session.conversation_id, p_memory_id) then
    insert into public.ai_memory_deliveries (session_id, kind, status, memory_id, version)
    values (p_session, 'read', 'forbidden', p_memory_id, v_mem.version);
    return jsonb_build_object('status', 'forbidden', 'id', p_memory_id, 'complete', false);
  end if;
  select version into v_prev
    from public.ai_memory_deliveries
   where session_id = p_session and memory_id = p_memory_id and kind = 'read' and status in ('ok', 'truncated')
   order by id desc
   limit 1;
  if v_off > 0 and v_prev is not null and v_prev is distinct from v_mem.version then
    insert into public.ai_memory_deliveries (session_id, kind, status, memory_id, version, title)
    values (p_session, 'read', 'version_changed', p_memory_id, v_mem.version, v_mem.title);
    return jsonb_build_object(
      'status', 'version_changed', 'id', p_memory_id, 'version', v_mem.version,
      'previous_version', v_prev, 'complete', false, 'offset', 0, 'next_offset', 0
    );
  end if;
  v_doc := public.ai_memory_document(v_mem);
  v_total := char_length(v_doc);
  if v_off > v_total then
    v_off := v_total;
  end if;
  -- 3500자면 따옴표가 이스케이프돼도 도구 출력 한도(12000) 안에 id·version·complete가 남는다.
  v_take := least(3500, v_total - v_off);
  v_slice := substr(v_doc, v_off + 1, v_take);
  insert into public.ai_memory_deliveries (
    session_id, kind, status, memory_id, version, title, offset_chars, delivered_chars, content_chars
  )
  values (
    p_session, 'read', 'truncated', p_memory_id, v_mem.version, v_mem.title, v_off, char_length(v_slice), v_total
  )
  returning id into v_id;
  v_complete := public.ai_memory_read_covered(p_session, p_memory_id, v_mem.version, v_total);
  if v_complete then
    update public.ai_memory_deliveries set status = 'ok' where id = v_id;
  end if;
  return jsonb_build_object(
    'status', case when v_complete then 'ok' else 'truncated' end,
    'id', p_memory_id,
    'version', v_mem.version,
    'title', v_mem.title,
    'kind', v_mem.kind,
    'memory_scope', v_mem.memory_scope,
    'scope_department', v_mem.scope_department,
    'offset', v_off,
    'next_offset', case when v_off + char_length(v_slice) < v_total then v_off + char_length(v_slice) end,
    'complete', v_complete,
    'content_chars', v_total,
    'document', v_slice
  );
end
$$;

create or replace function public.ai_memory_uuid_list(p jsonb, p_max integer)
returns uuid[]
language plpgsql
immutable
set search_path = public
as $$
declare
  v uuid[] := '{}'::uuid[];
  v_text text;
begin
  if jsonb_typeof(p) is distinct from 'array' then
    return v;
  end if;
  for v_text in
    select left(btrim(x), 80)
      from jsonb_array_elements_text(p) with ordinality as t(x, o)
     where btrim(x) <> ''
     order by o
     limit p_max
  loop
    begin
      v := v || v_text::uuid;
    exception when invalid_text_representation then
      raise exception 'memory_compared_id_invalid' using errcode = '22023';
    end;
  end loop;
  return v;
end
$$;

-- 제안 시점에 검색 성공과 원문 완독을 확인하고, 그 판을 카드에 남긴다. 최신 판으로 조용히 바꾸지 않는다.
create or replace function public.ai_memory_collect_basis(
  p_session uuid,
  p_conversation uuid,
  p_mem jsonb,
  p_relation text,
  p_compared jsonb
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_relation text := btrim(coalesce(p_relation, ''));
  v_sup uuid := nullif(p_mem ->> 'supersedes_id', '')::uuid;
  v_ids uuid[];
  v_sorted uuid[];
  v_id uuid;
  v_mem public.ai_memories;
  v_doc text;
  v_reads jsonb := '[]'::jsonb;
  v_searches jsonb;
  v_dup uuid;
  v_search text;
begin
  perform public.ai_memory_session(p_session, p_conversation);
  if v_relation not in ('duplicate', 'supplement', 'conflict', 'distinct', 'hold') then
    raise exception 'memory_relation_required' using errcode = '22023';
  end if;
  -- 마지막 검색만 본다. 성공 뒤에 시간 초과를 적으면 그 성공으로 제안하지 못한다.
  select status into v_search
    from public.ai_memory_deliveries
   where session_id = p_session and kind = 'search'
   order by id desc
   limit 1;
  if v_search is null then
    raise exception 'memory_search_required' using errcode = '22023';
  elsif v_search not in ('ok', 'empty') then
    raise exception 'memory_search_failed' using errcode = '22023';
  end if;
  v_ids := public.ai_memory_uuid_list(p_compared, 8);
  if v_sup is not null and (v_ids is null or not v_sup = any(v_ids)) then
    v_ids := coalesce(v_ids, '{}'::uuid[]) || v_sup;
  end if;
  select coalesce(array_agg(distinct u order by u), '{}'::uuid[]) into v_sorted
    from unnest(coalesce(v_ids, '{}'::uuid[])) as u;
  foreach v_id in array v_sorted
  loop
    select * into v_mem from public.ai_memories where id = v_id for update;
    if not found or v_mem.status <> 'active' then
      raise exception 'memory_read_missing:%', v_id using errcode = '22023';
    end if;
    if not public.ai_memory_visible_to_conversation(p_conversation, v_id) then
      raise exception 'memory_basis_forbidden:%', v_id using errcode = '42501';
    end if;
    v_doc := public.ai_memory_document(v_mem);
    if exists (
      select 1 from public.ai_memory_deliveries
       where session_id = p_session and kind = 'read' and memory_id = v_id
         and status = 'ok' and version = v_mem.version and content_chars = char_length(v_doc)
    ) then
      null;
    elsif exists (
      select 1 from public.ai_memory_deliveries
       where session_id = p_session and kind = 'read' and memory_id = v_id
         and status = 'truncated' and version = v_mem.version
    ) then
      raise exception 'memory_read_incomplete:%', v_id using errcode = '22023';
    elsif exists (
      select 1 from public.ai_memory_deliveries
       where session_id = p_session and kind = 'read' and memory_id = v_id
         and status in ('ok', 'truncated', 'version_changed') and version is distinct from v_mem.version
    ) then
      raise exception 'memory_reread_required:%', v_id using errcode = '22023';
    elsif exists (
      select 1 from public.ai_memory_deliveries
       where session_id = p_session and kind = 'read' and memory_id = v_id and status = 'forbidden'
    ) then
      raise exception 'memory_basis_forbidden:%', v_id using errcode = '42501';
    else
      raise exception 'memory_read_missing:%', v_id using errcode = '22023';
    end if;
    v_reads := v_reads || jsonb_build_array(jsonb_build_object(
      'id', v_mem.id,
      'version', v_mem.version,
      'title', v_mem.title,
      'role', case when v_mem.id = v_sup then 'supersede' else 'compared' end
    ));
  end loop;
  if v_relation = 'duplicate' then
    v_dup := coalesce(v_sup, v_sorted[1]);
    if v_dup is null then
      raise exception 'memory_duplicate_target_required' using errcode = '22023';
    end if;
    raise exception 'memory_duplicate_classified:%', v_dup using errcode = '23505';
  end if;
  if v_relation = 'hold' then
    raise exception 'memory_comparison_held' using errcode = '22023';
  end if;
  if v_relation in ('supplement', 'conflict') and v_sup is null and cardinality(coalesce(v_ids, '{}'::uuid[])) = 0 then
    raise exception 'memory_compare_target_required' using errcode = '22023';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'query', query, 'status', status, 'hit_count', hit_count, 'scope', scope
         ) order by id), '[]'::jsonb)
    into v_searches
    from (
      select id, query, status, hit_count, scope
        from public.ai_memory_deliveries
       where session_id = p_session and kind = 'search' and status in ('ok', 'empty')
       order by id desc
       limit 8
    ) s;
  return jsonb_build_object(
    'session_id', p_session,
    'relation', v_relation,
    'searches', v_searches,
    'reads', v_reads,
    'limit', 'searched_only'
  );
end
$$;

create or replace function public.ai_memory_recheck_basis(p_conversation uuid, p_basis jsonb, p_mem jsonb)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_sup uuid := nullif(p_mem ->> 'supersedes_id', '')::uuid;
  v_seen boolean := false;
  r record;
  v_mem public.ai_memories;
  v_hit uuid;
begin
  if jsonb_typeof(p_basis) is distinct from 'object'
     or jsonb_typeof(p_basis -> 'reads') is distinct from 'array'
     or jsonb_typeof(p_basis -> 'searches') is distinct from 'array'
     or jsonb_array_length(p_basis -> 'searches') = 0 then
    raise exception 'memory_basis_missing' using errcode = '22023';
  end if;
  if not exists (
    select 1 from jsonb_array_elements(p_basis -> 'searches') s
     where s ->> 'status' in ('ok', 'empty')
  ) then
    raise exception 'memory_basis_missing' using errcode = '22023';
  end if;
  for r in
    select (e ->> 'id')::uuid as id, (e ->> 'version')::integer as version
      from jsonb_array_elements(p_basis -> 'reads') with ordinality as t(e, o)
     where e ->> 'id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     order by (e ->> 'id')::uuid
  loop
    select * into v_mem from public.ai_memories where id = r.id for update;
    if not found or v_mem.status <> 'active' or v_mem.version is distinct from r.version then
      raise exception 'memory_version_conflict:%', r.id using errcode = '22023';
    end if;
    if not public.ai_memory_visible_to_conversation(p_conversation, r.id) then
      raise exception 'memory_basis_forbidden:%', r.id using errcode = '42501';
    end if;
    if r.id = v_sup then
      v_seen := true;
    end if;
  end loop;
  if v_sup is not null and not v_seen then
    raise exception 'memory_read_missing:%', v_sup using errcode = '22023';
  end if;
  if v_sup is not null then
    update public.ai_memories set status = 'superseded'
     where id = v_sup and version = (
       select (e ->> 'version')::integer
         from jsonb_array_elements(p_basis -> 'reads') e
        where e ->> 'id' = v_sup::text
        limit 1
     ) and status = 'active'
    returning id into v_hit;
    if v_hit is null then
      raise exception 'memory_supersede_lost' using errcode = '22023';
    end if;
  end if;
end
$$;

-- 거절된 같은 제목·같은 본문은 다시 제안하지 않는다. 대체되어 닫힌 카드는 막지 않는다.
create or replace function public.ai_memory_reject_same(p_mem jsonb)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  select id into v_id
    from public.ai_actions
   where kind = 'save_memory'
     and status = 'rejected'
     and not superseded
     and public.ai_memory_title_key(payload -> 'memory' ->> 'title') = public.ai_memory_title_key(p_mem ->> 'title')
     and payload -> 'memory' ->> 'content' = p_mem ->> 'content'
   limit 1;
  if v_id is not null then
    raise exception 'memory_proposal_rejected:%', v_id using errcode = '23505';
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- 3) 제안. 클라이언트가 실은 basis·version은 버리고 조회 기록으로 다시 만든다.
-- ---------------------------------------------------------------------------
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
  v_session uuid;
  v_basis jsonb;
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

  if p_kind = 'save_memory' then
    v_mem := public.ai_memory_proposal_clean(p_payload -> 'memory');
    perform public.ai_memory_proposal_guard(v_mem, null);
    perform public.ai_memory_reject_same(v_mem);
    begin
      v_session := nullif(btrim(coalesce(p_payload ->> 'read_session', '')), '')::uuid;
    exception when invalid_text_representation then
      raise exception 'memory_read_session_invalid' using errcode = '22023';
    end;
    v_basis := public.ai_memory_collect_basis(
      v_session, p_conversation_id, v_mem, p_payload ->> 'relation', p_payload -> 'compared_ids'
    );
    insert into public.ai_actions (conversation_id, kind, payload, preview)
    values (
      p_conversation_id, 'save_memory',
      jsonb_build_object('memory', v_mem, 'reason', v_reason, 'basis', v_basis),
      public.ai_memory_proposal_preview(v_mem, v_reason) || jsonb_build_object('relation', v_basis ->> 'relation')
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
      perform public.ai_memory_reject_same(v_mem);
      begin
        v_session := nullif(btrim(coalesce(p_payload ->> 'read_session', '')), '')::uuid;
      exception when invalid_text_representation then
        raise exception 'memory_read_session_invalid' using errcode = '22023';
      end;
      v_basis := public.ai_memory_collect_basis(
        v_session, p_conversation_id, v_mem, p_payload ->> 'relation', p_payload -> 'compared_ids'
      );
    end if;
    insert into public.ai_actions (conversation_id, kind, payload, preview)
    values (
      p_conversation_id, 'memory_card_change',
      jsonb_build_object('target_action_id', v_target.id, 'op', v_op, 'memory', v_mem, 'reason', v_reason, 'basis', v_basis),
      jsonb_build_object(
        'op', v_op,
        'title', coalesce(v_mem ->> 'title', v_target.preview ->> 'title'),
        'target_title', v_target.preview ->> 'title',
        'target_conversation_id', v_target.conversation_id,
        'memory_kind', v_mem ->> 'kind',
        'memory_scope', v_mem ->> 'memory_scope',
        'scope_department', v_mem ->> 'scope_department',
        'reason', v_reason,
        'relation', v_basis ->> 'relation'
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

-- ---------------------------------------------------------------------------
-- 4) 승인. 카드에 적힌 판이 아니면 통째로 롤백하고, 버전 없는 카드는 채우지 않는다.
-- ---------------------------------------------------------------------------
create or replace function public.ai_memory_action_apply(p_id uuid, p_overrides jsonb)
returns public.ai_actions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.ai_actions;
  v_over jsonb := coalesce(p_overrides, '{}'::jsonb);
  v_target public.ai_actions;
  v_mem jsonb;
  v_mem_id uuid;
  v_sup uuid;
  v_new public.ai_actions;
  v_result jsonb;
  v_op text;
  v_basis jsonb;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into v_row from public.ai_actions where id = p_id for update;
  if not found then
    raise exception 'action_not_found' using errcode = 'P0002';
  end if;
  if v_row.status <> 'proposed' then
    raise exception 'action_not_pending' using errcode = '22023';
  end if;

  if v_row.kind = 'save_memory' then
    v_mem := public.ai_memory_proposal_clean(
      case when jsonb_typeof(v_over -> 'memory') = 'object' then v_over -> 'memory' else v_row.payload -> 'memory' end
    );
    v_basis := v_row.payload -> 'basis';
    perform public.ai_memory_proposal_guard(v_mem, v_row.id);
    -- 대체 대상 상태 변경은 recheck 안에서 하고, 실패하면 이 함수의 삽입도 함께 롤백된다.
    perform public.ai_memory_recheck_basis(v_row.conversation_id, v_basis, v_mem);
    v_sup := nullif(v_mem ->> 'supersedes_id', '')::uuid;
    insert into public.ai_memories (
      kind, status, title, content, decision_context, decision_reason, alternatives, tags,
      supersedes_id, source_conversation_id, memory_scope, scope_department
    )
    values (
      v_mem ->> 'kind', 'active', v_mem ->> 'title', v_mem ->> 'content',
      case when v_mem ->> 'kind' = 'decision' then v_mem ->> 'decision_context' end,
      case when v_mem ->> 'kind' = 'decision' then v_mem ->> 'decision_reason' end,
      case when v_mem ->> 'kind' = 'decision'
        then array(select jsonb_array_elements_text(v_mem -> 'alternatives')) else '{}'::text[] end,
      array(select jsonb_array_elements_text(v_mem -> 'tags')),
      v_sup,
      (select id from public.ai_conversations where id = v_row.conversation_id),
      v_mem ->> 'memory_scope',
      v_mem ->> 'scope_department'
    )
    returning id into v_mem_id;
    v_result := jsonb_build_object(
      'memory_id', v_mem_id,
      'superseded_id', v_sup,
      'edited', coalesce(jsonb_typeof(v_over -> 'memory') = 'object', false)
    );

  elsif v_row.kind = 'memory_card_change' then
    select * into v_target
      from public.ai_actions
     where id = nullif(v_row.payload ->> 'target_action_id', '')::uuid
     for update;
    if not found or v_target.kind <> 'save_memory' or v_target.status <> 'proposed' then
      raise exception 'memory_card_not_pending' using errcode = '22023';
    end if;
    v_op := v_row.payload ->> 'op';
    if v_op = 'withdraw' then
      update public.ai_actions
         set status = 'rejected', decided_at = now(), decided_by = auth.uid(),
             result = jsonb_build_object('withdrawn_by_action_id', v_row.id)
       where id = v_target.id;
      v_result := jsonb_build_object('op', v_op, 'target_action_id', v_target.id);
    else
      v_mem := public.ai_memory_proposal_clean(
        case when jsonb_typeof(v_over -> 'memory') = 'object' then v_over -> 'memory' else v_row.payload -> 'memory' end
      );
      v_basis := v_row.payload -> 'basis';
      perform public.ai_memory_proposal_guard(v_mem, v_target.id);
      -- 변경 카드 승인에서는 기억을 대체하지 않는다. 판·권한만 다시 본다.
      perform public.ai_memory_recheck_basis_view(v_row.conversation_id, v_basis, v_mem);
      if v_op = 'revise' then
        update public.ai_actions
           set payload = jsonb_set(jsonb_set(payload, '{memory}', v_mem), '{basis}', v_basis),
               preview = public.ai_memory_proposal_preview(v_mem, payload ->> 'reason')
                 || jsonb_build_object('revised', true, 'relation', v_basis ->> 'relation')
         where id = v_target.id;
        v_result := jsonb_build_object('op', v_op, 'target_action_id', v_target.id);
      elsif v_op = 'replace' then
        update public.ai_actions
           set status = 'rejected', superseded = true, decided_at = now(), decided_by = auth.uid(),
               result = jsonb_build_object('replaced_by_action_id', v_row.id)
         where id = v_target.id;
        insert into public.ai_actions (conversation_id, message_id, kind, payload, preview)
        values (
          v_row.conversation_id, v_row.message_id, 'save_memory',
          jsonb_build_object('memory', v_mem, 'reason', v_row.payload ->> 'reason', 'basis', v_basis),
          public.ai_memory_proposal_preview(v_mem, v_row.payload ->> 'reason')
            || jsonb_build_object('relation', v_basis ->> 'relation')
        )
        returning * into v_new;
        v_result := jsonb_build_object('op', v_op, 'target_action_id', v_target.id, 'new_action_id', v_new.id);
      else
        raise exception 'memory_card_op_invalid' using errcode = '22023';
      end if;
    end if;

  else
    raise exception 'action_kind_not_appliable' using errcode = '22023';
  end if;

  update public.ai_actions
     set status = 'applied', result = v_result, error = null, decided_at = now(), decided_by = auth.uid()
   where id = p_id
  returning * into v_row;
  return v_row;
end
$$;

-- 저장 승인 전 판 검사. 대체 UPDATE는 하지 않는다(변경 카드가 기억을 바꾸지 않게).
create or replace function public.ai_memory_recheck_basis_view(p_conversation uuid, p_basis jsonb, p_mem jsonb)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_sup uuid := nullif(p_mem ->> 'supersedes_id', '')::uuid;
  v_seen boolean := false;
  r record;
  v_mem public.ai_memories;
begin
  if jsonb_typeof(p_basis) is distinct from 'object'
     or jsonb_typeof(p_basis -> 'reads') is distinct from 'array'
     or jsonb_typeof(p_basis -> 'searches') is distinct from 'array'
     or jsonb_array_length(p_basis -> 'searches') = 0 then
    raise exception 'memory_basis_missing' using errcode = '22023';
  end if;
  for r in
    select (e ->> 'id')::uuid as id, (e ->> 'version')::integer as version
      from jsonb_array_elements(p_basis -> 'reads') e
     where e ->> 'id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     order by (e ->> 'id')::uuid
  loop
    select * into v_mem from public.ai_memories where id = r.id for update;
    if not found or v_mem.status <> 'active' or v_mem.version is distinct from r.version then
      raise exception 'memory_version_conflict:%', r.id using errcode = '22023';
    end if;
    if not public.ai_memory_visible_to_conversation(p_conversation, r.id) then
      raise exception 'memory_basis_forbidden:%', r.id using errcode = '42501';
    end if;
    if r.id = v_sup then
      v_seen := true;
    end if;
  end loop;
  if v_sup is not null and not v_seen then
    raise exception 'memory_read_missing:%', v_sup using errcode = '22023';
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- 5) 기능 확인. 개념 표가 없는 시험 DB에서도 깨지지 않게 to_regclass를 쓴다.
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
      then 1 else 0 end,
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
      then 1 else 0 end,
    'memory_proposals',
    case
      when to_regprocedure('public.ai_memory_action_apply(uuid, jsonb)') is not null
       and to_regprocedure('public.ai_memory_proposal_clean(jsonb)') is not null
       and to_regprocedure('public.ai_memory_proposal_guard(jsonb, uuid)') is not null
       and to_regprocedure('public.ai_memory_read_open(uuid)') is not null
       and to_regprocedure('public.ai_memory_search(uuid, text, text[])') is not null
       and to_regprocedure('public.ai_memory_read(uuid, uuid, integer)') is not null
       and to_regprocedure('public.ai_memory_collect_basis(uuid, uuid, jsonb, text, jsonb)') is not null
       and to_regprocedure('public.ai_memory_recheck_basis(uuid, jsonb, jsonb)') is not null
      then 1 else 0 end,
    'department_work',
    case
      when exists (
         select 1 from pg_attribute
          where attrelid = 'public.ai_tree_nodes'::regclass and attname = 'department' and not attisdropped
       )
       and to_regprocedure('public.ai_tree_move_department(uuid, uuid, uuid, integer, text)') is not null
       and to_regprocedure('public.ai_conversation_move_department(uuid, text)') is not null
       and to_regprocedure('public.ai_department_handover_propose(uuid, text, text)') is not null
      then 1 else 0 end,
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
      then 1 else 0 end,
    'course_map_actions',
    case
      when exists (
         select 1 from pg_attribute
          where attrelid = to_regclass('public.concept_appearances') and attname = 'course_unit_id' and not attisdropped
       )
       and to_regprocedure('public.course_think_action_propose(uuid, text, jsonb)') is not null
       and to_regprocedure('public.course_think_action_apply(uuid, jsonb)') is not null
       and to_regprocedure('public.course_map_placements(uuid)') is not null
       and to_regprocedure('public.concept_placement_candidates(uuid, text, text, integer, integer)') is not null
       and to_regprocedure('public.concept_think_detail(uuid)') is not null
      then 1 else 0 end,
    'concept_review',
    case
      when to_regclass('public.concept_quality_reviews') is not null
       and to_regclass('public.concept_review_walks') is not null
       and to_regprocedure('public.concept_review_walk(uuid, jsonb, integer, integer)') is not null
       and to_regprocedure('public.concept_review_status(uuid[])') is not null
       and to_regprocedure('public.course_think_propose_review(uuid, jsonb, text)') is not null
       and to_regprocedure('public.course_think_apply_review(public.ai_actions, jsonb)') is not null
      then 1 else 0 end,
    'concept_relation_change',
    case
      when exists (
         select 1 from pg_attribute
          where attrelid = to_regclass('public.concept_relations') and attname = 'judged_marks' and not attisdropped
       )
       and to_regclass('public.concept_relation_events') is not null
       and to_regprocedure('public.concept_relation_list(uuid)') is not null
       and to_regprocedure('public.course_think_propose_relation(uuid, jsonb, text)') is not null
       and to_regprocedure('public.course_think_apply_relation(public.ai_actions, jsonb)') is not null
      then 1 else 0 end,
    'concept_source_pages',
    case
      when to_regclass('public.concept_source_page_images') is not null
       and to_regclass('public.concept_source_page_workers') is not null
       and to_regprocedure('public.concept_source_list(uuid)') is not null
       and to_regprocedure('public.concept_source_page_context(uuid, integer)') is not null
       and to_regprocedure('public.concept_source_page_image(uuid, integer, boolean)') is not null
      then 1 else 0 end,
    'concept_review_jobs',
    case
      when to_regclass('public.concept_review_jobs') is not null
       and to_regclass('public.concept_review_job_items') is not null
       and to_regclass('public.concept_review_job_cards') is not null
       and to_regprocedure('public.concept_review_jobs_find()') is not null
       and to_regprocedure('public.concept_review_job_claim(uuid, text, text)') is not null
       and to_regprocedure('public.concept_review_job_status(uuid, integer)') is not null
       and to_regprocedure('public.concept_review_job_next(uuid, bigint, integer)') is not null
       and to_regprocedure('public.concept_review_job_save(uuid, bigint, jsonb)') is not null
       and to_regprocedure('public.concept_review_job_submit(uuid, bigint, uuid, text, integer)') is not null
       and to_regprocedure('public.concept_review_job_cards_here(uuid, bigint, uuid)') is not null
      then 1 else 0 end,
    'concept_review_job_batch',
    case
      when to_regclass('public.concept_review_job_batches') is not null
       and to_regprocedure('public.concept_review_job_material(uuid, bigint, integer[], jsonb, integer)') is not null
       and to_regprocedure('public.concept_review_job_batch_begin(uuid, bigint)') is not null
       and to_regprocedure('public.concept_review_job_batch_log(uuid, bigint, uuid, integer, text, jsonb)') is not null
       and to_regprocedure('public.concept_review_job_targets(uuid, bigint, integer)') is not null
       and to_regprocedure('public.concept_review_job_courses(uuid, bigint)') is not null
       and to_regprocedure('public.concept_review_job_search(uuid, bigint, text[], integer)') is not null
       and exists (
         select 1 from pg_attribute
          where attrelid = to_regclass('public.concept_quality_reviews') and attname = 'fixes' and not attisdropped
       )
      then 1 else 0 end
  );
end
$$;

revoke all on function public.ai_memory_visible_to_conversation(uuid, uuid) from public, anon, authenticated;
revoke all on function public.ai_memory_document(public.ai_memories) from public, anon, authenticated;
revoke all on function public.ai_memory_read_covered(uuid, uuid, integer, integer) from public, anon, authenticated;
revoke all on function public.ai_memory_session(uuid, uuid) from public, anon, authenticated;
revoke all on function public.ai_memory_uuid_list(jsonb, integer) from public, anon, authenticated;
revoke all on function public.ai_memory_collect_basis(uuid, uuid, jsonb, text, jsonb) from public, anon, authenticated;
revoke all on function public.ai_memory_recheck_basis(uuid, jsonb, jsonb) from public, anon, authenticated;
revoke all on function public.ai_memory_recheck_basis_view(uuid, jsonb, jsonb) from public, anon, authenticated;
revoke all on function public.ai_memory_reject_same(jsonb) from public, anon, authenticated;

revoke all on function public.ai_memory_read_open(uuid) from public, anon;
revoke all on function public.ai_memory_search(uuid, text, text[]) from public, anon;
revoke all on function public.ai_memory_read(uuid, uuid, integer) from public, anon;
revoke all on function public.ai_memory_note_outcome(uuid, text, text, uuid) from public, anon;

grant execute on function public.ai_memory_read_open(uuid) to authenticated;
grant execute on function public.ai_memory_search(uuid, text, text[]) to authenticated;
grant execute on function public.ai_memory_read(uuid, uuid, integer) to authenticated;
grant execute on function public.ai_memory_note_outcome(uuid, text, text, uuid) to authenticated;

notify pgrst, 'reload schema';
