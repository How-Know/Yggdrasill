-- absence_carryover is true only when the student was actually absent on the
-- original due day. Teacher-missed inspection (student attended) stays false
-- so clients can label it as "미검사" instead of "결석".

create or replace function public._homework_student_absent_on_due_day(
  p_academy_id uuid,
  p_student_id uuid,
  p_due_at timestamptz
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  with due_day as (
    select (p_due_at at time zone 'Asia/Seoul')::date as day
  ),
  sessions as (
    select
      ar.arrival_time,
      coalesce(ar.is_present, false) as attended_flag
    from public.attendance_records ar
    join due_day d on true
    where ar.academy_id = p_academy_id
      and ar.student_id = p_student_id
      and ar.class_date_time is not null
      and (ar.class_date_time at time zone 'Asia/Seoul')::date = d.day
  )
  select case
    -- No class record that day → not treated as absence (likely missed check).
    when not exists (select 1 from sessions) then false
    -- Any arrival/present marks that day as attended.
    when exists (
      select 1
      from sessions s
      where s.arrival_time is not null
         or s.attended_flag
    ) then false
    else true
  end;
$$;

revoke all on function public._homework_student_absent_on_due_day(
  uuid, uuid, timestamptz
) from public;

create or replace function public._normalize_homework_return_absence()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_original timestamptz;
begin
  if new.status = 'carried_to_class'
     and new.due_for_check_at is not null then
    v_original := coalesce(new.original_due_at, new.due_at);
    if v_original is null or v_original >= new.due_for_check_at then
      new.absence_carryover := false;
    else
      new.absence_carryover := public._homework_student_absent_on_due_day(
        new.academy_id,
        new.student_id,
        v_original
      );
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_homework_return_absence
  on public.homework_assignments;
create trigger trg_homework_return_absence
before insert or update of status, due_for_check_at, due_at, original_due_at,
  academy_id, student_id
on public.homework_assignments
for each row execute function public._normalize_homework_return_absence();

update public.homework_assignments a
set absence_carryover = (
  a.status = 'carried_to_class'
  and a.due_for_check_at is not null
  and coalesce(a.original_due_at, a.due_at) is not null
  and coalesce(a.original_due_at, a.due_at) < a.due_for_check_at
  and public._homework_student_absent_on_due_day(
    a.academy_id,
    a.student_id,
    coalesce(a.original_due_at, a.due_at)
  )
)
where a.status = 'carried_to_class';
