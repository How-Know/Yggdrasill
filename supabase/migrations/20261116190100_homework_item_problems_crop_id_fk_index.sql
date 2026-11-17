-- 교재·시험지 문항 영역(crop)이나 검수용 책 행을 지우면 딸린 행을 crop_id / book_id 하나만으로 찾는다
-- (ON DELETE CASCADE / SET NULL). academy_id·student_id 로 시작하는 인덱스는 이 조회에 쓰이지 못해
-- 큰 표를 통째로 읽고, 캐시가 식어 있으면 시험지 한 부를 지우다 statement_timeout(57014)에 걸린다.
-- 학생 기록 표는 FK 열마다 그 열로 시작하는 인덱스를 둔다(.cursor/rules/learning-records.mdc 12번).
--
-- 학생 앱이 쓰는 표라 표 하나에 파일 하나로 나눠 적용한다: 한 번에 표 하나만 잠그므로
-- 학생 쪽 트랜잭션과 서로 물리지 않고, 쓰기는 인덱스를 만드는 잠깐만 기다린다.
set lock_timeout = '3s';

create index if not exists idx_homework_item_problems_crop_id_fk
  on public.homework_item_problems (crop_id);
