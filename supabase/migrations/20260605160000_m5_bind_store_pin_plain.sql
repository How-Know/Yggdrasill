-- Store the plaintext PIN on M5 first-login so the teacher app can display the
-- current PIN for students who set it themselves (not only teacher-set PINs).
--
-- Same logic as 20260530120000_m5_bind_safe_pin_reconnect.sql, with one change:
-- the first-login branch (pin_required, pin_hash null) now also writes pin_plain.

create or replace function public.m5_bind_device_safe(
  p_academy_id uuid,
  p_device_id text,
  p_student_id uuid,
  p_pin text default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_pin public.m5_student_pins%rowtype;
  v_has_pin_row boolean := false;
  v_pin_enforced boolean := false;        -- pin_required AND a PIN is already set
  v_reconnect boolean := false;            -- same device already actively bound
  v_now timestamptz := now();
  v_locked_seconds integer;
begin
  if p_academy_id is null or p_device_id is null or p_device_id = '' or p_student_id is null then
    return jsonb_build_object('status', 'error', 'message', 'invalid args');
  end if;

  perform pg_advisory_xact_lock(hashtext(p_academy_id::text || ':' || p_student_id::text));

  select * into v_pin from public.m5_student_pins
   where academy_id = p_academy_id and student_id = p_student_id;
  v_has_pin_row := found;
  v_pin_enforced := v_has_pin_row and v_pin.pin_required and v_pin.pin_hash is not null;

  v_reconnect := exists (
    select 1 from public.m5_device_bindings
    where academy_id = p_academy_id and device_id = p_device_id
      and student_id = p_student_id and active = true
  );

  if v_reconnect then
    if not v_pin_enforced then
      return jsonb_build_object('status', 'ok');
    elsif p_pin is null or length(p_pin) = 0 then
      return jsonb_build_object('status', 'pin_required');
    end if;
  end if;

  if exists (
    select 1 from public.m5_device_bindings
    where academy_id = p_academy_id and student_id = p_student_id
      and active = true and device_id <> p_device_id
  ) then
    return jsonb_build_object('status', 'already_bound');
  end if;

  if v_has_pin_row and v_pin.pin_required then
    if v_pin.pin_hash is null then
      -- first login: a PIN must be supplied to set it
      if p_pin is null or length(p_pin) = 0 then
        return jsonb_build_object('status', 'pin_setup_required');
      end if;
      update public.m5_student_pins
         set pin_hash = crypt(p_pin, gen_salt('bf')),
             pin_plain = p_pin,
             failed_attempts = 0,
             locked_until = null,
             updated_at = v_now
       where academy_id = p_academy_id and student_id = p_student_id;
    else
      if v_pin.locked_until is not null and v_pin.locked_until > v_now then
        v_locked_seconds := ceil(extract(epoch from (v_pin.locked_until - v_now)))::int;
        return jsonb_build_object('status', 'locked', 'locked_seconds', v_locked_seconds);
      end if;
      if p_pin is null or length(p_pin) = 0 then
        return jsonb_build_object('status', 'pin_invalid', 'attempts_left', greatest(5 - v_pin.failed_attempts, 0));
      end if;
      if v_pin.pin_hash = crypt(p_pin, v_pin.pin_hash) then
        update public.m5_student_pins
           set failed_attempts = 0,
               locked_until = null,
               pin_plain = coalesce(pin_plain, p_pin),
               updated_at = v_now
         where academy_id = p_academy_id and student_id = p_student_id;
      elsif v_pin.failed_attempts + 1 >= 5 then
        update public.m5_student_pins
           set failed_attempts = 0,
               locked_until = v_now + interval '5 minutes',
               updated_at = v_now
         where academy_id = p_academy_id and student_id = p_student_id;
        return jsonb_build_object('status', 'locked', 'locked_seconds', 300);
      else
        update public.m5_student_pins
           set failed_attempts = failed_attempts + 1, updated_at = v_now
         where academy_id = p_academy_id and student_id = p_student_id;
        return jsonb_build_object('status', 'pin_invalid', 'attempts_left', greatest(5 - (v_pin.failed_attempts + 1), 0));
      end if;
    end if;
  end if;

  update public.m5_device_bindings
     set active = false, unbound_at = v_now, updated_at = v_now
   where academy_id = p_academy_id
     and (device_id = p_device_id or student_id = p_student_id)
     and active = true;

  insert into public.m5_device_bindings(academy_id, device_id, student_id, active, bound_at, updated_at)
  values (p_academy_id, p_device_id, p_student_id, true, v_now, v_now);

  return jsonb_build_object('status', 'ok');
end; $$;

grant execute on function public.m5_bind_device_safe(uuid, text, uuid, text) to anon, authenticated;
