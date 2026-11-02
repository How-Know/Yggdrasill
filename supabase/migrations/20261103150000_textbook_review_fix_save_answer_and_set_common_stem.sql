-- 20261103150000: 문항검수 — 채점 정답 저장 오류(42703)와 세트 공통 발문 수정 반영
--
-- 1) textbook_review_save_item_edit: textbook_problem_answers 에는 book_id/grade_label/big_order/mid_order/sub_key/problem_number
--    컬럼이 없고 crop_id 가 1:1 키이며 answer_kind 는 ('objective','subjective') 만 허용된다.
--    없는 컬럼을 넣어 42703(column "book_id" of relation "textbook_problem_answers" does not exist)이 나던 것을 고친다.
-- 2) textbook_review_apply_problem_fix: 공통 발문(p_common_stem)을 바꿀 때
--    (a) pb_questions.meta 의 set_model.common_stem 만 바꾸고 pb_question_sets.common_stem 은 바꾸지 않아
--        출제 단위 기준 렌더링에서 옛 공통 발문이 남던 것을 함께 갱신하고,
--    (b) pb_questions 에 set_key 가 없어도 같은 세트 머리(textbook_problem_crops.is_set_header) 범위에 속한
--        형제 문항들을 찾아 set_model(common_stem, set_type, set_key, header_number)을 함께 채운다.

create or replace function public.textbook_review_save_item_edit(
  p_crop_id uuid,
  p_new_answer text,
  p_ai_solution text,
  p_visual_tags text[],
  p_approve_math boolean default false,
  p_approve_quality boolean default false,
  p_solution_transcribed text default null,
  p_solution_answer text default null,
  p_alternative_solutions jsonb default null,
  p_sync_pb_answer boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_crop public.textbook_problem_crops;
  v_alt jsonb;
  v_sync jsonb := null;
  v_ans text;
  v_kind text;
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
    v_ans := btrim(p_new_answer);
    select a.answer_kind into v_kind from public.textbook_problem_answers a where a.crop_id = p_crop_id;
    if v_kind is null or v_kind not in ('objective', 'subjective') then
      select case
               when pq.question_type = '객관식'
                 or (coalesce(pq.allow_objective, false) and not coalesce(pq.allow_subjective, true))
                 or (jsonb_typeof(pq.choices) = 'array' and jsonb_array_length(pq.choices) >= 2
                     and public.textbook_review_objective_key(v_ans) <> '')
               then 'objective'
               else 'subjective'
             end
        into v_kind
        from public.pb_questions pq
       where pq.id = public.textbook_review_linked_pb_question(p_crop_id);
      v_kind := coalesce(v_kind, case when public.textbook_review_objective_key(v_ans) ~ '[①②③④⑤⑥⑦⑧⑨⑩]' and v_ans ~ '[①②③④⑤⑥⑦⑧⑨⑩]' then 'objective' else 'subjective' end);
    end if;

    perform set_config('yggdrasill.manual_override', 'on', true);
    insert into public.textbook_problem_answers
      (crop_id, academy_id, answer_kind, answer_text, answer_latex_2d, answer_source, edited_at)
    values
      (v_crop.id, v_crop.academy_id, v_kind, v_ans, v_ans, 'manual', now())
    on conflict (crop_id) do update
      set answer_kind = coalesce(public.textbook_problem_answers.answer_kind, excluded.answer_kind),
          answer_text = excluded.answer_text,
          answer_latex_2d = excluded.answer_latex_2d,
          answer_source = 'manual',
          edited_at = now();
    perform set_config('yggdrasill.manual_override', '', true);
    if p_sync_pb_answer then
      v_sync := public.textbook_review_sync_pb_answer(p_crop_id, v_ans);
    end if;
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
        engine_resolved_at = case
          when p_approve_quality and public.textbook_problem_analyses.quality_status = 'held' then now()
          else public.textbook_problem_analyses.engine_resolved_at
        end,
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
  return jsonb_build_object('ok', true, 'crop_id', p_crop_id, 'pb_answer_sync', v_sync);
end;
$$;

revoke all on function public.textbook_review_save_item_edit(uuid, text, text, text[], boolean, boolean, text, text, jsonb, boolean) from public, anon;
grant execute on function public.textbook_review_save_item_edit(uuid, text, text, text[], boolean, boolean, text, text, jsonb, boolean) to authenticated;

-- ── 수정 적용: 본문·선지·공통 발문 + 그림 배치·그림 자산 ──
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
  v_set_id uuid;
  v_set_members int := 0;
  v_cur_common text;
  v_hdr public.textbook_problem_crops;
  v_hdr_pq_id uuid;
  v_prob_num int;
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
      -- 이 문항이 속한 세트 머리 크롭(있으면)
      if (regexp_replace(v_crop.problem_number, '[^0-9]', '', 'g')) ~ '^[0-9]+$' then
        v_prob_num := (regexp_replace(v_crop.problem_number, '[^0-9]', '', 'g'))::int;
        select sh.* into v_hdr
          from public.textbook_problem_crops sh
         where sh.academy_id = v_crop.academy_id
           and sh.book_id = v_crop.book_id
           and sh.grade_label = v_crop.grade_label
           and sh.big_order = v_crop.big_order
           and sh.mid_order = v_crop.mid_order
           and sh.sub_key = v_crop.sub_key
           and sh.sub_index = v_crop.sub_index
           and sh.is_set_header
           and v_prob_num between coalesce(sh.set_from, 0) and coalesce(sh.set_to, 0)
         order by sh.raw_page desc
         limit 1;
      end if;

      v_cur_common := btrim(coalesce(
        nullif(btrim(coalesce(v_pq.meta -> 'set_model' ->> 'common_stem', v_pq.meta -> 'set_model' ->> 'commonStem', '')), ''),
        case when v_hdr.id is not null then v_hdr.item_name else '' end,
        ''
      ));

      if v_cur_common is distinct from btrim(p_common_stem)
         or btrim(coalesce(v_pq.meta -> 'set_model' ->> 'common_stem', '')) is distinct from btrim(p_common_stem) then
        v_set_key := nullif(btrim(coalesce(
          v_pq.meta -> 'delivery_unit' ->> 'set_id',
          v_pq.meta -> 'delivery_unit' ->> 'set_key',
          v_pq.meta -> 'set_model' ->> 'set_key',
          v_pq.meta -> 'set_model' ->> 'setKey',
          case when v_hdr.id is not null then 'textbook_hdr:' || v_hdr.id::text else '' end
        )), '');
        v_set_id := case
          when (v_pq.meta -> 'delivery_unit' ->> 'set_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
            then (v_pq.meta -> 'delivery_unit' ->> 'set_id')::uuid
          else null
        end;

        -- 대상 문항: (1) 자신, (2) 같은 문서·같은 set_key, (3) 같은 세트 머리 크롭 범위의 형제 크롭에 연결된 pb_questions
        with sibling_crops as (
          select c2.id as crop_id
            from public.textbook_problem_crops c2
           where v_hdr.id is not null
             and c2.academy_id = v_crop.academy_id
             and c2.book_id = v_crop.book_id
             and c2.grade_label = v_crop.grade_label
             and c2.big_order = v_crop.big_order
             and c2.mid_order = v_crop.mid_order
             and c2.sub_key = v_crop.sub_key
             and c2.sub_index = v_crop.sub_index
             and not c2.is_set_header
             and (regexp_replace(c2.problem_number, '[^0-9]', '', 'g')) ~ '^[0-9]+$'
             and (regexp_replace(c2.problem_number, '[^0-9]', '', 'g'))::int
                 between coalesce(v_hdr.set_from, 0) and coalesce(v_hdr.set_to, 0)
        ),
        target as (
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
          union
          select public.textbook_review_linked_pb_question(sc.crop_id)
            from sibling_crops sc
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
                   ((coalesce(q.meta -> 'set_model', '{}'::jsonb) - 'commonStem')
                     || jsonb_build_object(
                          'common_stem', p_common_stem,
                          'set_type', coalesce(nullif(btrim(q.meta -> 'set_model' ->> 'set_type'), ''), 'independent_set'),
                          'set_key', coalesce(
                            nullif(btrim(coalesce(q.meta -> 'set_model' ->> 'set_key', q.meta -> 'set_model' ->> 'setKey', '')), ''),
                            v_set_key,
                            'review_set:' || v_pq_id::text
                          )
                        )
                     || case
                          when v_hdr.id is not null and btrim(coalesce(q.meta -> 'set_model' ->> 'header_number', '')) = ''
                            then jsonb_build_object(
                              'header_number', coalesce(nullif(btrim(v_hdr.problem_number), ''), v_hdr.set_from::text || '-' || v_hdr.set_to::text),
                              'range_from', v_hdr.set_from,
                              'range_to', v_hdr.set_to
                            )
                          else '{}'::jsonb
                        end)
                 ) || jsonb_build_object('is_set_question', true),
                 updated_at = now()
            from target t
           where t.id is not null and q.id = t.id
          returning q.id
        )
        select count(*) into v_set_members from upd;

        -- pb_question_sets·pb_delivery_units 의 common_stem 도 함께 맞춘다(출제 단위 렌더링 일관성).
        if v_pq.document_id is not null then
          update public.pb_question_sets s
             set common_stem = p_common_stem,
                 updated_at = now()
           where s.academy_id = v_pq.academy_id
             and s.source_document_id = v_pq.document_id
             and ((v_set_id is not null and s.id = v_set_id)
                  or (v_set_key is not null and s.set_key = v_set_key)
                  or exists (
                    select 1 from public.pb_question_set_items si
                     where si.set_id = s.id and si.question_id = v_pq_id
                  ));

          update public.pb_delivery_units du
             set source_meta = jsonb_set(coalesce(du.source_meta, '{}'::jsonb), '{common_stem}', to_jsonb(p_common_stem)),
                 updated_at = now()
           where du.academy_id = v_pq.academy_id
             and du.source_document_id = v_pq.document_id
             and (du.question_id = v_pq_id
                  or (v_set_id is not null and du.set_id = v_set_id));
        end if;

        -- 세트 머리 크롭에 연결된 pb_questions 나 item_name 도 맞춰 둔다(overview 폴백용).
        if v_hdr.id is not null then
          v_hdr_pq_id := public.textbook_review_linked_pb_question(v_hdr.id);
          if v_hdr_pq_id is not null then
            update public.pb_questions
               set stem = p_common_stem,
                   meta = jsonb_set(coalesce(meta, '{}'::jsonb), '{set_model,common_stem}', to_jsonb(p_common_stem)),
                   updated_at = now()
             where id = v_hdr_pq_id;
          end if;
        end if;

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

notify pgrst, 'reload schema';
