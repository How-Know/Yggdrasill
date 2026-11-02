-- 문항검수 원터치 승인·렌더 엔진 보류
--
-- 1) 수학 승인: 채점 정답(textbook_problem_answers)을 고칠 때 문제은행 사본(pb_questions)의
--    주관식·객관식 정답도 함께 맞춘다. 적재 확인의 "문제은행 정답과 채점 정답이 다름" 경고를 예방한다.
-- 2) 품질 승인: AI 가 제안한 본문·선지 수정(fix_proposal)을 pb_questions 에 적용하고 바로 승인한다.
-- 3) 렌더 엔진 문제는 quality_status='held' 로 따로 분류한다. 집계에서 승인은 완료, 보류는 별도 관리.
--    보류 시점의 판정을 engine_hold_snapshot 에 남겨, 엔진 수정 뒤 다시 렌더링해 비교할 수 있게 한다.

alter table public.textbook_problem_analyses
  add column if not exists fix_proposal jsonb not null default '{}'::jsonb,
  add column if not exists engine_hold_note text,
  add column if not exists engine_held_at timestamptz,
  add column if not exists engine_held_by uuid references auth.users(id) on delete set null,
  add column if not exists engine_resolved_at timestamptz,
  add column if not exists engine_hold_snapshot jsonb not null default '{}'::jsonb;

comment on column public.textbook_problem_analyses.fix_proposal is
  'AI 가 제안한 문항 데이터 수정 {stem, choices, reason, kind, source, created_at}. 적용은 textbook_review_apply_problem_fix 로만.';
comment on column public.textbook_problem_analyses.engine_hold_snapshot is
  '엔진 보류 시점의 quality_checks·render_checks 사본. 엔진 수정 뒤 재렌더 비교용.';

create index if not exists textbook_problem_analyses_engine_hold_idx
  on public.textbook_problem_analyses (academy_id, engine_held_at)
  where quality_status = 'held';

-- ── 정답 표기 → 객관식 키(①, ③ 형식). 숫자·원문자·쉼표·'번'만으로 된 표기만 변환하고, 아니면 '' ──
create or replace function public.textbook_review_objective_key(p text)
returns text
language plpgsql
immutable
as $$
declare
  v text := regexp_replace(coalesce(p, ''), '\s+', '', 'g');
  v_labels text[] := array['①','②','③','④','⑤','⑥','⑦','⑧','⑨','⑩'];
  v_out text[] := '{}';
  v_tok text;
  v_n int;
begin
  if v = '' then return ''; end if;
  v := replace(replace(replace(v, '번', ''), '(', ''), ')', '');
  v := regexp_replace(v, '[，、ㆍ·/]', ',', 'g');
  -- 원문자가 섞여 있으면 원문자만 추출
  if v ~ '[①②③④⑤⑥⑦⑧⑨⑩]' then
    if regexp_replace(v, '[①②③④⑤⑥⑦⑧⑨⑩,]', '', 'g') <> '' then return ''; end if;
    for v_tok in select m[1] from regexp_matches(v, '([①②③④⑤⑥⑦⑧⑨⑩])', 'g') as m loop
      if not (v_tok = any (v_out)) then v_out := v_out || v_tok; end if;
    end loop;
    return array_to_string(v_out, ', ');
  end if;
  -- 숫자(1~10)만으로 된 표기
  if v !~ '^(10|[1-9])(,(10|[1-9]))*$' then return ''; end if;
  foreach v_tok in array string_to_array(v, ',') loop
    v_n := v_tok::int;
    if not (v_labels[v_n] = any (v_out)) then v_out := v_out || v_labels[v_n]; end if;
  end loop;
  return array_to_string(v_out, ', ');
end;
$$;

-- ── 크롭에 연결된 문제은행 문항 id ──
create or replace function public.textbook_review_linked_pb_question(p_crop_id uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select l.pb_question_id from public.textbook_crop_question_links l where l.crop_id = p_crop_id limit 1),
    (select q.id
       from public.textbook_problem_crops c
       join public.pb_questions q on q.academy_id = c.academy_id and q.question_uid = c.pb_question_uid
      where c.id = p_crop_id and c.pb_question_uid is not null
      limit 1)
  );
$$;

revoke all on function public.textbook_review_linked_pb_question(uuid) from public, anon, authenticated;

-- ── 문제은행 사본 정답 동기화 (내부용) ──
-- 객관식 허용 문항: 표기가 선지 번호로 읽히면 objective_answer_key 를 맞춘다.
-- 주관식 허용 문항: 번호 표기면 해당 선지 본문을, 아니면 표기 그대로 subjective_answer 에 넣는다.
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
begin
  if v_ans = '' then return jsonb_build_object('synced', false, 'reason', 'empty'); end if;
  select * into v_pq from public.pb_questions where id = public.textbook_review_linked_pb_question(p_crop_id);
  if not found then return jsonb_build_object('synced', false, 'reason', 'no_pb_question'); end if;

  v_key := public.textbook_review_objective_key(v_ans);

  if v_pq.allow_objective and v_key <> '' and v_pq.objective_answer_key is distinct from v_key then
    v_changed := v_changed || 'objective_answer_key';
  end if;

  if v_pq.allow_subjective then
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
      v_changed := v_changed || 'subjective_answer';
    end if;
  end if;

  if cardinality(v_changed) = 0 then
    return jsonb_build_object('synced', true, 'pb_question_id', v_pq.id, 'changed', '[]'::jsonb);
  end if;

  update public.pb_questions
     set objective_answer_key = case when 'objective_answer_key' = any (v_changed) then v_key else objective_answer_key end,
         subjective_answer = case when 'subjective_answer' = any (v_changed) then v_subj else subjective_answer end,
         updated_at = now()
   where id = v_pq.id;

  return jsonb_build_object('synced', true, 'pb_question_id', v_pq.id, 'changed', to_jsonb(v_changed));
end;
$$;

revoke all on function public.textbook_review_sync_pb_answer(uuid, text) from public, anon, authenticated;

-- ── 정답·풀이·해설 저장 + 승인 (p_sync_pb_answer 추가) ──
drop function if exists public.textbook_review_save_item_edit(uuid, text, text, text[], boolean, boolean, text, text, jsonb);

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
    if p_sync_pb_answer then
      v_sync := public.textbook_review_sync_pb_answer(p_crop_id, p_new_answer);
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
        -- 엔진 보류 중이던 문항을 승인하면 해결 시각을 남긴다.
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

-- ── 본문·선지 수정 적용 (+ 품질 승인) ──
-- pb_questions 를 직접 고친다. pb_questions_emit_revision 트리거가 수정 이력을 남긴다.
create or replace function public.textbook_review_apply_problem_fix(
  p_crop_id uuid,
  p_stem text default null,
  p_choices jsonb default null,
  p_approve_quality boolean default false,
  p_note text default null
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

  v_pq_id := public.textbook_review_linked_pb_question(p_crop_id);
  if v_pq_id is not null and (p_stem is not null or p_choices is not null) then
    select * into v_pq from public.pb_questions where id = v_pq_id;
    if p_stem is not null and v_pq.stem is distinct from p_stem then v_changed := v_changed || 'stem'; end if;
    if p_choices is not null and v_pq.choices is distinct from p_choices then v_changed := v_changed || 'choices'; end if;
    if cardinality(v_changed) > 0 then
      update public.pb_questions
         set stem = case when 'stem' = any (v_changed) then p_stem else stem end,
             choices = case when 'choices' = any (v_changed) then p_choices else choices end,
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
         -- 본문이 바뀌면 이전 V2 판정은 더 이상 그 화면이 아니다.
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
    'approved', p_approve_quality
  );
end;
$$;

revoke all on function public.textbook_review_apply_problem_fix(uuid, text, jsonb, boolean, text) from public, anon;
grant execute on function public.textbook_review_apply_problem_fix(uuid, text, jsonb, boolean, text) to authenticated;

-- ── 렌더 엔진 보류 설정/해제 ──
create or replace function public.textbook_review_set_engine_hold(
  p_crop_ids uuid[],
  p_hold boolean,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_updated int := 0;
begin
  if not (select public.is_superadmin()) then
    raise exception 'textbook_review_forbidden';
  end if;
  if p_crop_ids is null or cardinality(p_crop_ids) = 0 then
    return jsonb_build_object('updated', 0);
  end if;

  insert into public.textbook_problem_analyses (crop_id, academy_id)
  select c.id, c.academy_id from public.textbook_problem_crops c where c.id = any (p_crop_ids)
  on conflict (crop_id) do nothing;

  if p_hold then
    update public.textbook_problem_analyses a
       set quality_status = 'held',
           engine_hold_note = coalesce(nullif(btrim(p_note), ''), a.render_checks ->> 'issue_title', a.quality_checks ->> 'issue_title', '렌더 엔진 문제'),
           engine_held_at = now(),
           engine_held_by = auth.uid(),
           engine_resolved_at = null,
           engine_hold_snapshot = jsonb_build_object(
             'held_at', now(),
             'quality_checks', a.quality_checks,
             'render_checks', a.render_checks
           ),
           updated_at = now()
     where a.crop_id = any (p_crop_ids)
       and a.quality_status <> 'approved';
    get diagnostics v_updated = row_count;

    update public.textbook_review_findings
       set status = 'held'
     where crop_id = any (p_crop_ids) and axis in ('fidelity', 'output') and status = 'open';
  else
    update public.textbook_problem_analyses a
       set quality_status = 'issue',
           engine_resolved_at = now(),
           updated_at = now()
     where a.crop_id = any (p_crop_ids)
       and a.quality_status = 'held';
    get diagnostics v_updated = row_count;

    update public.textbook_review_findings
       set status = 'open'
     where crop_id = any (p_crop_ids) and axis in ('fidelity', 'output') and status = 'held';
  end if;

  return jsonb_build_object('updated', v_updated, 'hold', p_hold);
end;
$$;

revoke all on function public.textbook_review_set_engine_hold(uuid[], boolean, text) from public, anon;
grant execute on function public.textbook_review_set_engine_hold(uuid[], boolean, text) to authenticated;

-- ── 승인 일괄: 보류 중이던 문항은 해결 시각을 남긴다 ──
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
           math_approved_at = now(),
           math_approved_by = auth.uid(),
           updated_at = now()
     where crop_id = any (p_crop_ids);
    get diagnostics v_updated = row_count;

    update public.textbook_review_findings
       set status = 'resolved', resolution = 'dismissed', resolved_at = now()
     where crop_id = any (p_crop_ids) and axis = 'validity' and status in ('open', 'held');
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
     where crop_id = any (p_crop_ids) and axis in ('fidelity', 'output') and status in ('open', 'held');
  end if;

  return jsonb_build_object('approved', v_updated, 'axis', p_axis);
end;
$$;

-- ── 단원 집계: 엔진 보류 수 추가 ──
create or replace function public.textbook_review_books_and_units()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not (select public.is_superadmin()) then
    raise exception 'textbook_review_forbidden';
  end if;
  return jsonb_build_object(
    'units', coalesce((
      select jsonb_agg(jsonb_build_object(
        'academy_id', g.academy_id,
        'book_id', g.book_id,
        'book_name', coalesce(rf.name, '(교재 이름 없음)'),
        'grade_label', g.grade_label,
        'big_order', g.big_order,
        'mid_order', g.mid_order,
        'big_name', coalesce(g.big_name, '대단원 ' || g.big_order),
        'mid_name', coalesce(g.mid_name, '중단원 ' || g.mid_order),
        'problem_count', g.problem_count,
        'analyzed_count', g.analyzed_count,
        'math_clean_count', g.math_clean_count,
        'math_issue_count', g.math_issue_count,
        'math_approved_count', g.math_approved_count,
        'quality_clean_count', g.quality_clean_count,
        'quality_issue_count', g.quality_issue_count,
        'quality_approved_count', g.quality_approved_count,
        'quality_held_count', g.quality_held_count
      ) order by rf.name nulls last, g.grade_label, g.big_order, g.mid_order)
      from (
        select
          c.academy_id,
          c.book_id,
          c.grade_label,
          c.big_order,
          c.mid_order,
          max(c.big_name) as big_name,
          max(c.mid_name) as mid_name,
          count(*)::int as problem_count,
          count(*) filter (where an.analyzed_at is not null)::int as analyzed_count,
          count(*) filter (where an.math_status = 'clean')::int as math_clean_count,
          count(*) filter (where an.math_status = 'issue')::int as math_issue_count,
          count(*) filter (where an.math_status = 'approved')::int as math_approved_count,
          count(*) filter (where an.quality_status = 'clean')::int as quality_clean_count,
          count(*) filter (where an.quality_status = 'issue')::int as quality_issue_count,
          count(*) filter (where an.quality_status = 'approved')::int as quality_approved_count,
          count(*) filter (where an.quality_status = 'held')::int as quality_held_count
        from public.textbook_problem_crops c
        left join public.textbook_problem_analyses an on an.crop_id = c.id
        where not c.is_set_header
        group by c.academy_id, c.book_id, c.grade_label, c.big_order, c.mid_order
      ) g
      left join public.resource_files rf on rf.id = g.book_id
    ), '[]'::jsonb)
  );
end;
$$;

-- ── 엔진 보류 목록: 보류 중(또는 최근 30일 안에 해결된) 문항이 있는 단원과 crop_id ──
-- 문항 상세는 앱이 textbook_review_unit_overview 로 단원별로 읽는다(같은 조회를 두 번 짜지 않는다).
create or replace function public.textbook_review_engine_hold_list()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not (select public.is_superadmin()) then
    raise exception 'textbook_review_forbidden';
  end if;
  return jsonb_build_object(
    'units', coalesce((
      select jsonb_agg(jsonb_build_object(
        'academy_id', g.academy_id,
        'book_id', g.book_id,
        'book_name', coalesce(rf.name, '(교재 이름 없음)'),
        'grade_label', g.grade_label,
        'big_order', g.big_order,
        'mid_order', g.mid_order,
        'big_name', coalesce(g.big_name, '대단원 ' || g.big_order),
        'mid_name', coalesce(g.mid_name, '중단원 ' || g.mid_order),
        'held_count', g.held_count,
        'resolved_count', g.resolved_count,
        'held_crop_ids', g.held_crop_ids,
        'resolved_crop_ids', g.resolved_crop_ids
      ) order by rf.name nulls last, g.grade_label, g.big_order, g.mid_order)
      from (
        select
          c.academy_id, c.book_id, c.grade_label, c.big_order, c.mid_order,
          max(c.big_name) as big_name,
          max(c.mid_name) as mid_name,
          count(*) filter (where an.quality_status = 'held')::int as held_count,
          count(*) filter (where an.quality_status <> 'held' and an.engine_resolved_at is not null)::int as resolved_count,
          coalesce(jsonb_agg(c.id order by an.engine_held_at desc nulls last) filter (where an.quality_status = 'held'), '[]'::jsonb) as held_crop_ids,
          coalesce(jsonb_agg(c.id order by an.engine_resolved_at desc) filter (where an.quality_status <> 'held' and an.engine_resolved_at is not null), '[]'::jsonb) as resolved_crop_ids
        from public.textbook_problem_analyses an
        join public.textbook_problem_crops c on c.id = an.crop_id
        where not c.is_set_header
          and (an.quality_status = 'held'
               or (an.engine_resolved_at is not null and an.engine_resolved_at > now() - interval '30 days'))
        group by c.academy_id, c.book_id, c.grade_label, c.big_order, c.mid_order
      ) g
      left join public.resource_files rf on rf.id = g.book_id
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.textbook_review_engine_hold_list() from public, anon;
grant execute on function public.textbook_review_engine_hold_list() to authenticated;

-- ── 단원 상세: 수정 제안·엔진 보류 필드 추가 (두 번째 jsonb_build_object 에 넣어 100-인자 상한을 지킨다) ──
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

notify pgrst, 'reload schema';
