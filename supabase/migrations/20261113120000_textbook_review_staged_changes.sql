-- 20261113120000: 교재 검수 2단계는 수정안만 만들고, 소단원 확정 때 한 번에 반영한다.
-- (docs/specs/20261113-교재-문항-검수-흐름과-기준.md 4번)
--
-- 1) textbook_problem_analyses.staged_changes: 확정 전까지 쌓아 두는 반영 대기 값.
--    키: stem, common_stem, choices, figure_layout, figure_assets, answer,
--        solution_transcribed, solution_answer, question_kind, allow_subjective
--    sources: 키별 출처('ai' | 'owner'). 사장님이 고친 값은 AI 가 덮어쓰지 않는다.
-- 2) textbook_review_unit_overview: 문제은행 값 위에 반영 대기 값을 겹쳐 돌려준다.
--    원래 값은 db_values 로 함께 준다. 화면·V2 렌더 검수·Edge 수정 단계가 모두 "고친 뒤" 모습을 본다.
-- 3) textbook_review_stage_changes: 수정안을 반영 대기 값으로 쌓는다(문제은행·정답 테이블은 쓰지 않음).
-- 4) textbook_review_apply_staged: 소단원 확정 때 반영 대기 값을 문제은행·정답에 반영하고 두 축을 승인한다.
--    한 트랜잭션이라 한 문항이라도 실패하면 아무것도 반영되지 않는다.

alter table public.textbook_problem_analyses
  add column if not exists staged_changes jsonb not null default '{}'::jsonb;

-- ── 2) overview 겹쳐 읽기 ────────────────────────────────────────────────
create or replace function public.textbook_review_overlay_staged(p_item jsonb, p_staged jsonb)
returns jsonb
language plpgsql
immutable
as $$
declare
  st jsonb := coalesce(p_staged, '{}'::jsonb) - 'sources' - 'notes' - 'staged_at';
  r jsonb;
  v_kind text;
  v_obj boolean;
  v_subj boolean;
begin
  r := p_item || jsonb_build_object(
    'staged_changes', coalesce(p_staged, '{}'::jsonb),
    'db_values', jsonb_build_object(
      'stem', p_item -> 'stem',
      'common_stem', p_item -> 'common_stem',
      'choices', p_item -> 'choices',
      'pb_figure_assets', p_item -> 'pb_figure_assets',
      'pb_figure_layout', p_item -> 'pb_figure_layout',
      'existing_answer', p_item -> 'existing_answer',
      'solution_transcribed', p_item -> 'solution_transcribed',
      'solution_answer', p_item -> 'solution_answer',
      'question_type', p_item -> 'question_type',
      'pb_allow_objective', p_item -> 'pb_allow_objective',
      'pb_allow_subjective', p_item -> 'pb_allow_subjective',
      'pb_allow_essay', p_item -> 'pb_allow_essay'
    )
  );
  if st = '{}'::jsonb then
    return r;
  end if;
  if st ? 'stem' then r := r || jsonb_build_object('stem', st -> 'stem'); end if;
  if st ? 'common_stem' then r := r || jsonb_build_object('common_stem', st -> 'common_stem'); end if;
  if st ? 'choices' then r := r || jsonb_build_object('choices', st -> 'choices'); end if;
  if st ? 'figure_assets' then r := r || jsonb_build_object('pb_figure_assets', st -> 'figure_assets'); end if;
  if st ? 'figure_layout' then r := r || jsonb_build_object('pb_figure_layout', st -> 'figure_layout'); end if;
  if st ? 'answer' then r := r || jsonb_build_object('existing_answer', st -> 'answer'); end if;
  if st ? 'solution_transcribed' then r := r || jsonb_build_object('solution_transcribed', st -> 'solution_transcribed'); end if;
  if st ? 'solution_answer' then r := r || jsonb_build_object('solution_answer', st -> 'solution_answer'); end if;
  if st ? 'question_kind' then
    v_kind := st ->> 'question_kind';
    -- textbook_review_set_question_kind 와 같은 규칙
    if v_kind = 'objective' then
      v_obj := true;
      v_subj := coalesce((st ->> 'allow_subjective')::boolean, (p_item ->> 'pb_allow_subjective')::boolean, false);
    elsif v_kind = 'subjective' then
      v_obj := coalesce((p_item ->> 'pb_allow_objective')::boolean, false);
      v_subj := true;
    else
      v_obj := false;
      v_subj := true;
    end if;
    r := r || jsonb_build_object(
      'question_type', case v_kind when 'objective' then '객관식' when 'subjective' then '주관식' else '서술형' end,
      'pb_allow_objective', v_obj,
      'pb_allow_subjective', v_subj,
      'pb_allow_essay', v_kind = 'essay'
    );
  end if;
  return r;
end;
$$;

do $$
begin
  if not exists (select 1 from pg_proc where proname = 'textbook_review_unit_overview_base') then
    alter function public.textbook_review_unit_overview(uuid, uuid, text, int, int)
      rename to textbook_review_unit_overview_base;
  end if;
end $$;

revoke all on function public.textbook_review_unit_overview_base(uuid, uuid, text, int, int) from public, anon, authenticated;

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
declare
  v jsonb;
begin
  v := public.textbook_review_unit_overview_base(p_academy_id, p_book_id, p_grade_label, p_big_order, p_mid_order);
  return (v - 'items') || jsonb_build_object('items', coalesce((
    select jsonb_agg(public.textbook_review_overlay_staged(e.item, an.staged_changes) order by e.ord)
      from jsonb_array_elements(coalesce(v -> 'items', '[]'::jsonb)) with ordinality as e(item, ord)
      left join public.textbook_problem_analyses an
        on an.crop_id = (e.item ->> 'crop_id')::uuid
  ), '[]'::jsonb));
end;
$$;

revoke all on function public.textbook_review_unit_overview(uuid, uuid, text, int, int) from public, anon;
grant execute on function public.textbook_review_unit_overview(uuid, uuid, text, int, int) to authenticated;

-- ── 3) 수정안을 반영 대기 값으로 쌓기 ────────────────────────────────────
-- p_patch 의 값이 JSON null 이면 그 키의 반영 대기를 지운다. 문제은행 값과 같아진 키도 지운다.
-- p_math_status / p_quality_status: AI·사장님 판정('clean' | 'issue'). 승인('approved')은 확정 때만 한다.
create or replace function public.textbook_review_stage_changes(
  p_crop_id uuid,
  p_patch jsonb default '{}'::jsonb,
  p_source text default 'ai',
  p_note text default null,
  p_math_status text default null,
  p_quality_status text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_crop public.textbook_problem_crops;
  v_pq public.pb_questions;
  v_an public.textbook_problem_analyses;
  v_st jsonb;
  v_src jsonb;
  v_base jsonb;
  v_key text;
  v_val jsonb;
  v_prev jsonb;
  v_changed text[] := '{}';
  v_skipped text[] := '{}';
  v_hdr public.textbook_problem_crops;
  v_prob_num int;
  v_sib record;
  v_sib_st jsonb;
  v_allowed constant text[] := array[
    'stem', 'common_stem', 'choices', 'figure_layout', 'figure_assets', 'answer',
    'solution_transcribed', 'solution_answer', 'question_kind', 'allow_subjective'
  ];
begin
  if auth.uid() is not null and not (select public.is_superadmin()) then
    raise exception 'textbook_review_forbidden';
  end if;
  if p_source not in ('ai', 'owner') then
    raise exception 'textbook_review_bad_source';
  end if;
  if p_math_status is not null and p_math_status not in ('clean', 'issue') then
    raise exception 'textbook_review_bad_status';
  end if;
  if p_quality_status is not null and p_quality_status not in ('clean', 'issue') then
    raise exception 'textbook_review_bad_status';
  end if;
  if p_patch is not null and jsonb_typeof(p_patch) <> 'object' then
    raise exception 'textbook_review_bad_patch';
  end if;
  select * into v_crop from public.textbook_problem_crops where id = p_crop_id;
  if not found then
    raise exception 'textbook_review_crop_not_found';
  end if;

  insert into public.textbook_problem_analyses (crop_id, academy_id)
  values (v_crop.id, v_crop.academy_id)
  on conflict (crop_id) do nothing;
  select * into v_an from public.textbook_problem_analyses where crop_id = p_crop_id for update;
  select * into v_pq from public.pb_questions where id = public.textbook_review_linked_pb_question(p_crop_id);

  v_base := jsonb_build_object(
    'stem', to_jsonb(coalesce(v_pq.stem, '')),
    'common_stem', to_jsonb(btrim(coalesce(v_pq.meta -> 'set_model' ->> 'common_stem', v_pq.meta -> 'set_model' ->> 'commonStem', ''))),
    'choices', coalesce(v_pq.choices, '[]'::jsonb),
    'figure_layout', coalesce(v_pq.meta -> 'figure_layout', 'null'::jsonb),
    'figure_assets', coalesce(v_pq.meta -> 'figure_assets', '[]'::jsonb),
    'answer', coalesce((
      select to_jsonb(coalesce(nullif(btrim(a.answer_text), ''), a.answer_latex_2d))
        from public.textbook_problem_answers a where a.crop_id = p_crop_id
    ), 'null'::jsonb),
    'solution_transcribed', coalesce(to_jsonb(v_an.solution_transcribed), 'null'::jsonb),
    'solution_answer', coalesce(to_jsonb(v_an.solution_answer), 'null'::jsonb),
    'question_kind', to_jsonb(case
      when coalesce(v_pq.question_type, '') like '%서술%' then 'essay'
      when coalesce(v_pq.question_type, '') like '%객관식%' then 'objective'
      when coalesce(v_pq.question_type, '') like '%주관식%' then 'subjective'
      else ''
    end),
    'allow_subjective', coalesce(to_jsonb(v_pq.allow_subjective), 'null'::jsonb)
  );

  v_st := coalesce(v_an.staged_changes, '{}'::jsonb);
  v_src := coalesce(v_st -> 'sources', '{}'::jsonb);

  for v_key, v_val in select * from jsonb_each(coalesce(p_patch, '{}'::jsonb)) loop
    if not (v_key = any (v_allowed)) then
      raise exception 'textbook_review_bad_patch_key: %', v_key;
    end if;
    if p_source = 'ai' and v_src ->> v_key = 'owner' then
      v_skipped := array_append(v_skipped, v_key);
      continue;
    end if;
    if v_key in ('stem', 'common_stem') and jsonb_typeof(v_val) = 'string' then
      v_val := to_jsonb(public.textbook_review_normalize_markup(v_val #>> '{}'));
    end if;
    v_prev := v_st -> v_key;
    if jsonb_typeof(v_val) = 'null' or v_val = v_base -> v_key then
      v_st := v_st - v_key;
      v_src := v_src - v_key;
    else
      v_st := v_st || jsonb_build_object(v_key, v_val);
      v_src := v_src || jsonb_build_object(v_key, p_source);
    end if;
    if (v_st -> v_key) is distinct from v_prev then
      v_changed := array_append(v_changed, v_key);
    end if;
  end loop;

  v_st := (v_st - 'sources' - 'notes' - 'staged_at');
  if v_st <> '{}'::jsonb then
    v_st := v_st || jsonb_build_object(
      'sources', v_src,
      'staged_at', now(),
      'notes', coalesce(v_an.staged_changes -> 'notes', '[]'::jsonb)
        || case when cardinality(v_changed) > 0 and coalesce(btrim(p_note), '') <> ''
             then jsonb_build_array(jsonb_build_object('at', now(), 'source', p_source, 'note', p_note, 'fields', to_jsonb(v_changed)))
             else '[]'::jsonb end
    );
  end if;

  update public.textbook_problem_analyses a
     set staged_changes = v_st,
         -- 수정 단계 제안이 반영 대기 값에 들어갔음을 기존 판정(applied_at)이 알 수 있게 남긴다.
         fix_proposal = case when cardinality(v_changed) > 0
           then coalesce(a.fix_proposal, '{}'::jsonb)
                || jsonb_build_object('applied_at', now(), 'applied_fields', to_jsonb(v_changed), 'applied_note', p_note, 'staged', true)
           else a.fix_proposal end,
         render_checked_at = case when cardinality(v_changed) > 0 then null else a.render_checked_at end,
         math_status = case when p_math_status is not null then p_math_status else a.math_status end,
         quality_status = case
           when p_quality_status is not null and a.quality_status is distinct from 'held' then p_quality_status
           else a.quality_status end,
         updated_at = now()
   where a.crop_id = p_crop_id;

  if p_math_status = 'clean' then
    update public.textbook_review_findings
       set status = 'resolved', resolution = 'staged_fix', resolved_at = now()
     where crop_id = p_crop_id
       and (axis = 'validity' or check_key in ('load:answer_missing', 'load:answer_mismatch', 'ai_answer_compare'))
       and status in ('open', 'held');
  end if;
  if p_quality_status = 'clean' then
    update public.textbook_review_findings
       set status = 'resolved', resolution = 'staged_fix', resolved_at = now()
     where crop_id = p_crop_id
       and axis in ('fidelity', 'output')
       and check_key not in ('load:answer_missing', 'load:answer_mismatch')
       and status in ('open', 'held');
  end if;

  -- 공통 발문은 같은 세트 형제 문항에도 반영 대기로 넣는다(확정 때 문제은행 세트 전파는 apply_problem_fix 가 한다).
  if 'common_stem' = any (v_changed) and v_st ? 'common_stem'
     and (regexp_replace(v_crop.problem_number, '[^0-9]', '', 'g')) ~ '^[0-9]+$' then
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
    if v_hdr.id is not null then
      for v_sib in
        select c2.id, c2.academy_id, coalesce(an2.staged_changes, '{}'::jsonb) as st
          from public.textbook_problem_crops c2
          left join public.textbook_problem_analyses an2 on an2.crop_id = c2.id
         where c2.id <> p_crop_id
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
      loop
        if p_source = 'ai' and v_sib.st -> 'sources' ->> 'common_stem' = 'owner' then
          continue;
        end if;
        if (v_sib.st -> 'common_stem') is not distinct from (v_st -> 'common_stem') then
          continue;
        end if;
        v_sib_st := (v_sib.st - 'sources' - 'staged_at')
          || jsonb_build_object('common_stem', v_st -> 'common_stem')
          || jsonb_build_object(
               'sources', coalesce(v_sib.st -> 'sources', '{}'::jsonb) || jsonb_build_object('common_stem', p_source),
               'staged_at', now()
             );
        insert into public.textbook_problem_analyses (crop_id, academy_id, staged_changes)
        values (v_sib.id, v_sib.academy_id, v_sib_st)
        on conflict (crop_id) do update
          set staged_changes = excluded.staged_changes,
              render_checked_at = null,
              updated_at = now();
      end loop;
    end if;
  end if;

  return jsonb_build_object(
    'ok', true,
    'crop_id', p_crop_id,
    'changed', to_jsonb(v_changed),
    'skipped_owner', to_jsonb(v_skipped),
    'staged', v_st - 'sources' - 'notes' - 'staged_at'
  );
end;
$$;

revoke all on function public.textbook_review_stage_changes(uuid, jsonb, text, text, text, text) from public, anon;
grant execute on function public.textbook_review_stage_changes(uuid, jsonb, text, text, text, text) to authenticated;

-- ── 4) 소단원 확정 때 일괄 반영 ──────────────────────────────────────────
create or replace function public.textbook_review_apply_staged(p_crop_ids uuid[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row record;
  v_st jsonb;
  v_applied int := 0;
  v_math int := 0;
  v_quality int := 0;
  v_held text;
  v_checked jsonb;
begin
  if not (select public.is_superadmin()) then
    raise exception 'textbook_review_forbidden';
  end if;
  if p_crop_ids is null or cardinality(p_crop_ids) = 0 then
    return jsonb_build_object('ok', true, 'applied', 0);
  end if;

  select string_agg(c.problem_number, ', ' order by c.raw_page, c.problem_number)
    into v_held
    from public.textbook_problem_analyses an
    join public.textbook_problem_crops c on c.id = an.crop_id
   where an.crop_id = any (p_crop_ids)
     and an.quality_status = 'held';
  if v_held is not null then
    raise exception 'textbook_review_engine_held: %', v_held;
  end if;

  -- 반영하면 문제은행 트리거가 렌더 검수 시각을 지운다. 확정 전에 검수한 화면이 곧 반영된 화면이므로 되돌린다.
  select coalesce(jsonb_object_agg(an.crop_id::text, an.render_checked_at), '{}'::jsonb)
    into v_checked
    from public.textbook_problem_analyses an
   where an.crop_id = any (p_crop_ids);

  for v_row in
    select an.crop_id, an.staged_changes
      from public.textbook_problem_analyses an
     where an.crop_id = any (p_crop_ids)
       and coalesce(an.staged_changes, '{}'::jsonb) - 'sources' - 'notes' - 'staged_at' <> '{}'::jsonb
  loop
    v_st := v_row.staged_changes;
    if v_st ?| array['stem', 'common_stem', 'choices', 'figure_layout', 'figure_assets'] then
      perform public.textbook_review_apply_problem_fix(
        v_row.crop_id,
        v_st ->> 'stem',
        v_st -> 'choices',
        true,
        '소단원 확정 일괄 반영',
        v_st ->> 'common_stem',
        v_st -> 'figure_layout',
        v_st -> 'figure_assets'
      );
    end if;
    if v_st ? 'question_kind' then
      perform public.textbook_review_set_question_kind(
        v_row.crop_id,
        v_st ->> 'question_kind',
        (v_st ->> 'allow_subjective')::boolean
      );
    end if;
    if v_st ?| array['answer', 'solution_transcribed', 'solution_answer'] then
      perform public.textbook_review_save_item_edit(
        v_row.crop_id,
        v_st ->> 'answer',
        null,
        null,
        true,
        true,
        v_st ->> 'solution_transcribed',
        v_st ->> 'solution_answer',
        null,
        true,
        null,
        coalesce(v_st -> 'sources' ->> 'answer', '') = 'owner'
      );
    end if;
    update public.textbook_problem_analyses
       set staged_changes = '{}'::jsonb,
           updated_at = now()
     where crop_id = v_row.crop_id;
    v_applied := v_applied + 1;
  end loop;

  select coalesce((public.textbook_review_approve_axis(p_crop_ids, 'math') ->> 'approved')::int, 0) into v_math;
  select coalesce((public.textbook_review_approve_axis(p_crop_ids, 'quality') ->> 'approved')::int, 0) into v_quality;

  update public.textbook_problem_analyses an
     set render_checked_at = (v_checked ->> an.crop_id::text)::timestamptz
   where an.crop_id = any (p_crop_ids)
     and v_checked ? an.crop_id::text;

  return jsonb_build_object('ok', true, 'applied', v_applied, 'math_approved', v_math, 'quality_approved', v_quality);
end;
$$;

revoke all on function public.textbook_review_apply_staged(uuid[]) from public, anon;
grant execute on function public.textbook_review_apply_staged(uuid[]) to authenticated;

notify pgrst, 'reload schema';
