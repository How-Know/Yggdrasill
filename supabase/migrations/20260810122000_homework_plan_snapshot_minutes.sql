-- 계획 저장(목표 제시) 시 남은 권장분을 고정. 학생앱 % 분모로 사용.

alter table public.attendance_records
  add column if not exists homework_plan_snapshot_minutes integer;

alter table public.attendance_records
  drop constraint if exists attendance_records_plan_snapshot_minutes_chk;

alter table public.attendance_records
  add constraint attendance_records_plan_snapshot_minutes_chk
  check (
    homework_plan_snapshot_minutes is null
    or homework_plan_snapshot_minutes >= 0
  );

comment on column public.attendance_records.homework_plan_snapshot_minutes is
  'Remaining recommended minutes (오늘+대기) frozen when teacher presents the class goal snapshot.';

create or replace function public.student_today_plan_progress_v1()
returns table(
  plan_minutes integer,
  completed_recommended_minutes integer
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

  -- 스냅샷이 있으면 분모 고정, 분자는 (고정 잔여 - 현재 잔여).
  -- 스냅샷 id에는 홈 '+'용 숙제 항목도 섞일 수 있어 오늘/대기만 집계한다.
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
          where (child.value->>'item_id')::uuid = s.item_id
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
    rem as (
      select coalesce(sum(
        greatest(
          0,
          public.m5_items_recommended_minutes(
            v_academy, v_student, g.item_ids
          )
          - public.m5_items_earned_recommended_minutes(
            v_academy, v_student, g.item_ids
          )
        )
      ), 0)::integer as minutes
      from by_group g
    )
    select r.minutes into v_current_remaining from rem r;

    v_plan := greatest(0, v_snapshot_minutes);
    v_completed := greatest(0, v_plan - coalesce(v_current_remaining, 0));
    plan_minutes := v_plan;
    completed_recommended_minutes := least(v_plan, v_completed);
    return next;
  end if;

  -- 스냅샷 전: 분모=현재 권장 합, 분자=권장×완료율(earned).
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
    join public.homework_items h
      on h.id = (child.value->>'item_id')::uuid
     and h.academy_id = v_academy
     and h.student_id = v_student
    where nullif(child.value->>'item_id', '') is not null
      and not exists (
        select 1
        from public.homework_session_plan_items spi
        where spi.academy_id = v_academy
          and spi.student_id = v_student
          and spi.homework_item_id = (child.value->>'item_id')::uuid
          and (
            v_attendance_id is null
            or spi.source_attendance_id = v_attendance_id
          )
          and spi.resolution in ('pending', 'confirmed', 'completed')
      )
  ),
  by_group as (
    select
      c.group_id,
      array_agg(c.item_id) as item_ids
    from plan_candidates c
    group by c.group_id
  ),
  totals as (
    select
      coalesce(sum(
        public.m5_items_recommended_minutes(
          v_academy, v_student, g.item_ids
        )
      ), 0)::integer as plan_minutes,
      coalesce(sum(
        public.m5_items_earned_recommended_minutes(
          v_academy, v_student, g.item_ids
        )
      ), 0)::integer as completed_minutes
    from by_group g
  )
  select t.plan_minutes, t.completed_minutes
  into v_plan, v_completed
  from totals t;

  plan_minutes := coalesce(v_plan, 0);
  completed_recommended_minutes := coalesce(v_completed, 0);
  return next;
end;
$$;

revoke all on function public.student_today_plan_progress_v1() from public;
grant execute on function public.student_today_plan_progress_v1()
  to authenticated;
