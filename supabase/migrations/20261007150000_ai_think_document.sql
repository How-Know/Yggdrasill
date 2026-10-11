-- 20261007150000: Think 종합 문서(kind=document) — 출처 연결·본문·순서·삭제 정책
-- - 발췌(summary)와 구분되는 body, 대화 순서대로 출처(메시지 id만, 원문 복제 없음)
-- - 출처 메시지가 하드 삭제되면 문서 노드 전체 삭제(발췌는 출처만 빠지고 노드 유지)
-- - RPC: ai_tree_create_document, ai_tree_get_document, ai_tree_update_document
-- 설계: docs/architecture/ai-think.md

-- ---------------------------------------------------------------------------
-- 1) 스키마
-- ---------------------------------------------------------------------------
alter table public.ai_tree_nodes
  add column if not exists body text;

alter table public.ai_tree_nodes drop constraint if exists ai_tree_nodes_kind_check;
alter table public.ai_tree_nodes
  add constraint ai_tree_nodes_kind_check
  check (kind in ('folder', 'conversation', 'excerpt', 'document'));

alter table public.ai_tree_nodes drop constraint if exists ai_tree_nodes_shape;
alter table public.ai_tree_nodes
  add constraint ai_tree_nodes_shape check (
    (kind = 'folder' and conversation_id is null and nullif(btrim(coalesce(title, '')), '') is not null)
    or (kind = 'conversation' and conversation_id is not null)
    or (kind = 'excerpt' and conversation_id is not null and nullif(btrim(coalesce(title, '')), '') is not null)
    or (
      kind = 'document'
      and conversation_id is not null
      and nullif(btrim(coalesce(title, '')), '') is not null
      and nullif(btrim(coalesce(body, '')), '') is not null
    )
  );

alter table public.ai_tree_node_sources
  add column if not exists sort_order integer not null default 0;

create index if not exists idx_ai_tree_node_sources_node_order
  on public.ai_tree_node_sources (node_id, sort_order);

-- ---------------------------------------------------------------------------
-- 2) 출처 검증·문서 삭제 트리거
-- ---------------------------------------------------------------------------
create or replace function public.ai_tree_node_sources_before_write()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if not exists (
    select 1
      from public.ai_tree_nodes n
      join public.ai_messages m on m.conversation_id = n.conversation_id
     where n.id = new.node_id
       and n.kind in ('excerpt', 'document')
       and m.id = new.message_id
  ) then
    raise exception 'tree_source_invalid' using errcode = '22023';
  end if;
  return new;
end
$$;

-- 종합 문서: 출처 연결이 하나라도 사라지면(메시지 DELETE cascade) 노드 전체 삭제
create or replace function public.ai_tree_node_sources_after_delete()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if exists (
    select 1 from public.ai_tree_nodes n where n.id = old.node_id and n.kind = 'document'
  ) then
    delete from public.ai_tree_nodes where id = old.node_id;
  end if;
  return old;
end
$$;

drop trigger if exists trg_ai_tree_node_sources_after_delete on public.ai_tree_node_sources;
create trigger trg_ai_tree_node_sources_after_delete
  after delete on public.ai_tree_node_sources
  for each row execute function public.ai_tree_node_sources_after_delete();

-- ---------------------------------------------------------------------------
-- 3) RPC
-- ---------------------------------------------------------------------------
create or replace function public.ai_tree_create_document(
  p_conversation_id uuid,
  p_parent_id uuid,
  p_title text,
  p_body text,
  p_message_ids uuid[]
)
returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_id uuid;
  v_wanted integer;
  v_found integer;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select count(distinct x) into v_wanted from unnest(coalesce(p_message_ids, '{}'::uuid[])) as x;
  if v_wanted = 0 then
    raise exception 'document_needs_messages' using errcode = '22023';
  end if;
  select count(*) into v_found
    from public.ai_messages
   where id = any(p_message_ids) and conversation_id = p_conversation_id;
  if v_found <> v_wanted then
    raise exception 'tree_source_invalid' using errcode = '22023';
  end if;

  insert into public.ai_tree_nodes (kind, parent_id, title, body, conversation_id, sort_order)
  values (
    'document',
    p_parent_id,
    btrim(coalesce(p_title, '')),
    btrim(coalesce(p_body, '')),
    p_conversation_id,
    (select coalesce(max(sort_order) + 1, 0) from public.ai_tree_nodes where parent_id is not distinct from p_parent_id)
  )
  returning id into v_id;

  insert into public.ai_tree_node_sources (node_id, message_id, sort_order)
  select v_id, m.id, (row_number() over (order by m.created_at, m.id) - 1)::integer
    from public.ai_messages m
   where m.id = any(p_message_ids) and m.conversation_id = p_conversation_id;

  return v_id;
end
$$;

create or replace function public.ai_tree_get_document(p_node_id uuid)
returns table (
  id uuid,
  parent_id uuid,
  conversation_id uuid,
  title text,
  body text,
  version integer,
  source_message_ids uuid[]
)
language plpgsql
security invoker
set search_path = public
as $$
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if not exists (select 1 from public.ai_tree_nodes where id = p_node_id and kind = 'document') then
    raise exception 'document_not_found' using errcode = 'P0002';
  end if;
  return query
  select
    n.id,
    n.parent_id,
    n.conversation_id,
    n.title,
    n.body,
    n.version,
    coalesce(
      (select array_agg(s.message_id order by s.sort_order, s.created_at, s.message_id)
         from public.ai_tree_node_sources s
        where s.node_id = n.id),
      '{}'::uuid[]
    )
  from public.ai_tree_nodes n
  where n.id = p_node_id and n.kind = 'document';
end
$$;

create or replace function public.ai_tree_update_document(
  p_node_id uuid,
  p_title text,
  p_body text,
  p_expected_version integer
)
returns public.ai_tree_nodes
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_row public.ai_tree_nodes;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update public.ai_tree_nodes
     set title = btrim(coalesce(p_title, '')),
         body = btrim(coalesce(p_body, ''))
   where id = p_node_id
     and kind = 'document'
     and version = p_expected_version
  returning * into v_row;
  if not found then
    if exists (select 1 from public.ai_tree_nodes where id = p_node_id and kind = 'document') then
      raise exception 'document_version_conflict' using errcode = '22023';
    end if;
    raise exception 'document_not_found' using errcode = 'P0002';
  end if;
  return v_row;
end
$$;

-- 발췌 생성 시 출처 순서(대화 순) 기록
create or replace function public.ai_tree_create_excerpt(
  p_conversation_id uuid,
  p_parent_id uuid,
  p_title text,
  p_summary text,
  p_message_ids uuid[]
)
returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_id uuid;
  v_wanted integer;
  v_found integer;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select count(distinct x) into v_wanted from unnest(coalesce(p_message_ids, '{}'::uuid[])) as x;
  if v_wanted = 0 then
    raise exception 'excerpt_needs_messages' using errcode = '22023';
  end if;
  select count(*) into v_found
    from public.ai_messages
   where id = any(p_message_ids) and conversation_id = p_conversation_id;
  if v_found <> v_wanted then
    raise exception 'tree_source_invalid' using errcode = '22023';
  end if;

  insert into public.ai_tree_nodes (kind, parent_id, title, summary, conversation_id, sort_order)
  values (
    'excerpt',
    p_parent_id,
    btrim(coalesce(p_title, '')),
    nullif(btrim(coalesce(p_summary, '')), ''),
    p_conversation_id,
    (select coalesce(max(sort_order) + 1, 0) from public.ai_tree_nodes where parent_id is not distinct from p_parent_id)
  )
  returning id into v_id;

  insert into public.ai_tree_node_sources (node_id, message_id, sort_order)
  select v_id, m.id, (row_number() over (order by m.created_at, m.id) - 1)::integer
    from public.ai_messages m
   where m.id = any(p_message_ids) and m.conversation_id = p_conversation_id;

  return v_id;
end
$$;

grant execute on function public.ai_tree_create_document(uuid, uuid, text, text, uuid[]) to authenticated;
grant execute on function public.ai_tree_get_document(uuid) to authenticated;
grant execute on function public.ai_tree_update_document(uuid, text, text, integer) to authenticated;
