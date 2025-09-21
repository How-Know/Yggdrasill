-- Owner-only authoring policies and owner read-access to results

-- Surveys: only authenticated users can create; only owner can update/delete
drop policy if exists "Auth can create surveys" on public.surveys;
create policy "Auth can create surveys"
on public.surveys for insert
with check (auth.role() = 'authenticated' and created_by = auth.uid());

drop policy if exists "Owner can update surveys" on public.surveys;
create policy "Owner can update surveys"
on public.surveys for update
using (created_by = auth.uid())
with check (created_by = auth.uid());

drop policy if exists "Owner can delete surveys" on public.surveys;
create policy "Owner can delete surveys"
on public.surveys for delete
using (created_by = auth.uid());

-- Questions: only owner of parent survey can insert/update/delete
drop policy if exists "Owner can insert questions" on public.survey_questions;
create policy "Owner can insert questions"
on public.survey_questions for insert
with check (
  exists (
    select 1 from public.surveys s
    where s.id = survey_id and s.created_by = auth.uid()
  )
);

drop policy if exists "Owner can update questions" on public.survey_questions;
create policy "Owner can update questions"
on public.survey_questions for update
using (
  exists (
    select 1 from public.surveys s
    where s.id = survey_id and s.created_by = auth.uid()
  )
)
with check (
  exists (
    select 1 from public.surveys s
    where s.id = survey_id and s.created_by = auth.uid()
  )
);

drop policy if exists "Owner can delete questions" on public.survey_questions;
create policy "Owner can delete questions"
on public.survey_questions for delete
using (
  exists (
    select 1 from public.surveys s
    where s.id = survey_id and s.created_by = auth.uid()
  )
);

-- Choices: only owner of parent survey can insert/update/delete
drop policy if exists "Owner can insert choices" on public.survey_choices;
create policy "Owner can insert choices"
on public.survey_choices for insert
with check (
  exists (
    select 1 from public.survey_questions q
    join public.surveys s on s.id = q.survey_id
    where q.id = survey_choices.question_id and s.created_by = auth.uid()
  )
);

drop policy if exists "Owner can update choices" on public.survey_choices;
create policy "Owner can update choices"
on public.survey_choices for update
using (
  exists (
    select 1 from public.survey_questions q
    join public.surveys s on s.id = q.survey_id
    where q.id = survey_choices.question_id and s.created_by = auth.uid()
  )
)
with check (
  exists (
    select 1 from public.survey_questions q
    join public.surveys s on s.id = q.survey_id
    where q.id = survey_choices.question_id and s.created_by = auth.uid()
  )
);

drop policy if exists "Owner can delete choices" on public.survey_choices;
create policy "Owner can delete choices"
on public.survey_choices for delete
using (
  exists (
    select 1 from public.survey_questions q
    join public.surveys s on s.id = q.survey_id
    where q.id = survey_choices.question_id and s.created_by = auth.uid()
  )
);

-- Results visibility: only owner can read responses/answers
drop policy if exists "Owner can read responses" on public.survey_responses;
create policy "Owner can read responses"
on public.survey_responses for select
using (
  exists (
    select 1 from public.surveys s
    where s.id = survey_responses.survey_id and s.created_by = auth.uid()
  )
);

drop policy if exists "Owner can read answers" on public.survey_answers;
create policy "Owner can read answers"
on public.survey_answers for select
using (
  exists (
    select 1
    from public.survey_responses r
    join public.surveys s on s.id = r.survey_id
    where r.id = survey_answers.response_id and s.created_by = auth.uid()
  )
);


