-- 20260325101000_problem_bank_figure_jobs.sql
-- 문제은행 AI 그림 생성 작업 큐

create table if not exists public.pb_figure_jobs (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  document_id uuid not null references public.pb_documents(id) on delete cascade,
  question_id uuid not null references public.pb_questions(id) on delete cascade,
  created_by uuid,
  status text not null default 'queued'
    check (status in (
      'queued',
      'rendering',
      'review_required',
      'completed',
      'failed',
      'cancelled'
    )),
  provider text not null default 'gemini',
  model_name text not null default '',
  options jsonb not null default '{}'::jsonb,
  prompt_text text not null default '',
  result_summary jsonb not null default '{}'::jsonb,
  output_storage_bucket text not null default 'problem-previews',
  output_storage_path text not null default '',
  worker_name text not null default '',
  error_code text not null default '',
  error_message text not null default '',
  started_at timestamptz,
  finished_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_pb_figure_jobs_academy_created
  on public.pb_figure_jobs (academy_id, created_at desc);
create index if not exists idx_pb_figure_jobs_document_created
  on public.pb_figure_jobs (document_id, created_at desc);
create index if not exists idx_pb_figure_jobs_question_created
  on public.pb_figure_jobs (question_id, created_at desc);
create index if not exists idx_pb_figure_jobs_status
  on public.pb_figure_jobs (status);

drop trigger if exists pb_figure_jobs_set_updated_at on public.pb_figure_jobs;
create trigger pb_figure_jobs_set_updated_at
before update on public.pb_figure_jobs
for each row execute function public.set_updated_at();

alter table public.pb_figure_jobs enable row level security;

drop policy if exists "pb_figure_jobs_select" on public.pb_figure_jobs;
drop policy if exists "pb_figure_jobs_insert" on public.pb_figure_jobs;
drop policy if exists "pb_figure_jobs_update" on public.pb_figure_jobs;
drop policy if exists "pb_figure_jobs_delete" on public.pb_figure_jobs;

create policy "pb_figure_jobs_select" on public.pb_figure_jobs
for select using (
  academy_id in (
    select m.academy_id
    from public.memberships m
    where m.user_id = auth.uid()
  )
);

create policy "pb_figure_jobs_insert" on public.pb_figure_jobs
for insert with check (
  academy_id in (
    select m.academy_id
    from public.memberships m
    where m.user_id = auth.uid()
  )
);

create policy "pb_figure_jobs_update" on public.pb_figure_jobs
for update using (
  academy_id in (
    select m.academy_id
    from public.memberships m
    where m.user_id = auth.uid()
  )
);

create policy "pb_figure_jobs_delete" on public.pb_figure_jobs
for delete using (
  academy_id in (
    select m.academy_id
    from public.memberships m
    where m.user_id = auth.uid()
  )
);
