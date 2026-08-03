-- 수력충전 시리즈의 문제 카테고리 카탈로그를 등록한다.
--
-- 개념서(개념원리·개념+유형)처럼 대-중-소단원 3계층 트리를 쓰지만, 한 소단원
-- 안의 코너가 하나뿐이라 카테고리는 둘이면 충분하다:
--   A 유형 문제         — 소단원 본문 문항. "유형 01 …" 배지 아래로 이어지며
--                         번호는 소단원마다 01부터 다시 시작한다. 지면 마지막에
--                         불규칙하게 붙는 "개념 체크"(빈칸 채우기)도 같은
--                         번호열을 이어받으므로 같은 카테고리에 담고 유형명으로만
--                         구분한다.
--   B 단원 마무리 평가  — 중단원 끝의 마무리 지면. 번호가 01부터 다시 시작하고
--                         계산 조심 / 생각 더하기 / 조건 확인 배지가 붙는다.
--
-- 소단원 첫 지면 상단의 개념 정리 박스와 대단원 도입 지면은 문항이 없는 개념
-- 지면이라 카테고리가 없다.

insert into public.textbook_problem_categories (
  series_key, category_code, display_label, order_index, description
) values
  ('suryeok', 'A', '유형 문제', 0, '소단원 유형 문제 및 개념 체크'),
  ('suryeok', 'B', '단원 마무리 평가', 1, '중단원 끝 마무리 평가')
on conflict (series_key, category_code) do update
set display_label = excluded.display_label,
    order_index = excluded.order_index,
    description = excluded.description,
    is_active = true;
