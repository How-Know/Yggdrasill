-- 교재 진입 모드(정답입력하기 / 바로풀기) + 자습 세션 중단·재개 + 실시간 상태 조회

-- ---------------------------------------------------------------------------
-- 1) learning_sessions 확장 (중단 상태, 진입 모드, 박동 시각)
-- ---------------------------------------------------------------------------
alter table public.learning_sessions
  drop constraint if exists learning_sessions_status_chk;

alter table public.learning_sessions
  add constraint learning_sessions_status_chk check (
    status in ('open', 'paused', 'completed', 'abandoned', 'void')
  );

alter table public.learning_sessions
  add column if not exists entry_mode text,
  add column if not exists paused_at timestamptz,
  add column if not exists last_resumed_at timestamptz,
  add column if not exists last_beat_at timestamptz;

alter table public.learning_sessions
  drop constraint if exists learning_sessions_entry_mode_chk;

alter table public.learning_sessions
  add constraint learning_sessions_entry_mode_chk check (
    entry_mode is null or entry_mode in ('solve', 'answer_entry')
  );

create index if not exists learning_sessions_student_book_active_idx
  on public.learning_sessions (student_id, book_id, grade_label, updated_at desc)
  where status in ('open', 'paused');

create index if not exists learning_sessions_academy_active_entry_idx
  on public.learning_sessions (academy_id, student_id, updated_at desc)
  where status in ('open', 'paused') and entry_mode is not null;

-- 학습앱이 학생의 자유풀이중 / 자유풀이 중단 / 정답입력중을 실시간으로 구독
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1
       from pg_publication_tables
       where pubname = 'supabase_realtime'
         and schemaname = 'public'
         and tablename = 'learning_sessions'
     ) then
    execute 'alter publication supabase_realtime add table public.learning_sessions';
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- 2) 장기 무응답(3시간) 정리 헬퍼
-- ---------------------------------------------------------------------------
create or replace function public._student_sweep_stale_textbook_sessions(
  p_student_id uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cutoff timestamptz := now() - interval '3 hours';
begin
  if p_student_id is null then
    return;
  end if;

  -- 바로풀기는 마지막 생존 신호 시각까지만 활성 시간을 누적하고 중단 상태로 전환
  update public.learning_sessions s
  set elapsed_sec = coalesce(s.elapsed_sec, 0) + greatest(
        0,
        floor(
          extract(
            epoch from (
              coalesce(s.last_beat_at, s.last_resumed_at, s.started_at) -
              coalesce(s.last_resumed_at, s.started_at)
            )
          )
        )::integer
      ),
      status = 'paused',
      paused_at = coalesce(s.last_beat_at, s.last_resumed_at, s.started_at),
      updated_at = now()
  where s.student_id = p_student_id
    and s.status = 'open'
    and s.entry_mode = 'solve'
    and coalesce(s.last_beat_at, s.last_resumed_at, s.started_at) < v_cutoff;

  -- 정답입력하기는 타이머가 없으므로 3시간 무응답 시 종료
  update public.learning_sessions s
  set status = 'completed',
      ended_at = coalesce(s.last_beat_at, s.started_at),
      elapsed_sec = 0,
      updated_at = now()
  where s.student_id = p_student_id
    and s.status = 'open'
    and s.entry_mode = 'answer_entry'
    and coalesce(s.last_beat_at, s.started_at) < v_cutoff;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3) 하원 트리거 보완: 바로풀기는 중단으로 전환해 집에서 이어 풀 수 있게 둔다
-- ---------------------------------------------------------------------------
create or replace function public._learning_close_sessions_on_departure()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_depart timestamptz;
begin
  if new.departure_time is null or old.departure_time is not null then
    return new;
  end if;

  v_depart := least(new.departure_time, now());

  -- 바로풀기 세션은 하원 시 자동 중단(paused) — 집에 가서도 바로 이어서 풀기 가능
  update public.learning_sessions s
  set elapsed_sec = coalesce(s.elapsed_sec, 0) + greatest(
        0,
        floor(
          extract(epoch from (v_depart - coalesce(s.last_resumed_at, s.started_at)))
        )::integer
      ),
      status = 'paused',
      paused_at = v_depart,
      last_beat_at = v_depart,
      updated_at = now()
  where s.academy_id = new.academy_id
    and s.student_id = new.student_id
    and s.status = 'open'
    and s.entry_mode = 'solve';

  -- 그 외(과제 세션, 정답입력하기 등)는 기존대로 마감해 장소가 섞이지 않게 한다
  update public.learning_sessions s
  set status = 'completed',
      ended_at = coalesce(s.ended_at, v_depart),
      elapsed_sec = coalesce(
        s.elapsed_sec,
        greatest(
          0,
          floor(extract(epoch from (v_depart - s.started_at)))::integer
        )
      ),
      updated_at = now()
  where s.academy_id = new.academy_id
    and s.student_id = new.student_id
    and s.status = 'open'
    and coalesce(s.entry_mode, '') <> 'solve';

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4) 학생앱 교재 세션 RPC 5종
-- ---------------------------------------------------------------------------
create or replace function public.student_list_active_textbook_sessions_v1()
returns table(
  session_id uuid,
  book_id uuid,
  grade_label text,
  entry_mode text,
  status text,
  started_at timestamptz,
  last_resumed_at timestamptz,
  paused_at timestamptz,
  elapsed_sec integer,
  interrupted_sec integer,
  last_beat_at timestamptz
)
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_student uuid;
begin
  select i.student_id into v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  perform public._student_sweep_stale_textbook_sessions(v_student);

  return query
  select distinct on (s.book_id, coalesce(s.grade_label, ''), s.entry_mode)
    s.id,
    s.book_id,
    coalesce(s.grade_label, ''),
    s.entry_mode,
    s.status,
    s.started_at,
    s.last_resumed_at,
    s.paused_at,
    coalesce(s.elapsed_sec, 0),
    coalesce(s.interrupted_sec, 0),
    s.last_beat_at
  from public.learning_sessions s
  where s.student_id = v_student
    and s.book_id is not null
    and s.entry_mode in ('solve', 'answer_entry')
    and s.status in ('open', 'paused')
  order by
    s.book_id,
    coalesce(s.grade_label, ''),
    s.entry_mode,
    s.updated_at desc;
end;
$$;

grant execute on function public.student_list_active_textbook_sessions_v1()
  to authenticated;

create or replace function public.student_start_textbook_session_v1(
  p_book_id uuid,
  p_grade_label text,
  p_entry_mode text
) returns table(
  session_id uuid,
  book_id uuid,
  grade_label text,
  entry_mode text,
  status text,
  started_at timestamptz,
  last_resumed_at timestamptz,
  paused_at timestamptz,
  elapsed_sec integer,
  interrupted_sec integer,
  last_beat_at timestamptz
)
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  v_grade text := coalesce(p_grade_label, '');
  v_mode text := lower(btrim(coalesce(p_entry_mode, '')));
  v_loc text;
  v_existing public.learning_sessions%rowtype;
  v_id uuid;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;
  if p_book_id is null or v_mode not in ('solve', 'answer_entry') then
    raise exception 'invalid textbook session args';
  end if;

  perform public._student_sweep_stale_textbook_sessions(v_student);
  v_loc := public._student_location_kind(v_academy, v_student, now());

  if v_mode = 'solve' then
    -- 다른 교재에서 열려 있던 바로풀기는 자동 중단해 동시 타이머를 막는다.
    update public.learning_sessions s
    set elapsed_sec = coalesce(s.elapsed_sec, 0) + greatest(
          0,
          floor(
            extract(epoch from (now() - coalesce(s.last_resumed_at, s.started_at)))
          )::integer
        ),
        status = 'paused',
        paused_at = now(),
        last_beat_at = now(),
        updated_at = now()
    where s.student_id = v_student
      and s.status = 'open'
      and s.entry_mode = 'solve'
      and (
        s.book_id <> p_book_id
        or coalesce(s.grade_label, '') <> v_grade
      );

    -- 같은 교재에 열려 있거나 중단된 바로풀기 세션이 있으면 이어서 연다.
    select * into v_existing
    from public.learning_sessions s
    where s.student_id = v_student
      and s.book_id = p_book_id
      and coalesce(s.grade_label, '') = v_grade
      and s.entry_mode = 'solve'
      and s.status in ('open', 'paused')
    order by s.updated_at desc
    limit 1
    for update;

    if found then
      if v_existing.status = 'paused' then
        update public.learning_sessions
        set status = 'open',
            interrupted_sec = coalesce(interrupted_sec, 0) + case
              when paused_at is not null
              then greatest(0, floor(extract(epoch from (now() - paused_at)))::integer)
              else 0
            end,
            paused_at = null,
            last_resumed_at = now(),
            last_beat_at = now(),
            location_kind = v_loc,
            supervision = case when v_loc = 'academy' then 'staff_present' else 'unsupervised' end,
            session_kind = case when v_loc = 'academy' then 'academy_selfstudy' else 'free_practice' end,
            updated_at = now()
        where id = v_existing.id
        returning id into v_id;
      else
        update public.learning_sessions
        set last_beat_at = now(),
            location_kind = v_loc,
            updated_at = now()
        where id = v_existing.id
        returning id into v_id;
      end if;
    else
      insert into public.learning_sessions (
        academy_id, student_id, session_kind,
        platform, location_kind, supervision, answer_access,
        scored_by, timing_source, material_kind, retry_policy,
        status, book_id, grade_label,
        entry_mode, started_at, last_resumed_at, last_beat_at,
        elapsed_sec, interrupted_sec,
        meta, created_by
      ) values (
        v_academy, v_student,
        case when v_loc = 'academy' then 'academy_selfstudy' else 'free_practice' end,
        'student_app', v_loc,
        case when v_loc = 'academy' then 'staff_present' else 'unsupervised' end,
        case when v_loc = 'academy' then 'blocked' else 'available' end,
        'mixed', 'per_range', 'db_textbook', 'until_correct',
        'open', p_book_id, v_grade,
        'solve', now(), now(), now(),
        0, 0,
        jsonb_build_object('origin', 'student_textbook_entry', 'entry_mode', 'solve'),
        auth.uid()
      )
      returning id into v_id;
    end if;
  else
    -- 다른 열려 있는 정답입력하기 세션은 닫고 새(또는 같은 책) 세션을 연다.
    update public.learning_sessions s
    set status = 'completed',
        ended_at = now(),
        elapsed_sec = 0,
        updated_at = now()
    where s.student_id = v_student
      and s.status = 'open'
      and s.entry_mode = 'answer_entry'
      and (
        s.book_id <> p_book_id
        or coalesce(s.grade_label, '') <> v_grade
      );

    select * into v_existing
    from public.learning_sessions s
    where s.student_id = v_student
      and s.book_id = p_book_id
      and coalesce(s.grade_label, '') = v_grade
      and s.entry_mode = 'answer_entry'
      and s.status = 'open'
      and s.location_kind = v_loc
      and s.started_at > now() - interval '12 hours'
    order by s.updated_at desc
    limit 1
    for update;

    if found then
      update public.learning_sessions
      set last_beat_at = now(),
          updated_at = now()
      where id = v_existing.id
      returning id into v_id;
    else
      insert into public.learning_sessions (
        academy_id, student_id, session_kind,
        platform, location_kind, supervision, answer_access,
        scored_by, timing_source, material_kind, retry_policy,
        status, book_id, grade_label,
        entry_mode, started_at, last_resumed_at, last_beat_at,
        elapsed_sec, interrupted_sec,
        meta, created_by
      ) values (
        v_academy, v_student, 'free_practice',
        'student_app', v_loc, 'unsupervised', 'available',
        'mixed', 'none', 'db_textbook', 'until_correct',
        'open', p_book_id, v_grade,
        'answer_entry', now(), now(), now(),
        0, 0,
        jsonb_build_object('origin', 'student_textbook_entry', 'entry_mode', 'answer_entry'),
        auth.uid()
      )
      returning id into v_id;
    end if;
  end if;

  return query
  select
    s.id,
    s.book_id,
    coalesce(s.grade_label, ''),
    s.entry_mode,
    s.status,
    s.started_at,
    s.last_resumed_at,
    s.paused_at,
    coalesce(s.elapsed_sec, 0),
    coalesce(s.interrupted_sec, 0),
    s.last_beat_at
  from public.learning_sessions s
  where s.id = v_id;
end;
$$;

grant execute on function public.student_start_textbook_session_v1(uuid, text, text)
  to authenticated;

create or replace function public.student_beat_textbook_session_v1(
  p_session_id uuid
) returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_student uuid;
begin
  select i.student_id into v_student
  from public.student_app_identity() i;
  if v_student is null or p_session_id is null then
    return jsonb_build_object('ok', false);
  end if;

  update public.learning_sessions
  set last_beat_at = now(),
      updated_at = now()
  where id = p_session_id
    and student_id = v_student
    and status = 'open';

  return jsonb_build_object('ok', found);
end;
$$;

grant execute on function public.student_beat_textbook_session_v1(uuid)
  to authenticated;

create or replace function public.student_pause_textbook_session_v1(
  p_session_id uuid
) returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_student uuid;
  v_s public.learning_sessions%rowtype;
  v_add integer := 0;
begin
  select i.student_id into v_student
  from public.student_app_identity() i;
  if v_student is null or p_session_id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_request');
  end if;

  select * into v_s
  from public.learning_sessions
  where id = p_session_id
    and student_id = v_student
  for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  if v_s.status = 'open' and v_s.entry_mode = 'solve' then
    v_add := greatest(
      0,
      floor(extract(epoch from (now() - coalesce(v_s.last_resumed_at, v_s.started_at))))::integer
    );
    update public.learning_sessions
    set status = 'paused',
        elapsed_sec = coalesce(elapsed_sec, 0) + v_add,
        paused_at = now(),
        last_beat_at = now(),
        updated_at = now()
    where id = v_s.id;
  end if;

  return jsonb_build_object(
    'ok', true,
    'status', 'paused',
    'elapsed_sec', coalesce(v_s.elapsed_sec, 0) + v_add
  );
end;
$$;

grant execute on function public.student_pause_textbook_session_v1(uuid)
  to authenticated;

create or replace function public.student_finish_textbook_session_v1(
  p_session_id uuid,
  p_status text default 'completed'
) returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_student uuid;
  v_s public.learning_sessions%rowtype;
  v_next_status text := case
    when p_status in ('completed', 'abandoned', 'void') then p_status
    else 'completed'
  end;
  v_elapsed integer;
  v_interrupted integer;
begin
  select i.student_id into v_student
  from public.student_app_identity() i;
  if v_student is null or p_session_id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_request');
  end if;

  select * into v_s
  from public.learning_sessions
  where id = p_session_id
    and student_id = v_student
  for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  v_elapsed := coalesce(v_s.elapsed_sec, 0);
  v_interrupted := coalesce(v_s.interrupted_sec, 0);

  if v_s.entry_mode = 'solve' then
    if v_s.status = 'open' then
      v_elapsed := v_elapsed + greatest(
        0,
        floor(extract(epoch from (now() - coalesce(v_s.last_resumed_at, v_s.started_at))))::integer
      );
    elsif v_s.status = 'paused' and v_s.paused_at is not null then
      v_interrupted := v_interrupted + greatest(
        0,
        floor(extract(epoch from (now() - v_s.paused_at)))::integer
      );
    end if;
  else
    v_elapsed := 0;
  end if;

  update public.learning_sessions
  set status = v_next_status,
      ended_at = now(),
      paused_at = null,
      last_beat_at = now(),
      elapsed_sec = v_elapsed,
      interrupted_sec = v_interrupted,
      updated_at = now()
  where id = v_s.id;

  return jsonb_build_object(
    'ok', true,
    'status', v_next_status,
    'elapsed_sec', v_elapsed
  );
end;
$$;

grant execute on function public.student_finish_textbook_session_v1(uuid, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 5) 채점 기록 RPC에 p_session_id 연결 (교재 세션이 있으면 그 세션에 시도 적재)
-- ---------------------------------------------------------------------------
drop function if exists public.learning_log_homework_attempt(
  uuid, uuid, uuid, text, text, text, integer, text, jsonb
);

create or replace function public.learning_log_homework_attempt(
  p_student_id uuid,
  p_homework_group_id uuid,
  p_crop_id uuid,
  p_result text,
  p_scored_by text default 'auto',
  p_answer_text text default null,
  p_duration_ms integer default null,
  p_assist_level text default 'unknown',
  p_meta jsonb default '{}'::jsonb,
  p_session_id uuid default null
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
  v_entry_mode text;
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

  if auth.uid() is not null
     and not public._learning_can_write(v_academy, p_student_id) then
    raise exception 'learning_log_homework_attempt: forbidden';
  end if;

  v_result := coalesce(nullif(btrim(coalesce(p_result, '')), ''), 'ungraded');
  v_scored_by := case
    when p_scored_by in ('auto', 'teacher', 'self') then p_scored_by
    else 'unknown'
  end;

  -- 명시적 세션이 전달됐으면 그 세션(바로풀기/정답입력하기 등)에 시도 적재
  if p_session_id is not null then
    select s.id, s.entry_mode into v_session, v_entry_mode
    from public.learning_sessions s
    where s.id = p_session_id
      and s.student_id = p_student_id
      and s.academy_id = v_academy
      and s.status in ('open', 'paused')
    limit 1;

    if v_session is not null then
      update public.learning_sessions
      set last_beat_at = now(),
          updated_at = now()
      where id = v_session;
    end if;
  end if;

  v_meta := coalesce(p_meta, '{}'::jsonb)
    || case when v_auto_linked
         then jsonb_build_object('auto_linked', true)
         else '{}'::jsonb
       end
    || case when v_free_practice
         then jsonb_build_object('free_practice', true)
         else '{}'::jsonb
       end
    || case when v_entry_mode is not null
         then jsonb_build_object('entry_mode', v_entry_mode)
         else '{}'::jsonb
       end;

  if v_session is null then
    select s.id into v_session
    from public.learning_sessions s
    where s.student_id = p_student_id
      and s.academy_id = v_academy
      and s.scored_by = v_scored_by
      and s.status = 'open'
      and s.entry_mode is null
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
  end if;

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

  perform public._student_apply_round_attempt(v_round, v_result, now());

  select r.round_no into v_round_no
  from public.student_problem_rounds r
  where r.id = v_round;

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

grant execute on function public.learning_log_homework_attempt(
  uuid, uuid, uuid, text, text, text, integer, text, jsonb, uuid
) to authenticated;
