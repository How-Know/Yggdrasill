-- 0043: RPC set_my_pin(p_pin_hash, p_email) to update only caller's teacher.pin_hash

create or replace function public.set_my_pin(p_pin_hash text, p_email text default null)
returns void
language sql
security definer
set search_path = public as $$
  -- Allow only authenticated users
  select 1 where auth.uid() is not null;

  -- Update teacher row linked to current user, or fallback by email within caller's memberships
  update public.teachers t
     set pin_hash = p_pin_hash
   where (
           t.user_id = auth.uid()
         )
      or (
           p_email is not null
       and lower(t.email) = lower(p_email)
       and exists (
             select 1 from public.memberships m
              where m.academy_id = t.academy_id
                and m.user_id = auth.uid()
           )
         );
$$;

revoke all on function public.set_my_pin(text, text) from public;
grant execute on function public.set_my_pin(text, text) to authenticated;






