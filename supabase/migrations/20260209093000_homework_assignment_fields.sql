-- 20260209093000: homework_assignments progress/issue fields

alter table public.homework_assignments
  add column if not exists progress integer not null default 0,
  add column if not exists issue_type text,
  add column if not exists issue_note text;

update public.homework_assignments
  set progress = 0
  where progress is null;
