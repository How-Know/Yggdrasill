-- Drop the one-running-per-student unique constraint.
-- Group homework allows multiple items to run simultaneously.
drop index if exists public.ux_hw_running_per_student;
