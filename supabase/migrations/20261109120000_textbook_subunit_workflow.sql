-- 20261109120000: 교재 작업 흐름(1단계 크롭 검수 → 2단계 추출·검수 → 3단계 확정) 기반
--
-- 1) textbook_subunit_workflows: 소단원별 작업 상태(크롭 확정, 2단계 진행 단계, 확정).
--    화면을 닫거나 앱을 다시 켜도 같은 단계에서 이어 간다. work_order 에는 2단계를 다시
--    돌리는 데 필요한 범위(추출 런·정답/해설 쪽 범위·검수 대상)를 그대로 담는다.
-- 2) textbook_problem_crops.region_source: 사람이 추가하거나 고친 크롭('manual')은
--    AI 재분석 저장과 범위 정리가 덮거나 지우지 않는다(게이트웨이가 이 값을 본다).
-- 3) textbook_pb_extract_runs.progress: 본문 추출 청크 진행도(끝난 청크 수·문항 번호).
--    결과 요약(result_summary)과 따로 둬 마지막 요약을 덮지 않게 한다.
-- 4) 이미지 정답 보호: 검수 저장·수학 승인이 이미지 정답을 글자 정답으로 바꾸거나
--    문제은행 정답 그림 표시를 지우지 않게 한다(운영자가 직접 바꿀 때만 바꾼다).
-- 5) 핀셋 크롭 저장(textbook_review_pincette_upsert_crop)은 수동 크롭으로 표시한다.

-- ── 1) 소단원 작업 상태 ─────────────────────────────────────────────────
create table if not exists public.textbook_subunit_workflows (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null
    references public.academies(id) on delete cascade,
  book_id uuid not null
    references public.resource_files(id) on delete cascade,
  grade_label text not null,
  big_order int not null,
  mid_order int not null,
  scope_key text not null,
  crop_status text not null default 'none',
  crop_confirmed_at timestamptz,
  pipeline_status text not null default 'idle',
  pipeline_phase text not null default '',
  pipeline_detail text not null default '',
  pipeline_error text not null default '',
  pipeline_started_at timestamptz,
  pipeline_finished_at timestamptz,
  work_order jsonb not null default '{}'::jsonb,
  confirmed_at timestamptz,
  confirmed_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint textbook_subunit_workflows_scope_uk
    unique (academy_id, book_id, grade_label, big_order, mid_order, scope_key),
  constraint textbook_subunit_workflows_crop_status_chk
    check (crop_status in ('none', 'draft', 'confirmed')),
  constraint textbook_subunit_workflows_pipeline_status_chk
    check (pipeline_status in ('idle', 'queued', 'running', 'done', 'failed'))
);

create index if not exists textbook_subunit_workflows_book_idx
  on public.textbook_subunit_workflows(academy_id, book_id, grade_label);

do $$ begin
  if exists (select 1 from pg_proc where proname = 'set_updated_at') then
    drop trigger if exists trg_textbook_subunit_workflows_updated_at
      on public.textbook_subunit_workflows;
    create trigger trg_textbook_subunit_workflows_updated_at
      before update on public.textbook_subunit_workflows
      for each row execute function public.set_updated_at();
  end if;
end $$;

alter table public.textbook_subunit_workflows enable row level security;

drop policy if exists "textbook_subunit_workflows select" on public.textbook_subunit_workflows;
create policy "textbook_subunit_workflows select" on public.textbook_subunit_workflows
  for select
  using (
    exists (
      select 1 from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id = textbook_subunit_workflows.academy_id
    )
  );

drop policy if exists "textbook_subunit_workflows insert" on public.textbook_subunit_workflows;
create policy "textbook_subunit_workflows insert" on public.textbook_subunit_workflows
  for insert
  with check (
    exists (
      select 1 from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id = textbook_subunit_workflows.academy_id
    )
  );

drop policy if exists "textbook_subunit_workflows update" on public.textbook_subunit_workflows;
create policy "textbook_subunit_workflows update" on public.textbook_subunit_workflows
  for update
  using (
    exists (
      select 1 from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id = textbook_subunit_workflows.academy_id
    )
  )
  with check (
    exists (
      select 1 from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id = textbook_subunit_workflows.academy_id
    )
  );

drop policy if exists "textbook_subunit_workflows delete" on public.textbook_subunit_workflows;
create policy "textbook_subunit_workflows delete" on public.textbook_subunit_workflows
  for delete
  using (
    exists (
      select 1 from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id = textbook_subunit_workflows.academy_id
    )
  );

-- ── 2) 수동 크롭 표시 ───────────────────────────────────────────────────
alter table public.textbook_problem_crops
  add column if not exists region_source text not null default 'vlm';
alter table public.textbook_problem_crops
  drop constraint if exists textbook_problem_crops_region_source_chk;
alter table public.textbook_problem_crops
  add constraint textbook_problem_crops_region_source_chk
  check (region_source in ('vlm', 'manual'));

-- ── 3) 본문 추출 진행도 ─────────────────────────────────────────────────
alter table public.textbook_pb_extract_runs
  add column if not exists progress jsonb not null default '{}'::jsonb;

-- ── 4) 이미지 정답 보호 ─────────────────────────────────────────────────
drop function if exists public.textbook_review_save_item_edit(uuid, text, text, text[], boolean, boolean, text, text, jsonb, boolean, text);
drop function if exists public.textbook_review_save_item_edit(uuid, text, text, text[], boolean, boolean, text, text, jsonb, boolean, text, boolean);

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
  p_ai_answer text default null,
  p_replace_image_answer boolean default false
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
  v_keep_image boolean := false;
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

  -- 그림으로 저장된 정답은 운영자가 글자 정답으로 바꾸겠다고 할 때만 바꾼다.
  select a.answer_kind = 'image' and btrim(coalesce(a.answer_image_path, '')) <> ''
    into v_keep_image
    from public.textbook_problem_answers a
   where a.crop_id = p_crop_id;
  v_keep_image := coalesce(v_keep_image, false) and not coalesce(p_replace_image_answer, false);

  if not v_keep_image then
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
  end if;
  if v_ans ~* '^(\[?\s*image\s*\]?|\(\s*image\s*\)|\[그림\])$' then
    v_ans := null;
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
  return jsonb_build_object('ok', true, 'crop_id', p_crop_id, 'pb_answer_sync', v_sync, 'image_answer_kept', v_keep_image);
end;
$$;

revoke all on function public.textbook_review_save_item_edit(uuid, text, text, text[], boolean, boolean, text, text, jsonb, boolean, text, boolean) from public, anon;
grant execute on function public.textbook_review_save_item_edit(uuid, text, text, text[], boolean, boolean, text, text, jsonb, boolean, text, boolean) to authenticated;

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
  v_kind text;
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
      v_ans := null;
      v_kind := null;
      select coalesce(nullif(btrim(a.answer_text), ''), nullif(btrim(a.answer_latex_2d), '')), a.answer_kind
        into v_ans, v_kind
        from public.textbook_problem_answers a
       where a.crop_id = v_cid;
      if v_ans is not null and v_ans <> ''
         and coalesce(v_kind, '') <> 'image'
         and v_ans !~* '^(\[?\s*image\s*\]?|\(\s*image\s*\)|\[그림\])$' then
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

-- ── 5) 핀셋 크롭 저장은 수동 크롭 ───────────────────────────────────────
create or replace function public.textbook_review_pincette_upsert_crop(
  p_academy_id uuid,
  p_book_id uuid,
  p_grade_label text,
  p_big_order int,
  p_mid_order int,
  p_sub_key text,
  p_sub_index int default 0,
  p_raw_page int default 1,
  p_display_page int default null,
  p_problem_number text default '01',
  p_item_region_1k int[] default null,
  p_bbox_1k int[] default null,
  p_big_name text default null,
  p_mid_name text default null,
  p_section text default null,
  p_item_name text default '',
  p_crop_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sub_key text := upper(btrim(coalesce(nullif(p_sub_key, ''), 'A')));
  v_sub_index int := greatest(0, coalesce(p_sub_index, 0));
  v_prob_num text := btrim(coalesce(p_problem_number, ''));
  v_region int[] := coalesce(p_item_region_1k, p_bbox_1k, array[100, 100, 900, 900]);
  v_bbox int[] := coalesce(p_bbox_1k, p_item_region_1k, v_region);
  v_crop_id uuid;
  v_storage_key text;
begin
  if not (select public.is_superadmin()) then
    raise exception 'textbook_review_forbidden';
  end if;
  if v_prob_num = '' then
    raise exception 'textbook_review_bad_problem_number';
  end if;
  if cardinality(v_region) <> 4 then
    raise exception 'textbook_review_bad_region';
  end if;

  if p_crop_id is not null then
    update public.textbook_problem_crops
       set raw_page = coalesce(p_raw_page, raw_page),
           display_page = coalesce(p_display_page, display_page),
           problem_number = v_prob_num,
           item_region_1k = v_region,
           bbox_1k = v_bbox,
           region_source = 'manual',
           updated_at = now()
     where id = p_crop_id
       and academy_id = p_academy_id
    returning id into v_crop_id;
  end if;

  if v_crop_id is null then
    v_storage_key := format(
      'regions_only/%s/%s/%s/%s_%s_%s_%s_%s.png',
      p_academy_id, p_book_id, p_grade_label,
      p_big_order, p_mid_order, v_sub_key, v_sub_index, v_prob_num
    );
    insert into public.textbook_problem_crops (
      academy_id, book_id, grade_label,
      big_order, mid_order, sub_key, category_code, sub_index,
      big_name, mid_name,
      raw_page, display_page, section,
      problem_number, label, item_name,
      is_important, is_set_header,
      content_group_kind, content_group_label, content_group_title,
      bbox_1k, item_region_1k,
      storage_bucket, storage_key, file_size_bytes,
      region_source,
      updated_at
    )
    values (
      p_academy_id, p_book_id, btrim(p_grade_label),
      p_big_order, p_mid_order, v_sub_key, v_sub_key, v_sub_index,
      coalesce(p_big_name, '대단원 ' || (p_big_order + 1)),
      coalesce(p_mid_name, '중단원 ' || (p_mid_order + 1)),
      greatest(1, coalesce(p_raw_page, 1)),
      p_display_page,
      p_section,
      v_prob_num, '', coalesce(p_item_name, ''),
      false, false,
      'none', '', '',
      v_bbox, v_region,
      'textbook-crops', v_storage_key, 0,
      'manual',
      now()
    )
    on conflict (academy_id, book_id, grade_label, big_order, mid_order, sub_key, sub_index, problem_number)
    do update set
      raw_page = excluded.raw_page,
      display_page = coalesce(excluded.display_page, public.textbook_problem_crops.display_page),
      bbox_1k = excluded.bbox_1k,
      item_region_1k = excluded.item_region_1k,
      region_source = 'manual',
      updated_at = now()
    returning id into v_crop_id;
  end if;

  insert into public.textbook_problem_analyses (crop_id, academy_id)
  values (v_crop_id, p_academy_id)
  on conflict (crop_id) do nothing;

  return jsonb_build_object(
    'ok', true,
    'crop_id', v_crop_id,
    'problem_number', v_prob_num,
    'raw_page', greatest(1, coalesce(p_raw_page, 1)),
    'item_region_1k', to_jsonb(v_region)
  );
end;
$$;

revoke all on function public.textbook_review_pincette_upsert_crop(uuid, uuid, text, int, int, text, int, int, int, text, int[], int[], text, text, text, text, uuid) from public, anon;
grant execute on function public.textbook_review_pincette_upsert_crop(uuid, uuid, text, int, int, text, int, int, int, text, int[], int[], text, text, text, text, uuid) to authenticated;
