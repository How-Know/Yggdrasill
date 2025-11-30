create extension if not exists "uuid-ossp";
create extension if not exists "pgcrypto";

-- Concepts: 원본 데이터
create table if not exists public.concepts (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('definition','theorem')),
  sub_type text,
  name text not null,
  content text not null,
  level int not null check (level in (1,2,3)),
  main_category_id uuid not null references public.concept_categories(id) on delete cascade,
  sort_order int default 0,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

alter table public.concepts enable row level security;
drop policy if exists "concepts_all" on public.concepts;
create policy "concepts_all" on public.concepts
  for all to authenticated using (true) with check (true);

-- updated_at trigger
create or replace function public.set_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_concepts_updated on public.concepts;
create trigger trg_concepts_updated
  before update on public.concepts
  for each row execute function public.set_updated_at();

-- Shortcut links: 보조 카테고리 링크
create table if not exists public.concept_shortcuts (
  category_id uuid not null references public.concept_categories(id) on delete cascade,
  concept_id uuid not null references public.concepts(id) on delete cascade,
  sort_order int default 0,
  created_at timestamptz default now(),
  primary key (category_id, concept_id)
);

alter table public.concept_shortcuts enable row level security;
drop policy if exists "concept_shortcuts_all" on public.concept_shortcuts;
create policy "concept_shortcuts_all" on public.concept_shortcuts
  for all to authenticated using (true) with check (true);


