-- 20260812170000: 학생앱 채점을 선생님 검사와 동등하게 통합
--
-- 목표 (사용자 결정):
--   1) 학생이 교재 탭(자유 풀이)에서 풀어도, 그 문항이 진행 중 과제에 배정돼
--      있으면 과제 기록(learning_exposures/attempts)에 자동 연결한다.
--      → 과제 카드에서 풀든 교재 탭에서 풀든 진행률·완료율이 같아진다.
--   2) 배정 문항을 전부 맞히면 서버가 즉시 과제를 완료 처리한다
--      (검사 이력 + homework_complete — 학습앱과 같은 경로라 양쪽 앱 표시가
--      항상 일치한다). 지금까지는 학생앱이 완료 RPC를 따로 불러야 했다.
--   3) 실물 교재를 검사 신청으로 제출한 동안(phase=3)에는 같은 교재의
--      디지털 채점·정답 공개를 잠근다 — 채점 후 답 고쳐쓰기 방지.
--      (검사 완료/반려로 phase가 바뀌면 자동 해제)

-- ---------------------------------------------------------------------------
-- 1) 내부용 마스터리 완료 — service_role(Edge Function) 경로에서도 호출 가능
-- ---------------------------------------------------------------------------
-- student_complete_homework_group_if_mastered 의 본체를 학원/학생 id 를 직접
-- 받는 내부 함수로 분리한다. 학생 토큰 검증은 학생용 래퍼가 담당한다.
create or replace function public._homework_group_complete_if_mastered(
  p_academy_id uuid,
  p_student_id uuid,
  p_group_id uuid
) returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_state jsonb;
  v_item record;
  v_assignment uuid;
  v_completed integer := 0;
  v_progress integer;
begin
  if p_academy_id is null or p_student_id is null or p_group_id is null then
    return jsonb_build_object('ok', false, 'reason', 'missing_args');
  end if;

  v_state := public._homework_group_mastery_state(
    p_academy_id, p_student_id, p_group_id);

  if not (v_state->>'problem_based')::boolean then
    return v_state || jsonb_build_object('ok', false, 'reason', 'not_problem_based');
  end if;

  if not (v_state->>'mastered')::boolean then
    return v_state || jsonb_build_object('ok', false, 'reason', 'incomplete');
  end if;

  v_progress := 100;

  for v_item in
    select gi.homework_item_id as item_id
    from public.homework_group_items gi
    join public.homework_items hi
      on hi.id = gi.homework_item_id
     and hi.academy_id = gi.academy_id
    where gi.group_id = p_group_id
      and gi.academy_id = p_academy_id
      and gi.student_id = p_student_id
      and coalesce(hi.status, 0) <> 1
  loop
    -- 활성 배정이 있으면 검사 이력으로도 남긴다 (진행률 100%).
    select ha.id into v_assignment
    from public.homework_assignments ha
    where ha.homework_item_id = v_item.item_id
      and ha.academy_id = p_academy_id
      and ha.status not in ('completed', 'canceled')
    order by ha.assigned_at desc
    limit 1;

    if v_assignment is not null then
      perform public.homework_assignment_check(
        v_assignment,
        p_academy_id,
        v_progress,
        null::text,
        '학생앱 자체 채점 전원 정답'::text,
        null::text
      );

      update public.homework_assignments
         set status = 'completed',
             updated_at = now(),
             version = coalesce(version, 1) + 1
       where id = v_assignment
         and academy_id = p_academy_id;
    end if;

    perform public.homework_complete(v_item.item_id, p_academy_id);
    v_completed := v_completed + 1;
  end loop;

  return v_state || jsonb_build_object(
    'ok', true,
    'reason', 'mastered',
    'completed_items', v_completed
  );
end;
$$;

revoke all on function public._homework_group_complete_if_mastered(uuid, uuid, uuid)
  from public;
grant execute on function public._homework_group_complete_if_mastered(uuid, uuid, uuid)
  to service_role;

comment on function public._homework_group_complete_if_mastered(uuid, uuid, uuid) is
  '배정 문항을 전부 맞힌 그룹 과제를 완료시킨다 (검사 이력 + homework_complete). '
  '학생용 래퍼와 learning_log_homework_attempt 가 공유하는 본체.';

-- 학생용 래퍼는 소유 검증 후 내부 함수에 위임한다 (동작 동일).
create or replace function public.student_complete_homework_group_if_mastered(
  p_group_id uuid
) returns jsonb
language plpgsql
volatile
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
    raise exception 'student_complete_homework_group_if_mastered: forbidden';
  end if;

  return public._homework_group_complete_if_mastered(
    v_academy, v_student, p_group_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- 2) 제출 잠금 판정 — 실물 교재가 검사 대기(phase=3)인 동안 true
-- ---------------------------------------------------------------------------
create or replace function public.student_textbook_submit_locked(
  p_student_id uuid,
  p_book_id uuid,
  p_grade_label text
) returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.homework_item_problems p
    join public.homework_items hi
      on hi.id = p.homework_item_id
     and hi.academy_id = p.academy_id
    where p.student_id = p_student_id
      and p.book_id = p_book_id
      and p.grade_label = p_grade_label
      and coalesce(hi.status, 0) <> 1
      and coalesce(hi.phase, 1) = 3
  );
$$;

revoke all on function public.student_textbook_submit_locked(uuid, uuid, text)
  from public;
grant execute on function public.student_textbook_submit_locked(uuid, uuid, text)
  to service_role;

comment on function public.student_textbook_submit_locked(uuid, uuid, text) is
  '해당 교재(book_id+grade_label)에 검사 대기(phase=3) 배정 문항이 있으면 true. '
  'Edge Function(student_textbook_grade)이 채점·정답 공개를 잠글 때 쓴다.';

-- ---------------------------------------------------------------------------
-- 3) learning_log_homework_attempt v2 — 자유 풀이 자동 연결 + 서버측 완료
-- ---------------------------------------------------------------------------
-- p_homework_group_id 가 null 이면(교재 탭 자유 풀이) 그 문항이 배정된
-- 진행 중(phase 1·2, 미완료, active 그룹) 과제를 찾아 자동 연결한다.
-- 정답이면 그룹 마스터리를 즉시 판정해 전원 정답 시 완료까지 처리한다.
create or replace function public.learning_log_homework_attempt(
  p_student_id uuid,
  p_homework_group_id uuid,
  p_crop_id uuid,
  p_result text,
  p_scored_by text default 'auto',
  p_answer_text text default null,
  p_duration_ms integer default null,
  p_assist_level text default 'unknown',
  p_meta jsonb default '{}'::jsonb
) returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_hip public.homework_item_problems%rowtype;
  v_hip_id uuid;
  v_group_id uuid := p_homework_group_id;
  v_auto_linked boolean := false;
  v_academy uuid;
  v_session uuid;
  v_exposure uuid;
  v_attempt uuid;
  v_prior integer := 0;
  v_reason text;
  v_scored_by text;
  v_result text;
  v_meta jsonb;
  v_mastery jsonb;
begin
  if p_student_id is null or p_crop_id is null then
    return jsonb_build_object('ok', false, 'reason', 'missing_args');
  end if;

  if v_group_id is not null then
    -- 과제 스코프 풀이: 지정 그룹에 배정된 문항인지 확인.
    select p.id into v_hip_id
    from public.homework_item_problems p
    join public.homework_group_items gi
      on gi.homework_item_id = p.homework_item_id
     and gi.academy_id = p.academy_id
    where gi.group_id = v_group_id
      and p.student_id = p_student_id
      and p.crop_id = p_crop_id
    order by p.sort_order
    limit 1;
  else
    -- 자유 풀이(교재 탭): 이 문항이 배정된 진행 중 과제를 찾아 자동 연결.
    -- 어느 경로로 풀든 진행률·완료율이 같아지게 하는 핵심 분기다.
    -- 제출(3)·확인(4) 단계는 제외 — 제출 중 잠금과 일관되게 수행 단계만 잇는다.
    select p.id, gi.group_id into v_hip_id, v_group_id
    from public.homework_item_problems p
    join public.homework_items hi
      on hi.id = p.homework_item_id
     and hi.academy_id = p.academy_id
    join public.homework_group_items gi
      on gi.homework_item_id = p.homework_item_id
     and gi.academy_id = p.academy_id
    join public.homework_groups g
      on g.id = gi.group_id
     and g.academy_id = gi.academy_id
    where p.student_id = p_student_id
      and p.crop_id = p_crop_id
      and g.status = 'active'
      and coalesce(hi.status, 0) <> 1
      and coalesce(hi.phase, 1) in (1, 2)
    order by g.created_at desc, p.sort_order
    limit 1;

    v_auto_linked := v_group_id is not null;
  end if;

  if v_hip_id is null then
    -- 배정 밖 자유 풀이. 과제 기록은 남기지 않는다 (answer_records 캐시만 존재).
    return jsonb_build_object('ok', false, 'reason', 'not_assigned');
  end if;

  select * into v_hip
  from public.homework_item_problems
  where id = v_hip_id;

  v_academy := v_hip.academy_id;

  -- 사용자 토큰으로 호출된 경우에만 권한을 검사한다 (service_role 은 uid 없음).
  if auth.uid() is not null
     and not public._learning_can_write(v_academy, p_student_id) then
    raise exception 'learning_log_homework_attempt: forbidden';
  end if;

  v_result := coalesce(nullif(btrim(coalesce(p_result, '')), ''), 'ungraded');
  v_scored_by := case
    when p_scored_by in ('auto', 'teacher', 'self') then p_scored_by
    else 'unknown'
  end;
  v_meta := coalesce(p_meta, '{}'::jsonb)
    || case when v_auto_linked
         then jsonb_build_object('auto_linked', true)
         else '{}'::jsonb
       end;

  -- 1) 세션 확보: 같은 과제 그룹의 열린 세션을 재사용하되, 채점 주체가 같은
  --    세션만 재사용한다. 신뢰도는 세션 단위로 계산되므로 자동채점과 자가표시를
  --    한 세션에 섞으면 양쪽 점수가 모두 왜곡된다.
  select s.id into v_session
  from public.learning_sessions s
  where s.student_id = p_student_id
    and s.academy_id = v_academy
    and s.homework_group_id = v_group_id
    and s.scored_by = v_scored_by
    and s.status = 'open'
    and s.started_at > now() - interval '12 hours'
  order by s.started_at desc
  limit 1;

  if v_session is null then
    insert into public.learning_sessions (
      academy_id, student_id, session_kind,
      platform, location_kind, supervision, answer_access,
      scored_by, timing_source, material_kind, retry_policy,
      status, homework_group_id, homework_item_id,
      book_id, grade_label, meta
    ) values (
      v_academy, p_student_id, 'homework',
      'student_app', 'unknown', 'unsupervised',
      case when v_scored_by = 'self' then 'available' else 'blocked' end,
      v_scored_by, 'per_item', 'db_textbook', 'until_correct',
      'open', v_group_id, v_hip.homework_item_id,
      v_hip.book_id, v_hip.grade_label,
      jsonb_build_object('origin', 'student_textbook_grade')
    )
    returning id into v_session;
  end if;

  -- 2) 노출 기록: 첫 출제인지 오답 재도전인지 구분한다.
  select count(*) into v_prior
  from public.learning_attempts la
  where la.homework_item_problem_id = v_hip.id;

  v_reason := case when v_prior > 0 then 'retry' else 'teacher_assigned' end;

  insert into public.learning_exposures (
    academy_id, student_id, session_id,
    crop_id, pb_question_uid, homework_item_problem_id,
    book_id, grade_label, raw_page, display_page,
    exposure_reason, attempted, meta
  ) values (
    v_academy, p_student_id, v_session,
    v_hip.crop_id, v_hip.pb_question_uid, v_hip.id,
    v_hip.book_id, v_hip.grade_label, v_hip.raw_page, v_hip.display_page,
    v_reason, true,
    v_meta
  )
  returning id into v_exposure;

  -- 3) 시도 기록
  insert into public.learning_attempts (
    academy_id, student_id, session_id, exposure_id,
    crop_id, pb_question_uid, homework_item_problem_id,
    book_id, grade_label,
    result, answer_text,
    assist_level, confidence,
    duration_ms, duration_source,
    scored_by, scored_at, meta
  ) values (
    v_academy, p_student_id, v_session, v_exposure,
    v_hip.crop_id, v_hip.pb_question_uid, v_hip.id,
    v_hip.book_id, v_hip.grade_label,
    v_result, nullif(p_answer_text, ''),
    case
      when p_assist_level in
        ('none', 'hint', 'solution_peek', 'peer', 'teacher') then p_assist_level
      else 'unknown'
    end,
    null,
    p_duration_ms,
    case when p_duration_ms is not null then 'measured' else 'unknown' end,
    v_scored_by, now(),
    v_meta
  )
  returning id into v_attempt;

  -- 4) 정답이면 서버가 곧바로 마스터리 판정 → 전원 정답 시 완료 처리.
  --    학생앱이 완료 RPC를 못 부르는 경로(자유 풀이)에서도 완료가 누락되지
  --    않게 한다. 실패해도 시도 기록은 유지한다.
  if v_result = 'correct' then
    begin
      v_mastery := public._homework_group_complete_if_mastered(
        v_academy, p_student_id, v_group_id);
    exception when others then
      v_mastery := jsonb_build_object(
        'ok', false, 'reason', 'complete_error', 'detail', sqlerrm);
    end;
  end if;

  return jsonb_build_object(
    'ok', true,
    'session_id', v_session,
    'exposure_id', v_exposure,
    'attempt_id', v_attempt,
    'homework_item_problem_id', v_hip.id,
    'homework_item_id', v_hip.homework_item_id,
    'homework_group_id', v_group_id,
    'auto_linked', v_auto_linked,
    'mastery', v_mastery
  );
end;
$$;

comment on function public.learning_log_homework_attempt(
  uuid, uuid, uuid, text, text, text, integer, text, jsonb
) is
  '학생앱 채점 결과를 배정 문항(homework_item_problems)에 연결해 '
  'learning_exposures / learning_attempts 로 남긴다. 그룹 id 가 null 이면 '
  '진행 중 과제를 찾아 자동 연결하고, 정답이면 마스터리 완료까지 판정한다. '
  '배정에 없는 문항이면 not_assigned 로 무시한다.';
