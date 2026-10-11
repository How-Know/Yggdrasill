-- Think ↔ Cursor 연결(relay): 커서(운영자 PC의 Cursor 작업창, 코드 작업자)가 Think에게 묻고, Think 기록을 읽는다.
--   ai_conversations.origin : 'cursor'면 커서가 시작한 대화(화면에 표시). 운영자는 그 대화에 이어 말할 수 있다.
--   ai_messages.asked_by    : 커서가 보낸 질문(user 메시지). null이면 운영자.
--   ai_messages.relay       : 커서 질문에 대한 Think 답의 판정(assistant 메시지).
--                             {verdict: answered|needs_owner, basis[{id,kind,title}], owner_questions[], asker}
--   ai_relay_asks           : 질문 1건 = 1행. 한도 계산과 감사용. 질문 본문은 메시지에만 둔다(대화를 지우면 같이 지워지게).
-- 질문 접수·마감은 service role 전용 RPC(ai_relay_reserve / ai_relay_finish)로만 한다.
-- 설계: docs/architecture/ai-think.md §12

alter table public.ai_conversations
  add column if not exists origin text not null default 'owner';
alter table public.ai_conversations drop constraint if exists ai_conversations_origin_check;
alter table public.ai_conversations
  add constraint ai_conversations_origin_check check (origin in ('owner', 'cursor'));

alter table public.ai_messages
  add column if not exists asked_by text,
  add column if not exists relay jsonb;
alter table public.ai_messages drop constraint if exists ai_messages_asked_by_check;
alter table public.ai_messages
  add constraint ai_messages_asked_by_check check (asked_by is null or asked_by in ('cursor_ide', 'cursor_worker'));
alter table public.ai_messages drop constraint if exists ai_messages_relay_check;
alter table public.ai_messages
  add constraint ai_messages_relay_check
  check (relay is null or (jsonb_typeof(relay) = 'object' and octet_length(relay::text) <= 20000));

create table if not exists public.ai_relay_asks (
  id uuid primary key default gen_random_uuid(),
  asker text not null check (asker in ('cursor_ide', 'cursor_worker')),
  worker_id text,
  request_id uuid references public.ai_code_requests(id) on delete set null,
  request_round integer,
  conversation_id uuid references public.ai_conversations(id) on delete set null,
  status text not null default 'running' check (status in ('running', 'answered', 'needs_owner', 'error')),
  error text,
  run_id uuid references public.ai_runs(id) on delete set null,
  created_at timestamptz not null default now(),
  finished_at timestamptz
);

create index if not exists idx_ai_relay_asks_recent on public.ai_relay_asks (created_at desc);
create index if not exists idx_ai_relay_asks_request on public.ai_relay_asks (request_id, request_round);

alter table public.ai_relay_asks enable row level security;
drop policy if exists ai_relay_asks_superadmin_select on public.ai_relay_asks;
create policy ai_relay_asks_superadmin_select on public.ai_relay_asks
  for select to authenticated
  using ((select public.is_superadmin()));
revoke all on public.ai_relay_asks from anon, authenticated;
grant select on public.ai_relay_asks to authenticated;

-- 질문 접수. 한도와 자격을 한 잠금 안에서 확인하고 1행을 남긴다.
--   공통: KST 하루 p_daily_limit건.
--   작업창(cursor_ide): 이어 물을 대화는 커서가 시작한 대화(origin = cursor)만.
--   작업자(cursor_worker): 그 작업자가 지금 돌리는 조사·조율 요청만, 같은 회차에 p_run_limit건.
--                          같은 요청의 앞 질문 대화가 남아 있으면 거기에 이어 묻는다.
create or replace function public.ai_relay_reserve(
  p_asker text,
  p_conversation_id uuid,
  p_worker_id text,
  p_request_id uuid,
  p_daily_limit integer,
  p_run_limit integer
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_today_start timestamptz := (date_trunc('day', now() at time zone 'Asia/Seoul')) at time zone 'Asia/Seoul';
  v_count integer;
  v_conv uuid;
  v_origin text;
  v_title text;
  v_mode text;
  v_status text;
  v_worker text;
  v_round integer;
  v_id uuid;
begin
  if p_asker is null or p_asker not in ('cursor_ide', 'cursor_worker') then
    raise exception 'relay_asker_invalid';
  end if;

  perform pg_advisory_xact_lock(hashtext('ai_relay_asks'));

  select count(*) into v_count from public.ai_relay_asks where created_at >= v_today_start;
  if v_count >= greatest(coalesce(p_daily_limit, 60), 1) then
    raise exception 'relay_daily_limit';
  end if;

  if p_asker = 'cursor_worker' then
    if p_request_id is null or coalesce(btrim(p_worker_id), '') = '' then
      raise exception 'relay_request_required';
    end if;
    select title, mode, status, worker_id, round into v_title, v_mode, v_status, v_worker, v_round
      from public.ai_code_requests where id = p_request_id;
    if not found then
      raise exception 'relay_request_not_found';
    end if;
    if v_status <> 'running' or v_worker is distinct from p_worker_id then
      raise exception 'relay_request_not_running';
    end if;
    if v_mode not in ('investigate', 'plan') then
      raise exception 'relay_mode_not_allowed';
    end if;
    select count(*) into v_count
      from public.ai_relay_asks
     where request_id = p_request_id and request_round = v_round;
    if v_count >= greatest(coalesce(p_run_limit, 3), 1) then
      raise exception 'relay_run_limit';
    end if;
    select a.conversation_id into v_conv
      from public.ai_relay_asks a
      join public.ai_conversations c on c.id = a.conversation_id and c.origin = 'cursor'
     where a.request_id = p_request_id
     order by a.created_at desc
     limit 1;
  elsif p_conversation_id is not null then
    select origin into v_origin from public.ai_conversations where id = p_conversation_id;
    if not found then
      raise exception 'relay_conversation_not_found';
    end if;
    if v_origin <> 'cursor' then
      raise exception 'relay_conversation_not_cursor';
    end if;
    v_conv := p_conversation_id;
  end if;

  insert into public.ai_relay_asks (asker, worker_id, request_id, request_round, conversation_id)
  values (
    p_asker,
    case when p_asker = 'cursor_worker' then p_worker_id end,
    case when p_asker = 'cursor_worker' then p_request_id end,
    v_round,
    v_conv
  )
  returning id into v_id;

  return jsonb_build_object(
    'id', v_id,
    'conversation_id', v_conv,
    'request_title', v_title,
    'request_mode', v_mode,
    'request_round', v_round
  );
end
$$;

-- 질문 마감. 이미 마감된 행은 바꾸지 않는다.
create or replace function public.ai_relay_finish(
  p_id uuid,
  p_status text,
  p_conversation_id uuid,
  p_run_id uuid,
  p_error text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_status is null or p_status not in ('answered', 'needs_owner', 'error') then
    raise exception 'relay_status_invalid';
  end if;
  update public.ai_relay_asks
     set status = p_status,
         conversation_id = coalesce(p_conversation_id, conversation_id),
         run_id = p_run_id,
         error = left(p_error, 500),
         finished_at = now()
   where id = p_id and status = 'running';
  return found;
end
$$;

revoke all on function public.ai_relay_reserve(text, uuid, text, uuid, integer, integer) from public, anon, authenticated;
revoke all on function public.ai_relay_finish(uuid, text, uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.ai_relay_reserve(text, uuid, text, uuid, integer, integer) to service_role;
grant execute on function public.ai_relay_finish(uuid, text, uuid, uuid, text) to service_role;
