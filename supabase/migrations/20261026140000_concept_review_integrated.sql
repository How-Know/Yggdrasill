-- 20261026140000: 개념 검수 통합 3조건(표기·의미 / 초등 기초 개념 / 출처 기반 배치)과 고치기 카드 연결.
-- 20261023160000 · 20261026100000 · 20261026120000 은 운영에 반영됐으므로 고치지 않고 이어서 바꾼다.
--
-- 설계: docs/architecture/concept-library.md §4.8 "통합 검수"
--
-- 1) 검토 범위 둘을 더한다. 둘 다 같은 검토 기록·카드·승인 길을 쓴다.
--      foundation  필요한 초등 기초 개념이 라이브러리에 있는지(검색·후보 본문 비교). 지문은 text(대상 본문이 바뀌면 다시)이고,
--                  비교해 재사용한 개념이 지워져도 다시 확인한다.
--      placement   출처(책·학년·책 단원·쪽)와 지금 배치(과정·단원)를 보고 배치가 맞는지. 지문은 새 placement 지문.
--    revision 은 text-class-relations-placement 넷을 잇는다(예전 세 칸 revision 도 앞 세 범위에는 그대로 맞는다).
-- 2) 검토 기록에 detail(조건별 근거: 필요한 기초·검색어·후보·결정, 출처 확인 방식 등)과 fixes(문제 있음에 딸린 고치기 카드·항목)를 둔다.
--    문제 있음의 상태는 고치기 카드로 정한다: 대기 중이면 승인 대기, 모두 반영되면 다시 확인할 차례, 거절·일부 반영이면 사용자 확인.
-- 3) 통합 완료(concept_review_job_concept_state): notation·meaning·foundation·placement 네 범위의 최신 승인 기록이 지금 판과 맞고
--    모두 no_issue_found 이며, 다른 범위에도 지금 판의 문제 있음·비교 필요·확인 못 함·병합 필요가 없고, 이 개념이 든 대기 카드
--    (검토·개념 고치기·배치)가 없을 때만. 바뀐 범위만 다시 검수한다(todo).
-- 4) concept_review_job_targets: 목록 앞에서부터 통합 완료가 아닌 위치를 부족한 범위(todo)와 함께 내준다. 이미 상태가 있는
--    위치(reused·submitted·waiting·deferred)도 보완 대상으로 다시 찾는다. 사용자 확인이 필요한 위치·판이 그대로인 미결은 다시 내지 않는다.
-- 5) 저장 초안의 검토마다 fix(고치기 제안)를 둘 수 있고, 제출 때 고치기 카드(개념 고치기 한 장, 과정별 배치 카드)를 먼저 만들어
--    검토 카드 항목에 잇는다. 같은 이름 만들기가 다른 대기 카드에 있으면 새로 만들지 않고 그 카드를 가리킨다. 모두 한 트랜잭션이다.
-- 6) 묶음 읽기에 출처(인쇄 쪽·PDF 쪽을 나눠)·배치를 싣고, 과정·단원 목록과 기초 개념 후보 검색 RPC를 더한다.
-- 7) 상태: 통합 완료 수(progress_line)와 조건별 충족 수를 따로 센다. 저장값이 아니라 승인된 기록으로 매번 센다.

-- ─────────────────────────────────────────────────────────────────────────
-- 1) 검토 기록 표
-- ─────────────────────────────────────────────────────────────────────────

alter table public.concept_quality_reviews drop constraint if exists concept_quality_reviews_scope_check;
alter table public.concept_quality_reviews add constraint concept_quality_reviews_scope_check
  check (scope in ('notation', 'meaning', 'classification', 'unit', 'relations', 'foundation', 'placement'));

alter table public.concept_quality_reviews
  add column if not exists detail jsonb not null default '{}'::jsonb,
  add column if not exists fixes jsonb not null default '[]'::jsonb;

alter table public.concept_quality_reviews drop constraint if exists concept_quality_reviews_detail_chk;
alter table public.concept_quality_reviews add constraint concept_quality_reviews_detail_chk
  check (jsonb_typeof(detail) = 'object' and octet_length(detail::text) <= 12000);
alter table public.concept_quality_reviews drop constraint if exists concept_quality_reviews_fixes_chk;
alter table public.concept_quality_reviews add constraint concept_quality_reviews_fixes_chk
  check (jsonb_typeof(fixes) = 'array' and (outcome = 'issue_found' or jsonb_array_length(fixes) = 0));

-- ─────────────────────────────────────────────────────────────────────────
-- 2) 판 표시
-- ─────────────────────────────────────────────────────────────────────────

-- 출처(책·학년·책 단원·PDF 쪽·인쇄 쪽)와 살아 있는 배치(단원). 둘 중 하나가 바뀌면 배치를 다시 확인한다.
create or replace function public.concept_review_placement_mark(p_concept_id uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select md5(jsonb_build_array(
           coalesce((
             select jsonb_agg(jsonb_build_array(s.book_id, s.grade_label, s.unit_path, s.raw_page, s.display_page)
                              order by s.book_id, s.grade_label, s.raw_page)
               from public.concept_sources s where s.concept_id = p_concept_id
           ), '[]'::jsonb),
           coalesce((
             select jsonb_agg(a.course_unit_id order by a.course_unit_id)
               from public.concept_appearances a
               join public.course_map_units u on u.id = a.course_unit_id and u.archived_at is null
               join public.course_maps m on m.id = u.course_id and m.archived_at is null
              where a.concept_id = p_concept_id
           ), '[]'::jsonb)
         )::text);
$$;

create or replace function public.concept_review_marks(p_concept_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select case when exists (select 1 from public.concepts where id = p_concept_id) then jsonb_build_object(
    'text', public.concept_review_text_mark(p_concept_id),
    'class', public.concept_review_class_mark(p_concept_id),
    'relations', public.concept_review_relation_mark(p_concept_id),
    'placement', public.concept_review_placement_mark(p_concept_id),
    'statements', coalesce((
      select jsonb_agg(jsonb_build_object('id', s.id, 'version', s.version) order by s.role <> 'core', s.sort_order, s.created_at)
        from public.concept_statements s where s.concept_id = p_concept_id and s.version > 0
    ), '[]'::jsonb)
  ) end;
$$;

create or replace function public.concept_review_revision(p_marks jsonb)
returns text
language sql
immutable
as $$
  select case when p_marks is null then null
    else left(p_marks ->> 'text', 12) || '-' || left(p_marks ->> 'class', 12) || '-' || left(p_marks ->> 'relations', 12)
         || case when p_marks ? 'placement' then '-' || left(p_marks ->> 'placement', 12) else '' end end;
$$;

create or replace function public.concept_review_scope_mark(p_scope text)
returns text
language sql
immutable
as $$
  select case p_scope when 'classification' then 'class' when 'relations' then 'relations' when 'placement' then 'placement'
                      else 'text' end;
$$;

create or replace function public.concept_review_revision_part(p_revision text, p_scope text)
returns text
language sql
immutable
as $$
  select nullif(split_part(coalesce(btrim(p_revision), ''), '-',
                case public.concept_review_scope_mark(p_scope) when 'class' then 2 when 'relations' then 3
                                                               when 'placement' then 4 else 1 end), '');
$$;

-- 기록이 지금 판과 다른가. foundation 은 재사용한 기초 개념이 지워져도 다시 본다.
create or replace function public.concept_review_record_stale(r public.concept_quality_reviews, p_marks jsonb)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select r.mark is distinct from (p_marks ->> public.concept_review_scope_mark(r.scope))
      or (r.scope = 'foundation' and exists (
            select 1 from jsonb_array_elements(coalesce(r.compared, '[]'::jsonb)) e
             where not exists (select 1 from public.concepts c where c.id = public.course_think_uuid(e ->> 'id'))
          ));
$$;

-- 문제 있음에 딸린 고치기 카드 상태: none(없음) · proposed(하나라도 대기) · applied(모두 승인되고 그 항목이 반영됨) · rejected(거절·일부 반영).
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
begin
  if p_fixes is null or jsonb_typeof(p_fixes) <> 'array' or jsonb_array_length(p_fixes) = 0 then
    return 'none';
  end if;
  for v_f in select e from jsonb_array_elements(p_fixes) e loop
    select * into v_a from public.ai_actions where id = public.course_think_uuid(v_f ->> 'action_id');
    if not found then
      v_all := false;
    elsif v_a.status = 'proposed' then
      return 'proposed';
    elsif v_a.status <> 'applied' or exists (
      select 1 from jsonb_array_elements(coalesce(v_a.result -> 'items', '[]'::jsonb)) e
       where (e ->> 'i')::integer in (select (x #>> '{}')::integer from jsonb_array_elements(coalesce(v_f -> 'items', '[]'::jsonb)) x)
         and e ->> 'status' <> 'applied'
    ) then
      v_all := false;
    end if;
  end loop;
  return case when v_all then 'applied' else 'rejected' end;
end;
$$;

-- 기록이 있는 범위만: {범위: {record_id, outcome, reviewed_at, stale, records, fix}}.
create or replace function public.concept_review_scope_state(p_concept_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with m as (select public.concept_review_marks(p_concept_id) as marks),
  latest as (
    select distinct on (r.scope) r
      from public.concept_quality_reviews r
     where r.concept_id = p_concept_id
     order by r.scope, r.created_at desc, r.id desc
  ),
  counts as (
    select scope, count(*) as n from public.concept_quality_reviews where concept_id = p_concept_id group by scope
  )
  select coalesce(jsonb_object_agg((l.r).scope, jsonb_build_object(
           'record_id', (l.r).id, 'outcome', (l.r).outcome, 'reviewed_at', (l.r).created_at,
           'stale', public.concept_review_record_stale(l.r, m.marks),
           'records', c.n,
           'fix', case when (l.r).outcome = 'issue_found' then public.concept_review_fix_state((l.r).fixes) end
         )), '{}'::jsonb)
    from latest l
    cross join m
    join counts c on c.scope = (l.r).scope;
$$;

create or replace function public.concept_review_matches(p_state jsonb, p_review text, p_scope text)
returns boolean
language sql
immutable
as $$
  select exists (
    select 1
      from unnest(case when p_scope is null
                       then array['notation', 'meaning', 'classification', 'unit', 'relations', 'foundation', 'placement']
                       else array[p_scope] end) s
     where case p_review
       when 'unreviewed' then not (p_state ? s)
       when 'stale' then coalesce((p_state -> s ->> 'stale')::boolean, false)
       when 'not_current' then not (p_state ? s) or coalesce((p_state -> s ->> 'stale')::boolean, false)
       when 'has_issue' then coalesce(p_state -> s ->> 'outcome', '') in ('issue_found', 'needs_comparison', 'unverified', 'merge_needed')
       when 'merge_needed' then coalesce(p_state -> s ->> 'outcome', '') = 'merge_needed'
       else true
     end
  );
$$;

create or replace function public.concept_review_record_json(r public.concept_quality_reviews, p_marks jsonb)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', r.id, 'scope', r.scope, 'outcome', r.outcome,
    'checked', r.checked, 'findings', r.findings, 'basis', r.basis, 'unverified', r.unverified, 'follow_up', r.follow_up,
    'compared', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', e ->> 'id', 'name', e ->> 'name',
               'state', case when c.id is null then 'deleted'
                             when public.concept_review_text_mark(c.id) is distinct from e ->> 'text' then 'changed'
                             else 'same' end
             ) order by n)
        from jsonb_array_elements(r.compared) with ordinality as t(e, n)
        left join public.concepts c on c.id = public.course_think_uuid(e ->> 'id')
    ), '[]'::jsonb),
    'to_compare', r.to_compare,
    'detail', r.detail,
    'fixes', r.fixes,
    'fix_state', case when r.outcome = 'issue_found' then public.concept_review_fix_state(r.fixes) end,
    'revision', public.concept_review_revision(r.marks),
    'statements', coalesce(r.marks -> 'statements', '[]'::jsonb),
    'stale', public.concept_review_record_stale(r, p_marks),
    'origin', r.origin, 'action_id', r.action_id, 'reviewed_at', r.created_at
  );
$$;

-- 20261023160000 정의에서 범위 목록만 일곱으로.
create or replace function public.concept_review_status(p_concept_ids uuid[])
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_out jsonb := '[]'::jsonb;
  v_id uuid;
  v_c public.concepts;
  v_marks jsonb;
  v_scopes jsonb;
  v_scope text;
  v_latest public.concept_quality_reviews;
  v_earlier jsonb;
begin
  perform public.concept_review_assert_operator();
  if p_concept_ids is null or cardinality(p_concept_ids) = 0 or cardinality(p_concept_ids) > 20 then
    raise exception 'concept_review_bad_ids';
  end if;
  foreach v_id in array p_concept_ids loop
    select * into v_c from public.concepts where id = v_id;
    if not found then
      v_out := v_out || jsonb_build_array(jsonb_build_object('id', v_id, 'missing', true));
      continue;
    end if;
    v_marks := public.concept_review_marks(v_id);
    v_scopes := '{}'::jsonb;
    foreach v_scope in array array['notation', 'meaning', 'classification', 'unit', 'relations', 'foundation', 'placement'] loop
      select * into v_latest
        from public.concept_quality_reviews
       where concept_id = v_id and scope = v_scope
       order by created_at desc, id desc
       limit 1;
      if not found then
        v_scopes := v_scopes || jsonb_build_object(v_scope, null);
        continue;
      end if;
      select coalesce(jsonb_agg(jsonb_build_object(
               'outcome', h.outcome, 'reviewed_at', h.created_at, 'revision', public.concept_review_revision(h.marks)
             ) order by h.created_at desc, h.id desc), '[]'::jsonb)
        into v_earlier
        from (
          select * from public.concept_quality_reviews
           where concept_id = v_id and scope = v_scope and id <> v_latest.id
           order by created_at desc, id desc
           limit 5
        ) h;
      v_scopes := v_scopes || jsonb_build_object(v_scope, jsonb_build_object(
        'latest', public.concept_review_record_json(v_latest, v_marks),
        'earlier', v_earlier,
        'records', (select count(*) from public.concept_quality_reviews where concept_id = v_id and scope = v_scope)
      ));
    end loop;
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'id', v_id, 'name', v_c.name, 'revision', public.concept_review_revision(v_marks), 'scopes', v_scopes,
      'pending', coalesce((
        select jsonb_agg(jsonb_build_object('action_id', a.id, 'item', t.n, 'scope', t.e ->> 'scope') order by a.created_at, t.n)
          from public.ai_actions a
          cross join lateral jsonb_array_elements(
            case when jsonb_typeof(a.payload -> 'items') = 'array' then a.payload -> 'items' else '[]'::jsonb end
          ) with ordinality as t(e, n)
         where a.kind = 'concept_review_record' and a.status = 'proposed' and t.e ->> 'concept_id' = v_id::text
      ), '[]'::jsonb)
    ));
  end loop;
  return v_out;
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 3) 검토 카드: detail·fixes (20261023160000 정의에 범위 둘·근거·고치기 카드 연결 추가)
-- ─────────────────────────────────────────────────────────────────────────

-- detail: 객체, 12000바이트까지. 없으면 {}.
create or replace function public.concept_review_detail_clean(p jsonb)
returns jsonb
language plpgsql
immutable
as $$
begin
  if p is null or jsonb_typeof(p) = 'null' then
    return '{}'::jsonb;
  end if;
  if jsonb_typeof(p) <> 'object' then
    raise exception 'concept_review_bad_detail';
  end if;
  if octet_length(p::text) > 12000 then
    raise exception 'concept_review_detail_too_long';
  end if;
  return p;
end;
$$;

-- fixes: [{action_id, items: [항목 번호]}] 3개까지. 개념 고치기·배치 카드만, issue_found 에만.
create or replace function public.concept_review_fixes_clean(p jsonb, p_outcome text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_out jsonb := '[]'::jsonb;
  v_f jsonb;
  v_a public.ai_actions;
  v_items jsonb;
begin
  if p is null or jsonb_typeof(p) = 'null' or p = '[]'::jsonb then
    return '[]'::jsonb;
  end if;
  if jsonb_typeof(p) <> 'array' or jsonb_array_length(p) > 3 or p_outcome <> 'issue_found' then
    raise exception 'concept_review_bad_fixes';
  end if;
  for v_f in select e from jsonb_array_elements(p) e loop
    select * into v_a from public.ai_actions where id = public.course_think_uuid(v_f ->> 'action_id');
    if not found or v_a.kind not in ('concept_library_change', 'concept_placement_change') then
      raise exception 'concept_review_fix_not_found';
    end if;
    v_items := coalesce((
      select jsonb_agg(distinct (x #>> '{}')::integer)
        from jsonb_array_elements(case when jsonb_typeof(v_f -> 'items') = 'array' then v_f -> 'items' else '[]'::jsonb end) x
       where jsonb_typeof(x) = 'number'
         and (x #>> '{}')::integer between 1 and jsonb_array_length(coalesce(v_a.payload -> 'items', '[]'::jsonb))
    ), '[]'::jsonb);
    if jsonb_array_length(v_items) = 0 then
      raise exception 'concept_review_bad_fixes';
    end if;
    v_out := v_out || jsonb_build_array(jsonb_build_object('action_id', v_a.id, 'kind', v_a.kind, 'items', v_items));
  end loop;
  return v_out;
end;
$$;

-- p_payload {items: [{concept_id, revision, scope, outcome, checked, findings, basis, unverified, follow_up,
--                     compared_ids, to_compare_ids, detail, fixes}], reason}
create or replace function public.course_think_propose_review(p_conversation_id uuid, p_payload jsonb, p_reason text)
returns public.ai_actions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_items jsonb := p_payload -> 'items';
  v_item jsonb;
  v_i integer := 0;
  v_concept public.concepts;
  v_scope text;
  v_outcome text;
  v_key text;
  v_seen text[] := '{}'::text[];
  v_marks jsonb;
  v_part text;
  v_compared jsonb;
  v_to jsonb;
  v_fixes jsonb;
  v_prev public.concept_quality_reviews;
  v_clean jsonb := '[]'::jsonb;
  v_preview jsonb := '[]'::jsonb;
  v_counts jsonb := '{"no_issue_found": 0, "issue_found": 0, "needs_comparison": 0, "unverified": 0, "merge_needed": 0}'::jsonb;
  v_out public.ai_actions;
begin
  if v_items is null or jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
    raise exception 'concept_review_no_items';
  end if;
  if jsonb_array_length(v_items) > 20 then
    raise exception 'concept_review_too_many';
  end if;

  for v_item in select e from jsonb_array_elements(v_items) e loop
    v_i := v_i + 1;
    begin
      if jsonb_typeof(v_item) <> 'object' then
        raise exception 'concept_review_bad_op';
      end if;
      select * into v_concept from public.concepts where id = public.course_think_uuid(v_item ->> 'concept_id');
      if not found then
        raise exception 'concept_review_concept_not_found';
      end if;
      v_scope := v_item ->> 'scope';
      if v_scope is null or v_scope not in ('notation', 'meaning', 'classification', 'unit', 'relations', 'foundation', 'placement') then
        raise exception 'concept_review_bad_scope';
      end if;
      v_outcome := v_item ->> 'outcome';
      if v_outcome is null or v_outcome not in ('no_issue_found', 'issue_found', 'needs_comparison', 'unverified', 'merge_needed') then
        raise exception 'concept_review_bad_outcome';
      end if;
      if v_outcome = 'merge_needed' and v_scope <> 'unit' then
        raise exception 'concept_review_merge_scope';
      end if;
      v_key := v_concept.id::text || ':' || v_scope;
      if v_key = any (v_seen) then
        raise exception 'concept_review_duplicate';
      end if;
      v_seen := v_seen || v_key;

      v_marks := public.concept_review_marks(v_concept.id);
      v_part := public.concept_review_revision_part(v_item ->> 'revision', v_scope);
      if v_part is null then
        raise exception 'concept_review_revision_required';
      end if;
      if v_part <> left(v_marks ->> public.concept_review_scope_mark(v_scope), 12) then
        raise exception 'concept_review_stale';
      end if;

      v_compared := public.concept_review_refs(v_item -> 'compared_ids', v_concept.id);
      v_to := (
        select coalesce(jsonb_agg(e - 'text' order by n), '[]'::jsonb)
          from jsonb_array_elements(public.concept_review_refs(v_item -> 'to_compare_ids', v_concept.id))
               with ordinality as t(e, n)
      );
      v_fixes := public.concept_review_fixes_clean(v_item -> 'fixes', v_outcome);

      v_clean := v_clean || jsonb_build_array(jsonb_build_object(
        'concept_id', v_concept.id, 'scope', v_scope, 'outcome', v_outcome,
        'checked', public.concept_review_text(v_item ->> 'checked', 1000, true),
        'findings', public.concept_review_text(v_item ->> 'findings', 2000, true),
        'basis', public.concept_review_text(v_item ->> 'basis', 1000, true),
        'unverified', public.concept_review_text(v_item ->> 'unverified', 1000, false),
        'follow_up', public.concept_review_text(v_item ->> 'follow_up', 1000, false),
        'compared', v_compared, 'to_compare', v_to, 'marks', v_marks,
        'detail', public.concept_review_detail_clean(v_item -> 'detail'), 'fixes', v_fixes
      ));

      select * into v_prev
        from public.concept_quality_reviews
       where concept_id = v_concept.id and scope = v_scope
       order by created_at desc, id desc
       limit 1;
      v_preview := v_preview || jsonb_build_array((v_clean -> -1) - 'marks' - 'compared' || jsonb_build_object(
        'i', v_i, 'name', v_concept.name,
        'type', (
          select t.name from public.concept_type_links l join public.concept_types t on t.id = l.type_id
           where l.concept_id = v_concept.id
        ),
        'folder', to_jsonb(public.concept_folder_path(v_concept.main_category_id)),
        'compared', (select coalesce(jsonb_agg(e - 'text' order by n), '[]'::jsonb)
                       from jsonb_array_elements(v_compared) with ordinality as t(e, n)),
        'revision', public.concept_review_revision(v_marks),
        'statements', v_marks -> 'statements',
        'previous', case when v_prev.id is null then null else jsonb_build_object(
          'outcome', v_prev.outcome, 'reviewed_at', v_prev.created_at,
          'stale', public.concept_review_record_stale(v_prev, v_marks)
        ) end,
        'pending_elsewhere', (
          select count(*)
            from public.ai_actions a
            cross join lateral jsonb_array_elements(
              case when jsonb_typeof(a.payload -> 'items') = 'array' then a.payload -> 'items' else '[]'::jsonb end
            ) x
           where a.kind = 'concept_review_record' and a.status = 'proposed'
             and x ->> 'concept_id' = v_concept.id::text and x ->> 'scope' = v_scope
        )
      ));
      v_prev := null;
      v_counts := jsonb_set(v_counts, array[v_outcome], to_jsonb((v_counts ->> v_outcome)::integer + 1));
    exception when others then
      raise exception 'concept_review_bad_item:%:%', v_i, sqlerrm;
    end;
  end loop;

  insert into public.ai_actions (conversation_id, kind, payload, preview)
  values (
    p_conversation_id, 'concept_review_record',
    jsonb_build_object('items', v_clean, 'reason', p_reason),
    jsonb_build_object('title', '개념 검토 기록', 'items', v_preview, 'counts', v_counts, 'reason', p_reason)
  )
  returning * into v_out;
  return v_out;
end;
$$;

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

  if v_applied = 0 then
    if v_failed = 0 then
      raise exception 'course_think_nothing_selected';
    end if;
    raise exception 'course_think_all_failed:%', v_first;
  end if;
  return jsonb_build_object('items', v_res, 'applied', v_applied, 'failed', v_failed, 'skipped', v_skipped);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 4) 통합 상태
-- ─────────────────────────────────────────────────────────────────────────

-- 승인을 기다리는 검토·개념 고치기·배치 카드에 든 개념 id(서술 고치기는 그 서술의 개념, 옮기기·빼기는 그 배치의 개념).
create or replace function public.concept_review_pending_concepts()
returns uuid[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(distinct x.id) filter (where x.id is not null), '{}'::uuid[])
    from (
      select coalesce(
               public.course_think_uuid(e ->> 'concept_id'),
               (select s.concept_id from public.concept_statements s where s.id = public.course_think_uuid(e ->> 'statement_id')),
               (select ap.concept_id from public.concept_appearances ap where ap.id = public.course_think_uuid(e ->> 'placement_id'))
             ) as id
        from public.ai_actions a
        cross join lateral jsonb_array_elements(
          case when jsonb_typeof(a.payload -> 'items') = 'array' then a.payload -> 'items' else '[]'::jsonb end
        ) e
       where a.status = 'proposed'
         and a.kind in ('concept_review_record', 'concept_library_change', 'concept_placement_change')
    ) x;
$$;

-- 개념 하나의 통합 상태. state: missing · pending(대기 카드에 있거나 고치기 카드 승인 대기) · todo(검수할 범위가 있음) ·
-- open(사용자 확인이 필요한 기록만 남음) · complete(통합 완료).
-- 범위 상태: met(지금 판·문제 못 찾음) · missing(필수인데 기록 없음) · recheck(내용이 바뀌었거나 고치기가 반영돼 다시 확인) ·
-- pending(고치기 카드 승인 대기) · issue(고치기 거절·일부 반영) · open(비교 필요·확인 못 함·병합 필요).
-- 필수 넷(notation·meaning·foundation·placement)은 기록이 없으면 missing, 나머지 셋은 기록이 있을 때만 본다.
-- 고치기 카드가 없는 예전 문제 있음 기록은 필수 범위면 다시 검수해 고치기 카드를 내고(recheck), 아니면 사용자 확인(issue)이다.
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
      v_st := case v_fix when 'proposed' then 'pending' when 'applied' then 'recheck'
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

-- ─────────────────────────────────────────────────────────────────────────
-- 5) 다음 대상(보완 포함)
-- ─────────────────────────────────────────────────────────────────────────

-- 사용자가 승인 때 뺀 항목이 있는 제출 위치인가(그 판이 그대로면 다시 내지 않는다).
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
       and (e ->> 'i')::integer = any (coalesce(p_items, '{}'::integer[])) and e ->> 'status' <> 'applied'
  );
$$;

-- p_at 뒤에 이 개념의 검토 기록이 새로 남았거나, 기록에 딸린 고치기 카드가 승인·거절됐는가.
create or replace function public.concept_review_changed_since(p_concept_id uuid, p_at timestamptz)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_at is null
      or exists (select 1 from public.concept_quality_reviews q where q.concept_id = p_concept_id and q.created_at > p_at)
      or exists (
        select 1
          from public.concept_quality_reviews q
          cross join lateral jsonb_array_elements(q.fixes) f
          join public.ai_actions a on a.id = public.course_think_uuid(f ->> 'action_id')
         where q.concept_id = p_concept_id and a.decided_at > p_at
      );
$$;

-- 목록 앞에서부터 통합 완료가 아닌 위치를 p_count(1~50)개, 부족한 범위(todo)와 함께 내준다.
-- 상태가 없는 위치: 완료는 reused, 지워짐은 missing, 대기 카드에 있음은 waiting, 사용자 확인만 남음은 deferred 로 저장하고 넘어간다.
-- 상태가 있는 위치(reused·submitted·waiting·deferred·failed)도 지금 todo 면 보완 대상으로 다시 내준다(supplement).
-- 다시 내지 않는 것: 저장만 된 초안(drafted), 승인 대기 카드에 든 위치, 미결·다시 판단 안 하는 실패, 사용자가 거절했거나
-- 승인 때 뺀 위치 — 단 판이 바뀌었거나 그 뒤 새 검토 기록·고치기 카드 결정이 있으면 다시 낸다.
-- 판단 실패(judge_*·판 바뀜)는 batch_begin 의 retry 로 따로 나간다.
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

-- ─────────────────────────────────────────────────────────────────────────
-- 6) 저장: 범위 일곱·근거(detail)·고치기 제안(fix)
-- ─────────────────────────────────────────────────────────────────────────

-- 고치기 제안 하나를 검사해 정리한다. issue_found 에만, 필수 넷(notation·meaning·foundation·placement)의 문제 있음에는 반드시.
--   notation·meaning      {kind: library, ops: [{op: edit, name?, content?}]}             이 개념만
--   classification        {kind: library, ops: [{op: edit, type?, folder?}]}              이 개념만
--   foundation            {kind: library, ops: [{op: create, name, type, folder, content, evidence?}] 1~3개}  배치하지 않는다
--   placement             {kind: placement, ops: [{op: place, unit_id, basis, evidence} | {op: move, placement_id, unit_id, evidence}
--                                                 | {op: remove, placement_id, evidence}] 1~5개}  이 개념의 배치만
create or replace function public.concept_review_fix_clean(p_scope text, p_outcome text, p_fix jsonb, p_concept uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_kind text;
  v_ops jsonb := '[]'::jsonb;
  o jsonb;
  v_op text;
  v_ev text;
  v_n integer;
  v_row public.concept_appearances;
begin
  if p_fix is null or jsonb_typeof(p_fix) = 'null' then
    if p_outcome = 'issue_found' and p_scope in ('notation', 'meaning', 'foundation', 'placement') then
      raise exception 'concept_review_fix_required';
    end if;
    return null;
  end if;
  if jsonb_typeof(p_fix) <> 'object' or p_outcome <> 'issue_found' or jsonb_typeof(p_fix -> 'ops') is distinct from 'array' then
    raise exception 'concept_review_bad_fix';
  end if;
  v_kind := p_fix ->> 'kind';
  v_n := jsonb_array_length(p_fix -> 'ops');
  if v_n < 1 or v_n > (case p_scope when 'foundation' then 3 when 'placement' then 5 else 1 end) then
    raise exception 'concept_review_bad_fix';
  end if;
  for o in select x from jsonb_array_elements(p_fix -> 'ops') x loop
    if jsonb_typeof(o) <> 'object' then
      raise exception 'concept_review_bad_fix';
    end if;
    o := jsonb_strip_nulls(o);
    v_op := o ->> 'op';
    v_ev := nullif(btrim(coalesce(o ->> 'evidence', '')), '');
    if char_length(coalesce(v_ev, '')) > 300 then
      raise exception 'concept_review_bad_fix';
    end if;
    if p_scope in ('notation', 'meaning', 'classification') then
      if v_kind <> 'library' or v_op <> 'edit' then
        raise exception 'concept_review_bad_fix';
      end if;
      if p_scope = 'classification' then
        if not (o ?| array['type', 'folder']) or o ?| array['name', 'content'] then
          raise exception 'concept_review_bad_fix';
        end if;
      elsif not (o ?| array['name', 'content']) or o ?| array['type', 'folder'] then
        raise exception 'concept_review_bad_fix';
      end if;
      v_ops := v_ops || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
        'op', 'edit', 'concept_id', p_concept, 'name', o -> 'name', 'content', o -> 'content',
        'type', o -> 'type', 'folder', o -> 'folder'
      )));
    elsif p_scope = 'foundation' then
      if v_kind <> 'library' or v_op <> 'create' then
        raise exception 'concept_review_bad_fix';
      end if;
      if nullif(btrim(coalesce(o ->> 'place_unit_id', '')), '') is not null then
        raise exception 'concept_review_fix_no_place';
      end if;
      if nullif(btrim(coalesce(o ->> 'name', '')), '') is null or nullif(btrim(coalesce(o ->> 'content', '')), '') is null then
        raise exception 'concept_review_bad_fix';
      end if;
      perform public.concept_think_type(o ->> 'type');
      perform public.concept_think_folder_check(o -> 'folder');
      v_ops := v_ops || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
        'op', 'create', 'name', btrim(o ->> 'name'), 'type', o -> 'type', 'folder', o -> 'folder',
        'content', o -> 'content', 'evidence', to_jsonb(v_ev)
      )));
    elsif p_scope = 'placement' then
      if v_kind <> 'placement' or v_op not in ('place', 'move', 'remove') then
        raise exception 'concept_review_bad_fix';
      end if;
      if v_ev is null then
        raise exception 'course_placement_evidence_required';
      end if;
      if v_op in ('place', 'move') and not exists (
        select 1 from public.course_map_units u join public.course_maps m on m.id = u.course_id
         where u.id = public.course_think_uuid(o ->> 'unit_id') and u.archived_at is null and m.archived_at is null
      ) then
        raise exception 'course_placement_unit_not_found';
      end if;
      if v_op = 'place' then
        if coalesce(o ->> 'basis', '') not in ('source', 'judgment') then
          raise exception 'course_placement_bad_basis';
        end if;
        v_ops := v_ops || jsonb_build_array(jsonb_build_object(
          'op', 'place', 'concept_id', p_concept, 'unit_id', public.course_think_uuid(o ->> 'unit_id'),
          'basis', o ->> 'basis', 'evidence', v_ev
        ));
      else
        select * into v_row from public.concept_appearances where id = public.course_think_uuid(o ->> 'placement_id');
        if not found or v_row.concept_id <> p_concept or v_row.course_unit_id is null then
          raise exception 'concept_review_fix_not_own';
        end if;
        v_ops := v_ops || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
          'op', v_op, 'placement_id', v_row.id,
          'unit_id', case when v_op = 'move' then to_jsonb(public.course_think_uuid(o ->> 'unit_id')) end,
          'evidence', v_ev
        )));
      end if;
    else
      raise exception 'concept_review_bad_fix';
    end if;
  end loop;
  return jsonb_build_object('kind', v_kind, 'ops', v_ops);
end;
$$;

-- 20261026100000 정의에 범위 둘·detail·fix 를 더한다. 나머지 규칙(임대·판·대기·끝난 위치·거절된 같은 초안)은 같다.
-- reviews [{scope, outcome, checked, findings, basis, unverified, follow_up, compared_ids, to_compare_ids, detail, fix}]
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

      v_hash := md5(jsonb_build_array(v_state, v_rev, v_draft, v_next, v_reason, v_unread, v_complete)::text);
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
        next_action, reason, action_id, action_items, gen, updated_by, updated_at
      )
      values (
        p_job_id, v_pos, v_cid, v_state, v_rev, v_complete, v_unread, v_draft, v_version, v_hash,
        v_next, v_reason, null, null, v_job.lease_gen, auth.uid(), now()
      )
      on conflict (job_id, pos) do update
        set state = excluded.state, revision = excluded.revision, read_complete = excluded.read_complete,
            unread = excluded.unread, draft = excluded.draft, draft_version = excluded.draft_version,
            draft_hash = excluded.draft_hash, next_action = excluded.next_action, reason = excluded.reason,
            action_id = case when excluded.state = 'drafted' or excluded.draft_version <> concept_review_job_items.draft_version
                             then null else concept_review_job_items.action_id end,
            action_items = case when excluded.state = 'drafted' or excluded.draft_version <> concept_review_job_items.draft_version
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

-- ─────────────────────────────────────────────────────────────────────────
-- 7) 제출: 고치기 카드 먼저, 검토 카드에 잇기
-- ─────────────────────────────────────────────────────────────────────────

-- 고르고 있는 위치들 [{pos, reviews}] 의 고치기 제안을 카드 단위로 모은다.
--   lib: 개념 고치기 카드 항목(같은 개념 고치기는 하나로 합치고, 같은 이름 만들기는 하나만), lib_pos: 그 카드에 걸린 위치
--   courses: {과정 id: 배치 항목}, course_pos: {과정 id: 위치}
--   refs: {"위치:검토 번호": {"lib" | "pl:<과정 id>" | "ext:<대기 카드 id>": [항목 번호]}}
-- 다른 대기 카드에 같은 이름 만들기가 있으면 새로 넣지 않고 그 카드(ext)를 가리킨다.
create or replace function public.concept_review_job_fix_plan(p_sel jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_lib jsonb := '[]'::jsonb;
  v_lib_pos jsonb := '[]'::jsonb;
  v_keys jsonb := '{}'::jsonb;
  v_courses jsonb := '{}'::jsonb;
  v_course_pos jsonb := '{}'::jsonb;
  v_refs jsonb := '{}'::jsonb;
  v_e jsonb;
  v_r jsonb;
  v_k integer;
  o jsonb;
  v_pos integer;
  v_key text;
  v_idx integer;
  v_course uuid;
  v_card text;
  v_ref text;
  v_ext_id uuid;
  v_ext_n integer;
begin
  for v_e in select x from jsonb_array_elements(p_sel) x loop
    v_pos := (v_e ->> 'pos')::integer;
    for v_r, v_k in select x, n::integer from jsonb_array_elements(v_e -> 'reviews') with ordinality t(x, n) loop
      continue when jsonb_typeof(v_r -> 'fix') is distinct from 'object';
      v_ref := v_pos || ':' || v_k;
      for o in select x from jsonb_array_elements(v_r -> 'fix' -> 'ops') x loop
        if v_r -> 'fix' ->> 'kind' = 'library' then
          v_key := case o ->> 'op' when 'edit' then 'edit:' || (o ->> 'concept_id') else 'create:' || lower(btrim(o ->> 'name')) end;
          v_ext_id := null;
          v_ext_n := null;
          if o ->> 'op' = 'create' and not (v_keys ? v_key) then
            select a.id, t.n::integer into v_ext_id, v_ext_n
              from public.ai_actions a
              cross join lateral jsonb_array_elements(
                case when jsonb_typeof(a.payload -> 'items') = 'array' then a.payload -> 'items' else '[]'::jsonb end
              ) with ordinality as t(x, n)
             where a.kind = 'concept_library_change' and a.status = 'proposed' and t.x ->> 'op' = 'create'
               and lower(btrim(t.x ->> 'name')) = lower(btrim(o ->> 'name'))
             order by a.created_at, t.n
             limit 1;
          end if;
          if v_ext_id is not null then
            v_card := 'ext:' || v_ext_id;
            v_idx := v_ext_n;
          else
            v_card := 'lib';
            if v_keys ? v_key then
              v_idx := (v_keys ->> v_key)::integer;
              if o ->> 'op' = 'edit' then
                v_lib := jsonb_set(v_lib, array[(v_idx - 1)::text], (v_lib -> (v_idx - 1)) || o);
              end if;
            else
              v_lib := v_lib || jsonb_build_array(o);
              v_idx := jsonb_array_length(v_lib);
              v_keys := v_keys || jsonb_build_object(v_key, v_idx);
            end if;
            if not (v_lib_pos @> to_jsonb(v_pos)) then
              v_lib_pos := v_lib_pos || to_jsonb(v_pos);
            end if;
          end if;
        else
          v_course := case o ->> 'op'
            when 'remove' then (
              select u.course_id from public.concept_appearances a join public.course_map_units u on u.id = a.course_unit_id
               where a.id = public.course_think_uuid(o ->> 'placement_id')
            )
            else (select u.course_id from public.course_map_units u where u.id = public.course_think_uuid(o ->> 'unit_id'))
          end;
          -- 단원·배치가 그사이 없어졌으면 없는 과정으로 모아 카드 만들기에서 거부되게 한다(그 위치만 빠진다).
          v_course := coalesce(v_course, '00000000-0000-0000-0000-000000000000'::uuid);
          v_card := 'pl:' || v_course;
          v_courses := jsonb_set(v_courses, array[v_course::text], coalesce(v_courses -> v_course::text, '[]'::jsonb) || jsonb_build_array(o));
          v_idx := jsonb_array_length(v_courses -> v_course::text);
          if not (coalesce(v_course_pos -> v_course::text, '[]'::jsonb) @> to_jsonb(v_pos)) then
            v_course_pos := jsonb_set(v_course_pos, array[v_course::text],
                                      coalesce(v_course_pos -> v_course::text, '[]'::jsonb) || to_jsonb(v_pos));
          end if;
        end if;
        v_refs := jsonb_set(v_refs, array[v_ref], coalesce(v_refs -> v_ref, '{}'::jsonb));
        v_refs := jsonb_set(v_refs, array[v_ref, v_card],
                            coalesce(v_refs -> v_ref -> v_card, '[]'::jsonb) || to_jsonb(v_idx));
      end loop;
    end loop;
  end loop;
  return jsonb_build_object('lib', v_lib, 'lib_pos', v_lib_pos, 'courses', v_courses, 'course_pos', v_course_pos, 'refs', v_refs);
end;
$$;

drop function if exists public.concept_review_job_submit(uuid, bigint, uuid, text);

-- drafted 위치를 순서대로 모아 검토 카드 한 장과 그에 딸린 고치기 카드(개념 고치기 한 장·과정별 배치 카드)를 한 트랜잭션에서 낸다.
-- 검토 20개·내용 45000바이트·개념 고치기 20개·과정별 배치 50개·이번에 낼 수 있는 카드 장수(p_max_cards, 대기 한도)까지.
-- 고치기 카드 항목이 거부되면(이름·폴더·단원 오류 등) 그 위치를 failed(fix_invalid) 로 돌리고 나머지로 다시 만든다.
-- 멱등 키 = 작업 + 위치:초안 판. 같은 키·같은 내용이면 이미 낸 카드들을 돌려주고, 같은 키·다른 내용이면 충돌이다.
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
  v_sel jsonb := '[]'::jsonb;
  v_try jsonb;
  v_plan jsonb;
  v_n_reviews integer := 0;
  v_add integer;
  v_cards integer;
  v_failed jsonb := '[]'::jsonb;
  v_blocked jsonb := '[]'::jsonb;
  v_positions integer[];
  v_versions text[];
  v_key text;
  v_hash text;
  v_link public.concept_review_job_cards;
  v_act public.ai_actions;
  v_lib public.ai_actions;
  v_fix_acts jsonb;
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

  for v_it in select * from public.concept_review_job_items where job_id = p_job_id and state = 'drafted' order by pos for update loop
    v_bad := null;
    v_marks := public.concept_review_marks(v_it.concept_id);
    if v_marks is null then
      v_bad := 'concept_review_concept_not_found';
    end if;
    for v_r in select x from jsonb_array_elements(v_it.draft) x loop
      exit when v_bad is not null;
      if public.concept_review_revision_part(v_r ->> 'revision', v_r ->> 'scope')
         is distinct from left(v_marks ->> public.concept_review_scope_mark(v_r ->> 'scope'), 12) then
        v_bad := 'concept_review_stale';
      elsif exists (
        select 1 from jsonb_each_text(coalesce(v_r -> 'compared_text', '{}'::jsonb)) c
         where public.concept_review_text_mark(c.key::uuid) is distinct from c.value
      ) then
        v_bad := 'concept_review_compared_changed';
      end if;
    end loop;
    if v_bad is not null then
      update public.concept_review_job_items
         set state = 'failed', reason = v_bad, next_action = '다시 읽고 판단해 새 초안을 저장한다', updated_at = now(), gen = v_job.lease_gen
       where job_id = p_job_id and pos = v_it.pos;
      v_failed := v_failed || jsonb_build_array(jsonb_build_object('position', v_it.pos, 'code', v_bad));
      continue;
    end if;
    if exists (
      select 1
        from public.ai_actions a
        cross join lateral jsonb_array_elements(
          case when jsonb_typeof(a.payload -> 'items') = 'array' then a.payload -> 'items' else '[]'::jsonb end
        ) x
        join jsonb_array_elements(v_it.draft) d on d ->> 'scope' = x ->> 'scope'
       where a.kind = 'concept_review_record' and a.status = 'proposed' and x ->> 'concept_id' = v_it.concept_id::text
         and not exists (select 1 from public.concept_review_job_cards jc where jc.job_id = p_job_id and jc.action_id = a.id)
    ) then
      v_blocked := v_blocked || jsonb_build_array(jsonb_build_object('position', v_it.pos, 'code', 'pending_elsewhere'));
      continue;
    end if;
    v_add := jsonb_array_length(v_it.draft);
    v_try := v_sel || jsonb_build_array(jsonb_build_object(
      'pos', v_it.pos, 'version', v_it.draft_version, 'concept_id', v_it.concept_id, 'reviews', v_it.draft
    ));
    v_plan := public.concept_review_job_fix_plan(v_try);
    v_cards := 1 + case when jsonb_array_length(v_plan -> 'lib') > 0 then 1 else 0 end
                 + (select count(*) from jsonb_object_keys(v_plan -> 'courses'));
    exit when v_n_reviews + v_add > 20
           or octet_length((select jsonb_agg(e -> 'reviews') from jsonb_array_elements(v_try) e)::text) > 45000
           or jsonb_array_length(v_plan -> 'lib') > 20
           or exists (select 1 from jsonb_each(v_plan -> 'courses') c where jsonb_array_length(c.value) > 50)
           or v_cards > v_room;
    v_sel := v_try;
    v_n_reviews := v_n_reviews + v_add;
  end loop;

  if jsonb_array_length(v_sel) = 0 then
    return jsonb_build_object('submitted', false, 'failed', v_failed, 'blocked', v_blocked, 'room', v_room);
  end if;

  -- 고치기 카드를 만든다. 거부된 항목의 위치는 빼고 다시 만든다(실패한 시도는 되돌려진다).
  loop
    v_round := v_round + 1;
    v_positions := array(select (e ->> 'pos')::integer from jsonb_array_elements(v_sel) e);
    v_versions := array(select (e ->> 'pos') || ':' || (e ->> 'version') from jsonb_array_elements(v_sel) e);
    v_key := md5(p_job_id::text || '|' || array_to_string(v_versions, ','));
    -- 내용 지문은 초안의 검토(비교 지문 뺌) 그대로다. 고치기 제안이 없는 예전 초안이면 예전 제출의 지문과 같다.
    v_hash := md5(coalesce((
      select jsonb_agg(y - 'compared_text' order by n, m)
        from jsonb_array_elements(v_sel) with ordinality as e(x, n)
        cross join lateral jsonb_array_elements(x -> 'reviews') with ordinality as d(y, m)
    ), '[]'::jsonb)::text);
    select * into v_link from public.concept_review_job_cards where job_id = p_job_id and idem_key = v_key;
    if found then
      if v_link.content_hash <> v_hash then
        raise exception 'concept_review_job_conflict';
      end if;
      select * into v_act from public.ai_actions where id = v_link.action_id;
      return jsonb_build_object(
        'submitted', true, 'existing', true, 'action', to_jsonb(v_act), 'positions', to_jsonb(v_link.positions),
        'fix_actions', coalesce((
          select jsonb_agg(to_jsonb(a) order by jc.created_at)
            from public.concept_review_job_cards jc join public.ai_actions a on a.id = jc.action_id
           where jc.job_id = p_job_id and jc.idem_key like v_key || ':%'
        ), '[]'::jsonb),
        'failed', v_failed, 'blocked', v_blocked
      );
    end if;
    v_plan := public.concept_review_job_fix_plan(v_sel);
    v_ids := '{}'::jsonb;
    v_fix_acts := '[]'::jsonb;
    v_stage := null;
    begin
      if jsonb_array_length(v_plan -> 'lib') > 0 then
        v_stage := 'lib';
        v_lib := public.course_think_propose_library(
          p_conversation_id, jsonb_build_object('items', v_plan -> 'lib', 'reason', v_reason), v_reason
        );
        v_ids := v_ids || jsonb_build_object('lib', v_lib.id);
        v_fix_acts := v_fix_acts || jsonb_build_array(to_jsonb(v_lib));
      end if;
      for v_course in select k from jsonb_object_keys(v_plan -> 'courses') k order by k loop
        v_stage := 'pl:' || v_course;
        v_lib := public.course_think_propose_placement(
          p_conversation_id,
          jsonb_build_object('course_id', v_course, 'items', v_plan -> 'courses' -> v_course, 'reason', v_reason),
          v_reason
        );
        v_ids := v_ids || jsonb_build_object('pl:' || v_course, v_lib.id);
        v_fix_acts := v_fix_acts || jsonb_build_array(to_jsonb(v_lib));
      end loop;
      v_stage := null;
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
        return jsonb_build_object('submitted', false, 'failed', v_failed, 'blocked', v_blocked, 'room', v_room);
      end if;
      continue;
    end;
    exit;
  end loop;

  -- 검토 카드 항목: 초안의 검토 + 고치기 카드 연결(fixes)
  v_items := '[]'::jsonb;
  v_map := '{}'::jsonb;
  for v_e in select x from jsonb_array_elements(v_sel) x loop
    v_pos := (v_e ->> 'pos')::integer;
    for v_r, v_k in select x, n::integer from jsonb_array_elements(v_e -> 'reviews') with ordinality t(x, n) loop
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

  v_act := public.course_think_propose_review(p_conversation_id, jsonb_build_object('items', v_items, 'reason', v_reason), v_reason);
  insert into public.concept_review_job_cards (job_id, action_id, idem_key, content_hash, positions, origin_conversation_id)
  values (p_job_id, v_act.id, v_key, v_hash, v_positions, p_conversation_id);
  if v_ids ? 'lib' then
    insert into public.concept_review_job_cards (job_id, action_id, idem_key, content_hash, positions, origin_conversation_id)
    values (
      p_job_id, (v_ids ->> 'lib')::uuid, v_key || ':lib', md5((v_plan -> 'lib')::text),
      array(select (x #>> '{}')::integer from jsonb_array_elements(v_plan -> 'lib_pos') x), p_conversation_id
    );
  end if;
  for v_course in select k from jsonb_object_keys(v_plan -> 'courses') k loop
    insert into public.concept_review_job_cards (job_id, action_id, idem_key, content_hash, positions, origin_conversation_id)
    values (
      p_job_id, (v_ids ->> ('pl:' || v_course))::uuid, v_key || ':pl:' || v_course, md5((v_plan -> 'courses' -> v_course)::text),
      array(select (x #>> '{}')::integer from jsonb_array_elements(v_plan -> 'course_pos' -> v_course) x), p_conversation_id
    );
  end loop;
  foreach v_pos in array v_positions loop
    update public.concept_review_job_items
       set state = 'submitted', action_id = v_act.id,
           action_items = array(select (x #>> '{}')::integer from jsonb_array_elements(v_map -> v_pos::text) x),
           gen = v_job.lease_gen, updated_at = now()
     where job_id = p_job_id and pos = v_pos;
  end loop;
  update public.concept_review_jobs set last_progress_at = now(), updated_at = now() where id = p_job_id;
  return jsonb_build_object(
    'submitted', true, 'existing', false, 'action', to_jsonb(v_act), 'fix_actions', v_fix_acts,
    'positions', to_jsonb(v_positions), 'failed', v_failed, 'blocked', v_blocked
  );
end;
$$;

-- 20261026100000 정의에서 작업에 이어진 고치기 카드(개념 고치기·배치)도 함께 옮긴다.
create or replace function public.concept_review_job_cards_here(p_job_id uuid, p_gen bigint, p_conversation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job public.concept_review_jobs;
  v_walk public.concept_review_walks;
  v_a public.ai_actions;
  v_ids uuid[];
  v_moved jsonb := '[]'::jsonb;
  v_conflicts jsonb := '[]'::jsonb;
  v_linked boolean;
begin
  v_job := public.concept_review_job_lock(p_job_id, p_gen);
  if not exists (select 1 from public.ai_conversations where id = p_conversation_id) then
    raise exception 'conversation_not_found' using errcode = 'P0002';
  end if;
  select * into v_walk from public.concept_review_walks where id = v_job.walk_id;
  for v_a in
    select * from public.ai_actions a
     where a.status = 'proposed'
       and (a.kind = 'concept_review_record'
            or exists (select 1 from public.concept_review_job_cards jc where jc.job_id = p_job_id and jc.action_id = a.id))
     order by a.created_at
     for update
  loop
    v_linked := exists (select 1 from public.concept_review_job_cards where job_id = p_job_id and action_id = v_a.id);
    if not v_linked then
      v_ids := array(
        select public.course_think_uuid(x ->> 'concept_id')
          from jsonb_array_elements(case when jsonb_typeof(v_a.payload -> 'items') = 'array' then v_a.payload -> 'items' else '[]'::jsonb end) x
      );
      continue when not (v_ids && v_walk.concept_ids);
      if not (v_ids <@ v_walk.concept_ids) or exists (
        select 1 from public.concept_review_job_cards where action_id = v_a.id and job_id <> p_job_id
      ) then
        v_conflicts := v_conflicts || jsonb_build_array(jsonb_build_object(
          'action_id', v_a.id, 'conversation_id', v_a.conversation_id, 'reason', '목록 밖 개념이 섞였거나 다른 작업의 카드'
        ));
        continue;
      end if;
      insert into public.concept_review_job_cards (job_id, action_id, idem_key, content_hash, positions, legacy, origin_conversation_id)
      values (
        p_job_id, v_a.id, 'legacy:' || v_a.id, md5(coalesce(v_a.payload -> 'items', '[]'::jsonb)::text),
        array(select x.n::integer from unnest(v_walk.concept_ids) with ordinality x(id, n) where x.id = any (v_ids) order by x.n),
        true, v_a.conversation_id
      );
    end if;
    if v_a.conversation_id <> p_conversation_id then
      update public.concept_review_job_cards
         set origin_conversation_id = coalesce(origin_conversation_id, v_a.conversation_id), moved_at = now()
       where job_id = p_job_id and action_id = v_a.id;
      update public.ai_actions set conversation_id = p_conversation_id, message_id = null where id = v_a.id
      returning * into v_a;
    end if;
    v_moved := v_moved || jsonb_build_array(to_jsonb(v_a));
  end loop;
  return jsonb_build_object('cards', v_moved, 'conflicts', v_conflicts);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 8) 읽기: 출처·배치를 실은 묶음 읽기, 과정·단원, 기초 개념 후보
-- ─────────────────────────────────────────────────────────────────────────

-- 20261026120000 정의에서 출처(12개까지: 책·학년·과정 키·책 단원·인쇄 쪽·PDF 쪽)를 싣는다. 배치(placements)는 brief 에 있다.
-- 인쇄 쪽(printed_page)이 없으면 비워 둔다. PDF 쪽(pdf_page)을 인쇄 쪽으로 바꿔 쓰지 않는다.
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
    v_d := v_d || jsonb_build_object('todo', v_cs -> 'todo', 'conditions', v_cs -> 'conditions');
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

-- 살아 있는 과정과 단원 경로(배치 판단 자료). 과정 키(course_key)는 출처 학년 칸이 이 과정으로 읽힐 때 같다.
create or replace function public.concept_review_job_courses(p_job_id uuid, p_gen bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.concept_review_job_lock(p_job_id, p_gen);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', m.id, 'name', m.name, 'school_level', m.school_level, 'course_key', m.course_key,
             'units', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'id', x ->> 'id', 'path', array_to_string(public.course_unit_path((x ->> 'id')::uuid), ' › ')
                      ) order by n)
                 from jsonb_array_elements(public.course_map_units_json(m.id)) with ordinality as t(x, n)
             ), '[]'::jsonb)
           ) order by m.sort_order, m.name)
      from public.course_maps m
     where m.archived_at is null
  ), '[]'::jsonb);
end;
$$;

-- 기초 개념 후보 찾기. 검색어(40개까지, 1~40자)마다 이름에 든 개념(같은 이름 먼저)을, 모자라면 본문에 든 개념을 p_per(1~8)개.
-- 후보는 본문 앞 1500자(truncated 표시)·배치·초등 과정 배치 여부와 함께 한 번씩만 싣는다.
-- 새 기초 개념 만들기에 쓸 유형 이름(types)과 최상위 폴더 이름(roots)도 함께 준다.
create or replace function public.concept_review_job_search(p_job_id uuid, p_gen bigint, p_terms text[], p_per integer)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_per integer := least(greatest(coalesce(p_per, 5), 1), 8);
  v_term text;
  v_ids uuid[];
  v_all uuid[] := '{}'::uuid[];
  v_results jsonb := '[]'::jsonb;
begin
  perform public.concept_review_job_lock(p_job_id, p_gen);
  if p_terms is null or cardinality(p_terms) = 0 or cardinality(p_terms) > 40 then
    raise exception 'concept_review_job_bad_terms';
  end if;
  foreach v_term in array p_terms loop
    v_term := btrim(coalesce(v_term, ''));
    continue when char_length(v_term) = 0;
    if char_length(v_term) > 40 then
      raise exception 'concept_review_job_bad_terms';
    end if;
    v_ids := array(
      select c.id from public.concepts c
       where strpos(lower(c.name), lower(v_term)) > 0
       order by lower(btrim(c.name)) = lower(v_term) desc, char_length(c.name), c.name, c.id
       limit v_per
    );
    if cardinality(v_ids) < v_per then
      v_ids := v_ids || array(
        select c.id from public.concepts c
         where strpos(lower(coalesce(c.content, '')), lower(v_term)) > 0 and not (c.id = any (v_ids))
         order by char_length(c.name), c.name, c.id
         limit v_per - cardinality(v_ids)
      );
    end if;
    v_results := v_results || jsonb_build_array(jsonb_build_object('term', v_term, 'ids', to_jsonb(v_ids)));
    v_all := v_all || array(select x from unnest(v_ids) x where not (x = any (v_all)));
  end loop;
  return jsonb_build_object(
    'results', v_results,
    'types', coalesce((select jsonb_agg(t.name order by t.name) from public.concept_types t), '[]'::jsonb),
    'roots', coalesce((
      select jsonb_agg(c.name order by c.sort_order, c.created_at)
        from public.concept_categories c where c.parent_id is null and coalesce(c.code, '') <> 'SHORTCUT'
    ), '[]'::jsonb),
    'concepts', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', c.id, 'name', c.name,
               'type', (select t.name from public.concept_type_links l join public.concept_types t on t.id = l.type_id
                         where l.concept_id = c.id),
               'folder', to_jsonb(public.concept_folder_path(c.main_category_id)),
               'placements', public.concept_placement_paths(c.id),
               'elementary', exists (
                 select 1 from public.concept_appearances a
                   join public.course_map_units u on u.id = a.course_unit_id and u.archived_at is null
                   join public.course_maps m on m.id = u.course_id and m.archived_at is null
                  where a.concept_id = c.id and m.school_level = '초'
               ),
               'content', left(c.content, 1500), 'content_chars', char_length(c.content),
               'truncated', char_length(c.content) > 1500
             ) order by x.n)
        from unnest(v_all) with ordinality as x(id, n)
        join public.concepts c on c.id = x.id
    ), '[]'::jsonb)
  );
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 9) 상태: 통합 완료 수와 조건별 충족 수
-- ─────────────────────────────────────────────────────────────────────────

-- 분류(위치마다 하나): complete(통합 완료) · awaiting(대기 카드에 있음) · drafted(저장만 됨, 제출 전) · open(미결·실패·거절·
-- 승인 때 뺌·사용자 확인이 필요한 기록) · todo(부족한 범위를 아직 검수하지 않음, 상태 있는 위치) · not_reviewed(아직 내준 적 없음) · missing.
-- conditions: 표기·의미(text)·기초 개념(foundation)·배치(placement)를 각각 충족한 개념 수. 통합 완료 수와 섞지 않는다.
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
           i.action_items, i.draft_version, a.id as card_id, a.status as card_status
      from unnest(v_walk.concept_ids) with ordinality as x(cid, pos)
      left join public.concept_review_job_items i on i.job_id = v_job.id and i.pos = x.pos
      left join public.ai_actions a on a.id = i.action_id
     order by x.pos
  loop
    v_cs := public.concept_review_job_concept_state(r.cid, v_pending);
    v_next := r.next_action;
    v_cat := case
      when v_cs ->> 'state' = 'missing' then 'missing'
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
    if v_cat = 'open' and r.item_state = 'submitted' and v_cs ->> 'state' <> 'open' then
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

-- ─────────────────────────────────────────────────────────────────────────
-- 10) 기능 확인 (20261026120000 정의에서 concept_review_job_batch 가 통합 검수 함수까지 본다)
-- ─────────────────────────────────────────────────────────────────────────

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
    end,
    'department_work',
    case
      when exists (
         select 1 from pg_attribute
          where attrelid = 'public.ai_tree_nodes'::regclass and attname = 'department' and not attisdropped
       )
       and to_regprocedure('public.ai_tree_move_department(uuid, uuid, uuid, integer, text)') is not null
       and to_regprocedure('public.ai_conversation_move_department(uuid, text)') is not null
       and to_regprocedure('public.ai_department_handover_propose(uuid, text, text)') is not null
      then 1
      else 0
    end,
    'auto_organize',
    case
      when exists (
         select 1 from pg_attribute
          where attrelid = 'public.ai_messages'::regclass and attname = 'marked_important' and not attisdropped
       )
       and exists (
         select 1 from pg_attribute
          where attrelid = 'public.ai_conversations'::regclass and attname = 'progress_summary' and not attisdropped
       )
       and exists (
         select 1 from pg_attribute
          where attrelid = 'public.ai_platform_settings'::regclass and attname = 'auto_organize_enabled' and not attisdropped
       )
       and to_regclass('public.ai_department_criteria') is not null
       and to_regprocedure('public.ai_context_exclusion_propose(uuid, uuid[], text, text, boolean)') is not null
       and to_regprocedure('public.ai_importance_mark_propose(uuid, uuid[], text, boolean)') is not null
       and to_regprocedure('public.ai_progress_summary_propose(uuid, jsonb, text, uuid)') is not null
       and to_regprocedure('public.ai_department_criteria_propose(uuid, text, jsonb, text)') is not null
       and to_regprocedure('public.ai_department_criteria_save(text, jsonb, integer)') is not null
       and to_regprocedure('public.ai_action_apply_batch(jsonb)') is not null
      then 1
      else 0
    end,
    'course_map_actions',
    case
      when exists (
         select 1 from pg_attribute
          where attrelid = 'public.concept_appearances'::regclass and attname = 'course_unit_id' and not attisdropped
       )
       and to_regprocedure('public.course_think_action_propose(uuid, text, jsonb)') is not null
       and to_regprocedure('public.course_think_action_apply(uuid, jsonb)') is not null
       and to_regprocedure('public.course_map_placements(uuid)') is not null
       and to_regprocedure('public.concept_placement_candidates(uuid, text, text, integer, integer)') is not null
       and to_regprocedure('public.concept_think_detail(uuid)') is not null
      then 1
      else 0
    end,
    'concept_review',
    case
      when to_regclass('public.concept_quality_reviews') is not null
       and to_regclass('public.concept_review_walks') is not null
       and to_regprocedure('public.concept_review_walk(uuid, jsonb, integer, integer)') is not null
       and to_regprocedure('public.concept_review_status(uuid[])') is not null
       and to_regprocedure('public.course_think_propose_review(uuid, jsonb, text)') is not null
       and to_regprocedure('public.course_think_apply_review(public.ai_actions, jsonb)') is not null
      then 1
      else 0
    end,
    'concept_relation_change',
    case
      when exists (
         select 1 from pg_attribute
          where attrelid = 'public.concept_relations'::regclass and attname = 'judged_marks' and not attisdropped
       )
       and to_regclass('public.concept_relation_events') is not null
       and to_regprocedure('public.concept_relation_list(uuid)') is not null
       and to_regprocedure('public.course_think_propose_relation(uuid, jsonb, text)') is not null
       and to_regprocedure('public.course_think_apply_relation(public.ai_actions, jsonb)') is not null
      then 1
      else 0
    end,
    'concept_source_pages',
    case
      when to_regclass('public.concept_source_page_images') is not null
       and to_regclass('public.concept_source_page_workers') is not null
       and to_regprocedure('public.concept_source_list(uuid)') is not null
       and to_regprocedure('public.concept_source_page_context(uuid, integer)') is not null
       and to_regprocedure('public.concept_source_page_image(uuid, integer, boolean)') is not null
      then 1
      else 0
    end,
    'concept_review_jobs',
    case
      when to_regclass('public.concept_review_jobs') is not null
       and to_regclass('public.concept_review_job_items') is not null
       and to_regclass('public.concept_review_job_cards') is not null
       and to_regprocedure('public.concept_review_jobs_find()') is not null
       and to_regprocedure('public.concept_review_job_claim(uuid, text, text)') is not null
       and to_regprocedure('public.concept_review_job_status(uuid, integer)') is not null
       and to_regprocedure('public.concept_review_job_next(uuid, bigint, integer)') is not null
       and to_regprocedure('public.concept_review_job_save(uuid, bigint, jsonb)') is not null
       and to_regprocedure('public.concept_review_job_submit(uuid, bigint, uuid, text, integer)') is not null
       and to_regprocedure('public.concept_review_job_cards_here(uuid, bigint, uuid)') is not null
      then 1
      else 0
    end,
    'concept_review_job_batch',
    case
      when to_regclass('public.concept_review_job_batches') is not null
       and to_regprocedure('public.concept_review_job_material(uuid, bigint, integer[], jsonb, integer)') is not null
       and to_regprocedure('public.concept_review_job_batch_begin(uuid, bigint)') is not null
       and to_regprocedure('public.concept_review_job_batch_log(uuid, bigint, uuid, integer, text, jsonb)') is not null
       and to_regprocedure('public.concept_review_job_targets(uuid, bigint, integer)') is not null
       and to_regprocedure('public.concept_review_job_courses(uuid, bigint)') is not null
       and to_regprocedure('public.concept_review_job_search(uuid, bigint, text[], integer)') is not null
       and exists (
         select 1 from pg_attribute
          where attrelid = 'public.concept_quality_reviews'::regclass and attname = 'fixes' and not attisdropped
       )
      then 1
      else 0
    end
  );
end
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 11) 권한
-- ─────────────────────────────────────────────────────────────────────────

revoke all on function public.concept_review_placement_mark(uuid) from public, anon, authenticated;
revoke all on function public.concept_review_record_stale(public.concept_quality_reviews, jsonb) from public, anon, authenticated;
revoke all on function public.concept_review_fix_state(jsonb) from public, anon, authenticated;
revoke all on function public.concept_review_detail_clean(jsonb) from public, anon, authenticated;
revoke all on function public.concept_review_fixes_clean(jsonb, text) from public, anon, authenticated;
revoke all on function public.concept_review_fix_clean(text, text, jsonb, uuid) from public, anon, authenticated;
revoke all on function public.concept_review_job_fix_plan(jsonb) from public, anon, authenticated;
revoke all on function public.concept_review_job_item_skipped(uuid, integer[]) from public, anon, authenticated;
revoke all on function public.concept_review_changed_since(uuid, timestamptz) from public, anon, authenticated;
revoke all on function public.concept_review_marks(uuid) from public, anon, authenticated;
revoke all on function public.concept_review_revision(jsonb) from public, anon, authenticated;
revoke all on function public.concept_review_scope_mark(text) from public, anon, authenticated;
revoke all on function public.concept_review_revision_part(text, text) from public, anon, authenticated;
revoke all on function public.concept_review_scope_state(uuid) from public, anon, authenticated;
revoke all on function public.concept_review_matches(jsonb, text, text) from public, anon, authenticated;
revoke all on function public.concept_review_record_json(public.concept_quality_reviews, jsonb) from public, anon, authenticated;
revoke all on function public.course_think_propose_review(uuid, jsonb, text) from public, anon, authenticated;
revoke all on function public.course_think_apply_review(public.ai_actions, jsonb) from public, anon, authenticated;
revoke all on function public.concept_review_pending_concepts() from public, anon, authenticated;
revoke all on function public.concept_review_job_concept_state(uuid, uuid[]) from public, anon, authenticated;

revoke all on function public.concept_review_status(uuid[]) from public, anon;
revoke all on function public.concept_review_job_targets(uuid, bigint, integer) from public, anon;
revoke all on function public.concept_review_job_save(uuid, bigint, jsonb) from public, anon;
revoke all on function public.concept_review_job_submit(uuid, bigint, uuid, text, integer) from public, anon;
revoke all on function public.concept_review_job_cards_here(uuid, bigint, uuid) from public, anon;
revoke all on function public.concept_review_job_material(uuid, bigint, integer[], jsonb, integer) from public, anon;
revoke all on function public.concept_review_job_courses(uuid, bigint) from public, anon;
revoke all on function public.concept_review_job_search(uuid, bigint, text[], integer) from public, anon;
revoke all on function public.concept_review_job_status(uuid, integer) from public, anon;

grant execute on function public.concept_review_status(uuid[]) to authenticated;
grant execute on function public.concept_review_job_targets(uuid, bigint, integer) to authenticated;
grant execute on function public.concept_review_job_save(uuid, bigint, jsonb) to authenticated;
grant execute on function public.concept_review_job_submit(uuid, bigint, uuid, text, integer) to authenticated;
grant execute on function public.concept_review_job_cards_here(uuid, bigint, uuid) to authenticated;
grant execute on function public.concept_review_job_material(uuid, bigint, integer[], jsonb, integer) to authenticated;
grant execute on function public.concept_review_job_courses(uuid, bigint) to authenticated;
grant execute on function public.concept_review_job_search(uuid, bigint, text[], integer) to authenticated;
grant execute on function public.concept_review_job_status(uuid, integer) to authenticated;

notify pgrst, 'reload schema';
