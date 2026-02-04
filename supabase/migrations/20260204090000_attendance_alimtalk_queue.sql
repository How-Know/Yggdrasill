-- 20260204: Attendance AlimTalk queue/settings/logs + triggers

-- Academy-level AlimTalk settings (template + sender info)
create table if not exists public.academy_alimtalk_settings (
  academy_id uuid primary key references public.academies(id) on delete cascade,
  sender_key text,
  sender_number text,
  arrival_template_code text,
  arrival_message_template text,
  departure_template_code text,
  departure_message_template text,
  late_template_code text,
  late_message_template text,
  enabled boolean not null default true,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
alter table public.academy_alimtalk_settings enable row level security;
drop policy if exists academy_alimtalk_settings_all on public.academy_alimtalk_settings;
create policy academy_alimtalk_settings_all on public.academy_alimtalk_settings for all
using (exists (select 1 from public.memberships s where s.academy_id = academy_alimtalk_settings.academy_id and s.user_id = auth.uid()))
with check (exists (select 1 from public.memberships s where s.academy_id = academy_alimtalk_settings.academy_id and s.user_id = auth.uid()));
drop trigger if exists trg_academy_alimtalk_settings_audit on public.academy_alimtalk_settings;
create trigger trg_academy_alimtalk_settings_audit before insert or update on public.academy_alimtalk_settings
for each row execute function public._set_audit_fields();

-- Attendance notification queue (internal)
create table if not exists public.attendance_notification_queue (
  id uuid primary key default gen_random_uuid(),
  attendance_id uuid not null references public.attendance_records(id) on delete cascade,
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  event_type text not null check (event_type in ('arrival','departure','late')),
  status text not null default 'pending' check (status in ('pending','processing','sent','error','skipped')),
  attempts integer not null default 0,
  last_error text,
  last_message_id text,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  sent_at timestamptz
);
create index if not exists idx_attendance_notification_queue_status on public.attendance_notification_queue(status, created_at);
create index if not exists idx_attendance_notification_queue_academy on public.attendance_notification_queue(academy_id);
create unique index if not exists uidx_attendance_notification_queue_attendance_event
  on public.attendance_notification_queue(attendance_id, event_type);
alter table public.attendance_notification_queue enable row level security;
drop trigger if exists trg_attendance_notification_queue_audit on public.attendance_notification_queue;
create trigger trg_attendance_notification_queue_audit before insert or update on public.attendance_notification_queue
for each row execute function public._set_audit_fields();

-- Attendance notification logs (internal)
create table if not exists public.attendance_notification_logs (
  id uuid primary key default gen_random_uuid(),
  queue_id uuid references public.attendance_notification_queue(id) on delete set null,
  attendance_id uuid not null references public.attendance_records(id) on delete cascade,
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  event_type text not null,
  status text not null,
  provider text,
  message_id text,
  template_code text,
  phone text,
  payload jsonb,
  error text,
  created_at timestamptz not null default now()
);
create index if not exists idx_attendance_notification_logs_attendance on public.attendance_notification_logs(attendance_id, event_type);
create index if not exists idx_attendance_notification_logs_status on public.attendance_notification_logs(status, created_at);
alter table public.attendance_notification_logs enable row level security;

-- Queue trigger for attendance_records
create or replace function public.enqueue_attendance_notification()
returns trigger
language plpgsql security definer set search_path=public as $$
begin
  if (TG_OP = 'INSERT') then
    if (new.arrival_time is not null) then
      insert into public.attendance_notification_queue (
        attendance_id, academy_id, student_id, event_type, status
      ) values (
        new.id, new.academy_id, new.student_id, 'arrival', 'pending'
      ) on conflict do nothing;
    end if;
    if (new.departure_time is not null) then
      insert into public.attendance_notification_queue (
        attendance_id, academy_id, student_id, event_type, status
      ) values (
        new.id, new.academy_id, new.student_id, 'departure', 'pending'
      ) on conflict do nothing;
    end if;
  else
    if (new.arrival_time is not null and old.arrival_time is null) then
      insert into public.attendance_notification_queue (
        attendance_id, academy_id, student_id, event_type, status
      ) values (
        new.id, new.academy_id, new.student_id, 'arrival', 'pending'
      ) on conflict do nothing;
    end if;
    if (new.departure_time is not null and old.departure_time is null) then
      insert into public.attendance_notification_queue (
        attendance_id, academy_id, student_id, event_type, status
      ) values (
        new.id, new.academy_id, new.student_id, 'departure', 'pending'
      ) on conflict do nothing;
    end if;
  end if;
  return new;
end; $$;

drop trigger if exists trg_attendance_notification_queue on public.attendance_records;
create trigger trg_attendance_notification_queue
after insert or update of arrival_time, departure_time on public.attendance_records
for each row execute function public.enqueue_attendance_notification();
