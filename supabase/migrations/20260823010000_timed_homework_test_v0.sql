-- 시간제한 과제 테스트 V0
--
-- 학생 앱 계약:
--   student_start_or_resume_timed_test_v1(group_id)
--   student_resume_timed_test_v1(group_id)
--   student_timed_test_expose_v1(session_id, crop_id, pb_question_uid, position)
--   student_finish_timed_test_v1(session_id, status)
--
-- 정오 판정은 이 migration에서 받지 않는다. correct/wrong 시도는 정답을
-- 보유한 Edge Function(service role)이 기존 학습 기록 경로로 저장한다.

-- 한 학생은 한 과제 그룹에서 테스트를 한 번만 시작할 수 있다. 완료/포기 후
-- 재시작도 허용하지 않으며, 운영상 무효(void) 처리된 세션만 새로 만들 수 있다.
create unique index if not exists learning_sessions_timed_homework_single_shot_uk
  on public.learning_sessions (student_id, homework_group_id)
  where session_kind = 'daily_test'
    and homework_group_id is not null
    and status <> 'void';

-- 테스트 노출은 position과 실제 배정 문항 양쪽에서 멱등이어야 한다.
create unique index if not exists learning_exposures_test_position_uk
  on public.learning_exposures (session_id, position_in_session)
  where exposure_reason = 'test_blueprint'
    and position_in_session is not null;

create unique index if not exists learning_exposures_test_hw_problem_uk
  on public.learning_exposures (session_id, homework_item_problem_id)
  where exposure_reason = 'test_blueprint'
    and homework_item_problem_id is not null;

-- 마감 재호출이 같은 노출에 timeout을 두 번 만들지 못하게 한다.
create unique index if not exists learning_attempts_timeout_exposure_uk
  on public.learning_attempts (session_id, exposure_id)
  where result = 'timeout'
    and exposure_id is not null;

-- 문제은행 문항 통계의 academy + uid 배치 조회 경로.
create index if not exists learning_exposures_academy_pb_question_idx
  on public.learning_exposures (academy_id, pb_question_uid)
  where pb_question_uid is not null;

-- 기존 helper는 auth.uid()가 없는 service_role을 거부한다. 학습 기록 RPC 중
-- 명시적으로 service_role에 EXECUTE를 부여한 함수만 Edge에서 쓸 수 있도록,
-- row 범위 검사에는 service_role을 신뢰하되 함수 ACL은 계속 별도로 제한한다.
create or replace function public._learning_can_write(
  p_academy_id uuid,
  p_student_id uuid
) returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    auth.role() = 'service_role'
    or exists (
      select 1
      from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id = p_academy_id
    )
    or exists (
      select 1
      from public.student_app_accounts a
      where a.user_id = auth.uid()
        and a.student_id = p_student_id
        and a.academy_id = p_academy_id
    );
$$;

-- 기존 learning_log_attempts는 학생도 호출할 수 있으므로 daily_test에는 그대로
-- 사용할 수 없다. 테스트 정오 결과는 service_role만 기록하고, timeout은 아래
-- finish RPC가 설정한 transaction-local 표식이 있을 때만 허용한다. 세션 행 잠금은
-- 정답 기록과 서버 마감이 동시에 진행되는 경쟁 조건도 직렬화한다.
create or replace function public._learning_guard_timed_test_attempt_v1()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_s public.learning_sessions%rowtype;
  v_e public.learning_exposures%rowtype;
  v_deadline timestamptz;
  v_finish_session text;
begin
  select *
    into v_s
    from public.learning_sessions s
   where s.id = new.session_id
   for update;

  if not found
     or v_s.session_kind <> 'daily_test'
     or v_s.homework_group_id is null then
    return new;
  end if;

  if not v_s.time_limit_enforced
     or coalesce(v_s.time_limit_sec, 0) <= 0 then
    raise exception 'timed_test_attempt: invalid_session';
  end if;

  select *
    into v_e
    from public.learning_exposures e
   where e.id = new.exposure_id
     and e.session_id = new.session_id
     and e.student_id = v_s.student_id
     and e.academy_id = v_s.academy_id
     and e.exposure_reason = 'test_blueprint';

  if not found or v_e.homework_item_problem_id is null then
    raise exception 'timed_test_attempt: valid_exposure_required';
  end if;

  if new.student_id <> v_s.student_id or new.academy_id <> v_s.academy_id then
    raise exception 'timed_test_attempt: owner_mismatch';
  end if;
  if new.crop_id is distinct from v_e.crop_id
     or new.pb_question_uid is distinct from v_e.pb_question_uid
     or new.homework_item_problem_id is distinct from v_e.homework_item_problem_id then
    raise exception 'timed_test_attempt: question_mismatch';
  end if;
  if exists (
    select 1
      from public.learning_attempts a
     where a.exposure_id = new.exposure_id
       and a.result <> 'void'
  ) then
    raise exception 'timed_test_attempt: already_attempted';
  end if;

  v_deadline := v_s.started_at + make_interval(secs => v_s.time_limit_sec);
  v_finish_session := current_setting(
    'app.timed_test_finishing_session',
    true
  );

  if new.result = 'timeout' then
    if v_finish_session is distinct from new.session_id::text
       or clock_timestamp() < v_deadline then
      raise exception 'timed_test_attempt: timeout_forbidden';
    end if;
  else
    if auth.role() is distinct from 'service_role' then
      raise exception 'timed_test_attempt: service_role_required';
    end if;
    if v_s.status <> 'open' or clock_timestamp() >= v_deadline then
      raise exception 'timed_test_attempt: session_closed';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_learning_guard_timed_test_attempt_v1
  on public.learning_attempts;
create trigger trg_learning_guard_timed_test_attempt_v1
before insert on public.learning_attempts
for each row execute function public._learning_guard_timed_test_attempt_v1();

-- 세션의 공통 응답 계약을 한 곳에서 만든다.
create or replace function public._student_timed_test_payload_v1(
  p_session_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_s public.learning_sessions%rowtype;
  v_deadline timestamptz;
  v_now timestamptz := clock_timestamp();
  v_remaining integer;
  v_correct integer;
  v_wrong integer;
  v_skipped integer;
  v_timeout integer;
  v_exposed integer;
  v_answered integer;
  v_denominator integer;
  v_accuracy numeric;
  v_expired boolean;
begin
  select *
    into v_s
    from public.learning_sessions s
   where s.id = p_session_id;

  if not found then
    raise exception 'student_timed_test: session_not_found';
  end if;

  v_deadline := v_s.started_at + make_interval(secs => v_s.time_limit_sec);
  v_remaining := greatest(
    0,
    ceil(extract(epoch from (v_deadline - v_now)))::integer
  );
  v_expired :=
    coalesce((v_s.meta->>'timed_test_expired')::boolean, false)
    or (v_s.status = 'open' and v_now >= v_deadline);

  select
    count(*) filter (where a.result = 'correct')::integer,
    count(*) filter (where a.result = 'wrong')::integer,
    count(*) filter (where a.result = 'skipped')::integer,
    count(*) filter (where a.result = 'timeout')::integer
    into v_correct, v_wrong, v_skipped, v_timeout
    from public.learning_attempts a
   where a.session_id = p_session_id
     and a.result <> 'void';

  select count(*)::integer
    into v_exposed
    from public.learning_exposures e
   where e.session_id = p_session_id;

  v_correct := coalesce(v_correct, 0);
  v_wrong := coalesce(v_wrong, 0);
  v_skipped := coalesce(v_skipped, 0);
  v_timeout := coalesce(v_timeout, 0);
  v_exposed := coalesce(v_exposed, 0);
  v_answered := v_correct + v_wrong + v_skipped;
  v_denominator := v_answered;
  v_accuracy := case
    when v_denominator > 0
      then round(v_correct::numeric / v_denominator::numeric, 4)
    else null
  end;

  return jsonb_build_object(
    'session_id', v_s.id,
    'status', v_s.status,
    'started_at', v_s.started_at,
    'deadline_at', v_deadline,
    'remaining_sec', v_remaining,
    'time_limit_sec', v_s.time_limit_sec,
    'expired', v_expired,
    'ended_at', v_s.ended_at,
    'elapsed_sec', v_s.elapsed_sec,
    'correct', v_correct,
    'wrong', v_wrong,
    'skipped', v_skipped,
    'timeout', v_timeout,
    'answered', v_answered,
    'exposed', v_exposed,
    'accuracy_denominator', v_denominator,
    'accuracy', v_accuracy
  );
end;
$$;

-- 테스트 응시가 끝나면 일반 숙제의 "모든 문항 정답" 규칙과 무관하게 해당
-- 배정을 완료한다. 테스트는 single-shot이므로 오답/패스가 있어도 재응시를
-- 요구하지 않는다. 세션 종료와 같은 트랜잭션에서 실행해 카드가 남지 않게 한다.
create or replace function public._complete_timed_test_homework_v1(
  p_session_id uuid
) returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_s public.learning_sessions%rowtype;
  v_item record;
begin
  select *
    into v_s
    from public.learning_sessions s
   where s.id = p_session_id;

  if not found
     or v_s.session_kind <> 'daily_test'
     or v_s.homework_group_id is null then
    return;
  end if;

  for v_item in
    select gi.homework_item_id as item_id
      from public.homework_group_items gi
      join public.homework_items h
        on h.id = gi.homework_item_id
       and h.academy_id = gi.academy_id
       and h.student_id = gi.student_id
     where gi.group_id = v_s.homework_group_id
       and gi.academy_id = v_s.academy_id
       and gi.student_id = v_s.student_id
       and coalesce(h.status, 0) <> 1
     order by gi.item_order_index
  loop
    update public.homework_assignments a
       set status = 'completed',
           updated_at = now(),
           version = coalesce(a.version, 1) + 1
     where a.academy_id = v_s.academy_id
       and a.homework_item_id = v_item.item_id
       and a.status not in ('completed', 'canceled');

    perform public.homework_complete(v_item.item_id, v_s.academy_id);
  end loop;
end;
$$;

-- 완료/포기 또는 서버 마감. 마감 시에는 마지막으로 노출된 문항 하나만 timeout
-- 처리한다. 아직 노출되지 않은 배정 문항에는 어떤 attempt도 만들지 않는다.
create or replace function public.student_finish_timed_test_v1(
  p_session_id uuid,
  p_status text default 'completed'
) returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  v_s public.learning_sessions%rowtype;
  v_requested_status text := lower(btrim(coalesce(p_status, 'completed')));
  v_now timestamptz := clock_timestamp();
  v_deadline timestamptz;
  v_expired boolean;
  v_end timestamptz;
  v_elapsed integer;
  v_last public.learning_exposures%rowtype;
begin
  select a.academy_id, a.student_id
    into v_academy, v_student
    from public.student_app_accounts a
   where a.user_id = auth.uid();

  if v_student is null then
    raise exception 'student_finish_timed_test_v1: no_student_account';
  end if;
  if p_session_id is null then
    raise exception 'student_finish_timed_test_v1: session_id_required';
  end if;
  if v_requested_status not in ('completed', 'abandoned') then
    raise exception 'student_finish_timed_test_v1: invalid_status';
  end if;

  select *
    into v_s
    from public.learning_sessions s
   where s.id = p_session_id
   for update;

  if not found
     or v_s.academy_id <> v_academy
     or v_s.student_id <> v_student then
    raise exception 'student_finish_timed_test_v1: session_not_found';
  end if;
  if v_s.session_kind <> 'daily_test'
     or v_s.homework_group_id is null
     or not v_s.time_limit_enforced
     or coalesce(v_s.time_limit_sec, 0) <= 0 then
    raise exception 'student_finish_timed_test_v1: invalid_timed_test_session';
  end if;

  -- 이미 닫힌 세션은 상태와 집계를 그대로 반환한다.
  if v_s.status <> 'open' then
    perform public._complete_timed_test_homework_v1(p_session_id);
    return public._student_timed_test_payload_v1(p_session_id);
  end if;

  v_deadline := v_s.started_at + make_interval(secs => v_s.time_limit_sec);
  v_expired := v_now >= v_deadline;
  v_end := case when v_expired then v_deadline else v_now end;
  v_elapsed := least(
    v_s.time_limit_sec,
    greatest(0, floor(extract(epoch from (v_end - v_s.started_at)))::integer)
  );

  if v_expired then
    select e.*
      into v_last
      from public.learning_exposures e
     where e.session_id = p_session_id
       and not exists (
         select 1
           from public.learning_attempts a
          where a.exposure_id = e.id
            and a.result <> 'void'
       )
     order by e.position_in_session desc nulls last, e.exposed_at desc, e.id desc
     limit 1
     for update;

    if v_last.id is not null then
      perform set_config(
        'app.timed_test_finishing_session',
        p_session_id::text,
        true
      );
      insert into public.learning_attempts (
        academy_id, student_id, session_id, exposure_id,
        crop_id, pb_question_uid, homework_item_problem_id,
        book_id, grade_label, unit_id,
        result, assist_level, duration_source,
        scored_by, scored_at, attempted_at, meta
      ) values (
        v_s.academy_id, v_s.student_id, v_s.id, v_last.id,
        v_last.crop_id, v_last.pb_question_uid, v_last.homework_item_problem_id,
        v_last.book_id, v_last.grade_label, v_last.unit_id,
        'timeout', 'none', 'unknown',
        'auto', v_end, v_end,
        jsonb_build_object('origin', 'student_finish_timed_test_v1')
      )
      on conflict do nothing;
    end if;
  end if;

  update public.learning_sessions s
     set status = case when v_expired then 'completed' else v_requested_status end,
         ended_at = v_end,
         elapsed_sec = v_elapsed,
         meta = s.meta || jsonb_build_object('timed_test_expired', v_expired)
   where s.id = p_session_id;

  perform public._complete_timed_test_homework_v1(p_session_id);

  return public._student_timed_test_payload_v1(p_session_id);
end;
$$;

-- 시작과 재개는 같은 원자적 계약이다. 테스트 child가 여러 개면 모두 양의
-- time_limit_minutes를 가져야 하며, 가장 짧은 값을 세션 제한시간으로 사용한다.
create or replace function public.student_start_or_resume_timed_test_v1(
  p_homework_group_id uuid
) returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  v_group public.homework_groups%rowtype;
  v_session public.learning_sessions%rowtype;
  v_test_child_count integer;
  v_invalid_limit_count integer;
  v_limit_minutes bigint;
  v_limit_sec integer;
begin
  select a.academy_id, a.student_id
    into v_academy, v_student
    from public.student_app_accounts a
   where a.user_id = auth.uid();

  if v_student is null then
    raise exception 'student_start_or_resume_timed_test_v1: no_student_account';
  end if;
  if p_homework_group_id is null then
    raise exception 'student_start_or_resume_timed_test_v1: group_id_required';
  end if;

  -- 그룹 행 잠금으로 같은 학생의 동시 start 요청을 직렬화한다.
  select *
    into v_group
    from public.homework_groups g
   where g.id = p_homework_group_id
     and g.academy_id = v_academy
     and g.student_id = v_student
   for update;

  if not found then
    raise exception 'student_start_or_resume_timed_test_v1: group_not_found';
  end if;

  with test_children as (
    select h.time_limit_minutes
      from public.homework_group_items gi
      join public.homework_items h
        on h.id = gi.homework_item_id
       and h.academy_id = gi.academy_id
       and h.student_id = gi.student_id
     where gi.group_id = p_homework_group_id
       and gi.academy_id = v_academy
       and gi.student_id = v_student
       and (
         coalesce(h.type, '') = '테스트'
         or h.test_origin_flow_id is not null
         or exists (
           select 1
             from public.student_flows sf
            where sf.id = h.flow_id
              and sf.academy_id = v_academy
              and sf.student_id = v_student
              and sf.name = '테스트'
         )
       )
  )
  select
    count(*)::integer,
    count(*) filter (where coalesce(time_limit_minutes, 0) <= 0)::integer,
    min(time_limit_minutes)::bigint
    into v_test_child_count, v_invalid_limit_count, v_limit_minutes
    from test_children;

  if coalesce(v_test_child_count, 0) = 0 then
    raise exception 'student_start_or_resume_timed_test_v1: not_a_test_group';
  end if;
  if coalesce(v_invalid_limit_count, 0) > 0 or coalesce(v_limit_minutes, 0) <= 0 then
    raise exception 'student_start_or_resume_timed_test_v1: invalid_time_limit';
  end if;
  if v_limit_minutes > 35791394 then
    raise exception 'student_start_or_resume_timed_test_v1: time_limit_out_of_range';
  end if;
  v_limit_sec := (v_limit_minutes * 60)::integer;

  select *
    into v_session
    from public.learning_sessions s
   where s.student_id = v_student
     and s.homework_group_id = p_homework_group_id
     and s.session_kind = 'daily_test'
     and s.status <> 'void'
   order by s.started_at desc
   limit 1
   for update;

  if found then
    if v_session.status = 'open'
       and clock_timestamp() >=
           v_session.started_at + make_interval(secs => v_session.time_limit_sec) then
      return public.student_finish_timed_test_v1(v_session.id, 'completed');
    end if;
    return public._student_timed_test_payload_v1(v_session.id);
  end if;

  begin
    insert into public.learning_sessions (
      academy_id, student_id, session_kind,
      platform, location_kind, supervision, answer_access,
      scored_by, timing_source, material_kind, retry_policy,
      time_limit_sec, time_limit_enforced,
      status, started_at, homework_group_id, flow_id,
      meta, created_by
    ) values (
      v_academy, v_student, 'daily_test',
      'student_app', 'unknown', 'unknown', 'blocked',
      'auto', 'per_item', 'mixed', 'single_shot',
      v_limit_sec, true,
      'open', clock_timestamp(), p_homework_group_id, v_group.flow_id,
      jsonb_build_object(
        'origin', 'student_start_or_resume_timed_test_v1',
        'time_limit_policy', 'minimum_test_child'
      ),
      auth.uid()
    )
    returning * into v_session;
  exception
    when unique_violation then
      select *
        into v_session
        from public.learning_sessions s
       where s.student_id = v_student
         and s.homework_group_id = p_homework_group_id
         and s.session_kind = 'daily_test'
         and s.status <> 'void'
       order by s.started_at desc
       limit 1;
      if not found then
        raise;
      end if;
  end;

  return public._student_timed_test_payload_v1(v_session.id);
end;
$$;

create or replace function public.student_resume_timed_test_v1(
  p_homework_group_id uuid
) returns jsonb
language sql
volatile
security definer
set search_path = public
as $$
  select public.student_start_or_resume_timed_test_v1(p_homework_group_id);
$$;

-- 앱이 제한시간 이후 다시 열렸지만 해당 테스트 카드에 직접 재진입하지 않은
-- 경우도 정리한다. 과제 목록을 새로고침할 때 호출하며, 시작하지 않은 테스트는
-- 건드리지 않는다.
create or replace function public.student_finalize_expired_timed_tests_v1()
returns integer
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  v_session record;
  v_count integer := 0;
begin
  select a.academy_id, a.student_id
    into v_academy, v_student
    from public.student_app_accounts a
   where a.user_id = auth.uid();

  if v_student is null then
    raise exception 'student_finalize_expired_timed_tests_v1: no_student_account';
  end if;

  for v_session in
    select s.id
      from public.learning_sessions s
     where s.academy_id = v_academy
       and s.student_id = v_student
       and s.session_kind = 'daily_test'
       and s.homework_group_id is not null
       and s.status = 'open'
       and s.time_limit_enforced
       and coalesce(s.time_limit_sec, 0) > 0
       and clock_timestamp() >=
           s.started_at + make_interval(secs => s.time_limit_sec)
     order by s.started_at
  loop
    perform public.student_finish_timed_test_v1(v_session.id, 'completed');
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- 배정 스냅샷에 실제로 포함된 문항만 노출한다. crop_id와 pb_question_uid를
-- 둘 다 보내면 같은 homework_item_problems 행에서 둘 다 일치해야 한다.
create or replace function public.student_timed_test_expose_v1(
  p_session_id uuid,
  p_crop_id uuid,
  p_pb_question_uid uuid,
  p_position_in_session integer
) returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  v_s public.learning_sessions%rowtype;
  v_hip public.homework_item_problems%rowtype;
  v_existing public.learning_exposures%rowtype;
  v_exposure public.learning_exposures%rowtype;
  v_deadline timestamptz;
  v_remaining integer;
  v_finished jsonb;
begin
  select a.academy_id, a.student_id
    into v_academy, v_student
    from public.student_app_accounts a
   where a.user_id = auth.uid();

  if v_student is null then
    raise exception 'student_timed_test_expose_v1: no_student_account';
  end if;
  if p_session_id is null then
    raise exception 'student_timed_test_expose_v1: session_id_required';
  end if;
  if p_crop_id is null and p_pb_question_uid is null then
    raise exception 'student_timed_test_expose_v1: question_id_required';
  end if;
  if coalesce(p_position_in_session, 0) <= 0 then
    raise exception 'student_timed_test_expose_v1: invalid_position';
  end if;

  -- 세션 잠금은 동일 세션의 position/item 멱등 검사를 원자화한다.
  select *
    into v_s
    from public.learning_sessions s
   where s.id = p_session_id
   for update;

  if not found
     or v_s.academy_id <> v_academy
     or v_s.student_id <> v_student then
    raise exception 'student_timed_test_expose_v1: session_not_found';
  end if;
  if v_s.session_kind <> 'daily_test'
     or v_s.homework_group_id is null
     or not v_s.time_limit_enforced
     or coalesce(v_s.time_limit_sec, 0) <= 0 then
    raise exception 'student_timed_test_expose_v1: invalid_timed_test_session';
  end if;
  if v_s.status <> 'open' then
    raise exception 'student_timed_test_expose_v1: session_closed';
  end if;

  v_deadline := v_s.started_at + make_interval(secs => v_s.time_limit_sec);
  if clock_timestamp() >= v_deadline then
    v_finished := public.student_finish_timed_test_v1(p_session_id, 'completed');
    return v_finished || jsonb_build_object(
      'ok', false,
      'error', 'session_expired'
    );
  end if;

  select p.*
    into v_hip
    from public.homework_item_problems p
    join public.homework_group_items gi
      on gi.homework_item_id = p.homework_item_id
     and gi.academy_id = p.academy_id
     and gi.student_id = p.student_id
   where gi.group_id = v_s.homework_group_id
     and p.academy_id = v_academy
     and p.student_id = v_student
     and (p_crop_id is null or p.crop_id = p_crop_id)
     and (p_pb_question_uid is null or p.pb_question_uid = p_pb_question_uid)
   order by gi.item_order_index, p.sort_order
   limit 1;

  if not found then
    raise exception 'student_timed_test_expose_v1: question_not_assigned';
  end if;

  select e.*
    into v_existing
    from public.learning_exposures e
   where e.session_id = p_session_id
     and (
       e.position_in_session = p_position_in_session
       or e.homework_item_problem_id = v_hip.id
     )
   order by e.exposed_at
   limit 1;

  if found then
    if v_existing.homework_item_problem_id is distinct from v_hip.id then
      raise exception 'student_timed_test_expose_v1: position_conflict';
    end if;
    v_exposure := v_existing;
  else
    insert into public.learning_exposures (
      academy_id, student_id, session_id,
      crop_id, pb_question_uid, homework_item_problem_id,
      book_id, grade_label, raw_page, display_page,
      exposure_reason, position_in_session, attempted, meta
    ) values (
      v_academy, v_student, p_session_id,
      v_hip.crop_id, v_hip.pb_question_uid, v_hip.id,
      v_hip.book_id, v_hip.grade_label, v_hip.raw_page, v_hip.display_page,
      'test_blueprint', p_position_in_session, false,
      jsonb_build_object('origin', 'student_timed_test_expose_v1')
    )
    returning * into v_exposure;
  end if;

  v_remaining := greatest(
    0,
    ceil(extract(epoch from (v_deadline - clock_timestamp())))::integer
  );

  return jsonb_build_object(
    'exposure_id', v_exposure.id,
    'session_id', p_session_id,
    'homework_item_problem_id', v_hip.id,
    'crop_id', v_hip.crop_id,
    'pb_question_uid', v_hip.pb_question_uid,
    'position_in_session', v_exposure.position_in_session,
    'exposed_at', v_exposure.exposed_at,
    'deadline_at', v_deadline,
    'remaining_sec', v_remaining,
    'expired', false
  );
end;
$$;

-- 매니저앱 문제은행 배치 통계. 호출자의 모든 staff membership academy만
-- 합산하므로 academy 인자를 신뢰하지 않으며 다른 tenant 데이터는 포함되지 않는다.
create or replace function public.pb_question_timed_test_stats_batch_v1(
  p_question_uids uuid[]
) returns table(
  question_uid uuid,
  assigned_student_count bigint,
  exposed_student_count bigint,
  responded_student_count bigint
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1
      from public.memberships m
     where m.user_id = auth.uid()
  ) then
    raise exception 'pb_question_timed_test_stats_batch_v1: forbidden';
  end if;

  return query
  with requested as (
    select distinct u.question_uid
      from unnest(coalesce(p_question_uids, array[]::uuid[])) as u(question_uid)
     where u.question_uid is not null
  ),
  allowed_academies as (
    select m.academy_id
      from public.memberships m
     where m.user_id = auth.uid()
  ),
  assigned as (
    select
      p.pb_question_uid as question_uid,
      count(distinct p.student_id)::bigint as student_count
    from public.homework_item_problems p
    join requested r on r.question_uid = p.pb_question_uid
    join allowed_academies aa on aa.academy_id = p.academy_id
    join public.homework_items h
      on h.id = p.homework_item_id
     and h.academy_id = p.academy_id
     and h.student_id = p.student_id
    where
      coalesce(h.type, '') = '테스트'
      or h.test_origin_flow_id is not null
      or exists (
        select 1
          from public.student_flows sf
         where sf.id = h.flow_id
           and sf.academy_id = h.academy_id
           and sf.student_id = h.student_id
           and sf.name = '테스트'
      )
    group by p.pb_question_uid
  ),
  exposed as (
    select
      e.pb_question_uid as question_uid,
      count(distinct e.student_id)::bigint as student_count
    from public.learning_exposures e
    join requested r on r.question_uid = e.pb_question_uid
    join allowed_academies aa on aa.academy_id = e.academy_id
    join public.learning_sessions s
      on s.id = e.session_id
     and s.academy_id = e.academy_id
     and s.student_id = e.student_id
     and s.session_kind = 'daily_test'
    group by e.pb_question_uid
  ),
  responded as (
    select
      a.pb_question_uid as question_uid,
      count(distinct a.student_id)::bigint as student_count
    from public.learning_attempts a
    join requested r on r.question_uid = a.pb_question_uid
    join allowed_academies aa on aa.academy_id = a.academy_id
    join public.learning_sessions s
      on s.id = a.session_id
     and s.academy_id = a.academy_id
     and s.student_id = a.student_id
     and s.session_kind = 'daily_test'
    where a.result in ('correct', 'wrong')
    group by a.pb_question_uid
  )
  select
    r.question_uid,
    coalesce(a.student_count, 0)::bigint,
    coalesce(e.student_count, 0)::bigint,
    coalesce(x.student_count, 0)::bigint
  from requested r
  left join assigned a on a.question_uid = r.question_uid
  left join exposed e on e.question_uid = r.question_uid
  left join responded x on x.question_uid = r.question_uid
  order by r.question_uid;
end;
$$;

revoke all on function public._student_timed_test_payload_v1(uuid) from public;
revoke all on function public._learning_guard_timed_test_attempt_v1() from public;
revoke all on function public._complete_timed_test_homework_v1(uuid) from public;

-- 기존 범용 기록 RPC는 신뢰된 Edge Function이 시간제한 세션의 정오 결과를
-- 저장할 수 있도록 service_role에만 추가 개방한다.
grant execute on function public.learning_log_attempts(uuid, jsonb)
  to service_role;

revoke all on function public.student_start_or_resume_timed_test_v1(uuid) from public;
grant execute on function public.student_start_or_resume_timed_test_v1(uuid)
  to authenticated;

revoke all on function public.student_resume_timed_test_v1(uuid) from public;
grant execute on function public.student_resume_timed_test_v1(uuid)
  to authenticated;

revoke all on function public.student_finalize_expired_timed_tests_v1() from public;
grant execute on function public.student_finalize_expired_timed_tests_v1()
  to authenticated;

revoke all on function public.student_timed_test_expose_v1(uuid, uuid, uuid, integer)
  from public;
grant execute on function public.student_timed_test_expose_v1(uuid, uuid, uuid, integer)
  to authenticated;

revoke all on function public.student_finish_timed_test_v1(uuid, text) from public;
grant execute on function public.student_finish_timed_test_v1(uuid, text)
  to authenticated;

revoke all on function public.pb_question_timed_test_stats_batch_v1(uuid[]) from public;
grant execute on function public.pb_question_timed_test_stats_batch_v1(uuid[])
  to authenticated;

comment on function public.student_start_or_resume_timed_test_v1(uuid) is
  '학생 본인의 시간제한 테스트를 단 한 번 시작하거나 기존 세션을 재개한다. '
  '반환: session_id,status,started_at,deadline_at,remaining_sec,time_limit_sec,expired 및 결과 집계.';

comment on function public.student_resume_timed_test_v1(uuid) is
  'student_start_or_resume_timed_test_v1과 동일한 멱등 재개 계약.';

comment on function public.student_finalize_expired_timed_tests_v1() is
  '학생 과제 목록 새로고침 시 이미 마감된 열린 시간제한 테스트를 완료·과제 종료 처리한다.';

comment on function public.student_timed_test_expose_v1(uuid, uuid, uuid, integer) is
  '과제 그룹에 실제 배정된 문항만 test_blueprint로 멱등 노출하고 서버 remaining_sec를 반환한다.';

comment on function public.student_finish_timed_test_v1(uuid, text) is
  'completed/abandoned 종료. 서버 마감이면 completed로 강제하고 마지막 미응답 노출 하나에 timeout을 멱등 기록한다.';

comment on function public.pb_question_timed_test_stats_batch_v1(uuid[]) is
  '호출 staff의 membership academy 범위에서 테스트 배정/노출/correct-or-wrong 응답 학생 수를 UID 배열로 일괄 집계한다.';
