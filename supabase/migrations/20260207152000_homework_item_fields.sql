-- 20260207152000: homework_items add type/page/count/content

alter table public.homework_items
  add column if not exists type text,
  add column if not exists page text,
  add column if not exists count integer,
  add column if not exists content text;
