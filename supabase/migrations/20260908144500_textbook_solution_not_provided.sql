-- Explicitly represent textbook problems whose publisher provides no solution.
--
-- A row still lives in textbook_problem_solution_refs so existing stage-completion
-- counts treat it as resolved. source_kind='none' means raw_page/regions are
-- sentinels and must never be used for PDF navigation.

alter table public.textbook_problem_solution_refs
  drop constraint if exists textbook_problem_solution_refs_source_kind_chk;

alter table public.textbook_problem_solution_refs
  add constraint textbook_problem_solution_refs_source_kind_chk
  check (source_kind in ('sol', 'body', 'none'));

comment on column public.textbook_problem_solution_refs.source_kind is
  'sol = solution PDF, body = solution printed in body PDF, '
  'none = publisher provides no solution (raw_page/regions are sentinels).';
