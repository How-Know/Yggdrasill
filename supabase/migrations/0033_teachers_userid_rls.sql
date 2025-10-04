-- 0033: Add teachers.user_id and tighten RLS (owner-only writes)

alter table if exists public.teachers
  add column if not exists user_id uuid references auth.users(id) on delete set null;

create index if not exists idx_teachers_user on public.teachers(user_id);

-- RLS: members can read; only owner can write
alter table public.teachers enable row level security;

drop policy if exists teachers_all on public.teachers;

drop policy if exists teachers_select on public.teachers;
create policy teachers_select on public.teachers
for select
using (
  exists (
    select 1 from public.memberships s
    where s.academy_id = teachers.academy_id and s.user_id = auth.uid()
  )
);

drop policy if exists teachers_insert_owner on public.teachers;
create policy teachers_insert_owner on public.teachers
for insert
with check (
  exists (
    select 1 from public.academies a
    where a.id = teachers.academy_id and a.owner_user_id = auth.uid()
  )
);

drop policy if exists teachers_update_owner on public.teachers;
create policy teachers_update_owner on public.teachers
for update
using (
  exists (
    select 1 from public.academies a
    where a.id = teachers.academy_id and a.owner_user_id = auth.uid()
  )
)
with check (
  exists (
    select 1 from public.academies a
    where a.id = teachers.academy_id and a.owner_user_id = auth.uid()
  )
);

drop policy if exists teachers_delete_owner on public.teachers;
create policy teachers_delete_owner on public.teachers
for delete
using (
  exists (
    select 1 from public.academies a
    where a.id = teachers.academy_id and a.owner_user_id = auth.uid()
  )
);



