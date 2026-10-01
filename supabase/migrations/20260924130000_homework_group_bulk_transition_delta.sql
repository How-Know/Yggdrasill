-- Return the rows a group transition actually changed so clients can patch
-- shared memory instead of reloading the student.

create or replace function public.homework_group_bulk_transition_delta(
  p_group_id uuid,
  p_academy_id uuid,
  p_from_phase smallint default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamptz := now();
  v_count integer := 0;
  v_student uuid;
  v_group_id uuid;
begin
  v_count := public.homework_group_bulk_transition(
    p_group_id,
    p_academy_id,
    p_from_phase
  );

  select g.student_id
    into v_student
    from public.homework_groups g
   where g.id = p_group_id
     and g.academy_id = p_academy_id;

  if v_student is not null then
    for v_group_id in
      select distinct gi.group_id
        from public.homework_group_items gi
        join public.homework_items h
          on h.id = gi.homework_item_id
         and h.academy_id = gi.academy_id
       where gi.academy_id = p_academy_id
         and h.student_id = v_student
         and h.updated_at >= v_now
    loop
      perform public.m5_group_runtime_sync_from_children(
        p_academy_id,
        v_group_id,
        v_now
      );
    end loop;
  end if;

  return jsonb_build_object(
    'transitioned', coalesce(v_count, 0),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', h.id,
        'status', h.status,
        'phase', h.phase,
        'accumulated_ms', h.accumulated_ms,
        'cycle_base_accumulated_ms', h.cycle_base_accumulated_ms,
        'run_start', h.run_start,
        'completed_at', h.completed_at,
        'first_started_at', h.first_started_at,
        'submitted_at', h.submitted_at,
        'confirmed_at', h.confirmed_at,
        'waiting_at', h.waiting_at,
        'updated_at', h.updated_at,
        'version', h.version
      ))
      from public.homework_items h
      where h.academy_id = p_academy_id
        and h.student_id = v_student
        and (
          h.updated_at >= v_now
          or exists (
            select 1
              from public.homework_group_items gi
             where gi.academy_id = p_academy_id
               and gi.group_id = p_group_id
               and gi.homework_item_id = h.id
          )
        )
    ), '[]'::jsonb),
    'groups', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', g.id,
        'status', g.status,
        'cycle_started_at', g.cycle_started_at,
        'updated_at', g.updated_at,
        'version', g.version
      ))
      from public.homework_groups g
      where g.academy_id = p_academy_id
        and g.student_id = v_student
        and g.updated_at >= v_now
    ), '[]'::jsonb),
    'runtimes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'group_id', r.group_id,
        'phase', r.phase,
        'accumulated_ms', r.accumulated_ms,
        'run_start', r.run_start,
        'first_started_at', r.first_started_at,
        'check_count', r.check_count,
        'updated_at', r.updated_at
      ))
      from public.homework_group_runtime r
      where r.academy_id = p_academy_id
        and r.student_id = v_student
        and r.updated_at >= v_now
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.homework_group_bulk_transition_delta(uuid, uuid, smallint)
  from public;
grant execute on function public.homework_group_bulk_transition_delta(uuid, uuid, smallint)
  to anon, authenticated;
