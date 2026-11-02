-- 20261102223000: 문항검수 본문 수정 적용에 공통 발문(common_stem) 수정 추가
--
-- 추출 단계에서 세트 문항의 공통 발문(meta.set_model.common_stem)에 개별 문항 본문까지 통째로 들어간 경우가 있다.
-- 학생 화면은 공통 발문 + 개별 발문을 이어 그리므로 지시문·답란이 두 번 보인다.
-- 공통 발문은 세트 전체가 공유하므로, 같은 문서의 같은 세트 키를 가진 문항 전부에 같은 값을 쓴다.

drop function if exists public.textbook_review_apply_problem_fix(uuid, text, jsonb, boolean, text);

create or replace function public.textbook_review_apply_problem_fix(
  p_crop_id uuid,
  p_stem text default null,
  p_choices jsonb default null,
  p_approve_quality boolean default false,
  p_note text default null,
  p_common_stem text default null
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
  v_set_key text;
  v_set_members int := 0;
  v_cur_common text;
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
  if v_pq_id is not null and (p_stem is not null or p_choices is not null or p_common_stem is not null) then
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

    if p_common_stem is not null then
      v_cur_common := btrim(coalesce(v_pq.meta -> 'set_model' ->> 'common_stem', v_pq.meta -> 'set_model' ->> 'commonStem', ''));
      if v_cur_common is distinct from btrim(p_common_stem) then
        v_set_key := nullif(btrim(coalesce(
          v_pq.meta -> 'delivery_unit' ->> 'set_id',
          v_pq.meta -> 'delivery_unit' ->> 'set_key',
          v_pq.meta -> 'set_model' ->> 'set_key',
          v_pq.meta -> 'set_model' ->> 'setKey',
          ''
        )), '');
        -- 세트 전체(같은 문서·같은 세트 키) 또는 세트 키가 없으면 이 문항만
        with target as (
          select q.id
            from public.pb_questions q
           where q.id = v_pq_id
              or (
                v_set_key is not null
                and q.document_id is not distinct from v_pq.document_id
                and v_set_key = nullif(btrim(coalesce(
                      q.meta -> 'delivery_unit' ->> 'set_id',
                      q.meta -> 'delivery_unit' ->> 'set_key',
                      q.meta -> 'set_model' ->> 'set_key',
                      q.meta -> 'set_model' ->> 'setKey',
                      ''
                    )), '')
              )
        ),
        upd as (
          update public.pb_questions q
             set meta = jsonb_set(
                   case
                     when (coalesce(q.meta, '{}'::jsonb) -> 'delivery_unit') ? 'common_stem'
                       then jsonb_set(coalesce(q.meta, '{}'::jsonb), '{delivery_unit,common_stem}', to_jsonb(p_common_stem))
                     else coalesce(q.meta, '{}'::jsonb)
                   end,
                   '{set_model}',
                   (coalesce(q.meta -> 'set_model', '{}'::jsonb) - 'commonStem') || jsonb_build_object('common_stem', p_common_stem)
                 ),
                 updated_at = now()
            from target t
           where q.id = t.id
          returning q.id
        )
        select count(*) into v_set_members from upd;
        v_changed := v_changed || 'common_stem';
      end if;
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
    'set_members_updated', v_set_members,
    'approved', p_approve_quality
  );
end;
$$;

revoke all on function public.textbook_review_apply_problem_fix(uuid, text, jsonb, boolean, text, text) from public, anon;
grant execute on function public.textbook_review_apply_problem_fix(uuid, text, jsonb, boolean, text, text) to authenticated;
