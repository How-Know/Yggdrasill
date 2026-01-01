-- Add memo category for filtering/classification
-- category values: schedule | consult | inquiry

alter table public.memos
  add column if not exists category text;

-- Backfill existing rows
update public.memos
set category = 'inquiry'
where category is null or category = '';

alter table public.memos
  alter column category set default 'inquiry';

alter table public.memos
  alter column category set not null;














