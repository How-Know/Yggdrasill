-- Ensure M5 refreshes immediately when assignment visibility changes.
-- Touch homework_items.updated_at on homework_assignments INSERT/UPDATE/DELETE
-- so existing homework_items realtime pipeline always emits a refresh event.

create or replace function public._touch_homework_item_on_assignment_change()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  -- Old item (DELETE or item changed on UPDATE)
  if tg_op = 'DELETE'
     or (tg_op = 'UPDATE' and old.homework_item_id is distinct from new.homework_item_id) then
    update public.homework_items
       set updated_at = now()
     where academy_id = old.academy_id
       and id = old.homework_item_id;
  end if;

  -- New item (INSERT or UPDATE)
  if tg_op <> 'DELETE' then
    update public.homework_items
       set updated_at = now()
     where academy_id = new.academy_id
       and id = new.homework_item_id;
  end if;

  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_touch_homework_item_on_assignment_change on public.homework_assignments;
create trigger trg_touch_homework_item_on_assignment_change
after insert or update or delete on public.homework_assignments
for each row execute function public._touch_homework_item_on_assignment_change();
