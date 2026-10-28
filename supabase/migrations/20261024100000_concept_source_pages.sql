-- 20261024100000: Think가 개념 출처의 원본 쪽을 다시 읽는다 (운영자 결정 2026-10-23)
--
-- 설계: docs/architecture/concept-library.md §4.7
--
-- Think가 개념을 검토하다 문맥이 빠졌거나 그림 설명이 틀렸다고 의심되면, 출처가 가리키는 PDF 쪽과 앞뒤 2쪽까지를 직접 읽는다.
--   concept_source_page_images   쪽 이미지 요청과 결과. ai_think(운영자 권한)가 요청하고, 운영자 PC의 게이트웨이(서버 키)가
--                                원본 PDF에서 그 쪽만 PNG로 만들어 저장소 concept-source-pages 에 올린다.
--                                요청 때 본 본문 PDF 연결(link_id)과 파일 해시 앞 16자(content_key)를 함께 적는다.
--                                지금 연결·해시와 다르면 예전 이미지는 쓰지 않고 다시 만든다.
--   concept_source_page_workers  게이트웨이가 살아 있다는 표시. 게이트웨이가 15초마다 고친다.
-- 쪽은 출처의 PDF 쪽(raw_page)으로만 고른다. 인쇄 쪽(display_page)은 표시용이고, 기록이 없으면 비워 둔다(추정하지 않는다).
-- 원본 열람은 개념·서술·출처·검토 기록·관계를 바꾸지 않는다. 이 파일의 RPC가 쓰는 것은 쪽 이미지 요청 행뿐이다.

-- ─────────────────────────────────────────────────────────────────────────
-- 1) 표와 저장소
-- ─────────────────────────────────────────────────────────────────────────

create table if not exists public.concept_source_page_images (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  book_id uuid not null references public.resource_files(id) on delete cascade,
  grade_label text not null check (btrim(grade_label) <> ''),
  raw_page integer not null check (raw_page > 0),
  link_id bigint not null,
  content_key text not null check (content_key ~ '^[A-Za-z0-9]{1,16}$'),
  status text not null default 'queued' check (status in ('queued', 'working', 'ready', 'failed')),
  error text check (error is null or char_length(error) <= 80),
  image_key text check (image_key is null or char_length(image_key) <= 300),
  width integer check (width is null or width > 0),
  height integer check (height is null or height > 0),
  bytes integer check (bytes is null or bytes > 0),
  attempts integer not null default 0,
  worker_name text check (worker_name is null or char_length(worker_name) <= 80),
  requested_by uuid references auth.users(id) on delete set null,
  requested_at timestamptz not null default now(),
  started_at timestamptz,
  heartbeat_at timestamptz,
  finished_at timestamptz,
  unique (academy_id, book_id, grade_label, raw_page),
  constraint concept_source_page_images_ready_chk check (
    status <> 'ready' or (image_key is not null and width is not null and height is not null)
  )
);

create index if not exists concept_source_page_images_queue_idx
  on public.concept_source_page_images (requested_at) where status in ('queued', 'working');

create table if not exists public.concept_source_page_workers (
  name text primary key check (char_length(name) between 1 and 80),
  seen_at timestamptz not null default now()
);

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('concept-source-pages', 'concept-source-pages', false, 10485760, array['image/png'])
on conflict (id) do nothing;

-- 경로: academies/<academy_id>/books/<book_id>/links/<link_id>/<content_key>_p<쪽>.png
-- 개념 출처를 읽을 수 있는 운영자이면서 그 교재의 학원 소속일 때만 읽는다(교재 PDF 저장소와 같은 소속 조건).
-- 쓰기는 게이트웨이(서버 키)만 한다.
drop policy if exists "concept source pages operator select" on storage.objects;
create policy "concept source pages operator select" on storage.objects
for select to authenticated
using (
  bucket_id = 'concept-source-pages'
  and (select public.is_superadmin())
  and exists (
    select 1 from public.memberships m
     where m.user_id = auth.uid()
       and m.academy_id::text = split_part(name, '/', 2)
  )
);

-- ─────────────────────────────────────────────────────────────────────────
-- 2) 본문 PDF 연결
-- ─────────────────────────────────────────────────────────────────────────

-- 교재 한 학년의 본문 PDF 연결(resource_file_links, grade = '<학년>#body').
-- {status: ok | link_missing | link_ambiguous | link_legacy, link_id?, content_key?}
-- 연결이 둘 이상이면 고르지 않는다. 저장소로 옮기지 않은 옛 연결은 쪽을 잘라 낼 수 없다.
create or replace function public.concept_source_page_link(p_academy_id uuid, p_book_id uuid, p_grade_label text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_n integer;
  v_l record;
begin
  select count(*) into v_n
    from public.resource_file_links
   where academy_id = p_academy_id and file_id = p_book_id and grade = p_grade_label || '#body';
  if v_n = 0 then
    return jsonb_build_object('status', 'link_missing');
  end if;
  if v_n > 1 then
    return jsonb_build_object('status', 'link_ambiguous');
  end if;
  select id, migration_status, storage_driver, storage_bucket, storage_key, content_hash into v_l
    from public.resource_file_links
   where academy_id = p_academy_id and file_id = p_book_id and grade = p_grade_label || '#body';
  if coalesce(v_l.migration_status, 'legacy') = 'legacy'
     or v_l.storage_driver is null or v_l.storage_bucket is null or v_l.storage_key is null then
    return jsonb_build_object('status', 'link_legacy', 'link_id', v_l.id);
  end if;
  -- 게이트웨이 textbookContentHashShort 와 같은 값이어야 한다.
  return jsonb_build_object(
    'status', 'ok',
    'link_id', v_l.id,
    'content_key', coalesce(nullif(left(regexp_replace(coalesce(v_l.content_hash, ''), '[^A-Za-z0-9]', '', 'g'), 16), ''), 'nohash')
  );
end;
$$;

-- 이미 만든 쪽 이미지가 지금 원본의 것인지. 상태만 돌려준다(이미지 위치는 concept_source_page_image 로만 준다).
create or replace function public.concept_source_page_image_state(
  p_academy_id uuid, p_book_id uuid, p_grade_label text, p_raw_page integer, p_link jsonb
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_job public.concept_source_page_images;
begin
  if p_link ->> 'status' is distinct from 'ok' then
    return jsonb_build_object('status', p_link ->> 'status');
  end if;
  select * into v_job from public.concept_source_page_images
   where academy_id = p_academy_id and book_id = p_book_id and grade_label = p_grade_label and raw_page = p_raw_page;
  if not found then
    return jsonb_build_object('status', 'not_requested');
  end if;
  if v_job.link_id is distinct from (p_link ->> 'link_id')::bigint or v_job.content_key is distinct from p_link ->> 'content_key' then
    return jsonb_build_object('status', 'stale');
  end if;
  return jsonb_build_object('status', v_job.status, 'error', v_job.error);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 3) Think 조회 RPC (운영자만, 읽기 전용)
-- ─────────────────────────────────────────────────────────────────────────

-- 개념의 출처 목록. 줄마다 PDF 쪽(raw_page)과 인쇄 쪽(display_page, 기록 없으면 null)을 따로 준다.
--   {concept_id, name, total, sources: [{id, statement_id, statement_title, book_id, book_name, grade_label, raw_page, display_page,
--    unit_path, evidence_scope, block_count, draft: none | missing | found, draft_covers_page, transcript_reads, member, link, image}]}
create or replace function public.concept_source_list(p_concept_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_name text;
  v_total integer;
  v_items jsonb;
begin
  perform public.concept_statement_assert_operator();
  select name into v_name from public.concepts where id = p_concept_id;
  if not found then
    raise exception 'concept_source_concept_not_found';
  end if;
  select count(*) into v_total from public.concept_sources where concept_id = p_concept_id;
  select coalesce(jsonb_agg(x.j order by x.n), '[]'::jsonb) into v_items
    from (
      select row_number() over (order by coalesce(r.name, ''), s.grade_label, s.raw_page, s.created_at, s.id) as n,
             jsonb_build_object(
               'id', s.id,
               'statement_id', s.statement_id,
               'statement_title', coalesce(st.content, st.draft) ->> 'title',
               'book_id', s.book_id,
               'book_name', r.name,
               'grade_label', s.grade_label,
               'raw_page', s.raw_page,
               'display_page', s.display_page,
               'unit_path', to_jsonb(s.unit_path),
               'evidence_scope', s.evidence_scope,
               'block_count', cardinality(s.block_ids),
               -- 초안이 지워지면 draft_id 는 비지만 근거 블록 id 는 남는다. 그것도 연결이 끊긴 것이다.
               'draft', case
                          when d.id is not null then 'found'
                          when s.draft_id is not null or cardinality(s.block_ids) > 0 then 'missing'
                          else 'none'
                        end,
               'draft_covers_page', d.id is not null and s.raw_page = any (d.pages),
               'transcript_reads', (
                 select count(distinct t.read_index)
                   from public.concept_page_transcripts t
                  where t.academy_id = s.academy_id and t.book_id = s.book_id
                    and t.grade_label = s.grade_label and t.raw_page = s.raw_page
               ),
               'member', exists (
                 select 1 from public.memberships m where m.academy_id = s.academy_id and m.user_id = auth.uid()
               ),
               'link', lk.link ->> 'status',
               'image', public.concept_source_page_image_state(s.academy_id, s.book_id, s.grade_label, s.raw_page, lk.link)
             ) as j
        from public.concept_sources s
        left join public.resource_files r on r.id = s.book_id
        left join public.concept_drafts d on d.id = s.draft_id
        left join public.concept_statements st on st.id = s.statement_id
        cross join lateral (select public.concept_source_page_link(s.academy_id, s.book_id, s.grade_label) as link) lk
       where s.concept_id = p_concept_id
       order by 1
       limit 300
    ) x;
  return jsonb_build_object('concept_id', p_concept_id, 'name', v_name, 'total', v_total, 'sources', v_items);
end;
$$;

-- 출처 하나가 가리키는 PDF 쪽(raw_page + p_offset, p_offset 은 -2~2)의 글 자료.
--   source    출처 줄(근거 블록 id 포함)
--   page      {raw_page, offset, display_page, display_from: source | draft | transcript | null}
--   blocks    출처를 만든 초안이 그 쪽을 덮으면 초안의 맞춘 블록(blocks_from 'draft'), 아니면 그 쪽 첫 번째 읽기 전사(blocks_from 'transcript').
--             둘 다 없으면 비어 있고 blocks_from 은 null 이다. 다른 쪽의 글로 채우지 않는다.
--   linked_missing  출처 쪽에서 근거 블록 id 가 초안 기록에 없는 것(연결 끊김). 초안이 지워졌으면 모두.
--   masks     전사할 때 가린 문항 영역(전사가 없으면 null = 모름)
--   basis     출처 쪽(p_offset 0)에서만: 이 출처가 뒷받침하는 편집 본문(개념 본문 또는 서술)
create or replace function public.concept_source_page_context(p_source_id uuid, p_offset integer)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_src public.concept_sources;
  v_page integer;
  v_concept text;
  v_book text;
  v_draft public.concept_drafts;
  v_covers boolean := false;
  v_tr record;
  v_has_tr boolean := false;
  v_reads jsonb;
  v_display integer;
  v_display_from text;
  v_blocks jsonb := '[]'::jsonb;
  v_from text;
  v_missing jsonb := '[]'::jsonb;
  v_disagree jsonb := '[]'::jsonb;
begin
  perform public.concept_statement_assert_operator();
  if p_offset is null or p_offset < -2 or p_offset > 2 then
    raise exception 'concept_source_page_bad_offset';
  end if;
  select * into v_src from public.concept_sources where id = p_source_id;
  if not found then
    raise exception 'concept_source_not_found';
  end if;
  v_page := v_src.raw_page + p_offset;
  select name into v_concept from public.concepts where id = v_src.concept_id;
  select name into v_book from public.resource_files where id = v_src.book_id;

  if v_src.draft_id is not null then
    select * into v_draft from public.concept_drafts where id = v_src.draft_id;
    v_covers := found
      and v_draft.academy_id = v_src.academy_id and v_draft.book_id = v_src.book_id and v_draft.grade_label = v_src.grade_label
      and v_page = any (v_draft.pages);
  end if;

  select t.prompt_version, t.display_page, t.masks, t.page ->> 'page_kind' as page_kind, t.page ->> 'notes' as notes,
         t.page -> 'blocks' as blocks, t.created_at
    into v_tr
    from public.concept_page_transcripts t
   where t.academy_id = v_src.academy_id and t.book_id = v_src.book_id and t.grade_label = v_src.grade_label
     and t.raw_page = v_page and t.read_index = 1
   order by t.created_at desc, t.id
   limit 1;
  v_has_tr := found;
  if v_has_tr then
    select coalesce(jsonb_agg(distinct t.read_index order by t.read_index), '[]'::jsonb) into v_reads
      from public.concept_page_transcripts t
     where t.academy_id = v_src.academy_id and t.book_id = v_src.book_id and t.grade_label = v_src.grade_label
       and t.raw_page = v_page and t.prompt_version = v_tr.prompt_version;
  end if;

  if p_offset = 0 and v_src.display_page is not null then
    v_display := v_src.display_page;
    v_display_from := 'source';
  end if;
  if v_display is null and v_covers then
    select nullif(pm ->> 'display_page', '')::integer into v_display
      from jsonb_array_elements(v_draft.page_meta) pm
     where pm ->> 'raw_page' = v_page::text
     limit 1;
    if v_display is not null and v_display > 0 then
      v_display_from := 'draft';
    else
      v_display := null;
    end if;
  end if;
  if v_display is null and v_has_tr and v_tr.display_page is not null then
    v_display := v_tr.display_page;
    v_display_from := 'transcript';
  end if;

  if v_covers then
    v_from := 'draft';
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', b ->> 'id', 'read', b ->> 'read', 'kind', b ->> 'kind', 'title', b ->> 'title', 'text', b ->> 'text',
             'figure_description', b ->> 'figure_description', 'uncertain', b -> 'uncertain',
             'linked', (b ->> 'id') = any (v_src.block_ids)
           ) order by n), '[]'::jsonb)
      into v_blocks
      from jsonb_array_elements(coalesce(v_draft.prepared -> 'blocks', '[]'::jsonb)) with ordinality as e(b, n)
     where b ->> 'raw_page' = v_page::text;
    select coalesce(jsonb_agg(jsonb_build_object('id', x ->> 'id', 'type', x ->> 'type') order by n), '[]'::jsonb)
      into v_disagree
      from jsonb_array_elements(
             case when jsonb_typeof(v_draft.prepared -> 'disagreements') = 'array' then v_draft.prepared -> 'disagreements' else '[]'::jsonb end
           ) with ordinality as e(x, n)
     where x ->> 'raw_page' = v_page::text;
  elsif v_has_tr then
    v_from := 'transcript';
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', null, 'read', 'a', 'kind', b ->> 'kind', 'title', b ->> 'title', 'text', b ->> 'text',
             'figure_description', b ->> 'figure_description', 'uncertain', b -> 'uncertain', 'linked', false
           ) order by n), '[]'::jsonb)
      into v_blocks
      from jsonb_array_elements(case when jsonb_typeof(v_tr.blocks) = 'array' then v_tr.blocks else '[]'::jsonb end)
           with ordinality as e(b, n);
  end if;

  if p_offset = 0 and cardinality(v_src.block_ids) > 0 then
    select coalesce(jsonb_agg(x.id order by x.n), '[]'::jsonb) into v_missing
      from unnest(v_src.block_ids) with ordinality as x(id, n)
     where v_draft.id is null
        or not exists (
          select 1 from jsonb_array_elements(coalesce(v_draft.prepared -> 'blocks', '[]'::jsonb)) b where b ->> 'id' = x.id
        );
  end if;

  return jsonb_build_object(
    'source', jsonb_build_object(
      'id', v_src.id, 'concept_id', v_src.concept_id, 'concept_name', v_concept, 'statement_id', v_src.statement_id,
      'book_id', v_src.book_id, 'book_name', v_book, 'grade_label', v_src.grade_label,
      'raw_page', v_src.raw_page, 'display_page', v_src.display_page, 'unit_path', to_jsonb(v_src.unit_path),
      'evidence_scope', v_src.evidence_scope, 'evidence_note', v_src.evidence_note,
      'draft_id', v_src.draft_id, 'draft_found', v_draft.id is not null, 'block_ids', to_jsonb(v_src.block_ids)
    ),
    'page', jsonb_build_object('raw_page', v_page, 'offset', p_offset, 'display_page', v_display, 'display_from', v_display_from),
    'blocks_from', v_from,
    'blocks', v_blocks,
    'linked_missing', v_missing,
    'disagreements', v_disagree,
    'transcript', case when v_has_tr then jsonb_build_object(
      'prompt_version', v_tr.prompt_version, 'reads', v_reads, 'page_kind', v_tr.page_kind, 'notes', v_tr.notes,
      'created_at', v_tr.created_at
    ) end,
    'masks', case when v_has_tr then v_tr.masks end,
    'basis', case when p_offset = 0 then public.concept_source_basis(v_src.concept_id, v_src.statement_id) end
  );
end;
$$;

-- 출처 쪽(raw_page + p_offset)의 원본 이미지. p_request 가 true 면 없거나 다시 만들어야 할 때 게이트웨이 대기열에 넣는다.
-- false 는 기다리는 동안 상태만 본다.
--   {status: ready | queued | working | failed | not_requested | stale | no_page | forbidden | link_missing | link_ambiguous | link_legacy,
--    error, raw_page, image_bucket·image_key·width·height·bytes(ready 일 때만), worker_alive, worker_seen_at}
-- 원본 연결이나 파일이 바뀐 뒤의 예전 이미지는 ready 로 돌려주지 않는다.
create or replace function public.concept_source_page_image(p_source_id uuid, p_offset integer, p_request boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_src public.concept_sources;
  v_page integer;
  v_link jsonb;
  v_job public.concept_source_page_images;
  v_seen timestamptz;
  v_out jsonb;
  v_request boolean := coalesce(p_request, false);
begin
  perform public.concept_statement_assert_operator();
  if p_offset is null or p_offset < -2 or p_offset > 2 then
    raise exception 'concept_source_page_bad_offset';
  end if;
  select * into v_src from public.concept_sources where id = p_source_id;
  if not found then
    raise exception 'concept_source_not_found';
  end if;
  v_page := v_src.raw_page + p_offset;
  select max(seen_at) into v_seen from public.concept_source_page_workers;
  v_out := jsonb_build_object(
    'raw_page', v_page,
    'worker_seen_at', v_seen,
    'worker_alive', coalesce(v_seen > clock_timestamp() - interval '60 seconds', false)
  );
  if v_page < 1 then
    return v_out || jsonb_build_object('status', 'no_page');
  end if;
  if not exists (select 1 from public.memberships m where m.academy_id = v_src.academy_id and m.user_id = auth.uid()) then
    return v_out || jsonb_build_object('status', 'forbidden');
  end if;
  v_link := public.concept_source_page_link(v_src.academy_id, v_src.book_id, v_src.grade_label);
  if v_link ->> 'status' <> 'ok' then
    return v_out || jsonb_build_object('status', v_link ->> 'status');
  end if;

  select * into v_job from public.concept_source_page_images
   where academy_id = v_src.academy_id and book_id = v_src.book_id and grade_label = v_src.grade_label and raw_page = v_page
   for update;
  if not found then
    if not v_request then
      return v_out || jsonb_build_object('status', 'not_requested');
    end if;
    insert into public.concept_source_page_images (academy_id, book_id, grade_label, raw_page, link_id, content_key, requested_by)
    values (v_src.academy_id, v_src.book_id, v_src.grade_label, v_page, (v_link ->> 'link_id')::bigint, v_link ->> 'content_key', auth.uid())
    on conflict (academy_id, book_id, grade_label, raw_page) do nothing
    returning * into v_job;
    if v_job.id is null then
      select * into v_job from public.concept_source_page_images
       where academy_id = v_src.academy_id and book_id = v_src.book_id and grade_label = v_src.grade_label and raw_page = v_page;
    end if;
  elsif v_job.link_id is distinct from (v_link ->> 'link_id')::bigint or v_job.content_key is distinct from v_link ->> 'content_key' then
    if not v_request then
      return v_out || jsonb_build_object('status', 'stale');
    end if;
    update public.concept_source_page_images
       set status = 'queued', link_id = (v_link ->> 'link_id')::bigint, content_key = v_link ->> 'content_key', error = null,
           image_key = null, width = null, height = null, bytes = null, attempts = 0, worker_name = null,
           requested_by = auth.uid(), requested_at = clock_timestamp(), started_at = null, heartbeat_at = null, finished_at = null
     where id = v_job.id
    returning * into v_job;
  elsif v_request and (
      (v_job.status = 'failed' and v_job.error is distinct from 'page_out_of_range'
        and coalesce(v_job.finished_at, v_job.requested_at) < clock_timestamp() - interval '1 minute')
      or (v_job.status = 'working'
        and coalesce(v_job.heartbeat_at, v_job.started_at, v_job.requested_at) < clock_timestamp() - interval '3 minutes')
    ) then
    update public.concept_source_page_images
       set status = 'queued', error = null, worker_name = null, requested_by = auth.uid(), requested_at = clock_timestamp(),
           started_at = null, heartbeat_at = null, finished_at = null
     where id = v_job.id
    returning * into v_job;
  end if;

  return v_out || jsonb_build_object(
    'status', v_job.status,
    'error', v_job.error,
    'requested_at', v_job.requested_at,
    'started_at', v_job.started_at,
    'image_bucket', case when v_job.status = 'ready' then 'concept-source-pages' end,
    'image_key', case when v_job.status = 'ready' then v_job.image_key end,
    'width', case when v_job.status = 'ready' then v_job.width end,
    'height', case when v_job.status = 'ready' then v_job.height end,
    'bytes', case when v_job.status = 'ready' then v_job.bytes end
  );
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 4) 기능 확인 (20261023180000 정의에 concept_source_pages 추가)
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
    end,
    'concept_relation_change',
    case
      when exists (
         select 1 from pg_attribute
          where attrelid = 'public.concept_relations'::regclass and attname = 'judged_marks' and not attisdropped
       )
       and to_regclass('public.concept_relation_events') is not null
       and to_regprocedure('public.concept_relation_list(uuid)') is not null
       and to_regprocedure('public.course_think_propose_relation(uuid, jsonb, text)') is not null
       and to_regprocedure('public.course_think_apply_relation(public.ai_actions, jsonb)') is not null
      then 1
      else 0
    end,
    'concept_source_pages',
    case
      when to_regclass('public.concept_source_page_images') is not null
       and to_regclass('public.concept_source_page_workers') is not null
       and to_regprocedure('public.concept_source_list(uuid)') is not null
       and to_regprocedure('public.concept_source_page_context(uuid, integer)') is not null
       and to_regprocedure('public.concept_source_page_image(uuid, integer, boolean)') is not null
      then 1
      else 0
    end
  );
end
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 5) 권한
-- ─────────────────────────────────────────────────────────────────────────

alter table public.concept_source_page_images enable row level security;
alter table public.concept_source_page_workers enable row level security;
revoke all on public.concept_source_page_images, public.concept_source_page_workers from anon, authenticated;

revoke all on function public.concept_source_page_link(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.concept_source_page_image_state(uuid, uuid, text, integer, jsonb) from public, anon, authenticated;
revoke all on function public.concept_source_list(uuid) from public, anon;
revoke all on function public.concept_source_page_context(uuid, integer) from public, anon;
revoke all on function public.concept_source_page_image(uuid, integer, boolean) from public, anon;

grant execute on function public.concept_source_list(uuid) to authenticated;
grant execute on function public.concept_source_page_context(uuid, integer) to authenticated;
grant execute on function public.concept_source_page_image(uuid, integer, boolean) to authenticated;

notify pgrst, 'reload schema';
