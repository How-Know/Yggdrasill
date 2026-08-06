-- PostgreSQL runs same-timing triggers alphabetically. Ensure due_at is derived first.

drop trigger if exists trg_homework_assignment_set_original_due_at
  on public.homework_assignments;
drop trigger if exists trg_zz_homework_assignment_set_original_due_at
  on public.homework_assignments;
create trigger trg_zz_homework_assignment_set_original_due_at
before insert or update of due_at, original_due_at
on public.homework_assignments
for each row execute function public._homework_assignment_set_original_due_at();

update public.homework_assignments
set original_due_at = due_at
where original_due_at is null
  and due_at is not null;
