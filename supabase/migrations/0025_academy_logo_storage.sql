-- 0025: Store academy logos in Supabase Storage instead of bytea
-- - Adds logo_bucket/logo_path/logo_url columns to academy_settings
-- - Creates a private storage bucket `academy-logos`
-- - Adds RLS policies on storage.objects so members of an academy can manage
--   files under the prefix `${academy_id}/...`

-- 1) Extend academy_settings schema (idempotent)
alter table if exists public.academy_settings
  add column if not exists logo_bucket text,
  add column if not exists logo_path text,
  add column if not exists logo_url text;

-- 2) Create storage bucket (idempotent)
insert into storage.buckets (id, name, public)
values ('academy-logos', 'academy-logos', false)
on conflict (id) do nothing;

-- 3) Policies for storage.objects (scoped to academy membership and path prefix)
-- Note: We derive academy_id from the first path segment: split_part(name, '/', 1)::uuid

-- SELECT policy
drop policy if exists "academy logos select" on storage.objects;
create policy "academy logos select" on storage.objects
for select
using (
  bucket_id = 'academy-logos'
  and exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = split_part(name, '/', 1)::uuid
  )
);

-- INSERT policy
drop policy if exists "academy logos insert" on storage.objects;
create policy "academy logos insert" on storage.objects
for insert
with check (
  bucket_id = 'academy-logos'
  and exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = split_part(name, '/', 1)::uuid
  )
);

-- UPDATE policy (allow overwrite/upsert by members)
drop policy if exists "academy logos update" on storage.objects;
create policy "academy logos update" on storage.objects
for update
using (
  bucket_id = 'academy-logos'
  and exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = split_part(name, '/', 1)::uuid
  )
)
with check (
  bucket_id = 'academy-logos'
  and exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = split_part(name, '/', 1)::uuid
  )
);

-- DELETE policy (optional; keep symmetry)
drop policy if exists "academy logos delete" on storage.objects;
create policy "academy logos delete" on storage.objects
for delete
using (
  bucket_id = 'academy-logos'
  and exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = split_part(name, '/', 1)::uuid
  )
);




