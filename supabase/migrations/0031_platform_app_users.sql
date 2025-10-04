-- 0031: Platform-level app_users and policies

create table if not exists public.app_users (
  user_id uuid primary key references auth.users(id) on delete cascade,
  platform_role text not null check (platform_role in ('superadmin','staff')) default 'staff',
  can_create_academy boolean not null default false,
  limits jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table public.app_users enable row level security;

-- Users can read own row; superadmins can read all
drop policy if exists app_users_select on public.app_users;
create policy app_users_select on public.app_users
for select
using (
  user_id = auth.uid() or exists (
    select 1 from public.app_users a where a.user_id = auth.uid() and a.platform_role = 'superadmin'
  )
);

-- Only superadmins can insert/update/delete app_users
drop policy if exists app_users_insert on public.app_users;
create policy app_users_insert on public.app_users
for insert
with check (
  exists (
    select 1 from public.app_users a where a.user_id = auth.uid() and a.platform_role = 'superadmin'
  )
);

drop policy if exists app_users_update on public.app_users;
create policy app_users_update on public.app_users
for update
using (
  exists (
    select 1 from public.app_users a where a.user_id = auth.uid() and a.platform_role = 'superadmin'
  )
)
with check (
  exists (
    select 1 from public.app_users a where a.user_id = auth.uid() and a.platform_role = 'superadmin'
  )
);

drop policy if exists app_users_delete on public.app_users;
create policy app_users_delete on public.app_users
for delete
using (
  exists (
    select 1 from public.app_users a where a.user_id = auth.uid() and a.platform_role = 'superadmin'
  )
);

-- Note: Initial bootstrap can be done by running a one-off SQL on the server:
-- insert into public.app_users(user_id, platform_role, can_create_academy)
-- select id, 'superadmin', true from auth.users where email = '<YOUR_EMAIL>'
-- on conflict (user_id) do update set platform_role='superadmin', can_create_academy=true;



