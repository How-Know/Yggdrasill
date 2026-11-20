-- 과제 완료 정합성 동기화:
--   1) homework_complete 실행 시 해당 과제에 배정된 문항(homework_item_problems) 중
--      아직 이 배정에서 정답(통과) 처리되지 않은 문항들만 찾아
--      선생님 완료 통과('correct') 시도를 1건 덧붙여 통과(passed=true)로 마감한다.
--      * 이미 정답이었던 문항은 절대 건드리지 않으므로 수정 횟수·최초 정답 여부·
--        기존 답안 데이터가 그대로 보존된다.
--      * 오답 기록이 있던 문항은 기존 오답 시도에 이번 통과 시도가 덧붙어
--        "몇 번 고쳐서 통과했는지"가 정확히 남는다.
--   2) staff_record_homework_grading_v1 에서도 답 캐시 신규 삽입 시
--      first_attempt_correct = (v_result = 'correct')를 정확히 남긴다.
--   3) student_list_textbooks 의 teacher_done 에 신형 homework_item_problems 완료분도
--      함께 포함하고, student_textbook_answer_records / student_textbook_seasons 를
--      supabase_realtime publication 에 등록해 학생앱 교재 탭이 즉시 동기화되게 한다.

-- ---------------------------------------------------------------------------
-- 1) Realtime publication 등록 (학생앱 교재 탭 실시간 동기화용)
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (
      select 1
      from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = 'student_textbook_answer_records'
    ) then
      execute 'alter publication supabase_realtime add table public.student_textbook_answer_records';
    end if;

    if not exists (
      select 1
      from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = 'student_textbook_seasons'
    ) then
      execute 'alter publication supabase_realtime add table public.student_textbook_seasons';
    end if;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2) staff_record_homework_grading_v1: 신규 답 캐시 first_attempt_correct 보정
-- ---------------------------------------------------------------------------
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
      when 'unsolved' then 'wrong'
      when 'not_performed' then 'skipped'
      else null
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

    -- 이미 이번 배정에서 정답 통과된 문항을 같은 'correct'로 다시 덮어써
    -- 불필요하게 새 회차나 시도 수를 늘리지 않는다.
    if v_result = 'correct' and exists (
      select 1
      from public.learning_attempts la
      where la.homework_item_problem_id = v_hip.id
        and la.result = 'correct'
    ) then
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

    if v_result in ('correct', 'wrong') then
      insert into public.student_textbook_answer_records (
        academy_id, student_id, book_id, grade_label, crop_id,
        last_answer, is_correct, first_attempt_correct, attempt_count, graded_by,
        first_correct_at, updated_at
      ) values (
        v_academy, p_student_id, v_hip.book_id, v_hip.grade_label,
        v_hip.crop_id,
        null, v_result = 'correct', v_result = 'correct', 1, 'teacher',
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

-- ---------------------------------------------------------------------------
-- 3) 과제 완료 시 미통과 문항만 통과 처리하는 내부 동기화 함수
-- ---------------------------------------------------------------------------
-- 시간제한 테스트(daily_test)는 single-shot 시험이라 오답을 억지로 정답으로
-- 덮지 않으며, 일반 과제만 아직 정답이 아닌 배정 문항들을 통과 마감한다.
create or replace function public._homework_sync_unpassed_problems_on_complete(
  p_academy_id uuid,
  p_item_id uuid,
  p_completed_at timestamptz default now()
) returns integer
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_item public.homework_items%rowtype;
  v_group_id uuid;
  v_session uuid;
  v_hip public.homework_item_problems%rowtype;
  v_round uuid;
  v_exposure uuid;
  v_prior integer;
  v_synced integer := 0;
  v_at timestamptz := coalesce(p_completed_at, now());
begin
  select * into v_item
  from public.homework_items hi
  where hi.id = p_item_id
    and hi.academy_id = p_academy_id;

  if not found or v_item.student_id is null then
    return 0;
  end if;

  -- 시간제한 테스트는 시험 결과 그대로 보존한다.
  if coalesce(v_item.time_limit_minutes, 0) > 0 then
    return 0;
  end if;
  if exists (
    select 1
    from public.homework_group_items gi
    join public.learning_sessions ls
      on ls.homework_group_id = gi.group_id
     and ls.academy_id = p_academy_id
     and ls.session_kind = 'daily_test'
    where gi.homework_item_id = p_item_id
      and gi.academy_id = p_academy_id
  ) then
    return 0;
  end if;

  select gi.group_id into v_group_id
  from public.homework_group_items gi
  where gi.academy_id = p_academy_id
    and gi.homework_item_id = p_item_id
  limit 1;

  for v_hip in
    select p.*
    from public.homework_item_problems p
    where p.academy_id = p_academy_id
      and p.homework_item_id = p_item_id
      and p.student_id = v_item.student_id
      and p.excluded_at is null
      and p.crop_id is not null
      -- 이미 이 배정에서 정답을 맞힌 문항은 원래 기록(수정 횟수·답안 등)을 보존한다.
      and not exists (
        select 1
        from public.learning_attempts la
        where la.homework_item_problem_id = p.id
          and la.result = 'correct'
      )
      -- 같은 시즌 안에서 이 배정 생성 이후 이미 통과된 회차가 있는 문항도 건드리지 않는다.
      and not exists (
        select 1
        from public.student_problem_rounds pr
        where pr.student_id = v_item.student_id
          and pr.crop_id = p.crop_id
          and pr.passed
          and (
            pr.homework_item_problem_id = p.id
            or pr.first_correct_at >= coalesce(v_item.created_at, '-infinity'::timestamptz)
          )
      )
    order by p.sort_order
  loop
    if v_session is null then
      select s.id into v_session
      from public.learning_sessions s
      where s.student_id = v_item.student_id
        and s.academy_id = p_academy_id
        and s.scored_by = 'teacher'
        and s.status = 'open'
        and s.session_kind = 'homework'
        and s.homework_item_id = p_item_id
        and s.started_at > v_at - interval '12 hours'
      order by s.started_at desc
      limit 1;

      if v_session is null then
        insert into public.learning_sessions (
          academy_id, student_id, session_kind,
          platform, location_kind, supervision, answer_access,
          scored_by, timing_source, material_kind, retry_policy,
          status, homework_group_id, homework_item_id,
          book_id, grade_label, started_at, ended_at, meta, created_by
        ) values (
          p_academy_id, v_item.student_id, 'homework',
          'teacher_input', 'academy', 'staff_present', 'blocked',
          'teacher', 'none', 'db_textbook', 'until_correct',
          'completed', v_group_id, p_item_id,
          v_hip.book_id, v_hip.grade_label, v_at, v_at,
          jsonb_build_object('origin', 'homework_complete_sync'),
          auth.uid()
        )
        returning id into v_session;
      end if;
    end if;

    v_round := public._student_open_problem_round(
      p_academy_id,
      v_item.student_id,
      v_hip.crop_id,
      v_hip.book_id,
      v_hip.grade_label,
      'homework',
      v_group_id,
      v_hip.id
    );

    select count(*) into v_prior
    from public.learning_attempts la
    where la.round_id = v_round
      and la.result in ('correct', 'wrong', 'partial');

    insert into public.learning_exposures (
      academy_id, student_id, session_id, round_id,
      crop_id, pb_question_uid, homework_item_problem_id,
      book_id, grade_label, raw_page, display_page,
      exposure_reason, attempted, exposed_at, meta
    ) values (
      p_academy_id, v_item.student_id, v_session, v_round,
      v_hip.crop_id, v_hip.pb_question_uid, v_hip.id,
      v_hip.book_id, v_hip.grade_label, v_hip.raw_page, v_hip.display_page,
      case when v_prior > 0 then 'retry' else 'teacher_assigned' end,
      true, v_at,
      jsonb_build_object('homework_complete_sync', true)
    )
    returning id into v_exposure;

    insert into public.learning_attempts (
      academy_id, student_id, session_id, exposure_id, round_id,
      crop_id, pb_question_uid, homework_item_problem_id,
      book_id, grade_label,
      result, answer_text,
      assist_level, duration_ms, duration_source,
      scored_by, attempted_at, scored_at, scorer_user_id, meta
    ) values (
      p_academy_id, v_item.student_id, v_session, v_exposure, v_round,
      v_hip.crop_id, v_hip.pb_question_uid, v_hip.id,
      v_hip.book_id, v_hip.grade_label,
      'correct', null,
      'unknown', null, 'unknown',
      'teacher', v_at, v_at, auth.uid(),
      jsonb_build_object('homework_complete_sync', true)
    );

    perform public._student_apply_round_attempt(v_round, 'correct', v_at);

    -- 답 캐시 갱신:
    --   · 아예 기록이 없던 문항이면 첫 시도에 통과한 것으로 기록 (attempt_count = 1, first_attempt_correct = true)
    --   · 오답 상태로 남아 있던 문항이면 기존 last_answer·first_attempt_correct 는 보존하고
    --     수정을 거쳐 통과한 것으로 attempt_count 만 +1 올린다.
    insert into public.student_textbook_answer_records (
      academy_id, student_id, book_id, grade_label, crop_id,
      last_answer, is_correct, first_attempt_correct, attempt_count, graded_by,
      first_correct_at, updated_at
    ) values (
      p_academy_id, v_item.student_id, v_hip.book_id, v_hip.grade_label,
      v_hip.crop_id,
      null, true, true, 1, 'teacher',
      v_at, v_at
    )
    on conflict (student_id, crop_id) do update
    set is_correct = true,
        attempt_count = case
          when student_textbook_answer_records.is_correct
               and coalesce(student_textbook_answer_records.attempt_count, 0) > 0
            then student_textbook_answer_records.attempt_count
          else coalesce(student_textbook_answer_records.attempt_count, 0) + 1
        end,
        graded_by = case
          when student_textbook_answer_records.is_correct
               and coalesce(student_textbook_answer_records.attempt_count, 0) > 0
            then student_textbook_answer_records.graded_by
          else 'teacher'
        end,
        first_correct_at = coalesce(
          student_textbook_answer_records.first_correct_at,
          excluded.first_correct_at
        ),
        updated_at = v_at;

    v_synced := v_synced + 1;
  end loop;

  return v_synced;
end;
$$;

revoke all on function public._homework_sync_unpassed_problems_on_complete(uuid, uuid, timestamptz)
  from public;

-- ---------------------------------------------------------------------------
-- 4) homework_complete 에 문항 통과 동기화 연결
-- ---------------------------------------------------------------------------
create or replace function public.homework_complete(
  p_item_id uuid,
  p_academy_id uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group_id uuid;
  v_now timestamptz := now();
begin
  update public.homework_items hi
     set accumulated_ms = coalesce(hi.accumulated_ms, 0)
                          + case
                              when hi.run_start is not null
                                then extract(epoch from (v_now - hi.run_start))::bigint * 1000
                              else 0
                            end,
         run_start = null,
         completed_at = coalesce(hi.completed_at, v_now),
         status = 1,
         student_level_current_snapshot = (
           select s.current_level_code
             from public.student_level_states s
            where s.student_id = hi.student_id
              and s.academy_id = hi.academy_id
            limit 1
         ),
         student_level_target_snapshot = (
           select s.target_level_code
             from public.student_level_states s
            where s.student_id = hi.student_id
              and s.academy_id = hi.academy_id
            limit 1
         ),
         updated_at = v_now,
         version = coalesce(hi.version, 1) + 1
   where hi.id = p_item_id
     and hi.academy_id = p_academy_id;

  if not found then
    return;
  end if;

  -- 아직 통과 전인 배정 문항들을 완료 통과로 동기화 (기존 정답 데이터는 보존).
  perform public._homework_sync_unpassed_problems_on_complete(
    p_academy_id,
    p_item_id,
    v_now
  );

  select gi.group_id
    into v_group_id
    from public.homework_group_items gi
   where gi.academy_id = p_academy_id
     and gi.homework_item_id = p_item_id
   limit 1;

  if v_group_id is not null then
    perform public.homework_archive_group_if_fully_completed(
      p_academy_id,
      v_group_id
    );
  end if;
end;
$$;

revoke all on function public.homework_complete(uuid, uuid) from public;
grant execute on function public.homework_complete(uuid, uuid)
  to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5) 기존에 바로 완료 처리되어 문항 통과가 비어 있던 완료 과제 백필
-- ---------------------------------------------------------------------------
do $$
declare
  r record;
begin
  for r in
    select distinct hi.academy_id, hi.id as item_id, coalesce(hi.completed_at, hi.confirmed_at, hi.updated_at, now()) as done_at
    from public.homework_items hi
    join public.homework_item_problems hip
      on hip.homework_item_id = hi.id
     and hip.academy_id = hi.academy_id
     and hip.excluded_at is null
    where (coalesce(hi.status, 0) = 1 or hi.completed_at is not null)
      and coalesce(hi.time_limit_minutes, 0) <= 0
      and not exists (
        select 1
        from public.learning_attempts la
        where la.homework_item_problem_id = hip.id
          and la.result = 'correct'
      )
    order by done_at
  loop
    perform public._homework_sync_unpassed_problems_on_complete(
      r.academy_id,
      r.item_id,
      r.done_at
    );
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 6) student_list_textbooks: teacher_done 에 신형 homework_item_problems 완료분도 포함
-- ---------------------------------------------------------------------------
drop function if exists public.student_list_textbooks();
create function public.student_list_textbooks()
returns table(
  book_id uuid,
  grade_label text,
  book_name text,
  book_description text,
  book_color integer,
  series text,
  cover_ref text,
  total_problems bigint,
  graded_count bigint,
  correct_count bigint,
  completed_count bigint,
  first_wrong_count bigint,
  corrected_count bigint,
  stage_progress jsonb,
  last_raw_page integer,
  last_display_page integer,
  last_activity timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
begin
  select i.academy_id, i.student_id
    into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  return query
  with books as (
    select distinct l.book_id, l.grade_label
    from public.student_flows f
    join public.flow_textbook_links l
      on l.flow_id = f.id
     and l.academy_id = f.academy_id
    where f.academy_id = v_academy
      and f.student_id = v_student
      and coalesce(f.enabled, true)
  ),
  open_seasons as (
    select distinct on (s.book_id, s.grade_label)
      s.book_id,
      s.grade_label,
      s.id as season_id,
      s.season_no,
      s.opened_at
    from public.student_textbook_seasons s
    where s.student_id = v_student
      and s.closed_at is null
    order by s.book_id, s.grade_label, s.season_no desc
  ),
  gradable as (
    select
      c.book_id,
      c.grade_label,
      c.id as crop_id,
      c.sub_key,
      c.raw_page,
      c.display_page,
      os.season_id,
      coalesce(os.season_no, 1) as season_no,
      os.opened_at as season_opened_at
    from public.textbook_problem_crops c
    join public.textbook_problem_answers a on a.crop_id = c.id
    join books b
      on b.book_id = c.book_id
     and b.grade_label = c.grade_label
    left join open_seasons os
      on os.book_id = c.book_id
     and os.grade_label = coalesce(c.grade_label, '')
    where c.academy_id = v_academy
      and not c.is_set_header
      and (
        (
          a.answer_kind in ('objective', 'subjective')
          and coalesce(a.answer_text, a.answer_latex_2d) is not null
        )
        or a.answer_kind = 'image'
      )
      and not public._student_crop_on_hold(v_student, c.id)
  ),
  season_passed as (
    select distinct g.crop_id
    from gradable g
    join public.student_problem_rounds pr
      on pr.student_id = v_student
     and pr.crop_id = g.crop_id
     and pr.passed
     and (
       (g.season_id is not null and pr.season_id = g.season_id)
       or (g.season_id is null and pr.season_id is null)
     )
  ),
  teacher_done as (
    select distinct g.crop_id
    from gradable g
    join public.homework_item_units u
      on u.academy_id = v_academy
     and u.student_id = v_student
     and u.book_id = g.book_id
     and u.grade_label = g.grade_label
    join public.homework_items h
      on h.id = u.homework_item_id
     and h.student_id = v_student
     and h.academy_id = v_academy
    where (
      h.completed_at is not null
      or coalesce(h.status, 0) = 1
      or h.confirmed_at is not null
      or coalesce(h.phase, 0) = 4
    )
    and (
      g.season_no <= 1
      or coalesce(h.completed_at, h.confirmed_at, h.created_at) >= g.season_opened_at
    )
    and (
      g.raw_page between least(coalesce(u.start_page, g.raw_page), coalesce(u.end_page, g.raw_page))
                     and greatest(coalesce(u.start_page, g.raw_page), coalesce(u.end_page, g.raw_page))
      or g.display_page between least(coalesce(u.start_page, g.display_page), coalesce(u.end_page, g.display_page))
                            and greatest(coalesce(u.start_page, g.display_page), coalesce(u.end_page, g.display_page))
    )
    union
    select distinct g.crop_id
    from gradable g
    join public.homework_item_problems hip
      on hip.academy_id = v_academy
     and hip.student_id = v_student
     and hip.crop_id = g.crop_id
     and hip.excluded_at is null
    join public.homework_items h
      on h.id = hip.homework_item_id
     and h.student_id = v_student
     and h.academy_id = v_academy
    where (
      h.completed_at is not null
      or coalesce(h.status, 0) = 1
      or (coalesce(h.phase, 0) = 4 and coalesce(h.pending_complete, false))
    )
    and coalesce(h.time_limit_minutes, 0) <= 0
    and (
      g.season_no <= 1
      or coalesce(h.completed_at, h.confirmed_at, h.created_at) >= g.season_opened_at
    )
  ),
  marked as (
    select
      g.*,
      r.id as record_id,
      (r.id is not null and coalesce(r.attempt_count, 0) > 0) as has_active_record,
      coalesce(r.is_correct, false) as is_correct,
      coalesce(r.first_attempt_correct, false) as first_attempt_correct,
      r.updated_at,
      (sp.crop_id is not null) as has_season_pass,
      (
        coalesce(r.is_correct, false)
        or sp.crop_id is not null
        or td.crop_id is not null
      ) as is_completed
    from gradable g
    left join public.student_textbook_answer_records r
      on r.crop_id = g.crop_id
     and r.student_id = v_student
    left join season_passed sp on sp.crop_id = g.crop_id
    left join teacher_done td on td.crop_id = g.crop_id
  ),
  book_stats as (
    select
      m.book_id,
      m.grade_label,
      count(*) as total_problems,
      count(*) filter (where m.has_active_record or m.has_season_pass) as graded_count,
      count(*) filter (
        where (m.has_active_record or m.has_season_pass) and m.first_attempt_correct
      ) as correct_count,
      count(*) filter (where m.is_completed) as completed_count,
      count(*) filter (
        where (m.has_active_record or m.has_season_pass)
          and not m.first_attempt_correct
      ) as first_wrong_count,
      count(*) filter (
        where (m.has_active_record or m.has_season_pass)
          and not m.first_attempt_correct
          and (m.is_correct or m.has_season_pass)
      ) as corrected_count,
      max(m.updated_at) as last_activity
    from marked m
    group by m.book_id, m.grade_label
  ),
  stage_rows as (
    select
      m.book_id,
      m.grade_label,
      upper(coalesce(nullif(m.sub_key, ''), 'A')) as sub_key,
      count(*) as total,
      count(*) filter (where m.has_active_record or m.has_season_pass) as graded,
      count(*) filter (
        where (m.has_active_record or m.has_season_pass) and m.first_attempt_correct
      ) as correct,
      count(*) filter (where m.is_completed) as completed
    from marked m
    group by m.book_id, m.grade_label,
      upper(coalesce(nullif(m.sub_key, ''), 'A'))
  ),
  stages as (
    select
      s.book_id,
      s.grade_label,
      jsonb_object_agg(
        s.sub_key,
        jsonb_build_object(
          'total', s.total,
          'graded', s.graded,
          'correct', s.correct,
          'completed', s.completed
        )
        order by s.sub_key
      ) as progress
    from stage_rows s
    group by s.book_id, s.grade_label
  ),
  last_rec as (
    select distinct on (r.book_id, r.grade_label)
      r.book_id,
      r.grade_label,
      c.raw_page,
      c.display_page
    from public.student_textbook_answer_records r
    join public.textbook_problem_crops c on c.id = r.crop_id
    where r.student_id = v_student
    order by r.book_id, r.grade_label, r.updated_at desc
  )
  select
    bs.book_id,
    bs.grade_label,
    coalesce(rf.name, '교재') as book_name,
    coalesce(rf.description, '') as book_description,
    rf.color as book_color,
    coalesce(tm.payload->>'series', '') as series,
    coalesce(cover.url, '') as cover_ref,
    bs.total_problems,
    bs.graded_count,
    bs.correct_count,
    bs.completed_count,
    bs.first_wrong_count,
    bs.corrected_count,
    coalesce(st.progress, '{}'::jsonb) as stage_progress,
    lr.raw_page as last_raw_page,
    lr.display_page as last_display_page,
    bs.last_activity
  from book_stats bs
  join public.resource_files rf on rf.id = bs.book_id
  left join public.textbook_metadata tm
    on tm.academy_id = v_academy
   and tm.book_id = bs.book_id
   and tm.grade_label = bs.grade_label
  left join stages st
    on st.book_id = bs.book_id
   and st.grade_label = bs.grade_label
  left join last_rec lr
    on lr.book_id = bs.book_id
   and lr.grade_label = bs.grade_label
  left join lateral (
    select l.url
    from public.resource_file_links l
    where l.academy_id = v_academy
      and l.file_id = bs.book_id
      and l.grade = bs.grade_label || '#cover'
      and coalesce(l.url, '') <> ''
    order by l.created_at desc
    limit 1
  ) cover on true
  order by coalesce(rf.name, '교재');
end;
$$;

revoke all on function public.student_list_textbooks() from public;
grant execute on function public.student_list_textbooks() to authenticated;
