-- Keep the editable inspection date authoritative across teacher grading and
-- student homework views. original_due_at remains immutable history.

create or replace function public.homework_update_session_plan_due_date(
  p_source_attendance_id uuid,
  p_homework_item_ids uuid[],
  p_due_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_attendance public.attendance_records%rowtype;
  v_updated_count integer := 0;
  v_assignment_count integer := 0;
begin
  select ar.*
  into v_attendance
  from public.attendance_records ar
  where ar.id = p_source_attendance_id;

  if v_attendance.id is null then
    raise exception 'HOMEWORK_SESSION_PLAN_ATTENDANCE_NOT_FOUND';
  end if;

  if not exists (
    select 1
    from public.memberships m
    where m.academy_id = v_attendance.academy_id
      and m.user_id = auth.uid()
  ) then
    raise exception 'HOMEWORK_SESSION_PLAN_FORBIDDEN';
  end if;

  if p_due_at is null
     or cardinality(coalesce(p_homework_item_ids, array[]::uuid[])) = 0 then
    raise exception 'HOMEWORK_SESSION_PLAN_DUE_DATE_REQUIRED';
  end if;

  with updated_plans as (
    update public.homework_session_plan_items spi
    set target_class_at = p_due_at,
        updated_at = now(),
        version = spi.version + 1
    where spi.academy_id = v_attendance.academy_id
      and spi.student_id = v_attendance.student_id
      and spi.homework_item_id = any(p_homework_item_ids)
      and spi.destination = 'homework'
      and spi.resolution in ('pending', 'confirmed')
      and spi.target_class_at is distinct from p_due_at
    returning spi.id
  )
  select count(*)::integer
  into v_updated_count
  from updated_plans;

  with updated_assignments as (
    update public.homework_assignments a
    set due_at = p_due_at,
        due_date = (p_due_at at time zone 'Asia/Seoul')::date,
        due_for_check_at = case
          when a.due_for_check_at is not null then p_due_at
          else null
        end,
        updated_at = now(),
        version = a.version + 1
    where a.academy_id = v_attendance.academy_id
      and a.student_id = v_attendance.student_id
      and a.homework_item_id = any(p_homework_item_ids)
      and a.status in ('assigned', 'in_progress', 'carried_to_class')
      and (
        a.due_at is distinct from p_due_at
        or a.due_date is distinct from
          (p_due_at at time zone 'Asia/Seoul')::date
        or (
          a.due_for_check_at is not null
          and a.due_for_check_at is distinct from p_due_at
        )
      )
    returning a.id
  )
  select count(*)::integer
  into v_assignment_count
  from updated_assignments;

  return jsonb_build_object(
    'attendance_id', p_source_attendance_id,
    'updated_count', v_updated_count,
    'assignment_count', v_assignment_count,
    'due_at', p_due_at
  );
end;
$$;

revoke all on function public.homework_update_session_plan_due_date(
  uuid, uuid[], timestamptz
) from public;
grant execute on function public.homework_update_session_plan_due_date(
  uuid, uuid[], timestamptz
) to authenticated;

create or replace function public.student_homework_inspection_metadata_v1()
returns table(
  group_id uuid,
  inspection_status text,
  original_due_at timestamptz,
  current_due_at timestamptz,
  absence_carryover boolean,
  defer_count integer,
  last_outcome text,
  last_reason text
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
begin
  select i.academy_id, i.student_id
  into v_academy, v_student
  from public.student_app_identity() i;

  if v_student is null then
    raise exception 'no student account';
  end if;

  return query
  with ranked_assignments as (
    select
      coalesce(a.group_id, gi.group_id) as resolved_group_id,
      a.id,
      a.status,
      a.original_due_at,
      coalesce(a.due_for_check_at, a.due_at) as effective_due_at,
      a.absence_carryover,
      a.defer_count,
      row_number() over (
        partition by coalesce(a.group_id, gi.group_id)
        order by
          (a.status = 'carried_to_class') desc,
          a.assigned_at desc,
          a.id desc
      ) as rank_in_group
    from public.homework_assignments a
    left join public.homework_group_items gi
      on gi.academy_id = a.academy_id
     and gi.student_id = a.student_id
     and gi.homework_item_id = a.homework_item_id
    where a.academy_id = v_academy
      and a.student_id = v_student
      and a.status in ('assigned', 'in_progress', 'carried_to_class')
  )
  select
    ra.resolved_group_id,
    case
      when (ra.effective_due_at at time zone 'Asia/Seoul')::date
        = (now() at time zone 'Asia/Seoul')::date
      then 'due_for_check'
      else 'assigned'
    end,
    ra.original_due_at,
    ra.effective_due_at,
    ra.absence_carryover,
    ra.defer_count,
    latest_check.outcome,
    latest_check.reason
  from ranked_assignments ra
  left join lateral (
    select c.outcome, c.reason
    from public.homework_assignment_checks c
    where c.assignment_id = ra.id
    order by c.checked_at desc, c.id desc
    limit 1
  ) latest_check on true
  where ra.rank_in_group = 1
    and ra.resolved_group_id is not null;
end;
$$;

revoke all on function public.student_homework_inspection_metadata_v1()
  from public;
grant execute on function public.student_homework_inspection_metadata_v1()
  to authenticated;
