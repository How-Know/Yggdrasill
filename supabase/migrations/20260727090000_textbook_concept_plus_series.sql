-- 개념+유형(개념플러스유형) 시리즈의 문제 카테고리 카탈로그를 등록한다.
--
-- 개념원리와 같은 개념서지만 지면 구성이 달라 카테고리 다섯 개를 쓴다:
--   A 개념확인            — 개념 설명 바로 아래의 확인 문항
--   B 필수 문제           — 소단원별로 따로 매기는 대표 문항. "7-1", "7-2" 처럼
--                           번호가 붙는 따름 문제도 같은 카테고리에 들어간다.
--   C 쏙쏙 개념 익히기    — 소단원 마무리 (STEP1). 앞에 "한번 더 연습"이
--                           불규칙하게 붙을 수 있다.
--   D 탄탄 단원 다지기    — 중단원 마무리 (STEP2). 난이도가 색칠된 원으로 표기.
--   E 쓱쓱 서술형 완성하기 — 중단원 마무리 (STEP3). 예제는 개념원리 필수유형처럼
--                           풀이·정답이 정답 파일이 아니라 본문 문항 아래에 있다.
--
-- 중단원 끝의 개념 리뷰 / 마인드맵은 문항이 없는 개념 지면이라 카테고리가 없다.

insert into public.textbook_problem_categories (
  series_key, category_code, display_label, order_index, description
) values
  ('gaeyu', 'A', '개념확인', 0, '개념 설명 아래 확인 문항'),
  ('gaeyu', 'B', '필수 문제', 1, '소단원별 필수 문제 및 따름 문제'),
  ('gaeyu', 'C', '쏙쏙 개념 익히기', 2, 'STEP1 소단원 마무리 (한번 더 연습 포함)'),
  ('gaeyu', 'D', '탄탄 단원 다지기', 3, 'STEP2 중단원 마무리'),
  ('gaeyu', 'E', '쓱쓱 서술형 완성하기', 4, 'STEP3 서술형 예제·유제')
on conflict (series_key, category_code) do update
set display_label = excluded.display_label,
    order_index = excluded.order_index,
    description = excluded.description,
    is_active = true;
