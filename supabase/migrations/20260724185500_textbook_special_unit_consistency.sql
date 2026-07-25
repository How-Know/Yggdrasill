-- Keep the app contract at one special-lecture node per middle unit.
-- Legacy E rows can carry different sub_index values, but the learning app
-- intentionally presents them as one physical "특강" section.

create temporary table _wonri_special_by_mid on commit drop as
select
  c.academy_id,
  c.book_id,
  c.grade_label,
  c.big_order,
  c.mid_order,
  min(c.display_page) filter (where c.display_page is not null) as start_page,
  max(c.display_page) filter (where c.display_page is not null) as end_page,
  mid.id as parent_id,
  mid.unit_key || '/SPECIAL:E' as unit_key
from public.textbook_problem_crops c
join public.textbook_metadata tm
  on tm.academy_id = c.academy_id
 and tm.book_id = c.book_id
 and tm.grade_label = c.grade_label
join public.textbook_units mid
  on mid.academy_id = c.academy_id
 and mid.book_id = c.book_id
 and mid.grade_label = c.grade_label
 and mid.unit_level = 'mid'
 and mid.unit_key = 'B:' || c.big_order || '/M:' || c.mid_order
where lower(coalesce(tm.payload->>'series', '')) = 'wonri'
  and upper(btrim(coalesce(c.category_code, c.sub_key, ''))) = 'E'
group by
  c.academy_id, c.book_id, c.grade_label,
  c.big_order, c.mid_order, mid.id, mid.unit_key;

update public.textbook_units u
set order_index = u.order_index + 100000
where u.unit_level = 'small'
  and exists (
    select 1
    from _wonri_special_by_mid s
    where s.parent_id = u.parent_id
  );

delete from public.textbook_units u
where u.unit_level = 'small'
  and u.unit_key like '%/SPECIAL:E%'
  and exists (
    select 1
    from _wonri_special_by_mid s
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
  -100000,
  s.unit_key,
  '특강',
  s.start_page,
  coalesce(s.end_page, s.start_page),
  null
from _wonri_special_by_mid s
where s.start_page is not null;

with ranked as (
  select
    u.id,
    row_number() over (
      partition by u.parent_id
      order by
        u.display_start_page nulls last,
        case when u.unit_key like '%/SPECIAL:E%' then 0 else 1 end,
        u.display_end_page nulls last,
        u.unit_key
    )::integer - 1 as next_order
  from public.textbook_units u
  where u.unit_level = 'small'
    and exists (
      select 1
      from _wonri_special_by_mid s
      where s.parent_id = u.parent_id
    )
)
update public.textbook_units u
set order_index = ranked.next_order
from ranked
where u.id = ranked.id;

update public.textbook_problem_crops c
set unit_id = u.id,
    category_code = 'E'
from _wonri_special_by_mid s
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
  and upper(btrim(coalesce(c.category_code, c.sub_key, ''))) = 'E';

update public.textbook_pb_extract_runs r
set unit_id = u.id,
    category_code = 'E'
from _wonri_special_by_mid s
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
  and upper(btrim(coalesce(r.category_code, r.sub_key, ''))) = 'E';
