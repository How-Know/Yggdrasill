-- Merge active homework items that share one assignment_code but were split
-- across multiple groups (or lost their group link during partial writes).

create or replace function public.homework_reconcile_assignment_code_groups(
  p_academy_id uuid,
  p_student_id uuid default null
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row record;
  v_canonical_group_id uuid;
  v_duplicate_group_ids uuid[];
  v_moved integer := 0;
  v_changed integer := 0;
begin
  if auth.uid() is not null and not exists (
    select 1
    from public.memberships m
    where m.academy_id = p_academy_id
      and m.user_id = auth.uid()
  ) then
    raise exception 'not a staff member';
  end if;

  for v_row in
    select
      h.student_id,
      h.assignment_code
    from public.homework_items h
    left join public.homework_group_items gi
      on gi.academy_id = h.academy_id
     and gi.homework_item_id = h.id
    where h.academy_id = p_academy_id
      and (p_student_id is null or h.student_id = p_student_id)
      and h.student_id is not null
      and h.assignment_code is not null
      and btrim(h.assignment_code) <> ''
      and h.completed_at is null
      and coalesce(h.status, 0) <> 1
    group by h.student_id, h.assignment_code
    having count(*) filter (where gi.group_id is null) > 0
        or count(distinct gi.group_id) > 1
  loop
    select array_agg(distinct gi.group_id)
      into v_duplicate_group_ids
    from public.homework_items h
    join public.homework_group_items gi
      on gi.academy_id = h.academy_id
     and gi.homework_item_id = h.id
    where h.academy_id = p_academy_id
      and h.student_id = v_row.student_id
      and h.assignment_code = v_row.assignment_code
      and h.completed_at is null
      and coalesce(h.status, 0) <> 1;

    select ranked.group_id
      into v_canonical_group_id
    from (
      select
        gi.group_id,
        bool_or(g.source_homework_item_id is null) as is_native_group,
        count(*) as child_count,
        min(g.created_at) as created_at
      from public.homework_items h
      join public.homework_group_items gi
        on gi.academy_id = h.academy_id
       and gi.homework_item_id = h.id
      join public.homework_groups g
        on g.id = gi.group_id
       and g.academy_id = gi.academy_id
      where h.academy_id = p_academy_id
        and h.student_id = v_row.student_id
        and h.assignment_code = v_row.assignment_code
        and h.completed_at is null
        and coalesce(h.status, 0) <> 1
      group by gi.group_id
      order by
        bool_or(g.source_homework_item_id is null) desc,
        count(*) desc,
        min(g.created_at) asc,
        gi.group_id
      limit 1
    ) ranked;

    if v_canonical_group_id is null then
      continue;
    end if;

    update public.homework_group_items gi
    set group_id = v_canonical_group_id,
        updated_at = now(),
        version = gi.version + 1
    from public.homework_items h
    where h.id = gi.homework_item_id
      and h.academy_id = p_academy_id
      and h.student_id = v_row.student_id
      and h.assignment_code = v_row.assignment_code
      and h.completed_at is null
      and coalesce(h.status, 0) <> 1
      and gi.academy_id = h.academy_id
      and gi.group_id <> v_canonical_group_id;
    get diagnostics v_changed = row_count;
    v_moved := v_moved + v_changed;

    insert into public.homework_group_items (
      academy_id,
      group_id,
      homework_item_id,
      student_id,
      item_order_index
    )
    select
      h.academy_id,
      v_canonical_group_id,
      h.id,
      h.student_id,
      (
        coalesce((
        select max(existing.item_order_index) + 1
        from public.homework_group_items existing
        where existing.academy_id = p_academy_id
          and existing.group_id = v_canonical_group_id
        ), 0)
        + row_number() over (order by h.order_index, h.created_at, h.id)
        - 1
      )::integer
    from public.homework_items h
    where h.academy_id = p_academy_id
      and h.student_id = v_row.student_id
      and h.assignment_code = v_row.assignment_code
      and h.completed_at is null
      and coalesce(h.status, 0) <> 1
      and not exists (
        select 1
        from public.homework_group_items existing
        where existing.academy_id = h.academy_id
          and existing.homework_item_id = h.id
      )
    on conflict (academy_id, homework_item_id) do update
      set group_id = excluded.group_id,
          updated_at = now(),
          version = public.homework_group_items.version + 1;
    get diagnostics v_changed = row_count;
    v_moved := v_moved + v_changed;

    with ordered as (
      select
        gi.id,
        (row_number() over (
          order by h.order_index, h.created_at, h.id
        ) - 1)::integer as next_order
      from public.homework_group_items gi
      join public.homework_items h on h.id = gi.homework_item_id
      where gi.academy_id = p_academy_id
        and gi.group_id = v_canonical_group_id
    )
    update public.homework_group_items gi
    set item_order_index = ordered.next_order,
        updated_at = now()
    from ordered
    where ordered.id = gi.id
      and gi.item_order_index <> ordered.next_order;

    delete from public.homework_groups g
    where g.academy_id = p_academy_id
      and g.student_id = v_row.student_id
      and g.id <> v_canonical_group_id
      and g.id = any(coalesce(v_duplicate_group_ids, '{}'::uuid[]))
      and not exists (
        select 1
        from public.homework_group_items gi
        where gi.academy_id = g.academy_id
          and gi.group_id = g.id
      );
  end loop;

  return v_moved;
end;
$$;

revoke all on function public.homework_reconcile_assignment_code_groups(
  uuid, uuid
) from public;
grant execute on function public.homework_reconcile_assignment_code_groups(
  uuid, uuid
) to authenticated;

-- Repair existing active split groups once when this migration is applied.
do $$
declare
  v_academy_id uuid;
begin
  for v_academy_id in
    select distinct h.academy_id
    from public.homework_items h
    where h.assignment_code is not null
      and btrim(h.assignment_code) <> ''
      and h.completed_at is null
      and coalesce(h.status, 0) <> 1
  loop
    perform public.homework_reconcile_assignment_code_groups(
      v_academy_id,
      null
    );
  end loop;
end;
$$;
