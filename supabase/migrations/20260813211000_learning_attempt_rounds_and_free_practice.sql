-- 채점 기록을 회차에 묶고, 과제 밖 자유 풀이도 남긴다.
--
-- 지금까지는 배정된 과제가 없으면 `not_assigned` 로 끝나서 learning_attempts 에
-- 아무것도 남지 않았다. 교재를 스스로 다시 푸는 것도 엄연한 풀이 기록이므로
-- free_practice 세션으로 남긴다. 그래야 "리셋하고 혼자 2번 고쳐 풀었다"가
-- 회차로 보인다.
--
-- 20260812170000_textbook_grading_unify.sql 의 정의를 이어받는다.

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
  v_free_practice boolean := false;
  v_academy uuid;
  v_session uuid;
  v_exposure uuid;
  v_attempt uuid;
  v_round uuid;
  v_round_no integer;
  v_prior integer := 0;
  v_reason text;
  v_scored_by text;
  v_result text;
  v_meta jsonb;
  v_mastery jsonb;
  v_book_id uuid;
  v_grade_label text;
  v_raw_page integer;
  v_display_page integer;
  v_pb_uid uuid;
  v_item_id uuid;
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

  if v_hip_id is not null then
    select * into v_hip
    from public.homework_item_problems
    where id = v_hip_id;

    v_academy := v_hip.academy_id;
    v_book_id := v_hip.book_id;
    v_grade_label := v_hip.grade_label;
    v_raw_page := v_hip.raw_page;
    v_display_page := v_hip.display_page;
    v_pb_uid := v_hip.pb_question_uid;
    v_item_id := v_hip.homework_item_id;
  else
    -- 배정 밖 자유 풀이. 과제 링크 없이 문항 정보만으로 기록한다.
    v_free_practice := true;
    v_group_id := null;

    select c.academy_id, c.book_id, c.grade_label, c.raw_page, c.display_page
      into v_academy, v_book_id, v_grade_label, v_raw_page, v_display_page
    from public.textbook_problem_crops c
    where c.id = p_crop_id;

    if v_academy is null then
      return jsonb_build_object('ok', false, 'reason', 'crop_not_found');
    end if;
  end if;

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
       end
    || case when v_free_practice
         then jsonb_build_object('free_practice', true)
         else '{}'::jsonb
       end;

  -- 1) 세션 확보: 같은 맥락의 열린 세션을 재사용하되, 채점 주체가 같은
  --    세션만 재사용한다. 신뢰도는 세션 단위로 계산되므로 자동채점과 자가표시를
  --    한 세션에 섞으면 양쪽 점수가 모두 왜곡된다.
  select s.id into v_session
  from public.learning_sessions s
  where s.student_id = p_student_id
    and s.academy_id = v_academy
    and s.scored_by = v_scored_by
    and s.status = 'open'
    and s.started_at > now() - interval '12 hours'
    and (
      (v_free_practice
        and s.session_kind = 'free_practice'
        and s.book_id = v_book_id
        and s.grade_label is not distinct from v_grade_label)
      or (not v_free_practice
        and s.session_kind = 'homework'
        and s.homework_group_id = v_group_id)
    )
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
      v_academy, p_student_id,
      case when v_free_practice then 'free_practice' else 'homework' end,
      'student_app', 'unknown', 'unsupervised',
      case when v_scored_by = 'self' then 'available' else 'blocked' end,
      v_scored_by, 'per_item', 'db_textbook', 'until_correct',
      'open', v_group_id, v_item_id,
      v_book_id, v_grade_label,
      jsonb_build_object('origin', 'student_textbook_grade')
    )
    returning id into v_session;
  end if;

  -- 2) 회차 확보: 통과·재배정·리셋으로만 갈린다.
  v_round := public._student_open_problem_round(
    v_academy,
    p_student_id,
    p_crop_id,
    v_book_id,
    v_grade_label,
    case when v_free_practice then 'free_practice' else 'homework' end,
    v_group_id,
    v_hip_id
  );

  -- 3) 노출 기록: 첫 출제인지 오답 재도전인지 구분한다.
  select count(*) into v_prior
  from public.learning_attempts la
  where la.round_id = v_round;

  v_reason := case
    when v_prior > 0 then 'retry'
    when v_free_practice then 'self_selected'
    else 'teacher_assigned'
  end;

  insert into public.learning_exposures (
    academy_id, student_id, session_id, round_id,
    crop_id, pb_question_uid, homework_item_problem_id,
    book_id, grade_label, raw_page, display_page,
    exposure_reason, attempted, meta
  ) values (
    v_academy, p_student_id, v_session, v_round,
    p_crop_id, v_pb_uid, v_hip_id,
    v_book_id, v_grade_label, v_raw_page, v_display_page,
    v_reason, true,
    v_meta
  )
  returning id into v_exposure;

  -- 4) 시도 기록
  insert into public.learning_attempts (
    academy_id, student_id, session_id, exposure_id, round_id,
    crop_id, pb_question_uid, homework_item_problem_id,
    book_id, grade_label,
    result, answer_text,
    assist_level, confidence,
    duration_ms, duration_source,
    scored_by, scored_at, meta
  ) values (
    v_academy, p_student_id, v_session, v_exposure, v_round,
    p_crop_id, v_pb_uid, v_hip_id,
    v_book_id, v_grade_label,
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

  -- 5) 회차 집계 갱신 (정답이면 여기서 닫힌다).
  perform public._student_apply_round_attempt(v_round, v_result, now());

  select r.round_no into v_round_no
  from public.student_problem_rounds r
  where r.id = v_round;

  -- 6) 정답이면 서버가 곧바로 마스터리 판정 → 전원 정답 시 완료 처리.
  --    학생앱이 완료 RPC를 못 부르는 경로(자유 풀이)에서도 완료가 누락되지
  --    않게 한다. 실패해도 시도 기록은 유지한다.
  if v_result = 'correct' and v_group_id is not null then
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
    'round_id', v_round,
    'round_no', v_round_no,
    'free_practice', v_free_practice,
    'homework_item_problem_id', v_hip_id,
    'homework_item_id', v_item_id,
    'homework_group_id', v_group_id,
    'auto_linked', v_auto_linked,
    'mastery', v_mastery
  );
end;
$$;

comment on function public.learning_log_homework_attempt(
  uuid, uuid, uuid, text, text, text, integer, text, jsonb
) is
  '학생앱 채점 결과를 회차(student_problem_rounds)에 묶어 learning_exposures / '
  'learning_attempts 로 남긴다. 그룹 id 가 null 이면 진행 중 과제를 찾아 자동 '
  '연결하고, 배정이 없으면 free_practice 세션으로 남긴다. 정답이면 회차를 닫고 '
  '마스터리 완료까지 판정한다.';
