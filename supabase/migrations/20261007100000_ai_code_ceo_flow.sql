-- 20261007100000: Think가 Cursor 작업을 이끈다 (운영자 결정 2026-10-06)
-- - 운영자는 작업 폴더 적용과 운영 DB 반영만 승인한다. 조율·수정·자동 검사·재수정은 Think가 이어서 맡긴다.
-- - 운영자에게 물을 것 없이 끝난 조율본은 Think가 바로 수정 요청으로 보낸다(ai_code_bridge_start_change).
-- - 자동 검사에서 실패한 수정은 Think가 최대 2회 다시 고치게 한다(ai_code_bridge_fix). 매번 하루 한도 1건을 쓴다.
-- - 재수정 작업은 앞 수정의 diff와 기준 커밋에서 이어 간다(ai_code_bridge_fix_source).
-- - 서버가 만든 요청도 대화에 카드가 보이도록 '실행됨' 상태의 code_change 행을 남긴다(ai_code_plan_start와 같은 방식).
-- 설계: docs/architecture/ai-think-actions.md §4.6

-- ---------------------------------------------------------------------------
-- 1) 대기열에 넣기. 앱(ai_code_request_submit)과 서버 자동 경로가 같은 하루 한도를 쓴다.
-- ---------------------------------------------------------------------------
create or replace function public.ai_code_request_enqueue(p_id uuid)
returns public.ai_code_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.ai_code_requests;
  v_limit integer;
  v_today integer;
begin
  select code_request_daily_limit into v_limit from public.ai_platform_settings where id for update;
  select * into v_row from public.ai_code_requests where id = p_id for update;
  if not found then
    raise exception 'code_request_not_found' using errcode = 'P0002';
  end if;
  if v_row.status <> 'draft' then
    raise exception 'code_request_not_draft' using errcode = '22023';
  end if;
  if nullif(btrim(coalesce(v_row.request ->> 'goal', '')), '') is null then
    raise exception 'code_request_goal_required' using errcode = '22023';
  end if;
  select count(*) into v_today
    from public.ai_code_requests
   where submitted_at >= (date_trunc('day', now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul');
  if v_today >= coalesce(v_limit, 10) then
    raise exception 'code_request_daily_limit' using errcode = '22023', detail = coalesce(v_limit, 10)::text;
  end if;
  update public.ai_code_requests
     set status = 'queued',
         submitted_at = now(),
         round = 0,
         attempts = 0,
         last_error = null,
         cancel_requested = false
   where id = p_id
   returning * into v_row;
  return v_row;
end
$$;

revoke all on function public.ai_code_request_enqueue(uuid) from public, anon, authenticated;
grant execute on function public.ai_code_request_enqueue(uuid) to service_role;

create or replace function public.ai_code_request_submit(p_id uuid)
returns public.ai_code_requests
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return public.ai_code_request_enqueue(p_id);
end
$$;

-- ---------------------------------------------------------------------------
-- 2) 조율본 → 바로 수정 (service role, 결과 검토 code_review.ts)
-- ---------------------------------------------------------------------------
-- 하루 한도에 걸리면 아무것도 만들지 않고 { ok: false, error: 'code_request_daily_limit' }.
-- 그때 검토는 예전처럼 승인 대기 카드를 올려 운영자가 나중에 보내게 한다.
create or replace function public.ai_code_bridge_start_change(
  p_plan_request_id uuid,
  p_message_id uuid,
  p_title text,
  p_spec jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_plan public.ai_code_requests;
  v_title text := left(btrim(coalesce(p_title, '')), 200);
  v_msg uuid;
  v_req uuid;
  v_action uuid;
begin
  select * into v_plan from public.ai_code_requests where id = p_plan_request_id for update;
  if not found or v_plan.mode <> 'plan' or v_plan.conversation_id is null then
    return jsonb_build_object('ok', false, 'error', 'not_plan');
  end if;
  if p_spec is null or jsonb_typeof(p_spec) <> 'object'
     or jsonb_typeof(p_spec -> 'instructions') <> 'array' or jsonb_array_length(p_spec -> 'instructions') = 0 then
    return jsonb_build_object('ok', false, 'error', 'no_instructions');
  end if;
  if exists (
    select 1 from public.ai_code_requests r
     where r.mode = 'change'
       and r.request -> 'based_on_plan' ->> 'id' = p_plan_request_id::text
       and r.request -> 'fix_of' is null
  ) then
    return jsonb_build_object('ok', false, 'error', 'already_started');
  end if;
  if v_title = '' then
    v_title := v_plan.title;
  end if;
  v_msg := case
    when exists (select 1 from public.ai_messages m where m.id = p_message_id and m.conversation_id = v_plan.conversation_id)
    then p_message_id
  end;
  begin
    insert into public.ai_code_requests (conversation_id, source_message_ids, title, request, mode, max_rounds, created_by)
    values (v_plan.conversation_id, array_remove(array[v_msg], null), v_title, p_spec, 'change', 1, v_plan.created_by)
    returning id into v_req;
    perform public.ai_code_request_enqueue(v_req);
  exception when others then
    if sqlerrm = 'code_request_daily_limit' then
      return jsonb_build_object('ok', false, 'error', 'code_request_daily_limit');
    end if;
    raise;
  end;
  update public.ai_actions
     set status = 'rejected', superseded = true, decided_at = now()
   where conversation_id = v_plan.conversation_id
     and kind = 'code_change'
     and status = 'proposed';
  insert into public.ai_actions (conversation_id, message_id, kind, status, payload, preview, result, decided_at, created_by)
  values (
    v_plan.conversation_id,
    v_msg,
    'code_change',
    'applied',
    jsonb_build_object('title', v_title, 'plan_request_id', v_plan.id, 'auto', true),
    jsonb_build_object('title', v_title, 'mode', 'change', 'plan_request_id', v_plan.id, 'auto', true,
                       'goal', left(coalesce(p_spec ->> 'goal', ''), 300)),
    jsonb_build_object('code_request_id', v_req),
    now(),
    v_plan.created_by
  )
  returning id into v_action;
  return jsonb_build_object('ok', true, 'code_request_id', v_req, 'action_id', v_action);
end
$$;

-- ---------------------------------------------------------------------------
-- 3) 자동 검사 실패 → 재수정 (service role)
-- ---------------------------------------------------------------------------
-- p_spec은 앞 요청 내용 + fix_of { request_id, attempt, ... }. 서버가 회차·중복을 다시 확인한다.
create or replace function public.ai_code_bridge_fix(p_request_id uuid, p_message_id uuid, p_spec jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_prev public.ai_code_requests;
  v_attempt integer;
  v_msg uuid;
  v_req uuid;
  v_action uuid;
begin
  select * into v_prev from public.ai_code_requests where id = p_request_id for update;
  if not found or v_prev.mode <> 'change' or v_prev.conversation_id is null
     or v_prev.status not in ('ready', 'needs_review') then
    return jsonb_build_object('ok', false, 'error', 'not_fixable');
  end if;
  v_attempt := coalesce((v_prev.request -> 'fix_of' ->> 'attempt')::integer, 0) + 1;
  if v_attempt > 2 then
    return jsonb_build_object('ok', false, 'error', 'fix_limit');
  end if;
  if p_spec is null or jsonb_typeof(p_spec) <> 'object' or jsonb_typeof(p_spec -> 'fix_of') <> 'object'
     or p_spec -> 'fix_of' ->> 'request_id' is distinct from p_request_id::text
     or (p_spec -> 'fix_of' ->> 'attempt')::integer is distinct from v_attempt then
    raise exception 'fix_spec_invalid' using errcode = '22023';
  end if;
  if exists (select 1 from public.ai_code_requests r where r.request -> 'fix_of' ->> 'request_id' = p_request_id::text) then
    return jsonb_build_object('ok', false, 'error', 'already_fixing');
  end if;
  if not exists (
    select 1 from public.ai_code_request_rounds x
     where x.request_id = p_request_id
       and btrim(coalesce(x.result ->> 'diff', '')) <> ''
       and coalesce(x.result ->> 'base_commit', '') ~ '^[0-9a-f]{40}$'
  ) then
    return jsonb_build_object('ok', false, 'error', 'no_diff');
  end if;
  v_msg := case
    when exists (select 1 from public.ai_messages m where m.id = p_message_id and m.conversation_id = v_prev.conversation_id)
    then p_message_id
  end;
  begin
    insert into public.ai_code_requests (conversation_id, source_message_ids, title, request, mode, max_rounds, created_by)
    values (v_prev.conversation_id, array_remove(array[v_msg], null), v_prev.title, p_spec, 'change', 1, v_prev.created_by)
    returning id into v_req;
    perform public.ai_code_request_enqueue(v_req);
  exception when others then
    if sqlerrm = 'code_request_daily_limit' then
      return jsonb_build_object('ok', false, 'error', 'code_request_daily_limit');
    end if;
    raise;
  end;
  insert into public.ai_actions (conversation_id, message_id, kind, status, payload, preview, result, decided_at, created_by)
  values (
    v_prev.conversation_id,
    v_msg,
    'code_change',
    'applied',
    jsonb_build_object('title', v_prev.title, 'fix_of', jsonb_build_object('request_id', v_prev.id, 'attempt', v_attempt), 'auto', true),
    jsonb_build_object('title', v_prev.title, 'mode', 'change', 'auto', true, 'fix_attempt', v_attempt),
    jsonb_build_object('code_request_id', v_req),
    now(),
    v_prev.created_by
  )
  returning id into v_action;
  return jsonb_build_object('ok', true, 'code_request_id', v_req, 'action_id', v_action, 'attempt', v_attempt);
end
$$;

-- 재수정 작업자에게 넘길 앞 수정의 diff와 기준 커밋(마지막 회차).
create or replace function public.ai_code_bridge_fix_source(p_request_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object('diff', x.result ->> 'diff', 'base_commit', x.result ->> 'base_commit')
    from public.ai_code_request_rounds x
    join public.ai_code_requests r on r.id = x.request_id
   where x.request_id = p_request_id
     and r.mode = 'change'
     and btrim(coalesce(x.result ->> 'diff', '')) <> ''
   order by x.round desc
   limit 1;
$$;

revoke all on function public.ai_code_bridge_start_change(uuid, uuid, text, jsonb) from public, anon, authenticated;
revoke all on function public.ai_code_bridge_fix(uuid, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.ai_code_bridge_fix_source(uuid) from public, anon, authenticated;
grant execute on function public.ai_code_bridge_start_change(uuid, uuid, text, jsonb) to service_role;
grant execute on function public.ai_code_bridge_fix(uuid, uuid, jsonb) to service_role;
grant execute on function public.ai_code_bridge_fix_source(uuid) to service_role;
