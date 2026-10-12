-- 20261011100000: Think 기억 저장 제안 카드 (운영자 결정 2026-10-11, 기억 5ede3fa1)
-- - save_memory: Think가 확정된 결론·원칙을 기억으로 저장하자고 제안한다. 사람이 승인(또는 고쳐서 승인)해야
--   ai_action_apply가 ai_memories에 active로 넣는다. 대체할 기억이 있으면 그 기억을 superseded로 바꾼다.
-- - memory_card_change: 대기 중인 save_memory 카드를 수정(revise)·대체(replace)·삭제(withdraw)하자는 제안.
--   승인해야 처리한다. 자동으로 카드를 고치거나 지우지 않는다.
-- - 대기 카드는 기한 없이 남는다. 다른 제안 종류와 달리 같은 종류의 새 제안이 이전 카드를 대체하지 않는다.
--   같은 제목의 확정 기억·대기 카드가 있으면 제안을 막고 그 id를 돌려준다(Think가 사용자에게 알리고 변경 카드를 낸다).
-- - 범위: 새 기억은 common 또는 department(+부서). legacy_unscoped로는 만들지 않는다. 범위는 Think의 제안값이고
--   카드에서 사람이 바꾼 값(p_overrides.memory)으로 저장한다.
-- 설계: docs/architecture/ai-think-actions.md §9

-- ---------------------------------------------------------------------------
-- 1) 제약
-- ---------------------------------------------------------------------------
alter table public.ai_actions drop constraint if exists ai_actions_kind_check;
alter table public.ai_actions add constraint ai_actions_kind_check
  check (kind in (
    'code_request', 'code_change', 'code_plan', 'place_conversation', 'delete_code_request', 'delete_folder',
    'delete_conversation', 'split_conversation', 'save_memory', 'memory_card_change'
  ));

create index if not exists idx_ai_actions_pending_memory
  on public.ai_actions (kind, created_at) where status = 'proposed' and kind in ('save_memory', 'memory_card_change');

-- ---------------------------------------------------------------------------
-- 2) 내부 도우미
-- ---------------------------------------------------------------------------
-- 같은 기억인지 보는 제목 키: 공백을 빼고 소문자로.
create or replace function public.ai_memory_title_key(p_title text)
returns text
language sql
immutable
set search_path = public
as $$
  select lower(regexp_replace(coalesce(p_title, ''), '\s+', '', 'g'))
$$;

create or replace function public.ai_memory_text_list(p jsonb, p_items integer, p_chars integer)
returns text[]
language sql
immutable
set search_path = public
as $$
  select coalesce(array_agg(left(btrim(x), p_chars) order by o), '{}'::text[])
    from (
      select x, o
        from jsonb_array_elements_text(case when jsonb_typeof(p) = 'array' then p else '[]'::jsonb end)
             with ordinality as t(x, o)
       where btrim(x) <> ''
       order by o
       limit p_items
    ) s
$$;

-- 제안·승인에 쓰는 기억 내용을 검사하고 정리한다. 대체 대상은 지금 active인 기억만 허용한다.
create or replace function public.ai_memory_proposal_clean(p jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v jsonb := case when jsonb_typeof(p) = 'object' then p else '{}'::jsonb end;
  v_kind text := btrim(coalesce(v ->> 'kind', ''));
  v_title text := left(btrim(coalesce(v ->> 'title', '')), 200);
  v_content text := left(btrim(coalesce(v ->> 'content', '')), 8000);
  v_scope text := coalesce(nullif(btrim(coalesce(v ->> 'memory_scope', '')), ''), 'common');
  v_dept text := nullif(btrim(coalesce(v ->> 'scope_department', '')), '');
  v_sup uuid;
begin
  if v_kind not in ('decision', 'principle') then
    raise exception 'memory_kind_invalid' using errcode = '22023';
  end if;
  if v_title = '' then
    raise exception 'memory_title_required' using errcode = '22023';
  end if;
  if v_content = '' then
    raise exception 'memory_content_required' using errcode = '22023';
  end if;
  if v_scope not in ('common', 'department') then
    raise exception 'memory_scope_invalid' using errcode = '22023';
  end if;
  if v_scope = 'department' then
    if v_dept is null or v_dept not in ('education', 'product', 'engineering') then
      raise exception 'scope_department_required' using errcode = '22023';
    end if;
  else
    v_dept := null;
  end if;
  begin
    v_sup := nullif(btrim(coalesce(v ->> 'supersedes_id', '')), '')::uuid;
  exception when invalid_text_representation then
    raise exception 'memory_supersede_not_active' using errcode = '22023';
  end;
  if v_sup is not null and not exists (select 1 from public.ai_memories where id = v_sup and status = 'active') then
    raise exception 'memory_supersede_not_active' using errcode = '22023';
  end if;
  return jsonb_build_object(
    'kind', v_kind,
    'title', v_title,
    'content', v_content,
    'decision_context', nullif(left(btrim(coalesce(v ->> 'decision_context', '')), 4000), ''),
    'decision_reason', nullif(left(btrim(coalesce(v ->> 'decision_reason', '')), 4000), ''),
    'alternatives', to_jsonb(public.ai_memory_text_list(v -> 'alternatives', 12, 500)),
    'tags', to_jsonb(public.ai_memory_text_list(v -> 'tags', 12, 60)),
    'memory_scope', v_scope,
    'scope_department', v_dept,
    'supersedes_id', v_sup
  );
end
$$;

-- 같은 제목의 확정 기억(대체 대상 제외)이나 대기 카드(p_except 제외)가 있으면 막는다.
-- 같은 기억을 대체하려는 대기 카드도 중복으로 본다.
create or replace function public.ai_memory_proposal_guard(p_mem jsonb, p_except_action uuid)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_key text := public.ai_memory_title_key(p_mem ->> 'title');
  v_sup uuid := nullif(p_mem ->> 'supersedes_id', '')::uuid;
  v_id uuid;
begin
  select id into v_id
    from public.ai_memories
   where status = 'active'
     and public.ai_memory_title_key(title) = v_key
     and id is distinct from v_sup
   limit 1;
  if v_id is not null then
    raise exception 'memory_duplicate_active:%', v_id using errcode = '23505';
  end if;
  select id into v_id
    from public.ai_actions
   where kind = 'save_memory'
     and status = 'proposed'
     and id is distinct from p_except_action
     and (
       public.ai_memory_title_key(payload -> 'memory' ->> 'title') = v_key
       or (v_sup is not null and nullif(payload -> 'memory' ->> 'supersedes_id', '')::uuid = v_sup)
     )
   order by created_at
   limit 1;
  if v_id is not null then
    raise exception 'memory_proposal_pending:%', v_id using errcode = '23505';
  end if;
end
$$;

create or replace function public.ai_memory_proposal_preview(p_mem jsonb, p_reason text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'title', p_mem ->> 'title',
    'memory_kind', p_mem ->> 'kind',
    'memory_scope', p_mem ->> 'memory_scope',
    'scope_department', p_mem ->> 'scope_department',
    'supersedes_title', (select m.title from public.ai_memories m where m.id = nullif(p_mem ->> 'supersedes_id', '')::uuid),
    'reason', p_reason
  )
$$;

-- ---------------------------------------------------------------------------
-- 3) 제안
-- ---------------------------------------------------------------------------
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
  v_mem jsonb;
  v_reason text := nullif(left(btrim(coalesce(p_payload ->> 'reason', '')), 500), '');
  v_target public.ai_actions;
  v_target_id uuid;
  v_op text;
  v_id uuid;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_kind = 'split_conversation' then
    raise exception 'split_use_dedicated_rpc' using errcode = '22023';
  end if;
  if not exists (select 1 from public.ai_conversations where id = p_conversation_id) then
    raise exception 'conversation_not_found' using errcode = 'P0002';
  end if;

  -- 기억 카드는 기한 없이 남고 서로 대체하지 않는다. 같은 기억인지 검사한 뒤 넣는다.
  if p_kind = 'save_memory' then
    v_mem := public.ai_memory_proposal_clean(p_payload -> 'memory');
    perform public.ai_memory_proposal_guard(v_mem, null);
    insert into public.ai_actions (conversation_id, kind, payload, preview)
    values (
      p_conversation_id, 'save_memory',
      jsonb_build_object('memory', v_mem, 'reason', v_reason),
      public.ai_memory_proposal_preview(v_mem, v_reason)
    )
    returning * into v_row;
    return v_row;
  end if;

  if p_kind = 'memory_card_change' then
    v_op := btrim(coalesce(p_payload ->> 'op', ''));
    if v_op not in ('revise', 'replace', 'withdraw') then
      raise exception 'memory_card_op_invalid' using errcode = '22023';
    end if;
    begin
      v_target_id := nullif(btrim(coalesce(p_payload ->> 'target_action_id', '')), '')::uuid;
    exception when invalid_text_representation then
      raise exception 'memory_card_not_pending' using errcode = '22023';
    end;
    select * into v_target from public.ai_actions where id = v_target_id;
    if not found or v_target.kind <> 'save_memory' or v_target.status <> 'proposed' then
      raise exception 'memory_card_not_pending' using errcode = '22023';
    end if;
    select id into v_id
      from public.ai_actions
     where kind = 'memory_card_change' and status = 'proposed' and payload ->> 'target_action_id' = v_target.id::text
     limit 1;
    if v_id is not null then
      raise exception 'memory_card_change_pending:%', v_id using errcode = '23505';
    end if;
    if v_op <> 'withdraw' then
      v_mem := public.ai_memory_proposal_clean(p_payload -> 'memory');
      perform public.ai_memory_proposal_guard(v_mem, v_target.id);
    end if;
    insert into public.ai_actions (conversation_id, kind, payload, preview)
    values (
      p_conversation_id, 'memory_card_change',
      jsonb_build_object('target_action_id', v_target.id, 'op', v_op, 'memory', v_mem, 'reason', v_reason),
      jsonb_build_object(
        'op', v_op,
        'title', coalesce(v_mem ->> 'title', v_target.preview ->> 'title'),
        'target_title', v_target.preview ->> 'title',
        'target_conversation_id', v_target.conversation_id,
        'memory_kind', v_mem ->> 'kind',
        'memory_scope', v_mem ->> 'memory_scope',
        'scope_department', v_mem ->> 'scope_department',
        'reason', v_reason
      )
    )
    returning * into v_row;
    return v_row;
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

-- ---------------------------------------------------------------------------
-- 4) 승인
-- ---------------------------------------------------------------------------
-- p_overrides.memory: 사용자가 카드에서 고친 기억 내용 전체(범위 포함). 없으면 제안 그대로.
create or replace function public.ai_memory_action_apply(p_id uuid, p_overrides jsonb)
returns public.ai_actions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.ai_actions;
  v_over jsonb := coalesce(p_overrides, '{}'::jsonb);
  v_target public.ai_actions;
  v_mem jsonb;
  v_mem_id uuid;
  v_sup uuid;
  v_new public.ai_actions;
  v_result jsonb;
  v_op text;
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

  if v_row.kind = 'save_memory' then
    v_mem := public.ai_memory_proposal_clean(
      case when jsonb_typeof(v_over -> 'memory') = 'object' then v_over -> 'memory' else v_row.payload -> 'memory' end
    );
    perform public.ai_memory_proposal_guard(v_mem, v_row.id);
    v_sup := nullif(v_mem ->> 'supersedes_id', '')::uuid;
    insert into public.ai_memories (
      kind, status, title, content, decision_context, decision_reason, alternatives, tags,
      supersedes_id, source_conversation_id, memory_scope, scope_department
    )
    values (
      v_mem ->> 'kind', 'active', v_mem ->> 'title', v_mem ->> 'content',
      case when v_mem ->> 'kind' = 'decision' then v_mem ->> 'decision_context' end,
      case when v_mem ->> 'kind' = 'decision' then v_mem ->> 'decision_reason' end,
      case when v_mem ->> 'kind' = 'decision'
        then array(select jsonb_array_elements_text(v_mem -> 'alternatives')) else '{}'::text[] end,
      array(select jsonb_array_elements_text(v_mem -> 'tags')),
      v_sup,
      (select id from public.ai_conversations where id = v_row.conversation_id),
      v_mem ->> 'memory_scope',
      v_mem ->> 'scope_department'
    )
    returning id into v_mem_id;
    if v_sup is not null then
      update public.ai_memories set status = 'superseded' where id = v_sup and status = 'active';
    end if;
    v_result := jsonb_build_object(
      'memory_id', v_mem_id,
      'superseded_id', v_sup,
      'edited', coalesce(jsonb_typeof(v_over -> 'memory') = 'object', false)
    );

  elsif v_row.kind = 'memory_card_change' then
    select * into v_target
      from public.ai_actions
     where id = nullif(v_row.payload ->> 'target_action_id', '')::uuid
     for update;
    if not found or v_target.kind <> 'save_memory' or v_target.status <> 'proposed' then
      raise exception 'memory_card_not_pending' using errcode = '22023';
    end if;
    v_op := v_row.payload ->> 'op';
    if v_op = 'withdraw' then
      update public.ai_actions
         set status = 'rejected', decided_at = now(), decided_by = auth.uid(),
             result = jsonb_build_object('withdrawn_by_action_id', v_row.id)
       where id = v_target.id;
      v_result := jsonb_build_object('op', v_op, 'target_action_id', v_target.id);
    else
      v_mem := public.ai_memory_proposal_clean(
        case when jsonb_typeof(v_over -> 'memory') = 'object' then v_over -> 'memory' else v_row.payload -> 'memory' end
      );
      perform public.ai_memory_proposal_guard(v_mem, v_target.id);
      if v_op = 'revise' then
        update public.ai_actions
           set payload = jsonb_set(payload, '{memory}', v_mem),
               preview = public.ai_memory_proposal_preview(v_mem, payload ->> 'reason') || jsonb_build_object('revised', true)
         where id = v_target.id;
        v_result := jsonb_build_object('op', v_op, 'target_action_id', v_target.id);
      elsif v_op = 'replace' then
        update public.ai_actions
           set status = 'rejected', superseded = true, decided_at = now(), decided_by = auth.uid(),
               result = jsonb_build_object('replaced_by_action_id', v_row.id)
         where id = v_target.id;
        insert into public.ai_actions (conversation_id, message_id, kind, payload, preview)
        values (
          v_row.conversation_id, v_row.message_id, 'save_memory',
          jsonb_build_object('memory', v_mem, 'reason', v_row.payload ->> 'reason'),
          public.ai_memory_proposal_preview(v_mem, v_row.payload ->> 'reason')
        )
        returning * into v_new;
        v_result := jsonb_build_object('op', v_op, 'target_action_id', v_target.id, 'new_action_id', v_new.id);
      else
        raise exception 'memory_card_op_invalid' using errcode = '22023';
      end if;
    end if;

  else
    raise exception 'action_kind_not_appliable' using errcode = '22023';
  end if;

  update public.ai_actions
     set status = 'applied', result = v_result, error = null, decided_at = now(), decided_by = auth.uid()
   where id = p_id
  returning * into v_row;
  return v_row;
end
$$;

-- 20261009100000의 정의에 기억 카드 분기만 더했다.
-- p_overrides: 사용자가 카드에서 고친 값만. code_*: {title, spec}, place_conversation: {folder_id},
-- split_conversation: {title, summary, folder_id}, save_memory·memory_card_change: {memory}
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
  -- 나누기는 원본 대화를 먼저 잠가야 해서 따로 처리한다.
  if exists (select 1 from public.ai_actions where id = p_id and kind = 'split_conversation') then
    return public.ai_conversation_split_apply(p_id, v_over);
  end if;
  if exists (select 1 from public.ai_actions where id = p_id and kind in ('save_memory', 'memory_card_change')) then
    return public.ai_memory_action_apply(p_id, v_over);
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

  else
    raise exception 'action_kind_not_appliable' using errcode = '22023';
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

-- ---------------------------------------------------------------------------
-- 5) 기능 확인 (20261010160000 정의에 memory_proposals 추가)
-- ---------------------------------------------------------------------------
create or replace function public.ai_think_db_features()
returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'conversation_split',
    case
      when to_regprocedure('public.ai_conversation_split_propose(uuid, uuid, jsonb, jsonb, boolean)') is not null
       and to_regprocedure('public.ai_conversation_split_apply(uuid, jsonb)') is not null
       and exists (
         select 1 from pg_attribute
          where attrelid = 'public.ai_conversations'::regclass and attname = 'split_summary' and not attisdropped
       )
       and exists (
         select 1 from pg_attribute
          where attrelid = 'public.ai_messages'::regclass and attname = 'source_message_id' and not attisdropped
       )
      then 1
      else 0
    end,
    'think_roles',
    case
      when exists (
         select 1 from pg_attribute
          where attrelid = 'public.ai_conversations'::regclass and attname = 'think_role_id' and not attisdropped
       )
       and to_regprocedure('public.ai_conversation_set_think_role(uuid, text, text[], text)') is not null
       and to_regprocedure('public.ai_search_memories_scoped(text[], integer, text, text[], uuid[])') is not null
       and to_regclass('public.ai_conversation_memory_links') is not null
       and to_regclass('public.ai_conversation_document_links') is not null
       and to_regclass('public.ai_message_context_snapshots') is not null
      then 1
      else 0
    end,
    'memory_proposals',
    case
      when to_regprocedure('public.ai_memory_action_apply(uuid, jsonb)') is not null
       and to_regprocedure('public.ai_memory_proposal_clean(jsonb)') is not null
       and to_regprocedure('public.ai_memory_proposal_guard(jsonb, uuid)') is not null
      then 1
      else 0
    end
  );
end
$$;

revoke all on function public.ai_memory_title_key(text) from public, anon, authenticated, service_role;
revoke all on function public.ai_memory_text_list(jsonb, integer, integer) from public, anon, authenticated, service_role;
revoke all on function public.ai_memory_proposal_clean(jsonb) from public, anon, authenticated, service_role;
revoke all on function public.ai_memory_proposal_guard(jsonb, uuid) from public, anon, authenticated, service_role;
revoke all on function public.ai_memory_proposal_preview(jsonb, text) from public, anon, authenticated, service_role;
revoke all on function public.ai_memory_action_apply(uuid, jsonb) from public, anon, authenticated, service_role;
