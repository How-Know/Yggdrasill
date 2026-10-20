-- 개념 주제 묶음과 수학 순서(운영자 결정 2026-10-18).
-- 설계: docs/architecture/concept-library.md §4.1
--
-- concept_anchor_links  개념 → 바로 앞에 알아야 하는 개념(같은 폴더). 여러 단계로 이어질 수 있고 돌아오는 고리는 막는다.
--                       라이브러리 트리는 폴더 안 개념을 이 묶음과 유형 순서로 늘어놓는다.
--                       origin: draft(초안 확정 때 검토 항목의 anchor), proposal(폴더 묶음 제안을 승인), manual(개념 상세에서 직접).
--                       나중에 한쪽이 다른 폴더로 옮겨 가면 연결은 남고 화면은 쓰지 않는다.
-- concept_types.sort_order  수학 순서(정의 → 표현 → 주의 → 성질 → 방법). 확정 때 더해진 유형은 그 뒤에 그대로 둔다.
-- concept_draft_item_norm   검토 항목의 anchor(같은 초안 항목의 key)를 남긴다(Think 변경 카드 승인 때 없어지지 않게).
-- concept_draft_confirm     20261018100000 과 같고, 마지막에 남긴 항목끼리의 anchor 를 같은 폴더일 때만 잇는 것만 다르다.
--                           합쳐서 빠진 항목을 가리키면 합친 항목으로 잇고, 뺀 항목·없는 key 는 잇지 않는다.

create table if not exists public.concept_anchor_links (
  concept_id uuid primary key references public.concepts(id) on delete cascade,
  anchor_id uuid not null references public.concepts(id) on delete cascade,
  origin text not null check (origin in ('draft', 'proposal', 'manual')),
  draft_id uuid references public.concept_drafts(id) on delete set null,
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  constraint concept_anchor_links_self_chk check (concept_id <> anchor_id)
);

create index if not exists concept_anchor_links_anchor_idx on public.concept_anchor_links (anchor_id);

update public.concept_types
   set sort_order = case lower(btrim(name)) when '정의' then 0 when '표현' then 1 when '주의' then 2 when '성질' then 3 when '방법' then 4 end
 where origin = 'seed' and lower(btrim(name)) in ('정의', '표현', '주의', '성질', '방법');

-- p_ids 중 하나에서 연결을 따라가 자기에게 돌아오면 true.
create or replace function public.concept_anchor_has_cycle(p_ids uuid[])
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  with recursive walk(start_id, cur, depth) as (
    select l.concept_id, l.anchor_id, 1
      from public.concept_anchor_links l
     where l.concept_id = any (p_ids)
    union all
    select w.start_id, l.anchor_id, w.depth + 1
      from walk w
      join public.concept_anchor_links l on l.concept_id = w.cur
     where w.cur <> w.start_id and w.depth < 1000
  )
  select exists (select 1 from walk where cur = start_id);
$$;

-- 묶음을 바꾼다. p_links: [{concept_id, anchor_id|null}] (null 이면 묶음에서 뺀다). 붙일 개념은 같은 폴더여야 한다.
-- 하나라도 어긋나거나 고리가 생기면 아무것도 바뀌지 않는다.
create or replace function public.concept_anchor_set(p_links jsonb, p_origin text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_link jsonb;
  v_concept uuid;
  v_anchor uuid;
  v_cat uuid;
  v_anchor_cat uuid;
  v_ids uuid[] := '{}';
  v_set integer := 0;
  v_cleared integer := 0;
begin
  perform public.concept_draft_assert_operator();
  if p_origin is null or p_origin not in ('proposal', 'manual') then
    raise exception 'concept_anchor_bad_request';
  end if;
  if jsonb_typeof(p_links) is distinct from 'array' or jsonb_array_length(p_links) = 0 or jsonb_array_length(p_links) > 300 then
    raise exception 'concept_anchor_bad_request';
  end if;
  for v_link in select value from jsonb_array_elements(p_links) loop
    begin
      v_concept := (v_link ->> 'concept_id')::uuid;
      v_anchor := nullif(v_link ->> 'anchor_id', '')::uuid;
    exception when others then
      raise exception 'concept_anchor_bad_request';
    end;
    if v_concept is null or v_concept = any (v_ids) then
      raise exception 'concept_anchor_bad_request';
    end if;
    v_ids := v_ids || v_concept;
    select main_category_id into v_cat from public.concepts where id = v_concept;
    if not found then
      raise exception 'concept_anchor_not_found';
    end if;
    if v_anchor is null then
      delete from public.concept_anchor_links where concept_id = v_concept;
      v_cleared := v_cleared + 1;
      continue;
    end if;
    if v_anchor = v_concept then
      raise exception 'concept_anchor_bad_request';
    end if;
    select main_category_id into v_anchor_cat from public.concepts where id = v_anchor;
    if not found then
      raise exception 'concept_anchor_not_found';
    end if;
    if v_anchor_cat is distinct from v_cat then
      raise exception 'concept_anchor_other_folder';
    end if;
    insert into public.concept_anchor_links (concept_id, anchor_id, origin, created_by)
    values (v_concept, v_anchor, p_origin, auth.uid())
    on conflict (concept_id) do update
      set anchor_id = excluded.anchor_id, origin = excluded.origin, draft_id = null,
          created_by = excluded.created_by, updated_at = now();
    v_set := v_set + 1;
  end loop;
  if public.concept_anchor_has_cycle(v_ids) then
    raise exception 'concept_anchor_cycle';
  end if;
  return jsonb_build_object('set', v_set, 'cleared', v_cleared);
end;
$$;

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
    'anchor', coalesce(p_item -> 'anchor', 'null'::jsonb)
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

    v_new_ids := v_new_ids || v_concept;
    v_concepts := v_concepts || jsonb_build_object('index', v_idx, 'key', v_key, 'id', v_concept, 'category_id', v_parent, 'type_id', v_type);
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
    select (c ->> 'id')::uuid, (c ->> 'category_id')::uuid into v_concept, v_parent
      from jsonb_array_elements(v_concepts) c where c ->> 'key' = v_key;
    select (c ->> 'id')::uuid, (c ->> 'category_id')::uuid into v_anchor, v_cat
      from jsonb_array_elements(v_concepts) c where c ->> 'key' = v_anchor_key;
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
                                     'anchors', v_anchors)
   where id = p_id
  returning * into v_row;
  return jsonb_build_object('id', v_row.id, 'status', v_row.status, 'result', v_row.result);
end;
$$;

alter table public.concept_anchor_links enable row level security;

drop policy if exists concept_anchor_links_operator_select on public.concept_anchor_links;
create policy concept_anchor_links_operator_select on public.concept_anchor_links
  for select to authenticated
  using ((select public.is_superadmin()));

revoke all on public.concept_anchor_links from anon;
revoke insert, update, delete, truncate on public.concept_anchor_links from authenticated;

revoke all on function public.concept_anchor_has_cycle(uuid[]) from public, anon, authenticated;
revoke all on function public.concept_anchor_set(jsonb, text) from public, anon;
grant execute on function public.concept_anchor_set(jsonb, text) to authenticated;

notify pgrst, 'reload schema';
