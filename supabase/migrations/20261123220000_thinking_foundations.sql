-- 20261123220000: 수학적 사고의 토대(C) 체계 구축
--
-- 전체 수학 교육 체계:
--   A. 지식 (개념 라이브러리 concepts / 연산 사전 arithmetic_primitives)
--   B. 사고 (사고 사전 thinking_primitives: frame 범용 사고틀 24개 · algorithm 실전 알고리즘 22개 / B3 사고 조절)
--   C. 사고의 토대 (thinking_foundations 12개 · thinking_foundation_examples 36개)
--      - C1 사고의 규범 (4), C2 판단의 규범 (4), C3 탐구의 태도 (4)
--      - 난이도 점수를 부여하지 않으며, 기존 A·B 데이터 및 3축 난이도 산출과 분리한다.
--
-- 포함 내역:
--   1) thinking_foundations (12개 마스터) + thinking_foundation_examples (개별 예시 36개, 개념·문항 확장 열 포함)
--   2) 마스터 조회·저장·삭제 RPC (thinking_foundation_overview / _save / _delete)
--   3) 초기 시드 등록 (C1-01 ~ C3-12 12개 역량 및 개별 예시 36개, 중복 삽입 방지)
--   4) 문항 연결:
--      - 확정 테이블 pb_question_foundation_links + 조회·저장 RPC (pb_question_foundation_links_list / _set)
--      - 문항검수 스테이징 컬럼 textbook_problem_analyses.foundation_links + textbook_review_set_foundations
--      - textbook_review_unit_overview / textbook_review_apply_staged 연동 (C3 정적 문항 직접 측정 금지 규칙 포함)
--   5) 학생 행동 관찰:
--      - student_foundation_observations (파티션 대비 규칙 및 퇴원 정리 _purge_withdrawn_student_step 등록)
--      - learning_log_foundation_observation / student_foundation_observations_recent RPC

-- ─────────────────────────────────────────────────────────────────────────
-- 1) 사고의 토대(C) 마스터 및 예시 테이블
-- ─────────────────────────────────────────────────────────────────────────

create table if not exists public.thinking_foundations (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (btrim(code) <> '' and char_length(code) <= 40),
  domain text not null default 'C' check (domain = 'C'),
  group_code text not null check (group_code in ('C1', 'C2', 'C3')),
  group_title text not null check (btrim(group_title) <> '' and char_length(group_title) <= 60),
  title text not null check (btrim(title) <> '' and char_length(title) <= 160),
  definition text not null default '' check (char_length(definition) <= 2000),
  learning_goals text[] not null default '{}'::text[],
  teaching_principle text not null default '' check (char_length(teaching_principle) <= 1000),
  observation_criteria text not null default '' check (char_length(observation_criteria) <= 2000),
  keywords text[] not null default '{}'::text[],
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists thinking_foundations_group_sort_idx
  on public.thinking_foundations (group_code, sort_order, code);

alter table public.thinking_foundations enable row level security;

drop policy if exists thinking_foundations_select on public.thinking_foundations;
create policy thinking_foundations_select on public.thinking_foundations
  for select to authenticated
  using (true);

revoke all on public.thinking_foundations from anon;
revoke insert, update, delete, truncate on public.thinking_foundations from authenticated;
grant select on public.thinking_foundations to authenticated;

create table if not exists public.thinking_foundation_examples (
  id uuid primary key default gen_random_uuid(),
  foundation_id uuid not null references public.thinking_foundations(id) on delete cascade,
  example_order integer not null check (example_order >= 1 and example_order <= 1000),
  content text not null check (btrim(content) <> '' and char_length(content) <= 2000),
  related_concept_ids uuid[] not null default '{}'::uuid[],
  related_question_ids uuid[] not null default '{}'::uuid[],
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint thinking_foundation_examples_ord_uniq unique (foundation_id, example_order)
);

create index if not exists thinking_foundation_examples_foundation_idx
  on public.thinking_foundation_examples (foundation_id, example_order);

alter table public.thinking_foundation_examples enable row level security;

drop policy if exists thinking_foundation_examples_select on public.thinking_foundation_examples;
create policy thinking_foundation_examples_select on public.thinking_foundation_examples
  for select to authenticated
  using (true);

revoke all on public.thinking_foundation_examples from anon;
revoke insert, update, delete, truncate on public.thinking_foundation_examples from authenticated;
grant select on public.thinking_foundation_examples to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 2) 마스터·예시 조회 / 저장 / 삭제 RPC
-- ─────────────────────────────────────────────────────────────────────────

create or replace function public.thinking_foundation_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'thinking_foundation_forbidden';
  end if;

  return jsonb_build_object(
    'items', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', f.id,
          'code', f.code,
          'domain', f.domain,
          'group_code', f.group_code,
          'group_title', f.group_title,
          'title', f.title,
          'definition', f.definition,
          'learning_goals', to_jsonb(coalesce(f.learning_goals, '{}'::text[])),
          'teaching_principle', f.teaching_principle,
          'observation_criteria', f.observation_criteria,
          'keywords', to_jsonb(coalesce(f.keywords, '{}'::text[])),
          'sort_order', f.sort_order,
          'is_active', f.is_active,
          'updated_at', f.updated_at,
          'examples', coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'id', ex.id,
                'example_order', ex.example_order,
                'content', ex.content,
                'related_concept_ids', to_jsonb(coalesce(ex.related_concept_ids, '{}'::uuid[])),
                'related_question_ids', to_jsonb(coalesce(ex.related_question_ids, '{}'::uuid[]))
              ) order by ex.example_order
            )
            from public.thinking_foundation_examples ex
            where ex.foundation_id = f.id
          ), '[]'::jsonb)
        )
        order by f.group_code, f.sort_order, f.code
      )
      from public.thinking_foundations f
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.thinking_foundation_save(
  p_id uuid,
  p_code text,
  p_group_code text,
  p_title text,
  p_definition text,
  p_learning_goals text[],
  p_teaching_principle text,
  p_observation_criteria text,
  p_keywords text[],
  p_examples jsonb,
  p_sort_order integer default 0,
  p_is_active boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group_title text;
  v_row public.thinking_foundations;
  v_goals text[];
  v_keywords text[];
  v_ord integer := 0;
  v_item jsonb;
  v_content text;
  v_ex_id uuid;
  v_kept_ids uuid[] := '{}'::uuid[];
  v_concepts uuid[];
  v_questions uuid[];
begin
  if not (select public.is_superadmin()) then
    raise exception 'thinking_foundation_forbidden';
  end if;

  v_group_title := case btrim(coalesce(p_group_code, ''))
    when 'C1' then '사고의 규범'
    when 'C2' then '판단의 규범'
    when 'C3' then '탐구의 태도'
    else null
  end;
  if v_group_title is null then
    raise exception 'thinking_foundation_bad_group';
  end if;

  if btrim(coalesce(p_code, '')) = '' or btrim(coalesce(p_title, '')) = '' then
    raise exception 'thinking_foundation_missing_required';
  end if;

  select coalesce(array_agg(btrim(g) order by ord), '{}'::text[])
    into v_goals
    from unnest(coalesce(p_learning_goals, '{}'::text[])) with ordinality as u(g, ord)
   where btrim(g) <> '';

  select coalesce(array_agg(distinct btrim(k)), '{}'::text[])
    into v_keywords
    from unnest(coalesce(p_keywords, '{}'::text[])) as u(k)
   where btrim(k) <> '';

  if p_id is null then
    insert into public.thinking_foundations (
      code, domain, group_code, group_title, title, definition,
      learning_goals, teaching_principle, observation_criteria,
      keywords, sort_order, is_active, updated_at
    )
    values (
      btrim(p_code), 'C', btrim(p_group_code), v_group_title, btrim(p_title),
      coalesce(btrim(p_definition), ''),
      v_goals,
      coalesce(btrim(p_teaching_principle), ''),
      coalesce(btrim(p_observation_criteria), ''),
      v_keywords,
      coalesce(p_sort_order, 0),
      coalesce(p_is_active, true),
      now()
    )
    returning * into v_row;
  else
    update public.thinking_foundations
       set code = btrim(p_code),
           group_code = btrim(p_group_code),
           group_title = v_group_title,
           title = btrim(p_title),
           definition = coalesce(btrim(p_definition), ''),
           learning_goals = v_goals,
           teaching_principle = coalesce(btrim(p_teaching_principle), ''),
           observation_criteria = coalesce(btrim(p_observation_criteria), ''),
           keywords = v_keywords,
           sort_order = coalesce(p_sort_order, sort_order),
           is_active = coalesce(p_is_active, is_active),
           updated_at = now()
     where id = p_id
    returning * into v_row;

    if not found then
      raise exception 'thinking_foundation_not_found';
    end if;
  end if;

  if p_examples is not null and jsonb_typeof(p_examples) = 'array' then
    update public.thinking_foundation_examples
       set example_order = example_order + 100
     where foundation_id = v_row.id
       and example_order <= 100;

    for v_item in select value from jsonb_array_elements(p_examples) loop
      if jsonb_typeof(v_item) = 'string' then
        v_content := btrim(v_item #>> '{}');
        v_ex_id := null;
        v_concepts := null;
        v_questions := null;
      elsif jsonb_typeof(v_item) = 'object' then
        v_content := btrim(coalesce(v_item ->> 'content', ''));
        begin
          v_ex_id := nullif(btrim(coalesce(v_item ->> 'id', '')), '')::uuid;
        exception when others then
          v_ex_id := null;
        end;
        if jsonb_typeof(v_item -> 'related_concept_ids') = 'array' then
          select coalesce(array_agg(distinct x::uuid), '{}'::uuid[])
            into v_concepts
            from jsonb_array_elements_text(v_item -> 'related_concept_ids') as x
           where btrim(x) <> '';
        else
          v_concepts := null;
        end if;
        if jsonb_typeof(v_item -> 'related_question_ids') = 'array' then
          select coalesce(array_agg(distinct x::uuid), '{}'::uuid[])
            into v_questions
            from jsonb_array_elements_text(v_item -> 'related_question_ids') as x
           where btrim(x) <> '';
        else
          v_questions := null;
        end if;
      else
        continue;
      end if;

      if v_content = '' then
        continue;
      end if;

      v_ord := v_ord + 1;
      if v_ord > 20 then
        exit;
      end if;

      if v_ex_id is not null and exists (
        select 1 from public.thinking_foundation_examples
         where id = v_ex_id and foundation_id = v_row.id
      ) then
        update public.thinking_foundation_examples
           set example_order = v_ord,
               content = v_content,
               related_concept_ids = coalesce(v_concepts, related_concept_ids),
               related_question_ids = coalesce(v_questions, related_question_ids),
               updated_at = now()
         where id = v_ex_id and foundation_id = v_row.id;
      else
        insert into public.thinking_foundation_examples (
          foundation_id, example_order, content, related_concept_ids, related_question_ids, updated_at
        )
        values (
          v_row.id, v_ord, v_content,
          coalesce(v_concepts, '{}'::uuid[]),
          coalesce(v_questions, '{}'::uuid[]),
          now()
        )
        returning id into v_ex_id;
      end if;

      v_kept_ids := array_append(v_kept_ids, v_ex_id);
    end loop;

    delete from public.thinking_foundation_examples
     where foundation_id = v_row.id
       and not (id = any (v_kept_ids));
  end if;

  return to_jsonb(v_row);
end;
$$;

create or replace function public.thinking_foundation_delete(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not (select public.is_superadmin()) then
    raise exception 'thinking_foundation_forbidden';
  end if;
  delete from public.thinking_foundations where id = p_id;
  return jsonb_build_object('deleted', found, 'id', p_id);
end;
$$;

revoke all on function public.thinking_foundation_overview() from public, anon;
grant execute on function public.thinking_foundation_overview() to authenticated;
revoke all on function public.thinking_foundation_save(uuid, text, text, text, text, text[], text, text, text[], jsonb, integer, boolean) from public, anon;
grant execute on function public.thinking_foundation_save(uuid, text, text, text, text, text[], text, text, text[], jsonb, integer, boolean) to authenticated;
revoke all on function public.thinking_foundation_delete(uuid) from public, anon;
grant execute on function public.thinking_foundation_delete(uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 3) 초기 시드 데이터 (C1-01 ~ C3-12 12개 역량 + 개별 예시 36개)
-- ─────────────────────────────────────────────────────────────────────────

insert into public.thinking_foundations (
  code, domain, group_code, group_title, title, definition,
  learning_goals, teaching_principle, observation_criteria, keywords, sort_order, is_active
)
values
  -- C1. 사고의 규범
  (
    'C1-01', 'C', 'C1', '사고의 규범', '의미의 명확성',
    '수학에서 사용하는 기호, 용어, 대상, 관계가 무엇을 의미하는지 분명하게 인식하고 사용하는 태도.',
    array[
      '의미를 모호하게 이해한 상태에서 풀이를 진행하지 않는다.',
      '일상적인 의미와 수학적인 의미를 구별한다.',
      '기호와 용어의 의미를 스스로 설명할 수 있다.'
    ],
    '지금 사용한 말이나 기호가 정확히 무엇을 의미하지?',
    '학생이 기호나 용어를 사용할 때 그 의미를 명확히 인식하고 있는지 관찰한다.',
    array['기호', '용어', '정의', '근', '역함수', '역수', '모든 실수', '어떤 실수', '양화사'],
    1, true
  ),
  (
    'C1-02', 'C', 'C1', '사고의 규범', '조건의 존중',
    '문제에서 주어진 조건과 수학적 대상의 성립 조건을 임의로 무시하거나 변경하지 않는 태도.',
    array[
      '문제에 명시된 조건을 끝까지 유지한다.',
      '계산 과정에서 생기는 제약을 인식한다.',
      '편리한 풀이를 위해 조건을 임의로 없애지 않는다.'
    ],
    '지금 계산이 원래 조건에서도 허용되는가?',
    '문제의 조건을 알고도 풀이 과정에서 누락하거나 무시하는 행동이 있는지 살펴본다. 단, 학생이 조건 자체를 이해하지 못했다면 우선 A의 지식 부족으로 판단해야 한다.',
    array['성립 조건', '정의역', '분모 0', '무리식', '영인자', '제약 조건'],
    2, true
  ),
  (
    'C1-03', 'C', 'C1', '사고의 규범', '기준의 일관성',
    '한번 설정한 정의, 기준, 규칙을 논리적 정당화 없이 임의로 바꾸지 않는 태도.',
    array[
      '동일한 조건에서 동일한 판단 기준을 적용한다.',
      '문제 해결 중 판단 기준이 달라졌는지 확인한다.',
      '예외를 인정하려면 그에 대한 근거를 제시한다.'
    ],
    '처음에 정했던 기준을 지금도 똑같이 적용하고 있는가?',
    '학생이 특정 결과를 얻기 위해 규칙이나 판단 기준을 임의로 변경하지 않는지 확인한다.',
    array['일관성', '판단 기준', '규칙 유지', '부등호 방향', '범위 유지', '경우 분류'],
    3, true
  ),
  (
    'C1-04', 'C', 'C1', '사고의 규범', '표현의 정확성',
    '자신의 수학적 생각을 기호, 식, 문장, 그림 등으로 표현할 때 실제 의미와 논리적 관계가 왜곡되지 않도록 하는 태도.',
    array[
      '등호와 부등호의 의미를 구별한다.',
      '수학적 표현을 정확하게 연결한다.',
      '생략으로 인해 의미가 달라지지 않도록 한다.'
    ],
    '내가 적은 표현이 내가 생각한 내용을 정확히 나타내는가?',
    '표현상의 부정확성이 단순한 표기 실수인지, 실제 의미의 혼동인지 구별하여 관찰한다.',
    array['등호', '부등호', '근삿값', '단위', '식 서술', '기호 표현'],
    4, true
  ),

  -- C2. 판단의 규범
  (
    'C2-05', 'C', 'C2', '판단의 규범', '근거 중심 판단',
    '자신이나 타인의 주장을 단순한 권위, 직관, 인상이 아니라 수학적으로 타당한 근거를 바탕으로 판단하는 태도.',
    array[
      '답과 그 답의 근거를 구별한다.',
      '주장을 뒷받침하는 이유를 찾는다.',
      '근거가 부족하면 결론을 보류할 수 있다.'
    ],
    '왜 그렇게 생각하는가? 무엇이 그것을 보장하는가?',
    '학생이 자신의 판단을 설명할 때 타당한 근거를 제시하려는지 살펴본다.',
    array['근거', '정당화', '증명', '정리 활용', '논증', '직관 경계'],
    5, true
  ),
  (
    'C2-06', 'C', 'C2', '판단의 규범', '일반화의 절제',
    '일부 사례에서 발견된 규칙을 충분한 근거 없이 모든 경우에 성립하는 법칙으로 확장하지 않는 태도.',
    array[
      '사례 관찰과 일반적인 증명을 구별한다.',
      '주장이 성립하는 범위를 확인한다.',
      '일반화하기 전에 추가적인 검증이나 증명이 필요한지 판단한다.'
    ],
    '몇 가지 사례에서 맞는다는 것이 모든 경우에서 맞는다는 뜻인가?',
    '학생이 경험적으로 발견한 패턴을 증명된 사실과 구별하는지 관찰한다.',
    array['성급한 일반화', '귀납 추측', '일반적 증명', '성립 범위', '사례와 법칙'],
    6, true
  ),
  (
    'C2-07', 'C', 'C2', '판단의 규범', '반례의 수용',
    '자신의 주장과 모순되는 사례가 발견되었을 때, 그 사례가 유효하다면 기존 주장을 수정하거나 폐기하는 태도.',
    array[
      '반례가 갖는 논리적 의미를 이해한다.',
      '기존 생각과 다른 증거를 무시하지 않는다.',
      '반례에 따라 주장의 적용 범위를 수정한다.'
    ],
    '이 반례가 성립한다면 내 원래 주장은 어떻게 바뀌어야 하는가?',
    '학생이 타당한 반례를 접했을 때 기존 주장에 집착하지 않고 그 의미를 검토하는지 살펴본다.',
    array['반례', '거짓 명제', '주장 수정', '모순', '절댓값', '적용 범위'],
    7, true
  ),
  (
    'C2-08', 'C', 'C2', '판단의 규범', '검증의 책임',
    '자신이 얻은 결론이 원래 문제의 조건과 요구를 만족하는지 확인해야 한다는 원칙을 인식하고 실천하는 태도.',
    array[
      '계산 결과와 최종 답의 타당성을 구별한다.',
      '필요할 때 결과를 원래 조건에 대입한다.',
      '풀이 과정에서 누락한 조건이나 경우가 없는지 확인한다.'
    ],
    '계산이 끝났다는 사실과 답이 옳다는 사실은 같은가?',
    '학생이 필요한 검증을 수행하는지, 검증을 생략했을 때 그 이유가 무엇인지 살펴본다.',
    array['검산', '무연근', '대입 확인', '타당성 점검', '최종 검증', '범위 적합성'],
    8, true
  ),

  -- C3. 탐구의 태도
  (
    'C3-09', 'C', 'C3', '탐구의 태도', '지적 자율성',
    '교사나 교재의 권위에만 의존하지 않고, 스스로 이해한 수학적 근거에 따라 판단하려는 태도.',
    array[
      '타인의 주장을 무조건 수용하지 않는다.',
      '스스로 판단한 근거를 설명한다.',
      '필요하다면 교사에게도 합리적으로 반박할 수 있다.'
    ],
    '누가 말했는지가 아니라 왜 옳은지가 중요하다.',
    '학생이 타인의 판단을 검토하고 자신의 판단을 근거에 따라 표현하는지 관찰한다. 다른 사람에게 반대하는 빈도 자체를 자율성 점수로 사용하지 않는다.',
    array['자율적 판단', '합리적 반박', '다른 풀이 검증', '근거 기반 동의'],
    9, true
  ),
  (
    'C3-10', 'C', 'C3', '탐구의 태도', '불확실성의 인정과 질문',
    '자신이 이해하지 못한 부분이나 아직 확인하지 못한 내용을 인정하고, 그 불확실성을 구체적인 질문으로 표현하려는 태도.',
    array[
      '알고 있는 것과 모르는 것을 구별한다.',
      '이해하지 못한 부분을 구체화한다.',
      '충분한 근거가 없을 때 판단을 유보할 수 있다.'
    ],
    '모르는 것이 있다면 정확히 무엇을 모르는지 설명할 수 있는가?',
    '학생이 불확실성을 표현하고 구체적인 확인 행동으로 연결하는지 관찰한다. 질문의 양이나 말의 유창성만으로 평가하지 않는다.',
    array['메타인지', '구체적 질문', '모르는 지점 특정', '판단 유보', '적용 조건 확인'],
    10, true
  ),
  (
    'C3-11', 'C', 'C3', '탐구의 태도', '오류 수용과 수정',
    '자신의 오류를 발견했을 때 이를 부정하거나 회피하지 않고, 원인을 분석하여 생각과 풀이를 수정하려는 태도.',
    array[
      '오류를 학습에 활용한다.',
      '잘못된 첫 단계를 찾아낸다.',
      '오류를 수정한 후 수정 이유를 설명한다.'
    ],
    '틀렸다는 사실보다 어디서 왜 틀렸는지가 중요하다.',
    '오류 발견 이후 학생이 보이는 반응과 실제 수정 행동을 관찰한다. 정답으로 수정했다는 사실만으로 오류의 원인을 이해했다고 판단하지 않는다.',
    array['오답 분석', '오류 원인', '첫 오류 단계', '교정 이유 설명'],
    11, true
  ),
  (
    'C3-12', 'C', 'C3', '탐구의 태도', '유연한 지속성',
    '어려운 문제를 해결하기 위해 사고를 지속하되, 현재 방법이 비효율적이거나 막혔다면 필요에 따라 다른 방법으로 전환하는 태도.',
    array[
      '어려운 상황에서 즉시 포기하지 않는다.',
      '막힌 원인을 탐색한다.',
      '필요하면 표현, 접근 방식, 해결 전략을 바꾼다.'
    ],
    '계속 생각한다는 것은 같은 방법만 반복한다는 뜻이 아니다.',
    '학생이 어려운 상황에서 어떤 시도를 했고, 어떤 이유로 지속하거나 전략을 변경했는지 살펴본다. 무조건 오래 붙잡는 행동을 높은 수준의 지속성으로 평가하지 않는다.',
    array['전략 전환', '끈기', '대안 탐색', '보조선', '작은 값 조사', '사고 조절'],
    12, true
  )
on conflict (code) do nothing;

with seed_examples(code, example_order, content) as (
  values
    -- C1-01 의미의 명확성
    ('C1-01', 1, E'방정식의 ''근''이 단순히 계산으로 얻은 숫자가 아니라, 원래 방정식을 만족하는 값이라는 사실을 설명한다.'),
    ('C1-01', 2, E'\\(f^{-1}(x)\\)가 역함수를 나타낸다는 사실과 \\(1/f(x)\\)가 역수를 나타낸다는 사실을 구별한다.'),
    ('C1-01', 3, E'''모든 실수''라는 표현과 ''어떤 실수''라는 표현이 논리적으로 다르다는 사실을 설명한다.'),

    -- C1-02 조건의 존중
    ('C1-02', 1, E'\\(\\frac{x^2-1}{x-1}=2\\)에서 \\(x=1\\)은 원래 식이 정의되지 않으므로 해로 인정하지 않는다.'),
    ('C1-02', 2, E'\\(\\sqrt{x-3}\\)이 실수 범위에서 정의되려면 \\(x\\ge3\\)이어야 한다는 조건을 확인한다.'),
    ('C1-02', 3, E'방정식의 양변을 \\(x\\)로 나누기 전에 \\(x=0\\)인 경우가 가능한지 검토한다.'),

    -- C1-03 기준의 일관성
    ('C1-03', 1, E'물건의 개수를 셀 때 한 물건을 한 번만 세는 규칙을 끝까지 유지한다.'),
    ('C1-03', 2, E'부등식의 양변을 음수로 나눌 때 부등호 방향을 바꾸는 규칙을 일관되게 적용한다.'),
    ('C1-03', 3, E'어떤 함수의 정의역을 정해 놓았다면, 중간 계산에서 그 범위를 임의로 확장하지 않는다.'),

    -- C1-04 표현의 정확성
    ('C1-04', 1, E'\\(x=2\\)와 \\(x\\approx2\\)를 구별하여 정확한 값과 근삿값을 혼동하지 않는다.'),
    ('C1-04', 2, E'등호를 단순히 ''다음 계산''이라는 의미로 사용하지 않고, 양쪽이 같다는 의미로 사용한다.'),
    ('C1-04', 3, E'길이가 2m인 물체와 30cm인 물체의 길이를 더할 때 단위를 맞추어 정확히 표현한다.'),

    -- C2-05 근거 중심 판단
    ('C2-05', 1, E'두 짝수의 합이 짝수라는 사실을 몇 가지 계산 결과만으로 주장하지 않고, \\(2a+2b=2(a+b)\\)로 설명한다.'),
    ('C2-05', 2, E'삼각형의 두 각이 같다면 그 대변의 길이가 같다는 사실을 관련 정리에 근거하여 설명한다.'),
    ('C2-05', 3, E'선생님이 어떤 답을 제시해도 그 답이 원래 조건을 만족하는지 확인한 후 받아들인다.'),

    -- C2-06 일반화의 절제
    ('C2-06', 1, E'\\(1+3=4\\), \\(3+5=8\\), \\(5+7=12\\)를 확인한 뒤 연속된 두 홀수의 합이 4의 배수라는 규칙을 추측하되, 세 사례만으로 증명되었다고 주장하지 않는다.'),
    ('C2-06', 2, E'몇 개의 이차함수 그래프가 위로 볼록하다고 해서 모든 이차함수가 위로 볼록하다고 일반화하지 않는다.'),
    ('C2-06', 3, E'어떤 수열의 처음 네 항이 일정한 규칙을 따른다고 하더라도, 이후 모든 항에 같은 규칙이 적용된다는 추가 조건이 있는지 확인한다.'),

    -- C2-07 반례의 수용
    ('C2-07', 1, E'''모든 소수는 홀수다''라는 주장에 대해 소수 2가 반례임을 확인하고 원래 주장을 수정한다.'),
    ('C2-07', 2, E'''모든 실수 \\(x\\)에 대해 \\(x^2\\ge x\\)''라는 주장에 \\(x=\\frac12\\)을 대입하여 반례를 확인하고 기존 주장을 철회한다.'),
    ('C2-07', 3, E'\\(\\sqrt{a^2}=a\\)가 모든 실수에서 성립한다는 주장에 \\(a=-3\\)을 대입하여 오류를 확인하고 \\(\\sqrt{a^2}=|a|\\)로 수정한다.'),

    -- C2-08 검증의 책임
    ('C2-08', 1, E'\\(\\sqrt{x+1}=x-1\\)을 제곱하여 얻은 후보 \\(x=0,3\\) 중 원래 식을 만족하는 \\(x=3\\)만 해로 인정한다.'),
    ('C2-08', 2, E'연립방정식을 풀어 얻은 순서쌍을 원래 두 방정식에 대입하여 확인한다.'),
    ('C2-08', 3, E'경우를 나누어 얻은 해들이 각 경우의 범위 조건을 만족하는지 마지막에 다시 점검한다.'),

    -- C3-09 지적 자율성
    ('C3-09', 1, E'선생님이 일부러 잘못 계산한 결과를 제시했을 때, 자신의 근거를 들어 오류를 설명한다.'),
    ('C3-09', 2, E'정답지의 풀이와 자신의 풀이가 다르더라도 자신의 방법이 타당한지 검증한다.'),
    ('C3-09', 3, E'친구들이 모두 같은 답을 제시하더라도 자신이 발견한 반례를 근거로 다른 의견을 제시한다.'),

    -- C3-10 불확실성의 인정과 질문
    ('C3-10', 1, E'''문제를 모르겠어요''라고 말하는 대신 ''이 식에서 왜 양변을 나누어도 되는지 모르겠어요''라고 질문한다.'),
    ('C3-10', 2, E'문제를 풀다가 어떤 정리를 적용할 수 있을지 확신이 없으면, 먼저 그 정리의 적용 조건을 확인한다.'),
    ('C3-10', 3, E'답은 구했지만 특정 변형의 정당성을 설명할 수 없다면, 그 부분에 대한 확신이 부족함을 스스로 인정한다.'),

    -- C3-11 오류 수용과 수정
    ('C3-11', 1, E'부등식에서 음수를 곱한 뒤 부등호 방향을 바꾸지 않은 실수를 발견하면, 잘못 적용한 규칙을 찾아 수정한다.'),
    ('C3-11', 2, E'함수의 정의역을 누락한 사실을 발견하면 계산 결과만 고치는 것이 아니라 풀이 과정에서 조건 확인이 빠진 지점을 찾아낸다.'),
    ('C3-11', 3, E'반례로 자신의 주장이 틀렸음이 드러나면, 주장 전체 또는 적용 범위를 수정하고 그 이유를 설명한다.'),

    -- C3-12 유연한 지속성
    ('C3-12', 1, E'복잡한 연립방정식의 계산이 계속 어려워지면, 변수를 제거하는 순서나 다른 대입 방법을 검토한다.'),
    ('C3-12', 2, E'도형 문제에서 식으로 관계를 표현하기 어려우면, 보조선을 추가하거나 그림을 다시 구성해 본다.'),
    ('C3-12', 3, E'일반적인 규칙을 찾기 어렵다면 작은 값부터 조사하거나 표로 정리하여 새로운 접근을 시도한다.')
)
insert into public.thinking_foundation_examples (foundation_id, example_order, content)
select f.id, s.example_order, s.content
  from seed_examples s
  join public.thinking_foundations f on f.code = s.code
on conflict (foundation_id, example_order) do nothing;

-- ─────────────────────────────────────────────────────────────────────────
-- 4) 문항 분석 C 역량 연결 (문제은행 + 문항검수 스테이징/확정 연동)
-- ─────────────────────────────────────────────────────────────────────────

create table if not exists public.pb_question_foundation_links (
  id uuid primary key default gen_random_uuid(),
  question_id uuid not null references public.pb_questions(id) on delete cascade,
  academy_id uuid not null references public.academies(id) on delete cascade,
  foundation_id uuid not null references public.thinking_foundations(id) on delete cascade,
  relevance_level text not null default 'core'
    check (relevance_level in ('core', 'supplementary')),
  rationale text not null default ''
    check (char_length(rationale) <= 1000),
  observability text not null default 'process_required'
    check (observability in ('static_item', 'process_required', 'class_activity')),
  created_by uuid default auth.uid() references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint pb_question_foundation_links_uniq unique (question_id, foundation_id)
);

create index if not exists pb_question_foundation_links_question_idx
  on public.pb_question_foundation_links (question_id);
create index if not exists pb_question_foundation_links_academy_idx
  on public.pb_question_foundation_links (academy_id);
create index if not exists pb_question_foundation_links_foundation_idx
  on public.pb_question_foundation_links (foundation_id);
create index if not exists pb_question_foundation_links_created_by_idx
  on public.pb_question_foundation_links (created_by)
  where created_by is not null;

alter table public.pb_question_foundation_links enable row level security;

drop policy if exists pb_question_foundation_links_select on public.pb_question_foundation_links;
create policy pb_question_foundation_links_select on public.pb_question_foundation_links
  for select to authenticated
  using (
    (select public.is_superadmin())
    or exists (
      select 1 from public.memberships m
       where m.user_id = auth.uid()
         and m.academy_id = pb_question_foundation_links.academy_id
    )
  );

revoke all on public.pb_question_foundation_links from anon;
revoke insert, update, delete, truncate on public.pb_question_foundation_links from authenticated;
grant select on public.pb_question_foundation_links to authenticated;

create or replace function public.pb_question_foundation_links_list(
  p_question_ids uuid[]
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'pb_foundation_links_forbidden';
  end if;
  if p_question_ids is null or cardinality(p_question_ids) = 0 then
    return jsonb_build_object('items', '[]'::jsonb);
  end if;

  return jsonb_build_object(
    'items', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', l.id,
          'question_id', l.question_id,
          'foundation_id', l.foundation_id,
          'code', f.code,
          'group_code', f.group_code,
          'group_title', f.group_title,
          'title', f.title,
          'relevance_level', l.relevance_level,
          'rationale', l.rationale,
          'observability', l.observability,
          'updated_at', l.updated_at
        )
        order by l.question_id, f.group_code, f.sort_order, f.code
      )
      from public.pb_question_foundation_links l
      join public.thinking_foundations f on f.id = l.foundation_id
      where l.question_id = any (p_question_ids)
        and (
          (select public.is_superadmin())
          or exists (
            select 1 from public.memberships m
             where m.user_id = auth.uid()
               and m.academy_id = l.academy_id
          )
        )
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.pb_question_foundation_links_set(
  p_question_id uuid,
  p_links jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_question public.pb_questions;
  v_el jsonb;
  v_fid uuid;
  v_f public.thinking_foundations;
  v_rel text;
  v_obs text;
  v_rat text;
  v_kept uuid[] := '{}'::uuid[];
begin
  if auth.uid() is null then
    raise exception 'pb_foundation_links_forbidden';
  end if;

  select * into v_question from public.pb_questions where id = p_question_id;
  if not found then
    raise exception 'pb_question_not_found';
  end if;

  if not (select public.is_superadmin()) and not exists (
    select 1 from public.memberships m
     where m.user_id = auth.uid()
       and m.academy_id = v_question.academy_id
  ) then
    raise exception 'pb_foundation_links_forbidden';
  end if;

  if p_links is not null and jsonb_typeof(p_links) <> 'array' then
    raise exception 'pb_foundation_links_bad_payload';
  end if;

  for v_el in select value from jsonb_array_elements(coalesce(p_links, '[]'::jsonb)) loop
    if jsonb_typeof(v_el) <> 'object' then
      continue;
    end if;
    begin
      v_fid := nullif(btrim(coalesce(v_el ->> 'foundation_id', '')), '')::uuid;
    exception when others then
      v_fid := null;
    end;
    if v_fid is null then
      continue;
    end if;

    select * into v_f from public.thinking_foundations where id = v_fid;
    if not found then
      continue;
    end if;

    v_rel := btrim(coalesce(v_el ->> 'relevance_level', 'core'));
    if v_rel not in ('core', 'supplementary') then
      v_rel := 'core';
    end if;

    v_obs := btrim(coalesce(v_el ->> 'observability', 'process_required'));
    if v_obs not in ('static_item', 'process_required', 'class_activity') then
      v_obs := 'process_required';
    end if;
    -- 원칙: C3(탐구의 태도)는 문항 내용만으로 직접 측정·평가하지 않는다.
    if v_f.group_code = 'C3' and v_obs = 'static_item' then
      raise exception 'c3_static_observability_forbidden';
    end if;

    v_rat := left(btrim(coalesce(v_el ->> 'rationale', '')), 1000);

    insert into public.pb_question_foundation_links (
      question_id, academy_id, foundation_id, relevance_level, rationale, observability, created_by, updated_at
    )
    values (
      v_question.id, v_question.academy_id, v_f.id, v_rel, v_rat, v_obs, auth.uid(), now()
    )
    on conflict (question_id, foundation_id) do update
       set relevance_level = excluded.relevance_level,
           rationale = excluded.rationale,
           observability = excluded.observability,
           updated_at = now();

    v_kept := array_append(v_kept, v_f.id);
  end loop;

  delete from public.pb_question_foundation_links
   where question_id = v_question.id
     and not (foundation_id = any (v_kept));

  return public.pb_question_foundation_links_list(array[v_question.id]);
end;
$$;

revoke all on function public.pb_question_foundation_links_list(uuid[]) from public, anon;
grant execute on function public.pb_question_foundation_links_list(uuid[]) to authenticated;
revoke all on function public.pb_question_foundation_links_set(uuid, jsonb) from public, anon;
grant execute on function public.pb_question_foundation_links_set(uuid, jsonb) to authenticated;

-- ── 문항검수 스테이징 컬럼 및 RPC ────────────────────────────────────────

alter table public.textbook_problem_analyses
  add column if not exists foundation_links jsonb not null default '[]'::jsonb;

create or replace function public.textbook_review_set_foundations(
  p_crop_id uuid,
  p_links jsonb,
  p_source text default 'owner'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_crop public.textbook_problem_crops;
  v_src jsonb;
  v_el jsonb;
  v_fid uuid;
  v_f public.thinking_foundations;
  v_rel text;
  v_obs text;
  v_rat text;
  v_seen uuid[] := '{}'::uuid[];
  v_norm jsonb := '[]'::jsonb;
begin
  if auth.uid() is not null and not (select public.is_superadmin()) then
    raise exception 'textbook_review_forbidden';
  end if;
  if p_source not in ('ai', 'owner') then
    raise exception 'textbook_review_bad_source';
  end if;
  if p_links is not null and jsonb_typeof(p_links) <> 'array' then
    raise exception 'textbook_review_bad_patch';
  end if;

  select * into v_crop from public.textbook_problem_crops where id = p_crop_id;
  if not found then
    raise exception 'textbook_review_crop_not_found';
  end if;

  insert into public.textbook_problem_analyses (crop_id, academy_id)
  values (v_crop.id, v_crop.academy_id)
  on conflict (crop_id) do nothing;

  select coalesce(meta_sources, '{}'::jsonb) into v_src
    from public.textbook_problem_analyses
   where crop_id = p_crop_id
     for update;

  if p_source = 'ai' and v_src ->> 'foundations' = 'owner' then
    return jsonb_build_object('ok', true, 'skipped', to_jsonb(array['foundations']::text[]));
  end if;

  for v_el in select value from jsonb_array_elements(coalesce(p_links, '[]'::jsonb)) loop
    if jsonb_typeof(v_el) <> 'object' then
      continue;
    end if;
    begin
      v_fid := nullif(btrim(coalesce(v_el ->> 'foundation_id', '')), '')::uuid;
    exception when others then
      v_fid := null;
    end;
    if v_fid is null or (v_fid = any (v_seen)) then
      continue;
    end if;

    select * into v_f from public.thinking_foundations where id = v_fid;
    if not found then
      continue;
    end if;

    v_rel := btrim(coalesce(v_el ->> 'relevance_level', 'core'));
    if v_rel not in ('core', 'supplementary') then
      v_rel := 'core';
    end if;

    v_obs := btrim(coalesce(v_el ->> 'observability', 'process_required'));
    if v_obs not in ('static_item', 'process_required', 'class_activity') then
      v_obs := 'process_required';
    end if;
    if v_f.group_code = 'C3' and v_obs = 'static_item' then
      if p_source = 'owner' then
        raise exception 'c3_static_observability_forbidden';
      end if;
      v_obs := 'process_required';
    end if;

    v_rat := left(btrim(coalesce(v_el ->> 'rationale', '')), 1000);
    v_seen := array_append(v_seen, v_f.id);
    v_norm := v_norm || jsonb_build_array(
      jsonb_build_object(
        'foundation_id', v_f.id,
        'relevance_level', v_rel,
        'rationale', v_rat,
        'observability', v_obs
      )
    );
  end loop;

  if p_source = 'owner' then
    v_src := v_src || jsonb_build_object('foundations', 'owner');
  end if;

  update public.textbook_problem_analyses
     set foundation_links = v_norm,
         meta_sources = v_src,
         updated_at = now()
   where crop_id = p_crop_id;

  return jsonb_build_object('ok', true, 'count', jsonb_array_length(v_norm));
end;
$$;

revoke all on function public.textbook_review_set_foundations(uuid, jsonb, text) from public, anon;
grant execute on function public.textbook_review_set_foundations(uuid, jsonb, text) to authenticated;

-- overview 에 foundations 항목 추가 (20261117000000 의 정의 유지 + foundations 병합)
create or replace function public.textbook_review_unit_overview(
  p_academy_id uuid,
  p_book_id uuid,
  p_grade_label text,
  p_big_order int,
  p_mid_order int
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v jsonb;
begin
  v := public.textbook_review_unit_overview_base(p_academy_id, p_book_id, p_grade_label, p_big_order, p_mid_order);
  return (v - 'items') || jsonb_build_object('items', coalesce((
    select jsonb_agg(
             (public.textbook_review_overlay_staged(
                e.item || jsonb_build_object('pb_common_figure_layout', pq.meta #> '{set_model,common_figure_layout}'),
                an.staged_changes
              ) - 'findings')
               || jsonb_build_object(
                    'findings', coalesce((
                      select jsonb_agg(fx.f order by fx.ord)
                        from jsonb_array_elements(coalesce(e.item -> 'findings', '[]'::jsonb)) with ordinality as fx(f, ord)
                       where not exists (
                         select 1
                           from jsonb_array_elements(cons.list) ci
                          where ci ->> 'id' = fx.f ->> 'id'
                       )
                    ), '[]'::jsonb),
                    'consistency_issues', cons.list,
                    'concept_proposals', coalesce(an.concept_proposals, '[]'::jsonb),
                    'meta_checked_at', an.meta_checked_at,
                    'meta_sources', coalesce(an.meta_sources, '{}'::jsonb),
                    'source_correction', an.source_correction,
                    'foundations', fnd.list
                  )
             order by e.ord)
      from jsonb_array_elements(coalesce(v -> 'items', '[]'::jsonb)) with ordinality as e(item, ord)
      left join public.textbook_problem_analyses an
        on an.crop_id = (e.item ->> 'crop_id')::uuid
      left join public.pb_questions pq
        on pq.id = nullif(e.item ->> 'pb_question_id', '')::uuid
      cross join lateral (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'id', f.id,
                 'code', substr(f.check_key, length('consistency:') + 1),
                 'axis', f.axis,
                 'title', f.title,
                 'detail', f.detail,
                 'status', f.status
               ) order by f.created_at), '[]'::jsonb) as list
          from public.textbook_review_findings f
         where f.academy_id = p_academy_id
           and f.crop_id = (e.item ->> 'crop_id')::uuid
           and f.check_key <> ''
           and f.check_key like 'consistency:%'
           and f.status in ('open', 'held')
      ) cons
      cross join lateral (
        select case
          when (coalesce(an.meta_sources, '{}'::jsonb) ? 'foundations')
               or jsonb_array_length(coalesce(an.foundation_links, '[]'::jsonb)) > 0
            then coalesce((
              select jsonb_agg(
                jsonb_build_object(
                  'foundation_id', tf.id,
                  'code', tf.code,
                  'group_code', tf.group_code,
                  'group_title', tf.group_title,
                  'title', tf.title,
                  'relevance_level', coalesce(el.val ->> 'relevance_level', 'core'),
                  'rationale', coalesce(el.val ->> 'rationale', ''),
                  'observability', coalesce(el.val ->> 'observability', 'process_required')
                )
                order by tf.group_code, tf.sort_order, tf.code
              )
              from jsonb_array_elements(coalesce(an.foundation_links, '[]'::jsonb)) as el(val)
              join public.thinking_foundations tf
                on tf.id = nullif(btrim(coalesce(el.val ->> 'foundation_id', '')), '')::uuid
            ), '[]'::jsonb)
          when pq.id is not null
            then coalesce((
              select jsonb_agg(
                jsonb_build_object(
                  'foundation_id', tf.id,
                  'code', tf.code,
                  'group_code', tf.group_code,
                  'group_title', tf.group_title,
                  'title', tf.title,
                  'relevance_level', qfl.relevance_level,
                  'rationale', qfl.rationale,
                  'observability', qfl.observability
                )
                order by tf.group_code, tf.sort_order, tf.code
              )
              from public.pb_question_foundation_links qfl
              join public.thinking_foundations tf on tf.id = qfl.foundation_id
              where qfl.question_id = pq.id
            ), '[]'::jsonb)
          else '[]'::jsonb
        end as list
      ) fnd
  ), '[]'::jsonb));
end;
$$;

revoke all on function public.textbook_review_unit_overview(uuid, uuid, text, int, int) from public, anon;
grant execute on function public.textbook_review_unit_overview(uuid, uuid, text, int, int) to authenticated;

-- 소단원 확정 시 스테이징된 foundation_links 를 pb_question_foundation_links 에 반영한다.
do $$
begin
  if not exists (select 1 from pg_proc where proname = 'textbook_review_apply_staged_pre_foundations') then
    alter function public.textbook_review_apply_staged(uuid[]) rename to textbook_review_apply_staged_pre_foundations;
  end if;
end $$;

revoke all on function public.textbook_review_apply_staged_pre_foundations(uuid[]) from public, anon, authenticated;

create or replace function public.textbook_review_apply_staged(p_crop_ids uuid[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_res jsonb;
  v_row record;
  v_qid uuid;
  v_n int := 0;
begin
  if not (select public.is_superadmin()) then
    raise exception 'textbook_review_forbidden';
  end if;
  if p_crop_ids is null or cardinality(p_crop_ids) = 0 then
    return jsonb_build_object('ok', true, 'applied', 0);
  end if;

  v_res := public.textbook_review_apply_staged_pre_foundations(p_crop_ids);

  for v_row in
    select an.crop_id, an.academy_id, coalesce(an.foundation_links, '[]'::jsonb) as links
      from public.textbook_problem_analyses an
     where an.crop_id = any (p_crop_ids)
       and (
         (coalesce(an.meta_sources, '{}'::jsonb) ? 'foundations')
         or jsonb_array_length(coalesce(an.foundation_links, '[]'::jsonb)) > 0
       )
  loop
    v_qid := public.textbook_review_linked_pb_question(v_row.crop_id);
    if v_qid is null then
      continue;
    end if;

    delete from public.pb_question_foundation_links where question_id = v_qid;

    insert into public.pb_question_foundation_links (
      question_id, academy_id, foundation_id, relevance_level, rationale, observability, created_by, updated_at
    )
    select distinct on (tf.id)
           v_qid,
           v_row.academy_id,
           tf.id,
           case when coalesce(el.val ->> 'relevance_level', '') in ('core', 'supplementary')
             then el.val ->> 'relevance_level' else 'core' end,
           left(btrim(coalesce(el.val ->> 'rationale', '')), 1000),
           case
             when tf.group_code = 'C3' then
               case when coalesce(el.val ->> 'observability', '') = 'class_activity' then 'class_activity' else 'process_required' end
             when coalesce(el.val ->> 'observability', '') in ('static_item', 'process_required', 'class_activity')
               then el.val ->> 'observability'
             else 'process_required'
           end,
           auth.uid(),
           now()
      from jsonb_array_elements(v_row.links) as el(val)
      join public.thinking_foundations tf
        on tf.id = nullif(btrim(coalesce(el.val ->> 'foundation_id', '')), '')::uuid;

    v_n := v_n + 1;
  end loop;

  return v_res || jsonb_build_object('foundation_questions', v_n);
end;
$$;

revoke all on function public.textbook_review_apply_staged(uuid[]) from public, anon;
grant execute on function public.textbook_review_apply_staged(uuid[]) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 5) 학생별 C 관찰 기록 (learning-records.md §11 파티션·퇴원 삭제 규칙 준수)
-- ─────────────────────────────────────────────────────────────────────────

create table if not exists public.student_foundation_observations (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  foundation_id uuid not null references public.thinking_foundations(id) on delete restrict,
  question_id uuid references public.pb_questions(id) on delete set null,
  crop_id uuid references public.textbook_problem_crops(id) on delete set null,
  -- 기록 행(learning_attempts)을 id 단독 FK로 참조하지 않는다 (§11 규칙 2).
  attempt_id uuid,
  observation_context text not null default 'problem_solving'
    check (observation_context in (
      'problem_solving',
      'oral_explanation',
      'error_revision',
      'class_discussion',
      'homework_review',
      'other'
    )),
  observation_result text not null
    check (observation_result in (
      'practiced',
      'not_practiced',
      'insufficient',
      'no_opportunity'
    )),
  ab_prerequisite_check text not null default 'not_checked'
    check (ab_prerequisite_check in (
      'sufficient',
      'knowledge_gap',
      'thinking_skill_gap',
      'not_checked'
    )),
  evidence text not null default ''
    check (char_length(evidence) <= 3000),
  observed_at timestamptz not null default now(),
  observer_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  -- 원칙 4: 미실천(부정적 관찰)을 남길 때는 반드시 구체적 행동 근거를 함께 기록한다.
  constraint student_foundation_obs_evidence_chk check (
    observation_result <> 'not_practiced' or btrim(evidence) <> ''
  )
);

-- 모든 FK 컬럼이 선두가 되는 인덱스 생성 (§11 규칙 3)
create index if not exists student_foundation_obs_student_idx
  on public.student_foundation_observations (student_id, observed_at desc);
create index if not exists student_foundation_obs_academy_idx
  on public.student_foundation_observations (academy_id, observed_at desc);
create index if not exists student_foundation_obs_foundation_idx
  on public.student_foundation_observations (foundation_id, observed_at desc);
create index if not exists student_foundation_obs_question_idx
  on public.student_foundation_observations (question_id)
  where question_id is not null;
create index if not exists student_foundation_obs_crop_idx
  on public.student_foundation_observations (crop_id)
  where crop_id is not null;
create index if not exists student_foundation_obs_observer_idx
  on public.student_foundation_observations (observer_id)
  where observer_id is not null;

alter table public.student_foundation_observations enable row level security;

drop policy if exists student_foundation_obs_select on public.student_foundation_observations;
create policy student_foundation_obs_select on public.student_foundation_observations
  for select to authenticated
  using (
    (select public.is_superadmin())
    or exists (
      select 1 from public.memberships m
       where m.user_id = auth.uid()
         and m.academy_id = student_foundation_observations.academy_id
    )
  );

-- 쓰기는 서버 RPC로만 수행한다 (§11 규칙 5, append-only).
revoke all on public.student_foundation_observations from anon;
revoke insert, update, delete, truncate on public.student_foundation_observations from authenticated;
grant select on public.student_foundation_observations to authenticated;

create or replace function public.learning_log_foundation_observation(
  p_academy_id uuid,
  p_student_id uuid,
  p_foundation_id uuid,
  p_observation_result text,
  p_observation_context text default 'problem_solving',
  p_evidence text default '',
  p_ab_prerequisite_check text default 'not_checked',
  p_question_id uuid default null,
  p_crop_id uuid default null,
  p_attempt_id uuid default null,
  p_observed_at timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.student_foundation_observations;
  v_evidence text := left(btrim(coalesce(p_evidence, '')), 3000);
begin
  if auth.uid() is null then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if not (select public.is_superadmin()) and not exists (
    select 1 from public.memberships m
     where m.academy_id = p_academy_id
       and m.user_id = auth.uid()
  ) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.students s
     where s.id = p_student_id
       and s.academy_id = p_academy_id
       and s.withdrawn_at is null
  ) then
    raise exception 'student_not_found' using errcode = 'P0002';
  end if;

  if not exists (
    select 1 from public.thinking_foundations f where f.id = p_foundation_id
  ) then
    raise exception 'foundation_not_found' using errcode = 'P0002';
  end if;

  if p_observation_result = 'not_practiced' and v_evidence = '' then
    raise exception 'evidence_required_for_not_practiced';
  end if;

  insert into public.student_foundation_observations (
    academy_id, student_id, foundation_id,
    question_id, crop_id, attempt_id,
    observation_context, observation_result, ab_prerequisite_check,
    evidence, observed_at, observer_id
  )
  values (
    p_academy_id, p_student_id, p_foundation_id,
    p_question_id, p_crop_id, p_attempt_id,
    coalesce(nullif(btrim(p_observation_context), ''), 'problem_solving'),
    btrim(p_observation_result),
    coalesce(nullif(btrim(p_ab_prerequisite_check), ''), 'not_checked'),
    v_evidence,
    coalesce(p_observed_at, now()),
    auth.uid()
  )
  returning * into v_row;

  return to_jsonb(v_row);
end;
$$;

create or replace function public.student_foundation_observations_recent(
  p_academy_id uuid,
  p_student_id uuid,
  p_foundation_id uuid default null,
  p_limit integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_lim integer := greatest(1, least(coalesce(p_limit, 50), 200));
begin
  if auth.uid() is null then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if not (select public.is_superadmin()) and not exists (
    select 1 from public.memberships m
     where m.academy_id = p_academy_id
       and m.user_id = auth.uid()
  ) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'items', coalesce((
      select jsonb_agg(to_jsonb(sub) order by sub.observed_at desc)
        from (
          select o.id,
                 o.academy_id,
                 o.student_id,
                 o.foundation_id,
                 f.code as foundation_code,
                 f.group_code,
                 f.group_title,
                 f.title as foundation_title,
                 o.question_id,
                 o.crop_id,
                 o.attempt_id,
                 o.observation_context,
                 o.observation_result,
                 o.ab_prerequisite_check,
                 o.evidence,
                 o.observed_at,
                 o.observer_id
            from public.student_foundation_observations o
            join public.thinking_foundations f on f.id = o.foundation_id
           where o.student_id = p_student_id
             and o.academy_id = p_academy_id
             and (p_foundation_id is null or o.foundation_id = p_foundation_id)
           order by o.observed_at desc
           limit v_lim
        ) sub
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.learning_log_foundation_observation(uuid, uuid, uuid, text, text, text, text, uuid, uuid, uuid, timestamptz) from public, anon;
grant execute on function public.learning_log_foundation_observation(uuid, uuid, uuid, text, text, text, text, uuid, uuid, uuid, timestamptz) to authenticated;
revoke all on function public.student_foundation_observations_recent(uuid, uuid, uuid, integer) from public, anon;
grant execute on function public.student_foundation_observations_recent(uuid, uuid, uuid, integer) to authenticated;

-- 퇴원 정리 목록(말단 테이블)에 student_foundation_observations 추가 (§11 규칙 4)
create or replace function public._purge_withdrawn_student_step(
  p_student_id uuid,
  p_deadline timestamptz,
  p_batch integer default 500
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tables constant text[] := array[
    'student_foundation_observations',
    'learning_attempts',
    'learning_exposures',
    'learning_range_timings',
    'learning_sessions',
    'student_problem_rounds',
    'homework_test_grading_attempt_items',
    'homework_test_grading_attempts',
    'homework_study_intervals',
    'homework_item_problems',
    'homework_item_pages',
    'homework_item_units',
    'homework_session_plan_items',
    'homework_assignment_checks',
    'homework_assignments',
    'homework_group_items',
    'homework_group_runtime',
    'homework_groups',
    'student_textbook_answer_records',
    'student_textbook_problem_reports',
    'student_handwriting_samples',
    'student_grading_equiv_logs',
    'student_class_session_snapshot_flows',
    'student_class_session_snapshots',
    'attendance_notification_logs',
    'attendance_notification_queue',
    'makeup_notification_logs',
    'makeup_notification_queue',
    'watch_push_events',
    'student_charge_points',
    'attendance_records',
    'student_point_ledger'
  ];
  v_table text;
  v_deleted integer;
  v_any_deleted boolean := false;
begin
  if not exists (
    select 1 from public.students s
    where s.id = p_student_id and s.withdrawn_at is not null
  ) then
    return true;
  end if;

  if not pg_try_advisory_xact_lock(hashtext('purge_withdrawn_student'), hashtext(p_student_id::text)) then
    return false;
  end if;

  foreach v_table in array v_tables loop
    loop
      if clock_timestamp() >= p_deadline then
        return false;
      end if;
      if v_table = 'student_point_ledger' then
        delete from public.student_point_ledger l
        where l.ctid = any(array(
          select x.ctid from public.student_point_ledger x
          where x.student_id = p_student_id
            and not exists (
              select 1 from public.student_point_ledger r where r.reverses_id = x.id
            )
          limit p_batch
        ));
      else
        execute format(
          'delete from public.%I t where t.ctid = any(array(select x.ctid from public.%I x where x.student_id = $1 limit $2))',
          v_table, v_table
        ) using p_student_id, p_batch;
      end if;
      get diagnostics v_deleted = row_count;
      exit when v_deleted = 0;
      v_any_deleted := true;
    end loop;
  end loop;

  if v_any_deleted then
    return false;
  end if;

  delete from public.students s
  where s.id = p_student_id and s.withdrawn_at is not null;
  return true;
end;
$$;

revoke all on function public._purge_withdrawn_student_step(uuid, timestamptz, integer)
  from public, anon, authenticated;

notify pgrst, 'reload schema';
