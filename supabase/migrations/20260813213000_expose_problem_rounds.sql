-- 회차를 화면에 내보낸다.
--
-- 회차별 타임라인 UI는 나중이지만, "이 학생이 이 문항을 지금 몇 회차째 풀고
-- 있는가"는 두 앱 모두 문항 옆에 바로 보여야 한다.
--
-- round_no 규칙: 열린 회차가 있으면 그 번호, 없으면 마지막 회차 번호.
-- 한 번도 푼 적 없으면 0.

-- ---------------------------------------------------------------------------
-- 학생앱: 교재 페이지 문항 목록
-- ---------------------------------------------------------------------------
drop function if exists public.student_textbook_page_problems_v2(uuid, text, integer);

create function public.student_textbook_page_problems_v2(
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
  part_results jsonb,
  category_code text,
  category_label text,
  item_name text,
  round_no integer,
  round_open boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
begin
  select i.academy_id, i.student_id
    into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  return query
  select
    c.id,
    c.problem_number,
    c.label,
    a.answer_kind,
    public._student_grading_mode(
      a.answer_kind, coalesce(a.answer_text, a.answer_latex_2d)
    ),
    r.last_answer,
    r.is_correct,
    r.attempt_count,
    r.graded_by,
    r.flags,
    report.status,
    case when a.answer_kind = 'subjective' then (
      select jsonb_agg(
        jsonb_build_object(
          'key', part ->> 'key',
          'mode', public._student_grading_mode(
            'subjective', part ->> 'text'
          )
        )
      )
      from jsonb_array_elements(
        public._split_set_answer_parts(
          coalesce(a.answer_text, a.answer_latex_2d)
        )
      ) part
    ) end,
    r.part_results,
    c.category_code,
    pc.display_label,
    nullif(btrim(c.item_name), ''),
    coalesce(rd.round_no, 0)::integer,
    coalesce(rd.is_open, false)
  from public.textbook_problem_crops c
  join public.textbook_problem_answers a on a.crop_id = c.id
  left join public.student_textbook_answer_records r
    on r.crop_id = c.id
   and r.student_id = v_student
  left join public.textbook_metadata tm
    on tm.academy_id = c.academy_id
   and tm.book_id = c.book_id
   and tm.grade_label = c.grade_label
  left join public.textbook_problem_categories pc
    on pc.series_key = lower(coalesce(tm.payload->>'series', ''))
   and pc.category_code = c.category_code
  left join lateral (
    select s.status
    from public.student_textbook_problem_reports s
    where s.student_id = v_student
      and s.crop_id = c.id
    order by
      case s.status when 'open' then 0 when 'accepted' then 1 else 2 end,
      s.created_at desc
    limit 1
  ) report on true
  left join lateral (
    select pr.round_no, pr.closed_at is null as is_open
    from public.student_problem_rounds pr
    where pr.student_id = v_student
      and pr.crop_id = c.id
    order by pr.round_no desc
    limit 1
  ) rd on true
  where c.academy_id = v_academy
    and c.book_id = p_book_id
    and c.grade_label = p_grade_label
    and c.raw_page = p_raw_page
    and not c.is_set_header
    and (
      (
        a.answer_kind in ('objective', 'subjective')
        and coalesce(a.answer_text, a.answer_latex_2d) is not null
      )
      or a.answer_kind = 'image'
    )
  order by
    case when c.problem_number ~ '^\d+$'
      then c.problem_number::integer else 2147483647 end,
    c.problem_number;
end;
$$;

grant execute on function public.student_textbook_page_problems_v2(uuid, text, integer)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 학생앱: 과제 문항 목록
-- ---------------------------------------------------------------------------
drop function if exists public.student_list_homework_problems_v1(uuid);

create function public.student_list_homework_problems_v1(
  p_group_id uuid
)
returns table(
  homework_item_id uuid,
  homework_item_problem_id uuid,
  item_title text,
  item_order integer,
  sort_order integer,
  crop_id uuid,
  pb_question_uid uuid,
  book_id uuid,
  grade_label text,
  problem_number text,
  raw_page integer,
  display_page integer,
  big_name text,
  mid_name text,
  type_group_label text,
  source_stage text,
  passed boolean,
  attempt_count integer,
  last_result text,
  last_attempted_at timestamptz,
  last_answer text,
  last_scored_by text,
  round_no integer,
  round_attempt_count integer
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
begin
  select o.academy_id, o.student_id into v_academy, v_student
  from public._student_owned_group(p_group_id) o;

  if v_student is null then
    raise exception 'student_list_homework_problems_v1: forbidden';
  end if;

  return query
  select
    p.homework_item_id,
    p.id,
    coalesce(hi.title, ''),
    coalesce(gi.item_order_index, 0),
    p.sort_order,
    p.crop_id,
    p.pb_question_uid,
    p.book_id,
    p.grade_label,
    p.problem_number,
    p.raw_page,
    p.display_page,
    p.big_name,
    p.mid_name,
    p.type_group_label,
    coalesce(p.source_stage, 'original'),
    coalesce(a.has_correct, false),
    coalesce(a.attempts, 0)::integer,
    a.last_result,
    a.last_attempted_at,
    a.last_answer,
    a.last_scored_by,
    coalesce(rd.round_no, 0)::integer,
    coalesce(rd.attempt_count, 0)::integer
  from public.homework_group_items gi
  join public.homework_items hi
    on hi.id = gi.homework_item_id
   and hi.academy_id = gi.academy_id
  join public.homework_item_problems p
    on p.homework_item_id = hi.id
   and p.academy_id = hi.academy_id
   and p.excluded_at is null
  left join lateral (
    select
      bool_or(la.result = 'correct') as has_correct,
      count(*) as attempts,
      (array_agg(la.result order by la.attempted_at desc))[1] as last_result,
      (array_agg(la.attempted_at order by la.attempted_at desc))[1]
        as last_attempted_at,
      -- 이 배정에서 마지막으로 낸 답. 학생앱 과제 풀이 화면이 이전 회차의
      -- 답 캐시 대신 이것으로 채운다.
      (array_agg(la.answer_text order by la.attempted_at desc))[1]
        as last_answer,
      (array_agg(la.scored_by order by la.attempted_at desc))[1]
        as last_scored_by
    from public.learning_attempts la
    where la.homework_item_problem_id = p.id
  ) a on true
  left join lateral (
    select pr.round_no, pr.attempt_count
    from public.student_problem_rounds pr
    where pr.student_id = v_student
      and pr.crop_id = p.crop_id
    order by pr.round_no desc
    limit 1
  ) rd on true
  where gi.group_id = p_group_id
    and gi.academy_id = v_academy
    and gi.student_id = v_student
  order by coalesce(gi.item_order_index, 0), p.sort_order;
end;
$$;

grant execute on function public.student_list_homework_problems_v1(uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 매니저앱: 문항 묶음의 회차 한 번에 조회
-- ---------------------------------------------------------------------------
create or replace function public.staff_list_problem_rounds_v1(
  p_student_id uuid,
  p_crop_ids uuid[]
) returns table(
  crop_id uuid,
  round_no integer,
  round_open boolean,
  attempt_count integer,
  passed boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_academy uuid;
begin
  select s.academy_id into v_academy
  from public.students s
  where s.id = p_student_id;

  if v_academy is null then
    return;
  end if;

  if not exists (
    select 1 from public.memberships m
    where m.academy_id = v_academy
      and m.user_id = auth.uid()
  ) then
    raise exception 'staff_list_problem_rounds_v1: forbidden';
  end if;

  return query
  select distinct on (pr.crop_id)
    pr.crop_id,
    pr.round_no,
    pr.closed_at is null,
    pr.attempt_count,
    pr.passed
  from public.student_problem_rounds pr
  where pr.student_id = p_student_id
    and pr.academy_id = v_academy
    and (p_crop_ids is null or pr.crop_id = any(p_crop_ids))
  order by pr.crop_id, pr.round_no desc;
end;
$$;

grant execute on function public.staff_list_problem_rounds_v1(uuid, uuid[])
  to authenticated;

-- ---------------------------------------------------------------------------
-- 회차별 풀이 이력 (UI 는 나중, 데이터는 지금부터 조회 가능하게)
-- ---------------------------------------------------------------------------
create or replace function public.student_problem_round_history_v1(
  p_student_id uuid,
  p_crop_id uuid
) returns table(
  round_id uuid,
  round_no integer,
  origin text,
  homework_group_id uuid,
  opened_at timestamptz,
  closed_at timestamptz,
  close_reason text,
  attempt_count integer,
  passed boolean,
  attempts jsonb
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_academy uuid;
begin
  select s.academy_id into v_academy
  from public.students s
  where s.id = p_student_id;

  if v_academy is null then
    return;
  end if;

  if not exists (
    select 1 from public.memberships m
    where m.academy_id = v_academy
      and m.user_id = auth.uid()
  ) and not exists (
    select 1 from public.student_app_accounts a
    where a.user_id = auth.uid()
      and a.student_id = p_student_id
  ) then
    raise exception 'student_problem_round_history_v1: forbidden';
  end if;

  return query
  select
    r.id,
    r.round_no,
    r.origin,
    r.homework_group_id,
    r.opened_at,
    r.closed_at,
    r.close_reason,
    r.attempt_count,
    r.passed,
    coalesce(la.attempts, '[]'::jsonb)
  from public.student_problem_rounds r
  left join lateral (
    select jsonb_agg(
      jsonb_build_object(
        'attempt_id', a.id,
        'result', a.result,
        'answer_text', a.answer_text,
        'scored_by', a.scored_by,
        'duration_ms', a.duration_ms,
        'attempted_at', a.attempted_at
      )
      order by a.attempted_at
    ) as attempts
    from public.learning_attempts a
    where a.round_id = r.id
  ) la on true
  where r.student_id = p_student_id
    and r.crop_id = p_crop_id
  order by r.round_no desc;
end;
$$;

grant execute on function public.student_problem_round_history_v1(uuid, uuid)
  to authenticated;
