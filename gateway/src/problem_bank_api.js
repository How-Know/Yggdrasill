import 'dotenv/config';
import http from 'node:http';
import { createHash } from 'node:crypto';
import { URL } from 'node:url';
import { createClient } from '@supabase/supabase-js';

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const API_PORT = Number.parseInt(process.env.PB_API_PORT || '8787', 10);
const API_HOST = process.env.PB_API_HOST || '0.0.0.0';
const API_KEY = (process.env.PB_API_KEY || '').trim();

if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
  console.error(
    '[pb-api] Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY in env',
  );
  process.exit(1);
}

const supa = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

function sendJson(res, statusCode, body) {
  const payload = JSON.stringify(body);
  res.writeHead(statusCode, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(payload),
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type,x-api-key',
  });
  res.end(payload);
}

function notFound(res) {
  sendJson(res, 404, { ok: false, error: 'not_found' });
}

function compact(value, max = 240) {
  const s = String(value ?? '').replace(/\s+/g, ' ').trim();
  if (s.length <= max) return s;
  return `${s.slice(0, max)}...`;
}

async function readJson(req) {
  const chunks = [];
  for await (const chunk of req) {
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  }
  const raw = Buffer.concat(chunks).toString('utf8').trim();
  if (!raw) return {};
  try {
    return JSON.parse(raw);
  } catch {
    throw new Error('invalid_json');
  }
}

function requireApiKey(req) {
  if (!API_KEY) return true;
  const incoming = String(req.headers['x-api-key'] || '').trim();
  return incoming === API_KEY;
}

function normalizeLimit(raw, fallback = 30, max = 100) {
  const n = Number.parseInt(String(raw || fallback), 10);
  if (!Number.isFinite(n) || n <= 0) return fallback;
  return Math.min(max, n);
}

function normalizeBool(raw, fallback = false) {
  if (raw == null) return fallback;
  if (typeof raw === 'boolean') return raw;
  const s = String(raw).trim().toLowerCase();
  if (['1', 'true', 'yes', 'y'].includes(s)) return true;
  if (['0', 'false', 'no', 'n'].includes(s)) return false;
  return fallback;
}

function normalizeTemplateProfile(raw) {
  const s = String(raw || '').trim().toLowerCase();
  if (s === 'csat' || s === 'mock' || s === 'naesin') return s;
  return 'naesin';
}

const CURRICULUM_CODES = new Set([
  'legacy_1to6',
  'k7_1997',
  'k7_2007',
  'rev_2009',
  'rev_2015',
  'rev_2022',
]);

const SOURCE_TYPE_CODES = new Set([
  'market_book',
  'lecture_book',
  'ebs_book',
  'school_past',
  'mock_past',
  'original_item',
]);

function normalizeCurriculumCode(raw, fallback = '') {
  const code = String(raw || '').trim();
  if (CURRICULUM_CODES.has(code)) return code;
  return fallback;
}

function normalizeSourceTypeCode(raw, fallback = '') {
  const code = String(raw || '').trim();
  if (SOURCE_TYPE_CODES.has(code)) return code;
  return fallback;
}

function normalizePaper(raw) {
  const v = String(raw || '').trim().toUpperCase();
  if (v === 'A4' || v === 'B4' || v === '8절') return v;
  if (v === '8K' || v === '8JEOL') return '8절';
  return 'A4';
}

function normalizeNumeric(raw, fallback, min, max) {
  const n = Number.parseFloat(String(raw ?? ''));
  if (!Number.isFinite(n)) return fallback;
  return Math.min(max, Math.max(min, n));
}

function normalizeLayoutColumns(raw) {
  const v = String(raw ?? '').trim();
  if (v === '2' || v === '2단' || v.toLowerCase() === 'two') return 2;
  return 1;
}

function normalizeMaxQuestionsPerPage(raw, columns) {
  const defaults = columns === 2 ? 8 : 4;
  const parsed = Number.parseInt(String(raw ?? ''), 10);
  if (!Number.isFinite(parsed) || parsed <= 0) return defaults;
  const allowed = columns === 2 ? [1, 2, 4, 6, 8] : [1, 2, 3, 4];
  if (allowed.includes(parsed)) return parsed;
  return defaults;
}

function normalizeQuestionMode(raw) {
  const v = String(raw || '').trim().toLowerCase();
  if (v === 'objective' || v === '객관식' || v === 'mcq') return 'objective';
  if (v === 'subjective' || v === '주관식') return 'subjective';
  if (v === 'essay' || v === '서술형') return 'essay';
  return 'original';
}

function normalizeQuestionModeMap(raw, selectedIds, fallbackMode = 'original') {
  const out = {};
  const src = raw && typeof raw === 'object' ? raw : {};
  for (const id of selectedIds) {
    const mode = normalizeQuestionMode(src[id] || fallbackMode);
    out[id] = mode;
  }
  return out;
}

function normalizeSelectedQuestionIdsOrdered(raw, fallbackSelectedIds) {
  const fallback = Array.isArray(fallbackSelectedIds)
    ? fallbackSelectedIds.filter((v) => isUuid(v))
    : [];
  const src = Array.isArray(raw) ? raw.filter((v) => isUuid(v)) : [];
  if (src.length === 0) return fallback;
  const set = new Set(fallback);
  const ordered = src.filter((id) => set.has(id));
  const orderedSet = new Set(ordered);
  for (const id of fallback) {
    if (!orderedSet.has(id)) ordered.push(id);
  }
  return ordered;
}

function normalizeLayoutTuning(rawLayoutTuning, options = {}) {
  const src = rawLayoutTuning && typeof rawLayoutTuning === 'object'
    ? rawLayoutTuning
    : {};
  return {
    pageMargin: normalizeNumeric(
      src.pageMargin ?? options.pageMargin,
      46,
      20,
      96,
    ),
    columnGap: normalizeNumeric(
      src.columnGap ?? options.columnGap,
      18,
      0,
      72,
    ),
    questionGap: normalizeNumeric(
      src.questionGap ?? options.questionGap,
      12,
      0,
      64,
    ),
    numberLaneWidth: normalizeNumeric(
      src.numberLaneWidth ?? options.numberLaneWidth,
      26,
      10,
      80,
    ),
    numberGap: normalizeNumeric(
      src.numberGap ?? options.numberGap,
      6,
      0,
      30,
    ),
    hangingIndent: normalizeNumeric(
      src.hangingIndent ?? options.hangingIndent,
      22,
      0,
      96,
    ),
    lineHeight: normalizeNumeric(
      src.lineHeight ?? options.lineHeight,
      15.4,
      10,
      32,
    ),
    choiceSpacing: normalizeNumeric(
      src.choiceSpacing ?? options.choiceSpacing,
      2.2,
      0,
      24,
    ),
  };
}

function normalizeFigureQuality(rawFigureQuality, options = {}) {
  const src = rawFigureQuality && typeof rawFigureQuality === 'object'
    ? rawFigureQuality
    : {};
  const targetDpi = Math.round(
    normalizeNumeric(src.targetDpi ?? options.targetDpi, 450, 300, 1200),
  );
  const minDpi = Math.round(
    normalizeNumeric(src.minDpi ?? options.minDpi, 300, 180, targetDpi),
  );
  return { targetDpi, minDpi };
}

function normalizeExportRenderConfig(options, selectedQuestionIds, defaults = {}) {
  const src = options && typeof options === 'object' ? options : {};
  const requestedRenderConfigVersion = String(
    src.renderConfigVersion || '',
  ).trim();
  const layoutColumns = normalizeLayoutColumns(
    src.layoutColumns ||
      src.layout_columns ||
      src.columnCount ||
      src.columns ||
      defaults.layoutColumns ||
      1,
  );
  const maxQuestionsPerPage = normalizeMaxQuestionsPerPage(
    src.maxQuestionsPerPage ||
      src.max_questions_per_page ||
      src.perPage ||
      src.questionsPerPage ||
      defaults.maxQuestionsPerPage ||
      '',
    layoutColumns,
  );
  const questionMode = normalizeQuestionMode(
    src.questionMode || src.question_mode || src.mode || defaults.questionMode,
  );
  const selectedQuestionIdsOrdered = normalizeSelectedQuestionIdsOrdered(
    src.selectedQuestionIdsOrdered,
    selectedQuestionIds,
  );
  const questionModeByQuestionId = normalizeQuestionModeMap(
    src.questionModeByQuestionId,
    selectedQuestionIdsOrdered,
    questionMode,
  );
  return {
    // Force server-side renderer to latest stable path even if older app build
    // sends a stale renderConfigVersion.
    renderConfigVersion: 'pb_render_v25_bogi_choice_indent_gap',
    layoutColumns,
    maxQuestionsPerPage,
    questionMode,
    layoutTuning: normalizeLayoutTuning(src.layoutTuning, src),
    figureQuality: normalizeFigureQuality(src.figureQuality, src),
    font:
      src.font && typeof src.font === 'object'
        ? {
            family: String(src.font.family || '').trim(),
            size: normalizeNumeric(src.font.size, 11.3, 8, 28),
          }
        : {
            family: '',
            size: 11.3,
          },
    selectedQuestionIdsOrdered,
    questionModeByQuestionId,
  };
}

function canonicalizeJson(value) {
  if (Array.isArray(value)) {
    return value.map((item) => canonicalizeJson(item));
  }
  if (value && typeof value === 'object') {
    const out = {};
    for (const key of Object.keys(value).sort()) {
      out[key] = canonicalizeJson(value[key]);
    }
    return out;
  }
  return value;
}

function computeRenderHash(renderPayload) {
  const canonical = JSON.stringify(canonicalizeJson(renderPayload));
  return createHash('sha256').update(canonical).digest('hex');
}

function isUuid(v) {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
    String(v || '').trim(),
  );
}

async function ensureDocumentBelongs(academyId, documentId) {
  const { data, error } = await supa
    .from('pb_documents')
    .select(
      [
        'id',
        'academy_id',
        'status',
        'exam_profile',
        'source_filename',
        'meta',
        'curriculum_code',
        'source_type_code',
        'course_label',
        'grade_label',
        'exam_year',
        'semester_label',
        'exam_term_label',
        'school_name',
        'publisher_name',
        'material_name',
        'classification_detail',
      ].join(','),
    )
    .eq('id', documentId)
    .eq('academy_id', academyId)
    .maybeSingle();
  if (error) {
    throw new Error(`document_lookup_failed:${error.message}`);
  }
  return data;
}

async function createExtractJob(body, res) {
  const academyId = String(body.academyId || '').trim();
  const documentId = String(body.documentId || '').trim();
  const createdBy = String(body.createdBy || '').trim();
  if (!isUuid(academyId) || !isUuid(documentId)) {
    sendJson(res, 400, {
      ok: false,
      error: 'academyId/documentId must be uuid',
    });
    return;
  }
  const doc = await ensureDocumentBelongs(academyId, documentId);
  if (!doc) {
    sendJson(res, 404, { ok: false, error: 'document_not_found' });
    return;
  }

  const { data: job, error: insertErr } = await supa
    .from('pb_extract_jobs')
    .insert({
      academy_id: academyId,
      document_id: documentId,
      created_by: isUuid(createdBy) ? createdBy : null,
      status: 'queued',
      retry_count: 0,
      max_retries: 3,
      worker_name: '',
      source_version: 'api_v1',
      result_summary: {},
      error_code: '',
      error_message: '',
      started_at: null,
      finished_at: null,
    })
    .select('*')
    .maybeSingle();
  if (insertErr || !job) {
    sendJson(res, 500, {
      ok: false,
      error: `extract_job_insert_failed:${insertErr?.message || 'unknown'}`,
    });
    return;
  }

  await supa
    .from('pb_documents')
    .update({
      status: 'extract_queued',
      updated_at: new Date().toISOString(),
    })
    .eq('id', documentId);

  sendJson(res, 201, { ok: true, job });
}

async function listExtractJobs(url, res) {
  const academyId = String(url.searchParams.get('academyId') || '').trim();
  if (!isUuid(academyId)) {
    sendJson(res, 400, { ok: false, error: 'academyId must be uuid' });
    return;
  }
  const status = String(url.searchParams.get('status') || '').trim();
  const documentId = String(url.searchParams.get('documentId') || '').trim();
  const limit = normalizeLimit(url.searchParams.get('limit'), 30, 120);

  let q = supa
    .from('pb_extract_jobs')
    .select('*')
    .eq('academy_id', academyId)
    .order('created_at', { ascending: false })
    .limit(limit);
  if (status) q = q.eq('status', status);
  if (documentId) q = q.eq('document_id', documentId);

  const { data, error } = await q;
  if (error) {
    sendJson(res, 500, { ok: false, error: `extract_job_list_failed:${error.message}` });
    return;
  }
  sendJson(res, 200, { ok: true, jobs: data || [] });
}

async function getExtractJob(jobId, url, res) {
  const academyId = String(url.searchParams.get('academyId') || '').trim();
  if (!isUuid(jobId) || !isUuid(academyId)) {
    sendJson(res, 400, { ok: false, error: 'jobId/academyId must be uuid' });
    return;
  }
  const { data, error } = await supa
    .from('pb_extract_jobs')
    .select('*')
    .eq('id', jobId)
    .eq('academy_id', academyId)
    .maybeSingle();
  if (error) {
    sendJson(res, 500, { ok: false, error: `extract_job_get_failed:${error.message}` });
    return;
  }
  if (!data) {
    sendJson(res, 404, { ok: false, error: 'extract_job_not_found' });
    return;
  }
  sendJson(res, 200, { ok: true, job: data });
}

async function retryExtractJob(jobId, body, res) {
  const academyId = String(body.academyId || '').trim();
  if (!isUuid(jobId) || !isUuid(academyId)) {
    sendJson(res, 400, { ok: false, error: 'jobId/academyId must be uuid' });
    return;
  }
  const { data: oldJob, error: oldErr } = await supa
    .from('pb_extract_jobs')
    .select('*')
    .eq('id', jobId)
    .eq('academy_id', academyId)
    .maybeSingle();
  if (oldErr) {
    sendJson(res, 500, { ok: false, error: `extract_job_lookup_failed:${oldErr.message}` });
    return;
  }
  if (!oldJob) {
    sendJson(res, 404, { ok: false, error: 'extract_job_not_found' });
    return;
  }
  if (oldJob.status === 'extracting') {
    sendJson(res, 409, { ok: false, error: 'extract_job_in_progress' });
    return;
  }
  const { data: updated, error: updErr } = await supa
    .from('pb_extract_jobs')
    .update({
      status: 'queued',
      error_code: '',
      error_message: '',
      result_summary: {},
      started_at: null,
      finished_at: null,
      updated_at: new Date().toISOString(),
    })
    .eq('id', jobId)
    .select('*')
    .maybeSingle();
  if (updErr || !updated) {
    sendJson(res, 500, {
      ok: false,
      error: `extract_job_retry_failed:${updErr?.message || 'unknown'}`,
    });
    return;
  }
  await supa
    .from('pb_documents')
    .update({
      status: 'extract_queued',
      updated_at: new Date().toISOString(),
    })
    .eq('id', updated.document_id);
  sendJson(res, 200, { ok: true, job: updated });
}

async function ensureQuestionBelongs(academyId, documentId, questionId) {
  const { data, error } = await supa
    .from('pb_questions')
    .select('id,academy_id,document_id,figure_refs,meta')
    .eq('id', questionId)
    .eq('academy_id', academyId)
    .eq('document_id', documentId)
    .maybeSingle();
  if (error) {
    throw new Error(`question_lookup_failed:${error.message}`);
  }
  return data;
}

async function createFigureJob(body, res) {
  const academyId = String(body.academyId || '').trim();
  const documentId = String(body.documentId || '').trim();
  const questionId = String(body.questionId || '').trim();
  const createdBy = String(body.createdBy || '').trim();
  const forceRegenerate = normalizeBool(body.forceRegenerate, false);
  const provider = String(body.provider || 'gemini').trim() || 'gemini';
  const modelName = String(body.modelName || '').trim();
  if (!isUuid(academyId) || !isUuid(documentId) || !isUuid(questionId)) {
    sendJson(res, 400, {
      ok: false,
      error: 'academyId/documentId/questionId must be uuid',
    });
    return;
  }
  const doc = await ensureDocumentBelongs(academyId, documentId);
  if (!doc) {
    sendJson(res, 404, { ok: false, error: 'document_not_found' });
    return;
  }
  const question = await ensureQuestionBelongs(academyId, documentId, questionId);
  if (!question) {
    sendJson(res, 404, { ok: false, error: 'question_not_found' });
    return;
  }
  const figureRefs = Array.isArray(question.figure_refs) ? question.figure_refs : [];
  if (figureRefs.length === 0) {
    sendJson(res, 409, { ok: false, error: 'question_has_no_figure_refs' });
    return;
  }

  if (!forceRegenerate) {
    const { data: existing } = await supa
      .from('pb_figure_jobs')
      .select('*')
      .eq('academy_id', academyId)
      .eq('document_id', documentId)
      .eq('question_id', questionId)
      .in('status', ['queued', 'rendering'])
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle();
    if (existing) {
      sendJson(res, 200, { ok: true, job: existing, reused: true });
      return;
    }
  }

  const { data: job, error: insertErr } = await supa
    .from('pb_figure_jobs')
    .insert({
      academy_id: academyId,
      document_id: documentId,
      question_id: questionId,
      created_by: isUuid(createdBy) ? createdBy : null,
      status: 'queued',
      provider,
      model_name: modelName,
      options: typeof body.options === 'object' && body.options ? body.options : {},
      prompt_text: String(body.promptText || '').trim(),
      worker_name: '',
      result_summary: {},
      output_storage_bucket: 'problem-previews',
      output_storage_path: '',
      error_code: '',
      error_message: '',
      started_at: null,
      finished_at: null,
    })
    .select('*')
    .maybeSingle();
  if (insertErr || !job) {
    sendJson(res, 500, {
      ok: false,
      error: `figure_job_insert_failed:${insertErr?.message || 'unknown'}`,
    });
    return;
  }
  sendJson(res, 201, { ok: true, job });
}

async function listFigureJobs(url, res) {
  const academyId = String(url.searchParams.get('academyId') || '').trim();
  if (!isUuid(academyId)) {
    sendJson(res, 400, { ok: false, error: 'academyId must be uuid' });
    return;
  }
  const documentId = String(url.searchParams.get('documentId') || '').trim();
  const questionId = String(url.searchParams.get('questionId') || '').trim();
  const status = String(url.searchParams.get('status') || '').trim();
  const limit = normalizeLimit(url.searchParams.get('limit'), 30, 120);
  let q = supa
    .from('pb_figure_jobs')
    .select('*')
    .eq('academy_id', academyId)
    .order('created_at', { ascending: false })
    .limit(limit);
  if (documentId) q = q.eq('document_id', documentId);
  if (questionId) q = q.eq('question_id', questionId);
  if (status) q = q.eq('status', status);
  const { data, error } = await q;
  if (error) {
    sendJson(res, 500, { ok: false, error: `figure_job_list_failed:${error.message}` });
    return;
  }
  sendJson(res, 200, { ok: true, jobs: data || [] });
}

async function getFigureJob(jobId, url, res) {
  const academyId = String(url.searchParams.get('academyId') || '').trim();
  if (!isUuid(jobId) || !isUuid(academyId)) {
    sendJson(res, 400, { ok: false, error: 'jobId/academyId must be uuid' });
    return;
  }
  const { data, error } = await supa
    .from('pb_figure_jobs')
    .select('*')
    .eq('id', jobId)
    .eq('academy_id', academyId)
    .maybeSingle();
  if (error) {
    sendJson(res, 500, { ok: false, error: `figure_job_get_failed:${error.message}` });
    return;
  }
  if (!data) {
    sendJson(res, 404, { ok: false, error: 'figure_job_not_found' });
    return;
  }
  sendJson(res, 200, { ok: true, job: data });
}

async function retryFigureJob(jobId, body, res) {
  const academyId = String(body.academyId || '').trim();
  if (!isUuid(jobId) || !isUuid(academyId)) {
    sendJson(res, 400, { ok: false, error: 'jobId/academyId must be uuid' });
    return;
  }
  const { data: oldJob, error: oldErr } = await supa
    .from('pb_figure_jobs')
    .select('*')
    .eq('id', jobId)
    .eq('academy_id', academyId)
    .maybeSingle();
  if (oldErr) {
    sendJson(res, 500, { ok: false, error: `figure_job_lookup_failed:${oldErr.message}` });
    return;
  }
  if (!oldJob) {
    sendJson(res, 404, { ok: false, error: 'figure_job_not_found' });
    return;
  }
  if (oldJob.status === 'rendering') {
    sendJson(res, 409, { ok: false, error: 'figure_job_in_progress' });
    return;
  }
  const { data: updated, error: updErr } = await supa
    .from('pb_figure_jobs')
    .update({
      status: 'queued',
      error_code: '',
      error_message: '',
      result_summary: {},
      output_storage_path: '',
      started_at: null,
      finished_at: null,
      updated_at: new Date().toISOString(),
    })
    .eq('id', jobId)
    .select('*')
    .maybeSingle();
  if (updErr || !updated) {
    sendJson(res, 500, {
      ok: false,
      error: `figure_job_retry_failed:${updErr?.message || 'unknown'}`,
    });
    return;
  }
  sendJson(res, 200, { ok: true, job: updated });
}

async function createExportJob(body, res) {
  const academyId = String(body.academyId || '').trim();
  const documentId = String(body.documentId || '').trim();
  const requestedBy = String(body.requestedBy || '').trim();
  if (!isUuid(academyId) || !isUuid(documentId)) {
    sendJson(res, 400, {
      ok: false,
      error: 'academyId/documentId must be uuid',
    });
    return;
  }
  const doc = await ensureDocumentBelongs(academyId, documentId);
  if (!doc) {
    sendJson(res, 404, { ok: false, error: 'document_not_found' });
    return;
  }

  const selectedQuestionIdsRaw = Array.isArray(body.selectedQuestionIds)
    ? body.selectedQuestionIds.filter((v) => isUuid(v))
    : [];
  let selectedQuestionIds = selectedQuestionIdsRaw;
  let sourceDocumentIds = [];
  if (selectedQuestionIdsRaw.length > 0) {
    const { data: selectedRows, error: selectedErr } = await supa
      .from('pb_questions')
      .select('id,document_id')
      .eq('academy_id', academyId)
      .in('id', selectedQuestionIdsRaw);
    if (selectedErr) {
      sendJson(res, 500, {
        ok: false,
        error: `export_selected_questions_lookup_failed:${selectedErr.message}`,
      });
      return;
    }
    const rowById = new Map(
      (selectedRows || []).map((row) => [String(row.id || ''), row]),
    );
    selectedQuestionIds = selectedQuestionIdsRaw.filter((id) => rowById.has(id));
    if (selectedQuestionIds.length === 0) {
      sendJson(res, 400, {
        ok: false,
        error: 'selected_question_ids_invalid',
      });
      return;
    }
    const seenDocIds = new Set();
    for (const id of selectedQuestionIds) {
      const row = rowById.get(id);
      const docId = String(row?.document_id || '').trim();
      if (!isUuid(docId) || seenDocIds.has(docId)) continue;
      seenDocIds.add(docId);
      sourceDocumentIds.push(docId);
    }
  }
  if (!sourceDocumentIds.includes(documentId)) {
    sourceDocumentIds = [documentId, ...sourceDocumentIds];
  }
  const rawOptions =
    typeof body.options === 'object' && body.options
      ? { ...body.options }
      : {};
  const templateProfile = normalizeTemplateProfile(body.templateProfile);
  const paperSize = normalizePaper(body.paperSize);
  const includeAnswerSheet = normalizeBool(body.includeAnswerSheet, true);
  const includeExplanation = normalizeBool(body.includeExplanation, false);
  const previewOnly = normalizeBool(
    body.previewOnly,
    normalizeBool(rawOptions.previewOnly, false),
  );
  const renderConfig = normalizeExportRenderConfig(rawOptions, selectedQuestionIds, {
    questionMode: rawOptions.questionMode || rawOptions.question_mode || rawOptions.mode,
    layoutColumns:
      rawOptions.layoutColumns ||
      rawOptions.layout_columns ||
      rawOptions.columnCount ||
      rawOptions.columns,
    maxQuestionsPerPage:
      rawOptions.maxQuestionsPerPage ||
      rawOptions.max_questions_per_page ||
      rawOptions.perPage ||
      rawOptions.questionsPerPage,
  });

  const renderHashPayload = {
    renderConfigVersion: renderConfig.renderConfigVersion,
    templateProfile,
    paperSize,
    includeAnswerSheet,
    includeExplanation,
    layoutColumns: renderConfig.layoutColumns,
    maxQuestionsPerPage: renderConfig.maxQuestionsPerPage,
    questionMode: renderConfig.questionMode,
    font: renderConfig.font,
    layoutTuning: renderConfig.layoutTuning,
    figureQuality: renderConfig.figureQuality,
    selectedQuestionIdsOrdered: renderConfig.selectedQuestionIdsOrdered,
    questionModeByQuestionId: renderConfig.questionModeByQuestionId,
  };
  const renderHash = computeRenderHash(renderHashPayload);

  const options = {
    ...rawOptions,
    sourceDocumentIds,
    renderConfigVersion: renderConfig.renderConfigVersion,
    templateProfile,
    paperSize,
    includeAnswerSheet,
    includeExplanation,
    layoutColumns: renderConfig.layoutColumns,
    maxQuestionsPerPage: renderConfig.maxQuestionsPerPage,
    questionMode: renderConfig.questionMode,
    layoutTuning: renderConfig.layoutTuning,
    figureQuality: renderConfig.figureQuality,
    font: renderConfig.font,
    selectedQuestionIdsOrdered: renderConfig.selectedQuestionIdsOrdered,
    questionModeByQuestionId: renderConfig.questionModeByQuestionId,
    renderHash,
    previewOnly,
  };

  const payload = {
    academy_id: academyId,
    document_id: documentId,
    requested_by: isUuid(requestedBy) ? requestedBy : null,
    status: 'queued',
    template_profile: templateProfile,
    paper_size: paperSize,
    include_answer_sheet: includeAnswerSheet,
    include_explanation: includeExplanation,
    selected_question_ids: selectedQuestionIds,
    render_hash: renderHash,
    preview_only: previewOnly,
    options,
    output_storage_bucket: 'problem-exports',
    output_storage_path: '',
    output_url: '',
    page_count: 0,
    worker_name: '',
    error_code: '',
    error_message: '',
    started_at: null,
    finished_at: null,
  };

  let { data: job, error } = await supa
    .from('pb_exports')
    .insert(payload)
    .select('*')
    .maybeSingle();
  if (error && /render_hash|preview_only/i.test(String(error.message || ''))) {
    const fallbackPayload = { ...payload };
    delete fallbackPayload.render_hash;
    delete fallbackPayload.preview_only;
    ({ data: job, error } = await supa
      .from('pb_exports')
      .insert(fallbackPayload)
      .select('*')
      .maybeSingle());
  }
  if (error || !job) {
    sendJson(res, 500, {
      ok: false,
      error: `export_job_insert_failed:${error?.message || 'unknown'}`,
    });
    return;
  }
  sendJson(res, 201, { ok: true, job });
}

async function listExportJobs(url, res) {
  const academyId = String(url.searchParams.get('academyId') || '').trim();
  if (!isUuid(academyId)) {
    sendJson(res, 400, { ok: false, error: 'academyId must be uuid' });
    return;
  }
  const status = String(url.searchParams.get('status') || '').trim();
  const documentId = String(url.searchParams.get('documentId') || '').trim();
  const renderHash = String(url.searchParams.get('renderHash') || '').trim();
  const previewOnlyRaw = String(url.searchParams.get('previewOnly') || '').trim();
  const previewOnlyFilter =
    previewOnlyRaw.length > 0 ? normalizeBool(previewOnlyRaw, false) : null;
  const limit = normalizeLimit(url.searchParams.get('limit'), 30, 120);
  let data = null;
  {
    let q = supa
      .from('pb_exports')
      .select('*')
      .eq('academy_id', academyId)
      .order('created_at', { ascending: false })
      .limit(limit);
    if (status) q = q.eq('status', status);
    if (documentId) q = q.eq('document_id', documentId);
    if (renderHash) q = q.eq('render_hash', renderHash);
    if (previewOnlyFilter != null) q = q.eq('preview_only', previewOnlyFilter);

    const result = await q;
    if (result.error && /render_hash|preview_only/i.test(String(result.error.message || ''))) {
      let fallback = supa
        .from('pb_exports')
        .select('*')
        .eq('academy_id', academyId)
        .order('created_at', { ascending: false })
        .limit(limit);
      if (status) fallback = fallback.eq('status', status);
      if (documentId) fallback = fallback.eq('document_id', documentId);
      const fallbackResult = await fallback;
      if (fallbackResult.error) {
        sendJson(res, 500, {
          ok: false,
          error: `export_job_list_failed:${fallbackResult.error.message}`,
        });
        return;
      }
      data = fallbackResult.data || [];
    } else if (result.error) {
      sendJson(res, 500, { ok: false, error: `export_job_list_failed:${result.error.message}` });
      return;
    } else {
      data = result.data || [];
    }
  }
  let jobs = data || [];
  if (renderHash) {
    jobs = jobs.filter((job) => {
      const rowHash = String(job?.render_hash || job?.options?.renderHash || '').trim();
      return rowHash === renderHash;
    });
  }
  if (previewOnlyFilter != null) {
    jobs = jobs.filter((job) => {
      const rowPreviewOnly =
        job?.preview_only === true || job?.options?.previewOnly === true;
      return rowPreviewOnly === previewOnlyFilter;
    });
  }
  sendJson(res, 200, { ok: true, jobs });
}

async function getExportJob(jobId, url, res) {
  const academyId = String(url.searchParams.get('academyId') || '').trim();
  if (!isUuid(jobId) || !isUuid(academyId)) {
    sendJson(res, 400, { ok: false, error: 'jobId/academyId must be uuid' });
    return;
  }
  const { data, error } = await supa
    .from('pb_exports')
    .select('*')
    .eq('id', jobId)
    .eq('academy_id', academyId)
    .maybeSingle();
  if (error) {
    sendJson(res, 500, { ok: false, error: `export_job_get_failed:${error.message}` });
    return;
  }
  if (!data) {
    sendJson(res, 404, { ok: false, error: 'export_job_not_found' });
    return;
  }
  sendJson(res, 200, { ok: true, job: data });
}

async function retryExportJob(jobId, body, res) {
  const academyId = String(body.academyId || '').trim();
  if (!isUuid(jobId) || !isUuid(academyId)) {
    sendJson(res, 400, { ok: false, error: 'jobId/academyId must be uuid' });
    return;
  }
  const { data: oldJob, error: oldErr } = await supa
    .from('pb_exports')
    .select('*')
    .eq('id', jobId)
    .eq('academy_id', academyId)
    .maybeSingle();
  if (oldErr) {
    sendJson(res, 500, { ok: false, error: `export_job_lookup_failed:${oldErr.message}` });
    return;
  }
  if (!oldJob) {
    sendJson(res, 404, { ok: false, error: 'export_job_not_found' });
    return;
  }
  if (oldJob.status === 'rendering') {
    sendJson(res, 409, { ok: false, error: 'export_job_in_progress' });
    return;
  }
  const { data: updated, error: updErr } = await supa
    .from('pb_exports')
    .update({
      status: 'queued',
      error_code: '',
      error_message: '',
      output_storage_path: '',
      output_url: '',
      page_count: 0,
      started_at: null,
      finished_at: null,
      updated_at: new Date().toISOString(),
    })
    .eq('id', jobId)
    .select('*')
    .maybeSingle();
  if (updErr || !updated) {
    sendJson(res, 500, {
      ok: false,
      error: `export_job_retry_failed:${updErr?.message || 'unknown'}`,
    });
    return;
  }
  sendJson(res, 200, { ok: true, job: updated });
}

async function cleanupExportArtifact(jobId, body, res) {
  const academyId = String(body.academyId || '').trim();
  if (!isUuid(jobId) || !isUuid(academyId)) {
    sendJson(res, 400, { ok: false, error: 'jobId/academyId must be uuid' });
    return;
  }
  const { data: job, error: lookupErr } = await supa
    .from('pb_exports')
    .select('id,output_storage_bucket,output_storage_path,result_summary')
    .eq('id', jobId)
    .eq('academy_id', academyId)
    .maybeSingle();
  if (lookupErr) {
    sendJson(res, 500, {
      ok: false,
      error: `export_job_lookup_failed:${lookupErr.message}`,
    });
    return;
  }
  if (!job) {
    sendJson(res, 404, { ok: false, error: 'export_job_not_found' });
    return;
  }

  const bucket = String(job.output_storage_bucket || '').trim();
  const path = String(job.output_storage_path || '').trim();
  if (bucket && path) {
    try {
      await supa.storage.from(bucket).remove([path]);
    } catch (_) {
      // ignore storage remove failures
    }
  }

  const nowIso = new Date().toISOString();
  const { data: updated, error: updErr } = await supa
    .from('pb_exports')
    .update({
      output_storage_bucket: '',
      output_storage_path: '',
      output_url: '',
      updated_at: nowIso,
      result_summary: {
        ...(job.result_summary && typeof job.result_summary === 'object'
          ? job.result_summary
          : {}),
        local_saved_at: nowIso,
      },
    })
    .eq('id', jobId)
    .eq('academy_id', academyId)
    .select('*')
    .maybeSingle();
  if (updErr || !updated) {
    sendJson(res, 500, {
      ok: false,
      error: `export_cleanup_failed:${updErr?.message || 'unknown'}`,
    });
    return;
  }
  sendJson(res, 200, { ok: true, job: updated });
}

async function documentSummary(url, res) {
  const academyId = String(url.searchParams.get('academyId') || '').trim();
  const documentId = String(url.searchParams.get('documentId') || '').trim();
  if (!isUuid(academyId) || !isUuid(documentId)) {
    sendJson(res, 400, { ok: false, error: 'academyId/documentId must be uuid' });
    return;
  }
  const doc = await ensureDocumentBelongs(academyId, documentId);
  if (!doc) {
    sendJson(res, 404, { ok: false, error: 'document_not_found' });
    return;
  }
  const { data: latestExtractJob } = await supa
    .from('pb_extract_jobs')
    .select('*')
    .eq('academy_id', academyId)
    .eq('document_id', documentId)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();
  const { data: latestExportJob } = await supa
    .from('pb_exports')
    .select('*')
    .eq('academy_id', academyId)
    .eq('document_id', documentId)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();
  const { count: questionCount } = await supa
    .from('pb_questions')
    .select('id', { count: 'exact', head: true })
    .eq('academy_id', academyId)
    .eq('document_id', documentId);

  sendJson(res, 200, {
    ok: true,
    summary: {
      document: doc,
      latestExtractJob: latestExtractJob || null,
      latestExportJob: latestExportJob || null,
      questionCount,
    },
  });
}

async function listQuestions(url, res) {
  const academyId = String(url.searchParams.get('academyId') || '').trim();
  if (!isUuid(academyId)) {
    sendJson(res, 400, { ok: false, error: 'academyId must be uuid' });
    return;
  }

  const documentId = String(url.searchParams.get('documentId') || '').trim();
  const curriculumCode = normalizeCurriculumCode(
    url.searchParams.get('curriculumCode'),
  );
  const sourceTypeCode = normalizeSourceTypeCode(
    url.searchParams.get('sourceTypeCode'),
  );
  const gradeLabel = String(url.searchParams.get('gradeLabel') || '').trim();
  const schoolName = String(url.searchParams.get('schoolName') || '').trim();
  const questionType = String(url.searchParams.get('questionType') || '').trim();
  const examYearRaw = String(url.searchParams.get('examYear') || '').trim();
  const examYear = Number.parseInt(examYearRaw, 10);
  const limit = normalizeLimit(url.searchParams.get('limit'), 80, 400);
  const offsetRaw = Number.parseInt(
    String(url.searchParams.get('offset') || '0'),
    10,
  );
  const offset = Number.isFinite(offsetRaw) && offsetRaw > 0 ? offsetRaw : 0;

  let q = supa.from('pb_questions').select('*').eq('academy_id', academyId);
  if (documentId) q = q.eq('document_id', documentId);
  if (curriculumCode) q = q.eq('curriculum_code', curriculumCode);
  if (sourceTypeCode) q = q.eq('source_type_code', sourceTypeCode);
  if (gradeLabel) q = q.ilike('grade_label', `%${gradeLabel}%`);
  if (schoolName) q = q.ilike('school_name', `%${schoolName}%`);
  if (questionType) q = q.eq('question_type', questionType);
  if (Number.isFinite(examYear) && examYear > 0) q = q.eq('exam_year', examYear);

  q = q
    .order('created_at', { ascending: false })
    .range(offset, offset + limit - 1);

  const { data, error } = await q;
  if (error) {
    sendJson(res, 500, {
      ok: false,
      error: `question_list_failed:${error.message}`,
    });
    return;
  }

  sendJson(res, 200, {
    ok: true,
    questions: data || [],
    paging: { offset, limit },
  });
}

async function handler(req, res) {
  if (req.method === 'OPTIONS') {
    sendJson(res, 200, { ok: true });
    return;
  }

  if (!requireApiKey(req)) {
    sendJson(res, 401, { ok: false, error: 'invalid_api_key' });
    return;
  }

  const url = new URL(req.url || '/', `http://${req.headers.host || 'localhost'}`);
  const method = req.method || 'GET';

  try {
    if (method === 'GET' && url.pathname === '/health') {
      sendJson(res, 200, { ok: true, service: 'problem_bank_api' });
      return;
    }

    if (method === 'POST' && url.pathname === '/pb/jobs/extract') {
      const body = await readJson(req);
      await createExtractJob(body, res);
      return;
    }
    if (method === 'GET' && url.pathname === '/pb/jobs/extract') {
      await listExtractJobs(url, res);
      return;
    }
    if (method === 'POST' && /^\/pb\/jobs\/extract\/[^/]+\/retry$/.test(url.pathname)) {
      const jobId = url.pathname.split('/')[4];
      const body = await readJson(req);
      await retryExtractJob(jobId, body, res);
      return;
    }
    if (method === 'GET' && /^\/pb\/jobs\/extract\/[^/]+$/.test(url.pathname)) {
      const jobId = url.pathname.split('/')[4];
      await getExtractJob(jobId, url, res);
      return;
    }

    if (method === 'POST' && url.pathname === '/pb/jobs/figure') {
      const body = await readJson(req);
      await createFigureJob(body, res);
      return;
    }
    if (method === 'GET' && url.pathname === '/pb/jobs/figure') {
      await listFigureJobs(url, res);
      return;
    }
    if (method === 'POST' && /^\/pb\/jobs\/figure\/[^/]+\/retry$/.test(url.pathname)) {
      const jobId = url.pathname.split('/')[4];
      const body = await readJson(req);
      await retryFigureJob(jobId, body, res);
      return;
    }
    if (method === 'GET' && /^\/pb\/jobs\/figure\/[^/]+$/.test(url.pathname)) {
      const jobId = url.pathname.split('/')[4];
      await getFigureJob(jobId, url, res);
      return;
    }

    if (method === 'POST' && url.pathname === '/pb/jobs/export') {
      const body = await readJson(req);
      await createExportJob(body, res);
      return;
    }
    if (method === 'GET' && url.pathname === '/pb/jobs/export') {
      await listExportJobs(url, res);
      return;
    }
    if (method === 'POST' && /^\/pb\/jobs\/export\/[^/]+\/retry$/.test(url.pathname)) {
      const jobId = url.pathname.split('/')[4];
      const body = await readJson(req);
      await retryExportJob(jobId, body, res);
      return;
    }
    if (method === 'POST' && /^\/pb\/jobs\/export\/[^/]+\/cleanup$/.test(url.pathname)) {
      const jobId = url.pathname.split('/')[4];
      const body = await readJson(req);
      await cleanupExportArtifact(jobId, body, res);
      return;
    }
    if (method === 'GET' && /^\/pb\/jobs\/export\/[^/]+$/.test(url.pathname)) {
      const jobId = url.pathname.split('/')[4];
      await getExportJob(jobId, url, res);
      return;
    }

    if (method === 'GET' && url.pathname === '/pb/documents/summary') {
      await documentSummary(url, res);
      return;
    }

    if (method === 'GET' && url.pathname === '/pb/questions') {
      await listQuestions(url, res);
      return;
    }

    notFound(res);
  } catch (err) {
    sendJson(res, 500, {
      ok: false,
      error: 'internal_error',
      message: compact(err?.message || err),
    });
  }
}

const server = http.createServer((req, res) => {
  void handler(req, res);
});

server.listen(API_PORT, API_HOST, () => {
  console.log(
    '[pb-api] listening',
    JSON.stringify({
      host: API_HOST,
      port: API_PORT,
      apiKeyRequired: Boolean(API_KEY),
    }),
  );
});
