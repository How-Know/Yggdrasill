-- M5: surface take-home homework (숙제) groups as read-only cards.
--
-- Background: m5_list_homework_groups intentionally EXCLUDES items that have an
-- 'assigned' homework_assignment (take-home homework). Those items still live in
-- their (active) homework_groups. We want the device to also show "pure homework"
-- groups -- groups whose only remaining (non-completed) items are take-home -- so
-- the student can see what was assigned as homework.
--
-- This is purely ADDITIVE: the existing active-group RPC is left untouched so the
-- in-progress display logic cannot regress. The gateway calls this function in
-- addition to m5_list_homework_groups and tags the rows with is_homework=true.
--
-- Returns the SAME column shape as m5_list_homework_groups so the device parser
-- and gateway payload sanitizer can treat both identically.

create or replace function public.m5_list_homework_only_groups(
  p_academy_id uuid,
  p_student_id uuid
) returns table(
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
  children jsonb
) as $$
begin
  return query
  with hw_items as (
    select
      gi.group_id,
      gi.item_order_index,
      h.id as item_id,
      h.title,
      h.page,
      h."count",
      h.memo,
      coalesce(h.check_count, 0)::integer as check_count,
      h.color::bigint as color,
      h.content,
      h.book_id::text as book_id,
      h.grade_label,
      h."type"
    from public.homework_group_items gi
    join public.homework_items h on h.id = gi.homework_item_id
    where gi.academy_id = p_academy_id
      and gi.student_id = p_student_id
      and h.academy_id = p_academy_id
      and h.student_id = p_student_id
      and h.completed_at is null
      and coalesce(h.status, 0) <> 1
      and exists (
        select 1
        from public.homework_assignments a
        where a.homework_item_id = h.id
          and a.academy_id = p_academy_id
          and a.student_id = p_student_id
          and a.status = 'assigned'
      )
  ),
  active_group_ids as (
    -- groups that already appear in the active list (have >=1 non-assigned item)
    select distinct gi.group_id
    from public.homework_group_items gi
    join public.homework_items h on h.id = gi.homework_item_id
    where gi.academy_id = p_academy_id
      and gi.student_id = p_student_id
      and h.academy_id = p_academy_id
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
  )
  select
    g.id as group_id,
    g.title as group_title,
    g.order_index,
    1::smallint as phase,
    0::bigint as accumulated,
    0::bigint as cycle_elapsed,
    max(hi.check_count)::integer as check_count,
    sum(coalesce(hi."count", 0))::integer as total_count,
    (array_agg(hi.color order by hi.item_order_index))[1] as color,
    string_agg(
      case when hi.page is not null and hi.page <> '' then hi.page else null end,
      ', ' order by hi.item_order_index
    ) as page_summary,
    null::timestamptz as run_start,
    null::timestamptz as first_started_at,
    (array_agg(hi.content order by hi.item_order_index))[1] as content,
    (array_agg(hi.book_id order by hi.item_order_index))[1] as book_id,
    (array_agg(hi.grade_label order by hi.item_order_index))[1] as grade_label,
    (array_agg(hi."type" order by hi.item_order_index))[1] as "type",
    0::integer as time_limit_minutes,
    null::text as m5_wait_title,
    jsonb_agg(
      jsonb_build_object(
        'item_id', hi.item_id,
        'title', hi.title,
        'page', hi.page,
        'count', hi."count",
        'memo', hi.memo,
        'check_count', hi.check_count,
        'phase', 1,
        'accumulated', 0,
        'run_start', null
      ) order by hi.item_order_index
    ) as children
  from public.homework_groups g
  join hw_items hi on hi.group_id = g.id
  where g.academy_id = p_academy_id
    and g.student_id = p_student_id
    and g.status = 'active'
    and not exists (select 1 from active_group_ids agi where agi.group_id = g.id)
  group by g.id, g.title, g.order_index
  order by g.order_index asc, g.id asc
  limit 6;
end;
$$ language plpgsql security definer set search_path=public;

grant execute on function public.m5_list_homework_only_groups(uuid, uuid) to anon, authenticated;
