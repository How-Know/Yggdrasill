-- Stage 2/3 sidecar tables use the shared set_updated_at trigger.
-- These tables were created without updated_at, so updates failed with:
--   record "new" has no field "updated_at"

alter table public.textbook_problem_answers
  add column if not exists updated_at timestamptz not null default now();

alter table public.textbook_problem_solution_refs
  add column if not exists updated_at timestamptz not null default now();

notify pgrst, 'reload schema';
