-- 20261101020000: 교재 검수 목록(concept_review_book_walk) 생성 시 동일 book_id 내 최근 확정 학년(grade_label) 필터링
--
-- 하나의 resource_files(예: '개념원리')가 여러 학년(1-1, 1-2, 공통수학1 등 3,400여 개 개념)에서 공유될 때,
-- 최근 확정된 초안의 grade_label이 있으면 해당 학년 출처 개념만 묶어 수천 개 전체가 잡히지 않게 한다.

create or replace function public.concept_review_book_walk(
  p_source_book_id uuid,
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
  v_book public.resource_files;
  v_scope text := coalesce(nullif(btrim(coalesce(p_source_scope, '')), ''), 'all');
  v_grade text;
  v_ids uuid[];
  v_walk public.concept_review_walks;
begin
  perform public.concept_review_assert_operator();
  if v_scope not in ('all', 'course_unplaced') then
    raise exception 'concept_review_bad_source_scope';
  end if;
  if p_source_book_id is null then
    raise exception 'concept_review_book_not_found';
  end if;
  select * into v_book from public.resource_files where id = p_source_book_id;
  if not found then
    raise exception 'concept_review_book_not_found';
  end if;

  -- 한 book_id에 여러 grade_label이 있을 때는 가장 최근 확정된 초안의 grade_label로 범위를 좁힌다.
  if (select count(distinct cs.grade_label) from public.concept_sources cs where cs.book_id = v_book.id) > 1 then
    select d.grade_label into v_grade
      from public.concept_drafts d
     where d.book_id = v_book.id
       and d.status = 'confirmed'
     order by d.confirmed_at desc nulls last, d.created_at desc
     limit 1;
  end if;

  select coalesce(array_agg(s.id order by s.path, s.sort_order nulls last, s.name, s.id), '{}'::uuid[])
    into v_ids
    from (
      select c.id, c.name, c.sort_order, public.concept_folder_path(c.main_category_id) as path
        from public.concepts c
       where exists (
         select 1
           from public.concept_sources cs
          where cs.concept_id = c.id
            and cs.book_id = v_book.id
            and (v_grade is null or cs.grade_label = v_grade)
            and (
              v_scope = 'all'
              or not exists (
                select 1
                  from public.concept_appearances a
                  join public.course_map_units u on u.id = a.course_unit_id and u.archived_at is null
                  join public.course_maps m on m.id = u.course_id and m.archived_at is null
                 where a.concept_id = c.id
                   and (
                     nullif(public._textbook_course_info(cs.grade_label) ->> 'course_key', '') is null
                     or m.course_key = public._textbook_course_info(cs.grade_label) ->> 'course_key'
                   )
              )
            )
       )
    ) s;

  delete from public.concept_review_walks w
   where w.created_at < now() - interval '30 days'
     and not exists (select 1 from public.concept_review_jobs j where j.walk_id = w.id);
  insert into public.concept_review_walks (filter, concept_ids, created_by)
  values (
    jsonb_build_object(
      'source_book_id', v_book.id,
      'book_name', v_book.name,
      'grade_label', v_grade,
      'source_scope', v_scope
    ),
    v_ids,
    auth.uid()
  )
  returning * into v_walk;

  return public.concept_review_walk(v_walk.id, null, p_offset, p_limit);
end;
$$;

-- 이미 생성된 '개념원리 1-2 개념 추가 검수'(b3fad714-4ec1-4285-9e85-66eea48822fa) 목록에서
-- 아직 내주지 않은 뒷부분(pos > served_through) 중 '1-2' 출처가 아닌 타 학년 개념을 정리한다.
do $$
declare
  v_job public.concept_review_jobs;
  v_walk public.concept_review_walks;
  v_new_ids uuid[];
begin
  select * into v_job from public.concept_review_jobs where id = 'b3fad714-4ec1-4285-9e85-66eea48822fa';
  if found then
    select * into v_walk from public.concept_review_walks where id = v_job.walk_id;
    if found then
      select coalesce(array_agg(u.cid order by u.pos), '{}'::uuid[])
        into v_new_ids
        from unnest(v_walk.concept_ids) with ordinality as u(cid, pos)
       where u.pos <= v_job.served_through
          or exists (
            select 1 from public.concept_sources cs
             where cs.concept_id = u.cid
               and cs.book_id = 'c3f55a9c-4c87-4c89-8f08-abe9cd35ea72'
               and cs.grade_label = '1-2'
          );
      update public.concept_review_walks
         set concept_ids = v_new_ids,
             filter = coalesce(filter, '{}'::jsonb) || '{"grade_label": "1-2"}'::jsonb
       where id = v_walk.id;
      update public.concept_review_jobs
         set total = cardinality(v_new_ids),
             updated_at = now()
       where id = v_job.id;
      update public.concept_review_progress_jobs
         set needs_rebuild = true,
             updated_at = now()
       where job_id = v_job.id;
    end if;
  end if;
end $$;

notify pgrst, 'reload schema';
