-- Shared-iPad quick login and correct-only textbook progress helpers.

create or replace function public.student_quick_login_candidates()
returns table(
  student_id uuid,
  name text,
  school text,
  grade integer,
  start_hour integer,
  start_minute integer
)
language sql
stable
security definer
set search_path = public
as $$
  with target_academy as (
    select s.academy_id
    from public.academy_settings s
    where btrim(s.name) = '정현수학교습소'
    order by s.updated_at desc
    limit 1
  )
  select
    today.student_id,
    today.name,
    today.school,
    today.grade,
    today.start_hour,
    today.start_minute
  from target_academy academy
  cross join lateral public.m5_get_students_today_basic(
    academy.academy_id
  ) today
  join public.student_app_accounts account
    on account.academy_id = academy.academy_id
   and account.student_id = today.student_id
  join public.m5_student_pins pin
    on pin.academy_id = academy.academy_id
   and pin.student_id = today.student_id
   and pin.pin_required
   and pin.pin_hash is not null
  where not exists (
    select 1
    from public.m5_device_bindings binding
    where binding.academy_id = academy.academy_id
      and binding.student_id = today.student_id
      and binding.active
  )
  order by today.start_hour, today.start_minute, today.name
$$;

revoke all on function public.student_quick_login_candidates() from public;
grant execute on function public.student_quick_login_candidates()
  to service_role;

create or replace function public.student_quick_login_verify(
  p_student_id uuid,
  p_pin text
) returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_academy uuid;
  v_username text;
  v_pin public.m5_student_pins%rowtype;
  v_attempts integer;
begin
  if p_student_id is null or p_pin !~ '^[0-9]{4,8}$' then
    return jsonb_build_object('ok', false, 'error', 'invalid_request');
  end if;

  select account.academy_id, account.username
    into v_academy, v_username
  from public.student_app_accounts account
  join public.academy_settings settings
    on settings.academy_id = account.academy_id
   and btrim(settings.name) = '정현수학교습소'
  where account.student_id = p_student_id
  limit 1;

  if v_academy is null then
    return jsonb_build_object('ok', false, 'error', 'not_eligible');
  end if;

  if not exists (
    select 1
    from public.student_quick_login_candidates() candidate
    where candidate.student_id = p_student_id
  ) then
    return jsonb_build_object('ok', false, 'error', 'not_eligible');
  end if;

  select *
    into v_pin
  from public.m5_student_pins
  where academy_id = v_academy
    and student_id = p_student_id
  for update;

  if v_pin.locked_until is not null and v_pin.locked_until > now() then
    return jsonb_build_object(
      'ok', false,
      'error', 'locked',
      'locked_seconds',
      greatest(1, ceil(extract(epoch from (v_pin.locked_until - now())))::int)
    );
  end if;

  if v_pin.pin_hash is null
     or crypt(p_pin, v_pin.pin_hash) <> v_pin.pin_hash then
    v_attempts := coalesce(v_pin.failed_attempts, 0) + 1;
    update public.m5_student_pins
    set
      failed_attempts = case when v_attempts >= 5 then 0 else v_attempts end,
      locked_until = case
        when v_attempts >= 5 then now() + interval '5 minutes'
        else null
      end,
      updated_at = now()
    where academy_id = v_academy
      and student_id = p_student_id;

    if v_attempts >= 5 then
      return jsonb_build_object(
        'ok', false,
        'error', 'locked',
        'locked_seconds', 300
      );
    end if;
    return jsonb_build_object(
      'ok', false,
      'error', 'pin_invalid',
      'attempts_left', 5 - v_attempts
    );
  end if;

  update public.m5_student_pins
  set failed_attempts = 0, locked_until = null, updated_at = now()
  where academy_id = v_academy
    and student_id = p_student_id;

  return jsonb_build_object(
    'ok', true,
    'username', v_username
  );
end;
$$;

revoke all on function public.student_quick_login_verify(uuid, text)
  from public;
grant execute on function public.student_quick_login_verify(uuid, text)
  to service_role;

create or replace function public.student_textbook_start_dates()
returns table(
  book_id uuid,
  grade_label text,
  started_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
begin
  select identity.academy_id, identity.student_id
    into v_academy, v_student
  from public.student_app_identity() identity;

  if v_student is null then
    raise exception 'no student account';
  end if;

  return query
  select
    record.book_id,
    record.grade_label,
    min(record.created_at) as started_at
  from public.student_textbook_answer_records record
  where record.academy_id = v_academy
    and record.student_id = v_student
  group by record.book_id, record.grade_label;
end;
$$;

revoke all on function public.student_textbook_start_dates() from public;
grant execute on function public.student_textbook_start_dates()
  to authenticated;

-- PIN hashes and plain-text admin display values must never be readable by
-- anonymous/student clients. Service-role gateway and security-definer admin
-- RPCs continue to work.
revoke select on table public.m5_student_pins from anon, authenticated;
