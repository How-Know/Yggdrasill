-- 개념+유형 고등 시리즈의 문제 카테고리 카탈로그를 등록한다.
--
-- 중등 개념+유형과 달리 소단원 하나가 개념 → 필수예제 → 연습문제로 끝나는
-- 고등 개념원리와 비슷한 구조다. 네 칸 모두 소단원마다 번호가 새로 시작한다:
--   A 개념 Check — 개념 지면 아래 확인 문항. 개념 블록마다 1번부터 다시 시작해
--                  블록 시작 쪽을 붙여 "8-1" 로 저장한다.
--   B 필수예제   — 한 지면에 하나("필수 예제 01"). 정답·풀이는 본문 "풀이" 상자.
--   C 문제       — 필수예제 아래 확인 문제("01-1", "01-2").
--   D 연습문제   — 소단원 끝. 교육청·평가원·수능 배지와 "실력" 구간이 붙는다.
--
-- 정답 PDF 가 따로 없어서 A·C·D 의 정답과 해설은 모두 해설 PDF 에서 읽는다.

insert into public.textbook_problem_categories (
  series_key, category_code, display_label, order_index, description
) values
  ('gaeyu_high', 'A', '개념 Check', 0, '개념 지면의 확인 문항'),
  ('gaeyu_high', 'B', '필수예제', 1, '유형별 대표 예제와 본문 풀이'),
  ('gaeyu_high', 'C', '문제', 2, '필수예제 아래 확인 문제'),
  ('gaeyu_high', 'D', '연습문제', 3, '소단원 마무리 연습문제와 실력 문항')
on conflict (series_key, category_code) do update
set display_label = excluded.display_label,
    order_index = excluded.order_index,
    description = excluded.description,
    is_active = true;
