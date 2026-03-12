-- 20260312100000: homework_groups + homework_group_items

create table if not exists public.homework_groups (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  title text not null default '과제 그룹',
  flow_id uuid,
  order_index integer not null default 0,
  status text not null default 'active',
  source_homework_item_id uuid references public.homework_items(id) on delete set null,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  constraint chk_homework_groups_status
    check (status in ('active', 'archived'))
);

create index if not exists idx_homework_groups_student_order
  on public.homework_groups(academy_id, student_id, order_index);

create index if not exists idx_homework_groups_flow
  on public.homework_groups(academy_id, flow_id);

create unique index if not exists uidx_homework_groups_source_item
  on public.homework_groups(academy_id, source_homework_item_id)
  where source_homework_item_id is not null;

alter table public.homework_groups enable row level security;

drop policy if exists homework_groups_all on public.homework_groups;
create policy homework_groups_all on public.homework_groups for all
using (
  exists (
    select 1
    from public.memberships s
    where s.academy_id = homework_groups.academy_id
      and s.user_id = auth.uid()
  )
)
with check (
  exists (
    select 1
    from public.memberships s
    where s.academy_id = homework_groups.academy_id
      and s.user_id = auth.uid()
  )
);

drop trigger if exists trg_homework_groups_audit on public.homework_groups;
create trigger trg_homework_groups_audit before insert or update on public.homework_groups
for each row execute function public._set_audit_fields();

create table if not exists public.homework_group_items (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  group_id uuid not null references public.homework_groups(id) on delete cascade,
  homework_item_id uuid not null references public.homework_items(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  item_order_index integer not null default 0,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid
);

create unique index if not exists uidx_homework_group_items_item
  on public.homework_group_items(academy_id, homework_item_id);

create index if not exists idx_homework_group_items_group_order
  on public.homework_group_items(academy_id, group_id, item_order_index);

create index if not exists idx_homework_group_items_student
  on public.homework_group_items(academy_id, student_id);

alter table public.homework_group_items enable row level security;

drop policy if exists homework_group_items_all on public.homework_group_items;
create policy homework_group_items_all on public.homework_group_items for all
using (
  exists (
    select 1
    from public.memberships s
    where s.academy_id = homework_group_items.academy_id
      and s.user_id = auth.uid()
  )
)
with check (
  exists (
    select 1
    from public.memberships s
    where s.academy_id = homework_group_items.academy_id
      and s.user_id = auth.uid()
  )
);

drop trigger if exists trg_homework_group_items_audit on public.homework_group_items;
create trigger trg_homework_group_items_audit before insert or update on public.homework_group_items
for each row execute function public._set_audit_fields();

-- Backfill: 기존 homework_items -> 1:1 그룹 자동 생성
insert into public.homework_groups (
  academy_id,
  student_id,
  title,
  flow_id,
  order_index,
  status,
  source_homework_item_id
)
select
  h.academy_id,
  h.student_id,
  coalesce(nullif(trim(h.title), ''), '과제 그룹') as title,
  h.flow_id,
  coalesce(h.order_index, 0) as order_index,
  'active' as status,
  h.id as source_homework_item_id
from public.homework_items h
where h.student_id is not null
  and not exists (
    select 1
    from public.homework_group_items gi
    where gi.academy_id = h.academy_id
      and gi.homework_item_id = h.id
  )
  and not exists (
    select 1
    from public.homework_groups g
    where g.academy_id = h.academy_id
      and g.source_homework_item_id = h.id
  );

insert into public.homework_group_items (
  academy_id,
  group_id,
  homework_item_id,
  student_id,
  item_order_index
)
select
  h.academy_id,
  g.id as group_id,
  h.id as homework_item_id,
  h.student_id,
  0 as item_order_index
from public.homework_items h
join public.homework_groups g
  on g.academy_id = h.academy_id
 and g.source_homework_item_id = h.id
where h.student_id is not null
  and not exists (
    select 1
    from public.homework_group_items gi
    where gi.academy_id = h.academy_id
      and gi.homework_item_id = h.id
  );
