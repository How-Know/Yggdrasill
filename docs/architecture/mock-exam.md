# Mock Exam Past Papers (모의고사 기출)

This note covers importing mock-exam past papers (교육청 학력평가, 평가원 6·9월
모의평가, 수능) from PDFs into the problem bank, keeping crop positions so the
learning app can open the original pages.

Status (2026-10-30): first build. Migration, gateway worker, manager workspace,
and the learning-app resource entry are new.

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

## Not in this build

- Editing crop rectangles in the manager (regions are re-detected by
  re-running).
- Unit classification, student-app delivery.
- Solution pages in the learning app.
