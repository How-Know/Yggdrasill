-- Fix RLS for question_answers so public/anon can save answers.
-- Previous policy referenced question_responses in a WITH CHECK, which requires SELECT privilege and fails for anon.
-- Also, upsert requires UPDATE permission; we allow public update to support editing answers during the survey.

alter table public.question_answers enable row level security;

drop policy if exists "Public insert question_answers" on public.question_answers;
create policy "Public insert question_answers"
on public.question_answers for insert
with check (true);

drop policy if exists "Public update question_answers" on public.question_answers;
create policy "Public update question_answers"
on public.question_answers for update
using (true)
with check (true);

