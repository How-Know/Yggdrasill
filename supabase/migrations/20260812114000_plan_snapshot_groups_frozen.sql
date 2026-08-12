-- 목표 제시 시점의 과제 그룹(및 소속 item)을 고정 저장.
-- 전체 개수는 이 스냅샷 길이를 쓰고, 완료 개수는 그 안에서의 completed_at만 센다.

alter table public.attendance_records
  add column if not exists homework_plan_snapshot_groups jsonb not null
    default '[]'::jsonb;

alter table public.attendance_records
  drop constraint if exists attendance_records_homework_plan_snapshot_groups_is_array;

alter table public.attendance_records
  add constraint attendance_records_homework_plan_snapshot_groups_is_array
  check (jsonb_typeof(homework_plan_snapshot_groups) = 'array');

comment on column public.attendance_records.homework_plan_snapshot_groups is
  '목표 제시 시점 과제 그룹 스냅샷 [{group_id, item_ids:[]}, ...]. 학생앱 완료개수 분모/분자.';

-- 기존 열린/과거 스냅샷 세션 백필 (현재 group_items 기준 1회).
update public.attendance_records ar
set homework_plan_snapshot_groups = coalesce((
  select jsonb_agg(
    jsonb_build_object(
      'group_id', t.group_id,
      'item_ids', t.item_ids
    )
    order by t.group_id
  )
  from (
    select
      coalesce(gi.group_id, s.item_id) as group_id,
      jsonb_agg(distinct s.item_id order by s.item_id) as item_ids
    from unnest(coalesce(ar.homework_plan_snapshot_item_ids, '{}'::uuid[]))
      as s(item_id)
    left join public.homework_group_items gi
      on gi.homework_item_id = s.item_id
     and gi.academy_id = ar.academy_id
     and gi.student_id = ar.student_id
    where s.item_id is not null
    group by coalesce(gi.group_id, s.item_id)
  ) t
), '[]'::jsonb)
where ar.homework_plan_snapshot_at is not null
  and coalesce(jsonb_array_length(ar.homework_plan_snapshot_groups), 0) = 0
  and cardinality(coalesce(ar.homework_plan_snapshot_item_ids, '{}'::uuid[])) > 0;

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
  v_snapshot_groups jsonb := '[]'::jsonb;
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
    ar.homework_plan_snapshot_minutes,
    coalesce(ar.homework_plan_snapshot_groups, '[]'::jsonb)
  into
    v_attendance_id,
    v_snapshot_at,
    v_snapshot_ids,
    v_snapshot_minutes,
    v_snapshot_groups
  from public.attendance_records ar
  where ar.academy_id = v_academy
    and ar.student_id = v_student
    and ar.arrival_time is not null
    and ar.departure_time is null
  order by ar.arrival_time desc nulls last
  limit 1;

  if v_snapshot_at is not null
     and v_snapshot_minutes is not null then
    -- 전체/완료 개수: 목표 제시 때 고정한 그룹 스냅샷.
    select
      coalesce(jsonb_array_length(v_snapshot_groups), 0)::integer,
      coalesce((
        select count(*)::integer
        from jsonb_array_elements(v_snapshot_groups) as g(value)
        where jsonb_typeof(g.value -> 'item_ids') = 'array'
          and jsonb_array_length(g.value -> 'item_ids') > 0
          and (
            select count(*)::integer
            from jsonb_array_elements_text(g.value -> 'item_ids') as iid(item_id)
            join public.homework_items h
              on h.id = iid.item_id::uuid
             and h.academy_id = v_academy
             and h.student_id = v_student
          ) = jsonb_array_length(g.value -> 'item_ids')
          and not exists (
            select 1
            from jsonb_array_elements_text(g.value -> 'item_ids') as iid(item_id)
            join public.homework_items h
              on h.id = iid.item_id::uuid
             and h.academy_id = v_academy
             and h.student_id = v_student
            where h.completed_at is null
          )
      ), 0)::integer
    into v_plan_groups, v_completed_groups;

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
      or exists (
        select 1
        from public.homework_items h
        where h.id = s.item_id
          and h.academy_id = v_academy
          and h.student_id = v_student
          and h.completed_at is not null
      )
    ),
    by_group as (
      select
        coalesce(gi.group_id, s.item_id) as group_id,
        array_agg(distinct s.item_id) as item_ids
      from snap_plan_items s
      left join public.homework_group_items gi
        on gi.homework_item_id = s.item_id
       and gi.academy_id = v_academy
       and gi.student_id = v_student
      group by coalesce(gi.group_id, s.item_id)
    ),
    rem as (
      select coalesce(sum(
        public.m5_group_teacher_remaining_minutes(
          v_academy,
          v_student,
          g.item_ids
        )
      ), 0)::integer as minutes
      from by_group g
    )
    select r.minutes into v_current_remaining
    from rem r;

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

  -- 스냅샷 전 레거시 경로.
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
    select c.group_id, array_agg(distinct c.item_id) as item_ids
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
      ) as earned,
      (
        cardinality(g.item_ids) > 0
        and (
          select count(*)::integer
          from unnest(g.item_ids) as iid(item_id)
          join public.homework_items h
            on h.id = iid.item_id
           and h.academy_id = v_academy
           and h.student_id = v_student
        ) = cardinality(g.item_ids)
        and not exists (
          select 1
          from unnest(g.item_ids) as iid(item_id)
          join public.homework_items h
            on h.id = iid.item_id
           and h.academy_id = v_academy
           and h.student_id = v_student
          where h.completed_at is null
        )
      ) as is_finished
    from by_group g
  ),
  totals as (
    select
      coalesce(sum(p.recommended), 0)::integer as plan_minutes,
      coalesce(sum(p.earned), 0)::integer as completed_minutes,
      count(*)::integer as plan_groups,
      count(*) filter (where p.is_finished)::integer as completed_groups
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
