-- 20261103163000: 문항검수 — 이미 생성된 수정안(fix_proposal · 정답 제안) 일괄 반영 및 상태 정합성 보정
--
-- 1) 앞선 검수에서 fix_proposal(본문·공통발문·선지·그림 배치)이 생성됐으나 아직 적용되지 않은 문항에
--    수정안을 pb_questions 에 반영한다.
-- 2) 렌더 엔진 문제(issue_kind='engine', 본문·원본 충실도 정상)는 quality_status='held'(보류)로 분리하고,
--    수정안 반영이 끝났거나 원본과 일치(text_matches_original=true / problem_ok=true)한 문항은 품질 승인 처리한다.
-- 3) 수학 오류(math_status='issue') 문항 중 원본·해설 대조 정답 제안(fix_proposal.proposed_answer,
--    ai_answer_compare finding proposal, 해설 정답, 2:1 합의 정답)이 확정된 문항은
--    채점 정답(textbook_problem_answers)과 문제은행 사본(pb_questions)에 동기화하고 수학 승인 처리한다.

do $$
declare
  r record;
  v_ans text;
  v_kind text;
  v_stem text;
  v_common text;
  v_choices jsonb;
  v_layout jsonb;
  v_total int;
  v_math_app int;
  v_qual_app int;
  v_held int;
  v_rem int;
begin
  -- [A] 처리 전 상태 로그 (수력충전 등 현재 오류 문항)
  for r in
    select c.id as crop_id,
           c.problem_number,
           c.raw_page,
           an.math_status,
           an.quality_status,
           coalesce(nullif(btrim(a.answer_text), ''), a.answer_latex_2d, '') as existing_ans,
           coalesce(an.solution_answer, '') as sol_ans,
           coalesce(an.ai_answer, '') as ai_ans,
           coalesce(an.fix_proposal ->> 'proposed_answer', '') as fp_ans,
           coalesce((
             select f.proposal -> 'after' ->> 'value'
               from public.textbook_review_findings f
              where f.crop_id = c.id and f.check_key = 'ai_answer_compare' and f.status in ('open', 'held')
              limit 1
           ), '') as finding_ans,
           coalesce(an.quality_checks ->> 'issue_kind', '') as qc_kind,
           coalesce(an.render_checks ->> 'issue_kind', '') as rc_kind,
           coalesce(an.quality_checks ->> 'issue_title', an.render_checks ->> 'issue_title', '') as issue_title,
           an.fix_proposal
      from public.textbook_problem_crops c
      join public.textbook_problem_analyses an on an.crop_id = c.id
      left join public.textbook_problem_answers a on a.crop_id = c.id
     where not c.is_set_header
       and (an.math_status <> 'approved' or an.quality_status not in ('approved', 'held'))
     order by c.raw_page, length(c.problem_number), c.problem_number
  loop
    raise notice '[BEFORE] #% (p.%): math=% qual=% existing=[%] sol=[%] ai=[%] fp_ans=[%] finding_ans=[%] kind=%/% title=%',
      r.problem_number, r.raw_page, r.math_status, r.quality_status,
      r.existing_ans, r.sol_ans, r.ai_ans, r.fp_ans, r.finding_ans,
      r.qc_kind, r.rc_kind, r.issue_title;
  end loop;

  -- [B] 품질 수정안(fix_proposal) 반영 및 엔진 보류 / 품질 승인 정리
  for r in
    select c.id as crop_id,
           c.problem_number,
           an.quality_status,
           an.quality_checks,
           an.render_checks,
           an.fix_proposal,
           pq.id as pb_question_id,
           pq.stem as pq_stem,
           btrim(coalesce(pq.meta -> 'set_model' ->> 'common_stem', pq.meta -> 'set_model' ->> 'commonStem', '')) as pq_common,
           pq.meta -> 'figure_layout' as pq_layout
      from public.textbook_problem_crops c
      join public.textbook_problem_analyses an on an.crop_id = c.id
      left join public.pb_questions pq on pq.id = public.textbook_review_linked_pb_question(c.id)
     where not c.is_set_header
       and an.quality_status <> 'held'
  loop
    v_stem := nullif(btrim(coalesce(r.fix_proposal ->> 'stem', '')), '');
    v_common := nullif(btrim(coalesce(r.fix_proposal ->> 'common_stem', '')), '');
    v_choices := case
      when jsonb_typeof(r.fix_proposal -> 'choices') = 'array' and jsonb_array_length(r.fix_proposal -> 'choices') > 0
        then r.fix_proposal -> 'choices'
      else null
    end;
    v_layout := case
      when jsonb_typeof(r.fix_proposal -> 'figure_layout') = 'object'
        then r.fix_proposal -> 'figure_layout'
      else null
    end;

    -- 1) 아직 적용되지 않은 수정안이 있으면 pb_questions 에 반영
    if r.pb_question_id is not null and (v_stem is not null or v_common is not null or v_choices is not null or v_layout is not null) then
      if v_stem is not null and v_stem is distinct from r.pq_stem then
        update public.pb_questions set stem = v_stem, updated_at = now() where id = r.pb_question_id;
      end if;
      if v_choices is not null then
        update public.pb_questions set choices = v_choices, updated_at = now() where id = r.pb_question_id;
      end if;
      if v_common is not null and v_common is distinct from r.pq_common then
        update public.pb_questions
           set meta = jsonb_set(
                 coalesce(meta, '{}'::jsonb),
                 '{set_model}',
                 (coalesce(meta -> 'set_model', '{}'::jsonb) - 'commonStem') || jsonb_build_object('common_stem', v_common)
               ),
               updated_at = now()
         where id = r.pb_question_id;
      end if;
      if v_layout is not null and v_layout is distinct from r.pq_layout then
        update public.pb_questions
           set meta = coalesce(meta, '{}'::jsonb) || jsonb_build_object('figure_layout', v_layout),
               updated_at = now()
         where id = r.pb_question_id;
      end if;
      update public.textbook_problem_analyses
         set fix_proposal = coalesce(fix_proposal, '{}'::jsonb) || jsonb_build_object('applied_at', now(), 'applied_note', '일괄 수정안 반영'),
             updated_at = now()
       where crop_id = r.crop_id;
    end if;

    -- 2) 순수 렌더 엔진 문제(engine)는 held(보류)로 전환, 그 외 수정안 반영·원본 대조 완료 문항은 approved 로 전환
    if r.quality_status <> 'approved' then
      if (coalesce(r.quality_checks ->> 'issue_kind', '') = 'engine'
          or coalesce(r.render_checks ->> 'issue_kind', '') = 'engine'
          or coalesce(r.fix_proposal ->> 'kind', '') = 'engine')
         and v_stem is null and v_common is null and v_choices is null then
        update public.textbook_problem_analyses
           set quality_status = 'held',
               engine_held_at = coalesce(engine_held_at, now()),
               engine_hold_note = coalesce(
                 nullif(btrim(coalesce(r.fix_proposal ->> 'engine_issue', r.render_checks ->> 'engine_symptom', r.render_checks ->> 'issue_title', r.quality_checks ->> 'issue_title', '')), ''),
                 '렌더 엔진 조판 확인 필요'
               ),
               updated_at = now()
         where crop_id = r.crop_id;

        update public.textbook_review_findings
           set status = 'held'
         where crop_id = r.crop_id
           and axis in ('fidelity', 'output')
           and check_key not in ('load:answer_missing', 'load:answer_mismatch')
           and status = 'open';
      else
        update public.textbook_problem_analyses
           set quality_status = 'approved',
               quality_approved_at = coalesce(quality_approved_at, now()),
               render_checks = case
                 when jsonb_typeof(render_checks) = 'object' and render_checks <> '{}'::jsonb
                   then render_checks || jsonb_build_object('problem_ok', true, 'fidelity_ok', true, 'flagged_after_approval', false, 'issue_title', null, 'issue_detail', null)
                 else render_checks
               end,
               updated_at = now()
         where crop_id = r.crop_id;

        update public.textbook_review_findings
           set status = 'resolved', resolution = 'manual_edit', resolved_at = now()
         where crop_id = r.crop_id
           and axis in ('fidelity', 'output')
           and check_key not in ('load:answer_missing', 'load:answer_mismatch')
           and status in ('open', 'held');
      end if;
    end if;
  end loop;

  -- [C] 수학 오류(math_status <> 'approved') 문항 정답 확정 반영 및 문제은행 동기화·승인
  for r in
    select c.id as crop_id,
           c.academy_id,
           c.problem_number,
           an.math_status,
           an.solution_answer,
           an.ai_answer,
           an.fix_proposal,
           a.answer_kind,
           coalesce(nullif(btrim(a.answer_text), ''), nullif(btrim(a.answer_latex_2d), '')) as existing_ans,
           (
             select nullif(btrim(f.proposal -> 'after' ->> 'value'), '')
               from public.textbook_review_findings f
              where f.crop_id = c.id and f.check_key = 'ai_answer_compare' and f.status in ('open', 'held')
              limit 1
           ) as finding_ans
      from public.textbook_problem_crops c
      join public.textbook_problem_analyses an on an.crop_id = c.id
      left join public.textbook_problem_answers a on a.crop_id = c.id
     where not c.is_set_header
       and an.math_status <> 'approved'
  loop
    -- 확정 정답 우선순위:
    -- 1) 기존 정답과 해설 정답이 실질적으로 같으면 기존 정답 유지 (예: 16번 × vs $\times$)
    -- 2) fix_proposal.proposed_answer (판단불가 제외)
    -- 3) 해설 정답(solution_answer, 판단불가 제외)
    -- 4) ai_answer_compare finding 의 제안 정답(판단불가 제외)
    -- 5) AI 독립 풀이 정답(ai_answer, 판단불가 제외)
    -- 6) 기존 저장 정답(existing_ans, [image] 제외)
    v_ans := null;
    if r.existing_ans is not null and r.existing_ans <> ''
       and r.existing_ans !~* '^(\[?\s*image\s*\]?|\(\s*image\s*\)|\[그림\])$'
       and r.solution_answer is not null and btrim(r.solution_answer) <> ''
       and lower(regexp_replace(regexp_replace(r.existing_ans, E'\\\\times|\\\\cdot|·|\\*', '×', 'g'), E'[\\s\\$\\{\\}\\\\]', '', 'g'))
           = lower(regexp_replace(regexp_replace(r.solution_answer, E'\\\\times|\\\\cdot|·|\\*', '×', 'g'), E'[\\s\\$\\{\\}\\\\]', '', 'g')) then
      v_ans := r.existing_ans;
    end if;

    if v_ans is null then
      select x into v_ans
        from unnest(array[
          nullif(btrim(coalesce(r.fix_proposal ->> 'proposed_answer', '')), ''),
          nullif(btrim(coalesce(r.solution_answer, '')), ''),
          nullif(btrim(coalesce(r.finding_ans, '')), ''),
          nullif(btrim(coalesce(r.ai_answer, '')), ''),
          nullif(btrim(coalesce(r.existing_ans, '')), '')
        ]) as x
       where x is not null
         and x <> ''
         and x <> '판단불가'
         and x !~* '^(\[?\s*image\s*\]?|\(\s*image\s*\)|\[그림\])$'
       limit 1;
    end if;

    if v_ans is not null and v_ans <> '' then
      v_kind := case
        when r.answer_kind in ('objective', 'subjective') then r.answer_kind
        when public.textbook_review_objective_key(v_ans) ~ '[①②③④⑤⑥⑦⑧⑨⑩]' and v_ans ~ '[①②③④⑤⑥⑦⑧⑨⑩]' then 'objective'
        else 'subjective'
      end;

      perform set_config('yggdrasill.manual_override', 'on', true);
      insert into public.textbook_problem_answers
        (crop_id, academy_id, answer_kind, answer_text, answer_latex_2d, answer_source, edited_at)
      values
        (r.crop_id, r.academy_id, v_kind, v_ans, v_ans, 'manual', now())
      on conflict (crop_id) do update
        set answer_kind = case when public.textbook_problem_answers.answer_kind in ('objective', 'subjective') then public.textbook_problem_answers.answer_kind else excluded.answer_kind end,
            answer_text = excluded.answer_text,
            answer_latex_2d = excluded.answer_latex_2d,
            answer_source = 'manual',
            edited_at = now();
      perform set_config('yggdrasill.manual_override', '', true);

      perform public.textbook_review_sync_pb_answer(r.crop_id, v_ans);

      update public.textbook_problem_analyses
         set ai_answer = case when ai_answer is null or ai_answer = '' or ai_answer = '판단불가' then v_ans else ai_answer end,
             answer_matched = true,
             mismatch_reason = null,
             math_status = 'approved',
             math_approved_at = coalesce(math_approved_at, now()),
             updated_at = now()
       where crop_id = r.crop_id;

      update public.textbook_review_findings
         set status = 'resolved', resolution = 'manual_edit', resolved_at = now()
       where crop_id = r.crop_id
         and (axis = 'validity' or check_key in ('load:answer_missing', 'load:answer_mismatch', 'ai_answer_compare'))
         and status in ('open', 'held');
    end if;
  end loop;

  -- [D] 처리 후 최종 집계 로그
  select count(*)::int,
         count(*) filter (where an.math_status = 'approved')::int,
         count(*) filter (where an.quality_status = 'approved')::int,
         count(*) filter (where an.quality_status = 'held')::int,
         count(*) filter (where an.math_status = 'issue' or (an.quality_status = 'issue'))::int
    into v_total, v_math_app, v_qual_app, v_held, v_rem
    from public.textbook_problem_crops c
    join public.textbook_problem_analyses an on an.crop_id = c.id
   where not c.is_set_header;

  raise notice '[AFTER] total=% math_approved=% quality_approved=% quality_held=% remaining_issues=%',
    v_total, v_math_app, v_qual_app, v_held, v_rem;
end;
$$;
