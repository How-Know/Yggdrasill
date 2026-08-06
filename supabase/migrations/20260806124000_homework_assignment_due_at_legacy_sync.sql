-- A legacy client may update only due_date. In that case discard the old
-- timestamp before deriving the new due_at value.
create or replace function public._sync_homework_assignment_due_at()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_plan_due_at timestamptz;
begin
  if tg_op = 'UPDATE'
     and new.due_date is distinct from old.due_date
     and new.due_at is not distinct from old.due_at then
    new.due_at := null;
  end if;

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
