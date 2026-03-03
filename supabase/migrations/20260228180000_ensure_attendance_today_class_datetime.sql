-- M5 ensure_attendance_today INSERT 시 class_date_time, class_end_time 누락으로
-- Flutter 출석 로드에서 null 캐스트 예외 발생. INSERT 시 두 컬럼을 채우도록 수정.

-- 기존에 이미 들어간 null 행 보정 (arrival_time 또는 date 기준)
update public.attendance_records
set
  class_date_time = coalesce(class_date_time, arrival_time, (date + time '00:00') at time zone 'UTC'),
  class_end_time = coalesce(class_end_time, arrival_time + interval '1 hour', (date + time '01:00') at time zone 'UTC')
where class_date_time is null or class_end_time is null;

create or replace function public.ensure_attendance_today(
  p_academy_id uuid,
  p_student_id uuid
) returns uuid
language plpgsql security definer set search_path=public as $$
declare
  v_id uuid;
  v_now timestamptz := now();
begin
  select id into v_id
  from public.attendance_records
  where academy_id = p_academy_id
    and student_id = p_student_id
    and date = current_date
  limit 1;

  if v_id is null then
    insert into public.attendance_records(
      academy_id, student_id, date, is_present, arrival_time,
      class_date_time, class_end_time
    )
    values (
      p_academy_id, p_student_id, current_date, true, v_now,
      v_now, v_now + interval '1 hour'
    )
    returning id into v_id;
  end if;
  return v_id;
end; $$;
