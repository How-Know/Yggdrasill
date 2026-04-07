-- M5 서술형 그룹 생성 시 학생 플로우 이름 '현행'이 있으면 homework_groups / homework_items 에 flow_id 설정

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
    and sf.name = '현행'
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
