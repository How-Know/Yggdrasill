-- 20260207113000: student_basic_info flows jsonb
-- Store student flows on server (jsonb array).

alter table public.student_basic_info
  add column if not exists flows jsonb;

alter table public.student_basic_info
  alter column flows set default '[]'::jsonb;

update public.student_basic_info
  set flows = '[]'::jsonb
  where flows is null;
