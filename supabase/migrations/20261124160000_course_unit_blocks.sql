-- 20261124160000: 교육과정 흐름 소단원 내 가르치는 단위(수업 블록, course_unit_blocks)
--
-- 설계: docs/architecture/course-map.md §6.4
--
-- 1) course_unit_blocks: 기준 단원(course_map_units) 아래에서 원자개념 배치를 가르치는 단위로 묶는 2층 블록.
--    무한 중첩 없이 단원 1단계 아래에만 두며, 이름을 직접 입력·수정하고 순서를 바꿀 수 있다.
-- 2) concept_appearances.unit_block_id: 같은 단원 안의 블록에 배치를 소속시킨다.
--    블록을 지워도(해제해도) 원자개념과 단원 배치는 지워지지 않고 블록 미지정(unit_block_id = null)으로 남는다.
--    개념 배치가 다른 단원으로 옮겨지면(운영자 직접·Think 카드 승인 모두) 이전 단원 블록 소속은 자동으로 풀린다.
-- 3) 모든 읽기와 쓰기는 기존 탐색도와 동일하게 최고 관리자(is_platform_operator) 전용 security definer RPC로만 연다.

-- ─────────────────────────────────────────────────────────────────────────
-- 1) 가르치는 단위(블록) 표와 배치 연결 칸
-- ─────────────────────────────────────────────────────────────────────────

create table if not exists public.course_unit_blocks (
  id uuid primary key default gen_random_uuid(),
  unit_id uuid not null references public.course_map_units(id) on delete cascade,
  name text not null check (btrim(name) <> '' and char_length(btrim(name)) <= 80),
  sort_order integer not null default 0 check (sort_order >= 0),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists course_unit_blocks_unit_sort_idx
  on public.course_unit_blocks (unit_id, sort_order, created_at, id);

alter table public.course_unit_blocks enable row level security;
revoke all on table public.course_unit_blocks from public, anon, authenticated;

alter table public.concept_appearances
  add column if not exists unit_block_id uuid references public.course_unit_blocks(id) on delete set null;

create index if not exists concept_appearances_unit_block_idx
  on public.concept_appearances (unit_block_id)
  where unit_block_id is not null;

create or replace function public.concept_appearance_block_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_block_unit uuid;
begin
  if new.course_unit_id is null then
    new.unit_block_id := null;
    return new;
  end if;

  -- 다른 단원으로 옮길 때 새 블록을 따로 지정하지 않았으면 이전 단원 블록 소속을 자동으로 푼다.
  if tg_op = 'UPDATE'
     and new.course_unit_id is distinct from old.course_unit_id
     and new.unit_block_id is not distinct from old.unit_block_id then
    new.unit_block_id := null;
  end if;

  -- 블록 소속 변경은 RPC(ygg.course_placement = 'on') 또는 블록 삭제 cascade(ON DELETE SET NULL)만 허용한다.
  if (tg_op = 'INSERT' and new.unit_block_id is not null)
     or (tg_op = 'UPDATE' and new.unit_block_id is distinct from old.unit_block_id) then
    if coalesce(current_setting('ygg.course_placement', true), '') <> 'on' then
      if new.unit_block_id is not null
         or (old.unit_block_id is not null and exists (select 1 from public.course_unit_blocks where id = old.unit_block_id)) then
        raise exception 'course_placement_use_rpc';
      end if;
    end if;
  end if;

  if new.unit_block_id is not null then
    select b.unit_id into v_block_unit
      from public.course_unit_blocks b
     where b.id = new.unit_block_id;
    if not found or v_block_unit <> new.course_unit_id then
      raise exception 'course_block_unit_mismatch';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_concept_appearances_block_guard on public.concept_appearances;
create trigger trg_concept_appearances_block_guard
  before insert or update of course_unit_id, unit_block_id on public.concept_appearances
  for each row execute function public.concept_appearance_block_guard();

-- ─────────────────────────────────────────────────────────────────────────
-- 2) 배치 JSON 확장(block_id 포함) 및 블록 읽기
-- ─────────────────────────────────────────────────────────────────────────

create or replace function public.course_placement_json(a public.concept_appearances)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', a.id,
    'unit_id', a.course_unit_id,
    'block_id', a.unit_block_id,
    'concept_id', a.concept_id,
    'statement_id', a.statement_id,
    'sort', a.unit_sort_order,
    'origin', a.origin,
    'note', a.note,
    'created_at', a.created_at,
    'name', c.name,
    'sub_type', c.sub_type,
    'type', t.name,
    'sources', (select count(*) from public.concept_sources s where s.concept_id = a.concept_id)
  )
    from public.concepts c
    left join public.concept_type_links l on l.concept_id = c.id
    left join public.concept_types t on t.id = l.type_id
   where c.id = a.concept_id;
$$;

create or replace function public.course_map_blocks(p_course_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.course_map_assert_operator();
  if not exists (select 1 from public.course_maps where id = p_course_id) then
    raise exception 'course_map_not_found';
  end if;
  return coalesce((
    select jsonb_agg(
             jsonb_build_object(
               'id', b.id,
               'unit_id', b.unit_id,
               'name', b.name,
               'sort', b.sort_order,
               'created_at', b.created_at
             )
             order by b.unit_id, b.sort_order, b.created_at, b.id
           )
      from public.course_unit_blocks b
      join public.course_map_units u on u.id = b.unit_id
     where u.course_id = p_course_id
       and u.archived_at is null
  ), '[]'::jsonb);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 3) 블록 내부 도우미 및 쓰기 RPC
-- ─────────────────────────────────────────────────────────────────────────

create or replace function public.course_unit_blocks_renumber(p_unit_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.course_unit_blocks b
     set sort_order = s.n
    from (
      select id, (row_number() over (order by sort_order, created_at, id) - 1)::integer as n
        from public.course_unit_blocks
       where unit_id = p_unit_id
    ) s
   where b.id = s.id and b.sort_order is distinct from s.n;
end;
$$;

create or replace function public.course_unit_block_create(
  p_unit_id uuid,
  p_name text,
  p_placement_ids uuid[] default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_unit public.course_map_units;
  v_name text := btrim(coalesce(p_name, ''));
  v_block_id uuid;
begin
  perform public.course_map_assert_operator();
  v_unit := public.course_placement_unit(p_unit_id);
  if v_name = '' or char_length(v_name) > 80 then
    raise exception 'course_block_bad_name';
  end if;
  perform 1 from public.course_map_units where id = p_unit_id for update;
  if (select count(*) from public.course_unit_blocks where unit_id = p_unit_id) >= 100 then
    raise exception 'course_block_too_many';
  end if;

  insert into public.course_unit_blocks (unit_id, name, sort_order, created_by)
  values (
    p_unit_id,
    v_name,
    coalesce((select max(sort_order) + 1 from public.course_unit_blocks where unit_id = p_unit_id), 0),
    auth.uid()
  )
  returning id into v_block_id;

  if p_placement_ids is not null and cardinality(p_placement_ids) > 0 then
    if exists (
      select 1
        from unnest(p_placement_ids) x
       where x is null
          or not exists (
            select 1 from public.concept_appearances a
             where a.id = x and a.course_unit_id = p_unit_id
          )
    ) then
      raise exception 'course_placement_not_found';
    end if;
    perform set_config('ygg.course_placement', 'on', true);
    update public.concept_appearances
       set unit_block_id = v_block_id
     where course_unit_id = p_unit_id
       and id = any(p_placement_ids);
    perform set_config('ygg.course_placement', '', true);
  end if;

  return jsonb_build_object(
    'block_id', v_block_id,
    'blocks', public.course_map_blocks(v_unit.course_id),
    'placements', public.course_map_placements(v_unit.course_id)
  );
end;
$$;

create or replace function public.course_unit_block_rename(
  p_block_id uuid,
  p_name text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_block public.course_unit_blocks;
  v_unit public.course_map_units;
  v_name text := btrim(coalesce(p_name, ''));
begin
  perform public.course_map_assert_operator();
  if v_name = '' or char_length(v_name) > 80 then
    raise exception 'course_block_bad_name';
  end if;
  select * into v_block from public.course_unit_blocks where id = p_block_id for update;
  if not found then
    raise exception 'course_block_not_found';
  end if;
  v_unit := public.course_placement_unit(v_block.unit_id);

  update public.course_unit_blocks
     set name = v_name,
         updated_at = now()
   where id = p_block_id;

  return public.course_map_blocks(v_unit.course_id);
end;
$$;

create or replace function public.course_unit_block_delete(p_block_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_block public.course_unit_blocks;
  v_unit public.course_map_units;
begin
  perform public.course_map_assert_operator();
  select * into v_block from public.course_unit_blocks where id = p_block_id for update;
  if not found then
    raise exception 'course_block_not_found';
  end if;
  v_unit := public.course_placement_unit(v_block.unit_id);

  perform set_config('ygg.course_placement', 'on', true);
  update public.concept_appearances
     set unit_block_id = null
   where unit_block_id = p_block_id;
  delete from public.course_unit_blocks where id = p_block_id;
  perform set_config('ygg.course_placement', '', true);

  perform public.course_unit_blocks_renumber(v_unit.id);

  return jsonb_build_object(
    'blocks', public.course_map_blocks(v_unit.course_id),
    'placements', public.course_map_placements(v_unit.course_id)
  );
end;
$$;

create or replace function public.course_unit_blocks_reorder(
  p_unit_id uuid,
  p_block_ids uuid[]
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_unit public.course_map_units;
begin
  perform public.course_map_assert_operator();
  v_unit := public.course_placement_unit(p_unit_id);
  perform 1 from public.course_unit_blocks where unit_id = p_unit_id for update;

  if p_block_ids is null
     or cardinality(p_block_ids) <> (select count(*) from public.course_unit_blocks where unit_id = p_unit_id)
     or cardinality(p_block_ids) <> (select count(distinct x) from unnest(p_block_ids) x where x is not null)
     or exists (
       select 1 from unnest(p_block_ids) x
        where not exists (
          select 1 from public.course_unit_blocks b
           where b.id = x and b.unit_id = p_unit_id
        )
     ) then
    raise exception 'course_block_stale';
  end if;

  update public.course_unit_blocks b
     set sort_order = (t.n - 1)::integer,
         updated_at = now()
    from unnest(p_block_ids) with ordinality as t(id, n)
   where b.id = t.id;

  return public.course_map_blocks(v_unit.course_id);
end;
$$;

create or replace function public.course_placement_set_block(
  p_placement_id uuid,
  p_block_id uuid default null,
  p_ordered_ids uuid[] default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.concept_appearances;
  v_unit public.course_map_units;
  v_block public.course_unit_blocks;
begin
  perform public.course_map_assert_operator();
  v_row := public.course_placement_row_in(p_placement_id, null);
  v_unit := public.course_placement_unit(v_row.course_unit_id);

  if p_block_id is not null then
    select * into v_block from public.course_unit_blocks where id = p_block_id;
    if not found then
      raise exception 'course_block_not_found';
    end if;
    if v_block.unit_id <> v_unit.id then
      raise exception 'course_block_unit_mismatch';
    end if;
  end if;

  perform set_config('ygg.course_placement', 'on', true);
  update public.concept_appearances
     set unit_block_id = p_block_id
   where id = p_placement_id;
  perform set_config('ygg.course_placement', '', true);

  if p_ordered_ids is not null then
    perform public.course_placement_reorder_rows(v_unit.id, p_ordered_ids);
  end if;

  return public.course_map_placements(v_unit.course_id);
end;
$$;

create or replace function public.course_unit_block_add_concepts(
  p_block_id uuid,
  p_concept_ids uuid[]
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_block public.course_unit_blocks;
  v_unit public.course_map_units;
  v_cid uuid;
  v_pid uuid;
begin
  perform public.course_map_assert_operator();
  select * into v_block from public.course_unit_blocks where id = p_block_id;
  if not found then
    raise exception 'course_block_not_found';
  end if;
  v_unit := public.course_placement_unit(v_block.unit_id);
  if p_concept_ids is null or cardinality(p_concept_ids) = 0 or cardinality(p_concept_ids) > 100 then
    raise exception 'course_placement_bad_concepts';
  end if;

  perform 1 from public.course_map_units where id = v_unit.id for update;
  for v_cid in
    select x from unnest(p_concept_ids) with ordinality as t(x, n) where x is not null group by x order by min(n)
  loop
    select id into v_pid
      from public.concept_appearances
     where course_unit_id = v_unit.id and concept_id = v_cid;
    if v_pid is null then
      v_pid := public.course_placement_insert(v_unit.id, v_cid, 'owner', null);
    end if;
    perform set_config('ygg.course_placement', 'on', true);
    update public.concept_appearances
       set unit_block_id = p_block_id
     where id = v_pid;
    perform set_config('ygg.course_placement', '', true);
  end loop;

  return public.course_map_placements(v_unit.course_id);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 4) 권한 정리
-- ─────────────────────────────────────────────────────────────────────────

revoke all on function public.concept_appearance_block_guard() from public, anon, authenticated;
revoke all on function public.course_placement_json(public.concept_appearances) from public, anon, authenticated;
revoke all on function public.course_unit_blocks_renumber(uuid) from public, anon, authenticated;

revoke all on function public.course_map_blocks(uuid) from public, anon;
revoke all on function public.course_unit_block_create(uuid, text, uuid[]) from public, anon;
revoke all on function public.course_unit_block_rename(uuid, text) from public, anon;
revoke all on function public.course_unit_block_delete(uuid) from public, anon;
revoke all on function public.course_unit_blocks_reorder(uuid, uuid[]) from public, anon;
revoke all on function public.course_placement_set_block(uuid, uuid, uuid[]) from public, anon;
revoke all on function public.course_unit_block_add_concepts(uuid, uuid[]) from public, anon;

grant execute on function public.course_map_blocks(uuid) to authenticated, service_role;
grant execute on function public.course_unit_block_create(uuid, text, uuid[]) to authenticated, service_role;
grant execute on function public.course_unit_block_rename(uuid, text) to authenticated, service_role;
grant execute on function public.course_unit_block_delete(uuid) to authenticated, service_role;
grant execute on function public.course_unit_blocks_reorder(uuid, uuid[]) to authenticated, service_role;
grant execute on function public.course_placement_set_block(uuid, uuid, uuid[]) to authenticated, service_role;
grant execute on function public.course_unit_block_add_concepts(uuid, uuid[]) to authenticated, service_role;
