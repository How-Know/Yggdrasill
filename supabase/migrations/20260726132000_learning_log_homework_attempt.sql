-- 20260726132000: 학생앱 채점 결과를 과제 문항에 연결해 기록
--
-- 학생앱 채점은 Edge Function(student_textbook_grade)이 service_role 로 수행한다.
-- service_role 은 auth.uid() 가 없어 _learning_can_write 를 통과하지 못하므로
-- learning_log_attempts 를 그대로 쓸 수 없다. 대신 소유권을 스스로 검증하는
-- 전용 함수를 둔다.
--
-- 이 함수 하나가 세션 확보 → 노출 기록 → 시도 기록까지 처리한다. 마스터리 루프의
-- 통과 판정(student_complete_homework_group_if_mastered)이 읽는 근거가 여기서
-- 만들어진다.

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
  v_academy uuid;
  v_session uuid;
  v_exposure uuid;
  v_attempt uuid;
  v_prior integer := 0;
  v_reason text;
  v_scored_by text;
  v_result text;
begin
  if p_student_id is null or p_homework_group_id is null or p_crop_id is null then
    return jsonb_build_object('ok', false, 'reason', 'missing_args');
  end if;

  -- 배정된 문항인지 확인. 자유 풀이(과제 밖)면 과제 기록을 남기지 않는다.
  select p.* into v_hip
  from public.homework_item_problems p
  join public.homework_group_items gi
    on gi.homework_item_id = p.homework_item_id
   and gi.academy_id = p.academy_id
  where gi.group_id = p_homework_group_id
    and p.student_id = p_student_id
    and p.crop_id = p_crop_id
  order by p.sort_order
  limit 1;

  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_assigned');
  end if;

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

  -- 1) 세션 확보: 같은 과제 그룹의 열린 세션을 재사용하되, 채점 주체가 같은
  --    세션만 재사용한다. 신뢰도는 세션 단위로 계산되므로 자동채점과 자가표시를
  --    한 세션에 섞으면 양쪽 점수가 모두 왜곡된다.
  select s.id into v_session
  from public.learning_sessions s
  where s.student_id = p_student_id
    and s.academy_id = v_academy
    and s.homework_group_id = p_homework_group_id
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
      'open', p_homework_group_id, v_hip.homework_item_id,
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
    coalesce(p_meta, '{}'::jsonb)
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
    coalesce(p_meta, '{}'::jsonb)
  )
  returning id into v_attempt;

  return jsonb_build_object(
    'ok', true,
    'session_id', v_session,
    'exposure_id', v_exposure,
    'attempt_id', v_attempt,
    'homework_item_problem_id', v_hip.id,
    'homework_item_id', v_hip.homework_item_id
  );
end;
$$;

revoke all on function public.learning_log_homework_attempt(
  uuid, uuid, uuid, text, text, text, integer, text, jsonb
) from public;
grant execute on function public.learning_log_homework_attempt(
  uuid, uuid, uuid, text, text, text, integer, text, jsonb
) to authenticated, service_role;

comment on function public.learning_log_homework_attempt(
  uuid, uuid, uuid, text, text, text, integer, text, jsonb
) is
  '학생앱 채점 결과를 배정 문항(homework_item_problems)에 연결해 '
  'learning_exposures / learning_attempts 로 남긴다. 과제에 없는 문항이면 '
  'not_assigned 로 무시한다.';
