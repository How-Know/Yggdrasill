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

Re-runs set `progress.request`: `all` and `crops` re-queue problem-bank
extraction; `solutions` only re-reads the solution PDFs and keeps the existing
section documents; `problem_bank` only re-queues extraction.

Bulk import from a folder: `node scripts/mock_exam_enqueue.mjs --academy <id>
<pdf> ...` (same file-name rule as the manager dialog).

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
`exam-folder-H{1,2,3}-mock`). `MockExamResourceService` lists exams in `review`
as cards: one per problem paper, so 고3 has one card per elective (common 22 +
that elective's 8; common pages are the same in every elective paper) and 고1/2
have one card per exam. A card opens `TextbookExplorerController` in mock mode:
number cards first, then item cards or the original PDF (signed URL of the
problem paper). Item cards use the linked `pb_questions`, which the learning app
reads only when `is_published = true`, so they appear after the manager
publishes the section documents. Number cards and the original work before that.

## Not in this build

- Editing crop rectangles in the manager (regions are re-detected by
  re-running).
- Unit classification, student-app delivery.
- Solution pages in the learning app.
