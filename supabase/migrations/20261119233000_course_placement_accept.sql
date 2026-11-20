-- Think가 놓은 개념 배치를 운영자가 확인한다.
-- 단원과 순서는 그대로 두고 origin을 owner로, 근거(note)는 비운다.
-- 넣기·옮기기·빼기가 아니라서 course_placement_log에는 남기지 않는다.
-- 설계: docs/architecture/course-map.md §6.2

create or replace function public.course_placement_accept(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.concept_appearances;
  v_course uuid;
begin
  perform public.course_map_assert_operator();
  v_row := public.course_placement_row_in(p_id, null);
  select u.course_id into v_course from public.course_map_units u where u.id = v_row.course_unit_id;
  if v_row.origin is distinct from 'owner' or v_row.note is not null then
    update public.concept_appearances
       set origin = 'owner',
           note = null
     where id = p_id;
  end if;
  return public.course_map_placements(v_course);
end;
$$;

revoke all on function public.course_placement_accept(uuid) from public, anon;
grant execute on function public.course_placement_accept(uuid) to authenticated;
