-- 20261020100000: 개념의 여러 서술 · 등장 위치 · 개념 본문 고친 기록 (운영자 결정 2026-10-20, 1단계 저장·조회)
--
-- 설계: docs/architecture/concept-library.md §4.2
--
-- 표
--   concept_statements           한 개념에 붙는 글. role = 'core'(개념 공통 의미·적용 범위, 개념마다 하나)
--                                또는 'statement'(그 개념을 설명하는 서술 하나). 정리 기준처럼 확정본(content·version)과
--                                저장된 초안(draft)을 따로 둔다. 확정본은 운영자가 확정할 때만 바뀐다.
--   concept_statement_revisions  확정 기록. 확정할 때마다 한 줄 쌓이고 고치거나 지우지 않는다.
--   concept_appearances          교육과정 등장 위치(교육과정 판·학교급·학년/과목·단원). 운영자가 넣은 것만 있다.
--   concept_content_revisions    기존 개념 본문(concepts.name·content)을 고치기 전 값.
--
-- 기존 개념 본문(concepts.content)은 그 개념의 "기본 서술"로 읽고 이 표로 옮기지 않는다.
-- concept_sources.statement_id 가 비어 있으면 기본 서술의 출처다. 기존 출처는 그대로 기본 서술의 출처로 남는다.
-- 이름·학년으로 개념을 합치거나 나누지 않는다. concepts.family_id·version_label(이름이 같은 개념 묶음)은 서술과 관계없다.
--
-- 접근
--   슈퍼관리자만 읽는다. 서술은 아래 RPC로만 바뀐다(표 직접 쓰기 금지). 등장 위치는 표에 직접 넣고 지운다.
--   출처를 서술에 잇는 일은 concept_source_set_statement 로만 한다(concept_sources 직접 고치기는 원래 막혀 있다).

-- ─────────────────────────────────────────────────────────────────────────
-- 1) 서술
-- ─────────────────────────────────────────────────────────────────────────

create table if not exists public.concept_statements (
  id uuid primary key default gen_random_uuid(),
  concept_id uuid not null references public.concepts(id) on delete cascade,
  role text not null check (role in ('core', 'statement')),
  sort_order integer not null default 0,
  -- 확정본. version 0 = 아직 확정한 적 없음.
  version integer not null default 0 check (version >= 0),
  content jsonb,
  confirmed_at timestamptz,
  confirmed_by uuid references auth.users(id) on delete set null,
  -- 저장된 초안. 확정하면 비워진다. 'ai' 는 운영자가 승인한 AI 제안 카드로만 들어온다(1단계에는 그 길이 없다).
  draft jsonb,
  draft_origin text,
  draft_saved_at timestamptz,
  draft_saved_by uuid references auth.users(id) on delete set null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint concept_statements_confirmed_chk check (
    (version = 0 and content is null and confirmed_at is null)
    or (version > 0 and content is not null and confirmed_at is not null)
  ),
  constraint concept_statements_draft_chk check (
    (draft is null and draft_origin is null and draft_saved_at is null)
    or (draft is not null and draft_origin in ('owner', 'ai') and draft_saved_at is not null)
  ),
  constraint concept_statements_content_chk check (version > 0 or draft is not null)
);

create unique index if not exists concept_statements_core_unique
  on public.concept_statements (concept_id) where role = 'core';
create index if not exists concept_statements_concept_idx
  on public.concept_statements (concept_id, role, sort_order, created_at);

drop trigger if exists trg_concept_statements_updated on public.concept_statements;
create trigger trg_concept_statements_updated
  before update on public.concept_statements
  for each row execute function public.set_updated_at();

create table if not exists public.concept_statement_revisions (
  id uuid primary key default gen_random_uuid(),
  statement_id uuid not null references public.concept_statements(id) on delete cascade,
  version integer not null check (version > 0),
  content jsonb not null,
  note text,
  confirmed_by uuid references auth.users(id) on delete set null,
  confirmed_at timestamptz not null default now(),
  unique (statement_id, version)
);

-- ─────────────────────────────────────────────────────────────────────────
-- 2) 출처의 서술, 교육과정 등장 위치
-- ─────────────────────────────────────────────────────────────────────────

-- 비어 있으면 기본 서술(개념 본문)의 출처. 같은 개념·책·학년·쪽은 지금처럼 한 번만 들어가므로 한 쪽은 한 서술에만 붙는다.
alter table public.concept_sources
  add column if not exists statement_id uuid references public.concept_statements(id);
create index if not exists concept_sources_statement_idx on public.concept_sources (statement_id) where statement_id is not null;

create table if not exists public.concept_appearances (
  id uuid primary key default gen_random_uuid(),
  concept_id uuid not null references public.concepts(id) on delete cascade,
  -- 비어 있으면 기본 서술.
  statement_id uuid references public.concept_statements(id),
  -- 문제은행과 같은 교육과정 코드. 모르면 비워 둔다(교재 이름·과목으로 추정하지 않는다).
  curriculum_code text check (
    curriculum_code is null
    or curriculum_code in ('legacy_1to6', 'k7_1997', 'k7_2007', 'rev_2009', 'rev_2015', 'rev_2022')
  ),
  school_level text not null check (school_level in ('초', '중', '고')),
  course_label text not null check (btrim(course_label) <> '' and char_length(course_label) <= 40),
  unit_path text[] not null default '{}'::text[] check (cardinality(unit_path) <= 3),
  note text check (note is null or char_length(note) <= 500),
  created_by uuid default auth.uid() references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create unique index if not exists concept_appearances_unique on public.concept_appearances (
  concept_id, coalesce(statement_id, '00000000-0000-0000-0000-000000000000'::uuid),
  coalesce(curriculum_code, ''), school_level, course_label, unit_path
);
create index if not exists concept_appearances_concept_idx on public.concept_appearances (concept_id, created_at);

-- 출처·등장 위치가 가리키는 서술은 같은 개념의 서술(role = 'statement')이어야 한다.
create or replace function public.concept_statement_link_check()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_concept uuid;
  v_role text;
begin
  if new.statement_id is null then
    return new;
  end if;
  select concept_id, role into v_concept, v_role from public.concept_statements where id = new.statement_id;
  if not found then
    raise exception 'concept_statement_not_found';
  end if;
  if v_concept <> new.concept_id then
    raise exception 'concept_statement_other_concept';
  end if;
  if v_role <> 'statement' then
    raise exception 'concept_statement_not_statement';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_concept_sources_statement_check on public.concept_sources;
create trigger trg_concept_sources_statement_check
  before insert or update of statement_id, concept_id on public.concept_sources
  for each row execute function public.concept_statement_link_check();

drop trigger if exists trg_concept_appearances_statement_check on public.concept_appearances;
create trigger trg_concept_appearances_statement_check
  before insert or update of statement_id, concept_id on public.concept_appearances
  for each row execute function public.concept_statement_link_check();

-- ─────────────────────────────────────────────────────────────────────────
-- 3) 기존 개념 본문 고친 기록
-- ─────────────────────────────────────────────────────────────────────────

create table if not exists public.concept_content_revisions (
  id uuid primary key default gen_random_uuid(),
  concept_id uuid not null references public.concepts(id) on delete cascade,
  -- 고치기 전 값.
  name text not null,
  content text not null,
  changed_by uuid references auth.users(id) on delete set null,
  changed_at timestamptz not null default now()
);

create index if not exists concept_content_revisions_concept_idx
  on public.concept_content_revisions (concept_id, changed_at desc);

create or replace function public.concept_content_history()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.concept_content_revisions (concept_id, name, content, changed_by)
  values (old.id, old.name, old.content, auth.uid());
  return new;
end;
$$;

drop trigger if exists trg_concept_content_history on public.concepts;
create trigger trg_concept_content_history
  after update of name, content on public.concepts
  for each row
  when (old.name is distinct from new.name or old.content is distinct from new.content)
  execute function public.concept_content_history();

-- ─────────────────────────────────────────────────────────────────────────
-- 4) 서술 RPC
-- ─────────────────────────────────────────────────────────────────────────

create or replace function public.concept_statement_assert_operator()
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.is_superadmin() then
    raise exception 'concept_statement_forbidden';
  end if;
end;
$$;

-- 글 칸 하나. 문자열이 아니면 bad_content, 길면 too_long. 앞뒤 공백만 있으면 null.
create or replace function public.concept_statement_text(p jsonb, p_key text, p_max integer)
returns text
language plpgsql
immutable
as $$
declare
  v jsonb := p -> p_key;
  v_text text;
begin
  if v is null or jsonb_typeof(v) = 'null' then
    return null;
  end if;
  if jsonb_typeof(v) <> 'string' then
    raise exception 'concept_statement_bad_content';
  end if;
  v_text := v #>> '{}';
  if btrim(v_text) = '' then
    return null;
  end if;
  if char_length(v_text) > p_max then
    raise exception 'concept_statement_too_long';
  end if;
  return v_text;
end;
$$;

-- 저장할 글을 검사하고 정해진 모양으로 바꾼다. 같은 내용이면 같은 jsonb 가 되어 확정본과 비교할 수 있다.
--   core:      meaning(필수, 공통 의미) · scope(적용 범위) · conditions(공통 조건)
--   statement: title·body(필수) · approach(서술 방식) · conditions(이 서술의 적용 대상·조건)
--              · conditions_in_source(원문에 조건이 stated 적혀 있음 / omitted 없음 / check_context 앞뒤 문맥 확인 필요)
--              · terms(필요한 용어) · basis(organized 우리가 정리한 글 / verbatim 원문 그대로) · quote(원문 또는 원문 참조)
--              · supplement_note(원문에서 보완·수정한 부분과 이유) · unverified_note(확인되지 않은 사항)
create or replace function public.concept_statement_clean(p_role text, p jsonb)
returns jsonb
language plpgsql
immutable
as $$
declare
  v_key text;
  v_allowed text[];
  v_terms text[] := '{}'::text[];
  v_term jsonb;
  v_term_text text;
  v_cis text;
  v_basis text;
  v_out jsonb;
begin
  if p is null or jsonb_typeof(p) <> 'object' then
    raise exception 'concept_statement_bad_content';
  end if;
  if p_role = 'core' then
    v_allowed := array['meaning', 'scope', 'conditions'];
  else
    v_allowed := array['title', 'body', 'approach', 'conditions', 'conditions_in_source', 'terms', 'basis', 'quote',
                       'supplement_note', 'unverified_note'];
  end if;
  for v_key in select jsonb_object_keys(p) loop
    if not v_key = any (v_allowed) then
      raise exception 'concept_statement_unknown_field';
    end if;
  end loop;

  if p_role = 'core' then
    v_out := jsonb_build_object(
      'meaning', public.concept_statement_text(p, 'meaning', 4000),
      'scope', public.concept_statement_text(p, 'scope', 4000),
      'conditions', public.concept_statement_text(p, 'conditions', 4000)
    );
    if v_out ->> 'meaning' is null then
      raise exception 'concept_statement_meaning_required';
    end if;
    return jsonb_strip_nulls(v_out);
  end if;

  if p ? 'terms' and jsonb_typeof(p -> 'terms') <> 'null' then
    if jsonb_typeof(p -> 'terms') <> 'array' then
      raise exception 'concept_statement_bad_content';
    end if;
    for v_term in select * from jsonb_array_elements(p -> 'terms') loop
      if jsonb_typeof(v_term) <> 'string' then
        raise exception 'concept_statement_bad_content';
      end if;
      v_term_text := btrim(v_term #>> '{}');
      if v_term_text = '' then
        continue;
      end if;
      if char_length(v_term_text) > 60 then
        raise exception 'concept_statement_too_long';
      end if;
      if not v_term_text = any (v_terms) then
        v_terms := v_terms || v_term_text;
      end if;
    end loop;
    if cardinality(v_terms) > 30 then
      raise exception 'concept_statement_too_long';
    end if;
  end if;

  v_cis := public.concept_statement_text(p, 'conditions_in_source', 20);
  if v_cis is not null and v_cis not in ('stated', 'omitted', 'check_context') then
    raise exception 'concept_statement_bad_content';
  end if;
  v_basis := coalesce(public.concept_statement_text(p, 'basis', 20), 'organized');
  if v_basis not in ('organized', 'verbatim') then
    raise exception 'concept_statement_bad_content';
  end if;

  v_out := jsonb_build_object(
    'title', btrim(public.concept_statement_text(p, 'title', 200)),
    'body', public.concept_statement_text(p, 'body', 20000),
    'approach', btrim(public.concept_statement_text(p, 'approach', 60)),
    'conditions', public.concept_statement_text(p, 'conditions', 4000),
    'conditions_in_source', v_cis,
    'terms', to_jsonb(v_terms),
    'basis', v_basis,
    'quote', public.concept_statement_text(p, 'quote', 4000),
    'supplement_note', public.concept_statement_text(p, 'supplement_note', 2000),
    'unverified_note', public.concept_statement_text(p, 'unverified_note', 2000)
  );
  if v_out ->> 'title' is null then
    raise exception 'concept_statement_title_required';
  end if;
  if v_out ->> 'body' is null then
    raise exception 'concept_statement_body_required';
  end if;
  return jsonb_strip_nulls(v_out);
end;
$$;

-- 화면에 보였던 판(version)과 초안 저장 시각이 지금과 같을 때만 바꾼다.
create or replace function public.concept_statement_lock(
  p_id uuid,
  p_expected_version integer,
  p_expected_draft_saved_at timestamptz
)
returns public.concept_statements
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.concept_statements;
begin
  select * into v_row from public.concept_statements where id = p_id for update;
  if not found then
    raise exception 'concept_statement_not_found';
  end if;
  if v_row.version is distinct from p_expected_version
     or v_row.draft_saved_at is distinct from p_expected_draft_saved_at then
    raise exception 'concept_statement_stale';
  end if;
  return v_row;
end;
$$;

-- 새 서술·공통 내용은 초안으로만 만든다. 공통 내용은 개념마다 하나다.
create or replace function public.concept_statement_create(p_concept_id uuid, p_role text, p_content jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_content jsonb;
  v_row public.concept_statements;
begin
  perform public.concept_statement_assert_operator();
  if p_role is null or p_role not in ('core', 'statement') then
    raise exception 'concept_statement_bad_role';
  end if;
  perform 1 from public.concepts where id = p_concept_id for share;
  if not found then
    raise exception 'concept_statement_concept_not_found';
  end if;
  v_content := public.concept_statement_clean(p_role, p_content);
  if p_role = 'core' and exists (
    select 1 from public.concept_statements where concept_id = p_concept_id and role = 'core'
  ) then
    raise exception 'concept_statement_core_exists';
  end if;
  insert into public.concept_statements
    (concept_id, role, sort_order, draft, draft_origin, draft_saved_at, draft_saved_by, created_by)
  values (
    p_concept_id, p_role,
    coalesce((select max(sort_order) + 1 from public.concept_statements where concept_id = p_concept_id and role = p_role), 0),
    v_content, 'owner', clock_timestamp(), auth.uid(), auth.uid()
  )
  returning * into v_row;
  return to_jsonb(v_row);
end;
$$;

-- 초안 저장. 확정본은 바꾸지 않는다. 확정본과 같은 내용으로 돌려 놓으면 초안을 비운다.
create or replace function public.concept_statement_save_draft(
  p_id uuid,
  p_content jsonb,
  p_expected_version integer,
  p_expected_draft_saved_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.concept_statements;
  v_content jsonb;
begin
  perform public.concept_statement_assert_operator();
  v_row := public.concept_statement_lock(p_id, p_expected_version, p_expected_draft_saved_at);
  v_content := public.concept_statement_clean(v_row.role, p_content);
  if v_row.version > 0 and v_content = v_row.content then
    update public.concept_statements
       set draft = null, draft_origin = null, draft_saved_at = null, draft_saved_by = null
     where id = p_id
    returning * into v_row;
  else
    update public.concept_statements
       set draft = v_content, draft_origin = 'owner', draft_saved_at = clock_timestamp(), draft_saved_by = auth.uid()
     where id = p_id
    returning * into v_row;
  end if;
  return to_jsonb(v_row);
end;
$$;

-- 저장된 초안을 확정본으로 올린다. 저장 안 된 편집은 여기 올 수 없다(앱은 저장 뒤에만 확정을 연다).
create or replace function public.concept_statement_confirm(
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
  v_row public.concept_statements;
begin
  perform public.concept_statement_assert_operator();
  v_row := public.concept_statement_lock(p_id, p_expected_version, p_expected_draft_saved_at);
  if v_row.draft is null then
    raise exception 'concept_statement_no_draft';
  end if;
  if char_length(coalesce(p_note, '')) > 2000 then
    raise exception 'concept_statement_too_long';
  end if;
  insert into public.concept_statement_revisions (statement_id, version, content, note, confirmed_by)
  values (p_id, v_row.version + 1, v_row.draft, nullif(btrim(coalesce(p_note, '')), ''), auth.uid());
  update public.concept_statements
     set content = v_row.draft, version = v_row.version + 1,
         confirmed_at = clock_timestamp(), confirmed_by = auth.uid(),
         draft = null, draft_origin = null, draft_saved_at = null, draft_saved_by = null
   where id = p_id
  returning * into v_row;
  return to_jsonb(v_row);
end;
$$;

-- 저장된 초안을 버린다. 확정한 적 없는 것은 초안이 전부라 줄째 지운다({id, removed: true}).
-- 그 서술에 출처·등장 위치가 붙어 있으면 지우지 않는다(concept_statement_in_use). 확정한 서술은 지우는 길이 없다.
create or replace function public.concept_statement_discard_draft(
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
  v_row public.concept_statements;
begin
  perform public.concept_statement_assert_operator();
  v_row := public.concept_statement_lock(p_id, p_expected_version, p_expected_draft_saved_at);
  if v_row.draft is null then
    raise exception 'concept_statement_no_draft';
  end if;
  if v_row.version = 0 then
    if exists (select 1 from public.concept_sources where statement_id = p_id)
       or exists (select 1 from public.concept_appearances where statement_id = p_id) then
      raise exception 'concept_statement_in_use';
    end if;
    delete from public.concept_statements where id = p_id;
    return jsonb_build_object('id', p_id, 'removed', true);
  end if;
  update public.concept_statements
     set draft = null, draft_origin = null, draft_saved_at = null, draft_saved_by = null
   where id = p_id
  returning * into v_row;
  return to_jsonb(v_row);
end;
$$;

-- 출처 한 줄을 서술에 잇거나(p_statement_id), 기본 서술로 되돌린다(null). 책·쪽은 바꾸지 않는다.
create or replace function public.concept_source_set_statement(p_source_id uuid, p_statement_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.concept_sources;
begin
  perform public.concept_statement_assert_operator();
  update public.concept_sources set statement_id = p_statement_id where id = p_source_id
  returning * into v_row;
  if not found then
    raise exception 'concept_statement_source_not_found';
  end if;
  return to_jsonb(v_row);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 5) 접근
-- ─────────────────────────────────────────────────────────────────────────

alter table public.concept_statements enable row level security;
alter table public.concept_statement_revisions enable row level security;
alter table public.concept_appearances enable row level security;
alter table public.concept_content_revisions enable row level security;

drop policy if exists concept_statements_operator_select on public.concept_statements;
create policy concept_statements_operator_select on public.concept_statements
  for select to authenticated
  using ((select public.is_superadmin()));

drop policy if exists concept_statement_revisions_operator_select on public.concept_statement_revisions;
create policy concept_statement_revisions_operator_select on public.concept_statement_revisions
  for select to authenticated
  using ((select public.is_superadmin()));

drop policy if exists concept_content_revisions_operator_select on public.concept_content_revisions;
create policy concept_content_revisions_operator_select on public.concept_content_revisions
  for select to authenticated
  using ((select public.is_superadmin()));

drop policy if exists concept_appearances_operator_select on public.concept_appearances;
create policy concept_appearances_operator_select on public.concept_appearances
  for select to authenticated
  using ((select public.is_superadmin()));
drop policy if exists concept_appearances_operator_insert on public.concept_appearances;
create policy concept_appearances_operator_insert on public.concept_appearances
  for insert to authenticated
  with check ((select public.is_superadmin()));
drop policy if exists concept_appearances_operator_delete on public.concept_appearances;
create policy concept_appearances_operator_delete on public.concept_appearances
  for delete to authenticated
  using ((select public.is_superadmin()));

revoke all on public.concept_statements, public.concept_statement_revisions,
  public.concept_appearances, public.concept_content_revisions from anon;
revoke insert, update, delete, truncate on public.concept_statements, public.concept_statement_revisions,
  public.concept_content_revisions from authenticated;
revoke update, truncate on public.concept_appearances from authenticated;

revoke all on function public.concept_statement_assert_operator() from public, anon, authenticated;
revoke all on function public.concept_statement_text(jsonb, text, integer) from public, anon, authenticated;
revoke all on function public.concept_statement_clean(text, jsonb) from public, anon, authenticated;
revoke all on function public.concept_statement_lock(uuid, integer, timestamptz) from public, anon, authenticated;
revoke all on function public.concept_statement_link_check() from public, anon, authenticated;
revoke all on function public.concept_content_history() from public, anon, authenticated;
revoke all on function public.concept_statement_create(uuid, text, jsonb) from public, anon;
revoke all on function public.concept_statement_save_draft(uuid, jsonb, integer, timestamptz) from public, anon;
revoke all on function public.concept_statement_confirm(uuid, integer, timestamptz, text) from public, anon;
revoke all on function public.concept_statement_discard_draft(uuid, integer, timestamptz) from public, anon;
revoke all on function public.concept_source_set_statement(uuid, uuid) from public, anon;

grant execute on function public.concept_statement_create(uuid, text, jsonb) to authenticated;
grant execute on function public.concept_statement_save_draft(uuid, jsonb, integer, timestamptz) to authenticated;
grant execute on function public.concept_statement_confirm(uuid, integer, timestamptz, text) to authenticated;
grant execute on function public.concept_statement_discard_draft(uuid, integer, timestamptz) to authenticated;
grant execute on function public.concept_source_set_statement(uuid, uuid) to authenticated;

notify pgrst, 'reload schema';
