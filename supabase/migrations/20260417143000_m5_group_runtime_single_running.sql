-- Ensure only one running group per student in runtime v3.

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

  if v_from_phase is null then
    v_from_phase := coalesce(v_runtime.phase, 1);
  end if;

  if v_from_phase = 1 then
    -- Single-running invariant: starting this group pauses all other running groups.
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
  elsif v_from_phase = 4 then
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

  if v_rows > 0 then
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
