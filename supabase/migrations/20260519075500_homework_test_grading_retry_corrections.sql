-- Track retry grading corrections without overwriting the first attempt.

alter table public.homework_test_grading_attempt_items
  add column if not exists baseline_attempt_id uuid
    references public.homework_test_grading_attempts(id) on delete set null,
  add column if not exists baseline_state text,
  add column if not exists correction_state text,
  add column if not exists correction_attempt_number integer;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'hw_test_grading_attempt_items_baseline_state_chk'
  ) then
    alter table public.homework_test_grading_attempt_items
      add constraint hw_test_grading_attempt_items_baseline_state_chk
      check (baseline_state is null or baseline_state in ('wrong', 'unsolved'));
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'hw_test_grading_attempt_items_correction_state_chk'
  ) then
    alter table public.homework_test_grading_attempt_items
      add constraint hw_test_grading_attempt_items_correction_state_chk
      check (correction_state is null or correction_state in ('corrected'));
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'hw_test_grading_attempt_items_correction_attempt_number_chk'
  ) then
    alter table public.homework_test_grading_attempt_items
      add constraint hw_test_grading_attempt_items_correction_attempt_number_chk
      check (correction_attempt_number is null or correction_attempt_number >= 1);
  end if;
end $$;

create index if not exists idx_hw_test_grading_items_baseline_attempt
  on public.homework_test_grading_attempt_items (baseline_attempt_id);

create index if not exists idx_hw_test_grading_items_correction_state
  on public.homework_test_grading_attempt_items (academy_id, correction_state, created_at desc)
  where correction_state is not null;
