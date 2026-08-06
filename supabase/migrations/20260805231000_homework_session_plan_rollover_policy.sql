-- Explicit session-plan classification and rollover lifecycle.
-- This migration is additive and preserves all existing M5/student RPC shapes.

alter table public.homework_session_plan_items
  add column if not exists rollover_policy text;

update public.homework_session_plan_items
set rollover_policy = case destination
  when 'next_session' then 'carry_paused'
  when 'in_class' then 'to_homework'
  when 'homework' then 'none'
end
where rollover_policy is null
   or rollover_policy not in ('to_homework', 'carry_paused', 'none');

alter table public.homework_session_plan_items
  alter column rollover_policy set default 'none',
  alter column rollover_policy set not null;

alter table public.homework_session_plan_items
  drop constraint if exists homework_session_plan_rollover_policy_chk;
alter table public.homework_session_plan_items
  add constraint homework_session_plan_rollover_policy_chk
  check (rollover_policy in ('to_homework', 'carry_paused', 'none'));

alter table public.homework_session_plan_items
  drop constraint if exists homework_session_plan_promoted_destination_chk;
alter table public.homework_session_plan_items
  add constraint homework_session_plan_promoted_destination_chk
  check (
    resolution <> 'promoted'
    or destination in ('next_session', 'homework')
  );

create index if not exists idx_homework_session_plan_rollover_active
  on public.homework_session_plan_items (
    academy_id,
    student_id,
    rollover_policy,
    destination,
    target_class_at
  )
  where resolution in ('pending', 'confirmed');

comment on column public.homework_session_plan_items.rollover_policy is
  'Departure behavior: to_homework, carry_paused, or none.';

create or replace function public._homework_session_plan_next_attendance_at(
  p_academy_id uuid,
  p_student_id uuid,
  p_after timestamptz
)
returns timestamptz
language sql
stable
security definer
set search_path = public
as $$
  with future_attendance as (
    select coalesce(
      ar.class_date_time,
      ar.date::timestamp at time zone 'Asia/Seoul'
    ) as class_at
    from public.attendance_records ar
    where ar.academy_id = p_academy_id
      and ar.student_id = p_student_id
      and coalesce(
        ar.class_date_time,
        ar.date::timestamp at time zone 'Asia/Seoul'
      ) > p_after
  ),
  future_template as (
    select (
      ((p_after at time zone 'Asia/Seoul')::date + days.offset_days)
        + make_time(b.start_hour, b.start_minute, 0)
    ) at time zone 'Asia/Seoul' as class_at
    from generate_series(0, 13) as days(offset_days)
    join public.student_time_blocks b
      on b.academy_id = p_academy_id
     and b.student_id = p_student_id
     and b.day_index = extract(
       isodow from (
         (p_after at time zone 'Asia/Seoul')::date + days.offset_days
       )
     )::integer - 1
     and b.start_date <= (
       (p_after at time zone 'Asia/Seoul')::date + days.offset_days
     )
     and (
       b.end_date is null
       or b.end_date >= (
         (p_after at time zone 'Asia/Seoul')::date + days.offset_days
       )
     )
    where (
      (
        ((p_after at time zone 'Asia/Seoul')::date + days.offset_days)
          + make_time(b.start_hour, b.start_minute, 0)
      ) at time zone 'Asia/Seoul'
    ) > p_after
  )
  select candidates.class_at
  from (
    select class_at from future_attendance
    union all
    select class_at from future_template
  ) candidates
  order by candidates.class_at
  limit 1;
$$;

revoke all on function public._homework_session_plan_next_attendance_at(
  uuid, uuid, timestamptz
) from public;

create or replace function public.homework_set_session_plan_classification_v2(
  p_source_attendance_id uuid,
  p_student_id uuid,
  p_group_id uuid,
  p_homework_item_ids uuid[],
  p_kind text,
  p_item_kind_overrides jsonb default '{}'::jsonb,
  p_target_class_at timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_attendance public.attendance_records%rowtype;
  v_group public.homework_groups%rowtype;
  v_item_id uuid;
  v_kind text;
  v_base_kind text;
  v_new_group_id uuid;
  v_target timestamptz;
  v_assignment_id uuid;
  v_created_assignments integer := 0;
  v_groups jsonb := '{}'::jsonb;
begin
  select ar.*
  into v_attendance
  from public.attendance_records ar
  where ar.id = p_source_attendance_id
    and ar.student_id = p_student_id
  for update;

  if v_attendance.id is null then
    raise exception 'HOMEWORK_SESSION_PLAN_ATTENDANCE_NOT_FOUND';
  end if;

  if not exists (
    select 1
    from public.memberships m
    where m.academy_id = v_attendance.academy_id
      and m.user_id = auth.uid()
  ) then
    raise exception 'HOMEWORK_SESSION_PLAN_FORBIDDEN';
  end if;

  if p_kind not in ('today', 'homework', 'next') then
    raise exception 'HOMEWORK_SESSION_PLAN_KIND_INVALID';
  end if;

  if p_item_kind_overrides is null
     or jsonb_typeof(p_item_kind_overrides) <> 'object' then
    raise exception 'HOMEWORK_SESSION_PLAN_OVERRIDES_INVALID';
  end if;

  if cardinality(coalesce(p_homework_item_ids, array[]::uuid[])) = 0 then
    raise exception 'HOMEWORK_SESSION_PLAN_ITEMS_REQUIRED';
  end if;

  select g.*
  into v_group
  from public.homework_groups g
  where g.id = p_group_id
    and g.academy_id = v_attendance.academy_id
    and g.student_id = p_student_id
    and g.status = 'active'
  for update;

  if v_group.id is null then
    raise exception 'HOMEWORK_SESSION_PLAN_GROUP_NOT_FOUND';
  end if;

  if exists (
    select 1
    from unnest(p_homework_item_ids) requested(item_id)
    where not exists (
      select 1
      from public.homework_group_items gi
      where gi.academy_id = v_attendance.academy_id
        and gi.student_id = p_student_id
        and gi.homework_item_id = requested.item_id
        and (
          gi.group_id = p_group_id
          or exists (
            select 1
            from public.homework_session_plan_items prior
            where prior.source_attendance_id = p_source_attendance_id
              and prior.homework_item_id = requested.item_id
              and prior.group_id = gi.group_id
          )
        )
    )
  ) then
    raise exception 'HOMEWORK_SESSION_PLAN_ITEM_NOT_IN_GROUP';
  end if;

  if exists (
    select 1
    from unnest(p_homework_item_ids) requested(item_id)
    where coalesce(
      nullif(p_item_kind_overrides->>requested.item_id::text, ''),
      p_kind
    ) not in ('today', 'homework', 'next')
  ) then
    raise exception 'HOMEWORK_SESSION_PLAN_KIND_INVALID';
  end if;

  perform pg_advisory_xact_lock(hashtext(p_group_id::text));

  v_target := coalesce(
    p_target_class_at,
    public._homework_session_plan_next_attendance_at(
      v_attendance.academy_id,
      p_student_id,
      coalesce(
        v_attendance.class_date_time,
        v_attendance.arrival_time,
        now()
      )
    )
  );

  -- Upsert every requested child before moving group membership. This keeps
  -- repeated calls deterministic even after a prior call split the group.
  for v_item_id in
    select requested.item_id
    from unnest(p_homework_item_ids) requested(item_id)
  loop
    v_kind := coalesce(
      nullif(p_item_kind_overrides->>v_item_id::text, ''),
      p_kind
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
      v_attendance.academy_id,
      p_student_id,
      p_source_attendance_id,
      case when v_kind = 'homework' then v_target else p_target_class_at end,
      case
        when v_kind = 'homework' then 'direct_homework'
        else 'planned_today'
      end::public.homework_session_plan_origin,
      case
        when v_kind = 'homework' then 'homework'
        else 'in_class'
      end::public.homework_session_plan_destination,
      case
        when v_kind = 'homework' then 'confirmed'
        else 'pending'
      end::public.homework_session_plan_resolution,
      case
        when v_kind = 'today' then 'to_homework'
        when v_kind = 'next' then 'carry_paused'
        else 'none'
      end,
      coalesce(h.recommended_minutes, h.recommended_minutes_auto),
      gi.group_id,
      h.id,
      gi.item_order_index
    from public.homework_items h
    join public.homework_group_items gi
      on gi.academy_id = h.academy_id
     and gi.homework_item_id = h.id
    where h.id = v_item_id
      and h.academy_id = v_attendance.academy_id
      and h.student_id = p_student_id
    on conflict (source_attendance_id, homework_item_id)
      where source_attendance_id is not null
    do update set
      target_class_at = excluded.target_class_at,
      origin = excluded.origin,
      destination = excluded.destination,
      resolution = excluded.resolution,
      rollover_policy = excluded.rollover_policy,
      recommended_minutes_snapshot = coalesce(
        homework_session_plan_items.recommended_minutes_snapshot,
        excluded.recommended_minutes_snapshot
      ),
      group_id = excluded.group_id,
      order_index = excluded.order_index,
      updated_at = now(),
      version = homework_session_plan_items.version + 1
    where homework_session_plan_items.target_class_at
            is distinct from excluded.target_class_at
       or homework_session_plan_items.origin is distinct from excluded.origin
       or homework_session_plan_items.destination
            is distinct from excluded.destination
       or homework_session_plan_items.resolution
            is distinct from excluded.resolution
       or homework_session_plan_items.rollover_policy
            is distinct from excluded.rollover_policy
       or homework_session_plan_items.group_id is distinct from excluded.group_id
       or homework_session_plan_items.order_index
            is distinct from excluded.order_index;
  end loop;

  -- Reclassification away from homework must release any active assignment;
  -- otherwise the unchanged M5 query would continue excluding the item.
  update public.homework_assignments a
  set status = 'classification_changed',
      updated_at = now(),
      version = a.version + 1
  where a.academy_id = v_attendance.academy_id
    and a.student_id = p_student_id
    and a.homework_item_id in (
      select requested.item_id
      from unnest(p_homework_item_ids) requested(item_id)
      where coalesce(
        nullif(p_item_kind_overrides->>requested.item_id::text, ''),
        p_kind
      ) <> 'homework'
    )
    and a.status in ('assigned', 'in_progress');

  update public.homework_items h
  set status = 0,
      updated_at = now(),
      version = h.version + 1
  where h.academy_id = v_attendance.academy_id
    and h.student_id = p_student_id
    and h.id in (
      select requested.item_id
      from unnest(p_homework_item_ids) requested(item_id)
      where coalesce(
        nullif(p_item_kind_overrides->>requested.item_id::text, ''),
        p_kind
      ) <> 'homework'
    )
    and coalesce(h.status, 0) = 2;

  update public.homework_session_plan_items spi
  set assignment_id = null,
      updated_at = now(),
      version = spi.version + 1
  where spi.source_attendance_id = p_source_attendance_id
    and spi.homework_item_id in (
      select requested.item_id
      from unnest(p_homework_item_ids) requested(item_id)
      where coalesce(
        nullif(p_item_kind_overrides->>requested.item_id::text, ''),
        p_kind
      ) <> 'homework'
    )
    and spi.assignment_id is not null;

  select effective.kind
  into v_base_kind
  from (
    select distinct coalesce(
      nullif(p_item_kind_overrides->>requested.item_id::text, ''),
      p_kind
    ) as kind
    from unnest(p_homework_item_ids) requested(item_id)
  ) effective
  order by case effective.kind
    when 'today' then 0
    when 'homework' then 1
    else 2
  end
  limit 1;

  v_groups := jsonb_set(v_groups, array[v_base_kind], to_jsonb(p_group_id), true);

  -- today and next both begin in_class, so split by UI kind/rollover rather
  -- than destination alone.
  for v_kind in
    select effective.kind
    from (
      select distinct coalesce(
        nullif(p_item_kind_overrides->>requested.item_id::text, ''),
        p_kind
      ) as kind
      from unnest(p_homework_item_ids) requested(item_id)
    ) effective
    where effective.kind <> v_base_kind
    order by case effective.kind
      when 'today' then 0
      when 'homework' then 1
      else 2
    end
  loop
    select spi.group_id
    into v_new_group_id
    from public.homework_session_plan_items spi
    where spi.source_attendance_id = p_source_attendance_id
      and spi.homework_item_id = any(p_homework_item_ids)
      and spi.group_id <> p_group_id
      and (
        (v_kind = 'today' and spi.rollover_policy = 'to_homework')
        or (v_kind = 'next' and spi.rollover_policy = 'carry_paused')
        or (v_kind = 'homework' and spi.destination = 'homework')
      )
    order by spi.created_at, spi.id
    limit 1;

    if v_new_group_id is null then
      insert into public.homework_groups (
        academy_id,
        student_id,
        title,
        flow_id,
        learning_track_code,
        cycle_started_at,
        order_index,
        status
      )
      values (
        v_group.academy_id,
        v_group.student_id,
        v_group.title,
        v_group.flow_id,
        v_group.learning_track_code,
        v_group.cycle_started_at,
        v_group.order_index
          + case v_kind when 'homework' then 1 when 'next' then 2 else 0 end,
        'active'
      )
      returning id into v_new_group_id;
    end if;

    update public.homework_group_items gi
    set group_id = v_new_group_id,
        updated_at = now(),
        version = gi.version + 1
    where gi.academy_id = v_attendance.academy_id
      and gi.student_id = p_student_id
      and gi.homework_item_id = any(p_homework_item_ids)
      and coalesce(
        nullif(p_item_kind_overrides->>gi.homework_item_id::text, ''),
        p_kind
      ) = v_kind
      and gi.group_id is distinct from v_new_group_id;

    update public.homework_session_plan_items spi
    set group_id = v_new_group_id,
        updated_at = now(),
        version = spi.version + 1
    where spi.source_attendance_id = p_source_attendance_id
      and spi.homework_item_id = any(p_homework_item_ids)
      and coalesce(
        nullif(p_item_kind_overrides->>spi.homework_item_id::text, ''),
        p_kind
      ) = v_kind
      and spi.group_id is distinct from v_new_group_id;

    perform public.m5_group_runtime_seed(
      v_attendance.academy_id,
      v_new_group_id
    );
    v_groups := jsonb_set(
      v_groups,
      array[v_kind],
      to_jsonb(v_new_group_id),
      true
    );
    v_new_group_id := null;
  end loop;

  -- Correct base rows after a repeated call whose requested children were
  -- previously split, then normalize each affected group's child order.
  update public.homework_session_plan_items spi
  set group_id = gi.group_id,
      updated_at = now(),
      version = spi.version + 1
  from public.homework_group_items gi
  where spi.source_attendance_id = p_source_attendance_id
    and spi.homework_item_id = any(p_homework_item_ids)
    and gi.academy_id = spi.academy_id
    and gi.homework_item_id = spi.homework_item_id
    and spi.group_id is distinct from gi.group_id;

  with affected_groups as (
    select distinct gi.group_id
    from public.homework_group_items gi
    where gi.academy_id = v_attendance.academy_id
      and gi.homework_item_id = any(p_homework_item_ids)
  ),
  ranked as (
    select
      gi.id,
      row_number() over (
        partition by gi.group_id
        order by gi.item_order_index, gi.created_at, gi.id
      ) - 1 as new_order
    from public.homework_group_items gi
    where gi.academy_id = v_attendance.academy_id
      and gi.group_id in (select group_id from affected_groups)
  )
  update public.homework_group_items gi
  set item_order_index = ranked.new_order,
      updated_at = now(),
      version = gi.version + 1
  from ranked
  where gi.id = ranked.id
    and gi.item_order_index is distinct from ranked.new_order;

  -- Direct homework is immediately assigned and paused.
  for v_item_id in
    select requested.item_id
    from unnest(p_homework_item_ids) requested(item_id)
    where coalesce(
      nullif(p_item_kind_overrides->>requested.item_id::text, ''),
      p_kind
    ) = 'homework'
  loop
    select a.id
    into v_assignment_id
    from public.homework_assignments a
    where a.academy_id = v_attendance.academy_id
      and a.student_id = p_student_id
      and a.homework_item_id = v_item_id
      and a.status in ('assigned', 'in_progress')
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
        v_attendance.academy_id,
        p_student_id,
        v_item_id,
        now(),
        case
          when v_target is null then null
          else (v_target at time zone 'Asia/Seoul')::date
        end,
        spi.order_index,
        'assigned',
        '__session_plan_direct__',
        spi.group_id,
        coalesce(g.title, h.title, '그룹 과제'),
        h.learning_track_code
      from public.homework_session_plan_items spi
      join public.homework_items h on h.id = spi.homework_item_id
      left join public.homework_groups g on g.id = spi.group_id
      where spi.source_attendance_id = p_source_attendance_id
        and spi.homework_item_id = v_item_id
      returning id into v_assignment_id;
      v_created_assignments := v_created_assignments + 1;
    else
      update public.homework_assignments a
      set due_date = case
            when v_target is null then null
            else (v_target at time zone 'Asia/Seoul')::date
          end,
          updated_at = now(),
          version = a.version + 1
      where a.id = v_assignment_id
        and a.due_date is distinct from case
          when v_target is null then null
          else (v_target at time zone 'Asia/Seoul')::date
        end;
    end if;

    update public.homework_session_plan_items spi
    set assignment_id = v_assignment_id,
        resolution = 'confirmed',
        updated_at = now(),
        version = spi.version + 1
    where spi.source_attendance_id = p_source_attendance_id
      and spi.homework_item_id = v_item_id
      and (
        spi.assignment_id is distinct from v_assignment_id
        or spi.resolution <> 'confirmed'
      );

    update public.homework_items h
    set status = 2,
        phase = 1,
        run_start = null,
        waiting_at = coalesce(h.waiting_at, now()),
        updated_at = now(),
        version = h.version + 1
    where h.id = v_item_id
      and h.academy_id = v_attendance.academy_id
      and (
        coalesce(h.status, 0) <> 2
        or coalesce(h.phase, 1) <> 1
        or h.run_start is not null
      );
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
      where spi.source_attendance_id = p_source_attendance_id
        and spi.homework_item_id = any(p_homework_item_ids)
        and spi.destination = 'homework'
    )
    and (r.phase <> 1 or r.run_start is not null);

  return jsonb_build_object(
    'attendance_id', p_source_attendance_id,
    'groups', v_groups,
    'created_assignments', v_created_assignments,
    'target_class_at', v_target
  );
end;
$$;

revoke all on function public.homework_set_session_plan_classification_v2(
  uuid, uuid, uuid, uuid[], text, jsonb, timestamptz
) from public;
grant execute on function public.homework_set_session_plan_classification_v2(
  uuid, uuid, uuid, uuid[], text, jsonb, timestamptz
) to authenticated;

create or replace function public.homework_finalize_session_plan_departure(
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
begin
  select ar.*
  into v_attendance
  from public.attendance_records ar
  where ar.id = p_attendance_id
  for update;

  if v_attendance.id is null then
    raise exception 'HOMEWORK_SESSION_PLAN_ATTENDANCE_NOT_FOUND';
  end if;

  if not exists (
    select 1
    from public.memberships m
    where m.academy_id = v_attendance.academy_id
      and m.user_id = auth.uid()
  ) then
    raise exception 'HOMEWORK_SESSION_PLAN_FORBIDDEN';
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
        and a.status in ('assigned', 'in_progress')
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
    'next_session_count', v_next_count
  );
end;
$$;

revoke all on function public.homework_finalize_session_plan_departure(uuid)
  from public;
grant execute on function public.homework_finalize_session_plan_departure(uuid)
  to authenticated;

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
    if v_candidate.destination = 'homework'
       and v_candidate.assignment_id is not null then
      update public.homework_assignments a
      set status = 'carried_to_class',
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
      v_effective_class_at,
      'carried_from_previous',
      'in_class',
      'pending',
      case
        when v_candidate.destination = 'homework' then 'to_homework'
        else 'carry_paused'
      end,
      v_candidate.recommended_minutes_snapshot,
      v_candidate.group_id,
      v_candidate.homework_item_id,
      null,
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
      assignment_id = null,
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

create or replace function public.homework_update_session_plan_due_date(
  p_plan_item_id uuid,
  p_due_date date
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_plan public.homework_session_plan_items%rowtype;
  v_target timestamptz;
begin
  select spi.*
  into v_plan
  from public.homework_session_plan_items spi
  where spi.id = p_plan_item_id
  for update;

  if v_plan.id is null then
    raise exception 'HOMEWORK_SESSION_PLAN_ITEM_NOT_FOUND';
  end if;

  if not exists (
    select 1
    from public.memberships m
    where m.academy_id = v_plan.academy_id
      and m.user_id = auth.uid()
  ) then
    raise exception 'HOMEWORK_SESSION_PLAN_FORBIDDEN';
  end if;

  if p_due_date is not null then
    select coalesce(
      ar.class_date_time,
      ar.date::timestamp at time zone 'Asia/Seoul'
    )
    into v_target
    from public.attendance_records ar
    where ar.academy_id = v_plan.academy_id
      and ar.student_id = v_plan.student_id
      and coalesce(
        ar.date,
        (ar.class_date_time at time zone 'Asia/Seoul')::date
      ) = p_due_date
    order by ar.class_date_time nulls last, ar.id
    limit 1;

    v_target := coalesce(
      v_target,
      p_due_date::timestamp at time zone 'Asia/Seoul'
    );
  end if;

  update public.homework_session_plan_items spi
  set target_class_at = v_target,
      updated_at = now(),
      version = spi.version + 1
  where spi.id = p_plan_item_id
    and spi.target_class_at is distinct from v_target;

  update public.homework_assignments a
  set due_date = p_due_date,
      updated_at = now(),
      version = a.version + 1
  where a.id = v_plan.assignment_id
    and a.status in ('assigned', 'in_progress')
    and a.due_date is distinct from p_due_date;

  return jsonb_build_object(
    'plan_item_id', p_plan_item_id,
    'target_class_at', v_target,
    'due_date', p_due_date,
    'assignment_id', v_plan.assignment_id
  );
end;
$$;

revoke all on function public.homework_update_session_plan_due_date(uuid, date)
  from public;
grant execute on function public.homework_update_session_plan_due_date(uuid, date)
  to authenticated;

create or replace function public.homework_update_session_plan_due_date(
  p_source_attendance_id uuid,
  p_homework_item_ids uuid[],
  p_due_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_attendance public.attendance_records%rowtype;
  v_updated_count integer := 0;
begin
  select ar.*
  into v_attendance
  from public.attendance_records ar
  where ar.id = p_source_attendance_id;

  if v_attendance.id is null then
    raise exception 'HOMEWORK_SESSION_PLAN_ATTENDANCE_NOT_FOUND';
  end if;

  if not exists (
    select 1
    from public.memberships m
    where m.academy_id = v_attendance.academy_id
      and m.user_id = auth.uid()
  ) then
    raise exception 'HOMEWORK_SESSION_PLAN_FORBIDDEN';
  end if;

  if p_due_at is null
     or cardinality(coalesce(p_homework_item_ids, array[]::uuid[])) = 0 then
    raise exception 'HOMEWORK_SESSION_PLAN_DUE_DATE_REQUIRED';
  end if;

  with updated_plans as (
    update public.homework_session_plan_items spi
    set target_class_at = p_due_at,
        updated_at = now(),
        version = spi.version + 1
    where spi.academy_id = v_attendance.academy_id
      and spi.student_id = v_attendance.student_id
      and spi.homework_item_id = any(p_homework_item_ids)
      and spi.destination = 'homework'
      and spi.resolution in ('pending', 'confirmed')
      and spi.target_class_at is distinct from p_due_at
    returning spi.assignment_id
  )
  select count(*)::integer
  into v_updated_count
  from updated_plans;

  update public.homework_assignments a
  set due_date = (p_due_at at time zone 'Asia/Seoul')::date,
      updated_at = now(),
      version = a.version + 1
  where a.academy_id = v_attendance.academy_id
    and a.student_id = v_attendance.student_id
    and a.homework_item_id = any(p_homework_item_ids)
    and a.status in ('assigned', 'in_progress')
    and a.due_date is distinct from
      (p_due_at at time zone 'Asia/Seoul')::date;

  return jsonb_build_object(
    'attendance_id', p_source_attendance_id,
    'updated_count', v_updated_count,
    'due_at', p_due_at
  );
end;
$$;

revoke all on function public.homework_update_session_plan_due_date(
  uuid, uuid[], timestamptz
) from public;
grant execute on function public.homework_update_session_plan_due_date(
  uuid, uuid[], timestamptz
) to authenticated;
