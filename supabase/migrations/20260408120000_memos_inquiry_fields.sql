-- Structured inquiry memo fields (nullable; schedule/consult leave null)
alter table public.memos
  add column if not exists inquiry_phone text;
alter table public.memos
  add column if not exists inquiry_school_grade text;
alter table public.memos
  add column if not exists inquiry_availability text;
alter table public.memos
  add column if not exists inquiry_note text;
alter table public.memos
  add column if not exists inquiry_sort_index integer;

