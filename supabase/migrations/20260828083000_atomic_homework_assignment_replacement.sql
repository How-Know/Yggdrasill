-- Replace active homework assignments as one transaction. A failed insert must
-- never leave the previous assignments stranded as carried_over history.

create or replace function public.homework_replace_assignments_v1(
  p_academy_id uuid,
  p_student_id uuid,
  p_carried_over_ids uuid[],
  p_rows jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_expected_count integer;
  v_inserted_count integer;
  v_carried_count integer := 0;
begin
  if p_academy_id is null or p_student_id is null then
    raise exception 'HOMEWORK_ASSIGNMENT_REPLACE_ARGS_REQUIRED';
  end if;

  if not exists (
    select 1
    from public.memberships m
    where m.academy_id = p_academy_id
      and m.user_id = auth.uid()
  ) then
    raise exception 'HOMEWORK_ASSIGNMENT_REPLACE_FORBIDDEN';
  end if;

  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'HOMEWORK_ASSIGNMENT_REPLACE_ROWS_REQUIRED';
  end if;

  v_expected_count := jsonb_array_length(p_rows);
  if v_expected_count = 0 then
    raise exception 'HOMEWORK_ASSIGNMENT_REPLACE_ROWS_EMPTY';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(p_academy_id::text || ':' || p_student_id::text, 0)
  );

  if exists (
    select 1
    from jsonb_to_recordset(p_rows) as x(
      id uuid,
      academy_id uuid,
      student_id uuid,
      homework_item_id uuid,
      carry_over_from_id uuid
    )
    where x.id is null
       or x.academy_id is distinct from p_academy_id
       or x.student_id is distinct from p_student_id
       or x.homework_item_id is null
       or not exists (
         select 1
         from public.homework_items hi
         where hi.id = x.homework_item_id
           and hi.academy_id = p_academy_id
           and hi.student_id = p_student_id
       )
  ) then
    raise exception 'HOMEWORK_ASSIGNMENT_REPLACE_INVALID_ROW';
  end if;

  if (
    select count(distinct x.id)
    from jsonb_to_recordset(p_rows) as x(id uuid)
  ) <> v_expected_count
  or (
    select count(distinct x.homework_item_id)
    from jsonb_to_recordset(p_rows) as x(homework_item_id uuid)
  ) <> v_expected_count then
    raise exception 'HOMEWORK_ASSIGNMENT_REPLACE_DUPLICATE_ROW';
  end if;

  if cardinality(coalesce(p_carried_over_ids, array[]::uuid[])) > 0 then
    if (
      select count(*)
      from public.homework_assignments a
      where a.id = any(p_carried_over_ids)
        and a.academy_id = p_academy_id
        and a.student_id = p_student_id
        and a.status <> 'completed'
        and exists (
          select 1
          from jsonb_to_recordset(p_rows) as x(
            homework_item_id uuid,
            carry_over_from_id uuid
          )
          where x.homework_item_id = a.homework_item_id
            and x.carry_over_from_id = a.id
        )
    ) <> cardinality(p_carried_over_ids) then
      raise exception 'HOMEWORK_ASSIGNMENT_REPLACE_INVALID_PREDECESSOR';
    end if;

    update public.homework_assignments a
    set status = 'carried_over',
        updated_at = now(),
        version = a.version + 1
    where a.id = any(p_carried_over_ids)
      and a.academy_id = p_academy_id
      and a.student_id = p_student_id
      and a.status <> 'completed';

    get diagnostics v_carried_count = row_count;
  end if;

  insert into public.homework_assignments (
    id,
    academy_id,
    student_id,
    homework_item_id,
    progress,
    issue_type,
    issue_note,
    group_id,
    group_title_snapshot,
    learning_track_code_snapshot,
    assigned_at,
    due_date,
    due_at,
    order_index,
    status,
    note,
    live_release_id,
    release_export_job_id,
    live_release_locked_at,
    repeat_index,
    split_parts,
    split_round,
    carry_over_from_id
  )
  select
    x.id,
    x.academy_id,
    x.student_id,
    x.homework_item_id,
    x.progress,
    x.issue_type,
    x.issue_note,
    x.group_id,
    x.group_title_snapshot,
    x.learning_track_code_snapshot,
    x.assigned_at,
    x.due_date,
    x.due_at,
    x.order_index,
    coalesce(x.status, 'assigned'),
    x.note,
    x.live_release_id,
    x.release_export_job_id,
    x.live_release_locked_at,
    coalesce(x.repeat_index, 1),
    coalesce(x.split_parts, 1),
    coalesce(x.split_round, 1),
    x.carry_over_from_id
  from jsonb_to_recordset(p_rows) as x(
    id uuid,
    academy_id uuid,
    student_id uuid,
    homework_item_id uuid,
    progress integer,
    issue_type text,
    issue_note text,
    group_id uuid,
    group_title_snapshot text,
    learning_track_code_snapshot text,
    assigned_at timestamptz,
    due_date date,
    due_at timestamptz,
    order_index integer,
    status text,
    note text,
    live_release_id uuid,
    release_export_job_id uuid,
    live_release_locked_at timestamptz,
    repeat_index integer,
    split_parts integer,
    split_round integer,
    carry_over_from_id uuid
  );

  get diagnostics v_inserted_count = row_count;
  if v_inserted_count <> v_expected_count then
    raise exception
      'HOMEWORK_ASSIGNMENT_REPLACE_INSERT_MISMATCH expected=% actual=%',
      v_expected_count,
      v_inserted_count;
  end if;

  return jsonb_build_object(
    'inserted_count', v_inserted_count,
    'carried_over_count', v_carried_count
  );
end;
$$;

revoke all on function public.homework_replace_assignments_v1(
  uuid, uuid, uuid[], jsonb
) from public;
grant execute on function public.homework_replace_assignments_v1(
  uuid, uuid, uuid[], jsonb
) to authenticated;

-- Repair only CLUZ4477 rows that are active homework items but have no active
-- assignment successor. Legitimate carried_over history remains untouched.
with orphaned as (
  select a.id
  from public.homework_assignments a
  join public.homework_items hi
    on hi.id = a.homework_item_id
   and hi.academy_id = a.academy_id
   and hi.student_id = a.student_id
  where a.academy_id = '3ff51b8d-3cfb-4a36-a1a1-b63aebbde677'::uuid
    and a.student_id = '9d21ead1-becb-492e-b1ab-b8d37ea376c2'::uuid
    and upper(hi.assignment_code) = 'CLUZ4477'
    and hi.status = 0
    and hi.phase in (1, 2, 3)
    and a.status = 'carried_over'
    and not exists (
      select 1
      from public.homework_assignments active
      where active.academy_id = a.academy_id
        and active.student_id = a.student_id
        and active.homework_item_id = a.homework_item_id
        and active.status in ('assigned', 'in_progress', 'carried_to_class')
    )
)
update public.homework_assignments a
set status = 'carried_to_class',
    due_for_check_at = coalesce(a.due_for_check_at, a.due_at),
    updated_at = now(),
    version = a.version + 1
where a.id in (select id from orphaned);
