-- M5 arrival and departure RPC functions

-- m5_record_arrival: Record or update arrival time for a student
create or replace function public.m5_record_arrival(
  p_academy_id uuid,
  p_student_id uuid
) returns void as $$
declare
  today_date date := (now() at time zone 'Asia/Seoul')::date;
  existing_id uuid;
begin
  -- Check if there's already an attendance record for today
  select id into existing_id
  from public.attendance_records
  where academy_id = p_academy_id 
    and student_id = p_student_id 
    and date = today_date
  limit 1;

  if existing_id is not null then
    -- Update existing record (only if arrival_time is not set)
    update public.attendance_records
    set arrival_time = coalesce(arrival_time, now()),
        is_present = true,
        updated_at = now()
    where id = existing_id;
  else
    -- Insert new record
    insert into public.attendance_records (
      academy_id,
      student_id,
      date,
      arrival_time,
      is_present,
      created_at,
      updated_at
    ) values (
      p_academy_id,
      p_student_id,
      today_date,
      now(),
      true,
      now(),
      now()
    );
  end if;
end; $$ language plpgsql security definer set search_path=public;

grant execute on function public.m5_record_arrival(uuid, uuid) to anon, authenticated;

-- m5_record_departure: Record departure time for a student
create or replace function public.m5_record_departure(
  p_academy_id uuid,
  p_student_id uuid
) returns void as $$
declare
  today_date date := (now() at time zone 'Asia/Seoul')::date;
  existing_id uuid;
begin
  -- Check if there's already an attendance record for today
  select id into existing_id
  from public.attendance_records
  where academy_id = p_academy_id 
    and student_id = p_student_id 
    and date = today_date
  limit 1;

  if existing_id is not null then
    -- Update existing record with departure time
    update public.attendance_records
    set departure_time = coalesce(departure_time, now()),
        updated_at = now()
    where id = existing_id;
  else
    -- Insert new record with departure time (edge case: student never arrived but leaving)
    insert into public.attendance_records (
      academy_id,
      student_id,
      date,
      departure_time,
      is_present,
      created_at,
      updated_at
    ) values (
      p_academy_id,
      p_student_id,
      today_date,
      now(),
      false,
      now(),
      now()
    );
  end if;
end; $$ language plpgsql security definer set search_path=public;

grant execute on function public.m5_record_departure(uuid, uuid) to anon, authenticated;

