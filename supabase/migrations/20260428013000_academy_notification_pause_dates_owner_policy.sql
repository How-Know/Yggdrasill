-- Allow academy owners as well as membership users to manage notification pause dates.

drop policy if exists academy_notification_pause_dates_all
  on public.academy_notification_pause_dates;

create policy academy_notification_pause_dates_all
  on public.academy_notification_pause_dates
  for all
  using (
    exists (
      select 1
      from public.memberships m
      where m.academy_id = academy_notification_pause_dates.academy_id
        and m.user_id = auth.uid()
    )
    or exists (
      select 1
      from public.academies a
      where a.id = academy_notification_pause_dates.academy_id
        and a.owner_user_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1
      from public.memberships m
      where m.academy_id = academy_notification_pause_dates.academy_id
        and m.user_id = auth.uid()
    )
    or exists (
      select 1
      from public.academies a
      where a.id = academy_notification_pause_dates.academy_id
        and a.owner_user_id = auth.uid()
    )
  );
-- Allow academy owners as well as membership users to manage notification pause dates.

drop policy if exists academy_notification_pause_dates_all
  on public.academy_notification_pause_dates;

create policy academy_notification_pause_dates_all
  on public.academy_notification_pause_dates
  for all
  using (
    exists (
      select 1
      from public.memberships m
      where m.academy_id = academy_notification_pause_dates.academy_id
        and m.user_id = auth.uid()
    )
    or exists (
      select 1
      from public.academies a
      where a.id = academy_notification_pause_dates.academy_id
        and a.owner_user_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1
      from public.memberships m
      where m.academy_id = academy_notification_pause_dates.academy_id
        and m.user_id = auth.uid()
    )
    or exists (
      select 1
      from public.academies a
      where a.id = academy_notification_pause_dates.academy_id
        and a.owner_user_id = auth.uid()
    )
  );
