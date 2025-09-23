-- Areas & Groups taxonomy for survey questions

create table if not exists public.question_areas (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  order_index integer not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists public.question_groups (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  order_index integer not null default 0,
  created_at timestamptz not null default now()
);

alter table public.question_areas enable row level security;
alter table public.question_groups enable row level security;

-- Public read (for rendering forms), owner write via admin UI requires auth
drop policy if exists "Public read areas" on public.question_areas;
create policy "Public read areas" on public.question_areas for select using (true);

drop policy if exists "Public read groups" on public.question_groups;
create policy "Public read groups" on public.question_groups for select using (true);

drop policy if exists "Owner write areas" on public.question_areas;
create policy "Owner write areas" on public.question_areas
  for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');

drop policy if exists "Owner write groups" on public.question_groups;
create policy "Owner write groups" on public.question_groups
  for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');

create index if not exists idx_question_areas_order on public.question_areas(order_index);
create index if not exists idx_question_groups_order on public.question_groups(order_index);








