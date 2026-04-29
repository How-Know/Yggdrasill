-- Extend default homework flows to six active flows:
-- 개념, 문제, 사고, 테스트, 서술, 행동.
-- Legacy 현행/선행 names are kept link-safe by renaming rows in place.

update public.student_flows
set name = case trim(name)
  when '현행' then '개념'
  when '선행' then '문제'
  else name
end
where trim(name) in ('현행', '선행');

insert into public.student_flows (
  academy_id,
  student_id,
  name,
  enabled,
  order_index,
  version,
  created_at,
  updated_at
)
select
  s.academy_id,
  s.id,
  defaults.name,
  true,
  defaults.order_index,
  1,
  now(),
  now()
from public.students s
cross join (
  values
    ('개념', 0),
    ('문제', 1),
    ('사고', 2),
    ('테스트', 3),
    ('서술', 4),
    ('행동', 5)
) as defaults(name, order_index)
where not exists (
  select 1
  from public.student_flows sf
  where sf.academy_id = s.academy_id
    and sf.student_id = s.id
    and trim(sf.name) = defaults.name
);

update public.student_flows sf
set enabled = true,
    order_index = defaults.order_index,
    updated_at = now()
from (
  values
    ('개념', 0),
    ('문제', 1),
    ('사고', 2),
    ('테스트', 3),
    ('서술', 4),
    ('행동', 5)
) as defaults(name, order_index)
where trim(sf.name) = defaults.name;

do $$
declare
  v_row record;
  v_elem jsonb;
  v_name text;
  v_next jsonb;
  v_has_concept boolean;
  v_has_problem boolean;
  v_has_thinking boolean;
  v_has_test boolean;
  v_has_narrative boolean;
  v_has_behavior boolean;
begin
  if not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'student_basic_info'
      and column_name = 'flows'
  ) then
    return;
  end if;

  for v_row in
    select student_id, coalesce(flows, '[]'::jsonb) as flows
    from public.student_basic_info
  loop
    v_next := '[]'::jsonb;
    v_has_concept := false;
    v_has_problem := false;
    v_has_thinking := false;
    v_has_test := false;
    v_has_narrative := false;
    v_has_behavior := false;

    for v_elem in
      select value
      from jsonb_array_elements(
        case
          when jsonb_typeof(v_row.flows) = 'array' then v_row.flows
          else '[]'::jsonb
        end
      )
    loop
      v_name := trim(coalesce(v_elem->>'name', ''));
      if v_name = '현행' then
        v_name := '개념';
      elsif v_name = '선행' then
        v_name := '문제';
      end if;

      if v_name = '개념' then
        v_has_concept := true;
        v_elem := jsonb_set(v_elem, '{orderIndex}', '0'::jsonb, true);
        v_elem := jsonb_set(v_elem, '{enabled}', 'true'::jsonb, true);
      elsif v_name = '문제' then
        v_has_problem := true;
        v_elem := jsonb_set(v_elem, '{orderIndex}', '1'::jsonb, true);
        v_elem := jsonb_set(v_elem, '{enabled}', 'true'::jsonb, true);
      elsif v_name = '사고' then
        v_has_thinking := true;
        v_elem := jsonb_set(v_elem, '{orderIndex}', '2'::jsonb, true);
        v_elem := jsonb_set(v_elem, '{enabled}', 'true'::jsonb, true);
      elsif v_name = '테스트' then
        v_has_test := true;
        v_elem := jsonb_set(v_elem, '{orderIndex}', '3'::jsonb, true);
        v_elem := jsonb_set(v_elem, '{enabled}', 'true'::jsonb, true);
      elsif v_name = '서술' then
        v_has_narrative := true;
        v_elem := jsonb_set(v_elem, '{orderIndex}', '4'::jsonb, true);
        v_elem := jsonb_set(v_elem, '{enabled}', 'true'::jsonb, true);
      elsif v_name = '행동' then
        v_has_behavior := true;
        v_elem := jsonb_set(v_elem, '{orderIndex}', '5'::jsonb, true);
        v_elem := jsonb_set(v_elem, '{enabled}', 'true'::jsonb, true);
      end if;

      v_elem := jsonb_set(v_elem, '{name}', to_jsonb(v_name), true);
      v_next := v_next || jsonb_build_array(v_elem);
    end loop;

    if not v_has_concept then
      v_next := v_next || jsonb_build_array(jsonb_build_object(
        'id', gen_random_uuid()::text,
        'name', '개념',
        'enabled', true,
        'orderIndex', 0
      ));
    end if;
    if not v_has_problem then
      v_next := v_next || jsonb_build_array(jsonb_build_object(
        'id', gen_random_uuid()::text,
        'name', '문제',
        'enabled', true,
        'orderIndex', 1
      ));
    end if;
    if not v_has_thinking then
      v_next := v_next || jsonb_build_array(jsonb_build_object(
        'id', gen_random_uuid()::text,
        'name', '사고',
        'enabled', true,
        'orderIndex', 2
      ));
    end if;
    if not v_has_test then
      v_next := v_next || jsonb_build_array(jsonb_build_object(
        'id', gen_random_uuid()::text,
        'name', '테스트',
        'enabled', true,
        'orderIndex', 3
      ));
    end if;
    if not v_has_narrative then
      v_next := v_next || jsonb_build_array(jsonb_build_object(
        'id', gen_random_uuid()::text,
        'name', '서술',
        'enabled', true,
        'orderIndex', 4
      ));
    end if;
    if not v_has_behavior then
      v_next := v_next || jsonb_build_array(jsonb_build_object(
        'id', gen_random_uuid()::text,
        'name', '행동',
        'enabled', true,
        'orderIndex', 5
      ));
    end if;

    update public.student_basic_info
    set flows = v_next
    where student_id = v_row.student_id;
  end loop;
end
$$;

create or replace function public.m5_create_descriptive_writing_group(
  p_academy_id uuid,
  p_device_id text,
  p_student_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_bind_student uuid;
  v_group_id uuid;
  v_item_id uuid;
  v_next_group_ord integer;
  v_next_item_ord integer;
  v_flow_id uuid;
begin
  if p_device_id is null or length(trim(p_device_id)) = 0 then
    raise exception 'device_id required';
  end if;

  select b.student_id into v_bind_student
  from public.m5_device_bindings b
  where b.academy_id = p_academy_id
    and b.device_id = p_device_id
    and b.active = true
  limit 1;

  if v_bind_student is null then
    raise exception 'no active binding for device';
  end if;

  if p_student_id is not null and p_student_id <> v_bind_student then
    raise exception 'student mismatch';
  end if;

  select sf.id into v_flow_id
  from public.student_flows sf
  where sf.academy_id = p_academy_id
    and sf.student_id = v_bind_student
    and sf.name = '서술'
  order by sf.order_index nulls last, sf.created_at asc
  limit 1;

  select coalesce(max(g.order_index), -1) + 1 into v_next_group_ord
  from public.homework_groups g
  where g.academy_id = p_academy_id
    and g.student_id = v_bind_student
    and g.status = 'active';

  select coalesce(max(h.order_index), -1) + 1 into v_next_item_ord
  from public.homework_items h
  where h.academy_id = p_academy_id
    and h.student_id = v_bind_student;

  insert into public.homework_groups (
    academy_id,
    student_id,
    title,
    order_index,
    status,
    flow_id
  ) values (
    p_academy_id,
    v_bind_student,
    '서술형 쓰기',
    v_next_group_ord,
    'active',
    v_flow_id
  )
  returning id into v_group_id;

  insert into public.homework_items (
    academy_id,
    student_id,
    title,
    type,
    memo,
    phase,
    order_index,
    accumulated_ms,
    check_count,
    default_split_parts,
    flow_id
  ) values (
    p_academy_id,
    v_bind_student,
    '서술형 쓰기',
    '학습',
    '두 문제 이상 쓰기',
    1,
    v_next_item_ord,
    0,
    0,
    1,
    v_flow_id
  )
  returning id into v_item_id;

  insert into public.homework_group_items (
    academy_id,
    group_id,
    homework_item_id,
    student_id,
    item_order_index
  ) values (
    p_academy_id,
    v_group_id,
    v_item_id,
    v_bind_student,
    0
  );

  perform public.homework_start(
    v_item_id,
    v_bind_student,
    p_academy_id,
    v_bind_student::text
  );

  return jsonb_build_object(
    'group_id', v_group_id,
    'item_id', v_item_id,
    'student_id', v_bind_student
  );
end;
$$;

revoke all on function public.m5_create_descriptive_writing_group(uuid, text, uuid) from public;
grant execute on function public.m5_create_descriptive_writing_group(uuid, text, uuid) to service_role;
