-- 학생앱: 오늘 예정 귀가(하원 시간) + 조퇴 사유
-- departure_time(실하원)과 분리. 알림톡/unbind 트리거를 건드리지 않는다.

alter table public.attendance_records
  add column if not exists planned_departure_at timestamptz,
  add column if not exists early_leave_reason text,
  add column if not exists planned_departure_set_at timestamptz,
  add column if not exists planned_departure_set_by text
    check (
      planned_departure_set_by is null
      or planned_departure_set_by in ('student', 'staff', 'system')
    );

comment on column public.attendance_records.planned_departure_at is
  'Optional target go-home time for this session. NOT actual checkout (departure_time).';
comment on column public.attendance_records.early_leave_reason is
  'Reason when planned_departure_at is earlier than class_end_time.';
comment on column public.attendance_records.planned_departure_set_at is
  'When planned_departure_at was last set/cleared.';
comment on column public.attendance_records.planned_departure_set_by is
  'Actor that set planned departure: student | staff | system.';

-- 오늘 출결 조회: 예정 귀가·수업 종료 포함
-- OUT 컬럼이 늘면 CREATE OR REPLACE 불가 → 기존 시그니처 drop 후 재생성.
drop function if exists public.student_today_attendance();

create or replace function public.student_today_attendance()
returns table(
  arrival_time timestamptz,
  departure_time timestamptz,
  class_date_time timestamptz,
  class_end_time timestamptz,
  planned_departure_at timestamptz,
  early_leave_reason text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  today_date date := (now() at time zone 'Asia/Seoul')::date;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  return query
  select
    ar.arrival_time,
    ar.departure_time,
    ar.class_date_time,
    ar.class_end_time,
    ar.planned_departure_at,
    ar.early_leave_reason
  from public.attendance_records ar
  where ar.academy_id = v_academy
    and ar.student_id = v_student
    and ar.date = today_date
  order by ar.class_date_time asc nulls last;
end;
$$;

revoke all on function public.student_today_attendance() from public;
grant execute on function public.student_today_attendance() to authenticated;

-- 예정 귀가 설정/수정 (p_planned_departure_at null이면 해제)
create or replace function public.student_set_planned_departure(
  p_planned_departure_at timestamptz default null,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  today_date date := (now() at time zone 'Asia/Seoul')::date;
  v_row_id uuid;
  v_class_end timestamptz;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  -- open session 우선(등원 후·미하원), 없으면 오늘 가장 이른 행
  select ar.id, ar.class_end_time
    into v_row_id, v_class_end
  from public.attendance_records ar
  where ar.academy_id = v_academy
    and ar.student_id = v_student
    and ar.date = today_date
    and ar.arrival_time is not null
    and ar.departure_time is null
  order by ar.arrival_time desc
  limit 1;

  if v_row_id is null then
    select ar.id, ar.class_end_time
      into v_row_id, v_class_end
    from public.attendance_records ar
    where ar.academy_id = v_academy
      and ar.student_id = v_student
      and ar.date = today_date
    order by ar.class_date_time asc nulls last, ar.created_at asc
    limit 1;
  end if;

  if v_row_id is null then
    -- 등원 전이라도 오늘 행을 만들어 예정만 기록
    insert into public.attendance_records (
      academy_id, student_id, date, is_present, created_at, updated_at
    ) values (
      v_academy, v_student, today_date, false, now(), now()
    )
    returning id, class_end_time into v_row_id, v_class_end;
  end if;

  if p_planned_departure_at is null then
    update public.attendance_records
       set planned_departure_at = null,
           early_leave_reason = null,
           planned_departure_set_at = now(),
           planned_departure_set_by = 'student',
           updated_at = now()
     where id = v_row_id;
    return;
  end if;

  -- 정규 종료보다 이르면 사유 필수
  if v_class_end is not null
     and p_planned_departure_at < v_class_end
     and v_reason is null then
    raise exception 'early_leave_reason_required';
  end if;

  update public.attendance_records
     set planned_departure_at = p_planned_departure_at,
         early_leave_reason = case
           when v_class_end is not null and p_planned_departure_at < v_class_end
             then v_reason
           else v_reason
         end,
         planned_departure_set_at = now(),
         planned_departure_set_by = 'student',
         updated_at = now()
   where id = v_row_id;
end;
$$;

revoke all on function public.student_set_planned_departure(timestamptz, text) from public;
grant execute on function public.student_set_planned_departure(timestamptz, text) to authenticated;
