-- 보류 중이고 이미 카드에 연결된 범위는 제출에서 빼는 것이 기본이다.
-- 연결된 카드의 비교 지문이 지금과 다르고, 이 초안이 그 개념을 지금 지문으로 다시 담은 경우에만 연결만으로 빼지 않는다.
-- 항목 전체 버전, 외부 근거 공백, 비교 대상 누락, 초안에 남지 않은 옛 지문은 재검토로 보지 않는다.
-- 판 검사·비교 지문 검사·미해결 수정 보류는 그대로다. 중복 방지 키는 바꾸지 않는다.

create or replace function public.concept_review_job_scope_compared_refreshed(p_link jsonb, p_review jsonb)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_act public.ai_actions;
  v_item jsonb;
  v_i integer;
  v_changed integer := 0;
  v_e jsonb;
  v_id uuid;
  v_now text;
begin
  if jsonb_typeof(p_link) <> 'object' or jsonb_typeof(p_review) <> 'object' then
    return false;
  end if;
  if coalesce(p_link ->> 'item', '') !~ '^[0-9]+$' then
    return false;
  end if;
  v_i := (p_link ->> 'item')::integer;
  if v_i < 1 then
    return false;
  end if;
  select * into v_act from public.ai_actions where id = public.course_think_uuid(p_link ->> 'action_id');
  if not found or v_act.kind is distinct from 'concept_review_record' then
    return false;
  end if;
  if jsonb_typeof(v_act.payload -> 'items') <> 'array' then
    return false;
  end if;
  v_item := v_act.payload -> 'items' -> (v_i - 1);
  if v_item is null
     or (v_item ->> 'scope') is distinct from (p_review ->> 'scope')
     or (v_item ->> 'concept_id') is distinct from (p_review ->> 'concept_id') then
    return false;
  end if;
  for v_e in
    select e from jsonb_array_elements(coalesce(v_item -> 'compared', '[]'::jsonb)) e
  loop
    if not (v_e ? 'text') then
      continue;
    end if;
    v_id := public.course_think_uuid(v_e ->> 'id');
    if v_id is null then
      return false;
    end if;
    v_now := public.concept_review_text_mark(v_id);
    -- 비교 개념이 없거나, 바뀐 개념을 지금 지문으로 담지 않으면 재검토가 아니다.
    if v_now is null or v_now is distinct from (v_e ->> 'text') then
      if v_now is null or (p_review -> 'compared_text' ->> v_id::text) is distinct from v_now then
        return false;
      end if;
      v_changed := v_changed + 1;
    end if;
  end loop;
  return v_changed > 0;
end;
$$;

revoke all on function public.concept_review_job_scope_compared_refreshed(jsonb, jsonb) from public, anon, authenticated;

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
      -- 이미 연결된 범위는 다시 내지 않는다. 비교 지문이 바뀌어 그 개념을 지금 지문으로 다시 담은 초안만 예외다.
      if v_it.state = 'held' and coalesce(v_it.scope_cards, '{}'::jsonb) ? (v_r ->> 'scope')
         and not public.concept_review_job_scope_compared_refreshed(v_it.scope_cards -> (v_r ->> 'scope'), v_r) then
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

notify pgrst, 'reload schema';
