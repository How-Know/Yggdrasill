-- 과제 재진입 때 skipped(이탈 미수행)가 마지막이면 그 앞의 자가/자동
-- 채점 정오가 가려졌다. 학생앱은 "skipped 만 있는 문항"만 빈 칸으로
-- 두고, 한 번이라도 채점한 문항은 마지막 정오를 다시 보여야 한다.

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
  last_graded_result text,
  last_graded_answer text,
  last_graded_scored_by text,
  graded_attempt_count integer,
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
    a.last_graded_result,
    a.last_graded_answer,
    a.last_graded_scored_by,
    coalesce(a.graded_attempts, 0)::integer,
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
      count(*) filter (
        where la.result is distinct from 'skipped'
      ) as graded_attempts,
      (array_agg(la.result order by la.attempted_at desc))[1] as last_result,
      (array_agg(la.attempted_at order by la.attempted_at desc))[1]
        as last_attempted_at,
      (array_agg(la.answer_text order by la.attempted_at desc))[1]
        as last_answer,
      (array_agg(la.scored_by order by la.attempted_at desc))[1]
        as last_scored_by,
      (array_agg(la.result order by la.attempted_at desc)
        filter (where la.result is distinct from 'skipped'))[1]
        as last_graded_result,
      (array_agg(la.answer_text order by la.attempted_at desc)
        filter (where la.result is distinct from 'skipped'))[1]
        as last_graded_answer,
      (array_agg(la.scored_by order by la.attempted_at desc)
        filter (where la.result is distinct from 'skipped'))[1]
        as last_graded_scored_by
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

comment on function public.student_list_homework_problems_v1(uuid) is
  '과제 배정 문항 + 이 배정의 시도 집계. last_graded_* 는 skipped 를 '
  '건너뛴 마지막 채점이라 학생앱이 이탈 후에도 정오를 복원한다.';
