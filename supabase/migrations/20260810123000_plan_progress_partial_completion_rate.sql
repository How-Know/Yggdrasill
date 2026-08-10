-- 계획 진행률 분자: 과제 전체 완료 전이라도 문항 완료율만큼 반영.
-- learning_attempts 누락 시 student_textbook_answer_records 로도 통과를 본다.

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
            and (
              la.homework_item_problem_id = p.id
              or (
                la.homework_item_problem_id is null
                and p.crop_id is not null
                and la.crop_id = p.crop_id
                and la.student_id = p_student_id
                and la.academy_id = p_academy_id
              )
            )
        )
        or exists (
          select 1
          from public.student_textbook_answer_records r
          where r.student_id = p_student_id
            and r.academy_id = p_academy_id
            and p.crop_id is not null
            and r.crop_id = p.crop_id
            and r.is_correct = true
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

-- 스냅샷 이후 분자도 earned(권장×완료율) 증가분을 쓰도록 명확화.
-- completed = max(0, snapshot_remaining - current_remaining)
--         = max(0, earned_now - earned_at_snapshot)  (권장분 불변 가정)
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
    -- 스냅샷 잔여 대비 소화분. 문항 완료율이 오르면 earned↑ → 분자↑.
    v_completed := greatest(
      0,
      least(
        v_plan,
        v_plan - coalesce(v_current_remaining, 0)
      )
    );
    -- snap 항목이 비어 earned/remaining 집계가 실패해도, earned만으로 보조.
    if coalesce(v_current_earned, 0) > v_completed
       and v_plan > 0 then
      v_completed := least(v_plan, v_current_earned);
    end if;

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
