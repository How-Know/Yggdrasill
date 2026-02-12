-- 20260211195500: homework unit stats view/rpc (small-grain)

create index if not exists idx_hw_assignment_checks_academy_checked_at
  on public.homework_assignment_checks(academy_id, checked_at desc);

create or replace view public.vw_homework_unit_stats_base as
with unit_weight as (
  select
    u.academy_id,
    u.homework_item_id,
    sum(greatest(u.weight, 0))::numeric as sum_weight
  from public.homework_item_units u
  group by u.academy_id, u.homework_item_id
)
select
  c.id as check_id,
  c.academy_id,
  c.student_id,
  c.homework_item_id,
  c.assignment_id,
  c.progress,
  c.checked_at,
  hi.book_id,
  hi.grade_label,
  hi.source_unit_level,
  hi.source_unit_path,
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
from public.homework_assignment_checks c
join public.homework_items hi
  on hi.id = c.homework_item_id
 and hi.academy_id = c.academy_id
join public.homework_item_units u
  on u.homework_item_id = c.homework_item_id
 and u.academy_id = c.academy_id
left join unit_weight uw
  on uw.academy_id = u.academy_id
 and uw.homework_item_id = u.homework_item_id
where hi.book_id is not null
  and hi.grade_label is not null;

create or replace function public.homework_unit_stats(
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
      and (p_from is null or b.checked_at >= p_from)
      and (p_to is null or b.checked_at < p_to)
  ),
  item_distinct as (
    select distinct
      f.student_id,
      f.homework_item_id,
      f.big_order,
      f.mid_order,
      f.small_order,
      f.big_name,
      f.mid_name,
      f.small_name,
      f.allocated_ms,
      f.item_check_count
    from filtered f
  ),
  item_grouped as (
    select
      i.big_order as g_big_order,
      case
        when p_group_level in ('mid', 'small') then i.mid_order
        else null
      end as g_mid_order,
      case
        when p_group_level = 'small' then i.small_order
        else null
      end as g_small_order,
      i.big_name as g_big_name,
      case
        when p_group_level in ('mid', 'small') then i.mid_name
        else null
      end as g_mid_name,
      case
        when p_group_level = 'small' then i.small_name
        else null
      end as g_small_name,
      avg(i.allocated_ms) as avg_allocated_ms,
      avg(i.item_check_count)::numeric as avg_item_check_count,
      count(distinct i.homework_item_id) as total_items,
      count(distinct i.student_id) as total_students
    from item_distinct i
    group by
      i.big_order,
      case
        when p_group_level in ('mid', 'small') then i.mid_order
        else null
      end,
      case
        when p_group_level = 'small' then i.small_order
        else null
      end,
      i.big_name,
      case
        when p_group_level in ('mid', 'small') then i.mid_name
        else null
      end,
      case
        when p_group_level = 'small' then i.small_name
        else null
      end
  ),
  check_grouped as (
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
      count(f.check_id) as total_checks
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
    coalesce(cg.total_checks, 0) as total_checks,
    ig.total_items,
    ig.total_students
  from item_grouped ig
  left join check_grouped cg
    on cg.g_big_order = ig.g_big_order
   and cg.g_mid_order is not distinct from ig.g_mid_order
   and cg.g_small_order is not distinct from ig.g_small_order
  order by
    ig.g_big_order asc,
    ig.g_mid_order asc nulls first,
    ig.g_small_order asc nulls first;
end;
$$;

revoke all on function public.homework_unit_stats(uuid,uuid,text,text,timestamptz,timestamptz) from public;
grant execute on function public.homework_unit_stats(uuid,uuid,text,text,timestamptz,timestamptz) to anon, authenticated;

