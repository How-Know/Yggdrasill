-- academies + memberships + RLS (multi-tenant skeleton)
-- This migration is safe to run on an existing project; it only adds new tables/policies.

create table if not exists public.academies (
  id uuid primary key default gen_random_uuid(),
  name text not null default 'My Academy',
  owner_user_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now()
);

alter table public.academies enable row level security;

create table if not exists public.memberships (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('owner','admin','staff')),
  created_at timestamptz not null default now(),
  unique (academy_id, user_id)
);

alter table public.memberships enable row level security;

-- RLS policies
-- academies: members can read; owner can create/update/delete
drop policy if exists "members can select academy" on public.academies;
create policy "members can select academy"
on public.academies
for select
using (
  exists (
    select 1 from public.memberships m
    where m.academy_id = academies.id and m.user_id = auth.uid()
  )
);

drop policy if exists "owner can insert own academy" on public.academies;
create policy "owner can insert own academy"
on public.academies
for insert
with check (owner_user_id = auth.uid());

drop policy if exists "owner can update own academy" on public.academies;
create policy "owner can update own academy"
on public.academies
for update
using (owner_user_id = auth.uid())
with check (owner_user_id = auth.uid());

drop policy if exists "owner can delete own academy" on public.academies;
create policy "owner can delete own academy"
on public.academies
for delete
using (owner_user_id = auth.uid());

-- memberships: each user can read own membership; owner can manage memberships in own academy
drop policy if exists "user can select own memberships" on public.memberships;
create policy "user can select own memberships"
on public.memberships
for select
using (
  user_id = auth.uid()
  or exists (
    select 1 from public.academies a
    where a.id = memberships.academy_id and a.owner_user_id = auth.uid()
  )
);

drop policy if exists "owner can insert membership in own academy" on public.memberships;
create policy "owner can insert membership in own academy"
on public.memberships
for insert
with check (
  exists (
    select 1 from public.academies a
    where a.id = memberships.academy_id and a.owner_user_id = auth.uid()
  )
);

drop policy if exists "owner can delete membership in own academy" on public.memberships;
create policy "owner can delete membership in own academy"
on public.memberships
for delete
using (
  exists (
    select 1 from public.academies a
    where a.id = memberships.academy_id and a.owner_user_id = auth.uid()
  )
);

-- Ensure owner gets a membership row automatically
create or replace function public.ensure_owner_membership()
returns trigger
language plpgsql
security definer as $$
begin
  insert into public.memberships (academy_id, user_id, role)
  values (new.id, new.owner_user_id, 'owner')
  on conflict (academy_id, user_id) do nothing;
  return new;
end$$;

drop trigger if exists trg_academies_owner_membership on public.academies;
create trigger trg_academies_owner_membership
after insert on public.academies
for each row execute function public.ensure_owner_membership();


