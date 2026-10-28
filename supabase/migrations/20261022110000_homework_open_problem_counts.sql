-- 과제별 남은 문항 수. 알림장 숙제 리스트가 하원 전 미리보기에서도
-- 숙제 배정 트리거(_homework_assignment_sync_problems)와 같은 기준으로 센다:
-- 제외 문항을 빼고, 정답 기록이 없는 문항.

create or replace function public.staff_homework_open_problem_counts_v1(
  p_item_ids uuid[]
)
returns table(
  homework_item_id uuid,
  total_count integer,
  open_count integer
)
language sql
stable
security definer
set search_path = public
as $$
  select
    p.homework_item_id,
    count(*)::integer,
    (count(*) filter (
      where not exists (
        select 1
        from public.learning_attempts la
        where la.homework_item_problem_id = p.id
          and la.result = 'correct'
      )
    ))::integer
  from public.homework_item_problems p
  where p.homework_item_id = any(coalesce(p_item_ids, '{}'::uuid[]))
    and p.excluded_at is null
    and exists (
      select 1
      from public.memberships m
      where m.academy_id = p.academy_id
        and m.user_id = auth.uid()
    )
  group by p.homework_item_id;
$$;

revoke all on function public.staff_homework_open_problem_counts_v1(uuid[])
  from public, anon;
grant execute on function public.staff_homework_open_problem_counts_v1(uuid[])
  to authenticated;
