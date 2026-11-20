-- 20261118190000: 표 모양 선지(빈칸형 선지)의 제목 행(meta.blank_choice_labels)을 반영 대기 값으로 다룬다.
--
-- 표 제목은 선지 글과 따로 저장돼서 검수 수정 단계가 고칠 수 없었다(추출 때 수식 중괄호가 빠진 제목이 그대로 남음).
-- 1) textbook_review_stage_changes: 'blank_choice_labels' 키(제목 2~4개 배열)를 받는다.
-- 2) textbook_review_apply_staged: 기존 확정 반영 뒤 문제은행 문항의 meta.blank_choice_labels 를 쓴다.
-- 확정 전 V2 카드는 앱이 반영 대기 값을 게이트웨이 덮어쓰기(questionOverrides.blank_choice_labels)로 넘겨 찍는다.

-- ── 1) 반영 대기 쌓기 ────────────────────────────────────────────────────
-- ── 1) 반영 대기 쌓기 ────────────────────────────────────────────────────
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
  v_resolution text;
  v_allowed constant text[] := array[
    'stem', 'common_stem', 'choices', 'blank_choice_labels', 'figure_layout', 'figure_assets', 'common_figure_layout', 'answer',
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
  v_resolution := case when p_source = 'owner' then 'manual_edit' else 'auto_cleared' end;

  insert into public.textbook_problem_analyses (crop_id, academy_id)
  values (v_crop.id, v_crop.academy_id)
  on conflict (crop_id) do nothing;
  select * into v_an from public.textbook_problem_analyses where crop_id = p_crop_id for update;
  select * into v_pq from public.pb_questions where id = public.textbook_review_linked_pb_question(p_crop_id);

  v_base := jsonb_build_object(
    'stem', to_jsonb(coalesce(v_pq.stem, '')),
    'common_stem', to_jsonb(btrim(coalesce(v_pq.meta -> 'set_model' ->> 'common_stem', v_pq.meta -> 'set_model' ->> 'commonStem', ''))),
    'choices', coalesce(v_pq.choices, '[]'::jsonb),
    'blank_choice_labels', coalesce(v_pq.meta -> 'blank_choice_labels', 'null'::jsonb),
    'figure_layout', coalesce(v_pq.meta -> 'figure_layout', 'null'::jsonb),
    'figure_assets', coalesce(v_pq.meta -> 'figure_assets', '[]'::jsonb),
    'common_figure_layout', coalesce(v_pq.meta #> '{set_model,common_figure_layout}', 'null'::jsonb),
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
    if v_key = 'blank_choice_labels' and jsonb_typeof(v_val) <> 'null'
       and (jsonb_typeof(v_val) <> 'array' or jsonb_array_length(v_val) not between 2 and 4) then
      raise exception 'textbook_review_bad_blank_choice_labels';
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

  -- 교정 의견(교재 원본 오류)은 반영 대기로 닫히지 않는다. 사장님이 따로 처리한다.
  if p_math_status = 'clean' then
    update public.textbook_review_findings
       set status = 'resolved', resolution = v_resolution, resolved_at = now()
     where crop_id = p_crop_id
       and (axis = 'validity' or check_key in ('load:answer_missing', 'load:answer_mismatch', 'ai_answer_compare'))
       and coalesce(proposal ->> 'target', '') <> 'correction_note'
       and (p_source = 'owner' or check_key <> 'ai_solution_logic')
       and status in ('open', 'held');
  end if;
  if p_quality_status = 'clean' then
    update public.textbook_review_findings
       set status = 'resolved', resolution = v_resolution, resolved_at = now()
     where crop_id = p_crop_id
       and axis in ('fidelity', 'output')
       and check_key not in ('load:answer_missing', 'load:answer_mismatch')
       and coalesce(proposal ->> 'target', '') <> 'correction_note'
       and status in ('open', 'held');
  end if;

  -- 공통 발문·공통 그림 배치는 같은 세트 형제 문항에도 반영 대기로 넣는다.
  if (v_changed && array['common_stem', 'common_figure_layout'])
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
      foreach v_key in array array['common_stem', 'common_figure_layout'] loop
        continue when not (v_key = any (v_changed));
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
          if p_source = 'ai' and v_sib.st -> 'sources' ->> v_key = 'owner' then
            continue;
          end if;
          if (v_sib.st -> v_key) is not distinct from (v_st -> v_key) then
            continue;
          end if;
          v_sib_st := (v_sib.st - 'sources' - 'staged_at' - v_key)
            || case when v_st ? v_key then jsonb_build_object(v_key, v_st -> v_key) else '{}'::jsonb end
            || jsonb_build_object(
                 'sources', case when v_st ? v_key
                   then coalesce(v_sib.st -> 'sources', '{}'::jsonb) || jsonb_build_object(v_key, p_source)
                   else coalesce(v_sib.st -> 'sources', '{}'::jsonb) - v_key end,
                 'staged_at', now()
               );
          insert into public.textbook_problem_analyses (crop_id, academy_id, staged_changes)
          values (v_sib.id, v_sib.academy_id, v_sib_st)
          on conflict (crop_id) do update
            set staged_changes = excluded.staged_changes,
                render_checked_at = null,
                updated_at = now();
        end loop;
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

-- ── 2) 확정 때 표 제목 쓰기 ──────────────────────────────────────────────
-- 기존 확정이 반영 대기를 비우므로 표 제목은 먼저 모아 두고, 기존 확정이 끝난 뒤에 쓴다.
do $$
begin
  if not exists (select 1 from pg_proc where proname = 'textbook_review_apply_staged_common') then
    alter function public.textbook_review_apply_staged(uuid[]) rename to textbook_review_apply_staged_common;
  end if;
end $$;

revoke all on function public.textbook_review_apply_staged_common(uuid[]) from public, anon, authenticated;

create or replace function public.textbook_review_apply_staged(p_crop_ids uuid[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_labels jsonb;
  v_checked jsonb;
  v_res jsonb;
  v_row record;
  v_n int := 0;
begin
  if not (select public.is_superadmin()) then
    raise exception 'textbook_review_forbidden';
  end if;
  if p_crop_ids is null or cardinality(p_crop_ids) = 0 then
    return jsonb_build_object('ok', true, 'applied', 0);
  end if;

  select coalesce(jsonb_object_agg(an.crop_id::text, an.staged_changes -> 'blank_choice_labels'), '{}'::jsonb)
    into v_labels
    from public.textbook_problem_analyses an
   where an.crop_id = any (p_crop_ids)
     and jsonb_typeof(an.staged_changes -> 'blank_choice_labels') = 'array'
     and jsonb_array_length(an.staged_changes -> 'blank_choice_labels') between 2 and 4;

  v_res := public.textbook_review_apply_staged_common(p_crop_ids);

  if v_labels = '{}'::jsonb then
    return v_res;
  end if;

  select coalesce(jsonb_object_agg(an.crop_id::text, an.render_checked_at), '{}'::jsonb)
    into v_checked
    from public.textbook_problem_analyses an
   where an.crop_id = any (p_crop_ids);

  for v_row in select e.key::uuid as crop_id, e.value as labels from jsonb_each(v_labels) e loop
    update public.pb_questions q
       set meta = jsonb_set(coalesce(q.meta, '{}'::jsonb), '{blank_choice_labels}', v_row.labels, true),
           updated_at = now()
     where q.id = public.textbook_review_linked_pb_question(v_row.crop_id)
       and (q.meta -> 'blank_choice_labels') is distinct from v_row.labels;
    v_n := v_n + 1;
  end loop;

  -- 확정으로 내용이 바뀐 것이 아니므로 렌더 검수 기록은 그대로 둔다.
  update public.textbook_problem_analyses an
     set render_checked_at = (v_checked ->> an.crop_id::text)::timestamptz
   where an.crop_id = any (p_crop_ids)
     and v_checked ? an.crop_id::text;

  return v_res || jsonb_build_object('blank_choice_labels', v_n);
end;
$$;

revoke all on function public.textbook_review_apply_staged(uuid[]) from public, anon;
grant execute on function public.textbook_review_apply_staged(uuid[]) to authenticated;

notify pgrst, 'reload schema';
