-- Keep the exact inspection time. `due_date` remains for date-based grouping
-- and legacy clients, while `due_at` is the authoritative timestamp.
alter table public.homework_assignments
  add column if not exists due_at timestamptz;

update public.homework_assignments
set due_at = due_date::timestamp at time zone 'Asia/Seoul'
where due_at is null
  and due_date is not null;

create or replace function public._sync_homework_assignment_due_at()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_plan_due_at timestamptz;
begin
  if new.due_at is null and new.due_date is not null then
    select spi.target_class_at
    into v_plan_due_at
    from public.homework_session_plan_items spi
    where spi.academy_id = new.academy_id
      and spi.student_id = new.student_id
      and spi.homework_item_id = new.homework_item_id
      and spi.destination = 'homework'
      and spi.target_class_at is not null
      and (spi.target_class_at at time zone 'Asia/Seoul')::date = new.due_date
    order by
      (spi.assignment_id = new.id) desc,
      spi.updated_at desc,
      spi.created_at desc
    limit 1;

    new.due_at := coalesce(
      v_plan_due_at,
      new.due_date::timestamp at time zone 'Asia/Seoul'
    );
  end if;

  if new.due_at is not null then
    new.due_date := (new.due_at at time zone 'Asia/Seoul')::date;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_homework_assignments_sync_due_at
  on public.homework_assignments;
create trigger trg_homework_assignments_sync_due_at
before insert or update of due_date, due_at
on public.homework_assignments
for each row execute function public._sync_homework_assignment_due_at();

create index if not exists idx_homework_assignments_due_at
  on public.homework_assignments(academy_id, student_id, due_at)
  where status in ('assigned', 'in_progress');
