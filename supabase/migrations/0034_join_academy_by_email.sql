-- 0034: RPC join_academy_by_email(email) to link current user to teachers/memberships

create or replace function public.join_academy_by_email(p_email text)
returns uuid
language plpgsql
security definer
set search_path = public as $$
declare
  uid uuid := auth.uid();
  aid uuid;
  tid uuid;
begin
  if uid is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  if p_email is null or length(trim(p_email)) = 0 then
    raise exception 'email required';
  end if;

  -- Find teacher by email within any academy the caller already belongs to; otherwise, try all academies
  select t.academy_id, t.id into aid, tid
  from public.teachers t
  where lower(t.email) = lower(p_email)
  order by t.created_at nulls last
  limit 1;

  if aid is null then
    return null; -- no teacher match; caller will need owner to add
  end if;

  -- Ensure membership
  insert into public.memberships(academy_id, user_id, role)
  values (aid, uid, 'staff')
  on conflict (academy_id, user_id) do nothing;

  -- Link teacher row
  update public.teachers set user_id = uid where id = tid and (user_id is null or user_id = uid);

  return aid;
end$$;

revoke all on function public.join_academy_by_email(text) from public;
grant execute on function public.join_academy_by_email(text) to authenticated;



