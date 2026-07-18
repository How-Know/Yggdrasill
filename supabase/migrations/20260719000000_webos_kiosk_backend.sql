-- webOS attendance kiosk backend.
-- Public kiosk clients never receive the service-role key. They authenticate with a
-- random device token whose SHA-256 digest is the only value persisted in Postgres.

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
create table public.kiosk_devices (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid references public.academies(id) on delete cascade,
  device_id text not null,
  device_name text not null,
  token_hash text,
  is_active boolean not null default true,
  paired_at timestamptz,
  last_seen_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint kiosk_devices_device_id_length check (length(device_id) between 1 and 200),
  constraint kiosk_devices_device_name_length check (length(device_name) between 1 and 200),
  constraint kiosk_devices_token_hash_format check (
    token_hash is null or token_hash ~ '^[0-9a-f]{64}$'
  ),
  unique (device_id),
  unique (token_hash)
);

create index kiosk_devices_academy_idx
  on public.kiosk_devices(academy_id, is_active);

create table public.kiosk_pairing_codes (
  id uuid primary key default gen_random_uuid(),
  device_id uuid not null references public.kiosk_devices(id) on delete cascade,
  academy_id uuid references public.academies(id) on delete cascade,
  code text not null,
  expires_at timestamptz not null,
  approved_at timestamptz,
  approved_by uuid references auth.users(id) on delete set null,
  consumed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint kiosk_pairing_codes_code_format check (code ~ '^[0-9]{6}$'),
  constraint kiosk_pairing_codes_expiry check (expires_at > created_at)
);

create unique index kiosk_pairing_codes_live_code_idx
  on public.kiosk_pairing_codes(code)
  where consumed_at is null;
create index kiosk_pairing_codes_device_idx
  on public.kiosk_pairing_codes(device_id, created_at desc);

create table public.academy_announcements (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  title text not null,
  body text not null,
  published_at timestamptz not null default now(),
  expires_at timestamptz,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null,
  constraint academy_announcements_title_length check (length(btrim(title)) between 1 and 200),
  constraint academy_announcements_body_length check (length(btrim(body)) between 1 and 10000),
  constraint academy_announcements_expiry check (
    expires_at is null or expires_at > published_at
  )
);

create index academy_announcements_active_idx
  on public.academy_announcements(academy_id, published_at desc)
  where is_active;

alter table public.attendance_records
  add column if not exists kiosk_request_id text;
create unique index if not exists attendance_records_kiosk_request_idx
  on public.attendance_records(academy_id, kiosk_request_id)
  where kiosk_request_id is not null;

-- ---------------------------------------------------------------------------
-- Audit timestamps
-- ---------------------------------------------------------------------------
create or replace function public.kiosk_set_updated_at()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger kiosk_devices_updated_at
before update on public.kiosk_devices
for each row execute function public.kiosk_set_updated_at();

create trigger kiosk_pairing_codes_updated_at
before update on public.kiosk_pairing_codes
for each row execute function public.kiosk_set_updated_at();

create trigger academy_announcements_updated_at
before update on public.academy_announcements
for each row execute function public.kiosk_set_updated_at();

-- ---------------------------------------------------------------------------
-- Tenant RLS
-- ---------------------------------------------------------------------------
alter table public.kiosk_devices enable row level security;
alter table public.kiosk_pairing_codes enable row level security;
alter table public.academy_announcements enable row level security;

create policy kiosk_devices_member_select
on public.kiosk_devices for select to authenticated
using (
  exists (
    select 1 from public.memberships m
    where m.academy_id = kiosk_devices.academy_id
      and m.user_id = auth.uid()
  )
);

create policy kiosk_pairing_codes_member_select
on public.kiosk_pairing_codes for select to authenticated
using (
  exists (
    select 1 from public.memberships m
    where m.academy_id = kiosk_pairing_codes.academy_id
      and m.user_id = auth.uid()
  )
);

create policy academy_announcements_member_all
on public.academy_announcements for all to authenticated
using (
  exists (
    select 1 from public.memberships m
    where m.academy_id = academy_announcements.academy_id
      and m.user_id = auth.uid()
  )
)
with check (
  exists (
    select 1 from public.memberships m
    where m.academy_id = academy_announcements.academy_id
      and m.user_id = auth.uid()
  )
);

revoke all on table public.kiosk_devices from public, anon, authenticated;
revoke all on table public.kiosk_pairing_codes from public, anon, authenticated;
revoke all on table public.academy_announcements from public, anon, authenticated;
grant select on table public.kiosk_devices to authenticated;
grant select, insert, update, delete on table public.academy_announcements to authenticated;
grant all on table public.kiosk_devices, public.kiosk_pairing_codes,
  public.academy_announcements to service_role;

-- Existing M5/admin SECURITY DEFINER RPCs keep working, but anonymous clients can
-- no longer read bcrypt hashes or the legacy display plaintext directly.
drop policy if exists m5_student_pins_select on public.m5_student_pins;
create policy m5_student_pins_member_select
on public.m5_student_pins for select to authenticated
using (
  exists (
    select 1 from public.memberships m
    where m.academy_id = m5_student_pins.academy_id
      and m.user_id = auth.uid()
  )
);
revoke select on table public.m5_student_pins from public, anon;

-- ---------------------------------------------------------------------------
-- Authenticated PC RPCs
-- ---------------------------------------------------------------------------
create or replace function public.kiosk_approve_pairing(
  p_academy_id uuid,
  p_code text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pair public.kiosk_pairing_codes%rowtype;
begin
  if not exists (
    select 1 from public.memberships m
    where m.academy_id = p_academy_id and m.user_id = auth.uid()
  ) then
    raise exception 'not_a_member' using errcode = '42501';
  end if;

  select * into v_pair
  from public.kiosk_pairing_codes
  where code = p_code
    and consumed_at is null
  for update;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'pairing_not_found');
  end if;
  if v_pair.expires_at <= now() then
    return jsonb_build_object('ok', false, 'error', 'pairing_expired');
  end if;
  if v_pair.approved_at is not null and v_pair.academy_id <> p_academy_id then
    return jsonb_build_object('ok', false, 'error', 'pairing_already_approved');
  end if;

  update public.kiosk_pairing_codes
  set academy_id = p_academy_id,
      approved_at = coalesce(approved_at, now()),
      approved_by = coalesce(approved_by, auth.uid())
  where id = v_pair.id;

  return jsonb_build_object('ok', true, 'device_id', v_pair.device_id);
end;
$$;

create or replace function public.kiosk_list_devices(p_academy_id uuid)
returns table (
  id uuid,
  device_id text,
  device_name text,
  is_active boolean,
  paired_at timestamptz,
  last_seen_at timestamptz,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from public.memberships m
    where m.academy_id = p_academy_id and m.user_id = auth.uid()
  ) then
    raise exception 'not_a_member' using errcode = '42501';
  end if;

  return query
  select d.id, d.device_id, d.device_name, d.is_active, d.paired_at,
         d.last_seen_at, d.created_at, d.updated_at
  from public.kiosk_devices d
  where d.academy_id = p_academy_id
  order by d.device_name, d.created_at;
end;
$$;

create or replace function public.kiosk_list_announcements(
  p_academy_id uuid,
  p_include_inactive boolean default true
) returns setof public.academy_announcements
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from public.memberships m
    where m.academy_id = p_academy_id and m.user_id = auth.uid()
  ) then
    raise exception 'not_a_member' using errcode = '42501';
  end if;

  return query
  select a.*
  from public.academy_announcements a
  where a.academy_id = p_academy_id
    and (p_include_inactive or a.is_active)
  order by a.published_at desc, a.created_at desc;
end;
$$;

create or replace function public.kiosk_create_announcement(
  p_academy_id uuid,
  p_title text,
  p_body text,
  p_published_at timestamptz default now(),
  p_expires_at timestamptz default null,
  p_is_active boolean default true
) returns public.academy_announcements
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.academy_announcements;
begin
  if not exists (
    select 1 from public.memberships m
    where m.academy_id = p_academy_id and m.user_id = auth.uid()
  ) then
    raise exception 'not_a_member' using errcode = '42501';
  end if;

  insert into public.academy_announcements(
    academy_id, title, body, published_at, expires_at, is_active,
    created_by, updated_by
  ) values (
    p_academy_id, btrim(p_title), btrim(p_body), coalesce(p_published_at, now()),
    p_expires_at, coalesce(p_is_active, true), auth.uid(), auth.uid()
  )
  returning * into v_row;
  return v_row;
end;
$$;

create or replace function public.kiosk_update_announcement(
  p_announcement_id uuid,
  p_patch jsonb
) returns public.academy_announcements
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.academy_announcements;
begin
  select * into v_row
  from public.academy_announcements a
  where a.id = p_announcement_id
    and exists (
      select 1 from public.memberships m
      where m.academy_id = a.academy_id and m.user_id = auth.uid()
    )
  for update;
  if not found then
    raise exception 'announcement_not_found' using errcode = 'P0002';
  end if;
  if p_patch is null
     or p_patch - array['title','body','published_at','expires_at','is_active'] <> '{}'::jsonb then
    raise exception 'invalid_patch';
  end if;

  update public.academy_announcements
  set title = case when p_patch ? 'title' then btrim(p_patch->>'title') else title end,
      body = case when p_patch ? 'body' then btrim(p_patch->>'body') else body end,
      published_at = case when p_patch ? 'published_at'
        then (p_patch->>'published_at')::timestamptz else published_at end,
      expires_at = case when p_patch ? 'expires_at'
        then nullif(p_patch->>'expires_at', '')::timestamptz else expires_at end,
      is_active = case when p_patch ? 'is_active'
        then (p_patch->>'is_active')::boolean else is_active end,
      updated_by = auth.uid()
  where id = p_announcement_id
  returning * into v_row;
  return v_row;
end;
$$;

create or replace function public.kiosk_end_announcement(p_announcement_id uuid)
returns public.academy_announcements
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.academy_announcements;
begin
  update public.academy_announcements a
  set is_active = false,
      updated_by = auth.uid()
  where a.id = p_announcement_id
    and exists (
      select 1 from public.memberships m
      where m.academy_id = a.academy_id and m.user_id = auth.uid()
    )
  returning * into v_row;
  if not found then
    raise exception 'announcement_not_found' using errcode = 'P0002';
  end if;
  return v_row;
end;
$$;

create or replace function public.kiosk_delete_announcement(p_announcement_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.academy_announcements a
  where a.id = p_announcement_id
    and exists (
      select 1 from public.memberships m
      where m.academy_id = a.academy_id and m.user_id = auth.uid()
    );
  if not found then
    raise exception 'announcement_not_found' using errcode = 'P0002';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Server-only kiosk RPCs
-- ---------------------------------------------------------------------------
create or replace function public.kiosk_begin_pairing(
  p_device_id text,
  p_device_name text,
  p_code text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_device uuid;
  v_expiry timestamptz := now() + interval '10 minutes';
begin
  if length(btrim(p_device_id)) not between 1 and 200
     or length(btrim(p_device_name)) not between 1 and 200
     or p_code !~ '^[0-9]{6}$' then
    return jsonb_build_object('ok', false, 'error', 'invalid_request');
  end if;

  insert into public.kiosk_devices(device_id, device_name)
  values (btrim(p_device_id), btrim(p_device_name))
  on conflict (device_id) do update
    set device_name = excluded.device_name
  returning id into v_device;

  update public.kiosk_pairing_codes
  set consumed_at = now()
  where device_id = v_device and consumed_at is null;

  update public.kiosk_pairing_codes
  set consumed_at = now()
  where consumed_at is null and expires_at <= now();

  insert into public.kiosk_pairing_codes(device_id, code, expires_at)
  values (v_device, p_code, v_expiry);

  return jsonb_build_object('ok', true, 'code', p_code, 'expires_at', v_expiry);
end;
$$;

create or replace function public.kiosk_claim_pairing(
  p_device_id text,
  p_code text,
  p_token_hash text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pair public.kiosk_pairing_codes%rowtype;
  v_device uuid;
begin
  if p_token_hash !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('ok', false, 'error', 'invalid_token_hash');
  end if;

  select p.* into v_pair
  from public.kiosk_pairing_codes p
  join public.kiosk_devices d on d.id = p.device_id
  where d.device_id = p_device_id
    and p.code = p_code
    and p.consumed_at is null
  for update of p;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'pairing_not_found');
  end if;
  if v_pair.expires_at <= now() then
    return jsonb_build_object('ok', false, 'error', 'pairing_expired');
  end if;
  if v_pair.approved_at is null or v_pair.academy_id is null then
    return jsonb_build_object('ok', false, 'error', 'pairing_pending');
  end if;

  v_device := v_pair.device_id;
  update public.kiosk_devices
  set academy_id = v_pair.academy_id,
      token_hash = p_token_hash,
      is_active = true,
      paired_at = now(),
      last_seen_at = now()
  where id = v_device;

  update public.kiosk_pairing_codes set consumed_at = now() where id = v_pair.id;
  return jsonb_build_object('ok', true, 'academy_id', v_pair.academy_id);
end;
$$;

create or replace function public.kiosk_bootstrap(p_token_hash text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_device public.kiosk_devices%rowtype;
  v_academy_name text;
  v_address text;
  v_announcement jsonb;
begin
  select * into v_device
  from public.kiosk_devices
  where token_hash = p_token_hash and is_active and academy_id is not null;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'invalid_token');
  end if;

  update public.kiosk_devices set last_seen_at = now() where id = v_device.id;
  select coalesce(s.name, a.name), s.address
    into v_academy_name, v_address
  from public.academies a
  left join public.academy_settings s on s.academy_id = a.id
  where a.id = v_device.academy_id;

  select jsonb_build_object(
    'id', x.id, 'title', x.title, 'body', x.body,
    'published_at', x.published_at, 'expires_at', x.expires_at
  ) into v_announcement
  from public.academy_announcements x
  where x.academy_id = v_device.academy_id
    and x.is_active
    and x.published_at <= now()
    and (x.expires_at is null or x.expires_at > now())
  order by x.published_at desc, x.created_at desc
  limit 1;

  return jsonb_build_object(
    'ok', true,
    'device', jsonb_build_object(
      'id', v_device.device_id, 'name', v_device.device_name
    ),
    'academy', jsonb_build_object(
      'id', v_device.academy_id, 'name', v_academy_name, 'address', v_address
    ),
    'announcement', v_announcement
  );
end;
$$;

create or replace function public.kiosk_list_today(p_token_hash text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_items jsonb;
begin
  select academy_id into v_academy
  from public.kiosk_devices
  where token_hash = p_token_hash and is_active and academy_id is not null;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'invalid_token');
  end if;

  update public.kiosk_devices set last_seen_at = now() where token_hash = p_token_hash;
  select coalesce(jsonb_agg(to_jsonb(q) order by q.class_date_time, q.name), '[]'::jsonb)
  into v_items
  from (
    select ar.id as attendance_id, s.id as student_id, s.name, s.school, s.grade,
           ar.set_id, ar.session_type_id, ar.class_date_time, ar.class_end_time,
           ar.arrival_time, (ar.arrival_time is not null) as checked_in,
           coalesce(pin.pin_required, false) as pin_required,
           (pin.pin_hash is not null) as pin_set
    from public.attendance_records ar
    join public.students s on s.id = ar.student_id and s.academy_id = v_academy
    left join public.m5_student_pins pin
      on pin.student_id = s.id and pin.academy_id = v_academy
    where ar.academy_id = v_academy
      and ar.is_planned is true
      and coalesce(ar.date, (ar.class_date_time at time zone 'Asia/Seoul')::date) = v_today
      and ar.departure_time is null
      and not exists (
        select 1
        from public.session_overrides so
        where so.academy_id = v_academy
          and so.student_id = ar.student_id
          and so.override_type = 'replace'
          and so.reason = 'makeup'
          and so.status <> 'canceled'
          and so.original_class_datetime is not null
          and date_trunc(
            'minute',
            so.original_class_datetime at time zone 'Asia/Seoul'
          ) = date_trunc(
            'minute',
            ar.class_date_time at time zone 'Asia/Seoul'
          )
      )
  ) q;
  return jsonb_build_object('ok', true, 'date', v_today, 'students', v_items);
end;
$$;

create or replace function public.kiosk_search_students(
  p_token_hash text,
  p_query text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_items jsonb;
begin
  select academy_id into v_academy
  from public.kiosk_devices
  where token_hash = p_token_hash and is_active and academy_id is not null;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'invalid_token');
  end if;
  if length(btrim(coalesce(p_query, ''))) < 1 then
    return jsonb_build_object('ok', false, 'error', 'query_required');
  end if;

  update public.kiosk_devices set last_seen_at = now() where token_hash = p_token_hash;
  select coalesce(jsonb_agg(to_jsonb(q) order by q.name), '[]'::jsonb)
  into v_items
  from (
    select s.id as student_id, s.name, s.school, s.grade,
           coalesce(pin.pin_required, false) as pin_required,
           (pin.pin_hash is not null) as pin_set
    from public.students s
    left join public.m5_student_pins pin
      on pin.student_id = s.id and pin.academy_id = v_academy
    where s.academy_id = v_academy
      and (
        -- PostgreSQL does not decompose Hangul syllables into choseong.
        -- For a choseong query return a bounded academy roster and let the
        -- kiosk's Korean matcher apply the exact initial-consonant filter.
        btrim(p_query) ~ '^[ㄱ-ㅎ]+$'
        or s.name ilike '%' || btrim(p_query) || '%'
      )
    order by s.name
    limit case when btrim(p_query) ~ '^[ㄱ-ㅎ]+$' then 200 else 30 end
  ) q;
  return jsonb_build_object('ok', true, 'students', v_items);
end;
$$;

create or replace function public.kiosk_check_in(
  p_token_hash text,
  p_student_id uuid,
  p_pin text,
  p_request_id text,
  p_walk_in boolean default false
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

-- ---------------------------------------------------------------------------
-- Function privileges (functions are PUBLIC-executable by default).
-- ---------------------------------------------------------------------------
revoke all on function public.kiosk_set_updated_at() from public, anon, authenticated;

revoke all on function public.kiosk_approve_pairing(uuid, text) from public, anon, authenticated;
revoke all on function public.kiosk_list_devices(uuid) from public, anon, authenticated;
revoke all on function public.kiosk_list_announcements(uuid, boolean) from public, anon, authenticated;
revoke all on function public.kiosk_create_announcement(uuid, text, text, timestamptz, timestamptz, boolean) from public, anon, authenticated;
revoke all on function public.kiosk_update_announcement(uuid, jsonb) from public, anon, authenticated;
revoke all on function public.kiosk_end_announcement(uuid) from public, anon, authenticated;
revoke all on function public.kiosk_delete_announcement(uuid) from public, anon, authenticated;

grant execute on function public.kiosk_approve_pairing(uuid, text) to authenticated;
grant execute on function public.kiosk_list_devices(uuid) to authenticated;
grant execute on function public.kiosk_list_announcements(uuid, boolean) to authenticated;
grant execute on function public.kiosk_create_announcement(uuid, text, text, timestamptz, timestamptz, boolean) to authenticated;
grant execute on function public.kiosk_update_announcement(uuid, jsonb) to authenticated;
grant execute on function public.kiosk_end_announcement(uuid) to authenticated;
grant execute on function public.kiosk_delete_announcement(uuid) to authenticated;

revoke all on function public.kiosk_begin_pairing(text, text, text) from public, anon, authenticated;
revoke all on function public.kiosk_claim_pairing(text, text, text) from public, anon, authenticated;
revoke all on function public.kiosk_bootstrap(text) from public, anon, authenticated;
revoke all on function public.kiosk_list_today(text) from public, anon, authenticated;
revoke all on function public.kiosk_search_students(text, text) from public, anon, authenticated;
revoke all on function public.kiosk_check_in(text, uuid, text, text, boolean) from public, anon, authenticated;

grant execute on function public.kiosk_begin_pairing(text, text, text) to service_role;
grant execute on function public.kiosk_claim_pairing(text, text, text) to service_role;
grant execute on function public.kiosk_bootstrap(text) to service_role;
grant execute on function public.kiosk_list_today(text) to service_role;
grant execute on function public.kiosk_search_students(text, text) to service_role;
grant execute on function public.kiosk_check_in(text, uuid, text, text, boolean) to service_role;

-- Realtime publication for PC announcement updates and kiosk refresh signals.
do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'academy_announcements'
  ) then
    alter publication supabase_realtime add table public.academy_announcements;
  end if;
end;
$$;
