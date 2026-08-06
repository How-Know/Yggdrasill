-- Exact timestamps distinguish a missed morning session from afternoon arrival.

create or replace function public._normalize_homework_return_absence()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.status = 'carried_to_class'
     and new.due_for_check_at is not null then
    new.absence_carryover :=
      coalesce(new.original_due_at, new.due_at) is not null
      and coalesce(new.original_due_at, new.due_at) < new.due_for_check_at;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_homework_return_absence
  on public.homework_assignments;
create trigger trg_homework_return_absence
before insert or update of status, due_for_check_at, due_at, original_due_at
on public.homework_assignments
for each row execute function public._normalize_homework_return_absence();

update public.homework_assignments
set absence_carryover = (
  coalesce(original_due_at, due_at) is not null
  and coalesce(original_due_at, due_at) < due_for_check_at
)
where status = 'carried_to_class'
  and due_for_check_at is not null;
