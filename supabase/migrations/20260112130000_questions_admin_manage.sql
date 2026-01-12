-- Allow authenticated users (admin UI) to manage questions.
-- Without this, only created_by=auth.uid() can update, so attaching images often fails for other admins.

alter table public.questions enable row level security;

drop policy if exists "Admins manage questions" on public.questions;
create policy "Admins manage questions"
on public.questions for all
using (auth.role() = 'authenticated')
with check (auth.role() = 'authenticated');

