-- 20261020160000: 출처 근거 범위와 근거 블록 (운영자 결정 2026-10-20, 여러 교재 설명 통합 2단계)
--
-- 설계: docs/architecture/concept-library.md §4.3
--
-- 출처(concept_sources)는 책·학년·쪽까지만 적혀 있어, 그 쪽이 서술을 얼마나 뒷받침하는지와 어느 문장이 근거인지 몰랐다.
--   evidence_scope     whole(이 서술 내용이 이 근거에 다 있음) · part(일부만) · related(직접 말하지 않는 관련 설명) · unknown(미확인).
--                      기존 출처는 모두 unknown 이다. 운영자가 정하거나, 운영자가 AI 제안을 받아들일 때만 바뀐다(evidence_origin owner / ai).
--   evidence_note      범위 메모. evidence_basis_md5 는 범위를 정할 때 본 서술 글의 md5 다. 그 뒤 서술이 바뀌면 다시 확인 대상이다.
--   draft_id·block_ids 근거 블록. 원문 글은 복사하지 않고 초안 기록(concept_drafts.prepared.blocks)을 가리킨다.
--                      초안 확정 때 채우고, 이 파일이 기존 확정 초안의 기록으로 한 번 채운다(기록에 있는 블록만, 추정하지 않는다).
-- 같은 쪽이 기본 서술과 다른 서술을 함께 뒷받침할 수 있게 출처 한 줄의 단위를 (개념, 서술, 책, 학년, 쪽)으로 바꾼다.
-- 출처를 지우거나 옮기지 않는다.

-- ─────────────────────────────────────────────────────────────────────────
-- 1) 열과 한 줄 단위
-- ─────────────────────────────────────────────────────────────────────────

alter table public.concept_sources
  add column if not exists evidence_scope text not null default 'unknown',
  add column if not exists evidence_note text,
  add column if not exists evidence_origin text,
  add column if not exists evidence_basis_md5 text,
  add column if not exists evidence_set_at timestamptz,
  add column if not exists evidence_set_by uuid references auth.users(id) on delete set null,
  add column if not exists draft_id uuid references public.concept_drafts(id) on delete set null,
  add column if not exists block_ids text[] not null default '{}'::text[];

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'concept_sources_evidence_chk') then
    alter table public.concept_sources
      add constraint concept_sources_evidence_chk check (
        evidence_scope in ('whole', 'part', 'related', 'unknown')
        and (evidence_note is null or char_length(evidence_note) <= 500)
        and cardinality(block_ids) <= 200
        and ((evidence_origin is null and evidence_set_at is null)
             or (evidence_origin in ('owner', 'ai') and evidence_set_at is not null))
      );
  end if;
end $$;

-- 예전 단위 (개념, 책, 학년, 쪽) 제약을 이름과 상관없이 찾아 뺀다.
do $$
declare
  v_name text;
begin
  for v_name in
    select c.conname
      from pg_constraint c
     where c.conrelid = 'public.concept_sources'::regclass
       and c.contype = 'u'
       and (select array_agg(a.attname::text order by a.attname)
              from unnest(c.conkey) k join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k)
           = array['book_id', 'concept_id', 'grade_label', 'raw_page']
  loop
    execute format('alter table public.concept_sources drop constraint %I', v_name);
  end loop;
end $$;

create unique index if not exists concept_sources_statement_page_unique on public.concept_sources (
  concept_id, coalesce(statement_id, '00000000-0000-0000-0000-000000000000'::uuid), book_id, grade_label, raw_page
);

-- ─────────────────────────────────────────────────────────────────────────
-- 2) 서술 글과 근거
-- ─────────────────────────────────────────────────────────────────────────

-- 출처가 뒷받침하는 글. 기본 서술이면 개념 본문, 서술이면 확정본(없으면 초안)의 제목·본문·적용 조건.
-- {kind: base | confirmed | draft, text, md5}. 범위 판단과 "그 뒤 바뀌었는지"를 같은 글로 본다.
create or replace function public.concept_source_basis(p_concept_id uuid, p_statement_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_text text;
  v_kind text;
  v_t jsonb;
  v_version integer;
begin
  if p_statement_id is null then
    select content into v_text from public.concepts where id = p_concept_id;
    if not found then
      return null;
    end if;
    v_kind := 'base';
  else
    select coalesce(content, draft), version into v_t, v_version
      from public.concept_statements where id = p_statement_id and concept_id = p_concept_id;
    if not found then
      return null;
    end if;
    v_kind := case when v_version > 0 then 'confirmed' else 'draft' end;
    v_text := concat_ws(E'\n', v_t ->> 'title', v_t ->> 'body',
                        case when v_t ? 'conditions' then '적용 대상·조건: ' || (v_t ->> 'conditions') end);
  end if;
  v_text := coalesce(v_text, '');
  return jsonb_build_object('kind', v_kind, 'text', v_text, 'md5', md5(v_text));
end;
$$;

-- 개념의 출처와 근거(운영자 화면·근거 범위 제안이 읽는다).
--   {concept_id, groups: [{statement_id, kind, text, md5}], sources: [{id, statement_id, book_name, grade_label, raw_page, display_page,
--    unit_path, evidence_scope, evidence_note, evidence_origin, evidence_set_at, basis_changed, draft_id, draft_found, blocks[]}]}
-- blocks 는 초안 기록에 남은 블록(id·쪽·종류·제목·글·그림 설명·불확실)이고, 기록이 없으면 비어 있다.
create or replace function public.concept_source_evidence(p_concept_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_groups jsonb;
  v_sources jsonb;
begin
  perform public.concept_statement_assert_operator();
  if not exists (select 1 from public.concepts where id = p_concept_id) then
    raise exception 'concept_source_concept_not_found';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('statement_id', g.statement_id) || g.basis order by g.statement_id nulls first), '[]'::jsonb)
    into v_groups
    from (
      select x.statement_id, public.concept_source_basis(p_concept_id, x.statement_id) as basis
        from (select null::uuid as statement_id
              union
              select distinct statement_id from public.concept_sources where concept_id = p_concept_id and statement_id is not null) x
    ) g
   where g.basis is not null;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', s.id,
           'statement_id', s.statement_id,
           'book_name', r.name,
           'grade_label', s.grade_label,
           'raw_page', s.raw_page,
           'display_page', s.display_page,
           'unit_path', to_jsonb(s.unit_path),
           'evidence_scope', s.evidence_scope,
           'evidence_note', s.evidence_note,
           'evidence_origin', s.evidence_origin,
           'evidence_set_at', s.evidence_set_at,
           'basis_changed', s.evidence_basis_md5 is not null
                            and s.evidence_basis_md5 is distinct from (public.concept_source_basis(p_concept_id, s.statement_id) ->> 'md5'),
           'draft_id', s.draft_id,
           'draft_found', d.id is not null,
           'blocks', coalesce((
             select jsonb_agg(jsonb_build_object(
                      'id', b ->> 'id', 'raw_page', b -> 'raw_page', 'kind', b ->> 'kind', 'title', b ->> 'title',
                      'text', b ->> 'text', 'figure_description', b ->> 'figure_description', 'uncertain', b -> 'uncertain'
                    ) order by array_position(s.block_ids, b ->> 'id'))
               from jsonb_array_elements(coalesce(d.prepared -> 'blocks', '[]'::jsonb)) b
              where (b ->> 'id') = any (s.block_ids)
           ), '[]'::jsonb)
         ) order by s.raw_page, s.created_at), '[]'::jsonb)
    into v_sources
    from public.concept_sources s
    left join public.resource_files r on r.id = s.book_id
    left join public.concept_drafts d on d.id = s.draft_id
   where s.concept_id = p_concept_id;
  return jsonb_build_object('concept_id', p_concept_id, 'groups', v_groups, 'sources', v_sources);
end;
$$;

-- 근거 범위 정하기. p_origin 'ai' 는 운영자가 AI 제안을 받아들일 때이고, 제안이 본 서술 글(p_basis_md5)이 지금과 같아야 한다.
-- 화면에서 본 범위 시각(p_expected_set_at, 정한 적 없으면 null)이 지금과 다르면 막는다.
create or replace function public.concept_source_set_evidence(
  p_source_id uuid,
  p_scope text,
  p_note text,
  p_expected_set_at timestamptz,
  p_origin text default 'owner',
  p_basis_md5 text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.concept_sources;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_md5 text;
begin
  perform public.concept_statement_assert_operator();
  select * into v_row from public.concept_sources where id = p_source_id for update;
  if not found then
    raise exception 'concept_statement_source_not_found';
  end if;
  if v_row.evidence_set_at is distinct from p_expected_set_at then
    raise exception 'concept_source_evidence_stale';
  end if;
  if p_scope is null or p_scope not in ('whole', 'part', 'related', 'unknown') then
    raise exception 'concept_source_bad_scope';
  end if;
  if p_origin is null or p_origin not in ('owner', 'ai') then
    raise exception 'concept_source_bad_scope';
  end if;
  if char_length(coalesce(v_note, '')) > 500 then
    raise exception 'concept_source_note_too_long';
  end if;
  v_md5 := public.concept_source_basis(v_row.concept_id, v_row.statement_id) ->> 'md5';
  if p_origin = 'ai' and p_basis_md5 is distinct from v_md5 then
    raise exception 'concept_source_basis_changed';
  end if;
  update public.concept_sources
     set evidence_scope = p_scope, evidence_note = v_note, evidence_origin = p_origin,
         evidence_basis_md5 = v_md5, evidence_set_at = clock_timestamp(), evidence_set_by = auth.uid()
   where id = p_source_id
  returning * into v_row;
  return jsonb_build_object(
    'id', v_row.id, 'evidence_scope', v_row.evidence_scope, 'evidence_note', v_row.evidence_note,
    'evidence_origin', v_row.evidence_origin, 'evidence_set_at', v_row.evidence_set_at
  );
end;
$$;

-- 이 마이그레이션 전에 확정한 초안의 기록으로 출처에 근거 블록을 잇는다(4절에서 한 번 부른다). 확정 결과(concepts[]: index·key·id·statement_id)마다 검토 항목의 blocks
-- (없으면 AI 초안의 source_blocks)를 쪽별로 나눠, 같은 개념·서술·책·학년·쪽이고 아직 블록이 없는 출처에만 넣는다.
-- 확정 뒤 다른 서술로 옮긴 출처처럼 기록과 맞지 않는 줄은 비워 둔다.
create or replace function public.concept_source_link_draft(p_draft_id uuid, p_concepts jsonb)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.concept_drafts;
  v_c jsonb;
  v_item jsonb;
  v_key text;
  v_idx integer;
  v_concept uuid;
  v_statement uuid;
  v_blocks text[];
  v_n integer := 0;
  v_k integer;
begin
  select * into v_row from public.concept_drafts where id = p_draft_id;
  if not found or jsonb_typeof(p_concepts) is distinct from 'array' then
    return 0;
  end if;
  for v_c in select value from jsonb_array_elements(p_concepts) loop
    begin
      v_concept := (v_c ->> 'id')::uuid;
      v_idx := (v_c ->> 'index')::integer;
      v_statement := nullif(v_c ->> 'statement_id', '')::uuid;
      continue when v_concept is null or v_idx is null;
      v_key := coalesce(nullif(btrim(v_c ->> 'key'), ''), 'c' || v_idx);
      v_item := null;
      select x into v_item
        from jsonb_array_elements(case when jsonb_typeof(v_row.review -> 'concepts') = 'array' then v_row.review -> 'concepts' else '[]'::jsonb end) x
       where coalesce(nullif(btrim(x ->> 'key'), ''), 'c' || (x ->> 'index')) = v_key
       limit 1;
      if v_item is not null and jsonb_typeof(v_item -> 'blocks') = 'array' then
        v_blocks := array(select b #>> '{}' from jsonb_array_elements(v_item -> 'blocks') b where jsonb_typeof(b) = 'string');
      else
        v_blocks := array(
          select b #>> '{}'
            from jsonb_array_elements(
                   case when jsonb_typeof(v_row.draft -> 'concepts' -> v_idx -> 'source_blocks') = 'array'
                        then v_row.draft -> 'concepts' -> v_idx -> 'source_blocks' else '[]'::jsonb end) b
           where jsonb_typeof(b) = 'string'
        );
      end if;
      continue when cardinality(v_blocks) = 0;
      with pb as (
        select b ->> 'id' as id, (b ->> 'raw_page')::integer as raw_page, t.n
          from jsonb_array_elements(coalesce(v_row.prepared -> 'blocks', '[]'::jsonb)) with ordinality as t(b, n)
         where (b ->> 'id') = any (v_blocks)
      ), per_page as (
        select raw_page, (array_agg(id order by n))[1:200] as ids from pb group by raw_page
      )
      update public.concept_sources s
         set draft_id = v_row.id, block_ids = pp.ids
        from per_page pp
       where s.concept_id = v_concept
         and s.statement_id is not distinct from v_statement
         and s.academy_id = v_row.academy_id
         and s.book_id = v_row.book_id
         and s.grade_label = v_row.grade_label
         and s.raw_page = pp.raw_page
         and s.draft_id is null
         and cardinality(s.block_ids) = 0;
      get diagnostics v_k = row_count;
      v_n := v_n + v_k;
    exception when others then
      continue;
    end;
  end loop;
  return v_n;
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 3) 초안 확정: 20261020120000 과 같고, 출처를 넣을 때 그 쪽의 근거 블록(draft_id·block_ids)을 함께 적고
--    서술로 붙이는 출처의 겹침 기준을 새 단위로 바꾼 것만 다르다.
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
-- 4) 이미 확정한 초안의 출처에 근거 블록 잇기 (한 번)
-- ─────────────────────────────────────────────────────────────────────────

do $$
declare
  v_d record;
begin
  for v_d in
    select id, result -> 'concepts' as concepts
      from public.concept_drafts
     where status = 'confirmed' and jsonb_typeof(result -> 'concepts') = 'array'
     order by confirmed_at nulls last, created_at
  loop
    perform public.concept_source_link_draft(v_d.id, v_d.concepts);
  end loop;
end $$;

-- ─────────────────────────────────────────────────────────────────────────
-- 5) 접근
-- ─────────────────────────────────────────────────────────────────────────

revoke all on function public.concept_source_basis(uuid, uuid) from public, anon, authenticated;
revoke all on function public.concept_source_link_draft(uuid, jsonb) from public, anon, authenticated;
revoke all on function public.concept_source_evidence(uuid) from public, anon;
revoke all on function public.concept_source_set_evidence(uuid, text, text, timestamptz, text, text) from public, anon;

grant execute on function public.concept_source_evidence(uuid) to authenticated;
grant execute on function public.concept_source_set_evidence(uuid, text, text, timestamptz, text, text) to authenticated;

notify pgrst, 'reload schema';
