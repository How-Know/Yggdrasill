-- 20260423120000: Textbook problem crops storage + table
--
-- Purpose: persist VLM-detected problem crops (PNG + coordinate metadata) so
-- they can later be joined 1:1 with HWPX-extracted problems in pb_questions.
--
-- Added:
--   * storage bucket `textbook-crops` (private, PNG/JPEG, 25MB cap)
--   * RLS on storage.objects for that bucket scoped to academy membership
--   * public.textbook_problem_crops table with UNIQUE canonical key
--     (academy_id, book_id, grade_label, big_order, mid_order, sub_key, problem_number)
--   * standard RLS (select/insert/update/delete) based on memberships

-- ─────────────────────────────────────────────────────────────────────────
-- 1) Table
-- ─────────────────────────────────────────────────────────────────────────

create table if not exists public.textbook_problem_crops (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null
    references public.academies(id) on delete cascade,
  book_id uuid not null
    references public.resource_files(id) on delete cascade,
  grade_label text not null,

  -- Unit path. Matches the "units" tree stored in
  -- public.textbook_metadata.payload (JSONB).
  big_order int not null,
  mid_order int not null,
  sub_key text not null,
  big_name text,
  mid_name text,

  -- VLM detection snapshot (copied from the detect-problems response so a
  -- crop row is self-contained for later joins).
  raw_page int not null,
  display_page int,
  section text,                        -- basic_drill | type_practice | mastery | unknown
  problem_number text not null,        -- e.g. '0001', '12', '48~52'
  label text not null default '',      -- 상/중/하/대표문제/창의문제/서술형
  is_set_header boolean not null default false,
  set_from int,
  set_to int,
  column_index int,
  bbox_1k int[],                       -- [ymin, xmin, ymax, xmax] normalised 0..1000
  item_region_1k int[],

  -- Image (Supabase Storage)
  storage_bucket text not null default 'textbook-crops',
  storage_key text not null,           -- relative path inside the bucket
  file_size_bytes bigint,
  content_hash text,                   -- sha256 hex of the PNG bytes
  width_px int,
  height_px int,
  crop_rect_px int[],                  -- [x, y, w, h] in the source hi-res page
  padding_px int,
  crop_long_edge_px int,
  deskew_angle_deg numeric,

  -- Forward link to problem bank (filled in by a future HWPX ↔ crop match step)
  pb_question_uid uuid,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Sub-section is fixed to 쎈's A/B/C trio for now. If another series needs
-- different codes we'll relax this with an ALTER.
alter table public.textbook_problem_crops
  drop constraint if exists textbook_problem_crops_sub_key_chk;
alter table public.textbook_problem_crops
  add constraint textbook_problem_crops_sub_key_chk
  check (sub_key in ('A', 'B', 'C'));

-- Canonical uniqueness so re-analysis overwrites instead of duplicating.
alter table public.textbook_problem_crops
  drop constraint if exists textbook_problem_crops_canon_uk;
alter table public.textbook_problem_crops
  add constraint textbook_problem_crops_canon_uk
  unique (academy_id, book_id, grade_label, big_order, mid_order, sub_key, problem_number);

create index if not exists textbook_problem_crops_book_idx
  on public.textbook_problem_crops(academy_id, book_id, grade_label);

create index if not exists textbook_problem_crops_pb_uid_idx
  on public.textbook_problem_crops(pb_question_uid)
  where pb_question_uid is not null;

-- Updated-at trigger (reuses the shared helper if available, else inlines)
do $$ begin
  if exists (
    select 1 from pg_proc where proname = 'set_updated_at'
  ) then
    drop trigger if exists trg_textbook_problem_crops_updated_at
      on public.textbook_problem_crops;
    create trigger trg_textbook_problem_crops_updated_at
      before update on public.textbook_problem_crops
      for each row execute function public.set_updated_at();
  end if;
end $$;

-- ─────────────────────────────────────────────────────────────────────────
-- 2) RLS — academy-scoped via memberships
-- ─────────────────────────────────────────────────────────────────────────

alter table public.textbook_problem_crops enable row level security;

drop policy if exists "textbook_problem_crops select" on public.textbook_problem_crops;
create policy "textbook_problem_crops select" on public.textbook_problem_crops
  for select
  using (
    exists (
      select 1 from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id = textbook_problem_crops.academy_id
    )
  );

drop policy if exists "textbook_problem_crops insert" on public.textbook_problem_crops;
create policy "textbook_problem_crops insert" on public.textbook_problem_crops
  for insert
  with check (
    exists (
      select 1 from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id = textbook_problem_crops.academy_id
    )
  );

drop policy if exists "textbook_problem_crops update" on public.textbook_problem_crops;
create policy "textbook_problem_crops update" on public.textbook_problem_crops
  for update
  using (
    exists (
      select 1 from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id = textbook_problem_crops.academy_id
    )
  )
  with check (
    exists (
      select 1 from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id = textbook_problem_crops.academy_id
    )
  );

drop policy if exists "textbook_problem_crops delete" on public.textbook_problem_crops;
create policy "textbook_problem_crops delete" on public.textbook_problem_crops
  for delete
  using (
    exists (
      select 1 from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id = textbook_problem_crops.academy_id
    )
  );

-- ─────────────────────────────────────────────────────────────────────────
-- 3) Storage bucket `textbook-crops`
-- ─────────────────────────────────────────────────────────────────────────
--
-- Key convention: academies/<academy_id>/books/<book_id>/<grade_label>/
--   <big_order>_<mid_order>_<sub_key>/<problem_number>.png
-- The second segment is the academy_id uuid used to gate membership.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'textbook-crops',
  'textbook-crops',
  false,
  26214400, -- 25MB per crop (plenty for a single problem)
  ARRAY['image/png', 'image/jpeg']
)
on conflict (id) do nothing;

drop policy if exists "textbook-crops select" on storage.objects;
create policy "textbook-crops select" on storage.objects
for select
using (
  bucket_id = 'textbook-crops'
  and exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = split_part(name, '/', 2)::uuid
  )
);

drop policy if exists "textbook-crops insert" on storage.objects;
create policy "textbook-crops insert" on storage.objects
for insert
with check (
  bucket_id = 'textbook-crops'
  and exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = split_part(name, '/', 2)::uuid
  )
);

drop policy if exists "textbook-crops update" on storage.objects;
create policy "textbook-crops update" on storage.objects
for update
using (
  bucket_id = 'textbook-crops'
  and exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = split_part(name, '/', 2)::uuid
  )
)
with check (
  bucket_id = 'textbook-crops'
  and exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = split_part(name, '/', 2)::uuid
  )
);

drop policy if exists "textbook-crops delete" on storage.objects;
create policy "textbook-crops delete" on storage.objects
for delete
using (
  bucket_id = 'textbook-crops'
  and exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.academy_id = split_part(name, '/', 2)::uuid
  )
);
