-- Allow public (anon) to read active trait questions for the in-app survey.
-- Existing policy already allows authenticated to read all questions.

alter table public.questions enable row level security;

drop policy if exists "Public can read active questions" on public.questions;
create policy "Public can read active questions"
on public.questions for select
using (is_active = true);

