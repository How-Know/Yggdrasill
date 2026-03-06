-- m5_list_homeworks: hide any item that has active assignment (match Flutter home chips)
drop function if exists public.m5_list_homeworks(uuid, uuid);

create function public.m5_list_homeworks(
  p_academy_id uuid,
  p_student_id uuid
) returns table(
  item_id uuid,
  title text,
  body text,
  page text,
  "count" integer,
  check_count integer,
  color bigint,
  phase smallint,
  accumulated bigint,
  content text,
  "type" text,
  book_id text,
  grade_label text,
  submitted_at timestamptz,
  confirmed_at timestamptz,
  waiting_at timestamptz
) as $$
begin
  return query
  select
    h.id as item_id,
    h.title,
    h.body,
    h.page,
    h."count",
    coalesce(h.check_count, 0)::integer,
    h.color::bigint,
    coalesce(h.phase, 1)::smallint,
    (coalesce(h.accumulated_ms, 0) / 1000)::bigint as accumulated,
    h.content,
    h."type",
    h.book_id::text,
    h.grade_label,
    h.submitted_at,
    h.confirmed_at,
    h.waiting_at
  from public.homework_items h
  where h.academy_id = p_academy_id
    and h.student_id = p_student_id
    and h.completed_at is null
    and coalesce(h.status, 0) <> 1
    and coalesce(h.phase, 1) between 1 and 4
    and not exists (
      select 1
      from public.homework_assignments a
      where a.homework_item_id = h.id
        and a.academy_id = p_academy_id
        and a.student_id = p_student_id
        and a.status = 'assigned'
    )
  order by
    coalesce(h.order_index, 0) asc,
    coalesce(h.waiting_at, h.submitted_at, h.confirmed_at, h.first_started_at, h.created_at) asc;
end;
$$ language plpgsql security definer set search_path=public;

grant execute on function public.m5_list_homeworks(uuid, uuid) to anon, authenticated;
