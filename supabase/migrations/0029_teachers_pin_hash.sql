-- Add pin_hash to teachers for PIN authentication
alter table if exists public.teachers
  add column if not exists pin_hash text;

create index if not exists idx_teachers_order
  on public.teachers(academy_id, display_order nulls last, name);

