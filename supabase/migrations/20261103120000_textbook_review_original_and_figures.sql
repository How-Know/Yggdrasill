-- 20261103120000: 문항검수 — 교재 원본 대조와 그림 배치
--
-- 1) 단원 상세(textbook_review_unit_overview)에 원본 좌표를 싣는다. 크롭 PNG 는 저장소에 없으므로 매니저앱이
--    본문 PDF 의 raw_page + item_region_1k(없으면 bbox_1k)로 원본 문항을 직접 렌더한다.
--    세트 문항은 세트 머리(공통 지시문) 크롭의 쪽·좌표도 함께 싣는다.
--    문제은행 그림 자산(meta.figure_assets)·배치(meta.figure_layout)도 싣는다(그림 크기·위치 맞춤용).
-- 2) 수정 적용(textbook_review_apply_problem_fix)이 그림 배치·그림 자산도 함께 저장한다.

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
          shl.common_text,
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
      ) || jsonb_build_object(
        'item_region_1k', to_jsonb(coalesce(c.item_region_1k, c.bbox_1k)),
        'set_header_raw_page', shl.raw_page,
        'set_header_region_1k', to_jsonb(shl.region),
        'pb_figure_assets', coalesce(pq.meta -> 'figure_assets', '[]'::jsonb),
        'pb_figure_layout', pq.meta -> 'figure_layout'
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
      -- 이 문항이 속한 세트 머리(공통 지시문) 크롭: 같은 소단원·세트 번호 범위
      left join lateral (
        select sh.raw_page,
               coalesce(sh.item_region_1k, sh.bbox_1k) as region,
               nullif(btrim(coalesce(pq_h.stem, pq_h.meta -> 'set_model' ->> 'common_stem', sh.item_name, '')), '') as common_text
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
      ) shl on true
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

-- ── 수정 적용: 본문·선지·공통 발문 + 그림 배치·그림 자산 ──
drop function if exists public.textbook_review_apply_problem_fix(uuid, text, jsonb, boolean, text, text);

create or replace function public.textbook_review_apply_problem_fix(
  p_crop_id uuid,
  p_stem text default null,
  p_choices jsonb default null,
  p_approve_quality boolean default false,
  p_note text default null,
  p_common_stem text default null,
  p_figure_layout jsonb default null,
  p_figure_assets jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_crop public.textbook_problem_crops;
  v_pq_id uuid;
  v_pq public.pb_questions;
  v_changed text[] := '{}';
  v_set_key text;
  v_set_members int := 0;
  v_cur_common text;
  v_cur_assets jsonb;
  v_cur_layout jsonb;
  v_fig_count int;
begin
  if not (select public.is_superadmin()) then
    raise exception 'textbook_review_forbidden';
  end if;
  select * into v_crop from public.textbook_problem_crops where id = p_crop_id;
  if not found then
    raise exception 'textbook_review_crop_not_found';
  end if;
  if p_choices is not null and jsonb_typeof(p_choices) <> 'array' then
    raise exception 'textbook_review_bad_choices';
  end if;
  if p_figure_assets is not null and jsonb_typeof(p_figure_assets) <> 'array' then
    raise exception 'textbook_review_bad_figure_assets';
  end if;
  if p_figure_layout is not null and jsonb_typeof(p_figure_layout) <> 'object' then
    raise exception 'textbook_review_bad_figure_layout';
  end if;

  v_pq_id := public.textbook_review_linked_pb_question(p_crop_id);
  if v_pq_id is not null and (p_stem is not null or p_choices is not null or p_common_stem is not null) then
    select * into v_pq from public.pb_questions where id = v_pq_id;
    if p_stem is not null and v_pq.stem is distinct from p_stem then
      v_changed := array_append(v_changed, 'stem'::text);
    end if;
    if p_choices is not null and v_pq.choices is distinct from p_choices then
      v_changed := array_append(v_changed, 'choices'::text);
    end if;
    if cardinality(v_changed) > 0 then
      update public.pb_questions
         set stem = case when 'stem' = any (v_changed) then p_stem else stem end,
             choices = case when 'choices' = any (v_changed) then p_choices else choices end,
             updated_at = now()
       where id = v_pq_id;
    end if;

    if p_common_stem is not null then
      v_cur_common := btrim(coalesce(v_pq.meta -> 'set_model' ->> 'common_stem', v_pq.meta -> 'set_model' ->> 'commonStem', ''));
      if v_cur_common is distinct from btrim(p_common_stem) then
        v_set_key := nullif(btrim(coalesce(
          v_pq.meta -> 'delivery_unit' ->> 'set_id',
          v_pq.meta -> 'delivery_unit' ->> 'set_key',
          v_pq.meta -> 'set_model' ->> 'set_key',
          v_pq.meta -> 'set_model' ->> 'setKey',
          ''
        )), '');
        -- 세트 전체(같은 문서·같은 세트 키) 또는 세트 키가 없으면 이 문항만
        with target as (
          select v_pq_id as id
          union
          select q.id
            from public.pb_questions q
           where v_set_key is not null
             and v_pq.document_id is not null
             and q.document_id = v_pq.document_id
             and q.academy_id = v_pq.academy_id
             and v_set_key = nullif(btrim(coalesce(
                   q.meta -> 'delivery_unit' ->> 'set_id',
                   q.meta -> 'delivery_unit' ->> 'set_key',
                   q.meta -> 'set_model' ->> 'set_key',
                   q.meta -> 'set_model' ->> 'setKey',
                   ''
                 )), '')
        ),
        upd as (
          update public.pb_questions q
             set meta = jsonb_set(
                   case
                     when (coalesce(q.meta, '{}'::jsonb) -> 'delivery_unit') ? 'common_stem'
                       then jsonb_set(coalesce(q.meta, '{}'::jsonb), '{delivery_unit,common_stem}', to_jsonb(p_common_stem))
                     else coalesce(q.meta, '{}'::jsonb)
                   end,
                   '{set_model}',
                   (coalesce(q.meta -> 'set_model', '{}'::jsonb) - 'commonStem') || jsonb_build_object('common_stem', p_common_stem)
                 ),
                 updated_at = now()
            from target t
           where q.id = t.id
          returning q.id
        )
        select count(*) into v_set_members from upd;
        v_changed := array_append(v_changed, 'common_stem'::text);
      end if;
    end if;
  end if;

  -- 그림: 자산 목록(figure_index 순서로 렌더러가 고른다)과 배치. 위 공통 발문 갱신 뒤의 meta 에 덧붙인다.
  if v_pq_id is not null and (p_figure_layout is not null or p_figure_assets is not null) then
    select coalesce(meta -> 'figure_assets', '[]'::jsonb), meta -> 'figure_layout'
      into v_cur_assets, v_cur_layout
      from public.pb_questions where id = v_pq_id;
    if jsonb_typeof(v_cur_assets) is distinct from 'array' then
      v_cur_assets := '[]'::jsonb;
    end if;
    if p_figure_assets is not null and v_cur_assets is distinct from p_figure_assets then
      v_changed := array_append(v_changed, 'figure_assets'::text);
    end if;
    if p_figure_layout is not null and v_cur_layout is distinct from p_figure_layout then
      v_changed := array_append(v_changed, 'figure_layout'::text);
    end if;
    if 'figure_assets' = any (v_changed) or 'figure_layout' = any (v_changed) then
      select count(distinct e ->> 'figure_index') into v_fig_count
        from jsonb_array_elements(coalesce(p_figure_assets, v_cur_assets)) e
       where (e ->> 'figure_index') ~ '^[1-9][0-9]*$';
      update public.pb_questions
         set meta = coalesce(meta, '{}'::jsonb)
               || case when 'figure_assets' = any (v_changed)
                    then jsonb_build_object('figure_assets', p_figure_assets, 'figure_count', v_fig_count,
                                            'figure_review_required', false, 'figure_crop_source', 'textbook_review_original')
                    else '{}'::jsonb end
               || case when 'figure_layout' = any (v_changed)
                    then jsonb_build_object('figure_layout', p_figure_layout)
                    else '{}'::jsonb end,
             figure_refs = case when 'figure_assets' = any (v_changed)
               then (select coalesce(jsonb_agg(to_jsonb('[그림]'::text)), '[]'::jsonb) from generate_series(1, v_fig_count))
               else figure_refs end,
             updated_at = now()
       where id = v_pq_id;
    end if;
  end if;

  insert into public.textbook_problem_analyses (crop_id, academy_id)
  values (v_crop.id, v_crop.academy_id)
  on conflict (crop_id) do nothing;

  update public.textbook_problem_analyses a
     set fix_proposal = case
           when cardinality(v_changed) > 0 or p_approve_quality then
             a.fix_proposal || jsonb_build_object('applied_at', now(), 'applied_fields', to_jsonb(v_changed), 'applied_note', p_note)
           else a.fix_proposal
         end,
         -- 본문·그림이 바뀌면 이전 V2 판정은 더 이상 그 화면이 아니다.
         render_checks = case when cardinality(v_changed) > 0 and not p_approve_quality then '{}'::jsonb else a.render_checks end,
         render_checked_at = case when cardinality(v_changed) > 0 and not p_approve_quality then null else a.render_checked_at end,
         engine_resolved_at = case when p_approve_quality and a.quality_status = 'held' then now() else a.engine_resolved_at end,
         quality_status = case when p_approve_quality then 'approved' else a.quality_status end,
         quality_approved_at = case when p_approve_quality then now() else a.quality_approved_at end,
         quality_approved_by = case when p_approve_quality then auth.uid() else a.quality_approved_by end,
         updated_at = now()
   where a.crop_id = p_crop_id;

  if p_approve_quality then
    update public.textbook_review_findings
       set status = 'resolved', resolution = 'manual_edit', resolved_at = now()
     where crop_id = p_crop_id and axis in ('fidelity', 'output') and status in ('open', 'held');
  end if;

  return jsonb_build_object(
    'ok', true,
    'crop_id', p_crop_id,
    'pb_question_id', v_pq_id,
    'changed', to_jsonb(v_changed),
    'set_members_updated', v_set_members,
    'approved', p_approve_quality
  );
end;
$$;

revoke all on function public.textbook_review_apply_problem_fix(uuid, text, jsonb, boolean, text, text, jsonb, jsonb) from public, anon;
grant execute on function public.textbook_review_apply_problem_fix(uuid, text, jsonb, boolean, text, text, jsonb, jsonb) to authenticated;
