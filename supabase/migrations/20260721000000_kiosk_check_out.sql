-- ---------------------------------------------------------------------------
-- Kiosk check-out (하원) RPC.
-- Mirrors kiosk_check_in PIN verification, then stamps departure_time on
-- today's open attendance record for the student.
-- ---------------------------------------------------------------------------
create or replace function public.kiosk_check_out(
  p_token_hash text,
  p_student_id uuid,
  p_pin text,
  p_request_id text
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
begin
  if p_request_id is null or length(btrim(p_request_id)) not between 1 and 128 then
    return jsonb_build_object('ok', false, 'error', 'invalid_request_id');
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(coalesce(p_token_hash, '') || ':out:' || p_request_id, 0)
  );

  select academy_id into v_academy
  from public.kiosk_devices
  where token_hash = p_token_hash and is_active and academy_id is not null;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'invalid_token');
  end if;

  if not exists (
    select 1 from public.students s
    where s.id = p_student_id and s.academy_id = v_academy
  ) then
    return jsonb_build_object('ok', false, 'error', 'student_not_found');
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(v_academy::text || ':' || p_student_id::text, 0)
  );

  -- PIN verification (same policy as kiosk_check_in).
  select * into v_pin
  from public.m5_student_pins
  where academy_id = v_academy and student_id = p_student_id
  for update;
  if found and v_pin.pin_required then
    if v_pin.pin_hash is null then
      return jsonb_build_object('ok', false, 'error', 'pin_setup_required');
    end if;
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

  -- Find today's checked-in (arrived, not yet departed) record.
  select * into v_attendance
  from public.attendance_records
  where academy_id = v_academy
    and student_id = p_student_id
    and coalesce(date, (class_date_time at time zone 'Asia/Seoul')::date) = v_today
    and arrival_time is not null
    and departure_time is null
  order by arrival_time desc
  limit 1
  for update;

  if not found then
    -- Distinguish "already departed today" from "never arrived".
    if exists (
      select 1 from public.attendance_records
      where academy_id = v_academy
        and student_id = p_student_id
        and coalesce(date, (class_date_time at time zone 'Asia/Seoul')::date) = v_today
        and departure_time is not null
    ) then
      return jsonb_build_object('ok', false, 'error', 'already_checked_out');
    end if;
    return jsonb_build_object('ok', false, 'error', 'not_checked_in');
  end if;

  update public.attendance_records
  set departure_time = v_now,
      updated_at = v_now
  where id = v_attendance.id
  returning * into v_attendance;

  update public.kiosk_devices set last_seen_at = v_now where token_hash = p_token_hash;

  return jsonb_build_object(
    'ok', true, 'status', 'checked_out',
    'attendance_id', v_attendance.id,
    'departure_time', v_attendance.departure_time
  );
end;
$$;

revoke all on function public.kiosk_check_out(text, uuid, text, text) from public, anon, authenticated;
grant execute on function public.kiosk_check_out(text, uuid, text, text) to service_role;
