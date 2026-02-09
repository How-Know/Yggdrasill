-- 20260209193000: add version to homework_assignment_checks

alter table public.homework_assignment_checks
  add column if not exists version integer not null default 1;

update public.homework_assignment_checks
  set version = 1
  where version is null;
