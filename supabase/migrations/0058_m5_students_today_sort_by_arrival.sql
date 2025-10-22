-- Sort students_today by arrival_time or class start time
-- Exclude students who already departed (departure_time is set)
-- Include student_time_blocks info for sorting and display

-- Drop old function first (return type changed)
drop function if exists public.m5_get_students_today_basic(uuid);

create or replace function public.m5_get_students_today_basic(
  p_academy_id uuid
) returns table(
  student_id uuid, 
  name text, 
  arrival_time timestamptz,
  start_hour integer,
  start_minute integer
) as $$
declare
  -- use KST local time for day-of-week
  d int := extract(dow from (now() at time zone 'Asia/Seoul')); -- 0:Sun..6:Sat
  day_idx int := case when d=0 then 6 else d-1 end; -- 0:Mon..6:Sun
  today_date date := (now() at time zone 'Asia/Seoul')::date;
begin
  return query
  with base as (
    select s.id as student_id, s.name, b.start_hour, b.start_minute
    from public.student_time_blocks b
    join public.students s on s.id = b.student_id
    where b.academy_id = p_academy_id and b.day_index = day_idx
  ), att as (
    select ar.student_id, ar.arrival_time, ar.departure_time
    from public.attendance_records ar
    where ar.academy_id = p_academy_id and ar.date = today_date
  ), bound as (
    select mdb.student_id
    from public.m5_device_bindings mdb
    where mdb.academy_id = p_academy_id and mdb.active = true
  ), candidates as (
    select 
      b.student_id,
      b.name,
      a.arrival_time,
      b.start_hour,
      b.start_minute,
      case when a.arrival_time is not null then 0 else 1 end as arrived_rank,
      case when a.arrival_time is not null 
        then a.arrival_time 
        else make_timestamptz(
          extract(year from now() at time zone 'Asia/Seoul')::int,
          extract(month from now() at time zone 'Asia/Seoul')::int,
          extract(day from now() at time zone 'Asia/Seoul')::int,
          coalesce(b.start_hour, 0),
          coalesce(b.start_minute, 0),
          0,
          'Asia/Seoul'
        )
      end as eff_sort
    from base b
    left join att a on a.student_id = b.student_id
    left join bound bn on bn.student_id = b.student_id
    where (a.student_id is null or a.departure_time is null) -- exclude departed
      and bn.student_id is null -- exclude currently bound
  ), per_student as (
    select distinct on (c.student_id)
      c.student_id, c.name, c.arrival_time, c.start_hour, c.start_minute, c.arrived_rank, c.eff_sort
    from candidates c
    order by c.student_id, c.eff_sort asc
  )
  select ps.student_id, ps.name, ps.arrival_time, ps.start_hour, ps.start_minute
  from per_student ps
  order by ps.arrived_rank asc, ps.eff_sort asc, ps.name asc;
end; $$ language plpgsql security definer set search_path=public;

grant execute on function public.m5_get_students_today_basic(uuid) to anon, authenticated;
