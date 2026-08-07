-- Align SQL next-class resolver with Dart NextClassStartResolver:
-- 1) Prefer session start (min per set_id/day), then filter by p_after
--    so a later block in the current set is not treated as the next class.
-- 2) Ignore attendance rows without class_date_time (date-only → midnight).
--
-- Also: when deriving due_at from due_date only, prefer the latest matching
-- plan target; keep midnight fallback only when no plan target exists.

create or replace function public._sync_homework_assignment_due_at()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_plan_due_at timestamptz;
begin
  if tg_op = 'UPDATE'
     and new.due_date is distinct from old.due_date
     and new.due_at is not distinct from old.due_at then
    new.due_at := null;
  end if;

  if new.due_at is null and new.due_date is not null then
    select spi.target_class_at
    into v_plan_due_at
    from public.homework_session_plan_items spi
    where spi.academy_id = new.academy_id
      and spi.student_id = new.student_id
      and spi.homework_item_id = new.homework_item_id
      and spi.destination = 'homework'
      and spi.target_class_at is not null
      and (spi.target_class_at at time zone 'Asia/Seoul')::date = new.due_date
    order by
      (spi.assignment_id = new.id) desc,
      spi.updated_at desc nulls last,
      spi.created_at desc,
      spi.id desc
    limit 1;

    new.due_at := coalesce(
      v_plan_due_at,
      new.due_date::timestamp at time zone 'Asia/Seoul'
    );
  end if;

  if new.due_at is not null then
    new.due_date := (new.due_at at time zone 'Asia/Seoul')::date;
  end if;
  return new;
end;
$$;

create or replace function public._homework_session_plan_next_attendance_at(
  p_academy_id uuid,
  p_student_id uuid,
  p_after timestamptz
)
returns timestamptz
language sql
stable
security definer
set search_path = public
as $$
  with future_attendance_sessions as (
    select
      min(ar.class_date_time) as class_at
    from public.attendance_records ar
    where ar.academy_id = p_academy_id
      and ar.student_id = p_student_id
      and ar.class_date_time is not null
    group by
      (ar.class_date_time at time zone 'Asia/Seoul')::date,
      coalesce(ar.set_id::text, ar.id::text)
  ),
  future_attendance as (
    select fas.class_at
    from future_attendance_sessions fas
    where fas.class_at > p_after
  ),
  future_template_raw as (
    select
      (
        ((p_after at time zone 'Asia/Seoul')::date + days.offset_days)
          + make_time(b.start_hour, b.start_minute, 0)
      ) at time zone 'Asia/Seoul' as class_at,
      coalesce(b.set_id::text, b.id::text) as session_key,
      (
        (p_after at time zone 'Asia/Seoul')::date + days.offset_days
      ) as class_date
    from generate_series(0, 13) as days(offset_days)
    join public.student_time_blocks b
      on b.academy_id = p_academy_id
     and b.student_id = p_student_id
     and b.day_index = extract(
       isodow from (
         (p_after at time zone 'Asia/Seoul')::date + days.offset_days
       )
     )::integer - 1
     and b.start_date <= (
       (p_after at time zone 'Asia/Seoul')::date + days.offset_days
     )
     and (
       b.end_date is null
       or b.end_date >= (
         (p_after at time zone 'Asia/Seoul')::date + days.offset_days
       )
     )
  ),
  future_template_sessions as (
    select min(ftr.class_at) as class_at
    from future_template_raw ftr
    group by ftr.class_date, ftr.session_key
  ),
  future_template as (
    select fts.class_at
    from future_template_sessions fts
    where fts.class_at > p_after
  )
  select candidates.class_at
  from (
    select class_at from future_attendance
    union
    select class_at from future_template
  ) candidates
  order by candidates.class_at
  limit 1;
$$;

revoke all on function public._homework_session_plan_next_attendance_at(
  uuid, uuid, timestamptz
) from public;
