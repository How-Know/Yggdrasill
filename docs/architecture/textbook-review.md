# Textbook Review

This note covers phase 1 of reviewing migrated textbook problems: protecting
human corrections from machine re-runs, recording review findings and owner
decisions, and the manager-app "문항검수" tab that shows them.

Status (2026-11-02): manual protection, the review tables, the load check, and
the decision RPCs are deployed. The gateway guard is in place. AI stages 1 to 4
(solution transcription, independent solve, compare, render check) run from the
production 문항검수 screen in the manager app; see "AI pipeline" below. Stages 5
and 6 are not built.

## Principles

- **Pilot first.** One mid-unit (개념+유형 중1-1, Ⅰ. 소인수분해) is reviewed in
  full to calibrate the checks before the scope grows.
- **Three axes.** Every finding belongs to one axis, and a pass on one axis does
  not stand in for another:
  - `fidelity`: matches the printed textbook (원본 충실도).
  - `validity`: mathematically sound (수학적 타당성).
  - `output`: what students see renders correctly (출력 품질).
- **Proposal only.** System checks and AI open findings, and may attach a
  proposal. Only an owner action changes data. Nothing is applied automatically.
- **Keep and correct.** The source PDF is never changed. Errors in the printed
  source are recorded as correction notes.
- **Staff only.** Students never read review tables or functions.
- **AI through Edge Functions.** The OpenAI key stays in the `OPENAI_API_KEY`
  secret and every call records an `ai_runs` row (see `ai-think.md`).

## Manual protection

Migration `20261014233000_textbook_manual_guard.sql`.

- An answer row with `answer_source = 'manual'` is not changed by a non-manual
  write. The BEFORE UPDATE trigger returns NULL, so the row is skipped and is
  missing from `RETURNING`.
- A solution-ref row with `edited_at` set is not changed by a write that clears
  `edited_at`.
- The guard is bypassed only when the transaction-local setting
  `yggdrasill.manual_override = 'on'`. Only `textbook_review_release_manual`
  sets it.
- When an answer's content changes, the caches built from it are invalidated:
  - `student_grading_ai_cache` rows with `equiv:%` keys are deleted.
  - Answer images in `textbook_answer_render_assets` and `answer_render_assets`
    (`source_kind = 'textbook_crop'`) get `render_error = 'stale_answer'`.
    Consumers use only images with an empty `render_error`, and the gateway
    renders them again.
  - `unit_spec:v1` depends only on the stem and is kept.
  - Already graded student records are not re-graded. That is an open decision.
- Deletes are not blocked. Stage delete is an explicit human action, and scope
  sync skips protected crops (next section).

## Gateway guard

`gateway/src/textbook/manual_guard.js`, used by `gateway/src/problem_bank_api.js`.

- `textbook/answers/batch-upsert` and `textbook/solution-refs/batch-upsert`
  compare the requested crop ids with the rows the database returned and report
  `protected` and `protected_crop_ids`. Answer images are queued only for rows
  that were actually written.
- `textbook/crops/sync-scope` does not delete a crop that has a problem-bank
  question (`pb_question_uid`), a question link, a manual answer, or a manual
  solution ref. It reports `protected`, `protected_numbers`, `manual_protected`,
  `manual_protected_numbers`, and `protected_reasons`.
- Crop storage keys include the sub-section index when it is above 0
  (`<big>_<mid>_<sub_key>-<sub_index>/<number>.png`), so the same number in two
  sub-sections no longer shares a path.
- Crops are currently stored as coordinates only, so most rows have no PNG file.
  Stages that need images must render them from the page PDF by coordinates.

## Review core

Migration `20261014233500_textbook_review_core.sql`.

### Tables

- `textbook_review_runs`: one row per stage run over a scope (academy, book,
  grade, big and mid order), with a summary and `ai_run_id` for AI stages.
- `textbook_review_findings`: one thing for the owner to decide.
  - What is wrong: `title`, `detail`, `evidence`, plus `axis`, `stage`,
    `error_type`, `severity` (`blocker`, `warning`, `info`) and `source`
    (`system`, `ai`, `owner`).
  - How to fix it: `proposal` = `{target, after, reason, keeps}`, where `target`
    is `answer`, `solution_ref`, or `correction_note`.
  - `check_key` is set only by system checks. It is unique per crop among open
    and held findings, so a re-run updates instead of duplicating.
  - `status` is `open`, `held`, `resolved`, or `dismissed`. `resolution` is
    `applied`, `manual_edit`, `noted`, `dismissed`, or `auto_cleared`.
- `textbook_review_decisions`: append-only log of owner actions
  (`apply_proposal`, `manual_edit`, `dismiss`, `hold`, `reopen`,
  `release_manual`) with before and after values, the note, the fingerprint the
  screen showed, and the fingerprint after.
- View `textbook_review_findings_live`: findings plus `stale_parts`, the parts
  that changed since the finding's base.

### Fingerprints

`textbook_review_fingerprint(crop_id)` returns an md5 per part:

- `crop`: page, region, number, storage key, content hash.
- `problem`: the linked problem-bank question (stem, choices, figures,
  equations, common stem).
- `answer`: kind, text, LaTeX, image.
- `solution_ref`: source kind, page, regions.

The source (`vlm` or `manual`) is not part of the hash, so protecting a value
does not make findings stale.

### Decisions

`textbook_review_decide(finding, action, expected, value, note)`:

- Every action except `reopen` sends `p_expected`, the fingerprint the screen
  showed, for the finding's base parts plus the target part. If any of them
  differs from now, it fails with `textbook_review_stale` and the screen
  reloads.
- `apply_proposal` is stricter. If a base part changed after the proposal was
  made, it fails with `textbook_review_proposal_stale` even after a reload. A
  proposal is evidence about the values it was computed on. The owner decides
  with `manual_edit` (the editor is prefilled with the proposal) or `dismiss`.
- `apply_proposal` and `manual_edit` write through
  `textbook_review_apply_change`:
  - Answers are written with `answer_source = 'manual'` and `edited_at`.
  - Solution refs are written with `edited_at`. `source_kind = 'none'` is the
    "no solution" sentinel (`raw_page` 0, number region `[0,0,0,0]`), the same
    one the stage dialog writes. Other positions need a page and a drawn number
    region, so the review tab sends the owner to the stage dialog for them.
  - A correction note changes no data and resolves as `noted`.
- `dismiss` moves `base_fingerprint` to the values the owner saw. Re-running the
  same check on the same values does not reopen it.
- `hold` keeps the finding active. `reopen` works only from `held` or
  `dismissed`. A resolved finding does not reopen; to undo, save a new value
  with a manual edit.
- `textbook_review_edit(crop, expected, value, note)` is a manual edit without
  a finding.
- `textbook_review_release_manual(crop, target, note)` is the owner's explicit
  release. It keeps the values, makes them overwritable again, and logs
  `release_manual`.

### Load check (stage 0)

`textbook_review_refresh_load_checks(academy, book, grade, big, mid)` opens
`fidelity` findings for:

- missing answer (blocker),
- missing solution ref (warning; a "no solution" row satisfies it),
- missing problem-bank link (warning),
- problem-bank answer differing from the grading answer after normalizing
  notation (warning),
- two crops with real files sharing a storage key (blocker).

A re-run updates open findings and their base, leaves dismissed findings closed
while their parts are unchanged, and closes findings whose condition is gone
(`auto_cleared`). Each run is recorded with its counts.

### List

`textbook_review_items(academy, book, grade, big, mid)` returns one row per
problem: answer and solution info, manual flags, problem-bank id, open and held
counts, open counts by axis, and the current fingerprint to send with decisions.

### Access

- Academy members can select. Insert, update, and delete are revoked from
  clients. Writes go only through the RPCs above (which check staff) and
  service-role Edge Functions.
- The internal helpers (`textbook_review_assert_staff`,
  `textbook_review_check_expected`, `textbook_review_apply_change`) are not
  executable by clients.
- Student Edge Functions and the student app must not reference
  `textbook_review`. `tools/db_test` scans their sources.

## Stages

| # | Stage | Key | State |
|---|-------|-----|-------|
| 0 | 적재 확인 | `load` | Built (database) |
| 1 | 해설 전사 | `solution_text` | Built (Edge `textbook_problem_review`, Vision on the solution crop) |
| 2 | AI 독립 풀이 | `solve` | Built (same action, judged on the V2 render) |
| 3 | 대조·판정 | `compare` | Built (same action) |
| 4 | 렌더 검수 | `render` | Built (Edge `textbook_problem_render_check`, second pass) |
| 5 | 개념서 | `concept` | Planned |
| 6 | 마감 | `close` | Planned |

AI stages open findings and store their analysis per problem. They never change
answers or solution refs; the owner does that through the decision RPCs or the
edit RPC below.

## AI pipeline

Migrations `20261101030000_textbook_problem_review_pipeline.sql`,
`20261102010000_textbook_review_set_common_stem.sql`,
`20261102030000_textbook_review_solution_vision_and_v2_render_check.sql`.
Edge code: `supabase/functions/ai_think/textbook_problem_review.ts`
(prompt version `TEXTBOOK_REVIEW_PROMPT_VERSION`). Manager code:
`services/textbook_problem_review_service.dart`,
`services/textbook_review_solution_image_service.dart`,
`screens/problem_roadmap/problem_roadmap_screen.dart`.

### Where the result lives

`textbook_problem_analyses`, one row per crop:

- Original solution: `solution_transcribed`, `solution_answer`,
  `solution_source` (`textbook_vision` or `manual`), `solution_extracted_at`.
  This is the printed solution read from the solution PDF. It is never derived
  from the AI solve.
- AI solve: `ai_solution`, `ai_answer`, concept ids, thinking codes, the three
  difficulty axes (concept, thinking, arithmetic; recomputed by
  `textbook_problem_recalc_scores`).
- Judgement: `math_status` and `quality_status`, each `pending`, `clean`,
  `issue`, or `approved`. `quality_checks` keeps the stage-2 flags
  (`judged_from_v2_image`, `fidelity_ok`, `solution_vision`), `render_checks`
  and `render_checked_at` keep the stage-4 result.
- `alternative_solutions`: a jsonb array of extra solutions the owner adds.

Reads go through `textbook_review_unit_overview(academy, book, grade, big, mid)`
(one row per problem with crop, problem-bank, answer, solution-ref and analysis
fields). Owner edits go through `textbook_review_save_item_edit`, which can set
the answer, the AI solution, visual tags, the transcribed solution and its
answer, alternative solutions, and approve the math or quality axis. Changing
the transcribed text sets `solution_source = 'manual'`; saving the same text
keeps `textbook_vision`.

### Why the client orchestrates

The V2 renderer (xelatex) and the textbook PDFs live on the operator PC behind
the gateway; the Edge Function cannot reach them. So the manager app prepares
the images for each chunk and the Edge Function only sees URLs and base64:

1. The screen loads V2 problem thumbnails for the unit
   (`/pb/preview/batch-render`, signed Supabase URLs).
2. For each todo problem with a real solution ref, the app downloads the
   solution (or body) PDF once per book and grade, renders the
   `content_region_1k` with pdfrx (padded, about 1100 px wide), and sends it
   as a base64 PNG.
3. It posts `crop_ids` plus `images` (per crop: `solution_image_base64`,
   `solution_image_mime`, `v2_problem_url`) to `ai_think` action
   `textbook_problem_review`, six problems per call. Only https URLs and
   png/jpeg/webp base64 under 4M characters are accepted.
4. After the unit is done it runs the render check pass (below).

`isReviewTodo` is the same on both sides: `pending` or no AI solution is todo;
`approved` is not; otherwise a problem is todo only if it has a solution ref,
no transcribed solution, and Vision has not been tried yet
(`quality_checks.solution_vision` absent). A problem whose Vision read failed
is therefore not retried on every run; "전체 강제 재검수" overrides this. The
screen also keeps a per-run sent set so one run never sends a crop twice.

### Stages 1 to 3 (`textbook_problem_review`)

- Stage 1 (reasoning low) transcribes the solution crop verbatim: text, the
  final answer, confidence, and `found = false` when the crop does not contain
  this problem's solution. It does not solve the problem.
- Stage 2 runs in parallel with stage 1. The model sees the V2 render of the
  problem (detail high) and, when a crop exists, the original textbook crop
  (detail auto). It solves independently and judges quality **from the V2
  image, as a student would see it**, not from the stem text. The original
  crop is only for fidelity (`fidelity_ok`: does the render match the print).
  Set problems get the common stem combined with the item
  (`[공통 지시문] ... [문항] ...`).
- Stage 3 compares the grading answer, the transcribed solution answer (when
  present), and the AI answer, and proposes concept ids, thinking codes and
  draft proposals.
- Writes: the analysis row (manual solutions are kept, `render_checks` is
  reset), `math_status` and `quality_status` (`clean` or `issue`), and
  findings with `check_key` `ai_answer_compare`, `ai_quality_v2_student_view`,
  `ai_solution_vision`. A re-run updates the open finding or resolves it as
  `auto_cleared`. Findings are matched by selecting the open row for
  `(crop_id, check_key)` first; the partial unique index cannot be targeted by
  a client upsert.

### Stage 4 (`textbook_problem_render_check`)

The manager app renders two V2 cards per problem through
`/pb/preview/custom-thumbnail`: the problem card and an answer + solution card
(`정답 X` then the printed solution, or the AI solution when there is none).
It posts up to eight `{crop_id, problem_url, answer_solution_url,
solution_kind}` items. The model reads both images as a student and reports
`problem_ok`, `answer_ok`, `solution_ok` with an issue title and detail.

Writes: `render_checks`, `render_checked_at`, finding `check_key`
`ai_v2_render_student_view`, and `quality_status`: approved stays approved;
otherwise `clean` only when the render is fine and the stage-2 checks were
fine, else `issue`. Every call records an `ai_runs` row with feature
`textbook_problem_review` or `textbook_problem_render_check`.

## Manager screen (문항검수)

`apps/yggdrasill_manager/lib/screens/problem_roadmap/problem_roadmap_screen.dart`.
Three columns:

- Left: the unit's problem list with math and quality status.
- Centre: the math review card (answers side by side, compare result), the
  solution edit card (transcribed solution, its answer, AI solution; "해설
  저장"), and the quality review card (stage-2 flags, render-check state,
  findings).
- Right, a vertical stack rendered **only with V2**: ① the problem card,
  ② answer + printed solution (or AI solution), ③ the AI solution when a printed
  one exists, then one card per alternative solution with add and remove. Card
  images are cached per `crop | kind | text hash` and rebuilt when the text
  changes. The client LaTeX renderer is not used here, because the point of the
  stack is to see exactly what students will see.
- Header menu: "전체 강제 재검수" (ignores `isReviewTodo`) and "V2 렌더 검수만
  전체 다시" (stage 4 only). "해설 답 채택 후 승인" copies the printed
  solution's answer into the grading answer and approves.

The older Preview under
`screens/design_preview/yggdrasill_manager/textbook_review/` with mock data is
superseded by this screen.

## Checks

- `tools/db_test`: `test/textbook_manual_guard.test.mjs`,
  `test/textbook_review.test.mjs` (`node --test`).
- `gateway`: `test/textbook_manual_guard.test.js`
  (`node --test "test/**/*.test.js"`).
- `apps/yggdrasill_manager`: `test/textbook_review_preview_test.dart`.
- `supabase/functions/ai_think`: `textbook_problem_review_test.ts` (image
  parsing, common-stem combining, `isReviewTodo`). AI tests use
  `FakeAiProvider` and do not assert model wording.

## Open questions

- Whether to re-grade already graded student records after an answer
  correction.
- Publisher terms before sending textbook pages to an external AI.
- The authoring and stage dialogs do not yet show protected counts.
