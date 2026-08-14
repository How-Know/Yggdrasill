-- 과거 선생님 채점을 학습 기록으로 백필한다 (진행 중 과제만).
--
-- 20260814050000 의 다리(staff_record_homework_grading_v1)는 앞으로 확정하는
-- 채점에만 걸린다. 이미 검사가 끝난 진행 중 과제(예: 91% 완료로 보이는데
-- 학생앱은 전부 빈 문항)는 여기서 한 번 소급 기록한다.
--
-- 범위: status='active' 인 homework_groups 에 연결된 하위 과제의
--       "가장 최근" homework_test_grading_attempts 1건씩.
-- 멱등: 해당 배정 문항(hip)에 scored_by='teacher' 시도가 이미 있으면 건너뛴다.
-- 시각: attempted_at/scored_at 은 당시 graded_at 을 그대로 쓴다.

do $$
declare
  v_att record;   -- 과제(하위)별 최신 채점 attempt
  v_row record;   -- attempt 의 문항별 행
  v_hip public.homework_item_problems%rowtype;
  v_uid uuid;
  v_result text;
  v_session uuid;
  v_round uuid;
  v_exposure uuid;
  v_prior integer;
  v_logged integer := 0;
begin
  for v_att in
    select distinct on (a.homework_item_id)
      a.id, a.academy_id, a.student_id, a.homework_item_id,
      a.graded_at, a.graded_by, gi.group_id
    from public.homework_test_grading_attempts a
    join public.homework_group_items gi
      on gi.homework_item_id = a.homework_item_id
     and gi.academy_id = a.academy_id
    join public.homework_groups g
      on g.id = gi.group_id
     and g.academy_id = gi.academy_id
    where g.status = 'active'
    order by a.homework_item_id, a.graded_at desc
  loop
    v_session := null;

    for v_row in
      select i.question_key, i.question_uid, i.state
      from public.homework_test_grading_attempt_items i
      where i.attempt_id = v_att.id
    loop
      -- 문제은행 uid: 컬럼 우선, 없으면 question_key 꼬리에서 파싱.
      v_uid := null;
      begin
        v_uid := coalesce(
          nullif(btrim(coalesce(v_row.question_uid, '')), '')::uuid,
          (regexp_match(
            coalesce(v_row.question_key, ''),
            '\|pb\|([0-9a-fA-F-]{36})'
          ))[1]::uuid
        );
      exception when others then
        v_uid := null;
      end;
      if v_uid is null then
        continue;
      end if;

      v_result := case lower(coalesce(v_row.state, ''))
        when 'correct' then 'correct'
        when 'wrong' then 'wrong'
        when 'blank' then 'wrong'
        when 'unsolved' then 'wrong'
        when 'not_performed' then 'skipped'
        else null  -- abandoned 등은 기록하지 않음
      end;
      if v_result is null then
        continue;
      end if;

      select * into v_hip
      from public.homework_item_problems p
      where p.homework_item_id = v_att.homework_item_id
        and p.student_id = v_att.student_id
        and p.pb_question_uid = v_uid
      order by p.sort_order
      limit 1;

      if v_hip.id is null or v_hip.crop_id is null then
        continue;
      end if;

      -- 이미 선생님 시도가 남아 있으면 건너뛴다 (재실행·라이브 경로와 중복 방지).
      if exists (
        select 1 from public.learning_attempts la
        where la.homework_item_problem_id = v_hip.id
          and la.scored_by = 'teacher'
      ) then
        continue;
      end if;

      -- 세션은 하위 과제당 하나, 백필 표식을 남기고 닫아 둔다.
      if v_session is null then
        insert into public.learning_sessions (
          academy_id, student_id, session_kind,
          platform, location_kind, supervision, answer_access,
          scored_by, timing_source, material_kind, retry_policy,
          status, started_at, ended_at,
          homework_group_id, homework_item_id, meta, created_by
        ) values (
          v_att.academy_id, v_att.student_id, 'homework',
          'teacher_input', 'academy', 'staff_present', 'blocked',
          'teacher', 'none', 'db_textbook', 'until_correct',
          'completed', v_att.graded_at, v_att.graded_at,
          v_att.group_id, v_att.homework_item_id,
          jsonb_build_object(
            'origin', 'backfill_teacher_grading',
            'backfilled', true,
            'grading_attempt_id', v_att.id
          ),
          v_att.graded_by
        )
        returning id into v_session;
      end if;

      v_round := public._student_open_problem_round(
        v_att.academy_id,
        v_att.student_id,
        v_hip.crop_id,
        v_hip.book_id,
        v_hip.grade_label,
        'homework',
        v_att.group_id,
        v_hip.id
      );

      select count(*) into v_prior
      from public.learning_attempts la
      where la.round_id = v_round;

      insert into public.learning_exposures (
        academy_id, student_id, session_id, round_id,
        crop_id, pb_question_uid, homework_item_problem_id,
        book_id, grade_label, raw_page, display_page,
        exposure_reason, attempted, exposed_at, meta
      ) values (
        v_att.academy_id, v_att.student_id, v_session, v_round,
        v_hip.crop_id, v_hip.pb_question_uid, v_hip.id,
        v_hip.book_id, v_hip.grade_label, v_hip.raw_page, v_hip.display_page,
        case when v_prior > 0 then 'retry' else 'teacher_assigned' end,
        v_result <> 'skipped', v_att.graded_at,
        jsonb_build_object('teacher_grading', true, 'backfilled', true)
      )
      returning id into v_exposure;

      insert into public.learning_attempts (
        academy_id, student_id, session_id, exposure_id, round_id,
        crop_id, pb_question_uid, homework_item_problem_id,
        book_id, grade_label,
        result, answer_text,
        assist_level, duration_ms, duration_source,
        scored_by, scored_at, scorer_user_id, attempted_at, meta
      ) values (
        v_att.academy_id, v_att.student_id, v_session, v_exposure, v_round,
        v_hip.crop_id, v_hip.pb_question_uid, v_hip.id,
        v_hip.book_id, v_hip.grade_label,
        v_result, null,
        'unknown', null, 'unknown',
        'teacher', v_att.graded_at, v_att.graded_by, v_att.graded_at,
        jsonb_build_object('teacher_grading', true, 'backfilled', true)
      );

      perform public._student_apply_round_attempt(
        v_round, v_result, v_att.graded_at);

      if v_result in ('correct', 'wrong') then
        insert into public.student_textbook_answer_records (
          academy_id, student_id, book_id, grade_label, crop_id,
          last_answer, is_correct, attempt_count, graded_by,
          first_correct_at, updated_at
        ) values (
          v_att.academy_id, v_att.student_id, v_hip.book_id,
          v_hip.grade_label, v_hip.crop_id,
          null, v_result = 'correct', 1, 'teacher',
          case when v_result = 'correct' then v_att.graded_at end, now()
        )
        on conflict (student_id, crop_id) do update
        set is_correct = excluded.is_correct,
            attempt_count = student_textbook_answer_records.attempt_count + 1,
            graded_by = 'teacher',
            first_correct_at = coalesce(
              student_textbook_answer_records.first_correct_at,
              excluded.first_correct_at
            ),
            updated_at = now();
      end if;

      v_logged := v_logged + 1;
    end loop;
  end loop;

  raise notice 'backfill_teacher_grading_attempts: % attempts logged', v_logged;
end;
$$;
