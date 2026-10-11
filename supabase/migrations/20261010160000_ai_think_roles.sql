-- 20261010160000: Think 역할별 자료 접근, 대화–기억·종합 문서 링크, 답변 맥락 스냅샷, 범위 판정 기억 검색
-- 설계: docs/architecture/ai-think.md, ai-think-actions.md

-- ---------------------------------------------------------------------------
-- 1) 대화 역할·추가 참조 범위
-- ---------------------------------------------------------------------------
alter table public.ai_conversations
  add column if not exists think_role_id text not null default 'lead'
    check (think_role_id in ('lead', 'education', 'product', 'engineering')),
  add column if not exists role_profile_version text,
  add column if not exists extra_ref_departments text[] not null default '{}'::text[];

alter table public.ai_conversations drop constraint if exists ai_conversations_extra_ref_departments_check;
alter table public.ai_conversations add constraint ai_conversations_extra_ref_departments_check
  check (extra_ref_departments <@ array['education', 'product', 'engineering']::text[]);

-- ---------------------------------------------------------------------------
-- 2) 기억 범위 (기존 행은 legacy_unscoped = 레거시 공통)
-- ---------------------------------------------------------------------------
alter table public.ai_memories
  add column if not exists memory_scope text not null default 'legacy_unscoped'
    check (memory_scope in ('legacy_unscoped', 'common', 'department')),
  add column if not exists scope_department text
    check (
      scope_department is null
      or scope_department in ('education', 'product', 'engineering')
    );

alter table public.ai_memories drop constraint if exists ai_memories_scope_department_shape;
alter table public.ai_memories add constraint ai_memories_scope_department_shape check (
  (memory_scope = 'department' and scope_department is not null)
  or (memory_scope <> 'department' and scope_department is null)
);

-- ---------------------------------------------------------------------------
-- 3) 대화–승인 기억·종합 문서 링크
-- ---------------------------------------------------------------------------
create table if not exists public.ai_conversation_memory_links (
  conversation_id uuid not null references public.ai_conversations(id) on delete cascade,
  memory_id uuid not null references public.ai_memories(id) on delete cascade,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  primary key (conversation_id, memory_id)
);

create index if not exists idx_ai_conv_memory_links_memory
  on public.ai_conversation_memory_links (memory_id);

create table if not exists public.ai_conversation_document_links (
  conversation_id uuid not null references public.ai_conversations(id) on delete cascade,
  document_node_id uuid not null references public.ai_tree_nodes(id) on delete cascade,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  primary key (conversation_id, document_node_id)
);

create index if not exists idx_ai_conv_document_links_node
  on public.ai_conversation_document_links (document_node_id);

alter table public.ai_conversation_memory_links enable row level security;
alter table public.ai_conversation_document_links enable row level security;

drop policy if exists ai_conv_memory_links_superadmin on public.ai_conversation_memory_links;
create policy ai_conv_memory_links_superadmin on public.ai_conversation_memory_links
  for all using (public.is_superadmin()) with check (public.is_superadmin());

drop policy if exists ai_conv_document_links_superadmin on public.ai_conversation_document_links;
create policy ai_conv_document_links_superadmin on public.ai_conversation_document_links
  for all using (public.is_superadmin()) with check (public.is_superadmin());

-- ---------------------------------------------------------------------------
-- 4) 답변별 역할·실제 전달 자료 스냅샷
-- ---------------------------------------------------------------------------
create table if not exists public.ai_message_context_snapshots (
  message_id uuid primary key references public.ai_messages(id) on delete cascade,
  run_id uuid references public.ai_runs(id) on delete set null,
  think_role_id text not null check (think_role_id in ('lead', 'education', 'product', 'engineering')),
  role_profile_version text,
  applied_scope jsonb not null default '{}'::jsonb,
  materials jsonb not null default '[]'::jsonb
    check (jsonb_typeof(materials) = 'array' and octet_length(materials::text) <= 100000),
  created_at timestamptz not null default now()
);

alter table public.ai_message_context_snapshots enable row level security;
drop policy if exists ai_message_context_snapshots_superadmin on public.ai_message_context_snapshots;
create policy ai_message_context_snapshots_superadmin on public.ai_message_context_snapshots
  for all using (public.is_superadmin()) with check (public.is_superadmin());

alter table public.ai_runs add column if not exists role_profile_version text;

-- ---------------------------------------------------------------------------
-- 5) 링크 RPC (승인·접근 재검증)
-- ---------------------------------------------------------------------------
create or replace function public.ai_memory_linkable(p_memory_id uuid)
returns boolean
language sql
stable
security invoker
set search_path = public
as $$
  select exists (
    select 1 from public.ai_memories m
     where m.id = p_memory_id
       and m.status = 'active'
  );
$$;

create or replace function public.ai_conversation_memory_link(p_conversation_id uuid, p_memory_id uuid)
returns public.ai_conversation_memory_links
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_row public.ai_conversation_memory_links;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if not exists (select 1 from public.ai_conversations where id = p_conversation_id) then
    raise exception 'conversation_not_found' using errcode = 'P0002';
  end if;
  if not public.ai_memory_linkable(p_memory_id) then
    raise exception 'memory_not_linkable' using errcode = '22023';
  end if;
  insert into public.ai_conversation_memory_links (conversation_id, memory_id)
  values (p_conversation_id, p_memory_id)
  on conflict do nothing
  returning * into v_row;
  if v_row.conversation_id is null then
    select * into v_row from public.ai_conversation_memory_links
     where conversation_id = p_conversation_id and memory_id = p_memory_id;
  end if;
  return v_row;
end
$$;

create or replace function public.ai_conversation_memory_unlink(p_conversation_id uuid, p_memory_id uuid)
returns void
language plpgsql
security invoker
set search_path = public
as $$
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  delete from public.ai_conversation_memory_links
   where conversation_id = p_conversation_id and memory_id = p_memory_id;
end
$$;

create or replace function public.ai_document_linkable(p_document_node_id uuid)
returns boolean
language sql
stable
security invoker
set search_path = public
as $$
  select exists (
    select 1 from public.ai_tree_nodes n
     where n.id = p_document_node_id and n.kind = 'document'
  );
$$;

create or replace function public.ai_conversation_document_link(p_conversation_id uuid, p_document_node_id uuid)
returns public.ai_conversation_document_links
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_row public.ai_conversation_document_links;
  v_conv uuid;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select conversation_id into v_conv from public.ai_tree_nodes
   where id = p_document_node_id and kind = 'document';
  if v_conv is null then
    raise exception 'document_not_found' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.ai_conversations where id = p_conversation_id) then
    raise exception 'conversation_not_found' using errcode = 'P0002';
  end if;
  insert into public.ai_conversation_document_links (conversation_id, document_node_id)
  values (p_conversation_id, p_document_node_id)
  on conflict do nothing
  returning * into v_row;
  if v_row.conversation_id is null then
    select * into v_row from public.ai_conversation_document_links
     where conversation_id = p_conversation_id and document_node_id = p_document_node_id;
  end if;
  return v_row;
end
$$;

create or replace function public.ai_conversation_document_unlink(p_conversation_id uuid, p_document_node_id uuid)
returns void
language plpgsql
security invoker
set search_path = public
as $$
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  delete from public.ai_conversation_document_links
   where conversation_id = p_conversation_id and document_node_id = p_document_node_id;
end
$$;

create or replace function public.ai_conversation_set_think_role(
  p_conversation_id uuid,
  p_think_role_id text,
  p_extra_ref_departments text[] default '{}'::text[],
  p_role_profile_version text default null
)
returns public.ai_conversations
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_row public.ai_conversations;
  v_refs text[] := coalesce(p_extra_ref_departments, '{}'::text[]);
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_think_role_id not in ('lead', 'education', 'product', 'engineering') then
    raise exception 'think_role_invalid' using errcode = '22023';
  end if;
  if exists (select 1 from unnest(v_refs) r where r not in ('education', 'product', 'engineering')) then
    raise exception 'extra_ref_invalid' using errcode = '22023';
  end if;
  update public.ai_conversations
     set think_role_id = p_think_role_id,
         extra_ref_departments = v_refs,
         role_profile_version = coalesce(nullif(btrim(p_role_profile_version), ''), role_profile_version)
   where id = p_conversation_id
  returning * into v_row;
  if not found then
    raise exception 'conversation_not_found' using errcode = 'P0002';
  end if;
  return v_row;
end
$$;

-- ---------------------------------------------------------------------------
-- 6) 대화 나누기: 역할·유효 링크 승계
-- ---------------------------------------------------------------------------
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
    title, scope_type, scope_id, split_from_conversation_id, split_from_action_id, split_summary,
    think_role_id, role_profile_version, extra_ref_departments
  )
  values (
    v_title, v_src.scope_type, v_src.scope_id, v_conv_id, p_id, v_summary,
    v_src.think_role_id, v_src.role_profile_version, v_src.extra_ref_departments
  )
  returning id into v_new;

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

  -- 승인 active 기억 링크만 승계
  insert into public.ai_conversation_memory_links (conversation_id, memory_id, created_by)
  select v_new, l.memory_id, l.created_by
    from public.ai_conversation_memory_links l
    join public.ai_memories m on m.id = l.memory_id and m.status = 'active'
   where l.conversation_id = v_conv_id
  on conflict do nothing;

  -- 접근 가능한 종합 문서 링크만 승계
  insert into public.ai_conversation_document_links (conversation_id, document_node_id, created_by)
  select v_new, l.document_node_id, l.created_by
    from public.ai_conversation_document_links l
    join public.ai_tree_nodes n on n.id = l.document_node_id and n.kind = 'document'
   where l.conversation_id = v_conv_id
  on conflict do nothing;

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
-- 7) 범위를 판정하는 기억 검색
--    ai_search_memories는 범위 열을 돌려주지 않아, 거기서 거르면 부서 기억이 공통처럼 보인다.
--    p_mode: all(대화와 무관한 운영자 조회) / legacy(역할 기능 미준비: 철학·공통·레거시만)
--            / lead(모든 부서) / education·product·engineering(자기 부서 + 참조 부서 + 대화에 연결한 기억)
-- ---------------------------------------------------------------------------
create or replace function public.ai_search_memories_scoped(
  p_terms text[],
  p_limit integer default 8,
  p_mode text default 'legacy',
  p_extra_refs text[] default '{}'::text[],
  p_linked_ids uuid[] default '{}'::uuid[]
)
returns table (
  id uuid,
  kind text,
  status text,
  title text,
  content text,
  decision_context text,
  decision_reason text,
  alternatives text[],
  tags text[],
  updated_at timestamptz,
  memory_scope text,
  scope_department text,
  score integer
)
language plpgsql
stable
security invoker
set search_path = public
as $$
#variable_conflict use_column
begin
  if coalesce(p_mode, '') not in ('all', 'legacy', 'lead', 'education', 'product', 'engineering') then
    raise exception 'memory_search_mode_invalid' using errcode = '22023';
  end if;
  return query
  with terms as (
    select distinct lower(trim(t)) as t
    from unnest(coalesce(p_terms, '{}'::text[])) as t
    where length(trim(t)) >= 2
  ),
  visible as (
    select m.*
    from public.ai_memories m
    where m.status = 'active'
      and (
        p_mode = 'all'
        or m.kind = 'identity'
        or m.memory_scope in ('legacy_unscoped', 'common')
        or (p_mode <> 'legacy' and m.memory_scope = 'department' and (
              p_mode = 'lead'
              or m.scope_department = p_mode
              or m.scope_department = any(coalesce(p_extra_refs, '{}'::text[]))
              or m.id = any(coalesce(p_linked_ids, '{}'::uuid[]))
            ))
      )
  ),
  scored as (
    select v.*,
           (
             select count(*)::integer
             from terms
             where position(
               terms.t in lower(
                 v.title || ' ' || v.content || ' ' ||
                 coalesce(v.decision_context, '') || ' ' ||
                 coalesce(v.decision_reason, '') || ' ' ||
                 array_to_string(v.alternatives, ' ') || ' ' ||
                 array_to_string(v.tags, ' ')
               )
             ) > 0
           ) as score
    from visible v
  )
  select s.id, s.kind, s.status, s.title, s.content, s.decision_context, s.decision_reason,
         s.alternatives, s.tags, s.updated_at, s.memory_scope, s.scope_department, s.score
  from scored s
  where s.score > 0
  order by s.score desc, s.updated_at desc
  limit greatest(1, least(coalesce(p_limit, 8), 30));
end
$$;

revoke all on function public.ai_search_memories_scoped(text[], integer, text, text[], uuid[]) from public, anon;
grant execute on function public.ai_search_memories_scoped(text[], integer, text, text[], uuid[]) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 8) 기능 확인
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
    end
  );
end
$$;

revoke all on function public.ai_memory_linkable(uuid) from public, anon;
revoke all on function public.ai_document_linkable(uuid) from public, anon;
revoke all on function public.ai_conversation_memory_link(uuid, uuid) from public, anon;
revoke all on function public.ai_conversation_memory_unlink(uuid, uuid) from public, anon;
revoke all on function public.ai_conversation_document_link(uuid, uuid) from public, anon;
revoke all on function public.ai_conversation_document_unlink(uuid, uuid) from public, anon;
revoke all on function public.ai_conversation_set_think_role(uuid, text, text[], text) from public, anon;

grant execute on function public.ai_memory_linkable(uuid) to authenticated;
grant execute on function public.ai_document_linkable(uuid) to authenticated;
grant execute on function public.ai_conversation_memory_link(uuid, uuid) to authenticated;
grant execute on function public.ai_conversation_memory_unlink(uuid, uuid) to authenticated;
grant execute on function public.ai_conversation_document_link(uuid, uuid) to authenticated;
grant execute on function public.ai_conversation_document_unlink(uuid, uuid) to authenticated;
grant execute on function public.ai_conversation_set_think_role(uuid, text, text[], text) to authenticated;
