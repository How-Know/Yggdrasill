-- Concurrency: reject stale group transitions when the device's expected
-- from_phase no longer matches the server's current phase.
--
-- Example race: the grader confirms a group (phase 3 → 4) at the same moment the
-- student taps submit on the M5 (from_phase=2). Previously the transition was
-- applied based purely on the supplied from_phase, so a stale tap could push the
-- group into the wrong phase (last-writer-wins). Now the command verifies the
-- live phase first and returns ok:false + 'phase_mismatch'; the gateway forwards
-- the failure and the M5 already refreshes its list on a failed transition ack
-- (clear_group_transition_pending → fw_publish_list_homeworks).

-- 1) Device v2 wrapper: guard the live phase before applying / recording the request.
create or replace function public.m5_group_transition_command(
  p_academy_id uuid,
  p_group_id uuid,
  p_from_phase smallint default null,
  p_request_id text default null,
  p_device_id text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request_id text := nullif(trim(coalesce(p_request_id, '')), '');
  v_device_id text := nullif(trim(coalesce(p_device_id, '')), '');
  v_group_student uuid;
  v_bound_student uuid;
  v_current_phase smallint;
  v_changed integer := 0;
  v_inserted integer := 0;
  v_result jsonb;
  v_existing jsonb;
begin
  if p_academy_id is null then
    return jsonb_build_object('ok', false, 'error', 'academy_id_required');
  end if;
  if p_group_id is null then
    return jsonb_build_object('ok', false, 'error', 'group_id_required');
  end if;
  if v_request_id is null then
    return jsonb_build_object('ok', false, 'error', 'request_id_required');
  end if;
  if v_device_id is null then
    return jsonb_build_object('ok', false, 'error', 'device_id_required');
  end if;

  select g.student_id
    into v_group_student
    from public.homework_groups g
   where g.id = p_group_id
     and g.academy_id = p_academy_id
   limit 1;

  if v_group_student is null then
    return jsonb_build_object(
      'ok', false,
      'error', 'group_not_found',
      'academy_id', p_academy_id,
      'group_id', p_group_id,
      'request_id', v_request_id,
      'device_id', v_device_id
    );
  end if;

  select b.student_id
    into v_bound_student
    from public.m5_device_bindings b
   where b.academy_id = p_academy_id
     and b.device_id = v_device_id
     and b.active = true
   limit 1;

  if v_bound_student is null then
    return jsonb_build_object(
      'ok', false,
      'error', 'device_not_bound',
      'academy_id', p_academy_id,
      'group_id', p_group_id,
      'student_id', v_group_student,
      'request_id', v_request_id,
      'device_id', v_device_id
    );
  end if;

  if v_bound_student <> v_group_student then
    return jsonb_build_object(
      'ok', false,
      'error', 'binding_mismatch',
      'academy_id', p_academy_id,
      'group_id', p_group_id,
      'student_id', v_group_student,
      'bound_student_id', v_bound_student,
      'request_id', v_request_id,
      'device_id', v_device_id
    );
  end if;

  -- Phase guard: compare the supplied from_phase against the live group phase.
  -- Cycle taps (1/2/4) must match exactly; submit-all (99) must come from an
  -- active/waiting phase (1 or 2). A mismatch means the grader (or another
  -- device) already advanced the group → reject so the M5 refreshes.
  if p_from_phase is not null then
    perform public.m5_group_runtime_seed(p_academy_id, p_group_id);
    select r.phase into v_current_phase
      from public.homework_group_runtime r
     where r.academy_id = p_academy_id
       and r.group_id = p_group_id
     limit 1;

    if v_current_phase is not null then
      if p_from_phase in (1, 2, 4) and v_current_phase <> p_from_phase then
        return jsonb_build_object(
          'ok', false,
          'error', 'phase_mismatch',
          'current_phase', v_current_phase,
          'from_phase', p_from_phase,
          'academy_id', p_academy_id,
          'group_id', p_group_id,
          'student_id', v_group_student,
          'request_id', v_request_id,
          'device_id', v_device_id
        );
      elsif p_from_phase = 99 and v_current_phase not in (1, 2) then
        return jsonb_build_object(
          'ok', false,
          'error', 'phase_mismatch',
          'current_phase', v_current_phase,
          'from_phase', p_from_phase,
          'academy_id', p_academy_id,
          'group_id', p_group_id,
          'student_id', v_group_student,
          'request_id', v_request_id,
          'device_id', v_device_id
        );
      end if;
    end if;
  end if;

  insert into public.homework_group_transition_requests (
    academy_id,
    request_id,
    group_id,
    student_id,
    from_phase,
    device_id
  ) values (
    p_academy_id,
    v_request_id,
    p_group_id,
    v_group_student,
    p_from_phase,
    v_device_id
  )
  on conflict (academy_id, request_id) do nothing;

  get diagnostics v_inserted = row_count;
  if v_inserted = 0 then
    select r.result_json
      into v_existing
      from public.homework_group_transition_requests r
     where r.academy_id = p_academy_id
       and r.request_id = v_request_id
     limit 1;

    if v_existing is null then
      return jsonb_build_object(
        'ok', true,
        'dedup', true,
        'changed', 0,
        'academy_id', p_academy_id,
        'group_id', p_group_id,
        'student_id', v_group_student,
        'request_id', v_request_id,
        'device_id', v_device_id
      );
    end if;

    return v_existing || jsonb_build_object('dedup', true);
  end if;

  v_changed := coalesce(
    public.homework_group_bulk_transition(p_group_id, p_academy_id, p_from_phase),
    0
  );

  v_result := jsonb_build_object(
    'ok', true,
    'dedup', false,
    'changed', v_changed,
    'academy_id', p_academy_id,
    'group_id', p_group_id,
    'student_id', v_group_student,
    'from_phase', p_from_phase,
    'request_id', v_request_id,
    'device_id', v_device_id
  );

  update public.homework_group_transition_requests r
     set changed_count = v_changed,
         result_json = v_result,
         updated_at = now()
   where r.academy_id = p_academy_id
     and r.request_id = v_request_id;

  return v_result;
exception when others then
  v_result := jsonb_build_object(
    'ok', false,
    'error', sqlerrm,
    'academy_id', p_academy_id,
    'group_id', p_group_id,
    'student_id', v_group_student,
    'request_id', v_request_id,
    'device_id', v_device_id
  );

  if v_request_id is not null then
    update public.homework_group_transition_requests r
       set result_json = v_result,
           updated_at = now()
     where r.academy_id = p_academy_id
       and r.request_id = v_request_id;
  end if;

  return v_result;
end;
$$;

revoke all on function public.m5_group_transition_command(uuid, uuid, smallint, text, text) from public;
grant execute on function public.m5_group_transition_command(uuid, uuid, smallint, text, text) to service_role;

-- 2) Defensive guard in the runtime-state sync used by the legacy path: never
-- overwrite the runtime phase from a stale from_phase. Returns -1 on mismatch.
create or replace function public.m5_group_transition_state_v3(
  p_academy_id uuid,
  p_group_id uuid,
  p_from_phase smallint default null
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamptz := now();
  v_from_phase smallint := p_from_phase;
  v_elapsed_ms bigint := 0;
  v_rows integer := 0;
  v_new_phase smallint;
  v_runtime public.homework_group_runtime%rowtype;
begin
  perform public.m5_group_runtime_seed(p_academy_id, p_group_id);

  select *
    into v_runtime
    from public.homework_group_runtime r
   where r.academy_id = p_academy_id
     and r.group_id = p_group_id
   for update;

  if not found then
    return 0;
  end if;

  -- Phase guard: reject stale cycle transitions (1/2/4 must match live phase).
  if p_from_phase is not null
     and p_from_phase in (1, 2, 4)
     and coalesce(v_runtime.phase, 1) <> p_from_phase then
    return -1;
  end if;

  if v_from_phase is null then
    v_from_phase := coalesce(v_runtime.phase, 1);
  end if;

  if v_from_phase = 1 then
    v_new_phase := 2;
    -- Single-running invariant: pause all other running groups for this student.
    with paused as (
      update public.homework_group_runtime r
         set accumulated_ms = coalesce(r.accumulated_ms, 0)
                               + case
                                   when r.run_start is not null
                                     then greatest(0, floor(extract(epoch from (v_now - r.run_start)) * 1000)::bigint)
                                   else 0
                                 end,
             run_start = null,
             phase = 1,
             updated_at = v_now,
             version = coalesce(r.version, 1) + 1
       where r.academy_id = p_academy_id
         and r.student_id = v_runtime.student_id
         and r.group_id <> p_group_id
         and (r.phase = 2 or r.run_start is not null)
      returning r.group_id
    )
    update public.homework_groups g
       set updated_at = v_now,
           version = coalesce(g.version, 1) + 1
      from paused p
     where g.id = p.group_id
       and g.academy_id = p_academy_id
       and g.status = 'active';

    -- Pause children of other running groups
    update public.homework_items hi
       set phase = 1, run_start = null, updated_at = v_now
     where hi.academy_id = p_academy_id
       and hi.student_id = v_runtime.student_id
       and hi.completed_at is null
       and (hi.phase = 2 or hi.run_start is not null)
       and hi.id not in (
         select gi2.homework_item_id
           from public.homework_group_items gi2
          where gi2.group_id = p_group_id
            and gi2.academy_id = p_academy_id
       );

    update public.homework_group_runtime r
       set phase = 2,
           run_start = coalesce(r.run_start, v_now),
           first_started_at = coalesce(r.first_started_at, v_now),
           updated_at = v_now,
           version = coalesce(r.version, 1) + 1
     where r.academy_id = p_academy_id
       and r.group_id = p_group_id
       and (r.phase <> 2 or r.run_start is null);
    get diagnostics v_rows = row_count;

  elsif v_from_phase = 2 then
    v_new_phase := 3;
    v_elapsed_ms := case
      when v_runtime.run_start is not null
        then greatest(0, floor(extract(epoch from (v_now - v_runtime.run_start)) * 1000)::bigint)
      else 0
    end;

    update public.homework_group_runtime r
       set phase = 3,
           accumulated_ms = coalesce(r.accumulated_ms, 0) + v_elapsed_ms,
           run_start = null,
           check_count = coalesce(r.check_count, 0) + 1,
           updated_at = v_now,
           version = coalesce(r.version, 1) + 1
     where r.academy_id = p_academy_id
       and r.group_id = p_group_id
       and (r.phase <> 3 or r.run_start is not null);
    get diagnostics v_rows = row_count;

  elsif v_from_phase = 3 then
    v_new_phase := 4;

    update public.homework_group_runtime r
       set phase = 4,
           run_start = null,
           updated_at = v_now,
           version = coalesce(r.version, 1) + 1
     where r.academy_id = p_academy_id
       and r.group_id = p_group_id
       and r.phase <> 4;
    get diagnostics v_rows = row_count;

  elsif v_from_phase = 4 then
    v_new_phase := 1;
    v_elapsed_ms := case
      when v_runtime.run_start is not null
        then greatest(0, floor(extract(epoch from (v_now - v_runtime.run_start)) * 1000)::bigint)
      else 0
    end;

    update public.homework_group_runtime r
       set phase = 1,
           accumulated_ms = coalesce(r.accumulated_ms, 0) + v_elapsed_ms,
           run_start = null,
           updated_at = v_now,
           version = coalesce(r.version, 1) + 1
     where r.academy_id = p_academy_id
       and r.group_id = p_group_id
       and (r.phase <> 1 or r.run_start is not null);
    get diagnostics v_rows = row_count;
  end if;

  -- Sync children's phase to match group state (triggers Realtime for app)
  if v_rows > 0 and v_new_phase is not null then
    update public.homework_items hi
       set phase = v_new_phase,
           run_start = case when v_new_phase = 2 then v_now else null end,
           updated_at = v_now
     where hi.id in (
       select gi.homework_item_id
         from public.homework_group_items gi
        where gi.group_id = p_group_id
          and gi.academy_id = p_academy_id
     )
     and hi.completed_at is null
     and coalesce(hi.status, 0) <> 1;

    update public.homework_groups g
       set updated_at = v_now,
           version = coalesce(g.version, 1) + 1
     where g.id = p_group_id
       and g.academy_id = p_academy_id
       and g.status = 'active';
  end if;

  return v_rows;
end;
$$;
