-- Teacher-managed M5 student PIN: store a display plaintext alongside the bcrypt
-- hash so the teacher app can show and edit a student's current PIN.
--
-- Adds:
--   1) m5_student_pins.pin_plain          : display-only plaintext (academy-internal)
--   2) m5_admin_get_student_pin(...)      : returns current PIN + state for the panel
--   3) m5_admin_set_student_pin(...)      : teacher sets/changes a 4~8 digit PIN
--   4) m5_admin_clear_student_pin(...)    : disable PIN gate (revert to instant bind)

create extension if not exists pgcrypto with schema extensions;

alter table public.m5_student_pins
  add column if not exists pin_plain text null;

-- ---------------------------------------------------------------------------
-- Read current PIN + gate state for the teacher panel.
-- ---------------------------------------------------------------------------
create or replace function public.m5_admin_get_student_pin(
  p_academy_id uuid,
  p_student_id uuid
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v public.m5_student_pins%rowtype;
  v_now timestamptz := now();
  v_locked boolean := false;
  v_locked_seconds integer := 0;
begin
  if p_academy_id is null or p_student_id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid args');
  end if;

  select * into v from public.m5_student_pins
   where academy_id = p_academy_id and student_id = p_student_id;

  if not found then
    return jsonb_build_object(
      'ok', true,
      'pin_required', false,
      'pin_set', false,
      'pin', null,
      'locked', false,
      'locked_seconds', 0
    );
  end if;

  if v.locked_until is not null and v.locked_until > v_now then
    v_locked := true;
    v_locked_seconds := ceil(extract(epoch from (v.locked_until - v_now)))::int;
  end if;

  return jsonb_build_object(
    'ok', true,
    'pin_required', v.pin_required,
    'pin_set', (v.pin_hash is not null),
    'pin', v.pin_plain,
    'locked', v_locked,
    'locked_seconds', v_locked_seconds
  );
end; $$;

grant execute on function public.m5_admin_get_student_pin(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Teacher sets/changes a student's PIN (4~8 digits). Enables the PIN gate,
-- stores both the hash (for verification) and the plaintext (for display),
-- and clears any lockout / failed attempts.
-- ---------------------------------------------------------------------------
create or replace function public.m5_admin_set_student_pin(
  p_academy_id uuid,
  p_student_id uuid,
  p_pin text
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_now timestamptz := now();
begin
  if p_academy_id is null or p_student_id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid args');
  end if;
  if p_pin is null or p_pin !~ '^[0-9]{4,8}$' then
    return jsonb_build_object('ok', false, 'error', 'invalid_pin');
  end if;

  insert into public.m5_student_pins(
    academy_id, student_id, pin_required, pin_hash, pin_plain,
    failed_attempts, locked_until, updated_at
  )
  values (
    p_academy_id, p_student_id, true,
    crypt(p_pin, gen_salt('bf')), p_pin,
    0, null, v_now
  )
  on conflict (student_id) do update set
    academy_id = excluded.academy_id,
    pin_required = true,
    pin_hash = excluded.pin_hash,
    pin_plain = excluded.pin_plain,
    failed_attempts = 0,
    locked_until = null,
    updated_at = v_now;

  return jsonb_build_object('ok', true);
end; $$;

grant execute on function public.m5_admin_set_student_pin(uuid, uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Disable the PIN gate for a student (revert to the instant-bind policy).
-- ---------------------------------------------------------------------------
create or replace function public.m5_admin_clear_student_pin(
  p_academy_id uuid,
  p_student_id uuid
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_academy_id is null or p_student_id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid args');
  end if;

  update public.m5_student_pins
     set pin_required = false,
         pin_hash = null,
         pin_plain = null,
         failed_attempts = 0,
         locked_until = null,
         updated_at = now()
   where academy_id = p_academy_id and student_id = p_student_id;

  return jsonb_build_object('ok', true);
end; $$;

grant execute on function public.m5_admin_clear_student_pin(uuid, uuid) to authenticated;
