-- 20261103000000: 문항검수에서 문항 유형(객관식·주관식·서술형) 표시·수정
--
-- 문제은행 표기: question_type('객관식'|'주관식'|'서술형'), allow_objective, allow_subjective, meta.allow_essay
-- (문제은행 화면 _cycleQuestionTypeBadge 와 같은 조합).
--   객관식: allow_objective = true. 주관식 허용은 건드리지 않는다(객관식·주관식 겸용 문항이 있다).
--   주관식: allow_subjective = true, allow_essay = false. 객관식 허용은 건드리지 않는다(생성된 객관식 보기가 있을 수 있다).
--   서술형: allow_subjective = true, allow_objective = false, allow_essay = true.

create or replace function public.textbook_review_set_question_kind(
  p_crop_id uuid,
  p_kind text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pq_id uuid;
  v_pq public.pb_questions;
  v_type text;
  v_obj boolean;
  v_subj boolean;
  v_essay boolean;
begin
  if not (select public.is_superadmin()) then
    raise exception 'textbook_review_forbidden';
  end if;
  if p_kind not in ('objective', 'subjective', 'essay') then
    raise exception 'textbook_review_bad_kind';
  end if;
  v_pq_id := public.textbook_review_linked_pb_question(p_crop_id);
  if v_pq_id is null then
    return jsonb_build_object('ok', false, 'reason', 'no_pb_question');
  end if;
  select * into v_pq from public.pb_questions where id = v_pq_id;

  if p_kind = 'objective' then
    v_type := '객관식';
    v_obj := true;
    v_subj := coalesce(v_pq.allow_subjective, false);
    v_essay := false;
  elsif p_kind = 'subjective' then
    v_type := '주관식';
    v_obj := coalesce(v_pq.allow_objective, false);
    v_subj := true;
    v_essay := false;
  else
    v_type := '서술형';
    v_obj := false;
    v_subj := true;
    v_essay := true;
  end if;

  if v_pq.question_type is not distinct from v_type
     and v_pq.allow_objective is not distinct from v_obj
     and v_pq.allow_subjective is not distinct from v_subj
     and coalesce((v_pq.meta ->> 'allow_essay')::boolean, false) = v_essay then
    return jsonb_build_object('ok', true, 'changed', false, 'pb_question_id', v_pq_id);
  end if;

  update public.pb_questions
     set question_type = v_type,
         allow_objective = v_obj,
         allow_subjective = v_subj,
         meta = coalesce(meta, '{}'::jsonb)
           || jsonb_build_object('allow_objective', v_obj, 'allow_subjective', v_subj, 'allow_essay', v_essay),
         updated_at = now()
   where id = v_pq_id;

  return jsonb_build_object('ok', true, 'changed', true, 'pb_question_id', v_pq_id, 'question_type', v_type);
end;
$$;

revoke all on function public.textbook_review_set_question_kind(uuid, text) from public, anon;
grant execute on function public.textbook_review_set_question_kind(uuid, text) to authenticated;

-- ── 단원 상세: pb_allow_essay 추가 ──
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
        'pb_allow_essay', coalesce((pq.meta ->> 'allow_essay')::boolean, false),
        'choices', coalesce(pq.choices, '[]'::jsonb),
        'objective_choices', coalesce(pq.objective_choices, '[]'::jsonb),
        'figure_refs', coalesce(pq.figure_refs, '[]'::jsonb),
        'equations', coalesce(pq.equations, '[]'::jsonb)
      ) || jsonb_build_object(
        'pb_objective_answer_key', coalesce(pq.objective_answer_key, ''),
        'pb_subjective_answer', coalesce(pq.subjective_answer, ''),
        'pb_allow_objective', coalesce(pq.allow_objective, false),
        'pb_allow_subjective', coalesce(pq.allow_subjective, false),
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
        'fix_proposal', coalesce(an.fix_proposal, '{}'::jsonb),
        'engine_hold_note', an.engine_hold_note,
        'engine_held_at', an.engine_held_at,
        'engine_resolved_at', an.engine_resolved_at,
        'engine_hold_snapshot', coalesce(an.engine_hold_snapshot, '{}'::jsonb),
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
