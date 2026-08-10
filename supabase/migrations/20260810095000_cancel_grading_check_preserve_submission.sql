-- Cancelling a pending grading check must remove only the check/grading
-- records. The homework itself stays submitted (phase 3) until the teacher
-- returns or otherwise transitions it.
--
-- Also accept legacy/fallback graded checks that have no group_check_id.

create or replace function public.homework_rollback_structured_grading(
  p_student_id uuid,
  p_group_id uuid,
  p_homework_item_ids uuid[]
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy_id uuid;
  v_seed_check_id uuid;
  v_group_check_id uuid;
  v_item_id uuid;
  v_check public.homework_assignment_checks%rowtype;
  v_attempt_id uuid;
  v_rolled_back integer := 0;
begin
  if cardinality(coalesce(p_homework_item_ids, array[]::uuid[])) = 0 then
    raise exception 'HOMEWORK_STRUCTURED_ROLLBACK_ITEMS_REQUIRED';
  end if;

  select g.academy_id
  into v_academy_id
  from public.homework_groups g
  where g.id = p_group_id
    and g.student_id = p_student_id
    and g.status = 'active';

  if v_academy_id is null then
    raise exception 'HOMEWORK_STRUCTURED_ROLLBACK_GROUP_NOT_FOUND';
  end if;
  if not exists (
    select 1
    from public.memberships m
    where m.academy_id = v_academy_id
      and m.user_id = auth.uid()
  ) then
    raise exception 'HOMEWORK_STRUCTURED_ROLLBACK_FORBIDDEN';
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
    raise exception 'HOMEWORK_STRUCTURED_ROLLBACK_ITEM_NOT_IN_GROUP';
  end if;

  perform pg_advisory_xact_lock(hashtext(p_group_id::text));

  select c.id, c.group_check_id
  into v_seed_check_id, v_group_check_id
  from public.homework_assignment_checks c
  where c.academy_id = v_academy_id
    and c.student_id = p_student_id
    and c.homework_item_id = any(p_homework_item_ids)
    and c.outcome = 'graded'
  order by c.checked_at desc, c.id desc
  limit 1;

  if v_seed_check_id is null then
    raise exception 'HOMEWORK_STRUCTURED_ROLLBACK_CHECK_NOT_FOUND';
  end if;

  foreach v_item_id in array p_homework_item_ids
  loop
    v_check := null;
    select c.*
    into v_check
    from public.homework_assignment_checks c
    where c.academy_id = v_academy_id
      and c.student_id = p_student_id
      and c.homework_item_id = v_item_id
      and c.outcome = 'graded'
      and (
        (v_group_check_id is not null and c.group_check_id = v_group_check_id)
        or
        (v_group_check_id is null and c.group_check_id is null)
      )
    order by c.checked_at desc, c.id desc
    limit 1
    for update;

    if v_check.id is null then
      continue;
    end if;

    delete from public.homework_assignment_checks c
    where c.id = v_check.id
      and c.academy_id = v_academy_id;

    update public.homework_items h
    set check_count = greatest(coalesce(h.check_count, 0) - 1, 0),
        updated_at = now(),
        version = coalesce(h.version, 1) + 1
    where h.id = v_item_id
      and h.academy_id = v_academy_id;

    update public.homework_assignments a
    set status = 'assigned',
        progress = 0,
        issue_type = null,
        issue_note = null,
        due_for_check_at = null,
        updated_at = now(),
        version = coalesce(a.version, 1) + 1
    where a.id = v_check.assignment_id
      and a.academy_id = v_academy_id;

    update public.homework_session_plan_items spi
    set resolution = 'confirmed',
        updated_at = now(),
        version = coalesce(spi.version, 1) + 1
    where spi.academy_id = v_academy_id
      and spi.student_id = p_student_id
      and spi.homework_item_id = v_item_id
      and spi.assignment_id = v_check.assignment_id
      and spi.resolution = 'completed';

    select a.id
    into v_attempt_id
    from public.homework_test_grading_attempts a
    where a.academy_id = v_academy_id
      and a.student_id = p_student_id
      and a.homework_item_id = v_item_id
    order by a.graded_at desc, a.id desc
    limit 1;

    if v_attempt_id is not null then
      delete from public.homework_test_grading_attempts a
      where a.id = v_attempt_id
        and a.academy_id = v_academy_id;
    end if;
    v_attempt_id := null;

    -- Intentionally do not call homework_wait: preserve phase 3/submitted_at.
    v_rolled_back := v_rolled_back + 1;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'group_id', p_group_id,
    'group_check_id', v_group_check_id,
    'rolled_back_count', v_rolled_back
  );
end;
$$;

revoke all on function public.homework_rollback_structured_grading(
  uuid, uuid, uuid[]
) from public;
grant execute on function public.homework_rollback_structured_grading(
  uuid, uuid, uuid[]
) to anon, authenticated;
