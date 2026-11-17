-- 20261114120000: 세트 공통 그림의 크기·배치(set_model.common_figure_layout)를 반영 대기 값으로 다룬다.
--
-- 세트 문항 카드의 공통 그림은 문항 배치(meta.figure_layout)가 아니라 세트 공통 배치로 그려진다.
-- 문항 그림 파일이 공통 그림과 다르면(문항마다 따로 자른 사본) 확정 때 트리거도 공통 배치를 맞추지 않는다.
-- 그래서 공통 그림 크기는 'common_figure_layout' 반영 대기 키로 따로 쌓는다.
--
-- 1) textbook_review_stage_changes: 'common_figure_layout' 키를 받고, 공통 발문처럼 같은 세트 문항에도 반영 대기로 넣는다.
-- 2) textbook_review_overlay_staged / textbook_review_unit_overview: 문제은행 공통 배치(pb_common_figure_layout) 위에 반영 대기 값을 겹쳐 준다.
-- 3) textbook_review_apply_staged: 기존 확정 반영 뒤 같은 세트 문제은행 문항 모두의 공통 배치를 쓴다.

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
    'stem', 'common_stem', 'choices', 'figure_layout', 'figure_assets', 'common_figure_layout', 'answer',
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
      'pb_common_figure_layout', p_item -> 'pb_common_figure_layout',
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
  if st ? 'common_figure_layout' then
    r := r || jsonb_build_object('pb_common_figure_layout', st -> 'common_figure_layout');
  end if;
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
    select jsonb_agg(
             (public.textbook_review_overlay_staged(
                e.item || jsonb_build_object('pb_common_figure_layout', pq.meta #> '{set_model,common_figure_layout}'),
                an.staged_changes
              ) - 'findings')
               || jsonb_build_object(
                    'findings', coalesce((
                      select jsonb_agg(fx.f order by fx.ord)
                        from jsonb_array_elements(coalesce(e.item -> 'findings', '[]'::jsonb)) with ordinality as fx(f, ord)
                       where not exists (
                         select 1
                           from jsonb_array_elements(cons.list) ci
                          where ci ->> 'id' = fx.f ->> 'id'
                       )
                    ), '[]'::jsonb),
                    'consistency_issues', cons.list,
                    'concept_proposals', coalesce(an.concept_proposals, '[]'::jsonb),
                    'meta_checked_at', an.meta_checked_at,
                    'meta_sources', coalesce(an.meta_sources, '{}'::jsonb)
                  )
             order by e.ord)
      from jsonb_array_elements(coalesce(v -> 'items', '[]'::jsonb)) with ordinality as e(item, ord)
      left join public.textbook_problem_analyses an
        on an.crop_id = (e.item ->> 'crop_id')::uuid
      left join public.pb_questions pq
        on pq.id = nullif(e.item ->> 'pb_question_id', '')::uuid
      cross join lateral (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'id', f.id,
                 'code', substr(f.check_key, length('consistency:') + 1),
                 'axis', f.axis,
                 'title', f.title,
                 'detail', f.detail,
                 'status', f.status
               ) order by f.created_at), '[]'::jsonb) as list
          from public.textbook_review_findings f
         where f.academy_id = p_academy_id
           and f.crop_id = (e.item ->> 'crop_id')::uuid
           and f.check_key <> ''
           and f.check_key like 'consistency:%'
           and f.status in ('open', 'held')
      ) cons
  ), '[]'::jsonb));
end;
$$;

revoke all on function public.textbook_review_unit_overview(uuid, uuid, text, int, int) from public, anon;
grant execute on function public.textbook_review_unit_overview(uuid, uuid, text, int, int) to authenticated;

-- ── 3) 확정 때 공통 배치 쓰기 ────────────────────────────────────────────
-- 기존 확정(textbook_review_apply_staged_base)이 반영 대기를 비우므로 공통 배치는 먼저 모아 둔다.
-- 문항 배치를 쓰면 트리거가 공통 배치를 문항 배치로 맞출 수 있어, 공통 배치는 기존 확정이 끝난 뒤에 쓴다.
do $$
begin
  if not exists (select 1 from pg_proc where proname = 'textbook_review_apply_staged_base') then
    alter function public.textbook_review_apply_staged(uuid[]) rename to textbook_review_apply_staged_base;
  end if;
end $$;

revoke all on function public.textbook_review_apply_staged_base(uuid[]) from public, anon, authenticated;

create or replace function public.textbook_review_apply_staged(p_crop_ids uuid[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_common jsonb;
  v_checked jsonb;
  v_res jsonb;
  v_row record;
  v_pq public.pb_questions;
  v_set_key text;
  v_n int := 0;
begin
  if not (select public.is_superadmin()) then
    raise exception 'textbook_review_forbidden';
  end if;
  if p_crop_ids is null or cardinality(p_crop_ids) = 0 then
    return jsonb_build_object('ok', true, 'applied', 0);
  end if;

  select coalesce(jsonb_object_agg(an.crop_id::text, an.staged_changes -> 'common_figure_layout'), '{}'::jsonb)
    into v_common
    from public.textbook_problem_analyses an
   where an.crop_id = any (p_crop_ids)
     and jsonb_typeof(an.staged_changes -> 'common_figure_layout') = 'object';

  v_res := public.textbook_review_apply_staged_base(p_crop_ids);

  if v_common = '{}'::jsonb then
    return v_res;
  end if;

  select coalesce(jsonb_object_agg(an.crop_id::text, an.render_checked_at), '{}'::jsonb)
    into v_checked
    from public.textbook_problem_analyses an
   where an.crop_id = any (p_crop_ids);

  for v_row in select e.key::uuid as crop_id, e.value as layout from jsonb_each(v_common) e loop
    select * into v_pq from public.pb_questions where id = public.textbook_review_linked_pb_question(v_row.crop_id);
    continue when v_pq.id is null;
    v_set_key := public.textbook_question_set_key(v_pq.meta);
    update public.pb_questions q
       set meta = jsonb_set(coalesce(q.meta, '{}'::jsonb), '{set_model,common_figure_layout}', v_row.layout, true),
           updated_at = now()
     where (q.id = v_pq.id
            or (v_set_key is not null
                and q.academy_id = v_pq.academy_id
                and q.document_id = v_pq.document_id
                and public.textbook_question_set_key(q.meta) = v_set_key))
       and jsonb_typeof(q.meta -> 'set_model') = 'object'
       and (q.meta #> '{set_model,common_figure_layout}') is distinct from v_row.layout;
    v_n := v_n + 1;
  end loop;

  update public.textbook_problem_analyses an
     set render_checked_at = (v_checked ->> an.crop_id::text)::timestamptz
   where an.crop_id = any (p_crop_ids)
     and v_checked ? an.crop_id::text;

  return v_res || jsonb_build_object('common_figure_layouts', v_n);
end;
$$;

revoke all on function public.textbook_review_apply_staged(uuid[]) from public, anon;
grant execute on function public.textbook_review_apply_staged(uuid[]) to authenticated;

notify pgrst, 'reload schema';
