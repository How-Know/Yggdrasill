-- 코드 작업 강도(Think 결정 255670bc, 2026-10-10)
-- 요청의 강도는 ai_code_requests.request.effort(medium/high/xhigh, 없거나 모르면 high)로 저장한다. 열은 늘리지 않는다.
-- 실제로 쓴 모델·강도는 작업자가 회차에 남긴다. 모델에 강도 옵션이 없거나 옛 작업자면 effort는 null.
-- 바뀌는 것: ai_code_request_rounds.effort 열, ai_code_bridge_complete / ai_code_bridge_fail이 p_round.effort를 저장.
-- 두 함수 본문은 20260930100000 / 20260929160000 정의와 같고 effort 한 줄만 더했다.

alter table public.ai_code_request_rounds
  add column if not exists effort text;

alter table public.ai_code_request_rounds
  drop constraint if exists ai_code_request_rounds_effort_check;
alter table public.ai_code_request_rounds
  add constraint ai_code_request_rounds_effort_check
  check (effort is null or effort in ('low', 'medium', 'high', 'xhigh'));

create or replace function public.ai_code_bridge_complete(p_worker_id text, p_request_id uuid, p_round jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req public.ai_code_requests;
  v_status text;
  v_parse_ok boolean := coalesce((p_round ->> 'parse_ok')::boolean, false);
  v_effort text := case when p_round ->> 'effort' in ('low', 'medium', 'high', 'xhigh') then p_round ->> 'effort' end;
begin
  select * into v_req from public.ai_code_requests where id = p_request_id for update;
  if not found or v_req.worker_id is distinct from p_worker_id or v_req.status <> 'running' then
    raise exception 'bridge_not_owner' using errcode = '42501';
  end if;

  update public.ai_code_request_rounds
     set status = 'finished',
         prompt = p_round ->> 'prompt',
         result_text = p_round ->> 'result_text',
         result = nullif(p_round -> 'result', 'null'::jsonb),
         parse_ok = v_parse_ok,
         cursor_run_id = coalesce(p_round ->> 'cursor_run_id', cursor_run_id),
         model = p_round ->> 'model',
         effort = v_effort,
         duration_ms = (p_round ->> 'duration_ms')::integer,
         usage = nullif(p_round -> 'usage', 'null'::jsonb),
         tool_calls = coalesce(nullif(p_round -> 'tool_calls', 'null'::jsonb), '[]'::jsonb),
         repo_state = nullif(p_round -> 'repo_state', 'null'::jsonb),
         error = null,
         finished_at = now()
   where request_id = p_request_id
     and round = v_req.round;

  v_status := case
                when v_req.cancel_requested then 'cancelled'
                when v_parse_ok then 'ready'
                else 'needs_review'
              end;
  update public.ai_code_requests
     set status = v_status,
         worker_id = null,
         lease_expires_at = null,
         finished_at = now(),
         attempts = 0,
         last_error = null,
         cursor_agent_id = coalesce(p_round ->> 'cursor_agent_id', cursor_agent_id),
         review_status = case when v_status <> 'cancelled' and conversation_id is not null then 'pending' end
   where id = p_request_id
   returning * into v_req;
  update public.ai_code_workers set current_request_id = null, last_seen_at = now() where worker_id = p_worker_id;
  return jsonb_build_object(
    'status', v_status,
    'round', v_req.round,
    'max_rounds', v_req.max_rounds,
    'mode', v_req.mode,
    'review', coalesce(v_req.review_status = 'pending', false),
    'conversation_id', v_req.conversation_id,
    'created_by', v_req.created_by
  );
end
$$;

create or replace function public.ai_code_bridge_fail(
  p_worker_id text,
  p_request_id uuid,
  p_code text,
  p_error text,
  p_retryable boolean,
  p_round jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req public.ai_code_requests;
  v_status text;
  v_round_status text := case p_code when 'timeout' then 'timeout' when 'cancelled' then 'cancelled' else 'error' end;
  v_terminal boolean;
  v_effort text := case when p_round ->> 'effort' in ('low', 'medium', 'high', 'xhigh') then p_round ->> 'effort' end;
begin
  select * into v_req from public.ai_code_requests where id = p_request_id for update;
  if not found or v_req.worker_id is distinct from p_worker_id or v_req.status <> 'running' then
    raise exception 'bridge_not_owner' using errcode = '42501';
  end if;

  update public.ai_code_request_rounds
     set status = v_round_status,
         error = left(coalesce(p_error, p_code), 2000),
         prompt = coalesce(p_round ->> 'prompt', prompt),
         result_text = coalesce(p_round ->> 'result_text', result_text),
         cursor_run_id = coalesce(p_round ->> 'cursor_run_id', cursor_run_id),
         model = coalesce(p_round ->> 'model', model),
         effort = coalesce(v_effort, effort),
         duration_ms = coalesce((p_round ->> 'duration_ms')::integer, duration_ms),
         usage = coalesce(nullif(p_round -> 'usage', 'null'::jsonb), usage),
         tool_calls = coalesce(nullif(p_round -> 'tool_calls', 'null'::jsonb), tool_calls),
         repo_state = coalesce(nullif(p_round -> 'repo_state', 'null'::jsonb), repo_state),
         finished_at = now()
   where request_id = p_request_id
     and round = v_req.round;

  if v_req.cancel_requested or p_code = 'cancelled' then
    v_status := 'cancelled';
  elsif coalesce(p_retryable, false) and v_req.attempts < 3 then
    v_status := case when v_req.round > 1 then 'followup_queued' else 'queued' end;
  else
    v_status := 'failed';
  end if;
  v_terminal := v_status in ('cancelled', 'failed');

  update public.ai_code_requests
     set status = v_status,
         round = case when v_terminal then round else round - 1 end,
         worker_id = null,
         lease_expires_at = null,
         last_error = left(coalesce(p_error, p_code), 2000),
         finished_at = case when v_terminal then now() else finished_at end,
         cursor_agent_id = coalesce(p_round ->> 'cursor_agent_id', cursor_agent_id)
   where id = p_request_id
   returning * into v_req;
  update public.ai_code_workers set current_request_id = null, last_seen_at = now() where worker_id = p_worker_id;
  return jsonb_build_object(
    'status', v_status,
    'round', v_req.round,
    'conversation_id', v_req.conversation_id,
    'created_by', v_req.created_by
  );
end
$$;

revoke all on function public.ai_code_bridge_complete(text, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.ai_code_bridge_fail(text, uuid, text, text, boolean, jsonb) from public, anon, authenticated;
grant execute on function public.ai_code_bridge_complete(text, uuid, jsonb) to service_role;
grant execute on function public.ai_code_bridge_fail(text, uuid, text, text, boolean, jsonb) to service_role;
