-- 20260725173500: 학습 기록 신뢰도 가중치 + 파생 점수
--
-- "집에서 품 < 학원 시중교재 < 학원 DB교재 < 학생앱 < 제한 약한 테스트 < 시간엄수 테스트"
-- 라는 순서를 하나의 enum 으로 굳히지 않는다. 그 순서는 사실 여러 축이 겹친 결과다.
--   * supervision    감독이 있었는가
--   * answer_access  정답/해설을 볼 수 있었는가
--   * scored_by      누가 채점했는가
--   * timing_source  시간을 어느 정밀도로 쟀는가
--   * platform       무엇으로 풀었는가
--   * location_kind  어디서 풀었는가
--   * material_kind  어떤 자료였는가
--   * time_limit     제한시간이 있었고 지켜졌는가
--
-- 축별 사실은 learning_sessions 에 저장하고, 점수는 여기 가중치로 파생한다.
-- 가중치를 바꾸면 과거 데이터도 함께 재평가된다(learning_reliability_recompute).

-- ---------------------------------------------------------------------------
-- 1) 가중치 버전
-- ---------------------------------------------------------------------------
create table if not exists public.learning_reliability_versions (
  version text primary key,
  is_active boolean not null default false,
  note text not null default '',
  created_at timestamptz not null default now()
);

-- 활성 버전은 하나만.
create unique index if not exists learning_reliability_versions_active_uk
  on public.learning_reliability_versions (is_active)
  where is_active;

create table if not exists public.learning_reliability_weights (
  id uuid primary key default gen_random_uuid(),
  version text not null
    references public.learning_reliability_versions(version) on delete cascade,
  dimension text not null,
  value text not null,
  weight numeric(4, 3) not null,
  note text not null default '',
  constraint learning_reliability_weights_uk unique (version, dimension, value),
  constraint learning_reliability_weights_range_chk
    check (weight > 0 and weight <= 1)
);

create index if not exists learning_reliability_weights_lookup_idx
  on public.learning_reliability_weights (version, dimension, value);

alter table public.learning_reliability_versions enable row level security;
alter table public.learning_reliability_weights enable row level security;

drop policy if exists learning_reliability_versions_read
  on public.learning_reliability_versions;
create policy learning_reliability_versions_read
  on public.learning_reliability_versions for select to authenticated using (true);

drop policy if exists learning_reliability_weights_read
  on public.learning_reliability_weights;
create policy learning_reliability_weights_read
  on public.learning_reliability_weights for select to authenticated using (true);

-- ---------------------------------------------------------------------------
-- 2) v1 시드
-- ---------------------------------------------------------------------------
insert into public.learning_reliability_versions (version, is_active, note)
values ('v1', true, '초기 가중치. 실제 데이터가 쌓이면 재보정할 것.')
on conflict (version) do nothing;

insert into public.learning_reliability_weights (version, dimension, value, weight, note)
values
  ('v1', 'supervision', 'proctored',            1.000, '감독 하 시험'),
  ('v1', 'supervision', 'staff_present',        0.850, '학원 내, 스태프가 지켜봄'),
  ('v1', 'supervision', 'unsupervised',         0.550, '무감독 (집 등)'),
  ('v1', 'supervision', 'unknown',              0.500, ''),

  ('v1', 'answer_access', 'blocked',            1.000, '정답/해설 접근 불가'),
  ('v1', 'answer_access', 'available',          0.500, '정답을 볼 수 있는 환경'),
  ('v1', 'answer_access', 'unknown',            0.700, ''),

  ('v1', 'scored_by', 'auto',                   1.000, '서버 자동 채점'),
  ('v1', 'scored_by', 'teacher',                0.900, ''),
  ('v1', 'scored_by', 'mixed',                  0.750, ''),
  ('v1', 'scored_by', 'self',                   0.550, '자가 채점'),
  ('v1', 'scored_by', 'unknown',                0.550, ''),

  ('v1', 'timing_source', 'per_item',           1.000, '문항별 실측'),
  ('v1', 'timing_source', 'per_range',          0.650, '구간 시간에서 추정'),
  ('v1', 'timing_source', 'per_session',        0.500, '세션 총시간만'),
  ('v1', 'timing_source', 'none',               0.400, '시간 미측정'),

  ('v1', 'platform', 'student_app',             1.000, ''),
  ('v1', 'platform', 'kiosk',                   0.950, ''),
  ('v1', 'platform', 'web',                     0.900, ''),
  ('v1', 'platform', 'paper',                   0.700, ''),
  ('v1', 'platform', 'teacher_input',           0.650, '사후 수기 입력'),
  ('v1', 'platform', 'unknown',                 0.600, ''),

  ('v1', 'location_kind', 'academy',            1.000, ''),
  ('v1', 'location_kind', 'school',             0.800, ''),
  ('v1', 'location_kind', 'home',               0.750, ''),
  ('v1', 'location_kind', 'other',              0.700, ''),
  ('v1', 'location_kind', 'unknown',            0.700, ''),

  ('v1', 'material_kind', 'db_textbook',        1.000, '편집 DB 교재 (문항 식별 가능)'),
  ('v1', 'material_kind', 'problem_bank',       1.000, ''),
  ('v1', 'material_kind', 'mixed',              0.900, ''),
  ('v1', 'material_kind', 'commercial_textbook',0.850, '시중 교재 (문항 매칭 불확실)'),
  ('v1', 'material_kind', 'unknown',            0.800, ''),

  ('v1', 'time_limit', 'strict',                1.000, '제한시간 있고 강제됨'),
  ('v1', 'time_limit', 'loose',                 0.900, '제한시간 있으나 느슨함'),
  ('v1', 'time_limit', 'none',                  0.800, '제한 없음')
on conflict (version, dimension, value) do update
  set weight = excluded.weight,
      note = excluded.note;

-- ---------------------------------------------------------------------------
-- 3) 점수 함수
-- ---------------------------------------------------------------------------
create or replace function public.learning_reliability_active_version()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select version from public.learning_reliability_versions where is_active limit 1),
    'v1'
  );
$$;

-- 축별 가중치의 기하평균. 한 축이 나빠도 전체가 붕괴하지 않으면서,
-- 여러 축이 동시에 나쁘면 확실히 낮아진다.
create or replace function public.learning_reliability_score(
  p_supervision text,
  p_answer_access text,
  p_scored_by text,
  p_timing_source text,
  p_platform text,
  p_location_kind text,
  p_material_kind text,
  p_time_limit text,
  p_version text default null
) returns numeric
language sql
stable
security definer
set search_path = public
as $$
  with v as (
    select coalesce(p_version, public.learning_reliability_active_version()) as version
  ),
  facts(dimension, value) as (
    values
      ('supervision',   coalesce(p_supervision, 'unknown')),
      ('answer_access', coalesce(p_answer_access, 'unknown')),
      ('scored_by',     coalesce(p_scored_by, 'unknown')),
      ('timing_source', coalesce(p_timing_source, 'none')),
      ('platform',      coalesce(p_platform, 'unknown')),
      ('location_kind', coalesce(p_location_kind, 'unknown')),
      ('material_kind', coalesce(p_material_kind, 'unknown')),
      ('time_limit',    coalesce(p_time_limit, 'none'))
  )
  select round(
    exp(avg(ln(coalesce(w.weight, 0.5))))::numeric,
    3
  )
  from facts f
  cross join v
  left join public.learning_reliability_weights w
    on w.version = v.version
   and w.dimension = f.dimension
   and w.value = f.value;
$$;

create or replace function public.learning_reliability_tier(p_score numeric)
returns text
language sql
immutable
as $$
  select case
    when p_score is null then 'unknown'
    when p_score >= 0.90 then 'high'
    when p_score >= 0.78 then 'medium'
    when p_score >= 0.65 then 'low'
    else 'very_low'
  end;
$$;

-- 세션 행에서 time_limit 축 값을 뽑는다.
create or replace function public._learning_time_limit_kind(
  p_time_limit_sec integer,
  p_enforced boolean
) returns text
language sql
immutable
as $$
  select case
    when p_time_limit_sec is null or p_time_limit_sec <= 0 then 'none'
    when coalesce(p_enforced, false) then 'strict'
    else 'loose'
  end;
$$;

-- ---------------------------------------------------------------------------
-- 4) 세션 저장 시 점수 스냅샷
-- ---------------------------------------------------------------------------
create or replace function public._learning_sessions_apply_reliability()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_version text := public.learning_reliability_active_version();
  v_score numeric;
begin
  v_score := public.learning_reliability_score(
    new.supervision,
    new.answer_access,
    new.scored_by,
    new.timing_source,
    new.platform,
    new.location_kind,
    new.material_kind,
    public._learning_time_limit_kind(new.time_limit_sec, new.time_limit_enforced),
    v_version
  );
  new.reliability_score := v_score;
  new.reliability_tier := public.learning_reliability_tier(v_score);
  new.reliability_version := v_version;
  return new;
end;
$$;

drop trigger if exists trg_learning_sessions_reliability on public.learning_sessions;
create trigger trg_learning_sessions_reliability
before insert or update of
  supervision, answer_access, scored_by, timing_source,
  platform, location_kind, material_kind,
  time_limit_sec, time_limit_enforced
on public.learning_sessions
for each row execute function public._learning_sessions_apply_reliability();

-- 시도 행에는 세션 점수를 복제해 둔다(집계 시 조인을 줄이기 위한 스냅샷).
create or replace function public._learning_attempts_copy_reliability()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.reliability_score is null then
    select s.reliability_score, s.reliability_tier
    into new.reliability_score, new.reliability_tier
    from public.learning_sessions s
    where s.id = new.session_id;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_learning_attempts_reliability on public.learning_attempts;
create trigger trg_learning_attempts_reliability
before insert on public.learning_attempts
for each row execute function public._learning_attempts_copy_reliability();

-- ---------------------------------------------------------------------------
-- 5) 가중치를 바꿨을 때 과거 데이터 재평가
-- ---------------------------------------------------------------------------
create or replace function public.learning_reliability_recompute(
  p_academy_id uuid default null
) returns integer
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_version text := public.learning_reliability_active_version();
  v_count integer;
begin
  update public.learning_sessions s
  set reliability_score = public.learning_reliability_score(
        s.supervision, s.answer_access, s.scored_by, s.timing_source,
        s.platform, s.location_kind, s.material_kind,
        public._learning_time_limit_kind(s.time_limit_sec, s.time_limit_enforced),
        v_version
      ),
      reliability_version = v_version
  where p_academy_id is null or s.academy_id = p_academy_id;

  update public.learning_sessions s
  set reliability_tier = public.learning_reliability_tier(s.reliability_score)
  where (p_academy_id is null or s.academy_id = p_academy_id)
    and s.reliability_tier is distinct from
        public.learning_reliability_tier(s.reliability_score);

  update public.learning_attempts a
  set reliability_score = s.reliability_score,
      reliability_tier = s.reliability_tier
  from public.learning_sessions s
  where s.id = a.session_id
    and (p_academy_id is null or a.academy_id = p_academy_id);

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.learning_reliability_recompute(uuid) from public;
grant execute on function public.learning_reliability_recompute(uuid) to authenticated;

grant execute on function public.learning_reliability_active_version() to authenticated;
grant execute on function public.learning_reliability_score(
  text, text, text, text, text, text, text, text, text
) to authenticated;
grant execute on function public.learning_reliability_tier(numeric) to authenticated;

comment on table public.learning_reliability_weights is
  '신뢰도 축별 가중치. 점수는 저장 사실에서 파생되며 버전을 바꿔 재평가할 수 있다.';
