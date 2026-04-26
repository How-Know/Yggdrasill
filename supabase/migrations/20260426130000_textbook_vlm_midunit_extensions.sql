-- Textbook VLM mid-unit extensions:
-- 1) A/B content group labels for Stage 1 crops.
-- 2) Image answers for Stage 2.
-- 3) Per-subunit link/status rows for PDF-only problem-bank extraction.

-- ─────────────────────────────────────────────────────────────────────────
-- Stage 1: content group labels (A: 01-1..., B: 유형 01...)
-- ─────────────────────────────────────────────────────────────────────────

alter table public.textbook_problem_crops
  add column if not exists content_group_kind text not null default 'none',
  add column if not exists content_group_label text not null default '',
  add column if not exists content_group_title text not null default '',
  add column if not exists content_group_order int;

alter table public.textbook_problem_crops
  drop constraint if exists textbook_problem_crops_content_group_kind_chk;
alter table public.textbook_problem_crops
  add constraint textbook_problem_crops_content_group_kind_chk
  check (content_group_kind in ('none', 'basic_subtopic', 'type'));

create index if not exists textbook_problem_crops_group_idx
  on public.textbook_problem_crops(
    academy_id,
    book_id,
    grade_label,
    big_order,
    mid_order,
    sub_key,
    content_group_order
  );

-- ─────────────────────────────────────────────────────────────────────────
-- Stage 2: image answers
-- ─────────────────────────────────────────────────────────────────────────

alter table public.textbook_problem_answers
  drop constraint if exists textbook_problem_answers_answer_kind_check;
alter table public.textbook_problem_answers
  drop constraint if exists textbook_problem_answers_answer_kind_chk;
alter table public.textbook_problem_answers
  add constraint textbook_problem_answers_answer_kind_chk
  check (answer_kind in ('objective', 'subjective', 'image'));

alter table public.textbook_problem_answers
  add column if not exists answer_image_bucket text not null default '',
  add column if not exists answer_image_path text not null default '',
  add column if not exists answer_image_region_1k int[],
  add column if not exists answer_image_width_px int,
  add column if not exists answer_image_height_px int,
  add column if not exists answer_image_size_bytes bigint,
  add column if not exists answer_image_content_hash text not null default '';

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'textbook-answer-images',
  'textbook-answer-images',
  false,
  26214400,
  array['image/png', 'image/jpeg', 'image/jpg', 'image/webp']
)
on conflict (id) do nothing;

drop policy if exists "textbook_answer_images select" on storage.objects;
create policy "textbook_answer_images select" on storage.objects
  for select
  using (
    bucket_id = 'textbook-answer-images'
    and exists (
      select 1
      from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id::text = split_part(name, '/', 2)
    )
  );

drop policy if exists "textbook_answer_images insert" on storage.objects;
create policy "textbook_answer_images insert" on storage.objects
  for insert
  with check (
    bucket_id = 'textbook-answer-images'
    and exists (
      select 1
      from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id::text = split_part(name, '/', 2)
    )
  );

drop policy if exists "textbook_answer_images update" on storage.objects;
create policy "textbook_answer_images update" on storage.objects
  for update
  using (
    bucket_id = 'textbook-answer-images'
    and exists (
      select 1
      from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id::text = split_part(name, '/', 2)
    )
  )
  with check (
    bucket_id = 'textbook-answer-images'
    and exists (
      select 1
      from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id::text = split_part(name, '/', 2)
    )
  );

drop policy if exists "textbook_answer_images delete" on storage.objects;
create policy "textbook_answer_images delete" on storage.objects
  for delete
  using (
    bucket_id = 'textbook-answer-images'
    and exists (
      select 1
      from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id::text = split_part(name, '/', 2)
    )
  );

-- ─────────────────────────────────────────────────────────────────────────
-- Problem-bank PDF-only extraction status per textbook subunit
-- ─────────────────────────────────────────────────────────────────────────

create table if not exists public.textbook_pb_extract_runs (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null
    references public.academies(id) on delete cascade,
  book_id uuid not null
    references public.resource_files(id) on delete cascade,
  grade_label text not null,

  big_order int not null,
  mid_order int not null,
  sub_key text not null,
  big_name text not null default '',
  mid_name text not null default '',
  sub_name text not null default '',
  raw_page_from int,
  raw_page_to int,
  display_page_from int,
  display_page_to int,

  pb_document_id uuid
    references public.pb_documents(id) on delete set null,
  extract_job_id uuid
    references public.pb_extract_jobs(id) on delete set null,

  status text not null default 'idle'
    check (status in ('idle', 'queued', 'extracting', 'completed', 'review_required', 'failed', 'cancelled')),
  error_code text not null default '',
  error_message text not null default '',
  result_summary jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.textbook_pb_extract_runs
  drop constraint if exists textbook_pb_extract_runs_sub_key_chk;
alter table public.textbook_pb_extract_runs
  add constraint textbook_pb_extract_runs_sub_key_chk
  check (sub_key in ('A', 'B', 'C'));

alter table public.textbook_pb_extract_runs
  drop constraint if exists textbook_pb_extract_runs_scope_uk;
alter table public.textbook_pb_extract_runs
  add constraint textbook_pb_extract_runs_scope_uk
  unique (academy_id, book_id, grade_label, big_order, mid_order, sub_key);

create index if not exists textbook_pb_extract_runs_book_idx
  on public.textbook_pb_extract_runs(academy_id, book_id, grade_label);

create index if not exists textbook_pb_extract_runs_job_idx
  on public.textbook_pb_extract_runs(extract_job_id)
  where extract_job_id is not null;

do $$ begin
  if exists (select 1 from pg_proc where proname = 'set_updated_at') then
    drop trigger if exists trg_textbook_pb_extract_runs_updated_at
      on public.textbook_pb_extract_runs;
    create trigger trg_textbook_pb_extract_runs_updated_at
      before update on public.textbook_pb_extract_runs
      for each row execute function public.set_updated_at();
  end if;
end $$;

alter table public.textbook_pb_extract_runs enable row level security;

drop policy if exists "textbook_pb_extract_runs select" on public.textbook_pb_extract_runs;
create policy "textbook_pb_extract_runs select" on public.textbook_pb_extract_runs
  for select
  using (
    exists (
      select 1 from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id = textbook_pb_extract_runs.academy_id
    )
  );

drop policy if exists "textbook_pb_extract_runs insert" on public.textbook_pb_extract_runs;
create policy "textbook_pb_extract_runs insert" on public.textbook_pb_extract_runs
  for insert
  with check (
    exists (
      select 1 from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id = textbook_pb_extract_runs.academy_id
    )
  );

drop policy if exists "textbook_pb_extract_runs update" on public.textbook_pb_extract_runs;
create policy "textbook_pb_extract_runs update" on public.textbook_pb_extract_runs
  for update
  using (
    exists (
      select 1 from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id = textbook_pb_extract_runs.academy_id
    )
  )
  with check (
    exists (
      select 1 from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id = textbook_pb_extract_runs.academy_id
    )
  );

drop policy if exists "textbook_pb_extract_runs delete" on public.textbook_pb_extract_runs;
create policy "textbook_pb_extract_runs delete" on public.textbook_pb_extract_runs
  for delete
  using (
    exists (
      select 1 from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id = textbook_pb_extract_runs.academy_id
    )
  );
