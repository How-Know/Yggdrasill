-- student_get_info가 m5_get_student_info의 실제 반환 컬럼(8개, weekday_kr 포함)과
-- 불일치(7개 선언)하여 "structure of query does not match" 오류가 발생하던 문제 수정.

drop function if exists public.student_get_info();

create or replace function public.student_get_info()
returns table(
  name text, school text, education_level integer, grade integer,
  start_hour integer, start_minute integer, duration integer, weekday_kr text
)
language plpgsql security definer set search_path = public as $$
declare
  v_academy uuid; v_student uuid;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;
  return query select * from public.m5_get_student_info(v_academy, v_student);
end; $$;

revoke all on function public.student_get_info() from public;
grant execute on function public.student_get_info() to authenticated;
