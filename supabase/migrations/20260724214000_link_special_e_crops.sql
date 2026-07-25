-- Link re-extracted 특강(E) crops to their SPECIAL:E small unit.
-- Re-extraction created E crops (sub_key='E') but left unit_id/category_code
-- unset, so textbook_resolved_unit_tree returned no pages for the special unit
-- and the student parser dropped the (page-empty) node -> tree started at 15.

update public.textbook_problem_crops c
set unit_id = u.id,
    category_code = 'E'
from public.textbook_units u
where u.unit_level = 'small'
  and u.unit_key like '%/SPECIAL:E'
  and c.academy_id = u.academy_id
  and c.book_id = u.book_id
  and c.grade_label = u.grade_label
  and ('B:' || c.big_order || '/M:' || c.mid_order || '/SPECIAL:E') = u.unit_key
  and upper(btrim(coalesce(c.category_code, c.sub_key, ''))) = 'E'
  and c.unit_id is distinct from u.id;

update public.textbook_pb_extract_runs r
set unit_id = u.id,
    category_code = 'E'
from public.textbook_units u
where u.unit_level = 'small'
  and u.unit_key like '%/SPECIAL:E'
  and r.academy_id = u.academy_id
  and r.book_id = u.book_id
  and r.grade_label = u.grade_label
  and ('B:' || r.big_order || '/M:' || r.mid_order || '/SPECIAL:E') = u.unit_key
  and upper(btrim(coalesce(r.category_code, r.sub_key, ''))) = 'E'
  and r.unit_id is distinct from u.id;
