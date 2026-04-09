alter table public.homework_items
  add column if not exists time_limit_minutes integer;

create or replace function public.homework_create_reserved_homework_bundle(
  p_academy_id uuid,
  p_student_id uuid,
  p_group jsonb,
  p_items jsonb
) returns jsonb
language plpgsql
volatile
security invoker
set search_path = public
as $$
declare
  elem jsonb;
  v_item_id uuid;
  v_group_id uuid;
  v_flow_text text;
  v_next_assign_order int;
  v_idx int := 0;
  v_i int;
  v_len int;
  v_split int;
  v_assigned_id uuid;
  v_has_group boolean;
  v_g_title text;
  v_g_order int;
  v_note text := '__reserved_homework__';
begin
  if p_academy_id is null or p_student_id is null then
    raise exception 'homework_create_reserved_homework_bundle: academy_id and student_id required';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) < 1 then
    raise exception 'homework_create_reserved_homework_bundle: p_items must be a non-empty array';
  end if;

  v_has_group :=
    p_group is not null
    and jsonb_typeof(p_group) = 'object'
    and nullif(trim(p_group->>'id'), '') is not null;

  if v_has_group then
    v_group_id := (trim(p_group->>'id'))::uuid;
    v_g_title := coalesce(nullif(trim(p_group->>'title'), ''), '그룹 과제');
    v_g_order := coalesce((p_group->>'order_index')::int, 0);
    v_flow_text := nullif(trim(p_group->>'flow_id'), '');
    insert into public.homework_groups (
      id,
      academy_id,
      student_id,
      title,
      flow_id,
      order_index,
      status,
      created_at,
      updated_at,
      version
    )
    values (
      v_group_id,
      p_academy_id,
      p_student_id,
      v_g_title,
      case
        when v_flow_text is null then null
        else v_flow_text::uuid
      end,
      v_g_order,
      'active',
      now(),
      now(),
      1
    );
  end if;

  select coalesce(max(order_index), -1) + 1
    into v_next_assign_order
    from public.homework_assignments
   where academy_id = p_academy_id
     and student_id = p_student_id
     and status = 'assigned'
     and due_date is null;

  v_len := jsonb_array_length(p_items);
  for v_i in 0..v_len - 1
  loop
    elem := p_items->v_i;
    v_idx := v_idx + 1;
    v_item_id := (trim(elem->>'id'))::uuid;
    v_split := greatest(
      1,
      least(
        4,
        coalesce(
          nullif((elem->>'split_parts')::int, 0),
          nullif((elem->>'default_split_parts')::int, 0),
          1
        )
      )
    );

    insert into public.homework_items (
      id,
      academy_id,
      student_id,
      title,
      body,
      color,
      flow_id,
      type,
      page,
      count,
      time_limit_minutes,
      memo,
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
      run_start,
      completed_at,
      first_started_at,
      submitted_at,
      confirmed_at,
      waiting_at,
      version
    )
    values (
      v_item_id,
      p_academy_id,
      p_student_id,
      coalesce(nullif(trim(elem->>'title'), ''), '과제'),
      coalesce(
        nullif(trim(elem->>'body'), ''),
        coalesce(nullif(trim(elem->>'title'), ''), '과제')
      ),
      coalesce((elem->>'color')::bigint, 4280391410),
      case
        when nullif(trim(elem->>'flow_id'), '') is null then null
        else trim(elem->>'flow_id')::uuid
      end,
      nullif(elem->>'type', ''),
      nullif(elem->>'page', ''),
      (elem->>'count')::int,
      case
        when (elem ? 'time_limit_minutes')
          and coalesce((elem->>'time_limit_minutes')::int, 0) > 0
        then (elem->>'time_limit_minutes')::int
        else null
      end,
      nullif(elem->>'memo', ''),
      nullif(elem->>'content', ''),
      case
        when nullif(trim(coalesce(elem->>'book_id', '')), '') is null then null
        else trim(elem->>'book_id')::uuid
      end,
      nullif(elem->>'grade_label', ''),
      nullif(elem->>'source_unit_level', ''),
      nullif(elem->>'source_unit_path', ''),
      greatest(1, least(4, coalesce((elem->>'default_split_parts')::int, 1))),
      coalesce((elem->>'order_index')::int, 0),
      coalesce((elem->>'check_count')::int, 0),
      coalesce((elem->>'status')::int, 0),
      coalesce((elem->>'phase')::int, 1),
      coalesce((elem->>'accumulated_ms')::bigint, 0),
      nullif(elem->>'run_start', '')::timestamptz,
      nullif(elem->>'completed_at', '')::timestamptz,
      nullif(elem->>'first_started_at', '')::timestamptz,
      nullif(elem->>'submitted_at', '')::timestamptz,
      nullif(elem->>'confirmed_at', '')::timestamptz,
      coalesce(nullif(elem->>'waiting_at', '')::timestamptz, now()),
      1
    );

    if v_has_group then
      insert into public.homework_group_items (
        academy_id,
        group_id,
        student_id,
        homework_item_id,
        item_order_index,
        created_at,
        updated_at,
        version
      )
      values (
        p_academy_id,
        v_group_id,
        p_student_id,
        v_item_id,
        coalesce((elem->>'item_order_index')::int, v_idx - 1),
        now(),
        now(),
        1
      );
    end if;

    v_assigned_id := gen_random_uuid();
    insert into public.homework_assignments (
      id,
      academy_id,
      student_id,
      homework_item_id,
      assigned_at,
      due_date,
      order_index,
      status,
      note,
      progress,
      repeat_index,
      split_parts,
      split_round,
      group_id,
      group_title_snapshot,
      version,
      created_at,
      updated_at
    )
    values (
      v_assigned_id,
      p_academy_id,
      p_student_id,
      v_item_id,
      now(),
      null,
      v_next_assign_order,
      'assigned',
      v_note,
      0,
      1,
      v_split,
      1,
      case when v_has_group then v_group_id else null end,
      case
        when v_has_group then v_g_title
        else coalesce(nullif(trim(elem->>'title'), ''), '과제')
      end,
      1,
      now(),
      now()
    );

    v_next_assign_order := v_next_assign_order + 1;
  end loop;

  return jsonb_build_object('ok', true, 'group_id', to_jsonb(v_group_id));
end;
$$;
