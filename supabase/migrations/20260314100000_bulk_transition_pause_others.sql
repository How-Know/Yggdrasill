-- Pause other running items before starting a new group (phase 1->2)

drop function if exists public.homework_group_bulk_transition(uuid, uuid, smallint);

create or replace function public.homework_group_bulk_transition(
  p_group_id uuid,
  p_academy_id uuid,
  p_from_phase smallint default null
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_student_id uuid;
  v_total integer := 0;
  v_rows integer := 0;
  v_just_started uuid[] := array[]::uuid[];
begin
  select g.student_id
    into v_student_id
    from public.homework_groups g
   where g.id = p_group_id
     and g.academy_id = p_academy_id
     and g.status = 'active';

  if v_student_id is null then
    return 0;
  end if;

  -- p_from_phase = 99: submit all (phase 1+2 -> 3)
  if p_from_phase = 99 then
    with updated as (
      update public.homework_items h
         set accumulated_ms = coalesce(h.accumulated_ms, 0)
                              + case
                                  when h.run_start is not null
                                    then greatest(0, floor(extract(epoch from (now() - h.run_start)) * 1000)::bigint)
                                  else 0
                                end,
             run_start = null,
             phase = 3,
             submitted_at = now(),
             updated_at = now(),
             version = coalesce(h.version, 1) + 1
       where h.academy_id = p_academy_id
         and h.student_id = v_student_id
         and h.completed_at is null
         and coalesce(h.status, 0) <> 1
         and h.phase in (1, 2)
         and exists (
           select 1
             from public.homework_group_items gi
            where gi.academy_id = p_academy_id
              and gi.group_id = p_group_id
              and gi.homework_item_id = h.id
         )
      returning h.id
    )
    insert into public.homework_item_phase_events(academy_id, item_id, phase, actor_user_id, note)
    select p_academy_id, u.id, 3::smallint, auth.uid(), 'group_bulk_submit'
      from updated u;
    get diagnostics v_rows = row_count;
    return v_rows;
  end if;

  -- phase 1 -> 2: first pause all other running items for this student
  if p_from_phase is null or p_from_phase = 1 then
    update public.homework_items h
       set accumulated_ms = coalesce(h.accumulated_ms, 0)
                            + greatest(0, floor(extract(epoch from (now() - h.run_start)) * 1000)::bigint),
           run_start = null,
           phase = 1,
           waiting_at = now(),
           updated_at = now(),
           version = coalesce(h.version, 1) + 1
     where h.academy_id = p_academy_id
       and h.student_id = v_student_id
       and h.run_start is not null
       and h.completed_at is null
       and not exists (
         select 1
           from public.homework_group_items gi
          where gi.academy_id = p_academy_id
            and gi.group_id = p_group_id
            and gi.homework_item_id = h.id
       );

    with updated as (
      update public.homework_items h
         set phase = 2,
             run_start = coalesce(h.run_start, now()),
             first_started_at = coalesce(h.first_started_at, now()),
             updated_at = now(),
             version = coalesce(h.version, 1) + 1
       where h.academy_id = p_academy_id
         and h.student_id = v_student_id
         and h.completed_at is null
         and coalesce(h.status, 0) <> 1
         and h.phase = 1
         and exists (
           select 1
             from public.homework_group_items gi
            where gi.academy_id = p_academy_id
              and gi.group_id = p_group_id
              and gi.homework_item_id = h.id
         )
      returning h.id
    )
    select array_agg(u.id) into v_just_started from updated u;
    if v_just_started is null then v_just_started := array[]::uuid[]; end if;

    insert into public.homework_item_phase_events(academy_id, item_id, phase, actor_user_id, note)
    select p_academy_id, uid, 2::smallint, auth.uid(), 'group_bulk_transition'
      from unnest(v_just_started) as uid;
    v_total := v_total + coalesce(array_length(v_just_started, 1), 0);
  end if;

  -- phase 2 -> 3 (exclude items just started from phase 1)
  if p_from_phase is null or p_from_phase = 2 then
    with updated as (
      update public.homework_items h
         set accumulated_ms = coalesce(h.accumulated_ms, 0)
                              + case
                                  when h.run_start is not null
                                    then greatest(0, floor(extract(epoch from (now() - h.run_start)) * 1000)::bigint)
                                  else 0
                                end,
             run_start = null,
             phase = 3,
             submitted_at = now(),
             updated_at = now(),
             version = coalesce(h.version, 1) + 1
       where h.academy_id = p_academy_id
         and h.student_id = v_student_id
         and h.completed_at is null
         and coalesce(h.status, 0) <> 1
         and h.phase = 2
         and h.id <> all(v_just_started)
         and exists (
           select 1
             from public.homework_group_items gi
            where gi.academy_id = p_academy_id
              and gi.group_id = p_group_id
              and gi.homework_item_id = h.id
         )
      returning h.id
    )
    insert into public.homework_item_phase_events(academy_id, item_id, phase, actor_user_id, note)
    select p_academy_id, u.id, 3::smallint, auth.uid(), 'group_bulk_transition'
      from updated u;
    get diagnostics v_rows = row_count;
    v_total := v_total + v_rows;
  end if;

  -- phase 4 -> 1
  if p_from_phase is null or p_from_phase = 4 then
    with updated as (
      update public.homework_items h
         set accumulated_ms = coalesce(h.accumulated_ms, 0)
                              + case
                                  when h.run_start is not null
                                    then greatest(0, floor(extract(epoch from (now() - h.run_start)) * 1000)::bigint)
                                  else 0
                                end,
             run_start = null,
             phase = 1,
             waiting_at = now(),
             updated_at = now(),
             version = coalesce(h.version, 1) + 1
       where h.academy_id = p_academy_id
         and h.student_id = v_student_id
         and h.completed_at is null
         and coalesce(h.status, 0) <> 1
         and h.phase = 4
         and exists (
           select 1
             from public.homework_group_items gi
            where gi.academy_id = p_academy_id
              and gi.group_id = p_group_id
              and gi.homework_item_id = h.id
         )
      returning h.id
    )
    insert into public.homework_item_phase_events(academy_id, item_id, phase, actor_user_id, note)
    select p_academy_id, u.id, 1::smallint, auth.uid(), 'group_bulk_transition'
      from updated u;
    get diagnostics v_rows = row_count;
    v_total := v_total + v_rows;
  end if;

  return v_total;
end;
$$;
