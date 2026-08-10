-- 계획 저장 시 학습앱이 사용한 교사 채점 완료율과 학생앱 진행률의 현재값을 통일한다.
-- 분모 = 저장 당시 남은 권장분
-- 분자 = 저장 당시 남은 권장분 - 현재 남은 권장분

create or replace function public.m5_group_teacher_remaining_minutes(
  p_academy_id uuid,
  p_student_id uuid,
  p_item_ids uuid[]
)
returns integer
language sql
stable
set search_path = public
as $$
  with item_set as (
    select
      h.id,
      greatest(0, coalesce(h.count, 0))::integer as question_count
    from public.homework_items h
    where h.academy_id = p_academy_id
      and h.student_id = p_student_id
      and h.id = any (coalesce(p_item_ids, '{}'::uuid[]))
  ),
  plan as (
    select public.m5_items_recommended_minutes(
      p_academy_id,
      p_student_id,
      coalesce(p_item_ids, '{}'::uuid[])
    )::integer as minutes
  ),
  group_questions as (
    select coalesce(sum(i.question_count), 0)::integer as total
    from item_set i
  ),
  latest_attempts as (
    select distinct on (a.homework_item_id)
      a.id,
      a.homework_item_id,
      greatest(0, round(coalesce(a.score_total, 0)))::integer as total,
      greatest(0, coalesce(a.not_performed_count, 0))::integer
        as not_performed,
      greatest(0, coalesce(a.wrong_count, 0))::integer as wrong_count,
      greatest(0, round(coalesce(a.score_correct, 0)))::integer
        as score_correct,
      a.graded_at
    from public.homework_test_grading_attempts a
    join item_set i on i.id = a.homework_item_id
    where a.academy_id = p_academy_id
      and a.student_id = p_student_id
    order by a.homework_item_id, a.graded_at desc, a.id desc
  ),
  rates as (
    select
      a.id,
      a.homework_item_id,
      a.total,
      case
        when a.wrong_count <= 0 then
          greatest(0, a.total - least(a.total, a.not_performed))
        else least(
          greatest(0, a.total - least(a.total, a.not_performed)),
          a.score_correct
        )
      end::integer as completed,
      (
        select count(*)::integer
        from public.homework_test_grading_attempt_items ai
        where ai.attempt_id = a.id
      ) as recorded_count
    from latest_attempts a
  ),
  group_wide as (
    -- 학습앱 findGroupWideHomeworkProgressRate 와 같은 판정.
    select r.total, r.completed
    from rates r
    cross join group_questions q
    where q.total > 0
      and r.recorded_count >= q.total
    order by r.recorded_count desc
    limit 1
  ),
  aggregate_rate as (
    select
      coalesce(sum(r.total), 0)::numeric as total,
      coalesce(sum(r.completed), 0)::numeric as completed
    from rates r
  ),
  completion as (
    select least(
      1::numeric,
      greatest(
        0::numeric,
        case
          when exists (select 1 from group_wide) then
            coalesce(
              (select g.completed::numeric / nullif(g.total, 0)
               from group_wide g),
              0::numeric
            )
          else
            coalesce(
              (select a.completed / nullif(a.total, 0)
               from aggregate_rate a),
              0::numeric
            )
        end
      )
    ) as rate
  )
  select round(
    p.minutes * (1::numeric - c.rate)
  )::integer
  from plan p
  cross join completion c;
$$;

revoke all on function public.m5_group_teacher_remaining_minutes(
  uuid, uuid, uuid[]
) from public;
grant execute on function public.m5_group_teacher_remaining_minutes(
  uuid, uuid, uuid[]
) to anon, authenticated;

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
  totals as (
    select
      coalesce(sum(public.m5_items_recommended_minutes(
        v_academy, v_student, g.item_ids
      )), 0)::integer as plan_minutes,
      coalesce(sum(public.m5_items_earned_recommended_minutes(
        v_academy, v_student, g.item_ids
      )), 0)::integer as completed_minutes
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
