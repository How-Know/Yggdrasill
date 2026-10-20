-- 20261013100000: 조율본 질문에 답하면 지시를 하나로 정리한다
-- - 질문의 보기마다 "고르면 추가할 단계"(options[].instructions), 질문마다 "답이 나올 때까지만 지킬 조건"(holds)이 붙을 수 있다.
-- - 답하면: 고른 보기의 단계만 instructions 뒤에 붙인다. 고르지 않은 보기의 단계와 holds는 지시·제약에서 빼고
--   discarded_branches(이력)에만 남긴다. Cursor와 수정 작업자에게는 보이지 않는다.
-- - owner_answers 항목에 plan_request_id·answer_round·option_id를 남긴다. 회차마다 q1부터 다시 세는 옛 질문 id도
--   (plan_request_id, id)로 구분된다. 같은 "운영자 결정" 줄은 제약에 한 번만 남는다.
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
  v_other jsonb;
  v_answer text;
  v_answers jsonb := '[]'::jsonb;
  v_lines jsonb := '[]'::jsonb;
  v_steps jsonb := '[]'::jsonb;
  v_dropped jsonb := '[]'::jsonb;
  v_drop_text jsonb := '[]'::jsonb;
  v_prev_answers jsonb;
  v_instructions jsonb;
  v_constraints jsonb;
  v_plan_req text;
  v_answer_round integer;
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

  v_plan_req := v_act.payload ->> 'plan_request_id';
  v_prev_answers := coalesce(case when jsonb_typeof(v_spec -> 'owner_answers') = 'array' then v_spec -> 'owner_answers' end, '[]'::jsonb);
  select 1 + count(distinct coalesce(a.value ->> 'plan_request_id', 'legacy'))::integer into v_answer_round
    from jsonb_array_elements(v_prev_answers) a;

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
      if jsonb_typeof(v_opt -> 'instructions') = 'array' then
        v_steps := v_steps || coalesce((
          select jsonb_agg(s.value) from jsonb_array_elements(v_opt -> 'instructions') s
           where jsonb_typeof(s.value) = 'string' and btrim(s.value #>> '{}') <> ''
        ), '[]'::jsonb);
      end if;
    else
      v_answer := left(btrim(coalesce(v_ans ->> 'text', '')), 1000);
      if v_answer = '' then
        raise exception 'plan_answer_missing' using errcode = '22023';
      end if;
    end if;

    for v_other in select value from jsonb_array_elements(v_dec -> 'options') loop
      if (v_opt is null or v_other ->> 'id' is distinct from v_opt ->> 'id')
         and jsonb_typeof(v_other -> 'instructions') = 'array' and jsonb_array_length(v_other -> 'instructions') > 0 then
        v_dropped := v_dropped || jsonb_build_array(jsonb_build_object(
          'kind', 'option',
          'plan_request_id', v_plan_req,
          'decision_id', v_dec ->> 'id',
          'question', coalesce(v_dec ->> 'question', ''),
          'label', coalesce(v_other ->> 'label', ''),
          'instructions', v_other -> 'instructions'
        ));
        v_drop_text := v_drop_text || (v_other -> 'instructions');
      end if;
    end loop;
    if jsonb_typeof(v_dec -> 'holds') = 'array' and jsonb_array_length(v_dec -> 'holds') > 0 then
      v_dropped := v_dropped || jsonb_build_array(jsonb_build_object(
        'kind', 'hold',
        'plan_request_id', v_plan_req,
        'decision_id', v_dec ->> 'id',
        'question', coalesce(v_dec ->> 'question', ''),
        'holds', v_dec -> 'holds'
      ));
      v_drop_text := v_drop_text || (v_dec -> 'holds');
    end if;

    v_answers := v_answers || jsonb_build_array(jsonb_build_object(
      'id', v_dec ->> 'id',
      'plan_request_id', v_plan_req,
      'answer_round', v_answer_round,
      'question', coalesce(v_dec ->> 'question', ''),
      'answer', v_answer,
      'option_id', v_opt ->> 'id',
      'detail', left(coalesce(v_opt ->> 'detail', ''), 600),
      'custom', v_opt is null
    ));
    v_lines := v_lines || to_jsonb('운영자 결정 — ' || coalesce(v_dec ->> 'question', '') || ': ' || v_answer);
  end loop;

  select coalesce(jsonb_agg(x.value order by x.n), '[]'::jsonb) into v_instructions
    from jsonb_array_elements(coalesce(case when jsonb_typeof(v_spec -> 'instructions') = 'array' then v_spec -> 'instructions' end, '[]'::jsonb))
         with ordinality as x(value, n)
   where not (v_drop_text @> jsonb_build_array(x.value));
  select v_instructions || coalesce(jsonb_agg(s.value order by s.n), '[]'::jsonb) into v_instructions
    from jsonb_array_elements(v_steps) with ordinality as s(value, n)
   where not (v_instructions @> jsonb_build_array(s.value));

  select coalesce(jsonb_agg(x.value order by x.n), '[]'::jsonb) into v_constraints
    from jsonb_array_elements(coalesce(case when jsonb_typeof(v_spec -> 'constraints') = 'array' then v_spec -> 'constraints' end, '[]'::jsonb))
         with ordinality as x(value, n)
   where not (v_drop_text @> jsonb_build_array(x.value)) and not (v_lines @> jsonb_build_array(x.value));
  v_constraints := v_constraints || v_lines;

  v_new := (v_spec - 'decisions' - 'disagreements' - 'owner_questions') || jsonb_build_object(
    'instructions', v_instructions,
    'constraints', v_constraints,
    'owner_answers', v_prev_answers || v_answers,
    'discarded_branches', coalesce(case when jsonb_typeof(v_spec -> 'discarded_branches') = 'array' then v_spec -> 'discarded_branches' end, '[]'::jsonb) || v_dropped,
    'questions', jsonb_build_array(
      '운영자가 정한 것(제약의 "운영자 결정")을 반영한 단계가 코드상 맞는지, 고칠 단계가 있는지. 이미 정한 것은 다시 묻지 않는다. ' ||
      '결정과 코드가 실제로 부딪히면 owner_decision_conflicts에 근거와 함께 따로 적는다.'
    )
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
         result = jsonb_build_object('answers', v_answers, 'revision_request_id', v_req, 'revision_action_id', v_row.id,
                                     'discarded', v_dropped)
   where id = v_act.id;
  return v_row;
end
$$;

revoke all on function public.ai_code_plan_revise(uuid, jsonb) from public, anon;
grant execute on function public.ai_code_plan_revise(uuid, jsonb) to authenticated;
