-- Keep homework_confirm check_count behavior and
-- sync group runtime to phase 4 when a group has no submitted children.

create or replace function public.homework_confirm(
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
  v_active_count integer := 0;
  v_submitted_count integer := 0;
  v_confirmed_count integer := 0;
begin
  update public.homework_items
     set accumulated_ms = coalesce(accumulated_ms, 0)
                          + case
                              when run_start is not null
                                then extract(epoch from (v_now - run_start))::bigint * 1000
                              else 0
                            end,
         run_start = null,
         phase = 4,
         confirmed_at = v_now,
         updated_at = v_now,
         updated_by = case
                        when p_updated_by is not null then p_updated_by::uuid
                        else updated_by
                      end,
         version = coalesce(version, 1) + 1,
         check_count = coalesce(check_count, 0) + 1
   where id = p_item_id
     and academy_id = p_academy_id
     and completed_at is null;

  if not found then
    return;
  end if;

  perform public._append_homework_phase_event(
    p_academy_id,
    p_item_id,
    4::smallint,
    null::text
  );

  select gi.group_id
    into v_group_id
    from public.homework_group_items gi
   where gi.academy_id = p_academy_id
     and gi.homework_item_id = p_item_id
   limit 1;

  if v_group_id is null then
    return;
  end if;

  select
    count(*)::integer,
    count(*) filter (where hi.phase = 3)::integer,
    count(*) filter (where hi.phase = 4)::integer
    into v_active_count, v_submitted_count, v_confirmed_count
    from public.homework_group_items gi
    join public.homework_items hi
      on hi.id = gi.homework_item_id
     and hi.academy_id = gi.academy_id
   where gi.academy_id = p_academy_id
     and gi.group_id = v_group_id
     and hi.completed_at is null
     and coalesce(hi.status, 0) <> 1;

  if v_active_count <= 0 then
    return;
  end if;

  -- Only move runtime to confirmed when all active children are phase 4.
  if v_submitted_count > 0 or v_confirmed_count <> v_active_count then
    return;
  end if;

  perform public.m5_group_runtime_seed(p_academy_id, v_group_id);

  update public.homework_group_runtime r
     set phase = 4,
         run_start = null,
         updated_at = v_now,
         version = coalesce(r.version, 1) + 1
   where r.academy_id = p_academy_id
     and r.group_id = v_group_id
     and r.phase <> 4;

  if found then
    update public.homework_groups g
       set updated_at = v_now,
           version = coalesce(g.version, 1) + 1
     where g.id = v_group_id
       and g.academy_id = p_academy_id
       and g.status = 'active';
  end if;
end;
$$;

revoke all on function public.homework_confirm(uuid, uuid, text) from public;
grant execute on function public.homework_confirm(uuid, uuid, text) to anon, authenticated;
