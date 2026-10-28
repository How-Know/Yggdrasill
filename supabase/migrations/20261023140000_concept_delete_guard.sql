-- 20261023140000: 개념 지우기 보호(운영자 결정 2026-10-23, 개념 라이브러리 정리 1단계)
--
-- 설계: docs/architecture/concept-library.md "개념 지우기"
--
-- 붙은 것이 하나도 없는 개념만 지운다. 앱 직접 삭제·Think 카드·폴더 삭제·REST·service role 어느 길이든 DB가 막는다.
-- 1) concept_attachments: 개념을 가리키는 자료를 모두 센다. 유형 연결·본문 고친 기록·열린 교재 초안 검토의 대상과,
--    이 목록에 없는 새 외래키(other)까지 센다. 미리 보기·Think 읽기·카드 제안·승인·실제 삭제가 모두 이 함수 하나를 쓴다.
-- 2) concepts BEFORE DELETE: 로그인한 운영자가 아니면 내용 없이 거절, 붙은 것이 있으면 종류·개수(detail)와 함께 거절.
-- 3) 개념을 가리키는 외래키의 on delete cascade → restrict. 세고 난 뒤 붙은 자료도 개념과 함께 지워지지 않는다.
-- 4) 폴더 → 개념 cascade → restrict, 폴더 BEFORE DELETE: 아래(하위 폴더 포함)에 개념이 있으면 개수와 함께 거절.
-- 5) concept_delete_check(미리 보기) · concept_delete(지우기): 매니저앱 개념 지우기가 쓰는 RPC.
-- 붙은 자료를 지워 조건을 맞추는 기능, 붙은 개념을 강제로 지우는 기능은 두지 않는다.

-- ─────────────────────────────────────────────────────────────────────────
-- 1) 붙은 것 세기
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
-- 2) 개념 지우기 막기
-- ─────────────────────────────────────────────────────────────────────────

create or replace function public.concepts_delete_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_att jsonb;
begin
  -- auth.uid() 가 없으면 service role·DB 관리 작업이다. 붙은 것 검사는 그때도 한다.
  if auth.uid() is not null and not public.is_superadmin() then
    raise exception 'concept_delete_forbidden';
  end if;
  v_att := public.concept_attachments(old.id);
  if (v_att ->> 'total')::integer > 0 then
    raise exception 'concept_delete_attached' using detail = v_att::text;
  end if;
  return old;
end;
$$;

drop trigger if exists trg_concepts_delete_guard on public.concepts;
create trigger trg_concepts_delete_guard
  before delete on public.concepts
  for each row execute function public.concepts_delete_guard();

-- ─────────────────────────────────────────────────────────────────────────
-- 3) 외래키: 개념을 지워도 붙은 자료가 따라 지워지지 않게
-- ─────────────────────────────────────────────────────────────────────────

do $$
declare
  r record;
begin
  for r in
    select c.conrelid::regclass as tbl, c.conname, pg_get_constraintdef(c.oid) as def
      from pg_constraint c
     where c.contype = 'f' and c.confdeltype = 'c'
       and (c.confrelid = 'public.concepts'::regclass
            or (c.conrelid = 'public.concepts'::regclass and c.confrelid = 'public.concept_categories'::regclass))
  loop
    execute format(
      'alter table %s drop constraint %I, add constraint %I %s',
      r.tbl, r.conname, r.conname, replace(r.def, 'ON DELETE CASCADE', 'ON DELETE RESTRICT')
    );
  end loop;
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 4) 폴더 지우기 막기
-- ─────────────────────────────────────────────────────────────────────────

create or replace function public.concept_categories_delete_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_n integer;
begin
  with recursive tree(id) as (
    select old.id
    union
    select c.id from public.concept_categories c join tree t on c.parent_id = t.id
  )
  select count(*) into v_n from public.concepts where main_category_id in (select id from tree);
  if v_n > 0 then
    raise exception 'concept_folder_not_empty' using detail = jsonb_build_object('concepts', v_n)::text;
  end if;
  return old;
end;
$$;

drop trigger if exists trg_concept_categories_delete_guard on public.concept_categories;
create trigger trg_concept_categories_delete_guard
  before delete on public.concept_categories
  for each row execute function public.concept_categories_delete_guard();

-- ─────────────────────────────────────────────────────────────────────────
-- 5) 매니저앱 개념 지우기
-- ─────────────────────────────────────────────────────────────────────────

create or replace function public.concept_delete_assert_operator()
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.is_superadmin() then
    raise exception 'concept_delete_forbidden';
  end if;
end;
$$;

-- 지우기 전에 본다. 지울 때 다시 센다(그사이 붙은 것이 생기면 지우지 않는다).
create or replace function public.concept_delete_check(p_concept_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_name text;
  v_att jsonb;
begin
  perform public.concept_delete_assert_operator();
  select name into v_name from public.concepts where id = p_concept_id;
  if not found then
    raise exception 'concept_delete_not_found';
  end if;
  v_att := public.concept_attachments(p_concept_id);
  return jsonb_build_object(
    'id', p_concept_id, 'name', v_name, 'deletable', (v_att ->> 'total')::integer = 0, 'attached', v_att
  );
end;
$$;

create or replace function public.concept_delete(p_concept_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_concept public.concepts;
begin
  perform public.concept_delete_assert_operator();
  select * into v_concept from public.concepts where id = p_concept_id for update;
  if not found then
    raise exception 'concept_delete_not_found';
  end if;
  delete from public.concepts where id = p_concept_id;
  return jsonb_build_object('id', v_concept.id, 'name', v_concept.name);
end;
$$;

revoke all on function public.concept_attachments(uuid) from public, anon, authenticated;
revoke all on function public.concepts_delete_guard() from public, anon, authenticated;
revoke all on function public.concept_categories_delete_guard() from public, anon, authenticated;
revoke all on function public.concept_delete_assert_operator() from public, anon, authenticated;
revoke all on function public.concept_delete_check(uuid) from public, anon;
revoke all on function public.concept_delete(uuid) from public, anon;
grant execute on function public.concept_delete_check(uuid) to authenticated;
grant execute on function public.concept_delete(uuid) to authenticated;
