-- 학생앱 번호 목록이 유형·페이지 구분선을 그리도록 내용 묶음을 함께 돌려준다.

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
  round_open boolean,
  content_group_kind text,
  content_group_label text,
  content_group_title text
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
    coalesce(rd.is_open, false),
    c.content_group_kind,
    c.content_group_label,
    c.content_group_title
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
