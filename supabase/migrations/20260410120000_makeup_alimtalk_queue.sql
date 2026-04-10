-- Makeup reservation AlimTalk: settings columns, queue, logs, enqueue trigger
-- Does not modify attendance_notification_* or attendance triggers.

-- 1) Academy settings (default off)
alter table public.academy_alimtalk_settings
  add column if not exists makeup_template_code text,
  add column if not exists makeup_message_template text,
  add column if not exists makeup_alimtalk_enabled boolean not null default false;

-- 2) Queue
create table if not exists public.makeup_notification_queue (
  id uuid primary key default gen_random_uuid(),
  session_override_id uuid not null references public.session_overrides(id) on delete cascade,
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  event_type text not null default 'scheduled_created'
    check (event_type in ('scheduled_created')),
  status text not null default 'pending'
    check (status in ('pending','processing','sent','error','skipped')),
  attempts integer not null default 0,
  last_error text,
  last_message_id text,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  sent_at timestamptz,
  version integer not null default 1
);

create unique index if not exists uidx_makeup_notification_queue_override_event
  on public.makeup_notification_queue(session_override_id, event_type);
create index if not exists idx_makeup_notification_queue_status
  on public.makeup_notification_queue(status, created_at);
create index if not exists idx_makeup_notification_queue_academy
  on public.makeup_notification_queue(academy_id);

alter table public.makeup_notification_queue enable row level security;

drop trigger if exists trg_makeup_notification_queue_audit on public.makeup_notification_queue;
create trigger trg_makeup_notification_queue_audit
  before insert or update on public.makeup_notification_queue
  for each row execute function public._set_audit_fields();

-- 3) Logs
create table if not exists public.makeup_notification_logs (
  id uuid primary key default gen_random_uuid(),
  queue_id uuid references public.makeup_notification_queue(id) on delete set null,
  session_override_id uuid not null references public.session_overrides(id) on delete cascade,
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

create index if not exists idx_makeup_notification_logs_override
  on public.makeup_notification_logs(session_override_id, event_type);
create index if not exists idx_makeup_notification_logs_status
  on public.makeup_notification_logs(status, created_at);

alter table public.makeup_notification_logs enable row level security;

-- 4) Enqueue on planned makeup insert (replace + add), KST date >= today, consent only
create or replace function public.enqueue_makeup_notification_on_create()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_consented boolean := false;
begin
  if new.reason is distinct from 'makeup' then
    return new;
  end if;
  if new.status is distinct from 'planned' then
    return new;
  end if;
  if new.override_type is null or new.override_type not in ('replace', 'add') then
    return new;
  end if;
  if new.replacement_class_datetime is null then
    return new;
  end if;

  if (new.replacement_class_datetime at time zone 'Asia/Seoul')::date
      < (now() at time zone 'Asia/Seoul')::date then
    return new;
  end if;

  select coalesce(sbi.notification_consent, false)
    into v_consented
  from public.student_basic_info sbi
  where sbi.student_id = new.student_id
  limit 1;

  if not coalesce(v_consented, false) then
    return new;
  end if;

  insert into public.makeup_notification_queue (
    session_override_id,
    academy_id,
    student_id,
    event_type,
    status
  ) values (
    new.id,
    new.academy_id,
    new.student_id,
    'scheduled_created',
    'pending'
  )
  on conflict (session_override_id, event_type) do nothing;

  return new;
end;
$$;

drop trigger if exists trg_enqueue_makeup_notification on public.session_overrides;
create trigger trg_enqueue_makeup_notification
  after insert on public.session_overrides
  for each row execute function public.enqueue_makeup_notification_on_create();
