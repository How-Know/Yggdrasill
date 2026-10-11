-- The progress-only "graded" check follows the same rule as the structured
-- grading return: the open attendance keeps (or gets) an in_class/pending/
-- to_homework plan, so departure re-issues the unfinished part. Only not_done
-- reports returned_to_class; a graded group never left the today list.

create or replace function public.homework_record_assignment_outcome(
  p_student_id uuid,
  p_group_id uuid,
  p_homework_item_ids uuid[],
  p_outcome text,
  p_progress integer default 0,
  p_idempotency_key uuid default gen_random_uuid(),
  p_checked_at timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy_id uuid;
  v_item_id uuid;
  v_assignment public.homework_assignments%rowtype;
  v_next_due_at timestamptz;
  v_reason text;
  v_processed integer := 0;
  v_existing integer := 0;
  v_attendance_id uuid;
  v_return_to_class boolean := false;
begin
  if p_outcome not in ('graded', 'not_done', 'left_behind') then
    raise exception 'HOMEWORK_OUTCOME_INVALID';
  end if;
  if cardinality(coalesce(p_homework_item_ids, array[]::uuid[])) = 0 then
    raise exception 'HOMEWORK_OUTCOME_ITEMS_REQUIRED';
  end if;

  select g.academy_id
  into v_academy_id
  from public.homework_groups g
  where g.id = p_group_id
    and g.student_id = p_student_id
    and g.status = 'active';

  if v_academy_id is null then
    raise exception 'HOMEWORK_OUTCOME_GROUP_NOT_FOUND';
  end if;
  if not exists (
    select 1
    from public.memberships m
    where m.academy_id = v_academy_id
      and m.user_id = auth.uid()
  ) then
    raise exception 'HOMEWORK_OUTCOME_FORBIDDEN';
  end if;
  if exists (
    select 1
    from unnest(p_homework_item_ids) requested(item_id)
    where not exists (
      select 1
      from public.homework_group_items gi
      where gi.academy_id = v_academy_id
        and gi.student_id = p_student_id
        and gi.group_id = p_group_id
        and gi.homework_item_id = requested.item_id
    )
  ) then
    raise exception 'HOMEWORK_OUTCOME_ITEM_NOT_IN_GROUP';
  end if;

  perform pg_advisory_xact_lock(hashtext(p_group_id::text));

  if p_outcome in ('not_done', 'graded') then
    select ar.id
    into v_attendance_id
    from public.attendance_records ar
    where ar.academy_id = v_academy_id
      and ar.student_id = p_student_id
      and ar.arrival_time is not null
      and ar.departure_time is null
      and ar.arrival_time <= p_checked_at
      and ar.arrival_time > p_checked_at - interval '24 hours'
    order by ar.arrival_time desc, ar.id desc
    limit 1;
    v_return_to_class :=
      p_outcome = 'not_done' and v_attendance_id is not null;
  end if;

  if p_outcome <> 'graded' and not v_return_to_class then
    v_next_due_at := public._homework_session_plan_next_attendance_at(
      v_academy_id,
      p_student_id,
      p_checked_at
    );
    if v_next_due_at is null then
      raise exception 'HOMEWORK_OUTCOME_NEXT_CLASS_NOT_FOUND';
    end if;
  end if;
  v_reason := case p_outcome
    when 'not_done' then 'not_done'
    when 'left_behind' then 'left_behind'
    else null
  end;

  foreach v_item_id in array p_homework_item_ids
  loop
    select a.*
    into v_assignment
    from public.homework_assignments a
    where a.academy_id = v_academy_id
      and a.student_id = p_student_id
      and a.homework_item_id = v_item_id
      and a.status in ('assigned', 'in_progress', 'carried_to_class')
    order by
      (a.status = 'carried_to_class') desc,
      a.assigned_at desc,
      a.id
    limit 1
    for update;

    if v_assignment.id is null then
      raise exception 'HOMEWORK_OUTCOME_ASSIGNMENT_NOT_FOUND:%', v_item_id;
    end if;

    insert into public.homework_assignment_checks (
      academy_id,
      student_id,
      homework_item_id,
      assignment_id,
      progress,
      checked_at,
      outcome,
      reason,
      scheduled_due_at,
      next_due_at,
      group_check_id,
      idempotency_key
    )
    values (
      v_academy_id,
      p_student_id,
      v_item_id,
      v_assignment.id,
      case when p_outcome = 'graded'
        then greatest(0, least(150, p_progress))
        else 0
      end,
      p_checked_at,
      p_outcome,
      v_reason,
      v_assignment.due_at,
      v_next_due_at,
      p_idempotency_key,
      p_idempotency_key
    )
    on conflict (assignment_id, idempotency_key)
      where assignment_id is not null and idempotency_key is not null
    do nothing;

    if not found then
      v_existing := v_existing + 1;
      continue;
    end if;

    update public.homework_items h
    set check_count = case
          when p_outcome = 'graded' then coalesce(h.check_count, 0) + 1
          else coalesce(h.check_count, 0)
        end,
        status = case
          when p_outcome = 'graded' or v_return_to_class then 0
          else 2
        end,
        phase = case when p_outcome = 'graded' then h.phase else 1 end,
        run_start = case when p_outcome = 'graded' then h.run_start else null end,
        waiting_at = case
          when p_outcome = 'graded' then h.waiting_at
          else coalesce(h.waiting_at, p_checked_at)
        end,
        updated_at = now(),
        version = h.version + 1
    where h.id = v_item_id
      and h.academy_id = v_academy_id;

    if p_outcome = 'graded' then
      update public.homework_assignments a
      set progress = greatest(0, least(150, p_progress)),
          issue_type = null,
          issue_note = null,
          status = 'completed',
          due_for_check_at = null,
          absence_carryover = false,
          updated_at = now(),
          version = a.version + 1
      where a.id = v_assignment.id;

      update public.homework_session_plan_items spi
      set resolution = 'completed',
          assignment_id = v_assignment.id,
          updated_at = now(),
          version = spi.version + 1
      where spi.academy_id = v_academy_id
        and spi.student_id = p_student_id
        and spi.homework_item_id = v_item_id
        and spi.resolution in ('pending', 'confirmed')
        and (
          spi.assignment_id = v_assignment.id
          or spi.origin = 'carried_from_previous'
        )
        and not (
          v_attendance_id is not null
          and spi.source_attendance_id = v_attendance_id
          and spi.destination = 'in_class'
        );

      if v_attendance_id is not null then
        insert into public.homework_session_plan_items (
          academy_id,
          student_id,
          source_attendance_id,
          target_class_at,
          origin,
          destination,
          resolution,
          rollover_policy,
          recommended_minutes_snapshot,
          group_id,
          homework_item_id,
          order_index
        )
        select
          v_academy_id,
          p_student_id,
          v_attendance_id,
          null,
          'carried_from_previous'::public.homework_session_plan_origin,
          'in_class'::public.homework_session_plan_destination,
          'pending'::public.homework_session_plan_resolution,
          'to_homework',
          coalesce(h.recommended_minutes, h.recommended_minutes_auto),
          p_group_id,
          h.id,
          gi.item_order_index
        from public.homework_items h
        join public.homework_group_items gi
          on gi.academy_id = h.academy_id
         and gi.student_id = h.student_id
         and gi.group_id = p_group_id
         and gi.homework_item_id = h.id
        where h.id = v_item_id
          and h.academy_id = v_academy_id
          and h.completed_at is null
          and coalesce(h.status, 0) <> 1
        on conflict (source_attendance_id, homework_item_id)
          where source_attendance_id is not null
        do update set
          resolution = 'pending',
          assignment_id = null,
          updated_at = now(),
          version = homework_session_plan_items.version + 1
        where homework_session_plan_items.destination = 'in_class'
          and (
            homework_session_plan_items.resolution is distinct from 'pending'
            or homework_session_plan_items.assignment_id is not null
          );
      end if;
    elsif v_return_to_class then
      update public.homework_assignments a
      set progress = 0,
          issue_type = v_reason,
          issue_note = null,
          status = 'not_done_to_class',
          due_for_check_at = null,
          updated_at = now(),
          version = a.version + 1
      where a.id = v_assignment.id;

      -- Plans left in other sessions would otherwise return this item again
      -- on the next arrival.
      update public.homework_session_plan_items spi
      set resolution = 'promoted',
          updated_at = now(),
          version = spi.version + 1
      where spi.academy_id = v_academy_id
        and spi.student_id = p_student_id
        and spi.homework_item_id = v_item_id
        and spi.source_attendance_id is distinct from v_attendance_id
        and spi.resolution in ('pending', 'confirmed');

      insert into public.homework_session_plan_items (
        academy_id,
        student_id,
        source_attendance_id,
        target_class_at,
        origin,
        destination,
        resolution,
        rollover_policy,
        recommended_minutes_snapshot,
        group_id,
        homework_item_id,
        order_index
      )
      select
        v_academy_id,
        p_student_id,
        v_attendance_id,
        null,
        'carried_from_previous'::public.homework_session_plan_origin,
        'in_class'::public.homework_session_plan_destination,
        'pending'::public.homework_session_plan_resolution,
        'to_homework',
        coalesce(h.recommended_minutes, h.recommended_minutes_auto),
        p_group_id,
        h.id,
        gi.item_order_index
      from public.homework_items h
      join public.homework_group_items gi
        on gi.academy_id = h.academy_id
       and gi.student_id = h.student_id
       and gi.group_id = p_group_id
       and gi.homework_item_id = h.id
      where h.id = v_item_id
        and h.academy_id = v_academy_id
      on conflict (source_attendance_id, homework_item_id)
        where source_attendance_id is not null
      do update set
        destination = 'in_class',
        resolution = 'pending',
        rollover_policy = 'to_homework',
        target_class_at = null,
        assignment_id = null,
        group_id = excluded.group_id,
        updated_at = now(),
        version = homework_session_plan_items.version + 1;
    else
      update public.homework_assignments a
      set progress = 0,
          issue_type = v_reason,
          issue_note = null,
          status = 'assigned',
          due_at = v_next_due_at,
          due_for_check_at = null,
          absence_carryover = false,
          defer_count = a.defer_count + 1,
          updated_at = now(),
          version = a.version + 1
      where a.id = v_assignment.id;

      update public.homework_session_plan_items spi
      set destination = 'homework',
          resolution = 'confirmed',
          rollover_policy = 'none',
          target_class_at = v_next_due_at,
          assignment_id = v_assignment.id,
          updated_at = now(),
          version = spi.version + 1
      where spi.academy_id = v_academy_id
        and spi.student_id = p_student_id
        and spi.homework_item_id = v_item_id
        and spi.resolution in ('pending', 'confirmed');
    end if;
    v_processed := v_processed + 1;
    v_assignment := null;
  end loop;

  if v_return_to_class and v_processed > 0 then
    update public.homework_group_runtime r
    set accumulated_ms = coalesce(r.accumulated_ms, 0)
          + case
              when r.run_start is not null then greatest(
                0,
                floor(extract(epoch from (now() - r.run_start)) * 1000)::bigint
              )
              else 0
            end,
        phase = 1,
        run_start = null,
        updated_at = now(),
        version = r.version + 1
    where r.academy_id = v_academy_id
      and r.group_id = p_group_id
      and (r.run_start is not null or r.phase <> 1);
  end if;

  return jsonb_build_object(
    'ok', true,
    'group_id', p_group_id,
    'outcome', p_outcome,
    'processed_count', v_processed,
    'existing_count', v_existing,
    'group_check_id', p_idempotency_key,
    'next_due_at', v_next_due_at,
    'returned_to_class', v_return_to_class,
    'attendance_id', v_attendance_id
  );
end;
$$;

revoke all on function public.homework_record_assignment_outcome(
  uuid, uuid, uuid[], text, integer, uuid, timestamptz
) from public;
grant execute on function public.homework_record_assignment_outcome(
  uuid, uuid, uuid[], text, integer, uuid, timestamptz
) to authenticated;
