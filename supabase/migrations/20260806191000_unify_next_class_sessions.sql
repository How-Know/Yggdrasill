-- Treat consecutive blocks with the same set_id as one class session.

create or replace function public._homework_session_plan_next_attendance_at(
  p_academy_id uuid,
  p_student_id uuid,
  p_after timestamptz
)
returns timestamptz
language sql
stable
security definer
set search_path = public
as $$
  with future_attendance_raw as (
    select
      coalesce(
        ar.class_date_time,
        ar.date::timestamp at time zone 'Asia/Seoul'
      ) as class_at,
      coalesce(ar.set_id::text, ar.id::text) as session_key
    from public.attendance_records ar
    where ar.academy_id = p_academy_id
      and ar.student_id = p_student_id
      and coalesce(
        ar.class_date_time,
        ar.date::timestamp at time zone 'Asia/Seoul'
      ) > p_after
  ),
  future_attendance as (
    select min(far.class_at) as class_at
    from future_attendance_raw far
    group by
      (far.class_at at time zone 'Asia/Seoul')::date,
      far.session_key
  ),
  future_template_raw as (
    select
      (
        ((p_after at time zone 'Asia/Seoul')::date + days.offset_days)
          + make_time(b.start_hour, b.start_minute, 0)
      ) at time zone 'Asia/Seoul' as class_at,
      coalesce(b.set_id::text, b.id::text) as session_key
    from generate_series(0, 13) as days(offset_days)
    join public.student_time_blocks b
      on b.academy_id = p_academy_id
     and b.student_id = p_student_id
     and b.day_index = extract(
       isodow from (
         (p_after at time zone 'Asia/Seoul')::date + days.offset_days
       )
     )::integer - 1
     and b.start_date <= (
       (p_after at time zone 'Asia/Seoul')::date + days.offset_days
     )
     and (
       b.end_date is null
       or b.end_date >= (
         (p_after at time zone 'Asia/Seoul')::date + days.offset_days
       )
     )
  ),
  future_template as (
    select min(ftr.class_at) as class_at
    from future_template_raw ftr
    where ftr.class_at > p_after
    group by
      (ftr.class_at at time zone 'Asia/Seoul')::date,
      ftr.session_key
  )
  select candidates.class_at
  from (
    select class_at from future_attendance
    union
    select class_at from future_template
  ) candidates
  order by candidates.class_at
  limit 1;
$$;

revoke all on function public._homework_session_plan_next_attendance_at(
  uuid, uuid, timestamptz
) from public;
