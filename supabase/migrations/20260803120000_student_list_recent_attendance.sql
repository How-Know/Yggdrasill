-- 학생앱: 최근 N회 출결(등원 편차) — 프로필 펼침 그래프용.

create or replace function public.student_list_recent_attendance_v1(
  p_limit integer default 10
)
returns table(
  class_date_time timestamptz,
  arrival_time timestamptz,
  departure_time timestamptz,
  class_name text,
  delta_minutes integer,
  lateness_threshold integer
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  v_limit integer := greatest(coalesce(p_limit, 10), 1);
  v_thresh integer;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  select greatest(coalesce(spi.lateness_threshold, 10), 0)::integer
    into v_thresh
  from public.student_payment_info spi
  where spi.academy_id = v_academy
    and spi.student_id = v_student;
  v_thresh := coalesce(v_thresh, 10);

  return query
  select
    ar.class_date_time,
    ar.arrival_time,
    ar.departure_time,
    ar.class_name,
    case
      when ar.arrival_time is null or ar.class_date_time is null then null
      else round(
        extract(epoch from (ar.arrival_time - ar.class_date_time)) / 60.0
      )::integer
    end as delta_minutes,
    v_thresh as lateness_threshold
  from public.attendance_records ar
  where ar.academy_id = v_academy
    and ar.student_id = v_student
    and ar.class_date_time is not null
    and ar.class_date_time <= now()
    and (
      ar.arrival_time is not null
      or ar.departure_time is not null
      or coalesce(ar.is_present, false)
      or (
        coalesce(ar.is_planned, false)
        and (ar.class_date_time at time zone 'Asia/Seoul')::date
          < (now() at time zone 'Asia/Seoul')::date
      )
    )
  order by ar.class_date_time desc
  limit v_limit;
end;
$$;

revoke all on function public.student_list_recent_attendance_v1(integer) from public;
grant execute on function public.student_list_recent_attendance_v1(integer) to authenticated;
