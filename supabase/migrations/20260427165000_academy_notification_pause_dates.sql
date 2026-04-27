-- Academy-wide AlimTalk pause dates (KST date)
-- Keeps student consent immutable and blocks sends for selected academy dates.

create table if not exists public.academy_notification_pause_dates (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  pause_date date not null,
  reason text,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  constraint uidx_academy_notification_pause_dates unique (academy_id, pause_date)
);

create index if not exists idx_academy_notification_pause_dates_academy_date
  on public.academy_notification_pause_dates(academy_id, pause_date);

alter table public.academy_notification_pause_dates enable row level security;

drop policy if exists academy_notification_pause_dates_all on public.academy_notification_pause_dates;
create policy academy_notification_pause_dates_all
  on public.academy_notification_pause_dates
  for all
  using (
    exists (
      select 1
      from public.memberships m
      where m.academy_id = academy_notification_pause_dates.academy_id
        and m.user_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1
      from public.memberships m
      where m.academy_id = academy_notification_pause_dates.academy_id
        and m.user_id = auth.uid()
    )
  );

drop trigger if exists trg_academy_notification_pause_dates_audit
  on public.academy_notification_pause_dates;
create trigger trg_academy_notification_pause_dates_audit
  before insert or update on public.academy_notification_pause_dates
  for each row execute function public._set_audit_fields();

create or replace function public.is_academy_notification_paused(
  p_academy_id uuid,
  p_pause_date date
) returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.academy_notification_pause_dates p
    where p.academy_id = p_academy_id
      and p.pause_date = p_pause_date
  );
$$;

-- Attendance trigger: consent + pause-date guard.
create or replace function public.enqueue_attendance_notification()
returns trigger
language plpgsql security definer set search_path=public as $$
declare
  v_consented boolean := false;
  v_event_date date;
begin
  v_event_date := coalesce(
    new.date,
    (new.class_date_time at time zone 'Asia/Seoul')::date,
    (new.arrival_time at time zone 'Asia/Seoul')::date,
    (new.departure_time at time zone 'Asia/Seoul')::date,
    (now() at time zone 'Asia/Seoul')::date
  );

  if public.is_academy_notification_paused(new.academy_id, v_event_date) then
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

-- Late enqueue RPC: same pause-date guard.
create or replace function public.enqueue_due_late_notifications(
  p_limit integer default 500
) returns integer
language plpgsql
security definer
set search_path=public
as $$
declare
  v_limit integer := greatest(coalesce(p_limit, 500), 1);
  v_inserted integer := 0;
begin
  with due as (
    select
      ar.id as attendance_id,
      ar.academy_id,
      ar.student_id
    from public.attendance_records ar
    join public.student_basic_info sbi
      on sbi.student_id = ar.student_id
    left join public.student_payment_info spi
      on spi.student_id = ar.student_id
    where ar.class_date_time is not null
      and ar.arrival_time is null
      and ar.departure_time is null
      and coalesce(sbi.notification_consent, false) = true
      and coalesce(spi.lateness_notification, true) = true
      and now() >= ar.class_date_time
        + make_interval(mins => greatest(coalesce(spi.lateness_threshold, 10), 0))
      and coalesce(
        ar.date,
        (ar.class_date_time at time zone 'Asia/Seoul')::date
      ) = (now() at time zone 'Asia/Seoul')::date
      and not public.is_academy_notification_paused(
        ar.academy_id,
        coalesce(ar.date, (ar.class_date_time at time zone 'Asia/Seoul')::date)
      )
      and not exists (
        select 1
        from public.attendance_notification_queue q
        where q.attendance_id = ar.id
          and q.event_type = 'late'
      )
    order by ar.class_date_time asc
    limit v_limit
  )
  insert into public.attendance_notification_queue (
    attendance_id,
    academy_id,
    student_id,
    event_type,
    status
  )
  select
    d.attendance_id,
    d.academy_id,
    d.student_id,
    'late',
    'pending'
  from due d
  on conflict do nothing;

  get diagnostics v_inserted = row_count;
  return v_inserted;
end;
$$;

grant execute on function public.enqueue_due_late_notifications(integer) to anon, authenticated;

-- Makeup create/update trigger: consent + pause-date guard.
create or replace function public.enqueue_makeup_notification_on_create()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_consented boolean := false;
  v_q_status text;
  v_event_date date;
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

  v_event_date := (new.replacement_class_datetime at time zone 'Asia/Seoul')::date;

  if v_event_date < (now() at time zone 'Asia/Seoul')::date then
    return new;
  end if;

  if public.is_academy_notification_paused(new.academy_id, v_event_date) then
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

  if tg_op = 'INSERT' then
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
  end if;

  if new.replacement_class_datetime is not distinct from old.replacement_class_datetime
     and new.original_class_datetime is not distinct from old.original_class_datetime
     and new.change_reason is not distinct from old.change_reason
     and new.override_type is not distinct from old.override_type
     and new.duration_minutes is not distinct from old.duration_minutes
     and new.reason is not distinct from old.reason
     and new.status is not distinct from old.status
     and new.set_id is not distinct from old.set_id
     and new.occurrence_id is not distinct from old.occurrence_id
     and new.session_type_id is not distinct from old.session_type_id
     and new.original_attendance_id is not distinct from old.original_attendance_id
     and new.replacement_attendance_id is not distinct from old.replacement_attendance_id then
    return new;
  end if;

  select q.status
    into v_q_status
  from public.makeup_notification_queue q
  where q.session_override_id = new.id
    and q.event_type = 'scheduled_created'
  limit 1;

  if found and v_q_status in ('pending', 'processing', 'error') then
    update public.makeup_notification_queue q
    set
      status = 'pending',
      attempts = 0,
      last_error = null
    where q.session_override_id = new.id
      and q.event_type = 'scheduled_created';
    return new;
  end if;

  if found and v_q_status in ('sent', 'skipped') then
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
      'scheduled_updated',
      'pending'
    )
    on conflict (session_override_id, event_type) do update set
      status = 'pending',
      attempts = 0,
      last_error = null;
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
