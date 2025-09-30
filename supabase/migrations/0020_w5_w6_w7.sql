-- W5/W6/W7: student_time_blocks, attendance_records, payment_records
-- Multi-tenant via academy_id; RLS based on memberships; OCC/audit via _set_audit_fields

-- Helper (idempotent)
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

-- W5: student_time_blocks -------------------------------------------------
create table if not exists public.student_time_blocks (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  day_index integer not null,
  start_hour integer not null,
  start_minute integer not null,
  duration integer not null,
  block_created_at timestamptz,
  set_id text,
  number integer,
  session_type_id text,
  weekly_order integer,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
create index if not exists idx_student_time_blocks_academy on public.student_time_blocks(academy_id);
alter table public.student_time_blocks enable row level security;
drop policy if exists stb_all on public.student_time_blocks;
create policy stb_all on public.student_time_blocks for all
using (exists (select 1 from public.memberships s where s.academy_id = student_time_blocks.academy_id and s.user_id = auth.uid()))
with check (exists (select 1 from public.memberships s where s.academy_id = student_time_blocks.academy_id and s.user_id = auth.uid()));
drop trigger if exists trg_student_time_blocks_audit on public.student_time_blocks;
create trigger trg_student_time_blocks_audit before insert or update on public.student_time_blocks
for each row execute function public._set_audit_fields();

-- W6: attendance_records --------------------------------------------------
create table if not exists public.attendance_records (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  class_date_time timestamptz,
  class_end_time timestamptz,
  date date,
  class_name text,
  is_present boolean,
  arrival_time timestamptz,
  departure_time timestamptz,
  notes text,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
create index if not exists idx_attendance_records_academy on public.attendance_records(academy_id);
alter table public.attendance_records enable row level security;
drop policy if exists attendance_all on public.attendance_records;
create policy attendance_all on public.attendance_records for all
using (exists (select 1 from public.memberships s where s.academy_id = attendance_records.academy_id and s.user_id = auth.uid()))
with check (exists (select 1 from public.memberships s where s.academy_id = attendance_records.academy_id and s.user_id = auth.uid()));
drop trigger if exists trg_attendance_records_audit on public.attendance_records;
create trigger trg_attendance_records_audit before insert or update on public.attendance_records
for each row execute function public._set_audit_fields();

-- W7: payment_records -----------------------------------------------------
create table if not exists public.payment_records (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  cycle integer,
  due_date timestamptz,
  paid_date timestamptz,
  postpone_reason text,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
create index if not exists idx_payment_records_academy on public.payment_records(academy_id);
alter table public.payment_records enable row level security;
drop policy if exists payment_records_all on public.payment_records;
create policy payment_records_all on public.payment_records for all
using (exists (select 1 from public.memberships s where s.academy_id = payment_records.academy_id and s.user_id = auth.uid()))
with check (exists (select 1 from public.memberships s where s.academy_id = payment_records.academy_id and s.user_id = auth.uid()));
drop trigger if exists trg_payment_records_audit on public.payment_records;
create trigger trg_payment_records_audit before insert or update on public.payment_records
for each row execute function public._set_audit_fields();







