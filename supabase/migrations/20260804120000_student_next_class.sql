-- 학생앱: 다음 회차 수업 일정 (요일·시각 표시용).

create or replace function public.student_next_class_v1()
returns table(
  class_date_time timestamptz,
  class_end_time timestamptz,
  class_name text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  v_now timestamptz := now();
  v_kst_date date := (v_now at time zone 'Asia/Seoul')::date;
  v_kst_now timestamp := (v_now at time zone 'Asia/Seoul');
  v_found boolean := false;
  v_day int;
  v_candidate timestamp;
  v_candidate_utc timestamptz;
  i int;
  r record;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  -- 1) planned/실제 출결 행에서 아직 시작하지 않은 다음 수업
  return query
  select
    ar.class_date_time,
    ar.class_end_time,
    ar.class_name
  from public.attendance_records ar
  where ar.academy_id = v_academy
    and ar.student_id = v_student
    and ar.class_date_time is not null
    and ar.class_date_time > v_now
  order by ar.class_date_time asc
  limit 1;

  if found then
    return;
  end if;

  -- 2) fallback: 주간 템플릿(student_time_blocks)에서 앞으로 14일 내 다음 슬롯
  for i in 0..13 loop
    v_day := extract(dow from (v_kst_date + i))::int; -- 0=일 .. 6=토
    -- 앱 day_index: 0=월 .. 6=일 → DOW 변환: mon=1..sat=6,sun=0 → (dow+6)%7
    for r in
      select
        b.start_hour,
        b.start_minute,
        b.duration
      from public.student_time_blocks b
      where b.academy_id = v_academy
        and b.student_id = v_student
        and b.day_index = ((v_day + 6) % 7)
        and b.start_date <= (v_kst_date + i)
        and (b.end_date is null or b.end_date >= (v_kst_date + i))
        and b.set_id is not null
        and b.set_id <> ''
      order by b.start_hour, b.start_minute
    loop
      v_candidate := (v_kst_date + i)
        + make_time(r.start_hour, r.start_minute, 0);
      if v_candidate > v_kst_now then
        v_candidate_utc := v_candidate at time zone 'Asia/Seoul';
        class_date_time := v_candidate_utc;
        class_end_time := v_candidate_utc
          + make_interval(mins => greatest(coalesce(r.duration, 60), 1));
        class_name := null;
        return next;
        return;
      end if;
    end loop;
  end loop;
end;
$$;

revoke all on function public.student_next_class_v1() from public;
grant execute on function public.student_next_class_v1() to authenticated;
