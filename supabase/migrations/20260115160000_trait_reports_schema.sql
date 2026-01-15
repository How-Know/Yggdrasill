-- Trait survey report generator schema (snapshots + runs) with cache/repro support.

-- 1) Snapshot header
create table if not exists public.trait_question_snapshots (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) default auth.uid(),
  source text,
  filters_json jsonb not null,
  filters_hash text not null,
  questions_count int not null default 0,
  questions_hash text not null default ''
);

create index if not exists idx_trait_snapshots_filters_hash
on public.trait_question_snapshots(filters_hash);

create index if not exists idx_trait_snapshots_created_at
on public.trait_question_snapshots(created_at desc);

alter table public.trait_question_snapshots enable row level security;

drop policy if exists "Admins read trait_question_snapshots" on public.trait_question_snapshots;
create policy "Admins read trait_question_snapshots"
on public.trait_question_snapshots for select
using (auth.role() = 'authenticated');

drop policy if exists "Admins manage trait_question_snapshots" on public.trait_question_snapshots;
create policy "Admins manage trait_question_snapshots"
on public.trait_question_snapshots for all
using (auth.role() = 'authenticated')
with check (auth.role() = 'authenticated');

-- 2) Snapshot items
create table if not exists public.trait_question_snapshot_items (
  snapshot_id uuid not null references public.trait_question_snapshots(id) on delete cascade,
  question_id uuid not null,
  order_index int not null,
  payload jsonb not null,
  primary key (snapshot_id, question_id)
);

create index if not exists idx_trait_snapshot_items_snapshot
on public.trait_question_snapshot_items(snapshot_id, order_index);

alter table public.trait_question_snapshot_items enable row level security;

drop policy if exists "Admins read trait_question_snapshot_items" on public.trait_question_snapshot_items;
create policy "Admins read trait_question_snapshot_items"
on public.trait_question_snapshot_items for select
using (auth.role() = 'authenticated');

drop policy if exists "Admins manage trait_question_snapshot_items" on public.trait_question_snapshot_items;
create policy "Admins manage trait_question_snapshot_items"
on public.trait_question_snapshot_items for all
using (auth.role() = 'authenticated')
with check (auth.role() = 'authenticated');

-- 3) Report runs
create table if not exists public.trait_report_runs (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) default auth.uid(),
  status text not null check (status in ('queued','running','succeeded','failed')),
  snapshot_id uuid references public.trait_question_snapshots(id) on delete set null,
  filters_hash text not null,
  questions_hash text not null,
  model text,
  prompt_version text not null,
  report_json_path text,
  report_html_path text,
  metrics jsonb,
  error text
);

create index if not exists idx_trait_runs_cache
on public.trait_report_runs(filters_hash, questions_hash, prompt_version, model, created_at desc);

create index if not exists idx_trait_runs_snapshot
on public.trait_report_runs(snapshot_id);

alter table public.trait_report_runs enable row level security;

drop policy if exists "Admins read trait_report_runs" on public.trait_report_runs;
create policy "Admins read trait_report_runs"
on public.trait_report_runs for select
using (auth.role() = 'authenticated');

drop policy if exists "Admins manage trait_report_runs" on public.trait_report_runs;
create policy "Admins manage trait_report_runs"
on public.trait_report_runs for all
using (auth.role() = 'authenticated')
with check (auth.role() = 'authenticated');

-- 4) Reports storage bucket (private)
insert into storage.buckets (id, name, public)
values ('reports', 'reports', false)
on conflict (id) do nothing;

-- Allow authenticated users to read reports bucket objects
drop policy if exists "reports_read_authenticated" on storage.objects;
create policy "reports_read_authenticated"
on storage.objects for select
to authenticated
using (bucket_id = 'reports');

