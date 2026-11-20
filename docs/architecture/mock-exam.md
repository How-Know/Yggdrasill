# Mock Exam Past Papers (모의고사 기출)

This note covers importing mock-exam past papers (교육청 학력평가, 평가원 6·9월
모의평가, 수능) from PDFs into the problem bank, keeping crop positions so the
learning app can open the original pages.

Status (2026-10-30): first build. Migration, gateway worker, manager workspace,
and the learning-app resource entry are new.

Status (2026-11-20): the question review (모의고사 검수) was added in the 교재
menu. See "Review" below.

## Owner decisions (2026-10-30)

- **Sources.** Only PDFs: a problem PDF and a solution PDF per file pair. There is
  no HWPX and no separate answer PDF.
- **Organizers.** `edu` (교육청), `kice` (평가원), `csat` (수능).
- **Curriculum.** 2015 revision. Grade 3 has the common part (1~22) and one of
  three electives (23~30): 미적분, 확률과 통계, 기하. Grades 1 and 2 have no
  elective: 30 items, 21 objective and 9 short-answer.
- **One exam, common stored once.** The 확통/미적/기하 problem PDFs repeat the
  common 1~22. An exam stores the common items once and 8 items per elective.
- **Course label.** Common items are labeled `공통` only (no 수학Ⅰ/Ⅱ split), for
  every grade. Only electives show a course. Items have no unit classification,
  the same as 내신 기출.
- **Year.** Both are stored: `exam_year` (시행연도, as in the file name) and
  `school_year` (학년도, grade 3 only, `exam_year + 1`). Apps display `exam_year`.
- **Upload.** Several PDFs at once. File names are parsed into exam, elective,
  and problem/solution, and shown for confirmation before upload.
- **Flow.** Upload runs everything automatically: item crops, answers, solution
  positions, problem-bank extraction. The manager reviews and fixes afterwards in
  the "모의고사 페이지 검수" workspace.
- **Solution crop.** Coordinates on the original solution page, the same as
  textbooks. No solution images.
- **Learning app.** Mock exams appear in the resource list, next to textbooks.

## File names

`{시행연도} 고{학년} {월}월 {교육청|평가원|수능} [({확통|미적|기하})][ - 해설].pdf`

Examples: `2024 고3 11월 수능 (확통).pdf`, `2024 고3 4월 교육청 (확통) -해설.pdf`,
`2024 고1 3월 교육청 - 해설.pdf`. A name that does not parse is shown as an error
and is not uploaded.

## Data

Migration `20261030120000_mock_exams.sql`.

- `mock_exams`: one row per exam (`academy_id, grade, exam_year, exam_month,
  org` unique). `status` moves `draft → queued → running → review` or `failed`;
  `stage` and `progress` show where the worker is.
- `mock_exam_papers`: one row per PDF. `kind` is `problem` or `solution`;
  `elective` is `''` for grades 1·2, else `probstats | calculus | geometry`.
  Files are in the `problem-documents` bucket under
  `{academy}/mock-exams/{exam}/`.
- `mock_exam_items`: one row per item (`exam_id, section, problem_number`
  unique). `section` is `common` or an elective key. Holds the problem crop
  (`paper_id, raw_page, item_region_1k`), the answer, and the solution position
  (`solution_paper_id, solution_raw_page, solution_number_region_1k,
  solution_content_region_1k`). Coordinates are `[ymin, xmin, ymax, xmax]` in
  0~1000, like `textbook_problem_crops`.
- `mock_exam_sections`: one row per section, linking the `pb_documents` row and
  its extract job.

Manual edits win: `answer_source = 'manual'` and `solution_source = 'manual'`
rows are not overwritten by the worker.

## Pipeline

Worker `gateway/src/mock_exam_worker.js` (pm2 `ygg-mock-exam`) picks up
`queued` exams.

1. **Item crops.** Each problem page is rendered and sent to Gemini, which returns
   item numbers and regions. The common items come from the first problem paper;
   the other papers only contribute items 23 and above. Pages that only hold
   common items are skipped after the first paper.
2. **Answers and solution positions.** Each solution page is sent to Gemini,
   which returns answer boxes, section headers (`[공통]`, `[선택: 확률과 통계]`)
   and solution blocks. Sections carry forward in reading order (left column,
   then right) across pages, so a solution PDF that holds all three electives
   fills all three.
3. **Problem bank.** One `pb_documents` row per section (`source_type_code =
   'mock_past'`, `meta.mock_scope`) and one extract job each. The extract worker
   uses the item pages as expected numbers and the answers as the answer
   sidecar, then writes `pb_question_id` back to the items.
4. **Export presets (`gateway/src/mock_exam/mock_preset.js`).** When a grade-3
   exam has its common 22 and elective 8 `pb_questions` extracted, the worker
   automatically upserts one `pb_export_presets` row (`preset_kind = 'settings'`,
   `render_config.mockExamLinkKey = 'H3|{year}|{month}|{org}|{elective}'`) per
   elective paper (30 questions combined). It fixes the 12-page 2-column slot
   counts (`2/2, 2/1, 2/1, 1/1, 1/1, 1/2, 2/1, 1/1, 1/1, 1/1, 1/1, 1/1`),
   title pages `[1, 9]`, objective/short-answer anchors (`5지선다형` on p.1 & p.9,
   `단답형` on p.6 & p.12, `선택과목(...)` notice on p.8, `확인 사항` on p.12),
   `paperSize = '8절'`, `includeQuestionScore = true`, and the original-style
   `titlePageTopText` (수능 / 평가원 6·9월 모의평가 / 교육청 전국연합학력평가).

Re-runs set `progress.request`: `all` and `crops` re-queue problem-bank
extraction; `solutions` only re-reads the solution PDFs and keeps the existing
section documents; `problem_bank` only re-queues extraction.

Bulk import from a folder: `node scripts/mock_exam_enqueue.mjs --academy <id>
<pdf> ...` (same file-name rule as the manager dialog). `--register` uploads the
PDFs and leaves the exam in `draft`, so the learning-app card and the manager
list appear without starting extraction. The manager's re-run menu then queues
extraction from those stored PDFs.

The mock-exam worker also watches the Dropbox `- 모의고사` folder (or
`MOCK_EXAM_DIR`) about every 30 seconds and registers new or changed files the
same way, without queueing. The exam desk, after it places a PDF, runs that
register step immediately when this PC has the gateway folder and Node. A file
that arrives only through Dropbox is picked up by the watcher. Exams already in
`review` keep their stored PDFs.

## Manager workspace

The upload-tab header cycles 내신 기출 → 시중교재 → 모의고사. The mock mode keeps
the 내신 layout: the left list (`mock_exam/mock_exam_quick_switch_panel.dart`,
same look as the 내신 tree) goes 학년 → 연도 → 회차 → section document, and the
right side is the existing question table and cards for the selected section's
`pb_documents` row. Review and edits happen there, as for 내신 and textbooks.
The header's 업로드 opens the batch dialog; each exam row has a re-run menu.
Mock documents are kept out of the 내신 tree (`meta.extract_mode =
'mock_exam_pdf'`).

## Learning app

Resources → exam tab → "고N 모의고사" folder (virtual roots
`exam-folder-H{1,2,3}-mock`). Under each grade, a month folder (`3월`, `4월`,
…) appears only when that grade has a paper in that month. The grade folder
shows every month; a month folder shows that month. `MockExamResourceService`
lists every exam that
has a problem paper, including ones still in `draft`. One card per problem
paper, so 고3 has one card per elective (common 22 + that elective's 8; common
pages are the same in every elective paper) and 고1/2 have one card per exam.
The card is the same `ExamPaperCard` as 내신, with the footer "탭하여 번호·문항
보기". A card opens `TextbookExplorerController` only when its questions have
been extracted: grades 1·2 need items, and a grade-3 card needs items in that
elective. It then shows number cards, then item cards. Original PDF is not
offered. Exams without those items are cards only. Item cards use the linked
`pb_questions`, which the learning app reads only when `is_published = true`,
so they appear after the manager publishes the section documents. Number cards
work before that.

## Review (모의고사 검수)

Built 2026-11-20. Mock exams go through the same subunit workflow as textbooks
and school exam papers (`docs/architecture/textbook-review.md`): prepare, AI
review, automatic fixes, then the owner confirms. One section document (공통, or
one elective) is one review scope. Manager code:
`services/mock_exam_review_service.dart` (exam and section list, upload, start
review), `screens/textbook/mock_exam_review_panel.dart` (grade panel). Gateway
code: `gateway/src/mock_exam/review_staging.js` (prepare, publish),
`mock_courses.js` (title, curriculum code, course label), `solution_layout.js`
and `solution_evidence.js` (solutions that continue in the next column or
page). Migration `20261120180000_mock_exam_review.sql`.

### Owner decisions (2026-11-20)

- **Where.** 교재 menu, a "모의고사" group under "내신기출": 고1·고2·고3 →
  exam → section. "모의고사 업로드" takes several PDFs at once; each grade
  panel has "모두 시작".
- **Start.** An exam uploaded from this menu starts extraction and review on
  its own. Exams that existed before are started with "검수 시작" or "모두
  시작".
- **Exams published before this flow (고3, 8 exams, 352 questions).** Full
  review, not answer-only. They stay published and a confirm applies the
  reviewed values. Figure sizes follow the original, the same rule as
  textbooks.
- **Publishing.** Questions of a section created by the review stay
  unpublished until that section is confirmed. The problem PDF is in the
  learning-app resource list as soon as it is registered.
- **Answer rule.** Three values are compared: the answer table, the answer
  printed in the solution, and the AI answer. Two that agree pass. When all
  three differ the owner picks. So `protectAnswerKey` is off for mock scopes.
- **Concept candidates** (`mockReviewCourseLabel`, 2022-revision courses):

  | Section | Courses |
  |---------|---------|
  | 고3 공통 | 대수 + 미적분1 |
  | 고3 확률과 통계 / 미적분 / 기하 | 확률과 통계 / 미적분2 / 기하 |
  | 고2 3월 | 공통수학1 + 공통수학2 |
  | 고2 other months | 대수 + 미적분1 |
  | 고1 3월 | 중학교 1-1 to 3-2 |
  | 고1 other months | 공통수학1 + 공통수학2 |

- **Curriculum code** (`mockCurriculumCode`). `rev_2022` for 고1 from exam
  year 2025 and 고2 from exam year 2026; `rev_2015` otherwise. 고3 from exam
  year 2027 changes its structure and is decided then.
- **Score.** The review problem card prints `[N점]` like the original, so the
  score is checked against the page. The score is
  `pb_questions.meta.score_point`; the stem never holds it.
- **Solution text.** One printed line of the solution is one line of text.
  The same format applies from now on to textbook solutions and to AI
  solutions of school exam papers. Texts confirmed earlier are left as they
  are.
- **`[출제의도]`.** Always transcribed, as the first line of the solution.
- **Failed solution card.** A question whose answer·solution card could not be
  rendered is not 준비됨. The reason is recorded on the question so the cause
  can be fixed and the question re-run. Mock solutions are the base for later
  explanations, so a render failure is fixed, not skipped.

### One section is one review scope

| Review key | Value for a mock section |
|------------|--------------------------|
| book id | `pb_documents.id` of the section document, with a hidden `resource_files` row of the same id (`category = 'mock_past'`, `is_published = false`) |
| `grade_label` | the course labels joined with `+` (`대수+미적분1`) |
| `big_order` / `mid_order` / `sub_key` / `sub_index` | `0` / `0` / `A` / `0` |
| workflow | series key `mock_exam`, `isMockExam`, `isDocumentScope`, full review (`reviewMode ''`) |

`POST /pb/mock-review/prepare` (`prepareMockReview`) writes these rows and can
be called again at any time with the same result:

- It waits while the exam or the section's extract job is still running
  (`state: 'waiting'`); the runner keeps asking. With `allowExtract` it queues
  the extraction of a section that has no questions yet.
- one `textbook_problem_crops` row per question from `mock_exam_items`
  (page and region only; the original is drawn from the problem PDF).
- one `textbook_problem_answers` row per question, seeded from the problem-bank
  answer (which the extraction took from the answer table of the solution
  PDF).
- one `textbook_problem_solution_refs` row per question from the solution
  position in `mock_exam_items`, plus `continuation_regions`
  (`[{raw_page, region_1k}]` in reading order) when the solution continues in
  the next column or page. `null` means not computed, `[]` means it does not
  continue.
- Answers, solution positions and item regions an operator edited are kept.
- A section document created by the review carries
  `meta.mock_review.publish_on_confirm`; its questions stay unpublished.

Mock book rows are left out of the textbook lists
(`textbook_review_books_and_units()` skips `category = 'mock_past'`).

### Differences from a textbook run

- **Score on the card.** `TextbookReviewUnitScope.scoreOnCard` is on for mock
  scopes. The problem cards are rendered through `/pb/preview/batch-render`
  with `renderConfig.includeQuestionScore` and stored under `card-score/`
  (`card-score-staged/`), so the cards the problem bank and the learning app
  use are not overwritten. The review and fix requests carry
  `score_separate: true`: the AI leaves the score out of the stem, a `[N점]`
  that still comes back is stripped (`stripScoreMarks`), and only a wrong
  score number is reported.
- **Solution text.** `solutionLinesToParagraphs` (Edge,
  `textbook_problem_review.ts`) stores every printed line as its own paragraph
  (blank line between lines), because the V2 engine starts a new line only at
  a blank line. Multi-line math (`$…$`, `\[…\]`, `\begin…\end`) and the rows
  of a text table stay one block. It runs where AI output is saved: solution
  transcription, the AI solution, the logic fix and the fix pass. Text stored
  before, and text the owner types, is not touched; a manual edit needs a
  blank line to start a new line.
- **Text tables.** A 증감표 is transcribed as rows of `| a | b |`; the engine
  turns consecutive rows into a ruled table (`explanationMarkdownTablesToArray`).
- **Solution figures.** When the figure-placement AI returns a text whose
  line structure differs, the markers are moved onto the stored text
  (`transferFigureMarkers`), so the line format survives.

### Failed answer·solution card

The manager sends the render error of the answer·solution card with the render
check (`answer_solution_error`). The Edge function then

- sets `render_checks.solution_ok = false` and stores the reason in
  `render_checks.answer_solution_error` (title "정답·해설 카드를 만들지
  못함"),
- treats a question whose only problem is the failed card as an engine issue
  (`issue_kind = 'engine'`), which the existing hold rule puts on the
  render-engine hold list (`quality_status = 'held'`, the reason in
  `engine_hold_note`); questions with figures stay `issue`,
- keeps the stored reason on later checks until a card is actually rendered.

No readiness rule was added: the question is blocked by the existing
"V2 렌더 이상" or "렌더 엔진 수정 필요". The gateway reports the TeX cause in
the error text (`texErrorSummary`: the first error line and the offending
source line).

To list failing questions without opening the app, run the batch tool from
`apps/yggdrasill_manager` (`tool/textbook_batch.dart`, see its header):

| `BATCH_STEP` | What it does |
|--------------|--------------|
| `mock` | start the exams in `BATCH_VALUE`, or continue stalled ones |
| `mock_status` | status only; every exam with a workflow when `BATCH_VALUE` is empty |
| `mock_continue` | run unconfirmed sections again from the review phase |
| `mock_restart` | drop AI-staged values and review again from the start (no re-extraction; values the owner staged are kept) |

Each question that is not 준비됨 is printed with its blockers and the card
error, render issue, quality issue and answer mismatch; the same fields are in
the result JSON under `build/textbook_batch/`.

### Confirm

Confirming a section applies the reviewed values as for textbooks, then
`POST /pb/mock-review/publish` (`publishMockReview`) publishes the questions
of a section created by the review, writes `meta.mock_review.published_at`,
and syncs the learning-app presets (a 고3 elective preset needs both the
common section and that elective published). Sections that were published
before this flow are left as they are.

### Known limits

- Re-uploading an exam from the menu extracts it again and restarts the review
  of all its sections. Re-extraction copies the answer-table answer again
  (manual answers are kept).
- A question held for a failed card skips the fix pass until its card renders,
  so it needs a second run.
- The render-engine hold panel builds its scope without `scoreOnCard`; its
  problem cards show no score.
- 고1 3월 uses every middle-school concept as candidates (about 2,100 per AI
  call).

## Not in this build

- Editing crop rectangles in the manager (regions are re-detected by
  re-running).
- Unit classification, student-app delivery.
- Solution pages in the learning app.
