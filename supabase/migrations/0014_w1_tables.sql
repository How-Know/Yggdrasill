-- W1: Low-risk tables with multi-tenant/OCC fields and generic RLS
-- Tables: tag_presets, tag_events, resource_folders, resource_files, resource_favorites, exam_days, exam_schedules, exam_ranges

-- Helpers -------------------------------------------------------------
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
    new.version := old.version + 1;
  end if;
  return new;
end$$;

-- Policy helper: inline memberships subquery will be used in policies (no view to satisfy advisor)

-- tag_presets ---------------------------------------------------------
create table if not exists public.tag_presets (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  name text not null,
  color integer,
  icon_code integer,
  order_index integer,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
create index if not exists idx_tag_presets_academy on public.tag_presets(academy_id);
alter table public.tag_presets enable row level security;
drop trigger if exists trg_tag_presets_audit on public.tag_presets;
create trigger trg_tag_presets_audit before insert or update on public.tag_presets
for each row execute function public._set_audit_fields();

drop policy if exists tag_presets_select on public.tag_presets;
create policy tag_presets_select on public.tag_presets for select
using (exists (select 1 from public.memberships s where s.academy_id = tag_presets.academy_id and s.user_id = auth.uid()));
drop policy if exists tag_presets_ins on public.tag_presets;
create policy tag_presets_ins on public.tag_presets for insert
with check (exists (select 1 from public.memberships s where s.academy_id = tag_presets.academy_id and s.user_id = auth.uid()));
drop policy if exists tag_presets_upd on public.tag_presets;
create policy tag_presets_upd on public.tag_presets for update
using (exists (select 1 from public.memberships s where s.academy_id = tag_presets.academy_id and s.user_id = auth.uid()))
with check (exists (select 1 from public.memberships s where s.academy_id = tag_presets.academy_id and s.user_id = auth.uid()));
drop policy if exists tag_presets_del on public.tag_presets;
create policy tag_presets_del on public.tag_presets for delete
using (exists (select 1 from public.memberships s where s.academy_id = tag_presets.academy_id and s.user_id = auth.uid()));

-- tag_events ----------------------------------------------------------
create table if not exists public.tag_events (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  set_id text,
  tag_name text,
  color_value integer,
  icon_code integer,
  occurred_at timestamptz not null default now(),
  note text,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
create index if not exists idx_tag_events_academy on public.tag_events(academy_id);
alter table public.tag_events enable row level security;
drop trigger if exists trg_tag_events_audit on public.tag_events;
create trigger trg_tag_events_audit before insert or update on public.tag_events
for each row execute function public._set_audit_fields();
drop policy if exists tag_events_select on public.tag_events;
create policy tag_events_select on public.tag_events for select
using (exists (select 1 from public.memberships s where s.academy_id = tag_events.academy_id and s.user_id = auth.uid()));
drop policy if exists tag_events_ins on public.tag_events;
create policy tag_events_ins on public.tag_events for insert
with check (exists (select 1 from public.memberships s where s.academy_id = tag_events.academy_id and s.user_id = auth.uid()));
drop policy if exists tag_events_upd on public.tag_events;
create policy tag_events_upd on public.tag_events for update
using (exists (select 1 from public.memberships s where s.academy_id = tag_events.academy_id and s.user_id = auth.uid()))
with check (exists (select 1 from public.memberships s where s.academy_id = tag_events.academy_id and s.user_id = auth.uid()));
drop policy if exists tag_events_del on public.tag_events;
create policy tag_events_del on public.tag_events for delete
using (exists (select 1 from public.memberships s where s.academy_id = tag_events.academy_id and s.user_id = auth.uid()));

-- resource_folders ----------------------------------------------------
create table if not exists public.resource_folders (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  name text not null,
  parent_id uuid references public.resource_folders(id) on delete cascade,
  order_index integer,
  category text,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
create index if not exists idx_resource_folders_academy on public.resource_folders(academy_id);
alter table public.resource_folders enable row level security;
drop trigger if exists trg_resource_folders_audit on public.resource_folders;
create trigger trg_resource_folders_audit before insert or update on public.resource_folders
for each row execute function public._set_audit_fields();
drop policy if exists resource_folders_select on public.resource_folders;
create policy resource_folders_select on public.resource_folders for select
using (exists (select 1 from public.memberships s where s.academy_id = resource_folders.academy_id and s.user_id = auth.uid()));
drop policy if exists resource_folders_ins on public.resource_folders;
create policy resource_folders_ins on public.resource_folders for insert
with check (exists (select 1 from public.memberships s where s.academy_id = resource_folders.academy_id and s.user_id = auth.uid()));
drop policy if exists resource_folders_upd on public.resource_folders;
create policy resource_folders_upd on public.resource_folders for update
using (exists (select 1 from public.memberships s where s.academy_id = resource_folders.academy_id and s.user_id = auth.uid()))
with check (exists (select 1 from public.memberships s where s.academy_id = resource_folders.academy_id and s.user_id = auth.uid()));
drop policy if exists resource_folders_del on public.resource_folders;
create policy resource_folders_del on public.resource_folders for delete
using (exists (select 1 from public.memberships s where s.academy_id = resource_folders.academy_id and s.user_id = auth.uid()));

-- resource_files ------------------------------------------------------
create table if not exists public.resource_files (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  folder_id uuid references public.resource_folders(id) on delete set null,
  name text not null,
  url text,
  category text,
  order_index integer,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
create index if not exists idx_resource_files_academy on public.resource_files(academy_id);
alter table public.resource_files enable row level security;
drop trigger if exists trg_resource_files_audit on public.resource_files;
create trigger trg_resource_files_audit before insert or update on public.resource_files
for each row execute function public._set_audit_fields();
drop policy if exists resource_files_select on public.resource_files;
create policy resource_files_select on public.resource_files for select
using (exists (select 1 from public.memberships s where s.academy_id = resource_files.academy_id and s.user_id = auth.uid()));
drop policy if exists resource_files_ins on public.resource_files;
create policy resource_files_ins on public.resource_files for insert
with check (exists (select 1 from public.memberships s where s.academy_id = resource_files.academy_id and s.user_id = auth.uid()));
drop policy if exists resource_files_upd on public.resource_files;
create policy resource_files_upd on public.resource_files for update
using (exists (select 1 from public.memberships s where s.academy_id = resource_files.academy_id and s.user_id = auth.uid()))
with check (exists (select 1 from public.memberships s where s.academy_id = resource_files.academy_id and s.user_id = auth.uid()));
drop policy if exists resource_files_del on public.resource_files;
create policy resource_files_del on public.resource_files for delete
using (exists (select 1 from public.memberships s where s.academy_id = resource_files.academy_id and s.user_id = auth.uid()));

-- resource_favorites (per user)
create table if not exists public.resource_favorites (
  academy_id uuid not null references public.academies(id) on delete cascade,
  file_id uuid not null references public.resource_files(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  primary key (academy_id, file_id, user_id),
  created_at timestamptz not null default now()
);
alter table public.resource_favorites enable row level security;
drop policy if exists resource_favorites_all on public.resource_favorites;
create policy resource_favorites_all on public.resource_favorites for all
using (
  exists (select 1 from public.memberships s where s.academy_id = resource_favorites.academy_id and s.user_id = auth.uid())
  and user_id = auth.uid()
)
with check (
  exists (select 1 from public.memberships s where s.academy_id = resource_favorites.academy_id and s.user_id = auth.uid())
  and user_id = auth.uid()
);

-- exam tables ---------------------------------------------------------
create table if not exists public.exam_days (
  academy_id uuid not null references public.academies(id) on delete cascade,
  school text not null,
  level integer not null,
  grade integer not null,
  date date not null,
  primary key (academy_id, school, level, grade, date)
);
alter table public.exam_days enable row level security;
drop policy if exists exam_days_all on public.exam_days;
create policy exam_days_all on public.exam_days for all
using (exists (select 1 from public.memberships s where s.academy_id = exam_days.academy_id and s.user_id = auth.uid()))
with check (exists (select 1 from public.memberships s where s.academy_id = exam_days.academy_id and s.user_id = auth.uid()));

create table if not exists public.exam_schedules (
  academy_id uuid not null references public.academies(id) on delete cascade,
  school text not null,
  level integer not null,
  grade integer not null,
  date date not null,
  names_json text,
  primary key (academy_id, school, level, grade, date)
);
alter table public.exam_schedules enable row level security;
drop policy if exists exam_schedules_all on public.exam_schedules;
create policy exam_schedules_all on public.exam_schedules for all
using (exists (select 1 from public.memberships s where s.academy_id = exam_schedules.academy_id and s.user_id = auth.uid()))
with check (exists (select 1 from public.memberships s where s.academy_id = exam_schedules.academy_id and s.user_id = auth.uid()));

create table if not exists public.exam_ranges (
  academy_id uuid not null references public.academies(id) on delete cascade,
  school text not null,
  level integer not null,
  grade integer not null,
  date date not null,
  range_text text,
  primary key (academy_id, school, level, grade, date)
);
alter table public.exam_ranges enable row level security;
drop policy if exists exam_ranges_all on public.exam_ranges;
create policy exam_ranges_all on public.exam_ranges for all
using (exists (select 1 from public.memberships s where s.academy_id = exam_ranges.academy_id and s.user_id = auth.uid()))
with check (exists (select 1 from public.memberships s where s.academy_id = exam_ranges.academy_id and s.user_id = auth.uid()));


