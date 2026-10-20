-- 20261014233500: 교재 문항 검수 기반 — 실행 기록·검수 항목·결정 이력·부분별 지문
--
-- 설계: docs/architecture/textbook-review.md
--
-- 표
--   textbook_review_runs       단계 실행 기록. 누가 언제 어느 범위를 돌렸고 결과가 무엇인지.
--   textbook_review_findings   문항별 검수 항목. 무엇이 문제인가(title·detail·evidence),
--                              어떻게 고칠까(proposal), 상태(open·held·resolved·dismissed).
--   textbook_review_decisions  사장님 결정 이력. 고치거나 지우지 않는다.
--
-- 버전 묶음
--   textbook_review_fingerprint(crop_id) 는 문항을 부분(crop·problem·answer·solution_ref)별 해시로 돌려준다.
--   검수 항목은 만들 때 본 부분의 해시(base_fingerprint)를 갖고, 결정은 화면에 보였던 지문(p_expected)을
--   함께 보낸다. 그사이 그 부분이 바뀌었으면 반영하지 않고 'textbook_review_stale' 로 실패한다.
--   부분별이라 정답이 바뀌면 정답에 걸린 항목만 다시 확인 대상이 된다(textbook_review_findings_live.stale_parts).
--   제안대로 반영은 더 엄격하다. 제안을 만든 뒤 그 부분이 바뀌었으면 다시 봐도 'textbook_review_proposal_stale' 로
--   실패하고, 사장님은 직접 고치기나 문제 없음으로 결정한다.
--
-- 반영
--   정답은 answer_source = 'manual', 해설 위치는 edited_at 을 채워 쓴다. 그래서 20261014233000 의
--   수동 보호가 이어지고, 정답이 바뀌면 채점 캐시·정답 그림이 무효가 된다.
--   교재 원본(PDF)은 바꾸지 않는다. 원본 오류는 교정 의견(target = 'correction_note')으로만 남긴다.
--
-- 접근
--   학원 직원(memberships)만 읽는다. 쓰기는 이 파일의 RPC(직원 확인)와 Edge Function(service role)만 한다.
--   학생 경로는 이 표를 읽지 않는다(tools/db_test/test/textbook_review.test.mjs 가 학생 쪽 소스를 검사한다).

-- ─────────────────────────────────────────────────────────────────────────
-- 1) 표
-- ─────────────────────────────────────────────────────────────────────────

create table if not exists public.textbook_review_runs (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  book_id uuid not null references public.resource_files(id) on delete cascade,
  grade_label text not null,
  big_order int not null,
  mid_order int not null,
  stage text not null
    check (stage in ('load', 'solution_text', 'solve', 'compare', 'render', 'concept', 'close')),
  status text not null default 'done'
    check (status in ('running', 'done', 'failed')),
  summary jsonb not null default '{}'::jsonb,
  ai_run_id uuid,                         -- ai_runs.id (AI 단계만)
  started_by uuid default auth.uid(),
  started_at timestamptz not null default now(),
  finished_at timestamptz
);

create index if not exists textbook_review_runs_scope_idx
  on public.textbook_review_runs (academy_id, book_id, grade_label, big_order, mid_order, stage, started_at desc);

create table if not exists public.textbook_review_findings (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  crop_id uuid not null references public.textbook_problem_crops(id) on delete cascade,
  run_id uuid references public.textbook_review_runs(id) on delete set null,
  stage text not null
    check (stage in ('load', 'solution_text', 'solve', 'compare', 'render', 'concept')),
  -- 원본 충실도 / 수학적 타당성 / 출력 품질. 한 축의 통과가 다른 축을 대신하지 않는다.
  axis text not null check (axis in ('fidelity', 'validity', 'output')),
  error_type text not null check (error_type in (
    'crop_image', 'missing_answer', 'missing_solution_ref', 'missing_question_link',
    'answer_mismatch', 'answer_link', 'solution_link', 'problem_transcription',
    'solution_transcription', 'answer_wrong', 'solution_logic', 'crop_leak',
    'missing_context', 'render_item', 'render_a4', 'undetermined', 'other')),
  severity text not null default 'warning' check (severity in ('blocker', 'warning', 'info')),
  source text not null check (source in ('system', 'ai', 'owner')),
  -- 시스템 검사가 같은 항목을 다시 만들지 않게 하는 키. AI·사람 항목은 비워 둔다.
  check_key text not null default '',
  title text not null,
  detail text not null default '',
  evidence jsonb not null default '{}'::jsonb,
  -- {"target": "answer" | "solution_ref" | "correction_note", "after": {...}, "reason": "...", "keeps": "..."}
  proposal jsonb,
  base_fingerprint jsonb not null default '{}'::jsonb,
  status text not null default 'open' check (status in ('open', 'held', 'resolved', 'dismissed')),
  resolution text check (resolution in ('applied', 'manual_edit', 'noted', 'dismissed', 'auto_cleared')),
  ai_run_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  resolved_at timestamptz,
  constraint textbook_review_findings_proposal_chk check (
    proposal is null
    or (jsonb_typeof(proposal) = 'object' and proposal ->> 'target' in ('answer', 'solution_ref', 'correction_note'))
  )
);

create unique index if not exists textbook_review_findings_active_check_uk
  on public.textbook_review_findings (crop_id, check_key)
  where check_key <> '' and status in ('open', 'held');

create index if not exists textbook_review_findings_crop_idx
  on public.textbook_review_findings (academy_id, crop_id, status);

drop trigger if exists trg_textbook_review_findings_updated_at on public.textbook_review_findings;
create trigger trg_textbook_review_findings_updated_at
  before update on public.textbook_review_findings
  for each row execute function public.set_updated_at();

create table if not exists public.textbook_review_decisions (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  crop_id uuid not null references public.textbook_problem_crops(id) on delete cascade,
  finding_id uuid references public.textbook_review_findings(id) on delete set null,
  action text not null
    check (action in ('apply_proposal', 'manual_edit', 'dismiss', 'hold', 'reopen', 'release_manual')),
  target text check (target in ('answer', 'solution_ref', 'correction_note')),
  before_value jsonb,
  after_value jsonb,
  note text not null default '',
  fingerprint_seen jsonb not null default '{}'::jsonb,
  fingerprint_after jsonb,
  decided_by uuid default auth.uid(),
  decided_at timestamptz not null default now()
);

create index if not exists textbook_review_decisions_crop_idx
  on public.textbook_review_decisions (crop_id, decided_at desc);

comment on table public.textbook_review_runs is
  '교재 검수 단계 실행 기록. 범위(교재·학년·대단원·중단원)와 단계별 결과 요약.';
comment on table public.textbook_review_findings is
  '교재 검수 항목. 무엇이 문제인가와 어떻게 고칠까(proposal). 직원만 읽고 RPC·service role 만 쓴다.';
comment on table public.textbook_review_decisions is
  '교재 검수 결정 이력(반영·직접 수정·문제 없음·보류·보호 해제). 고치거나 지우지 않는다.';

-- ─────────────────────────────────────────────────────────────────────────
-- 2) 부분별 지문과 보조 함수
-- ─────────────────────────────────────────────────────────────────────────

-- 호출한 사람 권한으로 읽는다(직원 RLS). 검수 RPC 안에서는 소유자 권한으로 읽힌다.
create or replace function public.textbook_review_fingerprint(p_crop_id uuid)
returns jsonb
language sql
stable
set search_path = public
as $$
  with c as (
    select * from public.textbook_problem_crops where id = p_crop_id
  ),
  q as (
    select pq.*
      from c
      join public.pb_questions pq
        on pq.id = coalesce(
          (select l.pb_question_id from public.textbook_crop_question_links l where l.crop_id = c.id),
          (select q2.id from public.pb_questions q2
            where c.pb_question_uid is not null
              and q2.academy_id = c.academy_id
              and q2.question_uid = c.pb_question_uid)
        )
  )
  select jsonb_build_object(
    'crop', (
      select md5(jsonb_build_array(c.raw_page, c.item_region_1k, c.problem_number, c.storage_key, c.content_hash)::text)
        from c
    ),
    'problem', (
      select md5(jsonb_build_array(
        q.id, q.question_type, q.stem, q.choices, q.objective_choices, q.figure_refs, q.equations,
        q.meta -> 'set_model' -> 'common_stem'
      )::text)
        from q
    ),
    'answer', (
      select md5(jsonb_build_array(
        a.answer_kind, a.answer_text, a.answer_latex_2d, a.answer_image_path, a.answer_image_content_hash
      )::text)
        from public.textbook_problem_answers a
       where a.crop_id = p_crop_id
    ),
    'solution_ref', (
      select md5(jsonb_build_array(s.source_kind, s.raw_page, s.number_region_1k, s.content_region_1k)::text)
        from public.textbook_problem_solution_refs s
       where s.crop_id = p_crop_id
    )
  )
$$;

comment on function public.textbook_review_fingerprint(uuid) is
  '문항 부분(crop·problem·answer·solution_ref)별 md5. 출처(vlm/manual)는 넣지 않는다.';

-- 표기만 다른 정답을 같은 값으로 본다(공백·$·\,·\left·\right·원문자).
create or replace function public.textbook_review_norm_answer(p text)
returns text
language sql
immutable
as $$
  select translate(
    replace(
      regexp_replace(
        lower(regexp_replace(coalesce(p, ''), '\s+|\$|\\[,;:! ]|\\left|\\right', '', 'g')),
        '\\[dt]frac', '\\frac', 'g'
      ),
      '⑩', '10'
    ),
    '①②③④⑤⑥⑦⑧⑨', '123456789'
  )
$$;

create or replace function public.textbook_review_region(p jsonb)
returns int[]
language sql
immutable
as $$
  select case
    when jsonb_typeof(p) = 'array'
     and jsonb_array_length(p) = 4
     and (select bool_and(jsonb_typeof(e) = 'number' and (e #>> '{}')::numeric between 0 and 1000)
            from jsonb_array_elements(p) e)
    then (select array_agg(round((e #>> '{}')::numeric)::int order by o)
            from jsonb_array_elements(p) with ordinality as t(e, o))
  end
$$;

create or replace function public.textbook_review_assert_staff(p_academy_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not exists (
    select 1 from public.memberships m
     where m.academy_id = p_academy_id
       and m.user_id = auth.uid()
  ) then
    raise exception 'textbook_review_forbidden';
  end if;
end;
$$;

-- 화면에 보였던 지문이 지금과 같은지. p_required 는 반드시 보내야 하는 부분.
create or replace function public.textbook_review_check_expected(
  p_required text[],
  p_expected jsonb,
  p_now jsonb
)
returns void
language plpgsql
immutable
as $$
declare
  v_key text;
  v_changed text[] := '{}';
begin
  if p_expected is null or jsonb_typeof(p_expected) <> 'object' then
    raise exception 'textbook_review_expected_required';
  end if;
  foreach v_key in array coalesce(p_required, '{}'::text[]) loop
    if not (p_expected ? v_key) then
      raise exception 'textbook_review_expected_required';
    end if;
  end loop;
  for v_key in select jsonb_object_keys(p_expected) loop
    if (p_expected -> v_key) is distinct from (p_now -> v_key) then
      v_changed := v_changed || v_key;
    end if;
  end loop;
  if cardinality(v_changed) > 0 then
    raise exception 'textbook_review_stale'
      using detail = array_to_string(v_changed, ',');
  end if;
end;
$$;

-- 수정 하나를 반영하고 {target, before, after} 를 돌려준다. 사람이 고친 값으로 쓴다.
create or replace function public.textbook_review_apply_change(
  p_crop_id uuid,
  p_academy_id uuid,
  p_change jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_target text := p_change ->> 'target';
  v_after jsonb := coalesce(p_change -> 'after', '{}'::jsonb);
  v_before jsonb;
  v_kind text;
  v_text text;
  v_latex text;
  v_source_kind text;
  v_raw_page int;
  v_display_page int;
  v_number int[];
  v_content int[];
begin
  if v_target = 'answer' then
    select jsonb_build_object(
             'answer_kind', a.answer_kind,
             'answer_text', a.answer_text,
             'answer_latex_2d', a.answer_latex_2d,
             'answer_source', a.answer_source)
      into v_before
      from public.textbook_problem_answers a
     where a.crop_id = p_crop_id;
    v_kind := coalesce(nullif(v_after ->> 'answer_kind', ''), v_before ->> 'answer_kind', 'subjective');
    v_text := nullif(btrim(coalesce(v_after ->> 'answer_text', '')), '');
    if v_kind not in ('objective', 'subjective') or v_text is null then
      raise exception 'textbook_review_bad_value';
    end if;
    v_latex := coalesce(nullif(btrim(coalesce(v_after ->> 'answer_latex_2d', '')), ''), v_text);

    insert into public.textbook_problem_answers (
      crop_id, academy_id, answer_kind, answer_text, answer_latex_2d, answer_source, edited_at
    ) values (
      p_crop_id, p_academy_id, v_kind, v_text, v_latex, 'manual', now()
    )
    on conflict (crop_id) do update
      set answer_kind = excluded.answer_kind,
          answer_text = excluded.answer_text,
          answer_latex_2d = excluded.answer_latex_2d,
          answer_source = 'manual',
          answer_image_bucket = '',
          answer_image_path = '',
          edited_at = now();

    return jsonb_build_object(
      'target', v_target,
      'before', v_before,
      'after', jsonb_build_object(
        'answer_kind', v_kind, 'answer_text', v_text, 'answer_latex_2d', v_latex, 'answer_source', 'manual'));

  elsif v_target = 'solution_ref' then
    select jsonb_build_object(
             'source_kind', s.source_kind,
             'raw_page', s.raw_page,
             'number_region_1k', s.number_region_1k,
             'content_region_1k', s.content_region_1k,
             'manual', s.edited_at is not null)
      into v_before
      from public.textbook_problem_solution_refs s
     where s.crop_id = p_crop_id;
    v_source_kind := coalesce(nullif(v_after ->> 'source_kind', ''), 'sol');
    if v_source_kind not in ('sol', 'body', 'none') then
      raise exception 'textbook_review_bad_value';
    end if;
    if v_source_kind = 'none' then
      -- 게이트웨이와 같은 센티널: 소비자는 'none' 을 먼저 보고 좌표를 쓰지 않는다.
      v_raw_page := 0;
      v_display_page := null;
      v_number := array[0, 0, 0, 0];
      v_content := null;
    else
      v_raw_page := case when (v_after ->> 'raw_page') ~ '^[0-9]+$' then (v_after ->> 'raw_page')::int end;
      v_display_page := case when (v_after ->> 'display_page') ~ '^[0-9]+$' then (v_after ->> 'display_page')::int end;
      v_number := public.textbook_review_region(v_after -> 'number_region_1k');
      v_content := public.textbook_review_region(v_after -> 'content_region_1k');
      if v_raw_page is null or v_raw_page <= 0 or v_number is null then
        raise exception 'textbook_review_bad_value';
      end if;
    end if;

    insert into public.textbook_problem_solution_refs (
      crop_id, academy_id, raw_page, display_page, number_region_1k, content_region_1k, source_kind, edited_at
    ) values (
      p_crop_id, p_academy_id, v_raw_page, v_display_page, v_number, v_content, v_source_kind, now()
    )
    on conflict (crop_id) do update
      set raw_page = excluded.raw_page,
          display_page = excluded.display_page,
          number_region_1k = excluded.number_region_1k,
          content_region_1k = excluded.content_region_1k,
          source_kind = excluded.source_kind,
          edited_at = now();

    return jsonb_build_object(
      'target', v_target,
      'before', v_before,
      'after', jsonb_build_object(
        'source_kind', v_source_kind, 'raw_page', v_raw_page,
        'number_region_1k', to_jsonb(v_number), 'content_region_1k', to_jsonb(v_content), 'manual', true));

  elsif v_target = 'correction_note' then
    v_text := nullif(btrim(coalesce(v_after ->> 'text', '')), '');
    if v_text is null then
      raise exception 'textbook_review_bad_value';
    end if;
    return jsonb_build_object(
      'target', v_target,
      'before', null,
      'after', jsonb_build_object('text', v_text, 'about', coalesce(nullif(v_after ->> 'about', ''), 'solution')));
  end if;

  raise exception 'textbook_review_bad_target';
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 3) 지금 상태: 항목마다 그사이 바뀐 부분
-- ─────────────────────────────────────────────────────────────────────────

create or replace view public.textbook_review_findings_live
with (security_invoker = true) as
select
  f.*,
  coalesce((
    select array_agg(b.key order by b.key)
      from jsonb_each(f.base_fingerprint) b
     where (cur.fp -> b.key) is distinct from b.value
  ), '{}'::text[]) as stale_parts
from public.textbook_review_findings f
cross join lateral (select public.textbook_review_fingerprint(f.crop_id) as fp) cur;

comment on view public.textbook_review_findings_live is
  '검수 항목 + stale_parts(항목을 만든 뒤 바뀐 부분). 열린 항목에 값이 있으면 화면은 다시 확인을 받는다.';

-- ─────────────────────────────────────────────────────────────────────────
-- 4) 0단계 적재 확인: 정답·해설 위치·문제은행 연결·두 정답 대조·이미지 경로 충돌
-- ─────────────────────────────────────────────────────────────────────────

create or replace function public.textbook_review_refresh_load_checks(
  p_academy_id uuid,
  p_book_id uuid,
  p_grade_label text,
  p_big_order int,
  p_mid_order int
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_run uuid;
  v_items int;
  v_opened int := 0;
  v_updated int := 0;
  v_kept_dismissed int := 0;
  v_cleared int := 0;
  v_open_total int;
  v_seen text[] := '{}';
  v_fp jsonb;
  v_base jsonb;
  v_id uuid;
  v_summary jsonb;
  r record;
begin
  perform public.textbook_review_assert_staff(p_academy_id);

  insert into public.textbook_review_runs (academy_id, book_id, grade_label, big_order, mid_order, stage, status)
  values (p_academy_id, p_book_id, p_grade_label, p_big_order, p_mid_order, 'load', 'running')
  returning id into v_run;

  select count(*)::int into v_items
    from public.textbook_problem_crops c
   where c.academy_id = p_academy_id and c.book_id = p_book_id and c.grade_label = p_grade_label
     and c.big_order = p_big_order and c.mid_order = p_mid_order and not c.is_set_header;

  for r in
    with scope as (
      select c.*
        from public.textbook_problem_crops c
       where c.academy_id = p_academy_id and c.book_id = p_book_id and c.grade_label = p_grade_label
         and c.big_order = p_big_order and c.mid_order = p_mid_order and not c.is_set_header
    ),
    linked as (
      select s.id as crop_id, pq.id as pb_id, pq.objective_answer_key, pq.subjective_answer
        from scope s
        left join public.textbook_crop_question_links l on l.crop_id = s.id
        left join public.pb_questions pq
          on pq.id = l.pb_question_id
          or (l.crop_id is null
              and s.pb_question_uid is not null
              and pq.academy_id = s.academy_id
              and pq.question_uid = s.pb_question_uid)
    ),
    answers as (
      select a.crop_id, a.answer_kind,
             coalesce(nullif(btrim(a.answer_text), ''), nullif(btrim(a.answer_latex_2d), '')) as shown,
             a.answer_image_path
        from public.textbook_problem_answers a
        join scope s on s.id = a.crop_id
    )
    select s.id as crop_id,
           'load:answer_missing' as check_key,
           'missing_answer' as error_type,
           'blocker' as severity,
           '채점 정답이 없음' as title,
           '정답 단계에서 이 문항의 정답이 저장되지 않았습니다. 학생 채점과 AI 대조를 할 수 없습니다.' as detail,
           '{}'::jsonb as evidence,
           array['answer'] as parts
      from scope s
      left join answers a on a.crop_id = s.id
     where a.crop_id is null
        or (a.answer_kind = 'image' and a.answer_image_path = '')
        or (a.answer_kind <> 'image' and a.shown is null)
    union all
    select s.id, 'load:solution_ref_missing', 'missing_solution_ref', 'warning',
           '해설 위치가 없음',
           '해설지에서 이 문항의 해설 위치를 찾지 못했습니다. 해설이 원래 없는 문항이면 "해설 없음"으로 표시하세요.',
           '{}'::jsonb,
           array['solution_ref']
      from scope s
      left join public.textbook_problem_solution_refs sr on sr.crop_id = s.id
     where sr.crop_id is null
    union all
    select l.crop_id, 'load:question_link_missing', 'missing_question_link', 'warning',
           '문제은행 문항과 연결되지 않음',
           '본문 추출이 이 문항을 아직 만들지 않았거나 연결이 끊겼습니다. AI 풀이에 줄 문항 본문이 없습니다.',
           '{}'::jsonb,
           array['problem']
      from linked l
     where l.pb_id is null
    union all
    select l.crop_id, 'load:answer_mismatch', 'answer_mismatch', 'warning',
           '문제은행 정답과 채점 정답이 다름',
           '학생 채점은 교재 정답 ' || a.shown || ' 을 씁니다. 문제은행 사본은 '
             || case when a.answer_kind = 'objective' then l.objective_answer_key else l.subjective_answer end
             || ' 입니다. 한쪽만 고쳐졌을 수 있습니다.',
           jsonb_build_object(
             'textbook_answer', a.shown,
             'problem_bank_answer',
             case when a.answer_kind = 'objective' then l.objective_answer_key else l.subjective_answer end),
           array['answer', 'problem']
      from linked l
      join answers a on a.crop_id = l.crop_id
     where l.pb_id is not null
       and a.answer_kind <> 'image'
       and public.textbook_review_norm_answer(a.shown) <> ''
       and public.textbook_review_norm_answer(
             case when a.answer_kind = 'objective' then l.objective_answer_key else l.subjective_answer end) <> ''
       and public.textbook_review_norm_answer(a.shown)
           <> public.textbook_review_norm_answer(
             case when a.answer_kind = 'objective' then l.objective_answer_key else l.subjective_answer end)
    union all
    -- 지금은 좌표만 저장하는 흐름이라 대부분 파일이 없다. 실제 파일이 있는 행끼리만 충돌로 본다.
    select s.id, 'load:storage_collision', 'crop_image', 'blocker',
           '다른 문항과 같은 이미지 파일을 씀',
           '같은 저장 경로를 쓰는 문항이 ' || o.n || '개 더 있습니다. 나중에 올린 이미지로 덮였을 수 있어 이 범위를 다시 잘라야 합니다.',
           jsonb_build_object('storage_key', s.storage_key, 'other_crop_ids', o.ids),
           array['crop']
      from scope s
      join lateral (
        select count(*)::int as n, jsonb_agg(c2.id order by c2.id) as ids
          from public.textbook_problem_crops c2
         where c2.academy_id = s.academy_id
           and c2.storage_bucket = s.storage_bucket
           and c2.storage_key = s.storage_key
           and c2.id <> s.id
           and coalesce(c2.file_size_bytes, 0) > 0
      ) o on o.n > 0
     where coalesce(s.file_size_bytes, 0) > 0
  loop
    v_fp := public.textbook_review_fingerprint(r.crop_id);
    select coalesce(jsonb_object_agg(k, v_fp -> k), '{}'::jsonb) into v_base from unnest(r.parts) as k;
    v_seen := v_seen || (r.crop_id::text || '|' || r.check_key);

    select f.id into v_id
      from public.textbook_review_findings f
     where f.crop_id = r.crop_id and f.check_key = r.check_key and f.status in ('open', 'held');
    if found then
      update public.textbook_review_findings
         set title = r.title, detail = r.detail, evidence = r.evidence, severity = r.severity,
             base_fingerprint = v_base, run_id = v_run
       where id = v_id;
      v_updated := v_updated + 1;
      continue;
    end if;

    -- 사장님이 "문제 없음"으로 닫은 항목은 그 부분이 바뀌기 전까지 다시 열지 않는다.
    if exists (
      select 1 from public.textbook_review_findings f
       where f.crop_id = r.crop_id and f.check_key = r.check_key
         and f.status = 'dismissed' and f.base_fingerprint = v_base
    ) then
      v_kept_dismissed := v_kept_dismissed + 1;
      continue;
    end if;

    insert into public.textbook_review_findings (
      academy_id, crop_id, run_id, stage, axis, error_type, severity, source,
      check_key, title, detail, evidence, base_fingerprint
    ) values (
      p_academy_id, r.crop_id, v_run, 'load', 'fidelity', r.error_type, r.severity, 'system',
      r.check_key, r.title, r.detail, r.evidence, v_base
    );
    v_opened := v_opened + 1;
  end loop;

  update public.textbook_review_findings f
     set status = 'resolved', resolution = 'auto_cleared', resolved_at = now(), run_id = v_run
   where f.academy_id = p_academy_id
     and f.source = 'system'
     and f.stage = 'load'
     and f.status in ('open', 'held')
     and f.crop_id in (
       select c.id from public.textbook_problem_crops c
        where c.academy_id = p_academy_id and c.book_id = p_book_id and c.grade_label = p_grade_label
          and c.big_order = p_big_order and c.mid_order = p_mid_order
     )
     and not ((f.crop_id::text || '|' || f.check_key) = any (v_seen));
  get diagnostics v_cleared = row_count;

  select count(*)::int into v_open_total
    from public.textbook_review_findings f
    join public.textbook_problem_crops c on c.id = f.crop_id
   where f.academy_id = p_academy_id and f.stage = 'load' and f.status = 'open'
     and c.book_id = p_book_id and c.grade_label = p_grade_label
     and c.big_order = p_big_order and c.mid_order = p_mid_order;

  v_summary := jsonb_build_object(
    'items', v_items,
    'opened', v_opened,
    'updated', v_updated,
    'cleared', v_cleared,
    'kept_dismissed', v_kept_dismissed,
    'open_total', v_open_total);

  update public.textbook_review_runs
     set status = 'done', summary = v_summary, finished_at = now()
   where id = v_run;

  return v_summary || jsonb_build_object('run_id', v_run);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 5) 결정: 제안대로 반영 / 직접 고치기 / 문제 없음 / 보류 / 다시 열기
-- ─────────────────────────────────────────────────────────────────────────

create or replace function public.textbook_review_decide(
  p_finding_id uuid,
  p_action text,
  p_expected jsonb,
  p_value jsonb default null,
  p_note text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  f public.textbook_review_findings;
  v_now jsonb;
  v_change jsonb;
  v_result jsonb := '{}'::jsonb;
  v_target text;
  v_required text[];
  v_status text;
  v_resolution text;
  v_base jsonb;
  v_after_fp jsonb;
begin
  select * into f from public.textbook_review_findings where id = p_finding_id for update;
  if not found then
    raise exception 'textbook_review_finding_not_found';
  end if;
  perform public.textbook_review_assert_staff(f.academy_id);

  if p_action not in ('apply_proposal', 'manual_edit', 'dismiss', 'hold', 'reopen') then
    raise exception 'textbook_review_bad_action';
  end if;
  if p_action = 'reopen' then
    if f.status not in ('held', 'dismissed') then
      raise exception 'textbook_review_bad_action';
    end if;
  elsif f.status not in ('open', 'held') then
    raise exception 'textbook_review_closed';
  end if;

  if p_action = 'apply_proposal' then
    if f.proposal is null then
      raise exception 'textbook_review_no_proposal';
    end if;
    v_change := f.proposal;
  elsif p_action = 'manual_edit' then
    v_change := p_value;
  end if;
  v_target := v_change ->> 'target';

  v_now := public.textbook_review_fingerprint(f.crop_id);
  if p_action <> 'reopen' then
    select array_agg(k) into v_required from jsonb_object_keys(f.base_fingerprint) k;
    if v_target in ('answer', 'solution_ref') then
      v_required := coalesce(v_required, '{}'::text[]) || v_target;
    end if;
    perform public.textbook_review_check_expected(v_required, p_expected, v_now);
  end if;

  -- 제안은 만들 때 본 값에 묶인다. 그 값이 바뀌었으면 사람이 본 뒤라도 그대로 반영하지 않는다(직접 고치기는 된다).
  if p_action = 'apply_proposal' then
    select array_agg(k order by k) into v_required
      from jsonb_object_keys(f.base_fingerprint) k
     where (f.base_fingerprint -> k) is distinct from (v_now -> k);
    if v_required is not null then
      raise exception 'textbook_review_proposal_stale'
        using detail = array_to_string(v_required, ',');
    end if;
  end if;

  if p_action in ('apply_proposal', 'manual_edit') then
    v_result := public.textbook_review_apply_change(f.crop_id, f.academy_id, v_change);
    v_status := 'resolved';
    v_resolution := case
      when v_target = 'correction_note' then 'noted'
      when p_action = 'apply_proposal' then 'applied'
      else 'manual_edit'
    end;
  elsif p_action = 'dismiss' then
    v_status := 'dismissed';
    v_resolution := 'dismissed';
  elsif p_action = 'hold' then
    v_status := 'held';
    v_resolution := null;
  else
    v_status := 'open';
    v_resolution := null;
  end if;

  v_after_fp := public.textbook_review_fingerprint(f.crop_id);

  -- 닫을 때 본 값으로 기준을 옮긴다. 다시 검사해도 같은 값이면 다시 열지 않는다.
  select coalesce(jsonb_object_agg(k, v_after_fp -> k), '{}'::jsonb)
    into v_base
    from jsonb_object_keys(f.base_fingerprint) k;

  update public.textbook_review_findings
     set status = v_status,
         resolution = v_resolution,
         resolved_at = case when v_status in ('resolved', 'dismissed') then now() end,
         base_fingerprint = case when p_action = 'dismiss' then v_base else base_fingerprint end
   where id = f.id;

  insert into public.textbook_review_decisions (
    academy_id, crop_id, finding_id, action, target, before_value, after_value, note,
    fingerprint_seen, fingerprint_after
  ) values (
    f.academy_id, f.crop_id, f.id, p_action, v_result ->> 'target', v_result -> 'before', v_result -> 'after',
    coalesce(p_note, ''), coalesce(p_expected, '{}'::jsonb), v_after_fp
  );

  return jsonb_build_object('ok', true, 'finding_id', f.id, 'status', v_status, 'fingerprint', v_after_fp);
end;
$$;

-- 검수 항목 없이 사장님이 직접 고칠 때.
create or replace function public.textbook_review_edit(
  p_crop_id uuid,
  p_expected jsonb,
  p_value jsonb,
  p_note text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_target text := p_value ->> 'target';
  v_result jsonb;
  v_after_fp jsonb;
begin
  select c.academy_id into v_academy from public.textbook_problem_crops c where c.id = p_crop_id;
  if v_academy is null then
    raise exception 'textbook_review_crop_not_found';
  end if;
  perform public.textbook_review_assert_staff(v_academy);

  perform public.textbook_review_check_expected(
    case when v_target in ('answer', 'solution_ref') then array[v_target] else '{}'::text[] end,
    p_expected,
    public.textbook_review_fingerprint(p_crop_id));

  v_result := public.textbook_review_apply_change(p_crop_id, v_academy, p_value);
  v_after_fp := public.textbook_review_fingerprint(p_crop_id);

  insert into public.textbook_review_decisions (
    academy_id, crop_id, finding_id, action, target, before_value, after_value, note,
    fingerprint_seen, fingerprint_after
  ) values (
    v_academy, p_crop_id, null, 'manual_edit', v_result ->> 'target', v_result -> 'before', v_result -> 'after',
    coalesce(p_note, ''), p_expected, v_after_fp
  );

  return jsonb_build_object('ok', true, 'fingerprint', v_after_fp);
end;
$$;

-- 사장님의 명시적 해제: 사람이 고친 값을 다시 기계 작업이 덮을 수 있게 한다. 값은 그대로 둔다.
create or replace function public.textbook_review_release_manual(
  p_crop_id uuid,
  p_target text,
  p_note text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_count int;
  v_fp jsonb;
begin
  select c.academy_id into v_academy from public.textbook_problem_crops c where c.id = p_crop_id;
  if v_academy is null then
    raise exception 'textbook_review_crop_not_found';
  end if;
  perform public.textbook_review_assert_staff(v_academy);
  if p_target not in ('answer', 'solution_ref') then
    raise exception 'textbook_review_bad_target';
  end if;

  perform set_config('yggdrasill.manual_override', 'on', true);
  if p_target = 'answer' then
    update public.textbook_problem_answers
       set answer_source = 'vlm', edited_at = null
     where crop_id = p_crop_id and answer_source = 'manual';
  else
    update public.textbook_problem_solution_refs
       set edited_at = null
     where crop_id = p_crop_id and edited_at is not null;
  end if;
  get diagnostics v_count = row_count;
  perform set_config('yggdrasill.manual_override', '', true);

  if v_count = 0 then
    return jsonb_build_object('ok', true, 'released', false);
  end if;

  v_fp := public.textbook_review_fingerprint(p_crop_id);
  insert into public.textbook_review_decisions (
    academy_id, crop_id, action, target, before_value, after_value, note, fingerprint_seen, fingerprint_after
  ) values (
    v_academy, p_crop_id, 'release_manual', p_target,
    jsonb_build_object('manual', true), jsonb_build_object('manual', false),
    coalesce(p_note, ''), v_fp, v_fp
  );
  return jsonb_build_object('ok', true, 'released', true);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 6) 검수 탭 문항 목록
-- ─────────────────────────────────────────────────────────────────────────

create or replace function public.textbook_review_items(
  p_academy_id uuid,
  p_book_id uuid,
  p_grade_label text,
  p_big_order int,
  p_mid_order int
)
returns table (
  crop_id uuid,
  sub_key text,
  sub_index int,
  item_name text,
  problem_number text,
  label text,
  raw_page int,
  display_page int,
  answer_kind text,
  answer_text text,
  answer_manual boolean,
  solution_source_kind text,
  solution_raw_page int,
  solution_manual boolean,
  pb_question_id uuid,
  open_findings int,
  held_findings int,
  open_by_axis jsonb,
  fingerprint jsonb
)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  perform public.textbook_review_assert_staff(p_academy_id);
  return query
  select c.id, c.sub_key, c.sub_index, c.item_name, c.problem_number, c.label, c.raw_page, c.display_page,
         a.answer_kind,
         coalesce(nullif(btrim(a.answer_text), ''), a.answer_latex_2d),
         coalesce(a.answer_source = 'manual', false),
         s.source_kind,
         s.raw_page,
         coalesce(s.edited_at is not null, false),
         coalesce(l.pb_question_id, pq.id),
         coalesce(fc.open_n, 0),
         coalesce(fc.held_n, 0),
         coalesce(fc.by_axis, '{}'::jsonb),
         public.textbook_review_fingerprint(c.id)
    from public.textbook_problem_crops c
    left join public.textbook_problem_answers a on a.crop_id = c.id
    left join public.textbook_problem_solution_refs s on s.crop_id = c.id
    left join public.textbook_crop_question_links l on l.crop_id = c.id
    left join public.pb_questions pq
      on l.crop_id is null
     and c.pb_question_uid is not null
     and pq.academy_id = c.academy_id
     and pq.question_uid = c.pb_question_uid
    left join lateral (
      select count(*) filter (where f.status = 'open')::int as open_n,
             count(*) filter (where f.status = 'held')::int as held_n,
             (select jsonb_object_agg(x.axis, x.n)
                from (select f2.axis, count(*)::int as n
                        from public.textbook_review_findings f2
                       where f2.crop_id = c.id and f2.status = 'open'
                       group by f2.axis) x) as by_axis
        from public.textbook_review_findings f
       where f.crop_id = c.id
    ) fc on true
   where c.academy_id = p_academy_id and c.book_id = p_book_id and c.grade_label = p_grade_label
     and c.big_order = p_big_order and c.mid_order = p_mid_order and not c.is_set_header
   order by c.raw_page, c.sub_key, c.sub_index, length(c.problem_number), c.problem_number;
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 7) 접근
-- ─────────────────────────────────────────────────────────────────────────

alter table public.textbook_review_runs enable row level security;
alter table public.textbook_review_findings enable row level security;
alter table public.textbook_review_decisions enable row level security;

drop policy if exists "textbook_review_runs select" on public.textbook_review_runs;
create policy "textbook_review_runs select" on public.textbook_review_runs
  for select to authenticated
  using (exists (
    select 1 from public.memberships m
     where m.user_id = auth.uid() and m.academy_id = textbook_review_runs.academy_id
  ));

drop policy if exists "textbook_review_findings select" on public.textbook_review_findings;
create policy "textbook_review_findings select" on public.textbook_review_findings
  for select to authenticated
  using (exists (
    select 1 from public.memberships m
     where m.user_id = auth.uid() and m.academy_id = textbook_review_findings.academy_id
  ));

drop policy if exists "textbook_review_decisions select" on public.textbook_review_decisions;
create policy "textbook_review_decisions select" on public.textbook_review_decisions
  for select to authenticated
  using (exists (
    select 1 from public.memberships m
     where m.user_id = auth.uid() and m.academy_id = textbook_review_decisions.academy_id
  ));

revoke all on public.textbook_review_runs, public.textbook_review_findings, public.textbook_review_decisions
  from anon;
revoke insert, update, delete, truncate
  on public.textbook_review_runs, public.textbook_review_findings, public.textbook_review_decisions
  from authenticated;
revoke all on public.textbook_review_findings_live from anon;

revoke all on function public.textbook_review_fingerprint(uuid) from public, anon;
revoke all on function public.textbook_review_assert_staff(uuid) from public, anon, authenticated;
revoke all on function public.textbook_review_check_expected(text[], jsonb, jsonb) from public, anon, authenticated;
revoke all on function public.textbook_review_apply_change(uuid, uuid, jsonb) from public, anon, authenticated;

revoke all on function public.textbook_review_refresh_load_checks(uuid, uuid, text, int, int) from public, anon;
revoke all on function public.textbook_review_decide(uuid, text, jsonb, jsonb, text) from public, anon;
revoke all on function public.textbook_review_edit(uuid, jsonb, jsonb, text) from public, anon;
revoke all on function public.textbook_review_release_manual(uuid, text, text) from public, anon;
revoke all on function public.textbook_review_items(uuid, uuid, text, int, int) from public, anon;

grant execute on function public.textbook_review_refresh_load_checks(uuid, uuid, text, int, int) to authenticated;
grant execute on function public.textbook_review_decide(uuid, text, jsonb, jsonb, text) to authenticated;
grant execute on function public.textbook_review_edit(uuid, jsonb, jsonb, text) to authenticated;
grant execute on function public.textbook_review_release_manual(uuid, text, text) to authenticated;
grant execute on function public.textbook_review_items(uuid, uuid, text, int, int) to authenticated;

notify pgrst, 'reload schema';
