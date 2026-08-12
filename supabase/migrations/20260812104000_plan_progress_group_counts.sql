-- 오늘 수업 계획 진행률에 과제(그룹) 개수/완료 개수 추가.
drop function if exists public.student_today_plan_progress_v1();

create or replace function public.student_today_plan_progress_v1()
returns table(
  plan_minutes integer,
  completed_recommended_minutes integer,
  plan_group_count integer,
  completed_group_count integer
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  v_attendance_id uuid;
  v_snapshot_at timestamptz;
  v_snapshot_ids uuid[] := '{}'::uuid[];
  v_snapshot_minutes integer;
  v_plan integer := 0;
  v_completed integer := 0;
  v_current_remaining integer := 0;
  v_plan_groups integer := 0;
  v_completed_groups integer := 0;
begin
  select i.academy_id, i.student_id
  into v_academy, v_student
  from public.student_app_identity() i;

  if v_student is null then
    raise exception 'no student account';
  end if;

  select
    ar.id,
    ar.homework_plan_snapshot_at,
    coalesce(ar.homework_plan_snapshot_item_ids, '{}'::uuid[]),
    ar.homework_plan_snapshot_minutes
  into
    v_attendance_id,
    v_snapshot_at,
    v_snapshot_ids,
    v_snapshot_minutes
  from public.attendance_records ar
  where ar.academy_id = v_academy
    and ar.student_id = v_student
    and ar.arrival_time is not null
    and ar.departure_time is null
  order by ar.arrival_time desc nulls last
  limit 1;

  if v_snapshot_at is not null
     and v_snapshot_minutes is not null then
    with snap_items as (
      select distinct item_id
      from unnest(v_snapshot_ids) as item_id
      where item_id is not null
    ),
    snap_plan_items as (
      select s.item_id
      from snap_items s
      where exists (
        select 1
        from public.homework_session_plan_items spi
        where spi.academy_id = v_academy
          and spi.student_id = v_student
          and spi.homework_item_id = s.item_id
          and spi.source_attendance_id = v_attendance_id
          and spi.destination in ('in_class', 'next_session')
          and spi.resolution in ('pending', 'confirmed', 'completed')
      )
      or (
        exists (
          select 1
          from public.m5_list_homework_groups(v_academy, v_student) m
          cross join lateral jsonb_array_elements(
            coalesce(m.children, '[]'::jsonb)
          ) as child(value)
          where nullif(child.value->>'item_id', '') is not null
            and (child.value->>'item_id')::uuid = s.item_id
        )
        and not exists (
          select 1
          from public.homework_session_plan_items spi
          where spi.academy_id = v_academy
            and spi.student_id = v_student
            and spi.homework_item_id = s.item_id
            and spi.source_attendance_id = v_attendance_id
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
       and gi.academy_id = v_academy
       and gi.student_id = v_student
      group by coalesce(gi.group_id, s.item_id)
    ),
    per_group as (
      select
        public.m5_group_teacher_remaining_minutes(
          v_academy,
          v_student,
          g.item_ids
        ) as rem
      from by_group g
    ),
    agg as (
      select
        coalesce(sum(p.rem), 0)::integer as minutes,
        count(*)::integer as plan_groups,
        count(*) filter (where p.rem <= 0)::integer as completed_groups
      from per_group p
    )
    select a.minutes, a.plan_groups, a.completed_groups
    into v_current_remaining, v_plan_groups, v_completed_groups
    from agg a;

    v_plan := greatest(0, v_snapshot_minutes);
    v_completed := greatest(
      0,
      least(
        v_plan,
        v_plan - coalesce(v_current_remaining, 0)
      )
    );

    plan_minutes := v_plan;
    completed_recommended_minutes := v_completed;
    plan_group_count := coalesce(v_plan_groups, 0);
    completed_group_count := coalesce(v_completed_groups, 0);
    return next;
  end if;

  -- 스냅샷 전 레거시 경로는 기존 권장분/earned 집계를 유지한다.
  with plan_candidates as (
    select
      spi.homework_item_id as item_id,
      coalesce(spi.group_id, gi.group_id, spi.homework_item_id) as group_id
    from public.homework_session_plan_items spi
    join public.homework_items h
      on h.id = spi.homework_item_id
     and h.academy_id = spi.academy_id
     and h.student_id = spi.student_id
    left join public.homework_group_items gi
      on gi.homework_item_id = spi.homework_item_id
     and gi.academy_id = spi.academy_id
     and gi.student_id = spi.student_id
    where v_attendance_id is not null
      and spi.academy_id = v_academy
      and spi.student_id = v_student
      and spi.source_attendance_id = v_attendance_id
      and spi.destination in ('in_class', 'next_session')
      and spi.resolution in ('pending', 'confirmed', 'completed')

    union

    select
      (child.value->>'item_id')::uuid as item_id,
      m.group_id
    from public.m5_list_homework_groups(v_academy, v_student) m
    cross join lateral jsonb_array_elements(coalesce(m.children, '[]'::jsonb))
      as child(value)
    where nullif(child.value->>'item_id', '') is not null
  ),
  by_group as (
    select c.group_id, array_agg(c.item_id) as item_ids
    from plan_candidates c
    group by c.group_id
  ),
  per_group as (
    select
      public.m5_items_recommended_minutes(
        v_academy, v_student, g.item_ids
      ) as recommended,
      public.m5_items_earned_recommended_minutes(
        v_academy, v_student, g.item_ids
      ) as earned
    from by_group g
  ),
  totals as (
    select
      coalesce(sum(p.recommended), 0)::integer as plan_minutes,
      coalesce(sum(p.earned), 0)::integer as completed_minutes,
      count(*)::integer as plan_groups,
      count(*) filter (
        where coalesce(p.recommended, 0) > 0
          and coalesce(p.earned, 0) >= coalesce(p.recommended, 0)
      )::integer as completed_groups
    from per_group p
  )
  select
    t.plan_minutes,
    t.completed_minutes,
    t.plan_groups,
    t.completed_groups
  into v_plan, v_completed, v_plan_groups, v_completed_groups
  from totals t;

  plan_minutes := coalesce(v_plan, 0);
  completed_recommended_minutes := coalesce(v_completed, 0);
  plan_group_count := coalesce(v_plan_groups, 0);
  completed_group_count := coalesce(v_completed_groups, 0);
  return next;
end;
$$;

revoke all on function public.student_today_plan_progress_v1() from public;
grant execute on function public.student_today_plan_progress_v1()
  to authenticated;
