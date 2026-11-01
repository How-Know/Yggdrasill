-- 20261101010000: 연산 점수 1/10배 스케일 조정 및 사고(범용 사고틀 · 실전 알고리즘) 사전 구축
--
-- 1) arithmetic_primitives의 unit_score를 1/10배(0.10 ~ 1.50점)로 조정한다(이미 2.0 초과인 행만 1회 변환).
-- 2) thinking_primitives 테이블 및 RPC(thinking_overview, thinking_primitive_save, thinking_primitive_delete)를 생성한다.
--    - kind = 'frame'     : 범용 사고틀 (이름 + 판정 기준 criteria + 예시 example_expr + 점수 3.0~9.0)
--    - kind = 'algorithm' : 실전 알고리즘 (이름 + ① 조건 단서 trigger_cond + ② 의사결정·절차 action_steps + ③ 함정 방어 trap_note + 점수 3.5~10.0)

update public.arithmetic_primitives
   set unit_score = round(unit_score / 10.0, 2),
       updated_at = now()
 where unit_score >= 0.99
   and exists (select 1 from public.arithmetic_primitives where code = 'nat_add_1d_1d_nc' and unit_score >= 0.99);

create table if not exists public.thinking_primitives (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (btrim(code) <> '' and char_length(code) <= 80),
  kind text not null check (kind in ('frame', 'algorithm')),
  category text not null check (btrim(category) <> '' and char_length(category) <= 60),
  title text not null check (btrim(title) <> '' and char_length(title) <= 160),
  -- 범용 사고틀(frame)용 한 줄 판정 기준
  criteria text not null default '' check (char_length(criteria) <= 1500),
  -- 실전 알고리즘(algorithm)용 3단 구조: ① 조건 단서(Trigger) ② 의사결정·절차(Action) ③ 함정·제한 조건(Trap)
  trigger_cond text not null default '' check (char_length(trigger_cond) <= 1500),
  action_steps text not null default '' check (char_length(action_steps) <= 3000),
  trap_note text not null default '' check (char_length(trap_note) <= 1500),
  example_expr text not null default '' check (char_length(example_expr) <= 500),
  unit_score numeric(6, 2) not null default 4.0 check (unit_score >= 0 and unit_score <= 100),
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists thinking_primitives_kind_cat_idx
  on public.thinking_primitives (kind, category, sort_order, code);

alter table public.thinking_primitives enable row level security;

drop policy if exists thinking_primitives_select on public.thinking_primitives;
create policy thinking_primitives_select on public.thinking_primitives
  for select to authenticated
  using (true);

revoke insert, update, delete on public.thinking_primitives from anon, authenticated;
grant select on public.thinking_primitives to authenticated;

create or replace function public.thinking_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not (select public.is_superadmin()) then
    raise exception 'thinking_forbidden';
  end if;
  return jsonb_build_object(
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', t.id,
        'code', t.code,
        'kind', t.kind,
        'category', t.category,
        'title', t.title,
        'criteria', t.criteria,
        'trigger_cond', t.trigger_cond,
        'action_steps', t.action_steps,
        'trap_note', t.trap_note,
        'example_expr', t.example_expr,
        'unit_score', t.unit_score,
        'sort_order', t.sort_order,
        'is_active', t.is_active,
        'updated_at', t.updated_at
      ) order by t.kind desc, t.sort_order, t.category, t.code)
      from public.thinking_primitives t
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.thinking_primitive_save(
  p_id uuid,
  p_code text,
  p_kind text,
  p_category text,
  p_title text,
  p_criteria text,
  p_trigger_cond text,
  p_action_steps text,
  p_trap_note text,
  p_example_expr text,
  p_unit_score numeric,
  p_sort_order integer default 0,
  p_is_active boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.thinking_primitives;
begin
  if not (select public.is_superadmin()) then
    raise exception 'thinking_forbidden';
  end if;
  if p_kind not in ('frame', 'algorithm') then
    raise exception 'thinking_bad_kind';
  end if;
  if p_id is null then
    insert into public.thinking_primitives
      (code, kind, category, title, criteria, trigger_cond, action_steps, trap_note, example_expr, unit_score, sort_order, is_active, updated_at)
    values
      (btrim(p_code), p_kind, btrim(p_category), btrim(p_title),
       coalesce(btrim(p_criteria), ''), coalesce(btrim(p_trigger_cond), ''),
       coalesce(btrim(p_action_steps), ''), coalesce(btrim(p_trap_note), ''),
       coalesce(btrim(p_example_expr), ''), round(coalesce(p_unit_score, 4.0), 2),
       coalesce(p_sort_order, 0), coalesce(p_is_active, true), now())
    returning * into v_row;
  else
    update public.thinking_primitives
       set code = btrim(p_code),
           kind = p_kind,
           category = btrim(p_category),
           title = btrim(p_title),
           criteria = coalesce(btrim(p_criteria), ''),
           trigger_cond = coalesce(btrim(p_trigger_cond), ''),
           action_steps = coalesce(btrim(p_action_steps), ''),
           trap_note = coalesce(btrim(p_trap_note), ''),
           example_expr = coalesce(btrim(p_example_expr), ''),
           unit_score = round(coalesce(p_unit_score, 4.0), 2),
           sort_order = coalesce(p_sort_order, sort_order),
           is_active = coalesce(p_is_active, is_active),
           updated_at = now()
     where id = p_id
    returning * into v_row;
    if not found then
      raise exception 'thinking_primitive_not_found';
    end if;
  end if;
  return to_jsonb(v_row);
end;
$$;

create or replace function public.thinking_primitive_delete(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not (select public.is_superadmin()) then
    raise exception 'thinking_forbidden';
  end if;
  delete from public.thinking_primitives where id = p_id;
  return jsonb_build_object('deleted', found, 'id', p_id);
end;
$$;

revoke all on function public.thinking_overview() from public, anon;
grant execute on function public.thinking_overview() to authenticated;
revoke all on function public.thinking_primitive_save(uuid, text, text, text, text, text, text, text, text, text, numeric, integer, boolean) from public, anon;
grant execute on function public.thinking_primitive_save(uuid, text, text, text, text, text, text, text, text, text, numeric, integer, boolean) to authenticated;
revoke all on function public.thinking_primitive_delete(uuid) from public, anon;
grant execute on function public.thinking_primitive_delete(uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 1) 범용 사고틀 (kind = 'frame', B안: 이름 + 판정 기준 + 예시 + 점수 3.0 ~ 9.0)
-- ─────────────────────────────────────────────────────────────────────────
insert into public.thinking_primitives
  (code, kind, category, title, criteria, example_expr, unit_score, sort_order)
values
  -- [구조·분해] 문제의 뼈대·설계도 읽기
  ('frame_struct_serial_explicit', 'frame', '구조·분해', '명시된 직렬 결합 (친절한 징검다리: A → B)',
   '문제에서 (1), (2) 또는 앞 문장으로 중간 구할 값 A를 명시해 주어, A의 결과를 B의 입력으로 바로 대입해 푸는 2단계 구조',
   'f(1)=2로 a를 먼저 구한 뒤, 완성된 f(x)로 f(3) 구하기', 3.5, 101),
  ('frame_struct_serial_hidden', 'frame', '구조·분해', '숨겨진 직렬 결합 (중간 징검다리 스스로 세우기: A → B)',
   '문제에는 최종 질문 B만 던져져 있으나, B를 구하려면 출제자가 숨겨 둔 중간 값 A(미정계수, 교점 좌표, 공차 등)를 먼저 구해야만 풀리는 구조',
   '삼각형 넓이를 물었으나 먼저 코사인법칙으로 숨은 변의 길이를 구해야 하는 구조', 6.5, 102),
  ('frame_struct_parallel_merge', 'frame', '구조·분해', '병렬 결합 (독립 조건 각각 풀어 마지막에 조립: A + B → C)',
   '서로 독립적인 두 조건(또는 두 단원 개념)에서 각각 A와 B를 따로 구한 뒤 마지막 구하는 식에서만 합치는 구조',
   '앞 조건(극한)에서 a 구하고, 뒤 조건(접선)에서 b를 따로 구해 a+b 계산', 4.5, 103),
  ('frame_struct_recursive_nest', 'frame', '구조·분해', '반복·합성 중첩 구조 (안쪽 껍데기부터 단계별 해체)',
   '합성함수 f(f(x))=k 나 중첩된 연산에서 안쪽 덩어리를 t로 두고 바깥쪽을 먼저 푼 뒤 다시 안쪽을 푸는 2회 반복 구조',
   'f(f(x))=0 에서 f(x)=t로 놓아 f(t)=0의 해 t₁, t₂를 구한 뒤 f(x)=t₁, t₂ 풀기', 6.0, 104),
  ('frame_struct_chunk_subst', 'frame', '구조·분해', '공통 덩어리 치환 (복잡한 식의 껍데기 벗기기)',
   '반복 등장하는 식 전체를 한 문자 X로 가려 기본형 문제로 단순화하는 구조 파악',
   '(x²-2x)² - 3(x²-2x) - 4 = 0 에서 x²-2x = t로 치환', 4.5, 105),
  ('frame_struct_symmetry_cycle', 'frame', '구조·분해', '대칭·순환 구조 포착 (합과 곱 또는 한쪽 결과 대칭 복사)',
   '두 문자(x, y)나 도형의 역할이 완전히 대칭일 때, 합(x+y)과 곱(xy)으로만 식을 다루거나 한쪽 계산 결과를 그대로 대칭 적용하는 사고',
   'x+y=u, xy=v 대칭식 변형 또는 대칭 도형에서 절반만 구해 2배', 5.5, 106),

  -- [연역·전개] 풀이 한 줄을 다음 줄로 내리는 필연적 추론
  ('frame_ded_backward_goal', 'frame', '연역·전개', '목표 역추적 (구하려는 식을 먼저 간단히 정리해 필요한 단서 역산)',
   '주어진 조건부터 무작정 변형하지 않고, 구하라고 한 최종 식을 먼저 정리하여 실제로 알아내야 할 최소 단서가 무엇인지 거꾸로 찾는 사고',
   '구할 값 α²+β²을 (α+β)²-2αβ로 먼저 고쳐 놓고 합과 곱만 찾기', 5.0, 201),
  ('frame_ded_dof_count', 'frame', '연역·전개', '미지수 개수 vs 조건식 개수 대조 (자유도·소거 계획)',
   '미지수가 n개이고 등식이 n개이면 연립해 값을 확정하고, 등식이 n-1개이면 한 문자로 통일해 비율(k배)로 나타내는 연역 판단',
   '미지수 a,b,c 3개에 식 2개 → 모두 a에 대한 식(b=2a, c=-a)으로 통일', 5.5, 202),
  ('frame_ded_case_split', 'frame', '연역·전개', '배반 케이스 분류 (기준 경계로 경우를 쪼개 각각 연역 전개)',
   '절댓값 부호, 0이 될 가능성, 홀짝, 대소 관계 등에 따라 한 줄로 내려갈 수 없을 때 빠짐없고 겹치지 않게 경우(i, ii, iii)를 나누는 사고',
   'x < 2 일 때와 x ≥ 2 일 때, 또는 공이 1개인 주머니가 4개인 경우와 6개인 경우로 분할', 7.0, 203),
  ('frame_ded_eliminate_contradiction', 'frame', '연역·전개', '귀류·모순 배제 (가정한 케이스에서 조건 위배를 찾아 소거)',
   '여러 후보 케이스를 전개하다가 문제의 전제(자연수 조건, 부호, 범위 3<k≤4 등)와 모순되는 가지를 논리적으로 소거하는 사고',
   '케이스 (i)에서 k=-8이 나와 k>3 조건에 모순되므로 기각하고 케이스 (ii) 확정', 7.5, 204),
  ('frame_ded_iff_vs_nec', 'frame', '연역·전개', '동치 변형과 필요조건 구별 (양변 제곱·나눗셈 시 역성립 확인)',
   '양변을 제곱하거나 미지수를 곱할 때 원래 식과 동치가 깨져 무연근이 들어올 수 있음을 알고 필요조건으로 먼저 푼 뒤 검산하는 사고',
   '√(x+2) = x 에서 양변 제곱 후 구한 두 근 중 x ≥ 0을 만족하는 근만 채택', 6.0, 205),
  ('frame_ded_ineq_squeeze', 'frame', '연역·전개', '부등식 범위 압축으로 정수·자연수 값 확정',
   '등식만으로 미지수가 하나로 정해지지 않을 때, 부등식 범위(예: 3 < k ≤ 4)와 자연수·정수 조건을 결합해 유일한 값을 확정하는 사고',
   '3 < k ≤ 4 이고 k가 자연수이므로 k = 4 확정', 6.5, 206),

  -- [번역·시각화] 표현 전환 (대수 ↔ 기하 ↔ 문장)
  ('frame_trans_eq_to_graph', 'frame', '번역·시각화', '방정식·부등식을 두 함수 그래프의 교점·위치 관계로 번역',
   '방정식 f(x)=g(x)의 실근의 개수나 위치를 직접 풀지 않고 y=f(x)와 y=g(x)(또는 상수함수 y=k) 그래프의 교점으로 바꾸어 해석하는 사고',
   'f(x)=k의 서로 다른 실근 3개 ⇔ y=f(x) 극댓값과 극솟값 사이에 y=k 위치', 6.5, 301),
  ('frame_trans_expr_to_geom', 'frame', '번역·시각화', '대수식을 기하적 의미(기울기·거리·넓이)로 번역',
   '(f(b)-f(a))/(b-a)를 두 점 사이의 기울기로, √((x-a)²+(y-b)²)를 두 점 사이의 거리로, 정적분을 넓이로 읽어내는 번역 사고',
   'f(b)/b 를 원점 (0,0)과 (b, f(b))를 잇는 직선의 기울기로 해석', 7.5, 302),
  ('frame_trans_word_to_identity', 'frame', '번역·시각화', '문장 조건을 항등식·인수정리 수식 한 줄로 즉시 번역',
   '긴 한국어 조건("f(x)를 ~로 나눈 나머지", "x=2에서 접한다" 등)을 읽자마자 표준 수식 형태(f(x)=(x-2)²Q(x)+R 등)로 직역하는 사고',
   'lim_{x→2} g(x)/(x-2)=0 ⇔ 인수정리에 의해 g(x)는 (x-2)²을 인수로 가짐', 6.0, 303),
  ('frame_trans_geom_to_coord', 'frame', '번역·시각화', '순수 도형 문제를 좌표평면·벡터 성분으로 옮겨 계산화',
   '보조선이 보이지 않는 평면도형(직각삼각형, 직사각형, 정사각형)에 원점과 축을 도입해 점의 좌표로 번역하는 사고',
   '직각삼각형의 직각 꼭짓점을 원점 (0,0)에 놓고 내분점·길이를 좌표로 계산', 7.0, 304),
  ('frame_trans_complement_inv', 'frame', '번역·시각화', '여사건·반대 명제 전환 ("적어도", "아닌 것"을 전체에서 빼기)',
   '직접 세거나 구할 케이스가 너무 많을 때, 전체 경우(또는 1)에서 반대 사건을 빼거나 대우 명제로 바꾸어 푸는 전환 사고',
   '적어도 한 번 나오는 확률 = 1 - (모두 나오지 않을 확률)', 5.0, 305),

  -- [탐색·추론] 실험과 관찰로 규칙·구조 발견
  ('frame_exp_small_n', 'frame', '탐색·추론', '작은 값(n=1, 2, 3, 4) 직접 대입 실험으로 규칙·주기 포착',
   '일반항이나 추상적인 수열·규칙이 한눈에 안 보일 때 n=1, 2, 3, 4를 차례로 넣어보며 변화량이나 반복 주기를 찾아내는 탐색 사고',
   '점화식에 n=1, 2, 3을 대입해 주기가 4임을 발견', 5.5, 401),
  ('frame_exp_boundary_extreme', 'frame', '탐색·추론', '경계값·특이점(접할 때, 양 끝점, 불연속점) 먼저 조사하기',
   '연속적으로 변하는 도형이나 그래프에서 조건이 바뀌는 경계 순간(접하는 순간, 꼭짓점을 지나는 순간)을 먼저 그려 기준을 잡는 사고',
   '직선이 곡선에 접할 때의 k값과 원점을 지날 때의 k값을 경계로 조사', 6.5, 402),
  ('frame_exp_invariant', 'frame', '탐색·추론', '변하는 것 속에서 변하지 않는 불변량(합·곱·거리·넓이 일정) 찾기',
   '점이 움직이거나 도형을 접고 옮겨도 항상 일정하게 유지되는 길이·각·넓이·대칭축을 찾아 등식을 세우는 사고',
   '종이를 접었을 때 접힌 각과 원래 각의 크기가 같음(합동)을 이용해 이등변삼각형 발견', 6.0, 403),

  -- [조건·방어] 숨은 제한 조건 및 함정 방어
  ('frame_def_implicit_domain', 'frame', '조건·방어', '명시되지 않은 식 자체의 정의역·성립 조건(분모≠0, 근호≥0, 진수>0, 최고차항≠0) 방어',
   '문제에 따로 적어주지 않아도 식이 정의되기 위해 반드시 성립해야 하는 기본 제한 조건을 첫 줄에 챙기는 방어 사고',
   '이차방정식에서 최고차항 계수 a≠0, 로그방정식에서 밑>0·밑≠1·진수>0 먼저 기록', 4.5, 501),
  ('frame_def_subst_range', 'frame', '조건·방어', '치환 시 새로운 변수의 값의 범위(정의역) 재설정',
   't = g(x)로 치환하는 순간 원래 변수 x가 사라지므로 반드시 g(x)의 치역을 구해 새 변수 t의 제한 범위로 옮겨 적는 방어 사고',
   't = 2^x 로 치환할 때 t > 0, t = sin x 로 치환할 때 -1 ≤ t ≤ 1 명시', 5.5, 502),
  ('frame_def_case_validity_check', 'frame', '조건·방어', '케이스 분류 후 구한 해가 해당 구간 가정에 들어가는지 적격성 검산',
   '구간을 나누어 푼 방정식·부등식에서 나온 해가 처음에 가정한 구간 조건을 실제로 만족하는지 대조해 무연근을 걸러내는 사고',
   'x < 1 가정하에 구한 해 x = 3 은 x < 1 밖이므로 버림', 5.0, 503),
  ('frame_def_equal_sign_boundary', 'frame', '조건·방어', '부등식 경계에서 등호(=) 포함 여부 별도 대입 검증',
   '두 집합의 포함 관계나 부등식 조건에서 경계값(a < b 인가 a ≤ b 인가)에 등호가 들어가도 조건이 성립하는지 경계 숫자를 직접 넣어 확인하는 사고',
   '경계값 k=3 일 때 자연수 개수가 2개가 맞는지 직접 대입해 3 < k ≤ 4 의 등호 확정', 5.5, 504)
on conflict (code) do update
  set kind = excluded.kind,
      category = excluded.category,
      title = excluded.title,
      criteria = excluded.criteria,
      example_expr = excluded.example_expr,
      unit_score = excluded.unit_score,
      sort_order = excluded.sort_order;

-- ─────────────────────────────────────────────────────────────────────────
-- 2) 실전 알고리즘 (kind = 'algorithm', A안: ① 조건 단서 Trigger + ② 의사결정·절차 Action + ③ 함정 방어 Trap + 점수 4.0 ~ 10.0)
-- ─────────────────────────────────────────────────────────────────────────
insert into public.thinking_primitives
  (code, kind, category, title, trigger_cond, action_steps, trap_note, example_expr, unit_score, sort_order)
values
  -- [다항식·방정식·부등식]
  ('algo_quad_roots_tree', 'algorithm', '다항식·방정식·부등식', '이차방정식의 두 근 조건 의사결정 트리 (판별식 vs 근과 계수 vs 근의 분리)',
   '이차방정식 ax²+bx+c=0의 "두 근(실근·중근·허근)"에 대한 조건이 주어졌을 때',
   '① 근의 존재·개수(서로 다른 두 실근, 중근, 실근을 가질 조건)만 물으면 → 판별식 D = b²-4ac 부호만 쓴다.\n② 두 근 α, β의 합·곱·차·대칭식(α²+β², 1/α+1/β)이나 두 근의 비(2:3)가 주어지면 → 근과 계수의 관계(α+β=-b/a, αβ=c/a)를 먼저 세운다.\n③ 두 근의 부호(두 양근, 두 음근)면 → D ≥ 0, α+β 부호, αβ 부호 3가지를 연립한다.\n④ 두 근이 특정 수 k보다 크다/작다(근의 위치·분리)면 → 이차함수 그래프를 그려 ㉠ 판별식 D, ㉡ 경계 함숫값 f(k) 부호, ㉢ 대칭축 x=-b/(2a) 위치 3가지를 따진다.',
   '"서로 다른" 말이 없으면 중근(D=0)도 두 근에 포함되므로 D ≥ 0을 써야 하며, 최고차항 계수 a ≠ 0 조건을 빠뜨리지 않는다.',
   '두 근이 모두 1보다 클 조건 → D ≥ 0, f(1) > 0, 축 > 1', 6.5, 601),

  ('algo_max_min_tree', 'algorithm', '다항식·방정식·부등식', '최댓값·최솟값 구하기 종합 의사결정 트리',
   '식이나 함수의 최댓값·최솟값을 구하라는 질문이 나왔을 때',
   '① 이차식 또는 이차함수로 귀결되면 → 완전제곱식 표준형 a(x-p)²+q 로 묶고 정의역(구간) 양 끝점과 꼭짓점(x=p)이 구간 안에 들어오는지 비교한다.\n② 양수 조건(a>0, b>0)과 합·곱·역수 구조(x + k/x)가 보이면 → 산술평균·기하평균(a+b ≥ 2√(ab))을 먼저 시도하고 등호 성립 조건(a=b)을 확인한다.\n③ 같은 덩어리가 반복되면 → t = g(x)로 치환한 뒤 먼저 t의 범위부터 구하고 1번(표준형) 또는 4번(미분)으로 푼다.\n④ 삼차 이상 다항함수이거나 치환 후 3차 이상이면 → 도함수 f''(x)=0으로 극댓값·극솟값과 구간 양 끝값을 비교한다.',
   '산술·기하평균은 양수 조건이 없거나 등호 성립 조건이 정의역 밖이면 쓸 수 없으며, 그 경우 함수의 그래프(증감)로 풀어야 한다.',
   'x > 1 일 때 x + 4/(x-1) = (x-1) + 4/(x-1) + 1 ≥ 2√4 + 1 = 5', 7.5, 602),

  ('algo_identity_poly_rem', 'algorithm', '다항식·방정식·부등식', '나머지정리·항등식 미정계수 결정 알고리즘',
   '다항식 f(x)를 나눈 몫과 나머지 조건이 주어지거나 "모든 x에 대하여 성립"하는 항등식이 주어졌을 때',
   '① 나눗셈 문장이 나오면 즉시 f(x) = B(x)Q(x) + R(x) (단, deg R < deg B) 항등식 한 줄로 바꿔 적는다.\n② 나누는 식 B(x)가 일차식들의 곱으로 인수분해되면 → 몫 Q(x)가0이 되는 x값을 대입(수치대입법)해 미정계수를 구한다.\n③ 완전제곱식 (x-a)²으로 나누거나 대입할 x값이 부족하면 → f(x)를 (x-a)²Q(x) + p(x-a) + f(a) 꼴로 놓거나 양변을 미분해 x=a를 대입한다.',
   '나머지 R(x)의 차수는 반드시 나누는 식 B(x)의 차수보다 1 이상 낮게(이차식으로 나누면 ax+b, 삼차식으로 나누면 ax²+bx+c) 설정해야 한다.',
   'f(x)를 (x-1)²(x-2)로 나눈 나머지 → R(x) = a(x-1)² + b(x-1) + c 로 설정', 6.5, 603),

  ('algo_abs_piecewise', 'algorithm', '다항식·방정식·부등식', '절댓값 기호가 포함된 식·방정식·부등식 해체 알고리즘',
   '식이나 방정식·부등식에 절댓값 |f(x)|가 1개 이상 포함되어 있을 때',
   '① |ax+b| = c 또는 |ax+b| < c (우변이 양의 상수)처럼 단순한 꼴이면 → 구간을 나누지 않고 바로 -c < ax+b < c 공식으로 벗긴다.\n② 절댓값 밖에도 미지수 x가 있거나 절댓값이 2개 이상(|x-a| + |x-b|)이면 → 절댓값 안이 0이 되는 기준점(x=a, b)으로 수직선을 쪼개 구간별로 부호를 정해 푼다.\n③ 각 구간에서 구한 해를 그 구간의 전제 조건과 교집합(∩)한 뒤, 마지막에 모든 구간의 해를 합집합(∪)한다.',
   '각 케이스에서 나온 해는 반드시 그 케이스의 범위 안인지 확인(교집합)해야 하며, 마지막에 케이스끼리는 교집합이 아니라 합집합이다.',
   '|x-1| + |x-3| < 4 → (i) x<1, (ii) 1≤x<3, (iii) x≥3 으로 분할', 6.0, 604),

  -- [함수·그래프·변환]
  ('algo_exp_log_trig_graph_coord', 'algorithm', '함수·그래프·변환', '지수·로그·삼각함수 그래프 위의 도형·길이 조건 풀이 알고리즘 (수능 10번형)',
   '지수·로그·삼각함수 그래프 위에 점 A, B, C와 선분 길이·직각삼각형·기울기 조건이 주어졌을 때',
   '① 그래프의 기준선(지수·로그의 점근선, 삼각함수의 대칭축·주기)과 정점(항상 지나는 점)부터 그래프에 표시한다.\n② 기준점이 되는 한 점의 좌표를 (p, f(p))로 설정한다.\n③ 주어진 길이·평행·기울기·대칭 조건을 이용해 나머지 점 B, C의 좌표를 새 미지수 없이 p를 이용해 표현한다.\n④ 표현된 다른 점의 좌표를 그 점이 놓인 두 번째 곡선의 식에 대입해 p와 미정계수를 구한다.',
   '점마다 미지수를 따로(x₁, y₁, x₂, y₂) 놓으면 미지수가 폭발하므로, 한 점의 x좌표 p와 도형 길이 관계(가로 Δx, 세로 Δy)로 나머지 좌표를 써야 한다.',
   'y=a^x-2 점근선 y=-2 확인 → A(p, 0) 설정 → 선분 길이 2로 B, C 좌표 표현', 7.0, 701),

  ('algo_cubic_quartic_ratio_shape', 'algorithm', '함수·그래프·변환', '삼차·사차함수 개형 추론 및 비율 관계 활용 알고리즘 (수능 9·21·22번형)',
   '삼차·사차함수의 극값, 접선, 실근의 개수 조건으로 함수식 f(x)를 결정해야 할 때',
   '① 도함수 f''(x)=0의 근의 형태에 따라 가능한 그래프 개형 후보(삼차 3가지, 사차 4가지)를 먼저 그린다.\n② "y=k와 접한다" 또는 "x=α에서 극값을 갖는다"는 조건이 있으면 전개식(ax³+bx²+cx+d) 대신 인수분해 꼴 f(x)-k = a(x-α)²(x-β) 로 식을 바로 세운다.\n③ 삼차함수의 대칭점(변곡점)과 극값·교점의 1:2(또는 1:√3) 비율 관계가 성립하는 위치면 미분 계산 없이 교점 좌표를 즉시 구한다.',
   'ax³+bx²+cx+d로 놓고 연립방정식을 풀면 계산량이 3배 이상 늘어나므로 반드시 접점(중근)과 교점을 이용한 인수정리 꼴로 식을 세운다.',
   'x=-3a에서 극댓값 5를 갖고 (0,4)를 지나는 삼차함수 → f(x)-5 = (x+3a)²(x-3a)', 8.5, 702),

  -- [미분·적분(극한·극값·넓이)]
  ('algo_limit_zero_over_zero_factor', 'algorithm', '미분·적분(극한·극값·넓이)', '0/0 꼴 극한 수렴 조건으로부터 다항함수 인수 결정 알고리즘 (수능 21번형)',
   'lim_{x→a} g(x)/(x-a)^n = L (수렴) 조건이 주어지고 다항함수 f(x), g(x)의 식을 찾아야 할 때',
   '① 분모가 0으로 가므로 분자도 0으로 가야 함(인수정리)을 이용해 g(x)가 (x-a)^n을 인수로 가짐을 확정한다.\n② 극한값이 0이 아닌 상수 L(또는 부호 < 0, > 0)이면 정확히 (x-a)^n만 약분되고 남은 식에 x=a를 대입한 값이 L임을 등식·부등식으로 세운다.\n③ 구간별로 정의된 함수라면 좌극한(x→a-)과 우극한(x→a+)을 각각 따로 인수 약분하여 계수 조건을 비교한다.',
   '분모에 x(x-2)가 있을 때 x→0과 x→2 두 군데 모두에서 인수를 챙겨야 하며, 약분 후 대입할 때 부호(음수 인수)를 놓치지 않는다.',
   'lim_{x→0+} g(x)/(x(x-2)) 수렴 및 lim_{x→2+} 수렴 ⇒ f(x)=ax(x-2)(x-k) 설정', 9.0, 801),

  ('algo_def_integral_function_extrema', 'algorithm', '미분·적분(극한·극값·넓이)', '정적분으로 정의된 함수 h(x) = ∫_a^x (g(t)-f(t))dt의 극값·개형 분석 알고리즘 (수능 15번형)',
   '위끝에 변수 x가 있는 정적분 함수 h(x) = ∫_a^x (g(t)-f(t))dt 의 극값 개수나 최댓값·최솟값 조건이 주어졌을 때',
   '① 무조건 두 가지를 먼저 적는다: ㉠ 아래끝 대입 h(a) = 0, ㉡ 양변 미분 h''(x) = g(x) - f(x).\n② h(x)의 극값 위치는 도함수 h''(x) = g(x) - f(x)의 부호가 바뀌는 점, 즉 두 그래프 y=g(x)와 y=f(x)가 접하지 않고 뚫고 지나가는 교점임을 파악한다.\n③ 정적분 값 h(b) - h(a)의 크기는 두 곡선 y=g(x)와 y=f(x) 사이의 넓이(위-아래 부호 있는 넓이)로 번역해 그래프 넓이 비교로 부호를 판정한다.',
   'f(x)=g(x)의 교점이라도 접하는 점(짝수 차수 중근)에서는 g(x)-f(x)의 부호가 바뀌지 않으므로 h(x)의 극값이 되지 않는다.',
   'h(x)가 오직 하나의 극값을 가질 조건 ⇔ y=f(x)와 y=g(x)가 부호 바뀌며 만나는 교점이 1개뿐', 9.0, 802),

  ('algo_velocity_distance_integral', 'algorithm', '미분·적분(극한·극값·넓이)', '수직선 위 운동(속도·운동 방향·위치·움직인 거리) 판독 알고리즘 (수능 11번형)',
   '점의 속도 v(t) 또는 위치 x(t)가 주어지고 운동 방향이 바뀌는 시각, 위치, 움직인 거리를 물을 때',
   '① 운동 방향이 바뀌는 시각 ⇔ 속도 v(t) = 0 이면서 전후로 v(t)의 부호가 바뀌는 시각 t를 찾는다.\n② 시각 t=b에서의 위치 ⇔ 초기 위치 x(a) + ∫_a^b v(t) dt (부호 그대로 적분).\n③ 시각 t=a부터 t=b까지 실제 움직인 거리 s ⇔ ∫_a^b |v(t)| dt 이므로, v(t)=0 이 되는 시각을 기준으로 적분 구간을 쪼개 음수 구간에 마이너스를 붙여 넓이를 합산한다.',
   '위치의 변화량(정적분)과 실제 움직인 거리(절댓값 정적분 = 넓이)를 혼동하지 않으며, v(t)=0 이어도 부호가 안 바뀌면(완전제곱식) 운동 방향은 바뀌지 않는다.',
   's = ∫_0^2 |v(t)| dt = ∫_0^1 v(t) dt + ∫_1^2 (-v(t)) dt', 6.0, 803),

  -- [수열·규칙·점화식]
  ('algo_seq_sum_to_term_inductive', 'algorithm', '수열·규칙·점화식', '수열의 합 S_n과 일반항 a_n이 섞인 귀납적 관계식 해법 알고리즘 (수능 22번형)',
   '식 안에 ∑_{k=1}^n a_k (또는 S_n)와 일반항 a_n, a_{n+1}이 함께 들어 있는 관계식이 주어졌을 때',
   '① S_n - S_{n-1} = a_n (단, n ≥ 2) 또는 S_{n+1} - S_n = a_{n+1} 을 이용해 합 기호 ∑를 소거하고 인접한 항(a_n, a_{n+1}) 사이의 점화식을 이끌어낸다.\n② n ≥ 2 제한 때문에 빠진 첫째항·둘째항 관계는 원래 합 식에 직접 n=1, n=2를 대입해 초기값(a₁, a₂)을 따로 구한다.\n③ 구한 점화식(예: 2a_n + a_{n+1} = n)과 구하려는 급수를 대조해, 개별 항을 일일이 다 구하지 않고 묶음 합(a_{2k} + 2a_{2k-1} 등)으로 소거하거나 역추적한다.',
   'S_n - S_{n-1} = a_n 은 n ≥ 2 일 때만 성립하므로 n=1 일 때 성립 여부를 확인하기 전에 함부로 첫째항에 적용하면 틀린다.',
   'S_{n+1} - S_n = a_{n+1} 로 정리하여 2a_n + a_{n+1} = n 유도 후 n=2 대입으로 a₂ 확정', 9.5, 901),

  -- [도형·삼각함수·벡터]
  ('algo_sine_cosine_law_tree', 'algorithm', '도형·삼각함수·벡터', '사인법칙 vs 코사인법칙 선택 및 도형 추적 알고리즘 (수능 14번형)',
   '삼각형과 원이 결합된 도형에서 변의 길이, 각의 크기, 외접원의 반지름을 차례로 구해야 할 때',
   '① 원이 보이면 먼저 원주각·중심각 성질, 내접사각형 대각의 합(π), 반원에 대한 원주각(π/2), 원의 중심에서 현·접선에 내린 수선을 표시한다.\n② "외접원의 반지름 R"이 나오거나 "마주 보는 한 쌍의 변과 각(a와 sin A)"을 알면 → 사인법칙(a/sin A = 2R)을 쓴다.\n③ "두 변과 끼인각(SAS)" 또는 "세 변의 길이(SSS)"를 알거나 구해야 하면 → 코사인법칙(a² = b²+c²-2bc cos A)으로 미지수를 세운다.\n④ 구한 cos θ로부터 sin²θ + cos²θ = 1 로 즉시 sin θ를 구해 다음 삼각형의 사인법칙 징검다리로 넘긴다.',
   '한 삼각형 안에서만 갇혀 있지 말고, 원주각으로 같은 각을 다른 삼각형으로 옮기거나 공유하는 변(공통현 GE 등)을 두 삼각형의 연결 다리로 잡아야 한다.',
   '△AGE에서 코사인법칙으로 GE 구하기 → △CGE에서 코사인법칙으로 cos θ₃ → sin θ₃ → 사인법칙으로 외접원 반지름 R', 8.5, 1001),

  -- [경우의 수·확률·통계]
  ('algo_comb_non_adjacent_multiset', 'algorithm', '경우의 수·확률·통계', '이웃하지 않는 배치 및 중복조합(nHr) 변환 알고리즘 (수능 확통 30번형)',
   '여럿을 배열하거나 주머니에 공을 넣을 때 "이웃하지 않는다" 또는 "합이 일정하고 크기순/조건부 개수"가 주어졌을 때',
   '① 조건이 걸린(개수가 적거나 특이한) 케이스를 먼저 나누어(예: 1개 들어가는 주머니가 4개인 경우 vs 6개인 경우) 큰 틀을 고정한다.\n② "이웃하지 않아야 하는 대상"이 있으면, 이웃해도 상관없는 나머지 대상을 먼저 배열한 뒤 그 사이와 양 끝의 빈자리(∨) 중에서 고른다.\n③ 같은 공을 구별되는 주머니(구간)에 나누어 넣거나 부정방정식 x₁+x₂+⋯+x_n = k 의 음이 아닌 정수해 개수로 번역되면 → 중복조합 nHk 로 계산한다.',
   '이웃하지 않는 빈자리(∨)를 고른 뒤 남은 원소들을 배치할 때, 주머니나 원소가 서로 구별되는지(순열) 같은 것인지(조합·중복조합) 반드시 구분해야 한다.',
   '빈 주머니 A₁~A₄를 먼저 놓고 양 끝·사이 5곳(∨) 중 2곳 선택: ₅C₂', 9.0, 1101),

  ('algo_binom_to_normal_approx', 'algorithm', '경우의 수·확률·통계', '독립시행 확률 → 이항분포 B(n, p) → 정규분포 N(m, σ²) 근사 알고리즘 (수능 확통 29번형)',
   '동일한 시행을 매우 많이(예: 100회, 19200회) 반복할 때 확률변수 X가 특정 범위일 확률 P(X ≤ k)를 구하라고 할 때',
   '① 먼저 1회 시행에서 사건이 일어날 확률 p를 구한다(필요하면 케이스를 나누어 덧셈정리·독립시행 확률로 p를 식으로 표현).\n② 전체 시행 횟수 n과 1회 확률 p로 이항분포 X ~ B(n, p)를 세우고, 평균 m = np, 분산 σ² = np(1-p)를 계산한다.\n③ n이 충분히 크므로 근사 정규분포 N(m, σ²)로 옮긴 뒤, Z = (X - m)/σ 로 표준화하여 표준정규분포표에서 확률을 읽는다.',
   '표준화 분모에는 분산(σ²)이 아니라 반드시 표준편차(σ = √(npq))를 넣어야 하며, 1회 시행 확률 p를 구할 때 배반인 두 케이스를 빠짐없이 더해야 한다.',
   'X ~ B(19200, 1/4) → m=4800, σ=60 → P(X≤4920) = P(Z≤2) = 0.5 + 0.477', 7.5, 1102),

  ('algo_poly_high_deg_factor', 'algorithm', '다항식·방정식·부등식', '고차식(3차·4차 이상) 인수분해 의사결정 트리',
   '3차 이상의 다항식을 인수분해하거나 고차방정식의 근을 구해야 할 때',
   '① 공통인수가 있으면 가장 먼저 묶어낸다.\n② 항이 4개이면 → (2개, 2개) 묶어 공통인수를 만들거나, 완전제곱식이 보이도록 (3개, 1개)로 묶어 A²-B² 합차공식을 쓴다.\n③ 보기차식(x⁴+ax²+b)이면 → x²=t로 치환해 인수분해하거나, 안 되면 이차항을 쪼개 (x²+k)² - (mx)² 꼴로 만든다.\n④ 문자가 여러 개이면 → 차수가 가장 낮은 문자에 대하여 내림차순 정리한다.\n⑤ 한 문자에 대한 일반 고차식이면 → 상수항의 약수/최고차항 계수의 약수를 대입해 0이 되는 값 α를 찾아 조립제법(인수정리)을 쓴다.',
   '조립제법에서 차수가 비어 있는 항(예: x²항이 없을 때)의 계수 자리에 0을 빠뜨리면 몫이 전부 밀려 틀린다.',
   'x³ - 4x + 3 → 계수 1, 0, -4, 3 으로 α=1 조립제법', 5.5, 605),

  ('algo_ineq_always_true', 'algorithm', '다항식·방정식·부등식', '절대부등식 · 모든 실수(또는 제한된 구간)에서 부등식이 항상 성립할 조건 알고리즘',
   '"모든 실수 x에 대하여" 또는 "a ≤ x ≤ b에서" 부등식 f(x) ≥ 0 (또는 f(x) ≥ g(x))이 항상 성립할 조건을 물을 때',
   '① 이차부등식이 모든 실수 x에서 성립할 조건이면 → 이차함수가 x축 위에 떠 있어야 하므로 최고차항 계수 a > 0 이고 판별식 D ≤ 0 을 연립한다.\n② 제한된 구간(α ≤ x ≤ β)에서 이차부등식이 성립할 조건이면 → 판별식 D를 쓰지 말고, 구간 [α, β] 안에서 함수의 최솟값 ≥ 0 (또는 최댓값 ≤ 0)을 구한다(대칭축 위치가 구간 안/밖인지 케이스 분류).\n③ 미정계수 k가 일차로만 들어 있으면 → k만 남기고 넘겨 f(x) ≥ k 꼴로 분리(상수 분리)한 뒤 좌변 함수의 최솟값 ≥ k 로 푼다.',
   '"이차부등식"이라는 말이 없으면 최고차항 계수가 0일 때(상수함수 꼴)도 성립하는지 반드시 별도로 확인해야 한다.',
   '0 ≤ x ≤ 2 에서 f(x) ≥ 0 ⇔ 구간 [0, 2]에서 f(x)의 최솟값 ≥ 0', 7.0, 606),

  ('algo_func_inverse_intersect', 'algorithm', '함수·그래프·변환', '역함수 f⁻¹(x) 관련 함숫값·교점·넓이 처리 알고리즘',
   '문제에 역함수 f⁻¹(x)의 함숫값, 원래 함수와의 교점, 또는 역함수 정적분이 등장할 때',
   '① 역함수 식 f⁻¹(x)를 직접 구하려고 하지 않는다.\n② f⁻¹(a) = b 조건이 나오면 → 즉시 f(b) = a 로 바꾸어 원래 함수에 대입한다.\n③ 증가함수 y = f(x)와 역함수 y = f⁻¹(x)의 교점은 → y = f(x)와 직선 y = x 의 교점으로 바꾸어 푼다.\n④ y = f(x)와 y = f⁻¹(x)로 둘러싸인 넓이는 → y = f(x)와 y = x 사이의 넓이를 구해 2배 한다.',
   '감소하는 구간이 있는 함수는 y = x 위의 점 외에 y = -x + k 대칭점(`f(a)=b, f(b)=a`)에서도 교점이 생길 수 있음을 주의한다.',
   'f⁻¹(3) = k ⇔ f(k) = 3, 교점은 f(x) = x 로 풀이', 5.5, 703),

  ('algo_func_continuity_diff_piecewise', 'algorithm', '미분·적분(극한·극값·넓이)', '구간별 정의된 함수·절댓값 함수의 연속성 및 미분가능성 판정 알고리즘',
   '경계 x=a에서 식이 갈라진 함수나 |f(x)|, f(x)g(x) 꼴 함수가 실수 전체에서 연속 또는 미분가능할 조건을 물을 때',
   '① 경계 x=a에서 연속 조건 → 좌극한 = 우극한 = 함숫값, 즉 두 조각 식에 각각 x=a를 대입한 값이 같음(f₁(a) = f₂(a))을 먼저 세운다.\n② 경계 x=a에서 미분가능 조건 → 연속 조건 성립 + 좌미분계수 = 우미분계수(f₁''(a) = f₂''(a))를 연립한다.\n③ |f(x)|가 x=a(f(a)=0인 근)에서 미분가능할 조건 → 그래프가 x축을 뚫지 않고 접해야 하므로 f''(a) = 0 (중근 이상)이어야 한다.\n④ 불연속 함수 g(x)에 연속함수 f(x)를 곱한 f(x)g(x)가 x=a에서 연속이려면 → 불연속을 덮어주기 위해 f(a) = 0 이어야 한다.',
   '미분가능 조건(도함수 대입 일치)만 쓰고 연속 조건(원함수 대입 일치)을 빼먹으면 상수항 조건이 누락되어 오답이 나온다.',
   'x=a에서 미분가능 ⇔ ① f₁(a)=f₂(a) (연속), ② f₁''(a)=f₂''(a) (미분계수 일치)', 7.5, 804),

  ('algo_tangent_line_3cases', 'algorithm', '미분·적분(극한·극값·넓이)', '접선의 방정식 3가지 유형(접점·기울기·곡선 밖의 점) 알고리즘 (수능 13번형)',
   '곡선 y = f(x)에 그은 접선의 방정식이나 접선으로 둘러싸인 도형의 넓이를 구할 때',
   '① 곡선 위의 점 (a, f(a))가 주어지면 → 기울기 f''(a)를 구해 y - f(a) = f''(a)(x - a)를 바로 세운다.\n② 기울기 m이 주어지면 → f''(t) = m 을 풀어 접점의 x좌표 t를 구한 뒤 1번으로 돌아간다.\n③ 곡선 밖의 점 (p, q)에서 그은 접선이면 → 무조건 접점의 좌표를 먼저 (t, f(t))로 놓고, 접선 식 y - f(t) = f''(t)(x - t)에 밖의 점 (p, q)를 대입해 t에 대한 방정식을 푼다.\n④ 곱의 미분법 형태 g(x) = u(x)f(x)의 접선이면 전개하지 말고 g''(x) = u''(x)f(x) + u(x)f''(x)에 바로 x=a를 대입한다.',
   '곡선 밖의 점 (p, q)를 미분계수 f''(p)에 바로 대입하면 절대 안 되며, 반드시 미지 접점 (t, f(t))를 먼저 잡아야 한다.',
   'g(x)=(x³-2x)f(x) 의 (1,6)에서의 접선 → 곱의 미분법으로 g''(1) 계산 후 직선 식 도출', 5.5, 805),

  ('algo_integral_area_formula', 'algorithm', '미분·적분(극한·극값·넓이)', '곡선과 직선(또는 두 곡선)으로 둘러싸인 넓이 및 넓이 이등분 알고리즘 (수능 7번형)',
   '두 곡선 y=f(x), y=g(x)로 둘러싸인 도형의 넓이를 구하거나 두 영역의 넓이가 같다(이등분)는 조건이 주어졌을 때',
   '① 먼저 f(x) - g(x) = 0 을 풀어 교점의 x좌표 α, β (α < β)를 구한다.\n② 두 교점 α, β 사이에서 다른 교점이 없는 이차함수(또는 삼차함수와 접선)로 둘러싸인 넓이면 → 일일이 적분하지 않고 넓이 공식 S = |a|/6 · (β - α)³ (삼차 접선은 |a|/12 · (β - α)⁴)을 즉시 적용한다.\n③ 두 영역 A, B의 넓이가 같다는 조건이 나오면 → 따로 넓이를 구하지 말고 한 번에 이어서 적분한 정적분 ∫_α^γ (f(x) - g(x)) dx = 0 으로 번역한다.',
   '넓이 공식 S = |a|/6·(β-α)³ 은 양 끝 적분 구간 α, β가 정확히 방정식 f(x)-g(x)=0 의 두 근일 때만 쓸 수 있다.',
   '이차곡선과 직선 교점 x=-1, 3 일 때 넓이 S = |a|/6 × (3 - (-1))³', 5.5, 806),

  ('algo_seq_arith_geom_structure', 'algorithm', '수열·규칙·점화식', '등차수열·등비수열 조건 번역 및 대칭항(등차·등비중항) 알고리즘 (수능 12번형)',
   '등차수열이나 등비수열의 몇 개 항의 합·곱·비 조건이 주어졌을 때',
   '① 등차수열이면 모든 항을 첫째항 a와 공차 d로(a_n = a + (n-1)d), 등비수열이면 첫째항 a와 공비 r로(a_n = a·r^(n-1)) 통일해 미지수를 2개로 줄인다.\n② 연속한 세 항이나 대칭인 항들의 합(예: a₁+a₂+a₃ = 15)이 주어지면 → 등차중항(3a₂ = 15 ⇒ a₂ = 5) 또는 등비중항(a₁a₃ = a₂²)으로 가운데 항을 즉시 구한다.\n③ 등비수열의 두 조건식 나눗셈: (a+ar+ar²)와 (ar³+ar⁴+ar⁵)처럼 항 번호가 일정하게 차이 나면 공통인수 r³으로 묶어 두 식을 나누어 r³을 한 번에 구한다.',
   '등비수열에서 공비 r이 양수인지 실수인지(짝수 거듭제곱 r²=4 일 때 r=±2) 부호 조건을 반드시 확인한다.',
   'a₃ + a₅ = 2a₄ (등차중항), a₄ / a₁ = r³ (등비수열 항의 비)', 5.0, 902),

  ('algo_geom_similarity_pythagoras', 'algorithm', '도형·삼각함수·벡터', '직각삼각형·평행선·접기 도형에서 닮음과 피타고라스 결합 알고리즘',
   '평면도형에서 선분의 길이를 구해야 하는데 직접 피타고라스 정리를 쓸 변이 하나 부족할 때',
   '① 직각이 여러 개이거나 평행선·맞꼭지각이 있으면 → AA 닮음인 두 삼각형을 찾아 대응변의 비(a:b = c:d)로 미지 변을 한 문자 k로 나타낸다.\n② 원의 접선이 있으면 → 원의 중심과 접점을 이어 수직(90°) 표시를 하고, 원 밖의 한 점에서 그은 두 접선의 길이가 같음을 표시한다.\n③ 구하려는 선분 x를 직각삼각형의 한 변에 포함시킨 뒤, 나머지 변들을 x에 대한 식으로 나타내어 피타고라스 정리 등식을 세운다.',
   '닮음비를 쓸 때 눈대중으로 대응변을 짝짓지 말고, 두 각(점 각, × 각, 직각)의 순서를 맞춰 대응 꼭짓점 순서대로 비례식을 세운다.',
   '직각삼각형 안의 수선 → 소 공식(AB² = BH·BC) 및 닮음비 적용', 6.0, 1002),

  ('algo_prob_conditional_exclusive', 'algorithm', '경우의 수·확률·통계', '덧셈정리 · 배반사건 · 조건부확률 의사결정 알고리즘 (수능 확통 24·25번형)',
   '사건 A, B의 확률 조건이나 "~일 때 ~일 확률(조건부확률)"이 주어졌을 때',
   '① P(A∪B)가 주어지면 → 덧셈정리 P(A∪B) = P(A) + P(B) - P(A∩B)를 먼저 적고, 두 케이스가 동시에 일어날 수 없는 배반사건이면 P(A∩B)=0 으로 처리한다.\n② "A와 B가 독립"이라는 말이 있으면 → P(A∩B) = P(A)P(B) 및 P(A|B) = P(A)로 즉시 고친다.\n③ 시행 결과 "~일 때, 그중 ~일 확률"처럼 분모 사건이 제한된 조건부확률 P(B|A)면 → 전체 표본공간 대신 사건 A를 두 배반 케이스 A₁, A₂로 쪼개 P(A₁) / (P(A₁) + P(A₂)) 형태로 계산한다.',
   '독립사건(P(A∩B)=P(A)P(B))과 배반사건(P(A∩B)=0)은 전혀 다른 조건이므로 절대 혼동하지 않는다.',
   'P(A∪B)=1 및 P(B|A)=P(A∩B)/P(A) 연립, 배반 케이스 분할 합산', 5.5, 1103)
on conflict (code) do update
  set kind = excluded.kind,
      category = excluded.category,
      title = excluded.title,
      trigger_cond = excluded.trigger_cond,
      action_steps = excluded.action_steps,
      trap_note = excluded.trap_note,
      example_expr = excluded.example_expr,
      unit_score = excluded.unit_score,
      sort_order = excluded.sort_order;

notify pgrst, 'reload schema';


