-- Reconcile M5 group runtime after app-side batch confirmations.
-- Batch confirm calls homework_confirm in parallel, so each call can miss
-- sibling item commits that finish slightly later. This RPC is called after
-- the batch settles and recomputes affected active groups from child items.

create or replace function public.homework_reconcile_group_runtime_for_items(
  p_academy_id uuid,
  p_item_ids uuid[]
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamptz := now();
  v_group_id uuid;
  v_changed integer := 0;
  v_total integer := 0;
begin
  if p_academy_id is null or p_item_ids is null or cardinality(p_item_ids) = 0 then
    return 0;
  end if;

  for v_group_id in
    select distinct gi.group_id
      from public.homework_group_items gi
      join public.homework_groups g
        on g.id = gi.group_id
       and g.academy_id = gi.academy_id
       and g.status = 'active'
     where gi.academy_id = p_academy_id
       and gi.homework_item_id = any(p_item_ids)
  loop
    v_changed := public.m5_group_runtime_sync_from_children(
      p_academy_id,
      v_group_id,
      v_now
    );
    v_total := v_total + coalesce(v_changed, 0);
  end loop;

  return v_total;
end;
$$;

revoke all on function public.homework_reconcile_group_runtime_for_items(uuid, uuid[]) from public;
grant execute on function public.homework_reconcile_group_runtime_for_items(uuid, uuid[]) to anon, authenticated;
