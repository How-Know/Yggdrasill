-- 20261020180000: 새 교재 항목을 기존 개념과 비교해 넣기 (운영자 결정 2026-10-20, 여러 교재 설명 통합 3단계)
--
-- 설계: docs/architecture/concept-library.md §4.3
--
-- 초안 검토 항목의 관계(relation.kind)에 셋을 더한다. 기존 다섯(new·statement·extends·special_case·review)은 그대로다.
--   source  출처만 연결. 기존 개념(relation.concept_id)의 기본 서술 또는 고른 서술(relation.statement_id)에 이 항목의 근거 쪽만
--           출처로 잇는다(근거 블록 포함, 범위 미확인). 새 개념·서술·본문은 만들지 않는다.
--   revise  대표 서술 수정안. 기본 서술에 출처를 잇고, 항목 글을 그 개념의 기본 서술 수정안(concept_content_drafts)으로 저장한다.
--           검토에서 그대로 둔 글은 origin 'ai', 고친 글은 'owner'. 본문은 바꾸지 않는다(1단계 창에서 이유를 적어 확정해야 바뀐다).
--           그 개념에 이미 수정안이 있으면 덮어쓰지 않고 확정을 막는다(concept_draft_revise_draft_exists).
--   hold    보류. 이번 확정에 넣지 않고 concept_draft_holds 에 남긴다. 나중에 "다시 검토"로 같은 초안 기록에서 새 검토 초안을 만들거나 버린다.
-- 이 셋은 새 개념이 아니라서 유형·폴더·주제 묶음을 쓰지 않는다.
-- 비교 칸·AI 비교 제안은 concept_compare_targets 로 기존 개념의 본문·서술·출처 수·수정안 유무를 읽기만 한다.

-- ─────────────────────────────────────────────────────────────────────────
-- 1) 보류
-- ─────────────────────────────────────────────────────────────────────────

alter table public.concept_drafts
  add column if not exists holds_of uuid references public.concept_drafts(id) on delete set null;

create table if not exists public.concept_draft_holds (
  id uuid primary key default gen_random_uuid(),
  draft_id uuid not null references public.concept_drafts(id) on delete cascade,
  item_key text not null check (btrim(item_key) <> ''),
  -- 확정할 때의 검토 항목(이름·내용·유형·폴더·근거 블록·관계).
  item jsonb not null check (jsonb_typeof(item) = 'object'),
  status text not null default 'open' check (status in ('open', 'reopened', 'dropped')),
  note text check (note is null or char_length(note) <= 500),
  reopened_draft_id uuid references public.concept_drafts(id) on delete set null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  closed_by uuid references auth.users(id) on delete set null,
  closed_at timestamptz,
  unique (draft_id, item_key),
  constraint concept_draft_holds_closed_chk check ((status = 'open') = (closed_at is null))
);

create index if not exists concept_draft_holds_open_idx on public.concept_draft_holds (created_at desc) where status = 'open';

-- 다시 처리할 보류 항목. 열린 것과, 다시 연 초안을 버려 되돌아온 것.
create or replace function public.concept_draft_holds_open()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.concept_draft_assert_operator();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', h.id, 'draft_id', h.draft_id, 'item_key', h.item_key,
             'title', h.item ->> 'title', 'content', h.item ->> 'content', 'relation', h.item -> 'relation',
             'status', h.status, 'created_at', h.created_at,
             'book_id', s.book_id, 'book_name', s.book_name, 'grade_label', s.grade_label, 'unit_path', to_jsonb(s.unit_path)
           ) order by h.created_at desc, h.item_key)
      from public.concept_draft_holds h
      join public.concept_drafts s on s.id = h.draft_id
      left join public.concept_drafts d on d.id = h.reopened_draft_id
     where h.status = 'open' or (h.status = 'reopened' and (d.id is null or d.status = 'discarded'))
  ), '[]'::jsonb);
end;
$$;

-- 보류 항목을 같은 초안 기록(쪽 전사·AI 초안·폴더 제안)으로 새 검토 초안에 다시 넣는다. 한 초안의 열린 보류를 모두 넣고,
-- 보류는 'reopened'로 닫는다. 다시 연 초안을 버렸으면 그 보류는 다시 열 수 있다. 새 초안의 검토는 보류 항목만이고 관계·붙일 개념은 비운다.
create or replace function public.concept_draft_hold_reopen(p_draft_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_src public.concept_drafts;
  v_items jsonb;
  v_ids uuid[];
  v_new uuid;
begin
  perform public.concept_draft_assert_operator();
  select * into v_src from public.concept_drafts where id = p_draft_id;
  if not found then
    raise exception 'concept_draft_not_found';
  end if;
  if not exists (
    select 1
      from public.resource_files r
      join public.memberships m on m.academy_id = r.academy_id
     where r.id = v_src.book_id and r.academy_id = v_src.academy_id and m.user_id = auth.uid()
  ) then
    raise exception 'concept_draft_book_forbidden';
  end if;
  perform 1 from public.concept_draft_holds where draft_id = p_draft_id for update;
  select array_agg(h.id order by h.created_at, h.item_key),
         jsonb_agg((h.item - 'anchor' - 'merged_into') || jsonb_build_object('relation', null) order by h.created_at, h.item_key)
    into v_ids, v_items
    from public.concept_draft_holds h
    left join public.concept_drafts d on d.id = h.reopened_draft_id
   where h.draft_id = p_draft_id
     and (h.status = 'open' or (h.status = 'reopened' and (d.id is null or d.status = 'discarded')));
  if v_ids is null then
    raise exception 'concept_draft_no_holds';
  end if;
  insert into public.concept_drafts
    (academy_id, book_id, grade_label, book_name, unit_path, pages, page_meta, model, prompt_version, criteria,
     prepared, draft, checks, folder_plan, concept_types, review, review_saved_at, review_saved_by, created_by, holds_of)
  values
    (v_src.academy_id, v_src.book_id, v_src.grade_label, v_src.book_name, v_src.unit_path, v_src.pages, v_src.page_meta,
     v_src.model, v_src.prompt_version, v_src.criteria, v_src.prepared, v_src.draft, v_src.checks, v_src.folder_plan,
     v_src.concept_types, jsonb_build_object('concepts', v_items), clock_timestamp(), auth.uid(), auth.uid(), v_src.id)
  returning id into v_new;
  update public.concept_draft_holds
     set status = 'reopened', reopened_draft_id = v_new, closed_at = clock_timestamp(), closed_by = auth.uid()
   where id = any (v_ids);
  return jsonb_build_object('draft_id', v_new, 'holds', cardinality(v_ids));
end;
$$;

-- 보류 항목을 넣지 않기로 하고 닫는다. 초안 기록은 그대로다.
create or replace function public.concept_draft_hold_drop(p_hold_id uuid, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.concept_draft_holds;
begin
  perform public.concept_draft_assert_operator();
  if char_length(coalesce(p_note, '')) > 500 then
    raise exception 'concept_draft_too_long';
  end if;
  update public.concept_draft_holds
     set status = 'dropped', note = nullif(btrim(coalesce(p_note, '')), ''), closed_at = clock_timestamp(), closed_by = auth.uid()
   where id = p_hold_id
     and (status = 'open' or (status = 'reopened' and not exists (
           select 1 from public.concept_drafts d where d.id = reopened_draft_id and d.status <> 'discarded')))
  returning * into v_row;
  if not found then
    raise exception 'concept_draft_hold_closed';
  end if;
  return to_jsonb(v_row);
end;
$$;

-- 비교할 기존 개념(검토 화면 비교 칸·AI 비교 제안이 읽는다). 읽기만 한다.
--   [{id, name, folder[], content, content_md5, statements[{id, confirmed, text}], sources, books[], content_draft}]
-- 서술 글은 확정본이 있으면 확정본, 없으면 확정 전 글이다(concept_source_basis 와 같은 모양).
create or replace function public.concept_compare_targets(p_ids uuid[])
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.concept_draft_assert_operator();
  if cardinality(coalesce(p_ids, '{}'::uuid[])) > 50 then
    raise exception 'concept_compare_too_many';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', c.id,
             'name', c.name,
             'folder', coalesce((
               with recursive up as (
                 select k.id, k.parent_id, k.name, 0 as n from public.concept_categories k where k.id = c.main_category_id
                 union all
                 select k.id, k.parent_id, k.name, up.n + 1 from public.concept_categories k join up on k.id = up.parent_id where up.n < 12
               )
               select jsonb_agg(up.name order by up.n desc) from up
             ), '[]'::jsonb),
             'content', coalesce(c.content, ''),
             'content_md5', md5(coalesce(c.content, '')),
             'statements', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'id', s.id,
                        'confirmed', s.version > 0,
                        'text', concat_ws(E'\n', coalesce(s.content, s.draft) ->> 'title', coalesce(s.content, s.draft) ->> 'body',
                                          case when coalesce(s.content, s.draft) ? 'conditions'
                                               then '적용 대상·조건: ' || (coalesce(s.content, s.draft) ->> 'conditions') end)
                      ) order by s.sort_order, s.created_at)
                 from public.concept_statements s
                where s.concept_id = c.id and s.role = 'statement'
             ), '[]'::jsonb),
             'sources', (select count(*) from public.concept_sources s where s.concept_id = c.id),
             'books', coalesce((
               select jsonb_agg(distinct r.name)
                 from public.concept_sources s join public.resource_files r on r.id = s.book_id
                where s.concept_id = c.id
             ), '[]'::jsonb),
             'content_draft', exists (select 1 from public.concept_content_drafts d where d.concept_id = c.id)
           ) order by array_position(p_ids, c.id))
      from public.concepts c
     where c.id = any (p_ids)
  ), '[]'::jsonb);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 2) 초안 확정: 20261020160000 과 같고, 관계 source·revise·hold 를 더한 것만 다르다.
-- ─────────────────────────────────────────────────────────────────────────

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
  v_page_blocks text[];
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
  v_rel_statement uuid;
  v_base text;
  v_revised boolean;
  v_holds integer := 0;
  v_linked integer := 0;
  v_revises integer := 0;
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
    v_rel_statement := null;
    if v_rel is not null and jsonb_typeof(v_rel) <> 'null' then
      if jsonb_typeof(v_rel) <> 'object' then
        raise exception 'concept_draft_bad_relation';
      end if;
      v_rel_kind := v_rel ->> 'kind';
      if v_rel_kind is null
         or v_rel_kind not in ('new', 'statement', 'source', 'revise', 'extends', 'special_case', 'review', 'hold') then
        raise exception 'concept_draft_bad_relation';
      end if;
      begin
        v_rel_target := nullif(v_rel ->> 'concept_id', '')::uuid;
        v_rel_statement := case when v_rel_kind = 'source' then nullif(v_rel ->> 'statement_id', '')::uuid end;
      exception when others then
        raise exception 'concept_draft_bad_relation';
      end;
      if v_rel_kind in ('statement', 'source', 'revise', 'extends', 'special_case') and v_rel_target is null then
        raise exception 'concept_draft_relation_target_required';
      end if;
      if v_rel_kind = 'new' then
        v_rel_target := null;
      end if;
      if v_rel_target is not null and not exists (select 1 from public.concepts where id = v_rel_target) then
        raise exception 'concept_draft_relation_target_not_found';
      end if;
      if v_rel_statement is not null and not exists (
        select 1 from public.concept_statements
         where id = v_rel_statement and concept_id = v_rel_target and role = 'statement'
      ) then
        raise exception 'concept_draft_relation_statement_not_found';
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

    if v_rel_kind = 'hold' then
      insert into public.concept_draft_holds (draft_id, item_key, item, created_by)
      values (v_row.id, v_key, public.concept_draft_item_norm(v_item) || jsonb_build_object('blocks', v_blocks), auth.uid());
      v_holds := v_holds + 1;
      continue;
    end if;

    -- 기존 개념에 붙이는 항목(서술·출처만·수정안)은 새 개념이 아니라서 주제 묶음(anchor)을 잇지 않는다.
    if v_rel_kind in ('statement', 'source', 'revise') then
      v_statement := null;
      v_revised := false;
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
      elsif v_rel_kind = 'source' then
        v_statement := v_rel_statement;
      else
        v_base := public.concept_content_lock_concept(v_rel_target);
        if exists (select 1 from public.concept_content_drafts where concept_id = v_rel_target) then
          raise exception 'concept_draft_revise_draft_exists';
        end if;
        if v_content <> btrim(coalesce(v_base, '')) then
          insert into public.concept_content_drafts (concept_id, content, base_md5, note, origin, saved_at, saved_by)
          values (
            v_rel_target, v_content, md5(coalesce(v_base, '')),
            left('교재 초안에서 온 수정안: ' || concat_ws(' · ', nullif(btrim(v_row.book_name || ' ' || v_row.grade_label), ''),
                 nullif(array_to_string(v_row.unit_path, ' > '), ''), v_title), 2000),
            case when v_mark = 'keep' then 'ai' else 'owner' end,
            clock_timestamp(), auth.uid()
          );
          v_revised := true;
        end if;
      end if;
      for v_page, v_order, v_page_blocks in
        with page_blocks as (
          select (b ->> 'raw_page')::integer as raw_page,
                 b ->> 'id' as id,
                 row_number() over (partition by (b ->> 'raw_page')::integer order by t.n) as pos
            from jsonb_array_elements(coalesce(v_row.prepared -> 'blocks', '[]'::jsonb)) with ordinality as t(b, n)
        )
        select pb.raw_page, min(pb.pos)::integer, (array_agg(pb.id order by pb.pos))[1:200]
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
          (concept_id, academy_id, book_id, grade_label, raw_page, display_page, unit_path, page_order, statement_id,
           draft_id, block_ids, created_by)
        values (v_rel_target, v_row.academy_id, v_row.book_id, v_row.grade_label, v_page,
                case when v_display > 0 then v_display end, v_row.unit_path, v_order, v_statement,
                v_row.id, v_page_blocks, auth.uid())
        on conflict (concept_id, (coalesce(statement_id, '00000000-0000-0000-0000-000000000000'::uuid)), book_id, grade_label, raw_page)
        do nothing;
        if found then
          v_sources := v_sources + 1;
        else
          v_sources_skipped := v_sources_skipped + 1;
        end if;
      end loop;
      if v_rel_kind = 'statement' then
        v_statements := v_statements + 1;
        v_concepts := v_concepts || jsonb_build_object(
          'index', v_idx, 'key', v_key, 'id', v_rel_target, 'statement_id', v_statement, 'relation', 'statement'
        );
      elsif v_rel_kind = 'source' then
        v_linked := v_linked + 1;
        v_concepts := v_concepts || jsonb_build_object(
          'index', v_idx, 'key', v_key, 'id', v_rel_target, 'statement_id', v_statement, 'relation', 'source'
        );
      else
        if v_revised then
          v_revises := v_revises + 1;
        end if;
        v_concepts := v_concepts || jsonb_build_object(
          'index', v_idx, 'key', v_key, 'id', v_rel_target, 'relation', 'revise', 'content_draft', v_revised
        );
      end if;
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

    for v_page, v_order, v_page_blocks in
      with page_blocks as (
        select (b ->> 'raw_page')::integer as raw_page,
               b ->> 'id' as id,
               row_number() over (partition by (b ->> 'raw_page')::integer order by t.n) as pos
          from jsonb_array_elements(coalesce(v_row.prepared -> 'blocks', '[]'::jsonb)) with ordinality as t(b, n)
      )
      select pb.raw_page, min(pb.pos)::integer, (array_agg(pb.id order by pb.pos))[1:200]
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
        (concept_id, academy_id, book_id, grade_label, raw_page, display_page, unit_path, page_order, draft_id, block_ids, created_by)
      values (v_concept, v_row.academy_id, v_row.book_id, v_row.grade_label, v_page,
              case when v_display > 0 then v_display end, v_row.unit_path, v_order, v_row.id, v_page_blocks, auth.uid());
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

  if jsonb_array_length(v_concepts) = 0 and v_holds = 0 then
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
      from jsonb_array_elements(v_concepts) c
     where c ->> 'key' = v_key and c ->> 'relation' not in ('statement', 'source', 'revise');
    select (c ->> 'id')::uuid, (c ->> 'category_id')::uuid into v_anchor, v_cat
      from jsonb_array_elements(v_concepts) c
     where c ->> 'key' = v_anchor_key and c ->> 'relation' not in ('statement', 'source', 'revise');
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
                                     'reviews', v_reviews, 'sources_skipped', v_sources_skipped,
                                     'linked', v_linked, 'revises', v_revises, 'holds', v_holds)
   where id = p_id
  returning * into v_row;
  return jsonb_build_object('id', v_row.id, 'status', v_row.status, 'result', v_row.result);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 3) 접근
-- ─────────────────────────────────────────────────────────────────────────

alter table public.concept_draft_holds enable row level security;

drop policy if exists concept_draft_holds_operator_select on public.concept_draft_holds;
create policy concept_draft_holds_operator_select on public.concept_draft_holds
  for select to authenticated
  using ((select public.is_superadmin()));

revoke all on public.concept_draft_holds from anon;
revoke insert, update, delete, truncate on public.concept_draft_holds from authenticated;

revoke all on function public.concept_compare_targets(uuid[]) from public, anon;
grant execute on function public.concept_compare_targets(uuid[]) to authenticated;
revoke all on function public.concept_draft_holds_open() from public, anon;
grant execute on function public.concept_draft_holds_open() to authenticated;
revoke all on function public.concept_draft_hold_reopen(uuid) from public, anon;
revoke all on function public.concept_draft_hold_drop(uuid, text) from public, anon;
grant execute on function public.concept_draft_hold_reopen(uuid) to authenticated;
grant execute on function public.concept_draft_hold_drop(uuid, text) to authenticated;

notify pgrst, 'reload schema';
