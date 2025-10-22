-- 0053: student info for M5 (expanded fields)

drop function if exists public.m5_get_student_info(uuid, uuid);

create or replace function public.m5_get_student_info(
  p_academy_id uuid,
  p_student_id uuid
) returns table(
  name text,
  school text,
  education_level integer,
  grade integer,
  start_hour integer,
  start_minute integer,
  duration integer,
  weekday_kr text
) as $$
declare
  d int := extract(dow from (now() at time zone 'Asia/Seoul'));
  day_idx int := case when d=0 then 6 else d-1 end; -- 0:Mon..6:Sun
begin
  return query
  with base as (
    select s.name,
           s.school,
           s.education_level,
           s.grade
      from public.students s
     where s.academy_id = p_academy_id and s.id = p_student_id
     limit 1
  ), blk as (
    select b.start_hour, b.start_minute, b.duration
      from public.student_time_blocks b
     where b.academy_id = p_academy_id and b.student_id = p_student_id and b.day_index = day_idx
     order by b.start_hour asc, b.start_minute asc
     limit 1
  )
  select base.name,
         coalesce(base.school, '') as school,
         coalesce(base.education_level, null) as education_level,
         base.grade,
         coalesce(blk.start_hour, null) as start_hour,
         coalesce(blk.start_minute, null) as start_minute,
         coalesce(blk.duration, null) as duration,
         (case day_idx when 0 then '월' when 1 then '화' when 2 then '수' when 3 then '목' when 4 then '금' when 5 then '토' else '일' end) as weekday_kr
    from base
    left join blk on true;
end; $$ language plpgsql security definer set search_path=public;

grant execute on function public.m5_get_student_info(uuid,uuid) to anon, authenticated;


