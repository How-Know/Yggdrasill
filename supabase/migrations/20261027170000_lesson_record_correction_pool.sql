-- 알림장 "수정한 문제"를 오늘 손댄 오답 문항 수로 바꾼다.
--
-- 회차 첫 채점이 이번 수업에서 틀린 문항뿐 아니라, 지난 수업에서 틀리고
-- 이번 수업 시작 전까지 정답이 없던 문항도 오늘 채점이 있으면 센다.
-- 이미 지난 수업에 정답으로 끝난 문항은 오늘 다시 채점해도 세지 않는다.
-- 수정률은 그중 하원까지 정답이 나온 비율이다.
-- 최대 수정 횟수는 오늘 고친 문항의 회차 첫 채점부터 정답까지 채점 수 중 최댓값.

alter table public.student_class_session_snapshots
  add column if not exists max_correction_tries integer;

comment on column public.student_class_session_snapshots.correction_required_count is
  '오늘(등원~하원) 채점한 오답 문항 수. 이번 수업에서 처음 틀린 문항과, 지난 수업에서 틀리고 수업 시작 전까지 정답이 없던 문항. null = 문항 기록 없음.';
comment on column public.student_class_session_snapshots.correction_success_count is
  'correction_required_count 중 하원까지 정답이 나온 문항 수.';
comment on column public.student_class_session_snapshots.max_correction_tries is
  '오늘 고친 문항(correction_success_count)의 회차 첫 채점부터 정답까지 채점 수 중 최댓값. 고친 문항이 없으면 null.';

do $compute$
declare
  v_definition text;
  v_old text;
  v_new text;
begin
  select pg_get_functiondef(
    'public._lesson_record_compute(uuid)'::regprocedure
  )
  into v_definition;
  v_definition := replace(v_definition, E'\r', '');

  v_old := $old$  v_avg_tries numeric;
$old$;
  v_new := $new$  v_avg_tries numeric;
  v_max_tries integer;
$new$;
  v_old := replace(v_old, E'\r', '');
  v_new := replace(v_new, E'\r', '');
  if strpos(v_definition, v_old) = 0 then
    raise exception 'LESSON_RECORD_CORRECTION_DECLARE_MISMATCH';
  end if;
  v_definition := replace(v_definition, v_old, v_new);

  v_old := $old$      (
        select count(distinct t.crop_id)
        from touched t
        join round_first f on f.round_id = t.round_id
        where f.first_result in ('wrong', 'partial')
          and f.first_at >= v_start
      )::integer,
      (
        select count(distinct t.crop_id)
        from touched t
        join round_first f on f.round_id = t.round_id
        join round_pass rp on rp.round_id = t.round_id
        where f.first_result in ('wrong', 'partial')
          and f.first_at >= v_start
          and rp.first_correct_at > f.first_at
      )::integer,
      (select count(*) from passed_tries)::integer,
      (select round(avg(pt.tries)::numeric, 2) from passed_tries pt)
    into v_solved, v_first_try, v_correction_required, v_correction_success,
      v_passed, v_avg_tries;
$old$;
  v_new := $new$      (
        -- 오늘 손댄 오답: 회차가 틀림·부분으로 시작했고, 등원 전에 이미 정답이 없다.
        select count(distinct t.crop_id)
        from touched t
        join round_first f on f.round_id = t.round_id
        where f.first_result in ('wrong', 'partial')
          and not exists (
            select 1
            from round_pass early
            where early.round_id = t.round_id
              and early.first_correct_at < v_start
          )
      )::integer,
      (
        select count(distinct t.crop_id)
        from touched t
        join round_first f on f.round_id = t.round_id
        join round_pass rp on rp.round_id = t.round_id
        where f.first_result in ('wrong', 'partial')
          and rp.first_correct_at >= v_start
          and rp.first_correct_at > f.first_at
      )::integer,
      (select count(*) from passed_tries)::integer,
      (select round(avg(pt.tries)::numeric, 2) from passed_tries pt),
      (
        select max(st.tries)::integer
        from (
          select greatest(1, (
            select count(*)
            from public.learning_attempts a
            where a.round_id = t.round_id
              and a.result in ('correct', 'wrong', 'partial')
              and a.attempted_at <= rp.first_correct_at
          )) as tries
          from touched t
          join round_first f on f.round_id = t.round_id
          join round_pass rp on rp.round_id = t.round_id
          where f.first_result in ('wrong', 'partial')
            and rp.first_correct_at >= v_start
            and rp.first_correct_at > f.first_at
        ) st
      )
    into v_solved, v_first_try, v_correction_required, v_correction_success,
      v_passed, v_avg_tries, v_max_tries;
$new$;
  v_old := replace(v_old, E'\r', '');
  v_new := replace(v_new, E'\r', '');
  if strpos(v_definition, v_old) = 0 then
    raise exception 'LESSON_RECORD_CORRECTION_COUNT_MISMATCH';
  end if;
  v_definition := replace(v_definition, v_old, v_new);

  v_old := $old$    'avg_tries_to_pass', v_avg_tries,
$old$;
  v_new := $new$    'avg_tries_to_pass', v_avg_tries,
    'max_correction_tries', v_max_tries,
$new$;
  v_old := replace(v_old, E'\r', '');
  v_new := replace(v_new, E'\r', '');
  if strpos(v_definition, v_old) = 0 then
    raise exception 'LESSON_RECORD_CORRECTION_RETURN_MISMATCH';
  end if;
  v_definition := replace(v_definition, v_old, v_new);

  v_old := $old$    'version', 5,$old$;
  v_new := $new$    'version', 6,$new$;
  v_old := replace(v_old, E'\r', '');
  v_new := replace(v_new, E'\r', '');
  if strpos(v_definition, v_old) = 0 then
    raise exception 'LESSON_RECORD_CORRECTION_VERSION_MISMATCH';
  end if;
  v_definition := replace(v_definition, v_old, v_new);

  execute v_definition;
end;
$compute$;

do $refresh$
declare
  v_definition text;
  v_old text;
  v_new text;
begin
  select pg_get_functiondef(
    'public._lesson_record_refresh(uuid)'::regprocedure
  )
  into v_definition;
  v_definition := replace(v_definition, E'\r', '');

  v_old := $old$      avg_tries_to_pass = (v_record->>'avg_tries_to_pass')::numeric,
$old$;
  v_new := $new$      avg_tries_to_pass = (v_record->>'avg_tries_to_pass')::numeric,
      max_correction_tries = (v_record->>'max_correction_tries')::integer,
$new$;
  v_old := replace(v_old, E'\r', '');
  v_new := replace(v_new, E'\r', '');
  if strpos(v_definition, v_old) = 0 then
    raise exception 'LESSON_RECORD_REFRESH_MAX_TRIES_MISMATCH';
  end if;
  execute replace(v_definition, v_old, v_new);
end;
$refresh$;
