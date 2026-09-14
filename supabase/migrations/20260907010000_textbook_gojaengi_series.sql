-- 고쟁이 시리즈의 문제 카테고리 카탈로그를 등록한다.
--
-- 쎈과 같은 문제집이라 대-중단원 아래에 고정 슬롯을 두지만, 단계가 셋이 아니라
-- 넷이고 워크북이 따로 붙어 여섯 칸을 쓴다:
--   A STEP1 핵심 유형    — "핵심 NN"(주황) / "발전 NN"(보라) 유형 배지 아래로
--                          이어진다. 첫 문항에 "대표 문제" 라벨이 붙는다.
--   B STEP2 심화 유형    — "유형 NN"(빨강) 배지. 앞에 대표 문항 + 스키마 해설
--                          지면이 한두 쪽 붙고(문항 없음), 끝에 서술형 문항이
--                          두세 개 이어진다.
--   C STEP3 최고난도 유형 — 유형 배지가 없다. 번호만 이어진다.
--   D 창의융합 유형      — 문항마다 "창의융합 ❶ <유형명>" 배지가 따로 붙는다.
--   E 중단원 TEST        — 워크북 앞부분. 중단원마다 네 쪽씩 하나.
--   F 대단원 TEST        — 워크북 뒷부분. 대단원 하나를 통틀어 다루므로 대단원
--                          끝에 "대단원 TEST" 중단원 행을 하나 만들어 담는다.
--
-- 문항 번호는 본문(A~D)에서 책 전체를 관통하는 세 자리 연속 번호이고(054 →
-- 634), 워크북(E·F)에서는 묶음마다 01 부터 다시 시작한다. 그래서 본문은 번호
-- 하나로 정답·해설이 유일하게 짚이고, 워크북은 슬롯과 단원까지 함께 봐야 한다.
--
-- 소단원 첫 개념 지면과 STEP2 스키마 지면, 대단원 도입 지면은 문항이 없는
-- 개념 지면이라 카테고리가 없다.

insert into public.textbook_problem_categories (
  series_key, category_code, display_label, order_index, description
) values
  ('gojaengi', 'A', 'STEP1 핵심 유형', 0, '교과서를 정복하는 핵심 유형 (핵심·발전 배지)'),
  ('gojaengi', 'B', 'STEP2 심화 유형', 1, '실전문제 체화를 위한 심화 유형 (서술형 포함)'),
  ('gojaengi', 'C', 'STEP3 최고난도 유형', 2, '최상위권 굳히기를 위한 최고난도 유형'),
  ('gojaengi', 'D', '창의융합 유형', 3, '종합적 사고력을 키우는 창의융합 유형'),
  ('gojaengi', 'E', '중단원 TEST', 4, '워크북 중단원 TEST'),
  ('gojaengi', 'F', '대단원 TEST', 5, '워크북 대단원 TEST')
on conflict (series_key, category_code) do update
set display_label = excluded.display_label,
    order_index = excluded.order_index,
    description = excluded.description,
    is_active = true;
