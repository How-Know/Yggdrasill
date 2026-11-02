-- 20261102030000: 문항검수 — 해설 PDF 좌표 기반 원본 해설 전사(Vision) · 대안 풀이 확장 · V2 렌더링 학생 시점 검수
--
-- 1) textbook_problem_analyses
--    solution_source        원본 해설(solution_transcribed)이 어디서 왔는지. 'textbook_vision' = 해설 PDF 좌표 영역 이미지를
--                           Vision으로 전사한 것, 'manual' = 운영자가 직접 입력. (AI 독립 풀이는 ai_solution에 따로 둔다)
--    alternative_solutions  추후 다른 풀이로 확장하기 위한 배열. [{id, source: 'ai'|'manual'|'textbook', title, solution, answer, created_at}]
--    render_checks          V2 엔진(xelatex) 렌더링 결과를 학생 시점에서 본 판정.
--                           {problem_ok, answer_ok, solution_ok, issue_title, issue_detail, images: {problem, answer_solution}, model}
--    render_checked_at      마지막 V2 렌더 검수 시각
-- 2) textbook_review_unit_overview 에 위 컬럼과 해설 좌표(source_kind, number/content_region_1k)를 함께 내려준다.
-- 3) textbook_review_save_item_edit 에 원본 해설·해설 정답·대안 풀이 편집 인자를 추가한다(기존 6인자 함수는 제거).

alter table public.textbook_problem_analyses
  add column if not exists solution_source text
    check (solution_source is null or solution_source in ('textbook_vision', 'manual')),
  add column if not exists alternative_solutions jsonb not null default '[]'::jsonb,
  add column if not exists render_checks jsonb not null default '{}'::jsonb,
  add column if not exists render_checked_at timestamptz;

-- 이전 파이프라인은 AI 풀이를 정리한 글을 solution_transcribed 에 넣었다. 원본 해설이 아니므로 비운다(재검수 때 Vision으로 채운다).
update public.textbook_problem_analyses
   set solution_transcribed = null,
       solution_answer = null,
       solution_extracted_at = null
 where solution_source is null
   and solution_transcribed is not null;

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
        'equations', coalesce(pq.equations, '[]'::jsonb),
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

-- 정답·AI 풀이·시각 태그에 더해 원본 해설(전사)·해설 정답·대안 풀이를 직접 고칠 수 있게 한다.
drop function if exists public.textbook_review_save_item_edit(uuid, text, text, text[], boolean, boolean);

create or replace function public.textbook_review_save_item_edit(
  p_crop_id uuid,
  p_new_answer text,
  p_ai_solution text,
  p_visual_tags text[],
  p_approve_math boolean default false,
  p_approve_quality boolean default false,
  p_solution_transcribed text default null,
  p_solution_answer text default null,
  p_alternative_solutions jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_crop public.textbook_problem_crops;
  v_alt jsonb;
begin
  if not (select public.is_superadmin()) then
    raise exception 'textbook_review_forbidden';
  end if;
  select * into v_crop from public.textbook_problem_crops where id = p_crop_id;
  if not found then
    raise exception 'textbook_review_crop_not_found';
  end if;
  if p_alternative_solutions is not null and jsonb_typeof(p_alternative_solutions) <> 'array' then
    raise exception 'textbook_review_bad_alternative_solutions';
  end if;
  v_alt := p_alternative_solutions;

  if p_new_answer is not null and btrim(p_new_answer) <> '' then
    perform set_config('yggdrasill.manual_override', 'on', true);
    insert into public.textbook_problem_answers
      (crop_id, academy_id, book_id, grade_label, big_order, mid_order, sub_key, problem_number, answer_kind, answer_text, answer_latex_2d, answer_source, edited_at)
    values
      (v_crop.id, v_crop.academy_id, v_crop.book_id, v_crop.grade_label, v_crop.big_order, v_crop.mid_order, v_crop.sub_key, v_crop.problem_number,
       'text', btrim(p_new_answer), btrim(p_new_answer), 'manual', now())
    on conflict (crop_id) do update
      set answer_text = btrim(p_new_answer),
          answer_latex_2d = btrim(p_new_answer),
          answer_source = 'manual',
          edited_at = now();
    perform set_config('yggdrasill.manual_override', '', true);
  end if;

  insert into public.textbook_problem_analyses (crop_id, academy_id, ai_solution, visual_tags, solution_transcribed, solution_answer, solution_source, alternative_solutions)
  values (
    v_crop.id, v_crop.academy_id, p_ai_solution, coalesce(p_visual_tags, '{}'::text[]),
    nullif(btrim(coalesce(p_solution_transcribed, '')), ''),
    nullif(btrim(coalesce(p_solution_answer, '')), ''),
    case when nullif(btrim(coalesce(p_solution_transcribed, '')), '') is not null then 'manual' end,
    coalesce(v_alt, '[]'::jsonb)
  )
  on conflict (crop_id) do update
    set ai_solution = coalesce(p_ai_solution, public.textbook_problem_analyses.ai_solution),
        visual_tags = coalesce(p_visual_tags, public.textbook_problem_analyses.visual_tags),
        -- 운영자가 원본 해설을 바꿨을 때만 manual 로 표시한다. 같은 글이면 Vision 출처를 유지한다.
        solution_transcribed = case
          when p_solution_transcribed is null then public.textbook_problem_analyses.solution_transcribed
          else nullif(btrim(p_solution_transcribed), '')
        end,
        solution_answer = case
          when p_solution_answer is null then public.textbook_problem_analyses.solution_answer
          else nullif(btrim(p_solution_answer), '')
        end,
        solution_source = case
          when p_solution_transcribed is null then public.textbook_problem_analyses.solution_source
          when nullif(btrim(p_solution_transcribed), '') is null then null
          when public.textbook_problem_analyses.solution_transcribed is distinct from btrim(p_solution_transcribed) then 'manual'
          else coalesce(public.textbook_problem_analyses.solution_source, 'manual')
        end,
        alternative_solutions = coalesce(v_alt, public.textbook_problem_analyses.alternative_solutions),
        answer_matched = case when p_approve_math then true else public.textbook_problem_analyses.answer_matched end,
        math_status = case when p_approve_math then 'approved' else public.textbook_problem_analyses.math_status end,
        math_approved_at = case when p_approve_math then now() else public.textbook_problem_analyses.math_approved_at end,
        math_approved_by = case when p_approve_math then auth.uid() else public.textbook_problem_analyses.math_approved_by end,
        quality_status = case when p_approve_quality then 'approved' else public.textbook_problem_analyses.quality_status end,
        quality_approved_at = case when p_approve_quality then now() else public.textbook_problem_analyses.quality_approved_at end,
        quality_approved_by = case when p_approve_quality then auth.uid() else public.textbook_problem_analyses.quality_approved_by end,
        updated_at = now();

  if p_approve_math then
    update public.textbook_review_findings
       set status = 'resolved', resolution = 'manual_edit', resolved_at = now()
     where crop_id = p_crop_id and axis = 'validity' and status in ('open', 'held');
  end if;
  if p_approve_quality then
    update public.textbook_review_findings
       set status = 'resolved', resolution = 'manual_edit', resolved_at = now()
     where crop_id = p_crop_id and axis in ('fidelity', 'output') and status in ('open', 'held');
  end if;

  perform public.textbook_problem_recalc_scores(p_crop_id);
  return jsonb_build_object('ok', true, 'crop_id', p_crop_id);
end;
$$;

revoke all on function public.textbook_review_save_item_edit(uuid, text, text, text[], boolean, boolean, text, text, jsonb) from public, anon;
grant execute on function public.textbook_review_save_item_edit(uuid, text, text, text[], boolean, boolean, text, text, jsonb) to authenticated;

notify pgrst, 'reload schema';
