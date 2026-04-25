-- 20260426120000: textbook_problem_answers (sidecar, Stage 2)
--
-- Purpose: persist the answer (객관식 원문자 or 주관식 LaTeX) produced by the
-- 답지 VLM for each 문항 in `textbook_problem_crops`. Stored as a 1:1 sidecar
-- via `crop_id` so that re-running the answer VLM or manually editing
-- answers never touches the Stage-1 문항 앵커 row.
--
-- Key design choices:
--   * `crop_id` is the primary key — one answer per crop, idempotent upsert.
--   * `answer_kind` is a check-constrained text so we can keep the schema
--     forward-compatible if we later add 'figure' / 'proof' / 'multi' etc.
--   * Both `answer_text` (the canonical 1D form the user may edit) and
--     `answer_latex_2d` (the pre-rendered 2D LaTeX the VLM produced) are
--     stored. When `answer_source = 'manual'` the 2D column becomes the user's
--     latest 2D choice; when `vlm` it's the raw VLM output.
--   * `raw_page` / `bbox_1k` let us later highlight *where* in the 답지 PDF
--     the answer came from, for quick double-check / correction.

create table if not exists public.textbook_problem_answers (
  crop_id uuid primary key
    references public.textbook_problem_crops(id) on delete cascade,
  academy_id uuid not null
    references public.academies(id) on delete cascade,

  answer_kind text not null
    check (answer_kind in ('objective', 'subjective')),
  answer_text text,                       -- 객관식: '①' / 주관식: 1D LaTeX 원문
  answer_latex_2d text,                   -- 주관식: 2D 렌더용 LaTeX
  answer_source text not null default 'vlm'
    check (answer_source in ('vlm', 'manual')),

  -- Where in the 답지 PDF this answer was detected.
  raw_page int,
  display_page int,
  bbox_1k int[],

  -- Free-form note (e.g. VLM confidence, alternative answers).
  note text,

  extracted_at timestamptz not null default now(),
  edited_at timestamptz
);

create index if not exists textbook_problem_answers_academy_idx
  on public.textbook_problem_answers(academy_id);

-- Updated-at trigger (share the generic helper if present).
do $$ begin
  if exists (select 1 from pg_proc where proname = 'set_updated_at') then
    drop trigger if exists trg_textbook_problem_answers_updated_at
      on public.textbook_problem_answers;
    create trigger trg_textbook_problem_answers_updated_at
      before update on public.textbook_problem_answers
      for each row execute function public.set_updated_at();
  end if;
end $$;

-- ─────────────────────────────────────────────────────────────────────────
-- RLS — academy-scoped via memberships (same pattern as crops table)
-- ─────────────────────────────────────────────────────────────────────────

alter table public.textbook_problem_answers enable row level security;

drop policy if exists "textbook_problem_answers select" on public.textbook_problem_answers;
create policy "textbook_problem_answers select" on public.textbook_problem_answers
  for select
  using (
    exists (
      select 1 from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id = textbook_problem_answers.academy_id
    )
  );

drop policy if exists "textbook_problem_answers insert" on public.textbook_problem_answers;
create policy "textbook_problem_answers insert" on public.textbook_problem_answers
  for insert
  with check (
    exists (
      select 1 from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id = textbook_problem_answers.academy_id
    )
  );

drop policy if exists "textbook_problem_answers update" on public.textbook_problem_answers;
create policy "textbook_problem_answers update" on public.textbook_problem_answers
  for update
  using (
    exists (
      select 1 from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id = textbook_problem_answers.academy_id
    )
  )
  with check (
    exists (
      select 1 from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id = textbook_problem_answers.academy_id
    )
  );

drop policy if exists "textbook_problem_answers delete" on public.textbook_problem_answers;
create policy "textbook_problem_answers delete" on public.textbook_problem_answers
  for delete
  using (
    exists (
      select 1 from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id = textbook_problem_answers.academy_id
    )
  );

comment on table public.textbook_problem_answers is
  'Stage 2 sidecar: per-문항 정답 (객관식 원문자 / 주관식 LaTeX) extracted '
  'from the 답지 PDF via VLM, with an optional manual override. Keyed 1:1 '
  'to textbook_problem_crops.id.';
