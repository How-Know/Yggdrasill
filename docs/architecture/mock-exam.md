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

`{시행연도} 고{학년} {월}월 {교육청|평가원|수능} [({확통|미적|기하|가형|나형})][ - 해설].pdf`

Examples: `2024 고3 11월 수능 (확통).pdf`, `2024 고3 4월 교육청 (확통) -해설.pdf`,
`2020 고3 3월 교육청 (가형).pdf`, `2020 고3 11월 수능 (나형) - 해설.pdf`,
`2024 고1 3월 교육청 - 해설.pdf`. A name that does not parse is shown as an error
and is not uploaded.

Pre-2021 curriculum (`가형` / `나형`, owner decision 2026-11-23):
- Organized into `{시행연도}/` with `(가형)` / `(나형)` in the file name.
- Registered in `mock_exams` + `mock_exam_papers` (`elective = 'ga' | 'na'`) in
  `draft` status by the folder sync, which still does not queue extraction for
  them; the learning app shows `가형` / `나형` cards and opens the original
  problem/solution PDFs.
- Extraction and review (owner decision 2026-11-23, second one the same day):
  each `가형` / `나형` problem paper is one section (`ga` / `na`) of 30
  questions, 1–21 objective and 22–30 subjective, with no `common` section and
  no elective header detection. Such an exam now appears in `모의고사 검수`
  and can be started from there or with the `mock` batch step. Migration
  `20261123230000_mock_exam_legacy_sections.sql` allows the two section values
  on `mock_exam_items` and `mock_exam_sections`.
- Review course label (`mockReviewCourseLabel`, by what the paper covered):
  2020 `가형` `대수+미적분1+미적분2+확률과 통계`, `나형`
  `대수+미적분1+확률과 통계`; 2019 and earlier `가형`
  `대수+미적분1+미적분2+확률과 통계+기하`, `나형`
  `공통수학2+대수+미적분1+미적분2+확률과 통계`. Content that no current course
  has (space vectors, for example) can end as `메타 누락`.
- One export preset per `ga` / `na` section of 30 questions (title
  `수학 영역`, subtitle `가형` / `나형`).
- `가형` and `나형` share some questions under different numbers. Both sections
  keep all 30; after review a code comparison records the `가형` twin on the
  `나형` item (`mock_exam_items.same_as_item_id`, `same_as_source`
  `auto` | `manual`). The learning-app problem bank shows one of a pair (see
  the 2020 수능 section below).
- The manager upload dialog's file-name rule does not accept `(가형)` /
  `(나형)`; these files come in through the folder sync only.

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
  0~1000, like `textbook_problem_crops`. `choice_number_region_1k` (migration
  `20261120200000_mock_exam_choice_number_region.sql`) is the box around the
  printed choice marks ①~⑤ of the item, written by the review prepare step:
  `null` not read yet, `[]` read but no marks found, four numbers otherwise.
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
보기" above two buttons, 원본 and 해설. 원본 opens the problem PDF
(`mock_exam_papers.kind = problem`). 해설 opens the solution PDF
(`kind = solution`), which holds the answer table and the written solutions
in one file. The viewer fits one whole page on first open and can print or
download that file. There is no separate answer PDF.
A card opens `TextbookExplorerController` only when its questions have
been extracted: grades 1·2 need items, and a grade-3 card needs items in that
elective. It then shows number cards, then item cards. Exams without those
items are cards only, and the original buttons still open. Item cards use the linked
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
page), `choice_layout.js` (where the choice marks are on the page). Edge code
that is specific to mock exams: `supabase/functions/ai_think/textbook_mock_format.ts`.
Migrations `20261120180000_mock_exam_review.sql` and
`20261120200000_mock_exam_choice_number_region.sql`.

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
- **`[출제의도]`.** Always transcribed, as the first line of the solution. The
  head is written `[출제의도]` for every exam, also where the page prints
  `출제의도 :` (평가원 solutions).
- **Figure under the choices.** A figure the page prints below the choices is
  printed below the choices (stem → choices → figure), also for the exams that
  were already published, when their section is confirmed.
- **Point names.** Point names and labels (점 A, 선분 AB, 상자 A) are upright
  as on the page; the engine otherwise prints every Latin letter in italics.
  See "Print conventions set by code".
- **Particle after math (2026-11-21).** A particle or unit the extraction
  left separated from the math before it is attached as on the page
  (`16 명` → `16명`, `A 와` → `A와`). Mock exams only.
- **No line break between math and the word attached to it (2026-11-21).**
  The cards broke a line between a formula and its particle ("상자 A" / "에서
  2개의…") and left an opening parenthesis alone at a line end. This is fixed
  in the V2 engine for every card and PDF, not only mock exams; see
  `textbook-review.md`, "Solution text rules".
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
- `mock_exam_items.choice_number_region_1k` for every question with choices
  (`choice_layout.js`): the box around the marks ①~⑤ found in the text layer of
  the problem PDF inside the crop region. It is read on the page and region
  the review shows as the original (a manual crop included), read again when
  the stored box no longer lies inside the crop region, and reset to `null` by
  a re-extraction. At least three different marks are needed; when a mark
  occurs twice (a ① inside the stem) the lowest one counts. Nothing is written
  when the PDF could not be read, so the next prepare tries again.
- Answers, solution positions and item regions an operator edited are kept.
- A section document created by the review carries
  `meta.mock_review.publish_on_confirm`; its questions stay unpublished.

Mock book rows are left out of the textbook lists
(`textbook_review_books_and_units()` skips `category = 'mock_past'`).

### Solution regions

`planSolutionSegments` (`solution_layout.js`) computes, for every question of
the section's solution paper, the first region and the regions the solution
continues into. Evidence comes from the PDF (`solution_evidence.js`: ink rows,
text lines).

- Columns come from the x positions of the question numbers. A slot is one
  column of one page.
- The first region runs from the number to the next number in the same slot,
  or to the column bottom. A solution that is last in its slot continues at
  the top of the next slots until the first number there. Elective header
  lines end a section.
- **Column top.** With a text layer, the top is the first text line of the
  slots, leaving out running heads (a line that repeats at the same height in
  at least 40% of the pages of that column, 3 pages minimum). The value must
  be supported by several slots (`supportedTop`), so a title on page 1 does
  not set it. It does not depend on where the numbers are: an elective paper
  read alone has only 8 numbers and none of them may start a column (2024 수능
  기하: highest number at 284, column top at 110). Without a text layer a
  running head cannot be told from solution text, so the top stays within 60
  of the highest number (`MAX_TOP_ABOVE_NUMBER`).
- Per-elective solution PDFs (2024 수능: 확통, 미적, 기하 files): the common
  questions are anchored to the 확통 file, so the 미적 and 기하 sections plan
  with their own 8 blocks only.
- The review screen draws each region with a margin of 10/1000 of the page
  (`kRegionPad1k`), so the first line of the next solution can show at the
  bottom of a crop. The transcription is told the question number.

**An edge column where no number starts** (owner decision, 2026-11-23). A
section that plans with its own 8 blocks can have a first or last column in
which no number starts (2026 고3 10월 기하: numbers start in columns 2 and 3
only; 7월 기하: in columns 1 and 2 only). `solutionColumns` then adds a column
(`inferred`) one column pitch left of the first or right of the last found
column, as long as a whole column fits inside the page (left edge at 30 or
more, right edge at 970 or less). It needs two found columns; a two-column
paper has no room for one more. Before this, 10월 기하 30 was ready with only
its 출제의도 line (the rest was at the top of column 1 of the next page), and
7월 기하 28·30 lost the part in column 3.

**A start point the page read missed** (2026-11-23). The AI that reads a
solution page can skip a whole column (2026 고3 3월: the third column of page
1, questions 12·13·14, on both reads). After each solution PDF is read,
`fillMissingSolutionBlocks` (`solution_anchor.js`, called from
`stageSolutions`) compares the numbers found with the numbers the paper must
hold (`solutionSectionsOfPaper`: 공통 on the first paper, the paper's elective,
and any elective of which a solution was read) and fills the gaps:

1. Text layer: a word `N.` followed on the same line by `[출제의도]` (or
   `출제의도`) is a solution head (`solutionHeadsFromWords`). A head whose
   number is missing and where the AI has no block of the same number
   (within 25 down, 60 across) becomes a block. Its region runs to the next
   number in the column, or to the lowest solution bottom of that page; a
   block above it in the same column is cut at the new number. No AI cost.
2. Re-read: for numbers still missing, the pages from the previous found
   number to the next found number of that section (4 pages at most) are
   read once more with the missing numbers named in the prompt
   (`buildSolutionPagePrompt({ lookFor })`). Only blocks of the missing
   numbers are taken.

A fill that would lose a number found before (the section assignment
changed) is dropped. Neither step throws; what was filled and what is still
missing is logged as `solution_fill` and stays in `progress.missing`.

**A solution that was not found is not "no solution"** (owner decision,
2026-11-23). When the section has a solution paper and a question has no
position, prepare writes the ref row with `source_kind 'sol'` and
`raw_page 0`. The review reads that as no solution position
(`has_solution_ref` needs `raw_page > 0`), so the question is held by
"해설 위치 없음" and is not ready. `source_kind 'none'` (counts as resolved)
is written only when the exam has no solution paper. Before this, the three
3월 questions were ready with an empty solution, and the solution of 11번
ran over the skipped column.

A position the gateway computed is not replaced by the fix pass. For a
question with a math issue the fix pass looks at the whole solution page and
returns a box; that box is written only when the stored position has no
`continuation_regions` (textbooks, or a question whose solution was not
found) and was not edited by a person (`solutionRefReplaceable`, Edge
`textbook_problem_fix.ts`). Before 2026-11-20 the box replaced the first
region of mock questions with a solution logic error, so the owner saw a
whole page as the original solution of exactly the questions to decide.

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
  (`transferFigureMarkers`), so the line format survives. A problem whose
  figure search found nothing while the render check reports a missing
  solution figure is searched once more in the same run
  (`solutionFigureSearchMissed`).
- **Long solutions.** The transcription sent to the compare step and the fix
  pass is cut at `SOLUTION_TEXT_MAX_CHARS` (12,000; a 30번 solution passes
  3,000 characters), and the transcription call may write 20,000 output
  tokens.
- **A settled solution is not transcribed again.** When the answer is not in
  dispute and the printed solution is already transcribed, the fix pass's
  re-transcription is dropped (`isSolutionSettled`, `solutionSettled`). This
  includes a problem whose only math issue is a solution logic error: the
  owner closes that one by picking the corrected text or the original.

Only the score on the card and the print conventions below are specific to
mock exams. The solution rules run for textbooks and school exams too; see
`textbook-review.md`, "Solution text rules".

### Print conventions set by code

Four things are set by code, with no AI call, in the consistency check
(Edge `textbook_consistency.ts`, pure rules in `textbook_mock_format.ts`).
They run only when the review scope is a mock section, which the handler
knows from `mock_exam_sections.pb_document_id = book_id`. Like every
consistency fix they are staged with source `ai` and applied at confirm, and
they leave alone a field the owner staged and a solution typed by hand
(`solution_source = 'manual'`). Fix titles in the staging note: "점 이름 곧은
글자", "출제의도 표기 통일", "그림을 선지 아래로", "수식 뒤 조사 붙여 쓰기".

For a mock scope the runner calls the consistency check twice: right after the
AI review rounds, so the render check sees the final cards, and at the end as
for textbooks (`TextbookReviewPipeline.runAll`, `scope.isMockExam`). A fix
clears `render_checked_at`, so each changed question is render-checked once
more.

**Figure under the choices** (`figureLayoutBelowChoices`). The figure layout
item gets `position: 'below-choices'` when the top of the figure box
(`pb_figure_assets[].bbox_1k`, same page as the crop, centre inside the crop
region) is at or below the bottom of the choice marks
(`choice_number_region_1k`, minus 2). The question must have at least two text
choices. A figure inside a text line (`inline-text`) or in a horizontal group
is not moved, and a figure already below the choices is never moved back. The
V2 engine prints such a figure after the choices
(`xelatex_v2/template.js`); the manager lists the position as "선지 아래" in
the figure settings of the review screen. The fix pass keeps the position when
the AI measures the figure as "below the text" (`buildFigureProposal`), and
the problem-bank figure editor keeps it when only the size is changed.

**Upright names** (`uprightNames`). The engine prints every non-Korean letter
as math italics; only `\text{…}` and `\mathrm{…}` are upright. Stems, common
stems and choices carry no `$`, so a name becomes `\text{AB}`. Solutions use
`$…$`: inside math a name becomes `\mathrm{AB}`, outside math
`$\mathrm{AB}$`, because the learning app shows text outside `$` as plain
text. Primes and subscripts stay outside the command (`\text{F}'`,
`\text{OH}_1`); `′` and `₂` in solution prose become `'` and `_{2}`.

What is made upright:

- a name after a head word: 점 A, 두 점 P, Q, 중심이 O, 수선의 발을 H, 선분
  AB, 삼각형 ABC, 사각뿔 A-BCDE, 평면 ABC, (단, O는 원점이다.);
- a label after 상자, 주머니, 과목, 학생, 사람, 팀, and "A 지점";
- a run of two or more letters inside `\overline{…}`, `\overrightarrow{…}` or
  after `\angle`, `\triangle`;
- anywhere else, a run of two or more letters that are all point names of
  that question, and a single such letter standing alone in prose (Korean,
  comma or bracket on both sides, or a coordinate form `P(a, b)`).

What stays italic, as on the page: a name after 원, 구, 곡선, 도형, 집합,
사건, 함수, 확률변수, 넓이, 값 and the like (원 O, 구 S, 사건 A, 넓이 A,
최댓값 M), and a single letter inside a formula (`\sin A`, `A=2B`,
`\overline{X}`, `P(X)`, `{}_5C_2`). The letters are collected per question
from stem, common stem and choices, and for a solution also from the solution
itself (`collectNameSets`). A text with unbalanced `$` is left unchanged, and
so is any result that differs from the source by more than the wrappers.

**`[출제의도]`** (`unifyIntentMark`). A head `출제의도 :`, `<출제의도>` and
the like at the very start of the solution becomes `[출제의도] `. The
transcription prompts ask for the same form.

**Particle after math** (`attachParticles`). The text taken from the problem
PDF has a space between a formula and the particle after it in about a
quarter of the stems (`f(x)=x^3-8x+7 에 대하여`, `학생 16 명을`); the page has
none, and the engine prints the space. The rule removes spaces and tabs on
one line, nothing else:

- in a stem, common stem or choice, between a character that ends math (a
  digit, a Latin or Greek letter, `)`, `}`, `]`, a prime, `|`, `%`, `°`) and
  an attachable word; a `]` that closes a Korean marker (`[그림]`,
  `[[공백:3]]`) does not count;
- in a solution, between a closing `$` and an attachable word.

An attachable word is a whole word from closed lists: a particle (은, 는, 이,
가, 을, 를, 와, 과, 의, 에, 에서, 로, 으로, 까지, 에서의 …), a form of 이다
(이다, 이고, 이므로, 일, 인, 라, 라고 …), or a unit or attached noun with an
optional particle (명, 개, 번, 번째, 장, 회, 가지, 쌍, 배, 축, 좌표, 절편:
`16 명을`, `x 축에`, `y 절편은`). The word must end at a space, a punctuation
mark or the line end, so `f(x) 위의`, `3 이상의`, `2 개수`, `k 배수`,
`a 이차함수` keep their space. The rule runs after the names are wrapped, so
`\text{A} 와` is caught too. Because `sameRenderedMath` ignores spaces next to
math symbols, the consistency check writes a stem this rule changed without
asking it.

A corrected solution the AI wrote for a solution logic error (finding
`ai_solution_logic`) gets the same three solution rules while it is still
open (`formatSolutionFixProposals`), because once the owner picks it the
value is the owner's and code does not change it again.

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

A 22번 or 30번 solution can pass 100 printed lines. The card page height
follows the text (`explanation_card_page.js`), and a solution that still does
not fit one page is reported as `explanation_card_overflow` rather than
returned as a blank card. See `textbook-review.md`, "Solution text rules".

To list failing questions without opening the app, run the batch tool from
`apps/yggdrasill_manager` (`tool/textbook_batch.dart`, see its header):

| `BATCH_STEP` | What it does |
|--------------|--------------|
| `mock` | start the exams in `BATCH_VALUE`, or continue stalled ones |
| `mock_status` | status only; every exam with a workflow when `BATCH_VALUE` is empty |
| `mock_continue` | run unconfirmed sections again from the review phase |
| `mock_restart` | drop AI-staged values and review again from the start (no re-extraction; values the owner staged are kept) |
| `mock_unstage` | drop the AI-staged fields in `BATCH_VALUE` (for example `solution_transcribed`) of the questions in `BATCH_CROPS`; values the owner staged are kept |
| `mock_prepare` | run prepare only, no review: solution positions that differ from the computed ones are rewritten (positions a person edited are kept); nothing is transcribed again |

`mock_continue`, `mock_restart` and `mock_prepare` take `BATCH_ONLY`
(`common`, `probstats`, `calculus`, `geometry`, comma separated) to run only
those sections.

Each question that is not 준비됨 is printed with its blockers and the card
error, render issue, quality issue, answer mismatch, solution logic error
(with "교정본 있음" when the AI wrote a corrected text) and correction notes;
the same fields are in the result JSON under `build/textbook_batch/`.

The per-question steps of the tool (`snapshot`, `render`, `solfig`, `answer`,
`stem`, ...) work on a mock section with `BATCH_BOOK=<section document id>`,
`BATCH_GRADES=<course label>`, `BATCH_OPEN=true` and `BATCH_CROPS`.

### Confirm

Confirming a section applies the reviewed values as for textbooks, then
`POST /pb/mock-review/publish` (`publishMockReview`) publishes the questions
of a section created by the review, writes `meta.mock_review.published_at`,
and syncs the learning-app presets (a 고3 elective preset needs both the
common section and that elective published). Sections that were published
before this flow are left as they are.

### Pilot (2026-11-20 to 21)

Three 고3 exams were run to "검수 대기" with the batch tool; nothing was
confirmed.

| Exam | Questions | Ready |
|------|-----------|-------|
| 2025 10월 교육청 | 46 | 43 |
| 2024 9월 평가원 | 46 | 45 |
| 2024 11월 수능 | 46 | 44 |

The six questions that are not ready all have a logic error in the printed
solution, which the owner decides in the review screen: 교육청 공통 20, 미적분
27 (opinion only, no corrected text), 기하 30; 평가원 기하 28; 수능 공통 20,
기하 28.

AI cost was about $16.5 in total: about $14.6 up to the first complete pass
of the three exams (including the runs repeated while the rules were being
fixed), $1.45 for the re-review after the three print conventions, and $0.43
for the re-review after the particle rule (37 questions changed, 38 cards
compared again in 13 calls). A re-review after a rule change costs little
because only the render check runs again, four questions per call.

### 2025 run (2026-11-21)

The six 2025 고3 exams other than 10월 (3·4·6·7·9·11월, 276 questions) were
run to "검수 대기"; nothing was confirmed.

- First pass: 243 ready, about 62 minutes, AI about $20.1.
- After the alignment reference fix (the region the figure is in, see
  `textbook-review.md`) and `mock_continue`: 251 ready, $1.25.
- After solution figures were searched per region for the 11 questions with a
  cut or mixed figure (`solfig` step, $0.82): 7 of them became ready, so 258.
- After centered solution figures were centered on the solution text width
  (gateway) and the tighten pass was added (see `textbook-review.md`; $0.22):
  4월 공통 15·21 became ready (260 by count; the six exams were not counted
  again as a whole). 9월 공통 15 has clean figures and is left with its
  solution logic error. 4월 확통 29 has clean figures (the first is still
  cut by a hair on the right) but the card put its figures in the wrong
  places.
- Causes found for the remaining single items, and what was changed
  (about $0.75; 267 ready by `mock_status`):
  - 4월 확통 29: the card uses the staged solution text (point names upright,
    staged by the consistency check), which still had the two old `[그림]`
    marks while the stored text had three. The figure search now brings an
    AI-staged solution text in line (`textbook-review.md`).
  - 7월 공통 22, 확통 28: `(★)` typed as a character was set in math, where
    the font has no ★. The engine now prints ▲▼■★ with the body font.
  - 4월 공통 21·22: the sentence after the condition box was printed inside
    the box (21 was ready by mistake, 22 was on engine hold). See "Box end"
    in `textbook-review.md`. Only these two of the 64 box stems of 2025 고3
    have the following sentence start with lowercase math.
  - 7월 미적분 28·30: this section has its own three-column solution paper
    and no question number starts in the middle column, so the column was
    unknown and the solution skipped it. `solutionColumns` now fills a column
    between two known ones that are about two column widths apart (ratio
    1.75 or more of the narrowest measured column; other 2025 papers are at
    1.03 to 1.07). The section was run again with `mock_restart`; 8 of 8
    ready. The 28 card prints the 증감표 arrows straight (↘ ↘ ↗) where the
    paper draws curved ones; the render check accepts it.
  - 11월 기하 29: the card was right ("제1사분면"); the render check had
    misread it and passed on a second run.
- The nine questions that are not ready are solution logic errors for the
  owner (3월 미적분 30, 4월 미적분 30, 6월 기하 30, 7월 확통 30, 7월 기하 26,
  9월 공통 15, 9월 미적분 29, 11월 공통 14·22). Ready questions were not
  compared by eye, apart from the cards of the questions named above.

### 2026 고3 3월 run (2026-11-23)

The first exam run from draft with the `mock` step (extraction, prepare, AI
review in one go, about 16 minutes): 46 of 46 ready.

- 공통 12·13·14 were ready with no solution: the page read skipped the third
  column of solution page 1, prepare marked the three "no solution", and the
  solution of 11번 was planned over that column. Fixed by the two rules in
  "Solution regions" (text-layer start points, not-found is held). No other
  고3 exam (2024, 2025) had a missing solution position.
- After the fix: "해설지 다시 읽기" (`progress.request = 'solutions'`) for the
  exam; the read skipped the column again and the text layer filled 12·13·14
  with no re-read. Then `mock_restart` for 공통: 22 of 22 ready, 46 of 46 for
  the exam. The answer·solution cards of 11·12·13·14 were compared with the
  solution page by eye.
- 기하 25 was held on the first run for a "[2점]" score and passed on a
  re-check; the card shows [3점]. The cause of the first report is unknown.
- One "해설 그림 다듬기" call for 공통 15 failed with HTTP 500 on the first run
  (the first box was used); it did not fail on the restart. Not examined.

### 2026 고3 6월 run (2026-11-23)

Run from draft with the `mock` step (about 14 minutes): 40 of 46 ready, then
42 of 46 after the two fixes below. The page read found every solution start,
so the text-layer fill and the re-read were not used on this paper.

- 공통 21: the solution prints a caption ("[그림 1]") under each of three
  graphs and the text refers to them; the card had neither caption. Owner
  decision: the caption is cut with the figure. The figure-finding and
  box-tightening instructions (`textbook_solution_figures.ts`) take a caption
  line directly under or over a figure into the box; the transcription
  instruction (`textbook_problem_review.ts`) does not write that line, so it
  is not printed twice. A sentence that refers to a figure ("[그림 1]과 같이")
  is solution text. Re-run with `solfig`: ready, card compared by eye.
- 기하 27: the figure is under the choices and extraction wrote no `[그림]`
  in the stem, so "그림 수와 그림 자리 불일치" held the question although the
  card was right. Owner decision: `checkItemConsistency` adds the marker at
  the end of the stem (`figure_marker_below_choices`) when every figure
  without a marker is under the choices on the page
  (`figureOrdersBelowChoices`) and its layout position is `below-choices`.
  Mock questions only; a stem or layout the owner staged, an inline or
  grouped figure, and a figure above the choices keep the finding. Before
  this the finding was kept on purpose (the unit test said so).
- Not ready, for the owner: solution logic errors 공통 11·15, 확통 28,
  미적분 30.
- The first attempt stopped at once with Gemini HTTP 402 (prepaid credits
  used up); a failed section resumes from its stage when `mock` is run again.

### 2026 고3 5월·7월·9월·10월·11월 run (2026-11-23)

The five exams were run together with the `mock` step (about 52 minutes):
5월 42, 7월 42, 9월 45, 10월 40, 11월 45 of 46. No solution start was missing.
With 3월 (46) and 6월 (42) that was 302 of 322; after the fixes below 313 of
322 are ready.

- 10월 기하 23~28: that solution paper has no answer line, and the
  transcription moved the last value of the solution ("이므로 k=5") into
  `solution_answer` and left it out of the text. Owner decision: the
  transcription instruction says the final conclusion is solution text and
  stays even when the same value is the answer. `mock_restart`: 8 of 8, the
  text of all eight ends with the conclusion (read from the DB).
- 7월 기하 28·30 and 10월 기하 30: edge column (see "Solution regions").
  `mock_prepare` over all 28 sections of 2026 changed the continuation of
  exactly these three questions. (The 3월 elective sections also moved the top
  of 10 regions by 1 to 2 thousandths, from the earlier re-read of that
  solution paper; they were not transcribed again.) After `mock_restart` the
  7월 기하 cards of 28·30 lacked the figures of the new column; `solfig` found
  them. Why the restart did not is not examined.
- 5월 공통 15: the caption "[그림 2]" is at the top of the next column, away
  from its figure. Owner decision: only in that case the transcription writes
  the caption as a line right after `[그림]` (left-aligned on the card, not
  centered). Re-run with `finish` + `BATCH_VALUE=rerun` for that one question.
- 5월 공통 21, 5월 기하 30 (figure box cut on the right): `solfig` again gave a
  full box. Nothing was changed; the box is still the model's answer.
- 7월 공통 13 (choices inside the problem figure): fixed by the original
  comparison once it ran.
- **The original comparison did not run for two sections.** The problem cards
  of a section are typeset as one document (`batchRenderThumbnails`); when
  one question fails in LaTeX the whole call fails and no card of the section
  is compared with the original, while the questions stay ready (the run only
  reports "문항 카드를 찍지 못해 원본 대조를 못 했습니다"). It was not load.
  - 7월 공통 20: extraction wrote a `[수식제시시작]` block with `&=` aligned
    lines and `\text{box{~~}}` for the blanks; the engine typesets each line
    of the block on its own ("Misplaced alignment tab character &"). The
    review staged a stem with `\begin{aligned}`, which fails as well
    ("Missing } inserted"). It is the only such block in the mock exams of
    2024 to 2026.
  - 9월 확통 27: the rows of the table end with one backslash instead of two
    ("Misplaced \noalign"). Every other table (10 questions) has two. This
    question is ready although it has no problem card.
  The other questions of the two sections (16 and 5) were compared with
  `render` and the crop ids of the rest; all ready.
- 7월 미적분 30 (not ready): the solution graph is as wide as its column on the
  page and about 0.7 of that on the card. `solutionFigureWidthEm` takes one em
  as 17.5/1000 of the page width for every solution paper. That fits the
  595pt-wide papers (11pt text, 18.5/1000); on the 841pt-wide three-column
  papers of 교육청 the text is 9.4 to 11.9/1000, so every solution figure of
  those papers is smaller against the text than on the page.

Owner decisions on these (2026-11-23) and what was built:

- **A failed card batch is split.** `renderThumbnailGroups`
  (`gateway/src/problem_bank/preview_batch_fallback.js`) renders the section
  as one document; a group that fails is halved and rendered again until the
  failing question is alone. That question gets `render_failed`, the others
  get their cards. At most 12 failed renders per call; past that the rest are
  `render_skipped`. The call answers 500 only when no card was made, and the
  200 answer lists `failedQuestionIds`.
- **A mock question without a problem card is not ready.** New blocker
  "문항 카드 없음" (`problemCardMissing`: render check done with
  `checked_problem = false`), mock exams only. The render step picks such
  questions up again. Textbook questions are not covered (112 rows have that
  flag).
- **Aligned display block.** A `[수식제시시작]…[수식제시끝]` block whose lines
  are aligned with `&`, or that holds an `aligned` split over lines, is typeset
  as one `[수식제시]\begin{aligned} … \end{aligned}` line
  (`collapseAlignedDisplayBlocks`). A block without alignment is typeset line
  by line as before.
- **Table row ends.** The consistency check rewrites a row of a `tabular`
  that ends with one backslash to two (`fixTabularRowEnds`, fix code
  `table_row_end`), for textbooks and mock exams; not when the owner staged
  the stem.
- **Solution figure width follows the two-column paper.** For a mock question
  the width is scaled by 350 / (width of the solution column the figure is
  in) when that column is narrower than 95% of 350 (`kMockSolutionColumn1k`,
  the column of the 수능 two-column paper), still at most 20em. A stored
  figure keeps its width until figures are found again (`solfig`).

After `finish` on 9월 확통 27 and 7월 공통 20 and `solfig` on 7월 미적분 30
all three are ready: 315 of 322. Seen on the cards: the table of 9월 확통 27
is typeset (below the text; on the page it is at the right), the graph of 7월
미적분 30 is about as wide as the text column. 7월 공통 20 was ready by the
model's comparison although inside the box the aligned formulas ran on with
the text around them ("의하여" left of a formula, "이다." right of it).

Second round of owner decisions (2026-11-23):

- **An aligned display line inside a box takes its own line.** In
  `renderDecoLine` a line `[수식제시]\begin{aligned}…\end{aligned}` (what
  `collapseAlignedDisplayBlocks` produces, or the same written directly) starts
  a new paragraph, indented 2em, and ends it. Every other `[수식제시]` line in
  a box is unchanged (the marker is dropped and the formula runs on). 7월 공통
  20 after a new render check: the three aligned formulas stand on their own
  lines; the plain lines of the box still run on (see Known limits).
- **Width of figures already found.** New step `solfig_width`
  (`recomputeSolutionFigureWidths`): no AI and no new crop, only `width_em`
  is recomputed, and only where the stored value is still the old formula's
  value. On the 19 other questions with solution figures of the 2026 교육청
  exams it changed three (7월 공통 14: 11.5 → 16; 7월 기하 28: 13.5 → 18 twice;
  7월 기하 30: 10.5/12.5/14 → 14/16.5/19), all ready after the render check
  (measured size 1.0 to 1.1 of the original). The other 16 were left: their
  widths (13.08 to 24.17) had already been set by the render check's own
  resize (`resizeSolutionFigures`) to the size on the page.

- Not ready, for the owner: solution logic errors 5월 미적분 26, 6월 공통
  11·15, 확통 28, 미적분 30, 9월 공통 15, 11월 기하 30.

### 2024 고3 3월·4월·6월·7월·10월 run (2026-11-23)

The five exams that were still drafts were run with the `mock` step (63
minutes, extraction included): 3월 46, 4월 40, 6월 42, 7월 45, 10월 44 of 46
(217 of 230). 9월 and 11월 were confirmed before and were not touched. One AI
call timed out (504 on 10월 공통 19~22) and the run's own retry filled all four.

Re-runs after that: 222 of 230 (3월 46, 4월 44, 6월 43, 7월 45, 10월 44).

- Solution figure box cut (`solfig` again): 4월 공통 8 and 4월 기하 29 ready.
- Solution figure boxes set by hand from the solution page (`page` step to
  write the page, then `solfig_recrop`; no AI figure search): 4월 공통 13 (box
  bottom 608 → 617 so the label "x=a" under the axis is in) is ready. 6월 공통
  15: a second `solfig` found the missing graph of (ii) (4 graphs), then two
  boxes were widened by hand (axis ticks 0 and 1 of the first graph, the label
  "y=2t-k" of the last); its render finding is gone and it stays blocked on the
  solution logic error only. On Windows a `BATCH_VALUE` with `|` cannot go
  through `--dart-define` (cmd takes it as a pipe); put it in a JSON file and
  pass `--dart-define-from-file`.
- 4월 미적분 30 (`>` transcribed for `≥`): `finish` + `BATCH_VALUE=rerun`,
  ready.
- **A logic-error finding judged against a stem that was fixed later.** The
  solution logic is checked before the original comparison. Where extraction
  got the stem wrong (10월 공통 20: lower limit 0 for 3; 6월 미적분 27: AB/AC
  for AC/AB), the logic check reports that the solution answers another
  problem; the original comparison then stages the right stem, and the finding
  stays. Both were re-solved with `finish` + `BATCH_VALUE=rerun`: 6월 미적분 27
  ready, 10월 공통 20 now has a finding about the solution itself. Such a
  finding has no corrected text ("교정본 있음" is absent). At the time of this
  run the pipeline did not re-solve these on its own; see the rule below.
- Not ready, for the owner: solution logic errors 4월 공통 22, 확통 28, 6월
  공통 15·21, 확통 28, 7월 미적분 29, 10월 공통 20, 미적분 30.

The 2024 고1 and 고2 exams (8, drafts) were left; a 고1 or 고2 exam has not
been through the review yet.

### Solution logic re-check after a stem fix (owner decision, 2026-11-23)

Why the stale finding stayed: a logic error sets the answer axis to `issue`,
`_bulkMathFixes` then stages the answer and sets the axis to `clean`
(`_stageAnswer`), and the stem proposal is applied later in
`_bulkQualityFixes`. The math re-solve only takes `issue` items, so nothing
solved the question again with the fixed stem. (All 8 open logic findings of
the 2024 run had the answer axis `clean`.)

Rule: a question with an open solution logic finding whose stem, choices or
common stem were staged after its last solve is solved once more with the
fixed text (one AI call per chunk of such questions). The ready criteria are
unchanged.

- App: `TextbookProblemReviewItem.solutionLogicRecheckCandidate` (open logic
  finding, not approved, a staged note with `stem`, `choices` or
  `common_stem`). `runAll` calls `_mathResolvePass(..., logicRecheck: true)`
  for the candidates right after `_bulkQualityFixes`; when something was
  re-solved it runs `_bulkMathFixes(withFixPass: false)` once more, so the
  result goes through the same answer step as the first solve.
- Edge (`textbook_problem_review`, `math_only` + `logic_recheck: true`): the
  last solve time (`analyzed_at`) is not in the overview, so the server reads
  it and decides with `isLogicRecheckTarget`: only a requested question whose
  problem text was staged after `analyzed_at` joins the math-only targets. A
  question already solved with the fixed text is skipped without an AI call,
  so a real logic error is not solved again on every run. As in every
  math-only solve, the transcription and the quality verdict are kept and the
  `ai_solution_logic` finding is resolved or rewritten.
- Checked: unit tests on both sides; with the deployed function, `finish` on
  10월 공통 20 (already solved after its stem fix) sent the re-check and nothing
  was solved (`analyzed_at` unchanged). The path where a stale question is
  actually re-solved has not run on real data: no stale case was left.

### Known limits

- The caption rule is an instruction to the model. A caption cut with its
  figure was seen on one question (6월 공통 21), a separated caption written
  as text on one (5월 공통 15). A figure whose box is set by hand is not
  covered.
- Every section of the 2024 (9월, 11월) and 2025 exams is confirmed, and
  `mock_prepare` skips a confirmed section (prepare also rewrites crops,
  answers and the published flag). For those there is a read-only preview:
  `POST /pb/mock-review/solution-preview` (`previewMockSolutionRefs`, batch
  step `mock_solref_preview`) computes the solution positions with the current
  rules and returns only the questions whose stored position would change. It
  writes nothing, skips positions edited by hand, and has its own path so that
  a gateway that does not know it cannot run prepare instead. Run on
  2026-11-23 over the 36 sections of 2024 9월·11월 and 2025: no question would
  change (the stored refs were read before and after: identical). 2026 10월 as
  a control: none, as expected. The other five 2024 exams are still drafts.
- A solution that skips a middle part and still ends properly would not be
  noticed by a text scan.
- 2025 9월 공통 (confirmed) had 16 questions checked without a problem card.
  They were rendered and compared again with `render` (2026-11-23): all ready,
  nothing staged.
- The split of a failed card batch was exercised by unit tests only; no real
  section has failed since.
- Inside a `[박스시작]` box a `[수식제시]` line that is not an aligned
  environment is not set on its own line: the marker is dropped and the
  formula runs on with the text unless `[문단]` stands around it (7월 공통 20:
  "b_{2k}=(2k-1)a_{2k}" follows "(ⅱ) n=2k … 일 때," on the same line). 14 other
  questions of 2026 고3 have such a line in a box; two were looked at (3월 공통
  12, 11월 공통 20: formulas on their own lines through `[문단]`). A block
  without alignment inside a box still closes the box.
- The model's original comparison passed 7월 공통 20 while formulas and text
  were run together. A ready question is not proof that the card was looked
  at.
- `solfig_width` and the new width rule were applied to 2026 only. The
  two-column rule and the render check's resize can disagree by up to the
  resize tolerance; the resize wins on the next render check that measures a
  ratio outside it.

- The text-layer fill needs a head of the form `N. [출제의도]`. A solution
  paper that starts solutions another way (or has no text layer) goes to the
  AI re-read, which was exercised only by unit tests. The re-read covers 4
  pages at most and skips a section of which no solution was found at all.
- "해설지 다시 읽기" reads the positions of every section again, and a
  re-read position can differ by a few thousandths from the stored one. The
  stored solution refs of a section change only when that section is prepared
  again.

- Re-uploading an exam from the menu extracts it again and restarts the review
  of all its sections. Re-extraction copies the answer-table answer again
  (manual answers are kept).
- A question held for a failed card skips the fix pass until its card renders,
  so it needs a second run.
- The render-engine hold panel builds its scope without `scoreOnCard`; its
  problem cards show no score.
- 고1 3월 uses every middle-school concept as candidates (about 2,100 per AI
  call).
- When prepare changes a solution position (a new gateway rule, a re-anchored
  solution), the stored transcription is not redone on its own; `mock_continue`
  does not run prepare. Run `mock_restart` for that section. There is no
  automatic reset because it would also drop what the owner staged later.
- A solution PDF without a text layer keeps the column top near the highest
  number, so a continuation at the top of a column can be cut when no number
  starts a column. Every solution PDF seen so far has a text layer.
- A render-check finding on a solution whose math is clean has no automatic
  repair: the fix pass leaves a settled solution alone. Such a question is
  re-checked (`render` step) or corrected by hand (`solution` step).
- Print conventions:
  - Labels after 상자 and 과목 were checked on the page. 주머니, 학생, 사람,
    팀 and "A 지점" are upright by the same reasoning, not by a page seen.
  - A point letter that is used in prose as the size of an angle ("A가 예각일
    때") would be made upright.
  - A letter that occurs only in the solution, with no head word, stays as
    transcribed (2024 수능 확통 30: "앞면을 H, 뒷면을 T"). Coordinates written
    outside `$` in a solution stay plain text.
  - The rules change the stem. A consistency finding the owner dismissed
    before reopens, because its signature includes the stem.
  - A field the owner staged is not touched (2024 수능 확통 27 stem).
  - A problem PDF without a text layer gives no choice region, so no figure
    is moved below the choices. A changed crop region does not clear a stored
    empty region. The problem-bank figure editor keeps "선지 아래" but cannot
    set it; the figure settings of the review screen can.
  - The particle rule attaches a one-syllable word from its list even when it
    is not a particle ("=0 이 식에서", 이 as "this"); none was found in 138
    questions. A space before math (`제 10항`) and nouns other than 축, 좌표,
    절편 are not handled.
  - Line breaks the page sets on purpose inside a box (one clause per line,
    2025 10월 확통 30) are not kept; the card runs the box text on.
- The second consistency pass of a mock run (`scope.isMockExam`) has no unit
  test; there are no pipeline tests with a fake service. It was verified on
  the three pilot exams.

## 2021–2023 평가원·수능 run (2026-11-23/24)

Nine 고3 exams (6월, 9월, 수능 of 2021–2023) were run from draft with the
`mock` step, one year per `flutter test` run (43–52 minutes a year). Nothing
was confirmed. 374 of 414 ready after the re-runs below:

- 2023: 6월 43, 9월 43, 수능 39. 2022: 6월 41, 9월 41, 수능 43.
  2021: 6월 42, 9월 40, 수능 42 (each of 46).
- Left: 31 with only a solution-logic finding (owner's call), 6 solution
  figures, 3 render findings. The figure and render ones were not worked on.
- The Edge function returned 500 for some chunks during the run. Render-check
  chunks were picked up by later passes; two review chunks were not
  (2022 9월 확통 23–28, 2021 9월 공통 1–6) and were re-run with `finish` on
  those crops.
- Engine fix found here: an explanation line `(1) $b_2$의 값` gives
  `$\displaystyle \text{(1)}\;$$\displaystyle b_2$`, and the pass in
  `explanationBody` that drops a doubled closing `$` turned that into
  unbalanced math (xelatex `Missing $ inserted`, no answer card). The pass now
  leaves `$$` that is followed by `\displaystyle ` alone. Verified on 2023 6월
  미적 30 and 9월 미적 29.

## 가형·나형 first run: 2020 수능 (2026-11-24)

- Extraction and preparation: 30 crops, 30 answers and 30 solutions for each
  of `ga` and `na`, nothing missing. Review: 가형 28 of 30 ready, 나형 27 of 30.
  One 가형 card and one 나형 card were compared with the original by eye.
- `mock_exam_items.score` is empty for these items, so the same-question
  comparison does not use the score.
- Same-question links: `gateway/src/mock_exam/legacy_links.js`
  (`matchLegacySameQuestions`) compares normalized stems by character-bigram
  overlap and accepts a pair only when the stems match (0.92 or more), the
  answer value is the same and, when both are objective, the choice values
  are the same set. It compares the answer value, not the answer number,
  because the two papers can print the same choices in reverse order
  (가형 6 ② = 나형 11 ④). A pair that is objective in one paper and
  subjective in the other is the same question when the subjective answer
  equals the value of the objective answer's choice (owner decision
  2026-11-24: one question id can serve both forms); the row carries
  `formDiffers`. Pairs that are alike (0.75 or more) but fail a condition are
  listed and not linked: same setup with a different question or a different
  asked value. `node scripts/mock_exam_link_legacy.mjs --exam <ids> [--apply]`
  prints the pairs and, with `--apply`, writes `same_as_item_id` /
  `same_as_source = 'auto'` on the 나형 item (rows marked `manual` are left).
  2020 수능: 5 same pairs recorded (나형 7·11·15·18·19 = 가형 5·6·26·13·12;
  15 = 26 differs in form only) and 3 alike pairs not linked (나형 21·28·29 ~
  가형 21·10·19).
- One question in the learning-app problem bank (2026-11-24). Both papers keep
  their own `pb_questions` row, so each paper's cards match its original
  (choice order can differ between the papers). The link decides which row
  the problem bank keeps (`pbSameQuestionCanonicalMap` in
  `learning_problem_bank_service.dart`): when only one of the pair is
  objective, the objective row (it carries the paper's choices, and every
  mock question also has `allow_subjective` with a subjective answer);
  otherwise the 가형 row the link points to. `searchQuestions` drops the other
  row only when the kept row is in the same list (`pbDropSameQuestionRows`),
  so a list of one 나형 paper still has 30 questions. Adding to the cart
  skips a question whose pair is already in the cart
  (`sameQuestionKey`). The links are read from `mock_exam_items` and cached
  for 5 minutes; if the read fails the list is shown without dropping. Not
  covered: the manager problem bank, a cart restored from saved question
  ids, and a 400-question list cut that leaves out the kept row. Not checked
  on screen (no 가형·나형 section is published yet).
- Hand fixes after the first run: 가형 19 illustration moved below the
  choices (`layout`, position `below-choices`), 나형 20 second solution graph
  re-cropped. 57 of 60 ready. 나형 10 shows `\sum fromk=1`, which is what the
  original solution PDF prints.

## Solution figure fixes found on the 2021–2023 leftovers (2026-11-24)

- `arrangeSolutionFigures` grouped a left-column figure and a right-column
  figure into one row when their heights overlapped (2022 9월 기하 30,
  2021 6월 공통 15). A row now needs both figures in the same solution
  segment and horizontal ranges that do not overlap by half or more (the
  second guard also stops two crops of the same place from becoming a row).
- `solutionFigureAlign` returned `right` for a figure that fills the column
  (region 512–867, figure 514–867: margins 2 and 0). When both margins
  together are under 4% of the region width the figure is `center`, the same
  as a figure with no margin (2021 수능 공통 22).
- Re-cropped by hand: 2023 6월 공통 21 (label ran into the column gutter),
  2021 수능 기하 30 (right part cut), 2021 6월 공통 15 (crop took in a text
  line below the graph).
- After these, 378 of 414 ready for 2021–2023. Two more causes were fixed
  after the owner's decision (379 of 414):
  - 2022 9월 공통 22 has 10 solution graphs and `MAX_FIGURES` in
    `textbook_solution_figures.ts` was 8, so the last two were dropped. It is
    12 now (deployed). The question has 10 figures and its card was checked;
    a solution-logic finding remains.
  - 2023 수능 확통 26: `shouldStackCaseConditionCell`
    (`render_engine/utils/text.js`) moved a cases condition to its own line
    when the cell was 34 or more characters of LaTeX source, so
    `X & (X가 0 또는 1의 값을 가지는 경우)` (43 source characters, about 15em
    on paper) was split. The rule now estimates the width on paper
    (`estimateCaseCellWidthEm`: 한글 1em, Latin and digits 0.5em, relations
    1.3em) and stacks only when widest formula cell + 1em + condition is
    over 22em (a card line is about 30em; `f(x)=` and the brace take 4–5em).
    A natural-language connective in the condition is still required. The
    V2 template passes `resolveProtectedText` so protected `\text{}` tokens
    are measured by their text. Checked against every `cases` block in
    `pb_questions.stem` (2,306 blocks): 8 questions lose a stacked row (5 mock,
    3 market books), 1 keeps it (formula cell about 12em), none gains one.
    Solution texts were not counted. Cached renders are not refreshed by
    this; a question shows the new layout after its next render.
- Known weakness seen in this run: when the network dropped during
  preparation, `mock_continue` resumed the 나형 section from the AI review
  step and reported it complete with 0 of 0 items. `mock_prepare` with
  `BATCH_ONLY=na` and another `mock_continue` fixed it. After a run, a section
  showing `준비됨 0/0` means preparation did not happen.

## One question, many slots (decided 2026-11-24, in progress)

Owner decision: a question that two papers share is one `pb_questions` row,
so its meta, solutions and learning records exist once. Values that differ by
paper live on the slot (`mock_exam_items`). The 14 remaining 가형·나형 exams
are not run until this is in place.

Why not two crops on one question: `textbook_crop_question_links.pb_question_id`
is unique; `textbook_review_apply_staged` writes kind, answer key, meta and
solutions to the question per crop (the later crop would win, and an empty
solution deletes the other paper's confirmed one); the extract worker deletes
and recreates a section document's questions on a re-run; publish and the
preset's 30-question check go by `document_id`.

Design:

- One section owns the question: the objective paper when the forms differ
  (it has the printed choices), otherwise 가형. The other paper's slot points
  to it with `pb_question_id` and has no crop or review record of its own, so
  the owner section's confirm writes meta and solutions once.
- Slot values (migration `20261124100000_mock_exam_item_slot_values.sql`),
  written only when they differ from the question: `score` (else
  `meta.score_point`), `choice_order` (slot choice i = question choice
  `choice_order[i]`; reversed is `{5,4,3,2,1}`), `stem_override` (the form
  pair ends "…는?" on one paper and "…를 구하시오." on the other),
  `merged_at`. `problem_number`, `answer_kind` and `answer_text` were already
  per slot. `score` existed and was empty on all 1,440 slots; it stays empty
  for a slot that uses its own question, because the manager edits the score
  on the question and syncs presets from there.

Steps:

1. Slot columns (this migration). Done.
2. Readers take slot values. Done 2026-11-24, not yet seen on a real merged
   paper (no slot is merged before step 3):
   - Preset (`mock_preset.js`, `syncMockExamPresetsForExam`): a paper's own
     questions still come from its section document; each merged slot of that
     section adds the owner's question under the slot's number
     (`slotQuestionRow` in `mock_exam/slot_values.js`). The form follows the
     slot number and the score is the slot's score or the question's. If the
     owner section is not published the paper stays under 30 and gets no
     preset.
   - Print (`mock_exam/paper_slots.js`, called in `processOneJob` of the
     export worker): the job options go through key whitelists in the API and
     the apps, so slot values are not carried in the preset. The worker reads
     them from `mock_exam_items` when the job is one 가형·나형 paper: every
     question is a 가형·나형 question of one exam, more than half belong to
     one section (the paper), and every other question is a merged slot of
     that section. Then that question is printed with the slot's number,
     score, form, `stem_override` and `choice_order` (labels stay, contents
     move, the answer key follows). Any other job reads nothing and is
     unchanged; so are the template and the question rows.
   - Learning-app exam explorer (`_seedMockSlotQuestionModes`): a slot whose
     question belongs to another section (`meta.mock_exam_item.section`)
     starts in the form of its own number. Its number already came from the
     slot.
   - Question cards of a referencing slot: see step 5.
   - Check that existing exams are unchanged:
     `node scripts/mock_preset_compare.mjs` (from `gateway`, read-only)
     rebuilds every preset with the current code and compares it with the
     stored row. 2026-11-24: 101 exams, 63 presets, all identical. Run it
     again after step 3 and step 4.
3. Merge tool, run after both sections are reviewed and before confirm.
   Built 2026-11-24, not applied to any exam yet (the apply needs the owner's
   approval): `node scripts/mock_exam_merge_same.mjs --exam <ids> [--apply]`
   from `gateway`, logic in `mock_exam/merge_same.js`. Without `--apply` it
   only lists what would change.
   - Pairs are the `same_as_item_id` links. The owner question is the
     objective one when the forms differ, otherwise 가형's.
   - It writes to the other slot: `pb_question_id` (the owner's question),
     `score` when the two scores differ, `choice_order` when the choices are
     in another order, `stem_override` when the stems differ after
     `normalizeForMatch`, and `merged_at`. Then it deletes the slot's old
     crop and question; the database cascades the review records, meta,
     solutions and the delivery unit.
   - Before deleting it writes those rows to a JSON file per slot (default
     `%LOCALAPPDATA%\Yggdrasill\merge_backup`, outside the repository).
     The restore script of step 4 reads these files.
   - It refuses a pair when: a section document is published or a question
     is published; the question to delete has learning or homework records
     (`MERGE_RECORD_CHECKS`); the choices cannot be paired one to one; the
     moved answer number is not that paper's answer; the owner's subjective
     answer differs from the short-answer paper's answer; the two stems
     differ and carry a different number of `[그림]` marks.
   - The steps are not one transaction. The slot is repointed first, so a
     stop in the middle leaves a duplicate question that the next run lists
     and removes.
   - Re-running extraction, review preparation or
     `mock_exam_link_legacy.mjs --apply` on a merged exam is covered by
     step 4.
   - Applied to the 2020 수능 on 2026-11-24 (owner approval), 5 pairs:
     나형 7→가형 5 (nothing differs), 나형 11→가형 6
     (`choice_order {5,4,3,2,1}`), 가형 26→나형 15 (owner is 나형,
     `stem_override`), 나형 18→가형 13 and 나형 19→가형 12 (slot score 4,
     question 3). After it: 가형 29 questions and crops, 나형 26, all 60
     slots have a question, no leftover duplicate. Read back with the real
     rows (sections assumed published, nothing written): both presets have
     30 questions in slot order with the slot's form and score, and the print
     path gives each referencing slot its number, score, form, stem and
     choice order (나형 11: answer ② becomes ④). Not seen as a printed PDF:
     the export worker only loads published questions and neither section is
     confirmed. 나형 15 (the owner of 가형 26) still has one open
     solution-logic finding.
4. Review preparation, publish and re-extraction know referencing slots.
   Built 2026-11-24 (`mock_exam/merged_slots.js`), tested with fakes only; no
   real re-extraction or preparation was run on the merged exam:
   - Re-extraction of the slot's section: the extract worker drops the
     questions of merged slots before it writes (`dropMergedSlotQuestions`,
     by `meta.mock_exam_item.item_id`, or by number when the question has no
     slot mark), so the duplicate is not recreated.
   - Re-extraction of the owner's section: the question ids change and the
     foreign key empties `pb_question_id` on both slots. After
     `linkMockExamItems` the worker points every merged slot at its
     partner's current question (`relinkMergedSlots`; the partner is the
     `same_as_item_id` link in either direction).
   - Review preparation goes by the section document's questions, so a
     merged slot gets no crop and needs no change. Publish sets the
     document's questions; a paper's preset needs the owner section
     published too (step 2).
   - `mock_exam_link_legacy.mjs` leaves merged pairs out of the comparison
     and does not touch their links.
   - Undo: `node scripts/mock_exam_merge_restore.mjs --file <backup.json>
     [--apply]` puts the deleted question, crop and review rows back and
     resets the slot. Rows the database recreates by itself are skipped on
     a key conflict. Not run against the real database.
   - Moved to step 5: the slot check that compares a referencing slot's
     card with its paper's original needs the slot-aware card render.
5. Lists, cards, slot check (built 2026-11-24).
   - Cards: `POST /pb/preview/batch-render` takes
     `mockSlotItemByQuestionId` (`{question id or uid: mock_exam_items id}`).
     For a merged slot that points to that question the card is rendered
     with the slot's stem, choice order and score (the number is not part of
     a card) and stored on the staged path, so the owner's own card file is
     untouched. A slot with nothing different gets the owner's card. The
     learning-app exam explorer sends the map for every referencing slot.
   - Learning-app problem bank (`pbMockSlotRows`, `_loadMockSlotRows`):
     when a listed 가형·나형 document has merged slots, each slot is added
     as a row of that document with the slot's number and score
     (`meta.mock_slot`). The row keeps the owner question's id, so a question
     listed in both papers is shown once and the cart holds it once. Only
     published owner questions are added. The interim hiding
     (`pbDropSameQuestionRows`) and the cart guard (`sameQuestionKey`) are
     removed. Known limit: a slot row shows the owner's stem and choice
     order, and a worksheet prints the owner's version.
   - Slot check: `BATCH_STEP=mock_slot_check` (`BATCH_VALUE=<exam ids>`,
     read-only) saves, for every merged slot, the slot's region of its own
     paper (`_original.png`) and the card rendered with the slot values
     (`_slot_card.png`) under `build/textbook_batch/slot`. A referencing slot
     has no review crop, so this is how it is compared with the original.
     Run on the 2020 수능 after the merge: all five slots match their paper
     (나형 11 choice order, 가형 26 short-answer stem, 나형 18·19 4점).
   - Manager section table: a section row shows how many of its slots use
     the other section's question, e.g. "가형 공통 4" on the 나형 row
     (`MockExamReviewSection.sharedSlotNote`, owner 2026-11-24). Those
     questions are not in that section's review list.
6. Run the 14 exams: extract and review, find same questions, merge, report.

Still open: which write branch of the extract worker a mock re-run takes was
not traced; the two guards of step 4 sit before and after all three
branches.

## Print differences found by the slot check (2026-11-24)

Comparing the five merged 2020 수능 slots with their paper showed five causes.
Owner principle: what matters is that a card prints like the original.

1. **Slot check ignored staged values.** `mock_slot_check` now collects every
   section's `previewOverride` and sends it as `questionOverrides`, like the
   review cards do.
2. **Merge copied the stem from before the review fixes.** A duplicate's
   staged stem is lost with the duplicate, so `planSameQuestionMerge` takes
   `stagedStemByQuestionId` (from `textbook_problem_analyses.staged_changes`)
   and uses the staged stem first, for the comparison and for
   `stem_override`. The 가형 26 slot of the 2020 수능 was rewritten from the
   merge backup (owner approval).
3. **A name right after a condition marker stayed italic.** `uprightNames`
   now also accepts a name whose previous character closes a marker such as
   `(가)` (`afterItemMarker`). It applies to questions reviewed from now on.
4. **Table cells lost `\text{P}`.** `unwrapLatexTextCommandsForTextMode`
   keeps `\text{…}` whose content is Latin letters only, so a table header
   prints `P` upright like the stem. Hangul `\text{합계}` is still unwrapped.
5. **Table printed below the stem instead of beside it.** See below.

### Table beside the end of the stem (`xelatex_v2/template.js`)

The papers put the table of a "…오른쪽 표준정규분포표를 이용하여 구한
것은?" question to the right of the last lines of the stem. Owner decision:
print it like the paper, and apply the same rule to every problem-bank
question, because the 수능 question is the standard.

- When: the stem has exactly one raw table (`[표시작]`), says "오른쪽 …표"
  (`stemSaysTableOnRight`; "오른쪽 좌표" does not count), the table is the last
  segment, the segment before it is plain text without sub-question marks, the
  table has at most 5 columns, and the question has no stored table position
  (`meta.table_layout`; a stored position always wins).
- How: `planSideTableCut` cuts the text segment by line and by sentence and
  picks the tail whose estimated height is closest to the table height. The
  head stays full width; the tail goes into a left `minipage` and is printed by
  the normal text path, so display formulas and the `[N점]` mark work as usual;
  the table goes into a right `minipage` (`sideTableWidthFraction`: 0.36 of the
  column for two columns, 0.45 for three, 0.55 for four or five). A stem
  shorter than the table goes to the left as a whole; with an inline question
  number the left box opens after the number and is narrowed by its width.
- A tail line whose formula is wider than the left box is never chosen
  (`sideLineFits`, counted by characters between Hangul and commas), because
  such a formula does not wrap and would run into the table.
- Not covered, printed below as before: a table that follows a box directly,
  a table followed by more text (sub-questions), tables of six or more
  columns, stems with two tables.
- The top rule of the table sits at the top of the Hangul letters of the left
  box's first line (owner 2026-11-24: "표 상단 선과 한글 본문의 상단선이
  일치해야 해"); the table is raised by the height of `가`, not by the strut.
- The left box is not justified on the right (`\rightskip` with stretch): in a
  narrow box justification spreads the words of a line that ends before an
  unbreakable formula.
- Where the cut goes depends on the source (owner 2026-11-24, after comparing
  with the books): a textbook question (`source_type_code = market_book`)
  puts the table beside the stem from its first line when every line fits
  (`planSideTableCut(..., prefer = 'top')`), like 개념원리 and 쎈 do; every
  other source keeps the 수능 layout (table beside the end of the stem).
- Line spacing: the left box is opened inside the stem spacing group
  (`stemLineSpacingTex`: stretch 1.53, `\lineskip` 0.8em), and that group
  closes after the `\par` that ends the side block. Without it the line that
  holds the two boxes is set with the document stretch (1.7) and the gap to
  the previous line is larger than between body lines.
- State: on by default (owner 2026-11-24). `PB_XELATEX_AUTO_TABLE_SIDE=0`
  turns it off. Tests: `gateway/test/xelatex_v2_table_upright_side.test.js`.
- The rule needs `source_type_code` on the question row: the card
  (`batchRenderThumbnails`), export worker and question-render worker selects
  carry it. A row without it prints with the 수능 layout.
- Known difference: the 2019 수능 가형 18 paper has the table mid-stem with
  the last line full width below it; the card keeps the last lines beside the
  table.

### Table fixes (2026-11-24, `xelatex_v2/template.js`)

Tests: `gateway/test/xelatex_v2_table_merge_cells.test.js`.

- **Merged cells.** `renderTableLatex` reads `\multirow{n}{*}{…}` itself (the
  package is not loaded): the cell is printed once, lowered to the middle of
  the rows it spans, and the rule under a row becomes `\cline` runs that skip
  the spanned columns.
- **Diagonal header cell.** `\diagbox{왼쪽 아래}{오른쪽 위}` draws the diagonal
  with tikz and makes that row 1.6 times as high. The stem of 2017 수능 나형 7
  was changed to this form (two header rows → one `\diagbox` row).
- **Row end with one backslash.** `normalizeTabularRowEnds` turns a single
  `\` at the end of a table line into `\\` ("Misplaced \noalign"). The 12
  stored stems with this were also corrected.
- **Absolute value inside braces.** `findTopLevelSetBar` treats an even
  number of top-level bars as absolute-value pairs, so
  `\{1-|-2|^{5}\}` is no longer read as set-builder notation.
- **Hangul in a superscript.** `unwrapLatexTextCommandsForTextMode` keeps
  `\text{…}` that sits inside an open brace group (`50^{\text{이상}}`).
- **Table inside a box.** `parseStemSegments` keeps a `[표시작]` table that
  starts inside a box without `<보기>` in that box (`boxTables` on the `deco`
  segment, one slot line per table); `renderDecoBoxLatex` prints the table at
  the slot. A `<보기>` box still closes before a table.
- Stems changed with owner approval (13 questions): the values before the
  change are in `%LOCALAPPDATA%\Yggdrasill\stem_fix_backup_20261123.json`.
- A local render script must pass `previewIndependentSetCommonStem: true`
  like pb-api does; without it the members of a set render empty ("XeLaTeX
  produced no PDF output").
- After an engine fix, `mock_continue` does not look at engine-held questions
  again (it only re-reviews from the AI step). `textbook_batch.dart`
  `mock_engine_recheck` does what the app button "코드 수정 후 재확인" does:
  only the "코드 수정 필요" questions of unconfirmed sections are printed and
  compared again. Result on 2016–2020 수능 (2026-11-24): the four held
  questions (2019 가18, 2017 가10·나17, 2016 가18) lost the hold; ready
  2016 52/57, 2017 48/57, 2018 49/57, 2019 49/57, 2020 52/55.
- 2019 나형 13: the stored stem has no table (dropped at extraction); the AI
  staged a stem whose table was written as `a | b` lines without
  `\begin{tabular}`, which the engine cannot print (no card). Cause: the fix
  instructions (`textbook_problem_fix.ts`) named the `[표시작]…[표끝]` markers
  but not what goes between them; they now give the tabular form with an
  example (deployed 2026-11-24). The staged stem of this question was replaced
  with the 가형 18 table form as an owner fix (`mock_stem` step) and the
  question is ready. Whether the new instructions make the AI write a
  printable table has not been observed yet.
- The same re-run blocked 2019 나형 18 (small shape figures inside the text
  line; same kind as 2016 나형 17). 2019 stays at 49/57.
- Still open: a `tabular` nested inside `\multirow` (고쟁이 255) does not
  render; the extraction prompt still asks for an image (`[그림]`) when a table
  has merged or diagonal cells.

## 2016–2019 수능 run (2026-11-24)

Ready 203/240: 2019 가형 27·나형 24, 2018 가형 27·나형 25, 2017 가형 23·나형 25,
2016 가형 24·나형 28. Most blocked questions are solution-logic findings.

- **2017 failed at extraction first.** Both solution PDFs have broken object
  references; pdf-lib cannot walk their page list ("Expected instance of
  PDFDict"). `mock_exam_worker.js` `pdfPageCount` now falls back to poppler
  `pdfinfo` for the page count (pages and text are read with poppler anyway).
  The source PDFs are not changed.
- Same questions: 12 pairs (3 per exam) linked by `mock_exam_link_legacy.mjs`
  and merged with owner approval; backups under
  `%LOCALAPPDATA%\Yggdrasill\merge_backup`. Not linked: 2017 나12~가6 (same
  stem, different choice values), 2017 나23~가23 (different questions), 2016
  나29~가18 (asks a different value).
- Slot check after the merge: 11 of 12 slots match their paper. 2019 나16 (=
  가14) prints its box closed before the table although the paper has the
  table inside the box; 2017 나15 has the table below until the side layout
  is on.
- Render problems found on this run (fixed afterwards, see "Table fixes"
  above): `\multirow` in a raw table is unknown to the engine (2017 나형 7 has
  no card); a table row ending with a single backslash ("Misplaced \noalign",
  2023 수능 확통 30); `\{1-|-2|^{5}\}` is read as set-builder notation
  (`normalizeSetBuilderBars`) and breaks the 2018 나형 29 solution card;
  Hangul inside a superscript of a table cell (`50^{미만}`); a table inside a
  box closes the box.

## Not in this build

- Editing crop rectangles in the manager (regions are re-detected by
  re-running).
- Unit classification, student-app delivery.
- Solution pages in the learning app.
