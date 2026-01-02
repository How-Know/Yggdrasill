-- Prevent duplicate attendance_records rows for the same academy+student+class "minute".
--
-- Why not date_trunc(...) in the index?
-- - Postgres requires index expressions to use IMMUTABLE functions.
-- - date_trunc(timestamptz) is STABLE (timezone-dependent), so it cannot be used in an index expression.
--
-- Strategy:
-- 1) Normalize class_date_time to UTC minute boundary on write (trigger).
-- 2) Normalize existing rows to UTC minute boundary (only if seconds are non-zero).
-- 3) Fail fast if duplicates still exist.
-- 4) Create a unique index on (academy_id, student_id, class_date_time).
--
-- IMPORTANT:
-- - Run the admin tool first:
--   Settings -> 데이터 -> 출석 중복 전체 정리
-- - This migration will fail fast if duplicates still exist.

-- 1) Normalize on write: minute-round class_date_time in UTC
create or replace function public._attendance_defaults()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  today_kst date := (now() at time zone 'Asia/Seoul')::date;
  sh integer;
  sm integer;
  dur integer;
  cdt timestamptz;
begin
  -- ensure date
  new.date := coalesce(
    new.date,
    (new.class_date_time at time zone 'Asia/Seoul')::date,
    (new.arrival_time at time zone 'Asia/Seoul')::date,
    today_kst
  );

  -- derive class_date_time from schedule if missing
  if new.class_date_time is null then
    select b.start_hour, b.start_minute, b.duration
      into sh, sm, dur
      from public.student_time_blocks b
     where b.academy_id = new.academy_id
       and b.student_id = new.student_id
       and b.day_index = case
         when extract(dow from (now() at time zone 'Asia/Seoul'))::int = 0 then 6
         else extract(dow from (now() at time zone 'Asia/Seoul'))::int - 1
       end
     order by b.start_hour, b.start_minute
     limit 1;

    if sh is not null then
      cdt := make_timestamptz(
        extract(year from now() at time zone 'Asia/Seoul')::int,
        extract(month from now() at time zone 'Asia/Seoul')::int,
        extract(day from now() at time zone 'Asia/Seoul')::int,
        sh, sm, 0, 'Asia/Seoul'
      );
      new.class_date_time := cdt;
      if new.class_end_time is null and dur is not null then
        new.class_end_time := cdt + (dur || ' minutes')::interval;
      end if;
    elsif new.arrival_time is not null then
      -- fallback: set class_date_time to arrival_time if schedule is unknown
      new.class_date_time := new.arrival_time;
    end if;
  end if;

  -- ✅ normalize class_date_time to UTC minute boundary
  if new.class_date_time is not null then
    new.class_date_time := (date_trunc('minute', new.class_date_time at time zone 'UTC') at time zone 'UTC');
  end if;

  return new;
end $$;

drop trigger if exists trg_attendance_defaults on public.attendance_records;
create trigger trg_attendance_defaults
before insert or update on public.attendance_records
for each row execute function public._attendance_defaults();

-- 2) Normalize existing rows (only if seconds/fraction exist)
update public.attendance_records
   set class_date_time = (date_trunc('minute', class_date_time at time zone 'UTC') at time zone 'UTC')
 where class_date_time is not null
   and date_part('second', class_date_time) <> 0;

-- 3) Fail fast if duplicates still exist (after normalization)
do $$
declare
  v_academy_id uuid;
  v_student_id uuid;
  v_class_dt timestamptz;
  v_cnt integer;
begin
  select
    academy_id,
    student_id,
    class_date_time,
    count(*) as cnt
  into v_academy_id, v_student_id, v_class_dt, v_cnt
  from public.attendance_records
  where class_date_time is not null
  group by academy_id, student_id, class_date_time
  having count(*) > 1
  limit 1;

  if v_academy_id is not null then
    raise exception
      'attendance_records has duplicates for (academy_id, student_id, class_date_time). Run the dedupe tool first. Example academy_id=%, student_id=%, class_date_time=%, cnt=%',
      v_academy_id, v_student_id, v_class_dt, v_cnt;
  end if;
end $$;

-- 4) Unique index (no expression functions)
create unique index if not exists uidx_attendance_records_academy_student_class_dt
  on public.attendance_records(academy_id, student_id, class_date_time)
  where class_date_time is not null;


