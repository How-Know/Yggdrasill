-- 필기 인식 개선 파이프라인.
--
-- 설계 (2026-07-26):
--   * 학생앱 신고 다이얼로그에 「필기 인식이 잘 안돼요」 칩을 추가한다.
--     이 칩으로 신고하면 필기 원본 데이터(획 좌표·타이밍·압력·인식 후보)를
--     student_handwriting_samples에 저장한다.
--   * 필기 인식 불량은 문항 자체의 오류가 아니므로, 이 사유만 단독으로
--     신고한 경우 문항을 보류(채점 제외)하지 않는다. 다른 사유와 함께
--     신고하면 기존처럼 보류 신고도 같이 접수한다.
--   * 매니저앱 문제은행 「필기」탭(오류 탭 오른쪽)에서 학생 필기 렌더와
--     해당 문항의 정답을 나란히 보고, 사용자+AI가 판단해 개선 방향을
--     review_note로 기록한다(ai_assessment에 AI 판단 원본 보존).

-- ---------------------------------------------------------------------------
-- 1) 필기 샘플 테이블
-- ---------------------------------------------------------------------------
create table if not exists public.student_handwriting_samples (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  book_id uuid not null references public.resource_files(id) on delete cascade,
  grade_label text not null,
  crop_id uuid not null
    references public.textbook_problem_crops(id) on delete cascade,
  report_id uuid
    references public.student_textbook_problem_reports(id) on delete set null,

  -- {canvas_width, canvas_height, model, recognized_candidates[],
  --  captured_at, strokes:[{x[],y[],t[],p[]}], recognized_text,
  --  submitted_answer, input_mode}
  payload jsonb not null default '{}'::jsonb,
  recognized_text text not null default '',
  submitted_answer text not null default '',
  -- 신고 시점의 정답 스냅샷 (이후 정답이 수정돼도 리뷰 기준 유지)
  expected_answer text not null default '',
  expected_answer_kind text not null default '',
  note text not null default '',

  -- open: 검토 대기 / resolved: 판단 완료 / dismissed: 무시
  review_status text not null default 'open',
  -- AI 판단 원본 {verdict, cause, improvement, raw...}
  ai_assessment jsonb,
  -- 사용자+AI가 합의한 최종 개선 방향
  review_note text not null default '',
  reviewed_by uuid,
  reviewed_at timestamptz,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint shs_review_status_chk
    check (review_status in ('open', 'resolved', 'dismissed'))
);

create index if not exists idx_shs_academy_status
  on public.student_handwriting_samples (academy_id, review_status, created_at desc);
create index if not exists idx_shs_student
  on public.student_handwriting_samples (student_id, created_at desc);

alter table public.student_handwriting_samples enable row level security;

-- 조회: 본인(학생 계정) 또는 학원 스태프.
drop policy if exists shs_select on public.student_handwriting_samples;
create policy shs_select on public.student_handwriting_samples
  for select to authenticated
  using (
    exists (
      select 1 from public.student_app_accounts a
      where a.user_id = auth.uid()
        and a.student_id = student_handwriting_samples.student_id
    )
    or exists (
      select 1 from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id = student_handwriting_samples.academy_id
    )
  );

-- 학생 쓰기는 RPC(security definer)로만. 스태프는 리뷰를 위해 update 허용.
drop policy if exists shs_staff_update on public.student_handwriting_samples;
create policy shs_staff_update on public.student_handwriting_samples
  for update to authenticated
  using (
    exists (
      select 1 from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id = student_handwriting_samples.academy_id
    )
  )
  with check (
    exists (
      select 1 from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id = student_handwriting_samples.academy_id
    )
  );

-- ---------------------------------------------------------------------------
-- 2) 학생 신고 RPC — 필기 데이터 첨부 지원
--    (시그니처 변경: p_handwriting 추가. 기존 5-인자 버전은 제거)
-- ---------------------------------------------------------------------------
drop function if exists public.student_report_textbook_problem(
  uuid, text, uuid, text[], text);

create or replace function public.student_report_textbook_problem(
  p_book_id uuid,
  p_grade_label text,
  p_crop_id uuid,
  p_issue_types text[],
  p_note text default '',
  p_handwriting jsonb default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_academy uuid;
  v_student uuid;
  v_student_name text;
  v_crop_ok boolean;
  v_report_id uuid;
  v_types text[];
  v_hold_types text[];
  v_question_id uuid;
  v_book_name text;
  v_problem_number text;
  v_raw_page integer;
  v_display_page integer;
  v_location text;
  v_context jsonb;
  v_sample_id uuid;
  v_expected text;
  v_expected_kind text;
  v_already boolean := false;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  v_types := (
    select coalesce(array_agg(distinct t), array[]::text[])
    from unnest(coalesce(p_issue_types, array[]::text[])) as t
    where btrim(t) <> ''
  );
  if cardinality(v_types) = 0 then
    return jsonb_build_object('ok', false, 'error', 'missing_issue_types');
  end if;

  -- 필기 인식 불량은 문항 보류 사유에서 제외.
  v_hold_types := (
    select coalesce(array_agg(t), array[]::text[])
    from unnest(v_types) as t
    where t <> 'handwriting_recognition'
  );

  select exists (
    select 1 from public.textbook_problem_crops c
    where c.id = p_crop_id
      and c.academy_id = v_academy
      and c.book_id = p_book_id
      and c.grade_label = p_grade_label
  ) into v_crop_ok;
  if not v_crop_ok then
    return jsonb_build_object('ok', false, 'error', 'crop_not_found');
  end if;

  -- 필기 샘플 저장 (칩 선택 + 데이터가 있을 때).
  if 'handwriting_recognition' = any(v_types) and p_handwriting is not null then
    select
      coalesce(a.answer_text, a.answer_latex_2d, ''),
      coalesce(a.answer_kind, '')
    into v_expected, v_expected_kind
    from public.textbook_problem_answers a
    where a.crop_id = p_crop_id;

    insert into public.student_handwriting_samples (
      academy_id, student_id, book_id, grade_label, crop_id,
      payload, recognized_text, submitted_answer,
      expected_answer, expected_answer_kind, note
    ) values (
      v_academy, v_student, p_book_id, p_grade_label, p_crop_id,
      p_handwriting,
      coalesce(p_handwriting->>'recognized_text', ''),
      coalesce(p_handwriting->>'submitted_answer', ''),
      coalesce(v_expected, ''),
      coalesce(v_expected_kind, ''),
      coalesce(btrim(p_note), '')
    )
    returning id into v_sample_id;
  end if;

  -- 보류 사유가 없으면(필기 단독 신고) 문항 보류 없이 종료.
  if cardinality(v_hold_types) = 0 then
    return jsonb_build_object(
      'ok', true,
      'report_id', null,
      'handwriting_sample_id', v_sample_id,
      'already_reported', false,
      'held', false
    );
  end if;

  -- 이미 보류 중이면 그대로 반환 (open은 유니크 인덱스로도 보호).
  select r.id into v_report_id
  from public.student_textbook_problem_reports r
  where r.student_id = v_student
    and r.crop_id = p_crop_id
    and r.status in ('open', 'accepted')
  limit 1;
  if v_report_id is not null then
    v_already := true;
  else
    insert into public.student_textbook_problem_reports (
      academy_id, student_id, book_id, grade_label, crop_id, issue_types, note
    ) values (
      v_academy, v_student, p_book_id, p_grade_label, p_crop_id,
      v_hold_types, coalesce(btrim(p_note), '')
    )
    returning id into v_report_id;
  end if;

  -- 필기 샘플 ↔ 신고 연결.
  if v_sample_id is not null and v_report_id is not null then
    update public.student_handwriting_samples
    set report_id = v_report_id, updated_at = now()
    where id = v_sample_id;
  end if;

  if v_already then
    return jsonb_build_object(
      'ok', true,
      'report_id', v_report_id,
      'handwriting_sample_id', v_sample_id,
      'already_reported', true,
      'held', true
    );
  end if;

  -- 위치·신고자 스냅샷
  select coalesce(nullif(btrim(s.name), ''), '학생')
    into v_student_name
  from public.students s
  where s.id = v_student;

  select
    coalesce(nullif(btrim(rf.name), ''), '교재'),
    coalesce(nullif(btrim(c.problem_number), ''), ''),
    c.raw_page,
    c.display_page
  into v_book_name, v_problem_number, v_raw_page, v_display_page
  from public.textbook_problem_crops c
  left join public.resource_files rf
    on rf.id = c.book_id
  where c.id = p_crop_id;

  v_location := trim(both ' · ' from concat_ws(
    ' · ',
    nullif(v_book_name, ''),
    case
      when coalesce(v_display_page, v_raw_page) is not null
        then 'p.' || coalesce(v_display_page, v_raw_page)::text
      else null
    end,
    case
      when v_problem_number <> '' then v_problem_number || '번'
      else null
    end
  ));

  v_context := jsonb_build_object(
    'reporter_name', coalesce(v_student_name, '학생'),
    'book_id', p_book_id,
    'book_name', coalesce(v_book_name, '교재'),
    'grade_label', coalesce(p_grade_label, ''),
    'problem_number', coalesce(v_problem_number, ''),
    'raw_page', v_raw_page,
    'display_page', v_display_page,
    'location_label', coalesce(nullif(v_location, ''), '교재 문항')
  );

  -- crop ↔ pb_question 링크가 있으면 매니저 오류 탭 큐에 미러.
  select coalesce(link.pb_question_id, q.id)
    into v_question_id
  from public.textbook_problem_crops c
  left join public.textbook_crop_question_links link
    on link.crop_id = c.id
  left join public.pb_questions q
    on q.academy_id = c.academy_id
   and c.pb_question_uid is not null
   and q.question_uid = c.pb_question_uid
  where c.id = p_crop_id
  limit 1;

  if v_question_id is not null then
    insert into public.pb_question_issue_reports (
      academy_id,
      question_id,
      student_id,
      reporter_user_id,
      issue_types,
      note,
      status,
      source,
      crop_id,
      student_textbook_report_id,
      context
    ) values (
      v_academy,
      v_question_id,
      v_student,
      null,
      v_hold_types,
      coalesce(btrim(p_note), ''),
      'open',
      'student_textbook',
      p_crop_id,
      v_report_id,
      v_context
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'report_id', v_report_id,
    'handwriting_sample_id', v_sample_id,
    'already_reported', false,
    'held', true,
    'mirrored_question_id', v_question_id
  );
end; $$;

revoke all on function public.student_report_textbook_problem(
  uuid, text, uuid, text[], text, jsonb) from public;
grant execute on function public.student_report_textbook_problem(
  uuid, text, uuid, text[], text, jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- 3) 매니저 필기 탭 조회 RPC
-- ---------------------------------------------------------------------------
create or replace function public.staff_handwriting_samples(
  p_academy_id uuid,
  p_status text default 'open',
  p_limit integer default 200
) returns table(
  id uuid,
  created_at timestamptz,
  student_id uuid,
  student_name text,
  book_id uuid,
  book_name text,
  grade_label text,
  crop_id uuid,
  problem_number text,
  raw_page integer,
  display_page integer,
  payload jsonb,
  recognized_text text,
  submitted_answer text,
  expected_answer text,
  expected_answer_kind text,
  note text,
  review_status text,
  ai_assessment jsonb,
  review_note text,
  reviewed_at timestamptz
)
language plpgsql security definer set search_path = public as $$
begin
  if not exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = p_academy_id
  ) then
    raise exception 'not a staff member';
  end if;

  return query
  select
    h.id,
    h.created_at,
    h.student_id,
    coalesce(nullif(btrim(s.name), ''), '학생') as student_name,
    h.book_id,
    coalesce(nullif(btrim(rf.name), ''), '교재') as book_name,
    h.grade_label,
    h.crop_id,
    coalesce(nullif(btrim(c.problem_number), ''), '') as problem_number,
    c.raw_page,
    c.display_page,
    h.payload,
    h.recognized_text,
    h.submitted_answer,
    -- 스냅샷이 비어 있으면 현재 정답으로 폴백.
    coalesce(
      nullif(h.expected_answer, ''),
      a.answer_text, a.answer_latex_2d, ''
    ) as expected_answer,
    coalesce(
      nullif(h.expected_answer_kind, ''), a.answer_kind, ''
    ) as expected_answer_kind,
    h.note,
    h.review_status,
    h.ai_assessment,
    h.review_note,
    h.reviewed_at
  from public.student_handwriting_samples h
  left join public.students s on s.id = h.student_id
  left join public.resource_files rf on rf.id = h.book_id
  left join public.textbook_problem_crops c on c.id = h.crop_id
  left join public.textbook_problem_answers a on a.crop_id = h.crop_id
  where h.academy_id = p_academy_id
    and (coalesce(p_status, '') = '' or h.review_status = p_status)
  order by h.created_at desc
  limit greatest(coalesce(p_limit, 200), 1);
end; $$;

revoke all on function public.staff_handwriting_samples(uuid, text, integer)
  from public;
grant execute on function public.staff_handwriting_samples(uuid, text, integer)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 4) 매니저 리뷰 저장 RPC — 사용자+AI 판단 결과 기록
-- ---------------------------------------------------------------------------
create or replace function public.staff_review_handwriting_sample(
  p_sample_id uuid,
  p_status text,
  p_review_note text default null,
  p_ai_assessment jsonb default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_academy uuid;
begin
  if p_status not in ('open', 'resolved', 'dismissed') then
    return jsonb_build_object('ok', false, 'error', 'invalid_status');
  end if;

  select h.academy_id into v_academy
  from public.student_handwriting_samples h
  where h.id = p_sample_id;
  if v_academy is null then
    return jsonb_build_object('ok', false, 'error', 'sample_not_found');
  end if;

  if not exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = v_academy
  ) then
    raise exception 'not a staff member';
  end if;

  update public.student_handwriting_samples
  set review_status = p_status,
      review_note = coalesce(p_review_note, review_note),
      ai_assessment = coalesce(p_ai_assessment, ai_assessment),
      reviewed_by = case
        when p_status = 'open' then null else auth.uid()
      end,
      reviewed_at = case
        when p_status = 'open' then null else now()
      end,
      updated_at = now()
  where id = p_sample_id;

  return jsonb_build_object('ok', true);
end; $$;

revoke all on function public.staff_review_handwriting_sample(
  uuid, text, text, jsonb) from public;
grant execute on function public.staff_review_handwriting_sample(
  uuid, text, text, jsonb) to authenticated;
