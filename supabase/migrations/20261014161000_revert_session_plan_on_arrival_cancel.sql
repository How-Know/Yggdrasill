-- Cancelling an arrival deletes the attendance row. The plans that arrival
-- copied into class used to stay pending with source_attendance_id set null
-- (ON DELETE SET NULL). "숙제 안 함" then marked those in_class rows promoted,
-- which homework_session_plan_promoted_destination_chk rejects, so the whole
-- check rolled back.
--
-- Arrival cancel now undoes uninspected in-class plans before the row goes
-- away, and restores the homework plan they were copied from. Already checked
-- items keep their result; their leftover in-class plan is cancelled so it
-- cannot become another attendance-less pending row.
-- "숙제 안 함" closes homework / next-session plans as promoted, and in-class
-- plans as cancelled.

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
      -- on the next arrival. in_class + promoted is illegal, so an
      -- attendance-less class plan is cancelled instead of promoted.
      update public.homework_session_plan_items spi
      set resolution = case
            when spi.destination = 'in_class'
              then 'cancelled'::public.homework_session_plan_resolution
            else 'promoted'::public.homework_session_plan_resolution
          end,
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

create or replace function public._homework_session_plan_revert_on_attendance_delete()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_plan public.homework_session_plan_items%rowtype;
  v_parent public.homework_session_plan_items%rowtype;
  v_assignment_id uuid;
  v_inspected boolean;
  v_has_other_assignment boolean;
  v_since timestamptz;
begin
  v_since := coalesce(old.arrival_time, old.created_at, now());

  -- Restore homework only when this attendance is an open arrival being
  -- cancelled. A departed class, a planned absence, or a cascading student
  -- delete just closes leftover in-class plans so they cannot stay pending
  -- after source_attendance_id is cleared.
  if pg_trigger_depth() > 1
     or old.arrival_time is null
     or old.departure_time is not null
  then
    update public.homework_session_plan_items spi
    set resolution = 'cancelled',
        updated_at = now(),
        version = spi.version + 1
    where spi.source_attendance_id = old.id
      and spi.destination = 'in_class'
      and spi.resolution in ('pending', 'confirmed');
    return old;
  end if;

  for v_plan in
    select spi.*
    from public.homework_session_plan_items spi
    where spi.source_attendance_id = old.id
      and spi.destination = 'in_class'
      and spi.resolution in ('pending', 'confirmed')
    for update of spi
  loop
    v_inspected := exists (
      select 1
      from public.homework_assignment_checks c
      where c.academy_id = old.academy_id
        and c.student_id = old.student_id
        and c.homework_item_id = v_plan.homework_item_id
        and c.checked_at >= v_since
    ) or exists (
      select 1
      from public.homework_assignments a
      where a.id = v_plan.assignment_id
        and a.status in ('completed', 'not_done_to_class', 'carried_over')
    ) or exists (
      select 1
      from public.homework_items h
      where h.id = v_plan.homework_item_id
        and (
          h.completed_at is not null
          or coalesce(h.status, 0) = 1
        )
    );

    if v_inspected then
      update public.homework_session_plan_items spi
      set resolution = 'cancelled',
          updated_at = now(),
          version = spi.version + 1
      where spi.id = v_plan.id
        and spi.resolution in ('pending', 'confirmed');
      continue;
    end if;

    if v_plan.carried_from_plan_item_id is not null then
      select parent.*
      into v_parent
      from public.homework_session_plan_items parent
      where parent.id = v_plan.carried_from_plan_item_id
      for update;

      if found
         and v_parent.resolution = 'promoted'
         and v_parent.destination in ('homework', 'next_session')
         and not exists (
           select 1
           from public.homework_session_plan_items sibling
           where sibling.carried_from_plan_item_id = v_parent.id
             and sibling.id <> v_plan.id
             and sibling.resolution in ('pending', 'confirmed')
         )
      then
        v_assignment_id := coalesce(v_parent.assignment_id, v_plan.assignment_id);
        v_has_other_assignment := exists (
          select 1
          from public.homework_assignments other
          where other.id is distinct from v_assignment_id
            and other.academy_id = v_plan.academy_id
            and other.student_id = v_plan.student_id
            and other.homework_item_id = v_plan.homework_item_id
            and other.status in ('assigned', 'in_progress', 'carried_to_class')
        );

        if v_has_other_assignment then
          update public.homework_assignments a
          set status = 'carried_over',
              due_for_check_at = null,
              absence_carryover = false,
              updated_at = now(),
              version = a.version + 1
          where a.id = v_assignment_id
            and a.status = 'carried_to_class';
        else
          update public.homework_session_plan_items parent
          set resolution = case v_parent.destination
                when 'homework'
                  then 'confirmed'::public.homework_session_plan_resolution
                else 'pending'::public.homework_session_plan_resolution
              end,
              updated_at = now(),
              version = parent.version + 1
          where parent.id = v_parent.id
            and parent.resolution = 'promoted';

          if v_parent.destination = 'homework' then
            update public.homework_assignments a
            set status = 'assigned',
                due_for_check_at = null,
                absence_carryover = false,
                updated_at = now(),
                version = a.version + 1
            where a.id = v_assignment_id
              and a.status = 'carried_to_class';

            update public.homework_items h
            set status = 2,
                phase = 1,
                run_start = null,
                updated_at = now(),
                version = h.version + 1
            where h.id = v_plan.homework_item_id
              and h.completed_at is null
              and coalesce(h.status, 0) = 0
              and not public._homework_item_keeps_complete_confirm(h.id);
          end if;
        end if;
      end if;
    end if;

    delete from public.homework_session_plan_items spi
    where spi.id = v_plan.id
      and spi.destination = 'in_class'
      and spi.resolution in ('pending', 'confirmed');
  end loop;

  return old;
end;
$$;

revoke all on function public._homework_session_plan_revert_on_attendance_delete()
  from public;

drop trigger if exists trg_homework_session_plan_revert_on_attendance_delete
  on public.attendance_records;
create trigger trg_homework_session_plan_revert_on_attendance_delete
before delete on public.attendance_records
for each row
execute function public._homework_session_plan_revert_on_attendance_delete();

-- Leftovers already created by an arrival cancel. Do not restore their parent
-- plans: a later homework assignment may already be open.
update public.homework_session_plan_items
set resolution = 'cancelled'
where destination = 'in_class'
  and resolution in ('pending', 'confirmed')
  and source_attendance_id is null;
