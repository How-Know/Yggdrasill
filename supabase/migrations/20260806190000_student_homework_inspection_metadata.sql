-- Student-facing metadata for returned, deferred, and absence-carried homework.

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
      a.due_at,
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
      when ra.status = 'carried_to_class' then 'due_for_check'
      else 'assigned'
    end,
    ra.original_due_at,
    ra.due_at,
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
