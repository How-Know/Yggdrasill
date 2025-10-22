-- Fix today calculation to Asia/Seoul timezone
create or replace function public.m5_get_students_today_basic(
  p_academy_id uuid
) returns table(student_id uuid, name text) as $$
declare
  -- use KST local time for day-of-week
  d int := extract(dow from (now() at time zone 'Asia/Seoul')); -- 0:Sun..6:Sat
  day_idx int := case when d=0 then 6 else d-1 end; -- 0:Mon..6:Sun
begin
  return query
  select distinct s.id, s.name
  from public.student_time_blocks b
  join public.students s on s.id = b.student_id
  where b.academy_id = p_academy_id and b.day_index = day_idx;
end; $$ language plpgsql security definer set search_path=public;




