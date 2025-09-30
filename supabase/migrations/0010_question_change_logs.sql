-- question change logs

create table if not exists public.question_change_logs (
  id bigserial primary key,
  question_id uuid not null references public.questions(id) on delete cascade,
  action text not null,
  from_value jsonb,
  to_value jsonb,
  created_by uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now()
);

alter table public.question_change_logs enable row level security;

drop policy if exists "Authenticated can read logs" on public.question_change_logs;
create policy "Authenticated can read logs"
on public.question_change_logs for select
using (true);

drop policy if exists "Owners can insert logs" on public.question_change_logs;
create policy "Owners can insert logs"
on public.question_change_logs for insert
with check (auth.uid() is not null);















