-- 0021: Migrate remaining local-only tables to Supabase with RLS and audit

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

-- memos -------------------------------------------------------------------
create table if not exists public.memos (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  original text,
  summary text,
  scheduled_at timestamptz,
  dismissed boolean,
  recurrence_type text,
  weekdays text,
  recurrence_end date,
  recurrence_count integer,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
create index if not exists idx_memos_academy on public.memos(academy_id);
alter table public.memos enable row level security;
drop policy if exists memos_all on public.memos;
create policy memos_all on public.memos for all
using (exists (select 1 from public.memberships s where s.academy_id = memos.academy_id and s.user_id = auth.uid()))
with check (exists (select 1 from public.memberships s where s.academy_id = memos.academy_id and s.user_id = auth.uid()));
drop trigger if exists trg_memos_audit on public.memos;
create trigger trg_memos_audit before insert or update on public.memos
for each row execute function public._set_audit_fields();

-- schedule_events ---------------------------------------------------------
create table if not exists public.schedule_events (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  group_id text,
  date date,
  title text,
  note text,
  start_hour integer,
  start_minute integer,
  end_hour integer,
  end_minute integer,
  color integer,
  tags text,
  icon_key text,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
create index if not exists idx_schedule_events_academy on public.schedule_events(academy_id);
alter table public.schedule_events enable row level security;
drop policy if exists schedule_events_all on public.schedule_events;
create policy schedule_events_all on public.schedule_events for all
using (exists (select 1 from public.memberships s where s.academy_id = schedule_events.academy_id and s.user_id = auth.uid()))
with check (exists (select 1 from public.memberships s where s.academy_id = schedule_events.academy_id and s.user_id = auth.uid()));
drop trigger if exists trg_schedule_events_audit on public.schedule_events;
create trigger trg_schedule_events_audit before insert or update on public.schedule_events
for each row execute function public._set_audit_fields();

-- resource grades/icons ---------------------------------------------------
create table if not exists public.resource_grades (
  id bigserial primary key,
  academy_id uuid not null references public.academies(id) on delete cascade,
  name text,
  order_index integer,
  created_at timestamptz not null default now()
);
create index if not exists idx_resource_grades_academy on public.resource_grades(academy_id);
alter table public.resource_grades enable row level security;
drop policy if exists resource_grades_all on public.resource_grades;
create policy resource_grades_all on public.resource_grades for all
using (exists (select 1 from public.memberships s where s.academy_id = resource_grades.academy_id and s.user_id = auth.uid()))
with check (exists (select 1 from public.memberships s where s.academy_id = resource_grades.academy_id and s.user_id = auth.uid()));

create table if not exists public.resource_grade_icons (
  academy_id uuid not null references public.academies(id) on delete cascade,
  name text not null,
  icon integer,
  primary key (academy_id, name)
);
alter table public.resource_grade_icons enable row level security;
drop policy if exists resource_grade_icons_all on public.resource_grade_icons;
create policy resource_grade_icons_all on public.resource_grade_icons for all
using (exists (select 1 from public.memberships s where s.academy_id = resource_grade_icons.academy_id and s.user_id = auth.uid()))
with check (exists (select 1 from public.memberships s where s.academy_id = resource_grade_icons.academy_id and s.user_id = auth.uid()));

-- resource file links/bookmarks ------------------------------------------
create table if not exists public.resource_file_links (
  id bigserial primary key,
  academy_id uuid not null references public.academies(id) on delete cascade,
  file_id uuid references public.resource_files(id) on delete cascade,
  grade text,
  url text,
  created_at timestamptz not null default now()
);
create index if not exists idx_rfl_academy on public.resource_file_links(academy_id);
alter table public.resource_file_links enable row level security;
drop policy if exists resource_file_links_all on public.resource_file_links;
create policy resource_file_links_all on public.resource_file_links for all
using (exists (select 1 from public.memberships s where s.academy_id = resource_file_links.academy_id and s.user_id = auth.uid()))
with check (exists (select 1 from public.memberships s where s.academy_id = resource_file_links.academy_id and s.user_id = auth.uid()));

create table if not exists public.resource_file_bookmarks (
  id bigserial primary key,
  academy_id uuid not null references public.academies(id) on delete cascade,
  file_id uuid references public.resource_files(id) on delete cascade,
  name text,
  description text,
  path text,
  order_index integer,
  created_at timestamptz not null default now()
);
create index if not exists idx_rfb_academy on public.resource_file_bookmarks(academy_id);
alter table public.resource_file_bookmarks enable row level security;
drop policy if exists resource_file_bookmarks_all on public.resource_file_bookmarks;
create policy resource_file_bookmarks_all on public.resource_file_bookmarks for all
using (exists (select 1 from public.memberships s where s.academy_id = resource_file_bookmarks.academy_id and s.user_id = auth.uid()))
with check (exists (select 1 from public.memberships s where s.academy_id = resource_file_bookmarks.academy_id and s.user_id = auth.uid()));

-- homework_items ----------------------------------------------------------
create table if not exists public.homework_items (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid references public.students(id) on delete set null,
  title text,
  body text,
  color integer,
  status integer,
  accumulated_ms bigint,
  run_start timestamptz,
  completed_at timestamptz,
  first_started_at timestamptz,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
create index if not exists idx_homework_items_academy on public.homework_items(academy_id);
alter table public.homework_items enable row level security;
drop policy if exists homework_items_all on public.homework_items;
create policy homework_items_all on public.homework_items for all
using (exists (select 1 from public.memberships s where s.academy_id = homework_items.academy_id and s.user_id = auth.uid()))
with check (exists (select 1 from public.memberships s where s.academy_id = homework_items.academy_id and s.user_id = auth.uid()));
drop trigger if exists trg_homework_items_audit on public.homework_items;
create trigger trg_homework_items_audit before insert or update on public.homework_items
for each row execute function public._set_audit_fields();

-- session_overrides -------------------------------------------------------
create table if not exists public.session_overrides (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  session_type_id text,
  set_id text,
  override_type text not null,
  original_class_datetime timestamptz,
  replacement_class_datetime timestamptz,
  duration_minutes integer,
  reason text,
  original_attendance_id uuid references public.attendance_records(id) on delete set null,
  replacement_attendance_id uuid references public.attendance_records(id) on delete set null,
  status text not null,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
create index if not exists idx_session_overrides_academy on public.session_overrides(academy_id);
alter table public.session_overrides enable row level security;
drop policy if exists session_overrides_all on public.session_overrides;
create policy session_overrides_all on public.session_overrides for all
using (exists (select 1 from public.memberships s where s.academy_id = session_overrides.academy_id and s.user_id = auth.uid()))
with check (exists (select 1 from public.memberships s where s.academy_id = session_overrides.academy_id and s.user_id = auth.uid()));
drop trigger if exists trg_session_overrides_audit on public.session_overrides;
create trigger trg_session_overrides_audit before insert or update on public.session_overrides
for each row execute function public._set_audit_fields();







