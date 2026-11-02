-- textbook_review_unit_overview: 항목 키가 56개라 jsonb_build_object 인자가 112개가 되어
-- Postgres 함수 인자 상한(100)을 넘었다 (54023 cannot pass more than 100 arguments).
-- 같은 결과를 두 jsonb_build_object 를 || 로 이어 만들도록만 바꾼다. 키·값·순서는 그대로다.

create or replace function public.textbook_review_unit_overview(
  p_academy_id uuid,
  p_book_id uuid,
  p_grade_label text,
  p_big_order int,
  p_mid_order int
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.textbook_review_assert_staff(p_academy_id);
  return jsonb_build_object(
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'crop_id', c.id,
        'pb_question_id', pq.id,
        'question_uid', coalesce(pq.question_uid::text, c.pb_question_uid::text, ''),
        'document_id', coalesce(pq.document_id::text, ''),
        'sub_key', c.sub_key,
        'sub_index', c.sub_index,
        'item_name', c.item_name,
        'problem_number', c.problem_number,
        'label', c.label,
        'raw_page', c.raw_page,
        'display_page', c.display_page,
        'storage_bucket', c.storage_bucket,
        'storage_key', c.storage_key,
        'answer_kind', a.answer_kind,
        'existing_answer', coalesce(nullif(btrim(a.answer_text), ''), a.answer_latex_2d),
        'answer_manual', coalesce(a.answer_source = 'manual', false),
        'has_solution_ref', (s.crop_id is not null and coalesce(s.source_kind, '') <> 'none' and s.raw_page > 0),
        'solution_raw_page', s.raw_page,
        'solution_source_kind', coalesce(s.source_kind, 'sol'),
        'solution_region_1k', coalesce(s.content_region_1k, s.number_region_1k),
        'solution_number_region_1k', s.number_region_1k,
        'solution_content_region_1k', s.content_region_1k,
        'stem', coalesce(pq.stem, ''),
        'common_stem', coalesce(
          nullif(btrim(coalesce(pq.meta -> 'set_model' ->> 'common_stem', pq.meta -> 'set_model' ->> 'commonStem', '')), ''),
          (
            select nullif(btrim(coalesce(pq_h.stem, pq_h.meta -> 'set_model' ->> 'common_stem', sh.item_name, '')), '')
              from public.textbook_problem_crops sh
              left join public.textbook_crop_question_links lh on lh.crop_id = sh.id
              left join public.pb_questions pq_h on pq_h.id = lh.pb_question_id
             where sh.academy_id = c.academy_id
               and sh.book_id = c.book_id
               and sh.grade_label = c.grade_label
               and sh.big_order = c.big_order
               and sh.mid_order = c.mid_order
               and sh.sub_key = c.sub_key
               and sh.sub_index = c.sub_index
               and sh.is_set_header
               and (regexp_replace(c.problem_number, '[^0-9]', '', 'g')) ~ '^[0-9]+$'
               and (regexp_replace(c.problem_number, '[^0-9]', '', 'g'))::int between coalesce(sh.set_from, 0) and coalesce(sh.set_to, 0)
             order by sh.raw_page desc
             limit 1
          ),
          ''
        ),
        'set_type', coalesce(pq.meta -> 'set_model' ->> 'set_type', case when (pq.meta ->> 'is_set_question')::boolean then 'dependent_set' else '' end),
        'set_header_number', coalesce(pq.meta -> 'set_model' ->> 'header_number', ''),
        'question_type', coalesce(pq.question_type, ''),
        'choices', coalesce(pq.choices, '[]'::jsonb),
        'objective_choices', coalesce(pq.objective_choices, '[]'::jsonb),
        'figure_refs', coalesce(pq.figure_refs, '[]'::jsonb),
        'equations', coalesce(pq.equations, '[]'::jsonb)
      ) || jsonb_build_object(
        'solution_transcribed', an.solution_transcribed,
        'solution_answer', an.solution_answer,
        'solution_source', an.solution_source,
        'solution_extracted_at', an.solution_extracted_at,
        'alternative_solutions', coalesce(an.alternative_solutions, '[]'::jsonb),
        'ai_solution', an.ai_solution,
        'ai_answer', an.ai_answer,
        'match_mode', coalesce(an.match_mode, case when s.crop_id is not null and coalesce(s.source_kind, '') <> 'none' and s.raw_page > 0 then '3way' else '2way' end),
        'answer_matched', an.answer_matched,
        'mismatch_reason', an.mismatch_reason,
        'concept_score', coalesce(an.concept_score, 0),
        'thinking_score', coalesce(an.thinking_score, 0),
        'arithmetic_score', coalesce(an.arithmetic_score, 0),
        'total_difficulty', coalesce(an.total_difficulty, 0),
        'visual_tags', to_jsonb(coalesce(an.visual_tags, '{}'::text[])),
        'quality_checks', coalesce(an.quality_checks, '{}'::jsonb),
        'render_checks', coalesce(an.render_checks, '{}'::jsonb),
        'render_checked_at', an.render_checked_at,
        'draft_proposals', coalesce(an.draft_proposals, '[]'::jsonb),
        'math_status', coalesce(an.math_status, 'pending'),
        'quality_status', coalesce(an.quality_status, 'pending'),
        'concepts', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', cp.id,
            'name', cp.name,
            'score', public.concept_difficulty_score(cp.id)
          ))
          from unnest(coalesce(an.concept_ids, '{}'::uuid[])) as u(cid)
          join public.concepts cp on cp.id = u.cid
        ), '[]'::jsonb),
        'thinkings', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', tp.id,
            'code', tp.code,
            'kind', tp.kind,
            'category', tp.category,
            'title', tp.title,
            'score', tp.unit_score
          ))
          from unnest(coalesce(an.thinking_ids, '{}'::uuid[])) as u(tid)
          join public.thinking_primitives tp on tp.id = u.tid
        ), '[]'::jsonb),
        'arithmetics', coalesce((
          select jsonb_agg(jsonb_build_object(
            'code', ap.code,
            'category', ap.category,
            'title', ap.title,
            'count', (e.value #>> '{}')::int,
            'unit_score', ap.unit_score,
            'subtotal', round(ap.unit_score * greatest(coalesce((e.value #>> '{}')::numeric, 0), 0), 2)
          ) order by ap.sort_order)
          from jsonb_each(coalesce(an.arithmetic_counts, '{}'::jsonb)) e
          join public.arithmetic_primitives ap on ap.code = e.key
          where coalesce((e.value #>> '{}')::int, 0) > 0
        ), '[]'::jsonb),
        'findings', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', f.id,
            'axis', f.axis,
            'stage', f.stage,
            'error_type', f.error_type,
            'severity', f.severity,
            'title', f.title,
            'detail', f.detail,
            'proposal', f.proposal,
            'status', f.status
          ) order by f.created_at)
          from public.textbook_review_findings f
          where f.crop_id = c.id and f.status in ('open', 'held')
        ), '[]'::jsonb)
      ) order by c.raw_page, c.sub_key, c.sub_index, length(c.problem_number), c.problem_number)
      from public.textbook_problem_crops c
      left join public.textbook_problem_answers a on a.crop_id = c.id
      left join public.textbook_problem_solution_refs s on s.crop_id = c.id
      left join public.textbook_crop_question_links l on l.crop_id = c.id
      left join public.pb_questions pq
        on pq.id = coalesce(
          l.pb_question_id,
          (select q2.id from public.pb_questions q2
            where c.pb_question_uid is not null and q2.academy_id = c.academy_id and q2.question_uid = c.pb_question_uid
            limit 1)
        )
      left join public.textbook_problem_analyses an on an.crop_id = c.id
      where c.academy_id = p_academy_id
        and c.book_id = p_book_id
        and c.grade_label = p_grade_label
        and c.big_order = p_big_order
        and c.mid_order = p_mid_order
        and not c.is_set_header
    ), '[]'::jsonb)
  );
end;
$$;

grant execute on function public.textbook_review_unit_overview(uuid, uuid, text, int, int) to authenticated;

notify pgrst, 'reload schema';
