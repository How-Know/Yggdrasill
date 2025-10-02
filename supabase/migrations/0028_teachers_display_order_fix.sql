-- Idempotent fix: ensure teachers.display_order exists and ordering index present
alter table if exists public.teachers
  add column if not exists display_order integer;

create index if not exists idx_teachers_display_order
  on public.teachers(academy_id, display_order nulls last, name);

