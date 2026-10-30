-- 20261030030000: 출처 과정별 개념 검수 목록 고정
--
-- 설계: docs/architecture/concept-library.md "출처 과정 검수 목록"
--
-- concept_review_walk 본문은 바꾸지 않는다. 이 함수는 과정 출처 조건으로 개념 id를
-- concept_review_walks에 한 번 고정하고, 페이지는 기존 concept_review_walk(walk_id)로 돌려준다.
-- 이어 읽기·검수 작업·승인 기록은 그 목록 id를 그대로 쓴다. 기존 작업·승인 행은 고치지 않는다.

create or replace function public.concept_review_source_walk(
  p_source_course_id uuid,
  p_source_scope text,
  p_offset integer,
  p_limit integer
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_course public.course_maps;
  v_scope text := nullif(btrim(coalesce(p_source_scope, '')), '');
  v_ids uuid[];
  v_walk public.concept_review_walks;
begin
  perform public.concept_review_assert_operator();
  if v_scope is null or v_scope not in ('all', 'course_unplaced') then
    raise exception 'concept_review_bad_source_scope';
  end if;
  select * into v_course from public.course_maps where id = p_source_course_id;
  if not found then
    raise exception 'course_map_not_found';
  end if;
  if nullif(btrim(coalesce(v_course.course_key, '')), '') is null then
    raise exception 'concept_review_empty_course_key';
  end if;

  -- all: 이 과정 키로 읽히는 출처가 있는 개념 전체(배치 여부 무관).
  -- course_unplaced: concept_placement_pool 의 course_sources 와 같다.
  --   이 과정 출처가 있고, 이 과정의 살아 있는 단원에는 아직 없다. 다른 과정에만 놓인 개념은 포함한다.
  -- 개념 행 하나라 출처가 여러 개여도 id 는 한 번이다.
  -- 정렬은 배치 후보(concept_placement_candidates)와 같다. 폴더 경로 배열·sort_order·이름·id.
  -- sort_order null 은 0 으로 바꾸지 않고 맨 뒤(nulls last)다. concept_review_walk 의 coalesce(sort_order, 0) 과 다르다.
  select coalesce(array_agg(s.id order by s.path, s.sort_order nulls last, s.name, s.id), '{}'::uuid[])
    into v_ids
    from (
      select c.id, c.name, c.sort_order, public.concept_folder_path(c.main_category_id) as path
        from public.concepts c
       where public.concept_has_course_source(c.id, v_course.course_key)
         and (
           v_scope = 'all'
           or not exists (
             select 1
               from public.concept_appearances a
               join public.course_map_units u on u.id = a.course_unit_id and u.archived_at is null
              where a.concept_id = c.id and u.course_id = v_course.id
           )
         )
    ) s;

  delete from public.concept_review_walks w
   where w.created_at < now() - interval '30 days'
     and not exists (select 1 from public.concept_review_jobs j where j.walk_id = w.id);
  insert into public.concept_review_walks (filter, concept_ids, created_by)
  values (
    jsonb_build_object(
      'source_course_id', v_course.id,
      'source_scope', v_scope,
      'course_key', v_course.course_key,
      'course_name', v_course.name
    ),
    v_ids,
    auth.uid()
  )
  returning * into v_walk;

  return public.concept_review_walk(v_walk.id, null, p_offset, p_limit);
end;
$$;

revoke all on function public.concept_review_source_walk(uuid, text, integer, integer) from public, anon;
grant execute on function public.concept_review_source_walk(uuid, text, integer, integer) to authenticated;

notify pgrst, 'reload schema';
