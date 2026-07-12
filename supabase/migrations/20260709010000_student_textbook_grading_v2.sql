-- 학생 교재 풀기 채점 v2.
--
-- 변경점:
--   1) 채점 기록에 graded_by('auto'|'self') / flags(단위 주의 등) 컬럼 추가.
--      셀프 채점(정답 공개 후 학생이 O/X)을 지원하기 위함.
--   2) 문항별 채점 방식 분류 함수 _student_grading_mode 추가.
--      auto: 서버 자동 채점 (Edge Function student_textbook_grade)
--      self: 정답 공개 + 셀프 채점 (세트형/(가)(나) 빈칸/행렬·연립/그림 답 등)
--   3) 목록/트리/문항 RPC가 image 답 문항도 포함하도록 확장 (셀프 채점 대상).
--   4) AI 판정 캐시 테이블 student_grading_ai_cache 추가.
--      (단위 지정 여부, 한글 표현 동치 판정 결과를 재사용 — 비용/지연 절감)
--
-- 실제 채점 로직은 Edge Function(student_textbook_grade)으로 승격되었다.
-- 기존 student_grade_textbook_page RPC는 하위호환으로 남겨두지만 앱은 더 이상
-- 사용하지 않는다.

-- ---------------------------------------------------------------------------
-- 1) 채점 기록 확장
-- ---------------------------------------------------------------------------
alter table public.student_textbook_answer_records
  add column if not exists graded_by text not null default 'auto';

alter table public.student_textbook_answer_records
  drop constraint if exists sta_records_graded_by_chk;
alter table public.student_textbook_answer_records
  add constraint sta_records_graded_by_chk
  check (graded_by in ('auto', 'self'));

-- flags: 'unit_caution'(단위 주의), 'unit_hint'(단위도 써 보기),
--        'form_differs'(수학적으로 같지만 표기가 다름)
alter table public.student_textbook_answer_records
  add column if not exists flags text[] not null default '{}';

-- ---------------------------------------------------------------------------
-- 2) AI 판정 캐시 (service role 전용 — 학생/스태프 정책 없음)
-- ---------------------------------------------------------------------------
create table if not exists public.student_grading_ai_cache (
  id uuid primary key default gen_random_uuid(),
  crop_id uuid not null references public.textbook_problem_crops(id) on delete cascade,
  cache_key text not null,          -- 'unit_spec:v1' | 'equiv:v1:<정규화된 학생답>'
  verdict jsonb not null,
  model text,
  created_at timestamptz not null default now(),
  constraint uq_student_grading_ai_cache unique (crop_id, cache_key)
);

alter table public.student_grading_ai_cache enable row level security;

-- ---------------------------------------------------------------------------
-- 3) 채점 방식 분류 함수
-- ---------------------------------------------------------------------------
-- Edge Function(TS)에도 동일 로직이 있다. 규칙을 바꾸면 양쪽을 함께 수정할 것.
--   self 분류 기준:
--     * image 답
--     * 세트형 소문항: "(1) ... (2) ..." 형태 (정답이 소문항별로 분리 안 됨)
--     * (가)(나) 빈칸 채우기
--     * \begin{...} 구조 답 (연립방정식/행렬)
--     * "풀이 N쪽" 참조 답
--     * 복수 라벨 답: "a=2, b=3" / "x절편: 2, y절편: 4" (서로 다른 라벨 2개 이상)
create or replace function public._student_grading_mode(
  p_kind text,
  p_text text
) returns text
language plpgsql immutable as $$
declare
  t text := coalesce(p_text, '');
  labels text[];
begin
  if p_kind = 'objective' then return 'auto'; end if;
  if p_kind = 'image' then return 'self'; end if;
  if btrim(t) = '' then return 'self'; end if;

  if t ~ '(^|\s)\(\s*\d\s*\)\s*\S' then return 'self'; end if;      -- 세트형 (1)(2)
  if t ~ '\((가|나|다|라|마|바|사)\)' then return 'self'; end if;    -- 빈칸 채우기
  if position('\begin' in t) > 0 then return 'self'; end if;         -- 연립/행렬
  if t ~ '풀이\s*\d+\s*쪽' then return 'self'; end if;                -- 풀이 참조

  -- 복수 라벨: '=' 또는 ':' 앞의 라벨(문자로 시작)이 2종 이상
  labels := array(
    select distinct btrim(m[1])
    from regexp_matches(t, '(?:^|[,;\s(])\s*([A-Za-z가-힣][A-Za-z0-9가-힣의 ]{0,15}?)\s*[:=]', 'g') m
    where btrim(m[1]) !~ '^\d+$'
  );
  if coalesce(array_length(labels, 1), 0) >= 2 then return 'self'; end if;

  return 'auto';
end; $$;

-- ---------------------------------------------------------------------------
-- 4) 페이지 문항 목록 v2 — grading_mode/graded_by/flags 포함, image 문항 포함
-- ---------------------------------------------------------------------------
drop function if exists public.student_textbook_page_problems(uuid, text, integer);

create or replace function public.student_textbook_page_problems(
  p_book_id uuid,
  p_grade_label text,
  p_raw_page integer
) returns table(
  crop_id uuid,
  problem_number text,
  label text,
  answer_kind text,
  grading_mode text,
  my_answer text,
  my_correct boolean,
  attempt_count integer,
  graded_by text,
  flags text[]
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
    public._student_grading_mode(
      a.answer_kind, coalesce(a.answer_text, a.answer_latex_2d)
    ) as grading_mode,
    r.last_answer as my_answer,
    r.is_correct as my_correct,
    r.attempt_count,
    r.graded_by,
    r.flags
  from public.textbook_problem_crops c
  join public.textbook_problem_answers a on a.crop_id = c.id
  left join public.student_textbook_answer_records r
    on r.crop_id = c.id and r.student_id = v_student
  where c.academy_id = v_academy
    and c.book_id = p_book_id
    and c.grade_label = p_grade_label
    and c.raw_page = p_raw_page
    and not c.is_set_header
    and (
      (a.answer_kind in ('objective', 'subjective')
        and coalesce(a.answer_text, a.answer_latex_2d) is not null)
      or a.answer_kind = 'image'
    )
  order by
    case when c.problem_number ~ '^\d+$'
         then c.problem_number::int else 2147483647 end,
    c.problem_number;
end; $$;

revoke all on function public.student_textbook_page_problems(uuid, text, integer) from public;
grant execute on function public.student_textbook_page_problems(uuid, text, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 5) 목록/트리 RPC — image 문항도 셀프 채점 대상으로 포함
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
      and (
        (a.answer_kind in ('objective', 'subjective')
          and coalesce(a.answer_text, a.answer_latex_2d) is not null)
        or a.answer_kind = 'image'
      )
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
      and (
        (a.answer_kind in ('objective', 'subjective')
          and coalesce(a.answer_text, a.answer_latex_2d) is not null)
        or a.answer_kind = 'image'
      )
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
