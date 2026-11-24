// 모의고사 한 구간(공통·선택과목)을 교재 검수 테이블에 올린다. 구간 문서 하나가 검수 범위 하나다.
//
//   책(book_id)  = 구간 문서(pb_documents.id)와 같은 UUID 의 resource_files 행(category 'mock_past', 비공개)
//   범위         = grade_label(개념 후보 과정들을 '+' 로 이은 라벨), big_order 0, mid_order 0, sub_key 'A', sub_index 0
//   문항 크롭    = mock_exam_items 의 쪽·영역(좌표만). 원본은 시험지 PDF 에서 그때그때 그린다.
//   정답         = 문제은행 정답(추출 때 해설지 정답표에서 옮긴 값)을 채점 정답으로 옮긴다.
//   해설         = mock_exam_items 의 해설 위치에, 다음 단·쪽으로 이어진 영역을 덧붙인다(solution_layout.js).
//   선지 번호 자리 = 시험지 글자 층에서 ①~⑤ 가 놓인 영역을 읽어 mock_exam_items 에 적는다(choice_layout.js).
//   공개         = 검수에서 만든 구간 문서(meta.mock_review.publish_on_confirm)의 문항은 확정할 때까지 비공개다.
//
// 여러 번 불러도 같은 결과가 나온다. 사람이 고친 정답·해설 위치·문항 영역은 덮어쓰지 않는다.
// 설계: docs/architecture/mock-exam.md

import {
  DEFAULT_RETRY_DELAYS_MS,
  examAnswerSeed,
  runQuery,
  runStep,
} from '../problem_bank/school_exam/review_staging.js';
import { choiceNumberRegion, readChoicePages, regionInside, validChoiceRegion } from './choice_layout.js';
import { ELECTIVES, LEGACY_TYPES, SECTION_LABELS } from './mock_pages.js';
import { mockExamTitle, mockReviewCourseLabel } from './mock_courses.js';
import { mockReviewPending, syncMockExamPresetsForExam } from './mock_preset.js';
import { planSolutionSegments, solutionRegionOf } from './solution_layout.js';
import { readSolutionEvidence } from './solution_evidence.js';

export const MOCK_EXAM_CATEGORY = 'mock_past';
export const MOCK_EXAM_SERIES_KEY = 'mock_exam';
export const MOCK_SCOPE = Object.freeze({ bigOrder: 0, midOrder: 0, subKey: 'A', subIndex: 0 });

const SECTION_ORDER = Object.freeze(['common', ...ELECTIVES, ...LEGACY_TYPES]);
const ELECTIVE_ORDER = Object.freeze(['', ...ELECTIVES, ...LEGACY_TYPES]);
const COURSE_KEYS = Object.freeze({ probstats: 'H-probstats', calculus: 'H-calculus', geometry: 'H-geometry' });
const PB_SOURCE_VERSION = 'mock_exam_pdf_v1';
const TERMINAL_JOB = new Set(['completed', 'review_required', 'failed', 'cancelled']);
const WHOLE_PAGE_REGION = Object.freeze([0, 0, 1000, 1000]);
const DEFAULT_BUCKET = 'problem-documents';

function compact(value) {
  return String(value ?? '').trim();
}

function chunk(list, size) {
  const out = [];
  for (let i = 0; i < list.length; i += size) out.push(list.slice(i, i + size));
  return out;
}

function validRegion(raw) {
  if (!Array.isArray(raw) || raw.length !== 4) return null;
  const v = raw.map((x) => Math.round(Number(x)));
  if (v.some((x) => !Number.isFinite(x) || x < 0 || x > 1000)) return null;
  if (v[2] - v[0] < 5 || v[3] - v[1] < 5) return null;
  return v;
}

function sameInts(a, b) {
  if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) return false;
  return a.every((x, i) => Number(x) === Number(b[i]));
}

function problemPapers(papers) {
  return (papers || [])
    .filter((p) => compact(p.kind) === 'problem')
    .sort((a, b) => ELECTIVE_ORDER.indexOf(compact(a.elective)) - ELECTIVE_ORDER.indexOf(compact(b.elective)));
}

/// 구간이 쓰는 문제지: 고3 선택과목은 그 과목 문제지, 그 밖(공통·고1·고2)은 첫 문제지.
export function mockSectionPaper(grade, section, papers) {
  const problems = problemPapers(papers);
  if (Number(grade) === 3 && section !== 'common') {
    return problems.find((p) => compact(p.elective) === section) || null;
  }
  return problems[0] || null;
}

/// 회차에 있어야 할 구간: 문제지가 있으면 공통, 고3 은 문제지가 올라온 선택과목, 그리고 이미 문서가 있는 구간.
/// 가형·나형('ga'·'na') 회차는 공통 구간 없이 문제지가 올라온 유형마다 구간 하나(1~30번)다(사장님 결정 2026-11-23).
export function mockExpectedSections(exam, papers, links) {
  const found = new Set();
  const problems = problemPapers(papers);
  if (Number(exam?.grade) === 3) {
    const electives = problems.map((p) => compact(p.elective)).filter((e) => ELECTIVES.includes(e));
    if (electives.length > 0) {
      found.add('common');
      for (const e of electives) found.add(e);
    }
    for (const p of problems) if (LEGACY_TYPES.includes(compact(p.elective))) found.add(compact(p.elective));
  } else if (problems.length > 0) {
    found.add('common');
  }
  for (const l of links || []) if (compact(l.pb_document_id)) found.add(compact(l.section));
  return SECTION_ORDER.filter((s) => found.has(s));
}

/// 추출 전에 미리 만드는 구간 문서. 추출 워커(mock_exam_worker ensureSectionDocument)가 같은 값으로 다시 채운다.
function sectionDocumentRow(exam, section, paper, nowIso) {
  const title = mockExamTitle(exam);
  const sectionLabel = SECTION_LABELS[section];
  const mockDetail = {
    exam_id: exam.id,
    org: exam.org,
    grade: exam.grade,
    exam_year: exam.exam_year,
    school_year: exam.school_year,
    exam_month: exam.exam_month,
    section,
  };
  return {
    academy_id: exam.academy_id,
    created_by: exam.created_by ?? null,
    source_sha256: '',
    source_size_bytes: 0,
    source_filename: `${title} · ${sectionLabel}`,
    source_storage_bucket: DEFAULT_BUCKET,
    source_storage_path: '',
    source_pdf_storage_bucket: compact(paper.storage_bucket) || DEFAULT_BUCKET,
    source_pdf_storage_path: compact(paper.storage_path),
    source_pdf_filename: compact(paper.file_name),
    source_pdf_sha256: compact(paper.sha256),
    source_pdf_size_bytes: Number(paper.size_bytes || 0),
    status: 'uploaded',
    curriculum_code: compact(exam.curriculum_code) || 'rev_2015',
    source_type_code: MOCK_EXAM_CATEGORY,
    school_level: 'high',
    grade_key: `H${exam.grade}`,
    grade_label: `고${exam.grade}`,
    course_key: COURSE_KEYS[section] || '',
    course_label: sectionLabel,
    exam_year: exam.exam_year,
    semester_label: '',
    exam_term_label: '',
    school_name: '',
    publisher_name: '',
    material_name: title,
    classification_detail: { mock_exam: mockDetail },
    meta: {
      source_classification: {
        private_material: false,
        school_past_exam: false,
        mock_past_exam: true,
        mock_exam: mockDetail,
      },
      // 검수에서 만든 문서: 문항은 구간을 확정할 때 공개한다.
      mock_review: { publish_on_confirm: true, created_at: nowIso },
      created_at: nowIso,
    },
  };
}

function bookName(title, section) {
  return `${title} · ${SECTION_LABELS[section] || section}`;
}

async function upsertBookRow(must, supa, academyId, documentId, name) {
  await must(
    supa.from('resource_files').upsert(
      {
        id: documentId,
        academy_id: academyId,
        name,
        category: MOCK_EXAM_CATEGORY,
        is_published: false,
        description: '모의고사 검수용',
      },
      { onConflict: 'id' },
    ),
    'mock_review_book_upsert_failed',
  );
}

/// 회차의 구간마다 검수 범위(구간 문서·책 행)를 만들고 돌려준다. 추출 전인 회차는 빈 구간 문서를 미리 만든다.
/// 추출이 돌고 있는 회차에 아직 문서가 없으면 만들지 않는다(추출 워커가 같은 문서를 만드는 중일 수 있다).
export async function prepareMockReviewIdentity({
  supa,
  academyId,
  examId,
  retryDelaysMs = DEFAULT_RETRY_DELAYS_MS,
  log = null,
}) {
  const must = (query, label, options = {}) => runQuery(query, label, { delaysMs: retryDelaysMs, ...options });
  const exam = await must(
    supa.from('mock_exams').select('*').eq('id', examId).eq('academy_id', academyId).maybeSingle(),
    'mock_review_exam_fetch_failed',
  );
  if (!exam) return { ok: false, status: 404, error: 'exam_not_found' };
  const papers = await must(
    supa
      .from('mock_exam_papers')
      .select('id,kind,elective,storage_bucket,storage_path,file_name,sha256,size_bytes')
      .eq('exam_id', examId),
    'mock_review_papers_fetch_failed',
  );
  if (problemPapers(papers).length === 0) return { ok: false, status: 400, error: 'problem_paper_missing' };
  const links = await must(
    supa.from('mock_exam_sections').select('section,pb_document_id,extract_job_id').eq('exam_id', examId),
    'mock_review_sections_fetch_failed',
  );
  const sections = mockExpectedSections(exam, papers, links);
  const documentOf = new Map();
  for (const l of links || []) if (compact(l.pb_document_id)) documentOf.set(compact(l.section), compact(l.pb_document_id));
  const linkedIds = sections.map((s) => documentOf.get(s)).filter(Boolean);
  const docs =
    linkedIds.length === 0
      ? []
      : await must(
          supa.from('pb_documents').select('id,meta').eq('academy_id', academyId).in('id', linkedIds),
          'mock_review_documents_fetch_failed',
        );
  const metaOf = new Map((docs || []).map((d) => [d.id, d.meta || {}]));
  const missing = sections.filter((s) => !metaOf.has(documentOf.get(s)));
  const status = compact(exam.status);
  if (missing.length > 0 && (status === 'queued' || status === 'running')) {
    return { ok: false, status: 409, error: 'exam_extracting' };
  }

  const title = mockExamTitle(exam);
  const nowIso = new Date().toISOString();
  for (const section of missing) {
    const paper = mockSectionPaper(exam.grade, section, papers);
    if (!paper) return { ok: false, status: 400, error: 'problem_paper_missing', section };
    const row = sectionDocumentRow(exam, section, paper, nowIso);
    const created = await must(
      supa.from('pb_documents').insert(row).select('id').single(),
      'mock_review_document_insert_failed',
      { retry: false },
    );
    await must(
      supa.from('mock_exam_sections').upsert(
        { exam_id: examId, section, academy_id: academyId, pb_document_id: created.id, extract_job_id: null },
        { onConflict: 'exam_id,section' },
      ),
      'mock_review_section_link_failed',
    );
    documentOf.set(section, created.id);
    metaOf.set(created.id, row.meta);
  }

  const documentIds = sections.map((s) => documentOf.get(s));
  for (const section of sections) {
    await upsertBookRow(must, supa, academyId, documentOf.get(section), bookName(title, section));
  }
  const questionRows = await must(
    supa.from('pb_questions').select('document_id,is_published').eq('academy_id', academyId).in('document_id', documentIds),
    'mock_review_questions_count_failed',
  );
  const counts = new Map();
  for (const q of questionRows || []) {
    const c = counts.get(q.document_id) || { total: 0, published: 0 };
    c.total += 1;
    if (q.is_published !== false) c.published += 1;
    counts.set(q.document_id, c);
  }
  const result = {
    ok: true,
    identityOnly: true,
    examId,
    title,
    grade: Number(exam.grade),
    examStatus: status,
    created: missing.length,
    sections: sections.map((section) => {
      const documentId = documentOf.get(section);
      const count = counts.get(documentId) || { total: 0, published: 0 };
      return {
        section,
        label: SECTION_LABELS[section] || section,
        documentId,
        bookId: documentId,
        bookName: bookName(title, section),
        gradeLabel: mockReviewCourseLabel({ grade: exam.grade, examMonth: exam.exam_month, section, examYear: exam.exam_year }),
        questionCount: count.total,
        publishedCount: count.published,
        publishOnConfirm: mockReviewPending(metaOf.get(documentId)),
      };
    }),
  };
  log?.('mock_review_identity', { examId, title, sections: result.sections.length, created: missing.length });
  return result;
}

/// 구간 문서가 추출할 범위: 이 구간의 문항 영역이 있는 문제지와 그 쪽 범위(mock_exam_worker 와 같은 계산).
export function mockSectionScope(examId, section, items, papers) {
  const withCrop = (items || []).filter(
    (it) => compact(it.section) === section && compact(it.paper_id) && Number(it.raw_page) > 0,
  );
  if (withCrop.length === 0) return null;
  const paper = (papers || []).find((p) => p.id === withCrop[0].paper_id);
  if (!paper) return null;
  const pages = withCrop.filter((it) => it.paper_id === paper.id).map((it) => Number(it.raw_page));
  return {
    exam_id: examId,
    section,
    paper_id: paper.id,
    raw_page_from: Math.min(...pages),
    raw_page_to: Math.max(...pages),
  };
}

/// 문항이 없는 구간의 추출을 건다. 반환: { reason, requested } 또는 걸 수 없으면 null.
///   어느 구간에도 문항이 없으면 회차 전체를, 문항 영역이 있는 구간이면 그 구간의 문제은행 추출만,
///   문항 영역도 없는 구간이면 뽑지 않은 구간들만 회차 워커에 맡긴다.
/// 문항이 있는 다른 구간은 다시 뽑지 않는다(다시 뽑으면 그 문항들이 새로 만들어진다).
async function startExtraction({ must, supa, academyId, exam, section, doc }) {
  const links = await must(
    supa.from('mock_exam_sections').select('section,pb_document_id').eq('exam_id', exam.id),
    'mock_review_sections_fetch_failed',
  );
  const documentIds = (links || []).map((l) => compact(l.pb_document_id)).filter(Boolean);
  const anyQuestion =
    documentIds.length === 0
      ? []
      : await must(
          supa.from('pb_questions').select('id').eq('academy_id', academyId).in('document_id', documentIds).limit(1),
          'mock_review_questions_probe_failed',
        );
  const queueExam = (progress) =>
    must(
      supa
        .from('mock_exams')
        .update({ status: 'queued', stage: '', last_error: '', progress })
        .eq('id', exam.id)
        .eq('status', compact(exam.status)),
      'mock_review_exam_queue_failed',
    );
  if ((anyQuestion || []).length === 0) {
    await queueExam({ request: 'all' });
    return { reason: 'exam_queued', requested: 'all' };
  }
  const papers = await must(
    supa.from('mock_exam_papers').select('id,kind,elective').eq('exam_id', exam.id),
    'mock_review_papers_fetch_failed',
  );
  const items = await must(
    supa.from('mock_exam_items').select('section,paper_id,raw_page').eq('exam_id', exam.id),
    'mock_review_items_fetch_failed',
  );
  const scope = mockSectionScope(exam.id, section, items, papers);
  if (!scope) {
    const cropped = new Set((items || []).filter((it) => Number(it.raw_page) > 0).map((it) => compact(it.section)));
    const sections = mockExpectedSections(exam, papers, links).filter((s) => !cropped.has(s));
    if (!sections.includes(section)) return null;
    await queueExam({ request: 'sections', sections });
    return { reason: 'exam_queued', requested: 'sections' };
  }
  await must(
    supa
      .from('pb_documents')
      .update({
        status: 'extract_queued',
        meta: { ...(doc.meta || {}), extract_mode: 'mock_exam_pdf', mock_scope: scope },
        updated_at: new Date().toISOString(),
      })
      .eq('id', doc.id)
      .eq('academy_id', academyId),
    'mock_review_document_queue_failed',
  );
  const created = await must(
    supa
      .from('pb_extract_jobs')
      .insert({
        academy_id: academyId,
        document_id: doc.id,
        created_by: exam.created_by ?? null,
        status: 'queued',
        source_version: PB_SOURCE_VERSION,
        result_summary: { engine: 'vlm_pdf_only', mock_scope: scope },
      })
      .select('id')
      .single(),
    'mock_review_job_insert_failed',
    { retry: false },
  );
  await must(
    supa.from('mock_exam_sections').update({ extract_job_id: created.id }).eq('exam_id', exam.id).eq('section', section),
    'mock_review_section_job_failed',
  );
  return { reason: 'extract_queued', requested: 'section' };
}

/// 해설지의 그 자리에 그 번호가 적혀 있는가(글자 층으로 본다).
function numberAt(evidence, page, region, number) {
  if (evidence?.hasText !== true || typeof evidence.lines !== 'function') return false;
  const area = [
    Math.max(0, region[0] - 4),
    Math.max(0, region[1] - 6),
    Math.min(1000, region[2] + 4),
    Math.min(1000, region[3] + 14),
  ];
  const re = new RegExp(`^\\D{0,2}0*${Number(number)}(?:\\D|$)`);
  return (evidence.lines(page, area) || []).some((l) => re.test(String(l.text).replace(/\s+/g, '')));
}

function answerSeedFor(question, item) {
  const seed = examAnswerSeed(question);
  if (seed) return seed;
  const kind = compact(item?.answer_kind);
  const text = compact(item?.answer_text);
  if (text && (kind === 'objective' || kind === 'subjective')) return { answer_kind: kind, answer_text: text };
  return null;
}

function sameSolutionRef(cur, row) {
  if (compact(cur.source_kind) !== row.source_kind) return false;
  if (Number(cur.raw_page) !== Number(row.raw_page)) return false;
  if (!sameInts(cur.number_region_1k, row.number_region_1k)) return false;
  if (row.content_region_1k == null ? cur.content_region_1k != null : !sameInts(cur.content_region_1k, row.content_region_1k)) {
    return false;
  }
  return JSON.stringify(cur.continuation_regions ?? null) === JSON.stringify(row.continuation_regions ?? null);
}

/// 구간의 해설지: 이 구간 풀이가 가장 많이 들어 있는 해설지(같으면 앞 선택과목 것). 없으면 null.
function sectionSolutionPaper(papers, sectionItems) {
  const solutionPapers = new Map(
    (papers || []).filter((p) => compact(p.kind) === 'solution' && compact(p.storage_path)).map((p) => [p.id, p]),
  );
  const votes = new Map();
  for (const it of sectionItems) {
    const id = compact(it.solution_paper_id);
    if (solutionPapers.has(id) && Number(it.solution_raw_page) > 0) votes.set(id, (votes.get(id) || 0) + 1);
  }
  const electiveRank = (id) => ELECTIVE_ORDER.indexOf(compact(solutionPapers.get(id)?.elective));
  const id = [...votes.entries()].sort((a, b) => b[1] - a[1] || electiveRank(a[0]) - electiveRank(b[0]))[0]?.[0] || '';
  return solutionPapers.get(id) || null;
}

/// 구간 문항([numbers])의 해설 위치를 해설지에서 계산한다: 번호 자리 + 첫 영역 + 다음 단·쪽으로 이어진 영역.
/// 읽기만 한다. 반환: planned(번호 → 조각), solutionReanchored, solutionUnchecked
async function planSectionSolutions({ solutionPaper, allItems, section, numbers, loadPaperPdf, readEvidence, retryDelaysMs }) {
  const planned = new Map();
  const solutionReanchored = [];
  const solutionUnchecked = [];
  if (!solutionPaper) return { planned, solutionReanchored, solutionUnchecked };
  const pdfBuffer = await runStep(() => loadPaperPdf(solutionPaper), retryDelaysMs);
  const evidence = await readEvidence(pdfBuffer);
  const blocks = [];
  for (const it of allItems || []) {
    const page = Number(it.solution_raw_page);
    const numberRegion = solutionRegionOf(it.solution_number_region_1k);
    if (!(page > 0) || !numberRegion) continue;
    const own = compact(it.section) === section;
    if (compact(it.solution_paper_id) !== solutionPaper.id) {
      // 다른 해설지에서 찾은 풀이: 이 해설지의 같은 자리에 같은 번호가 적혀 있을 때만 그 자리를 쓴다.
      if (!own || !numberAt(evidence, page, numberRegion, it.problem_number)) continue;
      solutionReanchored.push(String(it.problem_number));
    }
    blocks.push({
      key: `${compact(it.section)}|${it.problem_number}`,
      section: compact(it.section),
      page,
      numberRegion,
      contentRegion: it.solution_content_region_1k,
      manual: compact(it.solution_source) === 'manual',
    });
  }
  const plan = planSolutionSegments({ blocks, evidence });
  for (const number of numbers) {
    const segment = plan.segments.get(`${section}|${number}`);
    if (!segment) continue;
    planned.set(number, segment);
    if (segment.unchecked) solutionUnchecked.push(number);
  }
  return { planned, solutionReanchored, solutionUnchecked };
}

/// 계산한 해설 조각([segment], 없으면 null)을 textbook_problem_solution_refs 행으로 바꾼다.
function solutionRefRow({ cropId, academyId, segment, hasSolutionPaper, nowIso }) {
  if (segment) {
    return {
      crop_id: cropId,
      academy_id: academyId,
      raw_page: segment.rawPage,
      display_page: segment.rawPage,
      number_region_1k: segment.numberRegion,
      content_region_1k: segment.contentRegion,
      // 빈 배열 = 이어진 부분이 없다고 계산했다(null 은 계산하지 않음: 교재).
      continuation_regions: segment.continuations.map((c) => ({ raw_page: c.rawPage, region_1k: c.region1k })),
      source_kind: 'sol',
      extracted_at: nowIso,
      edited_at: null,
    };
  }
  return {
    crop_id: cropId,
    academy_id: academyId,
    raw_page: 0,
    display_page: null,
    number_region_1k: [0, 0, 0, 0],
    content_region_1k: null,
    continuation_regions: null,
    // 해설지가 있는데 이 문항의 풀이 자리를 못 찾았다: '해설 없음'(none)으로 넘기지 않는다.
    // 쪽이 0 인 'sol' 행은 검수에서 "해설 위치 없음"으로 막힌다(준비됨이 되지 않는다).
    // 해설지가 아예 없는 시험만 none 이다.
    source_kind: hasSolutionPaper ? 'sol' : 'none',
    // 한 번에 여러 행을 보낼 때 빠진 값은 null 로 들어간다. extracted_at 은 null 을 받지 않는다.
    extracted_at: nowIso,
    edited_at: null,
  };
}

/// 구간의 해설 위치를 지금 규칙으로 다시 계산해, 저장된 위치와 달라지는 문항만 돌려준다. **아무것도 쓰지 않는다.**
/// 확정된 구간에도 쓸 수 있다(prepareMockReview 는 크롭·정답·공개 상태까지 다시 쓰므로 확정 구간에 돌리지 않는다).
/// 사람이 고친 위치(edited_at)는 prepare 와 같이 비교하지 않고 solutionProtected 로 센다.
/// 반환: { ok, …, solutionCount, solutionProtected, changes: [{ number, cropId, before, after }] }
export async function previewMockSolutionRefs({
  supa,
  academyId,
  documentId,
  loadPaperPdf,
  readEvidence = readSolutionEvidence,
  retryDelaysMs = DEFAULT_RETRY_DELAYS_MS,
}) {
  const must = (query, label, options = {}) => runQuery(query, label, { delaysMs: retryDelaysMs, ...options });
  const link = await must(
    supa
      .from('mock_exam_sections')
      .select('exam_id,section,pb_document_id')
      .eq('academy_id', academyId)
      .eq('pb_document_id', documentId)
      .maybeSingle(),
    'mock_review_section_fetch_failed',
  );
  if (!link) return { ok: false, status: 400, error: 'not_mock_section' };
  const section = compact(link.section);
  const exam = await must(
    supa.from('mock_exams').select('*').eq('id', link.exam_id).eq('academy_id', academyId).maybeSingle(),
    'mock_review_exam_fetch_failed',
  );
  if (!exam) return { ok: false, status: 404, error: 'exam_not_found' };
  const gradeLabel = mockReviewCourseLabel({ grade: exam.grade, examMonth: exam.exam_month, section, examYear: exam.exam_year });
  if (!gradeLabel) return { ok: false, status: 400, error: 'course_unresolved' };
  const questions = await must(
    supa
      .from('pb_questions')
      .select('question_uid,question_number,source_order')
      .eq('academy_id', academyId)
      .eq('document_id', documentId)
      .order('source_order', { ascending: true }),
    'mock_review_questions_fetch_failed',
  );
  const numbers = [];
  for (const q of questions || []) {
    const number = compact(q.question_number);
    if (number && compact(q.question_uid) && !numbers.includes(number)) numbers.push(number);
  }
  const papers = await must(
    supa.from('mock_exam_papers').select('id,kind,elective,storage_bucket,storage_path').eq('exam_id', exam.id),
    'mock_review_papers_fetch_failed',
  );
  const allItems = await must(
    supa
      .from('mock_exam_items')
      .select(
        'section,problem_number,solution_paper_id,solution_raw_page,solution_number_region_1k,solution_content_region_1k,solution_source',
      )
      .eq('exam_id', exam.id),
    'mock_review_items_fetch_failed',
  );
  const sectionItems = (allItems || []).filter((it) => compact(it.section) === section);
  const solutionPaper = sectionSolutionPaper(papers, sectionItems);
  const crops = await must(
    supa
      .from('textbook_problem_crops')
      .select('id,problem_number')
      .eq('academy_id', academyId)
      .eq('book_id', documentId)
      .eq('grade_label', gradeLabel)
      .eq('big_order', MOCK_SCOPE.bigOrder)
      .eq('mid_order', MOCK_SCOPE.midOrder)
      .eq('sub_key', MOCK_SCOPE.subKey)
      .eq('sub_index', MOCK_SCOPE.subIndex),
    'mock_review_crops_reload_failed',
  );
  const cropIdByNumber = new Map((crops || []).map((c) => [compact(c.problem_number), c.id]));
  const { planned } = await planSectionSolutions({
    solutionPaper,
    allItems,
    section,
    numbers,
    loadPaperPdf,
    readEvidence,
    retryDelaysMs,
  });
  const cropIds = Array.from(cropIdByNumber.values());
  const refRows = cropIds.length
    ? await must(
        supa
          .from('textbook_problem_solution_refs')
          .select('crop_id,raw_page,number_region_1k,content_region_1k,continuation_regions,source_kind,edited_at')
          .in('crop_id', cropIds),
        'mock_review_solution_refs_fetch_failed',
      )
    : [];
  const refOf = new Map((refRows || []).map((r) => [r.crop_id, r]));
  const shape = (r) => ({
    raw_page: Number(r.raw_page),
    number_region_1k: r.number_region_1k ?? null,
    content_region_1k: r.content_region_1k ?? null,
    continuation_regions: r.continuation_regions ?? null,
    source_kind: compact(r.source_kind),
  });
  const changes = [];
  let solutionProtected = 0;
  for (const number of numbers) {
    const cropId = cropIdByNumber.get(number);
    if (!cropId) continue;
    const cur = refOf.get(cropId);
    if (cur && compact(cur.edited_at)) {
      solutionProtected += 1;
      continue;
    }
    const row = solutionRefRow({
      cropId,
      academyId,
      segment: planned.get(number) || null,
      hasSolutionPaper: Boolean(solutionPaper),
      nowIso: '',
    });
    if (cur && sameSolutionRef(cur, row)) continue;
    changes.push({ number, cropId, before: cur ? shape(cur) : null, after: shape(row) });
  }
  return {
    ok: true,
    preview: true,
    examId: exam.id,
    section,
    bookId: documentId,
    gradeLabel,
    title: mockExamTitle(exam),
    label: SECTION_LABELS[section] || section,
    cropCount: cropIds.length,
    solutionCount: planned.size,
    solutionProtected,
    changes,
  };
}

/// 구간 문서 하나를 검수 테이블에 올린다.
///   loadPaperPdf(paper) → Buffer(시험지·해설지 PDF), readEvidence(buffer) → solution_evidence 의 근거
///   readChoiceWords(buffer) → 시험지의 쪽별 낱말 상자(선지 번호 자리를 읽는다)
///   allowExtract: 문항이 없으면 추출을 건다(검수 실행기가 한 번의 실행에서 처음 부를 때만 켠다).
///   refreshAnswers: 방금 다시 추출한 문서라 문제은행 정답을 채점 정답에 다시 옮긴다(사람이 고친 정답은 그대로).
/// 반환: 추출을 기다려야 하면 { ok: true, state: 'waiting', reason }, 올렸으면 { ok: true, state: 'ready', … }
export async function prepareMockReview({
  supa,
  academyId,
  documentId,
  loadPaperPdf,
  readEvidence = readSolutionEvidence,
  readChoiceWords = readChoicePages,
  allowExtract = false,
  refreshAnswers = false,
  retryDelaysMs = DEFAULT_RETRY_DELAYS_MS,
  log = null,
}) {
  const must = (query, label, options = {}) => runQuery(query, label, { delaysMs: retryDelaysMs, ...options });
  const link = await must(
    supa
      .from('mock_exam_sections')
      .select('exam_id,section,pb_document_id,extract_job_id')
      .eq('academy_id', academyId)
      .eq('pb_document_id', documentId)
      .maybeSingle(),
    'mock_review_section_fetch_failed',
  );
  if (!link) return { ok: false, status: 400, error: 'not_mock_section' };
  const section = compact(link.section);
  const exam = await must(
    supa.from('mock_exams').select('*').eq('id', link.exam_id).eq('academy_id', academyId).maybeSingle(),
    'mock_review_exam_fetch_failed',
  );
  if (!exam) return { ok: false, status: 404, error: 'exam_not_found' };
  const doc = await must(
    supa
      .from('pb_documents')
      .select('id,status,meta,source_pdf_storage_bucket,source_pdf_storage_path,source_pdf_size_bytes,source_pdf_sha256')
      .eq('id', documentId)
      .eq('academy_id', academyId)
      .maybeSingle(),
    'mock_review_document_fetch_failed',
  );
  if (!doc) return { ok: false, status: 404, error: 'document_not_found' };
  const gradeLabel = mockReviewCourseLabel({ grade: exam.grade, examMonth: exam.exam_month, section, examYear: exam.exam_year });
  if (!gradeLabel) return { ok: false, status: 400, error: 'course_unresolved' };
  const title = mockExamTitle(exam);
  const label = SECTION_LABELS[section] || section;
  const identity = { examId: exam.id, section, bookId: documentId, bookName: bookName(title, section), gradeLabel, title, label };
  const waiting = (reason, extra = {}) => ({ ok: true, state: 'waiting', reason, ...identity, ...extra });

  // 1) 추출이 끝났는가
  const examStatus = compact(exam.status);
  if (examStatus === 'queued' || examStatus === 'running') return waiting(`exam_${examStatus}`);
  const job = compact(link.extract_job_id)
    ? await must(
        supa.from('pb_extract_jobs').select('id,status,error_code,error_message').eq('id', link.extract_job_id).maybeSingle(),
        'mock_review_job_fetch_failed',
      )
    : null;
  const jobStatus = compact(job?.status);
  if (job && !TERMINAL_JOB.has(jobStatus)) return waiting(jobStatus === 'queued' ? 'extract_queued' : 'extracting');

  const questions = await must(
    supa
      .from('pb_questions')
      .select(
        'id,question_uid,question_number,source_order,choices,allow_objective,objective_answer_key,subjective_answer,is_published',
      )
      .eq('academy_id', academyId)
      .eq('document_id', documentId)
      .order('source_order', { ascending: true }),
    'mock_review_questions_fetch_failed',
  );
  const byNumber = new Map();
  for (const q of questions || []) {
    const number = compact(q.question_number);
    if (number && compact(q.question_uid) && !byNumber.has(number)) byNumber.set(number, q);
  }
  if (byNumber.size === 0) {
    if (allowExtract) {
      const started = await startExtraction({ must, supa, academyId, exam, section, doc });
      if (started) {
        log?.('mock_review_extract_requested', { documentId, examId: exam.id, section, ...started });
        return waiting(started.reason, { requested: started.requested });
      }
    }
    if (examStatus === 'failed') {
      return { ok: false, status: 409, error: 'exam_extract_failed', message: compact(exam.last_error) };
    }
    if (job && (jobStatus === 'failed' || jobStatus === 'cancelled')) {
      return {
        ok: false,
        status: 409,
        error: 'extract_failed',
        message: compact(job.error_message) || compact(job.error_code),
      };
    }
    if (job) return { ok: false, status: 409, error: 'no_questions' };
    return { ok: false, status: 409, error: allowExtract ? 'no_items' : 'needs_extract' };
  }

  const bodyPath = compact(doc.source_pdf_storage_path);
  if (!bodyPath) return { ok: false, status: 400, error: 'pdf_source_required' };
  const papers = await must(
    supa
      .from('mock_exam_papers')
      .select('id,kind,elective,storage_bucket,storage_path,file_name,sha256,size_bytes')
      .eq('exam_id', exam.id),
    'mock_review_papers_fetch_failed',
  );
  const allItems = await must(
    supa
      .from('mock_exam_items')
      .select(
        'section,problem_number,paper_id,raw_page,item_region_1k,choice_number_region_1k,answer_kind,answer_text,solution_paper_id,solution_raw_page,solution_number_region_1k,solution_content_region_1k,solution_source',
      )
      .eq('exam_id', exam.id),
    'mock_review_items_fetch_failed',
  );
  const sectionItems = new Map();
  for (const it of allItems || []) {
    if (compact(it.section) === section) sectionItems.set(String(it.problem_number), it);
  }
  const bodyPaper = (papers || []).find((p) => compact(p.kind) === 'problem' && compact(p.storage_path) === bodyPath) || null;
  const solutionPaper = sectionSolutionPaper(papers, sectionItems.values());

  // 2) 책 행(학습앱·교재 목록에는 보이지 않는다)
  await upsertBookRow(must, supa, academyId, documentId, identity.bookName);

  // 3) 시험지·해설지 PDF 연결(검수 화면이 PDF 를 받는 경로)
  const nowIso = new Date().toISOString();
  const wantedLinks = [
    {
      kind: 'body',
      bucket: compact(doc.source_pdf_storage_bucket) || DEFAULT_BUCKET,
      path: bodyPath,
      size: Number(doc.source_pdf_size_bytes) || null,
      hash: compact(doc.source_pdf_sha256) || null,
    },
  ];
  if (solutionPaper) {
    wantedLinks.push({
      kind: 'sol',
      bucket: compact(solutionPaper.storage_bucket) || DEFAULT_BUCKET,
      path: compact(solutionPaper.storage_path),
      size: Number(solutionPaper.size_bytes) || null,
      hash: compact(solutionPaper.sha256) || null,
    });
  }
  // 연결 행에는 겹침을 막는 키가 없다. 넣다가 끊기면 다시 읽어 보고 없을 때만 넣는다.
  await runStep(async () => {
    const rows = await must(
      supa.from('resource_file_links').select('id,grade,storage_key').eq('academy_id', academyId).eq('file_id', documentId),
      'mock_review_link_fetch_failed',
    );
    for (const w of wantedLinks) {
      const composite = `${gradeLabel}#${w.kind}`;
      const values = {
        academy_id: academyId,
        file_id: documentId,
        grade: composite,
        url: '',
        storage_driver: 'supabase',
        storage_bucket: w.bucket,
        storage_key: w.path,
        migration_status: 'migrated',
        file_size_bytes: w.size,
        content_hash: w.hash,
        uploaded_at: nowIso,
      };
      const same = (rows || []).find((l) => compact(l.grade) === composite);
      if (!same) {
        await must(supa.from('resource_file_links').insert(values), 'mock_review_link_insert_failed', { retry: false });
      } else if (compact(same.storage_key) !== w.path) {
        await must(supa.from('resource_file_links').update(values).eq('id', same.id), 'mock_review_link_update_failed');
      }
    }
  }, retryDelaysMs);

  // 4) 문항 크롭(좌표)
  const existingCrops = await must(
    supa
      .from('textbook_problem_crops')
      .select('id,problem_number,raw_page,item_region_1k,pb_question_uid,region_source,grade_label,big_order,mid_order,sub_key,sub_index')
      .eq('academy_id', academyId)
      .eq('book_id', documentId),
    'mock_review_crops_fetch_failed',
  );
  const inScope = (c) =>
    compact(c.grade_label) === gradeLabel &&
    Number(c.big_order) === MOCK_SCOPE.bigOrder &&
    Number(c.mid_order) === MOCK_SCOPE.midOrder &&
    compact(c.sub_key) === MOCK_SCOPE.subKey &&
    Number(c.sub_index || 0) === MOCK_SCOPE.subIndex;
  const cropByNumber = new Map();
  const staleCropIds = [];
  for (const c of existingCrops || []) {
    const number = compact(c.problem_number);
    if (inScope(c) && byNumber.has(number) && !cropByNumber.has(number)) cropByNumber.set(number, c);
    else staleCropIds.push(c.id);
  }
  const cropRows = [];
  const recreatedCropIds = [];
  const pageFallbacks = [];
  // 번호 → 검수가 원본으로 쓰는 쪽·영역(쪽 전체로 대신한 문항은 넣지 않는다).
  const itemOrigins = new Map();
  for (const [number, q] of byNumber) {
    const crop = cropByNumber.get(number);
    const item = sectionItems.get(number);
    const cropRegion = validRegion(crop?.item_region_1k);
    const cropPage = Number(crop?.raw_page) > 0 ? Number(crop.raw_page) : 0;
    const manual = compact(crop?.region_source) === 'manual';
    const itemRegion = validRegion(item?.item_region_1k);
    const itemPage = Number(item?.raw_page) > 0 ? Number(item.raw_page) : 0;
    // 구간 문서의 문제지가 아닌 문제지에서 찾은 영역은 쓰지 않는다(쪽 번호가 다른 PDF 의 것이다).
    const itemOnBody = Boolean(item) && (!bodyPaper || compact(item.paper_id) === bodyPaper.id);
    let rawPage;
    let region;
    if (manual && cropRegion && cropPage > 0) {
      rawPage = cropPage;
      region = cropRegion;
    } else if (itemRegion && itemPage > 0 && itemOnBody) {
      rawPage = itemPage;
      region = itemRegion;
    } else if (cropRegion && cropPage > 0) {
      rawPage = cropPage;
      region = cropRegion;
    } else {
      // 영역이 없다: 쪽 전체를 원본으로 쓴다(검수는 돌고, 다음 준비 때 다시 맞춘다).
      rawPage = itemOnBody && itemPage > 0 ? itemPage : 1;
      region = [...WHOLE_PAGE_REGION];
      pageFallbacks.push(number);
    }
    if (!pageFallbacks.includes(number)) itemOrigins.set(number, { rawPage, region });
    // 문항 uid 가 바뀌었다 = 문항을 새로 만들었다. 예전 문항의 검수 기록은 맞지 않는다.
    const recreated =
      Boolean(crop) && compact(crop.pb_question_uid) !== '' && compact(crop.pb_question_uid) !== compact(q.question_uid);
    if (recreated) recreatedCropIds.push(crop.id);
    const unchanged =
      Boolean(crop) &&
      compact(crop.pb_question_uid) === compact(q.question_uid) &&
      cropPage === rawPage &&
      sameInts(crop.item_region_1k, region);
    if (unchanged) continue;
    const num = number.replace(/[^0-9A-Za-z가-힣_-]/g, '_') || 'item';
    cropRows.push({
      academy_id: academyId,
      book_id: documentId,
      grade_label: gradeLabel,
      big_order: MOCK_SCOPE.bigOrder,
      mid_order: MOCK_SCOPE.midOrder,
      sub_key: MOCK_SCOPE.subKey,
      sub_index: MOCK_SCOPE.subIndex,
      big_name: title,
      mid_name: label,
      raw_page: rawPage,
      display_page: rawPage,
      problem_number: number,
      label: '',
      is_set_header: false,
      item_region_1k: region,
      storage_key: `academies/${academyId}/books/${documentId}/exam/0_0_A/${num}.png`,
      pb_question_uid: q.question_uid,
      category_code: 'A',
      region_source: manual ? 'manual' : 'vlm',
    });
  }
  for (const rows of chunk(cropRows, 100)) {
    await must(
      supa.from('textbook_problem_crops').upsert(rows, {
        onConflict: 'academy_id,book_id,grade_label,big_order,mid_order,sub_key,sub_index,problem_number',
      }),
      'mock_review_crops_upsert_failed',
    );
  }
  // 다시 추출해 없어진 번호의 크롭은 지운다(검수 기록도 함께 지워진다).
  for (const ids of chunk(staleCropIds, 100)) {
    await must(supa.from('textbook_problem_crops').delete().in('id', ids), 'mock_review_crops_delete_failed');
  }
  // 문항을 새로 만든 크롭은 검수 기록(판정·지적·반영 대기)을 비워 처음부터 다시 검수하게 한다.
  for (const ids of chunk(recreatedCropIds, 100)) {
    await must(supa.from('textbook_review_findings').delete().in('crop_id', ids), 'mock_review_findings_reset_failed');
    await must(supa.from('textbook_problem_analyses').delete().in('crop_id', ids), 'mock_review_analyses_reset_failed');
  }

  // 4-1) 선지 번호(①~⑤) 자리: 그림이 선지 아래에 있는 문항을 가려내는 근거(정합성 점검이 그림 자리와 견준다).
  //   null = 아직 읽지 않음, [] = 읽었지만 번호 글자를 찾지 못함, [ymin, xmin, ymax, xmax] = 번호 글자 영역.
  //   적어 둔 영역이 지금의 문항 영역 안에 있으면 그대로 둔다. 시험지 PDF 는 읽을 문항이 있을 때만 받는다.
  const choiceTargets = [];
  for (const [number, q] of byNumber) {
    const origin = itemOrigins.get(number);
    const item = sectionItems.get(number);
    if (!origin || !item || !Array.isArray(q.choices) || q.choices.length === 0) continue;
    const stored = item.choice_number_region_1k;
    const storedRegion = validChoiceRegion(stored);
    const fresh = storedRegion ? regionInside(storedRegion, origin.region) : Array.isArray(stored) && stored.length === 0;
    if (!fresh) choiceTargets.push({ number, origin, stored });
  }
  let choiceRegionsWritten = 0;
  let choiceRegionsUnread = false;
  const choiceRegionsMissing = [];
  if (choiceTargets.length > 0 && bodyPaper) {
    const pdfBuffer = await runStep(() => loadPaperPdf(bodyPaper), retryDelaysMs);
    const wordPages = await readChoiceWords(pdfBuffer);
    if (!Array.isArray(wordPages) || wordPages.length === 0) {
      // 쪽을 하나도 읽지 못했다(도구 오류일 수 있다). 적지 않고 다음 준비 때 다시 읽는다.
      choiceRegionsUnread = true;
    } else {
      for (const t of choiceTargets) {
        const wordPage = wordPages.find((p) => Number(p.page) === t.origin.rawPage);
        const found = wordPage ? choiceNumberRegion(wordPage, t.origin.region) : null;
        if (!found) choiceRegionsMissing.push(t.number);
        const next = found || [];
        if (Array.isArray(t.stored) && sameInts(t.stored, next)) continue;
        await must(
          supa
            .from('mock_exam_items')
            .update({ choice_number_region_1k: next })
            .eq('exam_id', exam.id)
            .eq('section', section)
            .eq('problem_number', Number(t.number)),
          'mock_review_choice_region_update_failed',
        );
        choiceRegionsWritten += 1;
      }
    }
  }

  const crops = await must(
    supa
      .from('textbook_problem_crops')
      .select('id,problem_number')
      .eq('academy_id', academyId)
      .eq('book_id', documentId)
      .eq('grade_label', gradeLabel)
      .eq('big_order', MOCK_SCOPE.bigOrder)
      .eq('mid_order', MOCK_SCOPE.midOrder)
      .eq('sub_key', MOCK_SCOPE.subKey)
      .eq('sub_index', MOCK_SCOPE.subIndex),
    'mock_review_crops_reload_failed',
  );
  const cropIdByNumber = new Map((crops || []).map((c) => [compact(c.problem_number), c.id]));
  const cropIds = Array.from(cropIdByNumber.values());

  // 5) 문제은행 문항 연결
  const linkRows = await must(
    supa.from('textbook_crop_question_links').select('crop_id,pb_question_id').in('crop_id', cropIds),
    'mock_review_links_fetch_failed',
  );
  const linkedTo = new Map((linkRows || []).map((l) => [l.crop_id, l.pb_question_id]));
  const newLinks = [];
  for (const [number, q] of byNumber) {
    const cropId = cropIdByNumber.get(number);
    if (cropId && linkedTo.get(cropId) !== q.id) {
      newLinks.push({ crop_id: cropId, academy_id: academyId, pb_question_id: q.id, source: 'extract', confidence: 1 });
    }
  }
  for (const rows of chunk(newLinks, 100)) {
    await must(
      supa.from('textbook_crop_question_links').upsert(rows, { onConflict: 'crop_id' }),
      'mock_review_links_upsert_failed',
    );
  }

  // 6) 채점 정답
  const answerRows = await must(
    supa.from('textbook_problem_answers').select('crop_id,answer_kind,answer_text,answer_source').in('crop_id', cropIds),
    'mock_review_answers_fetch_failed',
  );
  const answerOf = new Map((answerRows || []).map((a) => [a.crop_id, a]));
  const recreatedCrops = new Set(recreatedCropIds);
  const answerInserts = [];
  const answerUpdates = [];
  const missingAnswers = [];
  for (const [number, q] of byNumber) {
    const cropId = cropIdByNumber.get(number);
    if (!cropId) continue;
    const seed = answerSeedFor(q, sectionItems.get(number));
    const cur = answerOf.get(cropId);
    if (!cur) {
      if (!seed) {
        missingAnswers.push(number);
        continue;
      }
      answerInserts.push({ crop_id: cropId, academy_id: academyId, ...seed, answer_source: 'vlm' });
    } else if (
      // 새로 만든 문항은 요청이 없어도 문제은행 정답을 다시 옮긴다(사람이 고친 정답은 그대로).
      (refreshAnswers || recreatedCrops.has(cropId)) &&
      seed &&
      compact(cur.answer_source) !== 'manual' &&
      (compact(cur.answer_kind) !== seed.answer_kind || compact(cur.answer_text) !== seed.answer_text)
    ) {
      answerUpdates.push({ cropId, seed });
    }
  }
  // 이미 있는 정답 행은 건드리지 않는다(그 사이 사람이 넣은 정답 포함). 다시 보내도 결과가 같다.
  for (const rows of chunk(answerInserts, 100)) {
    await must(
      supa.from('textbook_problem_answers').upsert(rows, { onConflict: 'crop_id', ignoreDuplicates: true }),
      'mock_review_answers_insert_failed',
    );
  }
  for (const u of answerUpdates) {
    await must(
      supa.from('textbook_problem_answers').update(u.seed).eq('crop_id', u.cropId).neq('answer_source', 'manual'),
      'mock_review_answers_update_failed',
    );
  }

  // 7) 해설 위치: 번호 자리 + 첫 영역 + 다음 단·쪽으로 이어진 영역
  const { planned, solutionReanchored, solutionUnchecked } = await planSectionSolutions({
    solutionPaper,
    allItems,
    section,
    numbers: byNumber.keys(),
    loadPaperPdf,
    readEvidence,
    retryDelaysMs,
  });
  const refRows = await must(
    supa
      .from('textbook_problem_solution_refs')
      .select('crop_id,raw_page,number_region_1k,content_region_1k,continuation_regions,source_kind,edited_at')
      .in('crop_id', cropIds),
    'mock_review_solution_refs_fetch_failed',
  );
  const refOf = new Map((refRows || []).map((r) => [r.crop_id, r]));
  const refWrites = [];
  const solutionMissing = [];
  let solutionContinued = 0;
  let solutionProtected = 0;
  for (const number of byNumber.keys()) {
    const cropId = cropIdByNumber.get(number);
    if (!cropId) continue;
    const segment = planned.get(number);
    const cur = refOf.get(cropId);
    // 검수 화면에서 사람이 고친 해설 위치(edited_at)는 그대로 둔다(DB 트리거도 막는다).
    // 모의고사 화면에서 손으로 잡은 위치는 계산할 때 그대로 쓰지만, 검수 화면의 수정으로 치지는 않는다.
    if (cur && compact(cur.edited_at)) {
      solutionProtected += 1;
      continue;
    }
    if (!segment) solutionMissing.push(number);
    else if (segment.continuations.length > 0) solutionContinued += 1;
    const row = solutionRefRow({ cropId, academyId, segment, hasSolutionPaper: Boolean(solutionPaper), nowIso });
    if (cur && sameSolutionRef(cur, row)) continue;
    refWrites.push(row);
  }
  for (const rows of chunk(refWrites, 100)) {
    await must(
      supa.from('textbook_problem_solution_refs').upsert(rows, { onConflict: 'crop_id' }),
      'mock_review_solution_refs_upsert_failed',
    );
  }

  // 8) 확정할 때 공개하는 문서: 그 전에는 문항을 학생에게 보이지 않는다.
  const publishOnConfirm = mockReviewPending(doc.meta);
  let unpublished = 0;
  if (publishOnConfirm) {
    const live = (questions || []).filter((q) => q.is_published !== false).map((q) => q.id);
    for (const ids of chunk(live, 100)) {
      await must(
        supa.from('pb_questions').update({ is_published: false }).eq('academy_id', academyId).in('id', ids),
        'mock_review_unpublish_failed',
      );
    }
    unpublished = live.length;
  }

  const result = {
    ok: true,
    state: 'ready',
    ...identity,
    questionCount: byNumber.size,
    cropCount: cropIds.length,
    cropsWritten: cropRows.length,
    cropsRemoved: staleCropIds.length,
    reviewsReset: recreatedCropIds.length,
    pageFallbacks,
    answersSeeded: answerInserts.length,
    answersRefreshed: answerUpdates.length,
    missingAnswers,
    solutionCount: planned.size,
    solutionMissing,
    solutionContinued,
    solutionUnchecked,
    solutionReanchored,
    solutionProtected,
    solutionsWritten: refWrites.length,
    choiceRegionsWritten,
    choiceRegionsMissing,
    choiceRegionsUnread,
    publishOnConfirm,
    unpublished,
  };
  log?.('mock_review_prepared', { documentId, ...result });
  return result;
}

/// 확정한 구간을 공개한다: 문항을 공개하고, 공개한 때를 구간 문서에 적고, 학습앱 모의고사 프리셋을 맞춘다.
/// 검수에서 만든 구간 문서만 해당한다. 처음부터 공개돼 있던 구간이나 이미 공개한 구간은 그대로 두고 published: false.
export async function publishMockReview({
  supa,
  academyId,
  documentId,
  syncPresets = syncMockExamPresetsForExam,
  retryDelaysMs = DEFAULT_RETRY_DELAYS_MS,
  log = null,
}) {
  const must = (query, label, options = {}) => runQuery(query, label, { delaysMs: retryDelaysMs, ...options });
  const link = await must(
    supa
      .from('mock_exam_sections')
      .select('exam_id,section')
      .eq('academy_id', academyId)
      .eq('pb_document_id', documentId)
      .maybeSingle(),
    'mock_review_section_fetch_failed',
  );
  if (!link) return { ok: false, status: 400, error: 'not_mock_section' };
  const doc = await must(
    supa.from('pb_documents').select('id,meta').eq('id', documentId).eq('academy_id', academyId).maybeSingle(),
    'mock_review_document_fetch_failed',
  );
  if (!doc) return { ok: false, status: 404, error: 'document_not_found' };
  // 프리셋은 공개된 구간만으로 만든다(고3 은 공통과 그 선택과목이 모두 공개돼야 그 과목 프리셋이 생긴다).
  const syncNow = async () => {
    try {
      return { presetsSynced: Number((await syncPresets(supa, link.exam_id))?.synced) || 0 };
    } catch (err) {
      return { presetsSynced: 0, presetError: compact(err?.message || err) || 'preset_sync_failed' };
    }
  };
  if (!mockReviewPending(doc.meta)) {
    const base = { ok: true, published: false, examId: link.exam_id, section: compact(link.section) };
    // 처음부터 공개돼 있던 구간은 그대로 둔다. 검수에서 이미 공개한 구간은 프리셋만 다시 맞춘다(지난번에 실패했을 수 있다).
    if (!compact(doc.meta?.mock_review?.published_at)) return base;
    return { ...base, ...(await syncNow()) };
  }

  const nowIso = new Date().toISOString();
  await must(
    supa.from('pb_questions').update({ is_published: true }).eq('academy_id', academyId).eq('document_id', documentId),
    'mock_review_publish_failed',
  );
  await must(
    supa
      .from('pb_documents')
      .update({
        meta: { ...doc.meta, mock_review: { ...doc.meta.mock_review, published_at: nowIso } },
        updated_at: nowIso,
      })
      .eq('id', documentId)
      .eq('academy_id', academyId),
    'mock_review_publish_mark_failed',
  );
  const result = {
    ok: true,
    published: true,
    examId: link.exam_id,
    section: compact(link.section),
    ...(await syncNow()),
  };
  log?.('mock_review_published', { documentId, ...result });
  return result;
}
