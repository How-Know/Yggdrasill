-- Keep kiosk walk-in attendance addressable by the main app's attendance sheet.
--
-- A searched student has no planned attendance row. When that student also has
-- no time block on the current weekday, kiosk_check_in previously inserted both
-- the add override and attendance row with set_id = null. The home screen reads
-- open attendance rows directly, but the attendance sheet groups rows by set_id
-- and therefore omitted these students.

-- Repair linked kiosk/add attendance rows that were already created without a
-- set_id. The override id is the canonical fallback for an add override.
update public.attendance_records ar
set set_id = coalesce(nullif(btrim(so.set_id), ''), so.id::text),
    updated_at = now()
from public.session_overrides so
where so.academy_id = ar.academy_id
  and so.replacement_attendance_id = ar.id
  and so.override_type = 'add'
  and so.status <> 'canceled'
  and nullif(btrim(ar.set_id), '') is null;

update public.session_overrides so
set set_id = so.id::text,
    updated_at = now()
where so.override_type = 'add'
  and so.replacement_attendance_id is not null
  and nullif(btrim(so.set_id), '') is null;

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

  perform pg_advisory_xact_lock(
    hashtextextended(v_academy::text || ':' || p_student_id::text, 0)
  );

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
        v_locked_seconds :=
          ceil(extract(epoch from (v_pin.locked_until - v_now)))::integer;
        return jsonb_build_object(
          'ok', false, 'error', 'pin_locked',
          'locked_seconds', v_locked_seconds
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
    update public.kiosk_devices
    set last_seen_at = v_now
    where token_hash = p_token_hash;
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
      when extract(dow from (v_now at time zone 'Asia/Seoul'))::integer = 0
        then 6
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

  -- Add overrides use their own id as a stable set key when no regular time
  -- block exists. Keep the override and attendance row on the same key.
  v_set_id := coalesce(nullif(btrim(v_set_id), ''), v_override_id::text);
  update public.session_overrides
  set set_id = v_set_id
  where id = v_override_id;

  insert into public.attendance_records(
    academy_id, student_id, set_id, session_type_id,
    class_date_time, class_end_time, date, class_name,
    is_present, is_planned, arrival_time, kiosk_request_id
  ) values (
    v_academy, p_student_id, v_set_id, v_session_type_id,
    date_trunc('minute', v_now),
    date_trunc('minute', v_now) + make_interval(mins => v_duration),
    v_today, '등하원(추가)', true, false, v_now, p_request_id
  ) returning * into v_attendance;

  update public.session_overrides
  set replacement_attendance_id = v_attendance.id
  where id = v_override_id;
  update public.kiosk_devices
  set last_seen_at = v_now
  where token_hash = p_token_hash;

  return jsonb_build_object(
    'ok', true, 'status', 'checked_in',
    'attendance_id', v_attendance.id,
    'arrival_time', v_attendance.arrival_time,
    'walk_in', true,
    'set_id', v_attendance.set_id
  );
end;
$$;

revoke all on function public.kiosk_check_in(
  text, uuid, text, text, boolean, boolean
) from public, anon, authenticated;
grant execute on function public.kiosk_check_in(
  text, uuid, text, text, boolean, boolean
) to service_role;
