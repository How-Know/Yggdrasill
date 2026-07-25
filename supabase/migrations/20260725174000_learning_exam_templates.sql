-- 20260725174000: 학습 세션 템플릿 (테스트 유형 정의)
--
-- 매일 30분 테스트, 월간 실전 시험, 자유 풀이처럼 "규칙이 정해진 풀이 자리"를
-- 코드에 흩어놓지 않고 한 곳에 정의한다. 세션은 이 템플릿을 참조하고,
-- 감독/시간/재시도/채점 규칙을 여기서 복사해 간다.
--
-- blueprint 는 문항 구성 비율이다. anchor(난이도 보정용 고정 문항)와
-- retention(과거 정답 문항 재노출)을 처음부터 자리로 잡아두면,
-- 나중에 별도 시험을 새로 만들지 않고도 회차 비교와 파지 측정이 가능해진다.

create table if not exists public.learning_exam_templates (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  code text not null,
  name text not null,
  description text not null default '',

  session_kind text not null,
  cadence text not null default 'ad_hoc',

  -- 세션 생성 시 복사되는 기본 규칙
  platform text not null default 'student_app',
  location_kind text not null default 'unknown',
  supervision text not null default 'unknown',
  answer_access text not null default 'blocked',
  scored_by text not null default 'auto',
  timing_source text not null default 'per_item',
  material_kind text not null default 'mixed',
  retry_policy text not null default 'none',

  time_limit_sec integer,
  time_limit_enforced boolean not null default false,
  target_item_count integer,

  -- 문항 구성 비율 (합이 1.0 이 되도록 운용). 예:
  --   {"new": 0.6, "retention": 0.2, "prerequisite": 0.1, "anchor": 0.1}
  blueprint jsonb not null default '{}'::jsonb,
  -- 그 외 규칙 (재도전 지연일수, 파지 확인 간격 등)
  config jsonb not null default '{}'::jsonb,

  is_active boolean not null default true,
  is_system boolean not null default false,
  order_index integer not null default 0,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint learning_exam_templates_code_uk unique (academy_id, code),
  constraint learning_exam_templates_code_chk check (btrim(code) <> ''),
  constraint learning_exam_templates_cadence_chk check (cadence in (
    'daily', 'weekly', 'monthly', 'per_unit', 'on_demand', 'ad_hoc'
  )),
  constraint learning_exam_templates_kind_chk check (session_kind in (
    'homework', 'academy_selfstudy', 'daily_test', 'monthly_exam',
    'free_practice', 'retry_clinic', 'retention_check', 'diagnostic',
    'prerequisite_check', 'power_test', 'mock_exam', 'other'
  )),
  constraint learning_exam_templates_platform_chk check (platform in (
    'student_app', 'kiosk', 'web', 'paper', 'teacher_input', 'unknown'
  )),
  constraint learning_exam_templates_location_chk check (location_kind in (
    'academy', 'home', 'school', 'other', 'unknown'
  )),
  constraint learning_exam_templates_supervision_chk check (supervision in (
    'proctored', 'staff_present', 'unsupervised', 'unknown'
  )),
  constraint learning_exam_templates_answer_access_chk check (answer_access in (
    'blocked', 'available', 'unknown'
  )),
  constraint learning_exam_templates_scored_by_chk check (scored_by in (
    'auto', 'teacher', 'self', 'mixed', 'unknown'
  )),
  constraint learning_exam_templates_timing_chk check (timing_source in (
    'per_item', 'per_range', 'per_session', 'none'
  )),
  constraint learning_exam_templates_material_chk check (material_kind in (
    'db_textbook', 'commercial_textbook', 'problem_bank', 'mixed', 'unknown'
  )),
  constraint learning_exam_templates_retry_chk check (retry_policy in (
    'none', 'single_shot', 'until_correct', 'post_session_retry'
  ))
);

create index if not exists learning_exam_templates_academy_idx
  on public.learning_exam_templates (academy_id, is_active, order_index);

drop trigger if exists learning_exam_templates_set_updated_at
  on public.learning_exam_templates;
create trigger learning_exam_templates_set_updated_at
before update on public.learning_exam_templates
for each row execute function public.set_updated_at();

alter table public.learning_exam_templates enable row level security;

drop policy if exists learning_exam_templates_staff_all
  on public.learning_exam_templates;
create policy learning_exam_templates_staff_all
on public.learning_exam_templates for all to authenticated
using (
  exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = learning_exam_templates.academy_id
  )
)
with check (
  exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = learning_exam_templates.academy_id
  )
);

drop policy if exists learning_exam_templates_student_select
  on public.learning_exam_templates;
create policy learning_exam_templates_student_select
on public.learning_exam_templates for select to authenticated
using (
  exists (
    select 1 from public.student_app_accounts a
    where a.user_id = auth.uid()
      and a.academy_id = learning_exam_templates.academy_id
  )
);

-- 세션 → 템플릿 FK 연결
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'learning_sessions_template_fk'
  ) then
    alter table public.learning_sessions
      add constraint learning_sessions_template_fk
      foreign key (template_id)
      references public.learning_exam_templates(id) on delete set null;
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- 기본 템플릿 시드
-- ---------------------------------------------------------------------------
create or replace function public.learning_seed_default_exam_templates(
  p_academy_id uuid
) returns integer
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  insert into public.learning_exam_templates (
    academy_id, code, name, description,
    session_kind, cadence,
    platform, location_kind, supervision, answer_access,
    scored_by, timing_source, material_kind, retry_policy,
    time_limit_sec, time_limit_enforced, target_item_count,
    blueprint, config, is_system, order_index
  )
  values
    (p_academy_id, 'DAILY30', '매일 30분 테스트',
     '추천 알고리즘이 뽑아주는 가벼운 일일 테스트. 주어진 시간 안에 몇 문항까지 가는지를 본다.',
     'daily_test', 'daily',
     'student_app', 'academy', 'staff_present', 'blocked',
     'auto', 'per_item', 'mixed', 'post_session_retry',
     1800, true, null,
     '{"new": 0.6, "retention": 0.2, "prerequisite": 0.1, "anchor": 0.1}'::jsonb,
     '{"retry_delay_days": 0, "shuffle": true}'::jsonb,
     true, 10),

    (p_academy_id, 'MONTHLY', '월간 실전 시험',
     '문항 수와 시간이 고정된 실제 시험 형태. 앵커 문항으로 월별 비교가 가능하게 한다.',
     'monthly_exam', 'monthly',
     'student_app', 'academy', 'proctored', 'blocked',
     'auto', 'per_item', 'mixed', 'single_shot',
     4800, true, 30,
     '{"new": 0.7, "retention": 0.2, "anchor": 0.1}'::jsonb,
     '{"allow_review_after": true}'::jsonb,
     true, 20),

    (p_academy_id, 'FREEPLAY', '자유 풀이',
     '학생이 원할 때 원하는 만큼. 자기선택 편향이 있어 실력 추정보다 학습량 지표로 쓴다.',
     'free_practice', 'on_demand',
     'student_app', 'home', 'unsupervised', 'blocked',
     'auto', 'per_item', 'mixed', 'until_correct',
     null, false, null,
     '{"new": 0.7, "retention": 0.3}'::jsonb,
     '{"track_abandon_point": true}'::jsonb,
     true, 30),

    (p_academy_id, 'RETRYCLINIC', '오답 재도전 (지연)',
     '틀린 문항을 며칠 뒤에 다시 낸다. 당일 재시도는 단기 기억, 지연 재시도가 이해 확인에 가깝다.',
     'retry_clinic', 'on_demand',
     'student_app', 'academy', 'staff_present', 'blocked',
     'auto', 'per_item', 'mixed', 'until_correct',
     null, false, null,
     '{"retry": 1.0}'::jsonb,
     '{"delay_days": 3}'::jsonb,
     true, 40),

    (p_academy_id, 'RETENTION', '파지 확인',
     '한 번 맞춘 문항을 간격을 두고 다시 낸다. 벼락치기와 실제 정착을 구분하는 유일한 축.',
     'retention_check', 'weekly',
     'student_app', 'academy', 'staff_present', 'blocked',
     'auto', 'per_item', 'mixed', 'single_shot',
     null, false, null,
     '{"retention": 1.0}'::jsonb,
     '{"offsets_days": [14, 28, 56]}'::jsonb,
     true, 50),

    (p_academy_id, 'PREREQ', '선수지식 점검',
     '새 단원에 들어가기 전 필요한 이전 개념만 짧게 확인한다.',
     'prerequisite_check', 'per_unit',
     'student_app', 'academy', 'staff_present', 'blocked',
     'auto', 'per_item', 'mixed', 'single_shot',
     300, false, 5,
     '{"prerequisite": 1.0}'::jsonb,
     '{"block_progress_on_fail": false}'::jsonb,
     true, 60),

    (p_academy_id, 'POWER', '시간 무제한 대조 테스트',
     '제한 없이 끝까지 풀게 한다. 시간이 부족한 것인지 몰라서 못 푸는 것인지 분리한다.',
     'power_test', 'ad_hoc',
     'student_app', 'academy', 'staff_present', 'blocked',
     'auto', 'per_item', 'mixed', 'single_shot',
     null, false, null,
     '{"new": 1.0}'::jsonb,
     '{"compare_with": "DAILY30"}'::jsonb,
     true, 70),

    (p_academy_id, 'DIAG', '진단 · 배치',
     '신규 학생 또는 학기 시작 시 시작점을 잡는다. 적응형으로 짧게.',
     'diagnostic', 'ad_hoc',
     'student_app', 'academy', 'staff_present', 'blocked',
     'auto', 'per_item', 'mixed', 'single_shot',
     900, false, null,
     '{"diagnostic": 1.0}'::jsonb,
     '{"adaptive": true}'::jsonb,
     true, 80),

    (p_academy_id, 'ACADEMY_PAPER', '학원 교재 풀이 (종이)',
     '학원에서 종이 교재를 푸는 자리. 구간 시간(회차별)만 기록되고 문항별 시간은 추정한다.',
     'academy_selfstudy', 'ad_hoc',
     'paper', 'academy', 'staff_present', 'blocked',
     'teacher', 'per_range', 'commercial_textbook', 'until_correct',
     null, false, null,
     '{}'::jsonb,
     '{"prefer_small_ranges": true}'::jsonb,
     true, 90),

    (p_academy_id, 'HOME_PAPER', '집 숙제 (종이)',
     '무감독 · 정답 접근 가능 · 자가 채점. 실력 추정에는 쓰지 말고 학습량으로만 본다.',
     'homework', 'ad_hoc',
     'paper', 'home', 'unsupervised', 'available',
     'self', 'none', 'commercial_textbook', 'until_correct',
     null, false, null,
     '{}'::jsonb,
     '{"volume_only": true}'::jsonb,
     true, 100)
  on conflict (academy_id, code) do nothing;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.learning_seed_default_exam_templates(uuid) from public;
grant execute on function public.learning_seed_default_exam_templates(uuid) to authenticated;

do $$
declare
  v_academy uuid;
begin
  for v_academy in select id from public.academies loop
    perform public.learning_seed_default_exam_templates(v_academy);
  end loop;
end
$$;

-- 새 학원이 생기면 기본 템플릿도 같이 만든다.
create or replace function public._learning_seed_templates_on_academy()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.learning_seed_default_exam_templates(new.id);
  return new;
end;
$$;

drop trigger if exists trg_academies_seed_learning_templates on public.academies;
create trigger trg_academies_seed_learning_templates
after insert on public.academies
for each row execute function public._learning_seed_templates_on_academy();

comment on table public.learning_exam_templates is
  '테스트 유형 정의. 세션은 여기서 감독/시간/재시도/문항구성 규칙을 복사해 간다.';
