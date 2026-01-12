-- Ensure anon/authenticated can upsert question_answers.
-- Some environments require explicit roles rather than relying on PUBLIC.

alter table public.question_answers enable row level security;

-- Table/sequence privileges (defensive; errors would otherwise be "permission denied", not RLS)
grant insert, update on table public.question_answers to anon, authenticated;
grant usage, select on sequence public.question_answers_id_seq to anon, authenticated;

drop policy if exists "Public insert question_answers" on public.question_answers;
create policy "Public insert question_answers"
on public.question_answers for insert
to anon, authenticated
with check (true);

drop policy if exists "Public update question_answers" on public.question_answers;
create policy "Public update question_answers"
on public.question_answers for update
to anon, authenticated
using (true)
with check (true);

