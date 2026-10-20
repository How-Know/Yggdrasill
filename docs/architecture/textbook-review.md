# Textbook Review

This note covers phase 1 of reviewing migrated textbook problems: protecting
human corrections from machine re-runs, recording review findings and owner
decisions, and the manager-app "문항검수" tab that shows them.

Status (2026-10-14): manual protection, the review tables, the load check, and
the decision RPCs exist in migrations that have not been pushed yet. The gateway
guard is in place. The manager tab exists only as a design Preview with mock
data. The AI stages are not built.

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
| 1 | 해설 전사 | `solution_text` | Planned |
| 2 | AI 독립 풀이 | `solve` | Planned |
| 3 | 대조·판정 | `compare` | Planned |
| 4 | 렌더 검수 | `render` | Planned |
| 5 | 개념서 | `concept` | Planned |
| 6 | 마감 | `close` | Planned |

Planned stages write findings with proposals and never change data directly.

## Manager tab

The Preview lives in
`apps/yggdrasill_manager/lib/screens/design_preview/yggdrasill_manager/textbook_review/`
and uses mock data. Run `flutter run -d windows` in
`apps/yggdrasill_design_preview` and open "문항검수" in the manager hub.

- A stage strip shows progress and the decisions left per stage.
- The item list filters by decision needed, held, passed, or all.
- The detail view shows the evidence (problem, grading answer, AI solution,
  solution position) and one card per finding with "무엇이 문제인가" and
  "어떻게 고칠까" (current value, new value, reason, what changes, what stays).
- Owner actions: apply the proposal, edit directly, no problem, hold, reopen,
  release protection.
- A stale proposal shows a notice under its title, and its apply button is
  disabled.
- The decision history is shown in full.

The production tab is wired to the RPCs only after the owner approves the
Preview.

## Checks

- `tools/db_test`: `test/textbook_manual_guard.test.mjs`,
  `test/textbook_review.test.mjs` (`node --test`).
- `gateway`: `test/textbook_manual_guard.test.js`
  (`node --test "test/**/*.test.js"`).
- `apps/yggdrasill_manager`: `test/textbook_review_preview_test.dart`.

## Open questions

- Whether to re-grade already graded student records after an answer
  correction.
- Publisher terms before sending textbook pages to an external AI.
- The authoring and stage dialogs do not yet show protected counts.
