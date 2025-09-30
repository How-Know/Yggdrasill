-- questions table and RLS

create table if not exists public.questions (
  id uuid primary key default gen_random_uuid(),
  area_id uuid references public.question_areas(id) on delete set null,
  group_id uuid references public.question_groups(id) on delete set null,
  trait text not null check (trait in ('D','I','A','C','N','L','S','P')),
  text text not null,
  type text not null check (type in ('scale','text')),
  min_score integer,
  max_score integer,
  weight integer not null default 1,
  reverse text not null default 'N' check (reverse in ('Y','N')),
  tags text,
  memo text,
  image_url text,
  pair_id text,
  version integer not null default 1,
  is_active boolean not null default true,
  created_by uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.questions enable row level security;

-- update timestamp trigger
create or replace function public.set_questions_updated_at() returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_set_questions_updated_at on public.questions;
create trigger trg_set_questions_updated_at
before update on public.questions
for each row execute function public.set_questions_updated_at();

-- RLS
drop policy if exists "Authenticated can read questions" on public.questions;
create policy "Authenticated can read questions"
on public.questions for select
using (true);

drop policy if exists "Owners manage questions" on public.questions;
create policy "Owners manage questions"
on public.questions for all
using (created_by = auth.uid())
with check (created_by = auth.uid());

















