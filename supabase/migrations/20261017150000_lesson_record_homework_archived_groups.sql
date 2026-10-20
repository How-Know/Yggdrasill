-- 알림장 숙제 수를 그룹 과제 단위로 유지한다.
--
-- 완료된 그룹은 archived가 된다. 활성 그룹만 묶으면 그 하위과제가
-- 각각 한 건으로 갈라진다. 한 문항은 그룹에 최대 하나이므로
-- 보관 그룹 링크를 그대로 그룹 키로 쓴다.

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
  with grp_link as (
    select gi.homework_item_id as item_id, gi.group_id
    from public.homework_group_items gi
    join public.homework_groups g
      on g.id = gi.group_id
     and g.status = 'active'
    where gi.academy_id = v_ar.academy_id
      and gi.student_id = v_ar.student_id
  ),$old$;
  v_new := $new$
  with grp_link as (
    select gi.homework_item_id as item_id, gi.group_id
    from public.homework_group_items gi
    join public.homework_groups g
      on g.id = gi.group_id
    where gi.academy_id = v_ar.academy_id
      and gi.student_id = v_ar.student_id
  ),$new$;
  v_old := replace(v_old, E'\r', '');
  v_new := replace(v_new, E'\r', '');
  v_definition := replace(v_definition, E'\r', '');
  if strpos(v_definition, v_old) = 0 then
    raise exception 'LESSON_RECORD_HOMEWORK_GROUP_SOURCE_MISMATCH';
  end if;
  v_definition := replace(v_definition, v_old, v_new);

  execute v_definition;
end;
$migration$;

-- 이미 저장된 하원 요약도 같은 기준으로 다시 계산한다.
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
