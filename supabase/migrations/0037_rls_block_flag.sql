-- 0037: Enforce block flag in RLS (read & write)

-- Helper condition: not blocked
create or replace function public._not_blocked()
returns boolean
language sql
security definer
set search_path = public as $$
  select not coalesce((select is_blocked from public.app_users where user_id = auth.uid()), false);
$$;

revoke all on function public._not_blocked() from public;
grant execute on function public._not_blocked() to anon, authenticated;

-- Apply to key tables (examples below). You can extend this to all tenant tables similarly.

drop policy if exists groups_all on public.groups;
create policy groups_all on public.groups for all
using ( public._not_blocked() and exists (select 1 from public.memberships s where s.academy_id = groups.academy_id and s.user_id = auth.uid()) )
with check ( public._not_blocked() and exists (select 1 from public.memberships s where s.academy_id = groups.academy_id and s.user_id = auth.uid()) );

drop policy if exists classes_all on public.classes;
create policy classes_all on public.classes for all
using ( public._not_blocked() and exists (select 1 from public.memberships s where s.academy_id = classes.academy_id and s.user_id = auth.uid()) )
with check ( public._not_blocked() and exists (select 1 from public.memberships s where s.academy_id = classes.academy_id and s.user_id = auth.uid()) );

drop policy if exists operating_hours_all on public.operating_hours;
create policy operating_hours_all on public.operating_hours for all
using ( public._not_blocked() and exists (select 1 from public.memberships s where s.academy_id = operating_hours.academy_id and s.user_id = auth.uid()) )
with check ( public._not_blocked() and exists (select 1 from public.memberships s where s.academy_id = operating_hours.academy_id and s.user_id = auth.uid()) );

drop policy if exists kakao_reservations_all on public.kakao_reservations;
create policy kakao_reservations_all on public.kakao_reservations for all
using ( public._not_blocked() and exists (select 1 from public.memberships s where s.academy_id = kakao_reservations.academy_id and s.user_id = auth.uid()) )
with check ( public._not_blocked() and exists (select 1 from public.memberships s where s.academy_id = kakao_reservations.academy_id and s.user_id = auth.uid()) );

drop policy if exists teachers_select on public.teachers;
create policy teachers_select on public.teachers for select
using ( public._not_blocked() and exists (select 1 from public.memberships s where s.academy_id = teachers.academy_id and s.user_id = auth.uid()) );

drop policy if exists teachers_insert_owner on public.teachers;
create policy teachers_insert_owner on public.teachers for insert
with check ( public._not_blocked() and exists (select 1 from public.academies a where a.id = teachers.academy_id and a.owner_user_id = auth.uid()) );

drop policy if exists teachers_update_owner on public.teachers;
create policy teachers_update_owner on public.teachers for update
using ( public._not_blocked() and exists (select 1 from public.academies a where a.id = teachers.academy_id and a.owner_user_id = auth.uid()) )
with check ( public._not_blocked() and exists (select 1 from public.academies a where a.id = teachers.academy_id and a.owner_user_id = auth.uid()) );

drop policy if exists teachers_delete_owner on public.teachers;
create policy teachers_delete_owner on public.teachers for delete
using ( public._not_blocked() and exists (select 1 from public.academies a where a.id = teachers.academy_id and a.owner_user_id = auth.uid()) );


