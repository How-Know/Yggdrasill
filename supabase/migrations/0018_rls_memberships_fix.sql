-- Fix RLS recursion between academies and memberships
-- Goal: memberships policies must NOT reference academies to avoid recursive policy evaluation

-- memberships: enable RLS (idempotent)
alter table if exists public.memberships enable row level security;

-- Make script idempotent: drop both old and new policy names if present
drop policy if exists "user can select own memberships" on public.memberships;
drop policy if exists "owner can insert membership in own academy" on public.memberships;
drop policy if exists "owner can delete membership in own academy" on public.memberships;
drop policy if exists "user can insert own membership" on public.memberships;
drop policy if exists "user can delete own membership" on public.memberships;

-- Recreate minimal, non-recursive policies on memberships
-- 1) SELECT: each user can read only their own memberships
create policy "user can select own memberships"
on public.memberships
for select
using (
  user_id = auth.uid()
);

-- 2) INSERT: allow inserting only a membership for oneself
--    This unblocks the academies trigger ensure_owner_membership() without referencing academies
create policy "user can insert own membership"
on public.memberships
for insert
with check (
  user_id = auth.uid()
);

-- 3) DELETE: allow deleting only one's own membership
create policy "user can delete own membership"
on public.memberships
for delete
using (
  user_id = auth.uid()
);

-- Note: academies policies remain unchanged. They can reference memberships since
-- memberships policies above are now non-recursive (do not reference academies).


