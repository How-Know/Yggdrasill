-- 희망 하원은 수업 종료보다 이르거나 늦어도 사유 없이 저장한다.
-- 사유가 있으면 early_leave_reason에 그대로 남긴다.

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

  update public.attendance_records
     set planned_departure_at = p_planned_departure_at,
         early_leave_reason = v_reason,
         planned_departure_set_at = now(),
         planned_departure_set_by = 'student',
         updated_at = now()
   where id = v_row_id;
end;
$$;
