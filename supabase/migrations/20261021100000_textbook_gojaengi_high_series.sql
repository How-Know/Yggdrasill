-- 고쟁이 고등 시리즈의 문제 카테고리 카탈로그를 등록한다.
--
-- 중등 고쟁이와 번호 체계(본문 전체를 관통하는 세 자리 연속 번호)와 STEP1~3
-- 구성은 같지만 창의융합 유형과 워크북(중단원·대단원 TEST)이 없어 세 칸만 쓴다:
--   A STEP1 핵심 유형    — 초록 "유형 NN" 배지 아래로 이어진다.
--   B STEP2 심화 유형    — 빨간 "유형 NN" 배지. 사이에 스키마 해설 지면(문항
--                          없음)이 끼어 있다.
--   C STEP3 최고난도 유형 — 유형 배지가 없다. 번호만 이어진다.
--
-- 문항 라벨은 별표 대신 빈출 / 서술형 / 선생님 Pick / 평가원·교육청 기출·변형
-- 배지이고, 정답·해설 파일 모두 본문 쪽 배지 없이 세 자리 번호로만 짚인다.

insert into public.textbook_problem_categories (
  series_key, category_code, display_label, order_index, description
) values
  ('gojaengi_high', 'A', 'STEP1 핵심 유형', 0, '교과서를 정복하는 핵심 유형'),
  ('gojaengi_high', 'B', 'STEP2 심화 유형', 1, '내신 실전문제 체화를 위한 심화 유형'),
  ('gojaengi_high', 'C', 'STEP3 최고난도 유형', 2, '내신 최상위권 굳히기를 위한 최고난도 유형')
on conflict (series_key, category_code) do update
set display_label = excluded.display_label,
    order_index = excluded.order_index,
    description = excluded.description,
    is_active = true;
