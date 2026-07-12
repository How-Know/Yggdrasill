-- 20260712000000: 개념서(개념원리) 문항이름 컬럼
--
-- 개념서는 쎈/RPM 같은 난이도(label)가 없고, 대신 문항마다 "문항이름"이 있다:
--   개념원리 익히기 / 필수유형 / 확인 체크 /
--   연습문제(STEP1 / STEP2 / 실력 UP / 수능 기출 / 평가원 기출 / 교육청 기출)
-- 난이도(label) 컬럼과 섞지 않도록 전용 컬럼(item_name)에 저장한다.
-- 난이도가 있는 시리즈(쎈/RPM)는 빈 문자열로 둔다.

alter table public.textbook_problem_crops
  add column if not exists item_name text not null default '';

comment on column public.textbook_problem_crops.item_name is
  '개념서 문항이름(개념원리 익히기 / 필수유형 / 확인 체크 / STEP1 등). 난이도(label)와 별개.';
