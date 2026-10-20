-- 20261020120000: 개념 사이 관계 · 검토 필요 표시 · 초안 확정 때 관계 고르기 (운영자 결정 2026-10-20, 여러 서술 4단계)
--
-- 설계: docs/architecture/concept-library.md §4.2
--
-- 표
--   concept_relations   개념 → 기준 개념. kind = extends(기준 개념을 넓힌 개념) · special_case(기준 개념의 특수한 경우).
--                       운영자가 고른 것만 들어간다. 이름·학년·문장이 비슷하다고 자동으로 넣지 않는다.
--   concept_reviews     "같은 개념인지 검토 필요" 표시. 열려 있으면(open) 트리·상세에 보이고, 운영자가 고르면 닫힌다(resolved).
--                       resolution = different(서로 다른 개념) · same(같은 개념으로 판단, 합치지는 않음) · extends · special_case.
--                       extends·special_case 로 닫으면 concept_relations 에 한 줄이 생긴다. 닫힌 줄은 판단 기록으로 남는다.
--
-- 초안 확정(concept_draft_confirm)은 20261018120000 과 같고, 검토 항목의 relation 을 읽는 것만 다르다.
--   relation: {kind, concept_id?}
--     new           새 개념(지금과 같음). 검토 표시를 남기지 않는다.
--     statement     새 개념을 만들지 않고 concept_id 개념에 확정 전 서술(초안)로 붙인다. 그 개념의 확정본·본문은 바꾸지 않는다.
--                   출처는 그 서술에 잇는다. 그 개념에 같은 쪽 출처가 이미 있으면 그 줄은 그대로 두고 건너뛴다.
--     extends · special_case   새 개념을 만들고 concept_id 개념과 관계를 잇는다.
--     review        새 개념을 만들고 검토 필요로 표시한다(concept_id 가 있으면 그 개념과 비교할 것으로).
--     없음          새 개념을 만들고, 라이브러리에 이름이 같은 개념이 있으면 그 개념과, 폴더 제안 AI가 겹친다고 본 항목이면
--                   상대 없이 검토 필요로 표시한다. 확정은 막지 않는다.
--   concept_draft_item_norm 이 relation 을 남긴다(Think 변경 카드 승인 때 없어지지 않게).
--
-- 기존 데이터는 옮기거나 합치지 않는다. 이미 있는 같은 이름 개념(concept_families)에 검토 표시를 자동으로 넣지 않는다.

-- ─────────────────────────────────────────────────────────────────────────
-- 1) 표
-- ─────────────────────────────────────────────────────────────────────────

create table if not exists public.concept_relations (
  id uuid primary key default gen_random_uuid(),
  concept_id uuid not null references public.concepts(id) on delete cascade,
  related_id uuid not null references public.concepts(id) on delete cascade,
  kind text not null check (kind in ('extends', 'special_case')),
  origin text not null check (origin in ('draft', 'review', 'manual')),
  draft_id uuid references public.concept_drafts(id) on delete set null,
  note text check (note is null or char_length(note) <= 500),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint concept_relations_self_chk check (concept_id <> related_id),
  unique (concept_id, related_id)
);

create index if not exists concept_relations_related_idx on public.concept_relations (related_id);

create table if not exists public.concept_reviews (
  id uuid primary key default gen_random_uuid(),
  concept_id uuid not null references public.concepts(id) on delete cascade,
  other_id uuid references public.concepts(id) on delete cascade,
  reason text not null check (reason in ('same_name', 'overlap', 'draft', 'manual')),
  note text check (note is null or char_length(note) <= 500),
  status text not null default 'open' check (status in ('open', 'resolved')),
  resolution text check (resolution is null or resolution in ('different', 'same', 'extends', 'special_case')),
  resolution_note text check (resolution_note is null or char_length(resolution_note) <= 500),
  draft_id uuid references public.concept_drafts(id) on delete set null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  resolved_by uuid references auth.users(id) on delete set null,
  resolved_at timestamptz,
  constraint concept_reviews_self_chk check (other_id is null or other_id <> concept_id),
  constraint concept_reviews_state_chk check (
    (status = 'open' and resolution is null and resolved_at is null)
    or (status = 'resolved' and resolution is not null and resolved_at is not null)
  )
);

create index if not exists concept_reviews_concept_idx on public.concept_reviews (concept_id, created_at);
create index if not exists concept_reviews_other_idx on public.concept_reviews (other_id) where other_id is not null;
create index if not exists concept_reviews_open_idx on public.concept_reviews (status) where status = 'open';

-- ─────────────────────────────────────────────────────────────────────────
-- 2) 관계·검토 RPC
-- ─────────────────────────────────────────────────────────────────────────

create or replace function public.concept_relation_assert_operator()
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.is_superadmin() then
    raise exception 'concept_relation_forbidden';
  end if;
end;
$$;

-- 관계 한 줄을 넣거나 종류를 바꾼다. 거꾸로 이어진 줄이 있으면 막는다(서로를 넓힌다고 둘 수 없다).
create or replace function public.concept_relation_put(
  p_concept uuid,
  p_related uuid,
  p_kind text,
  p_origin text,
  p_draft uuid,
  p_note text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if p_kind is null or p_kind not in ('extends', 'special_case') then
    raise exception 'concept_relation_bad_kind';
  end if;
  if p_concept is null or p_related is null or p_concept = p_related then
    raise exception 'concept_relation_bad_request';
  end if;
  if char_length(coalesce(p_note, '')) > 500 then
    raise exception 'concept_relation_too_long';
  end if;
  if not exists (select 1 from public.concepts where id = p_concept)
     or not exists (select 1 from public.concepts where id = p_related) then
    raise exception 'concept_relation_not_found';
  end if;
  if exists (select 1 from public.concept_relations where concept_id = p_related and related_id = p_concept) then
    raise exception 'concept_relation_reverse_exists';
  end if;
  insert into public.concept_relations (concept_id, related_id, kind, origin, draft_id, note, created_by)
  values (p_concept, p_related, p_kind, p_origin, p_draft, nullif(btrim(coalesce(p_note, '')), ''), auth.uid())
  on conflict (concept_id, related_id) do update
    set kind = excluded.kind, origin = excluded.origin, draft_id = excluded.draft_id, note = excluded.note,
        created_by = excluded.created_by, created_at = now()
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.concept_relation_set(p_concept uuid, p_related uuid, p_kind text, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  perform public.concept_relation_assert_operator();
  v_id := public.concept_relation_put(p_concept, p_related, p_kind, 'manual', null, p_note);
  return (select to_jsonb(r) from public.concept_relations r where r.id = v_id);
end;
$$;

create or replace function public.concept_relation_remove(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.concept_relation_assert_operator();
  delete from public.concept_relations where id = p_id;
  if not found then
    raise exception 'concept_relation_not_found';
  end if;
  return jsonb_build_object('id', p_id, 'removed', true);
end;
$$;

-- 검토 필요 표시를 직접 연다. 같은 두 개념의 열린 표시가 이미 있으면 그것을 돌려준다.
create or replace function public.concept_review_open(p_concept uuid, p_other uuid default null, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.concept_reviews;
begin
  perform public.concept_relation_assert_operator();
  if p_concept is null or p_concept = p_other then
    raise exception 'concept_relation_bad_request';
  end if;
  if char_length(coalesce(p_note, '')) > 500 then
    raise exception 'concept_relation_too_long';
  end if;
  if not exists (select 1 from public.concepts where id = p_concept)
     or (p_other is not null and not exists (select 1 from public.concepts where id = p_other)) then
    raise exception 'concept_relation_not_found';
  end if;
  select * into v_row from public.concept_reviews
   where status = 'open'
     and ((concept_id = p_concept and other_id is not distinct from p_other)
          or (p_other is not null and concept_id = p_other and other_id = p_concept))
   limit 1;
  if found then
    return to_jsonb(v_row);
  end if;
  insert into public.concept_reviews (concept_id, other_id, reason, note, created_by)
  values (p_concept, p_other, 'manual', nullif(btrim(coalesce(p_note, '')), ''), auth.uid())
  returning * into v_row;
  return to_jsonb(v_row);
end;
$$;

-- 검토 필요를 닫는다. 상대가 없던 표시는 p_other 로 상대를 정할 수 있다(different 는 상대 없이도 된다).
-- 닫힌 줄은 "concept_id 가 other_id 를 넓힘·other_id 의 특수한 경우"로 읽는다. p_reverse 면 두 쪽을 바꿔 적고 관계도 반대로 잇는다.
create or replace function public.concept_review_resolve(
  p_id uuid,
  p_resolution text,
  p_other uuid default null,
  p_note text default null,
  p_reverse boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.concept_reviews;
  v_other uuid;
  v_from uuid;
  v_to uuid;
begin
  perform public.concept_relation_assert_operator();
  if p_resolution is null or p_resolution not in ('different', 'same', 'extends', 'special_case') then
    raise exception 'concept_review_bad_resolution';
  end if;
  if char_length(coalesce(p_note, '')) > 500 then
    raise exception 'concept_relation_too_long';
  end if;
  select * into v_row from public.concept_reviews where id = p_id for update;
  if not found then
    raise exception 'concept_review_not_found';
  end if;
  if v_row.status <> 'open' then
    raise exception 'concept_review_closed';
  end if;
  v_other := coalesce(v_row.other_id, p_other);
  if p_other is not null and v_row.other_id is not null and p_other <> v_row.other_id then
    raise exception 'concept_relation_bad_request';
  end if;
  if v_other is not null and (v_other = v_row.concept_id or not exists (select 1 from public.concepts where id = v_other)) then
    raise exception 'concept_relation_not_found';
  end if;
  if p_resolution <> 'different' and v_other is null then
    raise exception 'concept_review_other_required';
  end if;
  if coalesce(p_reverse, false) and v_other is null then
    raise exception 'concept_review_other_required';
  end if;
  v_from := case when coalesce(p_reverse, false) then v_other else v_row.concept_id end;
  v_to := case when coalesce(p_reverse, false) then v_row.concept_id else v_other end;
  if p_resolution in ('extends', 'special_case') then
    perform public.concept_relation_put(v_from, v_to, p_resolution, 'review', v_row.draft_id, p_note);
  end if;
  update public.concept_reviews
     set status = 'resolved', resolution = p_resolution, concept_id = v_from, other_id = v_to,
         resolution_note = nullif(btrim(coalesce(p_note, '')), ''),
         resolved_by = auth.uid(), resolved_at = clock_timestamp()
   where id = p_id
  returning * into v_row;
  return to_jsonb(v_row);
end;
$$;

-- 같은 이름 검토 창: 두 개념의 판단을 남긴다. 열린 표시가 있으면 그것을 닫고, 없으면 닫힌 줄을 새로 쓴다.
create or replace function public.concept_review_decide_pair(
  p_concept uuid,
  p_other uuid,
  p_resolution text,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_reason text;
  v_out jsonb;
begin
  perform public.concept_relation_assert_operator();
  if p_concept is null or p_other is null or p_concept = p_other then
    raise exception 'concept_relation_bad_request';
  end if;
  if not exists (select 1 from public.concepts where id = p_concept)
     or not exists (select 1 from public.concepts where id = p_other) then
    raise exception 'concept_relation_not_found';
  end if;
  select id into v_id from public.concept_reviews
   where status = 'open' and concept_id = p_concept and other_id = p_other
   limit 1;
  if v_id is null then
    select case when lower(btrim(a.name)) = lower(btrim(b.name)) then 'same_name' else 'manual' end into v_reason
      from public.concepts a, public.concepts b
     where a.id = p_concept and b.id = p_other;
    insert into public.concept_reviews (concept_id, other_id, reason, created_by)
    values (p_concept, p_other, v_reason, auth.uid())
    returning id into v_id;
  end if;
  v_out := public.concept_review_resolve(v_id, p_resolution, null, p_note, false);
  update public.concept_reviews
     set status = 'resolved', resolution = p_resolution, resolution_note = nullif(btrim(coalesce(p_note, '')), ''),
         resolved_by = auth.uid(), resolved_at = clock_timestamp()
   where status = 'open' and concept_id = p_other and other_id = p_concept;
  return v_out;
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 3) 초안 확정
-- ─────────────────────────────────────────────────────────────────────────

create or replace function public.concept_draft_item_norm(p_item jsonb)
returns jsonb
language sql
immutable
set search_path = public
as $$
  select jsonb_build_object(
    'key', coalesce(nullif(btrim(p_item ->> 'key'), ''), 'c' || coalesce(p_item ->> 'index', '')),
    'index', coalesce(p_item -> 'index', 'null'::jsonb),
    'mark', coalesce(p_item -> 'mark', '"keep"'::jsonb),
    'title', coalesce(p_item -> 'title', '""'::jsonb),
    'content', coalesce(p_item -> 'content', '""'::jsonb),
    'type', coalesce(p_item -> 'type', '""'::jsonb),
    'folder', coalesce(p_item -> 'folder', '[]'::jsonb),
    'blocks', coalesce(p_item -> 'blocks', 'null'::jsonb),
    'merged_into', coalesce(p_item -> 'merged_into', 'null'::jsonb),
    'anchor', coalesce(p_item -> 'anchor', 'null'::jsonb),
    'relation', coalesce(p_item -> 'relation', 'null'::jsonb)
  )
$$;

create or replace function public.concept_draft_confirm(p_id uuid, p_expected_review_saved_at timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.concept_drafts;
  v_items jsonb;
  v_item jsonb;
  v_nt jsonb;
  v_total integer;
  v_seen text[] := '{}';
  v_key text;
  v_idx integer;
  v_mark text;
  v_title text;
  v_content text;
  v_type_name text;
  v_type uuid;
  v_sub text;
  v_desc text;
  v_path text[];
  v_seg text;
  v_parent uuid;
  v_parent_depth integer;
  v_cat uuid;
  v_family uuid;
  v_label text;
  v_n integer;
  v_concept uuid;
  v_page integer;
  v_order integer;
  v_display integer;
  v_blocks jsonb;
  v_block_ids text[];
  v_anchor_key text;
  v_target jsonb;
  v_anchor uuid;
  v_new_ids uuid[] := '{}';
  v_anchors integer := 0;
  v_concepts jsonb := '[]'::jsonb;
  v_folders jsonb := '[]'::jsonb;
  v_types jsonb := '[]'::jsonb;
  v_sources integer := 0;
  v_rel jsonb;
  v_rel_kind text;
  v_rel_target uuid;
  v_statement uuid;
  v_same uuid;
  v_overlap text;
  v_statements integer := 0;
  v_relations integer := 0;
  v_reviews integer := 0;
  v_sources_skipped integer := 0;
begin
  perform public.concept_draft_assert_operator();
  v_row := public.concept_draft_lock(p_id, p_expected_review_saved_at);
  if not exists (
    select 1
      from public.resource_files r
      join public.memberships m on m.academy_id = r.academy_id
     where r.id = v_row.book_id and r.academy_id = v_row.academy_id and m.user_id = auth.uid()
  ) then
    raise exception 'concept_draft_book_forbidden';
  end if;
  v_items := v_row.review -> 'concepts';
  if v_items is null or jsonb_typeof(v_items) <> 'array' then
    raise exception 'concept_draft_review_required';
  end if;
  v_total := coalesce(jsonb_array_length(v_row.draft -> 'concepts'), 0);
  v_block_ids := array(select b ->> 'id' from jsonb_array_elements(coalesce(v_row.prepared -> 'blocks', '[]'::jsonb)) b);

  if v_row.review ? 'new_types' and jsonb_typeof(v_row.review -> 'new_types') <> 'array' then
    raise exception 'concept_draft_bad_type';
  end if;
  for v_nt in select value from jsonb_array_elements(coalesce(v_row.review -> 'new_types', '[]'::jsonb)) loop
    continue when (v_nt -> 'accept') is distinct from 'true'::jsonb;
    v_type_name := btrim(coalesce(v_nt ->> 'name', ''));
    v_desc := btrim(coalesce(v_nt ->> 'description', ''));
    v_sub := v_nt ->> 'legacy_sub_type';
    if v_type_name = '' or char_length(v_type_name) > 40 or char_length(v_desc) > 500
       or v_sub is null or v_sub not in ('정의', '연산', '정리') then
      raise exception 'concept_draft_bad_type';
    end if;
    continue when exists (select 1 from public.concept_types where lower(btrim(name)) = lower(v_type_name));
    insert into public.concept_types (name, description, legacy_sub_type, sort_order, origin, draft_id, created_by)
    values (
      v_type_name, v_desc, v_sub,
      coalesce((select max(sort_order) + 1 from public.concept_types), 0),
      'draft', v_row.id, auth.uid()
    )
    returning id into v_type;
    v_types := v_types || jsonb_build_object('id', v_type, 'name', v_type_name);
  end loop;

  for v_item in select value from jsonb_array_elements(v_items) loop
    v_mark := v_item ->> 'mark';
    if v_mark is null or v_mark not in ('keep', 'edit', 'drop') then
      raise exception 'concept_draft_bad_review';
    end if;
    begin
      v_idx := (v_item ->> 'index')::integer;
    exception when others then
      raise exception 'concept_draft_bad_review';
    end;
    if v_idx is null or v_idx < 0 or v_idx >= v_total then
      raise exception 'concept_draft_bad_review';
    end if;
    v_key := coalesce(nullif(btrim(v_item ->> 'key'), ''), 'c' || v_idx);
    if v_key = any (v_seen) then
      raise exception 'concept_draft_bad_review';
    end if;
    v_seen := v_seen || v_key;
    continue when v_mark = 'drop';

    v_rel := v_item -> 'relation';
    v_rel_kind := null;
    v_rel_target := null;
    if v_rel is not null and jsonb_typeof(v_rel) <> 'null' then
      if jsonb_typeof(v_rel) <> 'object' then
        raise exception 'concept_draft_bad_relation';
      end if;
      v_rel_kind := v_rel ->> 'kind';
      if v_rel_kind is null or v_rel_kind not in ('new', 'statement', 'extends', 'special_case', 'review') then
        raise exception 'concept_draft_bad_relation';
      end if;
      begin
        v_rel_target := nullif(v_rel ->> 'concept_id', '')::uuid;
      exception when others then
        raise exception 'concept_draft_bad_relation';
      end;
      if v_rel_kind in ('statement', 'extends', 'special_case') and v_rel_target is null then
        raise exception 'concept_draft_relation_target_required';
      end if;
      if v_rel_kind = 'new' then
        v_rel_target := null;
      end if;
      if v_rel_target is not null and not exists (select 1 from public.concepts where id = v_rel_target) then
        raise exception 'concept_draft_relation_target_not_found';
      end if;
    end if;

    if jsonb_typeof(v_item -> 'blocks') = 'array' then
      v_blocks := v_item -> 'blocks';
      if exists (
        select 1 from jsonb_array_elements(v_blocks) b
         where jsonb_typeof(b) <> 'string' or not ((b #>> '{}') = any (v_block_ids))
      ) then
        raise exception 'concept_draft_bad_review';
      end if;
    elsif v_item ? 'blocks' and jsonb_typeof(v_item -> 'blocks') <> 'null' then
      raise exception 'concept_draft_bad_review';
    else
      v_blocks := coalesce(v_row.draft -> 'concepts' -> v_idx -> 'source_blocks', '[]'::jsonb);
    end if;

    v_title := btrim(coalesce(v_item ->> 'title', ''));
    v_content := btrim(coalesce(v_item ->> 'content', ''));
    if v_title = '' or v_content = '' then
      raise exception 'concept_draft_text_required';
    end if;
    if char_length(v_title) > 200 or char_length(v_content) > 20000 then
      raise exception 'concept_draft_too_long';
    end if;

    -- 서술로 붙인 항목은 새 개념이 아니라서 주제 묶음(anchor)을 잇지 않는다.
    if v_rel_kind = 'statement' then
      insert into public.concept_statements
        (concept_id, role, sort_order, draft, draft_origin, draft_saved_at, draft_saved_by, created_by)
      values (
        v_rel_target, 'statement',
        coalesce((select max(sort_order) + 1 from public.concept_statements where concept_id = v_rel_target and role = 'statement'), 0),
        public.concept_statement_clean('statement', jsonb_build_object('title', v_title, 'body', v_content, 'basis', 'organized')),
        case when v_mark = 'keep' then 'ai' else 'owner' end,
        clock_timestamp(), auth.uid(), auth.uid()
      )
      returning id into v_statement;
      for v_page, v_order in
        with page_blocks as (
          select (b ->> 'raw_page')::integer as raw_page,
                 b ->> 'id' as id,
                 row_number() over (partition by (b ->> 'raw_page')::integer order by t.n) as pos
            from jsonb_array_elements(coalesce(v_row.prepared -> 'blocks', '[]'::jsonb)) with ordinality as t(b, n)
        )
        select pb.raw_page, min(pb.pos)::integer
          from page_blocks pb
         where pb.id in (select jsonb_array_elements_text(v_blocks))
         group by pb.raw_page
         order by 1
      loop
        select nullif((pm ->> 'display_page'), '')::integer into v_display
          from jsonb_array_elements(v_row.page_meta) pm
         where (pm ->> 'raw_page')::integer = v_page
         limit 1;
        insert into public.concept_sources
          (concept_id, academy_id, book_id, grade_label, raw_page, display_page, unit_path, page_order, statement_id, created_by)
        values (v_rel_target, v_row.academy_id, v_row.book_id, v_row.grade_label, v_page,
                case when v_display > 0 then v_display end, v_row.unit_path, v_order, v_statement, auth.uid())
        on conflict (concept_id, book_id, grade_label, raw_page) do nothing;
        if found then
          v_sources := v_sources + 1;
        else
          v_sources_skipped := v_sources_skipped + 1;
        end if;
      end loop;
      v_statements := v_statements + 1;
      v_concepts := v_concepts || jsonb_build_object(
        'index', v_idx, 'key', v_key, 'id', v_rel_target, 'statement_id', v_statement, 'relation', 'statement'
      );
      continue;
    end if;

    v_type_name := btrim(coalesce(v_item ->> 'type', ''));
    if v_type_name = '' then
      raise exception 'concept_draft_type_required';
    end if;
    v_type := null;
    select id, legacy_sub_type into v_type, v_sub
      from public.concept_types
     where lower(btrim(name)) = lower(v_type_name);
    if v_type is null then
      raise exception 'concept_draft_unknown_type';
    end if;

    if jsonb_typeof(v_item -> 'folder') is distinct from 'array' then
      raise exception 'concept_draft_bad_folder';
    end if;
    v_path := array(select btrim(x) from jsonb_array_elements_text(v_item -> 'folder') with ordinality as t(x, n) order by n);
    if cardinality(v_path) < 2 or cardinality(v_path) > 7 then
      raise exception 'concept_draft_bad_folder';
    end if;
    foreach v_seg in array v_path loop
      if v_seg = '' or char_length(v_seg) > 80 then
        raise exception 'concept_draft_bad_folder';
      end if;
    end loop;

    select id, depth into v_parent, v_parent_depth
      from public.concept_categories
     where parent_id is null and name = v_path[1]
     order by sort_order, created_at
     limit 1;
    if v_parent is null then
      raise exception 'concept_draft_unknown_root';
    end if;
    for v_n in 2 .. cardinality(v_path) loop
      v_cat := null;
      select id into v_cat
        from public.concept_categories
       where parent_id = v_parent and name = v_path[v_n] and coalesce(code, '') <> 'SHORTCUT'
       order by sort_order, created_at
       limit 1;
      if v_cat is null then
        insert into public.concept_categories (name, parent_id, depth, sort_order)
        values (
          v_path[v_n], v_parent, v_parent_depth + 1,
          coalesce((select max(sort_order) + 1 from public.concept_categories where parent_id = v_parent), 0)
        )
        returning id into v_cat;
        v_folders := v_folders || jsonb_build_object('id', v_cat, 'path', to_jsonb(v_path[1:v_n]));
      end if;
      v_parent := v_cat;
      v_parent_depth := v_parent_depth + 1;
    end loop;

    -- 이 초안에서 만들기 전의 라이브러리에서 이름이 같은 개념(검토 표시 상대).
    v_same := null;
    if v_rel_kind is null then
      select id into v_same
        from public.concepts
       where lower(btrim(name)) = lower(v_title) and not (id = any (v_new_ids))
       order by created_at, id
       limit 1;
    end if;

    insert into public.concept_families (canonical_name) values (v_title) on conflict (canonical_name) do nothing;
    select id into v_family from public.concept_families where canonical_name = v_title;
    v_label := '기본';
    v_n := 1;
    while exists (select 1 from public.concepts where family_id = v_family and version_label = v_label) loop
      v_n := v_n + 1;
      v_label := '기본-' || v_n;
    end loop;

    insert into public.concepts (kind, sub_type, name, content, level, main_category_id, sort_order, family_id, version_label)
    values (
      case when v_sub = '정의' then 'definition' else 'theorem' end,
      v_sub, v_title, v_content, 1, v_parent,
      coalesce((select max(sort_order) + 1 from public.concepts where main_category_id = v_parent), 0),
      v_family, v_label
    )
    returning id into v_concept;

    insert into public.concept_type_links (concept_id, type_id, draft_id, created_by)
    values (v_concept, v_type, v_row.id, auth.uid());

    for v_page, v_order in
      with page_blocks as (
        select (b ->> 'raw_page')::integer as raw_page,
               b ->> 'id' as id,
               row_number() over (partition by (b ->> 'raw_page')::integer order by t.n) as pos
          from jsonb_array_elements(coalesce(v_row.prepared -> 'blocks', '[]'::jsonb)) with ordinality as t(b, n)
      )
      select pb.raw_page, min(pb.pos)::integer
        from page_blocks pb
       where pb.id in (select jsonb_array_elements_text(v_blocks))
       group by pb.raw_page
       order by 1
    loop
      select nullif((pm ->> 'display_page'), '')::integer into v_display
        from jsonb_array_elements(v_row.page_meta) pm
       where (pm ->> 'raw_page')::integer = v_page
       limit 1;
      insert into public.concept_sources (concept_id, academy_id, book_id, grade_label, raw_page, display_page, unit_path, page_order, created_by)
      values (v_concept, v_row.academy_id, v_row.book_id, v_row.grade_label, v_page,
              case when v_display > 0 then v_display end, v_row.unit_path, v_order, auth.uid());
      v_sources := v_sources + 1;
    end loop;

    if v_rel_kind in ('extends', 'special_case') then
      perform public.concept_relation_put(v_concept, v_rel_target, v_rel_kind, 'draft', v_row.id, null);
      v_relations := v_relations + 1;
    elsif v_rel_kind = 'review' then
      insert into public.concept_reviews (concept_id, other_id, reason, draft_id, created_by)
      values (v_concept, v_rel_target, 'draft', v_row.id, auth.uid());
      v_reviews := v_reviews + 1;
    elsif v_rel_kind is null then
      if v_same is not null then
        insert into public.concept_reviews (concept_id, other_id, reason, draft_id, created_by)
        values (v_concept, v_same, 'same_name', v_row.id, auth.uid());
        v_reviews := v_reviews + 1;
      else
        select left(string_agg(btrim(o ->> 'other') || coalesce(nullif(' (' || btrim(o ->> 'reason') || ')', ' ()'), ''), ' · '), 500)
          into v_overlap
          from jsonb_array_elements(
                 case when jsonb_typeof(v_row.folder_plan -> 'overlaps') = 'array' then v_row.folder_plan -> 'overlaps' else '[]'::jsonb end
               ) o
         where o ->> 'concept' = v_idx::text and btrim(coalesce(o ->> 'other', '')) <> '';
        if v_overlap is not null then
          insert into public.concept_reviews (concept_id, other_id, reason, note, draft_id, created_by)
          values (v_concept, null, 'overlap', v_overlap, v_row.id, auth.uid());
          v_reviews := v_reviews + 1;
        end if;
      end if;
    end if;

    v_new_ids := v_new_ids || v_concept;
    v_concepts := v_concepts || jsonb_build_object(
      'index', v_idx, 'key', v_key, 'id', v_concept, 'category_id', v_parent, 'type_id', v_type,
      'relation', coalesce(v_rel_kind, 'auto')
    );
  end loop;

  if jsonb_array_length(v_concepts) = 0 then
    raise exception 'concept_draft_nothing_kept';
  end if;

  for v_item in select value from jsonb_array_elements(v_items) loop
    continue when v_item ->> 'mark' = 'drop';
    v_anchor_key := nullif(btrim(coalesce(v_item ->> 'anchor', '')), '');
    continue when v_anchor_key is null;
    v_key := coalesce(nullif(btrim(v_item ->> 'key'), ''), 'c' || (v_item ->> 'index'));
    select x into v_target
      from jsonb_array_elements(v_items) x
     where coalesce(nullif(btrim(x ->> 'key'), ''), 'c' || (x ->> 'index')) = v_anchor_key
     limit 1;
    if v_target ->> 'mark' = 'drop' and nullif(btrim(coalesce(v_target ->> 'merged_into', '')), '') is not null then
      v_anchor_key := btrim(v_target ->> 'merged_into');
    end if;
    v_concept := null;
    v_anchor := null;
    select (c ->> 'id')::uuid, (c ->> 'category_id')::uuid into v_concept, v_parent
      from jsonb_array_elements(v_concepts) c where c ->> 'key' = v_key and c ->> 'relation' <> 'statement';
    select (c ->> 'id')::uuid, (c ->> 'category_id')::uuid into v_anchor, v_cat
      from jsonb_array_elements(v_concepts) c where c ->> 'key' = v_anchor_key and c ->> 'relation' <> 'statement';
    continue when v_concept is null or v_anchor is null or v_anchor = v_concept or v_cat is distinct from v_parent;
    insert into public.concept_anchor_links (concept_id, anchor_id, origin, draft_id, created_by)
    values (v_concept, v_anchor, 'draft', v_row.id, auth.uid());
    v_anchors := v_anchors + 1;
  end loop;
  if v_anchors > 0 and public.concept_anchor_has_cycle(v_new_ids) then
    raise exception 'concept_anchor_cycle';
  end if;

  update public.concept_drafts
     set status = 'confirmed', confirmed_at = clock_timestamp(), confirmed_by = auth.uid(), closed_at = clock_timestamp(),
         result = jsonb_build_object('concepts', v_concepts, 'folders', v_folders, 'types', v_types, 'sources', v_sources,
                                     'anchors', v_anchors, 'statements', v_statements, 'relations', v_relations,
                                     'reviews', v_reviews, 'sources_skipped', v_sources_skipped)
   where id = p_id
  returning * into v_row;
  return jsonb_build_object('id', v_row.id, 'status', v_row.status, 'result', v_row.result);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 4) 접근
-- ─────────────────────────────────────────────────────────────────────────

alter table public.concept_relations enable row level security;
alter table public.concept_reviews enable row level security;

drop policy if exists concept_relations_operator_select on public.concept_relations;
create policy concept_relations_operator_select on public.concept_relations
  for select to authenticated
  using ((select public.is_superadmin()));

drop policy if exists concept_reviews_operator_select on public.concept_reviews;
create policy concept_reviews_operator_select on public.concept_reviews
  for select to authenticated
  using ((select public.is_superadmin()));

revoke all on public.concept_relations, public.concept_reviews from anon;
revoke insert, update, delete, truncate on public.concept_relations, public.concept_reviews from authenticated;

revoke all on function public.concept_relation_assert_operator() from public, anon, authenticated;
revoke all on function public.concept_relation_put(uuid, uuid, text, text, uuid, text) from public, anon, authenticated;
revoke all on function public.concept_relation_set(uuid, uuid, text, text) from public, anon;
revoke all on function public.concept_relation_remove(uuid) from public, anon;
revoke all on function public.concept_review_open(uuid, uuid, text) from public, anon;
revoke all on function public.concept_review_resolve(uuid, text, uuid, text, boolean) from public, anon;
revoke all on function public.concept_review_decide_pair(uuid, uuid, text, text) from public, anon;

grant execute on function public.concept_relation_set(uuid, uuid, text, text) to authenticated;
grant execute on function public.concept_relation_remove(uuid) to authenticated;
grant execute on function public.concept_review_open(uuid, uuid, text) to authenticated;
grant execute on function public.concept_review_resolve(uuid, text, uuid, text, boolean) to authenticated;
grant execute on function public.concept_review_decide_pair(uuid, uuid, text, text) to authenticated;

notify pgrst, 'reload schema';
