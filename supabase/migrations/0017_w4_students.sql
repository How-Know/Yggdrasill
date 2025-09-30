-- W4: students / student_basic_info / student_payment_info
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

-- students ---------------------------------------------------------------
create table if not exists public.students (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  name text not null,
  school text,
  education_level integer,
  grade integer,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
create index if not exists idx_students_academy on public.students(academy_id);
alter table public.students enable row level security;
drop policy if exists students_all on public.students;
create policy students_all on public.students for all
using (exists (select 1 from public.memberships s where s.academy_id = students.academy_id and s.user_id = auth.uid()))
with check (exists (select 1 from public.memberships s where s.academy_id = students.academy_id and s.user_id = auth.uid()));
drop trigger if exists trg_students_audit on public.students;
create trigger trg_students_audit before insert or update on public.students
for each row execute function public._set_audit_fields();

-- student_basic_info -----------------------------------------------------
create table if not exists public.student_basic_info (
  student_id uuid primary key references public.students(id) on delete cascade,
  academy_id uuid not null references public.academies(id) on delete cascade,
  phone_number text,
  parent_phone_number text,
  group_id uuid references public.groups(id) on delete set null,
  memo text,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
create index if not exists idx_student_basic_info_academy on public.student_basic_info(academy_id);
alter table public.student_basic_info enable row level security;
drop policy if exists sbi_all on public.student_basic_info;
create policy sbi_all on public.student_basic_info for all
using (exists (select 1 from public.memberships s where s.academy_id = student_basic_info.academy_id and s.user_id = auth.uid()))
with check (exists (select 1 from public.memberships s where s.academy_id = student_basic_info.academy_id and s.user_id = auth.uid()));
drop trigger if exists trg_student_basic_info_audit on public.student_basic_info;
create trigger trg_student_basic_info_audit before insert or update on public.student_basic_info
for each row execute function public._set_audit_fields();

-- student_payment_info ---------------------------------------------------
create table if not exists public.student_payment_info (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null unique references public.students(id) on delete cascade,
  registration_date timestamptz,
  payment_method text,
  weekly_class_count integer default 1,
  tuition_fee integer,
  lateness_threshold integer default 10,
  schedule_notification boolean default false,
  attendance_notification boolean default false,
  departure_notification boolean default false,
  lateness_notification boolean default false,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
create index if not exists idx_student_payment_info_academy on public.student_payment_info(academy_id);
alter table public.student_payment_info enable row level security;
drop policy if exists spi_all on public.student_payment_info;
create policy spi_all on public.student_payment_info for all
using (exists (select 1 from public.memberships s where s.academy_id = student_payment_info.academy_id and s.user_id = auth.uid()))
with check (exists (select 1 from public.memberships s where s.academy_id = student_payment_info.academy_id and s.user_id = auth.uid()));
drop trigger if exists trg_student_payment_info_audit on public.student_payment_info;
create trigger trg_student_payment_info_audit before insert or update on public.student_payment_info
for each row execute function public._set_audit_fields();










