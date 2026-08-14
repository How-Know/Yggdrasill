-- 자정을 넘긴 수업은 등원중으로 유지하고, 이틀을 넘긴 미하원만 닫는다.
--
-- 학생앱은 달력 오늘(ar.date = KST today)만 봐서, 14일 등원·미하원 회차가
-- 15일이 되면 "등원 전"으로 떨어졌다. 학습앱은 열린 회차(arrival, 무 departure)를
-- 그대로 보므로 어긋났다.
--
-- 규칙: 등원날짜 다음날 밤 12시 = (등원일 + 2일) 00:00 Asia/Seoul.
-- 그 시각 전까지는 날짜가 바뀌어도 등원중. 그 시각이 되면 departure 를 찍는다.
-- 2틀을 학원에서 사는 사람은 없다는 전제다.

-- ---------------------------------------------------------------------------
-- 1) 캡 시각 · 만료 하원 찍기
-- ---------------------------------------------------------------------------
create or replace function public._attendance_open_cap_at(p_date date)
returns timestamptz
language sql
immutable
as $$
  select ((p_date + 2)::timestamp at time zone 'Asia/Seoul');
$$;

create or replace function public._attendance_session_date(
  p_date date,
  p_class_date_time timestamptz
) returns date
language sql
immutable
as $$
  select coalesce(
    p_date,
    (p_class_date_time at time zone 'Asia/Seoul')::date
  );
$$;

-- 캡이 지난 열린 회차에 하원을 찍는다. 하원 트리거(과제 대기 복귀)가 그대로 돈다.
create or replace function public._attendance_close_expired_open_sessions(
  p_academy_id uuid,
  p_student_id uuid default null
) returns integer
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_n integer := 0;
begin
  if p_academy_id is null then
    return 0;
  end if;

  update public.attendance_records ar
  set departure_time = public._attendance_open_cap_at(
        public._attendance_session_date(ar.date, ar.class_date_time)
      ),
      is_present = true,
      updated_at = now(),
      version = coalesce(ar.version, 1) + 1
  where ar.academy_id = p_academy_id
    and (p_student_id is null or ar.student_id = p_student_id)
    and ar.arrival_time is not null
    and ar.departure_time is null
    and now() >= public._attendance_open_cap_at(
      public._attendance_session_date(ar.date, ar.class_date_time)
    );

  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

revoke all on function public._attendance_open_cap_at(date) from public;
revoke all on function public._attendance_session_date(date, timestamptz) from public;
revoke all on function public._attendance_close_expired_open_sessions(uuid, uuid)
  from public;

-- ---------------------------------------------------------------------------
-- 2) 위치 판정 — 달력 오늘이 아니라 열린 회차(+캡)
-- ---------------------------------------------------------------------------
create or replace function public._student_location_kind(
  p_academy_id uuid,
  p_student_id uuid,
  p_at timestamptz default now()
) returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
    when exists (
      select 1
      from public.attendance_records ar
      where ar.academy_id = p_academy_id
        and ar.student_id = p_student_id
        and ar.arrival_time is not null
        and ar.arrival_time <= p_at
        and (ar.departure_time is null or ar.departure_time > p_at)
        and p_at < public._attendance_open_cap_at(
          public._attendance_session_date(ar.date, ar.class_date_time)
        )
    ) then 'academy'
    else 'home'
  end;
$$;

-- ---------------------------------------------------------------------------
-- 3) 오늘 출결 — 열린 회차를 날짜 넘어 우선
-- ---------------------------------------------------------------------------
create or replace function public.student_today_attendance()
returns table(
  arrival_time timestamptz,
  departure_time timestamptz,
  class_date_time timestamptz,
  class_end_time timestamptz,
  planned_departure_at timestamptz,
  early_leave_reason text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  today_date date := (now() at time zone 'Asia/Seoul')::date;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  perform public._attendance_close_expired_open_sessions(v_academy, v_student);

  return query
  select
    ar.arrival_time,
    ar.departure_time,
    ar.class_date_time,
    ar.class_end_time,
    ar.planned_departure_at,
    ar.early_leave_reason
  from public.attendance_records ar
  where ar.academy_id = v_academy
    and ar.student_id = v_student
    and (
      public._attendance_session_date(ar.date, ar.class_date_time) = today_date
      or (
        ar.arrival_time is not null
        and ar.departure_time is null
        and now() < public._attendance_open_cap_at(
          public._attendance_session_date(ar.date, ar.class_date_time)
        )
      )
    )
  order by ar.class_date_time asc nulls last;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4) 희망 하원 — 열린 회차 탐색에서 오늘 날짜 제한 제거
-- ---------------------------------------------------------------------------
create or replace function public.student_set_planned_departure(
  p_planned_departure_at timestamptz default null,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  today_date date := (now() at time zone 'Asia/Seoul')::date;
  v_row_id uuid;
  v_class_end timestamptz;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  perform public._attendance_close_expired_open_sessions(v_academy, v_student);

  select ar.id, ar.class_end_time
    into v_row_id, v_class_end
  from public.attendance_records ar
  where ar.academy_id = v_academy
    and ar.student_id = v_student
    and ar.arrival_time is not null
    and ar.departure_time is null
    and now() < public._attendance_open_cap_at(
      public._attendance_session_date(ar.date, ar.class_date_time)
    )
  order by ar.arrival_time desc
  limit 1;

  if v_row_id is null then
    select ar.id, ar.class_end_time
      into v_row_id, v_class_end
    from public.attendance_records ar
    where ar.academy_id = v_academy
      and ar.student_id = v_student
      and public._attendance_session_date(ar.date, ar.class_date_time) = today_date
    order by ar.class_date_time asc nulls last, ar.created_at asc
    limit 1;
  end if;

  if v_row_id is null then
    insert into public.attendance_records (
      academy_id, student_id, date, is_present, created_at, updated_at
    ) values (
      v_academy, v_student, today_date, false, now(), now()
    )
    returning id, class_end_time into v_row_id, v_class_end;
  end if;

  if p_planned_departure_at is null then
    update public.attendance_records
       set planned_departure_at = null,
           early_leave_reason = null,
           planned_departure_set_at = now(),
           planned_departure_set_by = 'student',
           updated_at = now()
     where id = v_row_id;
    return;
  end if;

  if v_class_end is not null
     and p_planned_departure_at < v_class_end
     and v_reason is null then
    raise exception 'early_leave_reason_required';
  end if;

  update public.attendance_records
     set planned_departure_at = p_planned_departure_at,
         early_leave_reason = v_reason,
         planned_departure_set_at = now(),
         planned_departure_set_by = 'student',
         updated_at = now()
   where id = v_row_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5) 하트비트 — 같은 열린 회차 규칙
-- ---------------------------------------------------------------------------
create or replace function public.student_app_heartbeat(
  p_ios_install_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  v_user uuid := auth.uid();
  v_at_academy boolean := false;
  v_kind text;
  v_install text := nullif(trim(coalesce(p_ios_install_id, '')), '');
  v_active text;
begin
  if v_user is null then
    raise exception 'not authenticated';
  end if;

  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  if v_install is not null then
    select a.active_ios_install_id into v_active
    from public.student_app_accounts a
    where a.student_id = v_student
      and a.user_id = v_user;

    if v_active is not null and v_active <> v_install then
      update public.student_app_presence
      set is_online = false,
          updated_at = now(),
          last_seen = now()
      where student_id = v_student
        and is_online = true;

      return jsonb_build_object(
        'ok', false,
        'error', 'ios_device_replaced'
      );
    end if;
  end if;

  perform public._attendance_close_expired_open_sessions(v_academy, v_student);

  select exists (
    select 1
    from public.attendance_records ar
    where ar.academy_id = v_academy
      and ar.student_id = v_student
      and ar.arrival_time is not null
      and ar.departure_time is null
      and now() < public._attendance_open_cap_at(
        public._attendance_session_date(ar.date, ar.class_date_time)
      )
  ) into v_at_academy;

  v_kind := case when v_at_academy then 'academy' else 'home' end;

  insert into public.student_app_presence as p (
    student_id, academy_id, user_id, is_online, last_seen, location_kind, updated_at
  ) values (
    v_student, v_academy, v_user, true, now(), v_kind, now()
  )
  on conflict (student_id) do update set
    academy_id = excluded.academy_id,
    user_id = excluded.user_id,
    is_online = true,
    last_seen = excluded.last_seen,
    location_kind = excluded.location_kind,
    updated_at = now();

  return jsonb_build_object(
    'ok', true,
    'location_kind', v_kind,
    'last_seen', now()
  );
end;
$$;
