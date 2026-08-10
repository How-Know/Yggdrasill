-- 수업 초 "계획 저장/목표 제시" 스냅샷.
-- 학생 앱 홈에서만 스냅샷 이후 추가 과제를 '+' 접두로 구분한다.
-- (서버 homework_groups.title 은 변경하지 않음)

alter table public.attendance_records
  add column if not exists homework_plan_snapshot_item_ids uuid[] not null
    default '{}'::uuid[],
  add column if not exists homework_plan_snapshot_at timestamptz;

comment on column public.attendance_records.homework_plan_snapshot_item_ids is
  'Item ids (오늘+다음) frozen when teacher presents the class goal snapshot.';

comment on column public.attendance_records.homework_plan_snapshot_at is
  'When the class goal snapshot was presented to the student. Null = not presented.';

drop function if exists public.student_list_homework_groups_v1();
create function public.student_list_homework_groups_v1()
returns table(
  group_id uuid,
  group_title text,
  order_index integer,
  phase smallint,
  accumulated bigint,
  cycle_elapsed bigint,
  check_count integer,
  total_count integer,
  color bigint,
  page_summary text,
  run_start timestamptz,
  first_started_at timestamptz,
  content text,
  book_id text,
  grade_label text,
  "type" text,
  time_limit_minutes integer,
  m5_wait_title text,
  children jsonb,
  recommended_minutes integer,
  list_kind text,
  assignment_origin text,
  due_date date,
  digital_solvable boolean,
  is_additional_after_snapshot boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  v_snapshot_at timestamptz;
  v_snapshot_ids uuid[] := '{}'::uuid[];
begin
  select i.academy_id, i.student_id
  into v_academy, v_student
  from public.student_app_identity() i;

  if v_student is null then
    raise exception 'no student account';
  end if;

  select ar.homework_plan_snapshot_at,
         coalesce(ar.homework_plan_snapshot_item_ids, '{}'::uuid[])
  into v_snapshot_at, v_snapshot_ids
  from public.attendance_records ar
  where ar.academy_id = v_academy
    and ar.student_id = v_student
    and ar.arrival_time is not null
    and ar.departure_time is null
  order by ar.arrival_time desc nulls last
  limit 1;

  return query
  select
    m.group_id,
    m.group_title,
    m.order_index,
    m.phase,
    m.accumulated,
    m.cycle_elapsed,
    m.check_count,
    m.total_count,
    m.color,
    m.page_summary,
    m.run_start,
    m.first_started_at,
    m.content,
    m.book_id,
    m.grade_label,
    m."type",
    m.time_limit_minutes,
    m.m5_wait_title,
    m.children,
    public.m5_group_recommended_minutes(
      v_academy,
      v_student,
      m.group_id
    ) as recommended_minutes,
    'in_class'::text as list_kind,
    metadata.assignment_origin,
    metadata.due_date,
    (
      btrim(coalesce(m."type", '')) not in ('출력물', '프린트')
      and exists (
        select 1
        from jsonb_array_elements(coalesce(m.children, '[]'::jsonb))
          as child(value)
        join public.homework_item_problems hip
          on hip.homework_item_id = (child.value->>'item_id')::uuid
         and hip.academy_id = v_academy
         and hip.student_id = v_student
      )
    )::boolean as digital_solvable,
    (
      v_snapshot_at is not null
      and coalesce(jsonb_array_length(coalesce(m.children, '[]'::jsonb)), 0) > 0
      and not exists (
        select 1
        from jsonb_array_elements(coalesce(m.children, '[]'::jsonb))
          as child(value)
        where nullif(child.value->>'item_id', '') is not null
          and (child.value->>'item_id')::uuid = any (v_snapshot_ids)
      )
    )::boolean as is_additional_after_snapshot
  from public.m5_list_homework_groups(v_academy, v_student) m
  cross join lateral public.homework_student_group_assignment_metadata(
    v_academy,
    v_student,
    m.group_id,
    false
  ) metadata;
end;
$$;

revoke all on function public.student_list_homework_groups_v1() from public;
grant execute on function public.student_list_homework_groups_v1()
  to authenticated;
