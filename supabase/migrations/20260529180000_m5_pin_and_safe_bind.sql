-- M5 PIN login (per-student opt-in) + race-safe binding.
--
-- Background:
--   * m5_bind_device unconditionally deactivates active bindings for the same
--     device OR student and re-inserts, so two devices binding the same student
--     concurrently steal each other's binding.
--   * The student list is only filtered at query time and never re-published to
--     other unbound devices, so a late device sees a stale list and binds the
--     wrong student.
--
-- This migration adds:
--   1) m5_student_pins        : per-student PIN gate (required flag + hash + lockout)
--   2) m5_get_students_today_basic : now also returns pin_required / pin_set
--   3) m5_bind_device_safe    : atomic bind with same-device reconnect, already_bound
--                               guard and PIN verification (5-attempt lockout).

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.m5_student_pins (
  academy_id uuid not null,
  student_id uuid not null primary key,
  pin_required boolean not null default false,
  pin_hash text null,
  failed_attempts integer not null default 0,
  locked_until timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.m5_student_pins enable row level security;
do $$ begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'm5_student_pins' and policyname = 'm5_student_pins_select'
  ) then
    create policy m5_student_pins_select on public.m5_student_pins for select using (true);
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- students_today now includes the PIN gate flags (return type changes → drop)
-- ---------------------------------------------------------------------------
drop function if exists public.m5_get_students_today_basic(uuid);

create or replace function public.m5_get_students_today_basic(
  p_academy_id uuid
) returns table(
  student_id uuid,
  name text,
  school text,
  grade integer,
  arrival_time timestamptz,
  start_hour integer,
  start_minute integer,
  pin_required boolean,
  pin_set boolean
) as $$
declare
  today_date date := (now() at time zone 'Asia/Seoul')::date;
begin
  return query
  with hidden as (
    select
      so.student_id,
      date_trunc('minute', so.original_class_datetime at time zone 'Asia/Seoul') as orig_min
    from public.session_overrides so
    where so.academy_id = p_academy_id
      and so.override_type = 'replace'
      and so.reason = 'makeup'
      and so.status <> 'canceled'
      and so.original_class_datetime is not null
      and (so.original_class_datetime at time zone 'Asia/Seoul')::date = today_date
  ),
  base as (
    select
      ar.*,
      coalesce(nullif(ar.set_id, ''), stb.set_id) as eff_set_id
    from public.attendance_records ar
    left join lateral (
      select b.set_id
      from public.student_time_blocks b
      where b.academy_id = p_academy_id
        and b.student_id = ar.student_id
        and b.set_id is not null and b.set_id <> ''
        and b.day_index = case
          when extract(dow from (ar.class_date_time at time zone 'Asia/Seoul'))::int = 0 then 6
          else extract(dow from (ar.class_date_time at time zone 'Asia/Seoul'))::int - 1
        end
        and b.start_hour = extract(hour from (ar.class_date_time at time zone 'Asia/Seoul'))::int
        and b.start_minute = extract(minute from (ar.class_date_time at time zone 'Asia/Seoul'))::int
        and b.start_date <= (ar.class_date_time at time zone 'Asia/Seoul')::date
        and (b.end_date is null or b.end_date >= (ar.class_date_time at time zone 'Asia/Seoul')::date)
      order by b.start_date desc nulls last, b.created_at desc
      limit 1
    ) stb on true
    where ar.academy_id = p_academy_id
      and ar.date = today_date
      and ar.class_date_time is not null
      and not (
        coalesce(ar.is_planned, false) = true
        and coalesce(ar.is_present, false) = false
        and ar.arrival_time is null
        and ar.departure_time is null
        and exists (
          select 1 from hidden h
          where h.student_id = ar.student_id
            and h.orig_min = date_trunc('minute', ar.class_date_time at time zone 'Asia/Seoul')
        )
      )
  ),
  ranked as (
    select
      b.*,
      row_number() over (
        partition by b.eff_set_id
        order by
          case when (b.arrival_time is not null or b.is_present = true) then 1 else 0 end desc,
          case when coalesce(b.is_planned, false) then 1 else 0 end asc,
          b.class_date_time asc
      ) as rn
    from base b
    where b.eff_set_id is not null and b.eff_set_id <> ''
  ),
  selected as (
    select r.*
    from ranked r
    where r.rn = 1
      and r.departure_time is null
  )
  select
    s.student_id,
    st.name,
    st.school,
    st.grade,
    s.arrival_time,
    extract(hour from (s.class_date_time at time zone 'Asia/Seoul'))::int as start_hour,
    extract(minute from (s.class_date_time at time zone 'Asia/Seoul'))::int as start_minute,
    coalesce(p.pin_required, false) as pin_required,
    (p.pin_hash is not null) as pin_set
  from selected s
  join public.students st on st.id = s.student_id
  left join public.m5_student_pins p
    on p.student_id = s.student_id and p.academy_id = p_academy_id
  order by s.class_date_time asc, st.name asc;
end; $$ language plpgsql security definer set search_path=public;

grant execute on function public.m5_get_students_today_basic(uuid) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Race-safe bind with PIN gate.
-- Returns jsonb { status, attempts_left?, locked_seconds? } where status is one of:
--   ok | already_bound | pin_setup_required | pin_invalid | locked | error
-- ---------------------------------------------------------------------------
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
  v_now timestamptz := now();
  v_locked_seconds integer;
begin
  if p_academy_id is null or p_device_id is null or p_device_id = '' or p_student_id is null then
    return jsonb_build_object('status', 'error', 'message', 'invalid args');
  end if;

  -- serialize concurrent binds for the same (academy, student)
  perform pg_advisory_xact_lock(hashtext(p_academy_id::text || ':' || p_student_id::text));

  -- same-device reconnect/re-announce: keep the existing binding, skip PIN
  if exists (
    select 1 from public.m5_device_bindings
    where academy_id = p_academy_id and device_id = p_device_id
      and student_id = p_student_id and active = true
  ) then
    return jsonb_build_object('status', 'ok');
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
  select * into v_pin from public.m5_student_pins
   where academy_id = p_academy_id and student_id = p_student_id;
  v_has_pin_row := found;

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

-- ---------------------------------------------------------------------------
-- TEST seed: enable PIN for 감나단 only (pin not set yet → first login defines it)
-- ---------------------------------------------------------------------------
insert into public.m5_student_pins (academy_id, student_id, pin_required)
values ('3ff51b8d-3cfb-4a36-a1a1-b63aebbde677', '8b995712-5fa1-4b43-989f-eab30165fcdb', true)
on conflict (student_id) do update set pin_required = true, updated_at = now();
