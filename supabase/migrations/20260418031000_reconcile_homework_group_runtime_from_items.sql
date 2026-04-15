-- Reconcile existing homework_group_runtime rows from homework_items state.
-- This repairs stale runtime phase (e.g. runtime=4 while items are already phase=1).

insert into public.homework_group_runtime (
  academy_id,
  group_id,
  student_id,
  phase,
  accumulated_ms,
  run_start,
  first_started_at,
  check_count
)
select
  gi.academy_id,
  gi.group_id,
  min(hi.student_id::text)::uuid as student_id,
  case
    when bool_or(hi.run_start is not null) then 2::smallint
    when bool_or(coalesce(hi.phase, 1) = 3) then 3::smallint
    when bool_or(coalesce(hi.phase, 1) = 4) then 4::smallint
    else 1::smallint
  end as phase,
  coalesce(max(coalesce(hi.accumulated_ms, 0)), 0)::bigint as accumulated_ms,
  (array_agg(hi.run_start order by gi.item_order_index) filter (where hi.run_start is not null))[1] as run_start,
  min(hi.first_started_at) as first_started_at,
  coalesce(max(coalesce(hi.check_count, 0)), 0)::integer as check_count
from public.homework_group_items gi
join public.homework_items hi
  on hi.id = gi.homework_item_id
 and hi.academy_id = gi.academy_id
join public.homework_groups g
  on g.id = gi.group_id
 and g.academy_id = gi.academy_id
 and g.status = 'active'
where hi.completed_at is null
  and coalesce(hi.status, 0) <> 1
group by gi.academy_id, gi.group_id
on conflict (academy_id, group_id) do nothing;

with runtime_from_items as (
  select
    gi.academy_id,
    gi.group_id,
    case
      when bool_or(hi.run_start is not null) then 2::smallint
      when bool_or(coalesce(hi.phase, 1) = 3) then 3::smallint
      when bool_or(coalesce(hi.phase, 1) = 4) then 4::smallint
      else 1::smallint
    end as phase,
    coalesce(max(coalesce(hi.accumulated_ms, 0)), 0)::bigint as accumulated_ms,
    (array_agg(hi.run_start order by gi.item_order_index) filter (where hi.run_start is not null))[1] as run_start,
    min(hi.first_started_at) as first_started_at,
    coalesce(max(coalesce(hi.check_count, 0)), 0)::integer as check_count
  from public.homework_group_items gi
  join public.homework_items hi
    on hi.id = gi.homework_item_id
   and hi.academy_id = gi.academy_id
  join public.homework_groups g
    on g.id = gi.group_id
   and g.academy_id = gi.academy_id
   and g.status = 'active'
  where hi.completed_at is null
    and coalesce(hi.status, 0) <> 1
  group by gi.academy_id, gi.group_id
)
update public.homework_group_runtime r
   set phase = s.phase,
       run_start = case when s.phase = 2 then s.run_start else null end,
       first_started_at = coalesce(r.first_started_at, s.first_started_at),
       check_count = s.check_count,
       accumulated_ms = greatest(coalesce(r.accumulated_ms, 0), coalesce(s.accumulated_ms, 0)),
       updated_at = now(),
       version = coalesce(r.version, 1) + 1
  from runtime_from_items s
 where r.academy_id = s.academy_id
   and r.group_id = s.group_id
   and (
     coalesce(r.phase, 0) <> coalesce(s.phase, 0)
     or coalesce(r.run_start, 'epoch'::timestamptz) <> coalesce(case when s.phase = 2 then s.run_start else null end, 'epoch'::timestamptz)
     or coalesce(r.check_count, 0) <> coalesce(s.check_count, 0)
     or coalesce(r.first_started_at, 'epoch'::timestamptz) <> coalesce(coalesce(r.first_started_at, s.first_started_at), 'epoch'::timestamptz)
   );
