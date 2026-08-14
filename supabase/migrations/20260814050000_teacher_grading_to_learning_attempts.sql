-- 선생님 채점 결과를 학습 기록(learning_attempts·회차·답 캐시)에 반영한다.
--
-- 지금까지 선생님의 문항별 O/X 는 homework_test_grading_* 에만 남아서,
-- 학생앱이 읽는 student_list_homework_problems_v1(learning_attempts 집계)에는
-- 보이지 않았다. 그래서 검사 후 학생앱에는 10문항이 전부 빈 상태로 보였다.
-- 매니저앱이 채점을 확정할 때 이 RPC 를 함께 불러 문항별 시도를 남기면,
-- 학생앱은 맞은 문항을 통과로, 틀린 문항만 다시 풀 것으로 표시한다.
--
-- 주의: learning_log_homework_attempt 와 달리 마스터리 완료 판정을 하지 않는다.
-- 검사 흐름의 단계 전환(제출 선반·확인)은 homework_record_structured_grading
-- 계열이 책임지므로, 여기서 완료를 건드리면 흐름이 꼬인다.

-- ---------------------------------------------------------------------------
-- 1) 답 캐시 graded_by 에 'teacher' 허용
-- ---------------------------------------------------------------------------
alter table public.student_textbook_answer_records
  drop constraint if exists sta_records_graded_by_chk;
alter table public.student_textbook_answer_records
  add constraint sta_records_graded_by_chk
  check (graded_by in ('auto', 'self', 'teacher'));

-- ---------------------------------------------------------------------------
-- 2) 선생님 문항별 채점 기록 RPC
-- ---------------------------------------------------------------------------
-- p_items: [{"question_uid": "...", "state": "correct|wrong|blank|not_performed"}]
--   state 매핑: correct → correct / wrong·blank → wrong / not_performed → skipped
--   abandoned(포기)는 기록하지 않는다 (분모에서도 빠지는 문항).
create or replace function public.staff_record_homework_grading_v1(
  p_student_id uuid,
  p_homework_item_id uuid,
  p_items jsonb
) returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_group uuid;
  v_session uuid;
  v_item jsonb;
  v_uid uuid;
  v_state text;
  v_result text;
  v_hip public.homework_item_problems%rowtype;
  v_round uuid;
  v_exposure uuid;
  v_prior integer;
  v_logged integer := 0;
  v_skipped_items integer := 0;
begin
  if p_student_id is null or p_homework_item_id is null then
    return jsonb_build_object('ok', false, 'reason', 'missing_args');
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    return jsonb_build_object('ok', false, 'reason', 'items_required');
  end if;

  select hi.academy_id into v_academy
  from public.homework_items hi
  where hi.id = p_homework_item_id;

  if v_academy is null then
    return jsonb_build_object('ok', false, 'reason', 'item_not_found');
  end if;

  if not exists (
    select 1 from public.memberships m
    where m.academy_id = v_academy
      and m.user_id = auth.uid()
  ) then
    raise exception 'staff_record_homework_grading_v1: forbidden';
  end if;

  select gi.group_id into v_group
  from public.homework_group_items gi
  where gi.homework_item_id = p_homework_item_id
    and gi.academy_id = v_academy
  limit 1;

  -- 선생님 채점 세션. 자동/자가 세션과 섞지 않는다 (신뢰도 계산 왜곡 방지).
  select s.id into v_session
  from public.learning_sessions s
  where s.student_id = p_student_id
    and s.academy_id = v_academy
    and s.scored_by = 'teacher'
    and s.status = 'open'
    and s.session_kind = 'homework'
    and s.homework_item_id = p_homework_item_id
    and s.started_at > now() - interval '12 hours'
  order by s.started_at desc
  limit 1;

  if v_session is null then
    insert into public.learning_sessions (
      academy_id, student_id, session_kind,
      platform, location_kind, supervision, answer_access,
      scored_by, timing_source, material_kind, retry_policy,
      status, homework_group_id, homework_item_id, meta, created_by
    ) values (
      v_academy, p_student_id, 'homework',
      'teacher_input', 'academy', 'staff_present', 'blocked',
      'teacher', 'none', 'db_textbook', 'until_correct',
      'open', v_group, p_homework_item_id,
      jsonb_build_object('origin', 'staff_record_homework_grading_v1'),
      auth.uid()
    )
    returning id into v_session;
  end if;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_uid := nullif(v_item->>'question_uid', '')::uuid;
    v_state := lower(coalesce(v_item->>'state', ''));
    if v_uid is null then
      v_skipped_items := v_skipped_items + 1;
      continue;
    end if;

    v_result := case v_state
      when 'correct' then 'correct'
      when 'wrong' then 'wrong'
      when 'blank' then 'wrong'
      when 'unsolved' then 'wrong'          -- 구버전 상태값 호환
      when 'not_performed' then 'skipped'
      else null                              -- abandoned 등은 기록하지 않음
    end;
    if v_result is null then
      v_skipped_items := v_skipped_items + 1;
      continue;
    end if;

    select * into v_hip
    from public.homework_item_problems p
    where p.homework_item_id = p_homework_item_id
      and p.student_id = p_student_id
      and p.pb_question_uid = v_uid
    order by p.sort_order
    limit 1;

    if v_hip.id is null or v_hip.crop_id is null then
      v_skipped_items := v_skipped_items + 1;
      continue;
    end if;

    v_round := public._student_open_problem_round(
      v_academy,
      p_student_id,
      v_hip.crop_id,
      v_hip.book_id,
      v_hip.grade_label,
      'homework',
      v_group,
      v_hip.id
    );

    select count(*) into v_prior
    from public.learning_attempts la
    where la.round_id = v_round;

    insert into public.learning_exposures (
      academy_id, student_id, session_id, round_id,
      crop_id, pb_question_uid, homework_item_problem_id,
      book_id, grade_label, raw_page, display_page,
      exposure_reason, attempted, meta
    ) values (
      v_academy, p_student_id, v_session, v_round,
      v_hip.crop_id, v_hip.pb_question_uid, v_hip.id,
      v_hip.book_id, v_hip.grade_label, v_hip.raw_page, v_hip.display_page,
      case when v_prior > 0 then 'retry' else 'teacher_assigned' end,
      v_result <> 'skipped',
      jsonb_build_object('teacher_grading', true)
    )
    returning id into v_exposure;

    insert into public.learning_attempts (
      academy_id, student_id, session_id, exposure_id, round_id,
      crop_id, pb_question_uid, homework_item_problem_id,
      book_id, grade_label,
      result, answer_text,
      assist_level, duration_ms, duration_source,
      scored_by, scored_at, scorer_user_id, meta
    ) values (
      v_academy, p_student_id, v_session, v_exposure, v_round,
      v_hip.crop_id, v_hip.pb_question_uid, v_hip.id,
      v_hip.book_id, v_hip.grade_label,
      v_result, null,
      'unknown', null, 'unknown',
      'teacher', now(), auth.uid(),
      jsonb_build_object('teacher_grading', true)
    );

    perform public._student_apply_round_attempt(v_round, v_result, now());

    -- 답 캐시 갱신 — 교재 탭에서도 검사 결과가 그대로 보이게 한다.
    -- 답 내용은 종이 풀이라 모른다: 기존 last_answer 는 유지한다.
    if v_result in ('correct', 'wrong') then
      insert into public.student_textbook_answer_records (
        academy_id, student_id, book_id, grade_label, crop_id,
        last_answer, is_correct, attempt_count, graded_by,
        first_correct_at, updated_at
      ) values (
        v_academy, p_student_id, v_hip.book_id, v_hip.grade_label,
        v_hip.crop_id,
        null, v_result = 'correct', 1, 'teacher',
        case when v_result = 'correct' then now() end, now()
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

  return jsonb_build_object(
    'ok', true,
    'session_id', v_session,
    'homework_group_id', v_group,
    'logged', v_logged,
    'skipped_items', v_skipped_items
  );
end;
$$;

revoke all on function public.staff_record_homework_grading_v1(uuid, uuid, jsonb)
  from public;
grant execute on function public.staff_record_homework_grading_v1(uuid, uuid, jsonb)
  to authenticated;

comment on function public.staff_record_homework_grading_v1(uuid, uuid, jsonb) is
  '선생님의 문항별 채점(homework_test_grading_*)을 learning_attempts·회차·답 '
  '캐시에도 남긴다. 학생앱이 검사 결과(맞은 문항 통과, 틀린 문항 재도전)를 '
  '그대로 볼 수 있게 하는 다리다. 마스터리 완료 판정은 하지 않는다.';

-- ---------------------------------------------------------------------------
-- 3) 매니저앱 회차 조회에 마지막 시도 결과 노출 (미수행 표시용)
-- ---------------------------------------------------------------------------
drop function if exists public.staff_list_problem_rounds_v1(uuid, uuid[]);

create function public.staff_list_problem_rounds_v1(
  p_student_id uuid,
  p_crop_ids uuid[]
) returns table(
  crop_id uuid,
  round_no integer,
  round_open boolean,
  attempt_count integer,
  passed boolean,
  last_result text
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_academy uuid;
begin
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
    raise exception 'staff_list_problem_rounds_v1: forbidden';
  end if;

  return query
  select distinct on (pr.crop_id)
    pr.crop_id,
    pr.round_no,
    pr.closed_at is null,
    pr.attempt_count,
    pr.passed,
    (
      select la.result
      from public.learning_attempts la
      where la.round_id = pr.id
      order by la.attempted_at desc
      limit 1
    )
  from public.student_problem_rounds pr
  where pr.student_id = p_student_id
    and pr.academy_id = v_academy
    and (p_crop_ids is null or pr.crop_id = any(p_crop_ids))
  order by pr.crop_id, pr.round_no desc;
end;
$$;

grant execute on function public.staff_list_problem_rounds_v1(uuid, uuid[])
  to authenticated;
