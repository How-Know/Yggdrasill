-- 연산 모델의 정책·측정 프로토콜·기준 시간 시드.
-- arithmetic_primitives.unit_score, est_seconds, 문항 점수, 학생 기록은 바꾸지 않는다.

create table if not exists public.arithmetic_measurement_protocols (
  code text primary key,
  name text not null,
  scratch_policy text not null check (scratch_policy in ('forbidden', 'allowed')),
  calculator_policy text not null default 'forbidden' check (calculator_policy = 'forbidden'),
  answer_format text not null check (answer_format in ('integer', 'quotient_remainder')),
  note text not null default ''
);

insert into public.arithmetic_measurement_protocols (code, name, scratch_policy, answer_format, note)
values
  ('mental_integer_v1', '기초 암산 · 정수 답', 'forbidden', 'integer', '한 자리 사칙과 구구단. 메모와 계산기는 쓰지 않는다.'),
  ('mental_quotrem_v1', '기초 암산 · 몫과 나머지', 'forbidden', 'quotient_remainder', '구구단 범위의 나머지 나눗셈. 몫과 나머지를 둘 다 입력한다.'),
  ('scratch_integer_v1', '복합 연산 · 메모 허용 · 정수 답', 'allowed', 'integer', '계산기는 쓰지 않고 메모는 허용한다.'),
  ('scratch_quotrem_v1', '복합 연산 · 메모 허용 · 몫과 나머지', 'allowed', 'quotient_remainder', '나머지가 있는 복합 나눗셈.')
on conflict (code) do nothing;

create table if not exists public.arithmetic_model_policies (
  id uuid primary key default gen_random_uuid(),
  version integer not null check (version > 0),
  state text not null check (state in ('draft', 'active', 'superseded')),
  parameters jsonb not null,
  change_reason text not null,
  created_at timestamptz not null default now()
);

create unique index if not exists arithmetic_model_policies_one_active
  on public.arithmetic_model_policies (state)
  where state = 'active';

create unique index if not exists arithmetic_model_policies_version_uidx
  on public.arithmetic_model_policies (version);

create table if not exists public.arithmetic_model_events (
  id uuid primary key default gen_random_uuid(),
  kind text not null,
  summary text not null,
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.arithmetic_reference_seeds (
  id uuid primary key default gen_random_uuid(),
  primitive_code text not null references public.arithmetic_primitives (code),
  protocol_code text not null references public.arithmetic_measurement_protocols (code),
  initial_time_ms integer not null check (initial_time_ms > 0),
  seed_version integer not null default 1 check (seed_version > 0),
  origin text not null default 'seed',
  note text not null default '',
  created_at timestamptz not null default now(),
  unique (primitive_code, protocol_code, seed_version)
);

create table if not exists public.arithmetic_reference_revisions (
  id uuid primary key default gen_random_uuid(),
  primitive_code text not null,
  protocol_code text not null,
  seed_version integer not null,
  policy_version integer not null,
  status text not null check (status in ('candidate', 'active', 'superseded', 'rejected')),
  empirical_time_ms numeric,
  candidate_time_ms numeric,
  applied_time_ms numeric,
  eligible_student_count integer not null default 0,
  change_reason text not null default '',
  idempotency_key text unique,
  created_at timestamptz not null default now()
);

create unique index if not exists arithmetic_reference_one_active
  on public.arithmetic_reference_revisions (primitive_code, protocol_code)
  where status = 'active';

create table if not exists public.arithmetic_type_candidates (
  code text primary key,
  name text not null,
  proposed_cost numeric(6, 2) not null check (proposed_cost >= 0),
  initial_time_ms integer not null check (initial_time_ms > 0),
  example text not null,
  status text not null default 'draft' check (status in ('draft', 'active', 'archived')),
  created_at timestamptz not null default now()
);

insert into public.arithmetic_reference_seeds (primitive_code, protocol_code, initial_time_ms, seed_version, origin, note)
select v.code, v.protocol, v.ms, 1, 'seed', '가설 시드. 기존 unit_score와 est_seconds는 바꾸지 않는다.'
from (values
  ('nat_add_1d_1d_nc', 'mental_integer_v1', 1000),
  ('nat_add_1d_1d_c1', 'mental_integer_v1', 1300),
  ('nat_add_2d_1d_nc', 'scratch_integer_v1', 1800),
  ('nat_add_2d_1d_c1', 'scratch_integer_v1', 2300),
  ('nat_add_2d_1d_c2', 'scratch_integer_v1', 3000),
  ('nat_add_2d_2d_nc', 'scratch_integer_v1', 2500),
  ('nat_add_2d_2d_c1', 'scratch_integer_v1', 3000),
  ('nat_add_2d_2d_c2', 'scratch_integer_v1', 3500),
  ('nat_add_3d_23d_c01', 'scratch_integer_v1', 4500),
  ('nat_add_3d_3d_c2p', 'scratch_integer_v1', 6000),
  ('nat_sub_1d_1d', 'mental_integer_v1', 1200),
  ('nat_sub_teen_1d_b1', 'mental_integer_v1', 1700),
  ('nat_sub_2d_1d_nb', 'scratch_integer_v1', 1800),
  ('nat_sub_2d_1d_b1', 'scratch_integer_v1', 2500),
  ('nat_sub_2d_2d_nb', 'scratch_integer_v1', 2500),
  ('nat_sub_2d_2d_b1', 'scratch_integer_v1', 3500),
  ('nat_sub_3d_23d_b01', 'scratch_integer_v1', 4500),
  ('nat_sub_3d_3d_b2', 'scratch_integer_v1', 6000),
  ('nat_sub_zero_chain', 'scratch_integer_v1', 6000),
  ('nat_mul_1d_1d', 'mental_integer_v1', 1200),
  ('nat_mul_pow10', 'scratch_integer_v1', 1700),
  ('nat_mul_2d_1d_nc', 'scratch_integer_v1', 3000),
  ('nat_mul_2d_1d_c1', 'scratch_integer_v1', 4000),
  ('nat_mul_2d_1d_c2', 'scratch_integer_v1', 5000),
  ('nat_mul_3d_1d', 'scratch_integer_v1', 6000),
  ('nat_mul_2d_2d_light', 'scratch_integer_v1', 8000),
  ('nat_mul_2d_2d_heavy', 'scratch_integer_v1', 12000),
  ('nat_mul_3d_2d', 'scratch_integer_v1', 16000),
  ('nat_mul_3d_3d', 'scratch_integer_v1', 25000),
  ('nat_div_table_exact', 'mental_integer_v1', 1500),
  ('nat_div_table_rem', 'mental_quotrem_v1', 2500),
  ('nat_div_2d_1d_no_drop', 'scratch_integer_v1', 3500),
  ('nat_div_2d_1d_drop_exact', 'scratch_integer_v1', 5000),
  ('nat_div_2d_1d_drop_rem', 'scratch_quotrem_v1', 6000),
  ('nat_div_3d_1d', 'scratch_integer_v1', 7000),
  ('nat_div_23d_2d_q1', 'scratch_integer_v1', 8000),
  ('nat_div_34d_2d_q2p', 'scratch_integer_v1', 13000)
) as v(code, protocol, ms)
join public.arithmetic_primitives p on p.code = v.code
on conflict (primitive_code, protocol_code, seed_version) do nothing;

insert into public.arithmetic_type_candidates (code, name, proposed_cost, initial_time_ms, example, status)
values
  ('draft_add_zero', '0과 덧셈', 0.05, 900, '37+0', 'draft'),
  ('draft_add_hundreds', '10·100의 배수 더하기', 0.12, 1800, '237+400', 'draft'),
  ('draft_add_3_1_c0', '3자리+1자리 (받아올림 없음)', 0.18, 2100, '235+4', 'draft'),
  ('draft_add_3_1_c1', '3자리+1자리 (받아올림 1회)', 0.25, 2700, '235+8', 'draft'),
  ('draft_add_3_1_c2', '3자리+1자리 (연속 받아올림 2회 이상)', 0.35, 3600, '299+8', 'draft'),
  ('draft_add_3_2_heavy', '3자리+2자리 (받아올림 2회 이상)', 0.50, 5000, '287+58', 'draft'),
  ('draft_add_4', '4자리 이상 덧셈', 0.70, 7500, '1234+5678', 'draft'),
  ('draft_sub_zero', '0 빼기', 0.05, 900, '37-0', 'draft'),
  ('draft_sub_same', '같은 수 빼기', 0.05, 900, '37-37', 'draft'),
  ('draft_sub_hundreds', '10·100의 배수 빼기', 0.15, 1900, '837-300', 'draft'),
  ('draft_sub_3_1_nb', '3자리-1자리 (받아내림 없음)', 0.20, 2200, '235-4', 'draft'),
  ('draft_sub_3_1_b', '3자리-1자리 (받아내림 있음)', 0.32, 3000, '423-7', 'draft'),
  ('draft_sub_4', '4자리 이상 뺄셈', 0.80, 8500, '5234-1789', 'draft'),
  ('draft_mul_zero', '0을 곱하기', 0.05, 900, '37*0', 'draft'),
  ('draft_mul_one', '1을 곱하기', 0.05, 900, '37*1', 'draft'),
  ('draft_mul_tens', '10의 배수 곱하기 (10의 거듭제곱 제외)', 0.30, 4500, '23*40', 'draft'),
  ('draft_div_zero_dividend', '0을 자연수로 나누기', 0.05, 900, '0/7', 'draft'),
  ('draft_div_one', '1로 나누기', 0.05, 1000, '37/1', 'draft'),
  ('draft_div_same', '같은 양의 수로 나누기', 0.05, 1000, '37/37', 'draft'),
  ('draft_div_smaller', '피제수<제수', 0.10, 1800, '3/7', 'draft'),
  ('draft_div_pow10', '10의 거듭제곱으로 나누기', 0.12, 1800, '3700/100', 'draft'),
  ('draft_div_strip_zeros', '끝자리 0을 지우는 나눗셈', 0.20, 3000, '360/40', 'draft'),
  ('draft_div_tens_exact_rem', '2자리÷1자리 (십의 자리 정확, 나머지)', 0.40, 4500, '85/4', 'draft'),
  ('draft_div_internal_zero', '몫 중간에 0이 있는 나눗셈', 0.60, 7000, '612/3', 'draft'),
  ('draft_div_3digit_divisor', '3자리 제수 나눗셈', 1.10, 14000, '1234/123', 'draft')
on conflict (code) do nothing;

insert into public.arithmetic_model_policies (version, state, parameters, change_reason)
select 1, 'active', jsonb_build_object(
  'formula_id', 'fluency_product_v1',
  'w_speed', 1,
  'w_accuracy', 1,
  'mastery_accuracy_pct', 98,
  'mastery_speed', 90,
  'mastery_min_attempts', 100,
  'mastery_min_days', 3,
  'mastery_min_correct_timed', 50,
  'mastery_min_items', 20,
  'calibration_window_days', 180,
  'per_student_recent_attempts', 100,
  'min_student_accuracy_pct', 98,
  'min_distinct_days', 3,
  'min_correct_timed_attempts', 50,
  'min_distinct_items', 20,
  'empirical_quantile', 0.30,
  'prior_strength_k', 20,
  'min_students_candidate', 10,
  'min_students_auto_publish', 30,
  'min_auto_change_fraction', 0.02,
  'max_auto_change_fraction', 0.10,
  'max_relative_ci_width', 0.40,
  'auto_publish_enabled', true,
  'short_time_flag_ms', 150,
  'reasoning_score_basis', 'alreadyWeighted',
  'reasoning_lambda_hypothesis', 5,
  'anchor_score', 50,
  'anchor_is_cap', false,
  'target_grade_percent', null,
  'mul22_light_max_total_carry', 1,
  'addition_base_seconds', 1.0,
  'addition_digit_seconds', 0.12,
  'addition_carry_seconds', 0.35,
  'addition_chain_extra_seconds', 0.15,
  'addition_result_digit_seconds', 0.20,
  'feature_time_affects_fluency', false,
  'bootstrap_draws', 1000,
  'bootstrap_seed', 20261126,
  'note', '기초 암산과 복합 연산 메모는 프로토콜을 나눈다. 사고 점수는 이미 가중된 합이라 5를 다시 곱하지 않는다. 50점은 앵커이고 상한이 아니다.'
), '초기 운영 정책'
where not exists (select 1 from public.arithmetic_model_policies);

insert into public.arithmetic_model_events (kind, summary, detail)
select 'policy_publish', '초기 운영 정책 v1', jsonb_build_object('version', 1)
where exists (select 1 from public.arithmetic_model_policies where version = 1 and state = 'active')
  and not exists (select 1 from public.arithmetic_model_events where kind = 'policy_publish' and summary = '초기 운영 정책 v1');

alter table public.arithmetic_measurement_protocols enable row level security;
alter table public.arithmetic_model_policies enable row level security;
alter table public.arithmetic_model_events enable row level security;
alter table public.arithmetic_reference_seeds enable row level security;
alter table public.arithmetic_reference_revisions enable row level security;
alter table public.arithmetic_type_candidates enable row level security;

revoke all on public.arithmetic_measurement_protocols from anon, authenticated;
revoke all on public.arithmetic_model_policies from anon, authenticated;
revoke all on public.arithmetic_model_events from anon, authenticated;
revoke all on public.arithmetic_reference_seeds from anon, authenticated;
revoke all on public.arithmetic_reference_revisions from anon, authenticated;
revoke all on public.arithmetic_type_candidates from anon, authenticated;

create or replace function public.arithmetic_model_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_policy public.arithmetic_model_policies;
begin
  if not (select public.is_superadmin()) then
    raise exception 'arithmetic_model_forbidden';
  end if;
  select * into v_policy from public.arithmetic_model_policies where state = 'active' order by version desc limit 1;
  return jsonb_build_object(
    'policy', case when v_policy.id is null then null else jsonb_build_object(
      'version', v_policy.version,
      'parameters', v_policy.parameters,
      'change_reason', v_policy.change_reason,
      'created_at', v_policy.created_at
    ) end,
    'events', coalesce((
      select jsonb_agg(jsonb_build_object(
        'kind', e.kind,
        'summary', e.summary,
        'created_at', e.created_at
      ) order by e.created_at desc)
      from (
        select kind, summary, created_at
        from public.arithmetic_model_events
        order by created_at desc
        limit 30
      ) e
    ), '[]'::jsonb),
    'attempt_count', 0,
    'seed_count', (select count(*)::int from public.arithmetic_reference_seeds)
  );
end;
$$;

create or replace function public.arithmetic_model_publish_policy(
  p_expected_version integer,
  p_parameters jsonb,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_active integer;
  v_next integer;
begin
  if not (select public.is_superadmin()) then
    raise exception 'arithmetic_model_forbidden';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'arithmetic_model_reason_required';
  end if;
  if p_parameters is null or jsonb_typeof(p_parameters) <> 'object' then
    raise exception 'arithmetic_model_parameters';
  end if;
  if coalesce(p_parameters->>'anchor_is_cap', 'false') = 'true' then
    raise exception 'arithmetic_model_anchor_cap';
  end if;
  if coalesce(p_parameters->>'feature_time_affects_fluency', 'false') = 'true' then
    raise exception 'arithmetic_model_fluency_guard';
  end if;
  if coalesce(p_parameters->>'reasoning_score_basis', 'alreadyWeighted') <> 'alreadyWeighted' then
    raise exception 'arithmetic_model_reasoning_basis';
  end if;
  select version into v_active from public.arithmetic_model_policies where state = 'active';
  if coalesce(v_active, 0) is distinct from coalesce(p_expected_version, 0) then
    raise exception 'arithmetic_model_conflict';
  end if;
  v_next := coalesce(v_active, 0) + 1;
  update public.arithmetic_model_policies
     set state = 'superseded'
   where state = 'active';
  insert into public.arithmetic_model_policies (version, state, parameters, change_reason)
  values (v_next, 'active', p_parameters, btrim(p_reason));
  insert into public.arithmetic_model_events (kind, summary, detail)
  values ('policy_publish', '정책 v' || v_next || ' 발행', jsonb_build_object('version', v_next, 'reason', btrim(p_reason)));
  return jsonb_build_object('version', v_next);
end;
$$;

revoke all on function public.arithmetic_model_overview() from public, anon;
grant execute on function public.arithmetic_model_overview() to authenticated;
revoke all on function public.arithmetic_model_publish_policy(integer, jsonb, text) from public, anon;
grant execute on function public.arithmetic_model_publish_policy(integer, jsonb, text) to authenticated;
