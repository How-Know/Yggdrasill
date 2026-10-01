-- 20260929160000: 코드 조사 연동 (Think ↔ Cursor) 1단계
-- - ai_code_requests: 조사 요청 1건. 앱은 초안(draft)의 제목·내용만 직접 고친다. 상태 전이는 RPC로만 한다.
-- - ai_code_request_rounds: 회차별 Cursor 결과
-- - ai_code_workers: 운영자 PC 작업자의 마지막 신호
-- - ai_platform_settings.code_request_daily_limit: 하루(한국 시간) 보내기 한도
-- 작업자 RPC(ai_code_bridge_*)는 service role 전용이다. Edge Function `ai_code_bridge`가 작업자 토큰을 확인한 뒤 부른다.
-- 설계: docs/architecture/ai-code-bridge.md

-- ---------------------------------------------------------------------------
-- 1) 설정
-- ---------------------------------------------------------------------------
alter table public.ai_platform_settings
  add column if not exists code_request_daily_limit integer not null default 10
    check (code_request_daily_limit between 0 and 100);

-- ---------------------------------------------------------------------------
-- 2) 테이블
-- ---------------------------------------------------------------------------
create table if not exists public.ai_code_requests (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid references public.ai_conversations(id) on delete set null,
  source_message_ids uuid[] not null default '{}',
  title text not null check (char_length(btrim(title)) between 1 and 200),
  request jsonb not null default '{}'::jsonb
    check (jsonb_typeof(request) = 'object' and octet_length(request::text) <= 50000),
  status text not null default 'draft'
    check (status in ('draft', 'queued', 'running', 'followup_queued', 'ready', 'needs_review', 'failed', 'cancelled')),
  round integer not null default 0 check (round >= 0),
  max_rounds integer not null default 2 check (max_rounds between 1 and 3),
  attempts integer not null default 0,
  last_error text,
  summary jsonb,
  outcome text check (outcome in ('adopted', 'rejected', 'deferred')),
  outcome_note text,
  decided_at timestamptz,
  cancel_requested boolean not null default false,
  cursor_agent_id text,
  worker_id text,
  lease_expires_at timestamptz,
  heartbeat_at timestamptz,
  submitted_at timestamptz,
  started_at timestamptz,
  finished_at timestamptz,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_ai_code_requests_queue
  on public.ai_code_requests (status, submitted_at);
create index if not exists idx_ai_code_requests_recent
  on public.ai_code_requests (created_at desc);
create index if not exists idx_ai_code_requests_conversation
  on public.ai_code_requests (conversation_id);

drop trigger if exists trg_ai_code_requests_updated_at on public.ai_code_requests;
create trigger trg_ai_code_requests_updated_at
  before update on public.ai_code_requests
  for each row execute function public.set_updated_at();

create table if not exists public.ai_code_request_rounds (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.ai_code_requests(id) on delete cascade,
  round integer not null check (round >= 1),
  status text not null default 'running' check (status in ('running', 'finished', 'error', 'timeout', 'cancelled')),
  prompt text,
  result_text text,
  result jsonb,
  parse_ok boolean,
  cursor_run_id text,
  model text,
  duration_ms integer,
  usage jsonb,
  tool_calls jsonb not null default '[]'::jsonb,
  repo_state jsonb,
  error text,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  unique (request_id, round)
);

create table if not exists public.ai_code_workers (
  worker_id text primary key check (worker_id ~ '^[A-Za-z0-9._-]{1,64}$'),
  version text,
  model text,
  info jsonb not null default '{}'::jsonb,
  current_request_id uuid references public.ai_code_requests(id) on delete set null,
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- 3) RLS + 열 권한
-- ---------------------------------------------------------------------------
alter table public.ai_code_requests enable row level security;
alter table public.ai_code_request_rounds enable row level security;
alter table public.ai_code_workers enable row level security;

revoke all on public.ai_code_requests from anon;
revoke all on public.ai_code_request_rounds from anon;
revoke all on public.ai_code_workers from anon;

-- 앱은 초안의 대화·출처·제목·내용만 쓴다. 상태·작업자·결과 열은 RPC(security definer)만 바꾼다.
revoke insert, update on public.ai_code_requests from authenticated;
grant insert (conversation_id, source_message_ids, title, request) on public.ai_code_requests to authenticated;
grant update (title, request) on public.ai_code_requests to authenticated;
revoke insert, update, delete on public.ai_code_request_rounds from authenticated;
revoke insert, update, delete on public.ai_code_workers from authenticated;

drop policy if exists ai_code_requests_superadmin_select on public.ai_code_requests;
create policy ai_code_requests_superadmin_select on public.ai_code_requests
  for select to authenticated
  using ((select public.is_superadmin()));

drop policy if exists ai_code_requests_superadmin_insert on public.ai_code_requests;
create policy ai_code_requests_superadmin_insert on public.ai_code_requests
  for insert to authenticated
  with check ((select public.is_superadmin()) and status = 'draft');

drop policy if exists ai_code_requests_superadmin_update on public.ai_code_requests;
create policy ai_code_requests_superadmin_update on public.ai_code_requests
  for update to authenticated
  using ((select public.is_superadmin()) and status = 'draft')
  with check ((select public.is_superadmin()) and status = 'draft');

-- 진행 중인 요청은 지우지 않는다(먼저 취소).
drop policy if exists ai_code_requests_superadmin_delete on public.ai_code_requests;
create policy ai_code_requests_superadmin_delete on public.ai_code_requests
  for delete to authenticated
  using ((select public.is_superadmin()) and status in ('draft', 'ready', 'needs_review', 'failed', 'cancelled'));

drop policy if exists ai_code_request_rounds_superadmin_select on public.ai_code_request_rounds;
create policy ai_code_request_rounds_superadmin_select on public.ai_code_request_rounds
  for select to authenticated
  using ((select public.is_superadmin()));

drop policy if exists ai_code_workers_superadmin_select on public.ai_code_workers;
create policy ai_code_workers_superadmin_select on public.ai_code_workers
  for select to authenticated
  using ((select public.is_superadmin()));

-- ---------------------------------------------------------------------------
-- 4) 앱 RPC (슈퍼관리자)
-- ---------------------------------------------------------------------------

-- 초안을 대기열에 올린다. 하루 한도는 설정 행을 잠가 동시에 보내도 넘지 않게 센다.
create or replace function public.ai_code_request_submit(p_id uuid)
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
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
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

-- 대기 중이면 바로 취소, 진행 중이면 작업자에게 취소를 요청한다(작업자가 다음 신호 때 멈춘다).
create or replace function public.ai_code_request_cancel(p_id uuid)
returns public.ai_code_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.ai_code_requests;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into v_row from public.ai_code_requests where id = p_id for update;
  if not found then
    raise exception 'code_request_not_found' using errcode = 'P0002';
  end if;
  if v_row.status in ('queued', 'followup_queued') then
    update public.ai_code_requests
       set status = 'cancelled', cancel_requested = true, finished_at = now()
     where id = p_id
     returning * into v_row;
  elsif v_row.status = 'running' then
    update public.ai_code_requests
       set cancel_requested = true
     where id = p_id
     returning * into v_row;
  else
    raise exception 'code_request_not_cancellable' using errcode = '22023';
  end if;
  return v_row;
end
$$;

-- 운영자 판단을 남긴다. 결정·기억은 여기서 만들지 않는다(기존 결정 초안 흐름을 쓴다).
create or replace function public.ai_code_request_decide(p_id uuid, p_outcome text, p_note text default null)
returns public.ai_code_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.ai_code_requests;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_outcome is not null and p_outcome not in ('adopted', 'rejected', 'deferred') then
    raise exception 'code_request_outcome_invalid' using errcode = '22023';
  end if;
  select * into v_row from public.ai_code_requests where id = p_id for update;
  if not found then
    raise exception 'code_request_not_found' using errcode = 'P0002';
  end if;
  if v_row.status not in ('ready', 'needs_review') then
    raise exception 'code_request_not_decidable' using errcode = '22023';
  end if;
  update public.ai_code_requests
     set outcome = p_outcome,
         outcome_note = nullif(btrim(coalesce(p_note, '')), ''),
         decided_at = case when p_outcome is null then null else now() end
   where id = p_id
   returning * into v_row;
  return v_row;
end
$$;

revoke all on function public.ai_code_request_submit(uuid) from public, anon;
revoke all on function public.ai_code_request_cancel(uuid) from public, anon;
revoke all on function public.ai_code_request_decide(uuid, text, text) from public, anon;
grant execute on function public.ai_code_request_submit(uuid) to authenticated;
grant execute on function public.ai_code_request_cancel(uuid) to authenticated;
grant execute on function public.ai_code_request_decide(uuid, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 5) 작업자 RPC (service role 전용)
-- ---------------------------------------------------------------------------

-- 점유가 끝난 요청을 정리한 뒤, 대기 중인 요청 하나를 가져간다.
-- 같은 회차를 다시 시도하면 attempts가 오르고, 3번을 넘으면 실패로 끝낸다.
create or replace function public.ai_code_bridge_claim(p_worker_id text, p_lease_seconds integer, p_info jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamptz := now();
  v_lease interval := make_interval(secs => least(greatest(coalesce(p_lease_seconds, 120), 30), 900));
  v_req public.ai_code_requests;
  v_round public.ai_code_request_rounds;
begin
  insert into public.ai_code_workers (worker_id, version, model, info, last_seen_at)
  values (p_worker_id, p_info ->> 'version', p_info ->> 'model', coalesce(p_info, '{}'::jsonb), v_now)
  on conflict (worker_id) do update
     set version = excluded.version,
         model = excluded.model,
         info = excluded.info,
         last_seen_at = v_now;

  with expired as (
    update public.ai_code_requests r
       set status = case
                      when r.cancel_requested then 'cancelled'
                      when r.attempts >= 3 then 'failed'
                      when r.round > 1 then 'followup_queued'
                      else 'queued'
                    end,
           round = case when r.cancel_requested or r.attempts >= 3 then r.round else r.round - 1 end,
           last_error = 'lease_expired',
           worker_id = null,
           lease_expires_at = null,
           finished_at = case when r.cancel_requested or r.attempts >= 3 then v_now else r.finished_at end
     where r.status = 'running'
       and r.lease_expires_at < v_now
    returning r.id
  )
  update public.ai_code_request_rounds x
     set status = 'error', error = 'lease_expired', finished_at = v_now
    from expired e
   where x.request_id = e.id
     and x.status = 'running';

  select * into v_req
    from public.ai_code_requests
   where status in ('queued', 'followup_queued')
     and not cancel_requested
   order by submitted_at nulls last, created_at
   for update skip locked
   limit 1;
  if not found then
    update public.ai_code_workers set current_request_id = null where worker_id = p_worker_id;
    return jsonb_build_object('request', null);
  end if;

  update public.ai_code_requests
     set status = 'running',
         round = round + 1,
         attempts = attempts + 1,
         worker_id = p_worker_id,
         lease_expires_at = v_now + v_lease,
         heartbeat_at = v_now,
         started_at = coalesce(started_at, v_now),
         last_error = null
   where id = v_req.id
   returning * into v_req;

  insert into public.ai_code_request_rounds (request_id, round, status, started_at)
  values (v_req.id, v_req.round, 'running', v_now)
  on conflict (request_id, round) do update
     set status = 'running', started_at = v_now, finished_at = null, error = null
  returning * into v_round;

  update public.ai_code_workers set current_request_id = v_req.id where worker_id = p_worker_id;
  return jsonb_build_object('request', to_jsonb(v_req), 'round', to_jsonb(v_round));
end
$$;

-- 진행 신호. 점유를 늘리고 취소 요청 여부를 돌려준다. 점유를 잃었으면 lost = true.
create or replace function public.ai_code_bridge_heartbeat(
  p_worker_id text,
  p_request_id uuid,
  p_lease_seconds integer,
  p_agent_id text default null,
  p_run_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lease interval := make_interval(secs => least(greatest(coalesce(p_lease_seconds, 120), 30), 900));
  v_cancel boolean;
  v_round integer;
begin
  update public.ai_code_workers set last_seen_at = now() where worker_id = p_worker_id;
  if p_request_id is null then
    return jsonb_build_object('ok', true);
  end if;
  update public.ai_code_requests
     set lease_expires_at = now() + v_lease,
         heartbeat_at = now(),
         cursor_agent_id = coalesce(p_agent_id, cursor_agent_id)
   where id = p_request_id
     and worker_id = p_worker_id
     and status = 'running'
  returning cancel_requested, round into v_cancel, v_round;
  if not found then
    return jsonb_build_object('ok', false, 'lost', true);
  end if;
  if p_run_id is not null then
    update public.ai_code_request_rounds
       set cursor_run_id = p_run_id
     where request_id = p_request_id and round = v_round;
  end if;
  return jsonb_build_object('ok', true, 'cancel_requested', v_cancel);
end
$$;

-- 회차 결과를 저장하고 요청을 끝낸다. 1단계는 형식에 맞으면 ready, 아니면 needs_review.
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

-- 회차 실패. 다시 해 볼 만한 오류이고 3번 미만이면 대기열로 돌려놓는다.
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

revoke all on function public.ai_code_bridge_claim(text, integer, jsonb) from public, anon, authenticated;
revoke all on function public.ai_code_bridge_heartbeat(text, uuid, integer, text, text) from public, anon, authenticated;
revoke all on function public.ai_code_bridge_complete(text, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.ai_code_bridge_fail(text, uuid, text, text, boolean, jsonb) from public, anon, authenticated;
grant execute on function public.ai_code_bridge_claim(text, integer, jsonb) to service_role;
grant execute on function public.ai_code_bridge_heartbeat(text, uuid, integer, text, text) to service_role;
grant execute on function public.ai_code_bridge_complete(text, uuid, jsonb) to service_role;
grant execute on function public.ai_code_bridge_fail(text, uuid, text, text, boolean, jsonb) to service_role;
