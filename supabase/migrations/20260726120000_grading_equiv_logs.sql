-- 수학적 동치 채점 판정 로그.
--
-- 설계 (2026-07-26):
--   * 채점 Edge Function(student_textbook_grade)은 이미 3단 판정을 한다:
--       1) 결정적 동치 (정규화 + 수치 샘플링 + 목록/단위/부등식)
--       2) AI 단위 판정 (환산 동치일 때 발문의 단위 지정 여부)
--       3) AI 표현 동치 판정 (한글 서술 답)
--     지금까지는 AI 캐시(student_grading_ai_cache)만 남고 판정 이벤트
--     자체는 어디에도 안 쌓였다.
--   * 이 테이블에 "동치 판정이 개입한 채점"(표기 다른 동치 정답, AI 판정
--     케이스)을 축적한다. 완전 일치 정답과 단순 오답은 기록하지 않는다.
--   * 매니저앱 문제은행 「채점」탭(필기 탭 오른쪽)에서 로그를 검토하고
--     교사가 동치 여부를 확정한다. 「AI 판정 + 교사 교정」 쌍이 향후
--     자체 서술형 채점 AI의 학습 데이터가 된다.

-- ---------------------------------------------------------------------------
-- 1) 로그 테이블
-- ---------------------------------------------------------------------------
create sequence if not exists public.student_grading_equiv_logs_log_no_seq;

create table if not exists public.student_grading_equiv_logs (
  id uuid primary key default gen_random_uuid(),
  -- 「#N」 지칭용 고정 번호.
  log_no bigint not null
    default nextval('public.student_grading_equiv_logs_log_no_seq'),
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  book_id uuid not null references public.resource_files(id) on delete cascade,
  grade_label text not null default '',
  crop_id uuid not null
    references public.textbook_problem_crops(id) on delete cascade,
  -- 세트형 파트 키('(1)'). 일반 문항은 ''.
  part_key text not null default '',

  expected_answer text not null default '',
  submitted_answer text not null default '',

  -- deterministic: 결정적 동치로 정답 처리 (form_differs)
  -- ai_unit: 단위 환산 동치 → AI가 발문 단위 지정 여부 판정
  -- ai_equiv: 한글 표현 동치 → AI 판정
  method text not null default 'deterministic',
  flags text[] not null default '{}',
  deterministic_correct boolean not null default false,
  ai_equivalent boolean,      -- null = 미실행/실패
  ai_unit_specified boolean,  -- null = 미실행/실패
  final_correct boolean not null default false,

  -- open: 검토 대기 / resolved: 판단 완료 / dismissed: 무시
  review_status text not null default 'open',
  -- 교사가 확정한 동치 여부 ('' = 미판정). 학습 데이터의 정답 라벨.
  teacher_verdict text not null default '',
  review_note text not null default '',
  reviewed_by uuid,
  reviewed_at timestamptz,

  created_at timestamptz not null default now(),

  constraint sgel_review_status_chk
    check (review_status in ('open', 'resolved', 'dismissed')),
  constraint sgel_method_chk
    check (method in ('deterministic', 'ai_unit', 'ai_equiv')),
  constraint sgel_teacher_verdict_chk
    check (teacher_verdict in ('', 'equivalent', 'not_equivalent')),
  -- 같은 학생이 같은 답을 다시 제출해도 중복 기록하지 않는다.
  constraint sgel_dedup
    unique (student_id, crop_id, part_key, submitted_answer)
);

alter sequence public.student_grading_equiv_logs_log_no_seq
  owned by public.student_grading_equiv_logs.log_no;

create index if not exists idx_sgel_academy_status
  on public.student_grading_equiv_logs
  (academy_id, review_status, created_at desc);
create unique index if not exists idx_sgel_log_no
  on public.student_grading_equiv_logs (log_no);

alter table public.student_grading_equiv_logs enable row level security;

-- 쓰기는 Edge Function(service role)만. 스태프는 조회/리뷰만.
drop policy if exists sgel_staff_select on public.student_grading_equiv_logs;
create policy sgel_staff_select on public.student_grading_equiv_logs
  for select to authenticated
  using (
    exists (
      select 1 from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id = student_grading_equiv_logs.academy_id
    )
  );

drop policy if exists sgel_staff_update on public.student_grading_equiv_logs;
create policy sgel_staff_update on public.student_grading_equiv_logs
  for update to authenticated
  using (
    exists (
      select 1 from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id = student_grading_equiv_logs.academy_id
    )
  )
  with check (
    exists (
      select 1 from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id = student_grading_equiv_logs.academy_id
    )
  );

-- ---------------------------------------------------------------------------
-- 2) 매니저 채점 탭 조회 RPC
-- ---------------------------------------------------------------------------
create or replace function public.staff_grading_equiv_logs(
  p_academy_id uuid,
  p_status text default 'open',
  p_limit integer default 200
) returns table(
  id uuid,
  log_no bigint,
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
  part_key text,
  expected_answer text,
  submitted_answer text,
  method text,
  flags text[],
  deterministic_correct boolean,
  ai_equivalent boolean,
  ai_unit_specified boolean,
  final_correct boolean,
  review_status text,
  teacher_verdict text,
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
    g.id,
    g.log_no,
    g.created_at,
    g.student_id,
    coalesce(nullif(btrim(s.name), ''), '학생') as student_name,
    g.book_id,
    coalesce(nullif(btrim(rf.name), ''), '교재') as book_name,
    g.grade_label,
    g.crop_id,
    coalesce(nullif(btrim(c.problem_number), ''), '') as problem_number,
    c.raw_page,
    c.display_page,
    g.part_key,
    g.expected_answer,
    g.submitted_answer,
    g.method,
    g.flags,
    g.deterministic_correct,
    g.ai_equivalent,
    g.ai_unit_specified,
    g.final_correct,
    g.review_status,
    g.teacher_verdict,
    g.review_note,
    g.reviewed_at
  from public.student_grading_equiv_logs g
  left join public.students s on s.id = g.student_id
  left join public.resource_files rf on rf.id = g.book_id
  left join public.textbook_problem_crops c on c.id = g.crop_id
  where g.academy_id = p_academy_id
    and (coalesce(p_status, '') = '' or g.review_status = p_status)
  order by g.created_at desc
  limit greatest(coalesce(p_limit, 200), 1);
end; $$;

revoke all on function public.staff_grading_equiv_logs(uuid, text, integer)
  from public;
grant execute on function public.staff_grading_equiv_logs(uuid, text, integer)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 3) 매니저 리뷰 저장 RPC — 교사 동치 확정 기록
-- ---------------------------------------------------------------------------
create or replace function public.staff_review_grading_equiv_log(
  p_log_id uuid,
  p_status text,
  p_teacher_verdict text default null,
  p_review_note text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_academy uuid;
begin
  if p_status not in ('open', 'resolved', 'dismissed') then
    return jsonb_build_object('ok', false, 'error', 'invalid_status');
  end if;
  if p_teacher_verdict is not null
     and p_teacher_verdict not in ('', 'equivalent', 'not_equivalent') then
    return jsonb_build_object('ok', false, 'error', 'invalid_verdict');
  end if;

  select g.academy_id into v_academy
  from public.student_grading_equiv_logs g
  where g.id = p_log_id;
  if v_academy is null then
    return jsonb_build_object('ok', false, 'error', 'log_not_found');
  end if;

  if not exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = v_academy
  ) then
    raise exception 'not a staff member';
  end if;

  update public.student_grading_equiv_logs
  set review_status = p_status,
      teacher_verdict = coalesce(p_teacher_verdict, teacher_verdict),
      review_note = coalesce(p_review_note, review_note),
      reviewed_by = case
        when p_status = 'open' then null else auth.uid()
      end,
      reviewed_at = case
        when p_status = 'open' then null else now()
      end
  where id = p_log_id;

  return jsonb_build_object('ok', true);
end; $$;

revoke all on function public.staff_review_grading_equiv_log(
  uuid, text, text, text) from public;
grant execute on function public.staff_review_grading_equiv_log(
  uuid, text, text, text) to authenticated;
