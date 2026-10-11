-- 수업 중 처음 생긴 채점용 assignment를 숙제 첫 검사로 오인하지 않는다.
--
-- 숙제 첫 검사는 등원 전에 이미 배정된 assignment의 첫 검사만 해당한다.
-- 수업 중 과제의 채점 과정에서 assignment/check가 함께 생성되더라도 첫 채점부터
-- 오늘 푼 문항으로 센다. 기존 함수가 길어, 바로 앞 최종 정의의 검증된 조각만
-- 교체하고 예상 정의와 다르면 migration을 중단한다.

do $migration$
declare
  v_definition text;
  v_old text;
  v_new text;
begin
  select pg_get_functiondef(
    'public._lesson_record_compute(uuid)'::regprocedure
  )
  into v_definition;

  v_old := $old$
    from public.homework_assignment_checks c
    where c.academy_id = v_ar.academy_id
      and c.student_id = v_ar.student_id
    group by c.homework_item_id
  ),
  cand as ($old$;
  v_new := $new$
    from public.homework_assignment_checks c
    join public.homework_assignments a
      on a.id = c.assignment_id
     and a.academy_id = c.academy_id
     and a.student_id = c.student_id
    where c.academy_id = v_ar.academy_id
      and c.student_id = v_ar.student_id
    group by c.homework_item_id
  ),
  cand as ($new$;
  v_old := replace(v_old, E'\r', '');
  v_new := replace(v_new, E'\r', '');
  if strpos(v_definition, v_old) = 0 then
    raise exception 'LESSON_RECORD_PRECLASS_HOMEWORK_CHK_SOURCE_MISMATCH';
  end if;
  v_definition := replace(v_definition, v_old, v_new);

  v_old := $old$
      bool_or(
        c.checked_at >= v_day_start
        and c.checked_at < v_day_end
        and not exists ($old$;
  v_new := $new$
      bool_or(
        c.checked_at >= v_day_start
        and c.checked_at < v_day_end
        and a.assigned_at < v_start
        and not exists ($new$;
  v_old := replace(v_old, E'\r', '');
  v_new := replace(v_new, E'\r', '');
  if strpos(v_definition, v_old) = 0 then
    raise exception 'LESSON_RECORD_PRECLASS_HOMEWORK_FLAG_SOURCE_MISMATCH';
  end if;
  v_definition := replace(v_definition, v_old, v_new);

  v_old := $old$
  from public.homework_assignment_checks c
  where c.academy_id = v_ar.academy_id
    and c.student_id = v_ar.student_id
    and c.homework_item_id = any(v_homework_items)$old$;
  v_new := $new$
  from public.homework_assignment_checks c
  join public.homework_assignments a
    on a.id = c.assignment_id
   and a.academy_id = c.academy_id
   and a.student_id = c.student_id
  where c.academy_id = v_ar.academy_id
    and c.student_id = v_ar.student_id
    and a.assigned_at < v_start
    and c.homework_item_id = any(v_homework_items)$new$;
  v_old := replace(v_old, E'\r', '');
  v_new := replace(v_new, E'\r', '');
  if strpos(v_definition, v_old) = 0 then
    raise exception 'LESSON_RECORD_PRECLASS_HOMEWORK_ITEMS_SOURCE_MISMATCH';
  end if;
  v_definition := replace(v_definition, v_old, v_new);

  v_old := $old$'version', 3,$old$;
  v_new := $new$'version', 4,$new$;
  v_old := replace(v_old, E'\r', '');
  v_new := replace(v_new, E'\r', '');
  if strpos(v_definition, v_old) = 0 then
    raise exception 'LESSON_RECORD_PRECLASS_HOMEWORK_VERSION_SOURCE_MISMATCH';
  end if;
  v_definition := replace(v_definition, v_old, v_new);

  execute v_definition;
end;
$migration$;

comment on column public.student_class_session_snapshots.solved_problem_count is
  '수업 시간에 푼 고유 문항 수. 등원 전 배정된 숙제의 첫 검사와 다시 저장한 정답은 제외한다. null = 문항 기록 없음.';

-- v3 적용 이후 만들어진 스냅샷은 같은 원자료로 다시 계산할 수 있다.
do $backfill$
declare
  v_attendance_id uuid;
begin
  for v_attendance_id in
    select ar.id
    from public.attendance_records ar
    join public.student_class_session_snapshots s
      on s.attendance_id = ar.id
    where ar.departure_time >= timestamptz '2026-10-05 00:00:00+09'
  loop
    perform public._lesson_record_refresh(v_attendance_id);
  end loop;
end;
$backfill$;
