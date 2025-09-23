-- Responses/answers for trait questions (public insert, private read)

create table if not exists public.question_responses (
  id uuid primary key default gen_random_uuid(),
  participant_id uuid references public.survey_participants(id) on delete set null,
  client_id text,
  user_agent text,
  created_by uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now()
);

create table if not exists public.question_answers (
  id bigserial primary key,
  response_id uuid not null references public.question_responses(id) on delete cascade,
  question_id uuid not null references public.questions(id) on delete cascade,
  answer_text text,
  answer_number numeric
);

alter table public.question_responses enable row level security;
alter table public.question_answers enable row level security;

-- Public can insert; reading is restricted to authenticated users
drop policy if exists "Public insert question_responses" on public.question_responses;
create policy "Public insert question_responses"
on public.question_responses for insert
with check (true);

drop policy if exists "Admin read/manage question_responses" on public.question_responses;
create policy "Admin read/manage question_responses"
on public.question_responses for all
using (auth.role() = 'authenticated')
with check (auth.role() = 'authenticated');

drop policy if exists "Public insert question_answers" on public.question_answers;
create policy "Public insert question_answers"
on public.question_answers for insert
with check (
  exists (select 1 from public.question_responses r where r.id = response_id)
);

drop policy if exists "Admin read/manage question_answers" on public.question_answers;
create policy "Admin read/manage question_answers"
on public.question_answers for all
using (auth.role() = 'authenticated')
with check (auth.role() = 'authenticated');

create index if not exists idx_question_answers_resp on public.question_answers(response_id);
create index if not exists idx_question_answers_question on public.question_answers(question_id);
-- upsert를 위한 유니크 제약 (response_id, question_id 조합은 1회만 존재)
create unique index if not exists uq_question_answers_resp_question on public.question_answers(response_id, question_id);


