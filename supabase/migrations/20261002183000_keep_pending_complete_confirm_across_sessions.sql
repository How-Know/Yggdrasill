-- 완료 플래그(pending_complete)가 켜진 확인(phase 4) 과제만
-- 하원 마무리와 다음 등원 승격에서 대기/숙제로 내리지 않는다.
-- 확인만 된 과제, 수행·제출 과제는 기존처럼 대기로 돌아간다.
-- homework_wait 와 하원 phase 리셋의 예외는 20260924113000 에 있다.
-- 그 뒤에 같은 트리거가 호출하는 수업 계획 마무리, 그리고 등원 승격이
-- phase 를 다시 1로 덮고 있었다.

create or replace function public._homework_item_keeps_complete_confirm(
  p_item_id uuid
) returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.homework_items h
    where h.id = p_item_id
      and h.completed_at is null
      and coalesce(h.status, 0) <> 1
      and coalesce(h.phase, 1) = 4
      and coalesce(h.pending_complete, false)
  );
$$;

create or replace function public._homework_group_keeps_complete_confirm(
  p_academy_id uuid,
  p_group_id uuid
) returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.homework_group_items gi
    join public.homework_items h
      on h.id = gi.homework_item_id
     and h.academy_id = gi.academy_id
    where gi.academy_id = p_academy_id
      and gi.group_id = p_group_id
      and h.completed_at is null
      and coalesce(h.status, 0) <> 1
      and coalesce(h.phase, 1) = 4
      and coalesce(h.pending_complete, false)
  );
$$;

revoke all on function public._homework_item_keeps_complete_confirm(uuid) from public;
revoke all on function public._homework_group_keeps_complete_confirm(uuid, uuid) from public;

create or replace function public.homework_session_plan_promote_next_session(
  p_attendance_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_attendance public.attendance_records%rowtype;
  v_effective_class_at timestamptz;
  v_candidate record;
  v_promoted_ids uuid[] := array[]::uuid[];
  v_new_plan_id uuid;
  v_is_homework_return boolean;
  v_group_phase smallint;
begin
  select ar.*
  into v_attendance
  from public.attendance_records ar
  where ar.id = p_attendance_id
  for update;

  if v_attendance.id is null then
    raise exception 'HOMEWORK_SESSION_PLAN_ATTENDANCE_NOT_FOUND';
  end if;
  if auth.uid() is not null
     and not exists (
       select 1
       from public.memberships m
       where m.academy_id = v_attendance.academy_id
         and m.user_id = auth.uid()
     )
     and not exists (
       select 1
       from public.student_app_accounts saa
       where saa.user_id = auth.uid()
         and saa.academy_id = v_attendance.academy_id
         and saa.student_id = v_attendance.student_id
     ) then
    raise exception 'HOMEWORK_SESSION_PLAN_FORBIDDEN';
  end if;

  perform pg_advisory_xact_lock(hashtext(p_attendance_id::text));
  v_effective_class_at := coalesce(
    v_attendance.class_date_time,
    v_attendance.arrival_time,
    now()
  );

  for v_candidate in
    select distinct on (spi.homework_item_id)
      spi.*
    from public.homework_session_plan_items spi
    join public.homework_items h
      on h.id = spi.homework_item_id
     and h.completed_at is null
     and coalesce(h.status, 0) <> 1
    where spi.academy_id = v_attendance.academy_id
      and spi.student_id = v_attendance.student_id
      and spi.source_attendance_id is distinct from p_attendance_id
      and spi.resolution in ('pending', 'confirmed')
      and (
        (
          spi.destination = 'next_session'
          and spi.rollover_policy = 'carry_paused'
          and (
            spi.target_class_at is null
            or spi.target_class_at <= v_effective_class_at
          )
        )
        or (
          spi.destination = 'homework'
          and spi.rollover_policy = 'none'
          and spi.assignment_id is not null
          and (
            spi.target_class_at is null
            or (
              spi.target_class_at at time zone 'Asia/Seoul'
            )::date <= (
              v_effective_class_at at time zone 'Asia/Seoul'
            )::date
          )
        )
      )
    order by
      spi.homework_item_id,
      spi.target_class_at desc nulls last,
      spi.created_at desc,
      spi.id desc
  loop
    v_is_homework_return :=
      v_candidate.destination = 'homework'
      and v_candidate.assignment_id is not null;

    if v_is_homework_return then
      update public.homework_assignments a
      set status = 'carried_to_class',
          due_for_check_at = v_effective_class_at,
          absence_carryover = (
            coalesce(a.due_at, v_candidate.target_class_at) is not null
            and (
              coalesce(a.due_at, v_candidate.target_class_at)
                at time zone 'Asia/Seoul'
            )::date < (
              v_effective_class_at at time zone 'Asia/Seoul'
            )::date
          ),
          updated_at = now(),
          version = a.version + 1
      where a.id = v_candidate.assignment_id
        and a.status in ('assigned', 'in_progress');

      update public.homework_items h
      set status = 0,
          phase = 1,
          run_start = null,
          waiting_at = coalesce(h.waiting_at, now()),
          updated_at = now(),
          version = h.version + 1
      where h.id = v_candidate.homework_item_id
        and not public._homework_item_keeps_complete_confirm(h.id)
        and (
          coalesce(h.status, 0) <> 0
          or coalesce(h.phase, 1) <> 1
          or h.run_start is not null
        );
    else
      update public.homework_items h
      set phase = 1,
          run_start = null,
          waiting_at = coalesce(h.waiting_at, now()),
          updated_at = now(),
          version = h.version + 1
      where h.id = v_candidate.homework_item_id
        and not public._homework_item_keeps_complete_confirm(h.id)
        and (coalesce(h.phase, 1) <> 1 or h.run_start is not null);
    end if;

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
      assignment_id,
      carried_from_plan_item_id,
      order_index
    )
    values (
      v_candidate.academy_id,
      v_candidate.student_id,
      p_attendance_id,
      case when v_is_homework_return then null else v_effective_class_at end,
      'carried_from_previous',
      'in_class',
      'pending',
      case when v_is_homework_return then 'to_homework' else 'carry_paused' end,
      v_candidate.recommended_minutes_snapshot,
      v_candidate.group_id,
      v_candidate.homework_item_id,
      case when v_is_homework_return
        then v_candidate.assignment_id
        else null
      end,
      v_candidate.id,
      v_candidate.order_index
    )
    on conflict (source_attendance_id, homework_item_id)
      where source_attendance_id is not null
    do update set
      origin = 'carried_from_previous',
      destination = 'in_class',
      resolution = 'pending',
      rollover_policy = excluded.rollover_policy,
      assignment_id = excluded.assignment_id,
      carried_from_plan_item_id = excluded.carried_from_plan_item_id,
      target_class_at = excluded.target_class_at,
      group_id = excluded.group_id,
      updated_at = now(),
      version = homework_session_plan_items.version + 1
    returning id into v_new_plan_id;

    update public.homework_session_plan_items spi
    set resolution = 'promoted',
        updated_at = now(),
        version = spi.version + 1
    where spi.id = v_candidate.id
      and spi.resolution <> 'promoted';

    perform public.m5_group_runtime_seed(
      v_candidate.academy_id,
      v_candidate.group_id
    );
    v_group_phase := case
      when public._homework_group_keeps_complete_confirm(
        v_candidate.academy_id,
        v_candidate.group_id
      ) then 4
      else 1
    end;
    update public.homework_group_runtime r
    set phase = v_group_phase,
        run_start = null,
        updated_at = now(),
        version = r.version + 1
    where r.academy_id = v_candidate.academy_id
      and r.group_id = v_candidate.group_id
      and (
        r.run_start is not null
        or r.phase is distinct from v_group_phase
      );

    v_promoted_ids := array_append(v_promoted_ids, v_new_plan_id);
  end loop;

  return jsonb_build_object(
    'attendance_id', p_attendance_id,
    'promoted_plan_item_ids', to_jsonb(v_promoted_ids),
    'promoted_count', cardinality(v_promoted_ids)
  );
end;
$$;

revoke all on function public.homework_session_plan_promote_next_session(uuid) from public;
grant execute on function public.homework_session_plan_promote_next_session(uuid) to authenticated;

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
      -- 완료 플래그가 있는 확인 과제는 phase/상태를 그대로 둔다.
      update public.homework_items h
      set status = 2,
          phase = 1,
          run_start = null,
          waiting_at = coalesce(h.waiting_at, now()),
          updated_at = now(),
          version = h.version + 1
      where h.id = v_plan.homework_item_id
        and not public._homework_item_keeps_complete_confirm(h.id)
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
        and not public._homework_item_keeps_complete_confirm(h.id)
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
      phase = case
        when public._homework_group_keeps_complete_confirm(r.academy_id, r.group_id)
          then 4
        else 1
      end,
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
    and (
      r.run_start is not null
      or r.phase is distinct from case
        when public._homework_group_keeps_complete_confirm(r.academy_id, r.group_id)
          then 4
        else 1
      end
    );

  return jsonb_build_object(
    'attendance_id', p_attendance_id,
    'homework_count', v_homework_count,
    'next_session_count', v_next_count,
    'seeded_plan_count', v_seeded_count
  );
end;
$$;

revoke all on function public._homework_finalize_session_plan_departure(uuid) from public;
