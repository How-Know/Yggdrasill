-- 0060: Attendance normalization (KST) and defaults for date/class times

-- 1) Update ensure_attendance_today to use KST date and set class_date_time when available
create or replace function public.ensure_attendance_today(
  p_academy_id uuid,
  p_student_id uuid
) returns uuid
language plpgsql security definer set search_path=public as $$
declare
  v_id uuid;
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_start_hour integer;
  v_start_minute integer;
  v_duration integer;
  v_class_dt timestamptz;
begin
  -- get today first block if any
  select b.start_hour, b.start_minute, b.duration
    into v_start_hour, v_start_minute, v_duration
    from public.student_time_blocks b
   where b.academy_id = p_academy_id
     and b.student_id = p_student_id
     and b.day_index = case when extract(dow from (now() at time zone 'Asia/Seoul'))::int = 0 then 6 else extract(dow from (now() at time zone 'Asia/Seoul'))::int - 1 end
   order by b.start_hour, b.start_minute
   limit 1;

  if v_start_hour is not null then
    v_class_dt := make_timestamptz(
      extract(year from now() at time zone 'Asia/Seoul')::int,
      extract(month from now() at time zone 'Asia/Seoul')::int,
      extract(day from now() at time zone 'Asia/Seoul')::int,
      v_start_hour, v_start_minute, 0, 'Asia/Seoul');
  end if;

  select id into v_id
    from public.attendance_records
   where academy_id = p_academy_id
     and student_id = p_student_id
     and date = v_today
   limit 1;

  if v_id is null then
    insert into public.attendance_records(
      academy_id, student_id, date, class_date_time, class_end_time,
      is_present, arrival_time, created_at, updated_at)
    values (
      p_academy_id, p_student_id, v_today,
      v_class_dt,
      case when v_class_dt is not null and v_duration is not null then v_class_dt + (v_duration || ' minutes')::interval else null end,
      true, now(), now(), now()
    ) returning id into v_id;
  else
    -- ensure class_date_time/end set if missing
    update public.attendance_records
       set class_date_time = coalesce(class_date_time, v_class_dt),
           class_end_time  = coalesce(class_end_time, case when v_class_dt is not null and v_duration is not null then v_class_dt + (v_duration || ' minutes')::interval else null end),
           updated_at = now()
     where id = v_id;
  end if;
  return v_id;
end; $$;

grant execute on function public.ensure_attendance_today(uuid, uuid) to anon, authenticated;

-- 2) Improve m5_record_arrival/departure to fill date and class times consistently
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

create or replace function public.m5_record_departure(
  p_academy_id uuid,
  p_student_id uuid
) returns void as $$
declare
  today_date date := (now() at time zone 'Asia/Seoul')::date;
  existing_id uuid;
begin
  select id into existing_id
    from public.attendance_records
   where academy_id = p_academy_id and student_id = p_student_id and date = today_date
   limit 1;

  if existing_id is not null then
    update public.attendance_records
       set departure_time = coalesce(departure_time, now()),
           updated_at = now()
     where id = existing_id;
  else
    insert into public.attendance_records (
      academy_id, student_id, date, departure_time, is_present, created_at, updated_at
    ) values (
      p_academy_id, p_student_id, today_date, now(), false, now(), now()
    );
  end if;
end; $$ language plpgsql security definer set search_path=public;

grant execute on function public.m5_record_departure(uuid, uuid) to anon, authenticated;

-- 3) Safety trigger: backfill date/class times on INSERT/UPDATE
create or replace function public._attendance_defaults()
returns trigger language plpgsql security definer as $$
declare
  today_kst date := (now() at time zone 'Asia/Seoul')::date;
  sh integer; sm integer; dur integer; cdt timestamptz;
begin
  -- ensure date
  new.date := coalesce(new.date, (new.class_date_time at time zone 'Asia/Seoul')::date, (new.arrival_time at time zone 'Asia/Seoul')::date, today_kst);

  -- derive class_date_time from schedule if missing
  if new.class_date_time is null then
    select b.start_hour, b.start_minute, b.duration into sh, sm, dur
      from public.student_time_blocks b
     where b.academy_id = new.academy_id and b.student_id = new.student_id
       and b.day_index = case when extract(dow from (now() at time zone 'Asia/Seoul'))::int = 0 then 6 else extract(dow from (now() at time zone 'Asia/Seoul'))::int - 1 end
     order by b.start_hour, b.start_minute
     limit 1;
    if sh is not null then
      cdt := make_timestamptz(
        extract(year from now() at time zone 'Asia/Seoul')::int,
        extract(month from now() at time zone 'Asia/Seoul')::int,
        extract(day from now() at time zone 'Asia/Seoul')::int,
        sh, sm, 0, 'Asia/Seoul');
      new.class_date_time := cdt;
      if new.class_end_time is null and dur is not null then
        new.class_end_time := cdt + (dur || ' minutes')::interval;
      end if;
    elsif new.arrival_time is not null then
      new.class_date_time := new.arrival_time;
    end if;
  end if;

  return new;
end $$;

drop trigger if exists trg_attendance_defaults on public.attendance_records;
create trigger trg_attendance_defaults
before insert or update on public.attendance_records
for each row execute function public._attendance_defaults();











