-- W2: academy_settings, operating_hours, teachers, kakao_reservations
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

-- academy_settings (singleton per academy)
create table if not exists public.academy_settings (
  academy_id uuid primary key references public.academies(id) on delete cascade,
  name text,
  slogan text,
  default_capacity integer,
  lesson_duration integer,
  payment_type text,
  logo bytea,
  session_cycle integer default 1,
  openai_api_key text,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
alter table public.academy_settings enable row level security;
drop policy if exists academy_settings_all on public.academy_settings;
create policy academy_settings_all on public.academy_settings for all
using (exists (select 1 from public.memberships s where s.academy_id = academy_settings.academy_id and s.user_id = auth.uid()))
with check (exists (select 1 from public.memberships s where s.academy_id = academy_settings.academy_id and s.user_id = auth.uid()));
drop trigger if exists trg_academy_settings_audit on public.academy_settings;
create trigger trg_academy_settings_audit before insert or update on public.academy_settings
for each row execute function public._set_audit_fields();

-- operating_hours (per academy, multiple rows)
create table if not exists public.operating_hours (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  day_of_week integer not null, -- 0=Mon..6=Sun
  start_time text,
  end_time text,
  break_times text,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
create index if not exists idx_operating_hours_academy on public.operating_hours(academy_id);
alter table public.operating_hours enable row level security;
drop policy if exists operating_hours_all on public.operating_hours;
create policy operating_hours_all on public.operating_hours for all
using (exists (select 1 from public.memberships s where s.academy_id = operating_hours.academy_id and s.user_id = auth.uid()))
with check (exists (select 1 from public.memberships s where s.academy_id = operating_hours.academy_id and s.user_id = auth.uid()));
drop trigger if exists trg_operating_hours_audit on public.operating_hours;
create trigger trg_operating_hours_audit before insert or update on public.operating_hours
for each row execute function public._set_audit_fields();

-- teachers (per academy)
create table if not exists public.teachers (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  name text,
  role integer,
  contact text,
  email text,
  description text,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
create index if not exists idx_teachers_academy on public.teachers(academy_id);
alter table public.teachers enable row level security;
drop policy if exists teachers_all on public.teachers;
create policy teachers_all on public.teachers for all
using (exists (select 1 from public.memberships s where s.academy_id = teachers.academy_id and s.user_id = auth.uid()))
with check (exists (select 1 from public.memberships s where s.academy_id = teachers.academy_id and s.user_id = auth.uid()));
drop trigger if exists trg_teachers_audit on public.teachers;
create trigger trg_teachers_audit before insert or update on public.teachers
for each row execute function public._set_audit_fields();

-- kakao_reservations (per academy)
create table if not exists public.kakao_reservations (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  created_at timestamptz not null default now(),
  message text,
  name text,
  student_name text,
  phone text,
  desired_datetime timestamptz,
  is_read boolean default false,
  kakao_user_id text,
  kakao_nickname text,
  status text,
  version integer not null default 1,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
create index if not exists idx_kakao_reservations_academy on public.kakao_reservations(academy_id);
alter table public.kakao_reservations enable row level security;
drop policy if exists kakao_reservations_all on public.kakao_reservations;
create policy kakao_reservations_all on public.kakao_reservations for all
using (exists (select 1 from public.memberships s where s.academy_id = kakao_reservations.academy_id and s.user_id = auth.uid()))
with check (exists (select 1 from public.memberships s where s.academy_id = kakao_reservations.academy_id and s.user_id = auth.uid()));
drop trigger if exists trg_kakao_reservations_audit on public.kakao_reservations;
create trigger trg_kakao_reservations_audit before insert or update on public.kakao_reservations
for each row execute function public._set_audit_fields();











