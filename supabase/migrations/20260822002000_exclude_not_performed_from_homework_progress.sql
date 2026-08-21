-- 미수행(skipped)은 최신 정오 상태로 유지하되, 실제로 푼 문항 수(graded)에는
-- 포함하지 않는다. 이전 정답 뒤 미수행이 기록된 경우에도 최신 skipped가
-- 과거 정답을 가리도록 latest 조회에는 포함한다.

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
    select 1 from public.memberships m
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
      and (p_item_ids is null or p.homework_item_id = any(p_item_ids))
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
        and la.result in ('correct', 'wrong', 'partial', 'skipped')
      order by la.attempted_at desc, la.id desc
      limit 1
    ) latest on true
  )
  select
    c.homework_item_id,
    count(*)::integer,
    count(*) filter (
      where c.result in ('correct', 'wrong', 'partial')
    )::integer,
    count(*) filter (where c.result = 'correct')::integer
  from current_grades c
  group by c.homework_item_id;
end;
$$;

comment on function public.staff_homework_item_live_progress_v1(uuid, uuid[]) is
  '최신 정오 기준 과제 진행률. skipped는 과거 상태를 가리지만 graded에는 세지 않는다.';
