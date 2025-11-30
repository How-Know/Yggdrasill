-- Concept Category tree for '개념' 메뉴
-- Expresses hierarchical folders using self-referencing parent_id (Windows-like folders)

-- Ensure pgcrypto (for gen_random_uuid) is available
create extension if not exists pgcrypto;

create table if not exists public.concept_categories (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  parent_id uuid null references public.concept_categories(id) on delete cascade,
  code text unique,
  depth int not null default 0,
  sort_order int not null default 0,
  description text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Helpful indexes for tree traversal and ordering
create index if not exists idx_concept_categories_parent on public.concept_categories(parent_id);
create index if not exists idx_concept_categories_parent_sort on public.concept_categories(parent_id, sort_order, name);

-- Updated at trigger
create or replace function public.fn_concept_categories_set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_concept_categories_updated on public.concept_categories;
create trigger trg_concept_categories_updated
before update on public.concept_categories
for each row execute procedure public.fn_concept_categories_set_updated_at();

-- RLS
alter table public.concept_categories enable row level security;
drop policy if exists concept_categories_all on public.concept_categories;
create policy concept_categories_all
on public.concept_categories
for all
to authenticated
using (true)
with check (true);

-- Optional bootstrap of domain roots if not present
do $$
declare
  cnt int;
begin
  select count(*) into cnt from public.concept_categories where parent_id is null;
  if cnt = 0 then
    insert into public.concept_categories (name, code, depth, sort_order)
    values
      ('대수','ALG',0,1),
      ('해석','CALC',0,2),
      ('확률통계','STAT',0,3),
      ('기하','GEOM',0,4);
  end if;
end$$;


