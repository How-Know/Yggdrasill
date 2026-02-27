-- 20260226100000: homework priority order indexes/columns

alter table public.homework_items
  add column if not exists order_index integer not null default 0;

alter table public.homework_assignments
  add column if not exists order_index integer not null default 0;

with ranked_items as (
  select
    id,
    row_number() over (
      partition by academy_id, student_id
      order by updated_at desc nulls last, created_at desc nulls last, id asc
    ) - 1 as ord
  from public.homework_items
  where student_id is not null
)
update public.homework_items h
set order_index = ranked_items.ord
from ranked_items
where h.id = ranked_items.id
  and coalesce(h.order_index, -1) <> ranked_items.ord;

with ranked_assignments as (
  select
    id,
    row_number() over (
      partition by academy_id, student_id, due_date
      order by assigned_at desc nulls last, created_at desc nulls last, id asc
    ) - 1 as ord
  from public.homework_assignments
)
update public.homework_assignments a
set order_index = ranked_assignments.ord
from ranked_assignments
where a.id = ranked_assignments.id
  and coalesce(a.order_index, -1) <> ranked_assignments.ord;

create index if not exists idx_homework_items_student_order
  on public.homework_items(academy_id, student_id, order_index);

create index if not exists idx_homework_assignments_group_order
  on public.homework_assignments(academy_id, student_id, status, due_date, order_index);
