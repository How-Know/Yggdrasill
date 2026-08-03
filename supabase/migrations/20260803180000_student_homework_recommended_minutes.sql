-- 학생앱 과제 목록에 권장시간(recommended_minutes) 노출.
-- 학습앱 홈 카드와 동일: 하위과제 합 − α(10분)×(개수−1).
-- time_limit_minutes(시험 제한시간)와는 별개.

create or replace function public.m5_group_recommended_minutes(
  p_academy_id uuid,
  p_student_id uuid,
  p_group_id uuid
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
    from public.homework_group_items gi
    join public.homework_items h on h.id = gi.homework_item_id
    where gi.academy_id = p_academy_id
      and gi.student_id = p_student_id
      and gi.group_id = p_group_id
      and h.academy_id = p_academy_id
      and h.student_id = p_student_id
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

revoke all on function public.m5_group_recommended_minutes(uuid, uuid, uuid) from public;
grant execute on function public.m5_group_recommended_minutes(uuid, uuid, uuid)
  to anon, authenticated;

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
  recommended_minutes integer
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

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
    public.m5_group_recommended_minutes(v_academy, v_student, m.group_id)
      as recommended_minutes
  from public.m5_list_homework_groups(v_academy, v_student) m;
end;
$$;

revoke all on function public.student_list_homework_groups_v1() from public;
grant execute on function public.student_list_homework_groups_v1() to authenticated;

drop function if exists public.student_list_homework_only_groups_v1();
create function public.student_list_homework_only_groups_v1()
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
  recommended_minutes integer
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

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
    public.m5_group_recommended_minutes(v_academy, v_student, m.group_id)
      as recommended_minutes
  from public.m5_list_homework_only_groups(v_academy, v_student) m;
end;
$$;

revoke all on function public.student_list_homework_only_groups_v1() from public;
grant execute on function public.student_list_homework_only_groups_v1() to authenticated;
