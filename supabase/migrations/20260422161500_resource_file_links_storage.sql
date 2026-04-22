-- 20260422161500: Textbook PDF dual-track storage migration
-- - Adds storage_driver / storage_bucket / storage_key / migration_status / file_size_bytes
--   / content_hash / uploaded_at columns on public.resource_file_links
-- - Creates private storage bucket `textbooks`
-- - Adds RLS policies on storage.objects scoped to academy membership (first path segment)
--
-- Migration strategy: existing rows remain migration_status='legacy' and keep Dropbox `url`.
-- New uploads populate storage_* columns and flip status to 'dual', then later 'migrated'.

-- 1) Extend resource_file_links columns (idempotent)
alter table public.resource_file_links
  add column if not exists storage_driver text,              -- null=legacy | 'supabase' | 'r2'
  add column if not exists storage_bucket text,              -- e.g. 'textbooks'
  add column if not exists storage_key text,                 -- e.g. 'academies/<uuid>/files/<uuid>/<grade>/<kind>.pdf'
  add column if not exists migration_status text not null default 'legacy',
  add column if not exists file_size_bytes bigint,
  add column if not exists content_hash text,                -- sha256 hex
  add column if not exists uploaded_at timestamptz;

-- 2) migration_status check constraint (drop then add to stay idempotent)
alter table public.resource_file_links
  drop constraint if exists resource_file_links_migration_status_chk;
alter table public.resource_file_links
  add constraint resource_file_links_migration_status_chk
  check (migration_status in ('legacy', 'dual', 'migrated'));

-- 3) storage_driver check constraint
alter table public.resource_file_links
  drop constraint if exists resource_file_links_storage_driver_chk;
alter table public.resource_file_links
  add constraint resource_file_links_storage_driver_chk
  check (storage_driver is null or storage_driver in ('supabase', 'r2'));

-- 4) Index on migration_status for dashboard / batch queries
create index if not exists resource_file_links_migration_status_idx
  on public.resource_file_links(migration_status);

-- 5) Create private storage bucket `textbooks` (idempotent)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'textbooks',
  'textbooks',
  false,
  524288000, -- 500MB (covers ~250MB body + margin)
  ARRAY['application/pdf']
)
on conflict (id) do nothing;

-- 6) RLS policies for storage.objects on the textbooks bucket
-- Path convention: academies/<academy_id>/files/<file_id>/<grade_label>/<kind>.pdf
-- The first segment is the academy_id uuid used to gate membership.

-- SELECT (members of the academy only, since bucket is private)
drop policy if exists "textbooks select" on storage.objects;
create policy "textbooks select" on storage.objects
for select
using (
  bucket_id = 'textbooks'
  and exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = split_part(name, '/', 2)::uuid
  )
);

-- INSERT (members of the academy)
drop policy if exists "textbooks insert" on storage.objects;
create policy "textbooks insert" on storage.objects
for insert
with check (
  bucket_id = 'textbooks'
  and exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = split_part(name, '/', 2)::uuid
  )
);

-- UPDATE (allow overwrite/upsert by members)
drop policy if exists "textbooks update" on storage.objects;
create policy "textbooks update" on storage.objects
for update
using (
  bucket_id = 'textbooks'
  and exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = split_part(name, '/', 2)::uuid
  )
)
with check (
  bucket_id = 'textbooks'
  and exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = split_part(name, '/', 2)::uuid
  )
);

-- DELETE (members only; keep symmetry for cleanup / re-upload)
drop policy if exists "textbooks delete" on storage.objects;
create policy "textbooks delete" on storage.objects
for delete
using (
  bucket_id = 'textbooks'
  and exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = split_part(name, '/', 2)::uuid
  )
);
