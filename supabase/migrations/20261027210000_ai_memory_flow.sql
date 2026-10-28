-- 기억 변경 흐름과 보관(삭제) 제안, 고른 대화의 작업 맥락 조회.
-- 생성·수정·삭제는 카드 승인으로만 반영한다. 서로 기대는 변경은 단계 순서대로만 승인된다.
-- 다른 대화의 승인 요약·작업 상태는 복사하지 않고, 고른 대화 id만 가리킨다.

alter table public.ai_conversations
  add column if not exists context_from_conversation_id uuid references public.ai_conversations (id) on delete set null;

comment on column public.ai_conversations.context_from_conversation_id is
  '사용자가 고른 다른 대화. 그 대화의 승인 요약·작업 상태를 다음 답변의 참고로만 읽는다. 요약 본문은 복사하지 않는다.';

-- ---------------------------------------------------------------------------
-- 흐름. 없거나 json null이면 독립 카드다.
-- ---------------------------------------------------------------------------
create or replace function public.ai_memory_flow_value(p jsonb)
returns jsonb
language plpgsql
immutable
as $$
declare
  v_key text;
  v_step integer;
  v_steps integer;
begin
  if p is null or jsonb_typeof(p) = 'null' then
    return null;
  end if;
  if jsonb_typeof(p) <> 'object' then
    raise exception 'memory_flow_invalid' using errcode = '22023';
  end if;
  v_key := btrim(coalesce(p ->> 'key', ''));
  if v_key = '' or v_key !~ '^[a-z0-9][a-z0-9_-]{0,39}$' then
    raise exception 'memory_flow_invalid' using errcode = '22023';
  end if;
  begin
    v_step := (p ->> 'step')::integer;
    v_steps := (p ->> 'steps')::integer;
  exception when others then
    raise exception 'memory_flow_invalid' using errcode = '22023';
  end;
  if v_step is null or v_steps is null or v_step < 1 or v_steps < v_step or v_steps > 8 then
    raise exception 'memory_flow_invalid' using errcode = '22023';
  end if;
  return jsonb_build_object('key', v_key, 'step', v_step, 'steps', v_steps);
end
$$;

create or replace function public.ai_memory_flow_accept(p_conversation uuid, p_flow jsonb)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if p_flow is null then
    return;
  end if;
  if exists (
    select 1 from public.ai_actions
     where conversation_id = p_conversation
       and kind = 'save_memory'
       and status = 'proposed'
       and payload -> 'flow' ->> 'key' = p_flow ->> 'key'
       and (payload -> 'flow' ->> 'step')::integer = (p_flow ->> 'step')::integer
  ) then
    raise exception 'memory_flow_duplicate' using errcode = '23505';
  end if;
  if (p_flow ->> 'step')::integer > 1 and not exists (
    select 1 from public.ai_actions
     where conversation_id = p_conversation
       and kind = 'save_memory'
       and status in ('proposed', 'applied')
       and payload -> 'flow' ->> 'key' = p_flow ->> 'key'
       and (payload -> 'flow' ->> 'step')::integer = (p_flow ->> 'step')::integer - 1
       and (payload -> 'flow' ->> 'steps')::integer = (p_flow ->> 'steps')::integer
  ) then
    raise exception 'memory_flow_order' using errcode = '22023';
  end if;
end
$$;

create or replace function public.ai_memory_flow_gate(p_row public.ai_actions)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_flow jsonb := public.ai_memory_flow_value(p_row.payload -> 'flow');
  v_prev text;
begin
  if v_flow is null or (v_flow ->> 'step')::integer = 1 then
    return;
  end if;
  select status into v_prev
    from public.ai_actions
   where conversation_id = p_row.conversation_id
     and kind = 'save_memory'
     and id <> p_row.id
     and payload -> 'flow' ->> 'key' = v_flow ->> 'key'
     and (payload -> 'flow' ->> 'step')::integer = (v_flow ->> 'step')::integer - 1
   order by case status when 'applied' then 0 when 'proposed' then 1 else 2 end, created_at desc
   limit 1;
  if v_prev is null or v_prev = 'proposed' then
    raise exception 'memory_flow_waiting' using errcode = '22023';
  elsif v_prev <> 'applied' then
    raise exception 'memory_flow_blocked' using errcode = '22023';
  end if;
end
$$;

-- 보관 제안(relation retire)을 비교 근거에 포함한다. 그 외 분류 규칙은 그대로다.
create or replace function public.ai_memory_collect_basis(
  p_session uuid,
  p_conversation uuid,
  p_mem jsonb,
  p_relation text,
  p_compared jsonb
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_relation text := btrim(coalesce(p_relation, ''));
  v_sup uuid := nullif(p_mem ->> 'supersedes_id', '')::uuid;
  v_ids uuid[];
  v_sorted uuid[];
  v_id uuid;
  v_mem public.ai_memories;
  v_doc text;
  v_reads jsonb := '[]'::jsonb;
  v_searches jsonb;
  v_dup uuid;
  v_search text;
begin
  perform public.ai_memory_session(p_session, p_conversation);
  if v_relation not in ('duplicate', 'supplement', 'conflict', 'distinct', 'hold', 'retire') then
    raise exception 'memory_relation_required' using errcode = '22023';
  end if;
  select status into v_search
    from public.ai_memory_deliveries
   where session_id = p_session and kind = 'search'
   order by id desc
   limit 1;
  if v_search is null then
    raise exception 'memory_search_required' using errcode = '22023';
  elsif v_search not in ('ok', 'empty') then
    raise exception 'memory_search_failed' using errcode = '22023';
  end if;
  v_ids := public.ai_memory_uuid_list(p_compared, 8);
  if v_sup is not null and (v_ids is null or not v_sup = any(v_ids)) then
    v_ids := coalesce(v_ids, '{}'::uuid[]) || v_sup;
  end if;
  select coalesce(array_agg(distinct u order by u), '{}'::uuid[]) into v_sorted
    from unnest(coalesce(v_ids, '{}'::uuid[])) as u;
  foreach v_id in array v_sorted
  loop
    select * into v_mem from public.ai_memories where id = v_id for update;
    if not found or v_mem.status <> 'active' then
      raise exception 'memory_read_missing:%', v_id using errcode = '22023';
    end if;
    if not public.ai_memory_visible_to_conversation(p_conversation, v_id) then
      raise exception 'memory_basis_forbidden:%', v_id using errcode = '42501';
    end if;
    v_doc := public.ai_memory_document(v_mem);
    if exists (
      select 1 from public.ai_memory_deliveries
       where session_id = p_session and kind = 'read' and memory_id = v_id
         and status = 'ok' and version = v_mem.version and content_chars = char_length(v_doc)
    ) then
      null;
    elsif exists (
      select 1 from public.ai_memory_deliveries
       where session_id = p_session and kind = 'read' and memory_id = v_id
         and status = 'truncated' and version = v_mem.version
    ) then
      raise exception 'memory_read_incomplete:%', v_id using errcode = '22023';
    elsif exists (
      select 1 from public.ai_memory_deliveries
       where session_id = p_session and kind = 'read' and memory_id = v_id
         and status in ('ok', 'truncated', 'version_changed') and version is distinct from v_mem.version
    ) then
      raise exception 'memory_reread_required:%', v_id using errcode = '22023';
    elsif exists (
      select 1 from public.ai_memory_deliveries
       where session_id = p_session and kind = 'read' and memory_id = v_id and status = 'forbidden'
    ) then
      raise exception 'memory_basis_forbidden:%', v_id using errcode = '42501';
    else
      raise exception 'memory_read_missing:%', v_id using errcode = '22023';
    end if;
    v_reads := v_reads || jsonb_build_array(jsonb_build_object(
      'id', v_mem.id,
      'version', v_mem.version,
      'title', v_mem.title,
      'role', case when v_mem.id = v_sup then 'supersede' else 'compared' end
    ));
  end loop;
  if v_relation = 'duplicate' then
    v_dup := coalesce(v_sup, v_sorted[1]);
    if v_dup is null then
      raise exception 'memory_duplicate_target_required' using errcode = '22023';
    end if;
    raise exception 'memory_duplicate_classified:%', v_dup using errcode = '23505';
  end if;
  if v_relation = 'hold' then
    raise exception 'memory_comparison_held' using errcode = '22023';
  end if;
  if v_relation = 'retire' and cardinality(coalesce(v_ids, '{}'::uuid[])) = 0 then
    raise exception 'memory_retire_target_required' using errcode = '22023';
  end if;
  if v_relation in ('supplement', 'conflict') and v_sup is null and cardinality(coalesce(v_ids, '{}'::uuid[])) = 0 then
    raise exception 'memory_compare_target_required' using errcode = '22023';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'query', query, 'status', status, 'hit_count', hit_count, 'scope', scope
         ) order by id), '[]'::jsonb)
    into v_searches
    from (
      select id, query, status, hit_count, scope
        from public.ai_memory_deliveries
       where session_id = p_session and kind = 'search' and status in ('ok', 'empty')
       order by id desc
       limit 8
    ) s;
  return jsonb_build_object(
    'session_id', p_session,
    'relation', v_relation,
    'searches', v_searches,
    'reads', v_reads,
    'limit', 'searched_only'
  );
end
$$;

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
  v_session uuid;
  v_basis jsonb;
  v_flow jsonb;
  v_title text;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_kind = 'split_conversation' then
    raise exception 'split_use_dedicated_rpc' using errcode = '22023';
  end if;
  if p_kind in ('handover_department', 'exclude_context', 'mark_important', 'progress_summary', 'department_criteria_change') then
    raise exception 'action_use_dedicated_rpc' using errcode = '22023';
  end if;
  if not exists (select 1 from public.ai_conversations where id = p_conversation_id) then
    raise exception 'conversation_not_found' using errcode = 'P0002';
  end if;

  if p_kind = 'save_memory' and btrim(coalesce(p_payload ->> 'op', '')) = 'retire' then
    begin
      v_id := nullif(btrim(coalesce(p_payload ->> 'memory_id', '')), '')::uuid;
      v_session := nullif(btrim(coalesce(p_payload ->> 'read_session', '')), '')::uuid;
    exception when invalid_text_representation then
      raise exception 'memory_read_session_invalid' using errcode = '22023';
    end;
    if v_id is null then
      raise exception 'memory_retire_target_required' using errcode = '22023';
    end if;
    v_flow := public.ai_memory_flow_value(p_payload -> 'flow');
    perform public.ai_memory_flow_accept(p_conversation_id, v_flow);
    v_basis := public.ai_memory_collect_basis(
      v_session, p_conversation_id, '{}'::jsonb, 'retire', jsonb_build_array(v_id)
    );
    if not exists (
      select 1 from jsonb_array_elements(v_basis -> 'reads') e where e ->> 'id' = v_id::text
    ) then
      raise exception 'memory_read_missing:%', v_id using errcode = '22023';
    end if;
    select e ->> 'title' into v_title
      from jsonb_array_elements(v_basis -> 'reads') e
     where e ->> 'id' = v_id::text
     limit 1;
    insert into public.ai_actions (conversation_id, kind, payload, preview)
    values (
      p_conversation_id, 'save_memory',
      jsonb_build_object('op', 'retire', 'memory_id', v_id, 'reason', v_reason, 'basis', v_basis)
        || case when v_flow is null then '{}'::jsonb else jsonb_build_object('flow', v_flow) end,
      jsonb_build_object('op', 'retire', 'title', coalesce(v_title, ''), 'relation', 'retire', 'memory_id', v_id, 'reason', v_reason)
    )
    returning * into v_row;
    return v_row;
  end if;

  if p_kind = 'save_memory' then
    if btrim(coalesce(p_payload ->> 'relation', '')) = 'retire' then
      raise exception 'memory_relation_required' using errcode = '22023';
    end if;
    v_mem := public.ai_memory_proposal_clean(p_payload -> 'memory');
    perform public.ai_memory_proposal_guard(v_mem, null);
    perform public.ai_memory_reject_same(v_mem);
    begin
      v_session := nullif(btrim(coalesce(p_payload ->> 'read_session', '')), '')::uuid;
    exception when invalid_text_representation then
      raise exception 'memory_read_session_invalid' using errcode = '22023';
    end;
    v_flow := public.ai_memory_flow_value(p_payload -> 'flow');
    perform public.ai_memory_flow_accept(p_conversation_id, v_flow);
    v_basis := public.ai_memory_collect_basis(
      v_session, p_conversation_id, v_mem, p_payload ->> 'relation', p_payload -> 'compared_ids'
    );
    insert into public.ai_actions (conversation_id, kind, payload, preview)
    values (
      p_conversation_id, 'save_memory',
      jsonb_build_object('memory', v_mem, 'reason', v_reason, 'basis', v_basis)
        || case when v_flow is null then '{}'::jsonb else jsonb_build_object('flow', v_flow) end,
      public.ai_memory_proposal_preview(v_mem, v_reason) || jsonb_build_object('relation', v_basis ->> 'relation')
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
      if btrim(coalesce(p_payload ->> 'relation', '')) = 'retire' then
        raise exception 'memory_relation_required' using errcode = '22023';
      end if;
      v_mem := public.ai_memory_proposal_clean(p_payload -> 'memory');
      perform public.ai_memory_proposal_guard(v_mem, v_target.id);
      perform public.ai_memory_reject_same(v_mem);
      begin
        v_session := nullif(btrim(coalesce(p_payload ->> 'read_session', '')), '')::uuid;
      exception when invalid_text_representation then
        raise exception 'memory_read_session_invalid' using errcode = '22023';
      end;
      v_basis := public.ai_memory_collect_basis(
        v_session, p_conversation_id, v_mem, p_payload ->> 'relation', p_payload -> 'compared_ids'
      );
    end if;
    insert into public.ai_actions (conversation_id, kind, payload, preview)
    values (
      p_conversation_id, 'memory_card_change',
      jsonb_build_object('target_action_id', v_target.id, 'op', v_op, 'memory', v_mem, 'reason', v_reason, 'basis', v_basis),
      jsonb_build_object(
        'op', v_op,
        'title', coalesce(v_mem ->> 'title', v_target.preview ->> 'title'),
        'target_title', v_target.preview ->> 'title',
        'target_conversation_id', v_target.conversation_id,
        'memory_kind', v_mem ->> 'kind',
        'memory_scope', v_mem ->> 'memory_scope',
        'scope_department', v_mem ->> 'scope_department',
        'reason', v_reason,
        'relation', v_basis ->> 'relation'
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
  v_basis jsonb;
  v_ver integer;
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
    perform public.ai_memory_flow_gate(v_row);
    if btrim(coalesce(v_row.payload ->> 'op', '')) = 'retire' then
      begin
        v_mem_id := nullif(v_row.payload ->> 'memory_id', '')::uuid;
      exception when invalid_text_representation then
        raise exception 'memory_retire_target_required' using errcode = '22023';
      end;
      v_basis := v_row.payload -> 'basis';
      if v_mem_id is null or not exists (
        select 1 from jsonb_array_elements(v_basis -> 'reads') e where e ->> 'id' = v_mem_id::text
      ) then
        raise exception 'memory_read_missing:%', coalesce(v_mem_id::text, '') using errcode = '22023';
      end if;
      perform public.ai_memory_recheck_basis_view(v_row.conversation_id, v_basis, '{}'::jsonb);
      select (e ->> 'version')::integer into v_ver
        from jsonb_array_elements(v_basis -> 'reads') e
       where e ->> 'id' = v_mem_id::text
       limit 1;
      update public.ai_memories
         set status = 'archived'
       where id = v_mem_id and version = v_ver and status = 'active';
      if not found then
        raise exception 'memory_version_conflict:%', v_mem_id using errcode = '22023';
      end if;
      v_result := jsonb_build_object('op', 'retire', 'memory_id', v_mem_id, 'archived', true);
    else
      v_mem := public.ai_memory_proposal_clean(
        case when jsonb_typeof(v_over -> 'memory') = 'object' then v_over -> 'memory' else v_row.payload -> 'memory' end
      );
      v_basis := v_row.payload -> 'basis';
      perform public.ai_memory_proposal_guard(v_mem, v_row.id);
      perform public.ai_memory_recheck_basis(v_row.conversation_id, v_basis, v_mem);
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
      v_result := jsonb_build_object(
        'memory_id', v_mem_id,
        'superseded_id', v_sup,
        'edited', coalesce(jsonb_typeof(v_over -> 'memory') = 'object', false)
      );
    end if;

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
      v_basis := v_row.payload -> 'basis';
      perform public.ai_memory_proposal_guard(v_mem, v_target.id);
      perform public.ai_memory_recheck_basis_view(v_row.conversation_id, v_basis, v_mem);
      if v_op = 'revise' then
        update public.ai_actions
           set payload = jsonb_set(jsonb_set(payload, '{memory}', v_mem), '{basis}', v_basis),
               preview = public.ai_memory_proposal_preview(v_mem, payload ->> 'reason')
                 || jsonb_build_object('revised', true, 'relation', v_basis ->> 'relation')
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
          jsonb_build_object('memory', v_mem, 'reason', v_row.payload ->> 'reason', 'basis', v_basis),
          public.ai_memory_proposal_preview(v_mem, v_row.payload ->> 'reason')
            || jsonb_build_object('relation', v_basis ->> 'relation')
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

-- 고른 대화의 승인 요약과 작업 상태. 행을 만들지 않는다.
create or replace function public.ai_conversation_context_lookup(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_conv public.ai_conversations;
  v_actions jsonb;
  v_codes jsonb;
  v_purpose text;
begin
  if not public.is_superadmin() then
    return jsonb_build_object('status', 'forbidden');
  end if;
  if p_id is null then
    return jsonb_build_object('status', 'not_found');
  end if;
  select * into v_conv from public.ai_conversations where id = p_id;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;
  v_purpose := btrim(coalesce(v_conv.progress_summary ->> 'purpose', ''));
  select coalesce(jsonb_agg(jsonb_build_object(
           'kind', kind, 'status', status,
           'title', left(coalesce(preview ->> 'title', payload ->> 'title', ''), 120)
         ) order by created_at desc), '[]'::jsonb)
    into v_actions
    from (
      select kind, status, preview, payload, created_at
        from public.ai_actions
       where conversation_id = p_id and superseded = false
       order by created_at desc
       limit 10
    ) s;
  select coalesce(jsonb_agg(jsonb_build_object(
           'title', left(coalesce(title, ''), 120), 'status', status
         ) order by created_at desc), '[]'::jsonb)
    into v_codes
    from (
      select title, status, created_at
        from public.ai_code_requests
       where conversation_id = p_id
       order by created_at desc
       limit 8
    ) c;
  if v_purpose = '' and jsonb_array_length(v_actions) = 0 and jsonb_array_length(v_codes) = 0 then
    return jsonb_build_object(
      'status', 'empty', 'title', v_conv.title,
      'progress_summary', null, 'actions', '[]'::jsonb, 'code_requests', '[]'::jsonb
    );
  end if;
  return jsonb_build_object(
    'status', 'ok',
    'title', v_conv.title,
    'progress_summary', case when v_purpose = '' then null else v_conv.progress_summary end,
    'actions', v_actions,
    'code_requests', v_codes
  );
end
$$;

-- 가리키기만 한다. 진행 요약을 복사하지 않고, 작업·카드도 만들지 않는다.
create or replace function public.ai_conversation_set_context_source(p_conversation uuid, p_source uuid)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_status text;
  v_before jsonb;
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if not exists (select 1 from public.ai_conversations where id = p_conversation) then
    raise exception 'conversation_not_found' using errcode = 'P0002';
  end if;
  if p_source is null then
    update public.ai_conversations set context_from_conversation_id = null where id = p_conversation;
    return;
  end if;
  if p_source = p_conversation then
    raise exception 'context_source_self' using errcode = '22023';
  end if;
  v_status := public.ai_conversation_context_lookup(p_source) ->> 'status';
  if v_status = 'not_found' then
    raise exception 'context_source_not_found' using errcode = 'P0002';
  elsif v_status = 'empty' then
    raise exception 'context_source_empty' using errcode = '22023';
  elsif v_status is distinct from 'ok' then
    raise exception 'context_source_unavailable' using errcode = '22023';
  end if;
  select progress_summary into v_before from public.ai_conversations where id = p_conversation;
  update public.ai_conversations
     set context_from_conversation_id = p_source
   where id = p_conversation;
  if (select progress_summary is distinct from v_before from public.ai_conversations where id = p_conversation) then
    raise exception 'context_source_copied' using errcode = '55000';
  end if;
end
$$;

revoke all on function public.ai_memory_flow_value(jsonb) from public, anon, authenticated;
revoke all on function public.ai_memory_flow_accept(uuid, jsonb) from public, anon, authenticated;
revoke all on function public.ai_memory_flow_gate(public.ai_actions) from public, anon, authenticated;
revoke all on function public.ai_memory_collect_basis(uuid, uuid, jsonb, text, jsonb) from public, anon, authenticated;

revoke all on function public.ai_conversation_context_lookup(uuid) from public, anon;
revoke all on function public.ai_conversation_set_context_source(uuid, uuid) from public, anon;
grant execute on function public.ai_conversation_context_lookup(uuid) to authenticated;
grant execute on function public.ai_conversation_set_context_source(uuid, uuid) to authenticated;

notify pgrst, 'reload schema';
