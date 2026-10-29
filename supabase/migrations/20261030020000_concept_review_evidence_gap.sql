-- 1차 초안 검수의 「1차 충족(근거 미확인)」.
-- 근거: Think 결정 「개념 통합 검수의 3조건·50개 처리·완료 집계 기준」 7번(1be39f66)과
--       「개념 검수 3조건 동시 충족 진행률 추가 표시」(fa26d8b7).
-- 표기·의미·배치 검토가 unverified이고 detail.evidence_gaps(외부 근거: source·grade_unit·figure·etymology)가 있으면
-- 그 범위를 'gap'으로 본다. gap은 1차 검수 3조건 동시 충족에만 충족으로 세고, 통합 완료·조건별 충족(승인 기준)에는 넣지 않는다.
-- 기초 개념(foundation)의 확인 못 함은 후보 비교의 미결이라 gap으로 보지 않는다.
-- 진행 줄은 근거 미확인 포함임과 그중 근거 미확인 수를 함께 적는다.

create or replace function public.concept_review_evidence_gap(p_scope text, p_outcome text, p_detail jsonb)
returns boolean
language sql
immutable
as $$
  select p_outcome = 'unverified'
     and p_scope in ('notation', 'meaning', 'placement')
     and jsonb_typeof(p_detail -> 'evidence_gaps') = 'array'
     and jsonb_array_length(p_detail -> 'evidence_gaps') > 0;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 1) 범위 상태: gap
-- ─────────────────────────────────────────────────────────────────────────

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
    elsif public.concept_review_evidence_gap(r.scope, r.outcome, r.detail) then
      v_st := 'gap';
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
    elsif v_st in ('issue', 'open', 'gap') then
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
                   when n in ('met', 'gap') and m in ('met', 'gap') then 'gap'
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

-- ─────────────────────────────────────────────────────────────────────────
-- 2) 1차 검수 3조건 동시 충족: met 또는 gap. 뒤에 남은 승인 기록으로 gap도 인정한다.
-- ─────────────────────────────────────────────────────────────────────────

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
     or coalesce(p_cs -> 'conditions' ->> 'text', '') not in ('met', 'gap')
     or coalesce(p_cs -> 'conditions' ->> 'foundation', '') not in ('met', 'gap')
     or coalesce(p_cs -> 'conditions' ->> 'placement', '') not in ('met', 'gap') then
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
            and (r.outcome = 'no_issue_found' or public.concept_review_evidence_gap(r.scope, r.outcome, r.detail))
            and r.created_at > a.created_at
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
         and (r.outcome = 'no_issue_found' or public.concept_review_evidence_gap(r.scope, r.outcome, r.detail))
         and r.created_at > v_decided
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
           and (r.outcome = 'no_issue_found' or public.concept_review_evidence_gap(r.scope, r.outcome, r.detail))
           and r.created_at > v_item.updated_at
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

-- ─────────────────────────────────────────────────────────────────────────
-- 3) 진행률 저장: 위치마다 근거 미확인 포함 여부
-- ─────────────────────────────────────────────────────────────────────────

alter table public.concept_review_progress_positions
  add column if not exists first_pass_gap boolean not null default false;
alter table public.concept_review_progress_stage
  add column if not exists first_pass_gap boolean not null default false;

create or replace function public.concept_review_progress_judge(
  p_job_id uuid, p_pos integer, p_pending uuid[]
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_job public.concept_review_jobs;
  v_cid uuid;
  v_state text;
  v_next text;
  v_reason text;
  v_action uuid;
  v_action_items integer[];
  v_draft_version jsonb;
  v_held jsonb;
  v_card_id uuid;
  v_card_status text;
  v_card_error text;
  v_marks jsonb;
  v_cs jsonb;
  v_hold jsonb;
  v_cat text;
  v_met boolean := false;
  v_gap boolean := false;
  v_open jsonb;
begin
  select * into v_job from public.concept_review_jobs where id = p_job_id;
  if not found then
    return null;
  end if;
  select u.cid into v_cid
    from public.concept_review_walks w
    join lateral unnest(w.concept_ids) with ordinality as u(cid, pos) on u.pos = p_pos
   where w.id = v_job.walk_id;
  if v_cid is null then
    return null;
  end if;
  select i.state, i.next_action, i.reason, i.action_id, i.action_items, to_jsonb(i.draft_version), i.held_fixes,
         a.id, a.status, a.error
    into v_state, v_next, v_reason, v_action, v_action_items, v_draft_version, v_held,
         v_card_id, v_card_status, v_card_error
    from (select 1) s
    left join public.concept_review_job_items i on i.job_id = p_job_id and i.pos = p_pos
    left join public.ai_actions a on a.id = i.action_id;
  if exists (select 1 from public.concepts where id = v_cid) then
    v_marks := public.concept_review_marks(v_cid);
  end if;
  v_cs := public.concept_review_job_concept_state(v_cid, coalesce(p_pending, '{}'::uuid[]), v_marks);
  v_hold := case when v_state = 'held' then public.concept_review_job_hold_view(v_held) else null end;
  v_cat := case
    when v_cs ->> 'state' = 'missing' then 'missing'
    when v_state = 'held' and jsonb_array_length(coalesce(v_hold -> 'ready', '[]'::jsonb)) > 0 then 'todo'
    when v_state = 'held' and coalesce((v_hold ->> 'waiting')::boolean, false) then 'awaiting'
    when v_state = 'held' then 'open'
    when v_state = 'submitted' and v_card_status = 'proposed' and coalesce(v_card_error, '') <> '' then 'open'
    when v_cs ->> 'state' = 'complete' then 'complete'
    when v_state = 'drafted' then 'drafted'
    when v_cs ->> 'state' = 'pending' then 'awaiting'
    when v_state in ('deferred', 'failed') then 'open'
    when v_state = 'submitted' and (v_card_id is null or v_card_status = 'rejected'
                                    or public.concept_review_job_item_skipped(v_action, v_action_items)) then 'open'
    when v_cs ->> 'state' = 'open' then 'open'
    when v_state is null then 'not_reviewed'
    else 'todo'
  end;
  if v_state = 'held' then
    v_next := coalesce(v_hold ->> 'next_action', case
      when jsonb_array_length(coalesce(v_hold -> 'ready', '[]'::jsonb)) > 0
        then '의존하던 변경이 반영됐습니다. 다음 검수가 그 범위만 다시 판단합니다.'
      else '의존하는 변경 결과를 확인한 뒤 그 범위만 다시 판단합니다.' end);
  elsif v_state = 'submitted' and v_card_status = 'proposed' and coalesce(v_card_error, '') <> '' then
    v_next := '지난 승인에서 반영하지 못했습니다. 카드는 그대로이니 다시 승인하거나 거절할 수 있습니다.';
  elsif v_cat = 'open' and v_state = 'submitted' and v_cs ->> 'state' <> 'open' then
    v_next := case
      when v_card_id is null then '카드가 없어졌다(대화 삭제 등). 다음 묶음 검수에서 다시 판단한다'
      when v_card_status = 'rejected' then '거절된 카드다. 사용자 의견을 확인하고 고친 초안을 저장한다(같은 내용 재제출 안 함)'
      else '승인 때 뺀 항목이 있다. 사용자 의견을 확인한 뒤 다시 검수한다'
    end;
  elsif v_cat = 'open' and v_state is distinct from 'deferred' and v_state is distinct from 'failed' then
    v_next := '사용자 확인이 필요한 기록: ' || coalesce((
      select string_agg((e ->> 'scope') || ' ' || coalesce(e ->> 'outcome', '') ||
                        case when e ->> 'state' = 'issue' then '(고치기 카드 거절·일부 반영)'
                             when e ->> 'state' = 'gap' then '(근거 미확인, 개별 검토 목록)'
                             else '' end, ', ')
        from jsonb_array_elements(v_cs -> 'open') e
    ), '');
  elsif v_cat in ('todo', 'not_reviewed') then
    v_next := '다음 묶음 검수에서 부족한 범위를 검수한다: ' || coalesce((
      select string_agg(x #>> '{}', ', ') from jsonb_array_elements(v_cs -> 'todo') x
    ), '');
  elsif v_cat = 'awaiting' then
    v_next := '승인 대기 카드(검토·고치기·배치)의 결과를 본다';
  end if;
  if v_marks is not null
     and public.concept_review_first_pass_met(v_cid, p_job_id, p_pos, v_cs, v_marks, v_hold) then
    v_met := true;
    v_gap := 'gap' in (v_cs -> 'conditions' ->> 'text', v_cs -> 'conditions' ->> 'foundation', v_cs -> 'conditions' ->> 'placement');
  end if;
  if v_cat in ('open', 'drafted', 'todo') then
    v_open := jsonb_build_object(
      'position', p_pos, 'concept_id', v_cid,
      'name', (select name from public.concepts where id = v_cid),
      'category', v_cat, 'item_state', v_state, 'next_action', v_next, 'reason', v_reason,
      'action_id', v_action, 'draft_version', v_draft_version,
      'conditions', v_cs -> 'conditions', 'todo', v_cs -> 'todo', 'open', v_cs -> 'open'
    );
  end if;
  return jsonb_build_object(
    'concept_id', v_cid,
    'category', v_cat,
    'cond_text', coalesce(v_cs -> 'conditions' ->> 'text' = 'met', false),
    'cond_foundation', coalesce(v_cs -> 'conditions' ->> 'foundation' = 'met', false),
    'cond_placement', coalesce(v_cs -> 'conditions' ->> 'placement' = 'met', false),
    'first_pass', v_met,
    'first_pass_gap', v_gap,
    'open_payload', v_open
  );
end;
$fn$;

create or replace function public.concept_review_first_pass_line(p_met integer, p_gap integer, p_total integer)
returns text
language sql
immutable
as $$
  select case
    when coalesce(p_total, 0) = 0 then format('1차 검수 3조건 충족(근거 미확인 포함): %s / %s개 · 그중 근거 미확인 %s개', p_met, p_total, p_gap)
    else format('1차 검수 3조건 충족(근거 미확인 포함): %s / %s개(%s%%) · 그중 근거 미확인 %s개',
                p_met, p_total, to_char(round((p_met::numeric * 100) / p_total, 1), 'FM999990.0'), p_gap)
  end;
$$;

create or replace function public.concept_review_progress_finish(p_job_id uuid, p_run_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_prog public.concept_review_progress_jobs;
  v_run public.concept_review_progress_runs;
  v_job public.concept_review_jobs;
  v_walk_n integer;
  v_complete integer;
  v_awaiting integer;
  v_drafted integer;
  v_open integer;
  v_todo integer;
  v_not integer;
  v_missing integer;
  v_text integer;
  v_found integer;
  v_place integer;
  v_met integer;
  v_gap integer;
  v_pct numeric;
  v_line text;
  v_counts jsonb;
  v_cond jsonb;
  v_fp jsonb;
  v_mismatch boolean;
  v_snap jsonb;
begin
  select * into v_prog from public.concept_review_progress_jobs where job_id = p_job_id for update;
  select * into v_run from public.concept_review_progress_runs where id = p_run_id;
  select * into v_job from public.concept_review_jobs where id = p_job_id;
  if v_prog.input_version is distinct from v_run.input_version
     or v_prog.active_run_id is distinct from p_run_id
     or v_run.state <> 'running' then
    update public.concept_review_progress_runs
       set state = 'superseded', finished_at = now()
     where id = p_run_id and state = 'running';
    update public.concept_review_progress_jobs
       set active_run_id = null
     where job_id = p_job_id and active_run_id = p_run_id;
    delete from public.concept_review_progress_stage where run_id = p_run_id;
    return false;
  end if;
  select coalesce(cardinality(w.concept_ids), 0) into v_walk_n
    from public.concept_review_walks w where w.id = v_job.walk_id;

  if v_run.kind = 'rebuild' then
    if (select count(*) from public.concept_review_progress_stage where run_id = p_run_id) <> v_walk_n
       or exists (
         select 1 from generate_series(1, v_walk_n) s(pos)
          where not exists (
            select 1 from public.concept_review_progress_stage g
             where g.run_id = p_run_id and g.pos = s.pos
          )
       ) then
      return false;
    end if;
    delete from public.concept_review_progress_positions where job_id = p_job_id;
    insert into public.concept_review_progress_positions (
      job_id, pos, concept_id, category, cond_text, cond_foundation, cond_placement, first_pass, first_pass_gap, open_payload,
      dirty_token, published_token
    )
    select p_job_id, pos, concept_id, category, cond_text, cond_foundation, cond_placement, first_pass, first_pass_gap, open_payload, 0, 0
      from public.concept_review_progress_stage where run_id = p_run_id;
    perform public.concept_review_progress_refresh_deps(p_job_id, null);
  elsif exists (
    select 1 from public.concept_review_progress_positions
     where job_id = p_job_id and dirty_token > published_token
  ) or v_prog.needs_rebuild
     or (select count(*) from public.concept_review_progress_positions where job_id = p_job_id) <> v_walk_n then
    return false;
  end if;

  select
    count(*) filter (where category = 'complete'),
    count(*) filter (where category = 'awaiting'),
    count(*) filter (where category = 'drafted'),
    count(*) filter (where category = 'open'),
    count(*) filter (where category = 'todo'),
    count(*) filter (where category = 'not_reviewed'),
    count(*) filter (where category = 'missing'),
    count(*) filter (where cond_text),
    count(*) filter (where cond_foundation),
    count(*) filter (where cond_placement),
    count(*) filter (where first_pass),
    count(*) filter (where first_pass and first_pass_gap)
    into v_complete, v_awaiting, v_drafted, v_open, v_todo, v_not, v_missing, v_text, v_found, v_place, v_met, v_gap
    from public.concept_review_progress_positions
   where job_id = p_job_id;

  v_counts := jsonb_build_object(
    'complete', v_complete, 'awaiting', v_awaiting, 'drafted', v_drafted, 'open', v_open,
    'todo', v_todo, 'not_reviewed', v_not, 'missing', v_missing
  );
  v_cond := jsonb_build_object('text', v_text, 'foundation', v_found, 'placement', v_place);
  v_pct := case when v_job.total = 0 then null else round((v_met::numeric * 100) / v_job.total, 1) end;
  v_line := public.concept_review_first_pass_line(v_met, v_gap, v_job.total);
  v_fp := jsonb_build_object(
    'met', v_met, 'evidence_gap', v_gap, 'total', v_job.total, 'percent', v_pct, 'line', v_line,
    'includes_evidence_gap', true
  );
  v_mismatch := v_walk_n <> v_job.total or v_missing > 0;
  v_snap := jsonb_build_object(
    'at', now(), 'input_version', v_prog.input_version, 'counts', v_counts, 'conditions', v_cond,
    'first_pass', v_fp,
    'progress_line', format('%s개 중 %s개 통합 완료', v_job.total, v_complete),
    'condition_line', format('조건별 충족(승인 기준): 표기·의미 %s · 기초 개념 %s · 배치 %s', v_text, v_found, v_place),
    'first_pass_line', v_line, 'total_mismatch', v_mismatch
  );
  update public.concept_review_progress_jobs
     set published_input_version = input_version,
         needs_rebuild = false,
         active_run_id = null,
         counts = v_counts,
         conditions = v_cond,
         first_pass = v_fp,
         progress_line = v_snap ->> 'progress_line',
         condition_line = v_snap ->> 'condition_line',
         first_pass_line = v_line,
         total_mismatch = v_mismatch,
         last_success = v_snap,
         last_success_at = now(),
         progress_error = null,
         updated_at = now()
   where job_id = p_job_id;
  update public.concept_review_progress_runs
     set state = 'published', finished_at = now(), updated_at = now(), error = null
   where id = p_run_id;
  delete from public.concept_review_progress_stage where run_id = p_run_id;
  delete from public.concept_review_progress_queue where job_id = p_job_id;
  return true;
end;
$fn$;

-- 진행률 구간 계산: 근거 미확인 포함 여부를 함께 저장한다.
create or replace function public.concept_review_progress_step(p_job_id uuid default null, p_limit integer default 20)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_job uuid := p_job_id;
  v_limit integer := least(greatest(coalesce(p_limit, 20), 1), 200);
  v_prog public.concept_review_progress_jobs;
  v_run public.concept_review_progress_runs;
  v_walk uuid[];
  v_walk_n integer;
  v_pos_n integer;
  v_dirty boolean;
  v_pending uuid[];
  v_row jsonb;
  v_token bigint;
  v_pos integer;
  v_cid uuid;
  v_processed integer := 0;
  v_next integer;
  v_err text;
  v_attempts integer;
begin
  perform public.concept_review_progress_assert_runner();
  if v_job is null then
    select q.job_id into v_job
      from public.concept_review_progress_queue q
     where q.attempts < 5
       and (q.next_attempt_at is null or q.next_attempt_at <= now())
     order by q.enqueued_at
     limit 1;
    if v_job is null then
      return jsonb_build_object('outcome', 'idle', 'more', false, 'processed', 0);
    end if;
  end if;
  if not exists (select 1 from public.concept_review_jobs where id = v_job) then
    raise exception 'concept_review_job_not_found';
  end if;
  if not pg_try_advisory_xact_lock(hashtext('concept_review_progress'), hashtext(v_job::text)) then
    return jsonb_build_object('outcome', 'already_running', 'more', false, 'job_id', v_job, 'processed', 0);
  end if;

  begin
    select * into v_run from public.concept_review_progress_runs where false;
    insert into public.concept_review_progress_jobs (job_id, input_version)
    values (v_job, 0)
    on conflict (job_id) do nothing;
    select * into v_prog from public.concept_review_progress_jobs where job_id = v_job;
    select w.concept_ids, coalesce(cardinality(w.concept_ids), 0)
      into v_walk, v_walk_n
      from public.concept_review_jobs j
      join public.concept_review_walks w on w.id = j.walk_id
     where j.id = v_job;
    select count(*) into v_pos_n from public.concept_review_progress_positions where job_id = v_job;
    v_dirty := exists (
      select 1 from public.concept_review_progress_positions
       where job_id = v_job and dirty_token > published_token
    );

    select * into v_run from public.concept_review_progress_runs where false;
    if v_prog.active_run_id is not null then
      select * into v_run from public.concept_review_progress_runs where id = v_prog.active_run_id;
    end if;
    if v_run.id is not null and v_run.state = 'running'
       and (v_run.input_version is distinct from v_prog.input_version
            or (v_run.kind <> 'rebuild' and v_prog.needs_rebuild)) then
      update public.concept_review_progress_runs
         set state = 'superseded', finished_at = now()
       where id = v_run.id;
      delete from public.concept_review_progress_stage where run_id = v_run.id;
      update public.concept_review_progress_jobs set active_run_id = null where job_id = v_job;
      select * into v_run from public.concept_review_progress_runs where false;
    end if;
    if v_run.id is not null and v_run.state = 'failed' and v_run.attempts >= 5
       and v_run.input_version = v_prog.input_version then
      return jsonb_build_object(
        'outcome', 'failed', 'more', false, 'job_id', v_job, 'processed', 0,
        'error', coalesce(v_run.error, 'progress_step_failed'), 'freshness', 'failed'
      );
    end if;
    if v_run.id is not null and v_run.state = 'running' and v_run.attempts > 0
       and v_run.next_attempt_at > now() and v_run.input_version = v_prog.input_version then
      return jsonb_build_object(
        'outcome', 'failed', 'more', false, 'job_id', v_job, 'processed', 0,
        'error', coalesce(v_run.error, 'progress_step_failed')
      );
    end if;

    if v_run.id is null or v_run.state <> 'running' then
      if v_prog.needs_rebuild or v_pos_n <> v_walk_n then
        insert into public.concept_review_progress_runs (job_id, kind, input_version, state, cursor_pos)
        values (v_job, 'rebuild', v_prog.input_version, 'running', 1)
        returning * into v_run;
      elsif v_dirty then
        insert into public.concept_review_progress_runs (job_id, kind, input_version, state, cursor_pos)
        values (v_job, 'partial', v_prog.input_version, 'running', 1)
        returning * into v_run;
      elsif v_prog.published_input_version is distinct from v_prog.input_version then
        insert into public.concept_review_progress_runs (job_id, kind, input_version, state, cursor_pos)
        values (v_job, 'resummarize', v_prog.input_version, 'running', 1)
        returning * into v_run;
      else
        delete from public.concept_review_progress_queue where job_id = v_job;
        return jsonb_build_object('outcome', 'idle', 'more', false, 'job_id', v_job, 'processed', 0, 'freshness', 'current');
      end if;
      update public.concept_review_progress_jobs set active_run_id = v_run.id, updated_at = now() where job_id = v_job;
    end if;

    if v_run.kind = 'resummarize' then
      if public.concept_review_progress_finish(v_job, v_run.id) then
        return jsonb_build_object('outcome', 'published', 'more', false, 'job_id', v_job, 'processed', 0, 'freshness', 'current');
      end if;
      return jsonb_build_object('outcome', 'superseded', 'more', true, 'job_id', v_job, 'processed', 0);
    end if;

    v_pending := public.concept_review_pending_concepts();
    if v_run.kind = 'rebuild' then
      for v_pos, v_cid in
        select u.pos::integer, u.cid
          from unnest(v_walk) with ordinality as u(cid, pos)
         where u.pos >= v_run.cursor_pos
         order by u.pos
         limit v_limit
      loop
        v_row := public.concept_review_progress_judge(v_job, v_pos, v_pending);
        insert into public.concept_review_progress_stage (
          run_id, pos, concept_id, category, cond_text, cond_foundation, cond_placement, first_pass, first_pass_gap, open_payload
        ) values (
          v_run.id, v_pos, (v_row ->> 'concept_id')::uuid, v_row ->> 'category',
          coalesce((v_row ->> 'cond_text')::boolean, false),
          coalesce((v_row ->> 'cond_foundation')::boolean, false),
          coalesce((v_row ->> 'cond_placement')::boolean, false),
          coalesce((v_row ->> 'first_pass')::boolean, false),
          coalesce((v_row ->> 'first_pass_gap')::boolean, false),
          v_row -> 'open_payload'
        )
        on conflict (run_id, pos) do update
          set concept_id = excluded.concept_id, category = excluded.category,
              cond_text = excluded.cond_text, cond_foundation = excluded.cond_foundation,
              cond_placement = excluded.cond_placement, first_pass = excluded.first_pass, first_pass_gap = excluded.first_pass_gap,
              open_payload = excluded.open_payload;
        v_processed := v_processed + 1;
        v_next := v_pos + 1;
      end loop;
      if v_processed = 0 and v_run.cursor_pos <= v_walk_n then
        raise exception 'progress_cursor_stuck';
      end if;
      update public.concept_review_progress_runs
         set cursor_pos = coalesce(v_next, v_run.cursor_pos), updated_at = now(), attempts = 0, next_attempt_at = null, error = null
       where id = v_run.id;
      if coalesce(v_next, v_run.cursor_pos) > v_walk_n or v_walk_n = 0 then
        if public.concept_review_progress_finish(v_job, v_run.id) then
          return jsonb_build_object('outcome', 'published', 'more', false, 'job_id', v_job, 'processed', v_processed, 'freshness', 'current');
        end if;
        return jsonb_build_object('outcome', 'superseded', 'more', true, 'job_id', v_job, 'processed', v_processed);
      end if;
      return jsonb_build_object('outcome', 'chunk', 'more', true, 'job_id', v_job, 'processed', v_processed, 'cursor', v_next, 'freshness', 'refreshing');
    end if;

    for v_pos, v_token in
      select p.pos, p.dirty_token
        from public.concept_review_progress_positions p
       where p.job_id = v_job and p.dirty_token > p.published_token
       order by p.pos
       limit v_limit
    loop
      v_row := public.concept_review_progress_judge(v_job, v_pos, v_pending);
      update public.concept_review_progress_positions
         set concept_id = (v_row ->> 'concept_id')::uuid,
             category = v_row ->> 'category',
             cond_text = coalesce((v_row ->> 'cond_text')::boolean, false),
             cond_foundation = coalesce((v_row ->> 'cond_foundation')::boolean, false),
             cond_placement = coalesce((v_row ->> 'cond_placement')::boolean, false),
             first_pass = coalesce((v_row ->> 'first_pass')::boolean, false),
             first_pass_gap = coalesce((v_row ->> 'first_pass_gap')::boolean, false),
             open_payload = v_row -> 'open_payload',
             published_token = v_token
       where job_id = v_job and pos = v_pos and dirty_token = v_token;
      if found then
        perform public.concept_review_progress_refresh_deps(v_job, v_pos);
        v_processed := v_processed + 1;
      end if;
    end loop;
    update public.concept_review_progress_runs
       set updated_at = now(), attempts = 0, next_attempt_at = null, error = null
     where id = v_run.id;
    if public.concept_review_progress_finish(v_job, v_run.id) then
      return jsonb_build_object('outcome', 'published', 'more', false, 'job_id', v_job, 'processed', v_processed, 'freshness', 'current');
    end if;
    if exists (
      select 1 from public.concept_review_progress_runs r
       where r.id = v_run.id and r.state = 'running'
    ) and exists (
      select 1 from public.concept_review_progress_positions
       where job_id = v_job and dirty_token > published_token
    ) then
      return jsonb_build_object('outcome', 'chunk', 'more', true, 'job_id', v_job, 'processed', v_processed, 'freshness', 'refreshing');
    end if;
    return jsonb_build_object('outcome', 'superseded', 'more', true, 'job_id', v_job, 'processed', v_processed);
  exception
    when others then
      if sqlerrm in ('concept_review_forbidden', 'concept_review_job_not_found') then
        raise;
      end if;
      v_err := case when sqlerrm ~ '^[a-z][a-z0-9_]{0,80}$' then sqlerrm else 'progress_step_failed' end;
      v_attempts := coalesce(v_run.attempts, 0) + 1;
      if v_run.id is not null then
        update public.concept_review_progress_runs
           set attempts = v_attempts,
               error = v_err,
               next_attempt_at = now() + make_interval(mins => v_attempts),
               state = case when v_attempts >= 5 then 'failed' else 'running' end,
               updated_at = now(),
               finished_at = case when v_attempts >= 5 then now() else null end
         where id = v_run.id;
        update public.concept_review_progress_jobs
           set progress_error = v_err, updated_at = now()
         where job_id = v_job;
        update public.concept_review_progress_queue
           set attempts = v_attempts, next_attempt_at = now() + make_interval(mins => v_attempts), last_error = v_err
         where job_id = v_job;
      end if;
      return jsonb_build_object(
        'outcome', 'failed', 'more', false, 'job_id', v_job, 'processed', v_processed,
        'error', v_err, 'sqlstate', sqlstate, 'attempts', v_attempts
      );
  end;
end;
$fn$;

-- 바로 세기(작업 상태 live): 같은 기준.
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
  v_gap integer := 0;
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
                          case when e ->> 'state' = 'issue' then '(고치기 카드 거절·일부 반영)'
                               when e ->> 'state' = 'gap' then '(근거 미확인, 개별 검토 목록)'
                               else '' end, ', ')
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
    if v_marks is not null
       and public.concept_review_first_pass_met(r.cid, v_job.id, r.pos, v_cs, v_marks, v_hold) then
      v_met := v_met + 1;
      if 'gap' in (v_cs -> 'conditions' ->> 'text', v_cs -> 'conditions' ->> 'foundation', v_cs -> 'conditions' ->> 'placement') then
        v_gap := v_gap + 1;
      end if;
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

  v_pct := case when v_job.total = 0 then null else round((v_met::numeric * 100) / v_job.total, 1) end;
  v_line := public.concept_review_first_pass_line(v_met, v_gap, v_job.total);

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
    'first_pass', jsonb_build_object(
      'met', v_met, 'evidence_gap', v_gap, 'total', v_job.total, 'percent', v_pct, 'line', v_line,
      'includes_evidence_gap', true
    ),
    'first_pass_line', v_line
  );
end;
$$;


-- ─────────────────────────────────────────────────────────────────────────
-- 4) 이미 있는 작업은 다시 집계한다(판단·카드는 바꾸지 않는다).
-- ─────────────────────────────────────────────────────────────────────────

update public.concept_review_progress_jobs set needs_rebuild = true, updated_at = now();
select public.concept_review_progress_bump(coalesce(array_agg(job_id), '{}'::uuid[])) from public.concept_review_progress_jobs;

revoke all on function public.concept_review_evidence_gap(text, text, jsonb) from public, anon, authenticated;
revoke all on function public.concept_review_first_pass_line(integer, integer, integer) from public, anon, authenticated;

notify pgrst, 'reload schema';