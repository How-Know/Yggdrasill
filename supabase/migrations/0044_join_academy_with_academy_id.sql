-- 0044: Extend join_academy_by_email to accept optional academy_id

create or replace function public.join_academy_by_email(p_email text, p_academy_id uuid default null)
returns uuid
language plpgsql
security definer
set search_path = public as $$
declare
  uid uuid := auth.uid();
  v_current_email text;
  aid uuid;
  tid uuid;
begin
  if uid is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  if p_email is null or length(trim(p_email)) = 0 then
    raise exception 'email required';
  end if;

  -- Enforce that caller's email matches requested teacher email
  select email into v_current_email from auth.users where id = uid;
  if v_current_email is null or lower(v_current_email) <> lower(p_email) then
    raise exception 'email mismatch';
  end if;

  if p_academy_id is not null then
    -- Prefer teacher in the specified academy (strict email match)
    select p_academy_id, t.id into aid, tid
      from public.teachers t
     where t.academy_id = p_academy_id
       and lower(t.email) = lower(p_email)
     order by t.created_at nulls last
     limit 1;
  end if;

  if aid is null then
    -- Fallback: any teacher with this email
    select t.academy_id, t.id into aid, tid
      from public.teachers t
     where lower(t.email) = lower(p_email)
     order by t.created_at nulls last
     limit 1;
  end if;

  if aid is null or tid is null then
    return null; -- owner must register the teacher first
  end if;

  -- Ensure membership for caller
  insert into public.memberships(academy_id, user_id, role)
  values (aid, uid, 'staff')
  on conflict (academy_id, user_id) do nothing;

  -- Link teacher row to caller
  update public.teachers set user_id = uid where id = tid and (user_id is null or user_id = uid);

  return aid;
end$$;

revoke all on function public.join_academy_by_email(text, uuid) from public;
grant execute on function public.join_academy_by_email(text, uuid) to authenticated;



