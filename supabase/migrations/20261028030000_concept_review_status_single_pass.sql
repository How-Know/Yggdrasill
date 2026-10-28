-- 검수 상태 집계를 목록 한 번 순회로 합친다.
-- 개념마다 지문(concept_review_marks)을 한 번 구하고, 그 jsonb를 상태와 1차 검수 판정에 넘긴다.
-- 상태 반환만으로 1차 검수를 판정하지 않는다. 통합 완료·3조건·조건별 합계의 기준은 그대로다.
-- 작업별 최근 집계 진단만 저장한다. 이 함수는 집계를 부르지 않는다.

create or replace function public.concept_review_job_concept_state(p_concept_id uuid, p_pending uuid[], p_marks jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_marks jsonb;
  v_scope text;
  v_required boolean;
  r public.concept_quality_reviews;
  v_st text;
  v_fix text;
  v_scopes jsonb := '{}'::jsonb;
  v_todo text[] := '{}'::text[];
  v_wait text[] := '{}'::text[];
  v_open jsonb := '[]'::jsonb;
  n text;
  m text;
begin
  if not exists (select 1 from public.concepts where id = p_concept_id) then
    return jsonb_build_object('state', 'missing');
  end if;
  v_marks := coalesce(p_marks, public.concept_review_marks(p_concept_id));
  foreach v_scope in array array['notation', 'meaning', 'foundation', 'placement', 'classification', 'unit', 'relations'] loop
    v_required := v_scope in ('notation', 'meaning', 'foundation', 'placement');
    select * into r from public.concept_quality_reviews
     where concept_id = p_concept_id and scope = v_scope
     order by created_at desc, id desc limit 1;
    if not found then
      continue when not v_required;
      v_st := 'missing';
    elsif public.concept_review_record_stale(r, v_marks) then
      v_st := 'recheck';
    elsif r.outcome = 'no_issue_found' then
      v_st := 'met';
    elsif r.outcome = 'issue_found' then
      v_fix := public.concept_review_fix_state(r.fixes);
      v_st := case v_fix
        when 'proposed' then 'pending'
        when 'applied' then 'recheck'
        when 'failed' then 'recheck'
        when 'none' then case when v_required then 'recheck' else 'issue' end
        else 'issue' end;
    else
      v_st := 'open';
    end if;
    v_scopes := v_scopes || jsonb_build_object(v_scope, jsonb_build_object(
      'state', v_st, 'outcome', r.outcome, 'record_id', r.id
    ));
    if v_st in ('missing', 'recheck') then
      v_todo := v_todo || v_scope;
    elsif v_st = 'pending' then
      v_wait := v_wait || v_scope;
    elsif v_st in ('issue', 'open') then
      v_open := v_open || jsonb_build_array(jsonb_build_object('scope', v_scope, 'outcome', r.outcome, 'state', v_st));
    end if;
  end loop;
  n := v_scopes -> 'notation' ->> 'state';
  m := v_scopes -> 'meaning' ->> 'state';
  return jsonb_build_object(
    'state', case
      when p_concept_id = any (coalesce(p_pending, '{}'::uuid[])) or cardinality(v_wait) > 0 then 'pending'
      when cardinality(v_todo) > 0 then 'todo'
      when jsonb_array_length(v_open) > 0 then 'open'
      else 'complete'
    end,
    'todo', to_jsonb(v_todo),
    'waiting', to_jsonb(v_wait),
    'open', v_open,
    'conditions', jsonb_build_object(
      'text', case when n = 'met' and m = 'met' then 'met'
                   when 'pending' in (n, m) then 'pending'
                   when 'recheck' in (n, m) then 'recheck'
                   when 'missing' in (n, m) then 'missing'
                   when 'issue' in (n, m) then 'issue'
                   else 'open' end,
      'foundation', v_scopes -> 'foundation' ->> 'state',
      'placement', v_scopes -> 'placement' ->> 'state'
    ),
    'scopes', v_scopes
  );
end;
$$;

create or replace function public.concept_review_job_concept_state(p_concept_id uuid, p_pending uuid[])
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  return public.concept_review_job_concept_state(p_concept_id, p_pending, null);
end;
$$;

create or replace function public.concept_review_first_pass_met(
  p_concept_id uuid, p_job_id uuid, p_pos integer, p_cs jsonb, p_marks jsonb, p_hold jsonb
)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_item public.concept_review_job_items;
  v_hold jsonb;
  v_hs jsonb;
  v_draft jsonb;
  v_scope text;
  v_decided timestamptz;
begin
  if p_marks is null
     or p_cs -> 'conditions' ->> 'text' is distinct from 'met'
     or p_cs -> 'conditions' ->> 'foundation' is distinct from 'met'
     or p_cs -> 'conditions' ->> 'placement' is distinct from 'met' then
    return false;
  end if;

  if exists (
    select 1 from public.ai_actions a
      cross join lateral jsonb_array_elements(
        case when jsonb_typeof(a.payload -> 'items') = 'array' then a.payload -> 'items' else '[]'::jsonb end
      ) e
     where a.status = 'proposed' and a.kind = 'concept_review_record'
       and public.course_think_uuid(e ->> 'concept_id') = p_concept_id
       and e ->> 'scope' in ('notation', 'meaning', 'foundation', 'placement')
  ) then
    return false;
  end if;
  if exists (
    select 1 from public.ai_actions a
      cross join lateral jsonb_array_elements(
        case when jsonb_typeof(a.payload -> 'items') = 'array' then a.payload -> 'items' else '[]'::jsonb end
      ) e
     where a.status = 'proposed' and a.kind = 'concept_library_change'
       and e ->> 'op' = 'edit'
       and public.course_think_uuid(e ->> 'concept_id') = p_concept_id
       and (e ? 'name' or e ? 'content')
  ) then
    return false;
  end if;
  if exists (
    select 1 from public.ai_actions a
      cross join lateral jsonb_array_elements(
        case when jsonb_typeof(a.payload -> 'items') = 'array' then a.payload -> 'items' else '[]'::jsonb end
      ) e
     where a.status = 'proposed' and a.kind = 'concept_placement_change'
       and (
         public.course_think_uuid(e ->> 'concept_id') = p_concept_id
         or exists (
           select 1 from public.concept_appearances ap
            where ap.id = public.course_think_uuid(e ->> 'placement_id') and ap.concept_id = p_concept_id
         )
       )
  ) then
    return false;
  end if;

  if exists (
    select 1 from public.ai_actions a
      cross join lateral jsonb_array_elements(
        case when jsonb_typeof(a.payload -> 'items') = 'array' then a.payload -> 'items' else '[]'::jsonb end
      ) with ordinality as t(e, n)
     where a.kind = 'concept_review_record'
       and public.course_think_uuid(t.e ->> 'concept_id') = p_concept_id
       and t.e ->> 'scope' in ('notation', 'meaning', 'foundation', 'placement')
       and t.e ->> 'outcome' in ('issue_found', 'needs_comparison', 'unverified')
       and (
         a.status = 'rejected'
         or (a.status = 'applied' and exists (
              select 1 from jsonb_array_elements(coalesce(a.result -> 'items', '[]'::jsonb)) ri
               where (ri ->> 'i')::integer = t.n::integer and ri ->> 'status' in ('failed', 'skipped')
            ))
       )
       and not exists (
         select 1 from public.concept_quality_reviews r
          where r.concept_id = p_concept_id and r.scope = t.e ->> 'scope'
            and r.outcome = 'no_issue_found' and r.created_at > a.created_at
            and not public.concept_review_record_stale(r, p_marks)
       )
  ) then
    return false;
  end if;

  select * into v_item from public.concept_review_job_items where job_id = p_job_id and pos = p_pos;
  if not found then
    return true;
  end if;

  v_hold := coalesce(p_hold, public.concept_review_job_hold_view(v_item.held_fixes));
  for v_hs in select x from jsonb_array_elements(coalesce(v_hold -> 'scopes', '[]'::jsonb)) x loop
    v_scope := v_hs ->> 'scope';
    continue when v_scope not in ('notation', 'meaning', 'foundation', 'placement');
    if v_hs ->> 'status' = 'pending' then
      return false;
    end if;
    select max(coalesce(a.decided_at, a.created_at)) into v_decided
      from jsonb_array_elements(coalesce(v_hs -> 'deps', '[]'::jsonb)) d
      join public.ai_actions a on a.id = public.course_think_uuid(d ->> 'action_id');
    if v_decided is null or not exists (
      select 1 from public.concept_quality_reviews r
       where r.concept_id = p_concept_id and r.scope = v_scope
         and r.outcome = 'no_issue_found' and r.created_at > v_decided
         and not public.concept_review_record_stale(r, p_marks)
    ) then
      return false;
    end if;
  end loop;

  if v_item.state in ('drafted', 'held') then
    for v_draft in select x from jsonb_array_elements(coalesce(v_item.draft, '[]'::jsonb)) x loop
      v_scope := v_draft ->> 'scope';
      continue when v_scope not in ('notation', 'meaning', 'foundation', 'placement');
      continue when v_draft ->> 'outcome' not in ('issue_found', 'needs_comparison', 'unverified');
      if public.concept_review_revision_part(v_draft ->> 'revision', v_scope)
         is distinct from left(p_marks ->> public.concept_review_scope_mark(v_scope), 12) then
        continue;
      end if;
      if exists (
        select 1 from public.concept_quality_reviews r
         where r.concept_id = p_concept_id and r.scope = v_scope
           and r.outcome = 'no_issue_found' and r.created_at > v_item.updated_at
           and not public.concept_review_record_stale(r, p_marks)
      ) then
        continue;
      end if;
      return false;
    end loop;
  end if;
  return true;
end;
$$;

create or replace function public.concept_review_first_pass_met(p_concept_id uuid, p_job_id uuid, p_pos integer)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_marks jsonb;
  v_cs jsonb;
begin
  if not exists (select 1 from public.concepts where id = p_concept_id) then
    return false;
  end if;
  v_marks := public.concept_review_marks(p_concept_id);
  v_cs := public.concept_review_job_concept_state(p_concept_id, '{}'::uuid[], v_marks);
  return public.concept_review_first_pass_met(p_concept_id, p_job_id, p_pos, v_cs, v_marks, null);
end;
$$;

create or replace function public.concept_review_job_status_counts(p_job_id uuid, p_open_limit integer default 20)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_job public.concept_review_jobs;
  v_walk public.concept_review_walks;
  v_pending uuid[];
  v_limit integer := least(greatest(coalesce(p_open_limit, 20), 0), 60);
  v_counts jsonb := '{"complete": 0, "awaiting": 0, "drafted": 0, "open": 0, "todo": 0, "not_reviewed": 0, "missing": 0}'::jsonb;
  v_cond jsonb := '{"text": 0, "foundation": 0, "placement": 0}'::jsonb;
  v_open jsonb := '[]'::jsonb;
  v_cs jsonb;
  v_marks jsonb;
  v_cat text;
  v_next text;
  v_hold jsonb;
  v_total integer;
  v_c text;
  v_met integer := 0;
  v_pct numeric;
  v_line text;
  r record;
begin
  perform public.concept_review_assert_operator();
  select * into v_job from public.concept_review_jobs where id = p_job_id;
  if not found then
    raise exception 'concept_review_job_not_found';
  end if;
  select * into v_walk from public.concept_review_walks where id = v_job.walk_id;
  v_total := coalesce(cardinality(v_walk.concept_ids), 0);
  v_pending := public.concept_review_pending_concepts();

  for r in
    select x.pos::integer as pos, x.cid, i.state as item_state, i.next_action, i.reason, i.action_id, i.revision,
           i.action_items, i.draft_version, i.held_fixes, a.id as card_id, a.status as card_status, a.error as card_error
      from unnest(v_walk.concept_ids) with ordinality as x(cid, pos)
      left join public.concept_review_job_items i on i.job_id = v_job.id and i.pos = x.pos
      left join public.ai_actions a on a.id = i.action_id
     order by x.pos
  loop
    if exists (select 1 from public.concepts where id = r.cid) then
      v_marks := public.concept_review_marks(r.cid);
    else
      v_marks := null;
    end if;
    v_cs := public.concept_review_job_concept_state(r.cid, v_pending, v_marks);
    v_next := r.next_action;
    v_hold := case when r.item_state = 'held' then public.concept_review_job_hold_view(r.held_fixes) else null end;
    v_cat := case
      when v_cs ->> 'state' = 'missing' then 'missing'
      when r.item_state = 'held' and jsonb_array_length(coalesce(v_hold -> 'ready', '[]'::jsonb)) > 0 then 'todo'
      when r.item_state = 'held' and coalesce((v_hold ->> 'waiting')::boolean, false) then 'awaiting'
      when r.item_state = 'held' then 'open'
      when r.item_state = 'submitted' and r.card_status = 'proposed' and coalesce(r.card_error, '') <> '' then 'open'
      when v_cs ->> 'state' = 'complete' then 'complete'
      when r.item_state = 'drafted' then 'drafted'
      when v_cs ->> 'state' = 'pending' then 'awaiting'
      when r.item_state in ('deferred', 'failed') then 'open'
      when r.item_state = 'submitted' and (r.card_id is null or r.card_status = 'rejected'
                                           or public.concept_review_job_item_skipped(r.action_id, r.action_items)) then 'open'
      when v_cs ->> 'state' = 'open' then 'open'
      when r.item_state is null then 'not_reviewed'
      else 'todo'
    end;
    if r.item_state = 'held' then
      v_next := coalesce(v_hold ->> 'next_action', case
        when jsonb_array_length(coalesce(v_hold -> 'ready', '[]'::jsonb)) > 0
          then '의존하던 변경이 반영됐습니다. 다음 검수가 그 범위만 다시 판단합니다.'
        else '의존하는 변경 결과를 확인한 뒤 그 범위만 다시 판단합니다.' end);
    elsif r.item_state = 'submitted' and r.card_status = 'proposed' and coalesce(r.card_error, '') <> '' then
      v_next := '지난 승인에서 반영하지 못했습니다. 카드는 그대로이니 다시 승인하거나 거절할 수 있습니다.';
    elsif v_cat = 'open' and r.item_state = 'submitted' and v_cs ->> 'state' <> 'open' then
      v_next := case
        when r.card_id is null then '카드가 없어졌다(대화 삭제 등). 다음 묶음 검수에서 다시 판단한다'
        when r.card_status = 'rejected' then '거절된 카드다. 사용자 의견을 확인하고 고친 초안을 저장한다(같은 내용 재제출 안 함)'
        else '승인 때 뺀 항목이 있다. 사용자 의견을 확인한 뒤 다시 검수한다'
      end;
    elsif v_cat = 'open' and r.item_state not in ('deferred', 'failed') then
      v_next := '사용자 확인이 필요한 기록: ' || coalesce((
        select string_agg((e ->> 'scope') || ' ' || coalesce(e ->> 'outcome', '') ||
                          case when e ->> 'state' = 'issue' then '(고치기 카드 거절·일부 반영)' else '' end, ', ')
          from jsonb_array_elements(v_cs -> 'open') e
      ), '');
    elsif v_cat in ('todo', 'not_reviewed') then
      v_next := '다음 묶음 검수에서 부족한 범위를 검수한다: ' || coalesce((
        select string_agg(x #>> '{}', ', ') from jsonb_array_elements(v_cs -> 'todo') x
      ), '');
    elsif v_cat = 'awaiting' then
      v_next := '승인 대기 카드(검토·고치기·배치)의 결과를 본다';
    end if;
    v_counts := jsonb_set(v_counts, array[v_cat], to_jsonb((v_counts ->> v_cat)::integer + 1));
    foreach v_c in array array['text', 'foundation', 'placement'] loop
      if v_cs -> 'conditions' ->> v_c = 'met' then
        v_cond := jsonb_set(v_cond, array[v_c], to_jsonb((v_cond ->> v_c)::integer + 1));
      end if;
    end loop;
    if v_cs -> 'conditions' ->> 'text' = 'met'
       and v_cs -> 'conditions' ->> 'foundation' = 'met'
       and v_cs -> 'conditions' ->> 'placement' = 'met'
       and v_marks is not null
       and public.concept_review_first_pass_met(r.cid, v_job.id, r.pos, v_cs, v_marks, v_hold) then
      v_met := v_met + 1;
    end if;
    if v_cat in ('open', 'drafted', 'todo') and jsonb_array_length(v_open) < v_limit then
      v_open := v_open || jsonb_build_array(jsonb_build_object(
        'position', r.pos, 'concept_id', r.cid, 'name', (select name from public.concepts where id = r.cid),
        'category', v_cat, 'item_state', r.item_state, 'next_action', v_next, 'reason', r.reason,
        'action_id', r.action_id, 'draft_version', r.draft_version,
        'conditions', v_cs -> 'conditions', 'todo', v_cs -> 'todo', 'open', v_cs -> 'open'
      ));
    end if;
  end loop;

  if v_job.total = 0 then
    v_pct := null;
    v_line := format('1차 검수 3조건 충족: %s / %s개', v_met, v_job.total);
  else
    v_pct := round((v_met::numeric * 100) / v_job.total, 1);
    v_line := format('1차 검수 3조건 충족: %s / %s개(%s%%)', v_met, v_job.total, to_char(v_pct, 'FM999990.0'));
  end if;

  return jsonb_build_object(
    'job', jsonb_build_object(
      'job_id', v_job.id, 'title', v_job.title, 'status', v_job.status, 'pause_reason', v_job.pause_reason,
      'walk_id', v_job.walk_id, 'walk_created_at', v_walk.created_at, 'total', v_job.total,
      'served_through', v_job.served_through, 'checkpoint', v_job.checkpoint,
      'created_by_me', v_job.created_by = auth.uid(), 'created_at', v_job.created_at, 'updated_at', v_job.updated_at,
      'lease_active', v_job.lease_until > now(), 'auto_run', v_job.auto_run, 'limits', v_job.limits
    ),
    'walk_total', v_total,
    'total_mismatch', v_total <> v_job.total or (v_counts ->> 'missing')::integer > 0,
    'counts', v_counts,
    'conditions', v_cond,
    'progress_line', format('%s개 중 %s개 통합 완료', v_job.total, v_counts ->> 'complete'),
    'condition_line', format('조건별 충족(승인 기준): 표기·의미 %s · 기초 개념 %s · 배치 %s',
                             v_cond ->> 'text', v_cond ->> 'foundation', v_cond ->> 'placement'),
    'open_items', v_open,
    'pending_cards', coalesce((
      select jsonb_agg(jsonb_build_object(
               'action_id', a.id, 'kind', a.kind, 'conversation_id', a.conversation_id, 'conversation_title', c.title,
               'created_at', a.created_at, 'items', jsonb_array_length(coalesce(a.payload -> 'items', '[]'::jsonb)),
               'linked', jc.action_id is not null, 'legacy', coalesce(jc.legacy, false)
             ) order by a.created_at)
        from public.ai_actions a
        left join public.ai_conversations c on c.id = a.conversation_id
        left join public.concept_review_job_cards jc on jc.job_id = v_job.id and jc.action_id = a.id
       where a.status = 'proposed'
         and (jc.action_id is not null or (a.kind = 'concept_review_record' and exists (
           select 1 from jsonb_array_elements(
             case when jsonb_typeof(a.payload -> 'items') = 'array' then a.payload -> 'items' else '[]'::jsonb end
           ) x where public.course_think_uuid(x ->> 'concept_id') = any (v_walk.concept_ids)
         )))
    ), '[]'::jsonb),
    'first_pass', jsonb_build_object('met', v_met, 'total', v_job.total, 'percent', v_pct, 'line', v_line),
    'first_pass_line', v_line
  );
end;
$$;

create or replace function public.concept_review_job_status(p_job_id uuid, p_open_limit integer default 20)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  return public.concept_review_job_status_counts(p_job_id, p_open_limit);
end;
$$;

alter table public.concept_review_jobs add column if not exists status_diag jsonb;

create or replace function public.concept_review_job_status_diag_put(p_job_id uuid, p_diag jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_trace text;
  v_stage text;
  v_code text;
  v_outcome text;
  v_cancel text;
  v_elapsed numeric;
  v_timeout numeric;
  v_clean jsonb;
begin
  perform public.concept_review_assert_operator();
  if not exists (select 1 from public.concept_review_jobs where id = p_job_id) then
    raise exception 'concept_review_job_not_found';
  end if;
  if jsonb_typeof(p_diag) is distinct from 'object' then
    raise exception 'concept_review_status_diag_invalid';
  end if;
  if exists (
    select 1 from jsonb_object_keys(p_diag) k
     where k not in ('trace_id', 'stage', 'elapsed_ms', 'timeout_ms', 'code', 'outcome', 'db_cancel')
  ) then
    raise exception 'concept_review_status_diag_invalid';
  end if;
  v_trace := p_diag ->> 'trace_id';
  v_stage := p_diag ->> 'stage';
  v_code := p_diag ->> 'code';
  v_outcome := p_diag ->> 'outcome';
  v_cancel := p_diag ->> 'db_cancel';
  if v_trace is null or v_trace !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    raise exception 'concept_review_status_diag_invalid';
  end if;
  if v_stage is null or v_stage !~ '^[a-z][a-z0-9_]{0,40}$' then
    raise exception 'concept_review_status_diag_invalid';
  end if;
  if v_code is not null and v_code !~ '^[a-z][a-z0-9_]{0,40}$' then
    raise exception 'concept_review_status_diag_invalid';
  end if;
  if v_outcome is not null and v_outcome not in ('failed', 'unaggregated', 'counted', 'not_run') then
    raise exception 'concept_review_status_diag_invalid';
  end if;
  if v_cancel is not null and v_cancel not in ('requested', 'not_requested') then
    raise exception 'concept_review_status_diag_invalid';
  end if;
  if (p_diag ->> 'elapsed_ms') !~ '^[0-9]+$' then
    raise exception 'concept_review_status_diag_invalid';
  end if;
  v_elapsed := (p_diag ->> 'elapsed_ms')::numeric;
  if v_elapsed > 86400000 then
    raise exception 'concept_review_status_diag_invalid';
  end if;
  if p_diag -> 'timeout_ms' is null or jsonb_typeof(p_diag -> 'timeout_ms') = 'null' then
    v_timeout := null;
  elsif (p_diag ->> 'timeout_ms') !~ '^[0-9]+$' then
    raise exception 'concept_review_status_diag_invalid';
  else
    v_timeout := (p_diag ->> 'timeout_ms')::numeric;
    if v_timeout > 86400000 then
      raise exception 'concept_review_status_diag_invalid';
    end if;
  end if;
  v_clean := jsonb_strip_nulls(jsonb_build_object(
    'trace_id', v_trace,
    'stage', v_stage,
    'elapsed_ms', v_elapsed,
    'timeout_ms', v_timeout,
    'code', v_code,
    'outcome', v_outcome,
    'db_cancel', v_cancel
  ));
  -- timeout_ms null은 구분이 필요해 strip하지 않고 다시 넣는다.
  if v_timeout is null then
    v_clean := v_clean || jsonb_build_object('timeout_ms', null);
  end if;
  update public.concept_review_jobs set status_diag = v_clean where id = p_job_id;
  return jsonb_build_object('saved', true);
end;
$$;

create or replace function public.concept_review_job_status_diag_get(p_job_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_diag jsonb;
begin
  perform public.concept_review_assert_operator();
  select status_diag into v_diag from public.concept_review_jobs where id = p_job_id;
  if not found then
    raise exception 'concept_review_job_not_found';
  end if;
  return jsonb_build_object('diagnosis', v_diag);
end;
$$;

revoke all on function public.concept_review_job_concept_state(uuid, uuid[], jsonb) from public, anon, authenticated;
revoke all on function public.concept_review_first_pass_met(uuid, uuid, integer, jsonb, jsonb, jsonb) from public, anon, authenticated;
revoke all on function public.concept_review_job_status_diag_put(uuid, jsonb) from public, anon;
revoke all on function public.concept_review_job_status_diag_get(uuid) from public, anon;
grant execute on function public.concept_review_job_status_diag_put(uuid, jsonb) to authenticated;
grant execute on function public.concept_review_job_status_diag_get(uuid) to authenticated;

notify pgrst, 'reload schema';
