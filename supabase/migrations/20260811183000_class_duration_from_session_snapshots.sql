-- 학생앱 수업시간 차트를 하원 시점 불변 스냅샷 기준으로 통일한다.
--
-- * 완료 회차: student_class_session_snapshots.productive_seconds
-- * 진행 중 오늘 회차: (현재-등원)-설정 휴식시간
-- * 평균: 오늘 이전 90일 중 기록이 있는 수업일의 순수 수업시간 평균
-- * 과거 스냅샷이 없으면 average_minutes=null (목업/0 평균을 만들지 않음)

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
  -- index 0=일 .. 6=토 (이번 주 일요일 기준 offset)
  v_weekdays text[] := array['일', '월', '화', '수', '목', '금', '토'];
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  v_week_start := v_today - extract(dow from v_today)::integer;
  v_avg_from := v_today - 89;

  with snapshot_sessions as (
    select
      s.session_date as day,
      greatest(
        0,
        least(
          720,
          round(s.productive_seconds::numeric / 60.0)::integer
        )
      ) as minutes
    from public.student_class_session_snapshots s
    where s.academy_id = v_academy
      and s.student_id = v_student
      and s.session_date between v_avg_from and v_today
      and s.productive_seconds > 0
  ),
  today_open as (
    select
      v_today as day,
      greatest(
        0,
        least(
          720,
          round(
            greatest(
              0::numeric,
              extract(epoch from (v_now - ar.arrival_time))
                - public.m5_attendance_configured_break_seconds(ar.id)
            ) / 60.0
          )::integer
        )
      ) as minutes
    from public.attendance_records ar
    where ar.academy_id = v_academy
      and ar.student_id = v_student
      and ar.arrival_time is not null
      and ar.departure_time is null
      and ar.arrival_time <= v_now
      and (ar.arrival_time at time zone 'Asia/Seoul')::date = v_today
  ),
  all_sessions as (
    select day, minutes from snapshot_sessions
    union all
    select day, minutes from today_open where minutes > 0
  ),
  day_totals as (
    select day, sum(minutes)::integer as minutes
    from all_sessions
    group by day
  ),
  historical_day_totals as (
    select day, sum(minutes)::integer as minutes
    from snapshot_sessions
    where day < v_today
    group by day
  ),
  scheduled_offsets as (
    select distinct ((b.day_index + 1) % 7) as weekday_index
    from public.student_time_blocks b
    where b.academy_id = v_academy
      and b.student_id = v_student
      and b.start_date <= v_week_start + 6
      and (b.end_date is null or b.end_date >= v_week_start)
      and b.set_id is not null
      and b.set_id <> ''
      and b.day_index between 0 and 6
  ),
  week_days as (
    select
      (v_week_start + so.weekday_index) as day,
      so.weekday_index,
      v_weekdays[so.weekday_index + 1] as weekday
    from scheduled_offsets so
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
      from historical_day_totals
      where minutes between 1 and 720
    ),
    (
      select count(*)::integer
      from historical_day_totals
      where minutes between 1 and 720
    ),
    (
      select coalesce(max(dt.minutes), 0)::integer
      from week_days wd
      left join day_totals dt on dt.day = wd.day
    )
  into v_days, v_avg_minutes, v_sample_count, v_max_day;

  v_sample_count := coalesce(v_sample_count, 0);
  v_max_day := coalesce(v_max_day, 0);

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
grant execute on function public.student_class_duration_week_v1()
  to authenticated;
