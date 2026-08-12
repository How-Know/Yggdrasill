-- 자정을 넘긴 열린 출석은 오늘 00시 이후만 계산하고,
-- 오늘 채점된 대표 item이 아니라 해당 homework group 전체로 전/후 통과 수를 비교한다.

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
  v_departure timestamptz;
  v_day_start timestamptz;
  v_day_end timestamptz;
  v_start timestamptz;
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

  v_day_start := (
    date_trunc('day', now() at time zone 'Asia/Seoul')
    at time zone 'Asia/Seoul'
  );
  v_day_end := v_day_start + interval '1 day';

  select ar.arrival_time, ar.departure_time
  into v_arrival, v_departure
  from public.attendance_records ar
  where ar.academy_id = v_academy
    and ar.student_id = v_student
    and ar.arrival_time is not null
    and ar.arrival_time < v_day_end
    and coalesce(ar.departure_time, now()) > v_day_start
  order by (ar.departure_time is null) desc, ar.arrival_time desc
  limit 1;

  v_start := greatest(v_arrival, v_day_start);
  v_end := least(coalesce(v_departure, now()), now(), v_day_end);

  if v_start is null or v_end <= v_start then
    productive_seconds := 0;
    completed_problem_count := 0;
    return next;
    return;
  end if;

  v_gross_seconds := greatest(
    0,
    floor(extract(epoch from (v_end - v_start)))::bigint
  );

  with local_days as (
    select d::date as local_date
    from generate_series(
      (v_start at time zone 'Asia/Seoul')::date,
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
        least(v_end, cb.break_end) - greatest(v_start, cb.break_start)
      )))::bigint
    )
  ), 0)::bigint
  into v_break_seconds
  from configured_breaks cb
  where cb.break_end > cb.break_start
    and cb.break_end > v_start
    and cb.break_start < v_end;

  with changed_groups as (
    select distinct coalesce(gi.group_id, a.homework_item_id) as group_id
    from public.homework_test_grading_attempts a
    left join public.homework_group_items gi
      on gi.homework_item_id = a.homework_item_id
     and gi.academy_id = a.academy_id
     and gi.student_id = a.student_id
    where a.academy_id = v_academy
      and a.student_id = v_student
      and a.graded_at >= v_start
      and a.graded_at <= v_end
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
          where gi.academy_id = v_academy
            and gi.student_id = v_student
            and gi.group_id = c.group_id
        ),
        array[c.group_id]::uuid[]
      ) as item_ids
    from changed_groups c
  )
  select coalesce(sum(
    greatest(
      0,
      public.m5_group_teacher_completed_count_at(
        v_academy, v_student, g.item_ids, v_end + interval '1 microsecond'
      )
      - public.m5_group_teacher_completed_count_at(
        v_academy, v_student, g.item_ids, v_start
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
