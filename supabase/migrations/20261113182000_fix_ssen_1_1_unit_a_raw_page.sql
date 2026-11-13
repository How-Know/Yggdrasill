-- 쎈 1-1 1단원 A 기본다잡기(0_0_A)의 raw_page가 +2(11, 12)로 잘못 저장되어
-- 원본 보기에서 p.9를 열면 실제 PDF 11쪽(B단계)이 열리던 문제를 수정한다.
-- 실제 PDF(body.pdf) 9쪽 = 0001~0026, 10쪽 = 0027~0052 이다.

with fixed_crops as (
  update public.textbook_problem_crops c
  set raw_page = c.display_page
  where c.book_id = 'c3ae29ad-4d99-4078-8381-00357074d151'
    and c.grade_label = '1-1'
    and c.big_order = 0
    and c.mid_order = 0
    and c.sub_key = 'A'
    and c.display_page in (9, 10)
    and c.raw_page = c.display_page + 2
  returning c.id, c.academy_id, c.pb_question_uid, c.display_page
),
updated_pb as (
  update public.pb_questions q
  set meta = jsonb_set(
    q.meta,
    '{textbook_crop_page,raw_page}',
    to_jsonb(fc.display_page),
    true
  )
  from fixed_crops fc
  where q.academy_id = fc.academy_id
    and q.question_uid = fc.pb_question_uid
    and coalesce((q.meta->'textbook_crop_page'->>'raw_page')::int, -1) <> fc.display_page
  returning q.id
)
update public.learning_exposures e
set raw_page = fc.display_page
from fixed_crops fc
where e.crop_id = fc.id
  and e.raw_page = fc.display_page + 2;

update public.textbook_metadata
set page_offset = 0
where book_id = 'c3ae29ad-4d99-4078-8381-00357074d151'
  and grade_label = '1-1'
  and page_offset = 2;
