-- 과제 권장 소요시간 1단계: 초기값(경험치) 기반 제안.
--
-- 설계 (2026-07-29, docs/homework_pacing_plan.md 참고):
--   * 권장시간은 마감이 아니라 페이스 지표다. 완료 조건은 항상 범위(문항).
--   * 단가는 (시리즈, 과정, 카테고리)별 초 단위로 저장한다.
--     시리즈/과정 ''(빈 값)는 공통 기본.
--   * 지금은 관리자가 경험으로 넣는 초기값만 사용한다. 나중에 간이 시험
--     실측(learning_attempts, 신뢰도 높은 표본)으로 보정한다.
--   * 과제 출제 시 자동 계산값(recommended_minutes_auto)과 사용자가 확정한
--     값(recommended_minutes)을 둘 다 저장한다. 차이가 곧 "사람의 교정"이라
--     이후 기본 단가 보정의 학습 데이터가 된다.

-- ---------------------------------------------------------------------------
-- 1) 단가 테이블
-- ---------------------------------------------------------------------------
create table if not exists public.homework_time_defaults (
  academy_id uuid not null references public.academies(id) on delete cascade,
  -- '' = 전역 기본 / 'ssen' / 'rpm' / 'wonri' 등 교재 시리즈 키
  series_key text not null default '',
  -- '' = 과정 공통 / 'middle' / 'high'
  school_level_key text not null default '',
  -- 문항 분류 키. 시리즈별 단계/유형('A','B','C','서술형 주관식','실력 UP',
  -- '개념원리 익히기','필수유형','확인 체크','연습문제','특강' 등) 또는 공통 키:
  --   'item'          : 분류 없는 문항 1개
  --   'page'          : 문항수를 모를 때 페이지 1쪽
  --   'item_overhead' : 문항 간 전환 오버헤드 (문항당 가산)
  --   'task_overhead' : 하위과제 1개당 오버헤드 (교재 펴기/자리 잡기)
  category_key text not null,
  seconds_per_unit integer not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint homework_time_defaults_seconds_chk check (seconds_per_unit >= 0),
  constraint homework_time_defaults_school_level_chk
    check (school_level_key in ('', 'middle', 'high')),
  primary key (academy_id, series_key, school_level_key, category_key)
);

-- 개발 중 먼저 생성된 3키 버전도 같은 마이그레이션으로 안전하게 승격한다.
alter table public.homework_time_defaults
  add column if not exists school_level_key text not null default '';
alter table public.homework_time_defaults
  drop constraint if exists homework_time_defaults_school_level_chk,
  drop constraint if exists homework_time_defaults_pkey;
alter table public.homework_time_defaults
  add constraint homework_time_defaults_school_level_chk
    check (school_level_key in ('', 'middle', 'high')),
  add constraint homework_time_defaults_pkey
    primary key (academy_id, series_key, school_level_key, category_key);

alter table public.homework_time_defaults enable row level security;

drop policy if exists homework_time_defaults_all on public.homework_time_defaults;
create policy homework_time_defaults_all on public.homework_time_defaults for all
using (
  exists (
    select 1 from public.memberships m
    where m.academy_id = homework_time_defaults.academy_id
      and m.user_id = auth.uid()
  )
)
with check (
  exists (
    select 1 from public.memberships m
    where m.academy_id = homework_time_defaults.academy_id
      and m.user_id = auth.uid()
  )
);

-- ---------------------------------------------------------------------------
-- 1-1) 경험 기반 초기 단가 (초/문항)
--
-- 새로 추출되는 교재/문항에 값을 복사하지 않는다. 과제 출제 시 교재 payload 의
-- series + grade_label + 문항 section/label 로 이 표를 조회하므로, 이후 추출분에도
-- 자동으로 같은 단가가 적용된다. 새 시리즈는 이 표에 행만 추가하면 된다.
-- ---------------------------------------------------------------------------
insert into public.homework_time_defaults (
  academy_id,
  series_key,
  school_level_key,
  category_key,
  seconds_per_unit
)
select
  a.id,
  seed.series_key,
  seed.school_level_key,
  seed.category_key,
  seed.seconds_per_unit
from public.academies a
cross join (
  values
    -- 초기 α: 과제(현재 저장 단위인 하위과제) 하나당 준비·이동·채점·검사 10분.
    -- 실측 데이터가 쌓이면 학생별 α로 교체한다.
    ('',       '',       'task_overhead',     600),

    -- 개념+유형: 중등 전 과정. 개념확인만 30초, 나머지는 2분.
    ('gaeyu', 'middle', 'concept_check',      30),
    ('gaeyu', 'middle', 'essential_problem', 120),
    ('gaeyu', 'middle', 'step_drill',        120),
    ('gaeyu', 'middle', 'unit_drill',        120),
    ('gaeyu', 'middle', 'descriptive',       120),
    ('gaeyu', 'middle', 'extra_practice',    120),

    -- 개념원리: 고등 전 과정. 연습문제 중 "실력 UP"만 별도 5분.
    ('wonri', 'high', '개념원리 익히기',  60),
    ('wonri', 'high', '필수유형',         120),
    ('wonri', 'high', '확인 체크',        120),
    ('wonri', 'high', '연습문제',         120),
    ('wonri', 'high', '실력 UP',          300),
    ('wonri', 'high', '특강',             120),

    -- 쎈 중등 / 고등.
    ('ssen', 'middle', 'A',  20),
    ('ssen', 'middle', 'B',  90),
    ('ssen', 'middle', 'C', 300),
    ('ssen', 'high',   'A',  30),
    ('ssen', 'high',   'B', 120),
    ('ssen', 'high',   'C', 360),

    -- RPM 중등 / 고등. C 안의 "실력 UP"은 label 로 별도 분류한다.
    ('rpm', 'middle', 'A',          20),
    ('rpm', 'middle', 'B',          90),
    ('rpm', 'middle', 'C',          90),
    ('rpm', 'middle', '실력 UP',   300),
    ('rpm', 'high',   'A',          30),
    ('rpm', 'high',   'B',         120),
    ('rpm', 'high',   'C',         120),
    ('rpm', 'high',   '실력 UP',   360)
) as seed(series_key, school_level_key, category_key, seconds_per_unit)
on conflict (academy_id, series_key, school_level_key, category_key)
do update set
  seconds_per_unit = excluded.seconds_per_unit,
  updated_at = now();

-- ---------------------------------------------------------------------------
-- 2) homework_items 권장시간 컬럼
-- ---------------------------------------------------------------------------
alter table public.homework_items
  add column if not exists recommended_minutes integer,
  add column if not exists recommended_minutes_auto integer;

comment on column public.homework_items.recommended_minutes is
  '권장 소요시간(분). 출제 시 확정된 값 (자동 계산값을 사람이 수정했을 수 있음).';
comment on column public.homework_items.recommended_minutes_auto is
  '출제 시점의 자동 계산 권장시간(분). recommended_minutes 와의 차이가 사람의 교정.';
