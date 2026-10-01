-- 20260930100000: Think 작업 도구 (제안 → 승인 → 실행) + 코드 수정 모드 + 조사 결과 자동 검토
-- - ai_actions: AI가 낸 제안. AI는 ai_action_propose로 행을 남길 뿐이고, 실행은 사용자가 ai_action_apply로 승인할 때만 한다.
-- - ai_code_requests: mode(investigate/change), 자동 검토 상태, 적용·되돌리기 상태, 2회차 질문
-- - 작업자 RPC: claim이 적용·되돌리기 작업도 가져가고, apply_done·followup·review_done이 추가된다.
-- 설계: docs/architecture/ai-think-actions.md, docs/architecture/ai-code-bridge.md

-- ---------------------------------------------------------------------------
-- 1) 코드 요청 확장
-- ---------------------------------------------------------------------------
alter table public.ai_code_requests
  add column if not exists mode text not null default 'investigate' check (mode in ('investigate', 'change')),
  add column if not exists followup_prompt text,
  add column if not exists review_status text check (review_status in ('pending', 'done', 'skipped', 'error')),
  add column if not exists review_message_id uuid references public.ai_messages(id) on delete set null,
  add column if not exists review_error text,
  add column if not exists apply_result jsonb;

alter table public.ai_code_requests drop constraint if exists ai_code_requests_status_check;
alter table public.ai_code_requests add constraint ai_code_requests_status_check
  check (status in (
    'draft', 'queued', 'running', 'followup_queued', 'ready', 'needs_review', 'failed', 'cancelled',
    'apply_queued', 'applying', 'applied', 'apply_failed', 'revert_queued', 'reverting', 'reverted', 'revert_failed'
  ));

drop policy if exists ai_code_requests_superadmin_delete on public.ai_code_requests;
create policy ai_code_requests_superadmin_delete on public.ai_code_requests
  for delete to authenticated
  using (
    (select public.is_superadmin())
    and status in ('draft', 'ready', 'needs_review', 'failed', 'cancelled', 'applied', 'apply_failed', 'reverted', 'revert_failed')
  );

grant insert (conversation_id, source_message_ids, title, request, mode) on public.ai_code_requests to authenticated;

-- ---------------------------------------------------------------------------
-- 2) 제안
-- ---------------------------------------------------------------------------
create table if not exists public.ai_actions (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.ai_conversations(id) on delete cascade,
  message_id uuid references public.ai_messages(id) on delete set null,
  kind text not null check (kind in (
    'code_request', 'code_change', 'place_conversation', 'delete_code_request', 'delete_folder', 'delete_conversation'
  )),
  status text not null default 'proposed' check (status in ('proposed', 'applied', 'rejected', 'failed', 'undone')),
  payload jsonb not null default '{}'::jsonb check (jsonb_typeof(payload) = 'object' and octet_length(payload::text) <= 60000),
  preview jsonb not null default '{}'::jsonb check (jsonb_typeof(preview) = 'object'),
  result jsonb,
  error text,
  superseded boolean not null default false,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  decided_by uuid references auth.users(id) on delete set null,
  decided_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists idx_ai_actions_conversation on public.ai_actions (conversation_id, created_at);

alter table public.ai_actions enable row level security;
revoke all on public.ai_actions from anon;
revoke insert, update, delete on public.ai_actions from authenticated;

drop policy if exists ai_actions_superadmin_select on public.ai_actions;
create policy ai_actions_superadmin_select on public.ai_actions
  for select to authenticated
  using ((select public.is_superadmin()));

-- 제안을 남긴다. 같은 대화의 같은 종류 제안이 아직 대기 중이면 대체된 것으로 닫는다.
create or replace function public.ai_action_propose(
  p_conversation_id uuid,
  p_kind text,
  p_payload jsonb,
  p_preview jsonb default '{}'::jsonb
)
returns public.ai_actions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.ai_actions;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if not exists (select 1 from public.ai_conversations where id = p_conversation_id) then
    raise exception 'conversation_not_found' using errcode = 'P0002';
  end if;
  update public.ai_actions
     set status = 'rejected', superseded = true, decided_at = now()
   where conversation_id = p_conversation_id
     and kind = p_kind
     and status = 'proposed';
  insert into public.ai_actions (conversation_id, kind, payload, preview)
  values (p_conversation_id, p_kind, coalesce(p_payload, '{}'::jsonb), coalesce(p_preview, '{}'::jsonb))
  returning * into v_row;
  return v_row;
end
$$;

-- 한 답변에서 낸 제안들을 그 답변 메시지에 붙인다.
create or replace function public.ai_action_attach(p_ids uuid[], p_message_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update public.ai_actions a
     set message_id = p_message_id
   where a.id = any(coalesce(p_ids, '{}'::uuid[]))
     and a.message_id is null
     and exists (select 1 from public.ai_messages m where m.id = p_message_id and m.conversation_id = a.conversation_id);
end
$$;

create or replace function public.ai_action_reject(p_id uuid)
returns public.ai_actions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.ai_actions;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update public.ai_actions
     set status = 'rejected', decided_at = now(), decided_by = auth.uid()
   where id = p_id and status = 'proposed'
  returning * into v_row;
  if not found then
    raise exception 'action_not_pending' using errcode = '22023';
  end if;
  return v_row;
end
$$;

-- 승인. 대상을 다시 확인하고 실행한 뒤 결과를 남긴다. 실패하면 예외로 전체를 되돌리고 제안은 대기 상태로 남는다.
-- p_overrides: 사용자가 카드에서 고친 값만. code_*: {title, spec}, place_conversation: {folder_id}
create or replace function public.ai_action_apply(p_id uuid, p_overrides jsonb default '{}'::jsonb)
returns public.ai_actions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.ai_actions;
  v_over jsonb := coalesce(p_overrides, '{}'::jsonb);
  v_result jsonb;
  v_target uuid;
  v_req_id uuid;
  v_title text;
  v_spec jsonb;
  v_folder uuid;
  v_new_folder uuid;
  v_parent uuid;
  v_node public.ai_tree_nodes;
  v_prev jsonb;
  v_prev_index integer;
  v_deleted_self boolean := false;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into v_row from public.ai_actions where id = p_id for update;
  if not found then
    raise exception 'action_not_found' using errcode = 'P0002';
  end if;
  if v_row.status <> 'proposed' then
    raise exception 'action_not_pending' using errcode = '22023';
  end if;

  if v_row.kind in ('code_request', 'code_change') then
    v_title := btrim(coalesce(nullif(v_over ->> 'title', ''), v_row.payload ->> 'title', ''));
    v_spec := case when jsonb_typeof(v_over -> 'spec') = 'object' then v_over -> 'spec' else v_row.payload -> 'spec' end;
    if v_title = '' then
      raise exception 'code_request_title_required' using errcode = '22023';
    end if;
    if v_spec is null or jsonb_typeof(v_spec) <> 'object' then
      raise exception 'code_request_goal_required' using errcode = '22023';
    end if;
    insert into public.ai_code_requests (conversation_id, source_message_ids, title, request, mode)
    values (
      v_row.conversation_id,
      array_remove(array[v_row.message_id], null),
      left(v_title, 200),
      v_spec,
      case when v_row.kind = 'code_change' then 'change' else 'investigate' end
    )
    returning id into v_req_id;
    perform public.ai_code_request_submit(v_req_id);
    v_result := jsonb_build_object('code_request_id', v_req_id);

  elsif v_row.kind = 'place_conversation' then
    v_folder := nullif(v_over ->> 'folder_id', '')::uuid;
    if v_folder is null and nullif(btrim(coalesce(v_row.payload ->> 'new_folder_title', '')), '') is not null then
      v_parent := nullif(v_row.payload ->> 'new_folder_parent_id', '')::uuid;
      if v_parent is not null and not exists (select 1 from public.ai_tree_nodes where id = v_parent and kind = 'folder') then
        raise exception 'tree_parent_not_folder' using errcode = '22023';
      end if;
      insert into public.ai_tree_nodes (kind, parent_id, title, created_via, sort_order)
      values ('folder', v_parent, left(btrim(v_row.payload ->> 'new_folder_title'), 120), 'ai', 2147483647)
      returning id into v_new_folder;
      perform public.ai_tree_renumber(v_parent);
      v_folder := v_new_folder;
    elsif v_folder is null then
      v_folder := nullif(v_row.payload ->> 'folder_id', '')::uuid;
    end if;
    if v_folder is null or not exists (select 1 from public.ai_tree_nodes where id = v_folder and kind = 'folder') then
      raise exception 'tree_folder_not_found' using errcode = 'P0002';
    end if;

    select * into v_node from public.ai_tree_nodes
     where kind = 'conversation' and conversation_id = v_row.conversation_id;
    if found then
      select count(*) into v_prev_index
        from public.ai_tree_nodes
       where parent_id is not distinct from v_node.parent_id
         and id <> v_node.id
         and (sort_order, created_at, id) < (v_node.sort_order, v_node.created_at, v_node.id);
      v_prev := jsonb_build_object('placed', true, 'parent_id', v_node.parent_id, 'index', v_prev_index);
    else
      v_prev := jsonb_build_object('placed', false);
    end if;
    perform public.ai_tree_place_conversation(v_row.conversation_id, v_folder, 2147483647);
    v_result := jsonb_build_object('folder_id', v_folder, 'created_folder_id', v_new_folder, 'previous', v_prev);

  elsif v_row.kind = 'delete_code_request' then
    v_target := nullif(v_row.payload ->> 'target_id', '')::uuid;
    delete from public.ai_code_requests
     where id = v_target
       and status in ('draft', 'ready', 'needs_review', 'failed', 'cancelled', 'applied', 'apply_failed', 'reverted', 'revert_failed');
    if not found then
      raise exception 'code_request_not_deletable' using errcode = '22023';
    end if;
    v_result := jsonb_build_object('deleted_id', v_target);

  elsif v_row.kind = 'delete_folder' then
    v_target := nullif(v_row.payload ->> 'target_id', '')::uuid;
    perform public.ai_tree_delete_folder(v_target);
    v_result := jsonb_build_object('deleted_id', v_target);

  elsif v_row.kind = 'delete_conversation' then
    v_target := nullif(v_row.payload ->> 'target_id', '')::uuid;
    v_deleted_self := v_target = v_row.conversation_id;
    delete from public.ai_conversations where id = v_target;
    if not found then
      raise exception 'conversation_not_found' using errcode = 'P0002';
    end if;
    v_result := jsonb_build_object('deleted_id', v_target, 'deleted_self', v_deleted_self);
  end if;

  if v_deleted_self then
    -- 제안이 속한 대화가 지워져 행도 함께 사라졌다. 결과만 돌려준다.
    v_row.status := 'applied';
    v_row.result := v_result;
    v_row.decided_at := now();
    v_row.decided_by := auth.uid();
    return v_row;
  end if;

  update public.ai_actions
     set status = 'applied', result = v_result, error = null, decided_at = now(), decided_by = auth.uid()
   where id = p_id
  returning * into v_row;
  return v_row;
end
$$;

-- 대화 분류만 되돌린다. 이전 위치로 옮기고, AI가 만든 폴더가 비었으면 지운다.
create or replace function public.ai_action_undo(p_id uuid)
returns public.ai_actions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.ai_actions;
  v_prev jsonb;
  v_node uuid;
  v_created uuid;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into v_row from public.ai_actions where id = p_id for update;
  if not found then
    raise exception 'action_not_found' using errcode = 'P0002';
  end if;
  if v_row.kind <> 'place_conversation' or v_row.status <> 'applied' then
    raise exception 'action_not_undoable' using errcode = '22023';
  end if;
  v_prev := coalesce(v_row.result -> 'previous', '{}'::jsonb);
  select id into v_node from public.ai_tree_nodes where kind = 'conversation' and conversation_id = v_row.conversation_id;
  if v_node is not null then
    if coalesce((v_prev ->> 'placed')::boolean, false) then
      if nullif(v_prev ->> 'parent_id', '') is not null
         and not exists (select 1 from public.ai_tree_nodes where id = (v_prev ->> 'parent_id')::uuid and kind = 'folder') then
        perform public.ai_tree_move(v_node, null, coalesce((v_prev ->> 'index')::integer, 0));
      else
        perform public.ai_tree_move(v_node, nullif(v_prev ->> 'parent_id', '')::uuid, coalesce((v_prev ->> 'index')::integer, 0));
      end if;
    else
      delete from public.ai_tree_nodes where id = v_node;
    end if;
  end if;
  v_created := nullif(v_row.result ->> 'created_folder_id', '')::uuid;
  if v_created is not null and not exists (select 1 from public.ai_tree_nodes where parent_id = v_created) then
    perform public.ai_tree_delete_folder(v_created);
  end if;
  update public.ai_actions set status = 'undone', decided_at = now(), decided_by = auth.uid()
   where id = p_id
  returning * into v_row;
  return v_row;
end
$$;

revoke all on function public.ai_action_propose(uuid, text, jsonb, jsonb) from public, anon;
revoke all on function public.ai_action_attach(uuid[], uuid) from public, anon;
revoke all on function public.ai_action_reject(uuid) from public, anon;
revoke all on function public.ai_action_apply(uuid, jsonb) from public, anon;
revoke all on function public.ai_action_undo(uuid) from public, anon;
grant execute on function public.ai_action_propose(uuid, text, jsonb, jsonb) to authenticated;
grant execute on function public.ai_action_attach(uuid[], uuid) to authenticated;
grant execute on function public.ai_action_reject(uuid) to authenticated;
grant execute on function public.ai_action_apply(uuid, jsonb) to authenticated;
grant execute on function public.ai_action_undo(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3) 코드 수정 적용·되돌리기 (앱)
-- ---------------------------------------------------------------------------
create or replace function public.ai_code_request_apply(p_id uuid)
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
  if v_row.mode <> 'change' or v_row.status not in ('ready', 'apply_failed') then
    raise exception 'code_request_not_appliable' using errcode = '22023';
  end if;
  update public.ai_code_requests
     set status = 'apply_queued', last_error = null, attempts = 0, apply_result = null
   where id = p_id
  returning * into v_row;
  return v_row;
end
$$;

create or replace function public.ai_code_request_revert(p_id uuid)
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
  if v_row.mode <> 'change' or v_row.status not in ('applied', 'revert_failed') then
    raise exception 'code_request_not_revertable' using errcode = '22023';
  end if;
  update public.ai_code_requests
     set status = 'revert_queued', last_error = null, attempts = 0
   where id = p_id
  returning * into v_row;
  return v_row;
end
$$;

-- 대기 중인 적용·되돌리기도 취소할 수 있게 한다.
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
  elsif v_row.status = 'apply_queued' then
    update public.ai_code_requests set status = 'ready' where id = p_id returning * into v_row;
  elsif v_row.status = 'revert_queued' then
    update public.ai_code_requests set status = 'applied' where id = p_id returning * into v_row;
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

revoke all on function public.ai_code_request_apply(uuid) from public, anon;
revoke all on function public.ai_code_request_revert(uuid) from public, anon;
grant execute on function public.ai_code_request_apply(uuid) to authenticated;
grant execute on function public.ai_code_request_revert(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 4) 작업자 RPC
-- ---------------------------------------------------------------------------

-- 적용·되돌리기가 조사보다 먼저다(사람이 기다리고 있다). 반환 job: run / apply / revert.
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
  v_job text;
begin
  insert into public.ai_code_workers (worker_id, version, model, info, last_seen_at)
  values (p_worker_id, p_info ->> 'version', p_info ->> 'model', coalesce(p_info, '{}'::jsonb), v_now)
  on conflict (worker_id) do update
     set version = excluded.version,
         model = excluded.model,
         info = excluded.info,
         last_seen_at = v_now;

  -- 적용 중에 작업자가 멈추면 작업 폴더 상태를 알 수 없다. 실패로 두고 사람이 확인하게 한다.
  update public.ai_code_requests r
     set status = case r.status when 'applying' then 'apply_failed' else 'revert_failed' end,
         last_error = 'lease_expired_state_unknown',
         worker_id = null,
         lease_expires_at = null
   where r.status in ('applying', 'reverting')
     and r.lease_expires_at < v_now;

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
   where status in ('apply_queued', 'revert_queued')
   order by updated_at
   for update skip locked
   limit 1;
  if found then
    v_job := case v_req.status when 'apply_queued' then 'apply' else 'revert' end;
    update public.ai_code_requests
       set status = case v_job when 'apply' then 'applying' else 'reverting' end,
           worker_id = p_worker_id,
           lease_expires_at = v_now + v_lease,
           heartbeat_at = v_now
     where id = v_req.id
     returning * into v_req;
    select * into v_round from public.ai_code_request_rounds
     where request_id = v_req.id and status = 'finished'
     order by round desc
     limit 1;
    update public.ai_code_workers set current_request_id = v_req.id where worker_id = p_worker_id;
    return jsonb_build_object('job', v_job, 'request', to_jsonb(v_req), 'round', to_jsonb(v_round));
  end if;

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
         last_error = null,
         review_status = null
   where id = v_req.id
   returning * into v_req;

  insert into public.ai_code_request_rounds (request_id, round, status, started_at, prompt)
  values (v_req.id, v_req.round, 'running', v_now, case when v_req.round > 1 then v_req.followup_prompt end)
  on conflict (request_id, round) do update
     set status = 'running', started_at = v_now, finished_at = null, error = null,
         prompt = case when v_req.round > 1 then v_req.followup_prompt else ai_code_request_rounds.prompt end
  returning * into v_round;

  update public.ai_code_workers set current_request_id = v_req.id where worker_id = p_worker_id;
  return jsonb_build_object('job', 'run', 'request', to_jsonb(v_req), 'round', to_jsonb(v_round));
end
$$;

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
  v_status text;
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
     and status in ('running', 'applying', 'reverting')
  returning cancel_requested, round, status into v_cancel, v_round, v_status;
  if not found then
    return jsonb_build_object('ok', false, 'lost', true);
  end if;
  if p_run_id is not null and v_status = 'running' then
    update public.ai_code_request_rounds
       set cursor_run_id = p_run_id
     where request_id = p_request_id and round = v_round;
  end if;
  return jsonb_build_object('ok', true, 'cancel_requested', v_cancel);
end
$$;

-- 회차 결과를 저장한다. 대화에 연결된 요청이면 자동 검토 대기(review_status = pending)로 둔다.
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

-- 적용·되돌리기 결과.
create or replace function public.ai_code_bridge_apply_done(p_worker_id text, p_request_id uuid, p_ok boolean, p_result jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req public.ai_code_requests;
  v_status text;
begin
  select * into v_req from public.ai_code_requests where id = p_request_id for update;
  if not found or v_req.worker_id is distinct from p_worker_id or v_req.status not in ('applying', 'reverting') then
    raise exception 'bridge_not_owner' using errcode = '42501';
  end if;
  v_status := case
                when v_req.status = 'applying' and p_ok then 'applied'
                when v_req.status = 'applying' then 'apply_failed'
                when p_ok then 'reverted'
                else 'revert_failed'
              end;
  update public.ai_code_requests
     set status = v_status,
         worker_id = null,
         lease_expires_at = null,
         apply_result = coalesce(apply_result, '{}'::jsonb)
                        || jsonb_build_object(case when v_req.status = 'applying' then 'apply' else 'revert' end, coalesce(p_result, '{}'::jsonb)),
         last_error = case when p_ok then null else left(coalesce(p_result ->> 'error', 'apply_failed'), 2000) end
   where id = p_request_id
   returning * into v_req;
  update public.ai_code_workers set current_request_id = null, last_seen_at = now() where worker_id = p_worker_id;
  return jsonb_build_object('status', v_status);
end
$$;

-- 자동 검토가 추가 질문을 정했을 때 한 번 더 조사하게 돌려놓는다.
create or replace function public.ai_code_bridge_followup(p_request_id uuid, p_prompt text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req public.ai_code_requests;
begin
  update public.ai_code_requests
     set status = 'followup_queued',
         followup_prompt = left(p_prompt, 60000),
         review_status = null,
         finished_at = null
   where id = p_request_id
     and status in ('ready', 'needs_review')
     and mode = 'investigate'
     and round < max_rounds
     and not cancel_requested
  returning * into v_req;
  return jsonb_build_object('ok', found);
end
$$;

create or replace function public.ai_code_bridge_review_done(p_request_id uuid, p_status text, p_message_id uuid, p_error text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.ai_code_requests
     set review_status = case when p_status in ('done', 'skipped', 'error') then p_status else 'error' end,
         review_message_id = coalesce(p_message_id, review_message_id),
         review_error = left(p_error, 2000)
   where id = p_request_id;
end
$$;

revoke all on function public.ai_code_bridge_claim(text, integer, jsonb) from public, anon, authenticated;
revoke all on function public.ai_code_bridge_heartbeat(text, uuid, integer, text, text) from public, anon, authenticated;
revoke all on function public.ai_code_bridge_complete(text, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.ai_code_bridge_apply_done(text, uuid, boolean, jsonb) from public, anon, authenticated;
revoke all on function public.ai_code_bridge_followup(uuid, text) from public, anon, authenticated;
revoke all on function public.ai_code_bridge_review_done(uuid, text, uuid, text) from public, anon, authenticated;
grant execute on function public.ai_code_bridge_claim(text, integer, jsonb) to service_role;
grant execute on function public.ai_code_bridge_heartbeat(text, uuid, integer, text, text) to service_role;
grant execute on function public.ai_code_bridge_complete(text, uuid, jsonb) to service_role;
grant execute on function public.ai_code_bridge_apply_done(text, uuid, boolean, jsonb) to service_role;
grant execute on function public.ai_code_bridge_followup(uuid, text) to service_role;
grant execute on function public.ai_code_bridge_review_done(uuid, text, uuid, text) to service_role;
