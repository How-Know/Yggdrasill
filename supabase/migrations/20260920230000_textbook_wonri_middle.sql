-- 중등 개념원리(wonri_middle) 추출 지원.
--
-- A 개념원리 확인하기 / B 핵심문제 익히기 / C 시험문제 /
-- D 중단원 마무리 / E 서술형 대비 / F 계산력 강화(선택).

insert into public.textbook_problem_categories (
  series_key, category_code, display_label, order_index, description
) values
  ('wonri_middle', 'A', '개념원리 확인하기', 0, '개념 설명 뒤 확인 문항'),
  ('wonri_middle', 'B', '핵심문제 익히기', 1, '대표 예제 및 확인 문항'),
  ('wonri_middle', 'C', '이런 문제가 시험에 나온다', 2, '학교 시험 대비 문항'),
  ('wonri_middle', 'D', '중단원 마무리하기', 3, 'STEP 1~3 중단원 마무리'),
  ('wonri_middle', 'E', '서술형 대비 문제', 4, '배정 가능한 예시 및 실전 서술형'),
  ('wonri_middle', 'F', '계산력 강화하기', 5, '실제 등장한 소단원에만 붙는 선택 코너')
on conflict (series_key, category_code) do update
set display_label = excluded.display_label,
    order_index = excluded.order_index,
    description = excluded.description,
    is_active = true;

-- 문제 본문에서 분리한 KEY POINT/힌트/참고 영역.
alter table public.textbook_problem_crops
  add column if not exists companion_regions jsonb not null default '[]'::jsonb;

alter table public.textbook_problem_crops
  drop constraint if exists textbook_problem_crops_companion_regions_chk;
alter table public.textbook_problem_crops
  add constraint textbook_problem_crops_companion_regions_chk
  check (jsonb_typeof(companion_regions) = 'array');

comment on column public.textbook_problem_crops.companion_regions is
  '문항 본문과 분리된 보조 영역 배열: '
  '[{kind:key_point|hint|reference,bbox:[ymin,xmin,ymax,xmax],text:string}]';

-- 해설 PDF에서 정답과 함께 읽은 서술형 단계·배점 및 부가 구조.
alter table public.textbook_problem_answers
  add column if not exists rubric_steps jsonb not null default '[]'::jsonb,
  add column if not exists solution_metadata jsonb not null default '{}'::jsonb;

alter table public.textbook_problem_answers
  drop constraint if exists textbook_problem_answers_rubric_steps_chk,
  drop constraint if exists textbook_problem_answers_solution_metadata_chk;
alter table public.textbook_problem_answers
  add constraint textbook_problem_answers_rubric_steps_chk
    check (jsonb_typeof(rubric_steps) = 'array'),
  add constraint textbook_problem_answers_solution_metadata_chk
    check (jsonb_typeof(solution_metadata) = 'object');

comment on column public.textbook_problem_answers.rubric_steps is
  '서술형 해설의 단계·배점 배열: [{step,label,text,points}]';
comment on column public.textbook_problem_answers.solution_metadata is
  '통합 해설 추출 부가 정보(solution_kind, total_points, item_role 등)';

-- 과제 시간 초기값. 학원마다 존재하는 설정 행을 시리즈 카탈로그처럼 채운다.
insert into public.homework_time_defaults (
  academy_id, series_key, school_level_key, category_key, seconds_per_unit
)
select
  a.id,
  'wonri_middle',
  'middle',
  seed.category_key,
  seed.seconds_per_unit
from public.academies a
cross join (
  values
    ('middle_concept_check', 60),
    ('middle_core_problem', 120),
    ('middle_exam_problem', 150),
    ('middle_unit_review', 150),
    ('middle_descriptive', 240),
    ('middle_calculation', 60)
) as seed(category_key, seconds_per_unit)
on conflict (academy_id, series_key, school_level_key, category_key)
do nothing;
