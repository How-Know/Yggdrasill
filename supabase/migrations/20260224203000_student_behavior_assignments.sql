-- 20260224203000: student_behavior_assignments

create table if not exists public.student_behavior_assignments (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  source_behavior_card_id uuid references public.learning_behavior_cards(id) on delete set null,
  name text not null,
  repeat_days integer not null check (repeat_days >= 1),
  is_irregular boolean not null default false,
  level_contents jsonb not null default '[]'::jsonb,
  selected_level_index integer not null default 0 check (selected_level_index >= 0),
  order_index integer not null default 0,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid
);

create index if not exists idx_student_behavior_assignments_academy
  on public.student_behavior_assignments(academy_id);
create index if not exists idx_student_behavior_assignments_student
  on public.student_behavior_assignments(student_id);
create index if not exists idx_student_behavior_assignments_order
  on public.student_behavior_assignments(academy_id, student_id, order_index);

create unique index if not exists uq_student_behavior_assignments_source
  on public.student_behavior_assignments(academy_id, student_id, source_behavior_card_id)
  where source_behavior_card_id is not null;

alter table public.student_behavior_assignments enable row level security;
drop policy if exists student_behavior_assignments_all on public.student_behavior_assignments;
create policy student_behavior_assignments_all on public.student_behavior_assignments for all
using (
  exists (
    select 1
    from public.memberships s
    where s.academy_id = student_behavior_assignments.academy_id
      and s.user_id = auth.uid()
  )
)
with check (
  exists (
    select 1
    from public.memberships s
    where s.academy_id = student_behavior_assignments.academy_id
      and s.user_id = auth.uid()
  )
);

drop trigger if exists trg_student_behavior_assignments_audit on public.student_behavior_assignments;
create trigger trg_student_behavior_assignments_audit
before insert or update on public.student_behavior_assignments
for each row execute function public._set_audit_fields();
