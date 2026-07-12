-- 학생용 앱 "교재 풀기" 기능.
--
-- 설계:
--   * 정답(textbook_problem_answers)은 학생에게 절대 내려보내지 않는다.
--     채점은 student_grade_textbook_page RPC(security definer)가 서버에서 수행.
--   * 학생 풀이 기록은 student_textbook_answer_records 에 crop 단위로 저장
--     (최신 답 + 맞음/틀림 + 시도 횟수). 다시 풀면 갱신된다.
--   * 표기 차이로 틀리지 않도록 정답/학생답 모두 _student_normalize_answer 로
--     정규화 후 비교한다. (①↔1, \frac{1}{2}↔1/2, x=3↔3 등)

-- ---------------------------------------------------------------------------
-- 1) 풀이 기록 테이블
-- ---------------------------------------------------------------------------
create table if not exists public.student_textbook_answer_records (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  book_id uuid not null references public.resource_files(id) on delete cascade,
  grade_label text not null,
  crop_id uuid not null references public.textbook_problem_crops(id) on delete cascade,
  last_answer text,
  is_correct boolean not null,
  attempt_count integer not null default 1,
  first_correct_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint uq_student_textbook_answer_records unique (student_id, crop_id)
);

create index if not exists idx_sta_records_student_book
  on public.student_textbook_answer_records (student_id, book_id, grade_label);
create index if not exists idx_sta_records_academy
  on public.student_textbook_answer_records (academy_id);

alter table public.student_textbook_answer_records enable row level security;

-- 조회: 본인(학생 계정) 또는 학원 스태프. 쓰기는 RPC(security definer)로만.
drop policy if exists sta_records_select on public.student_textbook_answer_records;
create policy sta_records_select on public.student_textbook_answer_records
  for select to authenticated
  using (
    exists (
      select 1 from public.student_app_accounts a
      where a.user_id = auth.uid()
        and a.student_id = student_textbook_answer_records.student_id
    )
    or exists (
      select 1 from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id = student_textbook_answer_records.academy_id
    )
  );

-- ---------------------------------------------------------------------------
-- 2) 정답 정규화 함수
-- ---------------------------------------------------------------------------
-- 객관식: 원문자/숫자를 뽑아 정렬된 "1,3" 형태로.
-- 주관식: LaTeX 표기 차이를 흡수한 선형 문자열로.
create or replace function public._student_normalize_answer(
  p_kind text,
  p_raw text
) returns text
language plpgsql immutable as $$
declare
  s text := coalesce(p_raw, '');
  nums int[];
  m text;
begin
  if p_kind = 'objective' then
    -- 원문자 → 숫자 (⑩~⑳ 먼저: 단일 코드포인트)
    s := replace(s, '⑩', ' 10 '); s := replace(s, '⑪', ' 11 ');
    s := replace(s, '⑫', ' 12 '); s := replace(s, '⑬', ' 13 ');
    s := replace(s, '⑭', ' 14 '); s := replace(s, '⑮', ' 15 ');
    s := replace(s, '⑯', ' 16 '); s := replace(s, '⑰', ' 17 ');
    s := replace(s, '⑱', ' 18 '); s := replace(s, '⑲', ' 19 ');
    s := replace(s, '⑳', ' 20 ');
    s := replace(s, '①', ' 1 '); s := replace(s, '②', ' 2 ');
    s := replace(s, '③', ' 3 '); s := replace(s, '④', ' 4 ');
    s := replace(s, '⑤', ' 5 '); s := replace(s, '⑥', ' 6 ');
    s := replace(s, '⑦', ' 7 '); s := replace(s, '⑧', ' 8 ');
    s := replace(s, '⑨', ' 9 ');
    nums := array(
      select distinct t[1]::int
      from regexp_matches(s, '(\d+)', 'g') as t
      order by t[1]::int
    );
    return array_to_string(nums, ',');
  end if;

  -- 주관식(LaTeX/선형 공통 정규화)
  s := replace(s, '$', '');
  s := regexp_replace(s, '\\left|\\right', '', 'g');
  s := regexp_replace(s, '\\[,;! ]', '', 'g');
  s := replace(s, '\dfrac', '\frac');
  s := replace(s, '\tfrac', '\frac');
  -- \frac{a}{b} → a/b (단순 피연산자, 중첩은 2회 반복으로 부분 처리)
  for i in 1..2 loop
    s := regexp_replace(s, '\\frac\{([^{}]*)\}\{([^{}]*)\}', '\1/\2', 'g');
  end loop;
  s := regexp_replace(s, '\\sqrt\{([^{}]*)\}', '√\1', 'g');
  s := regexp_replace(s, '\\sqrt(\d)', '√\1', 'g');
  s := replace(s, '\pi', 'π');
  s := replace(s, '\pm', '±');
  s := replace(s, '\leq', '≤'); s := replace(s, '\le', '≤');
  s := replace(s, '\geq', '≥'); s := replace(s, '\ge', '≥');
  s := replace(s, '\neq', '≠'); s := replace(s, '\ne', '≠');
  s := replace(s, '\cdot', '*');
  s := replace(s, '\times', '*');
  s := replace(s, '\div', '/');
  s := replace(s, '×', '*');
  s := replace(s, '÷', '/');
  s := regexp_replace(s, '\^\{([^{}]*)\}', '^\1', 'g');
  s := regexp_replace(s, '_\{([^{}]*)\}', '_\1', 'g');
  -- 남은 중괄호/공백 제거
  s := regexp_replace(s, '[{}]', '', 'g');
  s := regexp_replace(s, '\s+', '', 'g');
  return s;
end; $$;

-- 주관식 동등 비교: 정규화 동일 or "=" 우변 비교 허용 (x=3 ↔ 3)
create or replace function public._student_answers_match(
  p_kind text,
  p_correct text,
  p_student text
) returns boolean
language plpgsql immutable as $$
declare
  a text := public._student_normalize_answer(p_kind, p_correct);
  b text := public._student_normalize_answer(p_kind, p_student);
  a_core text;
  b_core text;
begin
  if a is null or a = '' or b is null or b = '' then
    return false;
  end if;
  if a = b then return true; end if;
  if p_kind = 'objective' then return false; end if;
  a_core := case when position('=' in a) > 0
                 then split_part(a, '=', 2) else a end;
  b_core := case when position('=' in b) > 0
                 then split_part(b, '=', 2) else b end;
  return a_core <> '' and a_core = b_core;
end; $$;

-- ---------------------------------------------------------------------------
-- 3) 교재 목록 (정답 DB가 있는, 학생 플로우에 연결된 교재)
-- ---------------------------------------------------------------------------
create or replace function public.student_list_textbooks()
returns table(
  book_id uuid,
  grade_label text,
  book_name text,
  total_problems bigint,
  graded_count bigint,
  correct_count bigint,
  last_raw_page integer,
  last_display_page integer,
  last_activity timestamptz
)
language plpgsql security definer set search_path = public as $$
declare
  v_academy uuid; v_student uuid;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  return query
  with books as (
    select distinct l.book_id, l.grade_label
    from public.student_flows f
    join public.flow_textbook_links l
      on l.flow_id = f.id and l.academy_id = f.academy_id
    where f.academy_id = v_academy and f.student_id = v_student
  ),
  gradable as (
    select c.book_id, c.grade_label, c.id as crop_id
    from public.textbook_problem_crops c
    join public.textbook_problem_answers a on a.crop_id = c.id
    join books b on b.book_id = c.book_id and b.grade_label = c.grade_label
    where c.academy_id = v_academy
      and not c.is_set_header
      and a.answer_kind in ('objective', 'subjective')
      and coalesce(a.answer_text, a.answer_latex_2d) is not null
  ),
  rec as (
    select r.book_id, r.grade_label,
           count(*) as graded_count,
           count(*) filter (where r.is_correct) as correct_count,
           max(r.updated_at) as last_activity
    from public.student_textbook_answer_records r
    where r.student_id = v_student
    group by r.book_id, r.grade_label
  ),
  last_rec as (
    select distinct on (r.book_id, r.grade_label)
           r.book_id, r.grade_label, c.raw_page, c.display_page
    from public.student_textbook_answer_records r
    join public.textbook_problem_crops c on c.id = r.crop_id
    where r.student_id = v_student
    order by r.book_id, r.grade_label, r.updated_at desc
  )
  select
    g.book_id,
    g.grade_label,
    coalesce(rf.name, '교재') as book_name,
    count(*) as total_problems,
    coalesce(max(rec.graded_count), 0) as graded_count,
    coalesce(max(rec.correct_count), 0) as correct_count,
    max(lr.raw_page) as last_raw_page,
    max(lr.display_page) as last_display_page,
    max(rec.last_activity) as last_activity
  from gradable g
  join public.resource_files rf on rf.id = g.book_id
  left join rec on rec.book_id = g.book_id and rec.grade_label = g.grade_label
  left join last_rec lr
    on lr.book_id = g.book_id and lr.grade_label = g.grade_label
  group by g.book_id, g.grade_label, rf.name
  having count(*) > 0
  order by coalesce(rf.name, '교재');
end; $$;

revoke all on function public.student_list_textbooks() from public;
grant execute on function public.student_list_textbooks() to authenticated;

-- ---------------------------------------------------------------------------
-- 4) 단원트리 + 페이지별 풀이 현황
-- ---------------------------------------------------------------------------
create or replace function public.student_textbook_unit_tree(
  p_book_id uuid,
  p_grade_label text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_academy uuid; v_student uuid;
  v_payload jsonb;
  v_page_offset integer;
  v_pages jsonb;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  select t.payload, t.page_offset into v_payload, v_page_offset
  from public.textbook_metadata t
  where t.academy_id = v_academy
    and t.book_id = p_book_id
    and t.grade_label = p_grade_label;

  select coalesce(jsonb_agg(row_to_json(p) order by p.big_order, p.mid_order, p.sub_key, p.raw_page), '[]'::jsonb)
  into v_pages
  from (
    select
      c.big_order, c.mid_order, c.sub_key,
      c.raw_page,
      max(c.display_page) as display_page,
      count(*) as total,
      count(r.id) as graded,
      count(r.id) filter (where r.is_correct) as correct
    from public.textbook_problem_crops c
    join public.textbook_problem_answers a on a.crop_id = c.id
    left join public.student_textbook_answer_records r
      on r.crop_id = c.id and r.student_id = v_student
    where c.academy_id = v_academy
      and c.book_id = p_book_id
      and c.grade_label = p_grade_label
      and not c.is_set_header
      and a.answer_kind in ('objective', 'subjective')
      and coalesce(a.answer_text, a.answer_latex_2d) is not null
    group by c.big_order, c.mid_order, c.sub_key, c.raw_page
  ) p;

  return jsonb_build_object(
    'payload', coalesce(v_payload, '{}'::jsonb),
    'page_offset', v_page_offset,
    'pages', v_pages
  );
end; $$;

revoke all on function public.student_textbook_unit_tree(uuid, text) from public;
grant execute on function public.student_textbook_unit_tree(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 5) 페이지 문항 목록 (정답 미포함 — answer_kind만 노출)
-- ---------------------------------------------------------------------------
create or replace function public.student_textbook_page_problems(
  p_book_id uuid,
  p_grade_label text,
  p_raw_page integer
) returns table(
  crop_id uuid,
  problem_number text,
  label text,
  answer_kind text,
  my_answer text,
  my_correct boolean,
  attempt_count integer
)
language plpgsql security definer set search_path = public as $$
declare
  v_academy uuid; v_student uuid;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  return query
  select
    c.id as crop_id,
    c.problem_number,
    c.label,
    a.answer_kind,
    r.last_answer as my_answer,
    r.is_correct as my_correct,
    r.attempt_count
  from public.textbook_problem_crops c
  join public.textbook_problem_answers a on a.crop_id = c.id
  left join public.student_textbook_answer_records r
    on r.crop_id = c.id and r.student_id = v_student
  where c.academy_id = v_academy
    and c.book_id = p_book_id
    and c.grade_label = p_grade_label
    and c.raw_page = p_raw_page
    and not c.is_set_header
    and a.answer_kind in ('objective', 'subjective')
    and coalesce(a.answer_text, a.answer_latex_2d) is not null
  order by
    case when c.problem_number ~ '^\d+$'
         then c.problem_number::int else 2147483647 end,
    c.problem_number;
end; $$;

revoke all on function public.student_textbook_page_problems(uuid, text, integer) from public;
grant execute on function public.student_textbook_page_problems(uuid, text, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 6) 페이지 일괄 채점
-- ---------------------------------------------------------------------------
-- p_items: [{"crop_id": "...", "answer": "..."}]
-- 반환: {ok, results: [{crop_id, correct}], correct_count, wrong_count}
create or replace function public.student_grade_textbook_page(
  p_book_id uuid,
  p_grade_label text,
  p_items jsonb
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_academy uuid; v_student uuid;
  v_item jsonb;
  v_crop uuid;
  v_answer text;
  v_kind text;
  v_correct_answer text;
  v_is_correct boolean;
  v_results jsonb := '[]'::jsonb;
  v_correct_count integer := 0;
  v_wrong_count integer := 0;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    return jsonb_build_object('ok', false, 'error', 'invalid_items');
  end if;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_crop := (v_item->>'crop_id')::uuid;
    v_answer := v_item->>'answer';
    if v_crop is null or v_answer is null or btrim(v_answer) = '' then
      continue;
    end if;

    -- 학생 학원 소속 교재의 문항인지 검증 + 정답 로드
    select a.answer_kind,
           case when a.answer_kind = 'subjective'
                then coalesce(a.answer_text, a.answer_latex_2d)
                else a.answer_text end
    into v_kind, v_correct_answer
    from public.textbook_problem_crops c
    join public.textbook_problem_answers a on a.crop_id = c.id
    where c.id = v_crop
      and c.academy_id = v_academy
      and c.book_id = p_book_id
      and c.grade_label = p_grade_label
      and not c.is_set_header;

    if v_kind is null then
      continue;
    end if;

    v_is_correct := public._student_answers_match(v_kind, v_correct_answer, v_answer);

    insert into public.student_textbook_answer_records as r (
      academy_id, student_id, book_id, grade_label, crop_id,
      last_answer, is_correct, attempt_count, first_correct_at
    ) values (
      v_academy, v_student, p_book_id, p_grade_label, v_crop,
      v_answer, v_is_correct, 1,
      case when v_is_correct then now() else null end
    )
    on conflict (student_id, crop_id) do update set
      last_answer = excluded.last_answer,
      is_correct = excluded.is_correct,
      attempt_count = r.attempt_count + 1,
      first_correct_at = coalesce(r.first_correct_at, excluded.first_correct_at),
      updated_at = now();

    if v_is_correct then
      v_correct_count := v_correct_count + 1;
    else
      v_wrong_count := v_wrong_count + 1;
    end if;

    v_results := v_results || jsonb_build_object(
      'crop_id', v_crop, 'correct', v_is_correct
    );
  end loop;

  return jsonb_build_object(
    'ok', true,
    'results', v_results,
    'correct_count', v_correct_count,
    'wrong_count', v_wrong_count
  );
end; $$;

revoke all on function public.student_grade_textbook_page(uuid, text, jsonb) from public;
grant execute on function public.student_grade_textbook_page(uuid, text, jsonb) to authenticated;
