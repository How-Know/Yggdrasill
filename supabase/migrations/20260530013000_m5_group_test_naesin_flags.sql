-- M5: expose per-group "is_test" / "is_naesin" flags without touching the large
-- m5_list_homework_groups function.
--
-- Test detection changed: new test homework is stored as type='프린트' with
-- flow_id pointing to the student's '테스트' flow (student_flows.name='테스트'),
-- so type='테스트' alone no longer identifies tests. We flag a group as test when
-- any of its non-completed items belongs to the student's 테스트 flow.
--
-- Naesin (내신기출) is identified by homework_items.source_unit_level = 'naesin'.
--
-- The gateway calls this alongside m5_list_homework_groups and merges the flags
-- into each group payload (is_test / is_naesin).

create or replace function public.m5_group_test_naesin_flags(
  p_academy_id uuid,
  p_student_id uuid
) returns table(
  group_id uuid,
  is_test boolean,
  is_naesin boolean
) as $$
declare
  v_test_flow_id uuid;
begin
  select sf.id into v_test_flow_id
    from public.student_flows sf
   where sf.academy_id = p_academy_id
     and sf.student_id = p_student_id
     and sf.name = '테스트'
   order by sf.order_index nulls last
   limit 1;

  return query
  select
    gi.group_id,
    bool_or(
      (v_test_flow_id is not null and h.flow_id = v_test_flow_id)
      or coalesce(nullif(trim(h.test_origin_flow_id::text), ''), null) is not null
      or coalesce(h."type", '') = '테스트'
    ) as is_test,
    bool_or(coalesce(h.source_unit_level, '') = 'naesin') as is_naesin
  from public.homework_group_items gi
  join public.homework_items h
    on h.id = gi.homework_item_id
   and h.academy_id = gi.academy_id
   and h.student_id = gi.student_id
  where gi.academy_id = p_academy_id
    and gi.student_id = p_student_id
    and h.completed_at is null
    and coalesce(h.status, 0) <> 1
  group by gi.group_id;
end;
$$ language plpgsql security definer set search_path=public;

grant execute on function public.m5_group_test_naesin_flags(uuid, uuid) to anon, authenticated;
