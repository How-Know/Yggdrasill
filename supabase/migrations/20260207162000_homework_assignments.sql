-- 20260207162000: homework_assignments history table

create table if not exists public.homework_assignments (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  homework_item_id uuid not null references public.homework_items(id) on delete cascade,
  assigned_at timestamptz not null default now(),
  due_date date,
  status text not null default 'assigned',
  carry_over_from_id uuid references public.homework_assignments(id) on delete set null,
  note text,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
create index if not exists idx_homework_assignments_academy on public.homework_assignments(academy_id);
create index if not exists idx_homework_assignments_student on public.homework_assignments(student_id);
create index if not exists idx_homework_assignments_item on public.homework_assignments(homework_item_id);
alter table public.homework_assignments enable row level security;
drop policy if exists homework_assignments_all on public.homework_assignments;
create policy homework_assignments_all on public.homework_assignments for all
using (exists (select 1 from public.memberships s where s.academy_id = homework_assignments.academy_id and s.user_id = auth.uid()))
with check (exists (select 1 from public.memberships s where s.academy_id = homework_assignments.academy_id and s.user_id = auth.uid()));
drop trigger if exists trg_homework_assignments_audit on public.homework_assignments;
create trigger trg_homework_assignments_audit before insert or update on public.homework_assignments
for each row execute function public._set_audit_fields();
