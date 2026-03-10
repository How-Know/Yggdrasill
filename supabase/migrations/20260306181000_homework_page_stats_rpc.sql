-- 20260306181000: homework_page_stats RPC for page-level aggregation

create or replace function public.homework_page_stats(
  p_academy_id uuid,
  p_book_id uuid default null,
  p_grade_label text default null,
  p_from timestamptz default null,
  p_to timestamptz default null
) returns table(
  page_number integer,
  avg_minutes numeric,
  avg_checks numeric,
  total_items bigint,
  total_students bigint
)
language plpgsql
security definer
set search_path = public as $$
begin
  if not exists (
    select 1
    from public.memberships m
    where m.academy_id = p_academy_id
      and m.user_id = auth.uid()
  ) then
    raise exception 'not allowed';
  end if;

  return query
  select
    p.page_number,
    round(avg(p.allocated_ms) / 60000.0, 2) as avg_minutes,
    round(avg(p.allocated_checks), 2) as avg_checks,
    count(distinct p.homework_item_id)::bigint as total_items,
    count(distinct p.student_id)::bigint as total_students
  from public.homework_item_pages p
  join public.homework_items hi
    on hi.id = p.homework_item_id
   and hi.academy_id = p.academy_id
  where p.academy_id = p_academy_id
    and p.allocated_ms > 0
    and (p_book_id is null or p.book_id = p_book_id)
    and (p_grade_label is null or p.grade_label = p_grade_label)
    and (p_from is null or hi.completed_at >= p_from)
    and (p_to is null or hi.completed_at < p_to)
    and (hi.completed_at is not null or hi.status = 1)
  group by p.page_number
  order by p.page_number asc;
end;
$$;

revoke all on function public.homework_page_stats(uuid, uuid, text, timestamptz, timestamptz) from public;
grant execute on function public.homework_page_stats(uuid, uuid, text, timestamptz, timestamptz) to anon, authenticated;
