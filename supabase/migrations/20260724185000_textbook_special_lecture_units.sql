-- Make wonri special lectures (legacy category E) first-class small units.
--
-- The source payload intentionally keeps E outside middles[].sub_units, so the
-- initial textbook_units normalization omitted it. App-side trees then
-- disagreed: the learning app could infer E from crop rows while the student
-- RPC only returned normalized textbook_units.

create temporary table _wonri_special_units on commit drop as
with special_rows as (
  select
    c.academy_id,
    c.book_id,
    c.grade_label,
    c.big_order,
    c.mid_order,
    coalesce(c.sub_index, 0) as sub_index,
    min(c.display_page) filter (where c.display_page is not null) as start_page,
    max(c.display_page) filter (where c.display_page is not null) as end_page
  from public.textbook_problem_crops c
  join public.textbook_metadata tm
    on tm.academy_id = c.academy_id
   and tm.book_id = c.book_id
   and tm.grade_label = c.grade_label
  where lower(coalesce(tm.payload->>'series', '')) = 'wonri'
    and upper(btrim(coalesce(c.category_code, c.sub_key, ''))) = 'E'
  group by
    c.academy_id, c.book_id, c.grade_label,
    c.big_order, c.mid_order, coalesce(c.sub_index, 0)
)
select
  r.*,
  mid.id as parent_id,
  mid.unit_key || '/SPECIAL:E:' || r.sub_index as unit_key
from special_rows r
join public.textbook_units mid
  on mid.academy_id = r.academy_id
 and mid.book_id = r.book_id
 and mid.grade_label = r.grade_label
 and mid.unit_level = 'mid'
 and mid.unit_key = 'B:' || r.big_order || '/M:' || r.mid_order
where r.start_page is not null;

-- Move current child orders away before inserting/reordering, avoiding the
-- unique (parent_id, unit_level, order_index) index during the transition.
update public.textbook_units u
set order_index = u.order_index + 100000
where u.unit_level = 'small'
  and exists (
    select 1
    from _wonri_special_units s
    where s.parent_id = u.parent_id
  );

insert into public.textbook_units (
  academy_id,
  book_id,
  grade_label,
  parent_id,
  unit_level,
  order_index,
  unit_key,
  name,
  display_start_page,
  display_end_page,
  legacy_sub_key
)
select
  s.academy_id,
  s.book_id,
  s.grade_label,
  s.parent_id,
  'small',
  -100000 - s.sub_index,
  s.unit_key,
  '특강',
  s.start_page,
  coalesce(s.end_page, s.start_page),
  null
from _wonri_special_units s
on conflict (academy_id, book_id, grade_label, unit_key) do update
set parent_id = excluded.parent_id,
    name = excluded.name,
    display_start_page = excluded.display_start_page,
    display_end_page = excluded.display_end_page;

-- Physical page order is the canonical display order. A special unit wins a
-- tie so a preface special appears before 소단원 1.
with ranked as (
  select
    u.id,
    row_number() over (
      partition by u.parent_id
      order by
        u.display_start_page nulls last,
        case when u.unit_key like '%/SPECIAL:E:%' then 0 else 1 end,
        u.display_end_page nulls last,
        u.unit_key
    )::integer - 1 as next_order
  from public.textbook_units u
  where u.unit_level = 'small'
    and exists (
      select 1
      from _wonri_special_units s
      where s.parent_id = u.parent_id
    )
)
update public.textbook_units u
set order_index = ranked.next_order
from ranked
where u.id = ranked.id;

-- E crops belong to the synthetic special unit instead of the neighboring
-- page-range subunit.
update public.textbook_problem_crops c
set unit_id = u.id,
    category_code = 'E'
from _wonri_special_units s
join public.textbook_units u
  on u.academy_id = s.academy_id
 and u.book_id = s.book_id
 and u.grade_label = s.grade_label
 and u.unit_key = s.unit_key
where c.academy_id = s.academy_id
  and c.book_id = s.book_id
  and c.grade_label = s.grade_label
  and c.big_order = s.big_order
  and c.mid_order = s.mid_order
  and coalesce(c.sub_index, 0) = s.sub_index
  and upper(btrim(coalesce(c.category_code, c.sub_key, ''))) = 'E';

update public.textbook_pb_extract_runs r
set unit_id = u.id,
    category_code = 'E'
from _wonri_special_units s
join public.textbook_units u
  on u.academy_id = s.academy_id
 and u.book_id = s.book_id
 and u.grade_label = s.grade_label
 and u.unit_key = s.unit_key
where r.academy_id = s.academy_id
  and r.book_id = s.book_id
  and r.grade_label = s.grade_label
  and r.big_order = s.big_order
  and r.mid_order = s.mid_order
  and coalesce(r.sub_index, 0) = s.sub_index
  and upper(btrim(coalesce(r.category_code, r.sub_key, ''))) = 'E';

-- Recompute parent ranges after inserting the special preface.
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
