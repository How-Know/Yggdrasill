-- 학생앱: 주간 수업시간 막대(최근 일~토) + 90일 평균.

create or replace function public.student_class_duration_week_v1()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  v_now timestamptz := now();
  v_today date := (v_now at time zone 'Asia/Seoul')::date;
  v_week_start date;
  v_avg_from date;
  v_avg_minutes numeric;
  v_sample_count integer;
  v_max_day integer;
  v_y_max integer;
  v_days jsonb;
  v_weekdays text[] := array['일', '월', '화', '수', '목', '금', '토'];
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  -- 이번 주 일요일(KST) 시작 ~ 토요일
  v_week_start := v_today - extract(dow from v_today)::integer;
  v_avg_from := v_today - 89;

  -- 유효 세션 수업시간(분): 하원−등원, 1~720분만
  with session_minutes as (
    select
      ar.date as day,
      greatest(
        0,
        least(
          720,
          round(
            extract(epoch from (ar.departure_time - ar.arrival_time)) / 60.0
          )::integer
        )
      ) as minutes
    from public.attendance_records ar
    where ar.academy_id = v_academy
      and ar.student_id = v_student
      and ar.arrival_time is not null
      and ar.departure_time is not null
      and ar.departure_time > ar.arrival_time
      and ar.date between v_avg_from and v_today
  ),
  -- 오늘: 등원만 있으면 진행 중 체류 포함
  today_open as (
    select
      ar.date as day,
      greatest(
        1,
        least(
          720,
          round(
            extract(epoch from (v_now - ar.arrival_time)) / 60.0
          )::integer
        )
      ) as minutes
    from public.attendance_records ar
    where ar.academy_id = v_academy
      and ar.student_id = v_student
      and ar.date = v_today
      and ar.arrival_time is not null
      and ar.departure_time is null
      and ar.arrival_time <= v_now
  ),
  all_sessions as (
    select day, minutes from session_minutes where minutes between 1 and 720
    union all
    select day, minutes from today_open
  ),
  day_totals as (
    select day, sum(minutes)::integer as minutes
    from all_sessions
    group by day
  ),
  week_days as (
    select
      (v_week_start + g.i) as day,
      g.i as weekday_index,
      v_weekdays[g.i + 1] as weekday
    from generate_series(0, 6) as g(i)
  )
  select
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'weekday', wd.weekday,
            'date', wd.day,
            'minutes', coalesce(dt.minutes, 0)
          )
          order by wd.weekday_index
        )
        from week_days wd
        left join day_totals dt on dt.day = wd.day
      ),
      '[]'::jsonb
    ),
    (
      select avg(minutes)::numeric
      from session_minutes
      where minutes between 1 and 720
    ),
    (
      select count(*)::integer
      from session_minutes
      where minutes between 1 and 720
    ),
    (
      select coalesce(max(minutes), 0)::integer
      from day_totals
      where day between v_week_start and v_week_start + 6
    )
  into v_days, v_avg_minutes, v_sample_count, v_max_day;

  v_sample_count := coalesce(v_sample_count, 0);
  v_max_day := coalesce(v_max_day, 0);

  -- Y축: 4/6/8/10시간 버킷 (분)
  v_y_max := greatest(v_max_day, coalesce(round(v_avg_minutes)::integer, 0), 60);
  if v_y_max <= 240 then
    v_y_max := 240;
  elsif v_y_max <= 360 then
    v_y_max := 360;
  elsif v_y_max <= 480 then
    v_y_max := 480;
  else
    v_y_max := 600;
  end if;

  return jsonb_build_object(
    'days', coalesce(v_days, '[]'::jsonb),
    'average_minutes', case
      when v_sample_count > 0 then round(v_avg_minutes)::integer
      else null
    end,
    'sample_count', v_sample_count,
    'y_max_minutes', v_y_max,
    'week_start', v_week_start,
    'week_end', v_week_start + 6
  );
end;
$$;

revoke all on function public.student_class_duration_week_v1() from public;
grant execute on function public.student_class_duration_week_v1() to authenticated;
