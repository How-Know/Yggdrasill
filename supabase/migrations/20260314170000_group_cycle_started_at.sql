-- Group-only cycle start timestamp support.
-- Records first 1->2 timestamp per cycle on homework_groups.cycle_started_at.

alter table if exists public.homework_groups
  add column if not exists cycle_started_at timestamptz;

-- Best-effort backfill for currently running groups.
with running_groups as (
  select
    gi.group_id,
    min(h.run_start) as cycle_started_at
  from public.homework_group_items gi
  join public.homework_items h
    on h.id = gi.homework_item_id
   and h.academy_id = gi.academy_id
  where h.run_start is not null
    and h.phase = 2
    and h.completed_at is null
    and coalesce(h.status, 0) <> 1
  group by gi.group_id
)
update public.homework_groups g
   set cycle_started_at = rg.cycle_started_at
  from running_groups rg
 where g.id = rg.group_id
   and g.cycle_started_at is null;

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
  v_group_cycle_delta bigint := 0;
  v_group_weight_sum bigint := 0;
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
    if v_just_started is null then
      v_just_started := array[]::uuid[];
    end if;

    insert into public.homework_item_phase_events(academy_id, item_id, phase, actor_user_id, note)
    select p_academy_id, uid, 2::smallint, auth.uid(), 'group_bulk_transition'
      from unnest(v_just_started) as uid;
    v_total := v_total + coalesce(array_length(v_just_started, 1), 0);

    if coalesce(array_length(v_just_started, 1), 0) > 0 then
      update public.homework_groups g
         set cycle_started_at = coalesce(g.cycle_started_at, now()),
             updated_at = now(),
             version = coalesce(g.version, 1) + 1
       where g.id = p_group_id
         and g.academy_id = p_academy_id
         and g.status = 'active';
    end if;
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
  -- group cycle delta는 1회만 계산하고, 4->1 시점에 문항수 비례로 하위 과제에 분배한다.
  if p_from_phase is null or p_from_phase = 4 then
    with targets as (
      select h.id,
             greatest(coalesce(h.count, 0), 1)::bigint as weight,
             coalesce(h.cycle_base_accumulated_ms, 0)::bigint as base_ms,
             (
               coalesce(h.accumulated_ms, 0)
               + case
                   when h.run_start is not null
                     then greatest(0, floor(extract(epoch from (now() - h.run_start)) * 1000)::bigint)
                   else 0
                 end
             )::bigint as current_ms
        from public.homework_items h
        join public.homework_group_items gi
          on gi.homework_item_id = h.id
         and gi.group_id = p_group_id
         and gi.academy_id = p_academy_id
       where h.academy_id = p_academy_id
         and h.student_id = v_student_id
         and h.completed_at is null
         and coalesce(h.status, 0) <> 1
         and h.phase = 4
    )
    select
      coalesce(max(greatest(0, current_ms - base_ms)), 0),
      coalesce(sum(weight), 0)
      into v_group_cycle_delta, v_group_weight_sum
      from targets;

    with targets as (
      select h.id,
             greatest(coalesce(h.count, 0), 1)::bigint as weight,
             coalesce(h.cycle_base_accumulated_ms, 0)::bigint as base_ms
        from public.homework_items h
        join public.homework_group_items gi
          on gi.homework_item_id = h.id
         and gi.group_id = p_group_id
         and gi.academy_id = p_academy_id
       where h.academy_id = p_academy_id
         and h.student_id = v_student_id
         and h.completed_at is null
         and coalesce(h.status, 0) <> 1
         and h.phase = 4
    ),
    shares as (
      select
        t.id,
        t.base_ms,
        t.weight,
        case
          when v_group_weight_sum > 0
            then (v_group_cycle_delta * t.weight) / v_group_weight_sum
          else 0
        end::bigint as floor_share,
        row_number() over (order by t.weight desc, t.id) as rn
      from targets t
    ),
    totals as (
      select coalesce(sum(s.floor_share), 0)::bigint as floor_sum
      from shares s
    ),
    distributed as (
      select
        s.id,
        (
          s.base_ms
          + s.floor_share
          + case
              when (v_group_cycle_delta - (select floor_sum from totals)) > 0
                   and s.rn <= (v_group_cycle_delta - (select floor_sum from totals))
                then 1
              else 0
            end
        )::bigint as target_ms
      from shares s
    ),
    updated as (
      update public.homework_items h
         set accumulated_ms = d.target_ms,
             run_start = null,
             phase = 1,
             waiting_at = now(),
             updated_at = now(),
             version = coalesce(h.version, 1) + 1
        from distributed d
       where h.id = d.id
         and h.academy_id = p_academy_id
         and h.student_id = v_student_id
         and h.completed_at is null
         and coalesce(h.status, 0) <> 1
         and h.phase = 4
      returning h.id
    )
    insert into public.homework_item_phase_events(academy_id, item_id, phase, actor_user_id, note)
    select p_academy_id, u.id, 1::smallint, auth.uid(), 'group_bulk_transition'
      from updated u;
    get diagnostics v_rows = row_count;
    v_total := v_total + v_rows;

    if v_rows > 0 then
      update public.homework_groups g
         set cycle_started_at = null,
             updated_at = now(),
             version = coalesce(g.version, 1) + 1
       where g.id = p_group_id
         and g.academy_id = p_academy_id
         and g.status = 'active';
    end if;
  end if;

  return v_total;
end;
$$;
