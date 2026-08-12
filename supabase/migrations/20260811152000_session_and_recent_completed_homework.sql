-- 첫 카드 펼침 리스트: 이번 열린 출석(등원~) 이후 완료분만.
-- 최근 1달 완료 기록: 다이얼로그용. 수행률/완료율 RPC는 건드리지 않는다.

create or replace function public.student_list_session_completed_homework_v1()
returns table(
  group_id uuid,
  group_title text,
  page_summary text,
  total_count integer,
  accumulated_sec bigint,
  book_id text,
  grade_label text,
  "type" text,
  content text,
  finished_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  v_arrival timestamptz;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  select ar.arrival_time
  into v_arrival
  from public.attendance_records ar
  where ar.academy_id = v_academy
    and ar.student_id = v_student
    and ar.arrival_time is not null
    and ar.departure_time is null
  order by ar.arrival_time desc nulls last
  limit 1;

  if v_arrival is null then
    return;
  end if;

  return query
  with done_items as (
    select
      h.id as item_id,
      gi.group_id,
      gi.item_order_index,
      h.title,
      h.page,
      coalesce(h."count", 0)::integer as item_count,
      coalesce(h.accumulated_ms, 0)::bigint as accumulated_ms,
      h.book_id::text as book_id,
      h.grade_label,
      h."type",
      h.content,
      h.completed_at as finished_at
    from public.homework_items h
    left join public.homework_group_items gi
      on gi.homework_item_id = h.id
     and gi.academy_id = h.academy_id
     and gi.student_id = h.student_id
    where h.academy_id = v_academy
      and h.student_id = v_student
      and h.completed_at is not null
      and h.completed_at >= v_arrival
  ),
  grouped as (
    select
      coalesce(d.group_id, d.item_id) as gid,
      coalesce(
        nullif(trim(g.title), ''),
        nullif(trim(max(d.title)), ''),
        '과제'
      ) as title,
      array_agg(d.item_id order by d.item_order_index nulls last, d.item_id)
        as item_ids,
      array_agg(d.page order by d.item_order_index nulls last, d.item_id)
        as page_texts,
      sum(d.item_count)::integer as total_count,
      (sum(d.accumulated_ms) / 1000)::bigint as accumulated_sec,
      (array_agg(d.book_id order by d.item_order_index nulls last, d.item_id)
        filter (where nullif(trim(d.book_id), '') is not null))[1] as book_id,
      (array_agg(d.grade_label order by d.item_order_index nulls last, d.item_id)
        filter (where nullif(trim(d.grade_label), '') is not null))[1]
        as grade_label,
      (array_agg(d."type" order by d.item_order_index nulls last, d.item_id)
        filter (where nullif(trim(d."type"), '') is not null))[1] as "type",
      (array_agg(d.content order by d.item_order_index nulls last, d.item_id)
        filter (where nullif(trim(d.content), '') is not null))[1] as content,
      max(d.finished_at) as finished_at
    from done_items d
    left join public.homework_groups g
      on g.id = d.group_id
     and g.academy_id = v_academy
     and g.student_id = v_student
    group by coalesce(d.group_id, d.item_id), g.title
  )
  select
    gr.gid as group_id,
    gr.title as group_title,
    coalesce(
      public.m5_group_page_summary_from_items(
        v_academy, v_student, gr.item_ids, gr.page_texts
      ),
      ''
    ) as page_summary,
    coalesce(gr.total_count, 0) as total_count,
    coalesce(gr.accumulated_sec, 0) as accumulated_sec,
    coalesce(gr.book_id, '') as book_id,
    coalesce(gr.grade_label, '') as grade_label,
    coalesce(gr."type", '') as "type",
    coalesce(gr.content, '') as content,
    gr.finished_at
  from grouped gr
  order by gr.finished_at desc nulls last, gr.title asc;
end;
$$;

revoke all on function public.student_list_session_completed_homework_v1()
  from public;
grant execute on function public.student_list_session_completed_homework_v1()
  to authenticated;

create or replace function public.student_list_recent_completed_homework_v1(
  p_days integer default 30
)
returns table(
  group_id uuid,
  group_title text,
  page_summary text,
  total_count integer,
  accumulated_sec bigint,
  book_id text,
  grade_label text,
  "type" text,
  content text,
  finished_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  v_days integer;
  v_from timestamptz;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  v_days := greatest(1, least(coalesce(p_days, 30), 92));
  v_from := now() - make_interval(days => v_days);

  return query
  with done_items as (
    select
      h.id as item_id,
      gi.group_id,
      gi.item_order_index,
      h.title,
      h.page,
      coalesce(h."count", 0)::integer as item_count,
      coalesce(h.accumulated_ms, 0)::bigint as accumulated_ms,
      h.book_id::text as book_id,
      h.grade_label,
      h."type",
      h.content,
      h.completed_at as finished_at
    from public.homework_items h
    left join public.homework_group_items gi
      on gi.homework_item_id = h.id
     and gi.academy_id = h.academy_id
     and gi.student_id = h.student_id
    where h.academy_id = v_academy
      and h.student_id = v_student
      and h.completed_at is not null
      and h.completed_at >= v_from
  ),
  grouped as (
    select
      coalesce(d.group_id, d.item_id) as gid,
      coalesce(
        nullif(trim(g.title), ''),
        nullif(trim(max(d.title)), ''),
        '과제'
      ) as title,
      array_agg(d.item_id order by d.item_order_index nulls last, d.item_id)
        as item_ids,
      array_agg(d.page order by d.item_order_index nulls last, d.item_id)
        as page_texts,
      sum(d.item_count)::integer as total_count,
      (sum(d.accumulated_ms) / 1000)::bigint as accumulated_sec,
      (array_agg(d.book_id order by d.item_order_index nulls last, d.item_id)
        filter (where nullif(trim(d.book_id), '') is not null))[1] as book_id,
      (array_agg(d.grade_label order by d.item_order_index nulls last, d.item_id)
        filter (where nullif(trim(d.grade_label), '') is not null))[1]
        as grade_label,
      (array_agg(d."type" order by d.item_order_index nulls last, d.item_id)
        filter (where nullif(trim(d."type"), '') is not null))[1] as "type",
      (array_agg(d.content order by d.item_order_index nulls last, d.item_id)
        filter (where nullif(trim(d.content), '') is not null))[1] as content,
      max(d.finished_at) as finished_at
    from done_items d
    left join public.homework_groups g
      on g.id = d.group_id
     and g.academy_id = v_academy
     and g.student_id = v_student
    group by coalesce(d.group_id, d.item_id), g.title
  )
  select
    gr.gid as group_id,
    gr.title as group_title,
    coalesce(
      public.m5_group_page_summary_from_items(
        v_academy, v_student, gr.item_ids, gr.page_texts
      ),
      ''
    ) as page_summary,
    coalesce(gr.total_count, 0) as total_count,
    coalesce(gr.accumulated_sec, 0) as accumulated_sec,
    coalesce(gr.book_id, '') as book_id,
    coalesce(gr.grade_label, '') as grade_label,
    coalesce(gr."type", '') as "type",
    coalesce(gr.content, '') as content,
    gr.finished_at
  from grouped gr
  order by gr.finished_at desc nulls last, gr.title asc;
end;
$$;

revoke all on function public.student_list_recent_completed_homework_v1(integer)
  from public;
grant execute on function public.student_list_recent_completed_homework_v1(integer)
  to authenticated;
