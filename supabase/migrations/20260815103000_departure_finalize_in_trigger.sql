-- 하원 시각이 찍히는 모든 경로(학습앱 슬라이드/홈카드, 스탠바이미)에서
-- 대기 리셋과 오늘→숙제 전환을 같은 트리거로 처리한다.
--
-- 공개 RPC는 멤버십 검사 후 내부 함수만 호출한다. 트리거는 auth.uid() 없이
-- 내부 함수를 직접 부른다. 이미 처리된 항목은 pending 이 아니라 재실행해도
-- 숙제를 중복 생성하지 않는다.

create or replace function public._homework_finalize_session_plan_departure(
  p_attendance_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_attendance public.attendance_records%rowtype;
  v_plan public.homework_session_plan_items%rowtype;
  v_assignment_id uuid;
  v_due_at timestamptz;
  v_homework_count integer := 0;
  v_next_count integer := 0;
  v_seeded_count integer := 0;
begin
  if p_attendance_id is null then
    return jsonb_build_object(
      'attendance_id', null,
      'homework_count', 0,
      'next_session_count', 0,
      'seeded_plan_count', 0
    );
  end if;

  select ar.*
  into v_attendance
  from public.attendance_records ar
  where ar.id = p_attendance_id
  for update;

  if v_attendance.id is null then
    raise exception 'HOMEWORK_SESSION_PLAN_ATTENDANCE_NOT_FOUND';
  end if;

  perform pg_advisory_xact_lock(hashtext(p_attendance_id::text));
  v_due_at := public._homework_session_plan_next_attendance_at(
    v_attendance.academy_id,
    v_attendance.student_id,
    coalesce(
      v_attendance.departure_time,
      v_attendance.class_date_time,
      now()
    )
  );

  insert into public.homework_session_plan_items (
    academy_id,
    student_id,
    source_attendance_id,
    target_class_at,
    origin,
    destination,
    resolution,
    rollover_policy,
    recommended_minutes_snapshot,
    group_id,
    homework_item_id,
    order_index
  )
  select
    h.academy_id,
    h.student_id,
    p_attendance_id,
    null,
    'planned_today'::public.homework_session_plan_origin,
    'in_class'::public.homework_session_plan_destination,
    'pending'::public.homework_session_plan_resolution,
    'to_homework',
    coalesce(h.recommended_minutes, h.recommended_minutes_auto),
    gi.group_id,
    h.id,
    gi.item_order_index
  from public.homework_items h
  join public.homework_group_items gi
    on gi.academy_id = h.academy_id
   and gi.homework_item_id = h.id
  join public.homework_groups g
    on g.id = gi.group_id
   and g.academy_id = h.academy_id
   and g.status = 'active'
  where h.academy_id = v_attendance.academy_id
    and h.student_id = v_attendance.student_id
    and h.completed_at is null
    and coalesce(h.status, 0) = 0
    and coalesce(h.phase, 1) <> 0
    and coalesce(h.type, '') <> '테스트'
    and h.created_at >= coalesce(
      v_attendance.arrival_time,
      v_attendance.class_date_time,
      v_attendance.created_at
    )
    and h.created_at <= coalesce(v_attendance.departure_time, now())
    and not exists (
      select 1
      from public.homework_assignments a
      where a.academy_id = h.academy_id
        and a.student_id = h.student_id
        and a.homework_item_id = h.id
        and a.status in ('assigned', 'in_progress', 'carried_to_class')
    )
    and not exists (
      select 1
      from public.homework_session_plan_items spi
      where spi.academy_id = h.academy_id
        and spi.student_id = h.student_id
        and spi.homework_item_id = h.id
        and spi.resolution in ('pending', 'confirmed')
    )
  on conflict (source_attendance_id, homework_item_id)
    where source_attendance_id is not null
  do nothing;

  get diagnostics v_seeded_count = row_count;

  for v_plan in
    select spi.*
    from public.homework_session_plan_items spi
    join public.homework_items h
      on h.id = spi.homework_item_id
     and h.academy_id = spi.academy_id
     and h.student_id = spi.student_id
    where spi.source_attendance_id = p_attendance_id
      and spi.academy_id = v_attendance.academy_id
      and spi.student_id = v_attendance.student_id
      and spi.destination = 'in_class'
      and spi.resolution = 'pending'
      and spi.rollover_policy in ('to_homework', 'carry_paused')
      and h.completed_at is null
      and coalesce(h.status, 0) <> 1
      and coalesce(h.phase, 1) <> 0
    order by spi.order_index, spi.id
    for update of spi
  loop
    if v_plan.rollover_policy = 'to_homework' then
      select a.id
      into v_assignment_id
      from public.homework_assignments a
      where a.academy_id = v_plan.academy_id
        and a.student_id = v_plan.student_id
        and a.homework_item_id = v_plan.homework_item_id
        and a.status in ('assigned', 'in_progress', 'carried_to_class')
      order by a.created_at desc, a.id
      limit 1
      for update;

      if v_assignment_id is null then
        insert into public.homework_assignments (
          academy_id,
          student_id,
          homework_item_id,
          assigned_at,
          due_date,
          order_index,
          status,
          note,
          group_id,
          group_title_snapshot,
          learning_track_code_snapshot
        )
        select
          v_plan.academy_id,
          v_plan.student_id,
          v_plan.homework_item_id,
          now(),
          case
            when coalesce(v_plan.target_class_at, v_due_at) is null then null
            else (
              coalesce(v_plan.target_class_at, v_due_at)
                at time zone 'Asia/Seoul'
            )::date
          end,
          v_plan.order_index,
          'assigned',
          '__session_plan_departure__',
          v_plan.group_id,
          coalesce(g.title, h.title, '그룹 과제'),
          h.learning_track_code
        from public.homework_items h
        left join public.homework_groups g on g.id = v_plan.group_id
        where h.id = v_plan.homework_item_id
        returning id into v_assignment_id;
      end if;

      update public.homework_assignments a
      set status = 'assigned',
          due_at = coalesce(v_plan.target_class_at, v_due_at),
          due_for_check_at = null,
          absence_carryover = false,
          updated_at = now(),
          version = a.version + 1
      where a.id = v_assignment_id
        and (
          a.status = 'carried_to_class'
          or a.due_at is distinct from coalesce(v_plan.target_class_at, v_due_at)
          or a.due_for_check_at is not null
          or a.absence_carryover
        );

      -- 대기 전환만 한다. check_count 는 올리지 않는다.
      update public.homework_items h
      set status = 2,
          phase = 1,
          run_start = null,
          waiting_at = coalesce(h.waiting_at, now()),
          updated_at = now(),
          version = h.version + 1
      where h.id = v_plan.homework_item_id
        and (
          coalesce(h.status, 0) <> 2
          or coalesce(h.phase, 1) <> 1
          or h.run_start is not null
        );

      update public.homework_session_plan_items spi
      set destination = 'homework',
          resolution = 'confirmed',
          rollover_policy = 'none',
          target_class_at = coalesce(spi.target_class_at, v_due_at),
          assignment_id = v_assignment_id,
          updated_at = now(),
          version = spi.version + 1
      where spi.id = v_plan.id;
      v_homework_count := v_homework_count + 1;
    else
      update public.homework_items h
      set phase = 1,
          run_start = null,
          waiting_at = coalesce(h.waiting_at, now()),
          updated_at = now(),
          version = h.version + 1
      where h.id = v_plan.homework_item_id
        and (coalesce(h.phase, 1) <> 1 or h.run_start is not null);

      update public.homework_session_plan_items spi
      set destination = 'next_session',
          target_class_at = coalesce(spi.target_class_at, v_due_at),
          updated_at = now(),
          version = spi.version + 1
      where spi.id = v_plan.id;
      v_next_count := v_next_count + 1;
    end if;
  end loop;

  update public.homework_group_runtime r
  set accumulated_ms = coalesce(r.accumulated_ms, 0)
        + case
            when r.run_start is not null then greatest(
              0,
              floor(extract(epoch from (now() - r.run_start)) * 1000)::bigint
            )
            else 0
          end,
      phase = 1,
      run_start = null,
      updated_at = now(),
      version = r.version + 1
  where r.academy_id = v_attendance.academy_id
    and r.group_id in (
      select distinct spi.group_id
      from public.homework_session_plan_items spi
      where spi.source_attendance_id = p_attendance_id
        and spi.destination in ('homework', 'next_session')
        and spi.resolution in ('pending', 'confirmed')
    )
    and (r.phase <> 1 or r.run_start is not null);

  return jsonb_build_object(
    'attendance_id', p_attendance_id,
    'homework_count', v_homework_count,
    'next_session_count', v_next_count,
    'seeded_plan_count', v_seeded_count
  );
end;
$$;

create or replace function public.homework_finalize_session_plan_departure(
  p_attendance_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy_id uuid;
begin
  select ar.academy_id
  into v_academy_id
  from public.attendance_records ar
  where ar.id = p_attendance_id;

  if v_academy_id is null then
    raise exception 'HOMEWORK_SESSION_PLAN_ATTENDANCE_NOT_FOUND';
  end if;
  if not exists (
    select 1
    from public.memberships m
    where m.academy_id = v_academy_id
      and m.user_id = auth.uid()
  ) then
    raise exception 'HOMEWORK_SESSION_PLAN_FORBIDDEN';
  end if;

  return public._homework_finalize_session_plan_departure(p_attendance_id);
end;
$$;

revoke all on function public._homework_finalize_session_plan_departure(uuid)
  from public;
revoke all on function public.homework_finalize_session_plan_departure(uuid)
  from public;
grant execute on function public.homework_finalize_session_plan_departure(uuid)
  to authenticated;

create or replace function public._homework_reset_on_departure()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cut timestamptz;
  v_item record;
begin
  if new.departure_time is null
     or old.departure_time is not null then
    return new;
  end if;

  v_cut := least(new.departure_time, now());

  for v_item in
    select i.item_id, h.run_start
    from public.homework_study_intervals i
    join public.homework_items h on h.id = i.item_id
    where i.academy_id = new.academy_id
      and i.student_id = new.student_id
      and i.ended_at is null
  loop
    perform public._homework_close_interval(
      v_item.item_id,
      greatest(v_cut, v_item.run_start),
      'departure'
    );
  end loop;

  update public.homework_items h
  set accumulated_ms = coalesce(h.accumulated_ms, 0)
        + greatest(
            0,
            floor(extract(epoch from (greatest(v_cut, h.run_start) - h.run_start)) * 1000)::bigint
          ),
      run_start = null,
      updated_at = now(),
      version = coalesce(h.version, 1) + 1
  where h.academy_id = new.academy_id
    and h.student_id = new.student_id
    and h.run_start is not null
    and h.completed_at is null;

  -- 오늘/숙제/다음 모두: 수행·제출·확인을 대기로 되돌린다.
  -- check_count 는 대기→수행에서만 늘어야 하므로 여기서 올리지 않는다.
  with reset as (
    update public.homework_items h
    set phase = 1,
        run_start = null,
        waiting_at = now(),
        updated_at = now(),
        version = coalesce(h.version, 1) + 1
    where h.academy_id = new.academy_id
      and h.student_id = new.student_id
      and h.completed_at is null
      and coalesce(h.status, 0) <> 1
      and coalesce(h.phase, 1) not in (0, 1)
    returning h.id
  )
  insert into public.homework_item_phase_events (
    academy_id, item_id, phase, actor_user_id, note
  )
  select new.academy_id, r.id, 1::smallint, auth.uid(), 'departure_reset'
  from reset r;

  update public.homework_group_runtime r
  set accumulated_ms = coalesce(r.accumulated_ms, 0)
        + case
            when r.run_start is not null then greatest(
              0,
              floor(extract(epoch from (greatest(v_cut, r.run_start) - r.run_start)) * 1000)::bigint
            )
            else 0
          end,
      run_start = null,
      phase = 1,
      updated_at = now(),
      version = coalesce(r.version, 1) + 1
  where r.academy_id = new.academy_id
    and r.student_id = new.student_id
    and (r.phase <> 1 or r.run_start is not null);

  -- 오늘 과제는 다음 수업까지 숙제로 넘긴다. 실패해도 하원 자체는 남긴다.
  begin
    perform public._homework_finalize_session_plan_departure(new.id);
  exception
    when others then
      raise warning 'homework finalize on departure failed attendance=%: %',
        new.id, sqlerrm;
  end;

  return new;
end;
$$;
