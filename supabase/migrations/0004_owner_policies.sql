-- Owner-only authoring policies and owner read-access to results

-- Surveys: only authenticated users can create; only owner can update/delete
create policy if not exists "Auth can create surveys"
on public.surveys for insert
with check (auth.role() = 'authenticated' and created_by = auth.uid());

create policy if not exists "Owner can update surveys"
on public.surveys for update
using (created_by = auth.uid())
with check (created_by = auth.uid());

create policy if not exists "Owner can delete surveys"
on public.surveys for delete
using (created_by = auth.uid());

-- Questions: only owner of parent survey can insert/update/delete
create policy if not exists "Owner can insert questions"
on public.survey_questions for insert
with check (
  exists (
    select 1 from public.surveys s
    where s.id = survey_id and s.created_by = auth.uid()
  )
);

create policy if not exists "Owner can update questions"
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

create policy if not exists "Owner can delete questions"
on public.survey_questions for delete
using (
  exists (
    select 1 from public.surveys s
    where s.id = survey_id and s.created_by = auth.uid()
  )
);

-- Choices: only owner of parent survey can insert/update/delete
create policy if not exists "Owner can insert choices"
on public.survey_choices for insert
with check (
  exists (
    select 1 from public.survey_questions q
    join public.surveys s on s.id = q.survey_id
    where q.id = survey_choices.question_id and s.created_by = auth.uid()
  )
);

create policy if not exists "Owner can update choices"
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

create policy if not exists "Owner can delete choices"
on public.survey_choices for delete
using (
  exists (
    select 1 from public.survey_questions q
    join public.surveys s on s.id = q.survey_id
    where q.id = survey_choices.question_id and s.created_by = auth.uid()
  )
);

-- Results visibility: only owner can read responses/answers
create policy if not exists "Owner can read responses"
on public.survey_responses for select
using (
  exists (
    select 1 from public.surveys s
    where s.id = survey_responses.survey_id and s.created_by = auth.uid()
  )
);

create policy if not exists "Owner can read answers"
on public.survey_answers for select
using (
  exists (
    select 1
    from public.survey_responses r
    join public.surveys s on s.id = r.survey_id
    where r.id = survey_answers.response_id and s.created_by = auth.uid()
  )
);


