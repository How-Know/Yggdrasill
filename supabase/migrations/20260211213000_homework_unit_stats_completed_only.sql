-- 20260211213000: unit stats = completed-only, exclude assigned-homework items

create index if not exists idx_homework_assignments_academy_item
  on public.homework_assignments(academy_id, homework_item_id);

drop function if exists public.homework_unit_stats(
  uuid,
  uuid,
  text,
  text,
  timestamptz,
  timestamptz
);

drop view if exists public.vw_homework_unit_stats_base;

create view public.vw_homework_unit_stats_base as
with unit_weight as (
  select
    u.academy_id,
    u.homework_item_id,
    sum(greatest(u.weight, 0))::numeric as sum_weight
  from public.homework_item_units u
  group by u.academy_id, u.homework_item_id
)
select
  hi.id as homework_item_id,
  hi.academy_id,
  hi.student_id,
  hi.book_id,
  hi.grade_label,
  hi.source_unit_level,
  hi.source_unit_path,
  hi.completed_at,
  coalesce(hi.check_count, 0) as item_check_count,
  coalesce(hi.accumulated_ms, 0)::numeric as item_accumulated_ms,
  u.big_order,
  u.mid_order,
  u.small_order,
  u.big_name,
  u.mid_name,
  u.small_name,
  u.start_page,
  u.end_page,
  u.page_count,
  u.weight,
  u.source_scope,
  case
    when coalesce(uw.sum_weight, 0) = 0 then 0::numeric
    else coalesce(hi.accumulated_ms, 0)::numeric * (u.weight / uw.sum_weight)
  end as allocated_ms
from public.homework_items hi
join public.homework_item_units u
  on u.homework_item_id = hi.id
 and u.academy_id = hi.academy_id
left join unit_weight uw
  on uw.academy_id = u.academy_id
 and uw.homework_item_id = u.homework_item_id
where hi.book_id is not null
  and hi.grade_label is not null
  and (hi.completed_at is not null or hi.status = 1)
  and not exists (
    select 1
    from public.homework_assignments a
    where a.academy_id = hi.academy_id
      and a.homework_item_id = hi.id
  );

create function public.homework_unit_stats(
  p_academy_id uuid,
  p_book_id uuid default null,
  p_grade_label text default null,
  p_group_level text default 'small',
  p_from timestamptz default null,
  p_to timestamptz default null
) returns table(
  group_level text,
  big_order integer,
  mid_order integer,
  small_order integer,
  big_name text,
  mid_name text,
  small_name text,
  avg_minutes numeric,
  avg_checks numeric,
  total_checks bigint,
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

  if p_group_level not in ('big', 'mid', 'small') then
    raise exception 'invalid group level: %', p_group_level;
  end if;

  return query
  with filtered as (
    select b.*
    from public.vw_homework_unit_stats_base b
    where b.academy_id = p_academy_id
      and (p_book_id is null or b.book_id = p_book_id)
      and (p_grade_label is null or b.grade_label = p_grade_label)
      and (p_from is null or b.completed_at >= p_from)
      and (p_to is null or b.completed_at < p_to)
  ),
  item_grouped as (
    select
      f.big_order as g_big_order,
      case
        when p_group_level in ('mid', 'small') then f.mid_order
        else null
      end as g_mid_order,
      case
        when p_group_level = 'small' then f.small_order
        else null
      end as g_small_order,
      f.big_name as g_big_name,
      case
        when p_group_level in ('mid', 'small') then f.mid_name
        else null
      end as g_mid_name,
      case
        when p_group_level = 'small' then f.small_name
        else null
      end as g_small_name,
      avg(f.allocated_ms) as avg_allocated_ms,
      avg(f.item_check_count)::numeric as avg_item_check_count,
      coalesce(sum(f.item_check_count), 0)::bigint as total_check_count,
      count(distinct f.homework_item_id)::bigint as total_items,
      count(distinct f.student_id)::bigint as total_students
    from filtered f
    group by
      f.big_order,
      case
        when p_group_level in ('mid', 'small') then f.mid_order
        else null
      end,
      case
        when p_group_level = 'small' then f.small_order
        else null
      end,
      f.big_name,
      case
        when p_group_level in ('mid', 'small') then f.mid_name
        else null
      end,
      case
        when p_group_level = 'small' then f.small_name
        else null
      end
  )
  select
    p_group_level as group_level,
    ig.g_big_order as big_order,
    ig.g_mid_order as mid_order,
    ig.g_small_order as small_order,
    ig.g_big_name as big_name,
    ig.g_mid_name as mid_name,
    ig.g_small_name as small_name,
    round((ig.avg_allocated_ms / 60000.0)::numeric, 2) as avg_minutes,
    round(ig.avg_item_check_count, 2) as avg_checks,
    coalesce(ig.total_check_count, 0) as total_checks,
    ig.total_items,
    ig.total_students
  from item_grouped ig
  order by
    ig.g_big_order asc,
    ig.g_mid_order asc nulls first,
    ig.g_small_order asc nulls first;
end;
$$;

revoke all on function public.homework_unit_stats(uuid,uuid,text,text,timestamptz,timestamptz) from public;
grant execute on function public.homework_unit_stats(uuid,uuid,text,text,timestamptz,timestamptz) to anon, authenticated;

