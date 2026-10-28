-- 바로 내는 그룹 과제를 한 트랜잭션으로 만든다.
-- 그룹, 하위과제, 그룹 연결, 단원·페이지 매핑, 문항 스냅샷을 한 번에 저장해
-- 약한 네트워크에서 "연결 없는 하위과제"나 빈 그룹이 남지 않게 한다.
-- 클라이언트가 정한 id를 그대로 쓰고 이미 있는 행은 건너뛰므로,
-- 응답을 못 받은 요청을 다시 보내도 중복 생성되지 않는다.

create or replace function public.homework_create_group_bundle(
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
  v_i int;
  v_len int;
  v_group_id uuid;
  v_group_track text;
  v_item_track text;
  v_item_id uuid;
  v_item_ids uuid[] := array[]::uuid[];
  v_assignment_code text;
  v_flow_text text;
  v_next_group_order int;
  v_problem_rows jsonb;
  v_problem_errors jsonb := '[]'::jsonb;
  v_result jsonb;
begin
  if p_academy_id is null or p_student_id is null then
    raise exception 'homework_create_group_bundle: academy_id and student_id required';
  end if;
  if p_group is null
     or jsonb_typeof(p_group) <> 'object'
     or nullif(trim(p_group->>'id'), '') is null then
    raise exception 'homework_create_group_bundle: p_group.id required';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) < 1 then
    raise exception 'homework_create_group_bundle: p_items must be a non-empty array';
  end if;

  v_group_id := (trim(p_group->>'id'))::uuid;
  v_group_track := public.homework_normalize_learning_track_code(
    p_group->>'learning_track_code'
  );
  v_len := jsonb_array_length(p_items);

  for v_i in 0..v_len - 1
  loop
    elem := p_items->v_i;
    v_item_track := public.homework_normalize_learning_track_code(
      coalesce(elem->>'learning_track_code', v_group_track)
    );
    if v_group_track is null then
      v_group_track := v_item_track;
    elsif v_group_track <> v_item_track then
      raise exception 'homework_create_group_bundle: mixed learning_track_code in group';
    end if;
  end loop;
  if v_group_track is null then
    v_group_track := 'EL';
  end if;

  select coalesce(max(g.order_index), -1) + 1
    into v_next_group_order
    from public.homework_groups g
   where g.academy_id = p_academy_id
     and g.student_id = p_student_id
     and g.status = 'active';

  v_flow_text := nullif(trim(p_group->>'flow_id'), '');
  insert into public.homework_groups (
    id,
    academy_id,
    student_id,
    title,
    flow_id,
    learning_track_code,
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
    coalesce(nullif(trim(p_group->>'title'), ''), '그룹 과제'),
    case when v_flow_text is null then null else v_flow_text::uuid end,
    v_group_track,
    greatest(coalesce((p_group->>'order_index')::int, 0), v_next_group_order),
    'active',
    now(),
    now(),
    1
  )
  on conflict (id) do nothing;

  for v_i in 0..v_len - 1
  loop
    elem := p_items->v_i;
    v_item_id := (trim(elem->>'id'))::uuid;
    v_item_ids := v_item_ids || v_item_id;
    v_assignment_code := upper(trim(coalesce(elem->>'assignment_code', '')));

    insert into public.homework_items (
      id,
      academy_id,
      student_id,
      title,
      body,
      color,
      flow_id,
      test_origin_flow_id,
      learning_track_code,
      assignment_code,
      type,
      page,
      count,
      time_limit_minutes,
      recommended_minutes,
      recommended_minutes_auto,
      pb_preset_id,
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
      nullif(trim(coalesce(elem->>'flow_id', '')), '')::uuid,
      nullif(trim(coalesce(elem->>'test_origin_flow_id', '')), '')::uuid,
      v_group_track,
      case
        when v_assignment_code ~ '^(CL|PL|FL|EL)[A-Z]{2}[0-9]{4}$'
          and substring(v_assignment_code from 1 for 2) = v_group_track
        then v_assignment_code
        else public.homework_issue_assignment_code(p_academy_id, v_group_track)
      end,
      nullif(elem->>'type', ''),
      nullif(elem->>'page', ''),
      nullif(elem->>'count', '')::int,
      case
        when coalesce(nullif(elem->>'time_limit_minutes', '')::int, 0) > 0
        then (elem->>'time_limit_minutes')::int
      end,
      case
        when coalesce(nullif(elem->>'recommended_minutes', '')::int, 0) > 0
        then (elem->>'recommended_minutes')::int
      end,
      case
        when coalesce(nullif(elem->>'recommended_minutes_auto', '')::int, 0) > 0
        then (elem->>'recommended_minutes_auto')::int
      end,
      nullif(trim(coalesce(elem->>'pb_preset_id', '')), '')::uuid,
      nullif(elem->>'memo', ''),
      nullif(elem->>'content', ''),
      nullif(trim(coalesce(elem->>'book_id', '')), '')::uuid,
      nullif(elem->>'grade_label', ''),
      nullif(elem->>'source_unit_level', ''),
      nullif(elem->>'source_unit_path', ''),
      greatest(1, least(4, coalesce(nullif(elem->>'default_split_parts', '')::int, 1))),
      coalesce(nullif(elem->>'order_index', '')::int, 0),
      0,
      coalesce(nullif(elem->>'status', '')::int, 0),
      coalesce(nullif(elem->>'phase', '')::int, 1),
      0,
      coalesce(nullif(elem->>'waiting_at', '')::timestamptz, now()),
      1
    )
    on conflict (id) do nothing;

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
      coalesce(nullif(elem->>'item_order_index', '')::int, v_i),
      now(),
      now(),
      1
    )
    on conflict (academy_id, homework_item_id) do nothing;

    if jsonb_typeof(elem->'unit_rows') = 'array' then
      delete from public.homework_item_units u
       where u.academy_id = p_academy_id
         and u.homework_item_id = v_item_id;
      insert into public.homework_item_units (
        academy_id,
        homework_item_id,
        student_id,
        book_id,
        grade_label,
        big_order,
        mid_order,
        small_order,
        big_name,
        mid_name,
        small_name,
        start_page,
        end_page,
        page_count,
        weight,
        source_scope
      )
      select
        p_academy_id,
        v_item_id,
        p_student_id,
        x.book_id,
        x.grade_label,
        x.big_order,
        x.mid_order,
        x.small_order,
        x.big_name,
        x.mid_name,
        x.small_name,
        x.start_page,
        x.end_page,
        x.page_count,
        coalesce(x.weight, 1),
        x.source_scope
      from jsonb_populate_recordset(
        null::public.homework_item_units,
        elem->'unit_rows'
      ) x;
    end if;

    if jsonb_typeof(elem->'page_rows') = 'array' then
      delete from public.homework_item_pages p
       where p.academy_id = p_academy_id
         and p.homework_item_id = v_item_id;
      insert into public.homework_item_pages (
        academy_id,
        homework_item_id,
        student_id,
        book_id,
        grade_label,
        page_number,
        problem_count
      )
      select
        p_academy_id,
        v_item_id,
        p_student_id,
        x.book_id,
        x.grade_label,
        x.page_number,
        coalesce(x.problem_count, 0)
      from jsonb_populate_recordset(
        null::public.homework_item_pages,
        elem->'page_rows'
      ) x;
    end if;

    -- 문항 스냅샷이 맞지 않아도 과제 자체는 만든다(기존 개별 저장과 같은 결과).
    -- 실패한 항목은 결과에 담아 앱이 기록하게 한다.
    v_problem_rows := elem->'problem_rows';
    if jsonb_typeof(v_problem_rows) = 'array'
       and jsonb_array_length(v_problem_rows) > 0 then
      begin
        perform public.homework_replace_item_problem_snapshots(
          v_item_id,
          v_problem_rows,
          coalesce(
            nullif(elem->>'problem_expected_count', '')::int,
            jsonb_array_length(v_problem_rows)
          )
        );
      exception when others then
        v_problem_errors := v_problem_errors || jsonb_build_array(
          jsonb_build_object('id', v_item_id, 'error', sqlerrm)
        );
      end;
    end if;
  end loop;

  select jsonb_build_object(
    'ok', true,
    'group_id', g.id,
    'group_order_index', g.order_index,
    'items', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', h.id,
            'version', h.version,
            'assignment_code', h.assignment_code,
            'learning_track_code', h.learning_track_code
          )
        )
        from public.homework_items h
        where h.academy_id = p_academy_id
          and h.id = any(v_item_ids)
      ),
      '[]'::jsonb
    ),
    'problem_errors', v_problem_errors
  )
    into v_result
    from public.homework_groups g
   where g.id = v_group_id;

  if v_result is null then
    raise exception 'homework_create_group_bundle: group not visible after insert';
  end if;
  return v_result;
end;
$$;

revoke all on function public.homework_create_group_bundle(uuid, uuid, jsonb, jsonb) from public;
grant execute on function public.homework_create_group_bundle(uuid, uuid, jsonb, jsonb) to authenticated;
