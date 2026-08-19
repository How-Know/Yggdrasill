-- Student pause: snapshot remaining classes, memo-only expected resume,
-- block arrival/notifications during the pause window.

alter table public.student_pause_periods
  add column if not exists expected_resume_on date,
  add column if not exists snapshot_cycle integer,
  add column if not exists snapshot_session_cycle integer,
  add column if not exists snapshot_consumed_count integer,
  add column if not exists snapshot_remaining_count integer;

alter table public.student_pause_periods
  drop constraint if exists student_pause_snapshot_counts_chk;
alter table public.student_pause_periods
  add constraint student_pause_snapshot_counts_chk
  check (
    (snapshot_cycle is null or snapshot_cycle >= 1)
    and (snapshot_session_cycle is null or snapshot_session_cycle >= 1)
    and (snapshot_consumed_count is null or snapshot_consumed_count >= 0)
    and (snapshot_remaining_count is null or snapshot_remaining_count >= 0)
  );

create unique index if not exists uidx_student_pause_periods_open
  on public.student_pause_periods(academy_id, student_id)
  where paused_to is null;

comment on column public.student_pause_periods.expected_resume_on is
  'Display/memo only. Never used as paused_to.';
comment on column public.student_pause_periods.snapshot_remaining_count is
  'Class days left in the current cycle at pause start. Resume billing uses this.';

create or replace function public.student_is_paused_on(
  p_academy_id uuid,
  p_student_id uuid,
  p_day date
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.student_pause_periods p
    where p.academy_id = p_academy_id
      and p.student_id = p_student_id
      and p.paused_from <= p_day
      and (p.paused_to is null or p.paused_to >= p_day)
  );
$$;

revoke all on function public.student_is_paused_on(uuid, uuid, date) from public;
grant execute on function public.student_is_paused_on(uuid, uuid, date)
  to anon, authenticated, service_role;

create or replace function public._student_pause_delete_planned(
  p_academy_id uuid,
  p_student_id uuid,
  p_from date
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.attendance_records ar
  where ar.academy_id = p_academy_id
    and ar.student_id = p_student_id
    and coalesce(ar.is_planned, false) = true
    and coalesce(ar.is_present, false) = false
    and ar.arrival_time is null
    and coalesce(
      ar.date,
      (ar.class_date_time at time zone 'Asia/Seoul')::date
    ) >= p_from;
end;
$$;

create or replace function public._student_pause_capture_snapshot(
  p_academy_id uuid,
  p_student_id uuid,
  p_from date
)
returns table(
  cycle integer,
  session_cycle integer,
  consumed_count integer,
  remaining_count integer
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_session_cycle integer := 1;
  v_cycle integer := 1;
  v_cycle_start date;
  v_cycle_end date;
  v_consumed integer := 0;
begin
  select greatest(coalesce(s.session_cycle, 1), 1)
    into v_session_cycle
  from public.academy_settings s
  where s.academy_id = p_academy_id
  limit 1;
  v_session_cycle := coalesce(v_session_cycle, 1);

  select pr.cycle, pr.due_date
    into v_cycle, v_cycle_start
  from public.payment_records pr
  where pr.academy_id = p_academy_id
    and pr.student_id = p_student_id
    and pr.waived_at is null
    and pr.due_date <= p_from
  order by pr.due_date desc, pr.cycle desc
  limit 1;

  if v_cycle is null then
    select pr.cycle, pr.due_date
      into v_cycle, v_cycle_start
    from public.payment_records pr
    where pr.academy_id = p_academy_id
      and pr.student_id = p_student_id
      and pr.waived_at is null
    order by pr.cycle asc, pr.due_date asc
    limit 1;
  end if;

  v_cycle := coalesce(v_cycle, 1);

  select pr.due_date
    into v_cycle_end
  from public.payment_records pr
  where pr.academy_id = p_academy_id
    and pr.student_id = p_student_id
    and pr.waived_at is null
    and pr.cycle = v_cycle + 1
  limit 1;

  select count(distinct coalesce(
      ar.date,
      (ar.class_date_time at time zone 'Asia/Seoul')::date
    ))::integer
    into v_consumed
  from public.attendance_records ar
  where ar.academy_id = p_academy_id
    and ar.student_id = p_student_id
    and coalesce(ar.is_planned, false) = false
    and (
      coalesce(ar.is_present, false) = true
      or ar.arrival_time is not null
    )
    and coalesce(
      ar.date,
      (ar.class_date_time at time zone 'Asia/Seoul')::date
    ) < p_from
    and (
      v_cycle_start is null
      or coalesce(
        ar.date,
        (ar.class_date_time at time zone 'Asia/Seoul')::date
      ) >= v_cycle_start
    )
    and (
      v_cycle_end is null
      or coalesce(
        ar.date,
        (ar.class_date_time at time zone 'Asia/Seoul')::date
      ) < v_cycle_end
    );

  cycle := v_cycle;
  session_cycle := v_session_cycle;
  consumed_count := v_consumed;
  remaining_count := greatest(v_session_cycle - v_consumed, 0);
  return next;
end;
$$;

create or replace function public.pause_student(
  p_academy_id uuid,
  p_student_id uuid,
  p_from date,
  p_to date default null,
  p_note text default ''
) returns uuid
language plpgsql
set search_path = public
as $$
declare
  v_id uuid;
  v_snap record;
begin
  perform set_config('statement_timeout', '60s', true);

  if p_from is null then
    raise exception 'STUDENT_PAUSE_FROM_REQUIRED';
  end if;

  if exists (
    select 1
    from public.student_pause_periods p
    where p.academy_id = p_academy_id
      and p.student_id = p_student_id
      and p.paused_to is not null
      and p.paused_from <= coalesce(p.paused_to, p.paused_from)
      and p_from <= p.paused_to
      and coalesce(p.paused_to, p.paused_from) >= p_from
  ) then
    raise exception 'STUDENT_PAUSE_OVERLAPS_HISTORY';
  end if;

  select s.*
    into v_snap
  from public._student_pause_capture_snapshot(
    p_academy_id,
    p_student_id,
    p_from
  ) s;

  select id into v_id
  from public.student_pause_periods
  where academy_id = p_academy_id
    and student_id = p_student_id
    and paused_to is null
  order by paused_from desc
  limit 1;

  if v_id is null then
    insert into public.student_pause_periods(
      academy_id,
      student_id,
      paused_from,
      paused_to,
      expected_resume_on,
      note,
      snapshot_cycle,
      snapshot_session_cycle,
      snapshot_consumed_count,
      snapshot_remaining_count
    )
    values (
      p_academy_id,
      p_student_id,
      p_from,
      null,
      p_to,
      nullif(trim(p_note), ''),
      v_snap.cycle,
      v_snap.session_cycle,
      v_snap.consumed_count,
      v_snap.remaining_count
    )
    returning id into v_id;
  else
    update public.student_pause_periods
    set paused_from = p_from,
        paused_to = null,
        expected_resume_on = p_to,
        note = nullif(trim(p_note), ''),
        snapshot_cycle = v_snap.cycle,
        snapshot_session_cycle = v_snap.session_cycle,
        snapshot_consumed_count = v_snap.consumed_count,
        snapshot_remaining_count = v_snap.remaining_count
    where id = v_id;
  end if;

  perform public._student_pause_delete_planned(
    p_academy_id,
    p_student_id,
    p_from
  );

  return v_id;
end;
$$;

create or replace function public.resume_student(
  p_academy_id uuid,
  p_student_id uuid,
  p_to date
) returns uuid
language plpgsql
set search_path = public
as $$
declare
  v_id uuid;
  v_from date;
begin
  perform set_config('statement_timeout', '60s', true);

  select id, paused_from
    into v_id, v_from
  from public.student_pause_periods
  where academy_id = p_academy_id
    and student_id = p_student_id
    and paused_to is null
  order by paused_from desc
  limit 1;

  if v_id is null then
    raise exception 'no ongoing pause for student' using errcode = 'P0002';
  end if;

  if p_to is null then
    raise exception 'STUDENT_RESUME_TO_REQUIRED';
  end if;

  update public.student_pause_periods
  set paused_to = p_to
  where id = v_id;

  return v_id;
end;
$$;

create or replace function public.recompute_charge_points(
  p_academy_id uuid,
  p_student_id uuid
) returns void
language plpgsql
set search_path = public
as $$
declare
  v_pause public.student_pause_periods%rowtype;
  v_resume date;
  v_remaining integer;
  v_cycle integer;
  v_charge_dt timestamptz;
  v_next_due timestamptz;
  v_class_at timestamptz;
  v_class_day date;
  v_last_day date;
begin
  perform set_config('statement_timeout', '60s', true);

  select p.*
    into v_pause
  from public.student_pause_periods p
  where p.academy_id = p_academy_id
    and p.student_id = p_student_id
  order by p.paused_to is null desc, p.paused_from desc, p.created_at desc
  limit 1;

  if v_pause.id is null then
    return;
  end if;

  -- Open pause: do not invent a next due while the student is away.
  if v_pause.paused_to is null then
    return;
  end if;

  v_resume := v_pause.paused_to + 1;
  v_remaining := coalesce(v_pause.snapshot_remaining_count, 0);
  v_cycle := coalesce(v_pause.snapshot_cycle, 1);

  for v_class_at in
    select (
      (v_resume + days.offset_days)
      + make_time(b.start_hour, b.start_minute, 0)
    ) at time zone 'Asia/Seoul'
    from generate_series(0, 180) as days(offset_days)
    join public.student_time_blocks b
      on b.academy_id = p_academy_id
     and b.student_id = p_student_id
     and b.day_index = extract(
       isodow from (v_resume + days.offset_days)
     )::integer - 1
     and b.start_date <= (v_resume + days.offset_days)
     and (
       b.end_date is null
       or b.end_date >= (v_resume + days.offset_days)
     )
    where not public.student_is_paused_on(
      p_academy_id,
      p_student_id,
      v_resume + days.offset_days
    )
    order by (v_resume + days.offset_days), b.start_hour, b.start_minute
  loop
    v_class_day := (v_class_at at time zone 'Asia/Seoul')::date;
    if v_last_day is not null and v_class_day = v_last_day then
      continue;
    end if;
    v_last_day := v_class_day;

    if v_remaining > 0 then
      v_remaining := v_remaining - 1;
      if v_remaining = 0 then
        v_charge_dt := v_class_at;
      end if;
    elsif v_next_due is null then
      v_next_due := v_class_at;
      exit;
    end if;
  end loop;

  if v_next_due is null then
    return;
  end if;

  insert into public.student_charge_points(
    academy_id, student_id, cycle,
    charge_point_occurrence_id, charge_point_datetime, next_due_datetime, computed_at
  )
  values (
    p_academy_id, p_student_id, v_cycle,
    null, v_charge_dt, v_next_due, now()
  )
  on conflict (academy_id, student_id, cycle)
  do update set
    charge_point_occurrence_id = excluded.charge_point_occurrence_id,
    charge_point_datetime = excluded.charge_point_datetime,
    next_due_datetime = excluded.next_due_datetime,
    computed_at = excluded.computed_at;
end;
$$;

create or replace function public._student_pause_block_arrival()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_day date;
  v_arriving boolean := false;
begin
  v_day := coalesce(
    new.date,
    (new.class_date_time at time zone 'Asia/Seoul')::date,
    (new.arrival_time at time zone 'Asia/Seoul')::date,
    (now() at time zone 'Asia/Seoul')::date
  );

  if not public.student_is_paused_on(new.academy_id, new.student_id, v_day) then
    return new;
  end if;

  if tg_op = 'INSERT' then
    v_arriving := new.arrival_time is not null
      or coalesce(new.is_present, false) = true;
  else
    v_arriving := (
      old.arrival_time is null and new.arrival_time is not null
    ) or (
      coalesce(old.is_present, false) is distinct from true
      and coalesce(new.is_present, false) = true
    );
  end if;

  if v_arriving then
    raise exception 'STUDENT_PAUSED';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_student_pause_block_arrival
  on public.attendance_records;
create trigger trg_student_pause_block_arrival
before insert or update of arrival_time, is_present, date, class_date_time
on public.attendance_records
for each row
execute function public._student_pause_block_arrival();

create or replace function public.m5_record_arrival(
  p_academy_id uuid,
  p_student_id uuid
) returns void as $$
declare
  today_date date := (now() at time zone 'Asia/Seoul')::date;
  existing_id uuid;
  start_hour integer; start_minute integer; duration integer; class_dt timestamptz;
begin
  if public.student_is_paused_on(p_academy_id, p_student_id, today_date) then
    raise exception 'STUDENT_PAUSED';
  end if;

  select id into existing_id
    from public.attendance_records
   where academy_id = p_academy_id and student_id = p_student_id and date = today_date
   limit 1;

  select b.start_hour, b.start_minute, b.duration into start_hour, start_minute, duration
    from public.student_time_blocks b
   where b.academy_id = p_academy_id and b.student_id = p_student_id
     and b.day_index = case when extract(dow from (now() at time zone 'Asia/Seoul'))::int = 0 then 6 else extract(dow from (now() at time zone 'Asia/Seoul'))::int - 1 end
   order by b.start_hour, b.start_minute
   limit 1;

  if start_hour is not null then
    class_dt := make_timestamptz(
      extract(year from now() at time zone 'Asia/Seoul')::int,
      extract(month from now() at time zone 'Asia/Seoul')::int,
      extract(day from now() at time zone 'Asia/Seoul')::int,
      start_hour, start_minute, 0, 'Asia/Seoul');
  end if;

  if existing_id is not null then
    update public.attendance_records
       set arrival_time = coalesce(arrival_time, now()),
           departure_time = null,
           is_present   = true,
           date         = coalesce(date, today_date),
           class_date_time = coalesce(class_date_time, class_dt),
           class_end_time  = coalesce(class_end_time, case when class_dt is not null and duration is not null then class_dt + (duration || ' minutes')::interval else null end),
           updated_at   = now()
     where id = existing_id;
  else
    insert into public.attendance_records (
      academy_id, student_id, date, class_date_time, class_end_time,
      is_present, arrival_time, created_at, updated_at
    ) values (
      p_academy_id, p_student_id, today_date,
      class_dt,
      case when class_dt is not null and duration is not null then class_dt + (duration || ' minutes')::interval else null end,
      true, now(), now(), now()
    );
  end if;
end; $$ language plpgsql security definer set search_path=public;

grant execute on function public.m5_record_arrival(uuid, uuid) to anon, authenticated;

create or replace function public.kiosk_check_in(
  p_token_hash text,
  p_student_id uuid,
  p_pin text,
  p_request_id text,
  p_walk_in boolean default false,
  p_setup_pin boolean default false
) returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_academy uuid;
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_now timestamptz := now();
  v_attendance public.attendance_records%rowtype;
  v_pin public.m5_student_pins%rowtype;
  v_attempts integer;
  v_locked_seconds integer;
  v_override_id uuid;
  v_set_id text;
  v_session_type_id text;
  v_duration integer := 1;
begin
  if p_request_id is null or length(btrim(p_request_id)) not between 1 and 128 then
    return jsonb_build_object('ok', false, 'error', 'invalid_request_id');
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(coalesce(p_token_hash, '') || ':' || p_request_id, 0)
  );

  select academy_id into v_academy
  from public.kiosk_devices
  where token_hash = p_token_hash and is_active and academy_id is not null;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'invalid_token');
  end if;

  select * into v_attendance
  from public.attendance_records
  where academy_id = v_academy
    and kiosk_request_id = p_request_id
  limit 1;
  if found then
    if v_attendance.student_id <> p_student_id then
      return jsonb_build_object('ok', false, 'error', 'request_id_conflict');
    end if;
    return jsonb_build_object(
      'ok', true, 'status', 'already_checked_in',
      'attendance_id', v_attendance.id,
      'arrival_time', v_attendance.arrival_time,
      'walk_in', not coalesce(v_attendance.is_planned, false)
    );
  end if;

  if not exists (
    select 1 from public.students s
    where s.id = p_student_id and s.academy_id = v_academy
  ) then
    return jsonb_build_object('ok', false, 'error', 'student_not_found');
  end if;

  if public.student_is_paused_on(v_academy, p_student_id, v_today) then
    return jsonb_build_object('ok', false, 'error', 'student_paused');
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_academy::text || ':' || p_student_id::text, 0));

  select * into v_attendance
  from public.attendance_records
  where academy_id = v_academy
    and student_id = p_student_id
    and coalesce(date, (class_date_time at time zone 'Asia/Seoul')::date) = v_today
    and arrival_time is not null
  order by arrival_time
  limit 1
  for update;
  if found then
    update public.attendance_records
    set kiosk_request_id = coalesce(kiosk_request_id, p_request_id)
    where id = v_attendance.id;
    return jsonb_build_object(
      'ok', true, 'status', 'already_checked_in',
      'attendance_id', v_attendance.id,
      'arrival_time', v_attendance.arrival_time,
      'walk_in', not coalesce(v_attendance.is_planned, false)
    );
  end if;

  select * into v_pin
  from public.m5_student_pins
  where academy_id = v_academy and student_id = p_student_id
  for update;
  if found and v_pin.pin_required then
    if v_pin.pin_hash is null then
      if not coalesce(p_setup_pin, false)
         or p_pin is null or length(btrim(p_pin)) = 0 then
        return jsonb_build_object('ok', false, 'error', 'pin_setup_required');
      end if;
      update public.m5_student_pins
      set pin_hash = crypt(p_pin, gen_salt('bf')),
          pin_plain = p_pin,
          failed_attempts = 0,
          locked_until = null,
          updated_at = v_now
      where student_id = p_student_id and academy_id = v_academy;
    else
      if v_pin.locked_until is not null and v_pin.locked_until > v_now then
        v_locked_seconds := ceil(extract(epoch from (v_pin.locked_until - v_now)))::integer;
        return jsonb_build_object(
          'ok', false, 'error', 'pin_locked', 'locked_seconds', v_locked_seconds
        );
      end if;
      if p_pin is null or v_pin.pin_hash <> crypt(p_pin, v_pin.pin_hash) then
        v_attempts := v_pin.failed_attempts + 1;
        if v_attempts >= 5 then
          update public.m5_student_pins
          set failed_attempts = 0,
              locked_until = v_now + interval '5 minutes',
              updated_at = v_now
          where student_id = p_student_id and academy_id = v_academy;
          return jsonb_build_object(
            'ok', false, 'error', 'pin_locked', 'locked_seconds', 300
          );
        end if;
        update public.m5_student_pins
        set failed_attempts = v_attempts, updated_at = v_now
        where student_id = p_student_id and academy_id = v_academy;
        return jsonb_build_object(
          'ok', false, 'error', 'pin_invalid', 'attempts_left', 5 - v_attempts
        );
      end if;
      update public.m5_student_pins
      set failed_attempts = 0, locked_until = null, updated_at = v_now
      where student_id = p_student_id and academy_id = v_academy;
    end if;
  end if;

  select * into v_attendance
  from public.attendance_records
  where academy_id = v_academy
    and student_id = p_student_id
    and is_planned is true
    and coalesce(date, (class_date_time at time zone 'Asia/Seoul')::date) = v_today
  order by abs(extract(epoch from (class_date_time - v_now))), class_date_time
  limit 1
  for update;

  if found then
    update public.attendance_records
    set arrival_time = coalesce(arrival_time, v_now),
        is_present = true,
        kiosk_request_id = p_request_id,
        updated_at = v_now
    where id = v_attendance.id
    returning * into v_attendance;
    update public.kiosk_devices set last_seen_at = v_now where token_hash = p_token_hash;
    return jsonb_build_object(
      'ok', true, 'status', 'checked_in',
      'attendance_id', v_attendance.id,
      'arrival_time', v_attendance.arrival_time,
      'walk_in', false,
      'set_id', v_attendance.set_id
    );
  end if;

  if not coalesce(p_walk_in, false) then
    return jsonb_build_object('ok', false, 'error', 'not_scheduled');
  end if;

  select b.set_id, b.session_type_id
    into v_set_id, v_session_type_id
  from public.student_time_blocks b
  where b.academy_id = v_academy
    and b.student_id = p_student_id
    and b.day_index = case
      when extract(dow from (v_now at time zone 'Asia/Seoul'))::integer = 0 then 6
      else extract(dow from (v_now at time zone 'Asia/Seoul'))::integer - 1
    end
  order by abs(
    (b.start_hour * 60 + b.start_minute)
    - (extract(hour from (v_now at time zone 'Asia/Seoul'))::integer * 60
       + extract(minute from (v_now at time zone 'Asia/Seoul'))::integer)
  )
  limit 1;

  insert into public.session_overrides(
    academy_id, student_id, session_type_id, set_id, override_type,
    replacement_class_datetime, duration_minutes, reason, status
  ) values (
    v_academy, p_student_id, v_session_type_id, v_set_id, 'add',
    date_trunc('minute', v_now), v_duration, 'other', 'planned'
  ) returning id into v_override_id;

  insert into public.attendance_records(
    academy_id, student_id, set_id, session_type_id,
    class_date_time, class_end_time, date, class_name,
    is_present, is_planned, arrival_time, kiosk_request_id
  ) values (
    v_academy, p_student_id, v_set_id, v_session_type_id,
    date_trunc('minute', v_now), date_trunc('minute', v_now) + make_interval(mins => v_duration),
    v_today, '등하원(추가)', true, false, v_now, p_request_id
  ) returning * into v_attendance;

  update public.session_overrides
  set replacement_attendance_id = v_attendance.id
  where id = v_override_id;
  update public.kiosk_devices set last_seen_at = v_now where token_hash = p_token_hash;

  return jsonb_build_object(
    'ok', true, 'status', 'checked_in',
    'attendance_id', v_attendance.id,
    'arrival_time', v_attendance.arrival_time,
    'walk_in', true,
    'set_id', v_attendance.set_id
  );
end;
$$;

revoke all on function public.kiosk_check_in(text, uuid, text, text, boolean, boolean) from public, anon, authenticated;
grant execute on function public.kiosk_check_in(text, uuid, text, text, boolean, boolean) to service_role;

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

  if public.student_is_paused_on(new.academy_id, new.student_id, v_event_date) then
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
      and not public.student_is_paused_on(
        ar.academy_id,
        ar.student_id,
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

  if public.student_is_paused_on(new.academy_id, new.student_id, v_event_date) then
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

revoke all on function public._student_pause_delete_planned(uuid, uuid, date) from public;
revoke all on function public._student_pause_capture_snapshot(uuid, uuid, date) from public;
revoke all on function public._student_pause_block_arrival() from public;

grant execute on function public.pause_student(uuid, uuid, date, date, text) to authenticated;
grant execute on function public.resume_student(uuid, uuid, date) to authenticated;
grant execute on function public.recompute_charge_points(uuid, uuid) to authenticated;
