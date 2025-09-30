-- Ensure survey bucket exists (idempotent)
insert into storage.buckets (id, name, public)
values ('survey', 'survey', true)
on conflict (id) do nothing;

-- RLS policies for storage.objects on survey bucket
-- Allow public read (mainly for completeness; public bucket already serves files)
drop policy if exists "survey_read" on storage.objects;
create policy "survey_read"
on storage.objects for select
using (bucket_id = 'survey');

-- Allow authenticated users to upload files to survey bucket
drop policy if exists "survey_insert" on storage.objects;
create policy "survey_insert"
on storage.objects for insert to authenticated
with check (bucket_id = 'survey');

-- Allow authenticated users to update their files in survey bucket
drop policy if exists "survey_update" on storage.objects;
create policy "survey_update"
on storage.objects for update to authenticated
using (bucket_id = 'survey')
with check (bucket_id = 'survey');

-- Allow authenticated users to delete files in survey bucket
drop policy if exists "survey_delete" on storage.objects;
create policy "survey_delete"
on storage.objects for delete to authenticated
using (bucket_id = 'survey');















