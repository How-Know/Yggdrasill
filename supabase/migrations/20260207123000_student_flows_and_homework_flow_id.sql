-- 20260207123000: student_flows + homework_items.flow_id

-- 1) Student flows table
create table if not exists public.student_flows (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  name text not null,
  enabled boolean not null default false,
  order_index integer,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
create index if not exists idx_student_flows_academy on public.student_flows(academy_id);
create index if not exists idx_student_flows_student on public.student_flows(student_id);
alter table public.student_flows enable row level security;
drop policy if exists student_flows_all on public.student_flows;
create policy student_flows_all on public.student_flows for all
using (exists (select 1 from public.memberships s where s.academy_id = student_flows.academy_id and s.user_id = auth.uid()))
with check (exists (select 1 from public.memberships s where s.academy_id = student_flows.academy_id and s.user_id = auth.uid()));
drop trigger if exists trg_student_flows_audit on public.student_flows;
create trigger trg_student_flows_audit before insert or update on public.student_flows
for each row execute function public._set_audit_fields();

-- 2) Link homework_items to flows
alter table public.homework_items
  add column if not exists flow_id uuid references public.student_flows(id) on delete set null;
create index if not exists idx_homework_items_flow_id on public.homework_items(flow_id);
