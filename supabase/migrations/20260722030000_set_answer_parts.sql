-- 세트형(종속형) 문항 파트별 채점 지원.
--
-- 원칙:
--   * 정답 저장은 기존처럼 crop당 한 덩어리 유지. 파트 분리는 읽기 시점 파싱.
--   * 파서는 보수적으로: 순차 마커((1)→(2)→…) + 파트 내용 비어있지 않음.
--     애매하면 null을 반환해 기존 단일(통째 자기 채점) 동작으로 폴백한다.
--   * 통계는 무변경 — is_correct(전 파트 정답)만 집계에 쓰인다.
--
-- 추가:
--   1) _split_set_answer_parts(text) — 파트 파서 (SQL 기준 구현.
--      Edge Function grading.ts의 splitSetAnswerParts와 동일 규칙 유지)
--   2) student_textbook_answer_records.part_results — 파트별 답·정오 누적
--   3) student_textbook_page_problems — set_parts(키+파트별 auto/self),
--      part_results 반환
--   4) homework_test_grading_attempt_items.part_states — 학습앱 우측 시트의
--      파트별 수기 채점 기록

-- ---------------------------------------------------------------------------
-- 1) 세트형 정답 파서
-- ---------------------------------------------------------------------------
-- 반환: [{"key":"(1)","text":"..."}, ...] 또는 null(파싱 불가/세트형 아님).
-- 규칙:
--   * 마커는 (1)부터 시작해 1씩 증가하는 것만 인정 (다음 기대 번호만 탐색)
--   * 마커는 문자열 시작 또는 공백 뒤에서만 인정
--   * 각 파트 내용은 비어 있으면 안 됨 — 빈 내용이 되는 마커 후보는
--     내용으로 간주하고 건너뜀 (예: "(1) (2) (2) 5" → (1)의 답이 "(2)")
--   * 파트 2개 미만이거나 마지막 내용이 비면 null
create or replace function public._split_set_answer_parts(
  p_text text
) returns jsonb
language plpgsql immutable as $$
declare
  t text := btrim(coalesce(p_text, ''));
  n int;
  i int := 1;
  expected int := 1;
  content_start int := null;
  parts jsonb := '[]'::jsonb;
  head text;
  mnum text;
  mtext text;
  prevch text;
  part_text text;
begin
  if t = '' then return null; end if;
  n := length(t);

  while i <= n loop
    head := substring(t from i);
    mnum := substring(head from '^[(（]\s*([0-9]{1,2})\s*[)）]');
    if mnum is not null and mnum::int = expected then
      prevch := case when i = 1 then ' ' else substring(t, i - 1, 1) end;
      if prevch ~ '\s' then
        mtext := substring(head from '^[(（]\s*[0-9]{1,2}\s*[)）]');
        if expected = 1 then
          -- 첫 마커: 마커 앞에는 내용이 없어야 세트형으로 본다
          if btrim(substring(t, 1, i - 1)) = '' then
            content_start := i + length(mtext);
            expected := 2;
            i := i + length(mtext);
            continue;
          end if;
        else
          part_text := btrim(substring(t, content_start, i - content_start));
          if part_text <> '' then
            parts := parts || jsonb_build_object(
              'key', '(' || (expected - 1)::text || ')',
              'text', part_text
            );
            content_start := i + length(mtext);
            expected := expected + 1;
            i := i + length(mtext);
            continue;
          end if;
          -- 내용이 비면 이 후보는 마커가 아니라 이전 파트의 내용
        end if;
      end if;
    end if;
    i := i + 1;
  end loop;

  if expected < 3 then return null; end if; -- 파트 2개 미만
  part_text := btrim(substring(t from content_start));
  if part_text = '' then return null; end if;
  parts := parts || jsonb_build_object(
    'key', '(' || (expected - 1)::text || ')',
    'text', part_text
  );
  if jsonb_array_length(parts) > 8 then return null; end if;
  return parts;
end; $$;

-- ---------------------------------------------------------------------------
-- 2) 학생 답 기록에 파트별 결과 누적 컬럼
-- ---------------------------------------------------------------------------
-- 형식: [{"key":"(1)","answer":"3","correct":true,"graded_by":"auto"}, ...]
alter table public.student_textbook_answer_records
  add column if not exists part_results jsonb;

-- ---------------------------------------------------------------------------
-- 3) 페이지 문항 목록 — set_parts / part_results 포함
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
  flags text[],
  report_status text,
  set_parts jsonb,
  part_results jsonb
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
    r.flags,
    rp.status as report_status,
    -- 파트 키 + 파트별 auto/self만 노출 (정답 텍스트는 절대 미포함)
    case when a.answer_kind = 'subjective' then (
      select jsonb_agg(
        jsonb_build_object(
          'key', part ->> 'key',
          'mode', public._student_grading_mode('subjective', part ->> 'text')
        )
      )
      from jsonb_array_elements(
        public._split_set_answer_parts(
          coalesce(a.answer_text, a.answer_latex_2d)
        )
      ) part
    ) end as set_parts,
    r.part_results
  from public.textbook_problem_crops c
  join public.textbook_problem_answers a on a.crop_id = c.id
  left join public.student_textbook_answer_records r
    on r.crop_id = c.id and r.student_id = v_student
  left join lateral (
    select s.status
    from public.student_textbook_problem_reports s
    where s.student_id = v_student and s.crop_id = c.id
    order by
      case s.status when 'open' then 0 when 'accepted' then 1 else 2 end,
      s.created_at desc
    limit 1
  ) rp on true
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
-- 4) 학습앱 우측 시트 — 파트별 수기 채점 기록
-- ---------------------------------------------------------------------------
-- 형식: {"(1)":"correct","(2)":"wrong"} (문항 state는 기존 컬럼 그대로,
-- 통계·점수 계산도 문항 단위 state만 사용)
alter table public.homework_test_grading_attempt_items
  add column if not exists part_states jsonb;
