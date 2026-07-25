-- 20260725180000: 학습 기록 ↔ 과제 출제 스냅샷 연결
--
-- homework_item_problems 는 "과제로 낸 문항"의 출제 시점 스냅샷이고,
-- learning_exposures / learning_attempts 는 "실제로 보여주고 푼" 사건이다.
-- 둘을 연결해야 "낸 것 대비 푼 것"을 문항 단위로 맞출 수 있다.
-- (docs/architecture/learning-records.md 참고)

alter table public.learning_exposures
  add column if not exists homework_item_problem_id uuid
    references public.homework_item_problems(id) on delete set null;

alter table public.learning_attempts
  add column if not exists homework_item_problem_id uuid
    references public.homework_item_problems(id) on delete set null;

create index if not exists learning_exposures_hw_problem_idx
  on public.learning_exposures (homework_item_problem_id)
  where homework_item_problem_id is not null;

create index if not exists learning_attempts_hw_problem_idx
  on public.learning_attempts (homework_item_problem_id)
  where homework_item_problem_id is not null;

-- 출제 스냅샷만 넘겨도 문항 식별자가 채워지도록 한다.
create or replace function public._learning_exposures_fill_item()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  h record;
  c record;
begin
  if new.homework_item_problem_id is not null and new.crop_id is null then
    select p.crop_id, p.pb_question_uid, p.book_id, p.grade_label,
           p.raw_page, p.display_page
    into h
    from public.homework_item_problems p
    where p.id = new.homework_item_problem_id;

    if found then
      new.crop_id := coalesce(new.crop_id, h.crop_id);
      new.pb_question_uid := coalesce(new.pb_question_uid, h.pb_question_uid);
      new.book_id := coalesce(new.book_id, h.book_id);
      new.grade_label := coalesce(new.grade_label, h.grade_label);
      new.raw_page := coalesce(new.raw_page, h.raw_page);
      new.display_page := coalesce(new.display_page, h.display_page);
    end if;
  end if;

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
    select le.crop_id, le.pb_question_uid, le.book_id, le.grade_label,
           le.unit_id, le.homework_item_problem_id
    into e
    from public.learning_exposures le
    where le.id = new.exposure_id;

    if found then
      new.crop_id := coalesce(new.crop_id, e.crop_id);
      new.pb_question_uid := coalesce(new.pb_question_uid, e.pb_question_uid);
      new.book_id := coalesce(new.book_id, e.book_id);
      new.grade_label := coalesce(new.grade_label, e.grade_label);
      new.unit_id := coalesce(new.unit_id, e.unit_id);
      new.homework_item_problem_id :=
        coalesce(new.homework_item_problem_id, e.homework_item_problem_id);
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

-- RPC 에서도 출제 스냅샷 id 를 받을 수 있게 한다.
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
       and nullif(v_item->>'pb_question_uid', '') is null
       and nullif(v_item->>'homework_item_problem_id', '') is null then
      continue;
    end if;

    insert into public.learning_exposures (
      academy_id, student_id, session_id,
      crop_id, pb_question_uid, homework_item_problem_id,
      book_id, grade_label,
      exposure_reason, recommender_key, is_anchor,
      position_in_session, exposed_at, meta
    )
    values (
      v_s.academy_id, v_s.student_id, p_session_id,
      nullif(v_item->>'crop_id', '')::uuid,
      nullif(v_item->>'pb_question_uid', '')::uuid,
      nullif(v_item->>'homework_item_problem_id', '')::uuid,
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
      'homework_item_problem_id', nullif(v_item->>'homework_item_problem_id', ''),
      'position_in_session', coalesce((v_item->>'position_in_session')::integer, v_idx)
    );
  end loop;

  return v_out;
end;
$$;

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
  v_hip uuid;
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
    v_hip := nullif(v_item->>'homework_item_problem_id', '')::uuid;

    if v_exposure is null and (v_crop is not null or v_pb is not null or v_hip is not null) then
      select e.id into v_exposure
      from public.learning_exposures e
      where e.session_id = p_session_id
        and (
          (v_crop is not null and e.crop_id = v_crop)
          or (v_crop is null and v_pb is not null and e.pb_question_uid = v_pb)
          or (v_crop is null and v_pb is null and e.homework_item_problem_id = v_hip)
        )
      order by e.exposed_at desc
      limit 1;
    end if;

    if v_crop is null and v_pb is null and v_hip is null and v_exposure is null then
      continue;
    end if;

    insert into public.learning_attempts (
      academy_id, student_id, session_id, exposure_id,
      crop_id, pb_question_uid, homework_item_problem_id,
      book_id, grade_label,
      result, answer_text,
      assist_level, assist_note, confidence,
      duration_ms, duration_source,
      scored_by, scored_at, scorer_user_id,
      student_level_snapshot, attempted_at, meta
    )
    values (
      v_s.academy_id, v_s.student_id, p_session_id, v_exposure,
      v_crop, v_pb, v_hip,
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

comment on column public.learning_exposures.homework_item_problem_id is
  '과제로 낸 문항 스냅샷(homework_item_problems). 낸 것 대비 푼 것을 문항 단위로 맞출 때 쓴다.';
