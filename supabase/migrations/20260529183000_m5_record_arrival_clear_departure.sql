-- Login (bind) should always re-mark the student as present for today.
--
-- Previously m5_record_arrival only did arrival_time = coalesce(arrival_time, now())
-- and never touched departure_time. So once a departure_time was set for today
-- (e.g. an accidental logout-departure, or a manual departure followed by the
-- student returning), a subsequent login could NOT restore the "present" state:
-- the student kept a departure_time and was filtered out of the M5 list.
--
-- Fix: on arrival, clear departure_time and force is_present = true. Binding a
-- device means the student is physically present, so this is the correct state.

create or replace function public.m5_record_arrival(
  p_academy_id uuid,
  p_student_id uuid
) returns void as $$
declare
  today_date date := (now() at time zone 'Asia/Seoul')::date;
  existing_id uuid;
  start_hour integer; start_minute integer; duration integer; class_dt timestamptz;
begin
  select id into existing_id
    from public.attendance_records
   where academy_id = p_academy_id and student_id = p_student_id and date = today_date
   limit 1;

  select b.start_hour, b.start_minute, b.duration into start_hour, start_minute, duration
    from public.student_time_blocks b
   where b.academy_id = p_academy_id and b.student_id = p_student_id
     and b.day_index = case when extract(dow from (now() at time zone 'Asia/Seoul'))::int = 0 then 6 else extract(dow from (now() at time zone 'Asia/Seoul'))::int - 1 end
   order by b.start_hour, b.start_minute
   limit 1;

  if start_hour is not null then
    class_dt := make_timestamptz(
      extract(year from now() at time zone 'Asia/Seoul')::int,
      extract(month from now() at time zone 'Asia/Seoul')::int,
      extract(day from now() at time zone 'Asia/Seoul')::int,
      start_hour, start_minute, 0, 'Asia/Seoul');
  end if;

  if existing_id is not null then
    update public.attendance_records
       set arrival_time = coalesce(arrival_time, now()),
           departure_time = null,            -- login = present again: clear any departure
           is_present   = true,
           date         = coalesce(date, today_date),
           class_date_time = coalesce(class_date_time, class_dt),
           class_end_time  = coalesce(class_end_time, case when class_dt is not null and duration is not null then class_dt + (duration || ' minutes')::interval else null end),
           updated_at   = now()
     where id = existing_id;
  else
    insert into public.attendance_records (
      academy_id, student_id, date, class_date_time, class_end_time,
      is_present, arrival_time, created_at, updated_at
    ) values (
      p_academy_id, p_student_id, today_date,
      class_dt,
      case when class_dt is not null and duration is not null then class_dt + (duration || ' minutes')::interval else null end,
      true, now(), now(), now()
    );
  end if;
end; $$ language plpgsql security definer set search_path=public;

grant execute on function public.m5_record_arrival(uuid, uuid) to anon, authenticated;
