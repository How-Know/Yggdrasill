-- 20260702020000: watch_record_attendance 매칭 개선
--
-- 기존 버전은 class_date_time(분 단위)로만 매칭해서, 시간표 계산 타깃과
-- 실제 예정 레코드(attendance_records)의 시각이 조금이라도 다르면 매칭에 실패하고
-- orphan 레코드를 새로 삽입하는 문제가 있었다. 이 때문에 iPhone/PC UI에 반영되지
-- 않거나 다음날 기록에 붙는 버그가 발생했다.
--
-- 개선: 워치 스냅샷이 항상 실어 보내는 set_id + 오늘(KST) 날짜로 먼저 매칭하고,
-- 그다음 class_date_time(분) 매칭, 마지막에만 새로 삽입한다.

create or replace function public.watch_record_attendance(
  p_academy_id uuid,
  p_student_id uuid,
  p_class_date_time timestamptz,
  p_action text,                 -- 'arrival' | 'departure'
  p_class_end_time timestamptz default null,
  p_class_name text default null,
  p_set_id uuid default null,
  p_session_type_id uuid default null
) returns void as $$
declare
  existing_id uuid;
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_date date := (coalesce(p_class_date_time, now()) at time zone 'Asia/Seoul')::date;
begin
  if not exists (
    select 1 from public.memberships s
    where s.academy_id = p_academy_id and s.user_id = auth.uid()
  ) then
    raise exception 'not_a_member';
  end if;

  if p_action not in ('arrival', 'departure') then
    raise exception 'invalid_action';
  end if;

  -- 1) set_id + 오늘(KST) 날짜로 예정 레코드를 먼저 찾는다(가장 정확).
  if p_set_id is not null then
    select id into existing_id
      from public.attendance_records
     where academy_id = p_academy_id
       and student_id = p_student_id
       and set_id = p_set_id
       and (
         date = v_date
         or (class_date_time is not null
             and (class_date_time at time zone 'Asia/Seoul')::date = v_date)
       )
     order by created_at asc
     limit 1;
  end if;

  -- 2) 못 찾으면 class_date_time(분 단위)로 매칭.
  if existing_id is null and p_class_date_time is not null then
    select id into existing_id
      from public.attendance_records
     where academy_id = p_academy_id
       and student_id = p_student_id
       and class_date_time is not null
       and date_trunc('minute', class_date_time) = date_trunc('minute', p_class_date_time)
     order by created_at asc
     limit 1;
  end if;

  if existing_id is not null then
    if p_action = 'arrival' then
      update public.attendance_records
         set arrival_time   = coalesce(arrival_time, now()),
             departure_time = null,
             is_present     = true,
             updated_at     = now()
       where id = existing_id;
    else
      update public.attendance_records
         set arrival_time   = coalesce(arrival_time, now()),
             departure_time = now(),
             is_present     = true,
             updated_at     = now()
       where id = existing_id;
    end if;
  else
    insert into public.attendance_records (
      academy_id, student_id, set_id, session_type_id,
      class_date_time, class_end_time, class_name, date,
      is_present, arrival_time, departure_time, is_planned,
      created_at, updated_at
    ) values (
      p_academy_id, p_student_id, p_set_id, p_session_type_id,
      p_class_date_time,
      coalesce(p_class_end_time, p_class_date_time + interval '1 hour'),
      coalesce(p_class_name, '수업'), v_date,
      true,
      now(),
      case when p_action = 'departure' then now() else null end,
      false,
      now(), now()
    );
  end if;
end; $$ language plpgsql security definer set search_path=public;

grant execute on function public.watch_record_attendance(uuid, uuid, timestamptz, text, timestamptz, text, uuid, uuid) to authenticated;
