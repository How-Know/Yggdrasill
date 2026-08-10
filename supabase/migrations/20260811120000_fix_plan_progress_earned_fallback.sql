-- 감나단 케이스: 계획 152분(잔여 스냅샷)인데 학생앱 100%로 표시되던 버그.
--
-- 원인:
-- 1) completed = snap - remaining 뒤에
--    if earned > completed then completed = min(snap, earned)
--    폴백이 있었음. 스냅샷이 '잔여분'이라 rec(전체 권장) > snap 이 정상인데,
--    이때 earned >= snap 이면 항상 100%로 붕괴함. (바닥값으로 earned를 쓰면 안 됨)
-- 2) 반대로 completed 는 현재 earned 를 넘을 수 없음 (천장). 계획 항목이 빠진 뒤
--    remaining 이 줄어 (snap - remaining) 이 허위로 커지는 것을 막는다.
-- 3) 스냅샷 경로 잔여는 오늘/대기 plan 교집합만 (분모와 동일 정의).
-- 4) m5_item_completion_rate 의 crop 단위 answer_records 는 과거 교재 풀이까지
--    오늘 완료율로 잡히므로 제거하고, learning_attempts(학생 스코프)만 사용.

create or replace function public.m5_item_completion_rate(
  p_academy_id uuid,
  p_student_id uuid,
  p_item_id uuid
)
returns numeric
language sql
stable
set search_path = public
as $$
  with probs as (
    select
      count(*)::numeric as total,
      count(*) filter (
        where exists (
          select 1
          from public.learning_attempts la
          where la.result = 'correct'
            and la.student_id = p_student_id
            and la.academy_id = p_academy_id
            and (
              la.homework_item_problem_id = p.id
              or (
                la.homework_item_problem_id is null
                and p.crop_id is not null
                and la.crop_id = p.crop_id
              )
            )
        )
      )::numeric as passed
    from public.homework_item_problems p
    where p.academy_id = p_academy_id
      and p.homework_item_id = p_item_id
      and p.excluded_at is null
  ),
  item as (
    select
      h.completed_at is not null
      or coalesce(h.status, 0) = 1
      or coalesce(h.phase, 1) = 0 as is_completed
    from public.homework_items h
    where h.academy_id = p_academy_id
      and h.student_id = p_student_id
      and h.id = p_item_id
  )
  select case
    when coalesce((select total from probs), 0) > 0 then
      least(
        1::numeric,
        greatest(
          0::numeric,
          (select passed from probs) / (select total from probs)
        )
      )
    when coalesce((select is_completed from item), false) then 1::numeric
    else 0::numeric
  end;
$$;

revoke all on function public.m5_item_completion_rate(uuid, uuid, uuid)
  from public;
grant execute on function public.m5_item_completion_rate(uuid, uuid, uuid)
  to anon, authenticated;

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
  v_current_earned integer := 0;
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
    -- 분모(스냅샷 잔여)와 동일: 오늘/대기 plan 만. 홈 '+'용 스냅샷 id 는 제외.
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
    agg as (
      select
        coalesce(sum(
          public.m5_items_recommended_minutes(
            v_academy, v_student, g.item_ids
          )
        ), 0)::integer as rec_minutes,
        coalesce(sum(
          public.m5_items_earned_recommended_minutes(
            v_academy, v_student, g.item_ids
          )
        ), 0)::integer as earned_minutes
      from by_group g
    )
    select
      greatest(0, a.rec_minutes - a.earned_minutes),
      a.earned_minutes
    into v_current_remaining, v_current_earned
    from agg a;

    v_plan := greatest(0, v_snapshot_minutes);
    -- 잔여 감소분. earned 로 바닥을 올리지 않는다 (100% 버그 원인).
    v_completed := greatest(
      0,
      least(
        v_plan,
        v_plan - coalesce(v_current_remaining, 0)
      )
    );
    -- 천장: 현재 집합에서 실제로 벌어들인 권장분을 넘지 못함.
    -- (계획에서 빠진 항목 때문에 remaining 이 줄며 %가 부푸는 것 방지)
    v_completed := least(
      v_completed,
      greatest(0, coalesce(v_current_earned, 0))
    );

    plan_minutes := v_plan;
    completed_recommended_minutes := v_completed;
    return next;
  end if;

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
