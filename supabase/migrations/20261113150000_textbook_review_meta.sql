-- 20261113150000: 문항 메타(개념·사고·난이도 3축·시각 태그·교재 라벨)를 확정 때 문제은행 쪽에 반영한다.
-- (docs/specs/20261113-교재-문항-검수-흐름과-기준.md 3번, 5-6번, 6-1번, 7번)
--
-- 1) textbook_problem_analyses
--    meta_checked_at   : 단원 기준 개념 후보로 개념·사고를 고른 시각. 비어 있으면 메타 전용 AI 대상이다.
--    concept_proposals : 맞는 개념이 라이브러리에 없을 때 AI가 낸 새 개념 초안
--                        [{name, type, content, near_concept_id, reason}]. 확정 때 개념을 만들고 연결한다.
--    meta_sources      : 사람이 고친 메타 {"concepts": "owner", "thinkings": "owner"}. AI 재실행이 덮어쓰지 않는다.
-- 2) concepts.origin / origin_detail: 교재 검수 확정 때 만든 개념 표시('textbook_review' = 교재 검수에서 생성).
--    개념 출처(concept_sources)는 운영자가 고른 쪽만 넣는 표라 여기서 쓰지 않는다.
--    출처가 없는 개념의 난이도 점수는 만든 학년(origin_detail.grade_label)으로 정한다.
-- 3) pb_question_meta: 확정된 메타의 문제은행 쪽 저장 위치. 검색·통계·출제는 여기를 읽는다.
-- 4) textbook_review_set_meta: 메타 제안을 쓴다. AI 시각 태그는 비어 있을 때만 채운다(시각 요소가 없으면 '없음').
-- 5) textbook_review_unit_overview: 문항에 새 개념 초안, 메타 판정 시각, 사람이 고친 메타 표시를 붙인다.
-- 6) textbook_review_apply_staged: 개념·사고·시각 태그가 비었거나 개념을 단원 기준 후보로 고르지 않았으면
--    (meta_checked_at 없음) 확정하지 않는다. 확정 때 새 개념을 만들어 연결하고 메타를 pb_question_meta 에 반영한다.

-- ── 1) 검수 쪽 메타 제안 ────────────────────────────────────────────────
alter table public.textbook_problem_analyses
  add column if not exists meta_checked_at timestamptz,
  add column if not exists concept_proposals jsonb not null default '[]'::jsonb,
  add column if not exists meta_sources jsonb not null default '{}'::jsonb;

-- ── 2) 교재 검수에서 만든 개념 표시 ─────────────────────────────────────
alter table public.concepts
  add column if not exists origin text,
  add column if not exists origin_detail jsonb not null default '{}'::jsonb;

create index if not exists concepts_origin_idx on public.concepts (origin) where origin is not null;

-- 과정 수준별 기본 난이도 점수 (초등 1.0 · 중1 1.5 · 중2 1.8 · 중3 2.0 · 공통수학 2.5 · 대수/미적1/확통 2.8 · 미적2/기하 3.0)
create or replace function public.concept_grade_score(p_grade text)
returns numeric
language sql
immutable
as $$
  select (case
    when p_grade is null then 2.00
    when p_grade ~ '^초' or p_grade ~ '^[3-6]-' then 1.00
    when p_grade ~ '1-[12]' then 1.50
    when p_grade ~ '2-[12]' then 1.80
    when p_grade ~ '3-[12]' then 2.00
    when p_grade ~ '공통수학' then 2.50
    when p_grade ~ '(미적분2|기하)' then 3.00
    when p_grade ~ '(대수|미적분|확률|통계)' then 2.80
    else 2.00
  end)::numeric;
$$;

create or replace function public.concept_difficulty_score(p_concept_id uuid)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_custom numeric;
  v_origin_grade text;
  v_grade text;
begin
  select c.unit_score, nullif(btrim(c.origin_detail ->> 'grade_label'), '')
    into v_custom, v_origin_grade
    from public.concepts c where c.id = p_concept_id;
  if v_custom is not null then
    return round(v_custom, 2);
  end if;
  select cs.grade_label into v_grade
    from public.concept_sources cs
   where cs.concept_id = p_concept_id
   order by cs.created_at
   limit 1;
  return public.concept_grade_score(coalesce(v_grade, v_origin_grade));
end;
$$;

revoke all on function public.concept_grade_score(text) from public, anon;
grant execute on function public.concept_grade_score(text) to authenticated;
revoke all on function public.concept_difficulty_score(uuid) from public, anon;
grant execute on function public.concept_difficulty_score(uuid) to authenticated;

-- ── 3) 문제은행 쪽 메타 ─────────────────────────────────────────────────
create table if not exists public.pb_question_meta (
  question_id uuid primary key references public.pb_questions(id) on delete cascade,
  academy_id uuid not null references public.academies(id) on delete cascade,
  concept_ids uuid[] not null default '{}'::uuid[],
  thinking_ids uuid[] not null default '{}'::uuid[],
  arithmetic_counts jsonb not null default '{}'::jsonb,
  concept_score numeric(6, 2) not null default 0,
  thinking_score numeric(6, 2) not null default 0,
  arithmetic_score numeric(6, 2) not null default 0,
  total_difficulty numeric(6, 2) not null default 0,
  visual_tags text[] not null default '{}'::text[],
  source_label text not null default '',
  source_crop_id uuid references public.textbook_problem_crops(id) on delete set null,
  confirmed_at timestamptz not null default now(),
  confirmed_by uuid default auth.uid() references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

create index if not exists pb_question_meta_academy_idx on public.pb_question_meta (academy_id);
create index if not exists pb_question_meta_concepts_idx on public.pb_question_meta using gin (concept_ids);
create index if not exists pb_question_meta_thinkings_idx on public.pb_question_meta using gin (thinking_ids);

alter table public.pb_question_meta enable row level security;

drop policy if exists pb_question_meta_select on public.pb_question_meta;
create policy pb_question_meta_select on public.pb_question_meta
  for select to authenticated
  using (exists (
    select 1 from public.memberships m
     where m.user_id = auth.uid() and m.academy_id = pb_question_meta.academy_id
  ));

revoke all on public.pb_question_meta from anon;
revoke insert, update, delete, truncate on public.pb_question_meta from authenticated;
grant select on public.pb_question_meta to authenticated;

-- ── 4) 메타 제안 쓰기 ───────────────────────────────────────────────────
-- 인자가 null 이면 그 항목은 그대로 둔다. p_concept_ids 나 p_concept_proposals 중 하나라도 오면 개념 제안 전체를 바꾼다.
-- AI(p_source='ai')는 사람이 고친 항목(meta_sources)을 건너뛴다. 사장님(p_source='owner')이 쓰면 그 항목을 표시한다.
-- 시각 태그는 AI 가 비어 있을 때만 채운다. meta_checked_at 은 개념이나 사고를 고른 때만 찍는다.
create or replace function public.textbook_review_set_meta(
  p_crop_id uuid,
  p_concept_ids uuid[] default null,
  p_thinking_ids uuid[] default null,
  p_concept_proposals jsonb default null,
  p_visual_tags text[] default null,
  p_source text default 'ai'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_crop public.textbook_problem_crops;
  v_src jsonb;
  v_set_concepts boolean;
  v_set_thinkings boolean;
  v_skipped text[] := '{}';
begin
  if auth.uid() is not null and not (select public.is_superadmin()) then
    raise exception 'textbook_review_forbidden';
  end if;
  if p_source not in ('ai', 'owner') then
    raise exception 'textbook_review_bad_source';
  end if;
  if p_concept_proposals is not null and jsonb_typeof(p_concept_proposals) <> 'array' then
    raise exception 'textbook_review_bad_patch';
  end if;
  select * into v_crop from public.textbook_problem_crops where id = p_crop_id;
  if not found then
    raise exception 'textbook_review_crop_not_found';
  end if;

  insert into public.textbook_problem_analyses (crop_id, academy_id)
  values (v_crop.id, v_crop.academy_id)
  on conflict (crop_id) do nothing;
  select coalesce(meta_sources, '{}'::jsonb) into v_src
    from public.textbook_problem_analyses where crop_id = p_crop_id for update;

  v_set_concepts := p_concept_ids is not null or p_concept_proposals is not null;
  v_set_thinkings := p_thinking_ids is not null;
  if p_source = 'ai' and v_set_concepts and v_src ->> 'concepts' = 'owner' then
    v_set_concepts := false;
    v_skipped := array_append(v_skipped, 'concepts');
  end if;
  if p_source = 'ai' and v_set_thinkings and v_src ->> 'thinkings' = 'owner' then
    v_set_thinkings := false;
    v_skipped := array_append(v_skipped, 'thinkings');
  end if;

  update public.textbook_problem_analyses a
     set concept_ids = case when v_set_concepts
           then array(
             select distinct x from unnest(coalesce(p_concept_ids, '{}'::uuid[])) as u(x)
              where exists (select 1 from public.concepts c where c.id = u.x))
           else a.concept_ids end,
         concept_proposals = case when v_set_concepts then coalesce(p_concept_proposals, '[]'::jsonb) else a.concept_proposals end,
         thinking_ids = case when v_set_thinkings
           then array(
             select distinct x from unnest(p_thinking_ids) as u(x)
              where exists (select 1 from public.thinking_primitives t where t.id = u.x))
           else a.thinking_ids end,
         meta_sources = case when p_source = 'owner'
           then v_src
             || case when v_set_concepts then '{"concepts": "owner"}'::jsonb else '{}'::jsonb end
             || case when v_set_thinkings then '{"thinkings": "owner"}'::jsonb else '{}'::jsonb end
           else v_src end,
         visual_tags = case
           when p_visual_tags is null then a.visual_tags
           when p_source = 'ai' and coalesce(cardinality(a.visual_tags), 0) > 0 then a.visual_tags
           else array(select distinct btrim(x) from unnest(p_visual_tags) as u(x) where btrim(x) <> '')
         end,
         meta_checked_at = case
           when p_concept_ids is not null or p_concept_proposals is not null or p_thinking_ids is not null then now()
           else a.meta_checked_at end,
         updated_at = now()
   where a.crop_id = p_crop_id;

  perform public.textbook_problem_recalc_scores(p_crop_id);

  return jsonb_build_object('ok', true, 'crop_id', p_crop_id, 'skipped_owner', to_jsonb(v_skipped));
end;
$$;

revoke all on function public.textbook_review_set_meta(uuid, uuid[], uuid[], jsonb, text[], text) from public, anon;
grant execute on function public.textbook_review_set_meta(uuid, uuid[], uuid[], jsonb, text[], text) to authenticated;

-- ── 5) 작업 화면: 메타 제안 ─────────────────────────────────────────────
create or replace function public.textbook_review_unit_overview(
  p_academy_id uuid,
  p_book_id uuid,
  p_grade_label text,
  p_big_order int,
  p_mid_order int
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v jsonb;
begin
  v := public.textbook_review_unit_overview_base(p_academy_id, p_book_id, p_grade_label, p_big_order, p_mid_order);
  return (v - 'items') || jsonb_build_object('items', coalesce((
    select jsonb_agg(
             public.textbook_review_overlay_staged(e.item, an.staged_changes)
               || jsonb_build_object(
                    'concept_proposals', coalesce(an.concept_proposals, '[]'::jsonb),
                    'meta_checked_at', an.meta_checked_at,
                    'meta_sources', coalesce(an.meta_sources, '{}'::jsonb)
                  )
             order by e.ord)
      from jsonb_array_elements(coalesce(v -> 'items', '[]'::jsonb)) with ordinality as e(item, ord)
      left join public.textbook_problem_analyses an
        on an.crop_id = (e.item ->> 'crop_id')::uuid
  ), '[]'::jsonb));
end;
$$;

revoke all on function public.textbook_review_unit_overview(uuid, uuid, text, int, int) from public, anon;
grant execute on function public.textbook_review_unit_overview(uuid, uuid, text, int, int) to authenticated;

-- ── 6) 확정: 반영 대기 값 + 새 개념 + 메타 ──────────────────────────────
create or replace function public.textbook_review_apply_staged(p_crop_ids uuid[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row record;
  v_st jsonb;
  v_applied int := 0;
  v_math int := 0;
  v_quality int := 0;
  v_held text;
  v_notes text;
  v_meta_missing text;
  v_checked jsonb;
  v_prop jsonb;
  v_name text;
  v_cid uuid;
  v_cat uuid;
  v_type public.concept_types;
  v_family uuid;
  v_label text;
  v_n int;
  v_new_ids uuid[];
  v_created jsonb := '{}'::jsonb;
  v_new_concepts int := 0;
  v_meta int := 0;
begin
  if not (select public.is_superadmin()) then
    raise exception 'textbook_review_forbidden';
  end if;
  if p_crop_ids is null or cardinality(p_crop_ids) = 0 then
    return jsonb_build_object('ok', true, 'applied', 0);
  end if;

  select string_agg(c.problem_number, ', ' order by c.raw_page, c.problem_number)
    into v_held
    from public.textbook_problem_analyses an
    join public.textbook_problem_crops c on c.id = an.crop_id
   where an.crop_id = any (p_crop_ids)
     and an.quality_status = 'held';
  if v_held is not null then
    raise exception 'textbook_review_engine_held: %', v_held;
  end if;

  select string_agg(distinct c.problem_number, ', ')
    into v_notes
    from public.textbook_review_findings f
    join public.textbook_problem_crops c on c.id = f.crop_id
   where f.crop_id = any (p_crop_ids)
     and f.proposal ->> 'target' = 'correction_note'
     and f.status in ('open', 'held');
  if v_notes is not null then
    raise exception 'textbook_review_correction_note_open: %', v_notes;
  end if;

  select string_agg(c.problem_number, ', ' order by c.raw_page, c.problem_number)
    into v_meta_missing
    from public.textbook_problem_crops c
    left join public.textbook_problem_analyses an on an.crop_id = c.id
   where c.id = any (p_crop_ids)
     and not coalesce(c.is_set_header, false)
     and public.textbook_review_linked_pb_question(c.id) is not null
     and (
       an.meta_checked_at is null
       or (coalesce(cardinality(an.concept_ids), 0) = 0
           and jsonb_array_length(coalesce(an.concept_proposals, '[]'::jsonb)) = 0)
       or coalesce(cardinality(an.thinking_ids), 0) = 0
       or coalesce(cardinality(an.visual_tags), 0) = 0
     );
  if v_meta_missing is not null then
    raise exception 'textbook_review_meta_missing: %', v_meta_missing;
  end if;

  select coalesce(jsonb_object_agg(an.crop_id::text, an.render_checked_at), '{}'::jsonb)
    into v_checked
    from public.textbook_problem_analyses an
   where an.crop_id = any (p_crop_ids);

  for v_row in
    select an.crop_id, an.staged_changes
      from public.textbook_problem_analyses an
     where an.crop_id = any (p_crop_ids)
       and coalesce(an.staged_changes, '{}'::jsonb) - 'sources' - 'notes' - 'staged_at' <> '{}'::jsonb
  loop
    v_st := v_row.staged_changes;
    if v_st ?| array['stem', 'common_stem', 'choices', 'figure_layout', 'figure_assets'] then
      perform public.textbook_review_apply_problem_fix(
        v_row.crop_id,
        v_st ->> 'stem',
        v_st -> 'choices',
        true,
        '소단원 확정 일괄 반영',
        v_st ->> 'common_stem',
        v_st -> 'figure_layout',
        v_st -> 'figure_assets'
      );
    end if;
    if v_st ? 'question_kind' then
      perform public.textbook_review_set_question_kind(
        v_row.crop_id,
        v_st ->> 'question_kind',
        (v_st ->> 'allow_subjective')::boolean
      );
    end if;
    if v_st ?| array['answer', 'solution_transcribed', 'solution_answer'] then
      perform public.textbook_review_save_item_edit(
        v_row.crop_id,
        v_st ->> 'answer',
        null,
        null,
        true,
        true,
        v_st ->> 'solution_transcribed',
        v_st ->> 'solution_answer',
        null,
        true,
        null,
        coalesce(v_st -> 'sources' ->> 'answer', '') = 'owner'
      );
    end if;
    update public.textbook_problem_analyses
       set staged_changes = '{}'::jsonb,
           updated_at = now()
     where crop_id = v_row.crop_id;
    v_applied := v_applied + 1;
  end loop;

  select coalesce((public.textbook_review_approve_axis(p_crop_ids, 'math') ->> 'approved')::int, 0) into v_math;
  select coalesce((public.textbook_review_approve_axis(p_crop_ids, 'quality') ->> 'approved')::int, 0) into v_quality;

  update public.textbook_problem_analyses an
     set render_checked_at = (v_checked ->> an.crop_id::text)::timestamptz
   where an.crop_id = any (p_crop_ids)
     and v_checked ? an.crop_id::text;

  -- 새 개념: 소단원 확정을 승인으로 본다(사양 7-1). 폴더는 AI가 고른 가장 가까운 기존 개념(near_concept_id)의 폴더다.
  -- 이름이 같다고 같은 개념으로 보지 않는다. 같은 학년 교재 검수에서 이미 만든 같은 이름 개념만 다시 쓰고,
  -- 그 밖에는 같은 이름 계열의 새 판(기본-n)으로 만든다.
  for v_row in
    select an.crop_id, an.concept_proposals, c.book_id, c.grade_label, c.big_name, c.mid_name, c.problem_number
      from public.textbook_problem_analyses an
      join public.textbook_problem_crops c on c.id = an.crop_id
     where an.crop_id = any (p_crop_ids)
       and jsonb_array_length(coalesce(an.concept_proposals, '[]'::jsonb)) > 0
  loop
    v_new_ids := '{}'::uuid[];
    for v_prop in select e.value from jsonb_array_elements(v_row.concept_proposals) as e(value) loop
      v_name := btrim(coalesce(v_prop ->> 'name', ''));
      continue when v_name = '';
      v_cid := public.course_think_uuid(v_created ->> v_name);
      if v_cid is null then
        select c.id into v_cid
          from public.concepts c
         where btrim(c.name) = v_name
           and c.origin = 'textbook_review'
           and c.origin_detail ->> 'grade_label' = v_row.grade_label
         order by c.created_at nulls last
         limit 1;
      end if;
      if v_cid is null then
        select c.main_category_id into v_cat
          from public.concepts c
         where c.id = public.course_think_uuid(v_prop ->> 'near_concept_id');
        if v_cat is null then
          raise exception 'textbook_review_new_concept_no_folder: % (%)', v_name, v_row.problem_number;
        end if;
        select * into v_type from public.concept_types t
         where lower(btrim(t.name)) = lower(btrim(coalesce(v_prop ->> 'type', '')));
        if not found then
          select * into v_type from public.concept_types t where t.name = '성질';
        end if;
        insert into public.concept_families (canonical_name) values (v_name) on conflict (canonical_name) do nothing;
        select id into v_family from public.concept_families where canonical_name = v_name;
        v_label := '기본';
        v_n := 1;
        while exists (select 1 from public.concepts where family_id = v_family and version_label = v_label) loop
          v_n := v_n + 1;
          v_label := '기본-' || v_n;
        end loop;
        insert into public.concepts (
          kind, sub_type, name, content, level, main_category_id, sort_order, family_id, version_label,
          origin, origin_detail
        ) values (
          case when v_type.legacy_sub_type = '정의' then 'definition' else 'theorem' end,
          v_type.legacy_sub_type,
          v_name,
          coalesce(nullif(btrim(v_prop ->> 'content'), ''), v_name),
          1,
          v_cat,
          coalesce((select max(sort_order) + 1 from public.concepts where main_category_id = v_cat), 0),
          v_family,
          v_label,
          'textbook_review',
          jsonb_build_object(
            'book_id', v_row.book_id,
            'grade_label', v_row.grade_label,
            'big_name', v_row.big_name,
            'mid_name', v_row.mid_name,
            'crop_id', v_row.crop_id,
            'problem_number', v_row.problem_number,
            'near_concept_id', v_prop ->> 'near_concept_id',
            'reason', coalesce(v_prop ->> 'reason', ''),
            'confirmed_by', auth.uid(),
            'confirmed_at', now()
          )
        )
        returning id into v_cid;
        insert into public.concept_type_links (concept_id, type_id, created_by) values (v_cid, v_type.id, auth.uid());
        v_new_concepts := v_new_concepts + 1;
      end if;
      v_created := v_created || jsonb_build_object(v_name, v_cid);
      v_new_ids := array_append(v_new_ids, v_cid);
    end loop;
    update public.textbook_problem_analyses
       set concept_ids = array(
             select distinct x from unnest(coalesce(concept_ids, '{}'::uuid[]) || v_new_ids) as u(x)),
           concept_proposals = '[]'::jsonb,
           updated_at = now()
     where crop_id = v_row.crop_id;
  end loop;

  -- 메타를 문제은행 문항 쪽에 반영한다.
  for v_row in
    select c.id as crop_id, c.academy_id, coalesce(c.label, '') as label,
           public.textbook_review_linked_pb_question(c.id) as question_id
      from public.textbook_problem_crops c
     where c.id = any (p_crop_ids)
       and not coalesce(c.is_set_header, false)
  loop
    continue when v_row.question_id is null;
    perform public.textbook_problem_recalc_scores(v_row.crop_id);
    insert into public.pb_question_meta (
      question_id, academy_id, concept_ids, thinking_ids, arithmetic_counts,
      concept_score, thinking_score, arithmetic_score, total_difficulty,
      visual_tags, source_label, source_crop_id, confirmed_at, confirmed_by, updated_at
    )
    select v_row.question_id, v_row.academy_id,
           coalesce(an.concept_ids, '{}'::uuid[]), coalesce(an.thinking_ids, '{}'::uuid[]),
           coalesce(an.arithmetic_counts, '{}'::jsonb),
           an.concept_score, an.thinking_score, an.arithmetic_score, an.total_difficulty,
           coalesce(an.visual_tags, '{}'::text[]), v_row.label, v_row.crop_id, now(), auth.uid(), now()
      from public.textbook_problem_analyses an
     where an.crop_id = v_row.crop_id
    on conflict (question_id) do update
      set academy_id = excluded.academy_id,
          concept_ids = excluded.concept_ids,
          thinking_ids = excluded.thinking_ids,
          arithmetic_counts = excluded.arithmetic_counts,
          concept_score = excluded.concept_score,
          thinking_score = excluded.thinking_score,
          arithmetic_score = excluded.arithmetic_score,
          total_difficulty = excluded.total_difficulty,
          visual_tags = excluded.visual_tags,
          source_label = excluded.source_label,
          source_crop_id = excluded.source_crop_id,
          confirmed_at = excluded.confirmed_at,
          confirmed_by = excluded.confirmed_by,
          updated_at = now();
    if found then
      v_meta := v_meta + 1;
    end if;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'applied', v_applied,
    'math_approved', v_math,
    'quality_approved', v_quality,
    'new_concepts', v_new_concepts,
    'meta_applied', v_meta
  );
end;
$$;

revoke all on function public.textbook_review_apply_staged(uuid[]) from public, anon;
grant execute on function public.textbook_review_apply_staged(uuid[]) to authenticated;

notify pgrst, 'reload schema';
