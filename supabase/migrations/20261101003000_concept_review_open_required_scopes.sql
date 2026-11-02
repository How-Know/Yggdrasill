-- 반영된 보류가 있는 위치는, 그 보류 범위만 다시 열지 않는다.
-- 최신 상태가 빠졌거나 다시 볼 필수 범위(표기·의미·기초 개념·배치)를 합친다.
-- 의미의 근거 미확인(gap)과 이미 충족(met)한 배치는 열지 않는다.
-- 필수 범위가 함께 열린 이번 보완에서만 분류·개념 단위·관계를 뺀다.
-- 반영된 보류가 없고 개념 단위만 다시 볼 때는 그 범위를 그대로 둔다.
-- 판단 문장은 바꾸지 않는다.

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
  v_applied boolean := false;
  v_fresh text[] := '{}'::text[];
begin
  select * into v_it from public.concept_review_job_items where job_id = p_job_id and pos = p_pos;
  if not found then
    return jsonb_build_object('scopes', '[]'::jsonb, 'created', '[]'::jsonb);
  end if;
  v_marks := public.concept_review_marks(v_it.concept_id);
  v_view := public.concept_review_job_hold_view(v_it.held_fixes);
  for v_s in select x from jsonb_array_elements(coalesce(v_view -> 'scopes', '[]'::jsonb)) x loop
    v_blocked := v_blocked || (v_s ->> 'scope');
    if v_s ->> 'status' = 'applied' then
      v_applied := true;
    end if;
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

  -- 이미 충족이거나 근거 미확인인 범위는 빼 둔 뒤, 반영된 보류가 있으면 빠진 필수 범위를 다시 넣는다.
  v_cs := public.concept_review_job_concept_state(v_it.concept_id, public.concept_review_pending_concepts());
  foreach v_scope in array v_scopes loop
    if (v_cs -> 'scopes' -> v_scope ->> 'state') in ('missing', 'recheck')
       and not (v_scope = any (v_fresh)) then
      v_fresh := v_fresh || v_scope;
    end if;
  end loop;
  if v_applied then
    foreach v_scope in array array['notation', 'meaning', 'foundation', 'placement']::text[] loop
      if (v_cs -> 'scopes' -> v_scope ->> 'state') in ('missing', 'recheck')
         and not (v_scope = any (v_fresh))
         and not public.concept_review_ref_scope_blocked(v_it.reason, v_it.revision, v_scope, v_marks) then
        v_fresh := v_fresh || v_scope;
      end if;
    end loop;
    if v_fresh && array['notation', 'meaning', 'foundation', 'placement']::text[] then
      select coalesce(array_agg(x.u order by x.n), '{}'::text[])
        into v_fresh
        from unnest(v_fresh) with ordinality as x(u, n)
       where x.u <> all (array['classification', 'unit', 'relations']::text[]);
    end if;
  end if;

  return jsonb_build_object('scopes', to_jsonb(v_fresh), 'created', v_created);
end;
$$;
