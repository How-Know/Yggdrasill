-- 0032: RPC is_superadmin() to check platform role via SECURITY DEFINER

create or replace function public.is_superadmin()
returns boolean
language plpgsql
security definer
set search_path = public as $$
declare
  uid uuid;
  ok boolean := false;
begin
  uid := auth.uid();
  if uid is null then
    return false;
  end if;
  begin
    select exists (
      select 1 from public.app_users u
      where u.user_id = uid and u.platform_role = 'superadmin'
    ) into ok;
  exception when others then
    -- if table missing, return false
    ok := false;
  end;
  return ok;
end$$;

revoke all on function public.is_superadmin() from public;
grant execute on function public.is_superadmin() to anon, authenticated;



