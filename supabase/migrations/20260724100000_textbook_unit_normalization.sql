-- Canonical textbook unit/category/link normalization.
-- This migration is additive: legacy metadata, RPCs, sub_key and link fields
-- remain available while normalized consumers move to schema_version 2.

-- ---------------------------------------------------------------------------
-- 1) Canonical hierarchy: big -> mid -> actual small unit
-- ---------------------------------------------------------------------------

create table if not exists public.textbook_units (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  book_id uuid not null references public.resource_files(id) on delete cascade,
  grade_label text not null,
  parent_id uuid references public.textbook_units(id) on delete cascade,
  unit_level text not null,
  order_index integer not null,
  unit_key text not null,
  name text not null,
  display_start_page integer,
  display_end_page integer,
  legacy_sub_key text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint textbook_units_level_chk
    check (unit_level in ('big', 'mid', 'small')),
  constraint textbook_units_name_chk check (btrim(name) <> ''),
  constraint textbook_units_key_chk check (btrim(unit_key) <> ''),
  constraint textbook_units_page_chk check (
    display_start_page is null
    or display_end_page is null
    or display_start_page <= display_end_page
  ),
  constraint textbook_units_parent_level_chk check (
    (unit_level = 'big' and parent_id is null)
    or (unit_level in ('mid', 'small') and parent_id is not null)
  ),
  constraint textbook_units_scope_key_uk
    unique (academy_id, book_id, grade_label, unit_key)
);

create index if not exists textbook_units_scope_order_idx
  on public.textbook_units
    (academy_id, book_id, grade_label, unit_level, order_index);
create unique index if not exists textbook_units_big_order_uk
  on public.textbook_units
    (academy_id, book_id, grade_label, order_index)
  where unit_level = 'big';
create unique index if not exists textbook_units_child_order_uk
  on public.textbook_units(parent_id, unit_level, order_index)
  where parent_id is not null;
create index if not exists textbook_units_parent_order_idx
  on public.textbook_units(parent_id, order_index, id);
create index if not exists textbook_units_legacy_sub_idx
  on public.textbook_units
    (academy_id, book_id, grade_label, legacy_sub_key)
  where unit_level = 'small' and legacy_sub_key is not null;

create or replace function public._textbook_units_validate_parent()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_parent public.textbook_units%rowtype;
begin
  if new.unit_level = 'big' then
    if new.parent_id is not null then
      raise exception 'big textbook unit cannot have a parent';
    end if;
    return new;
  end if;

  select * into v_parent
  from public.textbook_units
  where id = new.parent_id;

  if not found
     or v_parent.academy_id <> new.academy_id
     or v_parent.book_id <> new.book_id
     or v_parent.grade_label <> new.grade_label
     or (new.unit_level = 'mid' and v_parent.unit_level <> 'big')
     or (new.unit_level = 'small' and v_parent.unit_level <> 'mid') then
    raise exception 'invalid textbook unit parent';
  end if;
  return new;
end;
$$;

drop trigger if exists textbook_units_validate_parent
  on public.textbook_units;
create trigger textbook_units_validate_parent
before insert or update of academy_id, book_id, grade_label, parent_id, unit_level
on public.textbook_units
for each row execute function public._textbook_units_validate_parent();

drop trigger if exists textbook_units_set_updated_at
  on public.textbook_units;
create trigger textbook_units_set_updated_at
before update on public.textbook_units
for each row execute function public.set_updated_at();

alter table public.textbook_units enable row level security;

drop policy if exists "textbook_units select" on public.textbook_units;
create policy "textbook_units select" on public.textbook_units
for select to authenticated
using (
  exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = textbook_units.academy_id
  )
);

drop policy if exists "textbook_units insert" on public.textbook_units;
create policy "textbook_units insert" on public.textbook_units
for insert to authenticated
with check (
  exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = textbook_units.academy_id
  )
);

drop policy if exists "textbook_units update" on public.textbook_units;
create policy "textbook_units update" on public.textbook_units
for update to authenticated
using (
  exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = textbook_units.academy_id
  )
)
with check (
  exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = textbook_units.academy_id
  )
);

drop policy if exists "textbook_units delete" on public.textbook_units;
create policy "textbook_units delete" on public.textbook_units
for delete to authenticated
using (
  exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = textbook_units.academy_id
  )
);

-- ---------------------------------------------------------------------------
-- 2) Maintainable per-series problem category catalog
-- ---------------------------------------------------------------------------

create table if not exists public.textbook_problem_categories (
  series_key text not null,
  category_code text not null,
  display_label text not null,
  order_index integer not null,
  description text not null default '',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (series_key, category_code),
  constraint textbook_problem_categories_series_chk
    check (series_key ~ '^[a-z][a-z0-9_-]*$'),
  constraint textbook_problem_categories_code_chk
    check (category_code ~ '^[A-Z][A-Z0-9_-]*$'),
  constraint textbook_problem_categories_label_chk
    check (btrim(display_label) <> ''),
  constraint textbook_problem_categories_order_uk
    unique (series_key, order_index)
);

drop trigger if exists textbook_problem_categories_set_updated_at
  on public.textbook_problem_categories;
create trigger textbook_problem_categories_set_updated_at
before update on public.textbook_problem_categories
for each row execute function public.set_updated_at();

alter table public.textbook_problem_categories enable row level security;

drop policy if exists "textbook_problem_categories read"
  on public.textbook_problem_categories;
create policy "textbook_problem_categories read"
on public.textbook_problem_categories
for select to authenticated
using (true);

insert into public.textbook_problem_categories (
  series_key, category_code, display_label, order_index, description
) values
  ('wonri', 'A', '개념원리 익히기', 0, '개념원리 기본 개념 적용 문항'),
  ('wonri', 'B', '필수유형', 1, '소단원별 필수유형'),
  ('wonri', 'C', '확인 체크', 2, '개념 확인 문항'),
  ('wonri', 'D', '연습문제', 3, 'STEP/실력 UP 연습문제'),
  ('wonri', 'E', '특강', 4, '특강 예제 및 확인 문항'),
  ('ssen', 'A', 'A 기본다잡기', 0, '기본 개념 적용'),
  ('ssen', 'B', 'B 유형뽀개기', 1, '대표 유형 학습'),
  ('ssen', 'C', 'C 만점도전하기', 2, '고난도 및 서술형'),
  ('rpm', 'A', 'A 교과서문제 정복하기', 0, '교과서 기본 문제'),
  ('rpm', 'B', 'B 유형 익히기', 1, '유형 학습'),
  ('rpm', 'C', 'C 시험에 꼭 나오는 문제', 2, '시험 대비 문항')
on conflict (series_key, category_code) do update
set display_label = excluded.display_label,
    order_index = excluded.order_index,
    description = excluded.description,
    is_active = true;

-- ---------------------------------------------------------------------------
-- 3) Normalized references on legacy crop/extraction rows
-- ---------------------------------------------------------------------------

alter table public.textbook_problem_crops
  add column if not exists unit_id uuid
    references public.textbook_units(id) on delete set null,
  add column if not exists category_code text;

alter table public.textbook_problem_crops
  drop constraint if exists textbook_problem_crops_category_code_chk;
alter table public.textbook_problem_crops
  add constraint textbook_problem_crops_category_code_chk
  check (
    category_code is null
    or category_code ~ '^[A-Z][A-Z0-9_-]*$'
  );

create index if not exists textbook_problem_crops_unit_idx
  on public.textbook_problem_crops(unit_id)
  where unit_id is not null;
create index if not exists textbook_problem_crops_category_idx
  on public.textbook_problem_crops
    (academy_id, book_id, grade_label, category_code);

alter table public.textbook_pb_extract_runs
  add column if not exists unit_id uuid
    references public.textbook_units(id) on delete set null,
  add column if not exists category_code text;

alter table public.textbook_pb_extract_runs
  drop constraint if exists textbook_pb_extract_runs_category_code_chk;
alter table public.textbook_pb_extract_runs
  add constraint textbook_pb_extract_runs_category_code_chk
  check (
    category_code is null
    or category_code ~ '^[A-Z][A-Z0-9_-]*$'
  );

create index if not exists textbook_pb_extract_runs_unit_idx
  on public.textbook_pb_extract_runs(unit_id)
  where unit_id is not null;
create index if not exists textbook_pb_extract_runs_category_idx
  on public.textbook_pb_extract_runs
    (academy_id, book_id, grade_label, category_code);

update public.textbook_problem_crops
set category_code = upper(btrim(sub_key))
where category_code is null
  and btrim(coalesce(sub_key, '')) <> '';

update public.textbook_pb_extract_runs
set category_code = upper(btrim(sub_key))
where category_code is null
  and btrim(coalesce(sub_key, '')) <> '';

-- ---------------------------------------------------------------------------
-- 4) Unit/link migration audit issues
-- ---------------------------------------------------------------------------

create table if not exists public.textbook_normalization_issues (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  book_id uuid references public.resource_files(id) on delete cascade,
  grade_label text,
  issue_key text not null unique,
  issue_kind text not null,
  entity_kind text not null,
  entity_id uuid,
  candidate_ids uuid[] not null default array[]::uuid[],
  details jsonb not null default '{}'::jsonb,
  resolved_at timestamptz,
  resolved_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint textbook_normalization_issues_kind_chk check (
    issue_kind in ('no_match', 'ambiguous', 'conflict')
  ),
  constraint textbook_normalization_issues_entity_chk check (
    entity_kind in ('crop_unit', 'extract_unit', 'crop_question_link')
  )
);

create index if not exists textbook_normalization_issues_scope_idx
  on public.textbook_normalization_issues
    (academy_id, book_id, grade_label, issue_kind)
  where resolved_at is null;

drop trigger if exists textbook_normalization_issues_set_updated_at
  on public.textbook_normalization_issues;
create trigger textbook_normalization_issues_set_updated_at
before update on public.textbook_normalization_issues
for each row execute function public.set_updated_at();

alter table public.textbook_normalization_issues enable row level security;

drop policy if exists "textbook_normalization_issues select"
  on public.textbook_normalization_issues;
create policy "textbook_normalization_issues select"
on public.textbook_normalization_issues
for select to authenticated
using (
  exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = textbook_normalization_issues.academy_id
  )
);

drop policy if exists "textbook_normalization_issues write"
  on public.textbook_normalization_issues;
create policy "textbook_normalization_issues write"
on public.textbook_normalization_issues
for all to authenticated
using (
  exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = textbook_normalization_issues.academy_id
  )
)
with check (
  exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = textbook_normalization_issues.academy_id
  )
);

-- ---------------------------------------------------------------------------
-- 5) Idempotent metadata.payload -> canonical hierarchy backfill
-- ---------------------------------------------------------------------------

create temporary table _textbook_payload_units on commit drop as
with metadata as (
  select
    tm.academy_id,
    tm.book_id,
    tm.grade_label,
    tm.payload
  from public.textbook_metadata tm
  where jsonb_typeof(tm.payload->'units') = 'array'
),
bigs as (
  select
    m.academy_id,
    m.book_id,
    m.grade_label,
    b.value as big_json,
    coalesce(
      case when b.value->>'order_index' ~ '^-?[0-9]+$'
        then (b.value->>'order_index')::integer end,
      b.ordinality::integer - 1
    ) as big_order
  from metadata m
  cross join lateral jsonb_array_elements(m.payload->'units')
    with ordinality as b(value, ordinality)
  where jsonb_typeof(b.value) = 'object'
),
mids as (
  select
    b.*,
    md.value as mid_json,
    coalesce(
      case when md.value->>'order_index' ~ '^-?[0-9]+$'
        then (md.value->>'order_index')::integer end,
      md.ordinality::integer - 1
    ) as mid_order
  from bigs b
  cross join lateral jsonb_array_elements(
    case when jsonb_typeof(b.big_json->'middles') = 'array'
      then b.big_json->'middles' else '[]'::jsonb end
  ) with ordinality as md(value, ordinality)
  where jsonb_typeof(md.value) = 'object'
),
actual_smalls as (
  select
    m.academy_id,
    m.book_id,
    m.grade_label,
    m.big_order,
    m.mid_order,
    s.value as small_json,
    s.ordinality::integer - 1 as fallback_order,
    case
      when jsonb_typeof(m.mid_json->'sub_units') = 'array'
       and jsonb_array_length(m.mid_json->'sub_units') > 0
      then true else false
    end as from_sub_units
  from mids m
  cross join lateral jsonb_array_elements(
    case
      when jsonb_typeof(m.mid_json->'sub_units') = 'array'
       and jsonb_array_length(m.mid_json->'sub_units') > 0
      then m.mid_json->'sub_units'
      when jsonb_typeof(m.mid_json->'smalls') = 'array'
      then m.mid_json->'smalls'
      else '[]'::jsonb
    end
  ) with ordinality as s(value, ordinality)
  where jsonb_typeof(s.value) = 'object'
)
select
  b.academy_id,
  b.book_id,
  b.grade_label,
  'big'::text as unit_level,
  b.big_order as order_index,
  ('B:' || b.big_order)::text as unit_key,
  null::text as parent_key,
  coalesce(nullif(btrim(b.big_json->>'name'), ''), '대단원') as name,
  null::integer as display_start_page,
  null::integer as display_end_page,
  null::text as legacy_sub_key,
  b.big_order,
  null::integer as mid_order
from bigs b
union all
select
  m.academy_id,
  m.book_id,
  m.grade_label,
  'mid',
  m.mid_order,
  'B:' || m.big_order || '/M:' || m.mid_order,
  'B:' || m.big_order,
  coalesce(nullif(btrim(m.mid_json->>'name'), ''), '중단원'),
  null,
  null,
  null,
  m.big_order,
  m.mid_order
from mids m
union all
select
  s.academy_id,
  s.book_id,
  s.grade_label,
  'small',
  coalesce(
    case when s.small_json->>'order_index' ~ '^-?[0-9]+$'
      then (s.small_json->>'order_index')::integer end,
    s.fallback_order
  ),
  'B:' || s.big_order || '/M:' || s.mid_order ||
    case
      when s.from_sub_units then '/U:'
      else '/S:' || coalesce(
        nullif(upper(btrim(s.small_json->>'sub_key')), ''),
        s.fallback_order::text
      ) || ':'
    end ||
    case
      when s.from_sub_units then coalesce(
        case when s.small_json->>'order_index' ~ '^-?[0-9]+$'
          then (s.small_json->>'order_index')::integer end,
        s.fallback_order
      )::text
      else coalesce(
        nullif(upper(btrim(s.small_json->>'sub_key')), ''),
        s.fallback_order::text
      )
    end,
  'B:' || s.big_order || '/M:' || s.mid_order,
  coalesce(nullif(btrim(s.small_json->>'name'), ''), '소단원'),
  case when s.small_json->>'start_page' ~ '^-?[0-9]+$'
    then (s.small_json->>'start_page')::integer end,
  case when s.small_json->>'end_page' ~ '^-?[0-9]+$'
    then (s.small_json->>'end_page')::integer end,
  case when not s.from_sub_units
    then nullif(upper(btrim(s.small_json->>'sub_key')), '') end,
  s.big_order,
  s.mid_order
from actual_smalls s;

insert into public.textbook_units (
  academy_id, book_id, grade_label, parent_id, unit_level, order_index,
  unit_key, name, display_start_page, display_end_page, legacy_sub_key
)
select
  p.academy_id, p.book_id, p.grade_label, null, p.unit_level, p.order_index,
  p.unit_key, p.name, p.display_start_page, p.display_end_page,
  p.legacy_sub_key
from _textbook_payload_units p
where p.unit_level = 'big'
on conflict (academy_id, book_id, grade_label, unit_key) do update
set order_index = excluded.order_index,
    name = excluded.name;

insert into public.textbook_units (
  academy_id, book_id, grade_label, parent_id, unit_level, order_index,
  unit_key, name, display_start_page, display_end_page, legacy_sub_key
)
select
  p.academy_id, p.book_id, p.grade_label, parent.id, p.unit_level,
  p.order_index, p.unit_key, p.name, p.display_start_page,
  p.display_end_page, p.legacy_sub_key
from _textbook_payload_units p
join public.textbook_units parent
  on parent.academy_id = p.academy_id
 and parent.book_id = p.book_id
 and parent.grade_label = p.grade_label
 and parent.unit_key = p.parent_key
where p.unit_level = 'mid'
on conflict (academy_id, book_id, grade_label, unit_key) do update
set parent_id = excluded.parent_id,
    order_index = excluded.order_index,
    name = excluded.name;

insert into public.textbook_units (
  academy_id, book_id, grade_label, parent_id, unit_level, order_index,
  unit_key, name, display_start_page, display_end_page, legacy_sub_key
)
select
  p.academy_id, p.book_id, p.grade_label, parent.id, p.unit_level,
  p.order_index, p.unit_key, p.name, p.display_start_page,
  coalesce(p.display_end_page, p.display_start_page), p.legacy_sub_key
from _textbook_payload_units p
join public.textbook_units parent
  on parent.academy_id = p.academy_id
 and parent.book_id = p.book_id
 and parent.grade_label = p.grade_label
 and parent.unit_key = p.parent_key
where p.unit_level = 'small'
on conflict (academy_id, book_id, grade_label, unit_key) do update
set parent_id = excluded.parent_id,
    order_index = excluded.order_index,
    name = excluded.name,
    display_start_page = excluded.display_start_page,
    display_end_page = excluded.display_end_page,
    legacy_sub_key = excluded.legacy_sub_key;

-- Derive mid/big display ranges from actual small units.
update public.textbook_units mid
set display_start_page = ranges.lo,
    display_end_page = ranges.hi
from (
  select
    s.parent_id,
    min(s.display_start_page) as lo,
    max(coalesce(s.display_end_page, s.display_start_page)) as hi
  from public.textbook_units s
  where s.unit_level = 'small'
  group by s.parent_id
) ranges
where mid.id = ranges.parent_id
  and mid.unit_level = 'mid';

update public.textbook_units big
set display_start_page = ranges.lo,
    display_end_page = ranges.hi
from (
  select
    m.parent_id,
    min(m.display_start_page) as lo,
    max(m.display_end_page) as hi
  from public.textbook_units m
  where m.unit_level = 'mid'
  group by m.parent_id
) ranges
where big.id = ranges.parent_id
  and big.unit_level = 'big';

-- ---------------------------------------------------------------------------
-- 6) Conservative unit matching (never choose an arbitrary candidate)
-- ---------------------------------------------------------------------------

create temporary table _crop_unit_candidates on commit drop as
with candidates as (
  select
    c.id as crop_id,
    s.id as unit_id,
    c.category_code,
    c.sub_index,
    s.order_index,
    count(*) over (partition by c.id) as all_count,
    count(*) filter (
      where c.category_code in ('B', 'E')
        and s.order_index = c.sub_index
    ) over (partition by c.id) as indexed_count
  from public.textbook_problem_crops c
  join public.textbook_units mid
    on mid.academy_id = c.academy_id
   and mid.book_id = c.book_id
   and mid.grade_label = c.grade_label
   and mid.unit_level = 'mid'
   and mid.unit_key =
       'B:' || c.big_order || '/M:' || c.mid_order
  join public.textbook_units s
    on s.parent_id = mid.id
   and s.unit_level = 'small'
  left join public.textbook_metadata tm
    on tm.academy_id = c.academy_id
   and tm.book_id = c.book_id
   and tm.grade_label = c.grade_label
  where c.unit_id is null
    and (
      (
        (
          lower(coalesce(tm.payload->>'series', '')) = 'wonri'
          or exists (
            select 1
            from public.textbook_units sx
            where sx.parent_id = mid.id
              and sx.unit_level = 'small'
              and sx.legacy_sub_key is null
          )
        )
        and c.display_page is not null
        and s.display_start_page is not null
        and c.display_page between s.display_start_page
          and coalesce(s.display_end_page, s.display_start_page)
      )
      or (
        lower(coalesce(tm.payload->>'series', '')) <> 'wonri'
        and s.legacy_sub_key = upper(btrim(c.sub_key))
      )
    )
),
selected as (
  select *
  from candidates
  where all_count = 1
     or (
       all_count > 1
       and category_code in ('B', 'E')
       and indexed_count = 1
       and order_index = sub_index
     )
)
select crop_id, unit_id
from selected;

update public.textbook_problem_crops c
set unit_id = m.unit_id
from _crop_unit_candidates m
where c.id = m.crop_id
  and c.unit_id is null;

insert into public.textbook_normalization_issues (
  academy_id, book_id, grade_label, issue_key, issue_kind, entity_kind,
  entity_id, candidate_ids, details
)
select
  c.academy_id,
  c.book_id,
  c.grade_label,
  'crop_unit:' || c.id,
  case when count(distinct s.id) = 0 then 'no_match' else 'ambiguous' end,
  'crop_unit',
  c.id,
  coalesce(array_agg(distinct s.id) filter (where s.id is not null),
           array[]::uuid[]),
  jsonb_build_object(
    'big_order', c.big_order,
    'mid_order', c.mid_order,
    'sub_key', c.sub_key,
    'sub_index', c.sub_index,
    'display_page', c.display_page
  )
from public.textbook_problem_crops c
left join public.textbook_units mid
  on mid.academy_id = c.academy_id
 and mid.book_id = c.book_id
 and mid.grade_label = c.grade_label
 and mid.unit_key = 'B:' || c.big_order || '/M:' || c.mid_order
left join public.textbook_units s
  on s.parent_id = mid.id
 and s.unit_level = 'small'
 and (
   s.legacy_sub_key = upper(btrim(c.sub_key))
   or (
     c.display_page is not null
     and s.display_start_page is not null
     and c.display_page between s.display_start_page
       and coalesce(s.display_end_page, s.display_start_page)
   )
 )
where c.unit_id is null
group by c.id
on conflict (issue_key) do nothing;

create temporary table _extract_unit_candidates on commit drop as
with candidates as (
  select
    r.id as run_id,
    s.id as unit_id,
    count(*) over (partition by r.id) as candidate_count
  from public.textbook_pb_extract_runs r
  join public.textbook_units mid
    on mid.academy_id = r.academy_id
   and mid.book_id = r.book_id
   and mid.grade_label = r.grade_label
   and mid.unit_key = 'B:' || r.big_order || '/M:' || r.mid_order
  join public.textbook_units s
    on s.parent_id = mid.id
   and s.unit_level = 'small'
  left join public.textbook_metadata tm
    on tm.academy_id = r.academy_id
   and tm.book_id = r.book_id
   and tm.grade_label = r.grade_label
  where r.unit_id is null
    and (
      (
        lower(coalesce(tm.payload->>'series', '')) = 'wonri'
        and r.display_page_from is not null
        and s.display_start_page is not null
        and r.display_page_from >= s.display_start_page
        and coalesce(r.display_page_to, r.display_page_from)
              <= coalesce(s.display_end_page, s.display_start_page)
        and (
          r.category_code not in ('B', 'E')
          or s.order_index = r.sub_index
        )
      )
      or (
        lower(coalesce(tm.payload->>'series', '')) <> 'wonri'
        and s.legacy_sub_key = upper(btrim(r.sub_key))
      )
    )
)
select run_id, unit_id
from candidates
where candidate_count = 1;

update public.textbook_pb_extract_runs r
set unit_id = m.unit_id
from _extract_unit_candidates m
where r.id = m.run_id
  and r.unit_id is null;

insert into public.textbook_normalization_issues (
  academy_id, book_id, grade_label, issue_key, issue_kind, entity_kind,
  entity_id, details
)
select
  r.academy_id,
  r.book_id,
  r.grade_label,
  'extract_unit:' || r.id,
  'no_match',
  'extract_unit',
  r.id,
  jsonb_build_object(
    'big_order', r.big_order,
    'mid_order', r.mid_order,
    'sub_key', r.sub_key,
    'sub_index', r.sub_index,
    'display_page_from', r.display_page_from,
    'display_page_to', r.display_page_to
  )
from public.textbook_pb_extract_runs r
where r.unit_id is null
on conflict (issue_key) do nothing;

-- ---------------------------------------------------------------------------
-- 7) Canonical one-to-one crop <-> problem-bank question link
-- ---------------------------------------------------------------------------

create table if not exists public.textbook_crop_question_links (
  crop_id uuid primary key
    references public.textbook_problem_crops(id) on delete cascade,
  pb_question_id uuid not null unique
    references public.pb_questions(id) on delete cascade,
  academy_id uuid not null references public.academies(id) on delete cascade,
  source text not null,
  confidence numeric(5,4) not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint textbook_crop_question_links_source_chk check (
    source in (
      'legacy_crop_uid', 'question_meta', 'unique_tuple',
      'extract', 'reconcile', 'backfill', 'manual'
    )
  ),
  constraint textbook_crop_question_links_confidence_chk check (
    confidence >= 0 and confidence <= 1
  )
);

create index if not exists textbook_crop_question_links_academy_idx
  on public.textbook_crop_question_links(academy_id, created_at desc);

create or replace function public._textbook_crop_question_link_sync()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_crop_academy uuid;
  v_question_academy uuid;
  v_question_uid uuid;
begin
  select c.academy_id into v_crop_academy
  from public.textbook_problem_crops c
  where c.id = new.crop_id;

  select q.academy_id, q.question_uid
    into v_question_academy, v_question_uid
  from public.pb_questions q
  where q.id = new.pb_question_id;

  if v_crop_academy is null
     or v_question_academy is null
     or v_crop_academy <> v_question_academy
     or new.academy_id <> v_crop_academy then
    raise exception 'crop/question link academy mismatch';
  end if;

  update public.textbook_problem_crops
  set pb_question_uid = v_question_uid,
      updated_at = now()
  where id = new.crop_id
    and pb_question_uid is distinct from v_question_uid;

  update public.pb_questions
  set meta = jsonb_set(
        coalesce(meta, '{}'::jsonb),
        '{textbook_crop_page}',
        coalesce(meta->'textbook_crop_page', '{}'::jsonb)
          || jsonb_build_object('crop_id', new.crop_id::text),
        true
      ),
      updated_at = now()
  where id = new.pb_question_id
    and coalesce(meta->'textbook_crop_page'->>'crop_id', '')
          <> new.crop_id::text;

  return new;
end;
$$;

drop trigger if exists textbook_crop_question_links_sync
  on public.textbook_crop_question_links;
create trigger textbook_crop_question_links_sync
after insert or update of crop_id, pb_question_id, academy_id
on public.textbook_crop_question_links
for each row execute function public._textbook_crop_question_link_sync();

drop trigger if exists textbook_crop_question_links_set_updated_at
  on public.textbook_crop_question_links;
create trigger textbook_crop_question_links_set_updated_at
before update on public.textbook_crop_question_links
for each row execute function public.set_updated_at();

alter table public.textbook_crop_question_links enable row level security;

drop policy if exists "textbook_crop_question_links select"
  on public.textbook_crop_question_links;
create policy "textbook_crop_question_links select"
on public.textbook_crop_question_links
for select to authenticated
using (
  exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = textbook_crop_question_links.academy_id
  )
);

drop policy if exists "textbook_crop_question_links write"
  on public.textbook_crop_question_links;
create policy "textbook_crop_question_links write"
on public.textbook_crop_question_links
for all to authenticated
using (
  exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = textbook_crop_question_links.academy_id
  )
)
with check (
  exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = textbook_crop_question_links.academy_id
  )
);

create or replace function public._textbook_normalize_problem_number(p_text text)
returns text
language sql
immutable
parallel safe
as $$
  select coalesce(
    nullif(
      ltrim(
        regexp_replace(lower(btrim(coalesce(p_text, ''))), '\s+', '', 'g'),
        '0'
      ),
      ''
    ),
    '0'
  );
$$;

create temporary table _crop_question_candidates on commit drop as
with direct_candidates as (
  select
    c.id as crop_id,
    q.id as question_id,
    c.academy_id,
    'legacy_crop_uid'::text as source,
    1.0000::numeric(5,4) as confidence
  from public.textbook_problem_crops c
  join public.pb_questions q
    on q.academy_id = c.academy_id
   and q.question_uid = c.pb_question_uid
  where c.pb_question_uid is not null
),
meta_candidates as (
  select
    c.id,
    q.id,
    c.academy_id,
    'question_meta'::text,
    1.0000::numeric(5,4)
  from public.pb_questions q
  join public.textbook_problem_crops c
    on c.academy_id = q.academy_id
   and q.meta->'textbook_crop_page'->>'crop_id' = c.id::text
  where q.meta->'textbook_crop_page'->>'crop_id' is not null
),
tuple_candidates as (
  select
    c.id,
    q.id,
    c.academy_id,
    'unique_tuple'::text,
    least(greatest(coalesce(q.confidence, 0.9000), 0), 1)::numeric(5,4)
  from public.textbook_problem_crops c
  join public.pb_questions q
    on q.academy_id = c.academy_id
   and q.meta->'textbook_scope'->>'book_id' = c.book_id::text
   and q.meta->'textbook_scope'->>'grade_label' = c.grade_label
   and upper(coalesce(q.meta->'textbook_scope'->>'sub_key', ''))
         = upper(c.sub_key)
   and case
         when q.meta->'textbook_scope'->>'big_order' ~ '^-?[0-9]+$'
         then (q.meta->'textbook_scope'->>'big_order')::integer
       end = c.big_order
   and case
         when q.meta->'textbook_scope'->>'mid_order' ~ '^-?[0-9]+$'
         then (q.meta->'textbook_scope'->>'mid_order')::integer
       end = c.mid_order
   and coalesce(
         case
           when q.meta->'textbook_scope'->>'sub_index' ~ '^[0-9]+$'
           then (q.meta->'textbook_scope'->>'sub_index')::integer
         end,
         0
       ) = coalesce(c.sub_index, 0)
   and public._textbook_normalize_problem_number(q.question_number)
         = public._textbook_normalize_problem_number(c.problem_number)
  where not c.is_set_header
),
all_candidates as (
  select * from direct_candidates
  union all
  select * from meta_candidates
  union all
  select * from tuple_candidates
),
deduplicated as (
  select
    crop_id,
    question_id,
    academy_id,
    case
      when bool_or(source = 'legacy_crop_uid') then 'legacy_crop_uid'
      when bool_or(source = 'question_meta') then 'question_meta'
      else 'unique_tuple'
    end as source,
    max(confidence) as confidence
  from all_candidates
  group by crop_id, question_id, academy_id
),
ranked as (
  select
    d.*,
    count(*) over (partition by crop_id) as crop_count,
    count(*) over (partition by question_id) as question_count
  from deduplicated d
)
select *
from ranked;

insert into public.textbook_crop_question_links (
  crop_id, pb_question_id, academy_id, source, confidence
)
select crop_id, question_id, academy_id, source, confidence
from _crop_question_candidates
where crop_count = 1
  and question_count = 1
on conflict do nothing;

insert into public.textbook_normalization_issues (
  academy_id, book_id, grade_label, issue_key, issue_kind, entity_kind,
  entity_id, candidate_ids, details
)
select
  c.academy_id,
  c.book_id,
  c.grade_label,
  'crop_question_link:' || c.id,
  case when count(distinct cc.question_id) = 0 then 'no_match'
       else 'ambiguous' end,
  'crop_question_link',
  c.id,
  coalesce(
    array_agg(distinct cc.question_id) filter (where cc.question_id is not null),
    array[]::uuid[]
  ),
  jsonb_build_object(
    'problem_number', c.problem_number,
    'big_order', c.big_order,
    'mid_order', c.mid_order,
    'sub_key', c.sub_key,
    'sub_index', c.sub_index
  )
from public.textbook_problem_crops c
left join _crop_question_candidates cc on cc.crop_id = c.id
left join public.textbook_crop_question_links link on link.crop_id = c.id
where not c.is_set_header
  and link.crop_id is null
group by c.id
on conflict (issue_key) do nothing;

-- ---------------------------------------------------------------------------
-- 8) Student-safe schema v2 RPCs
-- ---------------------------------------------------------------------------

create or replace function public.textbook_resolved_unit_tree(
  p_book_id uuid,
  p_grade_label text
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  v_series text;
  v_page_offset integer;
  v_units jsonb;
  v_categories jsonb;
begin
  select i.academy_id, i.student_id
    into v_academy, v_student
  from public.student_app_identity() i;

  if v_student is null then
    raise exception 'no student account';
  end if;

  select
    lower(coalesce(tm.payload->>'series', '')),
    tm.page_offset
  into v_series, v_page_offset
  from public.textbook_metadata tm
  where tm.academy_id = v_academy
    and tm.book_id = p_book_id
    and tm.grade_label = p_grade_label;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'code', pc.category_code,
        'label', pc.display_label,
        'order_index', pc.order_index
      ) order by pc.order_index
    ),
    '[]'::jsonb
  )
  into v_categories
  from public.textbook_problem_categories pc
  where pc.series_key = v_series
    and pc.is_active;

  with page_stats as (
    select
      c.unit_id,
      c.raw_page,
      max(c.display_page) as display_page,
      count(*) filter (where held.crop_id is null) as total,
      count(r.id) filter (where held.crop_id is null) as graded,
      count(r.id) filter (
        where r.is_correct and held.crop_id is null
      ) as correct,
      count(*) filter (where held.crop_id is not null) as reported
    from public.textbook_problem_crops c
    join public.textbook_problem_answers a on a.crop_id = c.id
    left join public.student_textbook_answer_records r
      on r.crop_id = c.id
     and r.student_id = v_student
    left join lateral (
      select report.crop_id
      from public.student_textbook_problem_reports report
      where report.student_id = v_student
        and report.crop_id = c.id
        and report.status in ('open', 'accepted')
      limit 1
    ) held on true
    where c.academy_id = v_academy
      and c.book_id = p_book_id
      and c.grade_label = p_grade_label
      and c.unit_id is not null
      and not c.is_set_header
      and (
        (
          a.answer_kind in ('objective', 'subjective')
          and coalesce(a.answer_text, a.answer_latex_2d) is not null
        )
        or a.answer_kind = 'image'
      )
    group by c.unit_id, c.raw_page
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', big.id,
        'unit_key', big.unit_key,
        'name', big.name,
        'order_index', big.order_index,
        'start_page', big.display_start_page,
        'end_page', big.display_end_page,
        'mids', (
          select coalesce(
            jsonb_agg(
              jsonb_build_object(
                'id', mid.id,
                'unit_key', mid.unit_key,
                'name', mid.name,
                'order_index', mid.order_index,
                'start_page', mid.display_start_page,
                'end_page', mid.display_end_page,
                'smalls', (
                  select coalesce(
                    jsonb_agg(
                      jsonb_build_object(
                        'id', small.id,
                        'unit_key', small.unit_key,
                        'name', small.name,
                        'order_index', small.order_index,
                        'legacy_sub_key', small.legacy_sub_key,
                        'start_page', small.display_start_page,
                        'end_page', small.display_end_page,
                        'pages', (
                          select coalesce(
                            jsonb_agg(
                              jsonb_build_object(
                                'raw_page', ps.raw_page,
                                'display_page', ps.display_page,
                                'total', ps.total,
                                'graded', ps.graded,
                                'correct', ps.correct,
                                'reported', ps.reported
                              )
                              order by ps.raw_page
                            ),
                            '[]'::jsonb
                          )
                          from page_stats ps
                          where ps.unit_id = small.id
                        )
                      )
                      order by small.order_index, small.id
                    ),
                    '[]'::jsonb
                  )
                  from public.textbook_units small
                  where small.parent_id = mid.id
                    and small.unit_level = 'small'
                )
              )
              order by mid.order_index, mid.id
            ),
            '[]'::jsonb
          )
          from public.textbook_units mid
          where mid.parent_id = big.id
            and mid.unit_level = 'mid'
        )
      )
      order by big.order_index, big.id
    ),
    '[]'::jsonb
  )
  into v_units
  from public.textbook_units big
  where big.academy_id = v_academy
    and big.book_id = p_book_id
    and big.grade_label = p_grade_label
    and big.unit_level = 'big';

  return jsonb_build_object(
    'schema_version', 2,
    'book_id', p_book_id,
    'grade_label', p_grade_label,
    'series', coalesce(v_series, ''),
    'page_offset', v_page_offset,
    'categories', coalesce(v_categories, '[]'::jsonb),
    'category_catalog', coalesce(v_categories, '[]'::jsonb),
    'units', coalesce(v_units, '[]'::jsonb)
  );
end;
$$;

revoke all on function public.textbook_resolved_unit_tree(uuid, text)
  from public;
grant execute on function public.textbook_resolved_unit_tree(uuid, text)
  to authenticated;

-- The current page-problems signature is already consumed by the student app.
-- Keep it intact and expose category additions through a separately named RPC.
create or replace function public.student_textbook_page_problems_v2(
  p_book_id uuid,
  p_grade_label text,
  p_raw_page integer
) returns table(
  crop_id uuid,
  problem_number text,
  label text,
  answer_kind text,
  grading_mode text,
  my_answer text,
  my_correct boolean,
  attempt_count integer,
  graded_by text,
  flags text[],
  report_status text,
  set_parts jsonb,
  part_results jsonb,
  category_code text,
  category_label text,
  item_name text
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
begin
  select i.academy_id, i.student_id
    into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  return query
  select
    c.id,
    c.problem_number,
    c.label,
    a.answer_kind,
    public._student_grading_mode(
      a.answer_kind, coalesce(a.answer_text, a.answer_latex_2d)
    ),
    r.last_answer,
    r.is_correct,
    r.attempt_count,
    r.graded_by,
    r.flags,
    report.status,
    case when a.answer_kind = 'subjective' then (
      select jsonb_agg(
        jsonb_build_object(
          'key', part ->> 'key',
          'mode', public._student_grading_mode(
            'subjective', part ->> 'text'
          )
        )
      )
      from jsonb_array_elements(
        public._split_set_answer_parts(
          coalesce(a.answer_text, a.answer_latex_2d)
        )
      ) part
    ) end,
    r.part_results,
    c.category_code,
    pc.display_label,
    nullif(btrim(c.item_name), '')
  from public.textbook_problem_crops c
  join public.textbook_problem_answers a on a.crop_id = c.id
  left join public.student_textbook_answer_records r
    on r.crop_id = c.id
   and r.student_id = v_student
  left join public.textbook_metadata tm
    on tm.academy_id = c.academy_id
   and tm.book_id = c.book_id
   and tm.grade_label = c.grade_label
  left join public.textbook_problem_categories pc
    on pc.series_key = lower(coalesce(tm.payload->>'series', ''))
   and pc.category_code = c.category_code
  left join lateral (
    select s.status
    from public.student_textbook_problem_reports s
    where s.student_id = v_student
      and s.crop_id = c.id
    order by
      case s.status when 'open' then 0 when 'accepted' then 1 else 2 end,
      s.created_at desc
    limit 1
  ) report on true
  where c.academy_id = v_academy
    and c.book_id = p_book_id
    and c.grade_label = p_grade_label
    and c.raw_page = p_raw_page
    and not c.is_set_header
    and (
      (
        a.answer_kind in ('objective', 'subjective')
        and coalesce(a.answer_text, a.answer_latex_2d) is not null
      )
      or a.answer_kind = 'image'
    )
  order by
    case when c.problem_number ~ '^\d+$'
      then c.problem_number::integer else 2147483647 end,
    c.problem_number;
end;
$$;

revoke all on function
  public.student_textbook_page_problems_v2(uuid, text, integer)
  from public;
grant execute on function
  public.student_textbook_page_problems_v2(uuid, text, integer)
  to authenticated;

-- Normalized staff coverage. The legacy coverage RPC remains unchanged.
create or replace function public.staff_textbook_normalization_coverage(
  p_book_id uuid default null,
  p_grade_label text default null
) returns table(
  academy_id uuid,
  total_crops bigint,
  unit_mapped_crops bigint,
  canonical_linked_crops bigint,
  fully_normalized_crops bigint,
  unresolved_unit_issues bigint,
  unresolved_link_issues bigint
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_academy uuid;
begin
  select m.academy_id into v_academy
  from public.memberships m
  where m.user_id = auth.uid()
    and m.role in ('owner', 'staff')
  order by (m.role = 'owner') desc
  limit 1;

  if v_academy is null then
    raise exception 'staff membership required' using errcode = '42501';
  end if;

  return query
  with crops as (
    select c.id, c.unit_id, link.crop_id as linked_crop_id
    from public.textbook_problem_crops c
    left join public.textbook_crop_question_links link on link.crop_id = c.id
    where c.academy_id = v_academy
      and not c.is_set_header
      and (p_book_id is null or c.book_id = p_book_id)
      and (p_grade_label is null or c.grade_label = p_grade_label)
  ),
  issues as (
    select
      count(*) filter (where i.entity_kind = 'crop_unit')::bigint
        as unit_issues,
      count(*) filter (where i.entity_kind = 'crop_question_link')::bigint
        as link_issues
    from public.textbook_normalization_issues i
    where i.academy_id = v_academy
      and i.resolved_at is null
      and (p_book_id is null or i.book_id = p_book_id)
      and (p_grade_label is null or i.grade_label = p_grade_label)
  )
  select
    v_academy,
    count(c.id)::bigint,
    count(c.id) filter (where c.unit_id is not null)::bigint,
    count(c.id) filter (where c.linked_crop_id is not null)::bigint,
    count(c.id) filter (
      where c.unit_id is not null and c.linked_crop_id is not null
    )::bigint,
    coalesce(max(i.unit_issues), 0)::bigint,
    coalesce(max(i.link_issues), 0)::bigint
  from crops c
  cross join issues i;
end;
$$;

revoke all on function
  public.staff_textbook_normalization_coverage(uuid, text)
  from public;
grant execute on function
  public.staff_textbook_normalization_coverage(uuid, text)
  to authenticated, service_role;

grant select on public.textbook_problem_categories to authenticated;
grant all on public.textbook_units to service_role;
grant all on public.textbook_problem_categories to service_role;
grant all on public.textbook_crop_question_links to service_role;
grant all on public.textbook_normalization_issues to service_role;

