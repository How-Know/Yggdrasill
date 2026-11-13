-- 교재 검수 사양 6 (데이터 위치): 확정한 해설(원본 해설 전사·해설 정답)과 해설 그림을 문제은행 문항 쪽에 둔다.
-- PDF 해설 섹션과 정답·해설 카드는 이 표만 읽는다. textbook_problem_analyses 는 검수 작업 기록으로 남는다.
-- 저장 단위는 문항 × 해설 종류 × 버전이다(2026-10-14 결정). 지금은 원본(original) 1판만 쓴다.
-- 학생 공개는 따로 정하기 전까지 없다: 학원 직원(memberships)만 읽는다.

-- ── 1) 문제은행 쪽 해설 ─────────────────────────────────────────────────
create table if not exists public.pb_question_solutions (
  question_id uuid not null references public.pb_questions(id) on delete cascade,
  kind text not null default 'original' check (kind in ('original')),
  version int not null default 1 check (version >= 1),
  academy_id uuid not null references public.academies(id) on delete cascade,
  body text not null default '',
  answer text not null default '',
  figure_assets jsonb not null default '[]'::jsonb check (jsonb_typeof(figure_assets) = 'array'),
  source_crop_id uuid references public.textbook_problem_crops(id) on delete set null,
  confirmed_at timestamptz not null default now(),
  confirmed_by uuid default auth.uid() references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key (question_id, kind, version)
);

create index if not exists pb_question_solutions_academy_idx on public.pb_question_solutions (academy_id);
create index if not exists pb_question_solutions_source_crop_idx on public.pb_question_solutions (source_crop_id);

alter table public.pb_question_solutions enable row level security;

drop policy if exists pb_question_solutions_select on public.pb_question_solutions;
create policy pb_question_solutions_select on public.pb_question_solutions
  for select to authenticated
  using (exists (
    select 1 from public.memberships m
     where m.user_id = auth.uid() and m.academy_id = pb_question_solutions.academy_id
  ));

revoke all on public.pb_question_solutions from anon;
revoke insert, update, delete, truncate on public.pb_question_solutions from authenticated;
grant select on public.pb_question_solutions to authenticated;

-- ── 2) 확정한 해설을 문제은행 문항 쪽에 쓴다(내부용) ─────────────────────
-- 원본 해설 전사·해설 정답·해설 그림이 모두 비면 그 문항의 원본 해설을 지운다.
create or replace function public.textbook_review_publish_solutions(p_crop_ids uuid[])
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row record;
  v_n int := 0;
begin
  for v_row in
    select c.id as crop_id, c.academy_id,
           public.textbook_review_linked_pb_question(c.id) as question_id,
           btrim(coalesce(an.solution_transcribed, '')) as body,
           btrim(coalesce(an.solution_answer, '')) as answer,
           case when jsonb_typeof(an.solution_figure_assets) = 'array'
                then an.solution_figure_assets else '[]'::jsonb end as figures
      from public.textbook_problem_crops c
      join public.textbook_problem_analyses an on an.crop_id = c.id
     where c.id = any (p_crop_ids)
       and not coalesce(c.is_set_header, false)
  loop
    continue when v_row.question_id is null;
    if v_row.body = '' and v_row.answer = '' and jsonb_array_length(v_row.figures) = 0 then
      delete from public.pb_question_solutions
       where question_id = v_row.question_id and kind = 'original';
      continue;
    end if;
    insert into public.pb_question_solutions (
      question_id, kind, version, academy_id, body, answer, figure_assets,
      source_crop_id, confirmed_at, confirmed_by, updated_at
    ) values (
      v_row.question_id, 'original', 1, v_row.academy_id, v_row.body, v_row.answer, v_row.figures,
      v_row.crop_id, now(), auth.uid(), now()
    )
    on conflict (question_id, kind, version) do update
      set academy_id = excluded.academy_id,
          body = excluded.body,
          answer = excluded.answer,
          figure_assets = excluded.figure_assets,
          source_crop_id = excluded.source_crop_id,
          confirmed_at = excluded.confirmed_at,
          confirmed_by = excluded.confirmed_by,
          updated_at = now();
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

revoke all on function public.textbook_review_publish_solutions(uuid[]) from public, anon, authenticated;

-- ── 3) 확정: 반영 대기 값 + 새 개념 + 메타 + 해설 ────────────────────────
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
  v_solutions int := 0;
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

  v_solutions := public.textbook_review_publish_solutions(p_crop_ids);

  return jsonb_build_object(
    'ok', true,
    'applied', v_applied,
    'math_approved', v_math,
    'quality_approved', v_quality,
    'new_concepts', v_new_concepts,
    'meta_applied', v_meta,
    'solutions_applied', v_solutions
  );
end;
$$;

revoke all on function public.textbook_review_apply_staged(uuid[]) from public, anon;
grant execute on function public.textbook_review_apply_staged(uuid[]) to authenticated;

-- ── 4) 이미 처리한(정답·품질 승인) 문항의 해설과 메타를 옮긴다(사양 6-3, AI 비용 없음) ──
-- 메타는 점수를 다시 계산하지 않고 지금 값을 그대로 옮긴다. 확정 때 만든 행은 건드리지 않는다.
-- confirmed_by 가 비어 있는 행이 옮겨 온 행이다.
select public.textbook_review_publish_solutions(coalesce(array(
  select an.crop_id
    from public.textbook_problem_analyses an
   where an.math_status = 'approved'
     and an.quality_status = 'approved'
), '{}'::uuid[]));

insert into public.pb_question_meta (
  question_id, academy_id, concept_ids, thinking_ids, arithmetic_counts,
  concept_score, thinking_score, arithmetic_score, total_difficulty,
  visual_tags, source_label, source_crop_id, confirmed_at, confirmed_by, updated_at
)
select distinct on (x.question_id)
       x.question_id, c.academy_id,
       coalesce(an.concept_ids, '{}'::uuid[]), coalesce(an.thinking_ids, '{}'::uuid[]),
       coalesce(an.arithmetic_counts, '{}'::jsonb),
       coalesce(an.concept_score, 0), coalesce(an.thinking_score, 0),
       coalesce(an.arithmetic_score, 0), coalesce(an.total_difficulty, 0),
       coalesce(an.visual_tags, '{}'::text[]), coalesce(c.label, ''), c.id, now(), null, now()
  from public.textbook_problem_analyses an
  join public.textbook_problem_crops c on c.id = an.crop_id
  cross join lateral (select public.textbook_review_linked_pb_question(c.id) as question_id) x
 where an.math_status = 'approved'
   and an.quality_status = 'approved'
   and an.analyzed_at is not null
   and not coalesce(c.is_set_header, false)
   and x.question_id is not null
 order by x.question_id, an.updated_at desc
on conflict (question_id) do nothing;

notify pgrst, 'reload schema';
