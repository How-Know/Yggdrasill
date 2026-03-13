-- 20260312101000: group bulk transition + split/merge(waiting only)

create or replace function public._touch_homework_group_on_item_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group_id uuid;
begin
  v_group_id := coalesce(new.group_id, old.group_id);
  if v_group_id is not null then
    update public.homework_groups
       set updated_at = now(),
           version = coalesce(version, 1) + 1
     where id = v_group_id;
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_touch_homework_group_on_item_change on public.homework_group_items;
create trigger trg_touch_homework_group_on_item_change
after insert or update or delete on public.homework_group_items
for each row execute function public._touch_homework_group_on_item_change();

create or replace function public.homework_group_bulk_transition(
  p_group_id uuid,
  p_academy_id uuid
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

  -- phase 1 -> 2: collect IDs to exclude from next step
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

  -- phase 2 -> 3: exclude items that were just transitioned from phase 1
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

  return v_total;
end;
$$;

create or replace function public.homework_group_split_waiting(
  p_group_id uuid,
  p_source_item_id uuid,
  p_parts jsonb,
  p_academy_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group public.homework_groups%rowtype;
  v_source public.homework_items%rowtype;
  v_total_parts integer := 0;
  v_source_order integer := 0;
  v_source_group_order integer := 0;
  v_part jsonb;
  v_ord bigint;
  v_part_title text;
  v_part_page text;
  v_part_type text;
  v_part_content text;
  v_part_count integer;
  v_new_id uuid;
  v_created_ids uuid[] := array[]::uuid[];
  v_ms_base bigint := 0;
  v_ms_remainder bigint := 0;
  v_check_base integer := 0;
  v_check_remainder integer := 0;
  v_alloc_ms bigint := 0;
  v_alloc_checks integer := 0;
begin
  if p_parts is null or jsonb_typeof(p_parts) <> 'array' then
    raise exception 'SPLIT_PARTS_INVALID_ARRAY';
  end if;

  v_total_parts := jsonb_array_length(p_parts);
  if v_total_parts <= 0 then
    raise exception 'SPLIT_PARTS_EMPTY';
  end if;

  select g.*
    into v_group
    from public.homework_groups g
   where g.id = p_group_id
     and g.academy_id = p_academy_id
     and g.status = 'active';

  if v_group.id is null then
    raise exception 'SPLIT_GROUP_NOT_FOUND';
  end if;

  select h.*
    into v_source
    from public.homework_items h
    join public.homework_group_items gi
      on gi.homework_item_id = h.id
     and gi.group_id = p_group_id
     and gi.academy_id = p_academy_id
   where h.id = p_source_item_id
     and h.academy_id = p_academy_id
     and h.student_id = v_group.student_id
   for update;

  if v_source.id is null then
    raise exception 'SPLIT_SOURCE_NOT_FOUND';
  end if;
  if coalesce(v_source.phase, 0) <> 1 then
    raise exception 'SPLIT_ONLY_WAITING_PHASE';
  end if;
  if v_source.completed_at is not null or coalesce(v_source.status, 0) = 1 then
    raise exception 'SPLIT_SOURCE_NOT_ACTIVE';
  end if;
  if exists (
    select 1
      from public.homework_assignments a
     where a.academy_id = p_academy_id
       and a.homework_item_id = v_source.id
       and a.status = 'assigned'
  ) then
    raise exception 'SPLIT_BLOCKED_BY_ASSIGNMENT';
  end if;

  select coalesce(gi.item_order_index, 0)
    into v_source_group_order
    from public.homework_group_items gi
   where gi.academy_id = p_academy_id
     and gi.group_id = p_group_id
     and gi.homework_item_id = v_source.id
   limit 1;

  v_source_order := coalesce(v_source.order_index, 0);
  v_ms_base := floor(coalesce(v_source.accumulated_ms, 0)::numeric / v_total_parts)::bigint;
  v_ms_remainder := coalesce(v_source.accumulated_ms, 0) - (v_ms_base * v_total_parts);
  v_check_base := floor(coalesce(v_source.check_count, 0)::numeric / v_total_parts)::integer;
  v_check_remainder := coalesce(v_source.check_count, 0) - (v_check_base * v_total_parts);

  if v_total_parts > 1 then
    update public.homework_items h
       set order_index = coalesce(h.order_index, 0) + (v_total_parts - 1)
     where h.academy_id = p_academy_id
       and h.student_id = v_group.student_id
       and h.id <> v_source.id
       and h.completed_at is null
       and coalesce(h.status, 0) <> 1
       and coalesce(h.order_index, 0) > v_source_order;

    update public.homework_group_items gi
       set item_order_index = coalesce(gi.item_order_index, 0) + (v_total_parts - 1)
     where gi.academy_id = p_academy_id
       and gi.group_id = p_group_id
       and gi.homework_item_id <> v_source.id
       and coalesce(gi.item_order_index, 0) > v_source_group_order;
  end if;

  delete from public.homework_group_items gi
   where gi.academy_id = p_academy_id
     and gi.group_id = p_group_id
     and gi.homework_item_id = v_source.id;

  for v_part, v_ord in
    select value, ordinality
      from jsonb_array_elements(p_parts) with ordinality
  loop
    v_part_title := nullif(trim(coalesce(v_part->>'title', '')), '');
    v_part_page := nullif(trim(coalesce(v_part->>'page', '')), '');
    v_part_type := nullif(trim(coalesce(v_part->>'type', '')), '');
    v_part_content := nullif(trim(coalesce(v_part->>'content', '')), '');
    v_part_count := case
      when coalesce(v_part->>'count', '') ~ '^[0-9]+$' then (v_part->>'count')::integer
      else null
    end;

    v_alloc_ms := v_ms_base + case when v_ord <= v_ms_remainder then 1 else 0 end;
    v_alloc_checks := v_check_base + case when v_ord <= v_check_remainder then 1 else 0 end;

    insert into public.homework_items (
      academy_id,
      student_id,
      title,
      body,
      color,
      flow_id,
      type,
      page,
      count,
      content,
      book_id,
      grade_label,
      source_unit_level,
      source_unit_path,
      default_split_parts,
      order_index,
      check_count,
      status,
      phase,
      accumulated_ms,
      waiting_at,
      first_started_at,
      version
    ) values (
      v_source.academy_id,
      v_source.student_id,
      coalesce(v_part_title, v_source.title),
      v_source.body,
      v_source.color,
      v_source.flow_id,
      coalesce(v_part_type, v_source.type),
      coalesce(v_part_page, v_source.page),
      coalesce(v_part_count, v_source.count),
      coalesce(v_part_content, v_source.content),
      v_source.book_id,
      v_source.grade_label,
      'split_waiting',
      coalesce(v_source.source_unit_path, '') || '#split:' || v_source.id::text,
      coalesce(v_source.default_split_parts, 1),
      v_source_order + (v_ord::integer - 1),
      greatest(0, v_alloc_checks),
      coalesce(v_source.status, 0),
      1,
      greatest(0, v_alloc_ms),
      now(),
      v_source.first_started_at,
      1
    )
    returning id into v_new_id;

    insert into public.homework_group_items (
      academy_id,
      group_id,
      homework_item_id,
      student_id,
      item_order_index
    ) values (
      p_academy_id,
      p_group_id,
      v_new_id,
      v_group.student_id,
      v_source_group_order + (v_ord::integer - 1)
    );

    v_created_ids := array_append(v_created_ids, v_new_id);
  end loop;

  update public.homework_items h
     set phase = 1,
         run_start = null,
         completed_at = coalesce(h.completed_at, now()),
         status = 1,
         updated_at = now(),
         version = coalesce(h.version, 1) + 1
   where h.id = v_source.id
     and h.academy_id = p_academy_id;

  return jsonb_build_object(
    'group_id', p_group_id,
    'source_item_id', p_source_item_id,
    'created_item_ids', to_jsonb(v_created_ids)
  );
end;
$$;

create or replace function public.homework_group_merge_waiting(
  p_group_id uuid,
  p_item_ids uuid[],
  p_merged_payload jsonb,
  p_academy_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group public.homework_groups%rowtype;
  v_base_item public.homework_items%rowtype;
  v_min_group_order integer := 0;
  v_min_item_order integer := 0;
  v_selected_count integer := 0;
  v_distinct_input_count integer := 0;
  v_sum_ms bigint := 0;
  v_sum_checks integer := 0;
  v_payload_title text;
  v_payload_page text;
  v_payload_type text;
  v_payload_content text;
  v_payload_count integer;
  v_new_id uuid;
begin
  v_distinct_input_count := (
    select count(distinct x)
      from unnest(coalesce(p_item_ids, array[]::uuid[])) as x
  );
  if v_distinct_input_count < 2 then
    raise exception 'MERGE_REQUIRES_AT_LEAST_TWO_ITEMS';
  end if;

  select g.*
    into v_group
    from public.homework_groups g
   where g.id = p_group_id
     and g.academy_id = p_academy_id
     and g.status = 'active';
  if v_group.id is null then
    raise exception 'MERGE_GROUP_NOT_FOUND';
  end if;

  select count(distinct h.id)
    into v_selected_count
    from public.homework_items h
    join public.homework_group_items gi
      on gi.homework_item_id = h.id
     and gi.academy_id = p_academy_id
     and gi.group_id = p_group_id
   where h.academy_id = p_academy_id
     and h.student_id = v_group.student_id
     and h.id = any(p_item_ids);
  if v_selected_count <> v_distinct_input_count then
    raise exception 'MERGE_ITEMS_NOT_IN_SAME_GROUP';
  end if;

  if exists (
    select 1
      from public.homework_items h
      join public.homework_group_items gi
        on gi.homework_item_id = h.id
       and gi.academy_id = p_academy_id
       and gi.group_id = p_group_id
     where h.academy_id = p_academy_id
       and h.student_id = v_group.student_id
       and h.id = any(p_item_ids)
       and (
         coalesce(h.phase, 0) <> 1
         or h.completed_at is not null
         or coalesce(h.status, 0) = 1
       )
  ) then
    raise exception 'MERGE_ONLY_WAITING_PHASE';
  end if;

  if exists (
    select 1
      from public.homework_assignments a
     where a.academy_id = p_academy_id
       and a.homework_item_id = any(p_item_ids)
       and a.status = 'assigned'
  ) then
    raise exception 'MERGE_BLOCKED_BY_ASSIGNMENT';
  end if;

  select h.*
    into v_base_item
    from public.homework_items h
    join public.homework_group_items gi
      on gi.homework_item_id = h.id
     and gi.academy_id = p_academy_id
     and gi.group_id = p_group_id
   where h.academy_id = p_academy_id
     and h.student_id = v_group.student_id
     and h.id = any(p_item_ids)
   order by coalesce(gi.item_order_index, 0), coalesce(h.order_index, 0), h.id
   limit 1;

  select
    coalesce(min(gi.item_order_index), 0),
    coalesce(min(h.order_index), 0),
    coalesce(sum(h.accumulated_ms), 0),
    coalesce(sum(h.check_count), 0)
    into v_min_group_order, v_min_item_order, v_sum_ms, v_sum_checks
    from public.homework_items h
    join public.homework_group_items gi
      on gi.homework_item_id = h.id
     and gi.academy_id = p_academy_id
     and gi.group_id = p_group_id
   where h.academy_id = p_academy_id
     and h.student_id = v_group.student_id
     and h.id = any(p_item_ids);

  v_payload_title := nullif(trim(coalesce(p_merged_payload->>'title', '')), '');
  v_payload_page := nullif(trim(coalesce(p_merged_payload->>'page', '')), '');
  v_payload_type := nullif(trim(coalesce(p_merged_payload->>'type', '')), '');
  v_payload_content := nullif(trim(coalesce(p_merged_payload->>'content', '')), '');
  v_payload_count := case
    when coalesce(p_merged_payload->>'count', '') ~ '^[0-9]+$' then (p_merged_payload->>'count')::integer
    else null
  end;

  insert into public.homework_items (
    academy_id,
    student_id,
    title,
    body,
    color,
    flow_id,
    type,
    page,
    count,
    content,
    book_id,
    grade_label,
    source_unit_level,
    source_unit_path,
    default_split_parts,
    order_index,
    check_count,
    status,
    phase,
    accumulated_ms,
    waiting_at,
    first_started_at,
    version
  ) values (
    v_base_item.academy_id,
    v_base_item.student_id,
    coalesce(v_payload_title, v_base_item.title),
    v_base_item.body,
    v_base_item.color,
    v_base_item.flow_id,
    coalesce(v_payload_type, v_base_item.type),
    coalesce(v_payload_page, v_base_item.page),
    coalesce(v_payload_count, v_base_item.count),
    coalesce(v_payload_content, v_base_item.content),
    v_base_item.book_id,
    v_base_item.grade_label,
    'merge_waiting',
    coalesce(v_base_item.source_unit_path, '') || '#merge:' || v_base_item.id::text,
    coalesce(v_base_item.default_split_parts, 1),
    v_min_item_order,
    greatest(0, v_sum_checks),
    coalesce(v_base_item.status, 0),
    1,
    greatest(0, v_sum_ms),
    now(),
    v_base_item.first_started_at,
    1
  )
  returning id into v_new_id;

  delete from public.homework_group_items gi
   where gi.academy_id = p_academy_id
     and gi.group_id = p_group_id
     and gi.homework_item_id = any(p_item_ids);

  insert into public.homework_group_items (
    academy_id,
    group_id,
    homework_item_id,
    student_id,
    item_order_index
  ) values (
    p_academy_id,
    p_group_id,
    v_new_id,
    v_group.student_id,
    v_min_group_order
  );

  update public.homework_items h
     set phase = 1,
         run_start = null,
         completed_at = coalesce(h.completed_at, now()),
         status = 1,
         updated_at = now(),
         version = coalesce(h.version, 1) + 1
   where h.academy_id = p_academy_id
     and h.id = any(p_item_ids);

  with ranked as (
    select gi.id,
           row_number() over (
             order by coalesce(gi.item_order_index, 0), gi.created_at, gi.id
           ) - 1 as normalized_idx
      from public.homework_group_items gi
     where gi.academy_id = p_academy_id
       and gi.group_id = p_group_id
  )
  update public.homework_group_items gi
     set item_order_index = ranked.normalized_idx,
         updated_at = now(),
         version = coalesce(gi.version, 1) + 1
    from ranked
   where gi.id = ranked.id;

  return jsonb_build_object(
    'group_id', p_group_id,
    'merged_item_id', v_new_id,
    'merged_from_item_ids', to_jsonb(p_item_ids)
  );
end;
$$;
