-- 20261017100000: 개념책 소단원 → 개념 초안 → 운영자 확인 뒤 라이브러리 반영 (운영자 결정 2026-10-16)
--
-- 설계: docs/architecture/concept-library.md §7
--
-- 표
--   concept_page_transcripts  개념책 한 쪽을 문항 영역만 가리고 옮겨 적은 결과. 같은 쪽을 두 번 읽는다(read_index 1·2).
--                             Edge 함수(concept_page_read)가 서버 키로만 쓴다. 가린 영역은 서버가 문항 기록에서 읽은 값이다.
--   concept_drafts            소단원 하나의 개념 초안. AI 결과(draft·prepared·checks·folder_plan)는 Edge 함수만 쓰고 고치지 않는다.
--                             운영자 편집은 review 에만 남는다(concept_draft_save_review).
--
-- 라이브러리(concept_categories·concepts·concept_sources)에는 운영자가 확정할 때만(concept_draft_confirm) 들어간다.
-- 확정은 저장된 검토 내용만 쓴다. 출처 쪽은 초안이 근거로 든 블록의 쪽(전사 기록)에서만 붙이고 추정하지 않는다.
-- 기존 폴더·개념은 바꾸거나 옮기지 않는다. 같은 이름의 폴더가 있으면 그 폴더에 넣고, 없으면 새로 만든다.

-- ─────────────────────────────────────────────────────────────────────────
-- 1) 쪽 전사
-- ─────────────────────────────────────────────────────────────────────────

create table if not exists public.concept_page_transcripts (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  book_id uuid not null references public.resource_files(id) on delete cascade,
  grade_label text not null check (btrim(grade_label) <> ''),
  raw_page integer not null check (raw_page > 0),
  display_page integer check (display_page is null or display_page > 0),
  read_index smallint not null check (read_index in (1, 2)),
  prompt_version text not null check (btrim(prompt_version) <> ''),
  model text not null,
  masks jsonb not null default '[]'::jsonb check (jsonb_typeof(masks) = 'array'),
  page jsonb not null check (jsonb_typeof(page) = 'object'),
  usage jsonb not null default '{}'::jsonb,
  cost_usd numeric,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (academy_id, book_id, grade_label, raw_page, read_index, prompt_version)
);

-- ─────────────────────────────────────────────────────────────────────────
-- 2) 개념 초안
-- ─────────────────────────────────────────────────────────────────────────

create table if not exists public.concept_drafts (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  book_id uuid not null references public.resource_files(id) on delete cascade,
  grade_label text not null check (btrim(grade_label) <> ''),
  -- 만들 때 본 책 이름(표시용).
  book_name text not null default '',
  -- 저장된 교재 구조의 대·중·소단원 이름. 출처의 unit_path 로 그대로 쓴다.
  unit_path text[] not null default '{}'::text[] check (cardinality(unit_path) <= 3),
  pages integer[] not null check (cardinality(pages) between 1 and 12),
  -- [{raw_page, display_page}] 전사 기록에 있던 값.
  page_meta jsonb not null default '[]'::jsonb check (jsonb_typeof(page_meta) = 'array'),
  status text not null default 'open' check (status in ('open', 'confirmed', 'discarded')),
  model text not null,
  prompt_version text not null,
  -- 정리할 때 쓴 기준(id·제목·판·확정/초안). 본문은 넣지 않는다.
  criteria jsonb not null default '[]'::jsonb check (jsonb_typeof(criteria) = 'array'),
  -- 두 번 읽은 결과를 맞춘 블록(id·쪽·위치), AI 초안, 검사 결과.
  prepared jsonb not null check (jsonb_typeof(prepared) = 'object'),
  draft jsonb not null check (jsonb_typeof(draft) = 'object'),
  checks jsonb not null default '{}'::jsonb check (jsonb_typeof(checks) = 'object'),
  usage jsonb not null default '{}'::jsonb,
  cost_usd numeric,
  -- AI 폴더 제안(수학 구조 기준). 만들기 뒤 따로 채운다.
  folder_plan jsonb check (folder_plan is null or jsonb_typeof(folder_plan) = 'object'),
  -- 운영자 검토(저장한 것만). {concepts: [{index, mark, title, content, sub_type, folder[]}]}
  review jsonb not null default '{}'::jsonb check (jsonb_typeof(review) = 'object'),
  review_saved_at timestamptz,
  review_saved_by uuid references auth.users(id) on delete set null,
  -- 확정 결과(만든 개념·폴더 id).
  result jsonb,
  confirmed_at timestamptz,
  confirmed_by uuid references auth.users(id) on delete set null,
  closed_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint concept_drafts_confirmed_chk check (
    (status = 'confirmed') = (confirmed_at is not null and result is not null)
  )
);

create index if not exists concept_drafts_book_idx
  on public.concept_drafts (academy_id, book_id, grade_label, created_at desc);
create index if not exists concept_drafts_open_idx
  on public.concept_drafts (created_at desc) where status = 'open';

drop trigger if exists trg_concept_drafts_updated on public.concept_drafts;
create trigger trg_concept_drafts_updated
  before update on public.concept_drafts
  for each row execute function public.set_updated_at();

-- ─────────────────────────────────────────────────────────────────────────
-- 3) RPC
-- ─────────────────────────────────────────────────────────────────────────

create or replace function public.concept_draft_assert_operator()
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.is_superadmin() then
    raise exception 'concept_draft_forbidden';
  end if;
end;
$$;

-- 화면에서 본 검토 저장 시각이 지금과 같고, 아직 열린 초안일 때만 바꾼다.
create or replace function public.concept_draft_lock(p_id uuid, p_expected_review_saved_at timestamptz)
returns public.concept_drafts
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.concept_drafts;
begin
  select * into v_row from public.concept_drafts where id = p_id for update;
  if not found then
    raise exception 'concept_draft_not_found';
  end if;
  if v_row.status <> 'open' then
    raise exception 'concept_draft_closed';
  end if;
  if v_row.review_saved_at is distinct from p_expected_review_saved_at then
    raise exception 'concept_draft_stale';
  end if;
  return v_row;
end;
$$;

create or replace function public.concept_draft_save_review(
  p_id uuid,
  p_review jsonb,
  p_expected_review_saved_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.concept_drafts;
begin
  perform public.concept_draft_assert_operator();
  if p_review is null or jsonb_typeof(p_review) <> 'object'
     or jsonb_typeof(coalesce(p_review -> 'concepts', '[]'::jsonb)) <> 'array' then
    raise exception 'concept_draft_bad_review';
  end if;
  if octet_length(p_review::text) > 400000 then
    raise exception 'concept_draft_too_long';
  end if;
  perform public.concept_draft_lock(p_id, p_expected_review_saved_at);
  update public.concept_drafts
     set review = p_review, review_saved_at = clock_timestamp(), review_saved_by = auth.uid()
   where id = p_id
  returning * into v_row;
  return jsonb_build_object('id', v_row.id, 'review_saved_at', v_row.review_saved_at, 'status', v_row.status);
end;
$$;

create or replace function public.concept_draft_discard(p_id uuid, p_expected_review_saved_at timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.concept_drafts;
begin
  perform public.concept_draft_assert_operator();
  perform public.concept_draft_lock(p_id, p_expected_review_saved_at);
  update public.concept_drafts
     set status = 'discarded', closed_at = clock_timestamp()
   where id = p_id
  returning * into v_row;
  return jsonb_build_object('id', v_row.id, 'status', v_row.status);
end;
$$;

-- 저장된 검토 내용으로 폴더·개념·출처를 한 번에 만든다. 하나라도 어긋나면 아무것도 들어가지 않는다.
--   mark: keep(그대로)·edit(고쳐서)·drop(빼기). drop 은 넣지 않는다.
--   folder: 영역 루트(대수·해석·확률통계·기하 등 이미 있는 최상위 폴더) 이름부터 시작하는 폴더 이름 경로.
--   sub_type: 정의·연산·정리(기존 세부 유형). 정의 → kind definition, 나머지 → theorem.
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
  v_total integer;
  v_seen integer[] := '{}';
  v_idx integer;
  v_mark text;
  v_title text;
  v_content text;
  v_sub text;
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
    v_sub := v_item ->> 'sub_type';
    if v_sub is null or v_sub not in ('정의', '연산', '정리') then
      raise exception 'concept_draft_bad_review';
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

    v_concepts := v_concepts || jsonb_build_object('index', v_idx, 'id', v_concept, 'category_id', v_parent);
  end loop;

  if jsonb_array_length(v_concepts) = 0 then
    raise exception 'concept_draft_nothing_kept';
  end if;
  update public.concept_drafts
     set status = 'confirmed', confirmed_at = clock_timestamp(), confirmed_by = auth.uid(), closed_at = clock_timestamp(),
         result = jsonb_build_object('concepts', v_concepts, 'folders', v_folders, 'sources', v_sources)
   where id = p_id
  returning * into v_row;
  return jsonb_build_object('id', v_row.id, 'status', v_row.status, 'result', v_row.result);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 4) 접근
-- ─────────────────────────────────────────────────────────────────────────

alter table public.concept_page_transcripts enable row level security;
alter table public.concept_drafts enable row level security;

drop policy if exists concept_page_transcripts_operator_select on public.concept_page_transcripts;
create policy concept_page_transcripts_operator_select on public.concept_page_transcripts
  for select to authenticated
  using ((select public.is_superadmin()));

drop policy if exists concept_drafts_operator_select on public.concept_drafts;
create policy concept_drafts_operator_select on public.concept_drafts
  for select to authenticated
  using ((select public.is_superadmin()));

revoke all on public.concept_page_transcripts, public.concept_drafts from anon;
revoke insert, update, delete, truncate on public.concept_page_transcripts, public.concept_drafts from authenticated;

revoke all on function public.concept_draft_assert_operator() from public, anon, authenticated;
revoke all on function public.concept_draft_lock(uuid, timestamptz) from public, anon, authenticated;
revoke all on function public.concept_draft_save_review(uuid, jsonb, timestamptz) from public, anon;
revoke all on function public.concept_draft_discard(uuid, timestamptz) from public, anon;
revoke all on function public.concept_draft_confirm(uuid, timestamptz) from public, anon;

grant execute on function public.concept_draft_save_review(uuid, jsonb, timestamptz) to authenticated;
grant execute on function public.concept_draft_discard(uuid, timestamptz) to authenticated;
grant execute on function public.concept_draft_confirm(uuid, timestamptz) to authenticated;

notify pgrst, 'reload schema';
