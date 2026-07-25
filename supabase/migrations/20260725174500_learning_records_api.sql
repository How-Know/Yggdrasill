-- 20260725174500: 학습 기록 쓰기 RPC + 구간 시간 분배 + 분석 뷰
--
-- 클라이언트는 테이블에 직접 쓰지 않는다. 회차 채번/신뢰도 스냅샷/비정규화 컬럼이
-- 서버에서 채워져야 하기 때문이다. 아이패드 학생앱은 아래 RPC만 호출하면 된다.
--
--   learning_start_session   → 세션 열기 (템플릿에서 규칙 복사)
--   learning_log_exposures   → 출제한 문항 목록 기록 (푼 것과 무관하게 전부)
--   learning_log_attempts    → 풀이 결과 기록
--   learning_finish_session  → 세션 닫기
--   learning_record_range_timing / learning_distribute_range_timing
--                            → 종이 구간 시간 기록 및 문항별 추정 분배

-- ---------------------------------------------------------------------------
-- 0) 권한 헬퍼
-- ---------------------------------------------------------------------------
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
    exists (
      select 1 from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id = p_academy_id
    )
    or exists (
      select 1 from public.student_app_accounts a
      where a.user_id = auth.uid()
        and a.student_id = p_student_id
        and a.academy_id = p_academy_id
    );
$$;

-- ---------------------------------------------------------------------------
-- 1) 문항 비정규화 컬럼 자동 채움
-- ---------------------------------------------------------------------------
create or replace function public._learning_exposures_fill_item()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  c record;
begin
  if new.crop_id is not null then
    select tc.book_id, tc.grade_label, tc.unit_id, tc.raw_page,
           tc.display_page, tc.pb_question_uid
    into c
    from public.textbook_problem_crops tc
    where tc.id = new.crop_id;

    if found then
      new.book_id := coalesce(new.book_id, c.book_id);
      new.grade_label := coalesce(new.grade_label, c.grade_label);
      new.unit_id := coalesce(new.unit_id, c.unit_id);
      new.raw_page := coalesce(new.raw_page, c.raw_page);
      new.display_page := coalesce(new.display_page, c.display_page);
      new.pb_question_uid := coalesce(new.pb_question_uid, c.pb_question_uid);
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_learning_exposures_fill_item on public.learning_exposures;
create trigger trg_learning_exposures_fill_item
before insert on public.learning_exposures
for each row execute function public._learning_exposures_fill_item();

create or replace function public._learning_attempts_fill_item()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  e record;
  c record;
begin
  if new.exposure_id is not null then
    select le.crop_id, le.pb_question_uid, le.book_id, le.grade_label, le.unit_id
    into e
    from public.learning_exposures le
    where le.id = new.exposure_id;

    if found then
      new.crop_id := coalesce(new.crop_id, e.crop_id);
      new.pb_question_uid := coalesce(new.pb_question_uid, e.pb_question_uid);
      new.book_id := coalesce(new.book_id, e.book_id);
      new.grade_label := coalesce(new.grade_label, e.grade_label);
      new.unit_id := coalesce(new.unit_id, e.unit_id);
    end if;
  end if;

  if new.crop_id is not null
     and (new.book_id is null or new.unit_id is null) then
    select tc.book_id, tc.grade_label, tc.unit_id, tc.pb_question_uid
    into c
    from public.textbook_problem_crops tc
    where tc.id = new.crop_id;

    if found then
      new.book_id := coalesce(new.book_id, c.book_id);
      new.grade_label := coalesce(new.grade_label, c.grade_label);
      new.unit_id := coalesce(new.unit_id, c.unit_id);
      new.pb_question_uid := coalesce(new.pb_question_uid, c.pb_question_uid);
    end if;
  end if;

  -- 문항별 집계에서 "이 문항을 푼 학생들의 수준"을 보려면 시점 값이 필요하다.
  if new.student_level_snapshot is null then
    select ls.current_level_code
    into new.student_level_snapshot
    from public.student_level_states ls
    where ls.student_id = new.student_id
    limit 1;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_learning_attempts_fill_item on public.learning_attempts;
create trigger trg_learning_attempts_fill_item
before insert on public.learning_attempts
for each row execute function public._learning_attempts_fill_item();

-- ---------------------------------------------------------------------------
-- 2) 세션 열기
-- ---------------------------------------------------------------------------
-- p_overrides 로 템플릿 기본값을 덮어쓸 수 있다.
--   {"location_kind":"home","supervision":"unsupervised","book_id":"...",
--    "grade_label":"...","homework_group_id":"...","flow_id":"...",
--    "time_limit_sec":1800,"meta":{...}}
create or replace function public.learning_start_session(
  p_student_id uuid,
  p_template_code text default null,
  p_session_kind text default null,
  p_overrides jsonb default '{}'::jsonb
) returns uuid
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_tpl public.learning_exam_templates%rowtype;
  v_ov jsonb := coalesce(p_overrides, '{}'::jsonb);
  v_id uuid;
begin
  select s.academy_id into v_academy
  from public.students s
  where s.id = p_student_id;

  if v_academy is null then
    raise exception 'learning_start_session: unknown student %', p_student_id;
  end if;
  if not public._learning_can_write(v_academy, p_student_id) then
    raise exception 'learning_start_session: forbidden';
  end if;

  if p_template_code is not null then
    select * into v_tpl
    from public.learning_exam_templates t
    where t.academy_id = v_academy
      and t.code = upper(btrim(p_template_code));
    if not found then
      raise exception 'learning_start_session: unknown template %', p_template_code;
    end if;
  end if;

  insert into public.learning_sessions (
    academy_id, student_id, session_kind, template_id,
    platform, location_kind, supervision, answer_access,
    scored_by, timing_source, material_kind, retry_policy,
    time_limit_sec, time_limit_enforced, target_item_count,
    homework_group_id, homework_item_id, flow_id, book_id, grade_label,
    status, started_at, meta, created_by
  )
  values (
    v_academy,
    p_student_id,
    coalesce(nullif(btrim(coalesce(p_session_kind, '')), ''), v_tpl.session_kind, 'other'),
    v_tpl.id,
    coalesce(v_ov->>'platform', v_tpl.platform, 'unknown'),
    coalesce(v_ov->>'location_kind', v_tpl.location_kind, 'unknown'),
    coalesce(v_ov->>'supervision', v_tpl.supervision, 'unknown'),
    coalesce(v_ov->>'answer_access', v_tpl.answer_access, 'unknown'),
    coalesce(v_ov->>'scored_by', v_tpl.scored_by, 'unknown'),
    coalesce(v_ov->>'timing_source', v_tpl.timing_source, 'none'),
    coalesce(v_ov->>'material_kind', v_tpl.material_kind, 'unknown'),
    coalesce(v_ov->>'retry_policy', v_tpl.retry_policy, 'none'),
    coalesce((v_ov->>'time_limit_sec')::integer, v_tpl.time_limit_sec),
    coalesce((v_ov->>'time_limit_enforced')::boolean, v_tpl.time_limit_enforced, false),
    coalesce((v_ov->>'target_item_count')::integer, v_tpl.target_item_count),
    nullif(v_ov->>'homework_group_id', '')::uuid,
    nullif(v_ov->>'homework_item_id', '')::uuid,
    nullif(v_ov->>'flow_id', '')::uuid,
    nullif(v_ov->>'book_id', '')::uuid,
    nullif(v_ov->>'grade_label', ''),
    'open',
    coalesce(nullif(v_ov->>'started_at', '')::timestamptz, now()),
    coalesce(v_ov->'meta', '{}'::jsonb),
    auth.uid()
  )
  returning id into v_id;

  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3) 노출 기록
-- ---------------------------------------------------------------------------
-- p_items: [{"crop_id":"...", "exposure_reason":"recommendation",
--            "recommender_key":"weakness_v1", "is_anchor":false,
--            "position_in_session":1}]
-- 반환: [{"crop_id":"...", "exposure_id":"...", "position_in_session":1}]
create or replace function public.learning_log_exposures(
  p_session_id uuid,
  p_items jsonb
) returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_s public.learning_sessions%rowtype;
  v_item jsonb;
  v_idx integer := 0;
  v_id uuid;
  v_out jsonb := '[]'::jsonb;
begin
  select * into v_s from public.learning_sessions where id = p_session_id;
  if not found then
    raise exception 'learning_log_exposures: unknown session';
  end if;
  if not public._learning_can_write(v_s.academy_id, v_s.student_id) then
    raise exception 'learning_log_exposures: forbidden';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    return v_out;
  end if;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_idx := v_idx + 1;
    if nullif(v_item->>'crop_id', '') is null
       and nullif(v_item->>'pb_question_uid', '') is null then
      continue;
    end if;

    insert into public.learning_exposures (
      academy_id, student_id, session_id,
      crop_id, pb_question_uid,
      book_id, grade_label,
      exposure_reason, recommender_key, is_anchor,
      position_in_session, exposed_at, meta
    )
    values (
      v_s.academy_id, v_s.student_id, p_session_id,
      nullif(v_item->>'crop_id', '')::uuid,
      nullif(v_item->>'pb_question_uid', '')::uuid,
      coalesce(nullif(v_item->>'book_id', '')::uuid, v_s.book_id),
      coalesce(nullif(v_item->>'grade_label', ''), v_s.grade_label),
      coalesce(nullif(v_item->>'exposure_reason', ''), 'unknown'),
      nullif(v_item->>'recommender_key', ''),
      coalesce((v_item->>'is_anchor')::boolean, false),
      coalesce((v_item->>'position_in_session')::integer, v_idx),
      coalesce(nullif(v_item->>'exposed_at', '')::timestamptz, now()),
      coalesce(v_item->'meta', '{}'::jsonb)
    )
    returning id into v_id;

    v_out := v_out || jsonb_build_object(
      'exposure_id', v_id,
      'crop_id', nullif(v_item->>'crop_id', ''),
      'pb_question_uid', nullif(v_item->>'pb_question_uid', ''),
      'position_in_session', coalesce((v_item->>'position_in_session')::integer, v_idx)
    );
  end loop;

  return v_out;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4) 시도 기록
-- ---------------------------------------------------------------------------
-- p_items: [{"crop_id":"...", "result":"correct", "assist_level":"none",
--            "confidence":"sure", "duration_ms":45000,
--            "duration_source":"measured", "answer_text":"3"}]
create or replace function public.learning_log_attempts(
  p_session_id uuid,
  p_items jsonb
) returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_s public.learning_sessions%rowtype;
  v_item jsonb;
  v_exposure uuid;
  v_crop uuid;
  v_pb uuid;
  v_id uuid;
  v_out jsonb := '[]'::jsonb;
begin
  select * into v_s from public.learning_sessions where id = p_session_id;
  if not found then
    raise exception 'learning_log_attempts: unknown session';
  end if;
  if not public._learning_can_write(v_s.academy_id, v_s.student_id) then
    raise exception 'learning_log_attempts: forbidden';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    return v_out;
  end if;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_exposure := nullif(v_item->>'exposure_id', '')::uuid;
    v_crop := nullif(v_item->>'crop_id', '')::uuid;
    v_pb := nullif(v_item->>'pb_question_uid', '')::uuid;

    if v_exposure is null and (v_crop is not null or v_pb is not null) then
      select e.id into v_exposure
      from public.learning_exposures e
      where e.session_id = p_session_id
        and (
          (v_crop is not null and e.crop_id = v_crop)
          or (v_crop is null and e.pb_question_uid = v_pb)
        )
      order by e.exposed_at desc
      limit 1;
    end if;

    if v_crop is null and v_pb is null and v_exposure is null then
      continue;
    end if;

    insert into public.learning_attempts (
      academy_id, student_id, session_id, exposure_id,
      crop_id, pb_question_uid, book_id, grade_label,
      result, answer_text,
      assist_level, assist_note, confidence,
      duration_ms, duration_source,
      scored_by, scored_at, scorer_user_id,
      student_level_snapshot, attempted_at, meta
    )
    values (
      v_s.academy_id, v_s.student_id, p_session_id, v_exposure,
      v_crop, v_pb,
      coalesce(nullif(v_item->>'book_id', '')::uuid, v_s.book_id),
      coalesce(nullif(v_item->>'grade_label', ''), v_s.grade_label),
      coalesce(nullif(v_item->>'result', ''), 'ungraded'),
      nullif(v_item->>'answer_text', ''),
      coalesce(nullif(v_item->>'assist_level', ''), 'none'),
      coalesce(v_item->>'assist_note', ''),
      nullif(v_item->>'confidence', ''),
      (v_item->>'duration_ms')::integer,
      coalesce(
        nullif(v_item->>'duration_source', ''),
        case when (v_item->>'duration_ms') is not null then 'measured' else 'unknown' end
      ),
      coalesce(nullif(v_item->>'scored_by', ''), v_s.scored_by, 'unknown'),
      coalesce(nullif(v_item->>'scored_at', '')::timestamptz, now()),
      auth.uid(),
      (v_item->>'student_level_snapshot')::smallint,
      coalesce(nullif(v_item->>'attempted_at', '')::timestamptz, now()),
      coalesce(v_item->'meta', '{}'::jsonb)
    )
    returning id into v_id;

    v_out := v_out || jsonb_build_object('attempt_id', v_id, 'crop_id', v_crop);
  end loop;

  return v_out;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5) 세션 닫기
-- ---------------------------------------------------------------------------
create or replace function public.learning_finish_session(
  p_session_id uuid,
  p_status text default 'completed',
  p_elapsed_sec integer default null,
  p_interrupted_sec integer default null
) returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_s public.learning_sessions%rowtype;
  v_elapsed integer;
begin
  select * into v_s from public.learning_sessions where id = p_session_id;
  if not found then
    raise exception 'learning_finish_session: unknown session';
  end if;
  if not public._learning_can_write(v_s.academy_id, v_s.student_id) then
    raise exception 'learning_finish_session: forbidden';
  end if;

  v_elapsed := coalesce(
    p_elapsed_sec,
    greatest(0, extract(epoch from (now() - v_s.started_at))::integer)
  );

  update public.learning_sessions
  set status = coalesce(nullif(btrim(coalesce(p_status, '')), ''), 'completed'),
      ended_at = now(),
      elapsed_sec = v_elapsed,
      interrupted_sec = coalesce(p_interrupted_sec, interrupted_sec)
  where id = p_session_id;

  return jsonb_build_object(
    'ok', true,
    'session_id', p_session_id,
    'elapsed_sec', v_elapsed,
    'exposed', (select count(*) from public.learning_exposures where session_id = p_session_id),
    'attempted', (select count(*) from public.learning_attempts where session_id = p_session_id)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 6) 구간 시간 기록 + 문항별 분배
-- ---------------------------------------------------------------------------
create or replace function public.learning_record_range_timing(
  p_student_id uuid,
  p_elapsed_sec integer,
  p_session_id uuid default null,
  p_book_id uuid default null,
  p_grade_label text default null,
  p_page_from integer default null,
  p_page_to integer default null,
  p_crop_ids uuid[] default null,
  p_interrupted_sec integer default 0,
  p_round_index integer default 1,
  p_note text default ''
) returns uuid
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_crops uuid[] := coalesce(p_crop_ids, array[]::uuid[]);
  v_id uuid;
begin
  select s.academy_id into v_academy from public.students s where s.id = p_student_id;
  if v_academy is null then
    raise exception 'learning_record_range_timing: unknown student';
  end if;
  if not public._learning_can_write(v_academy, p_student_id) then
    raise exception 'learning_record_range_timing: forbidden';
  end if;

  -- 문항 집합을 명시하지 않았으면 페이지 범위에서 만든다.
  -- 구간마다 문항 집합이 달라야 나중에 문항별 시간을 역산할 수 있다.
  if array_length(v_crops, 1) is null
     and p_book_id is not null
     and p_page_from is not null and p_page_to is not null then
    select coalesce(array_agg(c.id), array[]::uuid[])
    into v_crops
    from public.textbook_problem_crops c
    where c.academy_id = v_academy
      and c.book_id = p_book_id
      and (p_grade_label is null or c.grade_label = p_grade_label)
      and not c.is_set_header
      and coalesce(c.display_page, c.raw_page) between p_page_from and p_page_to;
  end if;

  insert into public.learning_range_timings (
    academy_id, student_id, session_id,
    book_id, grade_label, page_from, page_to,
    crop_ids, item_count,
    round_index, elapsed_sec, interrupted_sec,
    recorded_by, note
  )
  values (
    v_academy, p_student_id, p_session_id,
    p_book_id, p_grade_label, p_page_from, p_page_to,
    v_crops, nullif(coalesce(array_length(v_crops, 1), 0), 0),
    greatest(1, coalesce(p_round_index, 1)),
    greatest(0, coalesce(p_elapsed_sec, 0)),
    greatest(0, least(coalesce(p_interrupted_sec, 0), greatest(0, coalesce(p_elapsed_sec, 0)))),
    auth.uid(), coalesce(p_note, '')
  )
  returning id into v_id;

  return v_id;
end;
$$;

-- 구간 시간을 문항별 추정치로 분배한다.
-- 단순 균등 분배다. 정확한 값이 아니라 "표본"이며, 여러 구간이 쌓이면
-- 나중에 최소제곱으로 문항별 시간을 다시 풀 수 있도록 원자료를 함께 남긴다.
create or replace function public.learning_distribute_range_timing(
  p_range_id uuid,
  p_overwrite boolean default false
) returns integer
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_r public.learning_range_timings%rowtype;
  v_count integer;
  v_per_ms integer;
  v_updated integer := 0;
begin
  select * into v_r from public.learning_range_timings where id = p_range_id;
  if not found then
    raise exception 'learning_distribute_range_timing: unknown range';
  end if;
  if not public._learning_can_write(v_r.academy_id, v_r.student_id) then
    raise exception 'learning_distribute_range_timing: forbidden';
  end if;

  v_count := coalesce(array_length(v_r.crop_ids, 1), 0);
  if v_count = 0 then
    return 0;
  end if;

  v_per_ms := ((greatest(0, v_r.elapsed_sec - v_r.interrupted_sec)::bigint * 1000)
               / v_count)::integer;

  update public.learning_attempts a
  set duration_ms = v_per_ms,
      duration_source = 'derived_from_range'
  where a.student_id = v_r.student_id
    and a.crop_id = any (v_r.crop_ids)
    and (v_r.session_id is null or a.session_id = v_r.session_id)
    and (p_overwrite or a.duration_ms is null
         or a.duration_source in ('unknown', 'derived_from_range'));

  get diagnostics v_updated = row_count;

  update public.learning_range_timings
  set distributed_at = now()
  where id = p_range_id;

  return v_updated;
end;
$$;

-- ---------------------------------------------------------------------------
-- 7) 권한
-- ---------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'public.learning_start_session(uuid, text, text, jsonb)',
    'public.learning_log_exposures(uuid, jsonb)',
    'public.learning_log_attempts(uuid, jsonb)',
    'public.learning_finish_session(uuid, text, integer, integer)',
    'public.learning_record_range_timing(uuid, integer, uuid, uuid, text, integer, integer, uuid[], integer, integer, text)',
    'public.learning_distribute_range_timing(uuid, boolean)'
  ]
  loop
    execute format('revoke all on function %s from public', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------
-- 8) 분석 뷰
-- ---------------------------------------------------------------------------

-- 문항별 집계: 이 문항을 푼 학생 수준, 평균/중앙 소요시간, 정답률.
drop view if exists public.learning_item_stats;
create view public.learning_item_stats
with (security_invoker = true) as
with att as (
  select
    academy_id, crop_id, pb_question_uid,
    count(*) as attempt_count,
    count(distinct student_id) as student_count,
    count(*) filter (where attempt_no = 1) as first_attempt_count,
    count(*) filter (where attempt_no = 1 and result = 'correct')
      as first_attempt_correct,
    count(*) filter (where result = 'correct') as correct_count,
    count(*) filter (where result = 'correct' and assist_level = 'none')
      as unaided_correct_count,
    count(*) filter (where assist_level in ('teacher', 'peer', 'solution_peek'))
      as assisted_count,
    count(*) filter (where confidence = 'guess') as guess_count,
    count(*) filter (where confidence = 'guess' and result = 'correct')
      as lucky_correct_count,
    count(*) filter (where reliability_tier in ('high', 'medium'))
      as trusted_attempt_count,
    count(*) filter (where reliability_tier in ('high', 'medium')
                       and result = 'correct') as trusted_correct_count,
    percentile_cont(0.5) within group (order by duration_ms)
      filter (where duration_source = 'measured' and duration_ms is not null)
      as median_measured_ms,
    avg(duration_ms) filter (where duration_ms is not null) as avg_any_duration_ms,
    avg(student_level_snapshot::numeric) as avg_student_level,
    max(attempted_at) as last_attempted_at
  from public.learning_attempts
  where result <> 'void'
  group by academy_id, crop_id, pb_question_uid
),
exp as (
  select
    academy_id, crop_id, pb_question_uid,
    count(*) as exposure_count,
    count(*) filter (where not attempted) as unattempted_count,
    count(*) filter (where exposure_reason = 'recommendation') as by_recommendation,
    count(*) filter (where exposure_reason = 'teacher_assigned') as by_teacher,
    count(*) filter (where exposure_reason = 'self_selected') as by_self,
    count(*) filter (where is_anchor) as anchor_exposures
  from public.learning_exposures
  group by academy_id, crop_id, pb_question_uid
)
select
  coalesce(a.academy_id, e.academy_id) as academy_id,
  coalesce(a.crop_id, e.crop_id) as crop_id,
  coalesce(a.pb_question_uid, e.pb_question_uid) as pb_question_uid,
  coalesce(e.exposure_count, 0) as exposure_count,
  coalesce(e.unattempted_count, 0) as unattempted_count,
  coalesce(e.by_recommendation, 0) as exposure_by_recommendation,
  coalesce(e.by_teacher, 0) as exposure_by_teacher,
  coalesce(e.by_self, 0) as exposure_by_self,
  coalesce(e.anchor_exposures, 0) as anchor_exposures,
  coalesce(a.attempt_count, 0) as attempt_count,
  coalesce(a.student_count, 0) as student_count,
  coalesce(a.first_attempt_count, 0) as first_attempt_count,
  coalesce(a.first_attempt_correct, 0) as first_attempt_correct,
  case when coalesce(a.first_attempt_count, 0) > 0
       then round(a.first_attempt_correct::numeric / a.first_attempt_count, 4)
  end as first_attempt_correct_rate,
  coalesce(a.correct_count, 0) as correct_count,
  coalesce(a.unaided_correct_count, 0) as unaided_correct_count,
  coalesce(a.assisted_count, 0) as assisted_count,
  coalesce(a.guess_count, 0) as guess_count,
  coalesce(a.lucky_correct_count, 0) as lucky_correct_count,
  coalesce(a.trusted_attempt_count, 0) as trusted_attempt_count,
  case when coalesce(a.trusted_attempt_count, 0) > 0
       then round(a.trusted_correct_count::numeric / a.trusted_attempt_count, 4)
  end as trusted_correct_rate,
  a.median_measured_ms,
  a.avg_any_duration_ms,
  round(a.avg_student_level, 2) as avg_student_level,
  a.last_attempted_at
from att a
full join exp e
  on e.academy_id = a.academy_id
 and e.crop_id is not distinct from a.crop_id
 and e.pb_question_uid is not distinct from a.pb_question_uid;

-- 학생 × 문항: "이 학생이 이 문항을 몇 번 봤고 몇 번 풀었고 언제 처음 맞췄는가".
drop view if exists public.learning_student_item_stats;
create view public.learning_student_item_stats
with (security_invoker = true) as
with att as (
  select
    academy_id, student_id, crop_id, pb_question_uid,
    count(*) as attempt_count,
    count(*) filter (where result = 'correct') as correct_count,
    count(*) filter (where result = 'wrong') as wrong_count,
    count(*) filter (where assist_level <> 'none') as assisted_count,
    min(attempt_no) filter (where result = 'correct') as first_correct_attempt_no,
    min(attempted_at) filter (where result = 'correct') as first_correct_at,
    max(attempted_at) as last_attempted_at,
    (array_agg(result order by attempted_at desc))[1] as last_result,
    sum(duration_ms) filter (where duration_ms is not null) as total_duration_ms,
    avg(duration_ms) filter (where duration_source = 'measured') as avg_measured_ms
  from public.learning_attempts
  where result <> 'void'
  group by academy_id, student_id, crop_id, pb_question_uid
),
exp as (
  select
    academy_id, student_id, crop_id, pb_question_uid,
    count(*) as exposure_count,
    count(*) filter (where not attempted) as unattempted_count,
    max(exposed_at) as last_exposed_at
  from public.learning_exposures
  group by academy_id, student_id, crop_id, pb_question_uid
)
select
  coalesce(a.academy_id, e.academy_id) as academy_id,
  coalesce(a.student_id, e.student_id) as student_id,
  coalesce(a.crop_id, e.crop_id) as crop_id,
  coalesce(a.pb_question_uid, e.pb_question_uid) as pb_question_uid,
  coalesce(e.exposure_count, 0) as exposure_count,
  coalesce(e.unattempted_count, 0) as unattempted_count,
  e.last_exposed_at,
  coalesce(a.attempt_count, 0) as attempt_count,
  coalesce(a.correct_count, 0) as correct_count,
  coalesce(a.wrong_count, 0) as wrong_count,
  coalesce(a.assisted_count, 0) as assisted_count,
  a.first_correct_attempt_no,
  a.first_correct_at,
  a.last_result,
  a.last_attempted_at,
  a.total_duration_ms,
  a.avg_measured_ms
from att a
full join exp e
  on e.academy_id = a.academy_id
 and e.student_id = a.student_id
 and e.crop_id is not distinct from a.crop_id
 and e.pb_question_uid is not distinct from a.pb_question_uid;

-- 학생 × 단원: 취약점 추천의 입력.
drop view if exists public.learning_student_unit_stats;
create view public.learning_student_unit_stats
with (security_invoker = true) as
select
  a.academy_id,
  a.student_id,
  a.book_id,
  a.grade_label,
  a.unit_id,
  count(*) as attempt_count,
  count(distinct a.crop_id) as item_count,
  count(*) filter (where a.result = 'correct') as correct_count,
  count(*) filter (where a.attempt_no = 1) as first_attempt_count,
  count(*) filter (where a.attempt_no = 1 and a.result = 'correct')
    as first_attempt_correct,
  case when count(*) filter (where a.attempt_no = 1) > 0
       then round(
         (count(*) filter (where a.attempt_no = 1 and a.result = 'correct'))::numeric
         / (count(*) filter (where a.attempt_no = 1)), 4)
  end as first_attempt_correct_rate,
  count(*) filter (where a.assist_level <> 'none') as assisted_count,
  avg(a.duration_ms) filter (where a.duration_source = 'measured')
    as avg_measured_ms,
  avg(a.reliability_score) as avg_reliability,
  max(a.attempted_at) as last_attempted_at
from public.learning_attempts a
where a.result <> 'void'
  and a.unit_id is not null
group by a.academy_id, a.student_id, a.book_id, a.grade_label, a.unit_id;

-- 세션 요약: 30분 안에 몇 문항까지 갔는지 등.
drop view if exists public.learning_session_summary;
create view public.learning_session_summary
with (security_invoker = true) as
select
  s.id as session_id,
  s.academy_id,
  s.student_id,
  s.session_kind,
  s.template_id,
  t.code as template_code,
  s.status,
  s.started_at,
  s.ended_at,
  s.elapsed_sec,
  s.interrupted_sec,
  s.time_limit_sec,
  s.time_limit_enforced,
  s.reliability_score,
  s.reliability_tier,
  coalesce(e.exposure_count, 0) as exposed_count,
  coalesce(e.attempted_count, 0) as attempted_count,
  coalesce(a.attempt_count, 0) as attempt_count,
  coalesce(a.correct_count, 0) as correct_count,
  case when coalesce(a.attempt_count, 0) > 0
       then round(a.correct_count::numeric / a.attempt_count, 4)
  end as correct_rate,
  a.avg_measured_ms
from public.learning_sessions s
left join public.learning_exam_templates t on t.id = s.template_id
left join (
  select session_id,
         count(*) as exposure_count,
         count(*) filter (where attempted) as attempted_count
  from public.learning_exposures
  group by session_id
) e on e.session_id = s.id
left join (
  select session_id,
         count(*) as attempt_count,
         count(*) filter (where result = 'correct') as correct_count,
         avg(duration_ms) filter (where duration_source = 'measured')
           as avg_measured_ms
  from public.learning_attempts
  where result <> 'void'
  group by session_id
) a on a.session_id = s.id;

grant select on public.learning_item_stats to authenticated;
grant select on public.learning_student_item_stats to authenticated;
grant select on public.learning_student_unit_stats to authenticated;
grant select on public.learning_session_summary to authenticated;

comment on view public.learning_item_stats is
  '문항별 집계. 노출 사유 분포, 첫 시도 정답률, 신뢰 구간 정답률, 중앙 소요시간.';
comment on view public.learning_student_item_stats is
  '학생×문항. 몇 번 노출되고 몇 번 시도했고 몇 번째에 맞췄는가.';
comment on view public.learning_student_unit_stats is
  '학생×단원 집계. 취약점 자동 추천의 입력.';
comment on view public.learning_session_summary is
  '세션 요약. 제한시간 안에 몇 문항까지 갔는지(노출 대비 시도)를 본다.';
