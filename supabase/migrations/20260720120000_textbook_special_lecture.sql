-- 20260720120000: 개념원리 특강(sub_key 'E') 지원
--
-- 개념원리에는 가끔 "특강 01" 배지가 붙은 심화 예제 코너가 있다. 지면 구성은
-- 필수유형과 같아서(예제 + 본문 "풀이" 단락 + 하단 확인 체크) 같은 방식으로
-- 추출·정답·해설을 처리하되, 번호가 01부터 새로 시작해 같은 소단원의
-- 필수유형(B) 번호와 충돌하므로 전용 슬롯 'E'로 분리 저장한다.
-- (sub_index 규칙은 B와 동일: 소단원 순번으로 분리.)

alter table public.textbook_problem_crops
  drop constraint if exists textbook_problem_crops_sub_key_chk;
alter table public.textbook_problem_crops
  add constraint textbook_problem_crops_sub_key_chk
  check (sub_key in ('A', 'B', 'C', 'D', 'E'));

alter table public.textbook_pb_extract_runs
  drop constraint if exists textbook_pb_extract_runs_sub_key_chk;
alter table public.textbook_pb_extract_runs
  add constraint textbook_pb_extract_runs_sub_key_chk
  check (sub_key in ('A', 'B', 'C', 'D', 'E'));
