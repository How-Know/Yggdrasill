-- Fix: PIN bypass via the same-device reconnect short-circuit.
--
-- m5_bind_device_safe returned 'ok' for any active (device, student) binding
-- BEFORE verifying the PIN. After 감나단 logged in once, the active binding row
-- persisted in m5_device_bindings, so on the next login attempt (fresh PIN page
-- after an M5 restart, or the silent boot re-announce) the reconnect exception
-- fired and ANY PIN was accepted.
--
-- New behavior for PIN-enforced students (pin_required AND pin_hash set):
--   * Interactive login (p_pin provided) → always verify the PIN, even when an
--     active same-device binding already exists.
--   * Silent re-announce (p_pin null/empty) → do NOT auto-confirm; return
--     'pin_required' so the device clears its local binding and re-authenticates.
-- Non-PIN students (or PIN not yet set) keep the original reconnect shortcut.

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

  -- serialize concurrent binds for the same (academy, student)
  perform pg_advisory_xact_lock(hashtext(p_academy_id::text || ':' || p_student_id::text));

  -- load the PIN gate up front so reconnect can be evaluated against it
  select * into v_pin from public.m5_student_pins
   where academy_id = p_academy_id and student_id = p_student_id;
  v_has_pin_row := found;
  v_pin_enforced := v_has_pin_row and v_pin.pin_required and v_pin.pin_hash is not null;

  v_reconnect := exists (
    select 1 from public.m5_device_bindings
    where academy_id = p_academy_id and device_id = p_device_id
      and student_id = p_student_id and active = true
  );

  -- same-device reconnect/re-announce
  if v_reconnect then
    if not v_pin_enforced then
      -- non-PIN (or PIN not yet set): keep the existing binding, skip PIN
      return jsonb_build_object('status', 'ok');
    elsif p_pin is null or length(p_pin) = 0 then
      -- PIN required but no PIN submitted (silent boot re-announce):
      -- force the device to re-authenticate with the PIN.
      return jsonb_build_object('status', 'pin_required');
    end if;
    -- else: PIN-enforced + PIN submitted → fall through to verification below
  end if;

  -- student already actively bound on a different device → do not steal
  if exists (
    select 1 from public.m5_device_bindings
    where academy_id = p_academy_id and student_id = p_student_id
      and active = true and device_id <> p_device_id
  ) then
    return jsonb_build_object('status', 'already_bound');
  end if;

  -- PIN gate
  if v_has_pin_row and v_pin.pin_required then
    if v_pin.pin_hash is null then
      -- first login: a PIN must be supplied to set it
      if p_pin is null or length(p_pin) = 0 then
        return jsonb_build_object('status', 'pin_setup_required');
      end if;
      update public.m5_student_pins
         set pin_hash = crypt(p_pin, gen_salt('bf')),
             failed_attempts = 0,
             locked_until = null,
             updated_at = v_now
       where academy_id = p_academy_id and student_id = p_student_id;
    else
      -- locked out?
      if v_pin.locked_until is not null and v_pin.locked_until > v_now then
        v_locked_seconds := ceil(extract(epoch from (v_pin.locked_until - v_now)))::int;
        return jsonb_build_object('status', 'locked', 'locked_seconds', v_locked_seconds);
      end if;
      if p_pin is null or length(p_pin) = 0 then
        return jsonb_build_object('status', 'pin_invalid', 'attempts_left', greatest(5 - v_pin.failed_attempts, 0));
      end if;
      if v_pin.pin_hash = crypt(p_pin, v_pin.pin_hash) then
        update public.m5_student_pins
           set failed_attempts = 0, locked_until = null, updated_at = v_now
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

  -- passed all gates → bind (same semantics as m5_bind_device)
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
