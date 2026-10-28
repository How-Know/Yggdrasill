-- 20261027010000: 수정에 의존하는 검토는 초안으로 보류하고, 반영 뒤 그 범위만 다시 판단한다.
-- 검토 카드의 전체 실패는 내용을 되돌린 뒤에도 카드에 남긴다(proposed 유지).
-- 이미 운영에 반영된 20261026140000 은 고치지 않는다.

-- ─────────────────────────────────────────────────────────────────────────
-- 1) 위치별 보류·범위별 카드 연결
-- ─────────────────────────────────────────────────────────────────────────

alter table public.concept_review_job_items
  add column if not exists held_fixes jsonb not null default '[]'::jsonb,
  add column if not exists scope_cards jsonb not null default '{}'::jsonb;

alter table public.concept_review_job_items drop constraint if exists concept_review_job_items_state_check;
alter table public.concept_review_job_items add constraint concept_review_job_items_state_check
  check (state in ('drafted', 'deferred', 'failed', 'submitted', 'reused', 'waiting', 'missing', 'held'));

alter table public.concept_review_job_items drop constraint if exists concept_review_job_items_held_fixes_check;
alter table public.concept_review_job_items add constraint concept_review_job_items_held_fixes_check
  check (jsonb_typeof(held_fixes) = 'array' and octet_length(held_fixes::text) <= 20000);

alter table public.concept_review_job_items drop constraint if exists concept_review_job_items_scope_cards_check;
alter table public.concept_review_job_items add constraint concept_review_job_items_scope_cards_check
  check (jsonb_typeof(scope_cards) = 'object' and octet_length(scope_cards::text) <= 8000);

comment on column public.concept_review_job_items.held_fixes is
  '제출을 보류한 검토 범위. 범위, 의존 변경 카드 id·항목 번호, 대상, 판단 당시 판.';
comment on column public.concept_review_job_items.scope_cards is
  '이미 검토 카드로 낸 범위. 범위 → {action_id, item}. 나중 제출이 앞 연결을 지우지 않는다.';

-- 비교 근거로 실제로 쓴 개념의 글이 바뀌면 그 범위만 낡다. 관계망 전체는 다시 보지 않는다.
create or replace function public.concept_review_record_stale(r public.concept_quality_reviews, p_marks jsonb)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select r.mark is distinct from (p_marks ->> public.concept_review_scope_mark(r.scope))
      or exists (
        select 1 from jsonb_array_elements(coalesce(r.compared, '[]'::jsonb)) e
         where e ? 'text'
           and public.concept_review_text_mark(public.course_think_uuid(e ->> 'id')) is distinct from e ->> 'text'
      )
      or (r.scope = 'foundation' and exists (
            select 1 from jsonb_array_elements(coalesce(r.compared, '[]'::jsonb)) e
             where not exists (select 1 from public.concepts c where c.id = public.course_think_uuid(e ->> 'id'))
          ));
$$;

-- none · proposed · applied · failed(판·비교 근거가 바뀌어 다시 판단할 반영 실패) · rejected(거절·생략·그 밖 실패).
create or replace function public.concept_review_fix_state(p_fixes jsonb)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_f jsonb;
  v_a public.ai_actions;
  v_all boolean := true;
  v_retry boolean := false;
  v_user boolean := false;
begin
  if p_fixes is null or jsonb_typeof(p_fixes) <> 'array' or jsonb_array_length(p_fixes) = 0 then
    return 'none';
  end if;
  for v_f in select e from jsonb_array_elements(p_fixes) e loop
    select * into v_a from public.ai_actions where id = public.course_think_uuid(v_f ->> 'action_id');
    if not found or v_a.status <> 'applied' then
      if found and v_a.status = 'proposed' then
        return 'proposed';
      end if;
      v_user := true;
      v_all := false;
    else
      if exists (
        select 1 from jsonb_array_elements(coalesce(v_a.result -> 'items', '[]'::jsonb)) e
         where (e ->> 'i')::integer in (select (x #>> '{}')::integer from jsonb_array_elements(coalesce(v_f -> 'items', '[]'::jsonb)) x)
           and e ->> 'status' = 'skipped'
      ) then
        v_user := true;
        v_all := false;
      end if;
      if exists (
        select 1 from jsonb_array_elements(coalesce(v_a.result -> 'items', '[]'::jsonb)) e
         where (e ->> 'i')::integer in (select (x #>> '{}')::integer from jsonb_array_elements(coalesce(v_f -> 'items', '[]'::jsonb)) x)
           and e ->> 'status' = 'failed'
           and coalesce(e ->> 'code', '') ~ '^(concept_review_stale|concept_review_compared_changed)'
      ) then
        v_retry := true;
        v_all := false;
      end if;
      if exists (
        select 1 from jsonb_array_elements(coalesce(v_a.result -> 'items', '[]'::jsonb)) e
         where (e ->> 'i')::integer in (select (x #>> '{}')::integer from jsonb_array_elements(coalesce(v_f -> 'items', '[]'::jsonb)) x)
           and e ->> 'status' <> 'applied'
           and e ->> 'status' is distinct from 'skipped'
           and not (e ->> 'status' = 'failed' and coalesce(e ->> 'code', '') ~ '^(concept_review_stale|concept_review_compared_changed)')
      ) then
        v_user := true;
        v_all := false;
      end if;
    end if;
  end loop;
  if v_all then
    return 'applied';
  end if;
  if v_retry and not v_user then
    return 'failed';
  end if;
  return 'rejected';
end;
$$;

create or replace function public.concept_review_job_concept_state(p_concept_id uuid, p_pending uuid[])
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
  v_marks := public.concept_review_marks(p_concept_id);
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

-- 사용자가 승인 때 뺀 항목만 생략이다. 반영 실패(failed)는 생략이 아니다.
create or replace function public.concept_review_job_item_skipped(p_action_id uuid, p_items integer[])
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.ai_actions a
     cross join lateral jsonb_array_elements(coalesce(a.result -> 'items', '[]'::jsonb)) e
     where a.id = p_action_id and a.status = 'applied'
       and (e ->> 'i')::integer = any (coalesce(p_items, '{}'::integer[])) and e ->> 'status' = 'skipped'
  );
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 2) 어떤 범위를 보류하는가
-- ─────────────────────────────────────────────────────────────────────────

-- 고르고 있는 초안에서, 자기 변경이 있거나 이번 제출의 변경이 그 범위의 판·비교 근거를 바꾸는 범위.
-- 검토 카드끼리는 기다리지 않고, 아직 판단하지 않은 나중 묶음은 보지 않는다.
create or replace function public.concept_review_job_hold_scopes(p_sel jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_e jsonb;
  v_r jsonb;
  o jsonb;
  v_effects jsonb := '[]'::jsonb;
  v_out jsonb := '{}'::jsonb;
  v_hold jsonb;
  v_concept uuid;
  v_target uuid;
  v_key text;
begin
  for v_e in select x from jsonb_array_elements(coalesce(p_sel, '[]'::jsonb)) x loop
    v_concept := public.course_think_uuid(v_e ->> 'concept_id');
    for v_r in select x from jsonb_array_elements(coalesce(v_e -> 'reviews', '[]'::jsonb)) x loop
      continue when jsonb_typeof(v_r -> 'fix') is distinct from 'object';
      for o in select x from jsonb_array_elements(coalesce(v_r -> 'fix' -> 'ops', '[]'::jsonb)) x loop
        if o ->> 'op' = 'edit' then
          v_target := coalesce(public.course_think_uuid(o ->> 'concept_id'), v_concept);
          if o ?| array['name', 'content'] then
            v_effects := v_effects || jsonb_build_array(jsonb_build_object('concept_id', v_target, 'mark_key', 'text'));
          end if;
          if o ?| array['type', 'folder'] then
            v_effects := v_effects || jsonb_build_array(jsonb_build_object('concept_id', v_target, 'mark_key', 'class'));
          end if;
        elsif o ->> 'op' = 'place' then
          v_effects := v_effects || jsonb_build_array(jsonb_build_object(
            'concept_id', coalesce(public.course_think_uuid(o ->> 'concept_id'), v_concept), 'mark_key', 'placement'));
        elsif o ->> 'op' in ('move', 'remove') then
          select a.concept_id into v_target from public.concept_appearances a where a.id = public.course_think_uuid(o ->> 'placement_id');
          if v_target is not null then
            v_effects := v_effects || jsonb_build_array(jsonb_build_object('concept_id', v_target, 'mark_key', 'placement'));
          end if;
        end if;
      end loop;
    end loop;
  end loop;

  for v_e in select x from jsonb_array_elements(coalesce(p_sel, '[]'::jsonb)) x loop
    v_concept := public.course_think_uuid(v_e ->> 'concept_id');
    v_hold := '[]'::jsonb;
    for v_r in select x from jsonb_array_elements(coalesce(v_e -> 'reviews', '[]'::jsonb)) x loop
      v_key := public.concept_review_scope_mark(v_r ->> 'scope');
      if jsonb_typeof(v_r -> 'fix') = 'object'
         or exists (
           select 1 from jsonb_array_elements(v_effects) ef
            where ef ->> 'concept_id' = v_concept::text and ef ->> 'mark_key' = v_key
         )
         or exists (
           select 1 from jsonb_array_elements(v_effects) ef
            where ef ->> 'mark_key' = 'text' and coalesce(v_r -> 'compared_text', '{}'::jsonb) ? (ef ->> 'concept_id')
         ) then
        v_hold := v_hold || jsonb_build_array(v_r ->> 'scope');
      end if;
    end loop;
    v_out := v_out || jsonb_build_object(v_e ->> 'pos', v_hold);
  end loop;
  return v_out;
end;
$$;

-- 의존 카드의 항목별 결과. 카드 전체가 applied여도 그 항목이 실패·생략이면 성공이 아니다.
create or replace function public.concept_review_job_hold_view(p_fixes jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_s jsonb;
  v_d jsonb;
  v_a public.ai_actions;
  v_item jsonb;
  v_st text;
  v_changed boolean;
  v_cid uuid;
  v_deps jsonb;
  v_scopes jsonb := '[]'::jsonb;
  v_ready jsonb := '[]'::jsonb;
  v_pending boolean := false;
  v_failed boolean := false;
  v_rejected boolean := false;
  v_skipped boolean := false;
  v_unclear boolean := false;
  v_code text;
  v_next text;
begin
  for v_s in select x from jsonb_array_elements(coalesce(p_fixes, '[]'::jsonb)) x loop
    v_deps := '[]'::jsonb;
    v_pending := false;
    v_failed := false;
    v_rejected := false;
    v_skipped := false;
    v_unclear := false;
    for v_d in select x from jsonb_array_elements(coalesce(v_s -> 'deps', '[]'::jsonb)) x loop
      v_st := 'unclear';
      v_changed := false;
      v_cid := null;
      v_item := null;
      select * into v_a from public.ai_actions where id = public.course_think_uuid(v_d ->> 'action_id');
      if not found then
        v_st := 'unclear';
      else
        select e into v_item from jsonb_array_elements(coalesce(v_a.result -> 'items', '[]'::jsonb)) e
         where (e ->> 'i')::integer = coalesce((v_d ->> 'item')::integer, -1) limit 1;
        if v_a.status = 'rejected' then
          v_st := 'rejected';
        elsif v_a.status = 'proposed' then
          if coalesce((v_a.result ->> 'attempt_failed')::boolean, false) and v_item ->> 'status' = 'failed' then
            v_st := 'failed';
          elsif coalesce((v_a.result ->> 'attempt_failed')::boolean, false) and v_item ->> 'status' = 'skipped' then
            v_st := 'skipped';
          else
            v_st := 'pending';
          end if;
        elsif v_a.status = 'applied' then
          v_st := case coalesce(v_item ->> 'status', '')
            when 'applied' then 'applied' when 'skipped' then 'skipped' when 'failed' then 'failed' else 'unclear' end;
          if v_st = 'applied' then
            v_cid := public.course_think_uuid(v_item ->> 'concept_id');
          end if;
        else
          v_st := 'unclear';
        end if;
        if v_st = 'applied' and nullif(v_d ->> 'mark_key', '') is not null and public.course_think_uuid(v_d ->> 'target_concept_id') is not null then
          v_changed := public.concept_review_marks(public.course_think_uuid(v_d ->> 'target_concept_id')) ->> (v_d ->> 'mark_key')
                       is distinct from v_d ->> 'mark';
        end if;
      end if;
      if v_st = 'pending' then v_pending := true;
      elsif v_st = 'failed' then v_failed := true;
      elsif v_st = 'rejected' then v_rejected := true;
      elsif v_st = 'skipped' then v_skipped := true;
      elsif v_st <> 'applied' then v_unclear := true;
      end if;
      v_deps := v_deps || jsonb_build_array(v_d || jsonb_build_object(
        'status', v_st, 'changed', v_changed, 'created_concept_id', v_cid, 'code', v_item ->> 'code'));
    end loop;
    if jsonb_array_length(coalesce(v_s -> 'deps', '[]'::jsonb)) = 0 then
      v_unclear := true;
    end if;
    v_code := case
      when v_pending then 'pending'
      when v_failed then 'failed'
      when v_rejected then 'rejected'
      when v_skipped then 'skipped'
      when v_unclear then 'unclear'
      else 'applied' end;
    v_scopes := v_scopes || jsonb_build_array(jsonb_build_object('scope', v_s ->> 'scope', 'status', v_code, 'deps', v_deps));
    if v_code = 'applied' then
      v_ready := v_ready || jsonb_build_array(v_s ->> 'scope');
    end if;
  end loop;

  v_pending := exists (select 1 from jsonb_array_elements(v_scopes) s where s ->> 'status' = 'pending');
  v_failed := exists (select 1 from jsonb_array_elements(v_scopes) s where s ->> 'status' = 'failed');
  v_code := case
    when v_pending and v_failed then 'pending_failed'
    when v_pending then 'pending'
    when v_failed then 'failed'
    when exists (select 1 from jsonb_array_elements(v_scopes) s where s ->> 'status' = 'rejected') then 'rejected'
    when exists (select 1 from jsonb_array_elements(v_scopes) s where s ->> 'status' = 'skipped') then 'skipped'
    when exists (select 1 from jsonb_array_elements(v_scopes) s where s ->> 'status' = 'unclear') then 'unclear'
    else null end;
  v_next := case v_code
    when 'pending_failed' then '변경 카드 일부는 승인 대기이고 일부는 반영에 실패했습니다. 실패한 범위는 성공으로 보지 않습니다.'
    when 'pending' then '의존하는 변경 카드가 승인 대기입니다. 반영되면 다음 검수가 그 범위만 다시 판단합니다.'
    when 'failed' then '의존하는 변경 항목이 반영되지 않았습니다. 성공으로 보지 않으며 같은 실패를 반복 제안하지 않습니다.'
    when 'rejected' then '의존하는 변경 카드가 거절되었습니다. 같은 변경을 다시 제안하지 않습니다. 사용자 확인 뒤 다시 검수합니다.'
    when 'skipped' then '의존하는 변경 항목을 승인할 때 뺐습니다. 같은 변경을 다시 제안하지 않습니다.'
    when 'unclear' then '의존하는 변경 결과를 확인하지 못했습니다. 성공으로 보지 않습니다.'
    else null end;
  return jsonb_build_object(
    'scopes', v_scopes, 'ready', v_ready, 'waiting', v_pending, 'code', v_code, 'next_action', v_next
  );
end;
$$;

-- 지금 다시 판단할 범위. 보류가 풀린 범위, 반영은 됐으나 판·비교 근거가 바뀌어 실패한 범위,
-- 보류 때문에 아직 내지 않은 다른 범위. 기다리는 범위는 넣지 않는다.
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
  v_view := public.concept_review_job_hold_view(v_it.held_fixes);
  for v_s in select x from jsonb_array_elements(coalesce(v_view -> 'scopes', '[]'::jsonb)) x loop
    v_blocked := v_blocked || (v_s ->> 'scope');
    if v_s ->> 'status' = 'applied' and not ((v_s ->> 'scope') = any (v_scopes)) then
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
      ) and not (v_scope = any (v_scopes)) and not exists (
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
      if not (v_scope = any (v_blocked)) and not (v_scope = any (v_scopes)) then
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
create or replace function public.concept_review_job_deps(p_sel jsonb, p_plan jsonb, p_ids jsonb, p_holds jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_e jsonb;
  v_r jsonb;
  v_k integer;
  v_pos integer;
  v_ref text;
  v_card text;
  v_item integer;
  v_op_i integer;
  o jsonb;
  v_action uuid;
  v_kind text;
  v_mark_key text;
  v_target uuid;
  v_mark text;
  v_dep jsonb;
  v_own jsonb;
  v_owns jsonb := '{}'::jsonb;
  v_effects jsonb := '[]'::jsonb;
  v_deps jsonb;
  v_list jsonb;
  v_out jsonb := '{}'::jsonb;
  v_concept uuid;
  v_ef jsonb;
begin
  for v_e in select x from jsonb_array_elements(coalesce(p_sel, '[]'::jsonb)) x loop
    v_pos := (v_e ->> 'pos')::integer;
    v_concept := public.course_think_uuid(v_e ->> 'concept_id');
    for v_r, v_k in select x, n::integer from jsonb_array_elements(coalesce(v_e -> 'reviews', '[]'::jsonb)) with ordinality t(x, n) loop
      v_ref := v_pos || ':' || v_k;
      v_own := '[]'::jsonb;
      v_op_i := 0;
      for v_card in select k from jsonb_object_keys(coalesce(p_plan -> 'refs' -> v_ref, '{}'::jsonb)) k loop
        for v_item in
          select (x #>> '{}')::integer from jsonb_array_elements(coalesce(p_plan -> 'refs' -> v_ref -> v_card, '[]'::jsonb)) x
        loop
          o := coalesce(v_r -> 'fix' -> 'ops' -> v_op_i, '{}'::jsonb);
          v_op_i := v_op_i + 1;
          v_action := case when v_card like 'ext:%' then substr(v_card, 5)::uuid else public.course_think_uuid(p_ids ->> v_card) end;
          v_kind := case when v_card = 'lib' or v_card like 'ext:%' then 'library' else 'placement' end;
          v_mark_key := case
            when o ->> 'op' = 'edit' and o ?| array['name', 'content'] then 'text'
            when o ->> 'op' = 'edit' and o ?| array['type', 'folder'] then 'class'
            when o ->> 'op' in ('place', 'move', 'remove') then 'placement'
            else null end;
          v_target := case
            when o ->> 'op' in ('edit', 'place') then coalesce(public.course_think_uuid(o ->> 'concept_id'), v_concept)
            when o ->> 'op' in ('move', 'remove') then (
              select a.concept_id from public.concept_appearances a where a.id = public.course_think_uuid(o ->> 'placement_id')
            )
            else null end;
          v_mark := case when v_target is not null and v_mark_key is not null
            then public.concept_review_marks(v_target) ->> v_mark_key end;
          v_dep := jsonb_strip_nulls(jsonb_build_object(
            'action_id', v_action, 'item', v_item, 'kind', v_kind, 'op', o ->> 'op',
            'target_concept_id', v_target, 'target_name', nullif(o ->> 'name', ''),
            'mark_key', v_mark_key, 'mark', v_mark
          ));
          v_own := v_own || jsonb_build_array(v_dep);
          if v_mark_key is not null and v_target is not null then
            v_effects := v_effects || jsonb_build_array(v_dep || jsonb_build_object(
              'effect_concept_id', v_target, 'effect_mark_key', v_mark_key
            ));
          end if;
        end loop;
      end loop;
      v_owns := jsonb_set(v_owns, array[v_ref], v_own);
    end loop;
  end loop;

  for v_e in select x from jsonb_array_elements(coalesce(p_sel, '[]'::jsonb)) x loop
    v_pos := (v_e ->> 'pos')::integer;
    v_concept := public.course_think_uuid(v_e ->> 'concept_id');
    v_list := '[]'::jsonb;
    for v_r, v_k in select x, n::integer from jsonb_array_elements(coalesce(v_e -> 'reviews', '[]'::jsonb)) with ordinality t(x, n) loop
      continue when not (coalesce(p_holds -> (v_e ->> 'pos'), '[]'::jsonb) ? (v_r ->> 'scope'));
      v_deps := coalesce(v_owns -> (v_pos || ':' || v_k), '[]'::jsonb);
      for v_ef in select x from jsonb_array_elements(v_effects) x loop
        if (
          (v_ef ->> 'effect_concept_id' = v_concept::text and v_ef ->> 'effect_mark_key' = public.concept_review_scope_mark(v_r ->> 'scope'))
          or (v_ef ->> 'effect_mark_key' = 'text' and coalesce(v_r -> 'compared_text', '{}'::jsonb) ? (v_ef ->> 'effect_concept_id'))
        ) and not exists (
          select 1 from jsonb_array_elements(v_deps) d
           where d ->> 'action_id' = v_ef ->> 'action_id' and d ->> 'item' = v_ef ->> 'item'
        ) then
          v_deps := v_deps || jsonb_build_array(v_ef - 'effect_concept_id' - 'effect_mark_key');
        end if;
      end loop;
      v_list := v_list || jsonb_build_array(jsonb_build_object('scope', v_r ->> 'scope', 'deps', v_deps));
    end loop;
    if jsonb_array_length(v_list) > 0 then
      v_out := v_out || jsonb_build_object(v_e ->> 'pos', v_list);
    end if;
  end loop;
  return v_out;
end;
$$;

-- drafted·held 위치를 순서대로 모은다.
-- 변경에 의존하지 않는 검토는 바로 검토 카드로 낸다.
-- 의존하는 범위는 초안과 held_fixes 로 보류하고, 필요한 변경 카드만 먼저 낸다.
-- 검토 멱등 키 = 작업 + 위치:초안 판:실제로 내는 범위. 변경 카드 키 = 수정안 내용(같은 수정안은 한 장).
create or replace function public.concept_review_job_submit(
  p_job_id uuid, p_gen bigint, p_conversation_id uuid, p_reason text, p_max_cards integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job public.concept_review_jobs;
  v_reason text := left(btrim(coalesce(p_reason, '')), 500);
  v_room integer;
  v_it public.concept_review_job_items;
  v_r jsonb;
  v_marks jsonb;
  v_bad text;
  v_reviews jsonb;
  v_sel jsonb := '[]'::jsonb;
  v_try jsonb;
  v_plan jsonb;
  v_holds jsonb;
  v_holds_try jsonb;
  v_sub_n integer;
  v_cards integer;
  v_failed jsonb := '[]'::jsonb;
  v_blocked jsonb := '[]'::jsonb;
  v_positions integer[];
  v_key text;
  v_key_src text;
  v_hash text;
  v_link public.concept_review_job_cards;
  v_act public.ai_actions;
  v_lib public.ai_actions;
  v_fix_acts jsonb := '[]'::jsonb;
  v_ids jsonb;
  v_course text;
  v_stage text;
  v_err text;
  v_bad_i integer;
  v_drop integer[];
  v_items jsonb;
  v_map jsonb;
  v_e jsonb;
  v_k integer;
  v_fixes jsonb;
  v_card text;
  v_pos integer;
  v_round integer := 0;
  v_fix_key text;
  v_fix_pos integer[];
  v_deps jsonb;
  v_held jsonb;
  v_scope_cards jsonb;
  v_state text;
  v_item_no integer;
  v_placed boolean;
  v_scope text;
  v_held_out jsonb;
  v_have boolean := false;
begin
  v_job := public.concept_review_job_lock(p_job_id, p_gen);
  if v_reason = '' then
    raise exception 'course_think_reason_required';
  end if;
  if not exists (select 1 from public.ai_conversations where id = p_conversation_id) then
    raise exception 'conversation_not_found' using errcode = 'P0002';
  end if;
  v_room := coalesce((v_job.limits ->> 'max_pending_cards')::integer, 15)
            - (select count(*) from public.concept_review_job_cards jc join public.ai_actions a on a.id = jc.action_id
                where jc.job_id = p_job_id and a.status = 'proposed');
  if v_room <= 0 then
    raise exception 'concept_review_job_pending_full';
  end if;
  if p_max_cards is not null then
    v_room := least(v_room, greatest(p_max_cards, 0));
  end if;

  for v_it in
    select * from public.concept_review_job_items
     where job_id = p_job_id and state in ('drafted', 'held')
     order by pos
     for update
  loop
    v_bad := null;
    v_marks := public.concept_review_marks(v_it.concept_id);
    if v_marks is null then
      v_bad := 'concept_review_concept_not_found';
    end if;
    v_reviews := '[]'::jsonb;
    for v_r in select x from jsonb_array_elements(coalesce(v_it.draft, '[]'::jsonb)) x loop
      if exists (
        select 1 from jsonb_array_elements(coalesce(v_it.held_fixes, '[]'::jsonb)) h where h ->> 'scope' = v_r ->> 'scope'
      ) then
        continue;
      end if;
      if v_it.state = 'held' and coalesce(v_it.scope_cards, '{}'::jsonb) ? (v_r ->> 'scope') then
        continue;
      end if;
      if v_bad is null and v_marks is not null and (
        public.concept_review_revision_part(v_r ->> 'revision', v_r ->> 'scope')
          is distinct from left(v_marks ->> public.concept_review_scope_mark(v_r ->> 'scope'), 12)
        or exists (
          select 1 from jsonb_each_text(coalesce(v_r -> 'compared_text', '{}'::jsonb)) c
           where public.concept_review_text_mark(c.key::uuid) is distinct from c.value
        )
      ) then
        if jsonb_array_length(coalesce(v_it.held_fixes, '[]'::jsonb)) = 0 then
          v_bad := case
            when public.concept_review_revision_part(v_r ->> 'revision', v_r ->> 'scope')
                 is distinct from left(v_marks ->> public.concept_review_scope_mark(v_r ->> 'scope'), 12)
            then 'concept_review_stale' else 'concept_review_compared_changed' end;
        end if;
        continue;
      end if;
      if v_bad is null then
        v_reviews := v_reviews || jsonb_build_array(v_r);
      end if;
    end loop;
    if v_bad is not null then
      update public.concept_review_job_items
         set state = 'failed', reason = v_bad, next_action = '다시 읽고 판단해 새 초안을 저장한다', updated_at = now(), gen = v_job.lease_gen
       where job_id = p_job_id and pos = v_it.pos;
      v_failed := v_failed || jsonb_build_array(jsonb_build_object('position', v_it.pos, 'code', v_bad));
      continue;
    end if;
    if jsonb_array_length(v_reviews) = 0 then
      continue;
    end if;
    v_try := v_sel || jsonb_build_array(jsonb_build_object(
      'pos', v_it.pos, 'version', v_it.draft_version, 'concept_id', v_it.concept_id, 'reviews', v_reviews
    ));
    v_holds_try := public.concept_review_job_hold_scopes(v_try);
    if exists (
      select 1
        from jsonb_array_elements(v_reviews) d
        join public.ai_actions a on a.kind = 'concept_review_record' and a.status = 'proposed'
        cross join lateral jsonb_array_elements(
          case when jsonb_typeof(a.payload -> 'items') = 'array' then a.payload -> 'items' else '[]'::jsonb end
        ) x
       where x ->> 'concept_id' = v_it.concept_id::text and x ->> 'scope' = d ->> 'scope'
         and not (coalesce(v_holds_try -> (v_it.pos::text), '[]'::jsonb) ? (d ->> 'scope'))
         and not exists (select 1 from public.concept_review_job_cards jc where jc.job_id = p_job_id and jc.action_id = a.id)
    ) then
      v_blocked := v_blocked || jsonb_build_array(jsonb_build_object('position', v_it.pos, 'code', 'pending_elsewhere'));
      continue;
    end if;
    v_plan := public.concept_review_job_fix_plan(v_try);
    select count(*)::integer into v_sub_n
      from jsonb_array_elements(v_try) e
      cross join lateral jsonb_array_elements(e -> 'reviews') y
     where not (coalesce(v_holds_try -> (e ->> 'pos'), '[]'::jsonb) ? (y ->> 'scope'));
    v_cards := case when v_sub_n > 0 then 1 else 0 end
             + case when jsonb_array_length(v_plan -> 'lib') > 0 then 1 else 0 end
             + (select count(*) from jsonb_object_keys(v_plan -> 'courses'))::integer;
    exit when v_sub_n > 20
           or octet_length(coalesce((
                select jsonb_agg(y) from jsonb_array_elements(v_try) e
                  cross join lateral jsonb_array_elements(e -> 'reviews') y
                 where not (coalesce(v_holds_try -> (e ->> 'pos'), '[]'::jsonb) ? (y ->> 'scope'))
              ), '[]'::jsonb)::text) > 45000
           or jsonb_array_length(v_plan -> 'lib') > 20
           or exists (select 1 from jsonb_each(v_plan -> 'courses') c where jsonb_array_length(c.value) > 50)
           or v_cards > v_room;
    v_sel := v_try;
  end loop;

  if jsonb_array_length(v_sel) = 0 then
    return jsonb_build_object('submitted', false, 'failed', v_failed, 'blocked', v_blocked, 'room', v_room, 'held', '[]'::jsonb);
  end if;

  loop
    v_round := v_round + 1;
    v_holds := public.concept_review_job_hold_scopes(v_sel);
    v_key_src := (
      select string_agg(
        (e ->> 'pos') || ':' || (e ->> 'version') || ':' || (
          select string_agg(y ->> 'scope', '+' order by y ->> 'scope')
            from jsonb_array_elements(e -> 'reviews') y
           where not (coalesce(v_holds -> (e ->> 'pos'), '[]'::jsonb) ? (y ->> 'scope'))
        ),
        ',' order by (e ->> 'pos')::integer
      )
        from jsonb_array_elements(v_sel) e
       where exists (
         select 1 from jsonb_array_elements(e -> 'reviews') y
          where not (coalesce(v_holds -> (e ->> 'pos'), '[]'::jsonb) ? (y ->> 'scope'))
       )
    );
    v_key := case when v_key_src is null then null else md5(p_job_id::text || '|' || v_key_src) end;
    v_hash := md5(coalesce((
      select jsonb_agg(y - 'compared_text' order by (e ->> 'pos')::integer, y ->> 'scope')
        from jsonb_array_elements(v_sel) e
        cross join lateral jsonb_array_elements(e -> 'reviews') y
       where not (coalesce(v_holds -> (e ->> 'pos'), '[]'::jsonb) ? (y ->> 'scope'))
    ), '[]'::jsonb)::text);
    if v_key is not null then
      select * into v_link from public.concept_review_job_cards where job_id = p_job_id and idem_key = v_key;
      if found then
        if v_link.content_hash <> v_hash then
          raise exception 'concept_review_job_conflict';
        end if;
        select * into v_act from public.ai_actions where id = v_link.action_id;
        v_held_out := coalesce((
          select jsonb_agg(jsonb_build_object('position', (e ->> 'pos')::integer, 'scopes', v_holds -> (e ->> 'pos'))
                           order by (e ->> 'pos')::integer)
            from jsonb_array_elements(v_sel) e
           where jsonb_array_length(coalesce(v_holds -> (e ->> 'pos'), '[]'::jsonb)) > 0
        ), '[]'::jsonb);
        return jsonb_build_object(
          'submitted', true, 'existing', true, 'action', to_jsonb(v_act), 'positions', to_jsonb(v_link.positions),
          'fix_actions', coalesce((
            select jsonb_agg(to_jsonb(a) order by jc.created_at)
              from public.concept_review_job_cards jc
              join public.ai_actions a on a.id = jc.action_id
             where jc.job_id = p_job_id
               and a.kind in ('concept_library_change', 'concept_placement_change')
               and a.status = 'proposed'
               and jc.positions && v_link.positions
          ), '[]'::jsonb),
          'held', v_held_out, 'failed', v_failed, 'blocked', v_blocked
        );
      end if;
    end if;

    v_plan := public.concept_review_job_fix_plan(v_sel);
    v_ids := '{}'::jsonb;
    v_fix_acts := '[]'::jsonb;
    v_stage := null;
    begin
      if jsonb_array_length(v_plan -> 'lib') > 0 then
        v_fix_key := 'fix:lib:' || md5((v_plan -> 'lib')::text);
        v_fix_pos := array(select (x #>> '{}')::integer from jsonb_array_elements(v_plan -> 'lib_pos') x);
        select * into v_link from public.concept_review_job_cards where job_id = p_job_id and idem_key = v_fix_key;
        if found then
          v_ids := v_ids || jsonb_build_object('lib', v_link.action_id);
          update public.concept_review_job_cards
             set positions = (select array(select distinct x from unnest(positions || v_fix_pos) x order by x))
           where id = v_link.id;
          select * into v_lib from public.ai_actions where id = v_link.action_id;
        else
          v_stage := 'lib';
          v_lib := public.course_think_propose_library(
            p_conversation_id, jsonb_build_object('items', v_plan -> 'lib', 'reason', v_reason), v_reason
          );
          v_stage := null;
          v_ids := v_ids || jsonb_build_object('lib', v_lib.id);
          insert into public.concept_review_job_cards (job_id, action_id, idem_key, content_hash, positions, origin_conversation_id)
          values (p_job_id, v_lib.id, v_fix_key, md5((v_plan -> 'lib')::text), v_fix_pos, p_conversation_id);
        end if;
        v_fix_acts := v_fix_acts || jsonb_build_array(to_jsonb(v_lib));
      end if;
      for v_course in select k from jsonb_object_keys(v_plan -> 'courses') k order by k loop
        v_fix_key := 'fix:pl:' || v_course || ':' || md5((v_plan -> 'courses' -> v_course)::text);
        v_fix_pos := array(select (x #>> '{}')::integer from jsonb_array_elements(v_plan -> 'course_pos' -> v_course) x);
        select * into v_link from public.concept_review_job_cards where job_id = p_job_id and idem_key = v_fix_key;
        if found then
          v_ids := v_ids || jsonb_build_object('pl:' || v_course, v_link.action_id);
          update public.concept_review_job_cards
             set positions = (select array(select distinct x from unnest(positions || v_fix_pos) x order by x))
           where id = v_link.id;
          select * into v_lib from public.ai_actions where id = v_link.action_id;
        else
          v_stage := 'pl:' || v_course;
          v_lib := public.course_think_propose_placement(
            p_conversation_id,
            jsonb_build_object('course_id', v_course, 'items', v_plan -> 'courses' -> v_course, 'reason', v_reason),
            v_reason
          );
          v_stage := null;
          v_ids := v_ids || jsonb_build_object('pl:' || v_course, v_lib.id);
          insert into public.concept_review_job_cards (job_id, action_id, idem_key, content_hash, positions, origin_conversation_id)
          values (p_job_id, v_lib.id, v_fix_key, md5((v_plan -> 'courses' -> v_course)::text), v_fix_pos, p_conversation_id);
        end if;
        v_fix_acts := v_fix_acts || jsonb_build_array(to_jsonb(v_lib));
      end loop;
    exception when others then
      v_err := sqlerrm;
      if v_stage is null or v_round > 25 then
        raise;
      end if;
      v_bad_i := nullif(substring(v_err from '_bad_item:([0-9]+):'), '')::integer;
      if v_stage = 'lib' then
        v_drop := array(select (x #>> '{}')::integer from jsonb_array_elements(v_plan -> 'lib_pos') x);
        if v_bad_i is not null then
          v_drop := array(
            select split_part(r.key, ':', 1)::integer
              from jsonb_each(v_plan -> 'refs') r
             where (r.value -> 'lib') @> to_jsonb(v_bad_i)
          );
        end if;
      else
        v_drop := array(select (x #>> '{}')::integer from jsonb_array_elements(v_plan -> 'course_pos' -> substr(v_stage, 4)) x);
        if v_bad_i is not null then
          v_drop := array(
            select split_part(r.key, ':', 1)::integer
              from jsonb_each(v_plan -> 'refs') r
             where (r.value -> v_stage) @> to_jsonb(v_bad_i)
          );
        end if;
      end if;
      if cardinality(v_drop) = 0 then
        raise;
      end if;
      update public.concept_review_job_items
         set state = 'failed', reason = left('fix_invalid: ' || v_err, 500),
             next_action = '고치기 제안이 거부됐다. 이유를 보고 다시 검수한다', updated_at = now(), gen = v_job.lease_gen
       where job_id = p_job_id and pos = any (v_drop);
      v_failed := v_failed || coalesce((
        select jsonb_agg(jsonb_build_object('position', d, 'code', left('fix_invalid: ' || v_err, 200))) from unnest(v_drop) d
      ), '[]'::jsonb);
      v_sel := coalesce((
        select jsonb_agg(e order by (e ->> 'pos')::integer) from jsonb_array_elements(v_sel) e
         where not ((e ->> 'pos')::integer = any (v_drop))
      ), '[]'::jsonb);
      if jsonb_array_length(v_sel) = 0 then
        return jsonb_build_object('submitted', false, 'failed', v_failed, 'blocked', v_blocked, 'room', v_room, 'held', '[]'::jsonb);
      end if;
      continue;
    end;
    exit;
  end loop;

  v_holds := public.concept_review_job_hold_scopes(v_sel);
  v_deps := public.concept_review_job_deps(v_sel, v_plan, v_ids, v_holds);
  v_items := '[]'::jsonb;
  v_map := '{}'::jsonb;
  for v_e in select x from jsonb_array_elements(v_sel) x loop
    v_pos := (v_e ->> 'pos')::integer;
    for v_r, v_k in select x, n::integer from jsonb_array_elements(v_e -> 'reviews') with ordinality t(x, n) loop
      continue when coalesce(v_holds -> (v_e ->> 'pos'), '[]'::jsonb) ? (v_r ->> 'scope');
      if exists (
        select 1 from public.ai_actions a
          cross join lateral jsonb_array_elements(
            case when jsonb_typeof(a.payload -> 'items') = 'array' then a.payload -> 'items' else '[]'::jsonb end
          ) x
         where a.kind = 'concept_review_record' and a.status = 'proposed'
           and x ->> 'concept_id' = v_e ->> 'concept_id' and x ->> 'scope' = v_r ->> 'scope'
      ) then
        continue;
      end if;
      v_fixes := '[]'::jsonb;
      for v_card in select k from jsonb_object_keys(coalesce(v_plan -> 'refs' -> (v_pos || ':' || v_k), '{}'::jsonb)) k loop
        v_fixes := v_fixes || jsonb_build_array(jsonb_build_object(
          'action_id', case when v_card like 'ext:%' then substr(v_card, 5) else v_ids ->> v_card end,
          'items', v_plan -> 'refs' -> (v_pos || ':' || v_k) -> v_card
        ));
      end loop;
      v_items := v_items || jsonb_build_array((v_r - 'compared_text' - 'fix') || jsonb_build_object('fixes', v_fixes));
      v_map := jsonb_set(v_map, array[v_pos::text], coalesce(v_map -> v_pos::text, '[]'::jsonb) || to_jsonb(jsonb_array_length(v_items)));
    end loop;
  end loop;

  v_act := null;
  v_have := false;
  if jsonb_array_length(v_items) > 0 then
    v_act := public.course_think_propose_review(p_conversation_id, jsonb_build_object('items', v_items, 'reason', v_reason), v_reason);
    v_have := true;
    v_positions := array(select (k)::integer from jsonb_object_keys(v_map) k order by 1);
    insert into public.concept_review_job_cards (job_id, action_id, idem_key, content_hash, positions, origin_conversation_id)
    values (p_job_id, v_act.id, v_key, v_hash, v_positions, p_conversation_id);
  end if;

  for v_e in select x from jsonb_array_elements(v_sel) x loop
    v_pos := (v_e ->> 'pos')::integer;
    select * into v_it from public.concept_review_job_items where job_id = p_job_id and pos = v_pos;
    v_held := coalesce(v_it.held_fixes, '[]'::jsonb) || coalesce(v_deps -> (v_pos::text), '[]'::jsonb);
    v_scope_cards := coalesce(v_it.scope_cards, '{}'::jsonb);
    v_placed := false;
    if v_have and v_map ? (v_pos::text) then
      v_placed := true;
      for v_r in select x from jsonb_array_elements(v_e -> 'reviews') x loop
        continue when coalesce(v_holds -> (v_e ->> 'pos'), '[]'::jsonb) ? (v_r ->> 'scope');
        if exists (
          select 1 from jsonb_array_elements(coalesce(v_act.payload -> 'items', '[]'::jsonb)) with ordinality t(x, n)
           where x ->> 'concept_id' = v_e ->> 'concept_id' and x ->> 'scope' = v_r ->> 'scope'
        ) then
          v_scope_cards := v_scope_cards || jsonb_build_object(v_r ->> 'scope', jsonb_build_object(
            'action_id', v_act.id,
            'item', (
              select n::integer from jsonb_array_elements(coalesce(v_act.payload -> 'items', '[]'::jsonb)) with ordinality t(x, n)
               where x ->> 'concept_id' = v_e ->> 'concept_id' and x ->> 'scope' = v_r ->> 'scope'
               limit 1
            )
          ));
        end if;
      end loop;
    end if;
    v_state := case when jsonb_array_length(v_held) > 0 then 'held' else 'submitted' end;
    update public.concept_review_job_items
       set state = v_state,
           held_fixes = v_held,
           scope_cards = v_scope_cards,
           action_id = case when v_placed then v_act.id else action_id end,
           action_items = case when v_placed then array(
             select (x #>> '{}')::integer from jsonb_array_elements(v_map -> v_pos::text) x
           ) else action_items end,
           reason = case when v_state = 'submitted' then null else reason end,
           next_action = case when v_state = 'submitted' then null else next_action end,
           gen = v_job.lease_gen, updated_at = now()
     where job_id = p_job_id and pos = v_pos;
  end loop;

  update public.concept_review_jobs set last_progress_at = now(), updated_at = now() where id = p_job_id;
  v_held_out := coalesce((
    select jsonb_agg(jsonb_build_object('position', (e ->> 'pos')::integer, 'scopes', v_holds -> (e ->> 'pos'))
                     order by (e ->> 'pos')::integer)
      from jsonb_array_elements(v_sel) e
     where jsonb_array_length(coalesce(v_holds -> (e ->> 'pos'), '[]'::jsonb)) > 0
  ), '[]'::jsonb);
  v_positions := case when not v_have then '{}'::integer[]
    else array(select (k)::integer from jsonb_object_keys(v_map) k order by 1) end;
  return jsonb_build_object(
    'submitted', true, 'existing', false,
    'action', case when v_have then to_jsonb(v_act) else null end,
    'fix_actions', v_fix_acts,
    'positions', to_jsonb(v_positions),
    'held', v_held_out, 'failed', v_failed, 'blocked', v_blocked
  );
end;
$$;

-- 전체 실패는 내용을 되돌린 채 시도 결과를 카드에 남긴다. 관계 카드는 예전처럼 예외다.
create or replace function public.course_think_apply_review(p_act public.ai_actions, p_overrides jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_skip integer[];
  v_item jsonb;
  v_i integer := 0;
  v_key text;
  v_marks jsonb;
  v_ref jsonb;
  v_id uuid;
  v_res jsonb := '[]'::jsonb;
  v_applied integer := 0;
  v_failed integer := 0;
  v_skipped integer := 0;
  v_first text;
begin
  begin
    v_skip := array(select x::integer from jsonb_array_elements_text(coalesce(p_overrides -> 'skip', '[]'::jsonb)) x);
  exception when others then
    raise exception 'course_think_bad_overrides';
  end;

  for v_item in select e from jsonb_array_elements(p_act.payload -> 'items') e loop
    v_i := v_i + 1;
    if v_i = any (v_skip) then
      v_skipped := v_skipped + 1;
      v_res := v_res || jsonb_build_array(jsonb_build_object('i', v_i, 'status', 'skipped'));
      continue;
    end if;
    begin
      perform 1 from public.concepts where id = (v_item ->> 'concept_id')::uuid for share;
      if not found then
        raise exception 'concept_review_concept_not_found';
      end if;
      v_key := public.concept_review_scope_mark(v_item ->> 'scope');
      v_marks := public.concept_review_marks((v_item ->> 'concept_id')::uuid);
      if (v_marks ->> v_key) is distinct from (v_item -> 'marks' ->> v_key) then
        raise exception 'concept_review_stale';
      end if;
      for v_ref in select e from jsonb_array_elements(coalesce(v_item -> 'compared', '[]'::jsonb)) e loop
        if public.concept_review_text_mark((v_ref ->> 'id')::uuid) is distinct from v_ref ->> 'text' then
          raise exception 'concept_review_compared_changed';
        end if;
      end loop;
      insert into public.concept_quality_reviews (
        concept_id, scope, outcome, checked, findings, basis, unverified, follow_up, compared, to_compare,
        marks, mark, origin, action_id, action_item, proposed_at, approved_by, detail, fixes
      )
      values (
        (v_item ->> 'concept_id')::uuid, v_item ->> 'scope', v_item ->> 'outcome', v_item ->> 'checked',
        v_item ->> 'findings', v_item ->> 'basis', v_item ->> 'unverified', v_item ->> 'follow_up',
        coalesce(v_item -> 'compared', '[]'::jsonb), coalesce(v_item -> 'to_compare', '[]'::jsonb),
        v_item -> 'marks', v_item -> 'marks' ->> v_key, 'think', p_act.id, v_i, p_act.created_at, auth.uid(),
        coalesce(v_item -> 'detail', '{}'::jsonb), coalesce(v_item -> 'fixes', '[]'::jsonb)
      )
      returning id into v_id;
      v_applied := v_applied + 1;
      v_res := v_res || jsonb_build_array(jsonb_build_object(
        'i', v_i, 'status', 'applied', 'review_id', v_id, 'concept_id', v_item ->> 'concept_id'
      ));
    exception when others then
      v_failed := v_failed + 1;
      v_first := coalesce(v_first, sqlerrm);
      v_res := v_res || jsonb_build_array(jsonb_build_object('i', v_i, 'status', 'failed', 'code', left(sqlerrm, 200)));
    end;
  end loop;

  if v_applied = 0 and v_failed = 0 then
    raise exception 'course_think_nothing_selected';
  end if;
  if v_applied = 0 then
    return jsonb_build_object(
      'attempt_failed', true,
      'error', 'course_think_all_failed:' || coalesce(v_first, ''),
      'items', v_res, 'applied', v_applied, 'failed', v_failed, 'skipped', v_skipped
    );
  end if;
  return jsonb_build_object('items', v_res, 'applied', v_applied, 'failed', v_failed, 'skipped', v_skipped);
end;
$$;

create or replace function public.course_think_apply_placement(p_act public.ai_actions, p_overrides jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_course public.course_maps;
  v_skip integer[];
  v_units jsonb := coalesce(nullif(p_overrides -> 'units', 'null'::jsonb), '{}'::jsonb);
  v_item jsonb;
  v_i integer := 0;
  v_unit uuid;
  v_id uuid;
  v_ids uuid[];
  v_res jsonb := '[]'::jsonb;
  v_applied integer := 0;
  v_failed integer := 0;
  v_skipped integer := 0;
  v_first text;
begin
  select * into v_course from public.course_maps where id = (p_act.payload ->> 'course_id')::uuid;
  if not found then
    raise exception 'course_map_not_found';
  end if;
  if v_course.archived_at is not null then
    raise exception 'course_map_archived';
  end if;
  begin
    v_skip := array(select x::integer from jsonb_array_elements_text(coalesce(p_overrides -> 'skip', '[]'::jsonb)) x);
  exception when others then
    raise exception 'course_think_bad_overrides';
  end;
  if jsonb_typeof(v_units) <> 'object' then
    raise exception 'course_think_bad_overrides';
  end if;

  for v_item in select e from jsonb_array_elements(p_act.payload -> 'items') e loop
    v_i := v_i + 1;
    if v_i = any (v_skip) then
      v_skipped := v_skipped + 1;
      v_res := v_res || jsonb_build_array(jsonb_build_object('i', v_i, 'status', 'skipped'));
      continue;
    end if;
    begin
      if v_units ? v_i::text then
        v_unit := public.course_think_uuid(v_units ->> v_i::text);
        if v_unit is null then
          raise exception 'course_think_bad_overrides';
        end if;
      else
        v_unit := public.course_think_uuid(v_item ->> 'unit_id');
      end if;
      v_id := null;
      case v_item ->> 'op'
        when 'place' then
          perform public.course_placement_unit_in(v_unit, v_course.id);
          v_id := public.course_placement_insert(v_unit, (v_item ->> 'concept_id')::uuid, 'ai', v_item ->> 'evidence');
        when 'move' then
          v_id := (v_item ->> 'placement_id')::uuid;
          perform public.course_placement_row_in(v_id, v_course.id);
          perform public.course_placement_unit_in(v_unit, v_course.id);
          perform public.course_placement_move_row(v_id, v_unit, 'ai', v_item ->> 'evidence');
        when 'remove' then
          v_id := (v_item ->> 'placement_id')::uuid;
          v_unit := (public.course_placement_row_in(v_id, v_course.id)).course_unit_id;
          delete from public.concept_appearances where id = v_id;
          perform public.course_placement_renumber(v_unit);
        when 'reorder' then
          perform public.course_placement_unit_in(v_unit, v_course.id);
          v_ids := array(
            select x::uuid from jsonb_array_elements_text(v_item -> 'placement_ids') with ordinality as t(x, n) order by n
          );
          perform public.course_placement_reorder_rows(v_unit, v_ids);
      end case;
      v_applied := v_applied + 1;
      v_res := v_res || jsonb_build_array(jsonb_build_object(
        'i', v_i, 'status', 'applied', 'placement_id', v_id, 'unit_id', v_unit
      ));
    exception when others then
      v_failed := v_failed + 1;
      v_first := coalesce(v_first, sqlerrm);
      v_res := v_res || jsonb_build_array(jsonb_build_object('i', v_i, 'status', 'failed', 'code', left(sqlerrm, 200)));
    end;
  end loop;

  if v_applied = 0 and v_failed = 0 then
    raise exception 'course_think_nothing_selected';
  end if;
  if v_applied = 0 then
    return jsonb_build_object(
      'attempt_failed', true,
      'error', 'course_think_all_failed:' || coalesce(v_first, ''),
      'course_id', v_course.id, 'items', v_res, 'applied', v_applied, 'failed', v_failed, 'skipped', v_skipped
    );
  end if;
  return jsonb_build_object(
    'course_id', v_course.id, 'items', v_res, 'applied', v_applied, 'failed', v_failed, 'skipped', v_skipped
  );
end;
$$;

create or replace function public.course_think_apply_library(p_act public.ai_actions, p_overrides jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_note text := left('Think 카드 승인: ' || coalesce(p_act.payload ->> 'reason', ''), 2000);
  v_skip integer[];
  v_item jsonb;
  v_i integer := 0;
  v_concept public.concepts;
  v_type public.concept_types;
  v_changes jsonb;
  v_base jsonb;
  v_cat uuid;
  v_family uuid;
  v_label text;
  v_n integer;
  v_id uuid;
  v_pid uuid;
  v_at timestamptz;
  v_att jsonb;
  v_snap jsonb;
  v_one jsonb;
  v_res jsonb := '[]'::jsonb;
  v_applied integer := 0;
  v_failed integer := 0;
  v_skipped integer := 0;
  v_first text;
begin
  begin
    v_skip := array(select x::integer from jsonb_array_elements_text(coalesce(p_overrides -> 'skip', '[]'::jsonb)) x);
  exception when others then
    raise exception 'course_think_bad_overrides';
  end;

  for v_item in select e from jsonb_array_elements(p_act.payload -> 'items') e loop
    v_i := v_i + 1;
    if v_i = any (v_skip) then
      v_skipped := v_skipped + 1;
      v_res := v_res || jsonb_build_array(jsonb_build_object('i', v_i, 'status', 'skipped'));
      continue;
    end if;
    begin
      v_one := jsonb_build_object('i', v_i, 'status', 'applied');
      case v_item ->> 'op'
        when 'create' then
          v_type := public.concept_think_type(v_item ->> 'type');
          v_cat := public.concept_think_folder_make(v_item -> 'folder');
          insert into public.concept_families (canonical_name) values (v_item ->> 'name') on conflict (canonical_name) do nothing;
          select id into v_family from public.concept_families where canonical_name = v_item ->> 'name';
          v_label := '기본';
          v_n := 1;
          while exists (select 1 from public.concepts where family_id = v_family and version_label = v_label) loop
            v_n := v_n + 1;
            v_label := '기본-' || v_n;
          end loop;
          insert into public.concepts (kind, sub_type, name, content, level, main_category_id, sort_order, family_id, version_label)
          values (
            case when v_type.legacy_sub_type = '정의' then 'definition' else 'theorem' end,
            v_type.legacy_sub_type, v_item ->> 'name', v_item ->> 'content', 1, v_cat,
            coalesce((select max(sort_order) + 1 from public.concepts where main_category_id = v_cat), 0),
            v_family, v_label
          )
          returning id into v_id;
          insert into public.concept_type_links (concept_id, type_id, created_by) values (v_id, v_type.id, auth.uid());
          v_pid := null;
          if public.course_think_uuid(v_item ->> 'place_unit_id') is not null then
            v_pid := public.course_placement_insert(
              (v_item ->> 'place_unit_id')::uuid, v_id, 'ai', v_item ->> 'evidence'
            );
          end if;
          v_one := v_one || jsonb_build_object('concept_id', v_id, 'placement_id', v_pid);
        when 'edit' then
          select * into v_concept from public.concepts where id = (v_item ->> 'concept_id')::uuid for update;
          if not found then
            raise exception 'concept_think_concept_not_found';
          end if;
          v_base := v_item -> 'base';
          if v_concept.name <> v_base ->> 'name'
             or md5(v_concept.content) <> v_base ->> 'md5'
             or v_concept.main_category_id <> (v_base ->> 'category_id')::uuid
             or (select type_id from public.concept_type_links where concept_id = v_concept.id)
                is distinct from (v_base ->> 'type_id')::uuid then
            raise exception 'concept_think_stale';
          end if;
          v_changes := v_item -> 'changes';
          if v_changes ? 'content'
             and exists (select 1 from public.concept_content_drafts where concept_id = v_concept.id) then
            raise exception 'concept_content_draft_pending';
          end if;
          if v_changes ? 'name' or v_changes ? 'content' then
            perform set_config('ygg.concept_content_via', 'draft', true);
            perform set_config('ygg.concept_content_note', v_note, true);
            perform set_config('ygg.concept_content_origin', 'ai', true);
            update public.concepts
               set name = coalesce(v_changes ->> 'name', name), content = coalesce(v_changes ->> 'content', content)
             where id = v_concept.id;
            perform set_config('ygg.concept_content_via', '', true);
            perform set_config('ygg.concept_content_note', '', true);
            perform set_config('ygg.concept_content_origin', '', true);
          end if;
          if v_changes ? 'type' then
            v_type := public.concept_think_type(v_changes ->> 'type');
            insert into public.concept_type_links (concept_id, type_id, created_by)
            values (v_concept.id, v_type.id, auth.uid())
            on conflict (concept_id) do update set type_id = excluded.type_id;
            update public.concepts
               set kind = case when v_type.legacy_sub_type = '정의' then 'definition' else 'theorem' end,
                   sub_type = v_type.legacy_sub_type
             where id = v_concept.id;
          end if;
          if v_changes ? 'folder' then
            v_cat := public.concept_think_folder_make(v_changes -> 'folder');
            update public.concepts
               set main_category_id = v_cat,
                   sort_order = coalesce((select max(sort_order) + 1 from public.concepts where main_category_id = v_cat), 0)
             where id = v_concept.id and main_category_id <> v_cat;
          end if;
          v_one := v_one || jsonb_build_object('concept_id', v_concept.id);
        when 'statement' then
          perform public.concept_statement_lock(
            (v_item ->> 'statement_id')::uuid, (v_item ->> 'base_version')::integer, null
          );
          update public.concept_statements
             set draft = v_item -> 'content', draft_origin = 'ai', draft_saved_at = clock_timestamp(),
                 draft_saved_by = auth.uid()
           where id = (v_item ->> 'statement_id')::uuid
          returning draft_saved_at into v_at;
          perform public.concept_statement_confirm(
            (v_item ->> 'statement_id')::uuid, (v_item ->> 'base_version')::integer, v_at, v_note
          );
          v_one := v_one || jsonb_build_object('statement_id', v_item ->> 'statement_id');
        when 'delete' then
          select * into v_concept from public.concepts where id = (v_item ->> 'concept_id')::uuid for update;
          if not found then
            raise exception 'concept_think_concept_not_found';
          end if;
          v_att := public.concept_attachments(v_concept.id);
          if (v_att ->> 'total')::integer > 0 then
            raise exception 'concept_delete_attached';
          end if;
          v_snap := jsonb_build_object(
            'id', v_concept.id, 'name', v_concept.name, 'content', v_concept.content,
            'folder', to_jsonb(public.concept_folder_path(v_concept.main_category_id)),
            'type', (
              select t.name from public.concept_type_links l join public.concept_types t on t.id = l.type_id
               where l.concept_id = v_concept.id
            )
          );
          delete from public.concepts where id = v_concept.id;
          v_one := v_one || jsonb_build_object('deleted', v_snap);
      end case;
      v_applied := v_applied + 1;
      v_res := v_res || jsonb_build_array(v_one);
    exception when others then
      v_failed := v_failed + 1;
      v_first := coalesce(v_first, sqlerrm);
      v_res := v_res || jsonb_build_array(jsonb_build_object('i', v_i, 'status', 'failed', 'code', left(sqlerrm, 200)));
    end;
  end loop;

  if v_applied = 0 and v_failed = 0 then
    raise exception 'course_think_nothing_selected';
  end if;
  if v_applied = 0 then
    return jsonb_build_object(
      'attempt_failed', true,
      'error', 'course_think_all_failed:' || coalesce(v_first, ''),
      'items', v_res, 'applied', v_applied, 'failed', v_failed, 'skipped', v_skipped
    );
  end if;
  return jsonb_build_object('items', v_res, 'applied', v_applied, 'failed', v_failed, 'skipped', v_skipped);
end;
$$;

create or replace function public.course_think_action_apply(p_id uuid, p_overrides jsonb default '{}'::jsonb)
returns public.ai_actions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_act public.ai_actions;
  v_res jsonb;
  v_over jsonb := coalesce(p_overrides, '{}'::jsonb);
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into v_act from public.ai_actions where id = p_id for update;
  if not found then
    raise exception 'action_not_found' using errcode = 'P0002';
  end if;
  if v_act.status <> 'proposed' then
    raise exception 'action_not_pending' using errcode = '22023';
  end if;
  if jsonb_typeof(v_over) <> 'object' then
    raise exception 'course_think_bad_overrides';
  end if;
  perform set_config('ygg.think_action_id', p_id::text, true);
  if v_act.kind = 'course_map_change' then
    v_res := public.course_think_apply_map(v_act);
  elsif v_act.kind = 'course_map_create' then
    v_res := public.course_think_apply_create(v_act);
  elsif v_act.kind = 'concept_placement_change' then
    v_res := public.course_think_apply_placement(v_act, v_over);
  elsif v_act.kind = 'concept_library_change' then
    v_res := public.course_think_apply_library(v_act, v_over);
  elsif v_act.kind = 'concept_review_record' then
    v_res := public.course_think_apply_review(v_act, v_over);
  elsif v_act.kind = 'concept_relation_change' then
    v_res := public.course_think_apply_relation(v_act, v_over);
  else
    raise exception 'action_kind_not_appliable' using errcode = '22023';
  end if;
  perform set_config('ygg.think_action_id', '', true);
  if coalesce((v_res ->> 'attempt_failed')::boolean, false) then
    update public.ai_actions
       set status = 'proposed', result = v_res, error = left(coalesce(v_res ->> 'error', ''), 500),
           decided_by = null, decided_at = null
     where id = p_id
    returning * into v_act;
    return v_act;
  end if;
  update public.ai_actions
     set status = 'applied', result = v_res, error = null, decided_by = auth.uid(), decided_at = now()
   where id = p_id
  returning * into v_act;
  return v_act;
end;
$$;

-- 다음 검수: 풀린 보류와 재판단할 실패만 대상에 넣는다.
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
       ) then
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

create or replace function public.concept_review_job_material(
  p_job_id uuid, p_gen bigint, p_positions integer[], p_offsets jsonb, p_budget integer
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job public.concept_review_jobs;
  v_walk public.concept_review_walks;
  v_budget integer := least(greatest(coalesce(p_budget, 60000), 4000), 120000);
  v_used integer := 0;
  v_items jsonb := '[]'::jsonb;
  v_rest integer[] := '{}'::integer[];
  v_stop boolean := false;
  v_pos integer;
  v_cid uuid;
  v_d jsonb;
  v_content text;
  v_len integer;
  v_off integer;
  v_base integer;
  v_take integer;
  v_pending uuid[];
  v_cs jsonb;
  v_open jsonb;
begin
  v_job := public.concept_review_job_lock(p_job_id, p_gen);
  if p_positions is null or cardinality(p_positions) = 0 then
    raise exception 'concept_review_job_no_items';
  end if;
  if cardinality(p_positions) > 60 then
    raise exception 'concept_review_job_too_many';
  end if;
  select * into v_walk from public.concept_review_walks where id = v_job.walk_id;
  v_pending := public.concept_review_pending_concepts();

  foreach v_pos in array p_positions loop
    if v_stop then
      v_rest := v_rest || v_pos;
      continue;
    end if;
    if v_pos is null or v_pos < 1 or v_pos > v_job.total then
      v_items := v_items || jsonb_build_array(jsonb_build_object('position', v_pos, 'error', 'concept_review_job_bad_position'));
      continue;
    end if;
    v_cid := v_walk.concept_ids[v_pos];
    if not exists (select 1 from public.concepts where id = v_cid) then
      v_items := v_items || jsonb_build_array(jsonb_build_object('position', v_pos, 'concept_id', v_cid, 'missing', true));
      continue;
    end if;
    v_d := public.concept_think_detail(v_cid);
    v_d := (v_d - 'sources' - 'attached')
           || jsonb_build_object(
                'source_count', jsonb_array_length(coalesce(v_d -> 'sources', '[]'::jsonb)),
                'sources', coalesce((
                  select jsonb_agg(jsonb_build_object(
                           'book', f.name, 'grade', s.grade_label,
                           'course_key', nullif(public._textbook_course_info(s.grade_label) ->> 'course_key', ''),
                           'unit_path', to_jsonb(s.unit_path), 'printed_page', s.display_page, 'pdf_page', s.raw_page
                         ) order by s.created_at, s.id)
                    from (
                      select * from public.concept_sources s0 where s0.concept_id = v_cid order by s0.created_at, s0.id limit 12
                    ) s
                    left join public.resource_files f on f.id = s.book_id
                ), '[]'::jsonb)
              );
    v_cs := public.concept_review_job_concept_state(v_cid, v_pending);
    v_open := public.concept_review_job_open_scopes(p_job_id, v_pos);
    if jsonb_array_length(coalesce(v_open -> 'scopes', '[]'::jsonb)) > 0 then
      v_d := v_d || jsonb_build_object(
        'todo', v_open -> 'scopes', 'resume_scopes', v_open -> 'scopes',
        'created_concepts', coalesce(v_open -> 'created', '[]'::jsonb), 'conditions', v_cs -> 'conditions'
      );
    else
      v_d := v_d || jsonb_build_object(
        'todo', v_cs -> 'todo', 'resume_scopes', '[]'::jsonb, 'created_concepts', '[]'::jsonb,
        'conditions', v_cs -> 'conditions'
      );
    end if;
    v_content := coalesce(v_d ->> 'content', '');
    v_len := char_length(v_content);
    v_off := least(greatest(coalesce((p_offsets ->> v_pos::text)::integer, 0), 0), v_len);
    v_base := char_length((v_d - 'content')::text);
    if v_used > 0 and v_used + v_base + (v_len - v_off) > v_budget then
      v_stop := true;
      v_rest := v_rest || v_pos;
      continue;
    end if;
    v_take := greatest(least(v_len - v_off, v_budget - v_used - v_base), least(v_len - v_off, 2000));
    v_items := v_items || jsonb_build_array(v_d || jsonb_build_object(
      'position', v_pos, 'concept_id', v_cid,
      'content', substr(v_content, v_off + 1, v_take),
      'content_offset', v_off, 'content_chars', v_len,
      'content_next_offset', case when v_off + v_take < v_len then v_off + v_take end
    ));
    v_used := v_used + v_base + v_take;
  end loop;
  return jsonb_build_object('items', v_items, 'rest', to_jsonb(v_rest), 'budget', v_budget, 'used', v_used);
end;
$$;

create or replace function public.concept_review_job_batch_begin(p_job_id uuid, p_gen bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job public.concept_review_jobs;
begin
  v_job := public.concept_review_job_lock(p_job_id, p_gen);
  return jsonb_build_object(
    'pending_cards', (
      select count(*) from public.concept_review_job_cards jc join public.ai_actions a on a.id = jc.action_id
       where jc.job_id = p_job_id and a.status = 'proposed'
    ),
    'max_pending_cards', coalesce((v_job.limits ->> 'max_pending_cards')::integer, 15),
    'max_cards_per_request', coalesce((v_job.limits ->> 'max_cards_per_request')::integer, 13),
    'max_batch', coalesce((v_job.limits ->> 'max_batch')::integer, 50),
    'drafted', (select count(*) from public.concept_review_job_items where job_id = p_job_id and state = 'drafted'),
    'deferred', (select count(*) from public.concept_review_job_items where job_id = p_job_id and state = 'deferred'),
    'retry', coalesce((
      select jsonb_agg(jsonb_build_object('position', i.pos, 'concept_id', i.concept_id, 'reason', i.reason) order by i.pos)
        from (
          select * from public.concept_review_job_items
           where job_id = p_job_id and state = 'failed'
             and (reason in ('concept_review_stale', 'concept_review_compared_changed') or reason like 'judge\_%')
           order by pos limit 50
        ) i
    ), '[]'::jsonb),
    'held', (select count(*)::integer from public.concept_review_job_items where job_id = p_job_id and state = 'held'),
    'recheck', coalesce((
      select jsonb_agg(jsonb_build_object(
               'position', s.pos, 'concept_id', s.concept_id, 'scopes', s.scopes, 'reason', 'resume'
             ) order by s.pos)
        from (
          select i.pos, i.concept_id, o -> 'scopes' as scopes
            from public.concept_review_job_items i
            cross join lateral public.concept_review_job_open_scopes(p_job_id, i.pos) o
           where i.job_id = p_job_id and i.state in ('held', 'submitted', 'failed')
             and jsonb_array_length(coalesce(o -> 'scopes', '[]'::jsonb)) > 0
           order by i.pos
           limit 50
        ) s
    ), '[]'::jsonb),
    'checkpoint', v_job.checkpoint, 'served_through', v_job.served_through, 'total', v_job.total
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
declare
  v_job public.concept_review_jobs;
  v_walk public.concept_review_walks;
  v_pending uuid[];
  v_limit integer := least(greatest(coalesce(p_open_limit, 20), 0), 60);
  v_counts jsonb := '{"complete": 0, "awaiting": 0, "drafted": 0, "open": 0, "todo": 0, "not_reviewed": 0, "missing": 0}'::jsonb;
  v_cond jsonb := '{"text": 0, "foundation": 0, "placement": 0}'::jsonb;
  v_open jsonb := '[]'::jsonb;
  v_cs jsonb;
  v_cat text;
  v_next text;
  v_hold jsonb;
  v_total integer;
  v_c text;
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
    v_cs := public.concept_review_job_concept_state(r.cid, v_pending);
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
    if v_cat in ('open', 'drafted', 'todo') and jsonb_array_length(v_open) < v_limit then
      v_open := v_open || jsonb_build_array(jsonb_build_object(
        'position', r.pos, 'concept_id', r.cid, 'name', (select name from public.concepts where id = r.cid),
        'category', v_cat, 'item_state', r.item_state, 'next_action', v_next, 'reason', r.reason,
        'action_id', r.action_id, 'draft_version', r.draft_version,
        'conditions', v_cs -> 'conditions', 'todo', v_cs -> 'todo', 'open', v_cs -> 'open'
      ));
    end if;
  end loop;

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
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.concept_review_job_hold_scopes(jsonb) from public, anon, authenticated;
revoke all on function public.concept_review_job_hold_view(jsonb) from public, anon, authenticated;
revoke all on function public.concept_review_job_open_scopes(uuid, integer) from public, anon, authenticated;
revoke all on function public.concept_review_job_hold_note(uuid, integer, bigint) from public, anon, authenticated;
revoke all on function public.concept_review_job_deps(jsonb, jsonb, jsonb, jsonb) from public, anon, authenticated;

notify pgrst, 'reload schema';
