-- 20260324193000_problem_bank_pipeline.sql
-- HWPX 문제은행 1차 파이프라인 스키마/스토리지/RLS

-- Storage buckets
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'problem-documents',
  'problem-documents',
  false,
  104857600, -- 100MB
  array[
    'application/octet-stream',
    'application/zip',
    'application/x-zip-compressed',
    'application/haansofthwpx'
  ]
)
on conflict (id) do nothing;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'problem-exports',
  'problem-exports',
  false,
  52428800, -- 50MB
  array['application/pdf']
)
on conflict (id) do nothing;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'problem-previews',
  'problem-previews',
  false,
  10485760, -- 10MB
  array['image/png', 'image/jpeg', 'image/jpg', 'image/webp']
)
on conflict (id) do nothing;

-- Documents (원본 HWPX)
create table if not exists public.pb_documents (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  created_by uuid,
  source_filename text not null default '',
  source_storage_bucket text not null default 'problem-documents',
  source_storage_path text not null,
  source_sha256 text not null default '',
  source_size_bytes bigint not null default 0,
  status text not null default 'uploaded'
    check (status in (
      'uploaded',
      'extract_queued',
      'extracting',
      'review_required',
      'ready',
      'failed',
      'archived'
    )),
  exam_profile text not null default 'naesin'
    check (exam_profile in ('naesin', 'csat', 'mock')),
  meta jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_pb_documents_academy_created
  on public.pb_documents (academy_id, created_at desc);
create index if not exists idx_pb_documents_status
  on public.pb_documents (status);

-- Extract jobs (비동기 추출 작업)
create table if not exists public.pb_extract_jobs (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  document_id uuid not null references public.pb_documents(id) on delete cascade,
  created_by uuid,
  status text not null default 'queued'
    check (status in (
      'queued',
      'extracting',
      'review_required',
      'completed',
      'failed',
      'cancelled'
    )),
  retry_count integer not null default 0 check (retry_count >= 0),
  max_retries integer not null default 3 check (max_retries >= 0),
  worker_name text not null default '',
  source_version text not null default '',
  result_summary jsonb not null default '{}'::jsonb,
  error_code text not null default '',
  error_message text not null default '',
  started_at timestamptz,
  finished_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_pb_extract_jobs_academy_created
  on public.pb_extract_jobs (academy_id, created_at desc);
create index if not exists idx_pb_extract_jobs_document_created
  on public.pb_extract_jobs (document_id, created_at desc);
create index if not exists idx_pb_extract_jobs_status
  on public.pb_extract_jobs (status);

-- Questions (정규화 결과)
create table if not exists public.pb_questions (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  document_id uuid not null references public.pb_documents(id) on delete cascade,
  extract_job_id uuid references public.pb_extract_jobs(id) on delete set null,
  source_page integer not null default 1 check (source_page >= 1),
  source_order integer not null default 0 check (source_order >= 0),
  question_number text not null default '',
  question_type text not null default '미분류'
    check (question_type in ('객관식', '주관식', '서술형', '복합형', '미분류')),
  stem text not null default '',
  choices jsonb not null default '[]'::jsonb,
  figure_refs jsonb not null default '[]'::jsonb,
  equations jsonb not null default '[]'::jsonb,
  source_anchors jsonb not null default '{}'::jsonb,
  confidence numeric(5, 4) not null default 0
    check (confidence >= 0 and confidence <= 1),
  flags text[] not null default array[]::text[],
  is_checked boolean not null default false,
  reviewed_by uuid,
  reviewed_at timestamptz,
  reviewer_notes text not null default '',
  meta jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_pb_questions_document_page_order
  on public.pb_questions (document_id, source_page, source_order);
create index if not exists idx_pb_questions_academy_created
  on public.pb_questions (academy_id, created_at desc);
create index if not exists idx_pb_questions_confidence
  on public.pb_questions (confidence);
create index if not exists idx_pb_questions_flags_gin
  on public.pb_questions using gin (flags);

-- Exports (양식 PDF 생성)
create table if not exists public.pb_exports (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  document_id uuid not null references public.pb_documents(id) on delete cascade,
  requested_by uuid,
  status text not null default 'queued'
    check (status in ('queued', 'rendering', 'completed', 'failed', 'cancelled')),
  template_profile text not null default 'naesin'
    check (template_profile in ('naesin', 'csat', 'mock')),
  paper_size text not null default 'A4'
    check (paper_size in ('A4', 'B4', '8절')),
  include_answer_sheet boolean not null default true,
  include_explanation boolean not null default false,
  selected_question_ids uuid[] not null default array[]::uuid[],
  options jsonb not null default '{}'::jsonb,
  result_summary jsonb not null default '{}'::jsonb,
  output_storage_bucket text not null default 'problem-exports',
  output_storage_path text not null default '',
  output_url text not null default '',
  page_count integer not null default 0 check (page_count >= 0),
  worker_name text not null default '',
  error_code text not null default '',
  error_message text not null default '',
  started_at timestamptz,
  finished_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_pb_exports_academy_created
  on public.pb_exports (academy_id, created_at desc);
create index if not exists idx_pb_exports_document_created
  on public.pb_exports (document_id, created_at desc);
create index if not exists idx_pb_exports_status
  on public.pb_exports (status);

-- updated_at triggers
drop trigger if exists pb_documents_set_updated_at on public.pb_documents;
create trigger pb_documents_set_updated_at
before update on public.pb_documents
for each row execute function public.set_updated_at();

drop trigger if exists pb_extract_jobs_set_updated_at on public.pb_extract_jobs;
create trigger pb_extract_jobs_set_updated_at
before update on public.pb_extract_jobs
for each row execute function public.set_updated_at();

drop trigger if exists pb_questions_set_updated_at on public.pb_questions;
create trigger pb_questions_set_updated_at
before update on public.pb_questions
for each row execute function public.set_updated_at();

drop trigger if exists pb_exports_set_updated_at on public.pb_exports;
create trigger pb_exports_set_updated_at
before update on public.pb_exports
for each row execute function public.set_updated_at();

-- RLS
alter table public.pb_documents enable row level security;
alter table public.pb_extract_jobs enable row level security;
alter table public.pb_questions enable row level security;
alter table public.pb_exports enable row level security;

drop policy if exists "pb_documents_select" on public.pb_documents;
drop policy if exists "pb_documents_insert" on public.pb_documents;
drop policy if exists "pb_documents_update" on public.pb_documents;
drop policy if exists "pb_documents_delete" on public.pb_documents;

create policy "pb_documents_select" on public.pb_documents
for select using (
  academy_id in (
    select m.academy_id
    from public.memberships m
    where m.user_id = auth.uid()
  )
);

create policy "pb_documents_insert" on public.pb_documents
for insert with check (
  academy_id in (
    select m.academy_id
    from public.memberships m
    where m.user_id = auth.uid()
  )
);

create policy "pb_documents_update" on public.pb_documents
for update using (
  academy_id in (
    select m.academy_id
    from public.memberships m
    where m.user_id = auth.uid()
  )
);

create policy "pb_documents_delete" on public.pb_documents
for delete using (
  academy_id in (
    select m.academy_id
    from public.memberships m
    where m.user_id = auth.uid()
  )
);

drop policy if exists "pb_extract_jobs_select" on public.pb_extract_jobs;
drop policy if exists "pb_extract_jobs_insert" on public.pb_extract_jobs;
drop policy if exists "pb_extract_jobs_update" on public.pb_extract_jobs;
drop policy if exists "pb_extract_jobs_delete" on public.pb_extract_jobs;

create policy "pb_extract_jobs_select" on public.pb_extract_jobs
for select using (
  academy_id in (
    select m.academy_id
    from public.memberships m
    where m.user_id = auth.uid()
  )
);

create policy "pb_extract_jobs_insert" on public.pb_extract_jobs
for insert with check (
  academy_id in (
    select m.academy_id
    from public.memberships m
    where m.user_id = auth.uid()
  )
);

create policy "pb_extract_jobs_update" on public.pb_extract_jobs
for update using (
  academy_id in (
    select m.academy_id
    from public.memberships m
    where m.user_id = auth.uid()
  )
);

create policy "pb_extract_jobs_delete" on public.pb_extract_jobs
for delete using (
  academy_id in (
    select m.academy_id
    from public.memberships m
    where m.user_id = auth.uid()
  )
);

drop policy if exists "pb_questions_select" on public.pb_questions;
drop policy if exists "pb_questions_insert" on public.pb_questions;
drop policy if exists "pb_questions_update" on public.pb_questions;
drop policy if exists "pb_questions_delete" on public.pb_questions;

create policy "pb_questions_select" on public.pb_questions
for select using (
  academy_id in (
    select m.academy_id
    from public.memberships m
    where m.user_id = auth.uid()
  )
);

create policy "pb_questions_insert" on public.pb_questions
for insert with check (
  academy_id in (
    select m.academy_id
    from public.memberships m
    where m.user_id = auth.uid()
  )
);

create policy "pb_questions_update" on public.pb_questions
for update using (
  academy_id in (
    select m.academy_id
    from public.memberships m
    where m.user_id = auth.uid()
  )
);

create policy "pb_questions_delete" on public.pb_questions
for delete using (
  academy_id in (
    select m.academy_id
    from public.memberships m
    where m.user_id = auth.uid()
  )
);

drop policy if exists "pb_exports_select" on public.pb_exports;
drop policy if exists "pb_exports_insert" on public.pb_exports;
drop policy if exists "pb_exports_update" on public.pb_exports;
drop policy if exists "pb_exports_delete" on public.pb_exports;

create policy "pb_exports_select" on public.pb_exports
for select using (
  academy_id in (
    select m.academy_id
    from public.memberships m
    where m.user_id = auth.uid()
  )
);

create policy "pb_exports_insert" on public.pb_exports
for insert with check (
  academy_id in (
    select m.academy_id
    from public.memberships m
    where m.user_id = auth.uid()
  )
);

create policy "pb_exports_update" on public.pb_exports
for update using (
  academy_id in (
    select m.academy_id
    from public.memberships m
    where m.user_id = auth.uid()
  )
);

create policy "pb_exports_delete" on public.pb_exports
for delete using (
  academy_id in (
    select m.academy_id
    from public.memberships m
    where m.user_id = auth.uid()
  )
);

-- Storage policies (path prefix: {academy_id}/...)
drop policy if exists "pb documents select" on storage.objects;
drop policy if exists "pb documents insert" on storage.objects;
drop policy if exists "pb documents update" on storage.objects;
drop policy if exists "pb documents delete" on storage.objects;

create policy "pb documents select" on storage.objects
for select using (
  bucket_id = 'problem-documents'
  and exists (
    select 1
    from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = split_part(name, '/', 1)::uuid
  )
);

create policy "pb documents insert" on storage.objects
for insert with check (
  bucket_id = 'problem-documents'
  and exists (
    select 1
    from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = split_part(name, '/', 1)::uuid
  )
);

create policy "pb documents update" on storage.objects
for update using (
  bucket_id = 'problem-documents'
  and exists (
    select 1
    from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = split_part(name, '/', 1)::uuid
  )
);

create policy "pb documents delete" on storage.objects
for delete using (
  bucket_id = 'problem-documents'
  and exists (
    select 1
    from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = split_part(name, '/', 1)::uuid
  )
);

drop policy if exists "pb exports select" on storage.objects;
drop policy if exists "pb exports insert" on storage.objects;
drop policy if exists "pb exports update" on storage.objects;
drop policy if exists "pb exports delete" on storage.objects;

create policy "pb exports select" on storage.objects
for select using (
  bucket_id = 'problem-exports'
  and exists (
    select 1
    from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = split_part(name, '/', 1)::uuid
  )
);

create policy "pb exports insert" on storage.objects
for insert with check (
  bucket_id = 'problem-exports'
  and exists (
    select 1
    from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = split_part(name, '/', 1)::uuid
  )
);

create policy "pb exports update" on storage.objects
for update using (
  bucket_id = 'problem-exports'
  and exists (
    select 1
    from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = split_part(name, '/', 1)::uuid
  )
);

create policy "pb exports delete" on storage.objects
for delete using (
  bucket_id = 'problem-exports'
  and exists (
    select 1
    from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = split_part(name, '/', 1)::uuid
  )
);

drop policy if exists "pb previews select" on storage.objects;
drop policy if exists "pb previews insert" on storage.objects;
drop policy if exists "pb previews update" on storage.objects;
drop policy if exists "pb previews delete" on storage.objects;

create policy "pb previews select" on storage.objects
for select using (
  bucket_id = 'problem-previews'
  and exists (
    select 1
    from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = split_part(name, '/', 1)::uuid
  )
);

create policy "pb previews insert" on storage.objects
for insert with check (
  bucket_id = 'problem-previews'
  and exists (
    select 1
    from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = split_part(name, '/', 1)::uuid
  )
);

create policy "pb previews update" on storage.objects
for update using (
  bucket_id = 'problem-previews'
  and exists (
    select 1
    from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = split_part(name, '/', 1)::uuid
  )
);

create policy "pb previews delete" on storage.objects
for delete using (
  bucket_id = 'problem-previews'
  and exists (
    select 1
    from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = split_part(name, '/', 1)::uuid
  )
);
