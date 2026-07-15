-- Allow authenticated academy members to sign/download unified answer renders.
--
-- Unified assets use `academies/<source_kind>/<source_id>/...`, so the old
-- policy incorrectly treated the second path segment as academy_id. Authorize
-- through the RLS-protected metadata row instead of parsing the object path.

drop policy if exists "answer_renders select" on storage.objects;
create policy "answer_renders select" on storage.objects
for select
using (
  bucket_id = 'answer-renders'
  and exists (
    select 1
    from public.answer_render_assets a
    join public.memberships m
      on m.academy_id = a.academy_id
     and m.user_id = auth.uid()
    where a.storage_bucket = storage.objects.bucket_id
      and a.storage_path = storage.objects.name
  )
);
