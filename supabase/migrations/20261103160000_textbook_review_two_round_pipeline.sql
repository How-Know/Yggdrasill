-- 20261103160000: 문항검수 2회차 파이프라인 완성
--
-- 1) 원본 해설 전사 텍스트 정제 함수(textbook_review_clean_solution_text):
--    [해설]·[풀이] 머리말과 '16 답 ×'·'[정답] ③' 같은 정답 줄 이중 추출을 제거하고 기존 전사본도 일괄 정제한다.
-- 2) 문제은행 정답 동기화(textbook_review_sync_pb_answer):
--    pb_questions 의 objective_answer_key/subjective_answer 뿐 아니라 meta(answer_key, subjective_answer, objective_answer_key)도
--    함께 맞추고, 열린 load:answer_missing / load:answer_mismatch / ai_answer_compare 소견을 자동으로 닫는다.
-- 3) 단건 저장(textbook_review_save_item_edit) · 축 일괄 승인(textbook_review_approve_axis):
--    p_ai_answer 갱신을 지원하고, 수학 승인 시 항상 문제은행 정답을 동기화하며 열린 수학·적재 정답 소견을 함께 닫는다.
--    품질 승인 시 열린 품질 소견(fidelity/output)을 모두 닫아, 승인된 문항이 소견 때문에 오류·불일치 탭에 남지 않게 한다.
-- 4) 본문·공통발문 수정 적용(textbook_review_apply_problem_fix):
--    세트 공통 발문을 바꿀 때 형제 문항들의 개별 발문 앞머리에 중복된 지시문(또는 이전 오염된 공통 발문 조각)도 함께 정리한다.
-- 5) 기존 데이터 복구:
--    - 앞선 규칙 버그로 공통 발문이 숫자·수식 조각('36', '36=2^2×3^2' 등)으로 잘린 세트 문항들을
--      수정 이력(pb_question_revisions)·형제 문항 본문에서 원래 지시문 문단을 찾아 복구한다.
--    - 그림이 있는 문항(figure_assets 또는 [그림] 마커) 중 아직 수정안이 반영되지 않은 문항은
--      원칙(이미지 문항은 무조건 품질 문제로 취급해 원본 대조 후 수정안 제시·반영)에 따라 quality_status='issue' 로 맞춘다.

create or replace function public.textbook_review_looks_like_instruction(p_text text)
returns boolean
language sql
immutable
as $$
  select length(btrim(coalesce(p_text, ''))) >= 4
     and btrim(coalesce(p_text, '')) ~ '((다음|아래|보기|위|오른쪽|왼쪽)|(구하|쓰|써넣|채우|고르|찾|연결|나타내|계산|비교|완성|판단|말하|답하|표시|그리|그려|풀어|인수분해|소인수분해|약분|통분|정리)(여라|시오|라|자|기|고)|\?)';
$$;

create or replace function public.textbook_review_clean_solution_text(
  p_text text,
  p_problem_number text default '',
  p_answer text default ''
)
returns text
language plpgsql
immutable
as $$
declare
  s text := regexp_replace(coalesce(p_text, ''), E'\\r\\n', E'\n', 'g');
  v_num text := regexp_replace( regexp_replace(coalesce(p_problem_number, ''), '[^0-9]', '', 'g'), '^0+', '' );
  v_ans_norm text := lower(regexp_replace(
    regexp_replace(
      regexp_replace(coalesce(p_answer, ''), E'\\\\left|\\\\right', '', 'g'),
      E'\\\\times|\\\\cdot|·|\\*', '×', 'g'
    ),
    E'[\\s\\$\\{\\}\\\\]', '', 'g'
  ));
  v_first text;
  v_rest text;
  v_pos int;
  v_prev text;
  v_inline text;
  v_pass int;
begin
  s := btrim(s);
  if s = '' then return ''; end if;

  for v_pass in 1..6 loop
    exit when s = '';
    v_prev := s;
    s := regexp_replace(s, E'^(?:\\s|\\[문단\\])+', '');
    s := regexp_replace(s, E'^(?:\\[\\s*(?:해설|풀이|정답과\\s*해설|정답\\s*및\\s*해설)\\s*\\]|<\\s*(?:해설|풀이)\\s*>|(?:해설|풀이)\\s*[:：])\\s*', '', 'i');
    s := regexp_replace(s, E'^(?:해설|풀이)\\s*(?:\\n|\\[문단\\])+', '');
    s := regexp_replace(s, E'^(?:\\s|\\[문단\\])+', '');

    v_pos := coalesce(nullif(strpos(s, E'\n'), 0), nullif(strpos(s, '[문단]'), 0), 0);
    if v_pos > 0 then
      v_first := btrim(left(s, v_pos - 1));
      v_rest := regexp_replace(substr(s, v_pos), E'^(?:\\s|\\[문단\\])+', '');
    else
      v_first := btrim(s);
      v_rest := '';
    end if;

    if v_first !~ '^(?:답|정답)(?:[은는이가을를도만]|(?:\s*없음))' then
      if v_first ~* E'^(?:0*[0-9]{1,3}(?:\\s*번|\\.|\\))?\\s*(?:\\[\\s*(?:답|정답)\\s*\\]|(?:답|정답))(?![은는이가을를도만])(?:\\s*[:：]?\\s*\\S.*|$)|\\[\\s*(?:답|정답)\\s*\\]\\s*[:：]?\\s*\\S.*|(?:답|정답)\\s*[:：]\\s*\\S.*)'
         or (v_first ~ E'^(?:답|정답)\\s+\\S.*$' and v_rest <> '') then
        v_inline := substring(v_first from E'(?:\\[\\s*(?:해설|풀이)\\s*\\]|(?:해설|풀이)\\s*[:：])\\s*(.+)$');
        if v_inline is not null and btrim(v_inline) <> '' then
          s := case when v_rest <> '' then btrim(v_inline) || E'\n' || v_rest else btrim(v_inline) end;
        else
          s := v_rest;
        end if;
        continue;
      end if;
    end if;

    if v_num <> '' and v_ans_norm <> '' and v_first ~ ('^0*' || v_num || E'(?:\\s*번|\\.|\\))?\\s+.+$') then
      if lower(regexp_replace(
           regexp_replace(
             regexp_replace(regexp_replace(v_first, '^0*' || v_num || E'(?:\\s*번|\\.|\\))?\\s+', ''), E'\\\\left|\\\\right', '', 'g'),
             E'\\\\times|\\\\cdot|·|\\*', '×', 'g'
           ),
           E'[\\s\\$\\{\\}\\\\]', '', 'g'
         )) = v_ans_norm then
        s := v_rest;
        continue;
      end if;
    end if;

    exit when s = v_prev;
  end loop;

  s := regexp_replace(s, E'(?:^|\\n|\\[문단\\])\\s*\\[\\s*(?:해설|풀이)\\s*\\]\\s*(?=\\n|\\[문단\\]|$)', E'\n', 'g');
  s := regexp_replace(s, E'^\\s*\\[\\s*(?:해설|풀이)\\s*\\]\\s*', '');
  s := regexp_replace(s, E'^(?:\\s|\\[문단\\])+', '');
  s := regexp_replace(s, E'(?:\\s|\\[문단\\])+$', '');
  return btrim(s);
end;
$$;

-- ── 문제은행 사본 정답 동기화 (내부용) ──
create or replace function public.textbook_review_sync_pb_answer(p_crop_id uuid, p_answer text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pq public.pb_questions;
  v_ans text := btrim(coalesce(p_answer, ''));
  v_key text;
  v_subj text;
  v_changed text[] := '{}';
  v_meta jsonb;
begin
  if v_ans = '' then return jsonb_build_object('synced', false, 'reason', 'empty'); end if;
  select * into v_pq from public.pb_questions where id = public.textbook_review_linked_pb_question(p_crop_id);
  if not found then
    update public.textbook_review_findings
       set status = 'resolved', resolution = 'auto_cleared', resolved_at = now()
     where crop_id = p_crop_id
       and check_key in ('load:answer_missing', 'load:answer_mismatch')
       and status in ('open', 'held');
    return jsonb_build_object('synced', false, 'reason', 'no_pb_question');
  end if;

  v_key := public.textbook_review_objective_key(v_ans);

  if v_pq.allow_objective and v_key <> '' and v_pq.objective_answer_key is distinct from v_key then
    v_changed := array_append(v_changed, 'objective_answer_key'::text);
  end if;

  if v_pq.allow_subjective or not v_pq.allow_objective then
    if v_key <> '' and jsonb_typeof(v_pq.choices) = 'array' and jsonb_array_length(v_pq.choices) > 0 then
      select string_agg(btrim(c ->> 'text'), ', ' order by o.ord)
        into v_subj
        from unnest(string_to_array(v_key, ', ')) with ordinality as o(label, ord)
        join jsonb_array_elements(v_pq.choices) as c on btrim(c ->> 'label') = o.label;
      v_subj := coalesce(nullif(v_subj, ''), v_ans);
    else
      v_subj := v_ans;
    end if;
    if v_pq.subjective_answer is distinct from v_subj then
      v_changed := array_append(v_changed, 'subjective_answer'::text);
    end if;
  end if;

  v_meta := coalesce(v_pq.meta, '{}'::jsonb) || jsonb_build_object(
    'answer_key', coalesce(v_subj, v_key, v_ans),
    'subjective_answer', coalesce(v_subj, v_pq.subjective_answer, ''),
    'objective_answer_key', case when 'objective_answer_key' = any (v_changed) then v_key else coalesce(v_pq.objective_answer_key, '') end
  );

  if cardinality(v_changed) > 0 or v_pq.meta is distinct from v_meta then
    update public.pb_questions
       set objective_answer_key = case when 'objective_answer_key' = any (v_changed) then v_key else objective_answer_key end,
           subjective_answer = case when 'subjective_answer' = any (v_changed) then v_subj else subjective_answer end,
           meta = v_meta,
           updated_at = now()
     where id = v_pq.id;
  end if;

  update public.textbook_review_findings
     set status = 'resolved', resolution = 'auto_cleared', resolved_at = now()
   where crop_id = p_crop_id
     and check_key in ('load:answer_missing', 'load:answer_mismatch')
     and status in ('open', 'held');

  return jsonb_build_object('synced', true, 'pb_question_id', v_pq.id, 'changed', to_jsonb(v_changed));
end;
$$;

revoke all on function public.textbook_review_sync_pb_answer(uuid, text) from public, anon, authenticated;

-- ── 단건 저장 + 승인 (p_ai_answer 지원 및 소견 자동 정리) ──
drop function if exists public.textbook_review_save_item_edit(uuid, text, text, text[], boolean, boolean, text, text, jsonb, boolean);
drop function if exists public.textbook_review_save_item_edit(uuid, text, text, text[], boolean, boolean, text, text, jsonb, boolean, text);

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
  p_sync_pb_answer boolean default true,
  p_ai_answer text default null
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
  v_clean_sol text;
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
  elsif p_approve_math then
    select coalesce(nullif(btrim(a.answer_text), ''), nullif(btrim(a.answer_latex_2d), ''))
      into v_ans
      from public.textbook_problem_answers a
     where a.crop_id = p_crop_id;
    if v_ans is null or v_ans = '' or v_ans ~* '^(\[?\s*image\s*\]?|\(\s*image\s*\)|\[그림\])$' then
      select coalesce(
               nullif(btrim(an.fix_proposal ->> 'proposed_answer'), ''),
               nullif(btrim(an.solution_answer), ''),
               nullif(btrim(an.ai_answer), '')
             )
        into v_ans
        from public.textbook_problem_analyses an
       where an.crop_id = p_crop_id;
    end if;
  end if;

  if v_ans is not null and btrim(v_ans) <> '' and v_ans <> '판단불가' then
    v_ans := btrim(v_ans);
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
      set answer_kind = case when public.textbook_problem_answers.answer_kind in ('objective', 'subjective') then public.textbook_problem_answers.answer_kind else excluded.answer_kind end,
          answer_text = excluded.answer_text,
          answer_latex_2d = excluded.answer_latex_2d,
          answer_source = 'manual',
          edited_at = now();
    perform set_config('yggdrasill.manual_override', '', true);
    if p_sync_pb_answer then
      v_sync := public.textbook_review_sync_pb_answer(p_crop_id, v_ans);
    end if;
  end if;

  v_clean_sol := case
    when p_solution_transcribed is null then null
    else nullif(public.textbook_review_clean_solution_text(p_solution_transcribed, v_crop.problem_number, coalesce(p_solution_answer, v_ans, '')), '')
  end;

  insert into public.textbook_problem_analyses (crop_id, academy_id, ai_solution, ai_answer, visual_tags, solution_transcribed, solution_answer, solution_source, alternative_solutions)
  values (
    v_crop.id, v_crop.academy_id, p_ai_solution, nullif(btrim(coalesce(p_ai_answer, '')), ''), coalesce(p_visual_tags, '{}'::text[]),
    v_clean_sol,
    nullif(btrim(coalesce(p_solution_answer, '')), ''),
    case when v_clean_sol is not null then 'manual' end,
    coalesce(v_alt, '[]'::jsonb)
  )
  on conflict (crop_id) do update
    set ai_solution = coalesce(nullif(btrim(coalesce(p_ai_solution, '')), ''), public.textbook_problem_analyses.ai_solution),
        ai_answer = coalesce(nullif(btrim(coalesce(p_ai_answer, '')), ''), public.textbook_problem_analyses.ai_answer),
        visual_tags = coalesce(p_visual_tags, public.textbook_problem_analyses.visual_tags),
        solution_transcribed = case
          when p_solution_transcribed is null then public.textbook_problem_analyses.solution_transcribed
          else v_clean_sol
        end,
        solution_answer = case
          when p_solution_answer is null then public.textbook_problem_analyses.solution_answer
          else nullif(btrim(p_solution_answer), '')
        end,
        solution_source = case
          when p_solution_transcribed is null then public.textbook_problem_analyses.solution_source
          when v_clean_sol is null then null
          when public.textbook_problem_analyses.solution_transcribed is distinct from v_clean_sol then 'manual'
          else coalesce(public.textbook_problem_analyses.solution_source, 'manual')
        end,
        alternative_solutions = coalesce(v_alt, public.textbook_problem_analyses.alternative_solutions),
        answer_matched = case when p_approve_math then true else public.textbook_problem_analyses.answer_matched end,
        mismatch_reason = case when p_approve_math then null else public.textbook_problem_analyses.mismatch_reason end,
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
     where crop_id = p_crop_id
       and (axis = 'validity' or check_key in ('load:answer_missing', 'load:answer_mismatch', 'ai_answer_compare'))
       and status in ('open', 'held');
  end if;
  if p_approve_quality then
    update public.textbook_review_findings
       set status = 'resolved', resolution = 'manual_edit', resolved_at = now()
     where crop_id = p_crop_id
       and axis in ('fidelity', 'output')
       and check_key not in ('load:answer_missing', 'load:answer_mismatch')
       and status in ('open', 'held');
  end if;

  perform public.textbook_problem_recalc_scores(p_crop_id);
  return jsonb_build_object('ok', true, 'crop_id', p_crop_id, 'pb_answer_sync', v_sync);
end;
$$;

revoke all on function public.textbook_review_save_item_edit(uuid, text, text, text[], boolean, boolean, text, text, jsonb, boolean, text) from public, anon;
grant execute on function public.textbook_review_save_item_edit(uuid, text, text, text[], boolean, boolean, text, text, jsonb, boolean, text) to authenticated;

-- ── 축 일괄 승인: 수학 승인 시 문제은행 정답도 함께 동기화하고 모든 관련 소견을 닫는다 ──
create or replace function public.textbook_review_approve_axis(
  p_crop_ids uuid[],
  p_axis text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_updated int := 0;
  v_cid uuid;
  v_ans text;
begin
  if not (select public.is_superadmin()) then
    raise exception 'textbook_review_forbidden';
  end if;
  if p_axis not in ('math', 'quality') then
    raise exception 'textbook_review_bad_axis';
  end if;
  if p_crop_ids is null or cardinality(p_crop_ids) = 0 then
    return jsonb_build_object('approved', 0);
  end if;

  insert into public.textbook_problem_analyses (crop_id, academy_id)
  select c.id, c.academy_id
    from public.textbook_problem_crops c
   where c.id = any (p_crop_ids)
  on conflict (crop_id) do nothing;

  if p_axis = 'math' then
    update public.textbook_problem_analyses
       set math_status = 'approved',
           answer_matched = true,
           mismatch_reason = null,
           math_approved_at = now(),
           math_approved_by = auth.uid(),
           updated_at = now()
     where crop_id = any (p_crop_ids);
    get diagnostics v_updated = row_count;

    foreach v_cid in array p_crop_ids loop
      select coalesce(nullif(btrim(a.answer_text), ''), nullif(btrim(a.answer_latex_2d), ''))
        into v_ans
        from public.textbook_problem_answers a
       where a.crop_id = v_cid;
      if v_ans is not null and v_ans <> '' and v_ans !~* '^(\[?\s*image\s*\]?|\(\s*image\s*\)|\[그림\])$' then
        perform public.textbook_review_sync_pb_answer(v_cid, v_ans);
      end if;
    end loop;

    update public.textbook_review_findings
       set status = 'resolved', resolution = 'dismissed', resolved_at = now()
     where crop_id = any (p_crop_ids)
       and (axis = 'validity' or check_key in ('load:answer_missing', 'load:answer_mismatch', 'ai_answer_compare'))
       and status in ('open', 'held');
  else
    update public.textbook_problem_analyses
       set engine_resolved_at = case when quality_status = 'held' then now() else engine_resolved_at end,
           quality_status = 'approved',
           quality_approved_at = now(),
           quality_approved_by = auth.uid(),
           updated_at = now()
     where crop_id = any (p_crop_ids);
    get diagnostics v_updated = row_count;

    update public.textbook_review_findings
       set status = 'resolved', resolution = 'dismissed', resolved_at = now()
     where crop_id = any (p_crop_ids)
       and axis in ('fidelity', 'output')
       and check_key not in ('load:answer_missing', 'load:answer_mismatch')
       and status in ('open', 'held');
  end if;

  return jsonb_build_object('approved', v_updated, 'axis', p_axis);
end;
$$;

revoke all on function public.textbook_review_approve_axis(uuid[], text) from public, anon;
grant execute on function public.textbook_review_approve_axis(uuid[], text) to authenticated;

-- ── 단원 상세 조회(textbook_review_unit_overview): 정답 좌표·이미지 정보 추가 및 보류 소견 구분 ──
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
        'pb_figure_layout', pq.meta -> 'figure_layout',
        'answer_raw_page', a.raw_page,
        'answer_bbox_1k', to_jsonb(coalesce(a.answer_image_region_1k, a.bbox_1k)),
        'answer_image_bucket', coalesce(a.answer_image_bucket, ''),
        'answer_image_path', coalesce(a.answer_image_path, '')
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

-- ── 기존 데이터 일괄 정제 및 복구 ──
do $$
declare
  r record;
  v_instr text;
begin
  -- 1) 기존 원본 해설 전사본에서 [해설] 머리말과 '16 답 ×' 이중 추출 줄 제거
  update public.textbook_problem_analyses an
     set solution_transcribed = nullif(
           public.textbook_review_clean_solution_text(an.solution_transcribed, c.problem_number, coalesce(an.solution_answer, '')),
           ''
         )
    from public.textbook_problem_crops c
   where c.id = an.crop_id
     and an.solution_transcribed is not null
     and an.solution_transcribed <> public.textbook_review_clean_solution_text(an.solution_transcribed, c.problem_number, coalesce(an.solution_answer, ''));

  -- 2) 공통 발문이 숫자·수식 조각('36', '36=2^2×3^2' 등)으로 잘못 잘린 pb_questions 복구:
  --    (가) 수정 이력(pb_question_revisions.before_snapshot)이나 자신의 stem/형제 stem 에서 원래 지시문 문단을 찾는다.
  for r in
    select q.id,
           q.academy_id,
           q.document_id,
           q.stem,
           btrim(coalesce(q.meta -> 'set_model' ->> 'common_stem', q.meta -> 'set_model' ->> 'commonStem', '')) as cur_common,
           nullif(btrim(coalesce(
             q.meta -> 'delivery_unit' ->> 'set_id',
             q.meta -> 'delivery_unit' ->> 'set_key',
             q.meta -> 'set_model' ->> 'set_key',
             q.meta -> 'set_model' ->> 'setKey',
             ''
           )), '') as set_key
      from public.pb_questions q
     where btrim(coalesce(q.meta -> 'set_model' ->> 'common_stem', q.meta -> 'set_model' ->> 'commonStem', '')) <> ''
       and not public.textbook_review_looks_like_instruction(
             btrim(coalesce(q.meta -> 'set_model' ->> 'common_stem', q.meta -> 'set_model' ->> 'commonStem', ''))
           )
  loop
    v_instr := null;
    -- (1) 현재 문항이나 같은 세트 형제 문항의 stem 또는 수정 전 스냅샷에서 지시문 문단 탐색
    select p.part into v_instr
      from (
        select btrim(u.part) as part, 1 as prio, u.ord
          from regexp_split_to_table(coalesce(r.stem, ''), E'\\[문단\\]|\\n') with ordinality as u(part, ord)
        union all
        select btrim(u.part) as part, 2 as prio, u.ord
          from public.pb_question_revisions rev,
               lateral regexp_split_to_table(
                 concat_ws(
                   E'\n',
                   rev.before_snapshot -> 'meta' -> 'set_model' ->> 'common_stem',
                   rev.before_snapshot -> 'meta' -> 'set_model' ->> 'commonStem',
                   rev.before_snapshot -> 'meta' -> 'delivery_unit' ->> 'common_stem',
                   rev.before_snapshot ->> 'stem'
                 ),
                 E'\\[문단\\]|\\n'
               ) with ordinality as u(part, ord)
         where rev.question_id = r.id
        union all
        select btrim(u.part) as part, 3 as prio, u.ord
          from public.pb_questions q2,
               lateral regexp_split_to_table(coalesce(q2.stem, ''), E'\\[문단\\]|\\n') with ordinality as u(part, ord)
         where r.set_key is not null
           and r.document_id is not null
           and q2.document_id = r.document_id
           and q2.academy_id = r.academy_id
           and r.set_key = nullif(btrim(coalesce(
                 q2.meta -> 'delivery_unit' ->> 'set_id',
                 q2.meta -> 'delivery_unit' ->> 'set_key',
                 q2.meta -> 'set_model' ->> 'set_key',
                 q2.meta -> 'set_model' ->> 'setKey',
                 ''
               )), '')
        union all
        select btrim(u.part) as part, 4 as prio, u.ord
          from public.pb_questions q2
          join public.pb_question_revisions rev on rev.question_id = q2.id,
               lateral regexp_split_to_table(
                 concat_ws(
                   E'\n',
                   rev.before_snapshot -> 'meta' -> 'set_model' ->> 'common_stem',
                   rev.before_snapshot -> 'meta' -> 'set_model' ->> 'commonStem',
                   rev.before_snapshot -> 'meta' -> 'delivery_unit' ->> 'common_stem',
                   rev.before_snapshot ->> 'stem'
                 ),
                 E'\\[문단\\]|\\n'
               ) with ordinality as u(part, ord)
         where r.set_key is not null
           and r.document_id is not null
           and q2.document_id = r.document_id
           and q2.academy_id = r.academy_id
           and r.set_key = nullif(btrim(coalesce(
                 q2.meta -> 'delivery_unit' ->> 'set_id',
                 q2.meta -> 'delivery_unit' ->> 'set_key',
                 q2.meta -> 'set_model' ->> 'set_key',
                 q2.meta -> 'set_model' ->> 'setKey',
                 ''
               )), '')
        union all
        select btrim(substring( coalesce(an.render_checks ->> 'issue_detail', an.quality_checks ->> 'issue_detail', '') from '''([^'']{6,120})''' )) as part,
               5 as prio, 1 as ord
          from public.textbook_crop_question_links l
          join public.textbook_problem_analyses an on an.crop_id = l.crop_id
         where l.pb_question_id = r.id
      ) p
     where p.part is not null
       and public.textbook_review_looks_like_instruction(p.part)
     order by p.prio, p.ord
     limit 1;

    if v_instr is not null and v_instr <> '' then
      update public.pb_questions q
         set meta = jsonb_set(
               case
                 when (coalesce(q.meta, '{}'::jsonb) -> 'delivery_unit') ? 'common_stem'
                   then jsonb_set(coalesce(q.meta, '{}'::jsonb), '{delivery_unit,common_stem}', to_jsonb(v_instr))
                 else coalesce(q.meta, '{}'::jsonb)
               end,
               '{set_model,common_stem}',
               to_jsonb(v_instr)
             ),
             stem = case
               when strpos(q.stem, v_instr) = 1 and btrim(substr(q.stem, length(v_instr) + 1)) <> ''
                 then regexp_replace(substr(q.stem, length(v_instr) + 1), E'^(?:\\s|\\[문단\\])+', '')
               when r.cur_common <> '' and strpos(q.stem, r.cur_common) = 1
                    and substr(q.stem, length(r.cur_common) + 1) ~ E'^(?:\\s|\\[문단\\])+.+$'
                 then regexp_replace(substr(q.stem, length(r.cur_common) + 1), E'^(?:\\s|\\[문단\\])+', '')
               else q.stem
             end,
             updated_at = now()
       where q.id = r.id;

      if r.document_id is not null and r.set_key is not null then
        update public.pb_question_sets s
           set common_stem = v_instr, updated_at = now()
         where s.academy_id = r.academy_id
           and s.source_document_id = r.document_id
           and s.set_key = r.set_key;
      end if;
    end if;
  end loop;

  -- 3) 이미 수학 승인(math_status='approved')된 문항의 문제은행 정답 동기화 및 열린 수학·적재 정답 소견 정리
  for r in
    select an.crop_id,
           coalesce(nullif(btrim(a.answer_text), ''), nullif(btrim(a.answer_latex_2d), '')) as ans
      from public.textbook_problem_analyses an
      left join public.textbook_problem_answers a on a.crop_id = an.crop_id
     where an.math_status = 'approved'
  loop
    if r.ans is not null and r.ans <> '' and r.ans !~* '^(\[?\s*image\s*\]?|\(\s*image\s*\)|\[그림\])$' then
      perform public.textbook_review_sync_pb_answer(r.crop_id, r.ans);
    end if;
    update public.textbook_review_findings
       set status = 'resolved', resolution = 'auto_cleared', resolved_at = now()
     where crop_id = r.crop_id
       and (axis = 'validity' or check_key in ('load:answer_missing', 'load:answer_mismatch', 'ai_answer_compare'))
       and status in ('open', 'held');
  end loop;

  -- 4) 이미 품질 승인(quality_status='approved')된 문항에서 열린 품질 소견 정리
  update public.textbook_review_findings f
     set status = 'resolved', resolution = 'auto_cleared', resolved_at = now()
    from public.textbook_problem_analyses an
   where f.crop_id = an.crop_id
     and an.quality_status = 'approved'
     and f.axis in ('fidelity', 'output')
     and f.check_key not in ('load:answer_missing', 'load:answer_mismatch')
     and f.status in ('open', 'held');
end;
$$;

notify pgrst, 'reload schema';
