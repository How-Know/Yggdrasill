-- 20260711000000: 개념원리(wonri) 시리즈 지원
--
-- 1) sub_key CHECK 완화: 쎈/RPM은 A/B/C 3슬롯이지만 개념원리는
--    A(개념원리 익히기) / B(필수유형) / C(확인 체크) / D(연습문제) 4슬롯을 쓴다.
-- 2) textbook_problem_solution_refs.source_kind: 필수유형(B)은 해설이 별도
--    해설 PDF가 아니라 본문 PDF의 '풀이' 단락에 있으므로, 좌표가 어느 PDF를
--    가리키는지 구분한다. ('sol' = 해설 PDF, 'body' = 본문 PDF)

alter table public.textbook_problem_crops
  drop constraint if exists textbook_problem_crops_sub_key_chk;
alter table public.textbook_problem_crops
  add constraint textbook_problem_crops_sub_key_chk
  check (sub_key in ('A', 'B', 'C', 'D'));

alter table public.textbook_pb_extract_runs
  drop constraint if exists textbook_pb_extract_runs_sub_key_chk;
alter table public.textbook_pb_extract_runs
  add constraint textbook_pb_extract_runs_sub_key_chk
  check (sub_key in ('A', 'B', 'C', 'D'));

alter table public.textbook_problem_solution_refs
  add column if not exists source_kind text not null default 'sol';

alter table public.textbook_problem_solution_refs
  drop constraint if exists textbook_problem_solution_refs_source_kind_chk;
alter table public.textbook_problem_solution_refs
  add constraint textbook_problem_solution_refs_source_kind_chk
  check (source_kind in ('sol', 'body'));

comment on column public.textbook_problem_solution_refs.source_kind is
  '해설 좌표가 가리키는 PDF 종류. sol = 해설 PDF(기본), body = 본문 PDF '
  '(개념원리 필수유형처럼 풀이가 본문에 인쇄된 경우).';
