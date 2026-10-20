-- 20261017120000: 개념 유형(운영자 결정 2026-10-17)
--
-- 설계: docs/architecture/concept-library.md §7.1
--
-- 표
--   concept_types       확정된 개념 유형 목록(한 줄 목록). 처음엔 시범에서 쓴 다섯 가지로 시작하고, 개념 초안 확정 때
--                       운영자가 받아들인 새 유형만 더해진다. 유형마다 기존 구분(정의·연산·정리)을 하나 정해 둔다.
--   concept_type_links  개념 ↔ 유형(개념 하나에 유형 하나). 기존 concepts 표는 바꾸지 않는다.
--                       concepts.sub_type 은 기존 구분 그대로이고, 유형의 기존 구분에서 채운다.
--   concept_drafts.concept_types  초안을 만들 때 AI에 준 유형 목록(이름·설명·기존 구분).
--
-- 기존 개념에는 유형을 붙이지 않는다(자동 재분류 없음).
-- 접근: 운영자만 읽는다. 쓰기는 concept_draft_confirm 으로만 한다.

create table if not exists public.concept_types (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  description text not null default '',
  legacy_sub_type text not null check (legacy_sub_type in ('정의', '연산', '정리')),
  sort_order integer not null default 0,
  origin text not null check (origin in ('seed', 'draft')),
  draft_id uuid references public.concept_drafts(id) on delete set null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint concept_types_name_chk check (btrim(name) <> '' and char_length(name) <= 40),
  constraint concept_types_description_chk check (char_length(description) <= 500)
);

create unique index if not exists concept_types_name_key on public.concept_types (lower(btrim(name)));

insert into public.concept_types (name, description, legacy_sub_type, sort_order, origin) values
  ('정의', '용어나 대상이 무엇인지 정하는 것. 예: 소수, 합성수, 거듭제곱의 뜻', '정의', 0, 'seed'),
  ('성질', '대상이 늘 만족하는 사실·법칙·정리. 예: 소인수분해 결과는 하나뿐이다', '정리', 1, 'seed'),
  ('방법', '계산하거나 구하는 절차. 예: 소인수분해하는 방법, 최대공약수 구하기', '연산', 2, 'seed'),
  ('표현', '기호·표기법·나타내는 방식. 예: 거듭제곱의 밑과 지수, 소인수분해를 거듭제곱으로 나타내기', '정의', 3, 'seed'),
  ('주의', '헷갈리기 쉬운 예외·조건. 예: 1은 소수도 합성수도 아니다', '정리', 4, 'seed')
on conflict ((lower(btrim(name)))) do nothing;

create table if not exists public.concept_type_links (
  concept_id uuid primary key references public.concepts(id) on delete cascade,
  type_id uuid not null references public.concept_types(id) on delete restrict,
  draft_id uuid references public.concept_drafts(id) on delete set null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists concept_type_links_type_idx on public.concept_type_links (type_id);

alter table public.concept_drafts add column if not exists concept_types jsonb not null default '[]'::jsonb;

-- 저장된 검토 내용으로 유형·폴더·개념·출처를 한 번에 만든다. 하나라도 어긋나면 아무것도 들어가지 않는다.
--   mark: keep(그대로)·edit(고쳐서)·drop(빼기). drop 은 넣지 않는다.
--   type: 개념 유형 이름. 확정된 유형이거나, 검토의 new_types 에서 받아들인(accept) 새 유형이어야 한다.
--   new_types: [{name, description, legacy_sub_type, accept}] AI가 제안한 새 유형과 운영자 결정.
--              받아들인 것만 concept_types 에 더한다(같은 이름이 이미 있으면 그것을 쓴다).
--   sub_type·kind: 유형의 기존 구분에서 채운다. 정의 → kind definition, 연산·정리 → theorem.
--   folder: 영역 루트 이름부터 시작하는 폴더 이름 경로.
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
  v_seen integer[] := '{}';
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
  v_display integer;
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
    if v_idx is null or v_idx < 0 or v_idx >= v_total or v_idx = any (v_seen) then
      raise exception 'concept_draft_bad_review';
    end if;
    v_seen := v_seen || v_idx;
    continue when v_mark = 'drop';

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

    for v_page in
      select distinct (b ->> 'raw_page')::integer
        from jsonb_array_elements(coalesce(v_row.prepared -> 'blocks', '[]'::jsonb)) b
       where b ->> 'id' in (
         select jsonb_array_elements_text(coalesce(v_row.draft -> 'concepts' -> v_idx -> 'source_blocks', '[]'::jsonb))
       )
       order by 1
    loop
      select nullif((pm ->> 'display_page'), '')::integer into v_display
        from jsonb_array_elements(v_row.page_meta) pm
       where (pm ->> 'raw_page')::integer = v_page
       limit 1;
      insert into public.concept_sources (concept_id, academy_id, book_id, grade_label, raw_page, display_page, unit_path, created_by)
      values (v_concept, v_row.academy_id, v_row.book_id, v_row.grade_label, v_page,
              case when v_display > 0 then v_display end, v_row.unit_path, auth.uid());
      v_sources := v_sources + 1;
    end loop;

    v_concepts := v_concepts || jsonb_build_object('index', v_idx, 'id', v_concept, 'category_id', v_parent, 'type_id', v_type);
  end loop;

  if jsonb_array_length(v_concepts) = 0 then
    raise exception 'concept_draft_nothing_kept';
  end if;
  update public.concept_drafts
     set status = 'confirmed', confirmed_at = clock_timestamp(), confirmed_by = auth.uid(), closed_at = clock_timestamp(),
         result = jsonb_build_object('concepts', v_concepts, 'folders', v_folders, 'types', v_types, 'sources', v_sources)
   where id = p_id
  returning * into v_row;
  return jsonb_build_object('id', v_row.id, 'status', v_row.status, 'result', v_row.result);
end;
$$;

alter table public.concept_types enable row level security;
alter table public.concept_type_links enable row level security;

drop policy if exists concept_types_operator_select on public.concept_types;
create policy concept_types_operator_select on public.concept_types
  for select to authenticated
  using ((select public.is_superadmin()));

drop policy if exists concept_type_links_operator_select on public.concept_type_links;
create policy concept_type_links_operator_select on public.concept_type_links
  for select to authenticated
  using ((select public.is_superadmin()));

revoke all on public.concept_types, public.concept_type_links from anon;
revoke insert, update, delete, truncate on public.concept_types, public.concept_type_links from authenticated;

revoke all on function public.concept_draft_confirm(uuid, timestamptz) from public, anon;
grant execute on function public.concept_draft_confirm(uuid, timestamptz) to authenticated;

notify pgrst, 'reload schema';
