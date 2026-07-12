-- 20260713000000: 개념서(개념원리) 소단원 차원(sub_index)
--
-- 개념원리 필수유형(B)은 소단원마다 번호(01,02...)가 새로 시작한다.
-- 기존 저장 구조는 (대단원, 중단원, sub_key)까지만 구분하고 소단원 차원이
-- 없어서, 한 중단원에 소단원이 여러 개면 필수유형이 서로 덮어써지고,
-- 문제은행 추출 문서 안에서도 번호가 중복됐다.
--
-- 이를 해결하기 위해 크롭/추출런 테이블에 sub_index 컬럼을 추가한다.
--   - 필수유형(B): sub_index = 소단원 순번(중단원 내 0-based). 소단원별로 분리.
--   - 그 외(A 개념원리 익히기 / C 확인 체크 / D 연습문제, 쎈/RPM): sub_index = 0.
--     (이들은 중단원 내 연속 번호라 소단원 분리가 필요 없다.)
-- 기존 행은 default 0 으로 채워지므로 유일성이 그대로 보존된다.

-- ─────────────────────────────────────────────────────────────────────────
-- textbook_problem_crops
-- ─────────────────────────────────────────────────────────────────────────
alter table public.textbook_problem_crops
  add column if not exists sub_index int not null default 0;

comment on column public.textbook_problem_crops.sub_index is
  '개념원리 소단원 순번(필수유형 B 전용, 중단원 내 0-based). 그 외 시리즈/카테고리는 0.';

alter table public.textbook_problem_crops
  drop constraint if exists textbook_problem_crops_canon_uk;
alter table public.textbook_problem_crops
  add constraint textbook_problem_crops_canon_uk
  unique (academy_id, book_id, grade_label, big_order, mid_order,
          sub_key, sub_index, problem_number);

-- ─────────────────────────────────────────────────────────────────────────
-- textbook_pb_extract_runs
-- ─────────────────────────────────────────────────────────────────────────
alter table public.textbook_pb_extract_runs
  add column if not exists sub_index int not null default 0;

comment on column public.textbook_pb_extract_runs.sub_index is
  '개념원리 소단원 순번(필수유형 B 전용, 중단원 내 0-based). 그 외는 0.';

alter table public.textbook_pb_extract_runs
  drop constraint if exists textbook_pb_extract_runs_scope_uk;
alter table public.textbook_pb_extract_runs
  add constraint textbook_pb_extract_runs_scope_uk
  unique (academy_id, book_id, grade_label, big_order, mid_order,
          sub_key, sub_index);
