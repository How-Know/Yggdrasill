-- 수능(csat) 문항 가운데 그림이 붙은 문항과 그 그림 자리.
-- tool/reference/extract_originals.dart 가 읽는 입력을 만든다.
--   supabase db query --linked -f tool/reference/csat_figures.sql > reference/work/csat_rows.json
select
  e.exam_year,
  i.section,
  i.problem_number,
  i.id as item_id,
  i.same_as_item_id,
  i.raw_page,
  i.item_region_1k,
  p.elective,
  p.file_name,
  i.pb_question_id,
  pq.stem,
  pq.choices,
  pq.meta -> 'figure_assets' as figure_assets,
  pq.meta -> 'figure_layout' as figure_layout
from public.mock_exams e
join public.mock_exam_items i on i.exam_id = e.id
join public.mock_exam_papers p on p.id = i.paper_id
join public.pb_questions pq on pq.id = i.pb_question_id
where e.org = 'csat'
  and jsonb_typeof(pq.meta -> 'figure_assets') = 'array'
  and jsonb_array_length(pq.meta -> 'figure_assets') > 0
order by e.exam_year, i.section, i.problem_number;
