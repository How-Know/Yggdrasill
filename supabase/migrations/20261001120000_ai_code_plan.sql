-- 20261001120000: Think ↔ Cursor 조율 (plan 모드)
-- - 코드 수정은 바로 고치지 않고 먼저 조율한다. Cursor가 읽기 전용으로 Think의 계획을 코드에 비춰 검토하고,
--   Think가 결과를 보고 최대 3회까지 되묻는다.
-- - 조율이 끝나면 Think가 조율본을 code_change 제안으로 올린다. 운영자가 승인해야 그 내용으로 수정 요청이 만들어진다.
-- - 조율 시작은 승인 없이 바로 대기열에 넣는다(운영자 결정 2026-10-01). 읽기 전용이고 하루 한도가 그대로 적용된다.
-- 설계: docs/architecture/ai-think-actions.md §4.3

-- ---------------------------------------------------------------------------
-- 1) 모드·제안 종류·Think 질문 기록
-- ---------------------------------------------------------------------------
alter table public.ai_code_requests drop constraint if exists ai_code_requests_mode_check;
alter table public.ai_code_requests add constraint ai_code_requests_mode_check
  check (mode in ('investigate', 'change', 'plan'));

-- 다음 회차에 보낼 Think의 질문(문자열 배열). 회차 행이 시작될 때 think_questions로 옮겨 적는다.
alter table public.ai_code_requests add column if not exists followup_questions jsonb;
alter table public.ai_code_request_rounds add column if not exists think_questions jsonb;

alter table public.ai_actions drop constraint if exists ai_actions_kind_check;
alter table public.ai_actions add constraint ai_actions_kind_check
  check (kind in (
    'code_request', 'code_change', 'code_plan', 'place_conversation', 'delete_code_request', 'delete_folder', 'delete_conversation'
  ));

-- 2회차부터는 Think가 무엇을 물었는지 회차 행에 남긴다(화면에서 Think ↔ Cursor 주고받기로 보여 준다).
create or replace function public.ai_code_rounds_think_questions()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'running' and new.round > 1 then
    select r.followup_questions into new.think_questions from public.ai_code_requests r where r.id = new.request_id;
  end if;
  return new;
end
$$;

drop trigger if exists ai_code_rounds_think_questions on public.ai_code_request_rounds;
create trigger ai_code_rounds_think_questions
  before insert or update of status on public.ai_code_request_rounds
  for each row execute function public.ai_code_rounds_think_questions();

-- ---------------------------------------------------------------------------
-- 2) 조율 시작 (ai_think의 start_code_plan 도구, 사용자 JWT)
-- ---------------------------------------------------------------------------
-- 요청(mode = plan, 최대 3회)을 만들어 바로 보내고, 대화 카드용으로 '실행됨' 상태의 code_plan 행을 남긴다.
create or replace function public.ai_code_plan_start(p_conversation_id uuid, p_title text, p_spec jsonb)
returns public.ai_actions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_title text := left(btrim(coalesce(p_title, '')), 200);
  v_req uuid;
  v_row public.ai_actions;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if not exists (select 1 from public.ai_conversations where id = p_conversation_id) then
    raise exception 'conversation_not_found' using errcode = 'P0002';
  end if;
  if v_title = '' then
    raise exception 'code_request_title_required' using errcode = '22023';
  end if;
  if p_spec is null or jsonb_typeof(p_spec) <> 'object' or btrim(coalesce(p_spec ->> 'goal', '')) = '' then
    raise exception 'code_request_goal_required' using errcode = '22023';
  end if;
  insert into public.ai_code_requests (conversation_id, title, request, mode, max_rounds)
  values (p_conversation_id, v_title, p_spec, 'plan', 3)
  returning id into v_req;
  perform public.ai_code_request_submit(v_req);
  insert into public.ai_actions (conversation_id, kind, status, payload, preview, result, decided_at, decided_by)
  values (
    p_conversation_id,
    'code_plan',
    'applied',
    jsonb_build_object('title', v_title, 'spec', p_spec),
    jsonb_build_object('title', v_title, 'goal', left(coalesce(p_spec ->> 'goal', ''), 300), 'mode', 'plan'),
    jsonb_build_object('code_request_id', v_req),
    now(),
    auth.uid()
  )
  returning * into v_row;
  return v_row;
end
$$;

revoke all on function public.ai_code_plan_start(uuid, text, jsonb) from public, anon;
grant execute on function public.ai_code_plan_start(uuid, text, jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- 3) 작업자·검토 RPC (service role)
-- ---------------------------------------------------------------------------
-- 추가 질문: 조사·조율 모드만. 질문 목록은 다음 회차 행에 남는다.
drop function if exists public.ai_code_bridge_followup(uuid, text);
create or replace function public.ai_code_bridge_followup(p_request_id uuid, p_prompt text, p_questions jsonb default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.ai_code_requests
     set status = 'followup_queued',
         followup_prompt = left(p_prompt, 60000),
         followup_questions = case when jsonb_typeof(p_questions) = 'array' then p_questions end,
         review_status = null,
         finished_at = null
   where id = p_request_id
     and status in ('ready', 'needs_review')
     and mode in ('investigate', 'plan')
     and round < max_rounds
     and not cancel_requested;
  return jsonb_build_object('ok', found);
end
$$;

-- 조율이 끝나면 Think가 조율본을 수정 제안으로 올린다. 같은 대화에 대기 중인 수정 제안은 대체된다.
create or replace function public.ai_code_bridge_propose_plan(
  p_request_id uuid,
  p_message_id uuid,
  p_title text,
  p_spec jsonb,
  p_preview jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req public.ai_code_requests;
  v_id uuid;
  v_title text := left(btrim(coalesce(p_title, '')), 200);
begin
  select * into v_req from public.ai_code_requests where id = p_request_id;
  if not found or v_req.mode <> 'plan' or v_req.conversation_id is null then
    return null;
  end if;
  if v_title = '' then
    v_title := v_req.title;
  end if;
  if p_spec is null or jsonb_typeof(p_spec) <> 'object' then
    raise exception 'code_request_goal_required' using errcode = '22023';
  end if;
  update public.ai_actions
     set status = 'rejected', superseded = true, decided_at = now()
   where conversation_id = v_req.conversation_id
     and kind = 'code_change'
     and status = 'proposed';
  insert into public.ai_actions (conversation_id, message_id, kind, payload, preview, created_by)
  values (
    v_req.conversation_id,
    case when exists (select 1 from public.ai_messages m where m.id = p_message_id and m.conversation_id = v_req.conversation_id)
         then p_message_id end,
    'code_change',
    jsonb_build_object('title', v_title, 'spec', p_spec, 'plan_request_id', v_req.id),
    coalesce(p_preview, '{}'::jsonb) || jsonb_build_object('title', v_title, 'mode', 'change', 'plan_request_id', v_req.id),
    v_req.created_by
  )
  returning id into v_id;
  return v_id;
end
$$;

revoke all on function public.ai_code_bridge_followup(uuid, text, jsonb) from public, anon, authenticated;
revoke all on function public.ai_code_bridge_propose_plan(uuid, uuid, text, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.ai_code_bridge_followup(uuid, text, jsonb) to service_role;
grant execute on function public.ai_code_bridge_propose_plan(uuid, uuid, text, jsonb, jsonb) to service_role;
