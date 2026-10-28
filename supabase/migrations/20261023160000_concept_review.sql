-- 20261023160000: 개념 검토 목록·범위별 검토 기록 카드 (운영자 결정 2026-10-23, 개념 라이브러리 정리 2단계)
--
-- 설계: docs/architecture/concept-library.md "개념 검토"
--
-- 1) 판 표시(concept_review_marks). 범위마다 무엇이 바뀌면 다시 검토할지 정하는 지문(md5)이다.
--      text       이름·본문·확정한 서술(서술 id와 판)  → notation(오타·표기) · meaning(수학적 의미·조건·범위) · unit(중복·개념 단위)
--      class      유형·폴더(폴더 경로 포함)            → classification(유형·폴더)
--      relations  관계 줄(양쪽)과 상대 개념의 text      → relations(개념 관계)
--    검토 기록·정렬 순서·바로가기·배치는 지문에 들지 않는다. 검토를 남겨도 다시 검토할 일이 생기지 않는다.
--    revision 은 세 지문의 앞 12자를 이은 짧은 판이다. Think는 읽은 revision을 카드에 그대로 낸다.
-- 2) concept_review_walks: 전체 순회 목록. 시작할 때 조건에 맞는 개념 id를 폴더 경로·순서·이름 순으로 고정한다.
--    도중에 이름·폴더·검토 상태가 바뀌어도 목록은 그대로다. 시작 뒤 생긴 개념은 개수(created_after)로만 알리고,
--    그사이 지워진 개념은 missing 으로 보인다. 30일 지난 목록은 새 목록을 만들 때 지운다(개념 자료가 아니라 순회 상태다).
-- 3) concept_quality_reviews: 범위별 검토 기록. 승인된 Think 카드로만 쌓이고 고치거나 지우지 않는다(이력).
--    concept_reviews(같은 개념인지 검토)와 다르다. 결과는 no_issue_found(이번에 확인한 범위에서 문제를 못 찾음) ·
--    issue_found · needs_comparison · unverified · merge_needed(unit 만, 병합 필요·삭제 보류). "검증 완료"는 없다.
--    기록의 지문(mark)이 지금 그 범위 지문과 다르면 "내용 바뀜, 다시 검토 필요"(stale)다.
-- 4) 읽기 RPC: concept_review_walk(목록) · concept_review_status(범위별 최신 기록·이력·대기 카드) ·
--    concept_think_detail(+판·관계·같은 개념 검토·범위별 상태·등장 위치·출처 전체).
-- 5) Think 카드 concept_review_record(20개까지). 제안 때 Think가 읽은 revision 이 그 범위에서 지금과 같아야 하고,
--    승인 때 다시 같아야 남는다. 판단에 쓴 다른 개념이 바뀌거나 지워졌어도 남기지 않는다. 개념 본문·폴더·관계는 바꾸지 않는다.
-- 6) concept_attachments 에 범위별 검토 기록(quality_reviews)을 더한다. 검토 기록이 있는 개념은 지우지 않는다.

-- ─────────────────────────────────────────────────────────────────────────
-- 1) 판 표시
-- ─────────────────────────────────────────────────────────────────────────

create or replace function public.concept_review_text_mark(p_concept_id uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select md5(jsonb_build_array(
           c.name, c.content,
           coalesce((
             select jsonb_agg(jsonb_build_array(s.id, s.version) order by s.id)
               from public.concept_statements s
              where s.concept_id = c.id and s.version > 0
           ), '[]'::jsonb)
         )::text)
    from public.concepts c
   where c.id = p_concept_id;
$$;

create or replace function public.concept_review_class_mark(p_concept_id uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select md5(jsonb_build_array(
           l.type_id, t.name, c.main_category_id, to_jsonb(public.concept_folder_path(c.main_category_id))
         )::text)
    from public.concepts c
    left join public.concept_type_links l on l.concept_id = c.id
    left join public.concept_types t on t.id = l.type_id
   where c.id = p_concept_id;
$$;

create or replace function public.concept_review_relation_mark(p_concept_id uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case when exists (select 1 from public.concepts where id = p_concept_id) then md5(coalesce((
    select jsonb_agg(jsonb_build_array(
             r.id, r.concept_id, r.related_id, r.kind, r.note,
             public.concept_review_text_mark(case when r.concept_id = p_concept_id then r.related_id else r.concept_id end)
           ) order by r.id)
      from public.concept_relations r
     where r.concept_id = p_concept_id or r.related_id = p_concept_id
  ), '[]'::jsonb)::text) end;
$$;

-- 없는 개념이면 null.
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
    else left(p_marks ->> 'text', 12) || '-' || left(p_marks ->> 'class', 12) || '-' || left(p_marks ->> 'relations', 12) end;
$$;

create or replace function public.concept_review_scope_mark(p_scope text)
returns text
language sql
immutable
as $$
  select case p_scope when 'classification' then 'class' when 'relations' then 'relations' else 'text' end;
$$;

-- revision 에서 그 범위 지문의 앞 12자.
create or replace function public.concept_review_revision_part(p_revision text, p_scope text)
returns text
language sql
immutable
as $$
  select nullif(split_part(coalesce(btrim(p_revision), ''), '-',
                case public.concept_review_scope_mark(p_scope) when 'class' then 2 when 'relations' then 3 else 1 end), '');
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 2) 표
-- ─────────────────────────────────────────────────────────────────────────

create table if not exists public.concept_quality_reviews (
  id uuid primary key default gen_random_uuid(),
  concept_id uuid not null references public.concepts(id) on delete restrict,
  scope text not null check (scope in ('notation', 'meaning', 'classification', 'unit', 'relations')),
  outcome text not null check (outcome in ('no_issue_found', 'issue_found', 'needs_comparison', 'unverified', 'merge_needed')),
  checked text not null check (char_length(btrim(checked)) between 1 and 1000),
  findings text not null check (char_length(btrim(findings)) between 1 and 2000),
  basis text not null check (char_length(btrim(basis)) between 1 and 1000),
  unverified text check (unverified is null or char_length(unverified) <= 1000),
  follow_up text check (follow_up is null or char_length(follow_up) <= 1000),
  -- 판단에 쓴 다른 개념 [{id, name, text(그때 text 지문)}], 더 비교할 개념 [{id, name}]. 지운 개념도 가리킬 수 있어 외래키가 아니다.
  compared jsonb not null default '[]'::jsonb check (jsonb_typeof(compared) = 'array'),
  to_compare jsonb not null default '[]'::jsonb check (jsonb_typeof(to_compare) = 'array'),
  -- 검토한 판(concept_review_marks)과 그중 이 범위의 지문.
  marks jsonb not null,
  mark text not null,
  origin text not null default 'think' check (origin in ('think')),
  action_id uuid references public.ai_actions(id) on delete set null,
  action_item integer,
  proposed_at timestamptz,
  approved_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint concept_quality_reviews_merge_chk check (outcome <> 'merge_needed' or scope = 'unit')
);

create index if not exists concept_quality_reviews_concept_idx
  on public.concept_quality_reviews (concept_id, scope, created_at desc);

create table if not exists public.concept_review_walks (
  id uuid primary key default gen_random_uuid(),
  filter jsonb not null default '{}'::jsonb,
  concept_ids uuid[] not null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

alter table public.concept_quality_reviews enable row level security;
alter table public.concept_review_walks enable row level security;

drop policy if exists concept_quality_reviews_operator_select on public.concept_quality_reviews;
create policy concept_quality_reviews_operator_select on public.concept_quality_reviews
  for select to authenticated
  using ((select public.is_superadmin()));

revoke all on public.concept_quality_reviews, public.concept_review_walks from anon;
revoke insert, update, delete, truncate on public.concept_quality_reviews from authenticated;
revoke all on public.concept_review_walks from authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 3) 붙은 것 세기(20261023140000 정의에 범위별 검토 기록 추가)
-- ─────────────────────────────────────────────────────────────────────────

create or replace function public.concept_attachments(p_concept_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v jsonb;
  v_n integer;
  v_other integer := 0;
  r record;
  -- 아래에서 이름 붙여 세는 열. 여기 없는 외래키는 other 로 센다.
  v_known text[] := array[
    'public.concept_sources.concept_id', 'public.concept_statements.concept_id',
    'public.concept_appearances.concept_id', 'public.concept_relations.concept_id',
    'public.concept_relations.related_id', 'public.concept_reviews.concept_id', 'public.concept_reviews.other_id',
    'public.concept_quality_reviews.concept_id',
    'public.concept_criterion_links.concept_id', 'public.concept_anchor_links.concept_id',
    'public.concept_anchor_links.anchor_id', 'public.concept_content_drafts.concept_id',
    'public.concept_type_links.concept_id', 'public.concept_content_revisions.concept_id',
    'public.concept_shortcuts.concept_id', 'public.operation_prompts.concept_id'
  ];
begin
  v := jsonb_build_object(
    'sources', (select count(*) from public.concept_sources where concept_id = p_concept_id),
    'statements', (select count(*) from public.concept_statements where concept_id = p_concept_id),
    'appearances', (
      select count(*) from public.concept_appearances where concept_id = p_concept_id and course_unit_id is null
    ),
    'placements', (
      select count(*) from public.concept_appearances where concept_id = p_concept_id and course_unit_id is not null
    ),
    'relations', (
      select count(*) from public.concept_relations where concept_id = p_concept_id or related_id = p_concept_id
    ),
    'reviews', (select count(*) from public.concept_reviews where concept_id = p_concept_id or other_id = p_concept_id),
    'quality_reviews', (select count(*) from public.concept_quality_reviews where concept_id = p_concept_id),
    'criteria', (select count(*) from public.concept_criterion_links where concept_id = p_concept_id),
    'anchors', (
      select count(*) from public.concept_anchor_links where concept_id = p_concept_id or anchor_id = p_concept_id
    ),
    'content_draft', (select count(*) from public.concept_content_drafts where concept_id = p_concept_id),
    'type_link', (select count(*) from public.concept_type_links where concept_id = p_concept_id),
    'content_revisions', (select count(*) from public.concept_content_revisions where concept_id = p_concept_id),
    'draft_refs', (
      select count(*)
        from public.concept_drafts d
        cross join lateral jsonb_array_elements(
          case when jsonb_typeof(d.review -> 'concepts') = 'array' then d.review -> 'concepts' else '[]'::jsonb end
        ) i
       where d.status = 'open'
         and i ->> 'mark' is distinct from 'drop'
         and jsonb_typeof(i -> 'relation') = 'object'
         and i -> 'relation' ->> 'concept_id' = p_concept_id::text
    )
  );
  if to_regclass('public.concept_shortcuts') is not null then
    execute 'select count(*) from public.concept_shortcuts where concept_id = $1' into v_n using p_concept_id;
    v := v || jsonb_build_object('shortcuts', v_n);
  end if;
  if to_regclass('public.operation_prompts') is not null then
    execute 'select count(*) from public.operation_prompts where concept_id = $1' into v_n using p_concept_id;
    v := v || jsonb_build_object('operation_prompts', v_n);
  end if;
  for r in
    select format('%I.%I', n.nspname, cl.relname) as tbl, a.attname as col
      from pg_constraint c
      join pg_class cl on cl.oid = c.conrelid
      join pg_namespace n on n.oid = cl.relnamespace
      join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
     where c.contype = 'f' and c.confrelid = 'public.concepts'::regclass and cardinality(c.conkey) = 1
  loop
    continue when (r.tbl || '.' || r.col) = any (v_known);
    execute format('select count(*) from %s where %I = $1', r.tbl, r.col) into v_n using p_concept_id;
    v_other := v_other + v_n;
  end loop;
  v := v || jsonb_build_object('other', v_other);
  return v || jsonb_build_object('total', (select coalesce(sum(value::integer), 0) from jsonb_each_text(v)));
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 4) 범위별 상태·읽기
-- ─────────────────────────────────────────────────────────────────────────

create or replace function public.concept_review_assert_operator()
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.is_superadmin() then
    raise exception 'concept_review_forbidden';
  end if;
end;
$$;

-- 기록이 있는 범위만: {범위: {record_id, outcome, reviewed_at, stale, records}}.
create or replace function public.concept_review_scope_state(p_concept_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with m as (select public.concept_review_marks(p_concept_id) as marks),
  latest as (
    select distinct on (r.scope) r.*
      from public.concept_quality_reviews r
     where r.concept_id = p_concept_id
     order by r.scope, r.created_at desc, r.id desc
  ),
  counts as (
    select scope, count(*) as n from public.concept_quality_reviews where concept_id = p_concept_id group by scope
  )
  select coalesce(jsonb_object_agg(l.scope, jsonb_build_object(
           'record_id', l.id, 'outcome', l.outcome, 'reviewed_at', l.created_at,
           'stale', l.mark is distinct from (m.marks ->> public.concept_review_scope_mark(l.scope)),
           'records', c.n
         )), '{}'::jsonb)
    from latest l
    cross join m
    join counts c on c.scope = l.scope;
$$;

-- p_review: unreviewed(그 범위 기록 없음) · stale(내용 바뀜) · not_current(없음 또는 바뀜) · has_issue(문제 있음·비교 필요·
-- 확인 못 함·병합 필요) · merge_needed. p_scope 가 null 이면 다섯 범위 중 하나라도.
create or replace function public.concept_review_matches(p_state jsonb, p_review text, p_scope text)
returns boolean
language sql
immutable
as $$
  select exists (
    select 1
      from unnest(case when p_scope is null then array['notation', 'meaning', 'classification', 'unit', 'relations']
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

-- 순회 목록 한 줄.
create or replace function public.concept_review_brief(p_concept_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', c.id, 'name', c.name, 'type', t.name,
    'folder', to_jsonb(public.concept_folder_path(c.main_category_id)),
    'excerpt', left(regexp_replace(c.content, '\s+', ' ', 'g'), 120),
    'content_chars', char_length(c.content),
    'statements', (select count(*) from public.concept_statements s where s.concept_id = c.id),
    'sources', (select count(*) from public.concept_sources s where s.concept_id = c.id),
    'placed', (select count(*) from public.concept_appearances a where a.concept_id = c.id and a.course_unit_id is not null),
    'relations', (select count(*) from public.concept_relations r where r.concept_id = c.id or r.related_id = c.id),
    'same_name', (
      select count(*) from public.concepts o where o.id <> c.id and lower(btrim(o.name)) = lower(btrim(c.name))
    ),
    'open_same_concept_reviews', (
      select count(*) from public.concept_reviews v where v.status = 'open' and (v.concept_id = c.id or v.other_id = c.id)
    ),
    'revision', public.concept_review_revision(public.concept_review_marks(c.id)),
    'review', public.concept_review_scope_state(c.id)
  )
    from public.concepts c
    left join public.concept_type_links l on l.concept_id = c.id
    left join public.concept_types t on t.id = l.type_id
   where c.id = p_concept_id;
$$;

-- p_walk_id 가 없으면 p_filter 로 목록을 새로 고정한다. 있으면 그 목록의 p_offset 부터 p_limit 개(최대 60).
-- p_filter {folder_id(하위 폴더 포함), type(유형 이름, '유형 없음'), name(이름에 든 말), placed(any·placed·unplaced),
--           review(any·unreviewed·stale·not_current·has_issue·merge_needed), review_scope(범위 하나, null이면 다섯 중 하나라도)}
create or replace function public.concept_review_walk(p_walk_id uuid, p_filter jsonb, p_offset integer, p_limit integer)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_walk public.concept_review_walks;
  v_f jsonb := coalesce(p_filter, '{}'::jsonb);
  v_folder uuid;
  v_type text;
  v_name text;
  v_placed text;
  v_review text;
  v_scope text;
  v_ids uuid[];
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_limit integer := least(greatest(coalesce(p_limit, 40), 1), 60);
  v_total integer;
  v_items jsonb;
begin
  perform public.concept_review_assert_operator();
  if p_walk_id is null then
    if jsonb_typeof(v_f) <> 'object' then
      raise exception 'concept_review_bad_filter';
    end if;
    if nullif(btrim(coalesce(v_f ->> 'folder_id', '')), '') is not null then
      v_folder := public.course_think_uuid(v_f ->> 'folder_id');
      if v_folder is null or not exists (select 1 from public.concept_categories where id = v_folder) then
        raise exception 'concept_review_folder_not_found';
      end if;
    end if;
    v_type := nullif(btrim(coalesce(v_f ->> 'type', '')), '');
    if v_type is not null and v_type <> '유형 없음'
       and not exists (select 1 from public.concept_types where lower(btrim(name)) = lower(v_type)) then
      raise exception 'concept_review_unknown_type';
    end if;
    v_name := nullif(btrim(coalesce(v_f ->> 'name', '')), '');
    if char_length(coalesce(v_name, '')) > 80 then
      raise exception 'concept_review_bad_filter';
    end if;
    v_placed := coalesce(nullif(v_f ->> 'placed', ''), 'any');
    v_review := coalesce(nullif(v_f ->> 'review', ''), 'any');
    v_scope := nullif(v_f ->> 'review_scope', '');
    if v_placed not in ('any', 'placed', 'unplaced')
       or v_review not in ('any', 'unreviewed', 'stale', 'not_current', 'has_issue', 'merge_needed')
       or (v_scope is not null and v_scope not in ('notation', 'meaning', 'classification', 'unit', 'relations')) then
      raise exception 'concept_review_bad_filter';
    end if;

    with recursive tree(id) as (
      select v_folder where v_folder is not null
      union
      select c.id from public.concept_categories c join tree t on c.parent_id = t.id
    )
    select coalesce(array_agg(x.id order by x.path, x.sort_order, x.name, x.id), '{}'::uuid[]) into v_ids
      from (
        select c.id, c.name, coalesce(c.sort_order, 0) as sort_order,
               array_to_string(public.concept_folder_path(c.main_category_id), ' › ') as path
          from public.concepts c
          left join public.concept_type_links l on l.concept_id = c.id
          left join public.concept_types t on t.id = l.type_id
         where (v_folder is null or c.main_category_id in (select id from tree))
           and (v_type is null or (v_type = '유형 없음' and t.id is null) or lower(btrim(t.name)) = lower(v_type))
           and (v_name is null or strpos(lower(c.name), lower(v_name)) > 0)
           and case v_placed
             when 'any' then true
             else (v_placed = 'placed') = exists (
               select 1
                 from public.concept_appearances a
                 join public.course_map_units u on u.id = a.course_unit_id and u.archived_at is null
                 join public.course_maps m on m.id = u.course_id and m.archived_at is null
                where a.concept_id = c.id
             )
           end
           and case v_review
             when 'any' then true
             else public.concept_review_matches(public.concept_review_scope_state(c.id), v_review, v_scope)
           end
      ) x;

    delete from public.concept_review_walks where created_at < now() - interval '30 days';
    insert into public.concept_review_walks (filter, concept_ids, created_by)
    values (
      jsonb_build_object('folder_id', v_folder, 'type', v_type, 'name', v_name, 'placed', v_placed,
                         'review', v_review, 'review_scope', v_scope),
      v_ids, auth.uid()
    )
    returning * into v_walk;
  else
    select * into v_walk from public.concept_review_walks where id = p_walk_id;
    if not found then
      raise exception 'concept_review_walk_not_found';
    end if;
  end if;

  v_total := coalesce(cardinality(v_walk.concept_ids), 0);
  select coalesce(jsonb_agg(
           case when c.id is null then jsonb_build_object('id', w.id, 'missing', true)
                else public.concept_review_brief(c.id) end
           order by w.n
         ), '[]'::jsonb)
    into v_items
    from unnest(v_walk.concept_ids[v_offset + 1 : v_offset + v_limit]) with ordinality as w(id, n)
    left join public.concepts c on c.id = w.id;
  return jsonb_build_object(
    'walk_id', v_walk.id, 'started_at', v_walk.created_at, 'filter', v_walk.filter,
    'total', v_total, 'offset', v_offset, 'items', v_items,
    'next_offset', case when v_offset + v_limit < v_total then v_offset + v_limit end,
    'created_after', (select count(*) from public.concepts where created_at > v_walk.created_at)
  );
end;
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
    'revision', public.concept_review_revision(r.marks),
    'statements', coalesce(r.marks -> 'statements', '[]'::jsonb),
    'stale', r.mark is distinct from (p_marks ->> public.concept_review_scope_mark(r.scope)),
    'origin', r.origin, 'action_id', r.action_id, 'reviewed_at', r.created_at
  );
$$;

-- 개념마다 범위별 최신 기록(+앞선 5개 요약·기록 수)과 승인을 기다리는 검토 카드 항목. 20개까지.
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
    foreach v_scope in array array['notation', 'meaning', 'classification', 'unit', 'relations'] loop
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

-- 20261023120000 정의에 출처 전체(300개까지)·등장 위치·관계·같은 개념 검토·범위별 상태·판을 더한다.
create or replace function public.concept_think_detail(p_concept_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_concept public.concepts;
  v_marks jsonb;
begin
  perform public.course_map_assert_operator();
  select * into v_concept from public.concepts where id = p_concept_id;
  if not found then
    raise exception 'concept_think_concept_not_found';
  end if;
  v_marks := public.concept_review_marks(p_concept_id);
  return public.concept_think_brief(p_concept_id) || jsonb_build_object(
    'content', v_concept.content,
    'content_draft_pending', exists (select 1 from public.concept_content_drafts d where d.concept_id = p_concept_id),
    'statements', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', s.id, 'role', s.role, 'version', s.version, 'has_draft', s.draft is not null,
               'content', s.content
             ) order by (s.role <> 'core'), s.sort_order, s.created_at)
        from public.concept_statements s where s.concept_id = p_concept_id
    ), '[]'::jsonb),
    'attached', public.concept_attachments(p_concept_id),
    'sources', coalesce((
      select jsonb_agg(jsonb_build_object(
               'book', f.name, 'grade', s.grade_label,
               'course_key', nullif(public._textbook_course_info(s.grade_label) ->> 'course_key', ''),
               'unit_path', to_jsonb(s.unit_path), 'page', coalesce(s.display_page, s.raw_page),
               'statement_id', s.statement_id
             ) order by s.created_at, s.id)
        from (
          select * from public.concept_sources s0 where s0.concept_id = p_concept_id order by s0.created_at, s0.id limit 300
        ) s
        left join public.resource_files f on f.id = s.book_id
    ), '[]'::jsonb),
    'appearances', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', a.id, 'statement_id', a.statement_id, 'curriculum_code', a.curriculum_code,
               'school_level', a.school_level, 'course_label', a.course_label, 'unit_path', to_jsonb(a.unit_path), 'note', a.note
             ) order by a.created_at, a.id)
        from public.concept_appearances a where a.concept_id = p_concept_id and a.course_unit_id is null
    ), '[]'::jsonb),
    'relations', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', r.id, 'direction', case when r.concept_id = p_concept_id then 'out' else 'in' end,
               'kind', r.kind, 'other_id', o.id, 'other_name', o.name, 'origin', r.origin, 'note', r.note,
               'created_at', r.created_at
             ) order by r.created_at, r.id)
        from public.concept_relations r
        join public.concepts o on o.id = case when r.concept_id = p_concept_id then r.related_id else r.concept_id end
       where r.concept_id = p_concept_id or r.related_id = p_concept_id
    ), '[]'::jsonb),
    'same_concept_reviews', coalesce((
      select jsonb_agg(t.j order by t.open desc, t.created_at desc)
        from (
          select v.status = 'open' as open, v.created_at, jsonb_build_object(
                   'id', v.id, 'other_id', o.id, 'other_name', o.name, 'reason', v.reason, 'note', v.note,
                   'status', v.status, 'resolution', v.resolution, 'resolution_note', v.resolution_note,
                   'created_at', v.created_at
                 ) as j
            from public.concept_reviews v
            left join public.concepts o on o.id = case when v.concept_id = p_concept_id then v.other_id else v.concept_id end
           where v.concept_id = p_concept_id or v.other_id = p_concept_id
           order by v.status = 'open' desc, v.created_at desc
           limit 20
        ) t
    ), '[]'::jsonb),
    'same_concept_review_count', (
      select count(*) from public.concept_reviews v where v.concept_id = p_concept_id or v.other_id = p_concept_id
    ),
    'review', public.concept_review_scope_state(p_concept_id),
    'revision', public.concept_review_revision(v_marks),
    'statement_versions', v_marks -> 'statements'
  );
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 5) Think 카드 concept_review_record
-- ─────────────────────────────────────────────────────────────────────────

alter table public.ai_actions drop constraint if exists ai_actions_kind_check;
alter table public.ai_actions add constraint ai_actions_kind_check
  check (kind in (
    'code_request', 'code_change', 'code_plan', 'place_conversation', 'delete_code_request', 'delete_folder',
    'delete_conversation', 'split_conversation', 'save_memory', 'memory_card_change', 'handover_department',
    'exclude_context', 'mark_important', 'progress_summary', 'department_criteria_change',
    'concept_draft_change', 'concept_criterion_change', 'concept_draft_rerun',
    'course_map_change', 'course_map_create', 'concept_placement_change', 'concept_library_change',
    'concept_review_record'
  ));

create or replace function public.concept_review_text(p text, p_max integer, p_required boolean)
returns text
language plpgsql
immutable
as $$
declare
  v text := nullif(btrim(coalesce(p, '')), '');
begin
  if v is null then
    if p_required then
      raise exception 'concept_review_text_required';
    end if;
    return null;
  end if;
  if char_length(v) > p_max then
    raise exception 'concept_review_too_long';
  end if;
  return v;
end;
$$;

-- 다른 개념 id 목록(10개까지) → [{id, name, text}]. 같은 id는 한 번만, 자기 자신·없는 개념은 막는다.
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
  if jsonb_array_length(p) > 10 then
    raise exception 'concept_review_too_many_refs';
  end if;
  for v_e in select e from jsonb_array_elements(p) e loop
    v_id := case when jsonb_typeof(v_e) = 'string' then public.course_think_uuid(v_e #>> '{}') end;
    if v_id is null or v_id = p_self then
      raise exception 'concept_review_ref_not_found';
    end if;
    continue when v_id = any (v_seen);
    select name into v_name from public.concepts where id = v_id;
    if not found then
      raise exception 'concept_review_ref_not_found';
    end if;
    v_seen := v_seen || v_id;
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'id', v_id, 'name', v_name, 'text', public.concept_review_text_mark(v_id)
    ));
  end loop;
  return v_out;
end;
$$;

-- p_payload {items: [{concept_id, revision, scope, outcome, checked, findings, basis, unverified, follow_up,
--                     compared_ids, to_compare_ids}], reason}
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
      if v_scope is null or v_scope not in ('notation', 'meaning', 'classification', 'unit', 'relations') then
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

      -- Think가 읽은 판이 이 범위에서 지금과 같아야 한다.
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

      v_clean := v_clean || jsonb_build_array(jsonb_build_object(
        'concept_id', v_concept.id, 'scope', v_scope, 'outcome', v_outcome,
        'checked', public.concept_review_text(v_item ->> 'checked', 1000, true),
        'findings', public.concept_review_text(v_item ->> 'findings', 2000, true),
        'basis', public.concept_review_text(v_item ->> 'basis', 1000, true),
        'unverified', public.concept_review_text(v_item ->> 'unverified', 1000, false),
        'follow_up', public.concept_review_text(v_item ->> 'follow_up', 1000, false),
        'compared', v_compared, 'to_compare', v_to, 'marks', v_marks
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
          'stale', v_prev.mark is distinct from (v_marks ->> public.concept_review_scope_mark(v_scope))
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

-- p_overrides {skip: [항목 번호]}. 항목마다 따로 남긴다. 판이 바뀐 항목·비교한 개념이 바뀐 항목은 남기지 않는다.
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
        marks, mark, origin, action_id, action_item, proposed_at, approved_by
      )
      values (
        (v_item ->> 'concept_id')::uuid, v_item ->> 'scope', v_item ->> 'outcome', v_item ->> 'checked',
        v_item ->> 'findings', v_item ->> 'basis', v_item ->> 'unverified', v_item ->> 'follow_up',
        coalesce(v_item -> 'compared', '[]'::jsonb), coalesce(v_item -> 'to_compare', '[]'::jsonb),
        v_item -> 'marks', v_item -> 'marks' ->> v_key, 'think', p_act.id, v_i, p_act.created_at, auth.uid()
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

-- 20261023120000 정의에 concept_review_record 추가.
create or replace function public.course_think_action_propose(p_conversation_id uuid, p_kind text, p_payload jsonb)
returns public.ai_actions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_payload jsonb := coalesce(p_payload, '{}'::jsonb);
  v_reason text := left(btrim(coalesce(p_payload ->> 'reason', '')), 500);
begin
  if not public.is_superadmin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if not exists (select 1 from public.ai_conversations where id = p_conversation_id) then
    raise exception 'conversation_not_found' using errcode = 'P0002';
  end if;
  if octet_length(v_payload::text) > 200000 then
    raise exception 'course_think_too_long';
  end if;
  if v_reason = '' then
    raise exception 'course_think_reason_required';
  end if;
  if p_kind = 'course_map_change' then
    return public.course_think_propose_map(p_conversation_id, v_payload, v_reason);
  elsif p_kind = 'course_map_create' then
    return public.course_think_propose_create(p_conversation_id, v_payload, v_reason);
  elsif p_kind = 'concept_placement_change' then
    return public.course_think_propose_placement(p_conversation_id, v_payload, v_reason);
  elsif p_kind = 'concept_library_change' then
    return public.course_think_propose_library(p_conversation_id, v_payload, v_reason);
  elsif p_kind = 'concept_review_record' then
    return public.course_think_propose_review(p_conversation_id, v_payload, v_reason);
  end if;
  raise exception 'action_kind_not_appliable' using errcode = '22023';
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
  else
    raise exception 'action_kind_not_appliable' using errcode = '22023';
  end if;
  update public.ai_actions
     set status = 'applied', result = v_res, error = null, decided_by = auth.uid(), decided_at = now()
   where id = p_id
  returning * into v_act;
  return v_act;
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 6) 기능 확인 (20261023120000 정의에 concept_review 추가)
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
    end
  );
end
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 7) 권한
-- ─────────────────────────────────────────────────────────────────────────

revoke all on function public.concept_review_text_mark(uuid) from public, anon, authenticated;
revoke all on function public.concept_review_class_mark(uuid) from public, anon, authenticated;
revoke all on function public.concept_review_relation_mark(uuid) from public, anon, authenticated;
revoke all on function public.concept_review_marks(uuid) from public, anon, authenticated;
revoke all on function public.concept_review_revision(jsonb) from public, anon, authenticated;
revoke all on function public.concept_review_scope_mark(text) from public, anon, authenticated;
revoke all on function public.concept_review_revision_part(text, text) from public, anon, authenticated;
revoke all on function public.concept_attachments(uuid) from public, anon, authenticated;
revoke all on function public.concept_review_assert_operator() from public, anon, authenticated;
revoke all on function public.concept_review_scope_state(uuid) from public, anon, authenticated;
revoke all on function public.concept_review_matches(jsonb, text, text) from public, anon, authenticated;
revoke all on function public.concept_review_brief(uuid) from public, anon, authenticated;
revoke all on function public.concept_review_record_json(public.concept_quality_reviews, jsonb) from public, anon, authenticated;
revoke all on function public.concept_review_text(text, integer, boolean) from public, anon, authenticated;
revoke all on function public.concept_review_refs(jsonb, uuid) from public, anon, authenticated;
revoke all on function public.course_think_propose_review(uuid, jsonb, text) from public, anon, authenticated;
revoke all on function public.course_think_apply_review(public.ai_actions, jsonb) from public, anon, authenticated;

revoke all on function public.concept_review_walk(uuid, jsonb, integer, integer) from public, anon;
revoke all on function public.concept_review_status(uuid[]) from public, anon;
revoke all on function public.concept_think_detail(uuid) from public, anon;
revoke all on function public.course_think_action_propose(uuid, text, jsonb) from public, anon;
revoke all on function public.course_think_action_apply(uuid, jsonb) from public, anon;

grant execute on function public.concept_review_walk(uuid, jsonb, integer, integer) to authenticated;
grant execute on function public.concept_review_status(uuid[]) to authenticated;
grant execute on function public.concept_think_detail(uuid) to authenticated;
grant execute on function public.course_think_action_propose(uuid, text, jsonb) to authenticated;
grant execute on function public.course_think_action_apply(uuid, jsonb) to authenticated;

notify pgrst, 'reload schema';
