# Textbook Review

This note covers phase 1 of reviewing migrated textbook problems: protecting
human corrections from machine re-runs, recording review findings and owner
decisions, and the manager-app "문항검수" tab that shows them.

Status (2026-11-14): the subunit workflow of the spec
`docs/specs/20261113-교재-문항-검수-흐름과-기준.md` is built (see "Subunit
workflow" right below). The review run only stores proposals; the problem bank
and the answer tables change only when the owner confirms a subunit. Older
sections below describe the parts that workflow uses; where they disagree with
"Subunit workflow", that section wins.

## Principles

- **Pilot first.** One mid-unit (개념+유형 중1-1, Ⅰ. 소인수분해) is reviewed in
  full to calibrate the checks before the scope grows.
- **Three axes.** Every finding belongs to one axis, and a pass on one axis does
  not stand in for another:
  - `fidelity`: matches the printed textbook (원본 충실도).
  - `validity`: mathematically sound (수학적 타당성).
  - `output`: what students see renders correctly (출력 품질).
- **Proposal only.** System checks and AI open findings and store proposals as
  staged values (`textbook_problem_analyses.staged_changes`). Owner edits before
  confirm are staged too. Nothing reaches the problem bank or the answer tables
  until the subunit confirm writes all staged values at once.
- **Keep and correct.** The source PDF is never changed. Errors in the printed
  source are recorded as correction notes.
- **Staff only.** Students never read review tables or functions.
- **AI through Edge Functions.** The OpenAI key stays in the `OPENAI_API_KEY`
  secret and every call records an `ai_runs` row (see `ai-think.md`).

## Subunit workflow

Spec `docs/specs/20261113-교재-문항-검수-흐름과-기준.md`. Manager code:
`services/textbook_workflow_service.dart` (work orders, confirm),
`services/textbook_workflow_runner.dart` (stage 2 runner),
`services/textbook_review_pipeline.dart` (AI review, `runAll`),
`services/textbook_problem_review_service.dart` (`stageChanges`,
`applyForConfirm`, ready judgement `isWorkflowReady`).

### Stage 1: crops (owner)

The owner draws problem regions per page and checks numbers, labels and set
headers. Crops are coordinates in `textbook_problem_crops`. Confirming the
crops writes a work order to `textbook_subunit_workflows`
(`crop_status = confirmed`, `pipeline_status = queued`).

### Stage 2: automatic run (no owner action)

`TextbookWorkflowRunner` runs it app-wide and stores `pipeline_phase`, so a
restarted app resumes from the stored phase.

1. **Extract and match, in parallel.**
   - The gateway worker reads the body PDF and creates the problems:
     `pb_documents`, `pb_questions` (stem, choices, figures, figure layout),
     `pb_question_sets` (common stem), and the crop link (`pb_question_uid`,
     `textbook_crop_question_links`). Progress is in
     `textbook_pb_extract_runs`.
   - A sub-key is extracted in full only when none of its crops has a body. If
     some have one, only the missing numbers are read, because a full
     extraction replaces every problem of the document, including hand-fixed
     ones.
   - The answer and solution PDFs are matched at the same time:
     `textbook_problem_answers` (grading answer) and the solution refs.
     For 수력충전 (`suryeok`), every subunit block restarts at 01 and one
     answer or solution page holds several blocks. So the model only reads the
     page structure (block headers with their body-page badge, then numbers
     and answers, via `/textbook/vlm/extract-answer-layout` and
     `/textbook/vlm/detect-solution-blocks`). Code picks the block from the
     header badge (`TextbookLayoutBlocks`, `textbookStageBlockForHeader`). It
     does not ask the model to find expected numbers, because the model then
     takes the same number from another block.
   - Answers that are not found stay missing and the run continues. It stops
     only when no answer page could be read.
2. **Answer sync.** The grading answers are copied to the problem-bank
   answers (`objective_answer_key`, `subjective_answer`).

   Steps 1 and 2 create the first values. They do not count as changes to
   reviewed data.
3. **AI review (`TextbookReviewPipeline.runAll`).** This step writes only to
   the review record. In order:
   1. Stages 1 to 3: the independent solve, the printed-solution transcription,
      and the student-view quality check of the V2 card.
   2. Solution figures: cut from the solution PDF for problems whose solution
      hints at a figure, with the placement in the original (`right` of the
      text or `below`). Code, not the model, then adds the arrangement
      (`arrangeSolutionFigures`): a `below` figure gets `align` (`left`,
      `center`, `right`) from its position inside the solution region, and
      neighbouring `below` figures whose heights overlap by half or more share
      a `row` number. `placement: left` (figure left of the text) is set only
      by hand (batch `solfig_arrange`).
   3. Stage 4: the problem card and the answer + solution card are compared
      with the original (figure size ratio, figure position, solution figure
      position).
   4. Pure engine issues without figures go on the engine hold list.
   5. The fix pass proposes stem, choice, common-stem, figure-layout and
      figure-crop fixes. Crops are cut from the body PDF and uploaded to
      storage, but only staged in the asset list.
   6. Math: answers are re-solved and settled where two of the three answers
      agree, and staged.
   7. Quality rules: common-stem duplication and the question type.
   8. The consistency check (no AI): figure count against `[그림]` markers,
      leftover '해' hints, `$` pairs, and answer mismatches.
   9. Problems whose staged values changed are rendered again **with the
      staged values** (`/pb/preview/custom-thumbnail`, no DB write) and
      compared with the original again, at most two rounds.
   10. The meta pass picks concepts from the unit's concept-book candidates,
       thinking codes, visual tags, and new-concept drafts.

   The subunit shows "준비됨 N/M". Blocked problems show their reason in the
   work screen.

### What stage 2 stores

| Where | What |
|-------|------|
| `textbook_problem_analyses` | AI solve and answer, solution transcription and its answer, solution figures (`solution_figure_assets`, with `placement`), math and quality judgement (`clean`, `issue`, `held`), render check and time, fix proposal, meta proposals, **staged values** (`staged_changes`) |
| `textbook_review_findings` | Blocking reasons and correction notes |
| `ai_runs` | Every AI call and its cost |
| Storage `problem-previews` | Figure files cut from the original; nothing links to them until confirm |

`staged_changes` keys: `stem`, `common_stem`, `choices`, `figure_layout`,
`figure_assets`, `common_figure_layout`, `answer`, `solution_transcribed`,
`solution_answer`, `question_kind`, `allow_subjective`. Each key records its
source (`ai` or `owner`). An AI re-run never replaces a key whose source is
`owner` (`textbook_review_stage_changes`).

A set question whose stem has no figure marker, while its common stem has one,
is drawn with the set's common figure layout
(`meta.set_model.common_figure_layout`), not with its own `figure_layout`.
The manager app sees this as `usesCommonFigure` and edits or resizes
`renderedFigureLayout`. It stages the size under `common_figure_layout`, which
is copied to the other set questions in the same way as `common_stem`. The
gateway preview override and the overview (`pb_common_figure_layout`) both read
it, and confirm writes it to every problem-bank question of the set.

### Stage 3: subunit confirm (owner)

Before confirming, owner edits in the work screen (stem, answer, solution,
figure layout and so on) are staged with source `owner`. Confirm
(`applyForConfirm` → `textbook_review_apply_staged`) fails as a whole when a
problem is engine-held, has an open correction note, or misses meta. Otherwise
one transaction:

- writes staged stem, choices, common stem (whole set), figure layout and
  figure assets to `pb_questions`, and the question type;
- writes staged answers to `textbook_problem_answers` and the problem-bank
  answers;
- publishes the solution, its answer and solution figures to
  `pb_question_solutions`;
- creates proposed new concepts (marked `origin = 'textbook_review'`) and links
  them;
- writes meta (concepts, thinking, arithmetic, three difficulty scores, visual
  tags, textbook label) to `pb_question_meta`;
- approves both axes, clears `staged_changes`, keeps the render check time;
- sets `confirmed_at` and `confirmed_by` on the workflow row.

After confirm, objective choices are generated for subjective problems through
the gateway. A failure there does not undo the confirm.

PDF solutions, the answer + solution card, search, statistics and test
building read only `pb_questions`, `pb_question_solutions` and
`pb_question_meta`. `textbook_problem_analyses` stays as the work record.
Learning-app visibility is still the per-book hide switch.

### Books reviewed before the spec (1-1, 1-2)

Spec section 5 applies: no full re-review. Instead, the consistency check, the
meta pass, the original-compared render check of every confirmed problem, and
the same pipeline for problems that stay blocked.

Figure size (spec 5-4, decided 2026-11-15): a figure blocks ready only when its
size differs from the original by more than ±30%, for every problem regardless
of when it was approved. Auto resize still targets 1.0×.

`apps/yggdrasill_manager/tool/textbook_batch.dart` (with `textbook_batch.ps1`)
runs these steps outside the app with the owner's session. It covers status,
consistency, meta, render recheck, `finish` (the pipeline on chosen problems),
staging owner fixes (`stem`, `answer`, `solution`, `layout`, `solref`,
`recrop`), solution-figure re-extraction (`solfig`), solution-figure
arrangement without AI (`solfig_arrange`, `solfig_recrop`), and reconfirm.
It uses the same services as the app.

How solution figures render (answer + solution card in the app,
`buildAnswerSolutionCardContent`; problem-bank PDF in the gateway,
`explanationBody`; both follow the same rules):

- A `[그림]` marker in the transcription is the figure's slot. Extra markers
  are dropped; figures without a marker go at the end.
- `right` / `left` figures sit beside the text before the marker. If there is
  no text before it (the solution starts with the figure), they sit beside the
  text after it: only the rest of the marker's line when there is any,
  otherwise everything up to the next marker.
- `below` figures follow `align` (default center).
- A `row` of two or more figures goes on one line, bottom-aligned, scaled down
  as one box when too wide. Text on the same line right after each marker
  becomes that figure's caption underneath (card: layout item `caption`, a
  horizontal group in `figure_layout.groups`).
- An owner-edited transcription (`solution_source = 'manual'`) gets no markers
  from the AI. Place them by staging the text with `solution`.

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
- Crops are stored as coordinates only. Storing crop PNGs was abandoned, so
  `storage_key` does not point to a file. Every stage that needs an image of
  the original renders it from the page PDF by coordinates.

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
`20261102030000_textbook_review_solution_vision_and_v2_render_check.sql`,
`20261102160000_textbook_review_unit_overview_arg_limit.sql`,
`20261102180000_textbook_review_one_touch_fix_and_engine_hold.sql`,
`20261103120000_textbook_review_original_and_figures.sql`.
Edge code: `supabase/functions/ai_think/textbook_problem_review.ts`
(prompt version `TEXTBOOK_REVIEW_PROMPT_VERSION`) and
`supabase/functions/ai_think/textbook_problem_fix.ts`. Manager code:
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
- Judgement: `math_status` is `pending`, `clean`, `issue`, or `approved`.
  `quality_status` has one more value, `held`: the problem is on the
  render-engine hold list (below). `quality_checks` keeps the stage-2 flags
  (`judged_from_v2_image`, `fidelity_ok`, `solution_vision`, `issue_kind`),
  `render_checks` and `render_checked_at` keep the stage-4 result
  (`issue_kind`, `engine_symptom` included).
- `issue_kind` classifies a quality issue: `data` (the stem or choices stored
  in the problem bank are wrong; fixable from the screen), `engine` (the V2
  renderer or markup conversion is wrong; needs a gateway code change),
  `figure` (missing or wrong figure), or `none`.
- `fix_proposal`: the corrected stem, choices and common stem
  (`{kind, stem, common_stem, choices, reason, reason_code, source,
  created_at}`). `source` is `system` (common-stem rule), `stage2`, or
  `fix_pass` (the original-comparison pass below, which adds
  `text_matches_original`, `engine_issue`, `figure_layout`, `figure_crops`,
  `figure_measure`, `fix_pass_at`). Once applied, `applied_at`,
  `applied_fields`, `applied_note` are appended. A stage-2 re-solve replaces
  the whole object.
- Engine hold: `engine_hold_note`, `engine_held_at`, `engine_held_by`,
  `engine_resolved_at`, `engine_hold_snapshot` (the quality and render checks
  at the time of the hold, for before/after comparison).
- `alternative_solutions`: a jsonb array of extra solutions the owner adds.

Reads go through `textbook_review_unit_overview(academy, book, grade, big, mid)`
(one row per problem with crop, problem-bank, answer, solution-ref and analysis
fields, including the problem-bank answers `pb_objective_answer_key`,
`pb_subjective_answer`, the original coordinates `item_region_1k` (falls back
to `bbox_1k`), the set header's `set_header_raw_page` /
`set_header_region_1k`, and the problem-bank figures `pb_figure_assets` /
`pb_figure_layout`). The function builds its row with several
`jsonb_build_object` calls joined by `||`; Postgres allows at most 100
arguments per call, so keep each call at 50 pairs or fewer.

### Confirmed values on the problem-bank side

`textbook_problem_analyses` is the review work record (proposals, render
results, engine holds, the AI solve). Confirmed values live with the
problem-bank question, and only the subunit confirm
(`textbook_review_apply_staged`) writes them:

- `pb_question_meta`, one row per question: concept and thinking ids,
  arithmetic counts, the three difficulty scores, visual tags, the textbook
  label.
- `pb_question_solutions`, keyed by question × kind × version (decision
  2026-10-14): the printed solution `body`, the solution's own answer `answer`,
  and `figure_assets`. `textbook_review_publish_solutions` copies them from
  the analysis row and deletes the rows when all three are empty.
  - `original` is the solution as printed, errors included.
  - `corrected` exists only for problems whose solution the owner corrected
    (owner decision 2026-11-16). Readers use `corrected` when it exists.

Textbook errors the owner handles (owner decision 2026-11-16):

- Solution error (`ai_solution_logic` finding, "해설 오류" banner): the owner
  only picks 교정 or 그대로 둠. No correction note is written. The AI attaches a
  minimally fixed solution as `proposal.target = 'solution_fix'`; 교정 stages
  it and `textbook_review_keep_solution_original` first saves the printed text
  in `textbook_problem_analyses.solution_transcribed_original`, so confirm
  publishes both kinds. A finding the owner closed is not reopened by a rerun.
  The render check compares the answer·solution card with the printed
  solution image, and the card of a corrected question shows the corrected
  text. So the render check input carries `solution_corrected: true` and the
  finding text as `solution_correction` (`solutionCorrectionInput`, when
  `solution_transcribed_original` is set and the card is not the AI solution),
  and the instructions say a corrected sentence that differs from the printed
  solution is not an issue; missing lines, broken text and solution figures
  are judged as before (owner decision 2026-11-24, after 2020 수능 나형 15 was
  blocked with "다른풀이의 마지막 설명이 원본과 다름").
- Answer or problem error (correction note): the owner adopts or dismisses it.
  Only the grading answer changes; the printed answer stays in the `original`
  solution row's `answer`. For a problem with an adopted note the render check
  does not flag a card answer that differs from the printed one.
- Figures inside a 보기 box (owner decision 2026-11-17): when the stem has one
  `[그림]` inside `[보기시작]`…`[보기끝]` (or a 박스) and the original shows
  several labelled shapes there, the box content is one figure. The fix stage
  merges separately measured shapes into one padded box
  (`mergeBoxFigureMeasures`) and re-crops only if the existing figure covers
  less than 95% of it. The review prompts treat the single image as normal.
  When automatic cropping is still wrong the owner uploads an image file from
  the figure editor ("N번 그림 직접 올리기", `stageManualFigure`, same storage as
  the problem bank's manual figure upload) and adjusts width and position
  there. Staged figures with source `owner` are not re-cropped by the fix
  stage (`ownerStagedFigures`) and the staging RPC skips AI writes to them.
- 보기 box in two columns (owner decision 2026-11-18): when every `[그림]` of
  the stem is inside the 보기 box, there are two or more, and two consecutive
  measured figures sit side by side in the original (`bogiFigureColumns`), the
  fix stage proposes `figure_layout.bogiColumns = 2`. The engine lays the box
  out in two columns for that flag, the same as the problem bank's
  `meta.bogi_box_columns = 2`. The flag travels inside `figure_layout`, so no
  new staged key exists; `figureLayoutSignature` includes it.
- Figure inside a text line (2026-11-18): when the fix stage measures a figure
  as `inline` (a small shape inside a sentence), the layout item gets
  `position: inline-text` with `heightEm` from the measured height
  (`inlineFigureHeightEm`), not `below-stem`. The V2 engine already had this
  position ("글 줄 안" in the figure editor); `renderStandaloneMathEnvironmentBlock`
  must not touch figure markers of lines that are not an aligned block, or the
  inline figure is consumed and later figures shift by one.
- Concept candidates by unit (owner decision 2026-11-18): the unit match is
  decided only by concept-book units (`concept_sources`). A concept created in
  review whose stored unit name happens to match (school exams share titles
  such as "2024 2학년 2학기 기말") does not make a unit match; without a
  concept-book match the whole grade is the candidate list.
- Other-semester retry (owner decision 2026-11-18): when the candidate scope
  is `grade` (no concept-book unit match, e.g. school exams) and the model
  picked neither a concept nor a new-concept draft for an item, the meta
  action picks once more for those items with the other semester of the same
  grade (`otherSemesterGrade`, 2-2 → 2-1). A second-semester final often
  includes first-semester content. Labels without a semester (공통수학2) are
  not retried. The retry is logged as its own `ai_runs` row.
- Tables with figures in their cells (owner decision 2026-11-17): the render
  engine cannot draw `[그림]` inside a `tabular` cell, so such a table is cut
  from the original as one figure. The fix stage asks the model for the whole
  table box (`whole_table`), replaces the `[표시작]`…`[표끝]` block in the stem
  with one `[그림]`, drops the cell measures, re-crops the table and lists the
  leftover cell assets in `figure_removals` (`mergeTableFigureMeasures`). If
  the model did not measure the whole table nothing is changed.
- Common stem guard (owner decision 2026-11-17): text that contains a 박스,
  보기 or 표 block is a condition of one problem, not a common stem. The
  duplicate-removal rule (`computeCommonStemFix` / `commonStemFix`) then keeps
  only the leading instruction as common stem and strips only that
  instruction from the stem; `stripCommonStem` returns null when only
  structure markers such as `[박스끝]` would remain; the fix stage does not
  accept a `corrected_common_stem` that contains such a block.
- Solution figure alignment (`solutionFigureAlign`): left/center/right comes
  from the share of the left margin inside the solution region (below 1/4
  left, above 3/4 right, else center), because the stored region is usually
  the full column and wider than the text. The pipeline recomputes the
  alignment of existing solution figures before the solution figure pass.
  When a solution has several regions on the same page (it continues in the
  next column), the region that overlaps the figure most is the reference
  (`arrangeSolutionFigures`); taking the first region of the page judged
  every figure of the second column as "right".
- Solution figures of a solution with more than one region
  (`extractSolutionFigures`): each region is rendered and sent as its own
  image (`solution_images_base64`, at most 8), and the AI returns a piece
  number per figure (`pieces`, 1-based) with a box relative to that piece;
  `solutionFigurePiece` maps it back to the page. A figure without a valid
  piece number is not attached. A one-region solution is sent as before
  (`solution_image_base64`). Reason: on the regions stacked into one tall
  image the model's boxes were several lines off (figure cut at the bottom,
  the lines above included, a whole column taken as a figure, figures
  missed). `dry_run: true` on the Edge action returns the boxes without
  writing the `[그림]` markers into `solution_transcribed`.
- Tighten pass (`_tightenSolutionFigures`): the first box of every found
  figure is widened (`expandSolutionFigureRegion`: 40 up and down, 25 left
  and right, inside the solution region it was found in), rendered again and
  sent in one call per question (`tighten: true`, `figure_images_base64`);
  the AI returns a box around the figure only (`boxes`, null when none).
  The Edge action writes nothing in this mode. When the call fails the first
  box is used and the failure is listed in the run errors. Reason: even per
  region the first box sometimes held the solution lines below a graph or
  cut a figure that sits next to another, and `solutionFigureKeepRows` does
  not apply when the figure itself touches the crop edge. Verified on two
  questions only (2025 9월 공통 15, 4월 확통 29).
- A centered solution figure is centered on the solution text width: the
  solution body has a `\leftskip` of the number width and `\centering`
  cleared it, which put the figure left of the text center by half the
  number width (`explanationFigureIncludes`, both `\hfill`; `max width` is
  `\linewidth-\leftskip`). The horizontal group (`adjustbox ... center`) was
  not changed or checked.
- Staged solution text and markers: the figure search writes the markers into
  the stored `solution_transcribed`, but the card uses the staged text when
  there is one (the consistency check stages a solution with upright point
  names). So after a search the Edge action also moves the markers of an
  AI-staged solution text to the same places (`syncStagedFigureMarkers`,
  through `textbook_review_stage_changes` with source `ai`; the result row
  carries `staged_sync`). It works by line: the line that follows a marker in
  the stored text is looked up in the staged text (spaces, `$`, `\mathrm`
  and braces ignored). If one marker's line cannot be found, nothing is
  changed. A solution text staged by the owner, a manually edited solution
  and `dry_run` are left alone.
- Box end: `sanitizeLatexControlChars` (it restores LaTeX commands that lost
  their backslash in JSON, `\nabla`, `\neq`, `\nu` ...) turns a line break
  into the two characters `\n` when the next line starts with lowercase
  letters followed by `(`, `_`, `^`, `{` ... (`f(a)`, `a_3`). The following
  line then arrives in the same parsed line as `[박스끝]`, and the whole line
  used to go into the box. `splitAfterBoxEnd` now closes the box at the mark
  and puts the rest after it.
- Single-letter recovery is off (owner decision 2026-11-21): the same step
  no longer turns a line break followed by `e`, `i` or `u` plus a non-letter
  into `\ne` (≠), `\ni` (∋), `\nu` (ν). It cannot be told from a line that
  starts with those letters. Before the change 28 stored stems (복소수 units
  of 수력충전·쎈·RPM 공통수학1, 행렬, 수열 tables, two school exam files;
  none reviewed yet) printed "∋= j인 성분", a table cell "≠" for `e`,
  "∋ +2i²+…"; after it none of the 28 has such a command in its TeX (two
  typeset locally and viewed). Searched on that day: every column of
  `pb_questions` (88,174 rows) and `textbook_problem_analyses` had no place
  where the recovery was right; every hit was a real line start. Longer
  commands are still recovered (`\neq`, `\neg`, `\nearrow`, `\nabla`,
  `\natural`, `\notin`, `\nwarrow`), and commands typed with their backslash
  are untouched. The helper for choice and answer text on the render path
  (`recoverMangledLatexNewlineCommands` in `render_engine/utils/text.js`)
  follows the same rule; no stored choice or answer had the form.
- Extraction (`recoverMangledLatexControls` in
  `extract_engines/vlm/client.js`, owner decision 2026-11-21): there the
  model output really can arrive broken, so only this much was taken out: a
  line starting with `i` or `u` is left alone, and a line starting with `e`
  is left alone when `^`, `_`, `=` or `&` follows (nothing can follow ≠ that
  way). `\ne` before a space, digit or letter is still recovered, and so are
  the longer commands and `\r…`. Raw model output is not stored, so whether
  the model ever sent a broken `\ne` could not be checked. One stem was
  stored as `[수식제시]\ni^2=-1` (created 2026-07-24, before the single-letter
  rule of 2026-09-14: the general rule "line break + lowercase + `^`" did
  it); it was corrected in the DB with the owner's approval
  (개념원리 공통수학1 복소수 필수유형 1번). A stem stored that way cannot be
  told from a real `\ni` by the engine.
- Not changed: the older engine `render_engine/xelatex/template.js`
  (`mathEngine: 'xelatex'`) keeps the old rule; which callers still use it
  was not looked up.
- ▲▼■★ typed as characters inside math are printed with the body font
  (`\text{★}`); the math font has no such glyphs and printed nothing, so
  "(★)" in a solution came out as "()".
- Figure layout proposals and `applied_at`: the staging RPC stamps
  `fix_proposal.applied_at` on any staged field (an answer proposal too), so
  `hasPendingFigureProposal` also checks the staged notes: a layout proposal
  stays pending until a figure field was staged after `fix_pass_at` (the
  resize note `kFigureResizeNote` does not count). With no notes after the
  pass (already confirmed) it counts as applied.
- Figures inside sub-questions (`subQuestionFigurePlacement`, owner decision
  2026-11-17): measured "beside text" means beside the sub-question label, so
  they are placed below that label, left aligned, not beside the stem.
- Figure width cap (owner decision 2026-11-17): figures are never grown past
  one column of the narrowest template (과제형). `kCardColumnWidthEm` /
  `MAX_WIDTH_EM` = 22em, computed from the 과제형 geometry (A4 assumed,
  hmargin 11.34mm, two columns, 11pt), not measured from a render. A figure
  already at that width (`figureAtCardWidth`, sent to the render check as
  `figure_at_card_width`) is not blocked by a "smaller than the original"
  size ratio; "larger than the original" still blocks. Leftover figures whose
  original region lies inside another figure are dropped when staging an AI
  fix (`pruneContainedFigureAssets`).
- Table-shaped choices (2026-11-17): a question whose `pb_questions.meta` has
  `choice_layout = 'blank_table'` (or `is_blank_choice_question`) is drawn by the engine as a table with
  `blank_choice_labels` as the header row; each choice text is split into cells by commas
  (`정사면체, 정삼각형, 4`). The fix stage reads that meta, sends `blank_choice_labels` to the model, and
  converts a choice written as a one-row `array`/`tabular` to the comma form (`blankChoicesFromArrays`),
  also when the stored choices already have that shape. The header row is not part of the stem.
  Header row as a staged value (2026-11-18): the fix stage may return `corrected_blank_choice_labels`
  (same count and order; kept only when the rendered text differs, `normalizeBlankChoiceLabelsFix`), stored
  as `fix_proposal.blank_choice_labels` and staged under the key `blank_choice_labels`
  (`textbook_review_stage_changes`). The current header is the staged value over the problem bank value
  (`currentBlankChoiceLabels`). The app sends the staged header to the gateway as
  `questionOverrides.blank_choice_labels`; confirm writes `pb_questions.meta.blank_choice_labels`
  (`textbook_review_apply_staged`). Engine: a header label containing LaTeX is typeset as math, each data
  column starts at its base width and is widened by TeX to the widest cell of that column (limit: the
  remaining line width divided by the column count), and rows with a fraction get a taller strut.
  Extraction keeps the braces of a math command in a header (`\overline{DC}`, not `\overlineDC`).
- Image choices (2026-11-18, owner decision): for a question whose choices ①~⑤ are all figures, the row
  arrangement (2 rows ①②③/④⑤ or 3 rows ①②/③④/⑤) is the user's setting and the figure size follows it.
  The render check gets `image_choices: true` and does not treat a different arrangement or choice-figure
  size as an issue; when the only figures are the choice figures, `figure_position_ok` is true and
  `figure_size_ratio` is null (`pbQuestionFiguresAreChoicesOnly`). A missing choice figure, a wrong
  number–figure pairing, or an unreadable figure is still an issue.
- Problem number inside a figure crop (2026-11-17): when the fix stage crops a figure from the original
  and the crop region overlaps the problem number box (`textbook_problem_crops.bbox_1k`, accepted only
  when it is number-sized and inside the item region), the overlapping part of the PNG is painted white
  before upload (`whiteOutProblemNumber`; the asset gets `number_masked: true`). The crop region itself is
  not changed. Set-header figures are not masked.
- Small figure inside a text line (owner decision 2026-11-24): the crop margin (12 per 1000 of the
  question image on each side) is as large as the shape itself, so the next letter and pieces of the
  lines above and below came into the PNG; the engine could then not trim the white margin, the
  shape printed small, and every re-crop repeated it (2019 수능 나형 18, 2016 나형 17, 2018 나형 16).
  For a figure measured as `inline`, `whiteOutUnrelatedInk` paints white every ink blob that does not
  reach the measured box (the asset gets `neighbors_cleared: true`). The margin is unchanged, a figure
  line that runs past the measured box stays, and nothing is changed when the measured box holds no
  ink. Other placements are not touched.
- Answer/solution review card uses the PDF solution-sheet layout (owner decision 2026-11-17): a text answer
  is rendered through `/pb/preview/custom-thumbnail` with `cardKind: 'explanation'`
  (`renderExplanationCardThumbnail`; engine option `explanationCardOnly`), i.e. the same
  `explanationEntry` typesetting as the student PDF 해설지: one column of the two-column A4 sheet,
  10pt, and line breaks allowed at operators, so a long equation wraps instead of being cut. Image
  answers still use the old question-card path. The learning app's in-app "해설" button is a different
  renderer and is not what this card shows. An answer that mixes Korean with a formula is still math
  where the formula starts with a command (`\triangle AGC\equiv \triangle HBC (SAS합동)`, 2026-11-18):
  `formatAnswerSegmentTextMode` keeps the parenthetical Korean as text and wraps the command run in math.
  The same formatter feeds the quick-answer table.
- Review rounds retry a failed chunk once and report problems that ended
  without an AI solution, instead of moving on silently.
- Problem body the printed original gets wrong (owner decision 2026-11-17):
  the owner edits the stem and marks the problem "원본 오류 교정"
  (`textbook_review_mark_source_correction`). The mark keeps the problem
  bank's stem and choices from before the edit in
  `textbook_problem_analyses.source_correction` (`{stem, choices, marked_at}`;
  an existing snapshot is never replaced) and the overview returns it. The
  blind solve, the fix stage and the render check then get `source_corrected`,
  `printed_stem` and `printed_choices` (the fix stage also drops, in code, a
  stem or choices proposal that equals the printed text, together with that
  run's answer proposal: `dropPrintedRevert`): where the printed text and the card differ, the
  owner's text is the reference; everything else (figure, choices, the rest of
  the text) is still compared with the original. The ready rule is unchanged;
  the mark only changes what the AI compares. Unmarking clears the snapshot.
  The printed text is kept on the review side only. Mark before confirming
  the edit, because after confirm the problem bank already holds the edit.

The PDF export solution section (gateway `attachSolutionExplanations`), the
learning app's confirmed-answer "해설" button, and the problem-bank difficulty
scores read only these tables. The AI solve is never shown there. Both tables
are readable by academy members (staff) only. The 2026-11-13 migration
`20261113180000_pb_question_solutions.sql` moved the values of every problem
already approved on both axes (1-1 and 1-2); moved rows have an empty
`confirmed_by`. The old 1-1/1-2 concept tags came from the wrong candidate
list (spec 5-6), so `20261113181000_pb_question_meta_clear_old_concepts.sql`
empties `concept_ids` and `concept_score` in the moved meta rows. The meta
pass picks new tags for every item (`meta_checked_at` is empty), and the
subunit confirm fills the rows.

### Owner edits before confirm

The work screen saves review-record fields (AI solution, visual tags,
alternative solutions) directly through `textbook_review_save_item_edit` with
`p_sync_pb_answer = false`. Everything that ends up in the problem bank is
staged with source `owner` through `textbook_review_stage_changes`:

- Math card: the grading answer, the transcribed solution and its answer.
  "해설 답 채택 후 승인" and "AI 답 채택 후 승인" stage the chosen answer and
  mark the math axis `clean` (the approval itself happens at confirm).
- Quality card: the editor prefills the proposal (text, common-stem rule,
  figure layout). "품질 검수 승인" stages whatever the editor changed (cutting
  and uploading proposed figures first) and marks the quality axis `clean`.
  "수정만 적용" stages without marking and renders the V2 card again with the
  staged values. "①′ 미리보기" shows the edited text as a V2 card.

The confirm writes these values with the RPCs that used to write them at once:
`textbook_review_apply_problem_fix` (stem, choices, common stem for the whole
set, `meta.figure_layout`, `meta.figure_assets`; new assets also set
`figure_count`, `figure_refs` and clear `figure_review_required`) and
`textbook_review_save_item_edit` (answers, with the problem-bank sync through
`textbook_review_sync_pb_answer`: `objective_answer_key` when the answer parses
as choice numbers, else `subjective_answer`). Changing the transcribed text
sets `solution_source = 'manual'`. `pb_questions_emit_revision` logs the
changes as usual.

### Render-engine hold list

A quality issue the screen cannot fix (`issue_kind = engine`, or any issue the
owner judges as an engine problem) is put on hold instead of being approved or
left as `issue`:

- `textbook_review_set_engine_hold(crop_ids, hold, note)`. Holding sets
  `quality_status = 'held'`, stores the note (defaults to the render or quality
  issue title) and `engine_hold_snapshot`, and moves the problem's open quality
  findings to `held`. Releasing sets `quality_status = 'issue'`,
  `engine_resolved_at`, and reopens the findings.
- A held problem keeps `held` through stage 1-3 and stage 4 re-runs; only an
  owner action (release, or quality approval) changes it. Approving a held
  problem sets `engine_resolved_at`.
- Counting: `textbook_review_books_and_units` reports `quality_held_count`
  separately. The screen shows `품질 승인 X / (N − held)` and `엔진 보류 K
  (별도 관리)`, so approved problems count as done and held problems do not
  drag the unit's progress.
- `textbook_review_engine_hold_list()` returns, across all books, the units
  with held problems or problems resolved in the last 30 days, with crop ids.
  The screen's "렌더 엔진 목록" dialog
  (`textbook_review_engine_hold_panel.dart`) lists them with the judgement at
  hold time, re-renders the two V2 cards on demand with the current engine
  (the gateway renders fresh on every call, so "다시 렌더링" is just another
  request), runs the stage-4 check again for the held set, and approves the
  ones that come back clean, one by one or in bulk. This is the loop for
  "fix the renderer, then look at the problems that were broken before".

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
3. For every problem it also renders the **original problem** from the body
   PDF (`raw_page` + `item_region_1k`, same padding) and, for set problems,
   the set header region. Crop PNGs (`storage_key`) do not exist, so nothing
   is signed from storage; the original is always rendered from the PDF.
   Renders are cached per page region for the session.
4. It posts `crop_ids` plus `images` (per crop: `solution_image_base64`,
   `v2_problem_url`, `original_image_base64` with `original_width_px`,
   `original_height_px`, `original_region_1k`, `original_raw_page`, and
   `set_header_image_base64`) to `ai_think` action
   `textbook_problem_review`, six problems per call. Only https URLs and
   png/jpeg/webp base64 under 4M characters are accepted.
5. After the unit is done it runs the render check pass, then the fix pass
   (both below).

Sending textbook page images to the external AI is approved by the owner
(same basis as the solution crops).

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
  - Answer and explanation are strictly separated: `solution_answer` holds
    only the final answer, and `solution_transcribed` holds only the pure
    explanation body (never the problem number, `"16 답 ×"` / `"[정답] ③"`
    answer lines, or `"[해설]"` / `"[풀이]"` headers, which are stripped by
    `cleanSolutionTranscribedText` in TypeScript, Dart, and SQL
    `textbook_review_clean_solution_text`).
- Stage 2 runs in parallel with stage 1. The model sees the V2 render of the
  problem (detail high), the original problem rendered from the body PDF
  (detail high) and, for set problems, the set header. It solves
  independently (reading the original PDF and set header images when the
  stored text is incomplete) and judges quality **from the V2 image, as a
  student would see it**, not from the stem text. The original is for fidelity
  (`fidelity_ok`: does the render match the print).
  - Every problem with figures goes through the fix pass (original
    comparison, figure size and placement), even when stage 2 found nothing.
  - Pure rendering engine issues (`issue_kind = 'engine'`, text matches
    original, no figures) are held (`quality_status = 'held'`) and excluded
    from the active error count.
  - Stage 2 sets only `clean`, `issue` or `held`. It never approves and never
    syncs answers to the problem bank; approval happens at the subunit
    confirm.
  Set problems get the common stem combined with the item
  (`[공통 지시문] ... [문항] ...`). When it finds an issue it classifies it
  (`issue_kind`) and, for `data` issues, proposes the corrected stem or
  choices based on the stored markup (`stem_raw` in the payload); the proposal
  is saved as `fix_proposal` and is never applied by the model.
  One data error is detected by rule, not by the model: common-stem
  duplication (`commonStemFix`, same in the Edge Function and the manager
  service). The renderer draws `meta.set_model.common_stem` + item stem, so
  the instruction appears twice.   Two shapes are handled: (1) the instruction
  is repeated at the head of the item stem → strip it from the stem (only when
  the common stem itself looks like an instruction sentence, so a corrupted
  expression fragment such as `'36'` never trims the item stem); (2) the
  common stem holds the whole item (`common_stem == stem`) → the common stem
  becomes its instruction paragraph (`looksLikeInstruction`: first paragraph if
  it is an instruction, else the first subsequent instruction paragraph when
  the first paragraph is an expression such as `'36=2^2×3^2'`) and the item
  stem the rest.
  Shape 2 is applied only when the common stem actually ends with this
  item's own text, so a legitimate multi-paragraph common stem (condition
  box) is left alone. The rule forces `stem_ok = false`, `issue_kind = data`,
  and stores a `fix_proposal` with `stem` and, for shape 2, `common_stem`
  (`source: system`, `reason_code: common_stem_duplicate`).
  The fix is staged; the confirm applies it through
  `textbook_review_apply_problem_fix(..., p_common_stem)`, where
  a common-stem change is written to every `pb_questions` row of the same
  set (same `document_id` and set key, or sibling crops in the same
  `is_set_header` range when no set key was stored yet) as well as
  `pb_question_sets.common_stem` and `pb_delivery_units.source_meta`, because
  the renderer takes the group's common stem from its first item or delivery
  unit. The screen recognises both shapes on already-reviewed rows and
  prefills the editor (common stem field + item stem).

### Automatic fixes inside the run

The old "품질 일괄 처리" / "수학 일괄 처리" buttons are gone. `runAll` does the
same work, but it stages the results instead of writing the problem bank and
marks problems `clean` instead of approving them:

- Quality (`_bulkQualityFixes`), in order:
  1. every common-stem fix in the unit (looping a few times, because fixing
     one set's common stem exposes the head duplication on its other items);
  2. question type fixes (below);
  3. up to two rounds of:
     a. the fix pass (below) for every problem that needs it;
     b. every pending proposal (text, figure layout, figure crops) is staged;
        proposed figure crops are cut from the body PDF and uploaded first;
     c. the stage-4 render check of the **staged** values, compared with the
        original, for the changed problems;
     d. problems whose V2 figure size is off get every `widthEm` multiplied by
        `1 / ratio`, staged, and checked again.
     The second round runs only if some problem still needs a fix pass.
  What remains are engine problems and issues the AI could not fix; the
  owner sees them as blocked problems.
- Math (`_bulkMathFixes`), in order:
  1. re-solves every math `issue` the two rules below cannot settle
     (`needsMathResolve`), with the current problem text and the original
     image. This is stage 2 with `math_only` (below);
  2. stages the printed solution's answer where the printed answer and the AI
     answer agree but the grading answer differs;
  3. keeps the grading answer where it equals the AI answer (two of three
     agree).
  Answers are compared after `normalizeAnswerForCompare` (spaces, `$`,
  braces, `\left`/`\right`, multiplication signs). What remains are real
  disagreements.
- The "오류·불일치" tab counts a problem when either axis is `issue` or it
  has an open finding, so a quality approval alone does not remove a math
  error. The tab label shows the math and quality counts.

### Question type

The quality card shows the problem-bank type (객관식 / 주관식 / 서술형, read
like the problem-bank badge from `question_type`, `allow_objective`,
`allow_subjective`, `meta.allow_essay`), the rule type, and the AI's type
(`quality_checks.question_kind_ai`, stage 2). The rule: an essay expression
("서술하시오", "과정을 쓰시오", "풀이 과정", "이유를 쓰시오", "설명하시오",
"증명하시오") in the combined stem makes it 서술형, otherwise two or more
choices make it 객관식, else 주관식. The owner can click a type. The run and
the confirm stage a rule-type mismatch as `question_kind`, and the confirm
applies it through `textbook_review_set_question_kind(crop, kind)`. That
function sets only what
the type requires: 객관식 turns objective on and leaves subjective as is (dual
mode); 주관식 turns subjective on and leaves objective as is (generated
choices); 서술형 sets subjective and essay on and objective off.

The stem / choices / common-stem editor is always shown on the quality card,
so the owner can edit any problem by hand.
- Stage 3 compares the grading answer, the transcribed solution answer (when
  present), and the AI answer, and proposes concept ids, thinking codes and
  draft proposals. The solution it compares with follows the storage rule
  (`effectiveSolution`): the owner's manual solution, else this run's Vision
  transcription, else the stored Vision transcription (no solution image
  sent, or Vision could not read it this time). For problems with figures it
  also receives the problem image (`compareFigureImages`: the original, else
  the V2 card), so it can read the figure when the answers differ
  (2026-11-16; before that it saw text only).
- `math_only: true` (with `crop_ids`) re-solves only math `issue` problems and
  writes only the math side: AI solution and answer, arithmetic counts, match
  mode, `answer_matched`, `mismatch_reason`, concept and thinking ids, draft
  proposals, `analyzed_at`, `math_status`, and the `ai_answer_compare`
  finding (plus the transcription when a solution image was sent for a
  problem without one). Quality checks, `quality_status`, `fix_proposal`,
  render checks and `solved_at` stay: `solved_at` marks the stage-2 quality
  judgement that stage 4 compares fix times against. A problem the model left
  out of its answer is skipped, not cleared.
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
It posts `{crop_id, problem_url, answer_solution_url, solution_kind}` plus the
original images (same fields as stage 2), four problems per call (the Edge
Function accepts up to eight). The model reads the cards as a student and
reports `problem_ok`, `answer_ok`, `solution_ok`, and, when the original is
attached, compares the problem card with it: `fidelity_ok` (same text,
choices and figures), `figure_position_ok`, and `figure_size_ratio` (V2
figure size relative to the text, divided by the same in the original; null
without figures).

Writes: `render_checks` (with `original_compared`, `flagged_after_approval`),
`render_checked_at`, finding `check_key` `ai_v2_render_student_view` (axis
`fidelity` when the original differs, else `output`), and `quality_status`:
`approved` and `held` stay as they are; otherwise `clean` only when every
check passes (size ratio within 0.8 to 1.25), else `issue`. When the original
was compared, that result supersedes the stage-2 flags (the stage-2 finding is
resolved on a pass), because stage 2 may have judged an older render. An
approved problem that differs from the original keeps its approval and gets
`flagged_after_approval` with a title prefixed `[승인 후 원본 대조]`. A finding
opened for a held problem is created as `held`, and re-runs keep a finding's
current status. Every call records an `ai_runs` row with feature
`textbook_problem_review` or `textbook_problem_render_check`.

### Fix pass (`textbook_problem_fix`)

Runs after the render check (in `runAll`, and from the per-problem button)
for problems the manager selects with `needsFixPass`: an original image
exists, and the problem is `issue`, or `clean` with figures; it has not run
since the last solve (`fix_pass_at` absent), or the problem is still `issue`
after its proposal was applied. The Edge Function skips any requested problem
without an original image. Three problems per call (at most four); per problem
the app sends the original (detail high), the set header (auto) and the V2
card (high) with the stored stem, choices, common stem, figure count and the
open issue titles.

The model compares the original with the stored markup and returns the full
corrected stem, choices and common stem (or `text_matches_original`), an
`engine_issue` note when the markup is right but the render is wrong, and for
figures: each figure's box in the original (`bbox_1k`), its placement
(`right_of_text`, `left_of_text`, `below_text`, `inline`, with `align`), its
state on the V2 card (`ok`, `missing`, `cut`, `size`, `position`, `unknown`),
and a sample text block (`bbox_1k` + line count). Code, not the model, turns
that into a layout:

- text em in pixels = sample height / ((lines − 1) × 1.7 + 1), the V2 line
  pitch;
- `widthEm` = figure width in pixels / em, clamped to 4 to 40 in 0.5 steps;
- `right_of_text` → `inline-right` / anchor right, `left_of_text` →
  `inline-left` / left, otherwise `below-stem` with the given alignment;
- figure *i* in the original maps to the *i*-th asset (approved first, then
  newest, by `figure_index`; key `idx:N`). A figure without an asset gets a
  new index and a `figure_crops` entry (`missing`); a `cut` figure gets a
  crop for its own index. Missing `[그림]` markers are appended to the stem.
- a `missing` figure beyond the stem's `[그림]` slots (after the existing
  assets) is not cropped automatically: it moves to `figure_crops_unslotted`
  with its layout item dropped and no marker added, because a figure inside a
  '해' hint looks like this. The figure editor shows it as "확인 필요" and the
  owner attaches it with a button (crop + layout item + `[그림]` marker).

The result is stored as `fix_proposal` (`source: fix_pass`). When a
common-stem rule proposal is still pending, its text is kept and only the
figure fields are added. Staging a figure crop converts
the box from original-image coordinates to page coordinates
(`cropBoxToPageRegion`), renders that region from the body PDF at about
900 px, uploads it to `problem-previews` as an approved manual asset
(`source: textbook_review_original_crop`), and stages the full asset list as
`figure_assets`; the confirm writes it to `pb_questions`. The renderer picks
the newest approved asset per index, so the crop replaces a cut figure.

Figures that sit at the end of a line of a multi-line `aligned` equation (for
example the arrow and blank between two transformation steps) are written as
`[그림]` at the end of that row with layout `position: inline-text`. The V2
engine puts them in an extra column right of the equation, so they line up
vertically, and `heightEm` / `offsetYEm` / `offsetXEm` set their size and
shift (`offsetYEm` moves the figure down, between two rows).

### Solution text rules (2026-11-20)

Added with the mock exam review; they apply to every scope (textbooks, school
exams, mock exams). Text stored before that day is not converted.

- **One printed line, one paragraph.** `solutionLinesToParagraphs` (Edge,
  `textbook_problem_review.ts`) runs where AI output is saved (solution
  transcription, the AI solution, the logic fix, the fix pass): every printed
  line becomes its own paragraph (a blank line between lines), because the V2
  engine starts a new line only at a blank line. Multi-line math and the rows
  of a text table (`| a | b |`) stay one block. A manual edit needs a blank
  line to start a new line.
- **Length.** The transcription sent to the compare step and to the fix pass
  is cut at `SOLUTION_TEXT_MAX_CHARS` (12,000). The old cut (3,000 / 2,000)
  dropped the end of a long solution and produced a false "해설 논리 오류".
- **A settled solution is not transcribed again.** The fix pass re-reads the
  printed solution for problems whose answer is in dispute. When the answer is
  not in dispute and the printed solution was already found and transcribed,
  its re-transcription is dropped (`isSolutionSettled` in the Edge Function,
  `solutionSettled` / `stageableSolutionTranscribed` in the manager). "Not in
  dispute" means the math axis is `clean` / `approved`, or the three answers
  agreed and the axis is `issue` only because of a solution logic error
  (`answer_matched` with a `mismatch_reason` that starts with
  `SOLUTION_LOGIC_REASON`). Staging the re-transcription replaced the
  stage-1 text, which has the print's notation (`\mathrm` point names) and the
  `[그림]` markers placed by the solution-figure step. The logic error itself
  stays open until the owner picks the corrected text or the original.
- **Solution figures are searched again once per run.** A problem whose
  figure search found nothing (`solution_figures_checked_at` set, no assets)
  and whose render check reports a missing solution figure
  (`solutionFigureSearchMissed`) goes through the search once more in the
  same run, then through the render check. Nothing else clears
  `solution_figures_checked_at`.
- **Failed answer·solution card.** The manager sends the render error with the
  render check (`answer_solution_error`); the problem is blocked by the
  existing "V2 렌더 이상" / render-engine hold and the reason is stored. See
  `mock-exam.md`, "Failed answer·solution card".
- **The card page grows with the solution.** The review's answer·solution
  card is one unbreakable block on one page. The page height comes from the
  text (`explanationCardPageHeightMm` in the gateway: 800 mm at least, more by
  line count and figure count, 5,000 mm at most). A block that still does not
  fit leaves page 1 blank, so the gateway answers
  `render_failed: explanation_card_overflow` instead of a blank card.
- **Enclosed characters print in the text font.** Circled and parenthesized
  numbers, letters and Hangul (①, ⑴, ⒜, Ⓐ, ⓐ, ㈀, ㉠, ㉮) have no glyph in the
  math font, so the V2 engine wraps them in `\text{}` (`template.js`). A
  multi-level case label such as `(ⅰ-ⓐ-①)` is printed as one text run; left as
  separate math pieces its hyphens became minus signs and the space after it
  was lost.
- **`\\` is not a delimiter.** The consistency rule `math_delimiters`
  (`mathDelimiterProblems`) removes line-break commands before counting, so
  `(x\geq0)\\(k+x)` inside `cases` is not reported as an unpaired `\(`.
- **The fix pass does not move a computed solution position.** For a problem
  with a math issue the fix pass may return the box where it found the
  solution (`corrected_solution_bbox_1k`). The box is written to
  `textbook_problem_solution_refs` only when the stored row was not edited by
  a person and has no `continuation_regions` (`solutionRefReplaceable`).
  Textbook rows have `continuation_regions = null` and behave as before; mock
  exam rows carry the regions the gateway computed and are left alone. See
  `mock-exam.md`, "Solution regions".
- **`[출제의도]` head.** Both transcription prompts (review, fix pass) ask for
  the intent sentence as the first line with the head `[출제의도]`, whatever
  the page prints.
- **Figure position "선지 아래" (`below-choices`).** The V2 engine prints such
  a figure after the choices, for text choices only. Nothing sets it for
  textbooks or school exams on its own; the mock consistency rule does
  (`mock-exam.md`, "Print conventions set by code") and the owner can pick it
  in the figure settings. The fix pass keeps it when the AI measures the
  figure as below the text (`buildFigureProposal`).
- **No line break between math and the word attached to it (2026-11-21).**
  Body text breaks only at spaces (`\XeTeXlinebreaklocale ""`), but TeX also
  takes the end of an inline formula as a break point. Cards therefore ended a
  line with "상자 A" and started the next with "에서", or left an opening
  parenthesis alone at a line end ("(" / "단, …"). `smartTexLineCore`
  (`xelatex_v2/template.js`) now writes `\penalty9999{}`
  (`MATH_GLUED_HANGUL_PENALTY`) after an inline formula when Hangul follows
  with no space. With 9999 the line breaks there only when nothing else
  fits; `\nobreak` would push a long formula plus its particle over the right
  edge. A space after the formula is still a normal break point, and nothing
  is added before a formula. This applies to every card and PDF the engine
  makes, so line breaks of cards rendered before can move. Test:
  `gateway/test/xelatex_v2_math_particle_break.test.js`.

## School exam papers (내신기출)

Built 2026-11-16. School exam papers go through the same subunit workflow as
textbooks. They are uploaded and reviewed from the manager 교재 menu (the
"내신기출" group at the bottom of the book list, grouped by school; the old
"내신 기출 일괄 등록" button in 문제은행 is gone). Manager code:
`services/school_exam_file_info.dart` (file-name parsing),
`services/school_exam_review_service.dart` (list, upload, start review, draft
delete), `screens/textbook/school_exam_panel.dart`,
`screens/textbook/school_exam_upload_dialog.dart`. Gateway code:
`gateway/src/problem_bank/school_exam/` (`pdf_tools.js`, `text_em.js`,
`item_regions.js`, `layout.js`, `review_staging.js`).

### One paper is one review scope

| Review key | Value for an exam paper |
|------------|-------------------------|
| book id | `pb_documents.id`, with a hidden `resource_files` row of the same id (`category = 'school_past'`, `is_published = false`) |
| `grade_label` | the 2022 course label of the paper (`examReviewCourseLabel`; 2015 courses map to their 2022 counterpart, e.g. 수학Ⅰ to 대수) |
| `big_order` / `mid_order` / `sub_key` / `sub_index` | `0` / `0` / `A` / `0` |
| workflow `scope_key` | `A`, series key `school_exam` |
| body PDF | `resource_file_links` row with `grade = '<grade_label>#body'` pointing at the paper PDF |

`POST /pb/exam-review/prepare` (`prepareExamReview`) writes these rows and can
be called again at any time with the same result:

- scores (owner decision 2026-11-17, `school_exam/score_distribution.js`):
  questions whose score was not read get a share of `100 − sum of read
  scores`, written to `pb_questions.meta.score_point` and marked with
  `meta.score_estimate = {value, total, at}`. Weights are the per-type
  (객관식 / 주관식·서술형) averages of the read scores on the same paper, else
  1 : 1.5. The unit is 0.1 when a read score has a decimal, else 1; leftover
  units go to the last 주관식·서술형 questions first. A score counts as
  estimated only while `score_point` equals `score_estimate.value`, so a
  value the owner changes, and any `score_parts`, are fixed and never
  redistributed. Nothing is written when the read scores leave no room
  (`scoreIssue: 'no_room'`).

- one `textbook_problem_crops` row per question, linked to the question by
  `textbook_crop_question_links`. The region comes from
  `pb_questions.meta.source_item` (written at extraction), else from a VLM
  detection on the PDF (`readExamLayout`), else the whole page. A whole-page
  region is looked for again on the next call. Regions an operator edited are
  kept.
- one `textbook_problem_answers` row per question, seeded from the answer key
  in the problem bank (`answer_source = 'vlm'`). Existing rows are never
  overwritten, except after a re-extraction (`refreshAnswers`), and manual
  answers never.
- one `textbook_problem_solution_refs` row with `source_kind = 'none'`: exam
  papers have no printed solution, so solution transcription and solution
  checks do not run.
- `identityOnly` writes only the book row and the PDF link (used before the
  extraction has produced questions). `redetect` looks for every region again.

Requests that fail because the network dropped are sent again (two more tries).
A paper without a PDF is refused (`pdf_source_required`).

Exam book rows are left out of the textbook lists: the manager book list
filters `category = 'school_past'` on the server, and
`textbook_review_books_and_units()` skips them
(`20261116170000_textbook_review_units_exclude_school_exams.sql`).

### Two review modes

The work order carries `reviewMode`; the pipeline entry point is
`TextbookReviewPipeline.run`.

- **Full** (new uploads): the same run as a textbook subunit (`runAll`),
  including the fix pass, the V2 render comparison with the original and the
  figure size and position checks.
- **Answer only** (`answer_only`, papers that were already published before
  this flow existed; owner decision of 2026-11-16, their figures were already
  fixed by hand): `runAnswerOnly` records the AI solution, compares the AI
  answer with the answer key, applies the question-type rule, and runs the
  consistency and meta passes. It skips the fix pass, the render check and
  figure resizing, and releases engine holds set by the AI. In this mode
  "문항 검수 미통과" and "V2 렌더 이상" do not block 준비됨.

The AI solution is kept in the review record
(`textbook_problem_analyses.ai_solution`) only.

### Answer key protection

Every exam scope sets `protectAnswerKey`
(`TextbookProblemReviewItem.stageableAnswer`):

- AI answer equals the answer key (normalized comparison): the answer-key text
  is staged and the math axis passes.
- AI answer differs, or the AI could not solve it ("판단불가"): nothing is
  staged and the problem stays "정답 검수 미통과". The owner looks at the
  original and the AI solution and picks; picking stages the answer with
  `source: 'owner'` and passes the problem.

The gateway answer sync used for textbooks is not called for exam scopes.

### New uploads

1. The upload dialog reads school, year, grade, semester, term and course from
   the file name. A PDF is required; an HWPX is optional and is used for the
   body text only.
2. A draft `pb_documents` row is created with empty classification codes and
   `meta.exam_review` (so the academy app does not list it), then an extract
   job and the work order (`identityOnly` prepare, crops confirmed, runner
   queued).
3. `TextbookWorkflowRunner._prepareExam` waits for the extract job (time in
   the queue does not count toward its limit), runs the full prepare, then the
   review.
4. Confirming the paper publishes the draft
   (`publishExamReviewDocument`: document `ready` plus classification on the
   document and its questions). Only then does the academy app show it.

Extraction for a document with a PDF runs the VLM engine on the PDF. Figures
are cut from the page image (`attachPdfFigureAssets`, bucket
`problem-previews`, `<academy>/<document>/pdf-figures/<job>/…`), sized from the
measured text em, and placed by the question's own region. The HWPX figure
overlay is off whenever a PDF exists (`PB_HWPX_FIGURE_OVERLAY=1` restores the
old behaviour). Drafts skip the naesin preset sync.

### Deleting a draft

`deleteExamReviewDraft` cancels active jobs, deletes the review book row
(crops, review records and the work order go with it), then the document, then
the source files and the cut figures. Database rows go first so a failure
leaves a draft that can be deleted again. Published papers are deleted from
문제은행, which removes the review book row first.

These deletes look up child rows by `crop_id`, `book_id`, `question_id`,
`extract_job_id` or `source_document_id` alone. Indexes led by those columns
were added on 2026-11-16 (`20261116190000` to `20261116190600`); before that a
21-question paper took 5 s to delete and timed out with a cold cache.

### Known limits

- Set-header crops are not staged for exam papers.
- There is no region editor for exam papers; `redetect` is the only way to
  redo regions.
- Three papers have no PDF (2025 중1 1학기 중간) and cannot be reviewed.

## Mock exams (모의고사)

Built 2026-11-20. One section of a mock exam (공통, 확률과 통계, 미적분,
기하; the whole paper for 고1·고2) is one review scope and runs through
`runAll` like a textbook subunit, with the printed solution PDF. The design,
the owner decisions and the differences from a textbook run are in
`mock-exam.md`, "Review (모의고사 검수)".

The consistency check has four fixes that run only for mock sections
(`ConsistencyContext.mock`): upright point names, the `[출제의도]` head, a
figure moved below the choices, and a particle attached to the math before it.
For a mock scope `runAll` also calls the consistency check once more right
after the review rounds, before the render check. Textbook and school exam
questions are not touched by these rules.

## Manager screen (문항검수)

`apps/yggdrasill_manager/lib/screens/problem_roadmap/problem_roadmap_screen.dart`.
Three columns:

- Left: the unit's problem list with math and quality status, the issue kind
  badge (데이터/엔진/도형, or "승인 후 원본 차이"), and a "문제은행 정답 다름"
  badge when the problem-bank answers differ from the grading answer. Filter
  tabs include "엔진 보류" and "승인 후 원본 차이".
- Centre: the math review card (answers side by side, compare result,
  problem-bank answers), the solution edit card (transcribed solution, its
  answer, AI solution; "해설 저장"), and the quality review card (stage-2
  flags, original-comparison state, findings, the stem/choices/figure editor,
  the "수정 후 재검토" button, and the hold banner for held problems).
  "수정 후 재검토" (2026-11-16) stages the editor's stem, choices and figures
  as owner edits and re-runs the review for that problem alone
  (`onlyCropIds`, `forceRerun`, `forceRenderCheck`), so the AI solves and
  compares with the edited text. The header "다시 검수" does not save the
  editor. While the quality axis is `issue`, a small "그대로 통과" button
  stages the edit and marks the axis `clean` without a re-run (the former
  "품질 검수 승인"). Staged values are shown
  as "반영 대기" and go to the problem bank only at the subunit confirm.
  The figure editor lists each `figure_layout` item (width in em, position,
  anchor) and the figures the proposal will crop from the original;
  "교재 원본 대조 수정안 만들기" runs the fix pass for that problem alone.
- Right, a vertical stack: ⓪ the original problem (and set header) rendered
  from the body PDF, then, rendered **only with V2**, ① the problem card,
  ①′ the preview of the edited stem/choices when the editor differs from the
  stored values, ② answer + printed solution (or AI solution), ③ the AI
  solution when a printed one exists, then one card per alternative solution
  with add and remove. Card images are cached per `crop | kind | text hash` and
  rebuilt when the text changes. The client LaTeX renderer is not used here,
  because the point of the stack is to see exactly what students will see.
- Header: "전체 강제 재검수" (ignores `isReviewTodo`), "V2 렌더 검수만 전체
  다시(원본 대조)" (stage 4 only), "승인 문항 원본 재대조" (stage 4 for
  approved problems not yet compared with the original; approval is kept and
  differences are flagged), "AI 엔진 의심 일괄 보류" (holds every problem whose
  latest issue is classified `engine`), and "렌더 엔진 목록" (the cross-book
  hold dialog). "해설 답 채택 후 승인" and "AI 답 채택 후 승인" stage the
  answer and mark the math axis `clean` (see "Owner edits before confirm").

The older Preview under
`screens/design_preview/yggdrasill_manager/textbook_review/` with mock data is
superseded by this screen.

## Checks

- `tools/db_test`: `test/textbook_manual_guard.test.mjs`,
  `test/textbook_review.test.mjs` (`node --test`).
- `gateway`: `test/textbook_manual_guard.test.js`,
  `test/problem_bank_explanation_figures.test.js` (solution figures beside or
  below the solution text), `test/problem_bank_aligned_row_figures.test.js`
  (figures at the end of `aligned` rows),
  `test/problem_bank_explanation_figure_arrangement.test.js` (align, left
  placement, figure-first solutions, figure rows with captions),
  `test/school_exam_review.test.js` (text em, item regions, staging one exam
  paper as a review scope, repeat calls, re-extraction, network drops)
  (`node --test "test/**/*.test.js"`).
- `apps/yggdrasill_manager`: `test/textbook_review_preview_test.dart`,
  `test/textbook_review_common_stem_test.dart`,
  `test/textbook_review_original_figure_test.dart` (figure helpers,
  `needsFixPass`, figure proposals, original-comparison flags, chunk image
  payload), `test/textbook_review_ready_criteria_test.dart` (group
  "내신 시험지": answer-only readiness, answer key protection),
  `test/school_exam_review_test.dart` (file-name parsing, exam list stages,
  exam work orders).
- `supabase/functions/ai_think`: `textbook_problem_review_test.ts` (image
  parsing including originals, common-stem combining, `isReviewTodo`,
  `issue_kind`, proposed choice normalizing, figure size ratio) and
  `textbook_problem_fix_test.ts` (box normalizing, em from the text sample,
  layout items, asset mapping and crops, figure markers). AI tests use
  `FakeAiProvider` and do not assert model wording.

## Open questions

- Whether to re-grade already graded student records after an answer
  correction.
- The authoring and stage dialogs do not yet show protected counts.
