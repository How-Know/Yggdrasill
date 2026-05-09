-- User-reported problem bank question issues from the learning app.
-- These are an operational queue, separate from pb_question_revisions
-- which records manager-side edits after review.

create table if not exists public.pb_question_issue_reports (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  question_id uuid not null references public.pb_questions(id) on delete cascade,
  homework_item_id uuid references public.homework_items(id) on delete set null,
  student_id uuid references public.students(id) on delete set null,
  reporter_user_id uuid default auth.uid(),
  issue_types text[] not null default array[]::text[],
  note text not null default '',
  status text not null default 'open',
  resolved_by uuid,
  resolved_at timestamptz,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,

  constraint pb_question_issue_reports_status_chk
    check (status in ('open', 'resolved', 'dismissed')),
  constraint pb_question_issue_reports_issue_types_nonempty_chk
    check (cardinality(issue_types) > 0)
);

create index if not exists idx_pbqir_academy_status_created
  on public.pb_question_issue_reports(academy_id, status, created_at desc);

create index if not exists idx_pbqir_question_status
  on public.pb_question_issue_reports(question_id, status, created_at desc);

create index if not exists idx_pbqir_issue_types_gin
  on public.pb_question_issue_reports using gin(issue_types);

alter table public.pb_question_issue_reports enable row level security;

drop policy if exists pbqir_select on public.pb_question_issue_reports;
create policy pbqir_select on public.pb_question_issue_reports
for select using (
  exists (
    select 1
    from public.memberships m
    where m.academy_id = pb_question_issue_reports.academy_id
      and m.user_id = auth.uid()
  )
);

drop policy if exists pbqir_insert on public.pb_question_issue_reports;
create policy pbqir_insert on public.pb_question_issue_reports
for insert with check (
  exists (
    select 1
    from public.memberships m
    where m.academy_id = pb_question_issue_reports.academy_id
      and m.user_id = auth.uid()
  )
);

drop policy if exists pbqir_update on public.pb_question_issue_reports;
create policy pbqir_update on public.pb_question_issue_reports
for update using (
  exists (
    select 1
    from public.memberships m
    where m.academy_id = pb_question_issue_reports.academy_id
      and m.user_id = auth.uid()
  )
) with check (
  exists (
    select 1
    from public.memberships m
    where m.academy_id = pb_question_issue_reports.academy_id
      and m.user_id = auth.uid()
  )
);

drop trigger if exists trg_pb_question_issue_reports_audit
  on public.pb_question_issue_reports;
create trigger trg_pb_question_issue_reports_audit
before insert or update on public.pb_question_issue_reports
for each row execute function public._set_audit_fields();
