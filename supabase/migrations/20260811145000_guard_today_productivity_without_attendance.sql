-- PostgreSQL greatest/least는 null 인자를 무시하므로, 출석이 없을 때도
-- 오늘 00시부터의 시간이 잡히지 않도록 공개 RPC 앞에서 명시적으로 차단한다.

alter function public.student_today_productivity_v1()
  rename to student_today_productivity_unchecked_v1;

revoke all on function public.student_today_productivity_unchecked_v1()
  from public, anon, authenticated;

create function public.student_today_productivity_v1()
returns table(
  productive_seconds bigint,
  completed_problem_count integer
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  v_day_start timestamptz;
  v_day_end timestamptz;
begin
  select i.academy_id, i.student_id
  into v_academy, v_student
  from public.student_app_identity() i;

  if v_student is null then
    raise exception 'no student account';
  end if;

  v_day_start := (
    date_trunc('day', now() at time zone 'Asia/Seoul')
    at time zone 'Asia/Seoul'
  );
  v_day_end := v_day_start + interval '1 day';

  if not exists (
    select 1
    from public.attendance_records ar
    where ar.academy_id = v_academy
      and ar.student_id = v_student
      and ar.arrival_time is not null
      and ar.arrival_time < v_day_end
      and coalesce(ar.departure_time, now()) > v_day_start
  ) then
    productive_seconds := 0;
    completed_problem_count := 0;
    return next;
    return;
  end if;

  return query
  select p.productive_seconds, p.completed_problem_count
  from public.student_today_productivity_unchecked_v1() p;
end;
$$;

revoke all on function public.student_today_productivity_v1() from public;
grant execute on function public.student_today_productivity_v1()
  to authenticated;
