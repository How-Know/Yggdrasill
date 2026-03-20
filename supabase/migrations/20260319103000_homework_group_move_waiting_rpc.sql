-- 20260319103000: move waiting child homework within/across groups

create or replace function public.homework_group_move_waiting(
  p_item_id uuid,
  p_target_group_id uuid,
  p_target_before_item_id uuid default null,
  p_academy_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy_id uuid;
  v_item public.homework_items%rowtype;
  v_source_link public.homework_group_items%rowtype;
  v_target_group public.homework_groups%rowtype;
  v_source_group_id uuid;
  v_source_index integer := 0;
  v_target_index integer := 0;
  v_before_index integer := 0;
  v_moved boolean := true;
begin
  v_academy_id := coalesce(p_academy_id, (
    select m.academy_id
      from public.memberships m
     where m.user_id = auth.uid()
     order by m.created_at asc
     limit 1
  ));
  if v_academy_id is null then
    raise exception 'MOVE_ACADEMY_NOT_FOUND';
  end if;

  select h.*
    into v_item
    from public.homework_items h
   where h.id = p_item_id
     and h.academy_id = v_academy_id
   for update;
  if v_item.id is null then
    raise exception 'MOVE_ITEM_NOT_FOUND';
  end if;
  if coalesce(v_item.phase, 0) <> 1 then
    raise exception 'MOVE_ONLY_WAITING_PHASE';
  end if;
  if v_item.completed_at is not null or coalesce(v_item.status, 0) = 1 then
    raise exception 'MOVE_ONLY_ACTIVE_ITEM';
  end if;

  if exists (
    select 1
      from public.homework_assignments a
     where a.academy_id = v_academy_id
       and a.homework_item_id = p_item_id
       and a.status = 'assigned'
  ) then
    raise exception 'MOVE_BLOCKED_BY_ASSIGNMENT';
  end if;

  select gi.*
    into v_source_link
    from public.homework_group_items gi
   where gi.academy_id = v_academy_id
     and gi.homework_item_id = p_item_id
   for update;
  if v_source_link.id is null then
    raise exception 'MOVE_SOURCE_LINK_NOT_FOUND';
  end if;
  v_source_group_id := v_source_link.group_id;
  v_source_index := coalesce(v_source_link.item_order_index, 0);

  select g.*
    into v_target_group
    from public.homework_groups g
   where g.id = p_target_group_id
     and g.academy_id = v_academy_id
     and g.status = 'active';
  if v_target_group.id is null then
    raise exception 'MOVE_TARGET_GROUP_NOT_FOUND';
  end if;
  if v_target_group.student_id <> v_item.student_id then
    raise exception 'MOVE_TARGET_STUDENT_MISMATCH';
  end if;

  if p_target_before_item_id is not null and
      p_target_before_item_id = p_item_id and
      v_source_group_id = p_target_group_id then
    v_moved := false;
  else
    if p_target_before_item_id is null then
      select coalesce(max(gi.item_order_index), -1) + 1
        into v_target_index
        from public.homework_group_items gi
       where gi.academy_id = v_academy_id
         and gi.group_id = p_target_group_id;
    else
      select coalesce(gi.item_order_index, 0)
        into v_before_index
        from public.homework_group_items gi
       where gi.academy_id = v_academy_id
         and gi.group_id = p_target_group_id
         and gi.homework_item_id = p_target_before_item_id
       limit 1;
      if not found then
        raise exception 'MOVE_TARGET_BEFORE_NOT_FOUND';
      end if;
      v_target_index := v_before_index;
    end if;

    if v_source_group_id = p_target_group_id then
      if v_target_index > v_source_index then
        v_target_index := v_target_index - 1;
      end if;
      if v_target_index = v_source_index then
        v_moved := false;
      else
        update public.homework_group_items gi
           set item_order_index = v_target_index,
               updated_at = now(),
               version = coalesce(gi.version, 1) + 1
         where gi.id = v_source_link.id;
      end if;
    else
      update public.homework_group_items gi
         set item_order_index = coalesce(gi.item_order_index, 0) + 1,
             updated_at = now(),
             version = coalesce(gi.version, 1) + 1
       where gi.academy_id = v_academy_id
         and gi.group_id = p_target_group_id
         and coalesce(gi.item_order_index, 0) >= v_target_index;

      update public.homework_group_items gi
         set group_id = p_target_group_id,
             student_id = v_target_group.student_id,
             item_order_index = v_target_index,
             updated_at = now(),
             version = coalesce(gi.version, 1) + 1
       where gi.id = v_source_link.id;
    end if;
  end if;

  with ranked as (
    select gi.id,
           row_number() over (
             order by coalesce(gi.item_order_index, 0), gi.created_at, gi.id
           ) - 1 as normalized_idx
      from public.homework_group_items gi
     where gi.academy_id = v_academy_id
       and gi.group_id = v_source_group_id
  )
  update public.homework_group_items gi
     set item_order_index = ranked.normalized_idx,
         updated_at = now(),
         version = coalesce(gi.version, 1) + 1
    from ranked
   where gi.id = ranked.id
     and coalesce(gi.item_order_index, 0) <> ranked.normalized_idx;

  if v_source_group_id <> p_target_group_id then
    with ranked as (
      select gi.id,
             row_number() over (
               order by coalesce(gi.item_order_index, 0), gi.created_at, gi.id
             ) - 1 as normalized_idx
        from public.homework_group_items gi
       where gi.academy_id = v_academy_id
         and gi.group_id = p_target_group_id
    )
    update public.homework_group_items gi
       set item_order_index = ranked.normalized_idx,
           updated_at = now(),
           version = coalesce(gi.version, 1) + 1
      from ranked
     where gi.id = ranked.id
       and coalesce(gi.item_order_index, 0) <> ranked.normalized_idx;
  end if;

  return jsonb_build_object(
    'item_id', p_item_id,
    'source_group_id', v_source_group_id,
    'target_group_id', p_target_group_id,
    'target_before_item_id', p_target_before_item_id,
    'moved', v_moved
  );
end;
$$;
