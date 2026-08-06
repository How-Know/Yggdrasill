-- Immutable homework inspection outcomes and atomic group transitions.

alter table public.homework_assignment_checks
  add column if not exists outcome text not null default 'legacy',
  add column if not exists reason text,
  add column if not exists scheduled_due_at timestamptz,
  add column if not exists next_due_at timestamptz,
  add column if not exists group_check_id uuid,
  add column if not exists idempotency_key uuid;

alter table public.homework_assignment_checks
  drop constraint if exists homework_assignment_checks_outcome_chk;
alter table public.homework_assignment_checks
  add constraint homework_assignment_checks_outcome_chk
  check (outcome in ('legacy', 'graded', 'not_done', 'left_behind'));

alter table public.homework_assignment_checks
  drop constraint if exists homework_assignment_checks_reason_chk;
alter table public.homework_assignment_checks
  add constraint homework_assignment_checks_reason_chk
  check (
    (outcome in ('legacy', 'graded') and reason is null)
    or (outcome = 'not_done' and reason = 'not_done')
    or (outcome = 'left_behind' and reason = 'left_behind')
  );

create unique index if not exists
  uidx_homework_assignment_checks_idempotency
  on public.homework_assignment_checks(assignment_id, idempotency_key)
  where assignment_id is not null and idempotency_key is not null;

create index if not exists idx_homework_assignment_checks_group_check
  on public.homework_assignment_checks(academy_id, group_check_id);

alter table public.homework_assignments
  add column if not exists original_due_at timestamptz,
  add column if not exists due_for_check_at timestamptz,
  add column if not exists absence_carryover boolean not null default false,
  add column if not exists defer_count integer not null default 0;

update public.homework_assignments
set original_due_at = due_at
where original_due_at is null and due_at is not null;

alter table public.homework_assignments
  drop constraint if exists homework_assignments_defer_count_chk;
alter table public.homework_assignments
  add constraint homework_assignments_defer_count_chk
  check (defer_count >= 0);

create or replace function public._homework_assignment_set_original_due_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.original_due_at is null and new.due_at is not null then
    new.original_due_at := new.due_at;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_homework_assignment_set_original_due_at
  on public.homework_assignments;
create trigger trg_homework_assignment_set_original_due_at
before insert or update of due_at, original_due_at
on public.homework_assignments
for each row execute function public._homework_assignment_set_original_due_at();

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
  if p_outcome <> 'graded' then
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
    set check_count = coalesce(h.check_count, 0) + 1,
        status = case when p_outcome = 'graded' then 0 else 2 end,
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
        );
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

  return jsonb_build_object(
    'ok', true,
    'group_id', p_group_id,
    'outcome', p_outcome,
    'processed_count', v_processed,
    'existing_count', v_existing,
    'group_check_id', p_idempotency_key,
    'next_due_at', v_next_due_at
  );
end;
$$;

revoke all on function public.homework_record_assignment_outcome(
  uuid, uuid, uuid[], text, integer, uuid, timestamptz
) from public;
grant execute on function public.homework_record_assignment_outcome(
  uuid, uuid, uuid[], text, integer, uuid, timestamptz
) to authenticated;
