-- M5 group payload: keep cycle elapsed across rest(pause/resume).
-- Also align group total with baseline(sum) + cycle(max) model.

drop function if exists public.m5_list_homework_groups(uuid, uuid);

create function public.m5_list_homework_groups(
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
  children jsonb
) as $$
begin
  return query
  with active_items as (
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
      coalesce(h.phase, 1)::smallint as phase,
      (coalesce(h.accumulated_ms, 0) / 1000)::bigint as accumulated,
      (
        (
          case
            when coalesce(h.cycle_base_accumulated_ms, 0) <= 0
                 and coalesce(h.phase, 1) = 1
                 and coalesce(h.accumulated_ms, 0) > 0
              then coalesce(h.accumulated_ms, 0)
            else coalesce(h.cycle_base_accumulated_ms, 0)
          end
        ) / 1000
      )::bigint as cycle_base_sec,
      greatest(
        0::bigint,
        (
          (
            coalesce(h.accumulated_ms, 0)
            -
            case
              when coalesce(h.cycle_base_accumulated_ms, 0) <= 0
                   and coalesce(h.phase, 1) = 1
                   and coalesce(h.accumulated_ms, 0) > 0
                then coalesce(h.accumulated_ms, 0)
              else coalesce(h.cycle_base_accumulated_ms, 0)
            end
          ) / 1000
        )::bigint
      ) as cycle_elapsed_sec,
      h.run_start,
      h.first_started_at,
      h.content,
      h.book_id::text as book_id,
      h.grade_label,
      h."type",
      h.submitted_at,
      h.confirmed_at,
      h.waiting_at
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
  ),
  group_summary as (
    select
      g.id as group_id,
      g.title as group_title,
      g.order_index,
      case
        when bool_or(ai.run_start is not null) then 2::smallint
        when bool_or(ai.phase = 3) then 3::smallint
        when bool_or(ai.phase = 4) then 4::smallint
        else greatest(max(ai.phase), 1)::smallint
      end as phase,
      (sum(ai.cycle_base_sec) + coalesce(max(ai.cycle_elapsed_sec), 0))::bigint as accumulated,
      coalesce(max(ai.cycle_elapsed_sec), 0)::bigint as cycle_elapsed,
      max(ai.check_count)::integer as check_count,
      sum(coalesce(ai."count", 0))::integer as total_count,
      (array_agg(ai.color order by ai.item_order_index))[1] as color,
      string_agg(
        case when ai.page is not null and ai.page <> '' then ai.page else null end,
        ', ' order by ai.item_order_index
      ) as page_summary,
      (array_agg(ai.run_start order by ai.item_order_index) filter (where ai.run_start is not null))[1] as run_start,
      min(ai.first_started_at) as first_started_at,
      (array_agg(ai.content order by ai.item_order_index))[1] as content,
      (array_agg(ai.book_id order by ai.item_order_index))[1] as book_id,
      (array_agg(ai.grade_label order by ai.item_order_index))[1] as grade_label,
      (array_agg(ai."type" order by ai.item_order_index))[1] as "type",
      jsonb_agg(
        jsonb_build_object(
          'item_id', ai.item_id,
          'title', ai.title,
          'page', ai.page,
          'count', ai."count",
          'memo', ai.memo,
          'check_count', ai.check_count,
          'phase', ai.phase,
          'accumulated', ai.accumulated,
          'run_start', ai.run_start
        ) order by ai.item_order_index
      ) as children
    from public.homework_groups g
    join active_items ai on ai.group_id = g.id
    where g.academy_id = p_academy_id
      and g.student_id = p_student_id
      and g.status = 'active'
    group by g.id, g.title, g.order_index
  )
  select
    gs.group_id,
    gs.group_title,
    gs.order_index,
    gs.phase,
    gs.accumulated,
    gs.cycle_elapsed,
    gs.check_count,
    gs.total_count,
    gs.color,
    gs.page_summary,
    gs.run_start,
    gs.first_started_at,
    gs.content,
    gs.book_id,
    gs.grade_label,
    gs."type",
    gs.children
  from group_summary gs
  order by gs.order_index asc, gs.group_id asc;
end;
$$ language plpgsql security definer set search_path=public;

grant execute on function public.m5_list_homework_groups(uuid, uuid) to anon, authenticated;
