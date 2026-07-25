-- Seed the missing 확률과 통계 「순열과 조합」 특강 preface unit (pages 10-14).
-- The 특강 pages were never extracted (no E crops, no payload sub_unit), so the
-- tree started at 중복순열 (page 15). This inserts the structural node so all
-- apps render 특강 before 소단원 1. Problems get attached later when the
-- manager re-runs VLM extraction (textbook_rebuild_special_units merges them).

with target_mid as (
  select mid.id, mid.academy_id, mid.book_id, mid.grade_label
  from public.textbook_units mid
  join public.textbook_metadata tm
    on tm.academy_id = mid.academy_id
   and tm.book_id = mid.book_id
   and tm.grade_label = mid.grade_label
  where mid.book_id = 'c3f55a9c-4c87-4c89-8f08-abe9cd35ea72'
    and mid.unit_level = 'mid'
    and mid.unit_key = 'B:0/M:0'
    and lower(coalesce(tm.payload->>'series', '')) = 'wonri'
    and (mid.grade_label ~ '(확률.*통계|확통)'
         or tm.payload::text ~ '(확률.*통계|확통)')
    and exists (
      select 1 from public.textbook_units u0
      where u0.parent_id = mid.id
        and u0.unit_level = 'small'
        and u0.unit_key = 'B:0/M:0/U:0'
        and u0.display_start_page = 15
    )
    and not exists (
      select 1 from public.textbook_units e
      where e.parent_id = mid.id
        and e.unit_level = 'small'
        and e.unit_key like '%/SPECIAL:E%'
    )
)
insert into public.textbook_units (
  academy_id, book_id, grade_label, parent_id, unit_level, order_index,
  unit_key, name, display_start_page, display_end_page, legacy_sub_key
)
select
  t.academy_id, t.book_id, t.grade_label, t.id, 'small', -1,
  'B:0/M:0/SPECIAL:E', '특강', 10, 14, null
from target_mid t;

-- Move current child orders out of the way before re-ranking, avoiding the
-- unique (parent_id, unit_level, order_index) index during the transition.
update public.textbook_units u
set order_index = u.order_index + 100000
where u.unit_level = 'small'
  and u.parent_id in (
    select mid.id
    from public.textbook_units mid
    where mid.book_id = 'c3f55a9c-4c87-4c89-8f08-abe9cd35ea72'
      and mid.unit_level = 'mid'
      and mid.unit_key = 'B:0/M:0'
      and exists (
        select 1 from public.textbook_units e
        where e.parent_id = mid.id
          and e.unit_key = 'B:0/M:0/SPECIAL:E'
      )
  );

-- Re-rank children by physical page (special preface wins the tie -> before U:0).
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
    and u.parent_id in (
      select mid.id
      from public.textbook_units mid
      where mid.book_id = 'c3f55a9c-4c87-4c89-8f08-abe9cd35ea72'
        and mid.unit_level = 'mid'
        and mid.unit_key = 'B:0/M:0'
        and exists (
          select 1 from public.textbook_units e
          where e.parent_id = mid.id
            and e.unit_key = 'B:0/M:0/SPECIAL:E'
        )
    )
)
update public.textbook_units u
set order_index = ranked.next_order
from ranked
where u.id = ranked.id;

-- Recompute mid/big display ranges to include the new preface page.
update public.textbook_units mid
set display_start_page = ranges.lo,
    display_end_page = ranges.hi
from (
  select
    child.parent_id,
    min(child.display_start_page) as lo,
    max(coalesce(child.display_end_page, child.display_start_page)) as hi
  from public.textbook_units child
  where child.unit_level = 'small'
  group by child.parent_id
) ranges
where mid.id = ranges.parent_id
  and mid.unit_level = 'mid'
  and mid.book_id = 'c3f55a9c-4c87-4c89-8f08-abe9cd35ea72';

update public.textbook_units big
set display_start_page = ranges.lo,
    display_end_page = ranges.hi
from (
  select
    child.parent_id,
    min(child.display_start_page) as lo,
    max(child.display_end_page) as hi
  from public.textbook_units child
  where child.unit_level = 'mid'
  group by child.parent_id
) ranges
where big.id = ranges.parent_id
  and big.unit_level = 'big'
  and big.book_id = 'c3f55a9c-4c87-4c89-8f08-abe9cd35ea72';
