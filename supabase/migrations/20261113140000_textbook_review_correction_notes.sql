-- 20261113140000: 반영 대기 소견 정리를 바로잡고, 교정 의견을 확정 전에 처리하게 한다.
-- (docs/specs/20261113-교재-문항-검수-흐름과-기준.md 2-2번·4-4번)
--
-- 1) textbook_review_stage_changes: 통과(clean)로 둘 때 소견을 허용된 resolution 값으로 닫는다
--    (사장님 'manual_edit', AI 'auto_cleared'). 교정 의견은 여기서 닫지 않는다. 해설 논리 오류는 사장님 판정만 닫는다.
-- 2) textbook_review_apply_staged: 처리하지 않은 교정 의견이 있으면 확정하지 않는다.
-- 3) textbook_review_close_correction_note: 사장님이 교정 의견을 확인(noted)하거나 기각(dismissed)한다.
--    교재 원본은 바꾸지 않는다.

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
  v_notes text;
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

  select string_agg(distinct c.problem_number, ', ')
    into v_notes
    from public.textbook_review_findings f
    join public.textbook_problem_crops c on c.id = f.crop_id
   where f.crop_id = any (p_crop_ids)
     and f.proposal ->> 'target' = 'correction_note'
     and f.status in ('open', 'held');
  if v_notes is not null then
    raise exception 'textbook_review_correction_note_open: %', v_notes;
  end if;

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

-- 교정 의견 처리. p_dismiss=false 면 확인(교재 오류로 기록), true 면 기각(교재 오류 아님).
create or replace function public.textbook_review_close_correction_note(
  p_finding_id uuid,
  p_dismiss boolean default false,
  p_note text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  f public.textbook_review_findings;
begin
  if not (select public.is_superadmin()) then
    raise exception 'textbook_review_forbidden';
  end if;
  select * into f from public.textbook_review_findings where id = p_finding_id for update;
  if not found then
    raise exception 'textbook_review_finding_not_found';
  end if;
  if coalesce(f.proposal ->> 'target', '') <> 'correction_note' then
    raise exception 'textbook_review_not_correction_note';
  end if;
  if f.status not in ('open', 'held') then
    raise exception 'textbook_review_closed';
  end if;

  update public.textbook_review_findings
     set status = case when p_dismiss then 'dismissed' else 'resolved' end,
         resolution = case when p_dismiss then 'dismissed' else 'noted' end,
         resolved_at = now()
   where id = f.id;

  insert into public.textbook_review_decisions (
    academy_id, crop_id, finding_id, action, target, before_value, after_value, note, fingerprint_seen
  ) values (
    f.academy_id, f.crop_id, f.id,
    case when p_dismiss then 'dismiss' else 'apply_proposal' end,
    'correction_note', null, f.proposal -> 'after', coalesce(p_note, ''), '{}'::jsonb
  );

  return jsonb_build_object('ok', true, 'finding_id', f.id, 'status', case when p_dismiss then 'dismissed' else 'resolved' end);
end;
$$;

revoke all on function public.textbook_review_close_correction_note(uuid, boolean, text) from public, anon;
grant execute on function public.textbook_review_close_correction_note(uuid, boolean, text) to authenticated;

notify pgrst, 'reload schema';
