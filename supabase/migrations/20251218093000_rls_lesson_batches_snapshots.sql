-- Enable RLS on newly added tables (snapshots, batches)
alter table public.lesson_snapshot_headers enable row level security;
alter table public.lesson_snapshot_blocks  enable row level security;
alter table public.lesson_batch_headers    enable row level security;
alter table public.lesson_batch_sessions   enable row level security;

-- =====================================================================
-- lesson_snapshot_headers
-- =====================================================================
drop policy if exists "select own snapshot headers" on public.lesson_snapshot_headers;
drop policy if exists "all own snapshot headers" on public.lesson_snapshot_headers;

create policy "select own snapshot headers" on public.lesson_snapshot_headers
  for select
  using (
    exists (
      select 1
      from public.memberships m
      where m.academy_id = lesson_snapshot_headers.academy_id
        and m.user_id = auth.uid()
    )
  );

create policy "all own snapshot headers" on public.lesson_snapshot_headers
  for all
  using (
    exists (
      select 1
      from public.memberships m
      where m.academy_id = lesson_snapshot_headers.academy_id
        and m.user_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1
      from public.memberships m
      where m.academy_id = lesson_snapshot_headers.academy_id
        and m.user_id = auth.uid()
    )
  );

-- =====================================================================
-- lesson_snapshot_blocks (link to headers via snapshot_id)
-- =====================================================================
drop policy if exists "select own snapshot blocks" on public.lesson_snapshot_blocks;
drop policy if exists "all own snapshot blocks" on public.lesson_snapshot_blocks;

create policy "select own snapshot blocks" on public.lesson_snapshot_blocks
  for select
  using (
    exists (
      select 1
      from public.lesson_snapshot_headers h
      join public.memberships m on m.academy_id = h.academy_id
      where h.id = lesson_snapshot_blocks.snapshot_id
        and m.user_id = auth.uid()
    )
  );

create policy "all own snapshot blocks" on public.lesson_snapshot_blocks
  for all
  using (
    exists (
      select 1
      from public.lesson_snapshot_headers h
      join public.memberships m on m.academy_id = h.academy_id
      where h.id = lesson_snapshot_blocks.snapshot_id
        and m.user_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1
      from public.lesson_snapshot_headers h
      join public.memberships m on m.academy_id = h.academy_id
      where h.id = lesson_snapshot_blocks.snapshot_id
        and m.user_id = auth.uid()
    )
  );

-- =====================================================================
-- lesson_batch_headers
-- =====================================================================
drop policy if exists "select own batch headers" on public.lesson_batch_headers;
drop policy if exists "all own batch headers" on public.lesson_batch_headers;

create policy "select own batch headers" on public.lesson_batch_headers
  for select
  using (
    exists (
      select 1
      from public.memberships m
      where m.academy_id = lesson_batch_headers.academy_id
        and m.user_id = auth.uid()
    )
  );

create policy "all own batch headers" on public.lesson_batch_headers
  for all
  using (
    exists (
      select 1
      from public.memberships m
      where m.academy_id = lesson_batch_headers.academy_id
        and m.user_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1
      from public.memberships m
      where m.academy_id = lesson_batch_headers.academy_id
        and m.user_id = auth.uid()
    )
  );

-- =====================================================================
-- lesson_batch_sessions (link to batch headers via batch_id)
-- =====================================================================
drop policy if exists "select own batch sessions" on public.lesson_batch_sessions;
drop policy if exists "all own batch sessions" on public.lesson_batch_sessions;

create policy "select own batch sessions" on public.lesson_batch_sessions
  for select
  using (
    exists (
      select 1
      from public.lesson_batch_headers h
      join public.memberships m on m.academy_id = h.academy_id
      where h.id = lesson_batch_sessions.batch_id
        and m.user_id = auth.uid()
    )
  );

create policy "all own batch sessions" on public.lesson_batch_sessions
  for all
  using (
    exists (
      select 1
      from public.lesson_batch_headers h
      join public.memberships m on m.academy_id = h.academy_id
      where h.id = lesson_batch_sessions.batch_id
        and m.user_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1
      from public.lesson_batch_headers h
      join public.memberships m on m.academy_id = h.academy_id
      where h.id = lesson_batch_sessions.batch_id
        and m.user_id = auth.uid()
    )
  );



