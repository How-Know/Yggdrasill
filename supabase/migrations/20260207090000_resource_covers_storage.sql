-- 20260207090000: Resource cover images storage bucket + policies
-- - Creates a public storage bucket `resource-covers`
-- - Adds RLS policies on storage.objects scoped to academy membership

-- 1) Create storage bucket (idempotent)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'resource-covers',
  'resource-covers',
  true,
  10485760, -- 10MB
  ARRAY['image/png', 'image/jpeg', 'image/jpg', 'image/webp', 'image/gif']
)
on conflict (id) do nothing;

-- 2) Policies for storage.objects
-- Note: We derive academy_id from the first path segment: split_part(name, '/', 1)::uuid

-- SELECT policy (public read)
drop policy if exists "resource covers select" on storage.objects;
create policy "resource covers select" on storage.objects
for select
using (
  bucket_id = 'resource-covers'
);

-- INSERT policy (members of the academy)
drop policy if exists "resource covers insert" on storage.objects;
create policy "resource covers insert" on storage.objects
for insert
with check (
  bucket_id = 'resource-covers'
  and exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = split_part(name, '/', 1)::uuid
  )
);

-- UPDATE policy (allow overwrite/upsert by members)
drop policy if exists "resource covers update" on storage.objects;
create policy "resource covers update" on storage.objects
for update
using (
  bucket_id = 'resource-covers'
  and exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = split_part(name, '/', 1)::uuid
  )
)
with check (
  bucket_id = 'resource-covers'
  and exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = split_part(name, '/', 1)::uuid
  )
);

-- DELETE policy (optional; keep symmetry)
drop policy if exists "resource covers delete" on storage.objects;
create policy "resource covers delete" on storage.objects
for delete
using (
  bucket_id = 'resource-covers'
  and exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = split_part(name, '/', 1)::uuid
  )
);
