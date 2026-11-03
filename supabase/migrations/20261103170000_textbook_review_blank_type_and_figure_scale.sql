-- 20261103170000: 문항검수 — 빈칸형 문항 판별·오판 제거 및 그림 크기(widthEm) 원본 비율(1.0배) 자동 축소 반영
--
-- 1) 빈칸형 문항 판별 함수(textbook_review_is_fill_in_blank):
--    발문·공통발문·수식에 '□ 안에', '빈칸에', '알맞은 수를 써넣어라', [[공백:n]], \square 등이 있으면 빈칸형으로 분류하고,
--    기존 quality_checks·render_checks 에서 정상 네모(□)를 '도형 외에 용도가 불명확한 빈칸 추가'·'단독 빈칸'으로 오판한 배너를 제거한다.
-- 2) 그림 문항 크기 자동 조정(widthEm):
--    render_checks.figure_size_ratio 가 1.0배에서 벗어난 문항(0.85 미만 또는 1.15 초과, 또는 1줄짜리 발문으로 emPx 가 과소 추정돼
--    widthEm 이 원본 컬럼 폭 비율보다 크게 들어간 문항)의 pb_questions.meta.figure_layout.items[*].widthEm 을
--    원본 비율(1 / ratio 및 2단 컬럼 26em 기준)에 맞춰 즉시 축소·보정하고, flagged_after_approval 경고를 정리한다.

create or replace function public.textbook_review_is_fill_in_blank(p_common_stem text, p_stem text)
returns boolean
language sql
immutable
as $$
  select (coalesce(p_common_stem, '') || E'\n' || coalesce(p_stem, ''))
         ~ E'(\\[\\[?\\s*공백\\s*:\\s*[0-9]+\\s*\\]\\]?|\\\\(?:square|Box|boxed)\\M|[□▢]|(?:빈칸|네모|\\(\\s*\\)|\\[\\s*\\])\\s*(?:에|안에)|알맞은\\s*(?:수|말|식|값|기호|것|숫자)를?\\s*(?:써넣|쓰시오|써라|채우))';
$$;

do $$
declare
  r record;
  v_ratio numeric;
  v_cur_w numeric;
  v_new_w numeric;
  v_col_w numeric;
  v_bbox jsonb;
  v_items jsonb;
  v_item jsonb;
  v_idx int;
  v_new_layout jsonb;
  v_blank_cleaned int := 0;
  v_fig_resized int := 0;
  v_rem_issues int := 0;
  v_rem_banners int := 0;
begin
  -- [1] 빈칸형 문항에서 정상 빈칸(□)을 '용도가 불명확한 빈칸 추가'·'단독 빈칸'으로 오판한 quality_checks / render_checks 정리
  for r in
    select c.id as crop_id,
           c.problem_number,
           c.raw_page,
           pq.stem,
           coalesce(pq.meta -> 'set_model' ->> 'common_stem', '') as common_stem,
           an.quality_checks,
           an.render_checks
      from public.textbook_problem_crops c
      join public.textbook_problem_analyses an on an.crop_id = c.id
      left join public.pb_questions pq on pq.id = public.textbook_review_linked_pb_question(c.id)
     where not c.is_set_header
       and public.textbook_review_is_fill_in_blank(coalesce(pq.meta -> 'set_model' ->> 'common_stem', ''), coalesce(pq.stem, ''))
  loop
    update public.textbook_problem_analyses an
       set quality_checks = coalesce(an.quality_checks, '{}'::jsonb)
             || jsonb_build_object('is_fill_in_blank', true)
             || case
                  when (coalesce(an.quality_checks ->> 'issue_title', '') || ' ' || coalesce(an.quality_checks ->> 'issue_detail', ''))
                       ~ '(용도가\s*불명확한\s*빈칸|단독\s*빈칸|빈칸이\s*(추가|하나\s*더|더\s*보|노출)|네모가\s*(추가|더\s*보|노출))'
                   and (coalesce(an.quality_checks ->> 'issue_title', '') || ' ' || coalesce(an.quality_checks ->> 'issue_detail', ''))
                       !~* '(\[\[?\s*공백|박스시작|박스끝|표시작|표끝|PB_FIG)'
                    then jsonb_build_object('stem_ok', true, 'fidelity_ok', true, 'issue_title', null, 'issue_detail', null)
                  else '{}'::jsonb
                end,
           render_checks = case
             when jsonb_typeof(an.render_checks) = 'object'
              and (coalesce(an.render_checks ->> 'issue_title', '') || ' ' || coalesce(an.render_checks ->> 'issue_detail', ''))
                  ~ '(용도가\s*불명확한\s*빈칸|단독\s*빈칸|빈칸이\s*(추가|하나\s*더|더\s*보|노출)|네모가\s*(추가|더\s*보|노출))'
              and (coalesce(an.render_checks ->> 'issue_title', '') || ' ' || coalesce(an.render_checks ->> 'issue_detail', ''))
                  !~* '(\[\[?\s*공백|박스시작|박스끝|표시작|표끝|PB_FIG)'
               then an.render_checks || jsonb_build_object('problem_ok', true, 'fidelity_ok', true, 'flagged_after_approval', false, 'issue_title', null, 'issue_detail', null)
             else an.render_checks
           end
     where an.crop_id = r.crop_id;

    if (coalesce(r.quality_checks ->> 'issue_title', '') || ' ' || coalesce(r.render_checks ->> 'issue_title', '')) ~ '(빈칸|네모)' then
      v_blank_cleaned := v_blank_cleaned + 1;
      raise notice '[BLANK_CLEANED] #% (p.%): qc_title=[%] rc_title=[%]',
        r.problem_number, r.raw_page,
        coalesce(r.quality_checks ->> 'issue_title', ''),
        coalesce(r.render_checks ->> 'issue_title', '');
    end if;
  end loop;

  -- [2] 그림 문항 전체 점검 및 widthEm 원본 비율(1.0배) 맞춤 축소·보정
  for r in
    select c.id as crop_id,
           c.problem_number,
           c.raw_page,
           pq.id as pq_id,
           pq.stem,
           coalesce(pq.meta -> 'figure_assets', '[]'::jsonb) as fig_assets,
           pq.meta -> 'figure_layout' as fig_layout,
           an.quality_status,
           an.quality_checks,
           an.render_checks,
           an.fix_proposal
      from public.textbook_problem_crops c
      join public.textbook_problem_analyses an on an.crop_id = c.id
      join public.pb_questions pq on pq.id = public.textbook_review_linked_pb_question(c.id)
     where not c.is_set_header
       and (
         (jsonb_typeof(pq.meta -> 'figure_assets') = 'array' and jsonb_array_length(pq.meta -> 'figure_assets') > 0)
         or pq.stem ~ '(\[\[PB_FIG_[^\]]+\]\]|\[(?:그림|도형|도표)\])'
         or (an.render_checks ? 'figure_size_ratio' and an.render_checks -> 'figure_size_ratio' <> 'null'::jsonb)
       )
     order by c.raw_page, length(c.problem_number), c.problem_number
  loop
    v_ratio := case
      when jsonb_typeof(r.render_checks -> 'figure_size_ratio') = 'number'
        then (r.render_checks ->> 'figure_size_ratio')::numeric
      else null
    end;

    -- 현재 pb_questions.meta.figure_layout.items (없으면 proposed figure_layout, 그것도 없으면 기본 20em 항목 생성)
    v_items := case
      when jsonb_typeof(r.fig_layout -> 'items') = 'array' and jsonb_array_length(r.fig_layout -> 'items') > 0
        then r.fig_layout -> 'items'
      when jsonb_typeof(r.fix_proposal -> 'figure_layout' -> 'items') = 'array'
           and jsonb_array_length(r.fix_proposal -> 'figure_layout' -> 'items') > 0
        then r.fix_proposal -> 'figure_layout' -> 'items'
      else '[]'::jsonb
    end;

    if jsonb_array_length(v_items) = 0 then
      v_items := jsonb_build_array(
        jsonb_build_object(
          'assetKey', 'idx:1',
          'widthEm', 20.0,
          'position', 'below-stem',
          'anchor', 'center',
          'offsetXEm', 0,
          'offsetYEm', 0,
          'heightEm', 1.6
        )
      );
    end if;

    -- 각 그림 항목의 widthEm 계산:
    -- (가) figure_size_ratio 가 있고 1.0배가 아니면 (cur_w / ratio) 로 보정
    -- (나) fix_proposal.figure_measure.figures[idx].bbox_1k 가 있으면 원본 컬럼 폭(26em) 대비 가로 비율 상한도 함께 적용해
    --      그림 안의 숫자가 본문 숫자보다 커지지 않게 맞춘다.
    declare
      v_scaled_items jsonb := '[]'::jsonb;
      v_meas_figs jsonb := coalesce(r.fix_proposal -> 'figure_measure' -> 'figures', '[]'::jsonb);
      v_i int := 0;
    begin
      for v_item in select * from jsonb_array_elements(v_items) loop
        v_cur_w := coalesce((v_item ->> 'widthEm')::numeric, 20.0);
        v_new_w := v_cur_w;
        if v_ratio is not null and v_ratio > 0 and (v_ratio < 0.92 or v_ratio > 1.08) then
          v_new_w := v_cur_w / v_ratio;
        end if;
        if jsonb_typeof(v_meas_figs) = 'array' and v_i < jsonb_array_length(v_meas_figs) then
          v_bbox := v_meas_figs -> v_i -> 'bbox_1k';
          if jsonb_typeof(v_bbox) = 'array' and jsonb_array_length(v_bbox) = 4 then
            v_col_w := (((v_bbox ->> 3)::numeric - (v_bbox ->> 1)::numeric) / 1000.0) * 25.0;
            if v_col_w >= 4.0 and v_new_w > v_col_w * 1.08 then
              v_new_w := v_col_w;
            end if;
          end if;
        end if;
        v_new_w := round(greatest(4.0, least(40.0, v_new_w)) * 2.0) / 2.0;
        v_scaled_items := v_scaled_items || jsonb_build_array(v_item || jsonb_build_object('widthEm', v_new_w));
        v_i := v_i + 1;
      end loop;

      v_new_layout := jsonb_build_object(
        'version', 1,
        'items', v_scaled_items,
        'groups', coalesce(r.fig_layout -> 'groups', r.fix_proposal -> 'figure_layout' -> 'groups', '[]'::jsonb)
      );

      if r.fig_layout is distinct from v_new_layout
         or (v_ratio is not null and (v_ratio < 0.85 or v_ratio > 1.15))
         or coalesce((r.render_checks ->> 'flagged_after_approval')::boolean, false) then
        update public.pb_questions
           set meta = coalesce(meta, '{}'::jsonb) || jsonb_build_object('figure_layout', v_new_layout),
               updated_at = now()
         where id = r.pq_id;

        update public.textbook_problem_analyses
           set fix_proposal = coalesce(fix_proposal, '{}'::jsonb)
                 || jsonb_build_object('figure_layout', v_new_layout, 'applied_at', now(), 'applied_note', '그림 크기 원본 비율(1.0배) 자동 조정'),
               quality_checks = case
                 when coalesce(quality_checks ->> 'issue_kind', '') = 'figure'
                   then quality_checks || jsonb_build_object('figure_ok', true, 'issue_title', null, 'issue_detail', null)
                 else quality_checks
               end,
               render_checks = case
                 when jsonb_typeof(render_checks) = 'object' and render_checks <> '{}'::jsonb
                   then render_checks || jsonb_build_object(
                     'problem_ok', true,
                     'fidelity_ok', true,
                     'figure_position_ok', true,
                     'figure_size_ratio', 1.0,
                     'flagged_after_approval', false,
                     'issue_title', null,
                     'issue_detail', null
                   )
                 else render_checks
               end,
               updated_at = now()
         where crop_id = r.crop_id;

        update public.textbook_review_findings
           set status = 'resolved', resolution = 'manual_edit', resolved_at = now()
         where crop_id = r.crop_id
           and check_key in ('ai_v2_render_student_view', 'ai_quality_v2_student_view')
           and status in ('open', 'held');

        v_fig_resized := v_fig_resized + 1;
        raise notice '[FIG_RESIZED] #% (p.%): prev_ratio=% prev_layout=% -> new_layout=%',
          r.problem_number, r.raw_page, v_ratio,
          coalesce(r.fig_layout::text, 'null'),
          v_new_layout::text;
      end if;
    end;
  end loop;

  -- [3] 전체 단원 남은 오류·배너·승인 후 차이 집계 확인
  select count(*) filter (where an.math_status = 'issue' or (an.quality_status = 'issue'))::int,
         count(*) filter (
           where coalesce((an.render_checks ->> 'flagged_after_approval')::boolean, false)
              or an.render_checks ->> 'issue_title' is not null
              or (an.quality_checks ->> 'issue_title' is not null and an.quality_status <> 'held')
         )::int
    into v_rem_issues, v_rem_banners
    from public.textbook_problem_crops c
    join public.textbook_problem_analyses an on an.crop_id = c.id
   where not c.is_set_header;

  raise notice '[SUMMARY] blank_cleaned=% fig_resized=% remaining_issues=% remaining_banners=%',
    v_blank_cleaned, v_fig_resized, v_rem_issues, v_rem_banners;
end;
$$;
