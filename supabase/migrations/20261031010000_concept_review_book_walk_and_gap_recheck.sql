-- 20261031010000: 특정 교재(book_id) 출처 기준 개념 검수 목록 고정 및 새 출처 추가 시 외부 근거 미확인(evidence_gaps) 재검토
--
-- 1) concept_review_record_stale:
--    표기·의미·배치의 최신 승인 기록이 외부 근거 미확인(gap: source·grade_unit·figure)일 때,
--    그 기록 시각(r.created_at) 이후에 새 출처(concept_sources)가 추가되면 한 번 다시 판단(recheck) 대상으로 연다.
--    다시 판단해 승인된 뒤에도 여전히 외부 근거 미확인이면 새 기록의 created_at > s.created_at 이므로
--    다시 1차 충족(근거 미확인, gap)으로 돌아가고 반복하지 않는다.
-- 2) concept_review_jobs_find:
--    출처가 연결된 교재 목록(books: book_id, book_name, grade_labels, concepts)을 함께 돌려준다.
-- 3) concept_review_book_walk:
--    특정 교재(p_source_book_id)의 출처가 있는 개념을 concept_review_walks에 한 번 고정하고,
--    페이지는 기존 concept_review_walk(walk_id)로 돌려준다.

create or replace function public.concept_review_record_stale(r public.concept_quality_reviews, p_marks jsonb)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select r.mark is distinct from (p_marks ->> public.concept_review_scope_mark(r.scope))
      or exists (
        select 1 from jsonb_array_elements(coalesce(r.compared, '[]'::jsonb)) e
         where e ? 'text'
           and public.concept_review_text_mark(public.course_think_uuid(e ->> 'id')) is distinct from e ->> 'text'
      )
      or (r.scope = 'foundation' and exists (
            select 1 from jsonb_array_elements(coalesce(r.compared, '[]'::jsonb)) e
             where not exists (select 1 from public.concepts c where c.id = public.course_think_uuid(e ->> 'id'))
          ))
      or (public.concept_review_evidence_gap(r.scope, r.outcome, r.detail)
          and exists (
            select 1 from jsonb_array_elements_text(r.detail -> 'evidence_gaps') g
             where g in ('source', 'grade_unit', 'figure')
          )
          and exists (
            select 1 from public.concept_sources s
             where s.concept_id = r.concept_id
               and s.created_at > r.created_at
          ));
$$;

create or replace function public.concept_review_jobs_find()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.concept_review_assert_operator();
  return jsonb_build_object(
    'jobs', coalesce((
      select jsonb_agg(jsonb_build_object(
               'job_id', j.id, 'title', j.title, 'status', j.status, 'pause_reason', j.pause_reason,
               'walk_id', j.walk_id, 'total', j.total, 'checkpoint', j.checkpoint, 'served_through', j.served_through,
               'created_by_me', j.created_by = auth.uid(), 'created_at', j.created_at, 'updated_at', j.updated_at,
               'last_progress_at', j.last_progress_at
             ) order by j.updated_at desc)
        from public.concept_review_jobs j
       where j.status <> 'cancelled'
    ), '[]'::jsonb),
    'walks', coalesce((
      select jsonb_agg(jsonb_build_object(
               'walk_id', w.id, 'total', cardinality(w.concept_ids), 'filter', w.filter, 'created_at', w.created_at,
               'job_id', (select j.id from public.concept_review_jobs j where j.walk_id = w.id),
               'deleted_after', case when exists (select 1 from public.concept_review_jobs j where j.walk_id = w.id)
                                     then null else w.created_at + interval '30 days' end
             ) order by w.created_at desc)
        from (select * from public.concept_review_walks order by created_at desc limit 10) w
    ), '[]'::jsonb),
    'books', coalesce((
      select jsonb_agg(jsonb_build_object(
               'book_id', b.book_id,
               'book_name', b.book_name,
               'grade_labels', b.grade_labels,
               'concepts', b.concepts
             ) order by b.book_name nulls last, b.book_id)
        from (
          select s.book_id,
                 f.name as book_name,
                 jsonb_agg(distinct s.grade_label order by s.grade_label) as grade_labels,
                 count(distinct s.concept_id)::integer as concepts
            from public.concept_sources s
            left join public.resource_files f on f.id = s.book_id
           group by s.book_id, f.name
        ) b
    ), '[]'::jsonb)
  );
end;
$$;

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
      'source_scope', v_scope
    ),
    v_ids,
    auth.uid()
  )
  returning * into v_walk;

  return public.concept_review_walk(v_walk.id, null, p_offset, p_limit);
end;
$$;

revoke all on function public.concept_review_book_walk(uuid, text, integer, integer) from public, anon;
grant execute on function public.concept_review_book_walk(uuid, text, integer, integer) to authenticated;

notify pgrst, 'reload schema';
