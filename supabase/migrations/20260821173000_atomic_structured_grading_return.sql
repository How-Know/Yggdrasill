-- 교사 구조화 채점의 문항 기록·검사 체크·assignment 완료·학생 반환을
-- 하나의 트랜잭션으로 커밋한다. request_id는 attempt id이자 멱등 키다.

-- 명시적 미수행(skipped)도 현재 상태다. 상태 없음과 구분해야 교사 화면의
-- '미기록만 정답 기본값'이 실제 미수행을 덮어쓰지 않는다.
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
    select 1 from public.memberships m
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
      and la.result in ('correct', 'wrong', 'partial', 'skipped')
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

create or replace function public.homework_commit_structured_grading_return_v1(
  p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request_id uuid := nullif(p_payload->>'request_id', '')::uuid;
  v_student_id uuid := nullif(p_payload->>'student_id', '')::uuid;
  v_group_id uuid := nullif(p_payload->>'group_id', '')::uuid;
  v_action text := lower(coalesce(p_payload->>'action', ''));
  v_progress integer := greatest(
    0,
    least(150, coalesce((p_payload->>'progress')::integer, 0))
  );
  v_checked_at timestamptz :=
    coalesce(nullif(p_payload->>'checked_at', '')::timestamptz, now());
  v_snapshot_at timestamptz :=
    nullif(p_payload->>'source_snapshot_at', '')::timestamptz;
  v_attempt jsonb := coalesce(p_payload->'attempt', '{}'::jsonb);
  v_attempt_items jsonb := coalesce(p_payload->'attempt_items', '[]'::jsonb);
  v_learning_by_homework jsonb :=
    coalesce(p_payload->'learning_items_by_homework', '{}'::jsonb);
  v_item_ids uuid[];
  v_academy_id uuid;
  v_item_id uuid;
  v_assignment public.homework_assignments%rowtype;
  v_learning_entry record;
  v_mirror jsonb;
  v_processed integer := 0;
begin
  if v_request_id is null or v_student_id is null or v_group_id is null then
    raise exception 'HOMEWORK_GRADING_RETURN_ARGS_REQUIRED';
  end if;
  if v_action not in ('complete', 'confirm') then
    raise exception 'HOMEWORK_GRADING_RETURN_ACTION_INVALID';
  end if;
  if jsonb_typeof(v_attempt_items) <> 'array'
      or jsonb_typeof(v_learning_by_homework) <> 'object' then
    raise exception 'HOMEWORK_GRADING_RETURN_PAYLOAD_INVALID';
  end if;

  select g.academy_id
  into v_academy_id
  from public.homework_groups g
  where g.id = v_group_id
    and g.student_id = v_student_id
    and g.status = 'active';

  if v_academy_id is null then
    raise exception 'HOMEWORK_GRADING_RETURN_GROUP_NOT_FOUND';
  end if;
  if not exists (
    select 1
    from public.memberships m
    where m.academy_id = v_academy_id
      and m.user_id = auth.uid()
  ) then
    raise exception 'HOMEWORK_GRADING_RETURN_FORBIDDEN';
  end if;

  if exists (
    select 1
    from public.homework_test_grading_attempts a
    where a.id = v_request_id
      and a.academy_id = v_academy_id
  ) then
    return jsonb_build_object(
      'ok', true,
      'duplicate', true,
      'request_id', v_request_id
    );
  end if;

  select array_agg(value::uuid order by ordinality)
  into v_item_ids
  from jsonb_array_elements_text(
    coalesce(p_payload->'homework_item_ids', '[]'::jsonb)
  ) with ordinality requested(value, ordinality);

  if cardinality(coalesce(v_item_ids, array[]::uuid[])) = 0 then
    raise exception 'HOMEWORK_GRADING_RETURN_ITEMS_REQUIRED';
  end if;
  if exists (
    select 1
    from unnest(v_item_ids) requested(item_id)
    where not exists (
      select 1
      from public.homework_group_items gi
      where gi.academy_id = v_academy_id
        and gi.student_id = v_student_id
        and gi.group_id = v_group_id
        and gi.homework_item_id = requested.item_id
    )
  ) then
    raise exception 'HOMEWORK_GRADING_RETURN_ITEM_NOT_IN_GROUP';
  end if;

  perform pg_advisory_xact_lock(hashtext(v_group_id::text));
  if exists (
    select 1
    from public.homework_test_grading_attempts a
    where a.id = v_request_id
      and a.academy_id = v_academy_id
  ) then
    return jsonb_build_object(
      'ok', true,
      'duplicate', true,
      'request_id', v_request_id
    );
  end if;

  -- 시트를 연 뒤 학생/다른 교사가 새 정오를 남겼으면 자동 정답 초안으로
  -- 덮어쓰지 않는다. 클라이언트는 outbox를 유지하고 다시 열도록 안내한다.
  if v_snapshot_at is not null and exists (
    select 1
    from public.learning_attempts la
    join public.homework_item_problems hip
      on hip.id = la.homework_item_problem_id
    where hip.homework_item_id = any(v_item_ids)
      and hip.student_id = v_student_id
      and la.attempted_at > v_snapshot_at
  ) then
    raise exception 'HOMEWORK_GRADING_CONCURRENT_CHANGE';
  end if;

  insert into public.homework_test_grading_attempts (
    id, academy_id, student_id, homework_item_id,
    assignment_code_snapshot, group_homework_title_snapshot,
    graded_at, graded_by, action, solve_elapsed_ms, extra_elapsed_ms,
    score_correct, score_total, wrong_count, unsolved_count,
    blank_count, not_performed_count, payload_version, version
  ) values (
    v_request_id,
    v_academy_id,
    v_student_id,
    nullif(v_attempt->>'homework_item_id', '')::uuid,
    nullif(v_attempt->>'assignment_code_snapshot', ''),
    nullif(v_attempt->>'group_homework_title_snapshot', ''),
    v_checked_at,
    auth.uid(),
    v_action,
    greatest(0, coalesce((v_attempt->>'solve_elapsed_ms')::integer, 0)),
    greatest(0, coalesce((v_attempt->>'extra_elapsed_ms')::integer, 0)),
    greatest(0, coalesce((v_attempt->>'score_correct')::numeric, 0)),
    greatest(0, coalesce((v_attempt->>'score_total')::numeric, 0)),
    greatest(0, coalesce((v_attempt->>'wrong_count')::integer, 0)),
    greatest(0, coalesce((v_attempt->>'unsolved_count')::integer, 0)),
    greatest(0, coalesce((v_attempt->>'blank_count')::integer, 0)),
    greatest(0, coalesce((v_attempt->>'not_performed_count')::integer, 0)),
    1,
    1
  );

  insert into public.homework_test_grading_attempt_items (
    id, attempt_id, academy_id, student_id, homework_item_id,
    question_key, question_uid, page_number, question_index,
    correct_answer_snapshot, state, incorrect_kind,
    baseline_attempt_id, baseline_state, correction_state,
    correction_attempt_number, part_states,
    point_value, earned_point, reserved_elapsed_ms, version
  )
  select
    nullif(item->>'id', '')::uuid,
    v_request_id,
    v_academy_id,
    v_student_id,
    nullif(v_attempt->>'homework_item_id', '')::uuid,
    item->>'question_key',
    nullif(item->>'question_uid', ''),
    greatest(1, coalesce((item->>'page_number')::integer, 1)),
    greatest(1, coalesce((item->>'question_index')::integer, 1)),
    nullif(item->>'correct_answer_snapshot', ''),
    item->>'state',
    nullif(item->>'incorrect_kind', ''),
    nullif(item->>'baseline_attempt_id', '')::uuid,
    nullif(item->>'baseline_state', ''),
    nullif(item->>'correction_state', ''),
    nullif(item->>'correction_attempt_number', '')::integer,
    case
      when jsonb_typeof(item->'part_states') = 'object'
        then item->'part_states'
      else null
    end,
    greatest(0, coalesce((item->>'point_value')::numeric, 1)),
    greatest(0, coalesce((item->>'earned_point')::numeric, 0)),
    nullif(item->>'reserved_elapsed_ms', '')::integer,
    1
  from jsonb_array_elements(v_attempt_items) item;

  for v_learning_entry in
    select key, value
    from jsonb_each(v_learning_by_homework)
  loop
    if v_learning_entry.key::uuid <> all(v_item_ids) then
      raise exception 'HOMEWORK_GRADING_RETURN_LEARNING_ITEM_INVALID:%',
        v_learning_entry.key;
    end if;
    v_mirror := public.staff_record_homework_grading_v1(
      v_student_id,
      v_learning_entry.key::uuid,
      v_learning_entry.value
    );
    if coalesce((v_mirror->>'ok')::boolean, false) is not true then
      raise exception 'HOMEWORK_GRADING_RETURN_MIRROR_FAILED:%',
        v_learning_entry.key;
    end if;
  end loop;

  foreach v_item_id in array v_item_ids
  loop
    v_assignment := null;
    select a.*
    into v_assignment
    from public.homework_assignments a
    where a.academy_id = v_academy_id
      and a.student_id = v_student_id
      and a.homework_item_id = v_item_id
      and a.status in ('assigned', 'in_progress', 'carried_to_class')
    order by
      (a.status = 'carried_to_class') desc,
      a.assigned_at desc,
      a.id
    limit 1
    for update;

    if v_assignment.id is null then
      raise exception 'HOMEWORK_GRADING_RETURN_ASSIGNMENT_NOT_FOUND:%',
        v_item_id;
    end if;

    insert into public.homework_assignment_checks (
      academy_id, student_id, homework_item_id, assignment_id,
      progress, checked_at, outcome, scheduled_due_at,
      group_check_id, idempotency_key
    ) values (
      v_academy_id, v_student_id, v_item_id, v_assignment.id,
      v_progress, v_checked_at, 'graded', v_assignment.due_at,
      v_request_id, v_request_id
    );

    update public.homework_assignments a
    set progress = v_progress,
        issue_type = null,
        issue_note = null,
        status = 'completed',
        due_for_check_at = null,
        absence_carryover = false,
        updated_at = now(),
        version = coalesce(a.version, 1) + 1
    where a.id = v_assignment.id;

    update public.homework_session_plan_items spi
    set resolution = 'completed',
        assignment_id = v_assignment.id,
        updated_at = now(),
        version = coalesce(spi.version, 1) + 1
    where spi.academy_id = v_academy_id
      and spi.student_id = v_student_id
      and spi.homework_item_id = v_item_id
      and spi.resolution in ('pending', 'confirmed')
      and (
        spi.assignment_id = v_assignment.id
        or spi.origin = 'carried_from_previous'
      );

    update public.homework_items h
    set status = 0,
        completed_at = null,
        pending_complete = (v_action = 'complete'),
        updated_at = now(),
        version = coalesce(h.version, 1) + 1
    where h.id = v_item_id
      and h.academy_id = v_academy_id
      and h.student_id = v_student_id;

    perform public.homework_confirm(
      v_item_id,
      v_academy_id,
      auth.uid()::text
    );
    v_processed := v_processed + 1;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'request_id', v_request_id,
    'processed_count', v_processed,
    'action', v_action
  );
end;
$$;

revoke all on function public.homework_commit_structured_grading_return_v1(jsonb)
  from public;
grant execute on function public.homework_commit_structured_grading_return_v1(jsonb)
  to authenticated;

comment on function public.homework_commit_structured_grading_return_v1(jsonb) is
  '교사 구조화 채점 문항 원장, 학습 정오, assignment check, phase 4 반환을 '
  'request_id 멱등 키로 한 트랜잭션에 커밋한다.';
