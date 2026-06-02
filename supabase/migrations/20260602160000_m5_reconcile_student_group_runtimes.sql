-- Method A (stop-gap): enforce the single-running invariant on
-- homework_group_runtime after group transitions.
--
-- Root cause (to be fixed properly later): running state lives in two places
-- (homework_items.phase = app's truth, homework_group_runtime.phase = M5's
-- truth) and the sync paths differ per route. The v2 device transition path
-- (m5_group_transition_command → homework_group_bulk_transition) pauses the
-- *items* of other groups but only re-syncs the TARGET group's runtime, leaving
-- the previously-running group's runtime stuck at phase=2. M5 reads
-- coalesce(gr.phase, gs.phase) so it keeps showing that group as 수행중 (green),
-- while the app (items-based) is correct.
--
-- Calling m5_group_transition_state_v3 from the gateway cannot fix this because
-- its phase guard (added for concurrency) rejects the call once the target
-- runtime already advanced. Instead we reconcile EVERY active group's runtime
-- from its children, which the gateway invokes after each transition. Since the
-- item level already honors single-running, this makes the runtime level match.

create or replace function public.m5_reconcile_student_group_runtimes(
  p_academy_id uuid,
  p_student_id uuid,
  p_now timestamptz default now()
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group_id uuid;
  v_now timestamptz := coalesce(p_now, now());
  v_total integer := 0;
begin
  if p_academy_id is null or p_student_id is null then
    return 0;
  end if;

  for v_group_id in
    select g.id
      from public.homework_groups g
     where g.academy_id = p_academy_id
       and g.student_id = p_student_id
       and g.status = 'active'
  loop
    v_total := v_total
      + coalesce(public.m5_group_runtime_sync_from_children(p_academy_id, v_group_id, v_now), 0);
  end loop;

  return v_total;
end;
$$;

revoke all on function public.m5_reconcile_student_group_runtimes(uuid, uuid, timestamptz) from public;
grant execute on function public.m5_reconcile_student_group_runtimes(uuid, uuid, timestamptz) to service_role;

-- One-off cleanup of existing stale runtimes: re-sync every group runtime that
-- is currently in a non-waiting phase from its children. This fixes the
-- already-diverged students (groups showing 수행중 on M5 while their items are
-- back to 대기) immediately on deploy.
do $$
declare
  r record;
begin
  for r in
    select distinct gr.academy_id, gr.group_id
      from public.homework_group_runtime gr
     where coalesce(gr.phase, 1) <> 1
  loop
    perform public.m5_group_runtime_sync_from_children(r.academy_id, r.group_id, now());
  end loop;
end $$;
