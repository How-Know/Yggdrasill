// 모의고사 기출 추출 워커.
//
// status='queued' 인 mock_exams 를 하나씩 집어 다음을 차례로 한다.
//   1) 문제지 지면마다 문항 번호·영역(크롭)을 판독해 mock_exam_items 에 쓴다.
//   2) 해설 지면마다 빠른 정답 상자·구간 머리·문항별 해설 시작점을 판독해
//      정답과 해설 위치를 채운다. 사람이 고친 값(manual)은 건드리지 않는다.
//   3) 구간(공통·선택과목)마다 pb_documents + pb_extract_jobs 를 만들어
//      문제은행 추출 워커에 넘긴다.
// docs/architecture/mock-exam.md 참고.

import 'dotenv/config';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFile as execFileCb } from 'node:child_process';
import { promisify } from 'node:util';
import { pathToFileURL } from 'node:url';
import { createClient } from '@supabase/supabase-js';
import { PDFDocument } from 'pdf-lib';
import { callGeminiImageJson } from './mock_exam/gemini_image.js';
import {
  ELECTIVES,
  SECTION_LABELS,
  assignProblemItems,
  assignSolutionSections,
  buildProblemPagePrompt,
  buildSolutionPagePrompt,
  electiveStartPageFromText,
  expectedNumbers,
  normalizeProblemPage,
  normalizeSolutionPage,
} from './mock_exam/mock_pages.js';
import { logVlmUsage } from './textbook/vlm_usage_log.js';

const execFileAsync = promisify(execFileCb);

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const GEMINI_API_KEY = String(
  process.env.GEMINI_API_KEY || process.env.GOOGLE_API_KEY || '',
).trim();
const MODEL = String(
  process.env.MOCK_EXAM_VLM_MODEL ||
    process.env.TEXTBOOK_VLM_MODEL ||
    process.env.PB_VLM_MODEL ||
    'gemini-3.1-pro-preview',
).trim();
const INTERVAL_MS = Math.max(
  2000,
  Number.parseInt(process.env.MOCK_EXAM_WORKER_INTERVAL_MS || '5000', 10) || 5000,
);
const STALE_MS = Math.max(
  5 * 60_000,
  Number.parseInt(process.env.MOCK_EXAM_STALE_MS || '1800000', 10) || 1800000,
);
const PAGE_CONCURRENCY = Math.max(
  1,
  Number.parseInt(process.env.MOCK_EXAM_PAGE_CONCURRENCY || '3', 10) || 3,
);
const RENDER_DPI = Number.parseInt(process.env.MOCK_EXAM_RENDER_DPI || '130', 10) || 130;
const PROCESS_ONCE = process.argv.includes('--once');
const PB_SOURCE_VERSION = 'mock_exam_pdf_v1';
const ELECTIVE_ORDER = ['', ...ELECTIVES];
const ORG_LABELS = { edu: '교육청', kice: '평가원', csat: '수능' };
const COURSE_KEYS = {
  probstats: 'H-probstats',
  calculus: 'H-calculus',
  geometry: 'H-geometry',
};

let supa = null;

function compact(v) {
  return String(v ?? '').trim();
}

function log(event, payload = {}) {
  console.log(`[mock-exam-worker] ${event}`, JSON.stringify(payload));
}

export function mockExamTitle(exam) {
  return `${exam.exam_year} 고${exam.grade} ${exam.exam_month}월 ${ORG_LABELS[exam.org] || ''}`.trim();
}

async function mapLimit(items, limit, fn) {
  const out = new Array(items.length);
  let next = 0;
  const run = async () => {
    while (next < items.length) {
      const i = next;
      next += 1;
      out[i] = await fn(items[i], i);
    }
  };
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, run));
  return out;
}

async function withTempPdf(buffer, fn) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mock-exam-'));
  const pdfPath = path.join(dir, 'source.pdf');
  fs.writeFileSync(pdfPath, buffer);
  try {
    return await fn(pdfPath, dir);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

async function renderPage(pdfPath, dir, page) {
  const outBase = path.join(dir, `p${page}`);
  await execFileAsync(
    'pdftoppm',
    ['-png', '-f', String(page), '-l', String(page), '-singlefile', '-r', String(RENDER_DPI), pdfPath, outBase],
    { timeout: 60_000, windowsHide: true },
  );
  return fs.readFileSync(`${outBase}.png`);
}

async function pageTexts(pdfPath) {
  try {
    const { stdout } = await execFileAsync('pdftotext', ['-layout', pdfPath, '-'], {
      timeout: 60_000,
      windowsHide: true,
      maxBuffer: 64 * 1024 * 1024,
    });
    return String(stdout || '').split('\f');
  } catch (_) {
    return [];
  }
}

async function downloadPaper(paper) {
  const { data, error } = await supa.storage
    .from(paper.storage_bucket || 'problem-documents')
    .download(paper.storage_path);
  if (error || !data) {
    throw new Error(`mock_paper_download_failed:${paper.id}:${error?.message || 'no_data'}`);
  }
  return Buffer.from(await data.arrayBuffer());
}

async function updateExam(examId, patch) {
  const { error } = await supa
    .from('mock_exams')
    .update({ ...patch, locked_at: new Date().toISOString() })
    .eq('id', examId);
  if (error) throw new Error(`mock_exam_update_failed:${error.message}`);
}

async function setProgress(exam, stage, progress) {
  exam.progress = { ...(exam.progress || {}), ...progress };
  await updateExam(exam.id, { stage, progress: exam.progress });
}

async function readPages({ paper, buffer, pages, prompt, normalize, stage }) {
  return withTempPdf(buffer, async (pdfPath, dir) =>
    mapLimit(pages, PAGE_CONCURRENCY, async (page) => {
      const png = await renderPage(pdfPath, dir, page);
      const res = await callGeminiImageJson({
        imageBuffer: png,
        prompt: prompt(page),
        model: MODEL,
        apiKey: GEMINI_API_KEY,
      });
      logVlmUsage(stage, res.usageMetadata, {
        paper: paper.id.slice(0, 8),
        page,
        elapsed: `${res.elapsedMs}ms`,
      });
      return { page, result: normalize(res.parsedJson) };
    }),
  );
}

function sortPapers(papers, kind) {
  return papers
    .filter((p) => p.kind === kind)
    .sort((a, b) => ELECTIVE_ORDER.indexOf(a.elective) - ELECTIVE_ORDER.indexOf(b.elective));
}

async function loadItems(examId) {
  const { data, error } = await supa
    .from('mock_exam_items')
    .select('*')
    .eq('exam_id', examId);
  if (error) throw new Error(`mock_items_fetch_failed:${error.message}`);
  const map = new Map();
  for (const row of data || []) map.set(`${row.section}|${row.problem_number}`, row);
  return map;
}

async function upsertItems(rows) {
  if (rows.length === 0) return;
  const { error } = await supa
    .from('mock_exam_items')
    .upsert(rows, { onConflict: 'exam_id,section,problem_number' });
  if (error) throw new Error(`mock_items_upsert_failed:${error.message}`);
}

async function savePageCount(paper, buffer) {
  const doc = await PDFDocument.load(buffer, { ignoreEncryption: true });
  const count = doc.getPageCount();
  if (paper.page_count !== count) {
    await supa.from('mock_exam_papers').update({ page_count: count }).eq('id', paper.id);
    paper.page_count = count;
  }
  return count;
}

async function stageCrops(exam, papers) {
  const problems = sortPapers(papers, 'problem');
  if (problems.length === 0) throw new Error('mock_problem_paper_missing');
  const rows = [];
  let commonLastPage = 0;
  for (let i = 0; i < problems.length; i += 1) {
    const paper = problems[i];
    const buffer = await downloadPaper(paper);
    const pageCount = await savePageCount(paper, buffer);
    const takeCommon = i === 0;
    const pages = [];
    for (let p = 1; p <= pageCount; p += 1) {
      if (!takeCommon && p <= commonLastPage) continue;
      pages.push(p);
    }
    await setProgress(exam, 'crops', {
      crops: { paper: paper.elective || 'common', done: i, total: problems.length },
    });
    const read = await readPages({
      paper,
      buffer,
      pages,
      prompt: (page) => buildProblemPagePrompt({ grade: exam.grade, page }),
      normalize: normalizeProblemPage,
      stage: 'mock-crops',
    });
    const items = assignProblemItems({
      grade: exam.grade,
      paperElective: paper.elective,
      pages: read,
      takeCommon,
    });
    if (takeCommon) {
      commonLastPage = items
        .filter((item) => item.section === 'common')
        .reduce((max, item) => Math.max(max, item.page), 0);
    }
    for (const item of items) {
      rows.push({
        academy_id: exam.academy_id,
        exam_id: exam.id,
        section: item.section,
        problem_number: item.number,
        paper_id: paper.id,
        raw_page: item.page,
        item_region_1k: item.region,
      });
    }
  }
  await upsertItems(rows);
  return rows.length;
}

async function stageSolutions(exam, papers) {
  const solutions = sortPapers(papers, 'solution');
  if (solutions.length === 0) return { answers: 0, solutions: 0 };
  const existing = await loadItems(exam.id);
  const answers = new Map();
  const positions = new Map();
  for (let i = 0; i < solutions.length; i += 1) {
    const paper = solutions[i];
    const buffer = await downloadPaper(paper);
    const pageCount = await savePageCount(paper, buffer);
    // 공통 해설은 첫 해설지에서 받는다. 나머지는 선택과목 머리가 있는 쪽부터 본다.
    let startPage = 1;
    if (i > 0 && paper.elective) {
      const texts = await withTempPdf(buffer, (pdfPath) => pageTexts(pdfPath));
      startPage = electiveStartPageFromText(texts, paper.elective) || 1;
    }
    const pages = [];
    for (let p = startPage; p <= pageCount; p += 1) pages.push(p);
    await setProgress(exam, 'solutions', {
      solutions: { paper: paper.elective || 'common', done: i, total: solutions.length },
    });
    const read = await readPages({
      paper,
      buffer,
      pages,
      prompt: (page) => buildSolutionPagePrompt({ grade: exam.grade, page }),
      normalize: normalizeSolutionPage,
      stage: 'mock-solutions',
    });
    const assigned = assignSolutionSections({
      grade: exam.grade,
      paperElective: paper.elective,
      pages: read,
    });
    for (const [key, value] of assigned.answers) {
      if (!answers.has(key)) answers.set(key, value);
    }
    for (const [key, value] of assigned.solutions) {
      if (!positions.has(key)) positions.set(key, { ...value, paperId: paper.id });
    }
  }

  const rows = [];
  const keys = new Set([...answers.keys(), ...positions.keys()]);
  for (const key of keys) {
    const [section, numberText] = key.split('|');
    const number = Number(numberText);
    const prev = existing.get(key);
    const row = {
      academy_id: exam.academy_id,
      exam_id: exam.id,
      section,
      problem_number: number,
    };
    const answer = answers.get(key);
    if (answer && prev?.answer_source !== 'manual') {
      row.answer_kind = answer.kind;
      row.answer_text = answer.text;
      row.answer_source = 'vlm';
    }
    const position = positions.get(key);
    if (position && prev?.solution_source !== 'manual') {
      row.solution_paper_id = position.paperId;
      row.solution_raw_page = position.page;
      row.solution_number_region_1k = position.numberRegion;
      row.solution_content_region_1k = position.contentRegion;
      row.solution_source = 'vlm';
    }
    rows.push(row);
  }
  // upsert 는 행마다 컬럼이 같아야 하므로 바뀌는 컬럼 묶음별로 나눠 쓴다.
  const groups = new Map();
  for (const row of rows) {
    const signature = Object.keys(row).sort().join(',');
    if (!groups.has(signature)) groups.set(signature, []);
    groups.get(signature).push(row);
  }
  for (const group of groups.values()) await upsertItems(group);
  return { answers: answers.size, solutions: positions.size };
}

function missingReport(exam, items) {
  const sections = Number(exam.grade) === 3
    ? ['common', ...ELECTIVES]
    : ['common'];
  const out = {};
  for (const section of sections) {
    const rows = [...items.values()].filter((row) => row.section === section);
    if (section !== 'common' && rows.length === 0) continue;
    const want = expectedNumbers(exam.grade, section);
    const crop = want.filter(
      (n) => !rows.some((r) => r.problem_number === n && Array.isArray(r.item_region_1k)),
    );
    const answer = want.filter(
      (n) => !rows.some((r) => r.problem_number === n && compact(r.answer_text)),
    );
    const solution = want.filter(
      (n) => !rows.some((r) => r.problem_number === n && r.solution_raw_page),
    );
    out[section] = { crop, answer, solution };
  }
  return out;
}

async function ensureSectionDocument(exam, section, sectionItems, papersById) {
  const withCrop = sectionItems.filter((row) => row.paper_id && row.raw_page);
  if (withCrop.length === 0) return null;
  const paper = papersById.get(withCrop[0].paper_id);
  if (!paper) return null;
  const pagesOfPaper = withCrop
    .filter((row) => row.paper_id === paper.id)
    .map((row) => row.raw_page);
  const mockScope = {
    exam_id: exam.id,
    section,
    paper_id: paper.id,
    raw_page_from: Math.min(...pagesOfPaper),
    raw_page_to: Math.max(...pagesOfPaper),
  };
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
  const now = new Date().toISOString();
  const docFields = {
    source_filename: `${title} · ${sectionLabel}`,
    source_storage_bucket: 'problem-documents',
    source_storage_path: '',
    source_pdf_storage_bucket: paper.storage_bucket,
    source_pdf_storage_path: paper.storage_path,
    source_pdf_filename: paper.file_name,
    source_pdf_sha256: paper.sha256 || '',
    source_pdf_size_bytes: Number(paper.size_bytes || 0),
    status: 'extract_queued',
    curriculum_code: exam.curriculum_code || 'rev_2015',
    source_type_code: 'mock_past',
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
    updated_at: now,
  };

  const { data: link } = await supa
    .from('mock_exam_sections')
    .select('pb_document_id')
    .eq('exam_id', exam.id)
    .eq('section', section)
    .maybeSingle();
  let documentId = compact(link?.pb_document_id);
  const meta = {
    source_classification: {
      private_material: false,
      school_past_exam: false,
      mock_past_exam: true,
      mock_exam: mockDetail,
    },
    extract_mode: 'mock_exam_pdf',
    mock_scope: mockScope,
  };
  if (documentId) {
    const { data: prev } = await supa
      .from('pb_documents')
      .select('meta')
      .eq('id', documentId)
      .maybeSingle();
    if (!prev) documentId = '';
    else {
      const { error } = await supa
        .from('pb_documents')
        .update({ ...docFields, meta: { ...(prev.meta || {}), ...meta } })
        .eq('id', documentId);
      if (error) throw new Error(`mock_pb_document_update_failed:${error.message}`);
    }
  }
  if (!documentId) {
    const { data, error } = await supa
      .from('pb_documents')
      .insert({
        academy_id: exam.academy_id,
        created_by: exam.created_by,
        source_sha256: '',
        source_size_bytes: 0,
        ...docFields,
        meta: { ...meta, created_at: now },
      })
      .select('id')
      .single();
    if (error) throw new Error(`mock_pb_document_insert_failed:${error.message}`);
    documentId = data.id;
  }
  const { data: job, error: jobErr } = await supa
    .from('pb_extract_jobs')
    .insert({
      academy_id: exam.academy_id,
      document_id: documentId,
      created_by: exam.created_by,
      status: 'queued',
      source_version: PB_SOURCE_VERSION,
      result_summary: { engine: 'vlm_pdf_only', mock_scope: mockScope },
    })
    .select('id')
    .single();
  if (jobErr) throw new Error(`mock_pb_job_insert_failed:${jobErr.message}`);
  const { error: linkErr } = await supa.from('mock_exam_sections').upsert(
    {
      exam_id: exam.id,
      section,
      academy_id: exam.academy_id,
      pb_document_id: documentId,
      extract_job_id: job.id,
    },
    { onConflict: 'exam_id,section' },
  );
  if (linkErr) throw new Error(`mock_section_link_failed:${linkErr.message}`);
  return { documentId, jobId: job.id };
}

async function stageProblemBank(exam, papers, { requeue }) {
  const items = await loadItems(exam.id);
  const papersById = new Map(papers.map((p) => [p.id, p]));
  const { data: links } = await supa
    .from('mock_exam_sections')
    .select('section, pb_document_id, extract_job_id')
    .eq('exam_id', exam.id);
  const linked = new Map((links || []).map((row) => [row.section, row]));
  const out = {};
  for (const section of ['common', ...ELECTIVES]) {
    const sectionItems = [...items.values()].filter((row) => row.section === section);
    if (sectionItems.length === 0) continue;
    const prev = linked.get(section);
    // 해설만 다시 읽을 때는 검수 중인 문제은행 문항을 다시 뽑지 않는다.
    if (!requeue && compact(prev?.pb_document_id)) {
      out[section] = { documentId: prev.pb_document_id, jobId: prev.extract_job_id };
      continue;
    }
    const created = await ensureSectionDocument(exam, section, sectionItems, papersById);
    if (created) out[section] = created;
  }
  return { items, sections: out };
}

export async function processExam(exam) {
  const { data: papers, error } = await supa
    .from('mock_exam_papers')
    .select('*')
    .eq('exam_id', exam.id);
  if (error) throw new Error(`mock_papers_fetch_failed:${error.message}`);
  const request = compact(exam.progress?.request) || 'all';
  exam.progress = { request, started_at: new Date().toISOString() };
  if (request === 'all' || request === 'crops') {
    const cropCount = await stageCrops(exam, papers || []);
    await setProgress(exam, 'crops', { crop_count: cropCount });
  }
  if (request === 'all' || request === 'solutions') {
    const counts = await stageSolutions(exam, papers || []);
    await setProgress(exam, 'solutions', { answer_count: counts.answers, solution_count: counts.solutions });
  }
  const { items, sections } = await stageProblemBank(exam, papers || [], {
    requeue: request === 'all' || request === 'crops' || request === 'problem_bank',
  });
  exam.progress = {
    ...exam.progress,
    missing: missingReport(exam, items),
    sections,
    finished_at: new Date().toISOString(),
  };
  await updateExam(exam.id, {
    status: 'review',
    stage: 'extracting',
    progress: exam.progress,
    last_error: '',
    title: mockExamTitle(exam),
  });
  return exam.progress;
}

async function claimNext() {
  const { data, error } = await supa
    .from('mock_exams')
    .select('*')
    .eq('status', 'queued')
    .order('updated_at', { ascending: true })
    .limit(1);
  if (error) throw new Error(`mock_queue_fetch_failed:${error.message}`);
  const row = (data || [])[0];
  if (!row) return null;
  const { data: locked, error: lockErr } = await supa
    .from('mock_exams')
    .update({ status: 'running', stage: 'starting', locked_at: new Date().toISOString(), last_error: '' })
    .eq('id', row.id)
    .eq('status', 'queued')
    .select('*')
    .maybeSingle();
  if (lockErr) throw new Error(`mock_lock_failed:${lockErr.message}`);
  return locked || null;
}

async function reclaimStale() {
  const cutoff = new Date(Date.now() - STALE_MS).toISOString();
  const { data } = await supa
    .from('mock_exams')
    .update({ status: 'failed', last_error: 'worker_stale' })
    .eq('status', 'running')
    .lt('locked_at', cutoff)
    .select('id');
  for (const row of data || []) log('reclaimed_stale', { examId: row.id });
}

async function tick() {
  const exam = await claimNext();
  if (!exam) return false;
  log('start', { examId: exam.id, title: mockExamTitle(exam) });
  try {
    const progress = await processExam(exam);
    log('done', { examId: exam.id, missing: progress.missing });
  } catch (err) {
    const message = compact(err?.message || err).slice(0, 1000);
    log('fail', { examId: exam.id, message });
    await supa
      .from('mock_exams')
      .update({ status: 'failed', last_error: message })
      .eq('id', exam.id);
  }
  return true;
}

async function main() {
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error('SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY missing');
  }
  supa = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  log('boot', { model: MODEL, dpi: RENDER_DPI, concurrency: PAGE_CONCURRENCY });
  await reclaimStale().catch(() => {});
  let lastReclaim = Date.now();
  while (true) {
    let worked = false;
    try {
      if (Date.now() - lastReclaim > STALE_MS / 2) {
        await reclaimStale().catch(() => {});
        lastReclaim = Date.now();
      }
      worked = await tick();
    } catch (err) {
      log('tick_error', { message: compact(err?.message || err) });
    }
    if (PROCESS_ONCE) break;
    if (!worked) await new Promise((resolve) => setTimeout(resolve, INTERVAL_MS));
  }
}

const isDirectRun =
  (typeof process.argv[1] === 'string' &&
    process.argv[1].length > 0 &&
    import.meta.url === pathToFileURL(process.argv[1]).href) ||
  (typeof process.env.pm_exec_path === 'string' &&
    process.env.pm_exec_path.length > 0 &&
    import.meta.url === pathToFileURL(process.env.pm_exec_path).href);

if (isDirectRun) {
  main().catch((err) => {
    console.error('[mock-exam-worker] fatal', compact(err?.message || err));
    process.exit(1);
  });
}
