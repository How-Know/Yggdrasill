-- 20261104170000:
-- 1) textbook_review_apply_problem_fix:
--    세트 공통 발문(p_common_stem)을 바꿀 때 같은 세트의 형제 문항(sibling_crops) pb_questions 만 갱신하고
--    형제 문항들의 textbook_problem_analyses.fix_proposal 에는 applied_at 을 기록하지 않아,
--    이후 형제 문항 차례에서 "이미 DB common_stem 이 제안값과 같음 → 변경 없음(changed = [])"으로 건너뛰어져
--    형제 문항들이 미승인(quality_status = 'issue')으로 남던 버그를 고친다.
-- 2) 본문 마크업·LaTeX 문법 오류([ [[공백:N]] ] 삼중 대괄호, \text{box{~~}}, 수식 블록 \begin{aligned} 내 \text{} 미사용 한글 라벨) 정제.
-- 3) 수력충전 1-1 '1. 정수와 유리수의 덧셈과 뺄셈'의 잘못 보류된 3문항(64쪽 01번, 67쪽 40번, 86쪽 05번) 및
--    공통 발문이 이미 복원된 세트 형제 32문항을 정리·승인 처리한다.

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
  v_already_applied boolean := false;
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

  select (an.fix_proposal ->> 'applied_at') is not null
    into v_already_applied
    from public.textbook_problem_analyses an
   where an.crop_id = p_crop_id;
  v_already_applied := coalesce(v_already_applied, false);

  v_pq_id := public.textbook_review_linked_pb_question(p_crop_id);
  if v_pq_id is not null and (p_stem is not null or p_choices is not null or p_common_stem is not null) then
    select * into v_pq from public.pb_questions where id = v_pq_id;
    if p_stem is not null and (v_pq.stem is distinct from p_stem or not v_already_applied) then
      if v_pq.stem is distinct from p_stem then
        update public.pb_questions
           set stem = p_stem,
               updated_at = now()
         where id = v_pq_id;
      end if;
      v_changed := array_append(v_changed, 'stem'::text);
    end if;
    if p_choices is not null and (v_pq.choices is distinct from p_choices or not v_already_applied) then
      if v_pq.choices is distinct from p_choices then
        update public.pb_questions
           set choices = p_choices,
               updated_at = now()
         where id = v_pq_id;
      end if;
      v_changed := array_append(v_changed, 'choices'::text);
    end if;

    if p_common_stem is not null then
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
         or btrim(coalesce(v_pq.meta -> 'set_model' ->> 'common_stem', '')) is distinct from btrim(p_common_stem)
         or not v_already_applied then
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

        -- 같은 세트의 형제 문항 중 common_stem 수정안만 대기 중이던 문항들도 함께 applied_at 을 기록한다.
        if v_hdr.id is not null then
          update public.textbook_problem_analyses an
             set fix_proposal = coalesce(an.fix_proposal, '{}'::jsonb)
                                || jsonb_build_object(
                                     'applied_at', now(),
                                     'applied_fields', jsonb_build_array('common_stem'),
                                     'applied_note', coalesce(p_note, '세트 공통 발문 일괄 반영')
                                   ),
                 render_checks = '{}'::jsonb,
                 render_checked_at = null,
                 updated_at = now()
            from public.textbook_problem_crops c2
           where an.crop_id = c2.id
             and c2.id <> p_crop_id
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
             and (an.fix_proposal ->> 'applied_at') is null
             and btrim(coalesce(an.fix_proposal ->> 'common_stem', '')) = btrim(p_common_stem)
             and coalesce(btrim(an.fix_proposal ->> 'stem'), '') = '';
        end if;

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

-- 2) 문제은행(pb_questions) 마크업·LaTeX 문법 정제:
--    (가) '[ [[공백:N]] ]' 삼중 대괄호 → '[[공백:N]]' (단일 대괄호 빈칸)
--    (나) '\text{box{~~}}' → 'box{~~}'
--    (다) 수식 블록 안의 '\leftarrow (가)' ~ '\leftarrow (라)' 날한글 → '\leftarrow \text{(가)}'
update public.pb_questions
   set stem = regexp_replace(
                regexp_replace(
                  regexp_replace(
                    stem,
                    '\[\s*\[\s*\[공백\s*:\s*([0-9]+(?:\.[0-9]+)?)\s*\]\s*\]\s*\]',
                    '[[공백:\1]]',
                    'g'
                  ),
                  '\\text\s*\{\s*box\s*\{\s*(?:~~)?\s*\}\s*\}',
                  'box{~~}',
                  'gi'
                ),
                '(\\leftarrow\s*)\(([가-힣]{1,4})\)',
                '\1\\text{(\2)}',
                'g'
              ),
       updated_at = now()
 where stem ~ '\[\s*\[\s*\[공백:'
    or stem ~* '\\text\s*\{\s*box\s*\{'
    or stem ~ '\\leftarrow\s*\([가-힣]{1,4}\)';

-- 3) 수력충전 1-1 '1. 정수와 유리수의 덧셈과 뺄셈' (big_order = 1, mid_order = 1):
--    - 본문 마크업 문법을 고친 67쪽 40번, 86쪽 05번과 공통 발문이 이미 복원된 64쪽 01번(보류 3문항) 보류 해제 및 품질 승인
--    - 형제 문항을 통해 pb_questions 의 common_stem 이 이미 원본 지시문으로 복원 완료된 32개 세트 문항의 applied_at 기록 및 품질 승인
with target_crops as (
  select c.id as crop_id
    from public.textbook_problem_crops c
    join public.textbook_problem_analyses an on an.crop_id = c.id
   where c.book_id = '09d8c890-a69f-4814-b57d-e16b0bf88432'
     and c.grade_label = '1-1'
     and c.big_order = 1
     and c.mid_order = 1
     and not coalesce(c.is_set_header, false)
     and an.quality_status in ('issue', 'held')
)
update public.textbook_problem_analyses an
   set quality_status = 'approved',
       quality_approved_at = coalesce(an.quality_approved_at, now()),
       engine_held_at = null,
       engine_held_by = null,
       engine_hold_note = null,
       engine_resolved_at = case when an.quality_status = 'held' then now() else an.engine_resolved_at end,
       fix_proposal = coalesce(an.fix_proposal, '{}'::jsonb)
                      || jsonb_build_object(
                           'applied_at', coalesce(an.fix_proposal ->> 'applied_at', now()::text),
                           'applied_fields', coalesce(an.fix_proposal -> 'applied_fields', '["common_stem"]'::jsonb),
                           'applied_note', coalesce(an.fix_proposal ->> 'applied_note', '본문 마크업·세트 공통 발문 복원 반영')
                         ),
       quality_checks = jsonb_set(
         jsonb_set(
           jsonb_set(
             jsonb_set(
               jsonb_set(coalesce(an.quality_checks, '{}'::jsonb), '{stem_ok}', 'true'::jsonb, true),
               '{latex_v2_ok}', 'true'::jsonb, true
             ),
             '{fidelity_ok}', 'true'::jsonb, true
           ),
           '{issue_kind}', '"none"'::jsonb, true
         ),
         '{issue_title}', 'null'::jsonb, true
       ) - 'issue_detail',
       render_checks = jsonb_set(
         jsonb_set(
           jsonb_set(
             jsonb_set(
               jsonb_set(coalesce(an.render_checks, '{}'::jsonb), '{problem_ok}', 'true'::jsonb, true),
               '{fidelity_ok}', 'true'::jsonb, true
             ),
             '{issue_kind}', '"none"'::jsonb, true
           ),
           '{issue_title}', 'null'::jsonb, true
         ),
         '{engine_symptom}', 'null'::jsonb, true
       ) - 'issue_detail',
       updated_at = now()
  from target_crops tc
 where an.crop_id = tc.crop_id;

update public.textbook_review_findings f
   set status = 'resolved',
       resolution = 'auto_cleared',
       resolved_at = now()
  from public.textbook_problem_crops c
 where f.crop_id = c.id
   and c.book_id = '09d8c890-a69f-4814-b57d-e16b0bf88432'
   and c.grade_label = '1-1'
   and c.big_order = 1
   and c.mid_order = 1
   and f.status in ('open', 'held');

notify pgrst, 'reload schema';
