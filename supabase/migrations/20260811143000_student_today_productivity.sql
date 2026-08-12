-- 학생앱 첫 카드 생산성:
-- (등원 후 경과시간 - 학원 설정 휴식시간) / 오늘 채점으로 새로 통과한 문항수.

create or replace function public.m5_try_parse_jsonb(p_value text)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
begin
  if nullif(btrim(coalesce(p_value, '')), '') is null then
    return '[]'::jsonb;
  end if;
  return p_value::jsonb;
exception when others then
  return '[]'::jsonb;
end;
$$;

create or replace function public.m5_group_teacher_completed_count_at(
  p_academy_id uuid,
  p_student_id uuid,
  p_item_ids uuid[],
  p_as_of timestamptz
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
        as score_correct
    from public.homework_test_grading_attempts a
    join item_set i on i.id = a.homework_item_id
    where a.academy_id = p_academy_id
      and a.student_id = p_student_id
      and (p_as_of is null or a.graded_at < p_as_of)
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
    select r.completed
    from rates r
    cross join group_questions q
    where q.total > 0
      and r.recorded_count >= q.total
    order by r.recorded_count desc
    limit 1
  )
  select coalesce(
    (select g.completed from group_wide g),
    (select sum(r.completed)::integer from rates r),
    0
  );
$$;

revoke all on function public.m5_group_teacher_completed_count_at(
  uuid, uuid, uuid[], timestamptz
) from public;
grant execute on function public.m5_group_teacher_completed_count_at(
  uuid, uuid, uuid[], timestamptz
) to anon, authenticated;

create or replace function public.student_today_productivity_v1()
returns table(
  productive_seconds bigint,
  completed_problem_count integer
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  v_arrival timestamptz;
  v_end timestamptz;
  v_gross_seconds bigint := 0;
  v_break_seconds bigint := 0;
  v_completed integer := 0;
begin
  select i.academy_id, i.student_id
  into v_academy, v_student
  from public.student_app_identity() i;

  if v_student is null then
    raise exception 'no student account';
  end if;

  select ar.arrival_time, least(coalesce(ar.departure_time, now()), now())
  into v_arrival, v_end
  from public.attendance_records ar
  where ar.academy_id = v_academy
    and ar.student_id = v_student
    and ar.arrival_time is not null
    and (ar.departure_time is null or ar.departure_time >= ar.arrival_time)
    and (ar.arrival_time at time zone 'Asia/Seoul')::date =
        (now() at time zone 'Asia/Seoul')::date
  order by ar.arrival_time desc
  limit 1;

  if v_arrival is null or v_end <= v_arrival then
    productive_seconds := 0;
    completed_problem_count := 0;
    return next;
    return;
  end if;

  v_gross_seconds := greatest(
    0,
    floor(extract(epoch from (v_end - v_arrival)))::bigint
  );

  -- 등원~현재와 실제로 겹치는 설정 휴식 구간만 차감한다.
  with local_days as (
    select d::date as local_date
    from generate_series(
      (v_arrival at time zone 'Asia/Seoul')::date,
      (v_end at time zone 'Asia/Seoul')::date,
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
      on oh.academy_id = v_academy
     and oh.day_of_week = extract(isodow from d.local_date)::integer - 1
    cross join lateral jsonb_array_elements(
      case
        when jsonb_typeof(public.m5_try_parse_jsonb(oh.break_times)) = 'array'
          then public.m5_try_parse_jsonb(oh.break_times)
        else '[]'::jsonb
      end
    ) b(value)
  )
  select coalesce(sum(
    greatest(
      0,
      floor(extract(epoch from (
        least(v_end, cb.break_end) - greatest(v_arrival, cb.break_start)
      )))::bigint
    )
  ), 0)::bigint
  into v_break_seconds
  from configured_breaks cb
  where cb.break_end > cb.break_start
    and cb.break_end > v_arrival
    and cb.break_start < v_end;

  -- 각 마이그레이션 그룹의 등원 직전 통과 수와 현재 통과 수의 증가분.
  with grading_groups as (
    select
      coalesce(gi.group_id, h.id) as group_id,
      array_agg(h.id order by gi.item_order_index nulls last, h.id) as item_ids
    from public.homework_items h
    left join public.homework_group_items gi
      on gi.homework_item_id = h.id
     and gi.academy_id = h.academy_id
     and gi.student_id = h.student_id
    where h.academy_id = v_academy
      and h.student_id = v_student
      and exists (
        select 1
        from public.homework_test_grading_attempts a
        where a.academy_id = v_academy
          and a.student_id = v_student
          and a.homework_item_id = h.id
          and a.graded_at >= v_arrival
          and a.graded_at <= v_end
      )
    group by coalesce(gi.group_id, h.id)
  )
  select coalesce(sum(
    greatest(
      0,
      public.m5_group_teacher_completed_count_at(
        v_academy, v_student, g.item_ids, v_end + interval '1 microsecond'
      )
      - public.m5_group_teacher_completed_count_at(
        v_academy, v_student, g.item_ids, v_arrival
      )
    )
  ), 0)::integer
  into v_completed
  from grading_groups g;

  productive_seconds := greatest(0, v_gross_seconds - v_break_seconds);
  completed_problem_count := greatest(0, v_completed);
  return next;
end;
$$;

revoke all on function public.student_today_productivity_v1() from public;
grant execute on function public.student_today_productivity_v1()
  to authenticated;
