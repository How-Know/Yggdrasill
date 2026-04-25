-- 20260426120500: textbook_problem_solution_refs (sidecar, Stage 3)
--
-- Purpose: persist the (raw_page, bbox) of each 문항 in the 해설 PDF so the
-- learning app can jump directly to a problem's solution page/region when
-- the user taps a number later. Stored as a 1:1 sidecar keyed by `crop_id`
-- so it can be recomputed independently of the body-PDF region in
-- `textbook_problem_crops`.

create table if not exists public.textbook_problem_solution_refs (
  crop_id uuid primary key
    references public.textbook_problem_crops(id) on delete cascade,
  academy_id uuid not null
    references public.academies(id) on delete cascade,

  raw_page int not null,
  display_page int,

  -- Bounding box of the 문항 번호 label inside the 해설 PDF page.
  number_region_1k int[] not null,
  -- Optional: the region that covers the whole solution body (if the VLM can
  -- confidently estimate it). Fall back to `number_region_1k` when null.
  content_region_1k int[],

  extracted_at timestamptz not null default now(),
  edited_at timestamptz
);

create index if not exists textbook_problem_solution_refs_academy_idx
  on public.textbook_problem_solution_refs(academy_id);

do $$ begin
  if exists (select 1 from pg_proc where proname = 'set_updated_at') then
    drop trigger if exists trg_textbook_problem_solution_refs_updated_at
      on public.textbook_problem_solution_refs;
    create trigger trg_textbook_problem_solution_refs_updated_at
      before update on public.textbook_problem_solution_refs
      for each row execute function public.set_updated_at();
  end if;
end $$;

-- ─────────────────────────────────────────────────────────────────────────
-- RLS
-- ─────────────────────────────────────────────────────────────────────────

alter table public.textbook_problem_solution_refs enable row level security;

drop policy if exists "textbook_problem_solution_refs select" on public.textbook_problem_solution_refs;
create policy "textbook_problem_solution_refs select" on public.textbook_problem_solution_refs
  for select
  using (
    exists (
      select 1 from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id = textbook_problem_solution_refs.academy_id
    )
  );

drop policy if exists "textbook_problem_solution_refs insert" on public.textbook_problem_solution_refs;
create policy "textbook_problem_solution_refs insert" on public.textbook_problem_solution_refs
  for insert
  with check (
    exists (
      select 1 from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id = textbook_problem_solution_refs.academy_id
    )
  );

drop policy if exists "textbook_problem_solution_refs update" on public.textbook_problem_solution_refs;
create policy "textbook_problem_solution_refs update" on public.textbook_problem_solution_refs
  for update
  using (
    exists (
      select 1 from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id = textbook_problem_solution_refs.academy_id
    )
  )
  with check (
    exists (
      select 1 from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id = textbook_problem_solution_refs.academy_id
    )
  );

drop policy if exists "textbook_problem_solution_refs delete" on public.textbook_problem_solution_refs;
create policy "textbook_problem_solution_refs delete" on public.textbook_problem_solution_refs
  for delete
  using (
    exists (
      select 1 from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id = textbook_problem_solution_refs.academy_id
    )
  );

comment on table public.textbook_problem_solution_refs is
  'Stage 3 sidecar: per-문항 해설 좌표 (raw_page + bbox) inside the 해설 PDF. '
  'Lets the student app jump straight to a problem''s solution region when a '
  'number is tapped. Keyed 1:1 to textbook_problem_crops.id.';
