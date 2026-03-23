-- 20260321153000: add academy address field for fallback weather location

alter table public.academy_settings
  add column if not exists address text;
