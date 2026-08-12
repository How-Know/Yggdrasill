-- 하원 시점의 회차 성과를 불변 스냅샷으로 보존한다.
-- 실제 휴식/휴식 포인트는 아직 관측하지 않으며, 확장 컬럼만 nullable 로 둔다.

create table if not exists public.student_class_session_snapshots (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  attendance_id uuid not null
    references public.attendance_records(id) on delete cascade,

  session_date date not null,
  arrival_time timestamptz not null,
  departure_time timestamptz not null,
  gross_attendance_seconds bigint not null default 0,
  configured_break_seconds bigint not null default 0,
  productive_seconds bigint not null default 0,

  -- 휴식 포인트 도입 후 채운다. 지금은 모두 null/not_tracked.
  authorized_break_seconds bigint,
  unauthorized_break_seconds bigint,
  break_points_earned integer,
  break_points_spent integer,
  break_data_status text not null default 'not_tracked',
  break_policy_version text,

  plan_snapshot_at timestamptz,
  plan_minutes integer not null default 0,
  completed_recommended_minutes integer not null default 0,
  remaining_recommended_minutes integer not null default 0,
  performance_rate numeric(7, 6) not null default 0,
  plan_item_count integer not null default 0,
  plan_group_count integer not null default 0,

  completed_problem_count integer not null default 0,
  completed_homework_count integer not null default 0,
  completed_group_count integer not null default 0,
  graded_solve_elapsed_ms bigint not null default 0,
  graded_extra_elapsed_ms bigint not null default 0,

  carry_in_item_count integer not null default 0,
  carry_out_item_count integer not null default 0,
  plan_details jsonb not null default '[]'::jsonb,
  metrics jsonb not null default '{}'::jsonb,

  data_quality text not null default 'complete',
  calculation_version text not null default 'session_performance_v1',
  finalized_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint uq_student_class_session_snapshot_attendance unique (attendance_id),
  constraint student_class_session_snapshot_times_chk check (
    departure_time >= arrival_time
  ),
  constraint student_class_session_snapshot_nonnegative_chk check (
    gross_attendance_seconds >= 0
    and configured_break_seconds >= 0
    and productive_seconds >= 0
    and plan_minutes >= 0
    and completed_recommended_minutes >= 0
    and remaining_recommended_minutes >= 0
    and completed_problem_count >= 0
    and completed_homework_count >= 0
    and completed_group_count >= 0
  ),
  constraint student_class_session_snapshot_rate_chk check (
    performance_rate >= 0 and performance_rate <= 1
  ),
  constraint student_class_session_snapshot_break_status_chk check (
    break_data_status in ('not_tracked', 'partial', 'complete')
  ),
  constraint student_class_session_snapshot_quality_chk check (
    data_quality in ('complete', 'partial', 'estimated')
  )
);

create index if not exists idx_class_session_snapshots_student_date
  on public.student_class_session_snapshots (
    academy_id, student_id, session_date desc
  );

alter table public.student_class_session_snapshots enable row level security;

drop policy if exists student_class_session_snapshots_staff_select
  on public.student_class_session_snapshots;
create policy student_class_session_snapshots_staff_select
on public.student_class_session_snapshots
for select
using (
  exists (
    select 1
    from public.memberships m
    where m.academy_id = student_class_session_snapshots.academy_id
      and m.user_id = auth.uid()
  )
);

create or replace function public.m5_attendance_plan_progress(
  p_attendance_id uuid
)
returns table(
  plan_minutes integer,
  completed_recommended_minutes integer,
  remaining_recommended_minutes integer,
  plan_item_count integer,
  plan_group_count integer
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_attendance public.attendance_records%rowtype;
begin
  select * into v_attendance
  from public.attendance_records ar
  where ar.id = p_attendance_id;

  if not found
     or v_attendance.homework_plan_snapshot_at is null
     or v_attendance.homework_plan_snapshot_minutes is null then
    plan_minutes := 0;
    completed_recommended_minutes := 0;
    remaining_recommended_minutes := 0;
    plan_item_count := 0;
    plan_group_count := 0;
    return next;
    return;
  end if;

  with snap_items as (
    select distinct item_id
    from unnest(
      coalesce(v_attendance.homework_plan_snapshot_item_ids, '{}'::uuid[])
    ) as item_id
    where item_id is not null
  ),
  snap_plan_items as (
    select s.item_id
    from snap_items s
    where exists (
      select 1
      from public.homework_session_plan_items spi
      where spi.academy_id = v_attendance.academy_id
        and spi.student_id = v_attendance.student_id
        and spi.homework_item_id = s.item_id
        and spi.source_attendance_id = v_attendance.id
        and spi.destination in ('in_class', 'next_session')
        and spi.resolution in ('pending', 'confirmed', 'completed')
    )
    or (
      exists (
        select 1
        from public.m5_list_homework_groups(
          v_attendance.academy_id, v_attendance.student_id
        ) m
        cross join lateral jsonb_array_elements(
          coalesce(m.children, '[]'::jsonb)
        ) child(value)
        where nullif(child.value->>'item_id', '') is not null
          and (child.value->>'item_id')::uuid = s.item_id
      )
      and not exists (
        select 1
        from public.homework_session_plan_items spi
        where spi.academy_id = v_attendance.academy_id
          and spi.student_id = v_attendance.student_id
          and spi.homework_item_id = s.item_id
          and spi.source_attendance_id = v_attendance.id
          and spi.resolution in ('pending', 'confirmed', 'completed')
      )
    )
  ),
  by_group as (
    select
      coalesce(gi.group_id, s.item_id) as group_id,
      array_agg(s.item_id) as item_ids
    from snap_plan_items s
    left join public.homework_group_items gi
      on gi.homework_item_id = s.item_id
     and gi.academy_id = v_attendance.academy_id
     and gi.student_id = v_attendance.student_id
    group by coalesce(gi.group_id, s.item_id)
  ),
  agg as (
    select
      coalesce(sum(public.m5_group_teacher_remaining_minutes(
        v_attendance.academy_id,
        v_attendance.student_id,
        g.item_ids
      )), 0)::integer as remaining,
      coalesce(sum(cardinality(g.item_ids)), 0)::integer as item_count,
      count(*)::integer as group_count
    from by_group g
  )
  select
    greatest(0, v_attendance.homework_plan_snapshot_minutes),
    greatest(
      0,
      least(
        greatest(0, v_attendance.homework_plan_snapshot_minutes),
        greatest(0, v_attendance.homework_plan_snapshot_minutes)
          - coalesce(a.remaining, 0)
      )
    ),
    greatest(0, coalesce(a.remaining, 0)),
    coalesce(a.item_count, 0),
    coalesce(a.group_count, 0)
  into
    plan_minutes,
    completed_recommended_minutes,
    remaining_recommended_minutes,
    plan_item_count,
    plan_group_count
  from agg a;

  return next;
end;
$$;

create or replace function public.m5_attendance_completed_problem_count(
  p_attendance_id uuid
)
returns integer
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_attendance public.attendance_records%rowtype;
  v_count integer := 0;
begin
  select * into v_attendance
  from public.attendance_records ar
  where ar.id = p_attendance_id;

  if not found
     or v_attendance.arrival_time is null
     or v_attendance.departure_time is null then
    return 0;
  end if;

  with changed_groups as (
    select distinct coalesce(gi.group_id, a.homework_item_id) as group_id
    from public.homework_test_grading_attempts a
    left join public.homework_group_items gi
      on gi.homework_item_id = a.homework_item_id
     and gi.academy_id = a.academy_id
     and gi.student_id = a.student_id
    where a.academy_id = v_attendance.academy_id
      and a.student_id = v_attendance.student_id
      and a.graded_at >= v_attendance.arrival_time
      and a.graded_at <= v_attendance.departure_time
  ),
  grading_groups as (
    select
      c.group_id,
      coalesce(
        (
          select array_agg(
            gi.homework_item_id
            order by gi.item_order_index, gi.homework_item_id
          )
          from public.homework_group_items gi
          where gi.academy_id = v_attendance.academy_id
            and gi.student_id = v_attendance.student_id
            and gi.group_id = c.group_id
        ),
        array[c.group_id]::uuid[]
      ) as item_ids
    from changed_groups c
  )
  select coalesce(sum(greatest(
    0,
    public.m5_group_teacher_completed_count_at(
      v_attendance.academy_id,
      v_attendance.student_id,
      g.item_ids,
      v_attendance.departure_time + interval '1 microsecond'
    )
    - public.m5_group_teacher_completed_count_at(
      v_attendance.academy_id,
      v_attendance.student_id,
      g.item_ids,
      v_attendance.arrival_time
    )
  )), 0)::integer
  into v_count
  from grading_groups g;

  return greatest(0, v_count);
end;
$$;

create or replace function public.m5_attendance_configured_break_seconds(
  p_attendance_id uuid
)
returns bigint
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_attendance public.attendance_records%rowtype;
  v_seconds bigint := 0;
begin
  select * into v_attendance
  from public.attendance_records ar
  where ar.id = p_attendance_id;

  if not found
     or v_attendance.arrival_time is null
     or v_attendance.departure_time is null
     or v_attendance.departure_time <= v_attendance.arrival_time then
    return 0;
  end if;

  with local_days as (
    select d::date as local_date
    from generate_series(
      (v_attendance.arrival_time at time zone 'Asia/Seoul')::date,
      (v_attendance.departure_time at time zone 'Asia/Seoul')::date,
      interval '1 day'
    ) d
  ),
  configured_breaks as (
    select distinct
      (
        d.local_date
        + make_interval(
            hours => coalesce((b.value->>'startHour')::integer, 0),
            mins => coalesce((b.value->>'startMinute')::integer, 0)
          )
      ) at time zone 'Asia/Seoul' as break_start,
      (
        d.local_date
        + make_interval(
            hours => coalesce((b.value->>'endHour')::integer, 0),
            mins => coalesce((b.value->>'endMinute')::integer, 0)
          )
      ) at time zone 'Asia/Seoul' as break_end
    from local_days d
    join public.operating_hours oh
      on oh.academy_id = v_attendance.academy_id
     and oh.day_of_week = extract(isodow from d.local_date)::integer - 1
    cross join lateral jsonb_array_elements(
      case
        when jsonb_typeof(public.m5_try_parse_jsonb(oh.break_times)) = 'array'
          then public.m5_try_parse_jsonb(oh.break_times)
        else '[]'::jsonb
      end
    ) b(value)
  )
  select coalesce(sum(greatest(
    0,
    floor(extract(epoch from (
      least(v_attendance.departure_time, cb.break_end)
      - greatest(v_attendance.arrival_time, cb.break_start)
    )))::bigint
  )), 0)::bigint
  into v_seconds
  from configured_breaks cb
  where cb.break_end > cb.break_start
    and cb.break_end > v_attendance.arrival_time
    and cb.break_start < v_attendance.departure_time;

  return greatest(0, v_seconds);
end;
$$;

create or replace function public.m5_finalize_class_session_snapshot(
  p_attendance_id uuid
)
returns uuid
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_attendance public.attendance_records%rowtype;
  v_progress record;
  v_break_seconds bigint := 0;
  v_gross_seconds bigint := 0;
  v_problem_count integer := 0;
  v_snapshot_id uuid;
  v_details jsonb := '[]'::jsonb;
begin
  select * into v_attendance
  from public.attendance_records ar
  where ar.id = p_attendance_id
  for update;

  if not found
     or v_attendance.arrival_time is null
     or v_attendance.departure_time is null then
    return null;
  end if;

  select * into v_progress
  from public.m5_attendance_plan_progress(v_attendance.id);

  v_gross_seconds := greatest(
    0,
    floor(extract(epoch from (
      v_attendance.departure_time - v_attendance.arrival_time
    )))::bigint
  );
  v_break_seconds :=
    public.m5_attendance_configured_break_seconds(v_attendance.id);
  v_problem_count :=
    public.m5_attendance_completed_problem_count(v_attendance.id);

  select coalesce(jsonb_agg(jsonb_build_object(
    'plan_item_id', spi.id,
    'homework_item_id', spi.homework_item_id,
    'group_id', spi.group_id,
    'title', h.title,
    'destination', spi.destination,
    'origin', spi.origin,
    'resolution', spi.resolution,
    'rollover_policy', spi.rollover_policy,
    'recommended_minutes_snapshot', spi.recommended_minutes_snapshot,
    'item_accumulated_ms_at_departure', coalesce(h.accumulated_ms, 0),
    'item_status_at_departure', h.status,
    'item_completed_at', h.completed_at
  ) order by spi.order_index, spi.id), '[]'::jsonb)
  into v_details
  from public.homework_session_plan_items spi
  left join public.homework_items h
    on h.id = spi.homework_item_id
   and h.academy_id = spi.academy_id
   and h.student_id = spi.student_id
  where spi.source_attendance_id = v_attendance.id
    and spi.academy_id = v_attendance.academy_id
    and spi.student_id = v_attendance.student_id;

  insert into public.student_class_session_snapshots (
    academy_id,
    student_id,
    attendance_id,
    session_date,
    arrival_time,
    departure_time,
    gross_attendance_seconds,
    configured_break_seconds,
    productive_seconds,
    authorized_break_seconds,
    unauthorized_break_seconds,
    break_points_earned,
    break_points_spent,
    break_data_status,
    plan_snapshot_at,
    plan_minutes,
    completed_recommended_minutes,
    remaining_recommended_minutes,
    performance_rate,
    plan_item_count,
    plan_group_count,
    completed_problem_count,
    completed_homework_count,
    completed_group_count,
    graded_solve_elapsed_ms,
    graded_extra_elapsed_ms,
    carry_in_item_count,
    carry_out_item_count,
    plan_details,
    metrics,
    data_quality,
    calculation_version
  )
  select
    v_attendance.academy_id,
    v_attendance.student_id,
    v_attendance.id,
    (v_attendance.departure_time at time zone 'Asia/Seoul')::date,
    v_attendance.arrival_time,
    v_attendance.departure_time,
    v_gross_seconds,
    v_break_seconds,
    greatest(0, v_gross_seconds - v_break_seconds),
    null,
    null,
    null,
    null,
    'not_tracked',
    v_attendance.homework_plan_snapshot_at,
    coalesce(v_progress.plan_minutes, 0),
    coalesce(v_progress.completed_recommended_minutes, 0),
    coalesce(v_progress.remaining_recommended_minutes, 0),
    case
      when coalesce(v_progress.plan_minutes, 0) <= 0 then 0
      else least(
        1::numeric,
        greatest(
          0::numeric,
          v_progress.completed_recommended_minutes::numeric
            / v_progress.plan_minutes::numeric
        )
      )
    end,
    coalesce(v_progress.plan_item_count, 0),
    coalesce(v_progress.plan_group_count, 0),
    v_problem_count,
    (
      select count(*)::integer
      from public.homework_items h
      where h.academy_id = v_attendance.academy_id
        and h.student_id = v_attendance.student_id
        and h.completed_at >= v_attendance.arrival_time
        and h.completed_at <= v_attendance.departure_time
    ),
    (
      select count(distinct coalesce(gi.group_id, h.id))::integer
      from public.homework_items h
      left join public.homework_group_items gi
        on gi.homework_item_id = h.id
       and gi.academy_id = h.academy_id
       and gi.student_id = h.student_id
      where h.academy_id = v_attendance.academy_id
        and h.student_id = v_attendance.student_id
        and h.completed_at >= v_attendance.arrival_time
        and h.completed_at <= v_attendance.departure_time
    ),
    (
      select coalesce(sum(a.solve_elapsed_ms), 0)::bigint
      from public.homework_test_grading_attempts a
      where a.academy_id = v_attendance.academy_id
        and a.student_id = v_attendance.student_id
        and a.graded_at >= v_attendance.arrival_time
        and a.graded_at <= v_attendance.departure_time
    ),
    (
      select coalesce(sum(a.extra_elapsed_ms), 0)::bigint
      from public.homework_test_grading_attempts a
      where a.academy_id = v_attendance.academy_id
        and a.student_id = v_attendance.student_id
        and a.graded_at >= v_attendance.arrival_time
        and a.graded_at <= v_attendance.departure_time
    ),
    (
      select count(*)::integer
      from public.homework_session_plan_items spi
      where spi.source_attendance_id = v_attendance.id
        and spi.origin = 'carried_from_previous'
    ),
    (
      select count(*)::integer
      from public.homework_session_plan_items spi
      where spi.source_attendance_id = v_attendance.id
        and (
          spi.destination in ('next_session', 'homework')
          or spi.rollover_policy in ('to_homework', 'carry_paused')
        )
        and spi.resolution in ('pending', 'confirmed')
    ),
    v_details,
    jsonb_build_object(
      'configured_break_only', true,
      'actual_break_tracking', false,
      'future_break_points_reserved', true
    ),
    case
      when v_attendance.homework_plan_snapshot_minutes is null
        then 'partial'
      else 'complete'
    end,
    'session_performance_v1'
  on conflict (attendance_id) do nothing
  returning id into v_snapshot_id;

  if v_snapshot_id is null then
    select s.id into v_snapshot_id
    from public.student_class_session_snapshots s
    where s.attendance_id = v_attendance.id;
  end if;

  return v_snapshot_id;
end;
$$;

create or replace function public._finalize_class_session_on_departure()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.departure_time is not null
     and old.departure_time is null
     and new.arrival_time is not null then
    perform public.m5_finalize_class_session_snapshot(new.id);
  end if;
  return new;
end;
$$;

drop trigger if exists trg_finalize_class_session_on_departure
  on public.attendance_records;
create trigger trg_finalize_class_session_on_departure
after update of departure_time on public.attendance_records
for each row
execute function public._finalize_class_session_on_departure();

create or replace function public.student_daily_performance_v1(
  p_days integer default 8
)
returns table(
  local_date date,
  plan_minutes integer,
  completed_recommended_minutes integer,
  performance_rate numeric,
  session_count integer,
  is_live boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  v_days integer;
  v_today date;
begin
  select i.academy_id, i.student_id
  into v_academy, v_student
  from public.student_app_identity() i;

  if v_student is null then
    raise exception 'no student account';
  end if;

  v_days := greatest(2, least(coalesce(p_days, 8), 31));
  v_today := (now() at time zone 'Asia/Seoul')::date;

  return query
  with dates as (
    select generate_series(
      v_today - (v_days - 1),
      v_today,
      interval '1 day'
    )::date as d
  ),
  closed as (
    select
      s.session_date as d,
      sum(s.plan_minutes)::integer as plan_minutes,
      sum(s.completed_recommended_minutes)::integer as completed_minutes,
      count(*)::integer as session_count
    from public.student_class_session_snapshots s
    where s.academy_id = v_academy
      and s.student_id = v_student
      and s.session_date >= v_today - (v_days - 1)
      and s.session_date <= v_today
    group by s.session_date
  ),
  open_attendance as (
    select ar.id
    from public.attendance_records ar
    where ar.academy_id = v_academy
      and ar.student_id = v_student
      and ar.arrival_time is not null
      and ar.departure_time is null
    order by ar.arrival_time desc
    limit 1
  ),
  live as (
    select
      v_today as d,
      p.plan_minutes,
      p.completed_recommended_minutes as completed_minutes,
      case when p.plan_minutes > 0 then 1 else 0 end::integer as session_count
    from open_attendance oa
    cross join lateral public.m5_attendance_plan_progress(oa.id) p
  ),
  totals as (
    select
      d.d,
      coalesce(c.plan_minutes, 0) + coalesce(l.plan_minutes, 0) as plan_minutes,
      coalesce(c.completed_minutes, 0) + coalesce(l.completed_minutes, 0)
        as completed_minutes,
      coalesce(c.session_count, 0) + coalesce(l.session_count, 0)
        as session_count,
      coalesce(l.session_count, 0) > 0 as is_live
    from dates d
    left join closed c on c.d = d.d
    left join live l on l.d = d.d
  )
  select
    t.d,
    t.plan_minutes,
    t.completed_minutes,
    case
      when t.plan_minutes <= 0 then 0::numeric
      else least(
        1::numeric,
        greatest(
          0::numeric,
          t.completed_minutes::numeric / t.plan_minutes::numeric
        )
      )
    end,
    t.session_count,
    t.is_live
  from totals t
  order by t.d;
end;
$$;

revoke all on function public.student_daily_performance_v1(integer) from public;
grant execute on function public.student_daily_performance_v1(integer)
  to authenticated;

revoke all on function public.m5_attendance_plan_progress(uuid) from public;
revoke all on function public.m5_attendance_completed_problem_count(uuid)
  from public;
revoke all on function public.m5_attendance_configured_break_seconds(uuid)
  from public;
revoke all on function public.m5_finalize_class_session_snapshot(uuid)
  from public;
