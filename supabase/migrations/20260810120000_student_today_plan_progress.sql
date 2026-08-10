-- 학생앱 상단: 수업 계획 진행률
-- 학습앱 수업계획 시트의 totalForTodayPlan() 과 동일하게
-- 오늘(in_class) + 대기(next_session) 권장분을 합산한다.

create or replace function public.m5_items_recommended_minutes(
  p_academy_id uuid,
  p_student_id uuid,
  p_item_ids uuid[]
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
    from public.homework_items h
    where h.academy_id = p_academy_id
      and h.student_id = p_student_id
      and h.id = any (coalesce(p_item_ids, '{}'::uuid[]))
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

revoke all on function public.m5_items_recommended_minutes(uuid, uuid, uuid[])
  from public;
grant execute on function public.m5_items_recommended_minutes(uuid, uuid, uuid[])
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
  v_plan integer := 0;
  v_completed integer := 0;
begin
  select i.academy_id, i.student_id
  into v_academy, v_student
  from public.student_app_identity() i;

  if v_student is null then
    raise exception 'no student account';
  end if;

  select ar.id
  into v_attendance_id
  from public.attendance_records ar
  where ar.academy_id = v_academy
    and ar.student_id = v_student
    and ar.arrival_time is not null
    and ar.departure_time is null
  order by ar.arrival_time desc nulls last
  limit 1;

  with plan_candidates as (
    -- 명시적 수업 계획: 오늘 + 대기(다음 수업)
    select
      spi.homework_item_id as item_id,
      coalesce(spi.group_id, gi.group_id, spi.homework_item_id) as group_id,
      (
        h.completed_at is not null
        or coalesce(h.status, 0) = 1
        or coalesce(h.phase, 1) = 0
        or spi.resolution = 'completed'
      ) as is_completed
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

    -- 계획 행이 없는 활성 오늘 수업 항목(기본 destination = 오늘)
    select
      (child.value->>'item_id')::uuid as item_id,
      m.group_id,
      (
        h.completed_at is not null
        or coalesce(h.status, 0) = 1
        or coalesce(h.phase, 1) = 0
      ) as is_completed
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
      array_agg(c.item_id) as item_ids,
      array_agg(c.item_id) filter (where c.is_completed) as completed_ids
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
        public.m5_items_recommended_minutes(
          v_academy, v_student, coalesce(g.completed_ids, '{}'::uuid[])
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
