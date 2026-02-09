-- 20260209123000: homework_assignment_checks for progress history

create table if not exists public.homework_assignment_checks (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  homework_item_id uuid not null references public.homework_items(id) on delete cascade,
  assignment_id uuid references public.homework_assignments(id) on delete set null,
  progress integer not null default 0,
  checked_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid
);

create index if not exists idx_hw_assignment_checks_academy
  on public.homework_assignment_checks(academy_id);
create index if not exists idx_hw_assignment_checks_student_item
  on public.homework_assignment_checks(student_id, homework_item_id);
create index if not exists idx_hw_assignment_checks_assignment
  on public.homework_assignment_checks(assignment_id);

alter table public.homework_assignment_checks enable row level security;
drop policy if exists homework_assignment_checks_all on public.homework_assignment_checks;
create policy homework_assignment_checks_all on public.homework_assignment_checks for all
using (
  exists (
    select 1
    from public.memberships s
    where s.academy_id = homework_assignment_checks.academy_id
      and s.user_id = auth.uid()
  )
)
with check (
  exists (
    select 1
    from public.memberships s
    where s.academy_id = homework_assignment_checks.academy_id
      and s.user_id = auth.uid()
  )
);

drop trigger if exists trg_hw_assignment_checks_audit on public.homework_assignment_checks;
create trigger trg_hw_assignment_checks_audit before insert or update on public.homework_assignment_checks
for each row execute function public._set_audit_fields();
