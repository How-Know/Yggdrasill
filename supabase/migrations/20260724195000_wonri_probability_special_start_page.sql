-- Data correction for 개념원리 확률과 통계.
-- The TOC parser previously discarded the "특강" row at printed page 10, so
-- normalization could only infer page 15 (the first detected E problem).

update public.textbook_units special
set display_start_page = 10
where special.unit_level = 'small'
  and special.unit_key like '%/SPECIAL:E%'
  and special.display_start_page = 15
  and special.grade_label ~ '확률.*통계'
  and exists (
    select 1
    from public.textbook_metadata tm
    where tm.academy_id = special.academy_id
      and tm.book_id = special.book_id
      and tm.grade_label = special.grade_label
      and lower(coalesce(tm.payload->>'series', '')) = 'wonri'
  );

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
  and mid.unit_level = 'mid';

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
  and big.unit_level = 'big';
