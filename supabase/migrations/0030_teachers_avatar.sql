-- Avatar fields for teachers
alter table if exists public.teachers
  add column if not exists avatar_url text,
  add column if not exists avatar_preset_color text,
  add column if not exists avatar_preset_initial text,
  add column if not exists avatar_use_icon boolean;

