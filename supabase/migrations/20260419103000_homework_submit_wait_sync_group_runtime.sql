-- Keep homework_group_runtime in sync when a single child item changes phase
-- via homework_submit / homework_wait RPC.

create or replace function public.m5_group_runtime_sync_from_children(
  p_academy_id uuid,
  p_group_id uuid,
  p_now timestamptz default now()
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamptz := coalesce(p_now, now());
  v_rows integer := 0;
begin
  if not exists (
    select 1
      from public.homework_groups g
     where g.id = p_group_id
       and g.academy_id = p_academy_id
       and g.status = 'active'
  ) then
    return 0;
  end if;

  perform public.m5_group_runtime_seed(p_academy_id, p_group_id);

  with runtime_from_items as (
    select
      case
        when bool_or(hi.run_start is not null) then 2::smallint
        when bool_or(coalesce(hi.phase, 1) = 3) then 3::smallint
        when bool_or(coalesce(hi.phase, 1) = 4) then 4::smallint
        else 1::smallint
      end as phase,
      coalesce(max(coalesce(hi.accumulated_ms, 0)), 0)::bigint as accumulated_ms,
      (array_agg(hi.run_start order by gi.item_order_index)
        filter (where hi.run_start is not null))[1] as run_start,
      min(hi.first_started_at) as first_started_at,
      coalesce(max(coalesce(hi.check_count, 0)), 0)::integer as check_count
    from public.homework_group_items gi
    join public.homework_items hi
      on hi.id = gi.homework_item_id
     and hi.academy_id = gi.academy_id
    join public.homework_groups g
      on g.id = gi.group_id
     and g.academy_id = gi.academy_id
     and g.status = 'active'
   where gi.academy_id = p_academy_id
     and gi.group_id = p_group_id
     and hi.completed_at is null
     and coalesce(hi.status, 0) <> 1
  )
  update public.homework_group_runtime r
     set phase = s.phase,
         run_start = case when s.phase = 2 then s.run_start else null end,
         first_started_at = coalesce(r.first_started_at, s.first_started_at),
         check_count = s.check_count,
         accumulated_ms = greatest(
           coalesce(r.accumulated_ms, 0),
           coalesce(s.accumulated_ms, 0)
         ),
         updated_at = v_now,
         version = coalesce(r.version, 1) + 1
    from runtime_from_items s
   where r.academy_id = p_academy_id
     and r.group_id = p_group_id
     and (
       coalesce(r.phase, 0) <> coalesce(s.phase, 0)
       or coalesce(r.run_start, 'epoch'::timestamptz)
            <> coalesce(
                 case when s.phase = 2 then s.run_start else null end,
                 'epoch'::timestamptz
               )
       or coalesce(r.check_count, 0) <> coalesce(s.check_count, 0)
       or coalesce(r.first_started_at, 'epoch'::timestamptz)
            <> coalesce(
                 coalesce(r.first_started_at, s.first_started_at),
                 'epoch'::timestamptz
               )
     );
  get diagnostics v_rows = row_count;

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

revoke all on function public.m5_group_runtime_sync_from_children(uuid, uuid, timestamptz) from public;
grant execute on function public.m5_group_runtime_sync_from_children(uuid, uuid, timestamptz) to service_role;

create or replace function public.homework_submit(
  p_item_id uuid,
  p_academy_id uuid,
  p_updated_by text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamptz := now();
  v_group_id uuid;
begin
  update public.homework_items
     set accumulated_ms = coalesce(accumulated_ms,0)
                          + case when run_start is not null
                                 then extract(epoch from (v_now - run_start))::bigint * 1000
                                 else 0 end,
         run_start    = null,
         phase        = 3,
         submitted_at = v_now,
         updated_at   = v_now,
         updated_by   = case when p_updated_by is not null then p_updated_by::uuid else updated_by end,
         version      = coalesce(version,1) + 1
   where id = p_item_id and academy_id = p_academy_id and completed_at is null;

  perform public._append_homework_phase_event(p_academy_id, p_item_id, 3::smallint, null::text);

  for v_group_id in
    select distinct gi.group_id
      from public.homework_group_items gi
     where gi.academy_id = p_academy_id
       and gi.homework_item_id = p_item_id
  loop
    perform public.m5_group_runtime_sync_from_children(
      p_academy_id,
      v_group_id,
      v_now
    );
  end loop;
end;
$$;

revoke all on function public.homework_submit(uuid,uuid,text) from public;
grant execute on function public.homework_submit(uuid,uuid,text) to anon, authenticated;

create or replace function public.homework_wait(
  p_item_id uuid,
  p_academy_id uuid,
  p_updated_by text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamptz := now();
  v_group_id uuid;
begin
  update public.homework_items
     set accumulated_ms = coalesce(accumulated_ms,0)
                          + case when run_start is not null
                                 then extract(epoch from (v_now - run_start))::bigint * 1000
                                 else 0 end,
         run_start     = null,
         phase         = 1,
         waiting_at    = v_now,
         updated_at    = v_now,
         updated_by    = case when p_updated_by is not null then p_updated_by::uuid else updated_by end,
         version       = coalesce(version,1) + 1
   where id = p_item_id and academy_id = p_academy_id and completed_at is null;

  perform public._append_homework_phase_event(p_academy_id, p_item_id, 1::smallint, null::text);

  for v_group_id in
    select distinct gi.group_id
      from public.homework_group_items gi
     where gi.academy_id = p_academy_id
       and gi.homework_item_id = p_item_id
  loop
    perform public.m5_group_runtime_sync_from_children(
      p_academy_id,
      v_group_id,
      v_now
    );
  end loop;
end;
$$;

revoke all on function public.homework_wait(uuid,uuid,text) from public;
grant execute on function public.homework_wait(uuid,uuid,text) to anon, authenticated;
