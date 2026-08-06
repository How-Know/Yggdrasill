-- Session-scoped homework planning.
--
-- Unclassified legacy homework deliberately remains visible. Only rows explicitly
-- deferred to next_session are hidden from active M5/student lists.

do $$
begin
  create type public.homework_session_plan_origin as enum (
    'planned_today',
    'direct_homework',
    'carried_from_previous'
  );
exception
  when duplicate_object then null;
end
$$;

do $$
begin
  create type public.homework_session_plan_destination as enum (
    'in_class',
    'homework',
    'next_session'
  );
exception
  when duplicate_object then null;
end
$$;

do $$
begin
  create type public.homework_session_plan_resolution as enum (
    'pending',
    'confirmed',
    'promoted',
    'completed',
    'cancelled'
  );
exception
  when duplicate_object then null;
end
$$;

create table if not exists public.homework_session_plan_items (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  source_attendance_id uuid references public.attendance_records(id) on delete set null,
  target_class_at timestamptz,
  origin public.homework_session_plan_origin not null default 'planned_today',
  destination public.homework_session_plan_destination not null default 'in_class',
  resolution public.homework_session_plan_resolution not null default 'pending',
  recommended_minutes_snapshot integer,
  group_id uuid references public.homework_groups(id) on delete set null,
  homework_item_id uuid not null references public.homework_items(id) on delete cascade,
  assignment_id uuid references public.homework_assignments(id) on delete set null,
  carried_from_plan_item_id uuid
    references public.homework_session_plan_items(id) on delete set null,
  order_index integer not null default 0,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  constraint homework_session_plan_recommended_minutes_chk
    check (
      recommended_minutes_snapshot is null
      or recommended_minutes_snapshot >= 0
    ),
  constraint homework_session_plan_version_chk check (version >= 1),
  constraint homework_session_plan_not_self_carried_chk
    check (
      carried_from_plan_item_id is null
      or carried_from_plan_item_id <> id
    ),
  constraint homework_session_plan_promoted_destination_chk
    check (
      resolution <> 'promoted'
      or destination = 'next_session'
    )
);

create unique index if not exists
  uidx_homework_session_plan_source_item
  on public.homework_session_plan_items(source_attendance_id, homework_item_id)
  where source_attendance_id is not null;

create index if not exists idx_homework_session_plan_student_active
  on public.homework_session_plan_items(
    academy_id,
    student_id,
    destination,
    resolution,
    target_class_at
  )
  where resolution in ('pending', 'confirmed');

create index if not exists idx_homework_session_plan_group_order
  on public.homework_session_plan_items(
    academy_id,
    group_id,
    order_index
  );

create index if not exists idx_homework_session_plan_item
  on public.homework_session_plan_items(
    academy_id,
    homework_item_id,
    created_at desc
  );

alter table public.homework_session_plan_items enable row level security;

drop policy if exists homework_session_plan_items_all
  on public.homework_session_plan_items;
create policy homework_session_plan_items_all
  on public.homework_session_plan_items
  for all
  using (
    exists (
      select 1
      from public.memberships m
      where m.academy_id = homework_session_plan_items.academy_id
        and m.user_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1
      from public.memberships m
      where m.academy_id = homework_session_plan_items.academy_id
        and m.user_id = auth.uid()
    )
  );

drop trigger if exists trg_homework_session_plan_items_audit
  on public.homework_session_plan_items;
create trigger trg_homework_session_plan_items_audit
before insert or update on public.homework_session_plan_items
for each row execute function public._set_audit_fields();

create or replace function public._homework_session_plan_resolve_completed_item()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (
    new.completed_at is not null
    or coalesce(new.status, 0) = 1
    or coalesce(new.phase, 1) = 0
  ) and (
    old.completed_at is distinct from new.completed_at
    or old.status is distinct from new.status
    or old.phase is distinct from new.phase
  ) then
    update public.homework_session_plan_items spi
    set resolution = 'completed',
        updated_at = now(),
        version = spi.version + 1
    where spi.academy_id = new.academy_id
      and spi.student_id = new.student_id
      and spi.homework_item_id = new.id
      and spi.resolution in ('pending', 'confirmed');
  end if;
  return new;
end;
$$;

drop trigger if exists trg_homework_session_plan_resolve_completed_item
  on public.homework_items;
create trigger trg_homework_session_plan_resolve_completed_item
after update of completed_at, status, phase
on public.homework_items
for each row
execute function public._homework_session_plan_resolve_completed_item();

comment on table public.homework_session_plan_items is
  'Per-attendance destination decisions for homework items; legacy items without a row use list fallback.';
comment on column public.homework_session_plan_items.recommended_minutes_snapshot is
  'Effective recommended minutes captured when the session plan row is created or changed.';

create or replace function public.homework_session_plan_item_is_visible(
  p_academy_id uuid,
  p_student_id uuid,
  p_homework_item_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select not exists (
    select 1
    from public.homework_session_plan_items spi
    where spi.academy_id = p_academy_id
      and spi.student_id = p_student_id
      and spi.homework_item_id = p_homework_item_id
      and spi.destination = 'next_session'
      and spi.resolution in ('pending', 'confirmed')
  );
$$;

revoke all on function public.homework_session_plan_item_is_visible(uuid, uuid, uuid)
  from public;
grant execute on function public.homework_session_plan_item_is_visible(uuid, uuid, uuid)
  to anon, authenticated;

create or replace function public.homework_session_plan_set_destination(
  p_academy_id uuid,
  p_source_attendance_id uuid,
  p_homework_item_id uuid,
  p_destination public.homework_session_plan_destination,
  p_origin public.homework_session_plan_origin default 'planned_today',
  p_target_class_at timestamptz default null,
  p_order_index integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_attendance public.attendance_records%rowtype;
  v_item public.homework_items%rowtype;
  v_group_id uuid;
  v_plan public.homework_session_plan_items%rowtype;
begin
  if not exists (
    select 1
    from public.memberships m
    where m.academy_id = p_academy_id
      and m.user_id = auth.uid()
  ) then
    raise exception 'HOMEWORK_SESSION_PLAN_FORBIDDEN';
  end if;

  select ar.*
  into v_attendance
  from public.attendance_records ar
  where ar.id = p_source_attendance_id
    and ar.academy_id = p_academy_id
  for update;

  if v_attendance.id is null then
    raise exception 'HOMEWORK_SESSION_PLAN_ATTENDANCE_NOT_FOUND';
  end if;

  select h.*
  into v_item
  from public.homework_items h
  where h.id = p_homework_item_id
    and h.academy_id = p_academy_id
    and h.student_id = v_attendance.student_id;

  if v_item.id is null then
    raise exception 'HOMEWORK_SESSION_PLAN_ITEM_NOT_FOUND';
  end if;

  select gi.group_id
  into v_group_id
  from public.homework_group_items gi
  where gi.academy_id = p_academy_id
    and gi.student_id = v_attendance.student_id
    and gi.homework_item_id = p_homework_item_id
  limit 1;

  insert into public.homework_session_plan_items (
    academy_id,
    student_id,
    source_attendance_id,
    target_class_at,
    origin,
    destination,
    resolution,
    recommended_minutes_snapshot,
    group_id,
    homework_item_id,
    order_index
  )
  values (
    p_academy_id,
    v_attendance.student_id,
    p_source_attendance_id,
    p_target_class_at,
    p_origin,
    p_destination,
    'pending',
    coalesce(v_item.recommended_minutes, v_item.recommended_minutes_auto),
    v_group_id,
    p_homework_item_id,
    coalesce(p_order_index, v_item.order_index, 0)
  )
  on conflict (source_attendance_id, homework_item_id)
    where source_attendance_id is not null
  do update set
    target_class_at = excluded.target_class_at,
    origin = excluded.origin,
    destination = excluded.destination,
    resolution = case
      when homework_session_plan_items.destination = excluded.destination
        then homework_session_plan_items.resolution
      else 'pending'::public.homework_session_plan_resolution
    end,
    recommended_minutes_snapshot =
      coalesce(
        homework_session_plan_items.recommended_minutes_snapshot,
        excluded.recommended_minutes_snapshot
      ),
    group_id = excluded.group_id,
    order_index = excluded.order_index,
    updated_at = now(),
    version = homework_session_plan_items.version + 1
  where homework_session_plan_items.target_class_at
          is distinct from excluded.target_class_at
     or homework_session_plan_items.origin
          is distinct from excluded.origin
     or homework_session_plan_items.destination
          is distinct from excluded.destination
     or homework_session_plan_items.group_id
          is distinct from excluded.group_id
     or homework_session_plan_items.order_index
          is distinct from excluded.order_index
     or (
       homework_session_plan_items.recommended_minutes_snapshot is null
       and excluded.recommended_minutes_snapshot is not null
     )
  returning * into v_plan;

  if v_plan.id is null then
    select spi.*
    into v_plan
    from public.homework_session_plan_items spi
    where spi.source_attendance_id = p_source_attendance_id
      and spi.homework_item_id = p_homework_item_id;
  end if;

  return to_jsonb(v_plan);
end;
$$;

revoke all on function public.homework_session_plan_set_destination(
  uuid,
  uuid,
  uuid,
  public.homework_session_plan_destination,
  public.homework_session_plan_origin,
  timestamptz,
  integer
) from public;
grant execute on function public.homework_session_plan_set_destination(
  uuid,
  uuid,
  uuid,
  public.homework_session_plan_destination,
  public.homework_session_plan_origin,
  timestamptz,
  integer
) to authenticated;

create or replace function public.homework_session_plan_split_group_by_destination(
  p_academy_id uuid,
  p_source_attendance_id uuid,
  p_group_id uuid,
  p_item_destinations jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group public.homework_groups%rowtype;
  v_attendance public.attendance_records%rowtype;
  v_entry jsonb;
  v_destination public.homework_session_plan_destination;
  v_item_id uuid;
  v_item_order integer;
  v_base_destination public.homework_session_plan_destination;
  v_new_group_id uuid;
  v_groups jsonb := '{}'::jsonb;
begin
  if jsonb_typeof(p_item_destinations) <> 'array'
     or jsonb_array_length(p_item_destinations) = 0 then
    raise exception 'HOMEWORK_SESSION_PLAN_DESTINATIONS_REQUIRED';
  end if;

  if not exists (
    select 1
    from public.memberships m
    where m.academy_id = p_academy_id
      and m.user_id = auth.uid()
  ) then
    raise exception 'HOMEWORK_SESSION_PLAN_FORBIDDEN';
  end if;

  select ar.*
  into v_attendance
  from public.attendance_records ar
  where ar.id = p_source_attendance_id
    and ar.academy_id = p_academy_id
  for update;

  select g.*
  into v_group
  from public.homework_groups g
  where g.id = p_group_id
    and g.academy_id = p_academy_id
    and g.student_id = v_attendance.student_id
    and g.status = 'active'
  for update;

  if v_attendance.id is null or v_group.id is null then
    raise exception 'HOMEWORK_SESSION_PLAN_GROUP_OR_ATTENDANCE_NOT_FOUND';
  end if;

  perform pg_advisory_xact_lock(hashtext(p_group_id::text));

  for v_entry in
    select value from jsonb_array_elements(p_item_destinations)
  loop
    begin
      v_item_id := (v_entry->>'homework_item_id')::uuid;
      v_destination :=
        (v_entry->>'destination')::public.homework_session_plan_destination;
    exception
      when others then
        raise exception 'HOMEWORK_SESSION_PLAN_DESTINATION_ENTRY_INVALID';
    end;

    if not exists (
      select 1
      from public.homework_group_items gi
      where gi.academy_id = p_academy_id
        and gi.student_id = v_group.student_id
        and gi.homework_item_id = v_item_id
        and (
          gi.group_id = p_group_id
          or exists (
            select 1
            from public.homework_session_plan_items prior
            where prior.source_attendance_id = p_source_attendance_id
              and prior.homework_item_id = v_item_id
              and prior.group_id = gi.group_id
          )
        )
    ) then
      raise exception 'HOMEWORK_SESSION_PLAN_ITEM_NOT_IN_GROUP';
    end if;

    perform public.homework_session_plan_set_destination(
      p_academy_id,
      p_source_attendance_id,
      v_item_id,
      v_destination,
      coalesce(
        nullif(v_entry->>'origin', '')::public.homework_session_plan_origin,
        'planned_today'::public.homework_session_plan_origin
      ),
      nullif(v_entry->>'target_class_at', '')::timestamptz,
      null
    );
  end loop;

  select spi.destination
  into v_base_destination
  from public.homework_session_plan_items spi
  join public.homework_group_items gi
    on gi.homework_item_id = spi.homework_item_id
   and gi.group_id = p_group_id
  where spi.source_attendance_id = p_source_attendance_id
  order by
    case spi.destination
      when 'in_class' then 0
      when 'homework' then 1
      else 2
    end,
    spi.order_index,
    spi.id
  limit 1;

  if v_base_destination is null then
    return jsonb_build_object('base_group_id', p_group_id, 'groups', v_groups);
  end if;

  v_groups := jsonb_set(
    v_groups,
    array[v_base_destination::text],
    to_jsonb(p_group_id),
    true
  );

  for v_destination in
    select distinct spi.destination
    from public.homework_session_plan_items spi
    where spi.source_attendance_id = p_source_attendance_id
      and spi.homework_item_id in (
        select (x->>'homework_item_id')::uuid
        from jsonb_array_elements(p_item_destinations) x
      )
      and spi.destination <> v_base_destination
    order by 1
  loop
    select gi.group_id
    into v_new_group_id
    from public.homework_group_items gi
    join public.homework_session_plan_items spi
      on spi.homework_item_id = gi.homework_item_id
     and spi.source_attendance_id = p_source_attendance_id
    where gi.academy_id = p_academy_id
      and gi.student_id = v_group.student_id
      and spi.destination = v_destination
      and gi.group_id <> p_group_id
    order by gi.created_at, gi.id
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
          + case v_destination
              when 'homework' then 1
              when 'next_session' then 2
              else 0
            end,
        'active'
      )
      returning id into v_new_group_id;
    end if;

    update public.homework_group_items gi
    set group_id = v_new_group_id,
        updated_at = now(),
        version = gi.version + 1
    where gi.academy_id = p_academy_id
      and gi.student_id = v_group.student_id
      and gi.group_id is distinct from v_new_group_id
      and gi.homework_item_id in (
        select spi.homework_item_id
        from public.homework_session_plan_items spi
        where spi.source_attendance_id = p_source_attendance_id
          and spi.destination = v_destination
          and spi.homework_item_id in (
            select (x->>'homework_item_id')::uuid
            from jsonb_array_elements(p_item_destinations) x
          )
      );

    update public.homework_session_plan_items spi
    set group_id = v_new_group_id,
        updated_at = now(),
        version = spi.version + 1
    where spi.source_attendance_id = p_source_attendance_id
      and spi.destination = v_destination
      and spi.group_id is distinct from v_new_group_id
      and spi.homework_item_id in (
        select (x->>'homework_item_id')::uuid
        from jsonb_array_elements(p_item_destinations) x
      );

    -- Each split destination gets its own runtime row. The base group keeps its
    -- current runtime so an in-flight class timer is not interrupted.
    perform public.m5_group_runtime_seed(p_academy_id, v_new_group_id);

    v_groups := jsonb_set(
      v_groups,
      array[v_destination::text],
      to_jsonb(v_new_group_id),
      true
    );
    v_new_group_id := null;
  end loop;

  with ranked as (
    select
      gi.id,
      row_number() over (
        partition by gi.group_id
        order by gi.item_order_index, gi.created_at, gi.id
      ) - 1 as new_order
    from public.homework_group_items gi
    where gi.academy_id = p_academy_id
      and gi.student_id = v_group.student_id
      and gi.group_id in (
        select (value #>> '{}')::uuid
        from jsonb_each(v_groups)
      )
  )
  update public.homework_group_items gi
  set item_order_index = ranked.new_order,
      updated_at = now(),
      version = gi.version + 1
  from ranked
  where gi.id = ranked.id
    and gi.item_order_index is distinct from ranked.new_order;

  return jsonb_build_object('base_group_id', p_group_id, 'groups', v_groups);
end;
$$;

revoke all on function public.homework_session_plan_split_group_by_destination(
  uuid,
  uuid,
  uuid,
  jsonb
) from public;
grant execute on function public.homework_session_plan_split_group_by_destination(
  uuid,
  uuid,
  uuid,
  jsonb
) to authenticated;

create or replace function public.homework_session_plan_confirm_departure(
  p_academy_id uuid,
  p_attendance_id uuid,
  p_group_ids uuid[],
  p_homework_item_ids uuid[]
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_attendance public.attendance_records%rowtype;
  v_group_ids uuid[];
  v_plan public.homework_session_plan_items%rowtype;
  v_assignment_id uuid;
  v_assignment_count integer := 0;
  v_plan_count integer := 0;
  v_due_date date;
  v_due_text text;
begin
  if not exists (
    select 1
    from public.memberships m
    where m.academy_id = p_academy_id
      and m.user_id = auth.uid()
  ) then
    raise exception 'HOMEWORK_SESSION_PLAN_FORBIDDEN';
  end if;

  select ar.*
  into v_attendance
  from public.attendance_records ar
  where ar.id = p_attendance_id
    and ar.academy_id = p_academy_id
  for update;

  if v_attendance.id is null then
    raise exception 'HOMEWORK_SESSION_PLAN_ATTENDANCE_NOT_FOUND';
  end if;

  perform pg_advisory_xact_lock(hashtext(p_attendance_id::text));
  v_group_ids := coalesce(p_group_ids, v_attendance.homework_draft_group_ids);

  if v_group_ids is null then
    v_group_ids := array[]::uuid[];
  end if;

  -- Legacy fallback: classify selected draft groups lazily, without a bulk backfill.
  insert into public.homework_session_plan_items (
    academy_id,
    student_id,
    source_attendance_id,
    origin,
    destination,
    resolution,
    recommended_minutes_snapshot,
    group_id,
    homework_item_id,
    order_index
  )
  select
    p_academy_id,
    v_attendance.student_id,
    p_attendance_id,
    'direct_homework',
    'homework',
    'pending',
    coalesce(h.recommended_minutes, h.recommended_minutes_auto),
    gi.group_id,
    gi.homework_item_id,
    gi.item_order_index
  from public.homework_group_items gi
  join public.homework_items h
    on h.id = gi.homework_item_id
   and h.academy_id = gi.academy_id
   and h.student_id = gi.student_id
  where gi.academy_id = p_academy_id
    and gi.student_id = v_attendance.student_id
    and gi.group_id = any(v_group_ids)
  on conflict (source_attendance_id, homework_item_id)
    where source_attendance_id is not null
  do update set
    destination = 'homework',
    resolution = case
      when homework_session_plan_items.destination = 'homework'
        then homework_session_plan_items.resolution
      else 'pending'::public.homework_session_plan_resolution
    end,
    group_id = excluded.group_id,
    order_index = excluded.order_index,
    recommended_minutes_snapshot = coalesce(
      homework_session_plan_items.recommended_minutes_snapshot,
      excluded.recommended_minutes_snapshot
    ),
    updated_at = now(),
    version = homework_session_plan_items.version + 1;

  for v_plan in
    select spi.*
    from public.homework_session_plan_items spi
    where spi.academy_id = p_academy_id
      and spi.student_id = v_attendance.student_id
      and spi.source_attendance_id = p_attendance_id
      and spi.destination = 'homework'
      and spi.resolution in ('pending', 'confirmed')
      and (
        cardinality(v_group_ids) = 0
        or spi.group_id = any(v_group_ids)
      )
      and (
        p_homework_item_ids is null
        or spi.homework_item_id = any(p_homework_item_ids)
      )
    order by spi.order_index, spi.id
    for update
  loop
    select a.id
    into v_assignment_id
    from public.homework_assignments a
    where a.academy_id = p_academy_id
      and a.student_id = v_attendance.student_id
      and a.homework_item_id = v_plan.homework_item_id
      and a.status = 'assigned'
    order by a.created_at desc
    limit 1;

    if v_assignment_id is null then
      v_due_text :=
        v_attendance.homework_draft_group_due_dates
          ->> v_plan.group_id::text;
      v_due_date := case
        when coalesce(v_due_text, '') ~ '^\d{4}-\d{2}-\d{2}'
          then left(v_due_text, 10)::date
        when v_plan.target_class_at is not null
          then (v_plan.target_class_at at time zone 'Asia/Seoul')::date
        else null
      end;

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
        group_title_snapshot
      )
      select
        p_academy_id,
        v_attendance.student_id,
        v_plan.homework_item_id,
        now(),
        v_due_date,
        v_plan.order_index,
        'assigned',
        '__session_plan_departure__',
        v_plan.group_id,
        coalesce(g.title, h.title, '그룹 과제')
      from public.homework_items h
      left join public.homework_groups g
        on g.id = v_plan.group_id
       and g.academy_id = p_academy_id
      where h.id = v_plan.homework_item_id
        and h.academy_id = p_academy_id
      returning id into v_assignment_id;

      v_assignment_count := v_assignment_count + 1;
    end if;

    update public.homework_session_plan_items spi
    set assignment_id = v_assignment_id,
        resolution = 'confirmed',
        updated_at = now(),
        version = spi.version + 1
    where spi.id = v_plan.id
      and (
        spi.assignment_id is distinct from v_assignment_id
        or spi.resolution <> 'confirmed'
      );

    v_plan_count := v_plan_count + 1;
    v_assignment_id := null;
    v_due_date := null;
    v_due_text := null;
  end loop;

  return jsonb_build_object(
    'attendance_id', p_attendance_id,
    'confirmed_plan_items', v_plan_count,
    'created_assignments', v_assignment_count
  );
end;
$$;

revoke all on function public.homework_session_plan_confirm_departure(
  uuid,
  uuid,
  uuid[],
  uuid[]
) from public;
grant execute on function public.homework_session_plan_confirm_departure(
  uuid,
  uuid,
  uuid[],
  uuid[]
) to authenticated;

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
  v_promoted_ids uuid[];
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

  v_effective_class_at := coalesce(
    v_attendance.class_date_time,
    v_attendance.arrival_time,
    now()
  );

  with candidates as materialized (
    select distinct on (spi.homework_item_id)
      spi.*
    from public.homework_session_plan_items spi
    where spi.academy_id = v_attendance.academy_id
      and spi.student_id = v_attendance.student_id
      and spi.source_attendance_id is distinct from p_attendance_id
      and spi.destination = 'next_session'
      and spi.resolution in ('pending', 'confirmed')
      and (
        spi.target_class_at is null
        or spi.target_class_at <= v_effective_class_at
      )
    order by
      spi.homework_item_id,
      spi.target_class_at desc nulls last,
      spi.created_at desc,
      spi.id desc
  ),
  carried as (
    insert into public.homework_session_plan_items (
      academy_id,
      student_id,
      source_attendance_id,
      target_class_at,
      origin,
      destination,
      resolution,
      recommended_minutes_snapshot,
      group_id,
      homework_item_id,
      assignment_id,
      carried_from_plan_item_id,
      order_index
    )
    select
      c.academy_id,
      c.student_id,
      p_attendance_id,
      v_effective_class_at,
      'carried_from_previous',
      'in_class',
      'pending',
      c.recommended_minutes_snapshot,
      c.group_id,
      c.homework_item_id,
      null::uuid,
      c.id,
      c.order_index
    from candidates c
    on conflict (source_attendance_id, homework_item_id)
      where source_attendance_id is not null
    do update set
      origin = 'carried_from_previous',
      destination = 'in_class',
      resolution = 'pending',
      assignment_id = null,
      carried_from_plan_item_id = excluded.carried_from_plan_item_id,
      target_class_at = excluded.target_class_at,
      updated_at = now(),
      version = homework_session_plan_items.version + 1
    returning id, carried_from_plan_item_id
  ),
  resolved as (
    update public.homework_session_plan_items spi
    set resolution = 'promoted',
        updated_at = now(),
        version = spi.version + 1
    where spi.id in (
      select carried.carried_from_plan_item_id
      from carried
    )
      and spi.resolution <> 'promoted'
    returning spi.id
  )
  select coalesce(array_agg(c.id), array[]::uuid[])
  into v_promoted_ids
  from carried c;

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

create or replace function public._homework_session_plan_promote_on_arrival()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.arrival_time is null then
    return new;
  end if;

  if tg_op = 'INSERT' then
    perform public.homework_session_plan_promote_next_session(new.id);
  elsif old.arrival_time is null
     or (old.departure_time is not null and new.departure_time is null) then
    perform public.homework_session_plan_promote_next_session(new.id);
  end if;
  return new;
end;
$$;

drop trigger if exists trg_homework_session_plan_promote_on_arrival
  on public.attendance_records;
create trigger trg_homework_session_plan_promote_on_arrival
after insert or update of arrival_time, departure_time
on public.attendance_records
for each row execute function public._homework_session_plan_promote_on_arrival();

-- Preserve the latest list implementations and filter their child payloads.
-- M5 signatures and every returned M5 column remain unchanged. Student-only
-- metadata is added by the student RPC redefinitions at the end of this file.
do $$
begin
  if to_regprocedure(
       'public._m5_list_homework_groups_before_session_plan(uuid,uuid)'
     ) is null
     and to_regprocedure(
       'public.m5_list_homework_groups(uuid,uuid)'
     ) is not null then
    alter function public.m5_list_homework_groups(uuid, uuid)
      rename to _m5_list_homework_groups_before_session_plan;
  end if;

  if to_regprocedure(
       'public._m5_list_homework_only_groups_before_session_plan(uuid,uuid)'
     ) is null
     and to_regprocedure(
       'public.m5_list_homework_only_groups(uuid,uuid)'
     ) is not null then
    alter function public.m5_list_homework_only_groups(uuid, uuid)
      rename to _m5_list_homework_only_groups_before_session_plan;
  end if;

  if to_regprocedure(
       'public._m5_list_homework_groups_before_session_plan(uuid,uuid)'
     ) is null
     or to_regprocedure(
       'public._m5_list_homework_only_groups_before_session_plan(uuid,uuid)'
     ) is null then
    raise exception 'HOMEWORK_SESSION_PLAN_M5_BASE_FUNCTION_NOT_FOUND';
  end if;
end
$$;

revoke all on function
  public._m5_list_homework_groups_before_session_plan(uuid, uuid)
  from public;
grant execute on function
  public._m5_list_homework_groups_before_session_plan(uuid, uuid)
  to anon, authenticated;

revoke all on function
  public._m5_list_homework_only_groups_before_session_plan(uuid, uuid)
  from public;
grant execute on function
  public._m5_list_homework_only_groups_before_session_plan(uuid, uuid)
  to anon, authenticated;

create or replace function public.m5_list_homework_groups(
  p_academy_id uuid,
  p_student_id uuid
)
returns table(
  group_id uuid,
  group_title text,
  order_index integer,
  phase smallint,
  accumulated bigint,
  cycle_elapsed bigint,
  check_count integer,
  total_count integer,
  color bigint,
  page_summary text,
  run_start timestamptz,
  first_started_at timestamptz,
  content text,
  book_id text,
  grade_label text,
  "type" text,
  time_limit_minutes integer,
  m5_wait_title text,
  children jsonb
)
language sql
security definer
set search_path = public
as $$
  select
    m.group_id,
    m.group_title,
    m.order_index,
    m.phase,
    m.accumulated,
    m.cycle_elapsed,
    m.check_count,
    m.total_count,
    m.color,
    m.page_summary,
    m.run_start,
    m.first_started_at,
    m.content,
    m.book_id,
    m.grade_label,
    m."type",
    m.time_limit_minutes,
    m.m5_wait_title,
    visible.children
  from public._m5_list_homework_groups_before_session_plan(
    p_academy_id,
    p_student_id
  ) m
  cross join lateral (
    select jsonb_agg(child.value order by child.ordinality) as children
    from jsonb_array_elements(coalesce(m.children, '[]'::jsonb))
      with ordinality as child(value, ordinality)
    where public.homework_session_plan_item_is_visible(
      p_academy_id,
      p_student_id,
      (child.value->>'item_id')::uuid
    )
  ) visible
  where visible.children is not null
  order by m.order_index, m.group_id;
$$;

grant execute on function public.m5_list_homework_groups(uuid, uuid)
  to anon, authenticated;

create or replace function public.m5_list_homework_only_groups(
  p_academy_id uuid,
  p_student_id uuid
)
returns table(
  group_id uuid,
  group_title text,
  order_index integer,
  phase smallint,
  accumulated bigint,
  cycle_elapsed bigint,
  check_count integer,
  total_count integer,
  color bigint,
  page_summary text,
  run_start timestamptz,
  first_started_at timestamptz,
  content text,
  book_id text,
  grade_label text,
  "type" text,
  time_limit_minutes integer,
  m5_wait_title text,
  children jsonb
)
language sql
security definer
set search_path = public
as $$
  select
    m.group_id,
    m.group_title,
    m.order_index,
    m.phase,
    m.accumulated,
    m.cycle_elapsed,
    m.check_count,
    m.total_count,
    m.color,
    m.page_summary,
    m.run_start,
    m.first_started_at,
    m.content,
    m.book_id,
    m.grade_label,
    m."type",
    m.time_limit_minutes,
    m.m5_wait_title,
    visible.children
  from public._m5_list_homework_only_groups_before_session_plan(
    p_academy_id,
    p_student_id
  ) m
  cross join lateral (
    select jsonb_agg(child.value order by child.ordinality) as children
    from jsonb_array_elements(coalesce(m.children, '[]'::jsonb))
      with ordinality as child(value, ordinality)
    where public.homework_session_plan_item_is_visible(
      p_academy_id,
      p_student_id,
      (child.value->>'item_id')::uuid
    )
  ) visible
  where visible.children is not null
  order by m.order_index, m.group_id;
$$;

grant execute on function public.m5_list_homework_only_groups(uuid, uuid)
  to anon, authenticated;

-- Keep the existing recommended-minutes payload field semantically aligned
-- when a destination exception leaves a mixed group during the same transaction.
create or replace function public.m5_group_recommended_minutes(
  p_academy_id uuid,
  p_student_id uuid,
  p_group_id uuid
)
returns integer
language sql
stable
set search_path = public
as $$
  with item_minutes as (
    select
      coalesce(
        nullif(h.recommended_minutes, 0),
        nullif(h.recommended_minutes_auto, 0),
        0
      )::integer as minutes
    from public.homework_group_items gi
    join public.homework_items h on h.id = gi.homework_item_id
    where gi.academy_id = p_academy_id
      and gi.student_id = p_student_id
      and gi.group_id = p_group_id
      and h.academy_id = p_academy_id
      and h.student_id = p_student_id
      and public.homework_session_plan_item_is_visible(
        p_academy_id,
        p_student_id,
        h.id
      )
  ),
  agg as (
    select
      coalesce(sum(minutes), 0)::integer as raw_sum,
      count(*) filter (where minutes > 0)::integer as positive_count
    from item_minutes
  )
  select greatest(
    0,
    a.raw_sum - greatest(a.positive_count - 1, 0) * 10
  )::integer
  from agg a;
$$;

-- RPC contracts used by HomeworkSessionPlanService.
create or replace function public.homework_split_group_by_plan_destination(
  p_source_attendance_id uuid,
  p_student_id uuid,
  p_group_id uuid,
  p_origin public.homework_session_plan_origin,
  p_group_destination public.homework_session_plan_destination,
  p_item_destinations jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy_id uuid;
  v_payload jsonb;
begin
  select ar.academy_id
  into v_academy_id
  from public.attendance_records ar
  where ar.id = p_source_attendance_id
    and ar.student_id = p_student_id;

  if v_academy_id is null then
    raise exception 'HOMEWORK_SESSION_PLAN_ATTENDANCE_NOT_FOUND';
  end if;

  if p_item_destinations is null
     or jsonb_typeof(p_item_destinations) <> 'object'
     or p_item_destinations = '{}'::jsonb then
    raise exception 'HOMEWORK_SESSION_PLAN_DESTINATIONS_REQUIRED';
  end if;

  select jsonb_agg(
    jsonb_build_object(
      'homework_item_id', entry.key,
      'destination', coalesce(nullif(entry.value #>> '{}', ''), p_group_destination::text),
      'origin', p_origin::text
    )
    order by entry.key
  )
  into v_payload
  from jsonb_each(p_item_destinations) entry;

  return public.homework_session_plan_split_group_by_destination(
    v_academy_id,
    p_source_attendance_id,
    p_group_id,
    v_payload
  );
end;
$$;

revoke all on function public.homework_split_group_by_plan_destination(
  uuid,
  uuid,
  uuid,
  public.homework_session_plan_origin,
  public.homework_session_plan_destination,
  jsonb
) from public;
grant execute on function public.homework_split_group_by_plan_destination(
  uuid,
  uuid,
  uuid,
  public.homework_session_plan_origin,
  public.homework_session_plan_destination,
  jsonb
) to authenticated;

create or replace function public.homework_set_session_plan_destination(
  p_source_attendance_id uuid,
  p_student_id uuid,
  p_group_id uuid,
  p_homework_item_ids uuid[],
  p_origin public.homework_session_plan_origin,
  p_destination public.homework_session_plan_destination,
  p_item_destination_overrides jsonb default '{}'::jsonb,
  p_target_class_at timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy_id uuid;
  v_payload jsonb;
begin
  select ar.academy_id
  into v_academy_id
  from public.attendance_records ar
  where ar.id = p_source_attendance_id
    and ar.student_id = p_student_id;

  if v_academy_id is null then
    raise exception 'HOMEWORK_SESSION_PLAN_ATTENDANCE_NOT_FOUND';
  end if;

  if cardinality(coalesce(p_homework_item_ids, array[]::uuid[])) = 0 then
    raise exception 'HOMEWORK_SESSION_PLAN_ITEMS_REQUIRED';
  end if;

  if exists (
    select 1
    from unnest(p_homework_item_ids) item_id
    where not exists (
      select 1
      from public.homework_group_items gi
      where gi.academy_id = v_academy_id
        and gi.student_id = p_student_id
        and gi.group_id = p_group_id
        and gi.homework_item_id = item_id
    )
  ) then
    raise exception 'HOMEWORK_SESSION_PLAN_ITEM_NOT_IN_GROUP';
  end if;

  select jsonb_agg(
    jsonb_build_object(
      'homework_item_id', item_id,
      'destination', coalesce(
        p_item_destination_overrides->>item_id::text,
        p_destination::text
      ),
      'origin', p_origin::text,
      'target_class_at', p_target_class_at
    )
    order by ordinality
  )
  into v_payload
  from unnest(p_homework_item_ids) with ordinality as ids(item_id, ordinality);

  return public.homework_session_plan_split_group_by_destination(
    v_academy_id,
    p_source_attendance_id,
    p_group_id,
    v_payload
  );
end;
$$;

revoke all on function public.homework_set_session_plan_destination(
  uuid,
  uuid,
  uuid,
  uuid[],
  public.homework_session_plan_origin,
  public.homework_session_plan_destination,
  jsonb,
  timestamptz
) from public;
grant execute on function public.homework_set_session_plan_destination(
  uuid,
  uuid,
  uuid,
  uuid[],
  public.homework_session_plan_origin,
  public.homework_session_plan_destination,
  jsonb,
  timestamptz
) to authenticated;

create or replace function public.homework_confirm_session_plan_homework(
  p_source_attendance_id uuid,
  p_homework_item_ids uuid[]
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_attendance public.attendance_records%rowtype;
  v_group_ids uuid[];
  v_result jsonb;
begin
  select ar.*
  into v_attendance
  from public.attendance_records ar
  where ar.id = p_source_attendance_id;

  if v_attendance.id is null then
    raise exception 'HOMEWORK_SESSION_PLAN_ATTENDANCE_NOT_FOUND';
  end if;

  if cardinality(coalesce(p_homework_item_ids, array[]::uuid[])) = 0 then
    return jsonb_build_object(
      'attendance_id', p_source_attendance_id,
      'confirmed_plan_items', 0,
      'created_assignments', 0
    );
  end if;

  if exists (
    select 1
    from unnest(p_homework_item_ids) requested(item_id)
    where not exists (
      select 1
      from public.homework_session_plan_items spi
      where spi.source_attendance_id = p_source_attendance_id
        and spi.academy_id = v_attendance.academy_id
        and spi.student_id = v_attendance.student_id
        and spi.homework_item_id = requested.item_id
        and spi.destination = 'homework'
        and spi.resolution in ('pending', 'confirmed')
    )
  ) then
    raise exception 'HOMEWORK_SESSION_PLAN_HOMEWORK_ITEM_NOT_FOUND';
  end if;

  select coalesce(array_agg(distinct spi.group_id), array[]::uuid[])
  into v_group_ids
  from public.homework_session_plan_items spi
  where spi.source_attendance_id = p_source_attendance_id
    and spi.academy_id = v_attendance.academy_id
    and spi.student_id = v_attendance.student_id
    and spi.homework_item_id = any(p_homework_item_ids)
    and spi.destination = 'homework'
    and spi.group_id is not null;

  v_result := public.homework_session_plan_confirm_departure(
    v_attendance.academy_id,
    p_source_attendance_id,
    v_group_ids,
    p_homework_item_ids
  );

  return v_result;
end;
$$;

revoke all on function public.homework_confirm_session_plan_homework(uuid, uuid[])
  from public;
grant execute on function public.homework_confirm_session_plan_homework(uuid, uuid[])
  to authenticated;

-- Student-only list metadata. M5 signatures above intentionally stay unchanged.
create or replace function public.homework_student_group_assignment_metadata(
  p_academy_id uuid,
  p_student_id uuid,
  p_group_id uuid,
  p_legacy_direct_fallback boolean
)
returns table(
  assignment_origin text,
  due_date date
)
language sql
stable
security definer
set search_path = public
as $$
  with group_item_ids as (
    select gi.homework_item_id
    from public.homework_group_items gi
    where gi.academy_id = p_academy_id
      and gi.student_id = p_student_id
      and gi.group_id = p_group_id
      and public.homework_session_plan_item_is_visible(
        p_academy_id,
        p_student_id,
        gi.homework_item_id
      )
  ),
  active_assignments as (
    select distinct
      a.id,
      a.homework_item_id,
      a.due_date
    from public.homework_assignments a
    where a.academy_id = p_academy_id
      and a.student_id = p_student_id
      and a.status = 'assigned'
      and a.homework_item_id in (
        select gii.homework_item_id
        from group_item_ids gii
      )
  ),
  plan_origin as (
    select
      bool_or(spi.origin = 'direct_homework') as has_direct,
      bool_or(
        spi.origin = 'planned_today'
        and spi.destination = 'homework'
        and spi.resolution = 'confirmed'
      ) as has_class_carryover
    from public.homework_session_plan_items spi
    where spi.academy_id = p_academy_id
      and spi.student_id = p_student_id
      and spi.homework_item_id in (
        select aa.homework_item_id
        from active_assignments aa
      )
      and spi.resolution <> 'cancelled'
  )
  select
    case
      when not exists (select 1 from active_assignments) then null::text
      when coalesce(po.has_direct, false) then 'direct'::text
      when coalesce(po.has_class_carryover, false)
        then 'class_carryover'::text
      when p_legacy_direct_fallback then 'direct'::text
      else null::text
    end as assignment_origin,
    (
      select min(aa.due_date)
      from active_assignments aa
    ) as due_date
  from plan_origin po;
$$;

revoke all on function public.homework_student_group_assignment_metadata(
  uuid,
  uuid,
  uuid,
  boolean
) from public;

drop function if exists public.student_list_homework_groups_v1();
create function public.student_list_homework_groups_v1()
returns table(
  group_id uuid,
  group_title text,
  order_index integer,
  phase smallint,
  accumulated bigint,
  cycle_elapsed bigint,
  check_count integer,
  total_count integer,
  color bigint,
  page_summary text,
  run_start timestamptz,
  first_started_at timestamptz,
  content text,
  book_id text,
  grade_label text,
  "type" text,
  time_limit_minutes integer,
  m5_wait_title text,
  children jsonb,
  recommended_minutes integer,
  list_kind text,
  assignment_origin text,
  due_date date,
  digital_solvable boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
begin
  select i.academy_id, i.student_id
  into v_academy, v_student
  from public.student_app_identity() i;

  if v_student is null then
    raise exception 'no student account';
  end if;

  return query
  select
    m.group_id,
    m.group_title,
    m.order_index,
    m.phase,
    m.accumulated,
    m.cycle_elapsed,
    m.check_count,
    m.total_count,
    m.color,
    m.page_summary,
    m.run_start,
    m.first_started_at,
    m.content,
    m.book_id,
    m.grade_label,
    m."type",
    m.time_limit_minutes,
    m.m5_wait_title,
    m.children,
    public.m5_group_recommended_minutes(
      v_academy,
      v_student,
      m.group_id
    ) as recommended_minutes,
    'in_class'::text as list_kind,
    metadata.assignment_origin,
    metadata.due_date,
    (
      btrim(coalesce(m."type", '')) not in ('출력물', '프린트')
      and exists (
        select 1
        from jsonb_array_elements(coalesce(m.children, '[]'::jsonb))
          as child(value)
        join public.homework_item_problems hip
          on hip.homework_item_id = (child.value->>'item_id')::uuid
         and hip.academy_id = v_academy
         and hip.student_id = v_student
      )
    )::boolean as digital_solvable
  from public.m5_list_homework_groups(v_academy, v_student) m
  cross join lateral public.homework_student_group_assignment_metadata(
    v_academy,
    v_student,
    m.group_id,
    false
  ) metadata;
end;
$$;

revoke all on function public.student_list_homework_groups_v1() from public;
grant execute on function public.student_list_homework_groups_v1()
  to authenticated;

drop function if exists public.student_list_homework_only_groups_v1();
create function public.student_list_homework_only_groups_v1()
returns table(
  group_id uuid,
  group_title text,
  order_index integer,
  phase smallint,
  accumulated bigint,
  cycle_elapsed bigint,
  check_count integer,
  total_count integer,
  color bigint,
  page_summary text,
  run_start timestamptz,
  first_started_at timestamptz,
  content text,
  book_id text,
  grade_label text,
  "type" text,
  time_limit_minutes integer,
  m5_wait_title text,
  children jsonb,
  recommended_minutes integer,
  list_kind text,
  assignment_origin text,
  due_date date,
  digital_solvable boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
begin
  select i.academy_id, i.student_id
  into v_academy, v_student
  from public.student_app_identity() i;

  if v_student is null then
    raise exception 'no student account';
  end if;

  return query
  select
    m.group_id,
    m.group_title,
    m.order_index,
    m.phase,
    m.accumulated,
    m.cycle_elapsed,
    m.check_count,
    m.total_count,
    m.color,
    m.page_summary,
    m.run_start,
    m.first_started_at,
    m.content,
    m.book_id,
    m.grade_label,
    m."type",
    m.time_limit_minutes,
    m.m5_wait_title,
    m.children,
    public.m5_group_recommended_minutes(
      v_academy,
      v_student,
      m.group_id
    ) as recommended_minutes,
    'homework'::text as list_kind,
    metadata.assignment_origin,
    metadata.due_date,
    (
      btrim(coalesce(m."type", '')) not in ('출력물', '프린트')
      and exists (
        select 1
        from jsonb_array_elements(coalesce(m.children, '[]'::jsonb))
          as child(value)
        join public.homework_item_problems hip
          on hip.homework_item_id = (child.value->>'item_id')::uuid
         and hip.academy_id = v_academy
         and hip.student_id = v_student
      )
    )::boolean as digital_solvable
  from public.m5_list_homework_only_groups(v_academy, v_student) m
  cross join lateral public.homework_student_group_assignment_metadata(
    v_academy,
    v_student,
    m.group_id,
    true
  ) metadata;
end;
$$;

revoke all on function public.student_list_homework_only_groups_v1()
  from public;
grant execute on function public.student_list_homework_only_groups_v1()
  to authenticated;
