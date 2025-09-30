-- Academies: allow owner to select own rows (without membership), and add RPC to ensure academy

-- Make idempotent on re-run
drop policy if exists "members can select academy" on public.academies;
drop policy if exists "members or owner can select academy" on public.academies;
create policy "members or owner can select academy"
on public.academies
for select
using (
  exists (
    select 1 from public.memberships m
    where m.academy_id = academies.id and m.user_id = auth.uid()
  )
  or academies.owner_user_id = auth.uid()
);

-- 2) RPC: ensure_academy() - returns existing or creates a new academy for current user
create or replace function public.ensure_academy()
returns uuid
language plpgsql
security definer
set search_path = public as $$
declare
  uid uuid := auth.uid();
  aid uuid;
begin
  if uid is null then
    raise exception 'No authenticated user';
  end if;

  select id into aid from public.academies where owner_user_id = uid limit 1;
  if aid is null then
    insert into public.academies (name, owner_user_id)
    values ('내 학원', uid)
    returning id into aid;
  end if;
  return aid;
end$$;

grant execute on function public.ensure_academy() to authenticated;


