-- 20261016100000: 개념 탭 정리 기준 · 기준–개념 연결 · 개념 출처 (운영자 결정 2026-10-16)
--
-- 설계: docs/architecture/concept-library.md
--
-- 표
--   concept_criteria            정리 기준 항목. 확정본(title·body·version)과 저장된 초안(draft_*)을 따로 둔다.
--                               확정본은 운영자가 확정할 때만 바뀐다(concept_criteria_confirm). 초안을 저장해도
--                               확정본은 그대로다. 기본 틀로 만든 항목도 초안(draft_origin = 'template')으로만 들어간다.
--   concept_criteria_revisions  확정 기록. 확정할 때마다 한 줄 쌓이고 고치거나 지우지 않는다.
--   concept_criterion_links     운영자가 직접 이은 기준–개념 연결. AI가 추정한 후보는 넣지 않는다.
--   concept_sources             개념의 출처(교재·쪽). 운영자가 고른 쪽만 넣는다. 책 이름·쪽을 추정해 채우지 않는다.
--
-- 기존 concepts·concept_categories 는 바꾸지 않는다. concepts.kind·sub_type 과 새 정리 기준은 별개다.
--
-- 접근
--   슈퍼관리자(매니저앱 운영자)만 읽고 쓴다. 기준은 아래 RPC로만 바뀐다(표 직접 쓰기 금지).
--   연결·출처는 표에 직접 넣고 지운다. AI·Edge Function에는 이 표에 쓰는 경로가 없다.

-- ─────────────────────────────────────────────────────────────────────────
-- 1) 정리 기준
-- ─────────────────────────────────────────────────────────────────────────

create table if not exists public.concept_criteria (
  id uuid primary key default gen_random_uuid(),
  sort_order integer not null default 0,
  -- 확정본. version 0 = 아직 확정한 적 없음.
  title text,
  body text,
  version integer not null default 0 check (version >= 0),
  confirmed_at timestamptz,
  confirmed_by uuid references auth.users(id) on delete set null,
  -- 저장된 초안(논의 중인 변경). 확정하면 비워진다.
  draft_title text,
  draft_body text,
  draft_origin text,
  draft_saved_at timestamptz,
  draft_saved_by uuid references auth.users(id) on delete set null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint concept_criteria_confirmed_chk check (
    (version = 0 and title is null and body is null and confirmed_at is null)
    or (version > 0 and title is not null and btrim(title) <> '' and body is not null and confirmed_at is not null)
  ),
  constraint concept_criteria_draft_chk check (
    (draft_title is null and draft_body is null and draft_origin is null and draft_saved_at is null)
    or (draft_title is not null and btrim(draft_title) <> '' and draft_body is not null
        and draft_origin in ('owner', 'template') and draft_saved_at is not null)
  ),
  constraint concept_criteria_content_chk check (version > 0 or draft_title is not null),
  constraint concept_criteria_length_chk check (
    char_length(coalesce(title, '')) <= 200 and char_length(coalesce(draft_title, '')) <= 200
    and char_length(coalesce(body, '')) <= 20000 and char_length(coalesce(draft_body, '')) <= 20000
  )
);

create index if not exists concept_criteria_sort_idx on public.concept_criteria (sort_order, created_at);

drop trigger if exists trg_concept_criteria_updated on public.concept_criteria;
create trigger trg_concept_criteria_updated
  before update on public.concept_criteria
  for each row execute function public.set_updated_at();

create table if not exists public.concept_criteria_revisions (
  id uuid primary key default gen_random_uuid(),
  criterion_id uuid not null references public.concept_criteria(id) on delete cascade,
  version integer not null check (version > 0),
  title text not null,
  body text not null,
  note text,
  confirmed_by uuid references auth.users(id) on delete set null,
  confirmed_at timestamptz not null default now(),
  unique (criterion_id, version)
);

-- ─────────────────────────────────────────────────────────────────────────
-- 2) 기준–개념 연결, 개념 출처
-- ─────────────────────────────────────────────────────────────────────────

create table if not exists public.concept_criterion_links (
  criterion_id uuid not null references public.concept_criteria(id) on delete cascade,
  concept_id uuid not null references public.concepts(id) on delete cascade,
  created_by uuid default auth.uid() references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (criterion_id, concept_id)
);

create index if not exists concept_criterion_links_concept_idx on public.concept_criterion_links (concept_id);

create table if not exists public.concept_sources (
  id uuid primary key default gen_random_uuid(),
  concept_id uuid not null references public.concepts(id) on delete cascade,
  academy_id uuid not null references public.academies(id) on delete cascade,
  book_id uuid not null references public.resource_files(id) on delete cascade,
  grade_label text not null check (btrim(grade_label) <> ''),
  raw_page integer not null check (raw_page > 0),
  display_page integer check (display_page is null or display_page > 0),
  -- 쪽을 고를 때 본 단원 경로(대·중·소단원 이름). 표시용 기록이고 책 구조를 대신하지 않는다.
  unit_path text[] not null default '{}'::text[] check (cardinality(unit_path) <= 3),
  created_by uuid default auth.uid() references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (concept_id, book_id, grade_label, raw_page)
);

create index if not exists concept_sources_concept_idx on public.concept_sources (concept_id, created_at);

-- ─────────────────────────────────────────────────────────────────────────
-- 3) 기준 RPC
-- ─────────────────────────────────────────────────────────────────────────

create or replace function public.concept_criteria_assert_operator()
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.is_superadmin() then
    raise exception 'concept_criteria_forbidden';
  end if;
end;
$$;

create or replace function public.concept_criteria_check_text(p_title text, p_body text)
returns void
language plpgsql
immutable
as $$
begin
  if btrim(coalesce(p_title, '')) = '' then
    raise exception 'concept_criteria_title_required';
  end if;
  if char_length(btrim(p_title)) > 200 or char_length(coalesce(p_body, '')) > 20000 then
    raise exception 'concept_criteria_too_long';
  end if;
end;
$$;

-- 화면에 보였던 판(version)과 초안 저장 시각이 지금과 같을 때만 바꾼다.
create or replace function public.concept_criteria_lock(
  p_id uuid,
  p_expected_version integer,
  p_expected_draft_saved_at timestamptz
)
returns public.concept_criteria
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.concept_criteria;
begin
  select * into v_row from public.concept_criteria where id = p_id for update;
  if not found then
    raise exception 'concept_criteria_not_found';
  end if;
  if v_row.version is distinct from p_expected_version
     or v_row.draft_saved_at is distinct from p_expected_draft_saved_at then
    raise exception 'concept_criteria_stale';
  end if;
  return v_row;
end;
$$;

-- 새 항목은 초안으로만 만든다. p_origin = 'template' 은 기본 틀에서 만든 초안.
create or replace function public.concept_criteria_create(p_title text, p_body text, p_origin text default 'owner')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.concept_criteria;
begin
  perform public.concept_criteria_assert_operator();
  perform public.concept_criteria_check_text(p_title, p_body);
  if p_origin is null or p_origin not in ('owner', 'template') then
    raise exception 'concept_criteria_bad_origin';
  end if;
  insert into public.concept_criteria
    (sort_order, draft_title, draft_body, draft_origin, draft_saved_at, draft_saved_by, created_by)
  values (
    coalesce((select max(sort_order) + 1 from public.concept_criteria), 0),
    btrim(p_title), coalesce(p_body, ''), p_origin, clock_timestamp(), auth.uid(), auth.uid()
  )
  returning * into v_row;
  return to_jsonb(v_row);
end;
$$;

-- 초안 저장. 확정본은 바꾸지 않는다. 확정본과 같은 내용으로 돌려 놓으면 초안을 비운다.
create or replace function public.concept_criteria_save_draft(
  p_id uuid,
  p_title text,
  p_body text,
  p_expected_version integer,
  p_expected_draft_saved_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.concept_criteria;
  v_title text;
  v_body text;
begin
  perform public.concept_criteria_assert_operator();
  perform public.concept_criteria_check_text(p_title, p_body);
  v_row := public.concept_criteria_lock(p_id, p_expected_version, p_expected_draft_saved_at);
  v_title := btrim(p_title);
  v_body := coalesce(p_body, '');
  if v_row.version > 0 and v_title = v_row.title and v_body = v_row.body then
    update public.concept_criteria
       set draft_title = null, draft_body = null, draft_origin = null, draft_saved_at = null, draft_saved_by = null
     where id = p_id
    returning * into v_row;
  else
    update public.concept_criteria
       set draft_title = v_title, draft_body = v_body, draft_origin = 'owner',
           draft_saved_at = clock_timestamp(), draft_saved_by = auth.uid()
     where id = p_id
    returning * into v_row;
  end if;
  return to_jsonb(v_row);
end;
$$;

-- 저장된 초안을 확정본으로 올린다. 저장 안 된 편집은 여기 올 수 없다(앱은 저장 뒤에만 확정을 연다).
create or replace function public.concept_criteria_confirm(
  p_id uuid,
  p_expected_version integer,
  p_expected_draft_saved_at timestamptz,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.concept_criteria;
begin
  perform public.concept_criteria_assert_operator();
  v_row := public.concept_criteria_lock(p_id, p_expected_version, p_expected_draft_saved_at);
  if v_row.draft_title is null then
    raise exception 'concept_criteria_no_draft';
  end if;
  insert into public.concept_criteria_revisions (criterion_id, version, title, body, note, confirmed_by)
  values (p_id, v_row.version + 1, v_row.draft_title, v_row.draft_body,
          nullif(btrim(coalesce(p_note, '')), ''), auth.uid());
  update public.concept_criteria
     set title = v_row.draft_title, body = v_row.draft_body, version = v_row.version + 1,
         confirmed_at = clock_timestamp(), confirmed_by = auth.uid(),
         draft_title = null, draft_body = null, draft_origin = null, draft_saved_at = null, draft_saved_by = null
   where id = p_id
  returning * into v_row;
  return to_jsonb(v_row);
end;
$$;

-- 저장된 초안을 버린다. 확정한 적 없는 항목은 초안이 전부라 항목째 지운다({id, removed: true}).
create or replace function public.concept_criteria_discard_draft(
  p_id uuid,
  p_expected_version integer,
  p_expected_draft_saved_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.concept_criteria;
begin
  perform public.concept_criteria_assert_operator();
  v_row := public.concept_criteria_lock(p_id, p_expected_version, p_expected_draft_saved_at);
  if v_row.draft_title is null then
    raise exception 'concept_criteria_no_draft';
  end if;
  if v_row.version = 0 then
    delete from public.concept_criteria where id = p_id;
    return jsonb_build_object('id', p_id, 'removed', true);
  end if;
  update public.concept_criteria
     set draft_title = null, draft_body = null, draft_origin = null, draft_saved_at = null, draft_saved_by = null
   where id = p_id
  returning * into v_row;
  return to_jsonb(v_row);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 4) 접근
-- ─────────────────────────────────────────────────────────────────────────

alter table public.concept_criteria enable row level security;
alter table public.concept_criteria_revisions enable row level security;
alter table public.concept_criterion_links enable row level security;
alter table public.concept_sources enable row level security;

drop policy if exists concept_criteria_operator_select on public.concept_criteria;
create policy concept_criteria_operator_select on public.concept_criteria
  for select to authenticated
  using ((select public.is_superadmin()));

drop policy if exists concept_criteria_revisions_operator_select on public.concept_criteria_revisions;
create policy concept_criteria_revisions_operator_select on public.concept_criteria_revisions
  for select to authenticated
  using ((select public.is_superadmin()));

drop policy if exists concept_criterion_links_operator_select on public.concept_criterion_links;
create policy concept_criterion_links_operator_select on public.concept_criterion_links
  for select to authenticated
  using ((select public.is_superadmin()));
drop policy if exists concept_criterion_links_operator_insert on public.concept_criterion_links;
create policy concept_criterion_links_operator_insert on public.concept_criterion_links
  for insert to authenticated
  with check ((select public.is_superadmin()));
drop policy if exists concept_criterion_links_operator_delete on public.concept_criterion_links;
create policy concept_criterion_links_operator_delete on public.concept_criterion_links
  for delete to authenticated
  using ((select public.is_superadmin()));

drop policy if exists concept_sources_operator_select on public.concept_sources;
create policy concept_sources_operator_select on public.concept_sources
  for select to authenticated
  using ((select public.is_superadmin()));
drop policy if exists concept_sources_operator_insert on public.concept_sources;
create policy concept_sources_operator_insert on public.concept_sources
  for insert to authenticated
  with check (
    (select public.is_superadmin())
    and exists (
      select 1 from public.resource_files r
       where r.id = concept_sources.book_id and r.academy_id = concept_sources.academy_id
    )
  );
drop policy if exists concept_sources_operator_delete on public.concept_sources;
create policy concept_sources_operator_delete on public.concept_sources
  for delete to authenticated
  using ((select public.is_superadmin()));

revoke all on public.concept_criteria, public.concept_criteria_revisions,
  public.concept_criterion_links, public.concept_sources from anon;
revoke insert, update, delete, truncate on public.concept_criteria, public.concept_criteria_revisions
  from authenticated;
revoke update, truncate on public.concept_criterion_links, public.concept_sources from authenticated;

revoke all on function public.concept_criteria_assert_operator() from public, anon, authenticated;
revoke all on function public.concept_criteria_check_text(text, text) from public, anon, authenticated;
revoke all on function public.concept_criteria_lock(uuid, integer, timestamptz) from public, anon, authenticated;
revoke all on function public.concept_criteria_create(text, text, text) from public, anon;
revoke all on function public.concept_criteria_save_draft(uuid, text, text, integer, timestamptz) from public, anon;
revoke all on function public.concept_criteria_confirm(uuid, integer, timestamptz, text) from public, anon;
revoke all on function public.concept_criteria_discard_draft(uuid, integer, timestamptz) from public, anon;

grant execute on function public.concept_criteria_create(text, text, text) to authenticated;
grant execute on function public.concept_criteria_save_draft(uuid, text, text, integer, timestamptz) to authenticated;
grant execute on function public.concept_criteria_confirm(uuid, integer, timestamptz, text) to authenticated;
grant execute on function public.concept_criteria_discard_draft(uuid, integer, timestamptz) to authenticated;

notify pgrst, 'reload schema';
