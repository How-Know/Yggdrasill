-- 20261101030000: 교재 문항 검수 파이프라인 (1단계 해설 추출 · 2단계 블라인드 풀이/연산/품질/시각태그 · 3단계 3축 난이도/개념/사고 분석 및 분리 승인)

alter table public.concepts
  add column if not exists unit_score numeric(6, 2);

-- 개념의 과정 수준별 기본 난이도 점수 (초등 1.0 · 중1 1.5 · 중2 1.8 · 중3 2.0 · 공통수학 2.5 · 대수/미적1/확통 2.8 · 미적2/기하 3.0)
create or replace function public.concept_difficulty_score(p_concept_id uuid)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_custom numeric;
  v_grade text;
begin
  select c.unit_score into v_custom from public.concepts c where c.id = p_concept_id;
  if v_custom is not null then
    return round(v_custom, 2);
  end if;
  select cs.grade_label into v_grade
    from public.concept_sources cs
   where cs.concept_id = p_concept_id
   order by cs.created_at
   limit 1;
  if v_grade is null then
    return 2.00;
  elsif v_grade ~ '^초' or v_grade ~ '^[3-6]-' then
    return 1.00;
  elsif v_grade ~ '1-[12]' then
    return 1.50;
  elsif v_grade ~ '2-[12]' then
    return 1.80;
  elsif v_grade ~ '3-[12]' then
    return 2.00;
  elsif v_grade ~ '공통수학' then
    return 2.50;
  elsif v_grade ~ '(미적분2|기하)' then
    return 3.00;
  elsif v_grade ~ '(대수|미적분|확률|통계)' then
    return 2.80;
  else
    return 2.00;
  end if;
end;
$$;

create table if not exists public.textbook_problem_analyses (
  crop_id uuid primary key references public.textbook_problem_crops(id) on delete cascade,
  academy_id uuid not null references public.academies(id) on delete cascade,

  -- 1단계: 해설 추출 (solution_text)
  solution_transcribed text,
  solution_answer text,
  solution_extracted_at timestamptz,

  -- 2단계: 블라인드 풀이 · 연산 카운트 · 품질/V2렌더/보기 · 시각 태그 (solve)
  ai_solution text,
  ai_answer text,
  arithmetic_counts jsonb not null default '{}'::jsonb,
  arithmetic_score numeric(6, 2) not null default 0,
  visual_tags text[] not null default '{}'::text[],
  quality_checks jsonb not null default '{}'::jsonb,
  solved_at timestamptz,

  -- 3단계: 정답 대조(3way/2way) · 개념/사고 태그 · 3축 난이도 · 초안 제안 (compare & analyze)
  match_mode text not null default '2way' check (match_mode in ('3way', '2way')),
  answer_matched boolean,
  mismatch_reason text,
  concept_ids uuid[] not null default '{}'::uuid[],
  concept_score numeric(6, 2) not null default 0,
  thinking_ids uuid[] not null default '{}'::uuid[],
  thinking_score numeric(6, 2) not null default 0,
  total_difficulty numeric(6, 2) not null default 0,
  draft_proposals jsonb not null default '[]'::jsonb,
  analyzed_at timestamptz,

  -- 분리 승인 상태: 수학적 검수(math_status) vs 품질·렌더링 검수(quality_status)
  math_status text not null default 'pending'
    check (math_status in ('pending', 'clean', 'issue', 'approved', 'held')),
  math_approved_at timestamptz,
  math_approved_by uuid references auth.users(id) on delete set null,

  quality_status text not null default 'pending'
    check (quality_status in ('pending', 'clean', 'issue', 'approved', 'held')),
  quality_approved_at timestamptz,
  quality_approved_by uuid references auth.users(id) on delete set null,

  updated_at timestamptz not null default now()
);

create index if not exists textbook_problem_analyses_academy_idx
  on public.textbook_problem_analyses (academy_id, math_status, quality_status);

alter table public.textbook_problem_analyses enable row level security;

drop policy if exists textbook_problem_analyses_select on public.textbook_problem_analyses;
create policy textbook_problem_analyses_select on public.textbook_problem_analyses
  for select to authenticated
  using (exists (
    select 1 from public.memberships m
     where m.user_id = auth.uid() and m.academy_id = textbook_problem_analyses.academy_id
  ));

revoke insert, update, delete on public.textbook_problem_analyses from anon, authenticated;
grant select on public.textbook_problem_analyses to authenticated;

-- 3축 점수 재계산 헬퍼
create or replace function public.textbook_problem_recalc_scores(p_crop_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.textbook_problem_analyses;
  v_c_score numeric := 0;
  v_t_score numeric := 0;
  v_a_score numeric := 0;
begin
  select * into v_row from public.textbook_problem_analyses where crop_id = p_crop_id;
  if not found then
    return;
  end if;

  select coalesce(round(sum(public.concept_difficulty_score(cid)), 2), 0)
    into v_c_score
    from unnest(coalesce(v_row.concept_ids, '{}'::uuid[])) as u(cid);

  select coalesce(round(sum(tp.unit_score), 2), 0)
    into v_t_score
    from public.thinking_primitives tp
   where tp.id = any (coalesce(v_row.thinking_ids, '{}'::uuid[]));

  select coalesce(round(sum(ap.unit_score * greatest(coalesce((e.value #>> '{}')::numeric, 0), 0)), 2), 0)
    into v_a_score
    from jsonb_each(coalesce(v_row.arithmetic_counts, '{}'::jsonb)) e
    join public.arithmetic_primitives ap on ap.code = e.key;

  update public.textbook_problem_analyses
     set concept_score = v_c_score,
         thinking_score = v_t_score,
         arithmetic_score = v_a_score,
         total_difficulty = round(v_c_score + v_t_score + v_a_score, 2),
         updated_at = now()
   where crop_id = p_crop_id;
end;
$$;

-- 1) 교재 및 중단원별 문항 검수 현황 목록
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
        'quality_approved_count', g.quality_approved_count
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
          count(*) filter (where an.quality_status = 'approved')::int as quality_approved_count
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

-- 2) 선택한 중단원의 전체 문항 및 수학/품질 검수 상세 조회
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
        'solution_region_1k', coalesce(s.content_region_1k, s.number_region_1k),
        'stem', coalesce(pq.stem, ''),
        'question_type', coalesce(pq.question_type, ''),
        'choices', coalesce(pq.choices, '[]'::jsonb),
        'objective_choices', coalesce(pq.objective_choices, '[]'::jsonb),
        'figure_refs', coalesce(pq.figure_refs, '[]'::jsonb),
        'equations', coalesce(pq.equations, '[]'::jsonb),
        'solution_transcribed', an.solution_transcribed,
        'solution_answer', an.solution_answer,
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

-- 3) 수학적 검수 / 품질 검수 개별 또는 일괄 승인
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
       set status = 'resolved',
           resolution = 'dismissed',
           resolved_at = now()
     where crop_id = any (p_crop_ids)
       and axis = 'validity'
       and status in ('open', 'held');
  else
    update public.textbook_problem_analyses
       set quality_status = 'approved',
           quality_approved_at = now(),
           quality_approved_by = auth.uid(),
           updated_at = now()
     where crop_id = any (p_crop_ids);
    get diagnostics v_updated = row_count;

    update public.textbook_review_findings
       set status = 'resolved',
           resolution = 'dismissed',
           resolved_at = now()
     where crop_id = any (p_crop_ids)
       and axis in ('fidelity', 'output')
       and status in ('open', 'held');
  end if;

  return jsonb_build_object('approved', v_updated, 'axis', p_axis);
end;
$$;

-- 4) 문항 정답·풀이·시각 태그 직접 수정 후 승인 반영
create or replace function public.textbook_review_save_item_edit(
  p_crop_id uuid,
  p_new_answer text,
  p_ai_solution text,
  p_visual_tags text[],
  p_approve_math boolean default false,
  p_approve_quality boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_crop public.textbook_problem_crops;
begin
  if not (select public.is_superadmin()) then
    raise exception 'textbook_review_forbidden';
  end if;
  select * into v_crop from public.textbook_problem_crops where id = p_crop_id;
  if not found then
    raise exception 'textbook_review_crop_not_found';
  end if;

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

  insert into public.textbook_problem_analyses (crop_id, academy_id, ai_solution, visual_tags)
  values (v_crop.id, v_crop.academy_id, p_ai_solution, coalesce(p_visual_tags, '{}'::text[]))
  on conflict (crop_id) do update
    set ai_solution = coalesce(p_ai_solution, public.textbook_problem_analyses.ai_solution),
        visual_tags = coalesce(p_visual_tags, public.textbook_problem_analyses.visual_tags),
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

-- 5) 검수 중 제안된 새 연산/사고 초안 승인 및 동일 중단원 앞 문항 자동 백필
create or replace function public.textbook_review_accept_draft_proposal(
  p_crop_id uuid,
  p_proposal_code text,
  p_backfill_midunit boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_crop public.textbook_problem_crops;
  v_an public.textbook_problem_analyses;
  v_prop jsonb;
  v_kind text;
  v_title text;
  v_cat text;
  v_score numeric;
  v_tid uuid;
  v_backfilled int := 0;
  r record;
begin
  if not (select public.is_superadmin()) then
    raise exception 'textbook_review_forbidden';
  end if;
  select * into v_crop from public.textbook_problem_crops where id = p_crop_id;
  select * into v_an from public.textbook_problem_analyses where crop_id = p_crop_id;
  if v_crop.id is null or v_an.crop_id is null then
    raise exception 'textbook_review_crop_not_found';
  end if;

  select p into v_prop
    from jsonb_array_elements(coalesce(v_an.draft_proposals, '[]'::jsonb)) p
   where p ->> 'code' = p_proposal_code
   limit 1;
  if v_prop is null then
    raise exception 'textbook_review_proposal_not_found';
  end if;

  v_kind := coalesce(v_prop ->> 'target', 'thinking');
  v_title := coalesce(nullif(btrim(v_prop ->> 'title'), ''), p_proposal_code);
  v_cat := coalesce(nullif(btrim(v_prop ->> 'category'), ''), case when v_kind = 'arithmetic' then '다항식·전개·인수분해' else '다항식·방정식·부등식' end);
  v_score := coalesce((v_prop ->> 'unit_score')::numeric, case when v_kind = 'arithmetic' then 0.35 else 6.0 end);

  if v_kind = 'arithmetic' then
    insert into public.arithmetic_primitives (code, category, title, criteria, example_expr, unit_score, est_seconds, sort_order, is_active)
    values (
      p_proposal_code, v_cat, v_title,
      coalesce(v_prop ->> 'criteria', v_title),
      coalesce(v_prop ->> 'example_expr', ''),
      round(v_score, 2), 3.0, 950, true
    )
    on conflict (code) do update set title = excluded.title, unit_score = excluded.unit_score;
  else
    insert into public.thinking_primitives (code, kind, category, title, criteria, trigger_cond, action_steps, trap_note, example_expr, unit_score, sort_order, is_active)
    values (
      p_proposal_code,
      case when coalesce(v_prop ->> 'thinking_kind', 'algorithm') = 'frame' then 'frame' else 'algorithm' end,
      v_cat, v_title,
      coalesce(v_prop ->> 'criteria', ''),
      coalesce(v_prop ->> 'trigger_cond', v_title),
      coalesce(v_prop ->> 'action_steps', coalesce(v_prop ->> 'criteria', '')),
      coalesce(v_prop ->> 'trap_note', ''),
      coalesce(v_prop ->> 'example_expr', ''),
      round(v_score, 2), 950, true
    )
    on conflict (code) do update set title = excluded.title, unit_score = excluded.unit_score
    returning id into v_tid;
  end if;

  -- 이 중단원의 모든 분석 문항 중 해당 초안 코드를 제안했거나 풀이 본문에 핵심 키워드가 등장한 문항에 백필
  for r in
    select an2.crop_id, an2.thinking_ids, an2.arithmetic_counts, an2.draft_proposals, an2.ai_solution
      from public.textbook_problem_analyses an2
      join public.textbook_problem_crops c2 on c2.id = an2.crop_id
     where c2.academy_id = v_crop.academy_id
       and c2.book_id = v_crop.book_id
       and c2.grade_label = v_crop.grade_label
       and c2.big_order = v_crop.big_order
       and c2.mid_order = v_crop.mid_order
       and (
         an2.crop_id = p_crop_id
         or exists (select 1 from jsonb_array_elements(coalesce(an2.draft_proposals, '[]'::jsonb)) dp where dp ->> 'code' = p_proposal_code)
         or (p_backfill_midunit and coalesce(an2.ai_solution, '') <> '' and strpos(an2.ai_solution, split_part(v_title, ' ', 1)) > 0)
       )
  loop
    if v_kind = 'arithmetic' then
      update public.textbook_problem_analyses
         set arithmetic_counts = coalesce(arithmetic_counts, '{}'::jsonb) || jsonb_build_object(p_proposal_code, greatest(coalesce((arithmetic_counts ->> p_proposal_code)::int, 0), 1)),
             draft_proposals = coalesce((
               select jsonb_agg(dp) from jsonb_array_elements(coalesce(draft_proposals, '[]'::jsonb)) dp where dp ->> 'code' <> p_proposal_code
             ), '[]'::jsonb),
             updated_at = now()
       where crop_id = r.crop_id;
    elsif v_tid is not null then
      update public.textbook_problem_analyses
         set thinking_ids = case when v_tid = any (coalesce(thinking_ids, '{}'::uuid[])) then thinking_ids else coalesce(thinking_ids, '{}'::uuid[]) || v_tid end,
             draft_proposals = coalesce((
               select jsonb_agg(dp) from jsonb_array_elements(coalesce(draft_proposals, '[]'::jsonb)) dp where dp ->> 'code' <> p_proposal_code
             ), '[]'::jsonb),
             updated_at = now()
       where crop_id = r.crop_id;
    end if;
    perform public.textbook_problem_recalc_scores(r.crop_id);
    v_backfilled := v_backfilled + 1;
  end loop;

  return jsonb_build_object('ok', true, 'code', p_proposal_code, 'backfilled_count', v_backfilled);
end;
$$;

revoke all on function public.concept_difficulty_score(uuid) from public, anon;
grant execute on function public.concept_difficulty_score(uuid) to authenticated;
revoke all on function public.textbook_problem_recalc_scores(uuid) from public, anon;
grant execute on function public.textbook_problem_recalc_scores(uuid) to authenticated;
revoke all on function public.textbook_review_books_and_units() from public, anon;
grant execute on function public.textbook_review_books_and_units() to authenticated;
revoke all on function public.textbook_review_unit_overview(uuid, uuid, text, int, int) from public, anon;
grant execute on function public.textbook_review_unit_overview(uuid, uuid, text, int, int) to authenticated;
revoke all on function public.textbook_review_approve_axis(uuid[], text) from public, anon;
grant execute on function public.textbook_review_approve_axis(uuid[], text) to authenticated;
revoke all on function public.textbook_review_save_item_edit(uuid, text, text, text[], boolean, boolean) from public, anon;
grant execute on function public.textbook_review_save_item_edit(uuid, text, text, text[], boolean, boolean) to authenticated;
revoke all on function public.textbook_review_accept_draft_proposal(uuid, text, boolean) from public, anon;
grant execute on function public.textbook_review_accept_draft_proposal(uuid, text, boolean) to authenticated;

notify pgrst, 'reload schema';

