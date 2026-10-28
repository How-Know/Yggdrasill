-- 개념 검수 참조 상한. compared_ids·to_compare_ids는 합산하지 않고 각각 고유 20개까지다.
-- 중복은 첫 순서를 남기고 센다. 21개째는 자르지 않고 concept_review_too_many_refs 다.
-- 잘못된 id·자기 참조·없는 개념은 버리지 않고 concept_review_ref_not_found 다.
-- 상한을 넘긴 위치는 묶음이 미결로 남긴다. 그때의 상한보다 지금 상한이 커지거나 판이 바뀌면 다시 판단한다.

create or replace function public.concept_review_ref_limit()
returns integer
language sql
immutable
as $$ select 20 $$;

create or replace function public.concept_review_ref_block_reopen(p_reason text)
returns boolean
language sql
immutable
as $$
  select split_part(coalesce(p_reason, ''), ':', 1) = 'concept_review_too_many_refs'
     and split_part(coalesce(p_reason, ''), ':', 5) ~ '^[0-9]+$'
     and split_part(p_reason, ':', 5)::integer < public.concept_review_ref_limit();
$$;

-- 상한 초과 미결이 아직 유효하고, 그 범위의 판이 미결을 남길 때와 같으면 다시 꺼내지 않는다.
create or replace function public.concept_review_ref_scope_blocked(
  p_reason text, p_revision text, p_scope text, p_marks jsonb
)
returns boolean
language sql
stable
as $$
  select split_part(coalesce(p_reason, ''), ':', 1) = 'concept_review_too_many_refs'
     and not public.concept_review_ref_block_reopen(p_reason)
     and public.concept_review_revision_part(p_revision, p_scope)
         is not distinct from left(p_marks ->> public.concept_review_scope_mark(p_scope), 12);
$$;

create or replace function public.concept_review_refs(p jsonb, p_self uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_out jsonb := '[]'::jsonb;
  v_seen uuid[] := '{}'::uuid[];
  v_e jsonb;
  v_id uuid;
  v_name text;
begin
  if p is null or jsonb_typeof(p) = 'null' then
    return v_out;
  end if;
  if jsonb_typeof(p) <> 'array' then
    raise exception 'concept_review_bad_refs';
  end if;
  for v_e in select e from jsonb_array_elements(p) e loop
    if jsonb_typeof(v_e) <> 'string' then
      raise exception 'concept_review_ref_not_found';
    end if;
    v_id := public.course_think_uuid(v_e #>> '{}');
    if v_id is null or v_id = p_self then
      raise exception 'concept_review_ref_not_found';
    end if;
    continue when v_id = any (v_seen);
    select name into v_name from public.concepts where id = v_id;
    if not found then
      raise exception 'concept_review_ref_not_found';
    end if;
    v_seen := v_seen || v_id;
    if cardinality(v_seen) > public.concept_review_ref_limit() then
      raise exception 'concept_review_too_many_refs';
    end if;
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'id', v_id, 'name', v_name, 'text', public.concept_review_text_mark(v_id)
    ));
  end loop;
  return v_out;
end;
$$;

revoke all on function public.concept_review_ref_limit() from public, anon, authenticated;
revoke all on function public.concept_review_ref_block_reopen(text) from public, anon, authenticated;
revoke all on function public.concept_review_ref_scope_blocked(text, text, text, jsonb) from public, anon, authenticated;
revoke all on function public.concept_review_refs(jsonb, uuid) from public, anon, authenticated;

create or replace function public.concept_review_job_open_scopes(p_job_id uuid, p_pos integer)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_it public.concept_review_job_items;
  v_view jsonb;
  v_scopes text[] := '{}'::text[];
  v_blocked text[] := '{}'::text[];
  v_created jsonb := '[]'::jsonb;
  v_s jsonb;
  v_d jsonb;
  v_scope text;
  v_cs jsonb;
  v_a public.ai_actions;
  v_item jsonb;
  v_i integer;
  v_marks jsonb;
  r public.concept_quality_reviews;
begin
  select * into v_it from public.concept_review_job_items where job_id = p_job_id and pos = p_pos;
  if not found then
    return jsonb_build_object('scopes', '[]'::jsonb, 'created', '[]'::jsonb);
  end if;
  v_marks := public.concept_review_marks(v_it.concept_id);
  v_view := public.concept_review_job_hold_view(v_it.held_fixes);
  for v_s in select x from jsonb_array_elements(coalesce(v_view -> 'scopes', '[]'::jsonb)) x loop
    v_blocked := v_blocked || (v_s ->> 'scope');
    if v_s ->> 'status' = 'applied' and not ((v_s ->> 'scope') = any (v_scopes))
       and not public.concept_review_ref_scope_blocked(v_it.reason, v_it.revision, v_s ->> 'scope', v_marks) then
      v_scopes := v_scopes || (v_s ->> 'scope');
    end if;
    for v_d in select x from jsonb_array_elements(coalesce(v_s -> 'deps', '[]'::jsonb)) x loop
      if v_d ->> 'status' = 'applied' and v_d ->> 'op' = 'create' and public.course_think_uuid(v_d ->> 'created_concept_id') is not null then
        v_created := v_created || jsonb_build_array(jsonb_build_object(
          'id', v_d ->> 'created_concept_id', 'name', v_d ->> 'target_name', 'scope', v_s ->> 'scope',
          'action_id', v_d ->> 'action_id', 'item', v_d -> 'item'));
      end if;
    end loop;
  end loop;

  v_blocked := v_blocked || coalesce(array(select jsonb_object_keys(coalesce(v_it.scope_cards, '{}'::jsonb))), '{}'::text[]);
  v_marks := public.concept_review_marks(v_it.concept_id);
  for v_a in
    select a.* from public.concept_review_job_cards jc
      join public.ai_actions a on a.id = jc.action_id
     where jc.job_id = p_job_id and a.kind = 'concept_review_record' and p_pos = any (jc.positions)
  loop
    v_i := 0;
    for v_item in select e from jsonb_array_elements(coalesce(v_a.payload -> 'items', '[]'::jsonb)) e loop
      v_i := v_i + 1;
      continue when v_item ->> 'concept_id' is distinct from v_it.concept_id::text;
      v_scope := v_item ->> 'scope';
      select * into r from public.concept_quality_reviews e
       where e.concept_id = v_it.concept_id and e.scope = v_scope
       order by e.created_at desc, e.id desc limit 1;
      if found and not public.concept_review_record_stale(r, v_marks) then
        continue;
      end if;
      if v_a.status = 'applied' and exists (
        select 1 from jsonb_array_elements(coalesce(v_a.result -> 'items', '[]'::jsonb)) e
         where (e ->> 'i')::integer = v_i and e ->> 'status' = 'failed'
           and coalesce(e ->> 'code', '') ~ '^(concept_review_stale|concept_review_compared_changed)'
      ) and not (v_scope = any (v_scopes))
           and not public.concept_review_ref_scope_blocked(v_it.reason, v_it.revision, v_scope, v_marks)
           and not exists (
        select 1 from public.ai_actions p
         cross join lateral jsonb_array_elements(coalesce(p.payload -> 'items', '[]'::jsonb)) x
         where p.kind = 'concept_review_record' and p.status = 'proposed'
           and x ->> 'concept_id' = v_it.concept_id::text and x ->> 'scope' = v_scope
      ) then
        v_scopes := v_scopes || v_scope;
      end if;
    end loop;
  end loop;

  if v_it.state = 'held' then
    v_cs := public.concept_review_job_concept_state(v_it.concept_id, public.concept_review_pending_concepts());
    for v_scope in
      select x #>> '{}' from jsonb_array_elements(coalesce(v_cs -> 'todo', '[]'::jsonb)) x
    loop
      if not (v_scope = any (v_blocked)) and not (v_scope = any (v_scopes))
         and not public.concept_review_ref_scope_blocked(v_it.reason, v_it.revision, v_scope, v_marks) then
        v_scopes := v_scopes || v_scope;
      end if;
    end loop;
  end if;

  return jsonb_build_object('scopes', to_jsonb(v_scopes), 'created', v_created);
end;
$$;


create or replace function public.concept_review_job_hold_note(p_job_id uuid, p_pos integer, p_gen bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_it public.concept_review_job_items;
  v_view jsonb;
  v_reason text;
begin
  select * into v_it from public.concept_review_job_items where job_id = p_job_id and pos = p_pos for update;
  if not found or v_it.state <> 'held' then
    return;
  end if;
  if split_part(coalesce(v_it.reason, ''), ':', 1) = 'concept_review_too_many_refs'
     and not public.concept_review_ref_block_reopen(v_it.reason) then
    return;
  end if;
  v_view := public.concept_review_job_hold_view(v_it.held_fixes);
  if jsonb_array_length(coalesce(v_view -> 'ready', '[]'::jsonb)) > 0 or v_view ->> 'code' is null then
    return;
  end if;
  v_reason := 'hold:' || (v_view ->> 'code');
  if v_it.reason is not distinct from v_reason then
    return;
  end if;
  update public.concept_review_job_items
     set reason = v_reason, next_action = v_view ->> 'next_action', gen = p_gen, updated_at = now()
   where job_id = p_job_id and pos = p_pos;
end;
$$;

-- 보류한 범위의 의존 카드. p_holds 는 위치 → 보류 범위 배열.


create or replace function public.concept_review_job_targets(p_job_id uuid, p_gen bigint, p_count integer)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job public.concept_review_jobs;
  v_walk public.concept_review_walks;
  v_count integer := least(greatest(coalesce(p_count, 50), 1), 50);
  v_pending uuid[];
  v_cs jsonb;
  v_rev text;
  v_state text;
  v_batch jsonb := '[]'::jsonb;
  v_auto jsonb := '{"reused": 0, "missing": 0, "waiting": 0, "open": 0}'::jsonb;
  v_held integer := 0;
  v_last integer := 0;
  v_open jsonb;
  r record;
begin
  v_job := public.concept_review_job_lock(p_job_id, p_gen);
  select * into v_walk from public.concept_review_walks where id = v_job.walk_id;
  v_pending := public.concept_review_pending_concepts();
  for r in
    select x.pos::integer as pos, x.cid, i.state as item_state, i.revision, i.reason, i.action_id, i.action_items,
           greatest(i.updated_at, a.decided_at) as updated_at, a.status as card_status
      from unnest(v_walk.concept_ids) with ordinality as x(cid, pos)
      left join public.concept_review_job_items i on i.job_id = p_job_id and i.pos = x.pos
      left join public.ai_actions a on a.id = i.action_id
     order by x.pos
  loop
    exit when jsonb_array_length(v_batch) >= v_count;
    v_last := r.pos;
    continue when r.item_state = 'drafted';
    continue when r.item_state = 'submitted' and r.card_status = 'proposed';
    continue when r.item_state = 'failed'
      and (r.reason in ('concept_review_stale', 'concept_review_compared_changed') or r.reason like 'judge\_%');
    if r.item_state = 'held' then
      perform public.concept_review_job_hold_note(p_job_id, r.pos, v_job.lease_gen);
    end if;
    v_open := public.concept_review_job_open_scopes(p_job_id, r.pos);
    if jsonb_array_length(coalesce(v_open -> 'scopes', '[]'::jsonb)) > 0 then
      v_cs := public.concept_review_job_concept_state(r.cid, v_pending);
      v_batch := v_batch || jsonb_build_array(jsonb_build_object(
        'position', r.pos, 'concept_id', r.cid, 'todo', v_open -> 'scopes', 'resume_scopes', v_open -> 'scopes',
        'conditions', v_cs -> 'conditions', 'open', v_cs -> 'open', 'supplement', true, 'previous_state', r.item_state
      ));
      continue;
    end if;
    if r.item_state = 'held' then
      continue;
    end if;
    v_cs := public.concept_review_job_concept_state(r.cid, v_pending);
    v_state := v_cs ->> 'state';
    if v_state <> 'todo' then
      if r.item_state is null then
        v_rev := public.concept_review_revision(public.concept_review_marks(r.cid));
        insert into public.concept_review_job_items (job_id, pos, concept_id, state, revision, reason, next_action, gen)
        values (
          p_job_id, r.pos, r.cid,
          case v_state when 'missing' then 'missing' when 'complete' then 'reused' when 'pending' then 'waiting' else 'deferred' end,
          v_rev,
          case v_state when 'missing' then '목록을 만든 뒤 지워진 개념'
                       when 'complete' then '세 조건 모두 지금 판과 맞는 승인 기록이 있다'
                       when 'pending' then '승인을 기다리는 카드(검토·고치기·배치)에 이미 들어 있다'
                       else '사용자 확인이 필요한 검토 기록이 있다: ' || (
                         select string_agg((e ->> 'scope') || ' ' || coalesce(e ->> 'outcome', ''), ', ')
                           from jsonb_array_elements(v_cs -> 'open') e
                       ) end,
          case v_state when 'pending' then '그 카드의 승인 결과를 본다'
                       when 'open' then '기록을 확인하고 사용자가 정한 대로 다시 검토한다' end,
          v_job.lease_gen
        );
        v_state := case v_state when 'complete' then 'reused' when 'pending' then 'waiting' else v_state end;
        v_auto := jsonb_set(v_auto, array[v_state], to_jsonb((v_auto ->> v_state)::integer + 1));
      end if;
      continue;
    end if;
    v_rev := public.concept_review_revision(public.concept_review_marks(r.cid));
    if r.revision is not distinct from v_rev and not public.concept_review_changed_since(r.cid, r.updated_at) and (
         r.item_state in ('deferred', 'failed')
         or (r.item_state = 'submitted' and (
               r.card_status = 'rejected' or public.concept_review_job_item_skipped(r.action_id, r.action_items)
             ))
       ) and not public.concept_review_ref_block_reopen(r.reason) then
      v_held := v_held + 1;
      continue;
    end if;
    v_batch := v_batch || jsonb_build_array(jsonb_build_object(
      'position', r.pos, 'concept_id', r.cid, 'todo', v_cs -> 'todo', 'conditions', v_cs -> 'conditions',
      'open', v_cs -> 'open', 'supplement', r.item_state is not null, 'previous_state', r.item_state
    ));
  end loop;
  update public.concept_review_jobs
     set served_through = greatest(served_through, v_last), updated_at = now(),
         last_progress_at = case when v_auto <> '{"reused": 0, "missing": 0, "waiting": 0, "open": 0}'::jsonb
                                 then now() else last_progress_at end
   where id = p_job_id;
  perform public.concept_review_job_advance(p_job_id);
  select * into v_job from public.concept_review_jobs where id = p_job_id;
  return jsonb_build_object(
    'batch', v_batch, 'auto_saved', v_auto, 'held', v_held,
    'supplement', (select count(*) from jsonb_array_elements(v_batch) e where (e ->> 'supplement')::boolean),
    'checkpoint', v_job.checkpoint, 'served_through', v_job.served_through, 'total', v_job.total,
    'reached_end', v_last >= v_job.total
  );
end;
$$;


create or replace function public.concept_review_job_save(p_job_id uuid, p_gen bigint, p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job public.concept_review_jobs;
  v_walk public.concept_review_walks;
  v_e jsonb;
  v_r jsonb;
  v_pos integer;
  v_cid uuid;
  v_state text;
  v_prev public.concept_review_job_items;
  v_card public.ai_actions;
  v_marks jsonb;
  v_rev text;
  v_draft jsonb;
  v_scopes text[];
  v_scope text;
  v_outcome text;
  v_hash text;
  v_rework boolean;
  v_next text;
  v_reason text;
  v_unread text;
  v_complete boolean;
  v_version integer;
  v_held jsonb;
  v_new_scopes text[];
  v_out jsonb := '[]'::jsonb;
  v_saved integer := 0;
begin
  v_job := public.concept_review_job_lock(p_job_id, p_gen);
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'concept_review_job_no_items';
  end if;
  if jsonb_array_length(p_items) > 10 then
    raise exception 'concept_review_job_too_many';
  end if;
  select * into v_walk from public.concept_review_walks where id = v_job.walk_id;

  for v_e in select e from jsonb_array_elements(p_items) e loop
    v_pos := null;
    begin
      if jsonb_typeof(v_e) <> 'object' then
        raise exception 'concept_review_job_bad_item';
      end if;
      v_pos := case when jsonb_typeof(v_e -> 'position') = 'number' then (v_e ->> 'position')::integer end;
      if v_pos is null or v_pos < 1 or v_pos > v_job.total then
        raise exception 'concept_review_job_bad_position';
      end if;
      v_cid := public.course_think_uuid(v_e ->> 'concept_id');
      if v_cid is distinct from v_walk.concept_ids[v_pos] then
        raise exception 'concept_review_job_wrong_concept';
      end if;
      if v_pos > v_job.served_through and not exists (
        select 1 from public.concept_review_job_items where job_id = p_job_id and pos = v_pos
      ) then
        raise exception 'concept_review_job_not_served';
      end if;
      v_state := v_e ->> 'state';
      if v_state is null or v_state not in ('drafted', 'deferred', 'failed') then
        raise exception 'concept_review_job_bad_state';
      end if;
      v_rework := coalesce((v_e ->> 'rework')::boolean, false);
      v_next := nullif(left(btrim(coalesce(v_e ->> 'next_action', '')), 300), '');
      v_reason := nullif(left(btrim(coalesce(v_e ->> 'reason', '')), 500), '');
      v_unread := nullif(left(btrim(coalesce(v_e ->> 'unread', '')), 500), '');
      v_complete := coalesce((v_e ->> 'read_complete')::boolean, false);
      if not exists (select 1 from public.concepts where id = v_cid) then
        raise exception 'concept_review_concept_not_found';
      end if;
      v_marks := public.concept_review_marks(v_cid);

      select * into v_prev from public.concept_review_job_items where job_id = p_job_id and pos = v_pos for update;
      v_card := null;
      if found and v_prev.action_id is not null then
        select * into v_card from public.ai_actions where id = v_prev.action_id;
      end if;
      if v_prev.state in ('submitted', 'waiting') and (
           v_card.status = 'proposed' or (v_prev.state = 'waiting' and v_cid = any (public.concept_review_pending_concepts()))
         ) then
        raise exception 'concept_review_job_item_pending';
      end if;
      if v_prev.state in ('reused', 'submitted') and not v_rework
         and public.concept_review_job_concept_state(v_cid, '{}'::uuid[]) ->> 'state' = 'complete' then
        raise exception 'concept_review_job_item_done';
      end if;

      v_draft := v_prev.draft;
      v_rev := v_prev.revision;
      if v_state = 'drafted' then
        if not v_complete then
          raise exception 'concept_review_job_read_incomplete';
        end if;
        if jsonb_typeof(v_e -> 'reviews') <> 'array' or jsonb_array_length(v_e -> 'reviews') not between 1 and 7 then
          raise exception 'concept_review_job_bad_reviews';
        end if;
        v_rev := btrim(coalesce(v_e ->> 'revision', ''));
        v_scopes := '{}'::text[];
        v_draft := '[]'::jsonb;
        for v_r in select x from jsonb_array_elements(v_e -> 'reviews') x loop
          v_scope := v_r ->> 'scope';
          v_outcome := v_r ->> 'outcome';
          if v_scope is null or v_scope not in ('notation', 'meaning', 'classification', 'unit', 'relations', 'foundation', 'placement') then
            raise exception 'concept_review_bad_scope';
          end if;
          if v_scope = any (v_scopes) then
            raise exception 'concept_review_duplicate';
          end if;
          v_scopes := v_scopes || v_scope;
          if v_outcome is null or v_outcome not in ('no_issue_found', 'issue_found', 'needs_comparison', 'unverified', 'merge_needed') then
            raise exception 'concept_review_bad_outcome';
          end if;
          if v_outcome = 'merge_needed' and v_scope <> 'unit' then
            raise exception 'concept_review_merge_scope';
          end if;
          if public.concept_review_revision_part(v_rev, v_scope) is null then
            raise exception 'concept_review_revision_required';
          end if;
          if public.concept_review_revision_part(v_rev, v_scope) <> left(v_marks ->> public.concept_review_scope_mark(v_scope), 12) then
            raise exception 'concept_review_stale';
          end if;
          v_draft := v_draft || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
            'concept_id', v_cid, 'revision', v_rev, 'scope', v_scope, 'outcome', v_outcome,
            'checked', public.concept_review_text(v_r ->> 'checked', 1000, true),
            'findings', public.concept_review_text(v_r ->> 'findings', 2000, true),
            'basis', public.concept_review_text(v_r ->> 'basis', 1000, true),
            'unverified', to_jsonb(public.concept_review_text(v_r ->> 'unverified', 1000, false)),
            'follow_up', to_jsonb(public.concept_review_text(v_r ->> 'follow_up', 1000, false)),
            'compared_ids', coalesce((
              select jsonb_agg(c ->> 'id') from jsonb_array_elements(public.concept_review_refs(v_r -> 'compared_ids', v_cid)) c
            ), '[]'::jsonb),
            'to_compare_ids', coalesce((
              select jsonb_agg(c ->> 'id') from jsonb_array_elements(public.concept_review_refs(v_r -> 'to_compare_ids', v_cid)) c
            ), '[]'::jsonb),
            'compared_text', coalesce((
              select jsonb_object_agg(c ->> 'id', c ->> 'text')
                from jsonb_array_elements(public.concept_review_refs(v_r -> 'compared_ids', v_cid)) c
            ), '{}'::jsonb),
            'detail', public.concept_review_detail_clean(v_r -> 'detail'),
            'fix', public.concept_review_fix_clean(v_scope, v_outcome, v_r -> 'fix', v_cid)
          )));
        end loop;
      else
        if v_next is null or v_reason is null then
          raise exception 'concept_review_job_next_required';
        end if;
      end if;

      v_held := '[]'::jsonb;
      if v_prev.pos is not null and v_prev.state = 'held' and v_state = 'drafted' then
        v_new_scopes := coalesce(array(select x ->> 'scope' from jsonb_array_elements(coalesce(v_draft, '[]'::jsonb)) x), '{}'::text[]);
        v_held := coalesce(v_prev.held_fixes, '[]'::jsonb);
        v_draft := coalesce((
          select jsonb_agg(x order by n)
            from jsonb_array_elements(coalesce(v_prev.draft, '[]'::jsonb)) with ordinality t(x, n)
           where (x ->> 'scope') in (select h ->> 'scope' from jsonb_array_elements(v_held) h)
             and not ((x ->> 'scope') = any (v_new_scopes))
        ), '[]'::jsonb) || coalesce(v_draft, '[]'::jsonb);
        v_held := coalesce((
          select jsonb_agg(h) from jsonb_array_elements(v_held) h
           where not ((h ->> 'scope') = any (v_new_scopes))
        ), '[]'::jsonb);
        if jsonb_array_length(v_held) > 0 then
          v_state := 'held';
        end if;
      elsif v_prev.pos is not null and v_prev.state = 'held' and v_state in ('failed', 'deferred') then
        v_draft := v_prev.draft;
        v_rev := v_prev.revision;
        v_held := coalesce(v_prev.held_fixes, '[]'::jsonb);
        v_state := 'held';
      end if;
      if split_part(coalesce(v_reason, ''), ':', 1) = 'concept_review_too_many_refs' then
        v_rev := public.concept_review_revision(v_marks);
      end if;
      v_hash := md5(jsonb_build_array(v_state, v_rev, v_draft, v_held, v_next, v_reason, v_unread, v_complete)::text);
      if v_prev.pos is not null and v_prev.draft_hash = v_hash and v_prev.state = v_state then
        v_out := v_out || jsonb_build_array(jsonb_build_object(
          'position', v_pos, 'status', 'unchanged', 'draft_version', v_prev.draft_version
        ));
        continue;
      end if;
      if v_prev.pos is not null and v_card.status = 'rejected' and not v_rework
         and v_draft is not distinct from v_prev.draft then
        raise exception 'concept_review_job_same_as_rejected';
      end if;
      v_version := case
        when v_prev.pos is null then case when v_state = 'drafted' then 1 else 0 end
        when v_draft is distinct from v_prev.draft or v_rework or v_prev.state in ('submitted', 'failed', 'waiting', 'reused', 'deferred')
          then v_prev.draft_version + 1
        else v_prev.draft_version
      end;

      insert into public.concept_review_job_items (
        job_id, pos, concept_id, state, revision, read_complete, unread, draft, draft_version, draft_hash,
        next_action, reason, action_id, action_items, held_fixes, gen, updated_by, updated_at
      )
      values (
        p_job_id, v_pos, v_cid, v_state, v_rev, v_complete, v_unread, v_draft, v_version, v_hash,
        v_next, v_reason, null, null, coalesce(v_held, '[]'::jsonb), v_job.lease_gen, auth.uid(), now()
      )
      on conflict (job_id, pos) do update
        set state = excluded.state, revision = excluded.revision, read_complete = excluded.read_complete,
            unread = excluded.unread, draft = excluded.draft, draft_version = excluded.draft_version,
            draft_hash = excluded.draft_hash, next_action = excluded.next_action, reason = excluded.reason,
            held_fixes = excluded.held_fixes,
            action_id = case
              when excluded.state = 'held' then concept_review_job_items.action_id
              when excluded.state = 'drafted' or excluded.draft_version <> concept_review_job_items.draft_version
                then null else concept_review_job_items.action_id end,
            action_items = case
              when excluded.state = 'held' then concept_review_job_items.action_items
              when excluded.state = 'drafted' or excluded.draft_version <> concept_review_job_items.draft_version
                then null else concept_review_job_items.action_items end,
            gen = excluded.gen, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
      v_saved := v_saved + 1;
      v_out := v_out || jsonb_build_array(jsonb_build_object('position', v_pos, 'status', 'saved', 'draft_version', v_version));
    exception when others then
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'position', v_pos, 'status', 'error', 'code', left(sqlerrm, 200)
      ));
    end;
  end loop;

  if v_saved > 0 then
    update public.concept_review_jobs set last_progress_at = now(), updated_at = now() where id = p_job_id;
  end if;
  return jsonb_build_object('items', v_out, 'saved', v_saved, 'checkpoint', public.concept_review_job_advance(p_job_id));
end;
$$;


notify pgrst, 'reload schema';
