-- 20260725173000: 학습 기록(노출 / 시도) 이벤트 스키마
--
-- 설계 요약
--   * learning_sessions      : "한 번의 풀이 자리". 신뢰도를 좌우하는 사실을 담는다.
--   * learning_exposures     : 문항이 학생에게 보여진 사건 (왜 보여줬는가).
--   * learning_attempts      : 실제 풀이 시도 (어떻게 풀었는가 / 결과 / 걸린 시간).
--   * learning_range_timings : 종이 풀이의 구간 시간(예: 10~15p 40분).
--
-- 원칙
--   1) 노출과 시도를 분리한다. "봤지만 못 푼 문항"이 곧 시간 부족 신호이고,
--      제한시간 테스트에서 몇 문항까지 갔는지도 이걸로만 알 수 있다.
--   2) 신뢰도는 점수로 저장하지 않고 사실(감독/정답접근/채점주체/시간측정)로 저장한다.
--      점수는 learning_reliability_weights 에서 파생한다(다음 마이그레이션).
--   3) 시간은 실측(measured)과 추정(derived_from_range)을 반드시 구분한다.
--   4) 문항 식별은 crop_id(교재 문항) 우선, pb_question_uid(문제은행) 보조.
--
-- 기록 주체는 아직 없다. 아이패드 학생앱 작업이 시작될 때 RPC를 호출해 채운다.

-- ---------------------------------------------------------------------------
-- 1) learning_sessions
-- ---------------------------------------------------------------------------
create table if not exists public.learning_sessions (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,

  -- 무엇을 하는 자리였는가
  session_kind text not null,
  template_id uuid,               -- learning_exam_templates (FK는 뒤 마이그레이션에서)

  -- 신뢰도를 결정하는 사실들
  platform text not null default 'unknown',
  location_kind text not null default 'unknown',
  supervision text not null default 'unknown',
  answer_access text not null default 'unknown',
  scored_by text not null default 'unknown',
  timing_source text not null default 'none',
  material_kind text not null default 'unknown',
  retry_policy text not null default 'none',

  -- 시간 규칙
  time_limit_sec integer,
  time_limit_enforced boolean not null default false,
  target_item_count integer,

  -- 실제 진행
  status text not null default 'open',
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  elapsed_sec integer,
  interrupted_sec integer not null default 0,

  -- 출처 링크 (있으면 채운다)
  homework_group_id uuid references public.homework_groups(id) on delete set null,
  homework_item_id uuid references public.homework_items(id) on delete set null,
  flow_id uuid references public.student_flows(id) on delete set null,
  book_id uuid references public.resource_files(id) on delete set null,
  grade_label text,

  -- 파생 신뢰도 (트리거로 채움 / 언제든 재계산 가능)
  reliability_score numeric(4, 3),
  reliability_tier text,
  reliability_version text,

  meta jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid,

  constraint learning_sessions_kind_chk check (session_kind in (
    'homework',            -- 숙제 / 과제
    'academy_selfstudy',   -- 학원 자습 (교재 풀이)
    'daily_test',          -- 매일 30분 가벼운 테스트
    'monthly_exam',        -- 월간 실전형 시험
    'free_practice',       -- 학생이 원할 때 푸는 자유 풀이
    'retry_clinic',        -- 오답 재도전 (지연 재시도 포함)
    'retention_check',     -- 파지 확인 (2/4/8주 뒤 재노출)
    'diagnostic',          -- 진단 / 배치
    'prerequisite_check',  -- 선수지식 점검
    'power_test',          -- 시간 무제한 대조 테스트
    'mock_exam',           -- 내신 대비 모의 실전
    'other'
  )),
  constraint learning_sessions_platform_chk check (platform in (
    'student_app', 'kiosk', 'web', 'paper', 'teacher_input', 'unknown'
  )),
  constraint learning_sessions_location_chk check (location_kind in (
    'academy', 'home', 'school', 'other', 'unknown'
  )),
  constraint learning_sessions_supervision_chk check (supervision in (
    'proctored',      -- 감독 하 (시간 엄수)
    'staff_present',  -- 학원 내, 스태프가 지켜봄
    'unsupervised',   -- 무감독
    'unknown'
  )),
  constraint learning_sessions_answer_access_chk check (answer_access in (
    'blocked',    -- 정답/해설 접근 불가
    'available',  -- 접근 가능 (집 교재 등)
    'unknown'
  )),
  constraint learning_sessions_scored_by_chk check (scored_by in (
    'auto', 'teacher', 'self', 'mixed', 'unknown'
  )),
  constraint learning_sessions_timing_source_chk check (timing_source in (
    'per_item',     -- 문항별 실측
    'per_range',    -- 구간(페이지 묶음)만 실측 → 문항별은 추정
    'per_session',  -- 세션 전체 시간만
    'none'
  )),
  constraint learning_sessions_material_chk check (material_kind in (
    'db_textbook', 'commercial_textbook', 'problem_bank', 'mixed', 'unknown'
  )),
  constraint learning_sessions_retry_policy_chk check (retry_policy in (
    'none',                -- 재시도 없음
    'single_shot',         -- 틀리면 그대로 통과
    'until_correct',       -- 맞출 때까지
    'post_session_retry'   -- 종료 후 오답만 재도전
  )),
  constraint learning_sessions_status_chk check (status in (
    'open', 'completed', 'abandoned', 'void'
  )),
  constraint learning_sessions_elapsed_chk check (
    elapsed_sec is null or elapsed_sec >= 0
  ),
  constraint learning_sessions_interrupted_chk check (interrupted_sec >= 0)
);

create index if not exists learning_sessions_student_idx
  on public.learning_sessions (academy_id, student_id, started_at desc);
create index if not exists learning_sessions_kind_idx
  on public.learning_sessions (academy_id, session_kind, started_at desc);
create index if not exists learning_sessions_template_idx
  on public.learning_sessions (template_id, started_at desc)
  where template_id is not null;
create index if not exists learning_sessions_open_idx
  on public.learning_sessions (academy_id, student_id)
  where status = 'open';

drop trigger if exists learning_sessions_set_updated_at on public.learning_sessions;
create trigger learning_sessions_set_updated_at
before update on public.learning_sessions
for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- 2) learning_exposures — 왜 보여줬는가
-- ---------------------------------------------------------------------------
create table if not exists public.learning_exposures (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  session_id uuid not null
    references public.learning_sessions(id) on delete cascade,

  -- 문항 식별 (둘 중 하나는 필수)
  crop_id uuid references public.textbook_problem_crops(id) on delete set null,
  pb_question_uid uuid,

  -- 조회 편의를 위한 비정규화 (문항 이동/삭제 후에도 집계가 남도록)
  book_id uuid references public.resource_files(id) on delete set null,
  grade_label text,
  unit_id uuid references public.textbook_units(id) on delete set null,
  raw_page integer,
  display_page integer,

  exposure_reason text not null default 'unknown',
  recommender_key text,           -- 추천 알고리즘 식별자 + 버전 (예: weakness_v1)
  is_anchor boolean not null default false,   -- 회차 난이도 보정용 고정 문항
  position_in_session integer,
  exposure_seq integer,           -- 이 학생이 이 문항을 본 n번째 (트리거로 채움)
  attempted boolean not null default false,   -- 실제 시도로 이어졌는가

  exposed_at timestamptz not null default now(),
  meta jsonb not null default '{}'::jsonb,

  constraint learning_exposures_item_chk check (
    crop_id is not null or pb_question_uid is not null
  ),
  constraint learning_exposures_reason_chk check (exposure_reason in (
    'teacher_assigned',   -- 선생님이 시킴 (필수 과정)
    'recommendation',     -- 추천 알고리즘
    'self_selected',      -- 학생이 직접 고름
    'test_blueprint',     -- 시험 구성표에 따라
    'retry',              -- 오답 재도전
    'retention_review',   -- 파지 확인용 재노출
    'anchor',             -- 난이도 보정용 앵커
    'prerequisite',       -- 선수지식 점검
    'diagnostic',         -- 진단
    'unknown'
  ))
);

create index if not exists learning_exposures_session_idx
  on public.learning_exposures (session_id, position_in_session);
create index if not exists learning_exposures_student_crop_idx
  on public.learning_exposures (student_id, crop_id, exposed_at desc)
  where crop_id is not null;
create index if not exists learning_exposures_crop_idx
  on public.learning_exposures (crop_id, exposed_at desc)
  where crop_id is not null;
create index if not exists learning_exposures_unit_idx
  on public.learning_exposures (unit_id, exposed_at desc)
  where unit_id is not null;
create index if not exists learning_exposures_reason_idx
  on public.learning_exposures (academy_id, exposure_reason, exposed_at desc);

-- ---------------------------------------------------------------------------
-- 3) learning_attempts — 어떻게 풀었는가
-- ---------------------------------------------------------------------------
create table if not exists public.learning_attempts (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  session_id uuid not null
    references public.learning_sessions(id) on delete cascade,
  exposure_id uuid references public.learning_exposures(id) on delete set null,

  crop_id uuid references public.textbook_problem_crops(id) on delete set null,
  pb_question_uid uuid,
  book_id uuid references public.resource_files(id) on delete set null,
  grade_label text,
  unit_id uuid references public.textbook_units(id) on delete set null,

  attempt_no integer not null default 1,             -- 학생×문항 누적 회차
  attempt_no_in_session integer not null default 1,

  result text not null default 'ungraded',
  answer_text text,

  assist_level text not null default 'none',
  assist_note text not null default '',
  confidence text,                                    -- 확신도 (찍었는지 구분)

  duration_ms integer,
  duration_source text not null default 'unknown',

  scored_by text not null default 'unknown',
  scored_at timestamptz,
  scorer_user_id uuid,

  -- 문항별 집계("이 문항을 푼 학생들의 수준")를 위한 시점 스냅샷
  student_level_snapshot smallint,
  reliability_score numeric(4, 3),
  reliability_tier text,

  attempted_at timestamptz not null default now(),
  meta jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),

  constraint learning_attempts_item_chk check (
    crop_id is not null or pb_question_uid is not null
  ),
  constraint learning_attempts_result_chk check (result in (
    'correct',
    'wrong',
    'partial',
    'skipped',    -- 보고 넘김
    'timeout',    -- 시간 종료로 미완
    'ungraded',   -- 채점 전
    'void'        -- 무효 (문항 오류 신고 인정 등)
  )),
  constraint learning_attempts_assist_chk check (assist_level in (
    'none',           -- 스스로 풀어냄
    'hint',           -- 힌트만
    'solution_peek',  -- 해설을 봄
    'peer',           -- 친구 도움
    'teacher',        -- 선생님 도움
    'unknown'
  )),
  constraint learning_attempts_confidence_chk check (
    confidence is null or confidence in ('sure', 'unsure', 'guess')
  ),
  constraint learning_attempts_duration_source_chk check (duration_source in (
    'measured',            -- 실측
    'derived_from_range',  -- 구간 시간 ÷ 문항 수로 추정
    'estimated',           -- 사람이 어림한 값
    'unknown'
  )),
  constraint learning_attempts_scored_by_chk check (scored_by in (
    'auto', 'teacher', 'self', 'unknown'
  )),
  constraint learning_attempts_duration_chk check (
    duration_ms is null or duration_ms >= 0
  ),
  constraint learning_attempts_attempt_no_chk check (
    attempt_no >= 1 and attempt_no_in_session >= 1
  )
);

create index if not exists learning_attempts_student_time_idx
  on public.learning_attempts (academy_id, student_id, attempted_at desc);
create index if not exists learning_attempts_student_crop_idx
  on public.learning_attempts (student_id, crop_id, attempt_no)
  where crop_id is not null;
create index if not exists learning_attempts_crop_idx
  on public.learning_attempts (crop_id, attempted_at desc)
  where crop_id is not null;
create index if not exists learning_attempts_pb_idx
  on public.learning_attempts (pb_question_uid, attempted_at desc)
  where pb_question_uid is not null;
create index if not exists learning_attempts_unit_idx
  on public.learning_attempts (unit_id, attempted_at desc)
  where unit_id is not null;
create index if not exists learning_attempts_session_idx
  on public.learning_attempts (session_id, attempt_no_in_session);
create index if not exists learning_attempts_reliability_idx
  on public.learning_attempts (academy_id, reliability_tier, attempted_at desc);

-- 같은 세션에서 같은 문항의 같은 회차가 중복 기록되지 않도록.
create unique index if not exists learning_attempts_session_crop_uk
  on public.learning_attempts (session_id, crop_id, attempt_no_in_session)
  where crop_id is not null;

-- ---------------------------------------------------------------------------
-- 4) learning_range_timings — 종이 풀이의 구간 시간
-- ---------------------------------------------------------------------------
-- 학원에서 "10~15p 푸는 데 40분" 처럼 구간 단위로만 시간을 잰다.
-- 구간이 회차마다 조금씩 다르면, 여러 구간의 합 방정식에서 문항별 시간을
-- 역산할 수 있다. 그래서 페이지 범위뿐 아니라 문항 집합(crop_ids)도 남긴다.
create table if not exists public.learning_range_timings (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  session_id uuid references public.learning_sessions(id) on delete cascade,

  book_id uuid references public.resource_files(id) on delete set null,
  grade_label text,
  page_from integer,
  page_to integer,
  crop_ids uuid[] not null default array[]::uuid[],
  item_count integer,

  round_index integer not null default 1,   -- 같은 구간의 몇 회차인가
  elapsed_sec integer not null,
  interrupted_sec integer not null default 0,   -- 질문/이석 등 제외할 시간

  distributed_at timestamptz,   -- 문항별 추정치로 분배한 시각
  recorded_by uuid,
  recorded_at timestamptz not null default now(),
  note text not null default '',

  constraint learning_range_timings_elapsed_chk check (elapsed_sec >= 0),
  constraint learning_range_timings_interrupted_chk check (
    interrupted_sec >= 0 and interrupted_sec <= elapsed_sec
  ),
  constraint learning_range_timings_page_chk check (
    page_from is null or page_to is null or page_from <= page_to
  )
);

create index if not exists learning_range_timings_student_idx
  on public.learning_range_timings (academy_id, student_id, recorded_at desc);
create index if not exists learning_range_timings_book_idx
  on public.learning_range_timings (book_id, grade_label, page_from, page_to);
create index if not exists learning_range_timings_session_idx
  on public.learning_range_timings (session_id)
  where session_id is not null;

-- ---------------------------------------------------------------------------
-- 5) 회차 자동 채번 트리거
-- ---------------------------------------------------------------------------
-- exposure_seq / attempt_no 를 클라이언트가 계산하면 반드시 어긋난다. 서버에서 센다.
create or replace function public._learning_fill_exposure_seq()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.exposure_seq is null or new.exposure_seq <= 0 then
    select count(*) + 1 into new.exposure_seq
    from public.learning_exposures e
    where e.student_id = new.student_id
      and (
        (new.crop_id is not null and e.crop_id = new.crop_id)
        or (new.crop_id is null and new.pb_question_uid is not null
            and e.pb_question_uid = new.pb_question_uid)
      );
  end if;
  return new;
end;
$$;

drop trigger if exists trg_learning_exposures_seq on public.learning_exposures;
create trigger trg_learning_exposures_seq
before insert on public.learning_exposures
for each row execute function public._learning_fill_exposure_seq();

create or replace function public._learning_fill_attempt_no()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.attempt_no is null or new.attempt_no <= 0 then
    select count(*) + 1 into new.attempt_no
    from public.learning_attempts a
    where a.student_id = new.student_id
      and a.result <> 'void'
      and (
        (new.crop_id is not null and a.crop_id = new.crop_id)
        or (new.crop_id is null and new.pb_question_uid is not null
            and a.pb_question_uid = new.pb_question_uid)
      );
  end if;

  if new.attempt_no_in_session is null or new.attempt_no_in_session <= 0 then
    select count(*) + 1 into new.attempt_no_in_session
    from public.learning_attempts a
    where a.session_id = new.session_id
      and (
        (new.crop_id is not null and a.crop_id = new.crop_id)
        or (new.crop_id is null and new.pb_question_uid is not null
            and a.pb_question_uid = new.pb_question_uid)
      );
  end if;

  return new;
end;
$$;

drop trigger if exists trg_learning_attempts_no on public.learning_attempts;
create trigger trg_learning_attempts_no
before insert on public.learning_attempts
for each row execute function public._learning_fill_attempt_no();

-- 시도가 생기면 노출을 "시도됨"으로 표시.
create or replace function public._learning_mark_exposure_attempted()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.exposure_id is not null then
    update public.learning_exposures
    set attempted = true
    where id = new.exposure_id
      and attempted = false;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_learning_attempts_mark_exposure on public.learning_attempts;
create trigger trg_learning_attempts_mark_exposure
after insert on public.learning_attempts
for each row execute function public._learning_mark_exposure_attempted();

-- ---------------------------------------------------------------------------
-- 6) RLS — 스태프는 학원 범위 전체, 학생은 본인 기록 읽기만
-- ---------------------------------------------------------------------------
alter table public.learning_sessions enable row level security;
alter table public.learning_exposures enable row level security;
alter table public.learning_attempts enable row level security;
alter table public.learning_range_timings enable row level security;

do $$
declare
  t text;
begin
  foreach t in array array[
    'learning_sessions',
    'learning_exposures',
    'learning_attempts',
    'learning_range_timings'
  ]
  loop
    execute format('drop policy if exists %I on public.%I', t || '_staff_all', t);
    execute format($f$
      create policy %I on public.%I for all to authenticated
      using (
        exists (
          select 1 from public.memberships m
          where m.user_id = auth.uid()
            and m.academy_id = %I.academy_id
        )
      )
      with check (
        exists (
          select 1 from public.memberships m
          where m.user_id = auth.uid()
            and m.academy_id = %I.academy_id
        )
      )
    $f$, t || '_staff_all', t, t, t);

    execute format('drop policy if exists %I on public.%I', t || '_student_select', t);
    execute format($f$
      create policy %I on public.%I for select to authenticated
      using (
        exists (
          select 1 from public.student_app_accounts a
          where a.user_id = auth.uid()
            and a.student_id = %I.student_id
        )
      )
    $f$, t || '_student_select', t, t);
  end loop;
end
$$;

comment on table public.learning_sessions is
  '학습 기록의 컨텍스트 단위. 감독/정답접근/채점주체/시간측정 등 신뢰도 사실을 담는다.';
comment on table public.learning_exposures is
  '문항이 학생에게 보여진 사건. 왜 보여줬는지(추천/지시/선택)와 시도 여부를 남긴다.';
comment on table public.learning_attempts is
  '문항 풀이 시도. 결과/도움수준/확신도/소요시간과 당시 학생 수준 스냅샷을 남긴다.';
comment on table public.learning_range_timings is
  '종이 풀이의 구간 시간. 문항별 시간을 역산하기 위한 원자료.';
