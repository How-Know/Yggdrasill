-- Security hardening: stricter constraints, input validation, rate limiting hooks (lightweight)

-- 1) Slug validation: only lowercase letters, digits, hyphen
alter table public.surveys
  add constraint surveys_slug_format
  check (slug ~ '^[a-z0-9-]{3,64}$');

-- 2) Prevent empty question text
alter table public.survey_questions
  add constraint survey_questions_nonempty
  check (length(trim(question_text)) > 0);

-- 3) Ensure order_index non-negative
alter table public.survey_questions
  add constraint survey_questions_order_nonneg
  check (order_index >= 0);

alter table public.survey_choices
  add constraint survey_choices_order_nonneg
  check (order_index >= 0);

-- 4) Basic size limits to mitigate abuse
alter table public.survey_answers
  add constraint survey_answers_text_len
  check (answer_text is null or length(answer_text) <= 2000);

-- 5) Public read only when active
drop policy if exists "Public can read public surveys" on public.surveys;
create policy "Public can read public surveys"
on public.surveys for select
using (is_public = true and is_active = true);

-- 6) Only active & public survey's questions/choices are selectable
drop policy if exists "Public can read questions of public surveys" on public.survey_questions;
create policy "Public can read questions of public surveys"
on public.survey_questions for select
using (
  exists (
    select 1 from public.surveys s
    where s.id = survey_id and s.is_public = true and s.is_active = true
  )
);

drop policy if exists "Public can read choices of public surveys" on public.survey_choices;
create policy "Public can read choices of public surveys"
on public.survey_choices for select
using (
  exists (
    select 1 from public.survey_questions q
    join public.surveys s on s.id = q.survey_id
    where q.id = question_id and s.is_public = true and s.is_active = true
  )
);

-- 7) Limit answers insertion to questions within the same survey as response
drop policy if exists "Anyone can submit answers" on public.survey_answers;
create policy "Anyone can submit answers"
on public.survey_answers for insert
with check (
  exists (
    select 1
    from public.survey_responses r
    join public.survey_questions q on q.id = survey_answers.question_id
    where r.id = survey_answers.response_id
      and r.survey_id = q.survey_id
  )
);

-- 8) Optional: simple rate limit per client per survey (max 1 per 5 minutes)
-- Commented out by default; uncomment to enable
-- create or replace function public.prevent_rapid_resubmission() returns trigger as $$
-- begin
--   if exists (
--     select 1 from public.survey_responses r
--     where r.survey_id = new.survey_id
--       and r.client_id = new.client_id
--       and r.submitted_at > now() - interval '5 minutes'
--   ) then
--     raise exception 'Too many submissions. Please wait and try again.' using errcode = 'P0001';
--   end if;
--   return new;
-- end;
-- $$ language plpgsql;
-- drop trigger if exists prevent_rapid_resubmission on public.survey_responses;
-- create trigger prevent_rapid_resubmission
-- before insert on public.survey_responses
-- for each row execute function public.prevent_rapid_resubmission();


