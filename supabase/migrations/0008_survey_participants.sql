-- Survey participants (basic info collected before starting a survey)

create table if not exists public.survey_participants (
  id uuid primary key default gen_random_uuid(),
  survey_id uuid not null references public.surveys(id) on delete cascade,
  client_id text,
  name text not null,
  email text,
  level text check (level in ('elementary','middle','high')),
  grade text,
  school text,
  student_phone text,
  parent_phone text,
  created_by uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now()
);

alter table public.survey_participants enable row level security;

-- Anyone may insert basic info for public/active surveys
drop policy if exists "Anyone can insert participants" on public.survey_participants;
create policy "Anyone can insert participants"
on public.survey_participants for insert
with check (
  exists (
    select 1 from public.surveys s
    where s.id = survey_id and s.is_public = true and s.is_active = true
  )
);

-- Only authenticated users (admins) can read/update/delete
drop policy if exists "Admins read participants" on public.survey_participants;
create policy "Admins read participants"
on public.survey_participants for select
using (auth.role() = 'authenticated');

drop policy if exists "Admins manage participants" on public.survey_participants;
create policy "Admins manage participants"
on public.survey_participants for all
using (auth.role() = 'authenticated')
with check (auth.role() = 'authenticated');

create index if not exists idx_survey_participants_survey on public.survey_participants(survey_id);
create index if not exists idx_survey_participants_client on public.survey_participants(client_id);
















