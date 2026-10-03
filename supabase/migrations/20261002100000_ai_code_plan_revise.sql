-- 20261002100000: 조율본 질문에 운영자가 답하면 다시 조율한다
-- - 조율이 끝나도 운영자만 정할 수 있는 것·끝까지 갈린 의견은 조율본의 spec.decisions(객관식 질문)로 남는다.
-- - 운영자가 모든 질문에 답하면(보기 또는 직접 입력) 그 답을 조율본에 '운영자 결정'으로 붙여 조율을 1회 더 돌린다.
--   Cursor가 코드에 비춰 확인하고, Think가 새 조율본을 올린다. 하루 요청 한도가 그대로 적용된다.
-- - 이전 조율본은 대체됨(rejected, superseded)으로 닫고 고른 답을 result에 남긴다.
-- 설계: docs/architecture/ai-think-actions.md §4.3

create or replace function public.ai_code_plan_revise(p_action_id uuid, p_answers jsonb)
returns public.ai_actions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_act public.ai_actions;
  v_spec jsonb;
  v_dec jsonb;
  v_ans jsonb;
  v_opt jsonb;
  v_answer text;
  v_answers jsonb := '[]'::jsonb;
  v_lines jsonb := '[]'::jsonb;
  v_new jsonb;
  v_title text;
  v_req uuid;
  v_row public.ai_actions;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into v_act from public.ai_actions where id = p_action_id for update;
  if not found then
    raise exception 'action_not_found' using errcode = 'P0002';
  end if;
  if v_act.kind <> 'code_change' or v_act.status <> 'proposed' or coalesce(v_act.payload ->> 'plan_request_id', '') = '' then
    raise exception 'action_not_pending' using errcode = '22023';
  end if;
  v_spec := v_act.payload -> 'spec';
  if jsonb_typeof(v_spec -> 'decisions') is distinct from 'array' or jsonb_array_length(v_spec -> 'decisions') = 0 then
    raise exception 'plan_no_decisions' using errcode = '22023';
  end if;
  if p_answers is null or jsonb_typeof(p_answers) <> 'array' then
    raise exception 'plan_answer_missing' using errcode = '22023';
  end if;

  for v_dec in select value from jsonb_array_elements(v_spec -> 'decisions') loop
    v_ans := null;
    v_opt := null;
    select a.value into v_ans from jsonb_array_elements(p_answers) a where a.value ->> 'id' = v_dec ->> 'id' limit 1;
    if v_ans is null then
      raise exception 'plan_answer_missing' using errcode = '22023';
    end if;
    if coalesce(v_ans ->> 'option_id', '') <> '' then
      select o.value into v_opt from jsonb_array_elements(v_dec -> 'options') o where o.value ->> 'id' = v_ans ->> 'option_id' limit 1;
      if v_opt is null then
        raise exception 'plan_answer_invalid' using errcode = '22023';
      end if;
      v_answer := coalesce(v_opt ->> 'label', '');
    else
      v_answer := left(btrim(coalesce(v_ans ->> 'text', '')), 1000);
      if v_answer = '' then
        raise exception 'plan_answer_missing' using errcode = '22023';
      end if;
    end if;
    v_answers := v_answers || jsonb_build_array(jsonb_build_object(
      'id', v_dec ->> 'id',
      'question', coalesce(v_dec ->> 'question', ''),
      'answer', v_answer,
      'detail', left(coalesce(v_opt ->> 'detail', ''), 600),
      'custom', v_opt is null
    ));
    v_lines := v_lines || to_jsonb('운영자 결정 — ' || coalesce(v_dec ->> 'question', '') || ': ' || v_answer);
  end loop;

  v_new := (v_spec - 'decisions' - 'disagreements' - 'owner_questions') || jsonb_build_object(
    'constraints', coalesce(case when jsonb_typeof(v_spec -> 'constraints') = 'array' then v_spec -> 'constraints' end, '[]'::jsonb) || v_lines,
    'owner_answers', coalesce(case when jsonb_typeof(v_spec -> 'owner_answers') = 'array' then v_spec -> 'owner_answers' end, '[]'::jsonb) || v_answers,
    'questions', jsonb_build_array('운영자가 정한 것(제약의 "운영자 결정")을 반영했을 때 계획 단계에 코드상 문제가 없는지, 고칠 단계가 있는지')
  );
  if btrim(coalesce(v_new ->> 'goal', '')) = '' then
    raise exception 'code_request_goal_required' using errcode = '22023';
  end if;
  v_title := left(coalesce(nullif(btrim(v_act.payload ->> 'title'), ''), '조율본'), 200);

  insert into public.ai_code_requests (conversation_id, title, request, mode, max_rounds)
  values (v_act.conversation_id, v_title, v_new, 'plan', 1)
  returning id into v_req;
  perform public.ai_code_request_submit(v_req);

  insert into public.ai_actions (conversation_id, message_id, kind, status, payload, preview, result, decided_at, decided_by)
  values (
    v_act.conversation_id,
    v_act.message_id,
    'code_plan',
    'applied',
    jsonb_build_object('title', v_title, 'spec', v_new, 'revises_action_id', v_act.id),
    jsonb_build_object('title', v_title, 'goal', left(coalesce(v_new ->> 'goal', ''), 300), 'mode', 'plan',
                       'revision', true, 'answers', jsonb_array_length(v_answers)),
    jsonb_build_object('code_request_id', v_req),
    now(),
    auth.uid()
  )
  returning * into v_row;

  update public.ai_actions
     set status = 'rejected',
         superseded = true,
         decided_at = now(),
         decided_by = auth.uid(),
         result = jsonb_build_object('answers', v_answers, 'revision_request_id', v_req, 'revision_action_id', v_row.id)
   where id = v_act.id;
  return v_row;
end
$$;

revoke all on function public.ai_code_plan_revise(uuid, jsonb) from public, anon;
grant execute on function public.ai_code_plan_revise(uuid, jsonb) to authenticated;
