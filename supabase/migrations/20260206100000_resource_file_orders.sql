-- Resource file ordering table (per scope/category/parent)
create table if not exists public.resource_file_orders (
  academy_id uuid not null references public.academies(id) on delete cascade,
  scope_type text not null,
  category text not null,
  parent_id text not null default '',
  file_id uuid not null references public.resource_files(id) on delete cascade,
  order_index integer,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  primary key (academy_id, scope_type, category, parent_id, file_id)
);

create index if not exists idx_resource_file_orders_scope
  on public.resource_file_orders(academy_id, scope_type, category, parent_id, order_index);

alter table public.resource_file_orders enable row level security;

drop trigger if exists trg_resource_file_orders_audit on public.resource_file_orders;
create trigger trg_resource_file_orders_audit before insert or update on public.resource_file_orders
for each row execute function public._set_audit_fields();

drop policy if exists resource_file_orders_select on public.resource_file_orders;
create policy resource_file_orders_select on public.resource_file_orders for select
using (exists (
  select 1 from public.memberships s
  where s.academy_id = resource_file_orders.academy_id and s.user_id = auth.uid()
));

drop policy if exists resource_file_orders_ins on public.resource_file_orders;
create policy resource_file_orders_ins on public.resource_file_orders for insert
with check (exists (
  select 1 from public.memberships s
  where s.academy_id = resource_file_orders.academy_id and s.user_id = auth.uid()
));

drop policy if exists resource_file_orders_upd on public.resource_file_orders;
create policy resource_file_orders_upd on public.resource_file_orders for update
using (exists (
  select 1 from public.memberships s
  where s.academy_id = resource_file_orders.academy_id and s.user_id = auth.uid()
))
with check (exists (
  select 1 from public.memberships s
  where s.academy_id = resource_file_orders.academy_id and s.user_id = auth.uid()
));

drop policy if exists resource_file_orders_del on public.resource_file_orders;
create policy resource_file_orders_del on public.resource_file_orders for delete
using (exists (
  select 1 from public.memberships s
  where s.academy_id = resource_file_orders.academy_id and s.user_id = auth.uid()
));
