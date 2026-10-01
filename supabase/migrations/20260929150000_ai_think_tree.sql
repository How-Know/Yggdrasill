-- 20260929150000: Think 대화 정리 트리 + 메시지 '답변에서 제외'
-- - ai_tree_nodes: 폴더(주제) / 대화 배치 / 발췌(원본 메시지를 가리키는 요약 노드)
-- - ai_tree_node_sources: 발췌 노드 → 원본 메시지 (메시지가 지워지면 연결도 지워진다)
-- - ai_messages.context_excluded: 기록·트리에는 보이지만 AI 맥락(대화 기록, 결정 초안, 스펙)에서는 뺀다
-- - 이동·폴더 삭제·발췌 생성 RPC. 부모 종류·순환·깊이·출처 대화는 서버가 검증한다.
-- 기존 대화는 노드가 없으므로 화면에서 '정리 안 됨'에 모인다. 기존 행은 바꾸지 않는다.
-- 설계: docs/architecture/ai-think.md

-- ---------------------------------------------------------------------------
-- 1) 메시지 맥락 제외
-- ---------------------------------------------------------------------------
alter table public.ai_messages
  add column if not exists context_excluded boolean not null default false;

-- ---------------------------------------------------------------------------
-- 2) 트리 노드
-- ---------------------------------------------------------------------------
create table if not exists public.ai_tree_nodes (
  id uuid primary key default gen_random_uuid(),
  parent_id uuid references public.ai_tree_nodes(id) on delete restrict,
  kind text not null check (kind in ('folder', 'conversation', 'excerpt')),
  title text,
  summary text,
  sort_order integer not null default 0,
  conversation_id uuid references public.ai_conversations(id) on delete cascade,
  created_via text not null default 'user' check (created_via in ('user', 'ai')),
  version integer not null default 1,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ai_tree_nodes_shape check (
    (kind = 'folder' and conversation_id is null and nullif(btrim(coalesce(title, '')), '') is not null)
    or (kind = 'conversation' and conversation_id is not null)
    or (kind = 'excerpt' and conversation_id is not null and nullif(btrim(coalesce(title, '')), '') is not null)
  )
);

create unique index if not exists uq_ai_tree_nodes_conversation
  on public.ai_tree_nodes (conversation_id) where kind = 'conversation';
create index if not exists idx_ai_tree_nodes_parent
  on public.ai_tree_nodes (parent_id, sort_order);
create index if not exists idx_ai_tree_nodes_conversation
  on public.ai_tree_nodes (conversation_id);

create table if not exists public.ai_tree_node_sources (
  node_id uuid not null references public.ai_tree_nodes(id) on delete cascade,
  message_id uuid not null references public.ai_messages(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (node_id, message_id)
);

create index if not exists idx_ai_tree_node_sources_message
  on public.ai_tree_node_sources (message_id);

-- 부모는 폴더만 될 수 있고, 자기 자신이나 자기 아래로 옮길 수 없다. 종류와 대화는 바꿀 수 없다.
create or replace function public.ai_tree_nodes_before_write()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_parent_kind text;
  v_cursor uuid;
  v_depth integer := 0;
begin
  if tg_op = 'UPDATE' then
    if new.kind is distinct from old.kind then
      raise exception 'tree_kind_immutable' using errcode = '22023';
    end if;
    if new.conversation_id is distinct from old.conversation_id then
      raise exception 'tree_conversation_immutable' using errcode = '22023';
    end if;
  end if;

  if new.parent_id is not null and (tg_op = 'INSERT' or new.parent_id is distinct from old.parent_id) then
    select kind into v_parent_kind from public.ai_tree_nodes where id = new.parent_id;
    if v_parent_kind is null then
      raise exception 'tree_parent_not_found' using errcode = '23503';
    end if;
    if v_parent_kind <> 'folder' then
      raise exception 'tree_parent_not_folder' using errcode = '22023';
    end if;
    v_cursor := new.parent_id;
    while v_cursor is not null loop
      if v_cursor = new.id then
        raise exception 'tree_cycle' using errcode = '22023';
      end if;
      v_depth := v_depth + 1;
      if v_depth > 12 then
        raise exception 'tree_too_deep' using errcode = '22023';
      end if;
      select parent_id into v_cursor from public.ai_tree_nodes where id = v_cursor;
    end loop;
  end if;

  if tg_op = 'INSERT' then
    new.version := 1;
    new.created_by := coalesce(new.created_by, auth.uid());
    new.updated_by := coalesce(new.updated_by, auth.uid());
    new.updated_at := now();
  else
    new.version := old.version + 1;
    new.created_at := old.created_at;
    new.created_by := old.created_by;
    new.created_via := old.created_via;
    new.updated_at := now();
    new.updated_by := coalesce(auth.uid(), new.updated_by);
  end if;
  return new;
end
$$;

drop trigger if exists trg_ai_tree_nodes_before_write on public.ai_tree_nodes;
create trigger trg_ai_tree_nodes_before_write
  before insert or update on public.ai_tree_nodes
  for each row execute function public.ai_tree_nodes_before_write();

-- 발췌의 출처는 그 발췌가 속한 대화의 메시지여야 한다.
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
       and n.kind = 'excerpt'
       and m.id = new.message_id
  ) then
    raise exception 'tree_source_invalid' using errcode = '22023';
  end if;
  return new;
end
$$;

drop trigger if exists trg_ai_tree_node_sources_before_write on public.ai_tree_node_sources;
create trigger trg_ai_tree_node_sources_before_write
  before insert or update on public.ai_tree_node_sources
  for each row execute function public.ai_tree_node_sources_before_write();

-- ---------------------------------------------------------------------------
-- 3) RLS: 슈퍼관리자 전용
-- ---------------------------------------------------------------------------
alter table public.ai_tree_nodes enable row level security;
alter table public.ai_tree_node_sources enable row level security;

drop policy if exists ai_tree_nodes_superadmin on public.ai_tree_nodes;
create policy ai_tree_nodes_superadmin on public.ai_tree_nodes
  for all to authenticated
  using ((select public.is_superadmin()))
  with check ((select public.is_superadmin()));

drop policy if exists ai_tree_node_sources_superadmin on public.ai_tree_node_sources;
create policy ai_tree_node_sources_superadmin on public.ai_tree_node_sources
  for all to authenticated
  using ((select public.is_superadmin()))
  with check ((select public.is_superadmin()));

-- ---------------------------------------------------------------------------
-- 4) RPC
-- ---------------------------------------------------------------------------

-- 형제 순서를 0부터 다시 매긴다. p_first를 주면 p_index 자리에 끼운다.
create or replace function public.ai_tree_renumber(p_parent_id uuid, p_first uuid default null, p_index integer default null)
returns void
language plpgsql
security invoker
set search_path = public
as $$
begin
  with sibs as (
    select id, row_number() over (order by sort_order, created_at, id) - 1 as rn
      from public.ai_tree_nodes
     where parent_id is not distinct from p_parent_id
       and (p_first is null or id <> p_first)
  ), slot as (
    select least(greatest(coalesce(p_index, 0), 0), (select count(*) from sibs)) as pos
  ), ordered as (
    select s.id, case when p_first is not null and s.rn >= slot.pos then s.rn + 1 else s.rn end as pos
      from sibs s, slot
    union all
    select p_first, slot.pos from slot where p_first is not null
  )
  update public.ai_tree_nodes n
     set sort_order = o.pos
    from ordered o
   where n.id = o.id
     and n.sort_order is distinct from o.pos::integer;
end
$$;

-- 노드를 p_parent_id(null이면 최상위) 아래 p_index 자리로 옮긴다. p_index는 자기 자신을 뺀 형제 기준.
create or replace function public.ai_tree_move(p_node_id uuid, p_parent_id uuid, p_index integer)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_old_parent uuid;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select parent_id into v_old_parent from public.ai_tree_nodes where id = p_node_id for update;
  if not found then
    raise exception 'tree_node_not_found' using errcode = 'P0002';
  end if;
  if v_old_parent is distinct from p_parent_id then
    update public.ai_tree_nodes set parent_id = p_parent_id where id = p_node_id;
  end if;
  perform public.ai_tree_renumber(p_parent_id, p_node_id, p_index);
  if v_old_parent is distinct from p_parent_id then
    perform public.ai_tree_renumber(v_old_parent);
  end if;
end
$$;

-- 대화를 트리에 놓는다(노드가 없으면 만든다). 반환: 대화 노드 id.
create or replace function public.ai_tree_place_conversation(p_conversation_id uuid, p_parent_id uuid, p_index integer)
returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_id uuid;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select id into v_id from public.ai_tree_nodes where kind = 'conversation' and conversation_id = p_conversation_id;
  if v_id is null then
    insert into public.ai_tree_nodes (kind, conversation_id, parent_id, sort_order)
    values ('conversation', p_conversation_id, p_parent_id, 2147483647)
    returning id into v_id;
  end if;
  perform public.ai_tree_move(v_id, p_parent_id, p_index);
  return v_id;
end
$$;

-- 폴더를 지운다. 안에 있던 항목은 지우지 않고 폴더가 있던 자리로 올린다.
create or replace function public.ai_tree_delete_folder(p_folder_id uuid)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_parent uuid;
  v_pos integer;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select parent_id, sort_order into v_parent, v_pos
    from public.ai_tree_nodes
   where id = p_folder_id and kind = 'folder'
     for update;
  if not found then
    raise exception 'tree_node_not_found' using errcode = 'P0002';
  end if;

  with kids as (
    select id, row_number() over (order by sort_order, created_at, id) as k
      from public.ai_tree_nodes
     where parent_id = p_folder_id
  ), merged as (
    select id, sort_order::numeric as key
      from public.ai_tree_nodes
     where parent_id is not distinct from v_parent and id <> p_folder_id
    union all
    select id, v_pos + k::numeric / ((select count(*) from kids) + 1) from kids
  ), numbered as (
    select id, (row_number() over (order by key, id) - 1)::integer as pos from merged
  )
  update public.ai_tree_nodes n
     set parent_id = v_parent,
         sort_order = numbered.pos
    from numbered
   where n.id = numbered.id
     and (n.parent_id is distinct from v_parent or n.sort_order <> numbered.pos);

  delete from public.ai_tree_nodes where id = p_folder_id;
end
$$;

-- 발췌 노드를 만들고 출처 메시지를 연결한다. 메시지는 모두 p_conversation_id에 속해야 한다.
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

  insert into public.ai_tree_node_sources (node_id, message_id)
  select v_id, x from (select distinct unnest(p_message_ids) as x) s;
  return v_id;
end
$$;

grant execute on function public.ai_tree_renumber(uuid, uuid, integer) to authenticated;
grant execute on function public.ai_tree_move(uuid, uuid, integer) to authenticated;
grant execute on function public.ai_tree_place_conversation(uuid, uuid, integer) to authenticated;
grant execute on function public.ai_tree_delete_folder(uuid) to authenticated;
grant execute on function public.ai_tree_create_excerpt(uuid, uuid, text, text, uuid[]) to authenticated;
