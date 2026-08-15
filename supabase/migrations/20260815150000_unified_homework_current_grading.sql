-- 학생앱·학습앱·과제 카드가 같은 문항별 현재 정오를 본다.
--
-- learning_attempts 는 채점 이력 원장이다. 현재 정오는 skipped(이탈 미수행)를
-- 제외한 마지막 채점 결과이며, 채점 주체(self/auto/teacher)는 구분하지 않는다.

create or replace function public.staff_homework_item_current_grading_v1(
  p_student_id uuid,
  p_homework_item_id uuid
)
returns table(
  homework_item_problem_id uuid,
  question_ref uuid,
  result text,
  scored_by text,
  attempted_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_academy uuid;
begin
  select hi.academy_id into v_academy
  from public.homework_items hi
  where hi.id = p_homework_item_id
    and hi.student_id = p_student_id;

  if v_academy is null then
    return;
  end if;

  if not exists (
    select 1
    from public.memberships m
    where m.academy_id = v_academy
      and m.user_id = auth.uid()
  ) then
    raise exception 'staff_homework_item_current_grading_v1: forbidden';
  end if;

  return query
  select
    p.id,
    coalesce(p.pb_question_uid, p.crop_id),
    latest.result,
    latest.scored_by,
    latest.attempted_at
  from public.homework_item_problems p
  join lateral (
    select la.result, la.scored_by, la.attempted_at
    from public.learning_attempts la
    where la.homework_item_problem_id = p.id
      and la.result in ('correct', 'wrong', 'partial')
    order by la.attempted_at desc, la.id desc
    limit 1
  ) latest on true
  where p.homework_item_id = p_homework_item_id
    and p.student_id = p_student_id
    and p.academy_id = v_academy
    and p.excluded_at is null
  order by p.sort_order;
end;
$$;

revoke all on function public.staff_homework_item_current_grading_v1(uuid, uuid)
  from public;
grant execute on function public.staff_homework_item_current_grading_v1(uuid, uuid)
  to authenticated;

comment on function public.staff_homework_item_current_grading_v1(uuid, uuid) is
  '학생·자동·선생님 채점을 합친 과제 문항별 현재 정오. skipped를 제외한 마지막 '
  'learning_attempts 결과를 반환한다.';

-- 카드 진행률도 동일한 현재 정오를 집계한다. 과거에 한 번 맞았더라도 마지막
-- 채점이 오답이면 현재 완료 문항으로 세지 않는다.
create or replace function public.staff_homework_item_live_progress_v1(
  p_student_id uuid,
  p_item_ids uuid[] default null
)
returns table(
  homework_item_id uuid,
  total integer,
  graded integer,
  completed integer
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_academy uuid;
begin
  if p_student_id is null then
    return;
  end if;

  select s.academy_id into v_academy
  from public.students s
  where s.id = p_student_id;

  if v_academy is null then
    return;
  end if;

  if not exists (
    select 1
    from public.memberships m
    where m.academy_id = v_academy
      and m.user_id = auth.uid()
  ) then
    raise exception 'staff_homework_item_live_progress_v1: forbidden';
  end if;

  return query
  with problems as (
    select p.homework_item_id, p.id as hip_id
    from public.homework_item_problems p
    join public.homework_items hi
      on hi.id = p.homework_item_id
     and hi.academy_id = p.academy_id
    where hi.student_id = p_student_id
      and hi.academy_id = v_academy
      and p.excluded_at is null
      and (p_item_ids is null or p.homework_item_id = any (p_item_ids))
  ),
  current_grades as (
    select
      pr.homework_item_id,
      pr.hip_id,
      latest.result
    from problems pr
    left join lateral (
      select la.result
      from public.learning_attempts la
      where la.homework_item_problem_id = pr.hip_id
        and la.result in ('correct', 'wrong', 'partial')
      order by la.attempted_at desc, la.id desc
      limit 1
    ) latest on true
  )
  select
    c.homework_item_id,
    count(*)::integer,
    count(*) filter (where c.result is not null)::integer,
    count(*) filter (where c.result = 'correct')::integer
  from current_grades c
  group by c.homework_item_id;
end;
$$;

revoke all on function public.staff_homework_item_live_progress_v1(uuid, uuid[])
  from public;
grant execute on function public.staff_homework_item_live_progress_v1(uuid, uuid[])
  to authenticated;

comment on function public.staff_homework_item_live_progress_v1(uuid, uuid[]) is
  '과제 문항의 마지막 현재 정오로 카드 진행률과 완료율을 집계한다.';
