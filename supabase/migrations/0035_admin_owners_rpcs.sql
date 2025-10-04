-- 0035: Admin RPCs - owners listing and block toggle

-- Extend app_users with block flag
alter table if exists public.app_users
  add column if not exists is_blocked boolean not null default false;

-- List owners with teacher counts
create or replace function public.list_owners_with_teacher_counts()
returns table (
  owner_user_id uuid,
  owner_email text,
  academy_id uuid,
  academy_name text,
  teacher_count bigint,
  is_blocked boolean
)
language sql
security definer
set search_path = public as $$
  select
    a.owner_user_id,
    u.email as owner_email,
    a.id as academy_id,
    a.name as academy_name,
    coalesce((select count(*) from public.teachers t where t.academy_id = a.id), 0) as teacher_count,
    coalesce(au.is_blocked, false) as is_blocked
  from public.academies a
  left join auth.users u on u.id = a.owner_user_id
  left join public.app_users au on au.user_id = a.owner_user_id
  order by a.created_at desc;
$$;

revoke all on function public.list_owners_with_teacher_counts() from public;
grant execute on function public.list_owners_with_teacher_counts() to anon, authenticated;

-- Toggle owner block
create or replace function public.set_owner_blocked(p_owner_user_id uuid, p_blocked boolean)
returns void
language plpgsql
security definer
set search_path = public as $$
declare
  caller_is_admin boolean := false;
begin
  select public.is_superadmin() into caller_is_admin;
  if not caller_is_admin then
    raise exception 'insufficient_privilege' using errcode = '42501';
  end if;

  insert into public.app_users(user_id, platform_role, can_create_academy, is_blocked)
  values (p_owner_user_id, 'staff', false, coalesce(p_blocked, false))
  on conflict (user_id) do update set is_blocked = excluded.is_blocked;
end$$;

revoke all on function public.set_owner_blocked(uuid, boolean) from public;
grant execute on function public.set_owner_blocked(uuid, boolean) to authenticated;



