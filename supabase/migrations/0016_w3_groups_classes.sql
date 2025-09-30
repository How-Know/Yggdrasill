-- W3: groups/classes
-- Multi-tenant: academy_id column + RLS based on memberships
-- OCC/audit fields: version, created_at/by, updated_at/by

-- Helper: audit fields function (idempotent)
create or replace function public._set_audit_fields()
returns trigger
language plpgsql
security definer as $$
begin
  if tg_op = 'INSERT' then
    new.created_at := coalesce(new.created_at, now());
    new.created_by := coalesce(new.created_by, auth.uid());
    new.updated_at := coalesce(new.updated_at, now());
    new.updated_by := coalesce(new.updated_by, auth.uid());
    new.version := coalesce(new.version, 1);
  elsif tg_op = 'UPDATE' then
    new.updated_at := now();
    new.updated_by := auth.uid();
    new.version := coalesce(old.version, 1) + 1;
  end if;
  return new;
end$$;

-- groups -----------------------------------------------------------------
create table if not exists public.groups (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  name text not null,
  description text,
  capacity integer,
  duration integer,
  color integer,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
create index if not exists idx_groups_academy on public.groups(academy_id);
alter table public.groups enable row level security;
drop policy if exists groups_all on public.groups;
create policy groups_all on public.groups for all
using (exists (select 1 from public.memberships s where s.academy_id = groups.academy_id and s.user_id = auth.uid()))
with check (exists (select 1 from public.memberships s where s.academy_id = groups.academy_id and s.user_id = auth.uid()));
drop trigger if exists trg_groups_audit on public.groups;
create trigger trg_groups_audit before insert or update on public.groups
for each row execute function public._set_audit_fields();

-- classes ----------------------------------------------------------------
create table if not exists public.classes (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  name text not null,
  capacity integer,
  description text,
  color integer,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
create index if not exists idx_classes_academy on public.classes(academy_id);
alter table public.classes enable row level security;
drop policy if exists classes_all on public.classes;
create policy classes_all on public.classes for all
using (exists (select 1 from public.memberships s where s.academy_id = classes.academy_id and s.user_id = auth.uid()))
with check (exists (select 1 from public.memberships s where s.academy_id = classes.academy_id and s.user_id = auth.uid()));
drop trigger if exists trg_classes_audit on public.classes;
create trigger trg_classes_audit before insert or update on public.classes
for each row execute function public._set_audit_fields();










