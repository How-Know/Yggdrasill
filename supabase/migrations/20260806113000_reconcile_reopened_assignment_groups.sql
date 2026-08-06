-- Active cards are determined by status, not completed_at alone. Reopened
-- homework can retain completed_at, so reconcile those split groups as well.

create or replace function public.homework_reconcile_assignment_code_groups(
  p_academy_id uuid,
  p_student_id uuid default null
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_moved integer := 0;
begin
  if auth.uid() is not null and not exists (
    select 1
    from public.memberships m
    where m.academy_id = p_academy_id
      and m.user_id = auth.uid()
  ) then
    raise exception 'not a staff member';
  end if;

  drop table if exists pg_temp.hw_group_repair_targets;
  create temporary table hw_group_repair_targets
  on commit drop
  as
  with active_items as (
    select
      h.academy_id,
      h.student_id,
      h.assignment_code,
      h.id as item_id,
      h.order_index,
      h.created_at,
      gi.group_id as old_group_id
    from public.homework_items h
    left join public.homework_group_items gi
      on gi.academy_id = h.academy_id
     and gi.homework_item_id = h.id
    where h.academy_id = p_academy_id
      and (p_student_id is null or h.student_id = p_student_id)
      and h.student_id is not null
      and h.assignment_code is not null
      and btrim(h.assignment_code) <> ''
      and coalesce(h.status, 0) <> 1
  ),
  group_candidates as (
    select
      a.academy_id,
      a.student_id,
      a.assignment_code,
      a.old_group_id as group_id,
      bool_or(g.source_homework_item_id is null) as is_native_group,
      count(*) as child_count,
      min(g.created_at) as group_created_at
    from active_items a
    join public.homework_groups g
      on g.academy_id = a.academy_id
     and g.id = a.old_group_id
    where a.old_group_id is not null
    group by
      a.academy_id,
      a.student_id,
      a.assignment_code,
      a.old_group_id
  ),
  canonical_groups as (
    select distinct on (academy_id, student_id, assignment_code)
      academy_id,
      student_id,
      assignment_code,
      group_id as canonical_group_id
    from group_candidates
    order by
      academy_id,
      student_id,
      assignment_code,
      is_native_group desc,
      child_count desc,
      group_created_at asc,
      group_id
  ),
  duplicate_codes as (
    select
      a.academy_id,
      a.student_id,
      a.assignment_code
    from active_items a
    group by a.academy_id, a.student_id, a.assignment_code
    having count(*) filter (where a.old_group_id is null) > 0
        or count(distinct a.old_group_id) > 1
  )
  select
    a.academy_id,
    a.student_id,
    a.assignment_code,
    a.item_id,
    a.old_group_id,
    c.canonical_group_id,
    a.order_index,
    a.created_at
  from active_items a
  join duplicate_codes d
    on d.academy_id = a.academy_id
   and d.student_id = a.student_id
   and d.assignment_code = a.assignment_code
  join canonical_groups c
    on c.academy_id = a.academy_id
   and c.student_id = a.student_id
   and c.assignment_code = a.assignment_code
  where a.old_group_id is distinct from c.canonical_group_id;

  select count(*)::integer into v_moved
  from pg_temp.hw_group_repair_targets;

  update public.homework_group_items gi
  set group_id = t.canonical_group_id,
      updated_at = now(),
      version = gi.version + 1
  from pg_temp.hw_group_repair_targets t
  where t.old_group_id is not null
    and gi.academy_id = t.academy_id
    and gi.homework_item_id = t.item_id;

  insert into public.homework_group_items (
    academy_id,
    group_id,
    homework_item_id,
    student_id,
    item_order_index
  )
  select
    t.academy_id,
    t.canonical_group_id,
    t.item_id,
    t.student_id,
    0
  from pg_temp.hw_group_repair_targets t
  where t.old_group_id is null
  on conflict (academy_id, homework_item_id) do update
    set group_id = excluded.group_id,
        updated_at = now(),
        version = homework_group_items.version + 1;

  with affected_groups as (
    select distinct academy_id, canonical_group_id
    from pg_temp.hw_group_repair_targets
  ),
  ordered as (
    select
      gi.id,
      (row_number() over (
        partition by gi.academy_id, gi.group_id
        order by h.order_index, h.created_at, h.id
      ) - 1)::integer as next_order
    from public.homework_group_items gi
    join affected_groups a
      on a.academy_id = gi.academy_id
     and a.canonical_group_id = gi.group_id
    join public.homework_items h on h.id = gi.homework_item_id
  )
  update public.homework_group_items gi
  set item_order_index = ordered.next_order,
      updated_at = now()
  from ordered
  where ordered.id = gi.id
    and gi.item_order_index <> ordered.next_order;

  delete from public.homework_groups g
  using (
    select distinct academy_id, old_group_id
    from pg_temp.hw_group_repair_targets
    where old_group_id is not null
  ) old_groups
  where g.academy_id = old_groups.academy_id
    and g.id = old_groups.old_group_id
    and not exists (
      select 1
      from public.homework_group_items gi
      where gi.academy_id = g.academy_id
        and gi.group_id = g.id
    );

  return v_moved;
end;
$$;

do $$
declare
  v_academy_id uuid;
begin
  for v_academy_id in
    select distinct h.academy_id
    from public.homework_items h
    where h.assignment_code is not null
      and btrim(h.assignment_code) <> ''
      and coalesce(h.status, 0) <> 1
  loop
    perform public.homework_reconcile_assignment_code_groups(
      v_academy_id,
      null
    );
  end loop;
end;
$$;
