-- 20261031140000: 연산/방법 개념 분리 및 초정밀 세부 연산 수치 사전(arithmetic_primitives)
--
-- 1) concept_types에 '연산' 유형을 추가하고, 기존 '방법' 유형 중 실제 수·식 계산 개념을 '연산'으로 분리한다.
-- 2) arithmetic_primitives: 자릿수 조합·받아올림/내림 횟수·통분 유형별 세부 연산 단위와 인간 체감 점수·소요 시간을 저장한다.
-- 3) 모체 개념(concept_id)의 이름·본문 해시(synced_concept_md5)를 저장해 라이브러리에서 개념이 수정되면
--    '원본 변경됨(concept_changed)'으로 감지하고 동기화할 수 있게 한다.

insert into public.concept_types (name, description, legacy_sub_type, sort_order, origin)
values (
  '연산',
  '수·식의 사칙연산, 통분·약분, 거듭제곱·제곱근, 다항식 전개·인수분해, 방정식·부등식 변형 등 직접 계산을 수행하는 연산 원리와 절차',
  '연산',
  6,
  'seed'
)
on conflict ((lower(btrim(name)))) do nothing;

-- 기존 '방법' 개념 중 순수 수·식 계산 폴더 및 계산 개념을 '연산' 유형으로 분류한다.
do $$
declare
  v_calc_type uuid;
  v_method_type uuid;
begin
  select id into v_calc_type from public.concept_types where lower(btrim(name)) = '연산' limit 1;
  select id into v_method_type from public.concept_types where lower(btrim(name)) = '방법' limit 1;
  if v_calc_type is not null and v_method_type is not null then
    update public.concept_type_links l
       set type_id = v_calc_type
      from public.concepts c
     where l.concept_id = c.id
       and l.type_id = v_method_type
       and (
         (public.concept_folder_path(c.main_category_id))[2] in ('수와 연산', '수의 연산', '거듭제곱', '행렬')
         or (
           (public.concept_folder_path(c.main_category_id))[2] in ('정수론', '수 체계', '문자와 식', '등식', '부등식', '로그', '벡터')
           and (
             c.name ~ '(덧셈|뺄셈|곱셈|나눗셈|사칙|세로셈|세로 셈|통분|약분|역수|소인수분해|최대공약수|최소공배수|거듭제곱|제곱근|유리화|실수화|전개|인수분해|조립제법|동류항|괄호 풀기|분배법칙|이항|가감법|대입법|완전제곱식|부분분수|번분수|성분에 의한)'
             and c.name !~ '(세우기|활용|찾기|판별|기억하기|그리기|도형|넓이|증명)'
           )
         )
       );
  end if;
end $$;

create table if not exists public.arithmetic_primitives (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (btrim(code) <> '' and char_length(code) <= 80),
  category text not null check (btrim(category) <> '' and char_length(category) <= 60),
  title text not null check (btrim(title) <> '' and char_length(title) <= 160),
  criteria text not null default '' check (char_length(criteria) <= 1000),
  example_expr text not null default '' check (char_length(example_expr) <= 300),
  unit_score numeric(6, 2) not null default 1.0 check (unit_score >= 0 and unit_score <= 100),
  est_seconds numeric(5, 1) not null default 1.5 check (est_seconds >= 0 and est_seconds <= 600),
  concept_id uuid references public.concepts(id) on delete set null,
  synced_concept_md5 text,
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists arithmetic_primitives_category_idx
  on public.arithmetic_primitives (category, sort_order, code);
create index if not exists arithmetic_primitives_concept_idx
  on public.arithmetic_primitives (concept_id);

alter table public.arithmetic_primitives enable row level security;

drop policy if exists arithmetic_primitives_select on public.arithmetic_primitives;
create policy arithmetic_primitives_select on public.arithmetic_primitives
  for select to authenticated
  using (true);

revoke insert, update, delete on public.arithmetic_primitives from anon, authenticated;
grant select on public.arithmetic_primitives to authenticated;

-- 개념의 현재 이름+본문 지문
create or replace function public.arithmetic_concept_md5(p_concept_id uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select md5(coalesce(c.name, '') || E'\n' || coalesce(c.content, ''))
    from public.concepts c
   where c.id = p_concept_id;
$$;

-- 이름으로 개념 ID 찾기(시드 연결용)
create or replace function public._arithmetic_find_concept(p_names text[])
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select c.id
    from unnest(p_names) with ordinality as u(n, ord)
    join public.concepts c on lower(btrim(c.name)) = lower(btrim(u.n))
   order by u.ord, c.created_at
   limit 1;
$$;

-- 연산 화면 전체 조회: 세부 연산 단위 목록 + 개념 라이브러리의 연산/방법 개념 목록 + 변경 감지 상태
create or replace function public.arithmetic_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not (select public.is_superadmin()) then
    raise exception 'arithmetic_forbidden';
  end if;
  return jsonb_build_object(
    'primitives', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id,
        'code', p.code,
        'category', p.category,
        'title', p.title,
        'criteria', p.criteria,
        'example_expr', p.example_expr,
        'unit_score', p.unit_score,
        'est_seconds', p.est_seconds,
        'concept_id', p.concept_id,
        'concept_name', c.name,
        'concept_content', c.content,
        'concept_folder', case when c.id is not null then to_jsonb(public.concept_folder_path(c.main_category_id)) else '[]'::jsonb end,
        'concept_changed', (c.id is not null and p.synced_concept_md5 is not null and public.arithmetic_concept_md5(c.id) is distinct from p.synced_concept_md5),
        'concept_missing', (p.concept_id is not null and c.id is null),
        'sort_order', p.sort_order,
        'is_active', p.is_active,
        'updated_at', p.updated_at
      ) order by p.sort_order, p.category, p.code)
      from public.arithmetic_primitives p
      left join public.concepts c on c.id = p.concept_id
    ), '[]'::jsonb),
    'concepts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', c.id,
        'name', c.name,
        'content', left(coalesce(c.content, ''), 800),
        'type_name', coalesce(t.name, c.sub_type),
        'folder', to_jsonb(public.concept_folder_path(c.main_category_id)),
        'primitive_count', (select count(*)::int from public.arithmetic_primitives ap where ap.concept_id = c.id)
      ) order by public.concept_folder_path(c.main_category_id), c.sort_order nulls last, c.name)
      from public.concepts c
      left join public.concept_type_links l on l.concept_id = c.id
      left join public.concept_types t on t.id = l.type_id
      where c.sub_type = '연산' or t.name in ('연산', '방법')
    ), '[]'::jsonb)
  );
end;
$$;

-- 세부 연산 단위 추가·수정
create or replace function public.arithmetic_primitive_save(
  p_id uuid,
  p_code text,
  p_category text,
  p_title text,
  p_criteria text,
  p_example_expr text,
  p_unit_score numeric,
  p_est_seconds numeric,
  p_concept_id uuid,
  p_sort_order integer default 0,
  p_is_active boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.arithmetic_primitives;
  v_md5 text;
begin
  if not (select public.is_superadmin()) then
    raise exception 'arithmetic_forbidden';
  end if;
  v_md5 := case when p_concept_id is not null then public.arithmetic_concept_md5(p_concept_id) else null end;
  if p_id is null then
    insert into public.arithmetic_primitives
      (code, category, title, criteria, example_expr, unit_score, est_seconds, concept_id, synced_concept_md5, sort_order, is_active, updated_at)
    values
      (btrim(p_code), btrim(p_category), btrim(p_title), coalesce(btrim(p_criteria), ''), coalesce(btrim(p_example_expr), ''),
       round(coalesce(p_unit_score, 1.0), 2), round(coalesce(p_est_seconds, 1.5), 1), p_concept_id, v_md5, coalesce(p_sort_order, 0), coalesce(p_is_active, true), now())
    returning * into v_row;
  else
    update public.arithmetic_primitives
       set code = btrim(p_code),
           category = btrim(p_category),
           title = btrim(p_title),
           criteria = coalesce(btrim(p_criteria), ''),
           example_expr = coalesce(btrim(p_example_expr), ''),
           unit_score = round(coalesce(p_unit_score, 1.0), 2),
           est_seconds = round(coalesce(p_est_seconds, 1.5), 1),
           concept_id = p_concept_id,
           synced_concept_md5 = v_md5,
           sort_order = coalesce(p_sort_order, sort_order),
           is_active = coalesce(p_is_active, is_active),
           updated_at = now()
     where id = p_id
    returning * into v_row;
    if not found then
      raise exception 'arithmetic_primitive_not_found';
    end if;
  end if;
  return to_jsonb(v_row);
end;
$$;

-- 세부 연산 단위 삭제
create or replace function public.arithmetic_primitive_delete(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not (select public.is_superadmin()) then
    raise exception 'arithmetic_forbidden';
  end if;
  delete from public.arithmetic_primitives where id = p_id;
  return jsonb_build_object('deleted', found, 'id', p_id);
end;
$$;

-- 원본 개념 변경 확인 완료(지문 동기화)
create or replace function public.arithmetic_primitive_sync_concept(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.arithmetic_primitives;
begin
  if not (select public.is_superadmin()) then
    raise exception 'arithmetic_forbidden';
  end if;
  update public.arithmetic_primitives p
     set synced_concept_md5 = public.arithmetic_concept_md5(p.concept_id),
         updated_at = now()
   where p.id = p_id
  returning * into v_row;
  if not found then
    raise exception 'arithmetic_primitive_not_found';
  end if;
  return to_jsonb(v_row);
end;
$$;

-- 개념 라이브러리의 개념 유형을 '연산' ↔ '방법'으로 전환
create or replace function public.arithmetic_set_concept_kind(p_concept_id uuid, p_type_name text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_type uuid;
begin
  if not (select public.is_superadmin()) then
    raise exception 'arithmetic_forbidden';
  end if;
  if p_type_name not in ('연산', '방법') then
    raise exception 'arithmetic_bad_type_name';
  end if;
  select id into v_type from public.concept_types where lower(btrim(name)) = lower(btrim(p_type_name)) limit 1;
  if v_type is null then
    raise exception 'arithmetic_type_not_found';
  end if;
  insert into public.concept_type_links (concept_id, type_id, created_by)
  values (p_concept_id, v_type, auth.uid())
  on conflict (concept_id) do update set type_id = excluded.type_id;
  return jsonb_build_object('concept_id', p_concept_id, 'type_name', p_type_name);
end;
$$;

revoke all on function public.arithmetic_overview() from public, anon;
grant execute on function public.arithmetic_overview() to authenticated;
revoke all on function public.arithmetic_primitive_save(uuid, text, text, text, text, text, numeric, numeric, uuid, integer, boolean) from public, anon;
grant execute on function public.arithmetic_primitive_save(uuid, text, text, text, text, text, numeric, numeric, uuid, integer, boolean) to authenticated;
revoke all on function public.arithmetic_primitive_delete(uuid) from public, anon;
grant execute on function public.arithmetic_primitive_delete(uuid) to authenticated;
revoke all on function public.arithmetic_primitive_sync_concept(uuid) from public, anon;
grant execute on function public.arithmetic_primitive_sync_concept(uuid) to authenticated;
revoke all on function public.arithmetic_set_concept_kind(uuid, text) from public, anon;
grant execute on function public.arithmetic_set_concept_kind(uuid, text) to authenticated;

-- 초정밀 세부 연산 단위 시드 데이터 (자릿수 조합 · 받아올림/내림 횟수 · 통분 유형 · 대수 변형)
with raw_seed(sort_order, code, category, title, criteria, example_expr, unit_score, est_seconds, concept_names) as (
  values
    -- 1. 자연수 덧셈
    (101, 'nat_add_1d_1d_nc', '자연수 덧셈', '1자리 + 1자리 (받아올림 없음)', '합이 9 이하인 두 한 자리 자연수의 덧셈', '3 + 5 = 8', 1.0, 1.0, array['자연수의 사칙계산', '덧셈과 뺄셈의 세로셈']),
    (102, 'nat_add_1d_1d_c1', '자연수 덧셈', '1자리 + 1자리 (받아올림 있음)', '합이 10 이상이 되어 십의 자리로 받아올림이 생기는 한 자리 덧셈', '7 + 8 = 15', 1.5, 1.5, array['자연수의 사칙계산', '덧셈과 뺄셈의 세로셈']),
    (103, 'nat_add_2d_1d_nc', '자연수 덧셈', '2자리 + 1자리 (받아올림 없음)', '일의 자리 합이 9 이하인 두 자리 수와 한 자리 수의 덧셈', '23 + 5 = 28', 1.5, 1.5, array['자연수의 사칙계산', '덧셈과 뺄셈의 세로셈']),
    (104, 'nat_add_2d_1d_c1', '자연수 덧셈', '2자리 + 1자리 (받아올림 1회)', '일의 자리에서 십의 자리로 받아올림이 1회 발생하는 덧셈', '27 + 6 = 33', 2.2, 2.2, array['자연수의 사칙계산', '덧셈과 뺄셈의 세로셈']),
    (105, 'nat_add_2d_1d_c2', '자연수 덧셈', '2자리 + 1자리 (연속 받아올림 2회)', '일의 자리 받아올림으로 십의 자리까지 10이 넘어 백의 자리로 넘어가는 덧셈', '96 + 7 = 103', 2.8, 2.8, array['자연수의 사칙계산', '덧셈과 뺄셈의 세로셈']),
    (106, 'nat_add_2d_2d_nc', '자연수 덧셈', '2자리 + 2자리 (받아올림 없음)', '일의 자리와 십의 자리 모두 받아올림이 없는 두 자리 수끼리의 덧셈', '32 + 45 = 77', 2.0, 2.0, array['덧셈과 뺄셈의 세로셈', '자연수의 사칙계산']),
    (107, 'nat_add_2d_2d_c1', '자연수 덧셈', '2자리 + 2자리 (받아올림 1회)', '일의 자리 또는 십의 자리 중 한 곳에서만 받아올림이 발생하는 두 자리 덧셈', '38 + 25 = 63', 3.0, 3.0, array['덧셈과 뺄셈의 세로셈', '자연수의 사칙계산']),
    (108, 'nat_add_2d_2d_c2', '자연수 덧셈', '2자리 + 2자리 (받아올림 2회)', '일의 자리와 십의 자리 모두에서 연속으로 받아올림이 발생하는 두 자리 덧셈', '67 + 58 = 125', 4.0, 4.0, array['덧셈과 뺄셈의 세로셈', '자연수의 사칙계산']),
    (109, 'nat_add_3d_23d_c01', '자연수 덧셈', '3자리 + 2·3자리 (받아올림 0~1회)', '세 자리 수와 두·세 자리 수의 덧셈 중 받아올림이 1회 이하인 경우', '245 + 138 = 383', 4.2, 4.5, array['덧셈과 뺄셈의 세로셈', '자연수의 사칙계산']),
    (110, 'nat_add_3d_3d_c2p', '자연수 덧셈', '3자리 + 3자리 이상 (받아올림 2회 이상)', '세 자리 이상 수끼리의 덧셈에서 받아올림이 2회 이상 연속 발생하는 경우', '587 + 695 = 1282', 5.5, 6.0, array['덧셈과 뺄셈의 세로셈', '자연수의 사칙계산']),

    -- 2. 자연수 뺄셈
    (201, 'nat_sub_1d_1d', '자연수 뺄셈', '1자리 - 1자리', '받아내림 없는 한 자리 자연수의 뺄셈', '9 - 4 = 5', 1.0, 1.0, array['자연수의 사칙계산', '덧셈과 뺄셈의 세로셈']),
    (202, 'nat_sub_teen_1d_b1', '자연수 뺄셈', '십몇 - 1자리 (받아내림 있음)', '10~18에서 한 자리 수를 빼며 받아내림이 일어나는 기본 뺄셈', '13 - 7 = 6', 1.8, 1.8, array['자연수의 사칙계산', '덧셈과 뺄셈의 세로셈']),
    (203, 'nat_sub_2d_1d_nb', '자연수 뺄셈', '2자리 - 1자리 (받아내림 없음)', '일의 자리끼리 바로 뺄 수 있는 두 자리 수 빼기 한 자리 수', '48 - 5 = 43', 1.6, 1.5, array['자연수의 사칙계산', '덧셈과 뺄셈의 세로셈']),
    (204, 'nat_sub_2d_1d_b1', '자연수 뺄셈', '2자리 - 1자리 (받아내림 1회)', '십의 자리에서 10을 빌려와 빼는 두 자리 수 빼기 한 자리 수', '52 - 7 = 45', 2.5, 2.5, array['덧셈과 뺄셈의 세로셈', '자연수의 사칙계산']),
    (205, 'nat_sub_2d_2d_nb', '자연수 뺄셈', '2자리 - 2자리 (받아내림 없음)', '각 자리마다 받아내림 없이 바로 빼는 두 자리 수끼리의 뺄셈', '76 - 34 = 42', 2.2, 2.2, array['덧셈과 뺄셈의 세로셈', '자연수의 사칙계산']),
    (206, 'nat_sub_2d_2d_b1', '자연수 뺄셈', '2자리 - 2자리 (받아내림 1회)', '십의 자리에서 10을 받아내려 일의 자리를 계산하는 두 자리 뺄셈', '63 - 28 = 35', 3.5, 3.5, array['덧셈과 뺄셈의 세로셈', '자연수의 사칙계산']),
    (207, 'nat_sub_3d_23d_b01', '자연수 뺄셈', '3자리 - 2·3자리 (받아내림 0~1회)', '세 자리 수의 뺄셈 중 받아내림이 없거나 한 자리에서만 일어나는 경우', '452 - 127 = 325', 4.5, 4.5, array['덧셈과 뺄셈의 세로셈', '자연수의 사칙계산']),
    (208, 'nat_sub_3d_3d_b2', '자연수 뺄셈', '3자리 - 2·3자리 (연속 받아내림 2회)', '일의 자리와 십의 자리에서 연달아 받아내림이 일어나는 세 자리 뺄셈', '623 - 278 = 345', 6.0, 6.0, array['덧셈과 뺄셈의 세로셈', '자연수의 사칙계산']),
    (209, 'nat_sub_zero_chain', '자연수 뺄셈', '0이 있는 자리 건너뛰어 받아내림 (100, 300 등)', '십의 자리가 0이어서 백의 자리에서 9, 10으로 쪼개 받아내리는 뺄셈(실수 다발)', '300 - 147 = 153', 6.5, 6.5, array['덧셈과 뺄셈의 세로셈', '자연수의 사칙계산']),

    -- 3. 자연수 곱셈
    (301, 'nat_mul_1d_1d', '자연수 곱셈', '1자리 × 1자리 (구구단 기본)', '구구단 한 단위로 즉시 나오는 곱셈', '6 × 8 = 48', 1.2, 1.2, array['자연수의 사칙계산']),
    (302, 'nat_mul_pow10', '자연수 곱셈', '자연수에 10, 100, 1000 곱하기', '자릿수 끝에 0을 붙여 계산하는 곱셈', '34 × 100 = 3400', 1.2, 1.0, array['자연수에 10, 100, 1000 곱하기', '자연수의 사칙계산']),
    (303, 'nat_mul_2d_1d_nc', '자연수 곱셈', '2자리 × 1자리 (받아올림 없음)', '일의 자리와 십의 자리 곱에서 모두 받아올림이 없는 곱셈', '23 × 3 = 69', 2.5, 2.5, array['자연수의 사칙계산']),
    (304, 'nat_mul_2d_1d_c1', '자연수 곱셈', '2자리 × 1자리 (받아올림 1회)', '일의 자리 곱에서 십의 자리로 올림이 1회 더해지는 곱셈', '17 × 4 = 68', 3.5, 3.5, array['자연수의 사칙계산']),
    (305, 'nat_mul_2d_1d_c2', '자연수 곱셈', '2자리 × 1자리 (십·일의 자리 모두 올림)', '일의 자리와 십의 자리 곱 모두 10을 넘어 세 자리 수가 되는 곱셈', '48 × 6 = 288', 4.5, 4.5, array['자연수의 사칙계산']),
    (306, 'nat_mul_3d_1d', '자연수 곱셈', '3자리 × 1자리', '세 자리 수에 한 자리 수를 곱하는 부분곱 3회 연산', '247 × 5 = 1235', 5.5, 5.5, array['자연수의 사칙계산']),
    (307, 'nat_mul_2d_2d_light', '자연수 곱셈', '2자리 × 2자리 (받아올림이 적은 경우)', '각 자리 숫자가 작아 부분곱과 합산에서 받아올림이 0~1회인 두 자리 곱셈', '12 × 23 = 276', 6.0, 6.5, array['자연수의 사칙계산']),
    (308, 'nat_mul_2d_2d_heavy', '자연수 곱셈', '2자리 × 2자리 (다중 받아올림 세로셈)', '두 부분곱과 자릿수 합산에서 모두 받아올림이 발생하는 두 자리 곱셈', '47 × 68 = 3196', 8.0, 9.0, array['자연수의 사칙계산']),
    (309, 'nat_mul_3d_2d', '자연수 곱셈', '3자리 × 2자리', '세 자리 수와 두 자리 수의 세로셈 곱셈', '236 × 45 = 10620', 10.5, 12.0, array['자연수의 사칙계산']),
    (310, 'nat_mul_3d_3d', '자연수 곱셈', '3자리 × 3자리 이상', '부분곱 3줄 이상을 더해야 하는 고부하 곱셈', '324 × 157 = 50868', 15.0, 18.0, array['자연수의 사칙계산']),

    -- 4. 자연수 나눗셈
    (401, 'nat_div_table_exact', '자연수 나눗셈', '구구단 범위 나눗셈 (나누어떨어짐)', '구구단 역연산으로 한 번에 몫이 나오는 나눗셈', '56 ÷ 7 = 8', 1.5, 1.5, array['자연수의 사칙계산']),
    (402, 'nat_div_table_rem', '자연수 나눗셈', '구구단 범위 나눗셈 (나머지 있음)', '몫 한 자리와 나머지를 뺄셈으로 구하는 나눗셈', '50 ÷ 8 = 6 ⋯ 2', 2.2, 2.2, array['자연수의 사칙계산']),
    (403, 'nat_div_2d_1d_no_drop', '자연수 나눗셈', '2자리 ÷ 1자리 (십의 자리 나누어떨어짐)', '십의 자리와 일의 자리가 각각 독립적으로 나누어떨어지는 나눗셈', '84 ÷ 4 = 21', 3.0, 3.0, array['자연수의 사칙계산']),
    (404, 'nat_div_2d_1d_drop_exact', '자연수 나눗셈', '2자리 ÷ 1자리 (십의 자리 내림 있음, 나누어떨어짐)', '십의 자리 나머지를 일의 자리로 내려 나누어떨어지는 나눗셈', '72 ÷ 6 = 12', 4.2, 4.5, array['자연수의 사칙계산']),
    (405, 'nat_div_2d_1d_drop_rem', '자연수 나눗셈', '2자리 ÷ 1자리 (내림 + 나머지 있음)', '십의 자리 내림 후 일의 자리에서도 나머지가 남는 나눗셈', '85 ÷ 6 = 14 ⋯ 1', 5.0, 5.0, array['자연수의 사칙계산']),
    (406, 'nat_div_3d_1d', '자연수 나눗셈', '3자리 ÷ 1자리', '세 자리 수를 한 자리 수로 나누는 다단계 세로셈 나눗셈', '438 ÷ 6 = 73', 6.0, 6.5, array['자연수의 사칙계산']),
    (407, 'nat_div_23d_2d_q1', '자연수 나눗셈', '2·3자리 ÷ 2자리 (몫 1자리 어림잡기)', '두 자리 나누는 수의 몫을 어림잡아 곱하고 빼는 나눗셈', '156 ÷ 26 = 6', 6.5, 7.0, array['자연수의 사칙계산']),
    (408, 'nat_div_34d_2d_q2p', '자연수 나눗셈', '3·4자리 ÷ 2자리 (몫 2자리 이상)', '두 자리 수로 두 번 이상 몫을 어림잡고 내려 계산하는 나눗셈', '864 ÷ 24 = 36', 9.5, 11.0, array['자연수의 사칙계산']),

    -- 5. 약수·배수·소인수분해
    (501, 'num_divisibility_235', '약수·배수·소인수분해', '2, 3, 5의 배수 판별 및 1회 소수 나눗셈', '일의 자리나 각 자리 합으로 2, 3, 5 인수를 찾아 한 번 나누기', '45 ÷ 3 = 15', 2.0, 2.0, array['소수로 나누어 소인수분해하는 방법', '소인수분해하는 방법']),
    (502, 'num_divisibility_7_11_13', '약수·배수·소인수분해', '7, 11, 13, 17 등 소인수 시험 나눗셈', '2, 3, 5로 안 나누어떨어져 7, 11, 13 등으로 직접 나누어 소인수를 찾는 과정', '91 = 7 × 13', 4.0, 4.5, array['소수로 나누어 소인수분해하는 방법', '소인수분해하는 방법']),
    (503, 'num_prime_factor_2d', '약수·배수·소인수분해', '두 자리 자연수 소인수분해 완주', '두 자리 합성수를 소수의 거듭제곱 곱으로 끝까지 분해', '72 = 2³ × 3²', 4.0, 4.5, array['소인수분해하는 방법', '소수로 나누어 소인수분해하는 방법']),
    (504, 'num_prime_factor_3d', '약수·배수·소인수분해', '세 자리 이상 자연수 소인수분해 완주', '100 이상의 자연수를 소인수분해하여 지수 꼴로 정리', '360 = 2³ × 3² × 5', 6.5, 7.5, array['소인수분해하는 방법', '소수로 나누어 소인수분해하는 방법']),
    (505, 'num_divisor_count_list', '약수·배수·소인수분해', '약수 모두 구하기 / 지수로 약수의 개수 계산', '소인수분해 지수에 1을 더해 곱하거나 약수 짝을 모두 나열', '(3+1)(2+1) = 12개', 3.5, 3.5, array['소인수분해를 이용하여 약수의 개수 구하기', '소인수분해를 이용하여 약수 구하기']),
    (506, 'num_gcd_2nums', '약수·배수·소인수분해', '두 수의 최대공약수(GCD) 구하기', '공약수 나눗셈 또는 소인수분해로 두 수의 최대공약수 산출', 'gcd(24, 36) = 12', 4.0, 4.5, array['공약수로 나누어 최대공약수 구하기', '소인수분해를 이용하여 최대공약수 구하기']),
    (507, 'num_lcm_2nums', '약수·배수·소인수분해', '두 수의 최소공배수(LCM) 구하기', '공약수 나눗셈 후 몫까지 곱해 최소공배수 산출', 'lcm(12, 18) = 36', 4.5, 5.0, array['공약수로 나누어 최소공배수 구하기', '소인수분해를 이용하여 최소공배수 구하기']),
    (508, 'num_gcd_lcm_3nums', '약수·배수·소인수분해', '세 수의 최대공약수·최소공배수 구하기', '세 수를 동시에 나누거나 둘씩 나누어 최소공배수·최대공약수 산출', 'lcm(8, 12, 15) = 120', 6.5, 7.5, array['공약수로 나누어 최소공배수 구하기', '소인수분해를 이용하여 최소공배수 구하기']),

    -- 6. 분수 연산
    (601, 'frac_mixed_improper', '분수 연산', '대분수 ↔ 가분수 변환', '대분수를 가분수로 고치거나 가분수를 대분수로 바꾸는 변환', '2와 3/4 = 11/4', 2.0, 2.0, array['대분수를 가분수로 나타내기', '분수의 계산']),
    (602, 'frac_reduce_easy', '분수 연산', '약분 (2, 3, 5 등 한눈에 보이는 공약수)', '짝수·5단·3단 등 직관적인 공약수로 분자·분모를 1회 약분', '6/8 = 3/4', 2.0, 2.0, array['약분', '기약분수와 약분']),
    (603, 'frac_reduce_hard', '분수 연산', '약분 (큰 소수 공약수 또는 다단계 약분)', '7, 13, 17 등의 공약수이거나 큰 수를 여러 번 나누어 기약분수로 약분', '51/68 = 3/4', 3.8, 4.0, array['약분', '기약분수와 약분']),
    (604, 'frac_add_sub_same_denom', '분수 연산', '분모가 같은 진분수·가분수 덧뺄셈', '통분 없이 분자끼리만 더하거나 빼는 기본 분수 연산', '5/7 - 2/7 = 3/7', 1.8, 1.8, array['분수의 덧셈과 뺄셈', '분수의 계산']),
    (605, 'frac_add_mixed_carry', '분수 연산', '대분수 덧셈 (진분수 부분 받아올림)', '진분수 부분의 합이 1 이상이 되어 자연수 부분으로 1을 올리는 덧셈', '1과 3/5 + 2와 4/5 = 4와 2/5', 3.2, 3.5, array['분수의 덧셈과 뺄셈', '분수의 계산']),
    (606, 'frac_sub_mixed_borrow', '분수 연산', '대분수 뺄셈 (자연수에서 1 받아내림)', '진분수끼리 뺄 수 없어 자연수에서 1을 분모만큼 빌려와 빼는 뺄셈', '3과 1/4 - 1과 3/4 = 1과 2/4', 4.0, 4.5, array['분수의 덧셈과 뺄셈', '분수의 계산']),
    (607, 'frac_common_multiple', '분수 연산', '통분 (한 분모가 다른 분모의 배수)', '한쪽 분수에만 자연수를 곱해 공통분모를 맞추는 가벼운 통분', '1/3 + 1/6 = 2/6 + 1/6', 3.0, 3.0, array['통분', '분모가 다른 두 분수의 덧셈']),
    (608, 'frac_common_coprime', '분수 연산', '통분 (두 분모가 서로소 — 교차 곱셈)', '두 분모의 곱을 공통분모로 삼고 대각선으로 분자를 곱하는 통분', '2/3 + 3/4 = 8/12 + 9/12', 4.5, 4.5, array['통분', '분모가 다른 두 분수의 덧셈']),
    (609, 'frac_common_lcm', '분수 연산', '통분 (최소공배수를 구해 양쪽 분자·분모 곱하기)', '배수도 서로소도 아닌 두 분모의 최소공배수를 구해 각각 곱하는 통분', '5/12 - 7/18 = 15/36 - 14/36', 6.0, 6.5, array['통분', '분모가 다른 두 분수의 덧셈']),
    (610, 'frac_common_3terms', '분수 연산', '세 개 이상 분수의 동시 통분', '세 분모의 최소공배수를 구해 세 분수를 한꺼번에 통분', '1/2 + 2/3 - 3/4 = 6/12 + 8/12 - 9/12', 8.0, 9.0, array['통분', '분수가 있는 식을 모아서 계산하기']),
    (611, 'frac_mul_basic', '분수 연산', '분수의 곱셈 (약분 없음 또는 1회 단순 약분)', '분모는 분모끼리, 분자는 분자끼리 곱하는 기본 분수 곱셈', '2/3 × 4/5 = 8/15', 3.0, 3.0, array['분수의 곱셈', '분수의 곱셈과 약분']),
    (612, 'frac_mul_cross_cancel', '분수 연산', '분수의 곱셈 (대각선 다중 약분 포함)', '곱하기 전에 분자·분모를 대각선으로 2회 이상 약분한 뒤 곱하는 연산', '8/15 × 25/12 = 10/9', 4.5, 5.0, array['분수의 곱셈과 약분', '분수의 곱셈']),
    (613, 'frac_div_reciprocal', '분수 연산', '분수의 나눗셈 (역수 변환 후 곱셈·약분)', '나누는 분수를 역수로 뒤집어 곱셈으로 고친 뒤 약분·계산', '4/9 ÷ 2/3 = 4/9 × 3/2 = 2/3', 4.5, 5.0, array['분수의 나눗셈과 역수', '역수를 이용한 분수의 나눗셈']),

    -- 7. 소수 및 분수·소수 혼합 연산
    (701, 'dec_shift_pow10', '소수 연산', '소수에 10, 100, 1000 곱하기·나누기', '소수점 자리를 오른쪽이나 왼쪽으로 옮기는 연산', '3.45 × 10 = 34.5', 1.5, 1.5, array['소수에 10, 100, 1000 곱하기', '소수의 곱셈']),
    (702, 'dec_add_sub_same_len', '소수 연산', '소수점 아래 자릿수가 같은 소수 덧뺄셈', '소수점 위치를 맞춰 같은 자릿수끼리 더하거나 빼는 연산', '2.4 + 1.8 = 4.2', 2.5, 2.5, array['소수의 덧셈과 뺄셈']),
    (703, 'dec_add_sub_diff_len', '소수 연산', '소수점 아래 자릿수가 다른 소수 덧뺄셈', '빈 끝자리에 0을 채워 자릿수를 맞춘 뒤 받아올림·내림하는 소수 덧뺄셈', '5.2 - 1.37 = 3.83', 3.8, 4.0, array['소수의 덧셈과 뺄셈']),
    (704, 'dec_mul_nat', '소수 연산', '소수 × 자연수', '자연수처럼 곱한 뒤 소수점 위치를 찍는 연산', '2.7 × 4 = 10.8', 3.8, 4.0, array['소수의 곱셈']),
    (705, 'dec_mul_dec', '소수 연산', '소수 × 소수', '두 소수의 자릿수를 합산해 곱의 소수점 자리를 정하는 연산', '1.4 × 0.25 = 0.35', 5.5, 6.0, array['소수의 곱셈']),
    (706, 'dec_div_nat', '소수 연산', '소수 ÷ 자연수 (나눗셈 후 몫에 소수점 찍기)', '피제수의 소수점 위치에 맞춰 몫의 소수점을 올려 찍는 나눗셈', '7.2 ÷ 6 = 1.2', 4.5, 5.0, array['소수의 나눗셈']),
    (707, 'dec_div_dec', '소수 연산', '소수 ÷ 소수 (소수점 동시 이동 후 나눗셈)', '나누는 수를 자연수로 만들기 위해 양쪽 소수점을 같이 옮긴 뒤 나누는 연산', '4.32 ÷ 1.2 = 43.2 ÷ 12 = 3.6', 6.5, 7.5, array['소수의 나눗셈']),
    (708, 'dec_to_frac_conv', '소수 연산', '유한소수 ↔ 분수 변환 후 혼합 계산', '소수를 10, 100 분모 분수로 고쳐 약분하거나 분수를 소수로 고치는 변환', '0.35 = 35/100 = 7/20', 3.2, 3.5, array['소수를 분수로 나타내기', '분수와 소수의 덧셈과 뺄셈']),
    (709, 'dec_repeating_to_frac', '소수 연산', '순환소수를 분수로 변환 (9, 90, 99 공식 또는 10^n차)', '순환마디 자릿수에 맞춰 분모를 9, 90, 99 등으로 놓고 약분하는 연산', '0.1222... = (12-1)/90 = 11/90', 4.5, 5.0, array['공식을 이용하여 순환소수를 분수로 나타내기', '10의 거듭제곱을 이용하여 순환소수를 분수로 나타내기']),

    -- 8. 정수와 유리수 부호 연산
    (801, 'sign_abs_compare', '정수·유리수 부호 연산', '절댓값 계산 및 음수끼리의 대소 비교', '절댓값 기호를 벗기거나 음수는 절댓값이 클수록 작다는 규칙 적용', '|-5| = 5, -3 > -7', 2.0, 2.0, array['부호가 같은 두 수의 덧셈', '부호가 다른 두 수의 덧셈']),
    (802, 'sign_add_same', '정수·유리수 부호 연산', '부호가 같은 두 정수의 덧셈', '공통 부호를 붙이고 두 수의 절댓값을 더하는 연산', '(-4) + (-9) = -13', 1.8, 1.8, array['부호가 같은 두 수의 덧셈']),
    (803, 'sign_add_diff', '정수·유리수 부호 연산', '부호가 다른 두 정수의 덧셈 (절댓값 차 + 부호 결정)', '절댓값이 큰 쪽의 부호를 붙이고 절댓값의 차를 구하는 연산', '(-8) + (+5) = -3', 2.8, 2.8, array['부호가 다른 두 수의 덧셈']),
    (804, 'sign_sub_flip', '정수·유리수 부호 연산', '음수의 뺄셈 부호 변환 (빼는 수의 부호 바꾸기)', 'a - (-b) = a + (+b) 처럼 뺄셈을 덧셈으로 바꾸고 뒤의 부호를 뒤집는 연산', '(-3) - (-7) = (-3) + (+7) = 4', 2.5, 2.5, array['수의 뺄셈', '덧셈과 뺄셈의 혼합 계산']),
    (805, 'sign_add_sub_chain', '정수·유리수 부호 연산', '부호가 생략된 셋 이상 정수의 덧뺄셈 혼합', '양수끼리, 음수끼리 모아서 합산한 뒤 마지막에 부호 차이를 계산', '-4 + 9 - 7 + 2 = 0', 4.2, 4.5, array['부호가 생략된 수의 덧셈과 뺄셈', '덧셈과 뺄셈의 혼합 계산']),
    (806, 'sign_frac_add_sub', '정수·유리수 부호 연산', '부호가 있는 유리수(분수)의 통분 + 부호 덧뺄셈', '통분과 동시에 음수 부호 및 절댓값의 차를 처리하는 복합 분수 연산', '(-2/3) - (-3/4) = -8/12 + 9/12 = 1/12', 6.5, 7.0, array['덧셈과 뺄셈의 혼합 계산', '부호가 다른 두 수의 덧셈']),
    (807, 'sign_mul_div_pair', '정수·유리수 부호 연산', '부호가 있는 두 수의 곱셈·나눗셈', '두 수의 부호 일치 여부로 전체 부호(+, -)를 정하고 절댓값을 곱하거나 나눔', '(-6) × (-4) = +24', 2.0, 2.0, array['부호가 같은 두 수의 곱셈', '부호가 다른 두 수의 곱셈']),
    (808, 'sign_mul_div_chain', '정수·유리수 부호 연산', '셋 이상 유리수의 곱셈·나눗셈 혼합 (음수 개수 판별 + 역수 약분)', '음수의 개수가 홀수/짝수인지 세어 전체 부호를 정하고 역수로 고쳐 일괄 약분', '(-3/4) ÷ (-9/8) × (-2) = -4/3', 5.5, 6.0, array['곱셈과 나눗셈의 혼합 계산', '셋 이상의 수의 곱셈']),
    (809, 'sign_mixed_4ops', '정수·유리수 부호 연산', '정수·유리수의 사칙혼합계산 (거듭제곱 → 괄호 → 곱나눗셈 → 덧뺄셈)', '계산 순서를 지켜 거듭제곱과 괄호, 곱나눗셈, 덧뺄셈을 차례로 정리', '2 - (-3)² × (1/3 - 1) = 8', 8.5, 10.0, array['덧셈, 뺄셈, 곱셈, 나눗셈의 혼합 계산']),

    -- 9. 거듭제곱·지수법칙·제곱근
    (901, 'pow_nat_basic', '거듭제곱·제곱근', '자연수의 기본 거듭제곱 계산 (2^n, 3^n 등)', '자연수를 여러 번 곱한 거듭제곱 값을 계산', '2⁴ = 16, 3³ = 27', 2.0, 2.0, array['반복된 곱을 거듭제곱으로 나타내기']),
    (902, 'pow_neg_sign_trap', '거듭제곱·제곱근', '음수의 거듭제곱 부호 판별 ((-a)^n vs -a^n)', '괄호 안팎의 음수 부호와 지수의 홀짝을 구별하여 부호 결정(오답 다발)', '(-2)³ = -8, -2² = -4, (-2)² = +4', 3.2, 3.0, array['셋 이상의 수의 곱셈', '반복된 곱을 거듭제곱으로 나타내기']),
    (903, 'pow_frac_dec', '거듭제곱·제곱근', '분수·소수의 거듭제곱 계산', '분모와 분자를 각각 거듭제곱하거나 소수를 거듭제곱', '(-2/3)³ = -8/27', 3.5, 3.5, array['반복된 곱을 거듭제곱으로 나타내기']),
    (904, 'exp_law_add_sub', '거듭제곱·제곱근', '지수법칙 — 밑이 같은 거듭제곱의 곱·몫 (지수 덧뺄셈)', 'a^m × a^n = a^(m+n) 또는 나눗셈에서 지수의 차 계산', 'x³ × x⁵ ÷ x² = x⁶', 2.2, 2.0, array['밑이 같은 거듭제곱끼리 모아 계산하기']),
    (905, 'exp_law_power_dist', '거듭제곱·제곱근', '지수법칙 — 거듭제곱의 거듭제곱 및 괄호 안 곱·몫 분배', '(a^m)^n = a^(mn), (ab)^n = a^n b^n 으로 지수를 각 인수에 곱해 분배', '(-2x²y)³ = -8x⁶y³', 2.8, 2.5, array['밑이 같은 거듭제곱끼리 모아 계산하기', '단항식의 곱셈']),
    (906, 'sqrt_simplify_out', '거듭제곱·제곱근', '제곱인 인수를 근호 밖으로 꺼내기 (√(a²b) = a√b)', '근호 안의 수를 소인수분해하여 제곱 인수를 근호 밖 계수로 추출', '√48 = √(16×3) = 4√3', 3.5, 3.5, array['근호 안의 제곱인 수를 밖으로 꺼내기', '제곱인 수를 이용하여 근호 없애기']),
    (907, 'sqrt_bring_in', '거듭제곱·제곱근', '근호 밖의 양수를 제곱하여 근호 안으로 넣기', '대소 비교나 약분을 위해 a√b = √(a²b)로 변형', '3√2 = √18', 2.8, 2.8, array['근호 밖의 양수를 안에 넣기']),
    (908, 'sqrt_mul_div', '거듭제곱·제곱근', '제곱근의 곱셈·나눗셈', '근호 안의 수끼리 곱하거나 나누고 제곱 인수를 밖으로 정리', '√6 × √15 = √90 = 3√10', 3.2, 3.2, array['제곱근의 곱셈과 나눗셈의 혼합 계산', '제곱근의 성질을 이용한 식의 계산']),
    (909, 'sqrt_rationalize_mono', '거듭제곱·제곱근', '분모의 유리화 — 단항 무리수 분모 (a/√b)', '분모·분자에 같은 제곱근 √b를 곱해 분모를 유리수로 만들고 약분', '6/√3 = 6√3/3 = 2√3', 3.5, 3.5, array['분모가 하나의 제곱근인 식의 유리화', '근호 안을 간단히 한 후 분모를 유리화하기']),
    (910, 'sqrt_rationalize_binom', '거듭제곱·제곱근', '분모의 유리화 — 이항 무리수 분모 (합차공식 켤레 곱하기)', '분모가 √a±√b 일 때 분모·분자에 √a∓√b를 곱해 합차공식으로 유리화', '1/(√3-√2) = √3+√2', 6.0, 6.5, array['분모가 두 제곱근의 합이나 차인 식의 유리화', '곱셈 공식을 이용한 분모의 유리화']),
    (911, 'sqrt_add_sub_like', '거듭제곱·제곱근', '제곱근의 덧셈·뺄셈 (근호 정리 후 동류근호 계산)', '각 항의 근호 안을 가장 작은 자연수로 정리한 뒤 같은 제곱근끼리 계수 덧뺄셈', '√12 + √27 - √3 = 2√3 + 3√3 - √3 = 4√3', 5.0, 5.5, array['제곱근의 덧셈과 뺄셈', '근호 안의 수를 간단히 하거나 분모를 유리화한 후 덧셈과 뺄셈하기']),

    -- 10. 문자와 식 · 다항식 · 인수분해
    (1001, 'alg_subst_pos', '다항식·전개·인수분해', '문자에 양수·정수 대입하여 식의 값 계산', '부호 변화나 역수 번분수 없이 양의 정수를 대입해 계산', 'x=3일 때 2x - 1 = 5', 2.5, 2.5, array['식의 값을 구하는 방법']),
    (1002, 'alg_subst_neg_frac', '다항식·전개·인수분해', '문자에 음수·분수 대입 (괄호 씌워 부호·역수 처리)', '음수나 분수를 대입할 때 반드시 괄호를 씌워 거듭제곱 부호나 분모 나눗셈을 처리', 'x=-2일 때 -x² + 3x = -4 - 6 = -10', 4.2, 4.5, array['식의 값을 구하는 방법', '분모에 분수를 대입하는 방법']),
    (1003, 'alg_mono_mul_div', '다항식·전개·인수분해', '단항식의 곱셈·나눗셈 혼합 (계수 약분 + 문자별 지수 정리)', '숫자 계수끼리 부호·약분 처리하고 각 문자의 지수를 모으는 연산', '6x³y ÷ (-2xy²) × 3y = -9x²', 4.5, 5.0, array['단항식의 곱셈과 나눗셈의 혼합 계산', '단항식의 곱셈']),
    (1004, 'alg_combine_like_1d', '다항식·전개·인수분해', '일차식의 동류항 묶어 덧셈·뺄셈 정리', '문자항은 문자항끼리, 상수항은 상수항끼리 모아 계수를 계산', '3x - 5 - 7x + 2 = -4x - 3', 2.5, 2.5, array['동류항의 덧셈과 뺄셈', '일차식의 덧셈과 뺄셈']),
    (1005, 'alg_combine_like_poly', '다항식·전개·인수분해', '이차식·다항식의 차수별 동류항 덧뺄셈', '이차항, 일차항, 상수항 등 여러 차수의 동류항을 찾아 각각 계수 정리', '(2x²-3x+1) + (x²+5x-4) = 3x²+2x-3', 3.5, 3.8, array['다항식의 덧셈과 뺄셈 계산 방법', '이차식의 덧셈과 뺄셈']),
    (1006, 'alg_dist_pos', '다항식·전개·인수분해', '분배법칙 괄호 풀기 (양수 계수 분배)', '괄호 앞의 양수 또는 양의 단항식을 각 항에 곱해 전개', '3(2x - 5) = 6x - 15', 2.5, 2.5, array['분배법칙을 이용한 괄호 풀기', '단항식과 다항식의 곱셈']),
    (1007, 'alg_dist_neg', '다항식·전개·인수분해', '분배법칙 괄호 풀기 (음수 부호·음수 계수 분배 — 부호 반전)', '괄호 앞의 마이너스(-)나 음수 계수를 각 항에 곱하며 안쪽 부호를 모두 반전', '-2(3x - 4) = -6x + 8', 3.8, 4.0, array['괄호 앞의 부호에 따라 괄호 풀기', '분배법칙을 이용한 괄호 풀기']),
    (1008, 'alg_frac_poly_common', '다항식·전개·인수분해', '분수 꼴 다항식의 통분 및 분자 괄호 전개 (등식이 아닌 식 정리)', '양변에 곱해 없앨 수 없는 식에서 공통분모로 통분하고 분자 괄호 앞 음수를 분배', '(2x-1)/3 - (x-3)/2 = (4x-2-3x+9)/6 = (x+7)/6', 6.5, 7.0, array['계수가 분수인 일차식의 덧셈과 뺄셈', '유리식의 통분']),
    (1009, 'alg_poly_expand_general', '다항식·전개·인수분해', '다항식 × 다항식 일반 분배 전개', '각 항을 차례로 곱해 전개한 뒤 동류항을 모으는 연산', '(x+2)(2x²-x+3) = 2x³+3x²+x+6', 5.0, 5.5, array['다항식과 다항식의 곱셈 방법', '다항식의 곱셈 방법']),
    (1010, 'alg_mul_formula_basic', '다항식·전개·인수분해', '곱셈공식 적용 전개 (완전제곱식·합차공식·일차식 곱)', '(a±b)², (a+b)(a-b), (x+a)(x+b) 공식을 적용해 전개', '(2x-3)² = 4x² - 12x + 9', 3.8, 4.0, array['다항식의 곱셈 방법', '곱셈 공식의 변형을 이용하여 식의 값 구하기']),
    (1011, 'alg_mul_formula_transform', '다항식·전개·인수분해', '곱셈공식 변형 계산 (합과 곱으로 제곱합·세제곱합 구하기)', 'a+b와 ab 값으로 a²+b², (a-b)², a³+b³ 등을 변형식에 대입해 계산', 'a²+b² = (a+b)² - 2ab', 5.5, 6.0, array['곱셈 공식의 변형을 이용하여 식의 값 구하기', '두 수의 합 또는 차와 곱이 주어진 경우의 계산']),
    (1012, 'alg_factor_common_square', '다항식·전개·인수분해', '인수분해 — 공통인수 묶기 / 완전제곱식 / 합차공식', '공통인수로 묶거나 제곱의 차·완전제곱식 형태를 바로 인수분해', '3x² - 12 = 3(x+2)(x-2)', 3.8, 4.0, array['공통인 인수를 이용한 인수분해', '항이 두 개인 제곱 형태의 인수분해']),
    (1013, 'alg_factor_cross_2d', '다항식·전개·인수분해', '인수분해 — 이차식 대각선(합과 곱) 인수 찾기', 'x²+px+q 또는 ax²+bx+c에서 두 수의 곱과 대각선 합을 맞춰 인수분해', '2x² + 5x - 3 = (2x-1)(x+3)', 5.5, 6.0, array['대각선 방향의 곱을 이용한 인수분해 방법', '합과 곱을 이용하여 두 정수를 찾는 인수분해 방법']),
    (1014, 'alg_poly_div_synthetic', '다항식·전개·인수분해', '다항식 직접 나눗셈 / 조립제법 및 고차식 인수분해', '다항식을 다항식으로 직접 나누거나 조립제법으로 몫과 나머지·인수를 구하는 연산', '조립제법으로 x³-4x+3 = (x-1)(x²+x-3) 분해', 7.5, 8.5, array['조립제법으로 몫과 나머지를 구하는 방법', '인수정리와 조립제법을 이용한 인수분해']),

    -- 11. 방정식 · 부등식 변형
    (1101, 'eq_transpose', '방정식·부등식 변형', '이항 (부호 바꾸어 좌변·우변으로 항 옮기기)', '미지수 항은 좌변으로, 상수항은 우변으로 부호를 바꾸어 이동', '3x - 7 = x + 5 → 3x - x = 5 + 7', 2.0, 2.0, array['일차방정식의 풀이', '등식의 성질을 이용한 방정식의 풀이']),
    (1102, 'eq_divide_coeff', '방정식·부등식 변형', '양변을 미지수의 계수로 나누어 해 구하기 (ax = b → x = b/a)', '정리된 일차식 ax = b의 양변을 a로 나누고 기약분수로 약분', '-4x = 10 → x = -5/2', 2.2, 2.0, array['방정식 ax=b의 풀이', '일차방정식의 풀이']),
    (1103, 'eq_clear_frac_dec', '방정식·부등식 변형', '방정식·부등식의 양변에 최소공배수·10^n을 곱해 계수 정수화', '분수·소수 계수를 없애기 위해 모든 항(상수항 포함)에 같은 수를 곱하는 변형', '0.2x - 1/3 = 1 의 양변에 30 곱하기', 4.5, 4.5, array['계수가 분수인 일차방정식의 풀이', '계수가 소수인 일차방정식의 풀이']),
    (1104, 'ineq_neg_flip', '방정식·부등식 변형', '부등식 양변에 음수를 곱하거나 나눌 때 부등호 방향 반전', '음수 계수로 나누면서 부등호 방향(< ↔ >)을 뒤집는 연산(실수 최다 구간)', '-3x > 12 → x < -4', 3.5, 3.0, array['계수의 부호에 따른 부등식 ax>b의 풀이', '일차부등식의 풀이']),
    (1105, 'sys_elim_2x2', '방정식·부등식 변형', '연립일차방정식 가감법 (계수 맞춘 뒤 두 식 더하기·빼기)', '한 미지수를 소거하기 위해 식에 상수를 곱하고 두 식을 더하거나 빼는 연산', '2x+3y=7, x-y=1 → 5y=5 → y=1, x=2', 5.5, 6.0, array['가감법을 이용한 연립방정식의 풀이']),
    (1106, 'sys_subst_2x2', '방정식·부등식 변형', '연립방정식 대입법 (한 문자 정리 후 다른 식에 대입·전개)', 'y = ax+b 꼴의 식을 다른 방정식에 괄호 쳐서 대입하고 전개해 푸는 연산', 'y = 2x-1 을 3x - 2y = 4 에 대입', 6.0, 6.5, array['대입법을 이용한 연립방정식의 풀이']),
    (1107, 'quad_complete_square', '방정식·부등식 변형', '이차식·이차방정식의 완전제곱식 변형 (a(x-p)²+q 또는 (x-p)²=q)', '일차항 계수의 절반의 제곱을 더하고 빼서 완전제곱식 표준형으로 고치는 연산', 'x² - 6x + 2 = (x-3)² - 7', 6.0, 6.5, array['완전제곱식을 이용한 이차방정식의 풀이', '완전제곱식을 만드는 방법']),
    (1108, 'quad_formula', '방정식·부등식 변형', '이차방정식 근의 공식(짝수 공식 포함) 대입 및 근호 약분', 'x = (-b ± √(b²-4ac)) / 2a 에 계수를 대입하고 판별식과 근호를 정리', 'x² - 4x + 1 = 0 → x = 2 ± √3', 6.5, 7.5, array['이차방정식의 풀이 절차']),
    (1109, 'abs_eq_ineq_split', '방정식·부등식 변형', '절댓값 방정식·부등식의 부호 벗기기 및 구간 해 구하기', '|ax+b| = c 또는 < c, > c 를 풀어 양쪽 경계를 계산', '|2x - 3| < 5 → -4 < x < 4', 5.5, 6.0, array['절댓값 기호를 포함한 방정식의 풀이', '절댓값 기호를 포함한 일차부등식을 구간을 나누어 풀기']),

    -- 12. 고등 식·복소수·로그·벡터·구조 부하
    (1201, 'high_complex_ops', '고등 식·복소수·로그·벡터', '복소수 사칙연산 및 분모의 실수화 (i² = -1 정리)', '실수부와 허수부를 나누어 계산하거나 분모·분자에 켤레복소수를 곱해 실수화', '(1+2i)/(1-i) = (-1+3i)/2', 5.0, 5.5, array['복소수의 나눗셈과 분모의 실수화', '복소수의 곱셈']),
    (1202, 'high_rational_partial_complex', '고등 식·복소수·로그·벡터', '유리식의 부분분수 분해 및 번분수식 정리', '1/(AB) = (1/(B-A))(1/A - 1/B) 변형 또는 분모·분자에 식을 곱해 번분수 정리', '1/(x(x+1)) = 1/x - 1/(x+1)', 6.5, 7.0, array['부분분수로 변형하는 방법', '번분수식의 계산']),
    (1203, 'high_log_exp_calc', '고등 식·복소수·로그·벡터', '유리수 지수 및 로그 성질 계산 (밑 변환·진수 곱나눗셈)', '로그의 합·차를 진수의 곱·몫으로 합치거나 밑 변환 공식을 적용해 계산', 'log₂3 × log₃4 = 2', 5.0, 5.5, array['밑이 다른 로그의 밑을 같게 하는 방법', '거듭제곱근을 유리수 지수로 변형하는 방법']),
    (1204, 'high_vector_comp_ops', '고등 식·복소수·로그·벡터', '평면·공간벡터의 성분 덧뺄셈·실수배·크기·내적 계산', '성분별로 실수배·덧뺄셈을 하거나 √(x²+y²) 크기 및 내적(x₁x₂+y₁y₂) 계산', '(2, -1)·(3, 4) = 6 - 4 = 2', 4.0, 4.5, array['평면벡터의 성분에 의한 덧셈', '평면벡터의 성분에 의한 실수배']),
    (1205, 'high_matrix_ops', '고등 식·복소수·로그·벡터', '행렬의 덧뺄셈·실수배 및 행렬 곱셈', '성분별 연산 또는 행과 열의 내적을 반복하는 행렬 곱셈 계산', '2×2 행렬의 곱셈', 6.0, 7.0, array['행렬의 곱의 계산 방법', '행렬의 덧셈·뺄셈·실수배의 계산']),
    (1206, 'struct_nested_brackets', '고등 식·복소수·로그·벡터', '중첩 괄호 풀기 (소괄호 → 중괄호 → 대괄호 순차 정리)', '소괄호 안부터 풀고 동류항을 정리한 뒤 중괄호·대괄호를 차례로 벗기는 구조 부하', '3x - {2x - (x - 5)} 정리', 3.5, 4.0, array['여러 괄호를 푸는 순서', '괄호가 있는 식의 계산 순서']),
    (1207, 'struct_frac_intermediate', '고등 식·복소수·로그·벡터', '중간 계산값이 정수로 떨어지지 않고 분수·소수로 이어지는 부하', '중간 해나 대입값이 분수(예: x = -7/3)여서 다음 단계 연산이 모두 분수로 진행되는 가중치', 'x = -5/3 을 다음 식에 대입', 3.5, 4.0, array['분수가 있는 식을 모아서 계산하기', '계수가 분수인 일차방정식의 풀이'])
)
insert into public.arithmetic_primitives
  (code, category, title, criteria, example_expr, unit_score, est_seconds, concept_id, synced_concept_md5, sort_order, is_active)
select
  s.code,
  s.category,
  s.title,
  s.criteria,
  s.example_expr,
  s.unit_score,
  s.est_seconds,
  cid.id,
  case when cid.id is not null then public.arithmetic_concept_md5(cid.id) else null end,
  s.sort_order,
  true
from raw_seed s
left join lateral (
  select public._arithmetic_find_concept(s.concept_names) as id
) cid on true
on conflict (code) do update
  set category = excluded.category,
      title = excluded.title,
      criteria = excluded.criteria,
      example_expr = excluded.example_expr,
      concept_id = coalesce(public.arithmetic_primitives.concept_id, excluded.concept_id),
      synced_concept_md5 = coalesce(public.arithmetic_primitives.synced_concept_md5, excluded.synced_concept_md5),
      sort_order = excluded.sort_order;

notify pgrst, 'reload schema';


