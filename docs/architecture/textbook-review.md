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
  An owner action may apply the proposal in the same touch (see "One-touch
  approval"); the AI itself never writes answers, stems, or choices.
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

### One-touch approval

Owner edits go through `textbook_review_save_item_edit`, which can set the
answer, the AI solution, visual tags, the transcribed solution and its answer,
alternative solutions, and approve the math or quality axis. Changing the
transcribed text sets `solution_source = 'manual'`; saving the same text keeps
`textbook_vision`.

- Math axis. Saving a grading answer also syncs the linked `pb_questions` row
  (`p_sync_pb_answer`, default on) through `textbook_review_sync_pb_answer`:
  `objective_answer_key` when the question allows objective answers and the
  answer parses as choice numbers (`3`, `③`, `1,3`, `3번` →
  `textbook_review_objective_key`), and `subjective_answer` (the choice text for
  a keyed answer, otherwise the answer itself). The screen's "해설 답 채택 후
  승인" and "AI 답 채택 후 승인" therefore fix the grading answer and both
  problem-bank answers in one touch. `pb_questions_emit_revision` logs the
  change as usual.
- Quality axis. `textbook_review_apply_problem_fix(crop, stem, choices,
  approve_quality, note, common_stem, figure_layout, figure_assets)` writes the
  stem, choices, common stem (whole set), `meta.figure_layout` and
  `meta.figure_assets` to `pb_questions` (only the fields that changed; new
  figure assets also set `figure_count`, `figure_refs`, and clear
  `figure_review_required`), records the application in `fix_proposal`, and
  when `approve_quality` is set approves the axis and resolves the open
  `fidelity`/`output` findings. Without approval it clears `render_checks` so
  the stage-4 check runs again on the new render.
  The screen prefills the editor with the proposal (text, common-stem rule,
  figure layout), lets the owner edit, and has **one** approval button:
  "품질 검수 승인" saves whatever the editor changed (cropping and uploading
  proposed figures first) and approves. "수정만 적용" applies without
  approval and re-runs the original-compared render check. "①′ 미리보기"
  shows the edited text as a V2 card; figure placement is checked on the real
  card after applying, because the text preview has no figures.

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
  - **Problems with figures (`itemHasFigures` / `hasFigures`) are always
    classified as `quality_status = 'issue'` (`issue_kind = 'figure'`) in
    Round 1**, regardless of whether math or text errors exist, so that every
    figure problem goes through original PDF comparison, automatic figure
    sizing and placement (`figure_layout` / `figure_crops`), and DB
    application in Round 2.
  - Pure rendering engine issues (`issue_kind = 'engine'`, text matches
    original, no figures) are **automatically held (`quality_status = 'held'`)**
    in Round 1 and excluded from the active error count and approval
    denominator.
  - Problems with no math or quality issues (and no figures) are
    **automatically approved (`approved`) in Round 1** (with problem-bank
    answer sync for math).
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
  Applying goes through `textbook_review_apply_problem_fix(..., p_common_stem)`;
  a common-stem change is written to every `pb_questions` row of the same
  set (same `document_id` and set key, or sibling crops in the same
  `is_set_header` range when no set key was stored yet) as well as
  `pb_question_sets.common_stem` and `pb_delivery_units.source_meta`, because
  the renderer takes the group's common stem from its first item or delivery
  unit. The screen recognises both shapes on already-reviewed rows and
  prefills the editor (common stem field + item stem), so the single approval
  button applies it.

### Bulk actions

There are no separate fix buttons; each axis has one bulk action that fixes
what a rule can fix, approves what is clean, and leaves only what needs a
person:

- "품질 일괄 처리", in order:
  1. every common-stem fix in the unit (looping a few times, because fixing
     one set's common stem exposes the head duplication on its other items);
     fixed problems whose other checks are fine and that have no figures are
     approved at once (figure problems still need the original comparison);
  2. question type fixes (below);
  3. up to two rounds of:
     a. the fix pass (below) for every problem that needs it;
     b. every pending proposal (text, figure layout, figure crops) is applied
        to `pb_questions` without approval; proposed figure crops are cut
        from the body PDF and uploaded first;
     c. the stage-4 render check, **compared with the original**, for the
        changed problems and every unapproved problem not yet compared with
        the original (approval must rest on that comparison);
     d. problems whose V2 figure size is off (`figure_size_ratio` outside
        0.8 to 1.25) get every `widthEm` multiplied by `1 / ratio` and are
        checked again.
     The second round runs only if some problem still needs a fix pass (it
     became `issue` in the comparison, or stayed `issue` after its proposal).
  4. every `clean` problem is approved.
  "중단원 문항 검수 실행" runs this same fix → apply → V2 re-render →
  original-compared re-check → auto-approve sequence at the end of the unit
  run, and the per-problem "원본 대조로 AI가 바로 고치기" button also applies
  the proposal and re-checks the V2 card at once.
  What remains are engine problems and issues the AI could not fix. The
  notice reports what was proposed, applied, re-checked and resized, and the
  count left. The pause button stops after the current chunk.
- "수학 일괄 처리", in order:
  1. re-solves every math `issue` the two rules below cannot settle
     (`needsMathResolve`), with the current problem text and the original
     image. The AI answer may come from before a stem fix (for example
     "판단불가" because the statement was missing then). This is stage 2 with
     `math_only` (below). The app skips a problem it already re-solved in
     this session when its text (`problemTextSignature`: common stem, stem,
     choices, figure count) has not changed;
  2. adopts the printed solution's answer (with the problem-bank sync) where
     the printed answer and the AI answer agree but the grading answer
     differs;
  3. keeps and approves the grading answer where it equals the AI answer (two
     of three agree);
  4. approves every `clean` problem.
  Answers are compared after `normalizeAnswerForCompare` (spaces, `$`,
  braces, `\left`/`\right`, multiplication signs). What remains are real
  disagreements. The button also shows when only re-solve targets are left.
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
choices make it 객관식, else 주관식. The owner can click a type, and
"품질 일괄 처리" applies the rule type through
`textbook_review_set_question_kind(crop, kind)`. That function sets only what
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
  sent, or Vision could not read it this time).
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

Runs after the render check (end of a unit run, and inside the bulk action)
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

The result is stored as `fix_proposal` (`source: fix_pass`). When a
common-stem rule proposal is still pending, its text is kept and only the
figure fields are added. Applying a figure crop converts
the box from original-image coordinates to page coordinates
(`cropBoxToPageRegion`), renders that region from the body PDF at about
900 px, uploads it to `problem-previews` as an approved manual asset
(`source: textbook_review_original_crop`), and passes the full asset list to
`textbook_review_apply_problem_fix`; the renderer picks the newest approved
asset per index, so the crop replaces a cut figure.

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
  the single "품질 검수 승인" button, and the hold banner for held problems).
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
  hold dialog). "해설 답 채택 후 승인" and "AI 답 채택 후 승인" copy the
  answer into the grading answer, sync the problem-bank answers, and approve.

The older Preview under
`screens/design_preview/yggdrasill_manager/textbook_review/` with mock data is
superseded by this screen.

## Checks

- `tools/db_test`: `test/textbook_manual_guard.test.mjs`,
  `test/textbook_review.test.mjs` (`node --test`).
- `gateway`: `test/textbook_manual_guard.test.js`
  (`node --test "test/**/*.test.js"`).
- `apps/yggdrasill_manager`: `test/textbook_review_preview_test.dart`,
  `test/textbook_review_common_stem_test.dart`,
  `test/textbook_review_original_figure_test.dart` (figure helpers,
  `needsFixPass`, figure proposals, original-comparison flags, chunk image
  payload).
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
