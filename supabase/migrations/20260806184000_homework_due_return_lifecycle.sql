-- Keep returned homework inspectable until staff records an outcome.

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
    update public.homework_group_runtime r
    set phase = 1,
        run_start = null,
        updated_at = now(),
        version = r.version + 1
    where r.academy_id = v_candidate.academy_id
      and r.group_id = v_candidate.group_id
      and (r.phase <> 1 or r.run_start is not null);

    v_promoted_ids := array_append(v_promoted_ids, v_new_plan_id);
  end loop;

  return jsonb_build_object(
    'attendance_id', p_attendance_id,
    'promoted_plan_item_ids', to_jsonb(v_promoted_ids),
    'promoted_count', cardinality(v_promoted_ids)
  );
end;
$$;

revoke all on function public.homework_session_plan_promote_next_session(uuid)
  from public;
grant execute on function public.homework_session_plan_promote_next_session(uuid)
  to authenticated;
