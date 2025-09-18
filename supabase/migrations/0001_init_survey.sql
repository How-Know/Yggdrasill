-- Surveys core schema
create table if not exists public.surveys (
  id uuid primary key default gen_random_uuid(),
  slug text unique not null,
  title text not null,
  description text,
  is_public boolean not null default true,
  is_active boolean not null default true,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function public.set_updated_at() returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

drop trigger if exists set_surveys_updated_at on public.surveys;
create trigger set_surveys_updated_at
before update on public.surveys
for each row execute function public.set_updated_at();

-- Questions
create table if not exists public.survey_questions (
  id bigserial primary key,
  survey_id uuid not null references public.surveys(id) on delete cascade,
  question_type text not null check (question_type in ('short_text','long_text','single_choice','multi_choice','number','rating','date')),
  question_text text not null,
  is_required boolean not null default true,
  order_index integer not null default 0
);

-- Choices
create table if not exists public.survey_choices (
  id bigserial primary key,
  question_id bigint not null references public.survey_questions(id) on delete cascade,
  label text not null,
  value text,
  order_index integer not null default 0
);

-- Responses
create table if not exists public.survey_responses (
  id uuid primary key default gen_random_uuid(),
  survey_id uuid not null references public.surveys(id) on delete cascade,
  client_id text,
  user_agent text,
  submitted_at timestamptz not null default now()
);

create unique index if not exists uniq_response_per_client
on public.survey_responses (survey_id, client_id) where client_id is not null;

-- Answers
create table if not exists public.survey_answers (
  id bigserial primary key,
  response_id uuid not null references public.survey_responses(id) on delete cascade,
  question_id bigint not null references public.survey_questions(id) on delete cascade,
  choice_id bigint references public.survey_choices(id) on delete set null,
  answer_text text,
  answer_number numeric,
  answer_json jsonb
);

-- RLS
alter table public.surveys enable row level security;
alter table public.survey_questions enable row level security;
alter table public.survey_choices enable row level security;
alter table public.survey_responses enable row level security;
alter table public.survey_answers enable row level security;

create policy if not exists "Public can read public surveys"
on public.surveys for select
using (is_public = true and is_active = true);

create policy if not exists "Public can read questions of public surveys"
on public.survey_questions for select
using (
  exists (
    select 1 from public.surveys s where s.id = survey_id and s.is_public = true and s.is_active = true
  )
);

create policy if not exists "Public can read choices of public surveys"
on public.survey_choices for select
using (
  exists (
    select 1 from public.survey_questions q
    join public.surveys s on s.id = q.survey_id
    where q.id = question_id and s.is_public = true and s.is_active = true
  )
);

create policy if not exists "Anyone can submit response"
on public.survey_responses for insert
with check (true);

create policy if not exists "Anyone can submit answers"
on public.survey_answers for insert
with check (
  exists (select 1 from public.survey_responses r where r.id = response_id)
);


