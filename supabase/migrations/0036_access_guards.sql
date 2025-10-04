-- 0036: Access guard RPCs (blocked / teacher email allow)

create or replace function public.is_user_blocked()
returns boolean
language sql
security definer
set search_path = public as $$
  select coalesce((
    select is_blocked from public.app_users where user_id = auth.uid()
  ), false);
$$;

revoke all on function public.is_user_blocked() from public;
grant execute on function public.is_user_blocked() to anon, authenticated;

create or replace function public.is_teacher_email_allowed(p_email text)
returns boolean
language sql
security definer
set search_path = public as $$
  select exists (
    select 1 from public.teachers t
    where lower(t.email) = lower(coalesce(p_email,''))
  ) and not coalesce((
    select is_blocked from public.app_users where user_id = auth.uid()
  ), false);
$$;

revoke all on function public.is_teacher_email_allowed(text) from public;
grant execute on function public.is_teacher_email_allowed(text) to anon, authenticated;


