-- 20260316143000: preserve group context on homework assignments

alter table public.homework_assignments
  add column if not exists group_id uuid references public.homework_groups(id) on delete set null,
  add column if not exists group_title_snapshot text;

-- Backfill group_id from current homework_group_items mapping when available.
update public.homework_assignments a
   set group_id = gi.group_id
  from public.homework_group_items gi
 where a.group_id is null
   and gi.academy_id = a.academy_id
   and gi.homework_item_id = a.homework_item_id;

-- Snapshot the group title at assignment time; if missing, keep a readable fallback.
update public.homework_assignments a
   set group_title_snapshot = g.title
  from public.homework_groups g
 where a.group_title_snapshot is null
   and a.group_id is not null
   and g.id = a.group_id
   and g.academy_id = a.academy_id;

update public.homework_assignments a
   set group_title_snapshot = hi.title
  from public.homework_items hi
 where a.group_title_snapshot is null
   and hi.id = a.homework_item_id
   and hi.academy_id = a.academy_id;

update public.homework_assignments
   set group_title_snapshot = '그룹 과제'
 where group_title_snapshot is null;

create index if not exists idx_hw_assignments_academy_student_status_group_due
  on public.homework_assignments(
    academy_id,
    student_id,
    status,
    group_id,
    due_date,
    order_index
  );

create index if not exists idx_hw_assignments_group_id
  on public.homework_assignments(group_id);
