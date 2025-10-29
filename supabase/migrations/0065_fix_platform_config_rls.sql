-- Fix platform_config RLS policies
-- Remove old policies that tried to access auth.users table

drop policy if exists "Super admins can read platform config" on platform_config;
drop policy if exists "Super admins can upsert platform config" on platform_config;

-- Create new policies that allow authenticated users
-- (Admin check is done in the app layer via AuthService)

create policy "Authenticated users can read platform config"
  on platform_config for select
  using (auth.role() = 'authenticated');

create policy "Authenticated users can upsert platform config"
  on platform_config for all
  using (auth.role() = 'authenticated')
  with check (auth.role() = 'authenticated');

-- Comment
comment on table platform_config is 'Platform-wide configuration settings (access controlled by app-level admin check)';



