-- 20261110030000: 문항 유형을 바꾸면 문제은행 정답도 다시 맞춘다.
--
--   객관식(원문 선지가 있는 문항): objective_answer_key = 채점 정답 원문자, 주관식 허용이면 subjective_answer = 그 선지 내용.
--     주관식 허용은 p_allow_subjective 로 정한다(답이 하나이고 "다음 중" 처럼 선지를 가리키지 않을 때만 주관식으로도 낸다).
--   주관식: 원문 선지가 없으므로 채점 정답(숫자 포함)을 객관식 정답 키로 바꾸지 않는다. AI 가 만든 객관식 보기 정답은 그대로 둔다.
--   서술형: 객관식 허용을 끈다.

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
  v_native boolean;
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

  v_native := jsonb_typeof(v_pq.choices) = 'array' and jsonb_array_length(v_pq.choices) >= 2;
  v_key := case when v_native then public.textbook_review_objective_key(v_ans) else '' end;

  if v_pq.allow_objective and v_key <> '' and v_pq.objective_answer_key is distinct from v_key then
    v_changed := array_append(v_changed, 'objective_answer_key'::text);
  end if;

  if v_pq.allow_subjective or not v_pq.allow_objective then
    if v_key <> '' then
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
    'answer_key', coalesce(v_subj, nullif(v_key, ''), v_ans),
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

drop function if exists public.textbook_review_set_question_kind(uuid, text);

create or replace function public.textbook_review_set_question_kind(
  p_crop_id uuid,
  p_kind text,
  p_allow_subjective boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pq_id uuid;
  v_pq public.pb_questions;
  v_type text;
  v_obj boolean;
  v_subj boolean;
  v_essay boolean;
  v_ans text;
  v_kind text;
  v_changed boolean := false;
begin
  if not (select public.is_superadmin()) then
    raise exception 'textbook_review_forbidden';
  end if;
  if p_kind not in ('objective', 'subjective', 'essay') then
    raise exception 'textbook_review_bad_kind';
  end if;
  v_pq_id := public.textbook_review_linked_pb_question(p_crop_id);
  if v_pq_id is null then
    return jsonb_build_object('ok', false, 'reason', 'no_pb_question');
  end if;
  select * into v_pq from public.pb_questions where id = v_pq_id;

  if p_kind = 'objective' then
    v_type := '객관식';
    v_obj := true;
    v_subj := coalesce(p_allow_subjective, v_pq.allow_subjective, false);
    v_essay := false;
  elsif p_kind = 'subjective' then
    v_type := '주관식';
    v_obj := coalesce(v_pq.allow_objective, false);
    v_subj := true;
    v_essay := false;
  else
    v_type := '서술형';
    v_obj := false;
    v_subj := true;
    v_essay := true;
  end if;

  if not (v_pq.question_type is not distinct from v_type
     and v_pq.allow_objective is not distinct from v_obj
     and v_pq.allow_subjective is not distinct from v_subj
     and coalesce((v_pq.meta ->> 'allow_essay')::boolean, false) = v_essay) then
    update public.pb_questions
       set question_type = v_type,
           allow_objective = v_obj,
           allow_subjective = v_subj,
           meta = coalesce(meta, '{}'::jsonb)
             || jsonb_build_object('allow_objective', v_obj, 'allow_subjective', v_subj, 'allow_essay', v_essay),
           updated_at = now()
     where id = v_pq_id;
    v_changed := true;
  end if;

  select coalesce(nullif(btrim(a.answer_text), ''), nullif(btrim(a.answer_latex_2d), '')), a.answer_kind
    into v_ans, v_kind
    from public.textbook_problem_answers a
   where a.crop_id = p_crop_id;
  if v_ans is not null and coalesce(v_kind, '') <> 'image'
     and v_ans !~* '^(\[?\s*image\s*\]?|\(\s*image\s*\)|\[그림\])$' then
    perform set_config('yggdrasill.manual_override', 'on', true);
    update public.textbook_problem_answers
       set answer_kind = case when p_kind = 'objective' then 'objective' else 'subjective' end
     where crop_id = p_crop_id
       and answer_kind is distinct from case when p_kind = 'objective' then 'objective' else 'subjective' end;
    perform set_config('yggdrasill.manual_override', '', true);
    perform public.textbook_review_sync_pb_answer(p_crop_id, v_ans);
  end if;

  return jsonb_build_object('ok', true, 'changed', v_changed, 'pb_question_id', v_pq_id, 'question_type', v_type);
end;
$$;

revoke all on function public.textbook_review_set_question_kind(uuid, text, boolean) from public, anon;
grant execute on function public.textbook_review_set_question_kind(uuid, text, boolean) to authenticated;

-- 원문 선지가 있는데 문제은행 객관식 정답 키가 채점 정답과 다른 문항을 바로잡는다.
do $$
declare
  r record;
begin
  for r in
    select c.id as crop_id,
           coalesce(nullif(btrim(a.answer_text), ''), nullif(btrim(a.answer_latex_2d), '')) as ans
      from public.textbook_problem_crops c
      join public.textbook_problem_answers a on a.crop_id = c.id
      join public.pb_questions pq on pq.id = public.textbook_review_linked_pb_question(c.id)
     where coalesce(a.answer_kind, '') <> 'image'
       and pq.allow_objective
       and jsonb_typeof(pq.choices) = 'array' and jsonb_array_length(pq.choices) >= 2
       and coalesce(nullif(btrim(a.answer_text), ''), a.answer_latex_2d) ~ '[①②③④⑤⑥⑦⑧⑨⑩]'
       and public.textbook_review_objective_key(coalesce(nullif(btrim(a.answer_text), ''), a.answer_latex_2d)) <> ''
       and coalesce(pq.objective_answer_key, '')
           is distinct from public.textbook_review_objective_key(coalesce(nullif(btrim(a.answer_text), ''), a.answer_latex_2d))
  loop
    perform set_config('yggdrasill.manual_override', 'on', true);
    update public.textbook_problem_answers
       set answer_kind = 'objective'
     where crop_id = r.crop_id and answer_kind = 'subjective';
    perform set_config('yggdrasill.manual_override', '', true);
    perform public.textbook_review_sync_pb_answer(r.crop_id, r.ans);
  end loop;
end;
$$;
