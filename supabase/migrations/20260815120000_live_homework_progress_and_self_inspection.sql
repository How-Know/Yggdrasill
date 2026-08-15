-- 학생 자가채점(풀이 이탈)을 학습앱 카드의 진행률·완료율·시도와 같은 장부에 둔다.
--
-- 진행률/완료율: 카드가 homework_test_grading_attempts(선생님 검사 스냅샷)만
-- 보고 있어서 학생 기록이 안 보였다. 배정 문항의 learning_attempts 를 집계한다.
--
-- 시도: 카드의 check_count 는 선생님 확인에서만 올랐다. 채점이 있었던 풀이
-- 이탈도 검사 1회다 (주체가 앱일 뿐). 열기만 하고 나가면 호출하지 않는다.
-- 제출 후 선생님 확인은 다른 검사라 기존처럼 따로 +1 된다.

-- ---------------------------------------------------------------------------
-- 1) 학습앱 카드용 실시간 진행률
-- ---------------------------------------------------------------------------
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
    select
      p.homework_item_id,
      p.id as hip_id
    from public.homework_item_problems p
    join public.homework_items hi
      on hi.id = p.homework_item_id
     and hi.academy_id = p.academy_id
    where hi.student_id = p_student_id
      and hi.academy_id = v_academy
      and p.excluded_at is null
      and (p_item_ids is null or p.homework_item_id = any (p_item_ids))
  ),
  stats as (
    select
      pr.homework_item_id,
      pr.hip_id,
      coalesce(bool_or(la.result = 'correct'), false) as has_correct,
      count(la.id) as attempts,
      (array_agg(la.result order by la.attempted_at desc))[1] as last_result
    from problems pr
    left join public.learning_attempts la
      on la.homework_item_problem_id = pr.hip_id
    group by pr.homework_item_id, pr.hip_id
  )
  select
    s.homework_item_id,
    count(*)::integer as total,
    count(*) filter (
      where s.attempts > 0
        and not (not s.has_correct and s.last_result = 'skipped')
    )::integer as graded,
    count(*) filter (where s.has_correct)::integer as completed
  from stats s
  group by s.homework_item_id;
end;
$$;

revoke all on function public.staff_homework_item_live_progress_v1(uuid, uuid[])
  from public;
grant execute on function public.staff_homework_item_live_progress_v1(uuid, uuid[])
  to authenticated;

comment on function public.staff_homework_item_live_progress_v1(uuid, uuid[]) is
  '배정 문항의 learning_attempts 로 카드 진행률(수행-미수행)/완료율(정답)을 집계한다. '
  '마지막이 skipped 이고 정답이 없으면 미수행으로 본다.';

-- ---------------------------------------------------------------------------
-- 2) 학생 풀이 이탈 = 검사 1회 (check_count +1, 단계는 그대로)
-- ---------------------------------------------------------------------------
create or replace function public.student_record_homework_self_inspection_v1(
  p_group_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  v_group_student uuid;
  v_items integer := 0;
  v_check integer := 0;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    return jsonb_build_object('ok', false, 'reason', 'no_student_account');
  end if;
  if p_group_id is null then
    return jsonb_build_object('ok', false, 'reason', 'group_id_required');
  end if;

  select g.student_id into v_group_student
  from public.homework_groups g
  where g.id = p_group_id
    and g.academy_id = v_academy
    and g.status = 'active';

  if v_group_student is null then
    return jsonb_build_object('ok', false, 'reason', 'group_not_found');
  end if;
  if v_group_student <> v_student then
    return jsonb_build_object('ok', false, 'reason', 'not_your_group');
  end if;

  perform public.m5_group_runtime_seed(v_academy, p_group_id);

  update public.homework_items h
  set check_count = coalesce(h.check_count, 0) + 1,
      updated_at = now(),
      version = coalesce(h.version, 1) + 1
  from public.homework_group_items gi
  where gi.group_id = p_group_id
    and gi.academy_id = v_academy
    and h.id = gi.homework_item_id
    and h.academy_id = v_academy
    and h.student_id = v_student
    and coalesce(h.status, 0) <> 1;
  get diagnostics v_items = row_count;

  update public.homework_group_runtime r
  set check_count = coalesce(r.check_count, 0) + 1,
      updated_at = now(),
      version = coalesce(r.version, 1) + 1
  where r.group_id = p_group_id
    and r.academy_id = v_academy
  returning r.check_count into v_check;

  if v_check is null then
    select coalesce(max(h.check_count), 0) into v_check
    from public.homework_items h
    join public.homework_group_items gi
      on gi.homework_item_id = h.id
     and gi.academy_id = h.academy_id
    where gi.group_id = p_group_id
      and gi.academy_id = v_academy
      and h.student_id = v_student;
  end if;

  return jsonb_build_object(
    'ok', true,
    'check_count', v_check,
    'items_updated', v_items
  );
end;
$$;

revoke all on function public.student_record_homework_self_inspection_v1(uuid)
  from public;
grant execute on function public.student_record_homework_self_inspection_v1(uuid)
  to authenticated;

comment on function public.student_record_homework_self_inspection_v1(uuid) is
  '채점이 있었던 과제 풀이 이탈을 검사 1회로 남긴다. check_count 만 올리고 '
  '단계(phase)는 바꾸지 않는다. 제출·선생님 확인과는 별개 사건이다.';
