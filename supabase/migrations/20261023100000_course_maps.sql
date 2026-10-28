-- 20261023100000: 기준 과정 탐색도 (운영자 결정 2026-10-23)
--
-- 설계: docs/architecture/course-map.md
--
-- 표
--   course_maps            과정(1-1 … 기하). 플랫폼 공유 기준 하나. 공식 교육과정과 맞춰 본 자료가 아니라 운영자가 고치는 기준 초안이다.
--   course_map_units       과정 안 대·중·소단원(깊이 1~3). 같은 부모 안 순서는 sort_order(0부터 빈칸 없이).
--                          순서는 "나열 순서"일 뿐 선수 관계가 아니다. 이름·순서·부모가 바뀌어도 id는 그대로다.
--                          지우지 않고 보관(archived_at)한다. 나중에 학습목표·개념·문항이 이 id를 가리킨다.
--   course_map_revisions   과정을 바꿀 때마다 그 과정 전체를 한 줄로 남긴다(되돌릴 근거). 고치거나 지우지 않는다.
--
-- 기존 curriculum·grade·chapter·section(0066) 과 교재 단원 구조(textbook_metadata) 는 쓰지도 바꾸지도 않는다.
--
-- 접근
--   슈퍼관리자(매니저앱 운영자)만 읽고 쓴다. 표에 직접 쓰는 길은 없고 아래 RPC로만 바뀐다.
--   과정 판(version)이 화면에 보였던 판과 다르면 course_map_stale 로 막는다.
--
-- 초기 자료
--   매니저앱 문항로드맵 화면에 적혀 있던 13개 과정 목록(대·중·소 이름과 순서 그대로)을 course_map_seed 로 넣는다.
--   seed_key 가 이미 있는 과정은 통째로 건너뛰므로 다시 실행해도 겹치거나 고친 내용을 덮지 않는다.

-- ─────────────────────────────────────────────────────────────────────────
-- 1) 표
-- ─────────────────────────────────────────────────────────────────────────

create table if not exists public.course_maps (
  id uuid primary key default gen_random_uuid(),
  -- 초기 자료로 넣은 과정만 있다(roadmap:<교재 과정 키>).
  seed_key text unique,
  -- 교재 과정 목록(textbook_course_catalog)의 키. 이름으로 맞추지 않고 이 키로만 잇는다. 모르면 비워 둔다.
  course_key text unique check (course_key is null or (btrim(course_key) <> '' and char_length(course_key) <= 40)),
  name text not null check (btrim(name) <> '' and char_length(name) <= 40),
  school_level text not null check (school_level in ('초', '중', '고')),
  -- 개념 등장 위치(concept_appearances)와 같은 교육과정 코드.
  curriculum_code text check (
    curriculum_code is null
    or curriculum_code in ('legacy_1to6', 'k7_1997', 'k7_2007', 'rev_2009', 'rev_2015', 'rev_2022')
  ),
  sort_order integer not null check (sort_order >= 0),
  version integer not null default 1 check (version >= 1),
  archived_at timestamptz,
  archived_by uuid references auth.users(id) on delete set null,
  created_by uuid default auth.uid() references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_by uuid default auth.uid() references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

create unique index if not exists course_maps_active_order on public.course_maps (sort_order) where archived_at is null;

create table if not exists public.course_map_units (
  id uuid primary key default gen_random_uuid(),
  course_id uuid not null references public.course_maps(id) on delete restrict,
  parent_id uuid references public.course_map_units(id) on delete restrict deferrable initially deferred,
  -- 1 대단원, 2 중단원, 3 소단원.
  depth smallint not null check (depth between 1 and 3),
  name text not null check (btrim(name) <> '' and char_length(name) <= 80),
  sort_order integer not null check (sort_order >= 0),
  archived_at timestamptz,
  archived_by uuid references auth.users(id) on delete set null,
  created_by uuid default auth.uid() references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_by uuid default auth.uid() references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  check ((parent_id is null) = (depth = 1)),
  check (parent_id is distinct from id)
);

create unique index if not exists course_map_units_active_order on public.course_map_units (
  course_id, coalesce(parent_id, '00000000-0000-0000-0000-000000000000'::uuid), sort_order
) where archived_at is null;
create index if not exists course_map_units_parent_idx on public.course_map_units (parent_id);
create index if not exists course_map_units_course_idx on public.course_map_units (course_id, archived_at);

create table if not exists public.course_map_revisions (
  id uuid primary key default gen_random_uuid(),
  course_id uuid not null references public.course_maps(id) on delete restrict,
  version integer not null,
  action text not null check (action in ('seed', 'create', 'save', 'restore_unit', 'archive', 'restore')),
  snapshot jsonb not null,
  created_by uuid default auth.uid() references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists course_map_revisions_course_idx on public.course_map_revisions (course_id, created_at desc);

-- 단원은 RPC로만 바뀌지만, 거래가 끝날 때 한 번 더 본다: 살아 있는 단원의 부모는 같은 과정의 살아 있는 단원이고
-- 깊이는 부모 + 1, 보관한 단원 아래에 살아 있는 단원이 없다. 깊이가 부모보다 하나씩 깊어지므로 순환은 생길 수 없다.
create or replace function public.course_map_units_check()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.course_map_units;
  v_parent public.course_map_units;
begin
  select * into v_row from public.course_map_units where id = new.id;
  if not found then
    return null;
  end if;
  if v_row.archived_at is null then
    if v_row.parent_id is not null then
      select * into v_parent from public.course_map_units where id = v_row.parent_id;
      if not found or v_parent.course_id <> v_row.course_id or v_parent.archived_at is not null
         or v_row.depth <> v_parent.depth + 1 then
        raise exception 'course_map_bad_parent';
      end if;
    end if;
  elsif exists (select 1 from public.course_map_units c where c.parent_id = v_row.id and c.archived_at is null) then
    raise exception 'course_map_bad_parent';
  end if;
  return null;
end;
$$;

drop trigger if exists trg_course_map_units_check on public.course_map_units;
create constraint trigger trg_course_map_units_check
  after insert or update on public.course_map_units
  deferrable initially deferred
  for each row execute function public.course_map_units_check();

-- ─────────────────────────────────────────────────────────────────────────
-- 2) 읽기
-- ─────────────────────────────────────────────────────────────────────────

create or replace function public.course_map_assert_operator()
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.is_superadmin() then
    raise exception 'course_map_forbidden';
  end if;
end;
$$;

-- 살아 있는 단원을 위에서 아래로(대단원 순서 → 그 안 중단원 순서 → …) 늘어놓는다.
create or replace function public.course_map_units_json(p_course_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with recursive t as (
    select u.id, u.parent_id, u.depth, u.name, u.sort_order, array[u.sort_order] as path
      from public.course_map_units u
     where u.course_id = p_course_id and u.parent_id is null and u.archived_at is null
    union all
    select c.id, c.parent_id, c.depth, c.name, c.sort_order, t.path || c.sort_order
      from public.course_map_units c
      join t on c.parent_id = t.id
     where c.archived_at is null
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', id, 'parent_id', parent_id, 'depth', depth, 'name', name, 'sort_order', sort_order
         ) order by path), '[]'::jsonb)
    from t;
$$;

create or replace function public.course_map_course_json(v public.course_maps)
returns jsonb
language sql
stable
as $$
  select jsonb_build_object(
    'id', v.id, 'name', v.name, 'school_level', v.school_level, 'curriculum_code', v.curriculum_code,
    'course_key', v.course_key, 'seeded', v.seed_key is not null, 'sort_order', v.sort_order,
    'version', v.version, 'updated_at', v.updated_at, 'archived_at', v.archived_at
  );
$$;

-- 과정 하나: 과정 정보, 살아 있는 단원, 보관한 단원(같이 보관된 묶음의 맨 위만, 묶음 크기·위 단원 이름과 함께).
create or replace function public.course_map_get(p_course_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_course public.course_maps;
  v_archived jsonb;
begin
  perform public.course_map_assert_operator();
  select * into v_course from public.course_maps where id = p_course_id;
  if not found then
    raise exception 'course_map_not_found';
  end if;

  with roots as (
    select u.*
      from public.course_map_units u
      left join public.course_map_units p on p.id = u.parent_id
     where u.course_id = p_course_id and u.archived_at is not null
       and (p.id is null or p.archived_at is null or p.archived_at <> u.archived_at)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', r.id, 'parent_id', r.parent_id, 'depth', r.depth, 'name', r.name, 'archived_at', r.archived_at,
           'parent_active', r.parent_id is null or exists (
             select 1 from public.course_map_units p where p.id = r.parent_id and p.archived_at is null
           ),
           'path', (
             with recursive up as (
               select p.id, p.parent_id, p.name, 1 as n from public.course_map_units p where p.id = r.parent_id
               union all
               select p.id, p.parent_id, p.name, up.n + 1 from public.course_map_units p join up on p.id = up.parent_id
             )
             select coalesce(array_agg(up.name order by up.n desc), '{}'::text[]) from up
           ),
           'count', (
             with recursive d as (
               select r.id
               union all
               select c.id from public.course_map_units c join d on c.parent_id = d.id where c.archived_at = r.archived_at
             )
             select count(*) from d
           )
         ) order by r.archived_at desc, r.depth, r.name), '[]'::jsonb)
    into v_archived
    from roots r;

  return jsonb_build_object(
    'course', public.course_map_course_json(v_course),
    'units', public.course_map_units_json(p_course_id),
    'archived', v_archived
  );
end;
$$;

-- 과정 목록: 살아 있는 과정을 순서대로, 그다음 보관한 과정. 단원 수는 깊이별 살아 있는 것만.
create or replace function public.course_maps_list()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.course_map_assert_operator();
  return (
    select coalesce(jsonb_agg(
             public.course_map_course_json(c) || jsonb_build_object(
               'counts', jsonb_build_array(
                 (select count(*) from public.course_map_units u where u.course_id = c.id and u.archived_at is null and u.depth = 1),
                 (select count(*) from public.course_map_units u where u.course_id = c.id and u.archived_at is null and u.depth = 2),
                 (select count(*) from public.course_map_units u where u.course_id = c.id and u.archived_at is null and u.depth = 3)
               )
             )
             order by (c.archived_at is not null), c.sort_order, c.created_at
           ), '[]'::jsonb)
      from public.course_maps c
  );
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 3) 바꾸기
-- ─────────────────────────────────────────────────────────────────────────

create or replace function public.course_map_check_course(p_name text, p_school_level text, p_curriculum_code text)
returns void
language plpgsql
immutable
as $$
begin
  if btrim(coalesce(p_name, '')) = '' or char_length(btrim(p_name)) > 40 then
    raise exception 'course_map_bad_name';
  end if;
  if p_school_level is null or p_school_level not in ('초', '중', '고') then
    raise exception 'course_map_bad_level';
  end if;
  if p_curriculum_code is not null
     and p_curriculum_code not in ('legacy_1to6', 'k7_1997', 'k7_2007', 'rev_2009', 'rev_2015', 'rev_2022') then
    raise exception 'course_map_bad_curriculum';
  end if;
end;
$$;

-- 화면에 보였던 판과 같을 때만 바꾼다. 보관한 과정은 되살린 뒤에 고친다.
create or replace function public.course_map_lock(p_course_id uuid, p_version integer)
returns public.course_maps
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.course_maps;
begin
  select * into v_row from public.course_maps where id = p_course_id for update;
  if not found then
    raise exception 'course_map_not_found';
  end if;
  if v_row.version is distinct from p_version then
    raise exception 'course_map_stale';
  end if;
  if v_row.archived_at is not null then
    raise exception 'course_map_archived';
  end if;
  return v_row;
end;
$$;

create or replace function public.course_map_record(p_course_id uuid, p_action text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_course public.course_maps;
begin
  select * into v_course from public.course_maps where id = p_course_id;
  insert into public.course_map_revisions (course_id, version, action, snapshot, created_by)
  values (
    p_course_id, v_course.version, p_action,
    jsonb_build_object('course', public.course_map_course_json(v_course), 'units', public.course_map_units_json(p_course_id)),
    auth.uid()
  );
end;
$$;

create or replace function public.course_map_create(p_name text, p_school_level text, p_curriculum_code text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  perform public.course_map_assert_operator();
  perform public.course_map_check_course(p_name, p_school_level, p_curriculum_code);
  perform 1 from public.course_maps where archived_at is null for update;
  insert into public.course_maps (name, school_level, curriculum_code, sort_order, created_by, updated_by)
  values (
    btrim(p_name), p_school_level, p_curriculum_code,
    coalesce((select max(sort_order) + 1 from public.course_maps where archived_at is null), 0),
    auth.uid(), auth.uid()
  )
  returning id into v_id;
  perform public.course_map_record(v_id, 'create');
  return public.course_map_get(v_id);
end;
$$;

-- 과정 하나를 한 번에 저장한다.
--   p_course  {name, school_level, curriculum_code}
--   p_units   살아 있을 단원 전부. 배열 순서가 같은 부모 안 순서다. [{id, parent_id, name}]
--             새 단원은 앱이 만든 id를 그대로 쓴다. 지금 살아 있는 단원이 빠지면 막는다(보관은 p_archive 로만).
--   p_archive 보관할 단원. 그 아래 단원도 함께 보관된다(p_units 에 넣어 다른 곳으로 옮긴 아래 단원은 빼고).
create or replace function public.course_map_save(
  p_course_id uuid,
  p_version integer,
  p_course jsonb,
  p_units jsonb,
  p_archive uuid[] default '{}'::uuid[]
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_course public.course_maps;
  v_name text;
  v_level text;
  v_code text;
  v_now timestamptz := clock_timestamp();
  v_rows integer;
  v_archive uuid[] := coalesce(p_archive, '{}'::uuid[]);
begin
  perform public.course_map_assert_operator();
  v_course := public.course_map_lock(p_course_id, p_version);

  v_name := btrim(coalesce(p_course ->> 'name', v_course.name));
  v_level := coalesce(p_course ->> 'school_level', v_course.school_level);
  v_code := case when p_course ? 'curriculum_code' then p_course ->> 'curriculum_code' else v_course.curriculum_code end;
  perform public.course_map_check_course(v_name, v_level, v_code);

  if p_units is null or jsonb_typeof(p_units) <> 'array' then
    raise exception 'course_map_bad_units';
  end if;
  if jsonb_array_length(p_units) > 3000 then
    raise exception 'course_map_too_many';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_units) e
     where jsonb_typeof(e) <> 'object'
        or coalesce(e ->> 'id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        or (e ->> 'parent_id' is not null
            and e ->> 'parent_id' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
  ) then
    raise exception 'course_map_bad_units';
  end if;

  drop table if exists pg_temp.course_map_in;
  create temp table course_map_in (
    ord integer not null,
    id uuid not null,
    parent_id uuid,
    name text,
    depth integer,
    pos integer
  ) on commit drop;
  insert into course_map_in (ord, id, parent_id, name)
  select o::integer, (e ->> 'id')::uuid, (e ->> 'parent_id')::uuid, btrim(coalesce(e ->> 'name', ''))
    from jsonb_array_elements(p_units) with ordinality as x(e, o);

  if (select count(*) <> count(distinct id) from course_map_in) then
    raise exception 'course_map_bad_units';
  end if;
  if exists (select 1 from course_map_in where name = '' or char_length(name) > 80) then
    raise exception 'course_map_bad_name';
  end if;

  -- 다른 과정의 단원, 보관한 단원은 받지 않는다(보관한 단원은 되살리기로).
  if exists (
    select 1 from course_map_in i join public.course_map_units u on u.id = i.id where u.course_id <> p_course_id
  ) then
    raise exception 'course_map_unit_foreign';
  end if;
  if exists (
    select 1 from course_map_in i join public.course_map_units u on u.id = i.id where u.archived_at is not null
  ) then
    raise exception 'course_map_unit_archived';
  end if;

  perform 1 from public.course_map_units where course_id = p_course_id and archived_at is null for update;

  -- 보관할 단원: 이 과정의 살아 있는 단원이어야 하고, 그 아래 단원도 함께다.
  -- 다만 저장 내용에 들어 있는 아래 단원은 다른 곳으로 옮긴 것이라 보관하지 않는다.
  if exists (
    select 1 from unnest(v_archive) a(id)
     where not exists (
       select 1 from public.course_map_units u where u.id = a.id and u.course_id = p_course_id and u.archived_at is null
     )
  ) then
    raise exception 'course_map_unit_not_found';
  end if;
  drop table if exists pg_temp.course_map_arch;
  create temp table course_map_arch (id uuid primary key) on commit drop;
  insert into course_map_arch (id)
  with recursive a as (
    select u.id from public.course_map_units u where u.id = any(v_archive)
    union
    select c.id from public.course_map_units c join a on c.parent_id = a.id
     where c.archived_at is null and not exists (select 1 from course_map_in i where i.id = c.id)
  )
  select id from a;

  if exists (select 1 from course_map_in i join course_map_arch a on a.id = i.id) then
    raise exception 'course_map_unit_conflict';
  end if;
  if exists (
    select 1 from public.course_map_units u
     where u.course_id = p_course_id and u.archived_at is null
       and not exists (select 1 from course_map_in i where i.id = u.id)
       and not exists (select 1 from course_map_arch a where a.id = u.id)
  ) then
    raise exception 'course_map_unit_missing';
  end if;
  if exists (
    select 1 from course_map_in i
     where i.parent_id is not null and not exists (select 1 from course_map_in p where p.id = i.parent_id)
  ) then
    raise exception 'course_map_bad_parent';
  end if;

  -- 깊이는 위에서부터 정한다. 끝까지 정해지지 않는 단원은 순환 안에 있다.
  update course_map_in set depth = 1 where parent_id is null;
  loop
    update course_map_in c set depth = p.depth + 1
      from course_map_in p
     where c.parent_id = p.id and c.depth is null and p.depth is not null;
    get diagnostics v_rows = row_count;
    exit when v_rows = 0;
  end loop;
  if exists (select 1 from course_map_in where depth is null) then
    raise exception 'course_map_cycle';
  end if;
  if exists (select 1 from course_map_in where depth > 3) then
    raise exception 'course_map_too_deep';
  end if;
  update course_map_in i set pos = s.pos
    from (select id, (row_number() over (partition by parent_id order by ord) - 1)::integer as pos from course_map_in) s
   where i.id = s.id;

  update public.course_map_units u
     set archived_at = v_now, archived_by = auth.uid(), updated_at = v_now, updated_by = auth.uid()
    from course_map_arch a
   where u.id = a.id;

  -- 같은 부모 안 순서를 0부터 다시 매긴다. 고유 색인과 부딪치지 않게 먼저 살아 있는 단원을 멀리 옮겨 둔다.
  update public.course_map_units
     set sort_order = sort_order + 1000000
   where course_id = p_course_id and archived_at is null;

  insert into public.course_map_units (id, course_id, parent_id, depth, name, sort_order, created_by, updated_by)
  select i.id, p_course_id, i.parent_id, i.depth, i.name, i.pos, auth.uid(), auth.uid()
    from course_map_in i
   where not exists (select 1 from public.course_map_units u where u.id = i.id);

  update public.course_map_units u
     set parent_id = s.parent_id,
         depth = s.depth,
         name = s.name,
         sort_order = s.pos,
         updated_at = case
           when u.parent_id is distinct from s.parent_id or u.name <> s.name or u.sort_order - 1000000 <> s.pos
             then v_now else u.updated_at end,
         updated_by = case
           when u.parent_id is distinct from s.parent_id or u.name <> s.name or u.sort_order - 1000000 <> s.pos
             then auth.uid() else u.updated_by end
    from course_map_in s
   where u.id = s.id and u.sort_order >= 1000000;

  update public.course_maps
     set name = v_name, school_level = v_level, curriculum_code = v_code,
         version = version + 1, updated_at = v_now, updated_by = auth.uid()
   where id = p_course_id;
  perform public.course_map_record(p_course_id, 'save');
  return public.course_map_get(p_course_id);
end;
$$;

-- 보관한 단원을 같이 보관된 아래 단원과 함께 되살린다. 부모가 살아 있어야 하고, 부모의 맨 끝에 붙는다.
create or replace function public.course_map_unit_restore(p_course_id uuid, p_version integer, p_unit_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_unit public.course_map_units;
  v_now timestamptz := clock_timestamp();
begin
  perform public.course_map_assert_operator();
  perform public.course_map_lock(p_course_id, p_version);
  select * into v_unit from public.course_map_units where id = p_unit_id and course_id = p_course_id for update;
  if not found or v_unit.archived_at is null then
    raise exception 'course_map_unit_not_found';
  end if;
  if v_unit.parent_id is not null and not exists (
    select 1 from public.course_map_units p where p.id = v_unit.parent_id and p.archived_at is null
  ) then
    raise exception 'course_map_parent_archived';
  end if;
  perform 1 from public.course_map_units where course_id = p_course_id and archived_at is null for update;

  -- 보관한 뒤 부모가 다른 깊이로 옮겨졌을 수 있으니 깊이는 지금 부모에서 다시 센다.
  drop table if exists pg_temp.course_map_back;
  create temp table course_map_back (id uuid primary key, parent_id uuid, sort_order integer, depth integer) on commit drop;
  insert into course_map_back (id, parent_id, sort_order, depth)
  with recursive d as (
    select v_unit.id as id, v_unit.parent_id as parent_id, v_unit.sort_order as sort_order,
           coalesce((select p.depth from public.course_map_units p where p.id = v_unit.parent_id), 0) + 1 as depth
    union all
    select c.id, c.parent_id, c.sort_order, d.depth + 1
      from public.course_map_units c join d on c.parent_id = d.id
     where c.archived_at = v_unit.archived_at
  )
  select id, parent_id, sort_order, depth from d;
  if exists (select 1 from course_map_back where depth > 3) then
    raise exception 'course_map_too_deep';
  end if;

  update public.course_map_units u
     set archived_at = null, archived_by = null, updated_at = v_now, updated_by = auth.uid(),
         depth = b.depth,
         sort_order = case
           when u.id = v_unit.id then coalesce((
             select max(s.sort_order) + 1 from public.course_map_units s
              where s.course_id = p_course_id and s.archived_at is null
                and s.parent_id is not distinct from v_unit.parent_id
           ), 0)
           else (
             select (count(*))::integer from course_map_back b2
              where b2.parent_id = b.parent_id and (b2.sort_order, b2.id) < (b.sort_order, b.id)
           )
         end
    from course_map_back b
   where u.id = b.id;

  update public.course_maps set version = version + 1, updated_at = v_now, updated_by = auth.uid() where id = p_course_id;
  perform public.course_map_record(p_course_id, 'restore_unit');
  return public.course_map_get(p_course_id);
end;
$$;

-- 살아 있는 과정 순서를 0부터 빈칸 없이 다시 매긴다.
create or replace function public.course_maps_renumber()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.course_maps set sort_order = sort_order + 1000000 where archived_at is null;
  update public.course_maps c
     set sort_order = s.n
    from (
      select id, (row_number() over (order by sort_order, created_at, id) - 1)::integer as n
        from public.course_maps where archived_at is null
    ) s
   where c.id = s.id;
end;
$$;

-- 과정을 보관한다. 단원은 그대로 두고 과정만 목록에서 뺀다.
create or replace function public.course_map_archive(p_course_id uuid, p_version integer)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.course_map_assert_operator();
  perform public.course_map_lock(p_course_id, p_version);
  perform 1 from public.course_maps where archived_at is null for update;
  update public.course_maps
     set archived_at = clock_timestamp(), archived_by = auth.uid(), version = version + 1,
         updated_at = clock_timestamp(), updated_by = auth.uid()
   where id = p_course_id;
  perform public.course_maps_renumber();
  perform public.course_map_record(p_course_id, 'archive');
  return public.course_maps_list();
end;
$$;

-- 보관한 과정을 되살려 목록 맨 끝에 둔다.
create or replace function public.course_map_restore(p_course_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.course_maps;
begin
  perform public.course_map_assert_operator();
  select * into v_row from public.course_maps where id = p_course_id for update;
  if not found or v_row.archived_at is null then
    raise exception 'course_map_not_found';
  end if;
  perform 1 from public.course_maps where archived_at is null for update;
  update public.course_maps
     set archived_at = null, archived_by = null, version = version + 1,
         sort_order = coalesce((select max(sort_order) + 1 from public.course_maps where archived_at is null), 0),
         updated_at = clock_timestamp(), updated_by = auth.uid()
   where id = p_course_id;
  perform public.course_map_record(p_course_id, 'restore');
  return public.course_maps_list();
end;
$$;

-- 과정 순서. 화면에 보였던 순서(p_expected)가 지금과 같을 때만 바꾼다.
create or replace function public.course_maps_reorder(p_expected uuid[], p_ids uuid[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_current uuid[];
begin
  perform public.course_map_assert_operator();
  perform 1 from public.course_maps where archived_at is null for update;
  select coalesce(array_agg(id order by sort_order), '{}'::uuid[]) into v_current
    from public.course_maps where archived_at is null;
  if v_current is distinct from coalesce(p_expected, '{}'::uuid[]) then
    raise exception 'course_map_list_stale';
  end if;
  if cardinality(coalesce(p_ids, '{}'::uuid[])) <> cardinality(v_current)
     or (select count(distinct x) from unnest(p_ids) x) <> cardinality(v_current)
     or exists (select 1 from unnest(p_ids) x where x <> all(v_current)) then
    raise exception 'course_map_bad_order';
  end if;
  update public.course_maps set sort_order = sort_order + 1000000 where archived_at is null;
  update public.course_maps c
     set sort_order = (x.o - 1)::integer
    from unnest(p_ids) with ordinality as x(id, o)
   where c.id = x.id;
  return public.course_maps_list();
end;
$$;

-- 초기 자료. [{seed, course_key, name, school_level, curriculum_code, units: [{name, children: [...]}]}]
-- seed 가 이미 있는 과정은 통째로 건너뛴다. 넣은 과정 수를 돌려준다. 앱에서는 부를 수 없다.
create or replace function public.course_map_seed(p_data jsonb)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_course jsonb;
  v_id uuid;
  v_n integer := 0;
  v_l1 jsonb;
  v_l2 jsonb;
  v_l3 jsonb;
  v_i integer;
  v_j integer;
  v_k integer;
  v_u1 uuid;
  v_u2 uuid;
begin
  for v_course in select e from jsonb_array_elements(p_data) e loop
    continue when exists (select 1 from public.course_maps where seed_key = v_course ->> 'seed');
    perform public.course_map_check_course(v_course ->> 'name', v_course ->> 'school_level', v_course ->> 'curriculum_code');
    insert into public.course_maps (seed_key, course_key, name, school_level, curriculum_code, sort_order, created_by, updated_by)
    values (
      v_course ->> 'seed', v_course ->> 'course_key', v_course ->> 'name', v_course ->> 'school_level',
      v_course ->> 'curriculum_code',
      coalesce((select max(sort_order) + 1 from public.course_maps where archived_at is null), 0),
      null, null
    )
    returning id into v_id;
    v_i := 0;
    for v_l1 in select e from jsonb_array_elements(coalesce(v_course -> 'units', '[]'::jsonb)) e loop
      insert into public.course_map_units (course_id, parent_id, depth, name, sort_order, created_by, updated_by)
      values (v_id, null, 1, v_l1 ->> 'name', v_i, null, null) returning id into v_u1;
      v_i := v_i + 1;
      v_j := 0;
      for v_l2 in select e from jsonb_array_elements(coalesce(v_l1 -> 'children', '[]'::jsonb)) e loop
        insert into public.course_map_units (course_id, parent_id, depth, name, sort_order, created_by, updated_by)
        values (v_id, v_u1, 2, v_l2 ->> 'name', v_j, null, null) returning id into v_u2;
        v_j := v_j + 1;
        v_k := 0;
        for v_l3 in select e from jsonb_array_elements(coalesce(v_l2 -> 'children', '[]'::jsonb)) e loop
          insert into public.course_map_units (course_id, parent_id, depth, name, sort_order, created_by, updated_by)
          values (v_id, v_u2, 3, v_l3 ->> 'name', v_k, null, null);
          v_k := v_k + 1;
        end loop;
      end loop;
    end loop;
    perform public.course_map_record(v_id, 'seed');
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 4) 접근
-- ─────────────────────────────────────────────────────────────────────────

alter table public.course_maps enable row level security;
alter table public.course_map_units enable row level security;
alter table public.course_map_revisions enable row level security;

drop policy if exists course_maps_operator_select on public.course_maps;
create policy course_maps_operator_select on public.course_maps
  for select to authenticated
  using ((select public.is_superadmin()));
drop policy if exists course_map_units_operator_select on public.course_map_units;
create policy course_map_units_operator_select on public.course_map_units
  for select to authenticated
  using ((select public.is_superadmin()));
drop policy if exists course_map_revisions_operator_select on public.course_map_revisions;
create policy course_map_revisions_operator_select on public.course_map_revisions
  for select to authenticated
  using ((select public.is_superadmin()));

revoke all on public.course_maps, public.course_map_units, public.course_map_revisions from anon;
revoke insert, update, delete, truncate on public.course_maps, public.course_map_units, public.course_map_revisions
  from authenticated;

revoke all on function public.course_map_units_check() from public, anon, authenticated;
revoke all on function public.course_map_assert_operator() from public, anon, authenticated;
revoke all on function public.course_map_units_json(uuid) from public, anon, authenticated;
revoke all on function public.course_map_course_json(public.course_maps) from public, anon, authenticated;
revoke all on function public.course_map_check_course(text, text, text) from public, anon, authenticated;
revoke all on function public.course_map_lock(uuid, integer) from public, anon, authenticated;
revoke all on function public.course_map_record(uuid, text) from public, anon, authenticated;
revoke all on function public.course_maps_renumber() from public, anon, authenticated;
revoke all on function public.course_map_seed(jsonb) from public, anon, authenticated;
revoke all on function public.course_map_get(uuid) from public, anon;
revoke all on function public.course_maps_list() from public, anon;
revoke all on function public.course_map_create(text, text, text) from public, anon;
revoke all on function public.course_map_save(uuid, integer, jsonb, jsonb, uuid[]) from public, anon;
revoke all on function public.course_map_unit_restore(uuid, integer, uuid) from public, anon;
revoke all on function public.course_map_archive(uuid, integer) from public, anon;
revoke all on function public.course_map_restore(uuid) from public, anon;
revoke all on function public.course_maps_reorder(uuid[], uuid[]) from public, anon;

grant execute on function public.course_map_get(uuid) to authenticated;
grant execute on function public.course_maps_list() to authenticated;
grant execute on function public.course_map_create(text, text, text) to authenticated;
grant execute on function public.course_map_save(uuid, integer, jsonb, jsonb, uuid[]) to authenticated;
grant execute on function public.course_map_unit_restore(uuid, integer, uuid) to authenticated;
grant execute on function public.course_map_archive(uuid, integer) to authenticated;
grant execute on function public.course_map_restore(uuid) to authenticated;
grant execute on function public.course_maps_reorder(uuid[], uuid[]) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 5) 초기 자료: 매니저앱 문항로드맵 화면(problem_roadmap_screen.dart)에 적혀 있던 목록 그대로
-- ─────────────────────────────────────────────────────────────────────────

select public.course_map_seed($course_map_seed$
[
 {
  "seed": "roadmap:M1-1",
  "course_key": "M1-1",
  "name": "1-1",
  "school_level": "중",
  "curriculum_code": "rev_2022",
  "units": [
   {
    "name": "수와 연산",
    "children": [
     {
      "name": "소인수분해",
      "children": [
       {
        "name": "소인수분해"
       },
       {
        "name": "최대공약수와 최소공배수"
       }
      ]
     },
     {
      "name": "정수와 유리수",
      "children": [
       {
        "name": "정수와 유리수"
       },
       {
        "name": "정수와 유리수의 덧셈과 뺄셈"
       },
       {
        "name": "정수와 유리수의 곱셈과 나눗셈"
       }
      ]
     }
    ]
   },
   {
    "name": "문자와 식",
    "children": [
     {
      "name": "문자의 사용과 식",
      "children": [
       {
        "name": "문자의 사용"
       },
       {
        "name": "식의 값"
       },
       {
        "name": "일차식과 그 계산"
       }
      ]
     },
     {
      "name": "일차방정식",
      "children": [
       {
        "name": "방정식과 그 해"
       },
       {
        "name": "일차방정식의 풀이"
       },
       {
        "name": "일차방정식의 활용"
       }
      ]
     }
    ]
   },
   {
    "name": "좌표평면과 그래프",
    "children": [
     {
      "name": "좌표와 그래프",
      "children": [
       {
        "name": "순서쌍과 좌표"
       },
       {
        "name": "그래프와 그 해석"
       }
      ]
     },
     {
      "name": "정비례와 반비례",
      "children": [
       {
        "name": "정비례"
       },
       {
        "name": "반비례"
       }
      ]
     }
    ]
   }
  ]
 },
 {
  "seed": "roadmap:M1-2",
  "course_key": "M1-2",
  "name": "1-2",
  "school_level": "중",
  "curriculum_code": "rev_2022",
  "units": [
   {
    "name": "기본 도형",
    "children": [
     {
      "name": "기본 도형",
      "children": [
       {
        "name": "점, 선, 면, 각"
       },
       {
        "name": "점, 직선, 평면의 위치 관계"
       },
       {
        "name": "동위각과 엇각"
       }
      ]
     },
     {
      "name": "작도와 합동",
      "children": [
       {
        "name": "삼각형의 작도"
       },
       {
        "name": "삼각형의 합동"
       }
      ]
     }
    ]
   },
   {
    "name": "평면도형",
    "children": [
     {
      "name": "다각형",
      "children": [
       {
        "name": "다각형"
       },
       {
        "name": "다각형의 내각과 외각의 크기의 합"
       }
      ]
     },
     {
      "name": "원과 부채꼴",
      "children": [
       {
        "name": "원과 부채꼴"
       },
       {
        "name": "부채꼴의 호의 길이와 넓이"
       }
      ]
     }
    ]
   },
   {
    "name": "입체도형",
    "children": [
     {
      "name": "다면체와 회전체",
      "children": [
       {
        "name": "다면체"
       },
       {
        "name": "정다면체"
       },
       {
        "name": "회전체"
       }
      ]
     },
     {
      "name": "입체도형의 겉넓이와 부피",
      "children": [
       {
        "name": "기둥의 겉넓이와 부피"
       },
       {
        "name": "뿔의 겉넓이와 부피"
       },
       {
        "name": "구의 겉넓이와 부피"
       }
      ]
     }
    ]
   },
   {
    "name": "통계",
    "children": [
     {
      "name": "자료의 정리와 해석",
      "children": [
       {
        "name": "대표값"
       },
       {
        "name": "줄기와 잎 그림, 도수분포표"
       },
       {
        "name": "히스토그램과 도수분포다각형"
       },
       {
        "name": "상대도수와 그 그래프"
       }
      ]
     }
    ]
   }
  ]
 },
 {
  "seed": "roadmap:M2-1",
  "course_key": "M2-1",
  "name": "2-1",
  "school_level": "중",
  "curriculum_code": "rev_2022",
  "units": [
   {
    "name": "유리수의 표현과 식의 계산",
    "children": [
     {
      "name": "유리수와 순환소수",
      "children": [
       {
        "name": "유리수와 순환소수"
       }
      ]
     },
     {
      "name": "식의 계산",
      "children": [
       {
        "name": "지수법칙"
       },
       {
        "name": "단항식의 계산"
       },
       {
        "name": "다항식의 계산"
       }
      ]
     }
    ]
   },
   {
    "name": "부등식과 연립방정식",
    "children": [
     {
      "name": "일차부등식",
      "children": [
       {
        "name": "부등식의 해와 그 성질"
       },
       {
        "name": "일차부등식의 풀이"
       },
       {
        "name": "일차부등식의 활용"
       }
      ]
     },
     {
      "name": "연립일차방정식",
      "children": [
       {
        "name": "미지수가 2개인 연립일차방정식"
       },
       {
        "name": "연립방정식의 풀이"
       },
       {
        "name": "연립방정식의 활용"
       }
      ]
     }
    ]
   },
   {
    "name": "일차함수",
    "children": [
     {
      "name": "일차함수와 그 그래프",
      "children": [
       {
        "name": "함수"
       },
       {
        "name": "일차함수와 그 그래프"
       },
       {
        "name": "일차함수의 그래프의 성질과 식"
       },
       {
        "name": "일차함수의 활용"
       }
      ]
     },
     {
      "name": "일차함수와 일차방정식의 관계",
      "children": [
       {
        "name": "일차함수와 일차방정식"
       },
       {
        "name": "일차함수의 그래프와 연립일차방정식"
       }
      ]
     }
    ]
   }
  ]
 },
 {
  "seed": "roadmap:M2-2",
  "course_key": "M2-2",
  "name": "2-2",
  "school_level": "중",
  "curriculum_code": "rev_2022",
  "units": [
   {
    "name": "삼각형과 사각형의 성질",
    "children": [
     {
      "name": "삼각형의 성질",
      "children": [
       {
        "name": "이등변삼각형의 성질"
       },
       {
        "name": "직각삼각형의 합동 조건"
       },
       {
        "name": "삼각형의 외심과 내심"
       }
      ]
     },
     {
      "name": "사각형의 성질",
      "children": [
       {
        "name": "평행사변형"
       },
       {
        "name": "여러 가지 사각형"
       },
       {
        "name": "평행선과 넓이"
       }
      ]
     }
    ]
   },
   {
    "name": "도형의 닮음과 피타고라스 정리",
    "children": [
     {
      "name": "도형의 닮음",
      "children": [
       {
        "name": "닮은 도형"
       },
       {
        "name": "삼각형의 닮음 조건"
       }
      ]
     },
     {
      "name": "평행선 사이의 선분의 길이의 비",
      "children": [
       {
        "name": "삼각형과 평행선"
       },
       {
        "name": "삼각형의 두 변의 중점을 이은 선분의 성질"
       },
       {
        "name": "평행선 사이의 선분의 길이의 비"
       },
       {
        "name": "삼각형의 무게중심"
       }
      ]
     },
     {
      "name": "피타고라스 정리",
      "children": [
       {
        "name": "피타고라스 정리"
       },
       {
        "name": "피타고라스 정리의 활용"
       }
      ]
     }
    ]
   },
   {
    "name": "확률",
    "children": [
     {
      "name": "경우의 수",
      "children": [
       {
        "name": "경우의 수"
       },
       {
        "name": "여러 가지 경우의 수"
       }
      ]
     },
     {
      "name": "확률",
      "children": [
       {
        "name": "확률의 뜻과 성질"
       },
       {
        "name": "확률의 계산"
       }
      ]
     }
    ]
   }
  ]
 },
 {
  "seed": "roadmap:M3-1",
  "course_key": "M3-1",
  "name": "3-1",
  "school_level": "중",
  "curriculum_code": "rev_2022",
  "units": [
   {
    "name": "실수와 그 계산",
    "children": [
     {
      "name": "제곱근과 실수",
      "children": [
       {
        "name": "제곱근의 뜻과 성질"
       },
       {
        "name": "무리수와 실수"
       }
      ]
     },
     {
      "name": "근호를 포함한 식의 계산",
      "children": [
       {
        "name": "근호를 포함한 식의 곱셈과 나눗셈"
       },
       {
        "name": "근호를 포함한 식의 덧셈과 뺄셈"
       }
      ]
     }
    ]
   },
   {
    "name": "인수분해와 이차방정식",
    "children": [
     {
      "name": "다항식의 곱셈",
      "children": [
       {
        "name": "곱셈 공식"
       },
       {
        "name": "곱셈 공식의 활용"
       }
      ]
     },
     {
      "name": "인수분해",
      "children": [
       {
        "name": "인수분해 공식"
       },
       {
        "name": "인수분해 공식의 응용"
       }
      ]
     },
     {
      "name": "이차방정식",
      "children": [
       {
        "name": "이차방정식과 그 해"
       },
       {
        "name": "이차방정식의 풀이"
       },
       {
        "name": "이차방정식의 활용"
       }
      ]
     }
    ]
   },
   {
    "name": "이차함수",
    "children": [
     {
      "name": "이차함수와 그 그래프",
      "children": [
       {
        "name": "이차함수의 뜻"
       },
       {
        "name": "이차함수 y=ax^2의 그래프"
       },
       {
        "name": "이차함수 y=a(x-p)^2+q의 그래프"
       }
      ]
     },
     {
      "name": "이차함수 y=ax^2+bx+c의 그래프",
      "children": [
       {
        "name": "이차함수 y=ax^2+bx+c의 그래프"
       },
       {
        "name": "이차함수의 식 구하기"
       },
       {
        "name": "이차함수의 최댓값과 최솟값"
       }
      ]
     }
    ]
   }
  ]
 },
 {
  "seed": "roadmap:M3-2",
  "course_key": "M3-2",
  "name": "3-2",
  "school_level": "중",
  "curriculum_code": "rev_2022",
  "units": [
   {
    "name": "삼각비",
    "children": [
     {
      "name": "삼각비",
      "children": [
       {
        "name": "삼각비"
       },
       {
        "name": "삼각비의 값"
       }
      ]
     },
     {
      "name": "삼각비의 활용",
      "children": [
       {
        "name": "길이 구하기"
       },
       {
        "name": "넓이 구하기"
       }
      ]
     }
    ]
   },
   {
    "name": "원의 성질",
    "children": [
     {
      "name": "원과 직선",
      "children": [
       {
        "name": "원의 현"
       },
       {
        "name": "원의 접선"
       }
      ]
     },
     {
      "name": "원주각",
      "children": [
       {
        "name": "원주각"
       },
       {
        "name": "원에 내접하는 사각형"
       },
       {
        "name": "원의 접선과 현이 이루는 각"
       }
      ]
     }
    ]
   },
   {
    "name": "통계",
    "children": [
     {
      "name": "산포도",
      "children": [
       {
        "name": "산포도"
       }
      ]
     },
     {
      "name": "상자그림과 산점도",
      "children": [
       {
        "name": "상자그림"
       },
       {
        "name": "산점도와 상관관계"
       }
      ]
     }
    ]
   }
  ]
 },
 {
  "seed": "roadmap:H1-c1",
  "course_key": "H1-c1",
  "name": "공통수학1",
  "school_level": "고",
  "curriculum_code": "rev_2022",
  "units": [
   {
    "name": "다항식",
    "children": [
     {
      "name": "다항식의 연산",
      "children": [
       {
        "name": "다항식의 덧셈과 뺄셈"
       },
       {
        "name": "다항식의 곱셈"
       },
       {
        "name": "곱셈 공식"
       },
       {
        "name": "곱셈 공식의 변형"
       },
       {
        "name": "다항식의 나눗셈"
       }
      ]
     },
     {
      "name": "항등식과 나머지정리",
      "children": [
       {
        "name": "항등식"
       },
       {
        "name": "나머지정리와 인수정리"
       }
      ]
     },
     {
      "name": "인수분해",
      "children": [
       {
        "name": "인수분해"
       },
       {
        "name": "복잡한 식의 인수분해"
       }
      ]
     }
    ]
   },
   {
    "name": "방정식과 부등식",
    "children": [
     {
      "name": "복소수",
      "children": [
       {
        "name": "복소수"
       },
       {
        "name": "복소수의 연산"
       },
       {
        "name": "i의 거듭제곱, 음수의 제곱근"
       }
      ]
     },
     {
      "name": "이차방정식",
      "children": [
       {
        "name": "이차방정식"
       },
       {
        "name": "이차방정식의 판별식"
       },
       {
        "name": "이차방정식의 근과 계수의 관계"
       }
      ]
     },
     {
      "name": "이차방정식과 이차함수",
      "children": [
       {
        "name": "이차방정식과 이차함수의 관계"
       },
       {
        "name": "이차함수의 최대·최소"
       }
      ]
     },
     {
      "name": "여러 가지 방정식",
      "children": [
       {
        "name": "삼차방정식과 사차방정식"
       },
       {
        "name": "삼차방정식의 근과 계수의 관계"
       },
       {
        "name": "방정식 x^n=1의 허근"
       },
       {
        "name": "미지수가 2개인 연립이차방정식"
       }
      ]
     },
     {
      "name": "여러 가지 부등식",
      "children": [
       {
        "name": "일차부등식"
       },
       {
        "name": "연립일차부등식"
       },
       {
        "name": "절댓값 기호를 포함한 일차부등식"
       },
       {
        "name": "이차부등식"
       },
       {
        "name": "이차부등식의 해의 조건"
       },
       {
        "name": "연립이차부등식"
       },
       {
        "name": "이차방정식의 실근의 조건"
       }
      ]
     }
    ]
   },
   {
    "name": "경우의 수",
    "children": [
     {
      "name": "경우의 수와 순열",
      "children": [
       {
        "name": "경우의 수"
       },
       {
        "name": "순열"
       }
      ]
     },
     {
      "name": "조합",
      "children": [
       {
        "name": "조합"
       }
      ]
     }
    ]
   },
   {
    "name": "행렬",
    "children": [
     {
      "name": "행렬",
      "children": [
       {
        "name": "행렬"
       },
       {
        "name": "행렬의 덧셈, 뺄셈과 실수배"
       },
       {
        "name": "행렬의 곱셈"
       },
       {
        "name": "행렬의 곱셈의 성질"
       }
      ]
     }
    ]
   }
  ]
 },
 {
  "seed": "roadmap:H1-c2",
  "course_key": "H1-c2",
  "name": "공통수학2",
  "school_level": "고",
  "curriculum_code": "rev_2022",
  "units": [
   {
    "name": "도형의 방정식",
    "children": [
     {
      "name": "평면좌표",
      "children": [
       {
        "name": "두 점 사이의 거리"
       },
       {
        "name": "선분의 내분점"
       },
       {
        "name": "삼각형의 무게중심"
       }
      ]
     },
     {
      "name": "직선의 방정식",
      "children": [
       {
        "name": "직선의 방정식"
       },
       {
        "name": "직선의 위치 관계"
       },
       {
        "name": "점과 직선 사이의 거리"
       }
      ]
     },
     {
      "name": "원의 방정식",
      "children": [
       {
        "name": "원의 방정식"
       },
       {
        "name": "원과 직선의 위치 관계"
       },
       {
        "name": "원의 접선의 방정식"
       },
       {
        "name": "두 원의 교점을 지나는 직선과 원의 방정식"
       }
      ]
     },
     {
      "name": "도형의 이동",
      "children": [
       {
        "name": "평행이동"
       },
       {
        "name": "대칭이동"
       },
       {
        "name": "점과 직선에 대한 대칭이동"
       }
      ]
     }
    ]
   },
   {
    "name": "집합과 명제",
    "children": [
     {
      "name": "집합의 뜻과 포함 관계",
      "children": [
       {
        "name": "집합의 뜻과 표현"
       },
       {
        "name": "집합 사이의 포함 관계"
       }
      ]
     },
     {
      "name": "집합의 연산",
      "children": [
       {
        "name": "집합의 연산"
       },
       {
        "name": "집합의 연산 법칙"
       },
       {
        "name": "유한집합의 원소의 개수"
       }
      ]
     },
     {
      "name": "명제",
      "children": [
       {
        "name": "명제와 조건"
       },
       {
        "name": "명제 p → q"
       },
       {
        "name": "‘모든’이나 ‘어떤’을 포함한 명제"
       },
       {
        "name": "명제의 역과 대우"
       },
       {
        "name": "충분조건과 필요조건"
       },
       {
        "name": "명제의 증명"
       },
       {
        "name": "절대부등식"
       }
      ]
     }
    ]
   },
   {
    "name": "함수",
    "children": [
     {
      "name": "함수",
      "children": [
       {
        "name": "함수"
       },
       {
        "name": "여러 가지 함수"
       },
       {
        "name": "합성함수"
       },
       {
        "name": "역함수"
       }
      ]
     },
     {
      "name": "유리함수",
      "children": [
       {
        "name": "유리식"
       },
       {
        "name": "유리함수"
       }
      ]
     },
     {
      "name": "무리함수",
      "children": [
       {
        "name": "무리식"
       },
       {
        "name": "무리함수"
       }
      ]
     }
    ]
   }
  ]
 },
 {
  "seed": "roadmap:H-algebra",
  "course_key": "H-algebra",
  "name": "대수",
  "school_level": "고",
  "curriculum_code": "rev_2022",
  "units": [
   {
    "name": "지수함수와 로그함수",
    "children": [
     {
      "name": "지수",
      "children": [
       {
        "name": "거듭제곱과 거듭제곱근"
       },
       {
        "name": "지수의 확장"
       }
      ]
     },
     {
      "name": "로그",
      "children": [
       {
        "name": "로그"
       },
       {
        "name": "로그의 성질"
       },
       {
        "name": "상용로그"
       }
      ]
     },
     {
      "name": "지수함수",
      "children": [
       {
        "name": "지수함수의 뜻과 그래프"
       },
       {
        "name": "지수함수의 최대·최소"
       },
       {
        "name": "지수함수의 활용: 방정식"
       },
       {
        "name": "지수함수의 활용: 부등식"
       }
      ]
     },
     {
      "name": "로그함수",
      "children": [
       {
        "name": "로그함수의 뜻과 그래프"
       },
       {
        "name": "로그함수의 최대·최소"
       },
       {
        "name": "로그함수의 활용: 방정식"
       },
       {
        "name": "로그함수의 활용: 부등식"
       }
      ]
     }
    ]
   },
   {
    "name": "삼각함수",
    "children": [
     {
      "name": "삼각함수",
      "children": [
       {
        "name": "일반각"
       },
       {
        "name": "호도법"
       },
       {
        "name": "삼각함수"
       }
      ]
     },
     {
      "name": "삼각함수의 그래프",
      "children": [
       {
        "name": "삼각함수의 그래프"
       },
       {
        "name": "일반각에 대한 삼각함수의 성질"
       },
       {
        "name": "삼각함수를 포함한 식의 최대·최소"
       },
       {
        "name": "삼각함수가 포함된 방정식과 부등식"
       }
      ]
     },
     {
      "name": "삼각함수의 활용",
      "children": [
       {
        "name": "사인법칙"
       },
       {
        "name": "코사인법칙"
       },
       {
        "name": "삼각형의 넓이"
       }
      ]
     }
    ]
   },
   {
    "name": "수열",
    "children": [
     {
      "name": "등차수열과 등비수열",
      "children": [
       {
        "name": "등차수열"
       },
       {
        "name": "등차수열의 합"
       },
       {
        "name": "등비수열"
       },
       {
        "name": "등비수열의 합"
       }
      ]
     },
     {
      "name": "수열의 합",
      "children": [
       {
        "name": "Σ의 뜻과 그 성질"
       },
       {
        "name": "자연수의 거듭제곱의 합"
       },
       {
        "name": "여러 가지 수열의 합"
       }
      ]
     },
     {
      "name": "수학적 귀납법",
      "children": [
       {
        "name": "수열의 귀납적 정의"
       },
       {
        "name": "수학적 귀납법"
       }
      ]
     }
    ]
   }
  ]
 },
 {
  "seed": "roadmap:H-calc1",
  "course_key": "H-calc1",
  "name": "미적분1",
  "school_level": "고",
  "curriculum_code": "rev_2022",
  "units": [
   {
    "name": "함수의 극한과 연속",
    "children": [
     {
      "name": "함수의 극한",
      "children": [
       {
        "name": "함수의 극한"
       },
       {
        "name": "우극한과 좌극한"
       },
       {
        "name": "함수의 극한에 대한 성질"
       },
       {
        "name": "함수의 극한의 응용"
       }
      ]
     },
     {
      "name": "함수의 연속",
      "children": [
       {
        "name": "함수의 연속"
       },
       {
        "name": "연속함수의 성질"
       }
      ]
     }
    ]
   },
   {
    "name": "미분",
    "children": [
     {
      "name": "미분계수와 도함수",
      "children": [
       {
        "name": "미분계수"
       },
       {
        "name": "미분가능성과 연속성"
       },
       {
        "name": "도함수"
       }
      ]
     },
     {
      "name": "도함수의 활용",
      "children": [
       {
        "name": "접선의 방정식"
       },
       {
        "name": "평균값 정리"
       },
       {
        "name": "함수의 증가와 감소"
       },
       {
        "name": "함수의 극대와 극소"
       },
       {
        "name": "함수의 그래프"
       },
       {
        "name": "함수의 최댓값과 최솟값"
       },
       {
        "name": "방정식과 부등식에의 활용"
       },
       {
        "name": "속도와 가속도"
       }
      ]
     }
    ]
   },
   {
    "name": "적분",
    "children": [
     {
      "name": "부정적분",
      "children": [
       {
        "name": "부정적분"
       },
       {
        "name": "부정적분의 계산"
       }
      ]
     },
     {
      "name": "정적분",
      "children": [
       {
        "name": "정적분"
       },
       {
        "name": "여러 가지 정적분"
       },
       {
        "name": "정적분으로 정의된 함수"
       }
      ]
     },
     {
      "name": "정적분의 활용",
      "children": [
       {
        "name": "정적분과 넓이"
       },
       {
        "name": "정적분과 넓이의 활용"
       },
       {
        "name": "속도와 거리"
       }
      ]
     }
    ]
   }
  ]
 },
 {
  "seed": "roadmap:H-probstats",
  "course_key": "H-probstats",
  "name": "확률과 통계",
  "school_level": "고",
  "curriculum_code": "rev_2022",
  "units": [
   {
    "name": "경우의 수",
    "children": [
     {
      "name": "순열과 조합",
      "children": [
       {
        "name": "중복순열"
       },
       {
        "name": "같은 것이 있는 순열"
       },
       {
        "name": "중복조합"
       }
      ]
     },
     {
      "name": "이항정리",
      "children": [
       {
        "name": "이항정리"
       },
       {
        "name": "이항정리의 활용"
       }
      ]
     }
    ]
   },
   {
    "name": "확률",
    "children": [
     {
      "name": "확률의 뜻과 활용",
      "children": [
       {
        "name": "시행과 사건"
       },
       {
        "name": "확률의 뜻"
       },
       {
        "name": "확률의 덧셈정리"
       }
      ]
     },
     {
      "name": "조건부확률",
      "children": [
       {
        "name": "조건부확률"
       },
       {
        "name": "사건의 독립과 종속"
       },
       {
        "name": "독립시행의 확률"
       }
      ]
     }
    ]
   },
   {
    "name": "통계",
    "children": [
     {
      "name": "확률분포",
      "children": [
       {
        "name": "확률변수와 확률분포"
       },
       {
        "name": "이산확률변수의 기댓값과 표준편차"
       },
       {
        "name": "이항분포"
       },
       {
        "name": "연속확률변수의 확률분포"
       },
       {
        "name": "정규분포"
       },
       {
        "name": "이항분포와 정규분포의 관계"
       }
      ]
     },
     {
      "name": "통계적 추정",
      "children": [
       {
        "name": "모집단과 표본"
       },
       {
        "name": "모평균과 표본평균"
       },
       {
        "name": "모비율과 표본비율"
       },
       {
        "name": "모평균의 추정"
       },
       {
        "name": "모비율의 추정"
       }
      ]
     }
    ]
   }
  ]
 },
 {
  "seed": "roadmap:H-calc2",
  "course_key": "H-calc2",
  "name": "미적분2",
  "school_level": "고",
  "curriculum_code": "rev_2022",
  "units": [
   {
    "name": "수열의 극한",
    "children": [
     {
      "name": "수열의 극한",
      "children": [
       {
        "name": "수열의 수렴과 발산"
       },
       {
        "name": "수열의 극한값의 계산"
       },
       {
        "name": "수열의 극한의 대소 관계"
       },
       {
        "name": "등비수열의 극한"
       }
      ]
     },
     {
      "name": "급수",
      "children": [
       {
        "name": "급수의 수렴과 발산"
       },
       {
        "name": "등비급수"
       },
       {
        "name": "등비급수의 활용"
       }
      ]
     }
    ]
   },
   {
    "name": "미분법",
    "children": [
     {
      "name": "지수함수와 로그함수의 미분",
      "children": [
       {
        "name": "지수함수와 로그함수의 극한"
       },
       {
        "name": "무리수 e와 자연로그"
       },
       {
        "name": "지수함수와 로그함수의 도함수"
       }
      ]
     },
     {
      "name": "삼각함수의 미분",
      "children": [
       {
        "name": "삼각함수의 뜻"
       },
       {
        "name": "삼각함수의 덧셈정리"
       },
       {
        "name": "삼각함수의 극한"
       },
       {
        "name": "삼각함수의 도함수"
       }
      ]
     },
     {
      "name": "여러 가지 미분법",
      "children": [
       {
        "name": "함수의 몫의 미분법"
       },
       {
        "name": "합성함수의 미분법"
       },
       {
        "name": "매개변수로 나타낸 함수의 미분법"
       },
       {
        "name": "음함수와 역함수의 미분법"
       }
      ]
     },
     {
      "name": "도함수의 활용",
      "children": [
       {
        "name": "접선의 방정식"
       },
       {
        "name": "함수의 극대와 극소"
       },
       {
        "name": "곡선의 볼록과 변곡점"
       },
       {
        "name": "함수의 그래프"
       },
       {
        "name": "함수의 최댓값과 최솟값"
       },
       {
        "name": "방정식과 부등식에의 활용"
       },
       {
        "name": "속도와 가속도"
       }
      ]
     }
    ]
   },
   {
    "name": "적분법",
    "children": [
     {
      "name": "여러 가지 함수의 적분",
      "children": [
       {
        "name": "여러 가지 함수의 부정적분"
       },
       {
        "name": "여러 가지 함수의 정적분"
       }
      ]
     },
     {
      "name": "치환적분법과 부분적분법",
      "children": [
       {
        "name": "치환적분법"
       },
       {
        "name": "부분적분법"
       },
       {
        "name": "정적분으로 정의된 함수"
       }
      ]
     },
     {
      "name": "정적분의 활용",
      "children": [
       {
        "name": "구분구적법"
       },
       {
        "name": "정적분과 급수"
       },
       {
        "name": "도형의 넓이"
       },
       {
        "name": "입체도형의 부피"
       },
       {
        "name": "속도와 거리"
       }
      ]
     }
    ]
   }
  ]
 },
 {
  "seed": "roadmap:H-geometry",
  "course_key": "H-geometry",
  "name": "기하",
  "school_level": "고",
  "curriculum_code": "rev_2022",
  "units": [
   {
    "name": "이차곡선",
    "children": [
     {
      "name": "이차곡선",
      "children": [
       {
        "name": "포물선의 방정식"
       },
       {
        "name": "타원의 방정식"
       },
       {
        "name": "쌍곡선의 방정식"
       },
       {
        "name": "이차곡선"
       }
      ]
     },
     {
      "name": "이차곡선의 접선",
      "children": [
       {
        "name": "포물선의 접선의 방정식"
       },
       {
        "name": "타원의 접선의 방정식"
       },
       {
        "name": "쌍곡선의 접선의 방정식"
       }
      ]
     }
    ]
   },
   {
    "name": "공간도형과 공간좌표",
    "children": [
     {
      "name": "공간도형",
      "children": [
       {
        "name": "직선과 평면의 위치 관계"
       },
       {
        "name": "직선과 평면의 평행"
       },
       {
        "name": "직선과 평면의 수직"
       },
       {
        "name": "삼수선 정리"
       },
       {
        "name": "이면각"
       },
       {
        "name": "정사영"
       }
      ]
     },
     {
      "name": "공간좌표",
      "children": [
       {
        "name": "공간좌표"
       },
       {
        "name": "두 점 사이의 거리"
       },
       {
        "name": "선분의 내분점"
       },
       {
        "name": "구의 방정식"
       }
      ]
     }
    ]
   },
   {
    "name": "벡터",
    "children": [
     {
      "name": "벡터의 연산",
      "children": [
       {
        "name": "벡터의 뜻"
       },
       {
        "name": "벡터의 덧셈과 뺄셈"
       },
       {
        "name": "벡터의 실수배"
       }
      ]
     },
     {
      "name": "벡터의 성분과 내적",
      "children": [
       {
        "name": "위치벡터"
       },
       {
        "name": "평면벡터의 성분"
       },
       {
        "name": "공간벡터의 성분"
       },
       {
        "name": "벡터의 내적"
       },
       {
        "name": "벡터의 내적과 두 벡터가 이루는 각"
       }
      ]
     },
     {
      "name": "도형의 방정식",
      "children": [
       {
        "name": "직선의 방정식"
       },
       {
        "name": "두 직선이 이루는 각"
       },
       {
        "name": "평면의 방정식"
       },
       {
        "name": "두 평면이 이루는 각"
       },
       {
        "name": "점과 평면 사이의 거리"
       },
       {
        "name": "벡터를 이용한 구의 방정식"
       }
      ]
     }
    ]
   }
  ]
 }
]
$course_map_seed$::jsonb);

notify pgrst, 'reload schema';
