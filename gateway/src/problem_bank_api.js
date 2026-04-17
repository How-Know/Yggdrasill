import 'dotenv/config';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { createHash, randomUUID } from 'node:crypto';
import { execFile as execFileCb } from 'node:child_process';
import { promisify } from 'node:util';
import { URL, fileURLToPath } from 'node:url';
import { createClient } from '@supabase/supabase-js';
import sharp from 'sharp';
import { renderPdfWithXeLatex } from './problem_bank/render_engine/xelatex/renderer.js';

const __api_dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__api_dirname, '..', '..');

function resolveBatchPreviewFont() {
  const kopubPath = path.resolve(
    REPO_ROOT, 'apps', 'yggdrasill', 'assets', 'fonts', 'kopub',
    'KoPubWorldBatangProLight.otf',
  );
  if (fs.existsSync(kopubPath)) {
    return { family: 'KoPubWorldBatangPro', path: kopubPath };
  }
  const hcrPath = path.resolve(
    REPO_ROOT, 'apps', 'yggdrasill', 'assets', 'fonts', 'hancom',
    'HCRBatang.ttf',
  );
  if (fs.existsSync(hcrPath)) {
    return { family: 'HCRBatang', path: hcrPath };
  }
  return { family: 'Malgun Gothic', path: '' };
}

const execFileAsync = promisify(execFileCb);
import {
  generateQuestionPreviews,
  getStoredPreviewUrls,
  buildPreviewHtmlBatch,
  buildDocumentHtmlForPreview,
} from './problem_bank_preview_service.js';

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

function normalizeWhitespace(value) {
  return String(value || '').replace(/\s+/g, ' ').trim();
}

function normalizePresetDisplayName(raw, fallback = '') {
  const normalized = normalizeWhitespace(raw);
  const safeFallback = normalizeWhitespace(fallback);
  const value = normalized || safeFallback;
  if (!value) return '';
  return value.slice(0, 120);
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

function normalizeSemesterLabel(raw) {
  const value = String(raw || '').trim();
  if (value === '1학기' || value === '2학기') return value;
  return '';
}

function normalizeExamTermLabel(raw) {
  const value = String(raw || '').trim();
  if (value === '중간' || value === '기말') return value;
  return '';
}

function normalizePaper(raw) {
  const v = String(raw || '').trim().toUpperCase();
  if (v === 'A4' || v === 'B4' || v === '8\uC808') return v;
  if (v === '8K' || v === '8JEOL') return '8\uC808';
  return 'A4';
}

function normalizeMathEngine(raw) {
  const v = String(raw || '').trim().toLowerCase();
  return v === 'xelatex' ? 'xelatex' : 'mathjax-svg';
}

function normalizeNumeric(raw, fallback, min, max) {
  const n = Number.parseFloat(String(raw ?? ''));
  if (!Number.isFinite(n)) return fallback;
  return Math.min(max, Math.max(min, n));
}

function normalizeUuidListOrdered(raw) {
  if (!Array.isArray(raw)) return [];
  const seen = new Set();
  const out = [];
  for (const item of raw) {
    const id = String(item || '').trim();
    if (!isUuid(id) || seen.has(id)) continue;
    seen.add(id);
    out.push(id);
  }
  return out;
}

function normalizeJsonObject(raw, fallback = {}) {
  if (raw && typeof raw === 'object' && !Array.isArray(raw)) {
    return raw;
  }
  return fallback;
}

function normalizeJsonArray(raw, fallback = []) {
  if (Array.isArray(raw)) return raw;
  return fallback;
}

function chunkArray(input, chunkSize = 200) {
  const safeChunk = Number.isFinite(chunkSize) && chunkSize > 0 ? chunkSize : 200;
  if (!Array.isArray(input) || input.length === 0) return [];
  const out = [];
  for (let i = 0; i < input.length; i += safeChunk) {
    out.push(input.slice(i, i + safeChunk));
  }
  return out;
}

function normalizeLayoutColumns(raw) {
  const v = String(raw ?? '').trim();
  if (v === '2' || v === '2\uB2E8' || v.toLowerCase() === 'two') return 2;
  return 1;
}

function normalizeLayoutMode(raw) {
  const v = String(raw ?? '').trim().toLowerCase();
  if (v === 'custom_columns' || v === 'custom-columns' || v === 'custom') {
    return 'custom_columns';
  }
  return 'legacy';
}

function normalizeMaxQuestionsPerPage(raw, columns) {
  const defaults = columns === 2 ? 8 : 4;
  const parsed = Number.parseInt(String(raw ?? ''), 10);
  if (!Number.isFinite(parsed) || parsed <= 0) return defaults;
  const allowed = columns === 2 ? [1, 2, 4, 6, 8] : [1, 2, 3, 4];
  if (allowed.includes(parsed)) return parsed;
  return defaults;
}

function normalizeColumnQuestionCounts(raw, layoutColumns, maxQuestionsPerPage) {
  if (!Array.isArray(raw)) return [];
  const targetColumns = Math.max(1, Number(layoutColumns || 1));
  const counts = raw
    .slice(0, targetColumns)
    .map((one) => Number.parseInt(String(one ?? ''), 10))
    .filter((one) => Number.isFinite(one) && one > 0);
  if (counts.length !== targetColumns) return [];
  const total = counts.reduce((sum, one) => sum + one, 0);
  if (total <= 0) return [];
  if (Number.isFinite(maxQuestionsPerPage) && maxQuestionsPerPage > 0 && total !== maxQuestionsPerPage) {
    return [];
  }
  return counts;
}

function normalizePageColumnQuestionCounts(raw, layoutColumns) {
  if (!Array.isArray(raw)) return [];
  if (Number(layoutColumns || 1) !== 2) return [];
  const out = [];
  for (const one of raw) {
    if (!one || typeof one !== 'object') continue;
    const pageIndexRaw = Number.parseInt(
      String(one.pageIndex ?? one.page ?? one.pageNo ?? one.pageNumber ?? ''),
      10,
    );
    const leftRaw = Number.parseInt(
      String(one.left ?? one.leftCount ?? one.col1 ?? one.l ?? ''),
      10,
    );
    const rightRaw = Number.parseInt(
      String(one.right ?? one.rightCount ?? one.col2 ?? one.r ?? ''),
      10,
    );
    if (!Number.isFinite(leftRaw) || !Number.isFinite(rightRaw)) continue;
    if (leftRaw < 0 || rightRaw < 0) continue;
    const pageIndex = Number.isFinite(pageIndexRaw)
      ? Math.max(0, pageIndexRaw - 1)
      : out.length;
    if (leftRaw + rightRaw <= 0) continue;
    out.push({
      pageIndex: pageIndex + 1,
      left: leftRaw,
      right: rightRaw,
    });
  }
  const dedup = new Map();
  for (const one of out) {
    dedup.set(one.pageIndex, one);
  }
  return [...dedup.values()].sort((a, b) => a.pageIndex - b.pageIndex);
}

function normalizeTitlePageIndices(raw) {
  const out = new Set([1]);
  if (Array.isArray(raw)) {
    for (const one of raw) {
      const page = Number.parseInt(String(one ?? ''), 10);
      if (!Number.isFinite(page) || page < 1) continue;
      out.add(page);
    }
  }
  return [...out].sort((a, b) => a - b);
}

function normalizeTitlePageHeaders(raw, titlePageIndices, fallbackTitle = '수학 영역') {
  const titlePages = normalizeTitlePageIndices(titlePageIndices);
  const titlePageSet = new Set(titlePages);
  const out = new Map();
  if (Array.isArray(raw)) {
    for (const one of raw) {
      if (!one || typeof one !== 'object') continue;
      const page = Number.parseInt(
        String(one.page ?? one.pageIndex ?? one.pageNo ?? one.pageNumber ?? ''),
        10,
      );
      if (!Number.isFinite(page) || page < 1) continue;
      if (!titlePageSet.has(page)) continue;
      const title = String(one.title ?? one.subjectTitleText ?? '')
        .replace(/\s+/g, ' ')
        .trim();
      const subtitle = String(one.subtitle ?? one.subTitle ?? one.sub ?? '')
        .replace(/\s+/g, ' ')
        .trim();
      if (!title && !subtitle) continue;
      out.set(page, { page, title, subtitle });
    }
  }
  const defaultTitle = String(fallbackTitle || '수학 영역').replace(/\s+/g, ' ').trim() || '수학 영역';
  const pageOneTitle = out.get(1)?.title || defaultTitle;
  for (const page of titlePages) {
    const prev = out.get(page);
    const title = String(prev?.title || '').trim() || pageOneTitle;
    out.set(page, {
      page,
      title,
      subtitle: String(prev?.subtitle || '').replace(/\s+/g, ' ').trim(),
    });
  }
  return [...out.values()].sort((a, b) => a.page - b.page);
}

function normalizeCoverPageItems(rawItems, fallbackItems = []) {
  const src = Array.isArray(rawItems) ? rawItems : [];
  const out = [];
  for (const one of src) {
    if (!one || typeof one !== 'object') continue;
    const name = normalizeWhitespace(one.name || one.label || '');
    const pages = normalizeWhitespace(one.pages || one.pageRange || '');
    if (!name && !pages) continue;
    out.push({ name, pages });
    if (out.length >= 24) break;
  }
  if (out.length > 0) return out;
  return (Array.isArray(fallbackItems) ? fallbackItems : [])
    .map((one) => ({
      name: normalizeWhitespace(one?.name || one?.label || ''),
      pages: normalizeWhitespace(one?.pages || one?.pageRange || ''),
    }))
    .filter((one) => one.name || one.pages)
    .slice(0, 24);
}

function normalizeCoverPageTexts(raw, defaults = {}) {
  const src = raw && typeof raw === 'object' ? raw : {};
  const seed = defaults && typeof defaults === 'object' ? defaults : {};
  const defaultElectiveItemsSrc = Array.isArray(seed.electiveItems) ? seed.electiveItems : [];
  const defaultElectiveItems = [0, 1, 2].map((index) => {
    const item = defaultElectiveItemsSrc[index] && typeof defaultElectiveItemsSrc[index] === 'object'
      ? defaultElectiveItemsSrc[index]
      : {};
    const fallbackName =
      index === 0 ? '확률과 통계' : (index === 1 ? '미적분' : '기하');
    const fallbackPages =
      index === 0 ? '9~12쪽' : (index === 1 ? '13~16쪽' : '17~20쪽');
    return {
      name: normalizeWhitespace(item.name || fallbackName) || fallbackName,
      pages: normalizeWhitespace(item.pages || fallbackPages) || fallbackPages,
    };
  });
  const defaultCommonItems = Array.isArray(seed.commonItems)
    ? normalizeCoverPageItems(seed.commonItems, [])
    : [];
  const topTitle = normalizeWhitespace(
    src.topTitle || seed.topTitle || '2026학년도 대학수학능력시험 문제지',
  ) || '2026학년도 대학수학능력시험 문제지';
  const subjectTitle = normalizeWhitespace(
    src.subjectTitle || seed.subjectTitle || '수학 영역',
  ) || '수학 영역';
  const handwritingPhrase = normalizeWhitespace(
    src.handwritingPhrase || seed.handwritingPhrase || '이 많은 별빛이 내린 언덕 위에',
  ) || '이 많은 별빛이 내린 언덕 위에';
  const fallbackGroups = [
    {
      label: normalizeWhitespace(src.commonLabel || seed.commonLabel || '공통과목') || '공통과목',
      pageRange: normalizeWhitespace(
        src.commonPageRange || src.commonPages || seed.commonPageRange || '1~12쪽',
      ) || '1~12쪽',
      items: normalizeCoverPageItems(src.commonItems, defaultCommonItems),
    },
    {
      label: normalizeWhitespace(src.electiveLabel || seed.electiveLabel || '선택과목') || '선택과목',
      pageRange: normalizeWhitespace(
        src.electivePageRange || src.electivePages || seed.electivePageRange || '',
      ),
      items: normalizeCoverPageItems(src.electiveItems, defaultElectiveItems),
    },
  ];
  const hasExplicitGroups = Array.isArray(src.subjectGroups);
  let subjectGroups = [];
  if (hasExplicitGroups) {
    const rawGroups = Array.isArray(src.subjectGroups) ? src.subjectGroups : [];
    subjectGroups = rawGroups
      .filter((group) => group && typeof group === 'object')
      .map((group, index) => {
        const fallbackLabel = normalizeWhitespace(
          fallbackGroups[index]?.label || `대분류 ${index + 1}`,
        ) || `대분류 ${index + 1}`;
        return {
          label: normalizeWhitespace(group.label || '') || fallbackLabel,
          pageRange: normalizeWhitespace(group.pageRange || group.pages || ''),
          items: normalizeCoverPageItems(group.items, []),
        };
      })
      .slice(0, 24);
  } else {
    subjectGroups = fallbackGroups;
  }
  const commonGroup = subjectGroups[0] || fallbackGroups[0];
  const electiveGroup = subjectGroups[1] || fallbackGroups[1];
  const commonLabel = commonGroup.label || '공통과목';
  const commonPageRange = commonGroup.pageRange || '1~12쪽';
  const commonItems = normalizeCoverPageItems(commonGroup.items, defaultCommonItems);
  const electiveLabel = electiveGroup.label || '선택과목';
  const electivePageRange = normalizeWhitespace(electiveGroup.pageRange || '');
  const electiveItems = normalizeCoverPageItems(electiveGroup.items, defaultElectiveItems);
  const organization = normalizeWhitespace(
    src.organization || src.organizationName || seed.organization || '한국교육과정평가원',
  ) || '한국교육과정평가원';
  return {
    topTitle,
    subjectTitle,
    handwritingPhrase,
    commonLabel,
    commonPageRange,
    commonItems,
    electiveLabel,
    electivePageRange,
    electiveItems,
    subjectGroups,
    organization,
  };
}

function normalizeAnchorPage(raw) {
  const v = String(raw || '').trim().toLowerCase();
  if (!v || v === 'first' || v === '1') return 'first';
  if (v === 'all' || v === 'every') return 'all';
  const n = Number.parseInt(v, 10);
  if (Number.isFinite(n) && n >= 1) return n;
  return 'first';
}

function normalizeColumnLabelAnchors(raw, layoutColumns) {
  if (!Array.isArray(raw)) return [];
  const maxColumns = Math.max(1, Number(layoutColumns || 1));
  const out = [];
  for (const one of raw) {
    if (!one || typeof one !== 'object') continue;
    const columnIndex = Number.parseInt(String(one.columnIndex ?? ''), 10);
    if (!Number.isFinite(columnIndex) || columnIndex < 0 || columnIndex >= maxColumns) continue;
    const parsedRowIndex = Number.parseInt(String(one.rowIndex ?? ''), 10);
    const rowIndex = Number.isFinite(parsedRowIndex) && parsedRowIndex >= 0
      ? parsedRowIndex
      : 0;
    const label = String(one.label || one.text || '').replace(/\s+/g, ' ').trim();
    if (!label) continue;
    const topPt = Number.parseFloat(String(one.topPt ?? ''));
    const paddingTopPt = Number.parseFloat(String(one.paddingTopPt ?? ''));
    const sourceRaw = String(one.source || '').trim().toLowerCase();
    const source = sourceRaw === 'auto' ? 'auto' : 'manual';
    out.push({
      columnIndex,
      rowIndex,
      label,
      source,
      page: normalizeAnchorPage(one.page),
      topPt: Number.isFinite(topPt) ? topPt : 8,
      paddingTopPt: Number.isFinite(paddingTopPt) ? paddingTopPt : 46,
    });
  }
  return out;
}

function normalizeAlignPolicy(raw) {
  const src = raw && typeof raw === 'object' ? raw : {};
  const pairRaw = String(src.pairAlignment || src.pairMode || '').trim().toLowerCase();
  return {
    pairAlignment: pairRaw === 'none' ? 'none' : 'row',
    skipAnchorRows: src.skipAnchorRows !== false,
  };
}

function normalizeQuestionMode(raw) {
  const v = String(raw || '').trim().toLowerCase();
  if (v === 'objective' || v === '\uAC1D\uAD00\uC2DD' || v === 'mcq') return 'objective';
  if (v === 'subjective' || v === '\uC8FC\uAD00\uC2DD') return 'subjective';
  if (v === 'essay' || v === '\uC11C\uC220\uD615') return 'essay';
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

function normalizeQuestionScoreMap(raw, selectedIds, fallbackScores = {}) {
  const out = {};
  const src = raw && typeof raw === 'object' ? raw : {};
  const fallback = fallbackScores && typeof fallbackScores === 'object'
    ? fallbackScores
    : {};
  for (const id of selectedIds) {
    const candidate = src[id] ?? fallback[id];
    const parsed = Number.parseFloat(String(candidate ?? ''));
    if (!Number.isFinite(parsed) || parsed < 0) continue;
    out[id] = Math.min(999, parsed);
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

const EXPORT_RENDER_CONFIG_VERSION = 'pb_render_v43_bogi_figure_lift_span';
const DEFAULT_TITLE_PAGE_TOP_TEXT = '2026학년도 대학수학능력시험 문제지';

const QUESTION_COPY_SELECT_COLUMNS = [
  'id',
  'academy_id',
  'document_id',
  'source_page',
  'source_order',
  'question_number',
  'question_type',
  'stem',
  'choices',
  'figure_refs',
  'equations',
  'source_anchors',
  'confidence',
  'flags',
  'is_checked',
  'reviewed_by',
  'reviewed_at',
  'reviewer_notes',
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
  'allow_objective',
  'allow_subjective',
  'objective_choices',
  'objective_answer_key',
  'subjective_answer',
  'objective_generated',
].join(',');

function normalizeExportRenderConfig(options, selectedQuestionUids, defaults = {}) {
  const src = options && typeof options === 'object' ? options : {};
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
  const layoutMode = normalizeLayoutMode(src.layoutMode || defaults.layoutMode || 'legacy');
  const columnQuestionCounts = normalizeColumnQuestionCounts(
    src.columnQuestionCounts,
    layoutColumns,
    maxQuestionsPerPage,
  );
  const columnLabelAnchors = normalizeColumnLabelAnchors(
    src.columnLabelAnchors,
    layoutColumns,
  );
  const pageColumnQuestionCounts = normalizePageColumnQuestionCounts(
    src.pageColumnQuestionCounts || src.pageColumnCounts,
    layoutColumns,
  );
  const titlePageIndices = normalizeTitlePageIndices(
    src.titlePageIndices || src.titlePages,
  );
  const alignPolicy = normalizeAlignPolicy(src.alignPolicy);
  const questionMode = normalizeQuestionMode(
    src.questionMode || src.question_mode || src.mode || defaults.questionMode,
  );
  const selectedQuestionUidsOrdered = normalizeSelectedQuestionIdsOrdered(
    src.selectedQuestionUidsOrdered || src.selectedQuestionIdsOrdered,
    selectedQuestionUids,
  );
  const questionModeByQuestionUid = normalizeQuestionModeMap(
    src.questionModeByQuestionUid || src.questionModeByQuestionId,
    selectedQuestionUidsOrdered,
    questionMode,
  );
  const includeQuestionScore = normalizeBool(
    src.includeQuestionScore ?? src.includeScore,
    normalizeBool(defaults.includeQuestionScore, false),
  );
  const questionScoreByQuestionUid = normalizeQuestionScoreMap(
    src.questionScoreByQuestionUid || src.questionScoreByQuestionId,
    selectedQuestionUidsOrdered,
    defaults.questionScoreByQuestionUid || defaults.questionScoreByQuestionId,
  );
  const subjectTitleText =
    String(src.subjectTitleText || defaults.subjectTitleText || '\uC218\uD559 \uC601\uC5ED')
      .replace(/\s+/g, ' ')
      .trim() || '\uC218\uD559 \uC601\uC5ED';
  const titlePageTopText = String(
    src.titlePageTopText || defaults.titlePageTopText || DEFAULT_TITLE_PAGE_TOP_TEXT,
  )
    .replace(/\s+/g, ' ')
    .trim() || DEFAULT_TITLE_PAGE_TOP_TEXT;
  const timeLimitText = String(
    src.timeLimitText || src.examTimeLimitText || defaults.timeLimitText || '',
  )
    .replace(/\s+/g, ' ')
    .trim();
  const includeAcademyLogo = normalizeBool(
    src.includeAcademyLogo ?? src.showAcademyLogo,
    normalizeBool(defaults.includeAcademyLogo, false),
  );
  const includeCoverPage = normalizeBool(
    src.includeCoverPage ?? src.coverPage,
    normalizeBool(defaults.includeCoverPage, false),
  );
  const hidePreviewHeader = normalizeBool(
    src.hidePreviewHeader ?? src.hideDocumentHeader ?? src.previewHideHeader,
    normalizeBool(defaults.hidePreviewHeader, false),
  );
  const hideQuestionNumber = normalizeBool(
    src.hideQuestionNumber ?? src.previewHideQuestionNumber,
    normalizeBool(defaults.hideQuestionNumber, false),
  );
  const coverPageTexts = normalizeCoverPageTexts(
    src.coverPageTexts || src.coverTexts || src.coverPageTextConfig,
    defaults.coverPageTexts,
  );
  const titlePageHeaders = normalizeTitlePageHeaders(
    src.titlePageHeaders || src.titleHeaders,
    titlePageIndices,
    subjectTitleText,
  );
  return {
    // Force server-side renderer to latest stable path even if older app build
    // sends a stale renderConfigVersion.
    renderConfigVersion: EXPORT_RENDER_CONFIG_VERSION,
    layoutColumns,
    maxQuestionsPerPage,
    layoutMode,
    columnQuestionCounts,
    pageColumnQuestionCounts,
    columnLabelAnchors,
    titlePageIndices,
    titlePageHeaders,
    includeCoverPage,
    hidePreviewHeader,
    hideQuestionNumber,
    coverPageTexts,
    alignPolicy,
    questionMode,
    layoutTuning: normalizeLayoutTuning(src.layoutTuning, src),
    figureQuality: normalizeFigureQuality(src.figureQuality, src),
    subjectTitleText,
    titlePageTopText,
    timeLimitText,
    includeAcademyLogo,
    includeQuestionScore,
    questionScoreByQuestionUid,
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
    selectedQuestionUidsOrdered,
    questionModeByQuestionUid,
    // Legacy aliases kept during rollout.
    selectedQuestionIdsOrdered: selectedQuestionUidsOrdered,
    questionModeByQuestionId: questionModeByQuestionUid,
    questionScoreByQuestionId: questionScoreByQuestionUid,
    hideDocumentHeader: hidePreviewHeader,
    mathEngine: String(src.mathEngine || '').trim() || undefined,
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

function buildDerivedSourceFilename(sourceFilename) {
  const raw = String(sourceFilename || '').trim();
  if (!raw) return `saved_settings_${Date.now()}.hwpx`;
  const dotIndex = raw.lastIndexOf('.');
  const hasExt = dotIndex > 0 && dotIndex < raw.length - 1;
  const base = hasExt ? raw.slice(0, dotIndex) : raw;
  const ext = hasExt ? raw.slice(dotIndex) : '.hwpx';
  return `${base}_세팅저장${ext}`;
}

async function ensureDocumentBelongs(academyId, documentId) {
  const { data, error } = await supa
    .from('pb_documents')
    .select(
      [
        'id',
        'academy_id',
        'status',
        'source_filename',
        'source_storage_bucket',
        'source_storage_path',
        'source_sha256',
        'source_size_bytes',
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

function parseJsonObjectSafely(raw) {
  if (!raw) return {};
  if (typeof raw === 'string') {
    try {
      const parsed = JSON.parse(raw);
      return parsed && typeof parsed === 'object' && !Array.isArray(parsed)
        ? parsed
        : {};
    } catch (_) {
      return {};
    }
  }
  if (raw && typeof raw === 'object' && !Array.isArray(raw)) return raw;
  return {};
}

function buildRenderHashPayload({
  renderConfig,
  templateProfile,
  paperSize,
  includeAnswerSheet,
  includeExplanation,
}) {
  return {
    renderConfigVersion: renderConfig.renderConfigVersion,
    templateProfile,
    paperSize,
    includeAnswerSheet,
    includeExplanation,
    includeQuestionScore: renderConfig.includeQuestionScore === true,
    questionScoreByQuestionUid: renderConfig.questionScoreByQuestionUid,
    questionScoreByQuestionId: renderConfig.questionScoreByQuestionUid,
    includeCoverPage: renderConfig.includeCoverPage,
    hidePreviewHeader: renderConfig.hidePreviewHeader === true,
    hideQuestionNumber: renderConfig.hideQuestionNumber === true,
    coverPageTexts: renderConfig.coverPageTexts,
    layoutColumns: renderConfig.layoutColumns,
    maxQuestionsPerPage: renderConfig.maxQuestionsPerPage,
    layoutMode: renderConfig.layoutMode,
    columnQuestionCounts: renderConfig.columnQuestionCounts,
    pageColumnQuestionCounts: renderConfig.pageColumnQuestionCounts,
    columnLabelAnchors: renderConfig.columnLabelAnchors,
    titlePageIndices: renderConfig.titlePageIndices,
    titlePageHeaders: renderConfig.titlePageHeaders,
    alignPolicy: renderConfig.alignPolicy,
    subjectTitleText: renderConfig.subjectTitleText,
    titlePageTopText: renderConfig.titlePageTopText,
    timeLimitText: renderConfig.timeLimitText,
    includeAcademyLogo: renderConfig.includeAcademyLogo === true,
    questionMode: renderConfig.questionMode,
    font: renderConfig.font,
    layoutTuning: renderConfig.layoutTuning,
    figureQuality: renderConfig.figureQuality,
    selectedQuestionUidsOrdered: renderConfig.selectedQuestionUidsOrdered,
    selectedQuestionIdsOrdered: renderConfig.selectedQuestionUidsOrdered,
    questionModeByQuestionUid: renderConfig.questionModeByQuestionUid,
    questionModeByQuestionId: renderConfig.questionModeByQuestionUid,
    mathEngine: renderConfig.mathEngine,
  };
}

function buildExportOptions({
  rawOptions,
  sourceDocumentIds,
  renderConfig,
  templateProfile,
  paperSize,
  includeAnswerSheet,
  includeExplanation,
  renderHash,
  previewOnly,
}) {
  return {
    ...rawOptions,
    sourceDocumentIds,
    renderConfigVersion: renderConfig.renderConfigVersion,
    templateProfile,
    paperSize,
    includeAnswerSheet,
    includeExplanation,
    includeQuestionScore: renderConfig.includeQuestionScore === true,
    questionScoreByQuestionUid: renderConfig.questionScoreByQuestionUid,
    questionScoreByQuestionId: renderConfig.questionScoreByQuestionUid,
    includeCoverPage: renderConfig.includeCoverPage,
    hidePreviewHeader: renderConfig.hidePreviewHeader === true,
    hideQuestionNumber: renderConfig.hideQuestionNumber === true,
    coverPageTexts: renderConfig.coverPageTexts,
    layoutColumns: renderConfig.layoutColumns,
    maxQuestionsPerPage: renderConfig.maxQuestionsPerPage,
    layoutMode: renderConfig.layoutMode,
    columnQuestionCounts: renderConfig.columnQuestionCounts,
    pageColumnQuestionCounts: renderConfig.pageColumnQuestionCounts,
    columnLabelAnchors: renderConfig.columnLabelAnchors,
    titlePageIndices: renderConfig.titlePageIndices,
    titlePageHeaders: renderConfig.titlePageHeaders,
    alignPolicy: renderConfig.alignPolicy,
    subjectTitleText: renderConfig.subjectTitleText,
    titlePageTopText: renderConfig.titlePageTopText,
    timeLimitText: renderConfig.timeLimitText,
    includeAcademyLogo: renderConfig.includeAcademyLogo === true,
    questionMode: renderConfig.questionMode,
    layoutTuning: renderConfig.layoutTuning,
    figureQuality: renderConfig.figureQuality,
    font: renderConfig.font,
    selectedQuestionUidsOrdered: renderConfig.selectedQuestionUidsOrdered,
    selectedQuestionIdsOrdered: renderConfig.selectedQuestionUidsOrdered,
    questionModeByQuestionUid: renderConfig.questionModeByQuestionUid,
    questionModeByQuestionId: renderConfig.questionModeByQuestionUid,
    mathEngine: renderConfig.mathEngine,
    renderHash,
    previewOnly,
  };
}

async function insertExportJobWithFallback(payload) {
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
    throw new Error(`export_job_insert_failed:${error?.message || 'unknown'}`);
  }
  return job;
}

async function loadExistingPreviewJobsByRenderHashes(academyId, renderHashes) {
  const uniqueHashes = [...new Set(renderHashes.filter((h) => String(h || '').trim()))];
  const out = new Map();
  if (!uniqueHashes.length) return out;

  for (const hashChunk of chunkArray(uniqueHashes, 120)) {
    let rows = null;
    {
      const { data, error } = await supa
        .from('pb_exports')
        .select('*')
        .eq('academy_id', academyId)
        .eq('preview_only', true)
        .in('render_hash', hashChunk)
        .order('created_at', { ascending: false })
        .limit(Math.max(200, hashChunk.length * 4));
      if (error && /preview_only/i.test(String(error.message || ''))) {
        const fallback = await supa
          .from('pb_exports')
          .select('*')
          .eq('academy_id', academyId)
          .in('render_hash', hashChunk)
          .order('created_at', { ascending: false })
          .limit(Math.max(200, hashChunk.length * 4));
        if (fallback.error) {
          throw new Error(`preview_jobs_lookup_failed:${fallback.error.message}`);
        }
        rows = fallback.data || [];
      } else if (error) {
        throw new Error(`preview_jobs_lookup_failed:${error.message}`);
      } else {
        rows = data || [];
      }
    }

    for (const row of rows) {
      const hash = String(row?.render_hash || '').trim();
      if (!hash || out.has(hash)) continue;
      out.set(hash, row);
    }
  }
  return out;
}

async function createSignedStorageUrl(bucket, objectPath, expiresInSeconds = 60 * 30) {
  const safeBucket = String(bucket || '').trim();
  const safePath = String(objectPath || '').trim();
  if (!safeBucket || !safePath) return '';
  try {
    const { data, error } = await supa.storage
      .from(safeBucket)
      .createSignedUrl(safePath, expiresInSeconds);
    if (error) return '';
    return String(data?.signedUrl || '');
  } catch (_) {
    return '';
  }
}

function extractPreviewThumbnailMeta(summaryRaw) {
  const summary = parseJsonObjectSafely(summaryRaw);
  const fromObject = parseJsonObjectSafely(summary.previewThumbnail);
  const bucket = String(
    fromObject.bucket || summary.previewThumbnailBucket || '',
  ).trim();
  const path = String(
    fromObject.path || summary.previewThumbnailPath || '',
  ).trim();
  const url = String(
    fromObject.url || summary.previewThumbnailUrl || '',
  ).trim();
  const width = Number(fromObject.width || summary.previewThumbnailWidth || 0);
  const height = Number(fromObject.height || summary.previewThumbnailHeight || 0);
  const error = String(
    fromObject.error || summary.previewThumbnailError || '',
  ).trim();
  return {
    bucket,
    path,
    url,
    width: Number.isFinite(width) ? width : 0,
    height: Number.isFinite(height) ? height : 0,
    error,
  };
}

async function buildPdfArtifactFromJob(job) {
  const safeJob = job && typeof job === 'object' ? job : {};
  const status = String(safeJob.status || 'queued').trim().toLowerCase();
  const jobId = String(safeJob.id || '').trim();
  const summary = parseJsonObjectSafely(safeJob.result_summary);
  const options = parseJsonObjectSafely(safeJob.options);
  const previewOnly = safeJob.preview_only === true || options.previewOnly === true;

  let pdfUrl = String(safeJob.output_url || '').trim();
  const pdfBucket = String(safeJob.output_storage_bucket || '').trim();
  const pdfPath = String(safeJob.output_storage_path || '').trim();
  const refreshedPdfUrl = await createSignedStorageUrl(pdfBucket, pdfPath, 60 * 30);
  if (refreshedPdfUrl) pdfUrl = refreshedPdfUrl;

  const thumb = extractPreviewThumbnailMeta(summary);
  let thumbnailUrl = thumb.url;
  const refreshedThumbUrl = await createSignedStorageUrl(
    thumb.bucket,
    thumb.path,
    60 * 30,
  );
  if (refreshedThumbUrl) thumbnailUrl = refreshedThumbUrl;

  const errorMessage = String(
    safeJob.error_message || summary.error || thumb.error || '',
  ).trim();
  const effectiveStatus =
    status === 'completed' &&
    !String(thumbnailUrl || '').trim() &&
    errorMessage.length > 0
      ? 'failed'
      : (status || 'queued');
  return {
    jobId,
    status: effectiveStatus,
    previewOnly,
    pdfUrl,
    thumbnailUrl,
    thumbnailBucket: thumb.bucket,
    thumbnailPath: thumb.path,
    thumbnailWidth: thumb.width,
    thumbnailHeight: thumb.height,
    error: errorMessage,
  };
}

async function createExtractJob(body, res) {
  const academyId = String(body.academyId || '').trim();
  const documentId = String(body.documentId || '').trim();
  const createdBy = String(body.createdBy || '').trim();
  const rawTargetQuestionIds = Array.isArray(body.targetQuestionIds)
    ? body.targetQuestionIds.map((v) => String(v || '').trim()).filter(Boolean)
    : [];
  const invalidTargetQuestionIds = rawTargetQuestionIds.filter((v) => !isUuid(v));
  const safeTargetQuestionIds = Array.from(
    new Set(rawTargetQuestionIds.filter((v) => isUuid(v))),
  );
  if (!isUuid(academyId) || !isUuid(documentId)) {
    sendJson(res, 400, {
      ok: false,
      error: 'academyId/documentId must be uuid',
    });
    return;
  }
  if (invalidTargetQuestionIds.length > 0) {
    sendJson(res, 400, {
      ok: false,
      error: 'targetQuestionIds must be uuid[]',
    });
    return;
  }
  const doc = await ensureDocumentBelongs(academyId, documentId);
  if (!doc) {
    sendJson(res, 404, { ok: false, error: 'document_not_found' });
    return;
  }
  let targetQuestionIds = [];
  if (safeTargetQuestionIds.length > 0) {
    const { data: targets, error: targetErr } = await supa
      .from('pb_questions')
      .select('id')
      .eq('academy_id', academyId)
      .eq('document_id', documentId)
      .in('id', safeTargetQuestionIds);
    if (targetErr) {
      sendJson(res, 500, {
        ok: false,
        error: `target_question_lookup_failed:${targetErr.message}`,
      });
      return;
    }
    const matched = new Set((targets || []).map((row) => String(row.id || '').trim()));
    targetQuestionIds = safeTargetQuestionIds.filter((id) => matched.has(id));
    if (targetQuestionIds.length === 0) {
      sendJson(res, 404, { ok: false, error: 'target_questions_not_found' });
      return;
    }
  }
  const initialSummary = targetQuestionIds.length > 0
    ? {
        partialReextract: true,
        targetQuestionCount: targetQuestionIds.length,
        targetQuestionIds,
      }
    : {};

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
      source_version: targetQuestionIds.length > 0 ? 'api_v1_partial' : 'api_v1',
      result_summary: initialSummary,
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
  const oldSummary =
    oldJob && typeof oldJob.result_summary === 'object' && oldJob.result_summary
      ? oldJob.result_summary
      : {};
  const preservedTargetIds = Array.isArray(oldSummary.targetQuestionIds)
    ? Array.from(
        new Set(
          oldSummary.targetQuestionIds
            .map((v) => String(v || '').trim())
            .filter((v) => isUuid(v)),
        ),
      )
    : [];
  const retrySummary = preservedTargetIds.length > 0
    ? {
        partialReextract: true,
        targetQuestionCount: preservedTargetIds.length,
        targetQuestionIds: preservedTargetIds,
      }
    : {};
  const { data: updated, error: updErr } = await supa
    .from('pb_extract_jobs')
    .update({
      status: 'queued',
      error_code: '',
      error_message: '',
      result_summary: retrySummary,
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
      options: {
        ...(typeof body.options === 'object' && body.options ? body.options : {}),
        ...(forceRegenerate ? { forceRegenerate: true } : {}),
      },
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

  const selectedQuestionUidsRaw = normalizeUuidListOrdered(
    body.selectedQuestionUids || body.selectedQuestionIds,
  );
  let selectedQuestionUids = selectedQuestionUidsRaw;
  let selectedQuestionIds = [];
  let sourceDocumentIds = [];
  if (selectedQuestionUidsRaw.length > 0) {
    const { data: selectedRows, error: selectedErr } = await supa
      .from('pb_questions')
      .select('id,document_id,question_uid')
      .eq('academy_id', academyId)
      .in('question_uid', selectedQuestionUidsRaw);
    if (selectedErr) {
      sendJson(res, 500, {
        ok: false,
        error: `export_selected_question_uids_lookup_failed:${selectedErr.message}`,
      });
      return;
    }
    const rowByUid = new Map(
      (selectedRows || []).map((row) => [String(row.question_uid || ''), row]),
    );
    selectedQuestionUids = selectedQuestionUidsRaw.filter((uid) => rowByUid.has(uid));
    selectedQuestionIds = selectedQuestionUids
      .map((uid) => String(rowByUid.get(uid)?.id || '').trim())
      .filter((id) => isUuid(id));
    if (selectedQuestionUids.length === 0 || selectedQuestionIds.length === 0) {
      sendJson(res, 400, {
        ok: false,
        error: 'selected_question_uids_invalid',
      });
      return;
    }
    const seenDocIds = new Set();
    for (const uid of selectedQuestionUids) {
      const row = rowByUid.get(uid);
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
  const renderConfig = normalizeExportRenderConfig(rawOptions, selectedQuestionUids, {
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
    includeQuestionScore: renderConfig.includeQuestionScore === true,
    questionScoreByQuestionUid: renderConfig.questionScoreByQuestionUid,
    questionScoreByQuestionId: renderConfig.questionScoreByQuestionUid,
    includeCoverPage: renderConfig.includeCoverPage,
    coverPageTexts: renderConfig.coverPageTexts,
    layoutColumns: renderConfig.layoutColumns,
    maxQuestionsPerPage: renderConfig.maxQuestionsPerPage,
    layoutMode: renderConfig.layoutMode,
    columnQuestionCounts: renderConfig.columnQuestionCounts,
    pageColumnQuestionCounts: renderConfig.pageColumnQuestionCounts,
    columnLabelAnchors: renderConfig.columnLabelAnchors,
    titlePageIndices: renderConfig.titlePageIndices,
    titlePageHeaders: renderConfig.titlePageHeaders,
    alignPolicy: renderConfig.alignPolicy,
    subjectTitleText: renderConfig.subjectTitleText,
    titlePageTopText: renderConfig.titlePageTopText,
    timeLimitText: renderConfig.timeLimitText,
    includeAcademyLogo: renderConfig.includeAcademyLogo === true,
    questionMode: renderConfig.questionMode,
    font: renderConfig.font,
    layoutTuning: renderConfig.layoutTuning,
    figureQuality: renderConfig.figureQuality,
    selectedQuestionUidsOrdered: renderConfig.selectedQuestionUidsOrdered,
    selectedQuestionIdsOrdered: renderConfig.selectedQuestionUidsOrdered,
    questionModeByQuestionUid: renderConfig.questionModeByQuestionUid,
    questionModeByQuestionId: renderConfig.questionModeByQuestionUid,
    mathEngine: renderConfig.mathEngine,
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
    includeQuestionScore: renderConfig.includeQuestionScore === true,
    questionScoreByQuestionUid: renderConfig.questionScoreByQuestionUid,
    questionScoreByQuestionId: renderConfig.questionScoreByQuestionUid,
    includeCoverPage: renderConfig.includeCoverPage,
    coverPageTexts: renderConfig.coverPageTexts,
    layoutColumns: renderConfig.layoutColumns,
    maxQuestionsPerPage: renderConfig.maxQuestionsPerPage,
    layoutMode: renderConfig.layoutMode,
    columnQuestionCounts: renderConfig.columnQuestionCounts,
    pageColumnQuestionCounts: renderConfig.pageColumnQuestionCounts,
    columnLabelAnchors: renderConfig.columnLabelAnchors,
    titlePageIndices: renderConfig.titlePageIndices,
    titlePageHeaders: renderConfig.titlePageHeaders,
    alignPolicy: renderConfig.alignPolicy,
    subjectTitleText: renderConfig.subjectTitleText,
    titlePageTopText: renderConfig.titlePageTopText,
    timeLimitText: renderConfig.timeLimitText,
    includeAcademyLogo: renderConfig.includeAcademyLogo === true,
    questionMode: renderConfig.questionMode,
    layoutTuning: renderConfig.layoutTuning,
    figureQuality: renderConfig.figureQuality,
    font: renderConfig.font,
    selectedQuestionUidsOrdered: renderConfig.selectedQuestionUidsOrdered,
    selectedQuestionIdsOrdered: renderConfig.selectedQuestionUidsOrdered,
    questionModeByQuestionUid: renderConfig.questionModeByQuestionUid,
    questionModeByQuestionId: renderConfig.questionModeByQuestionUid,
    mathEngine: renderConfig.mathEngine,
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

function normalizeSignedUrlTtlSeconds(raw, fallbackSeconds = 60 * 15) {
  const parsed = Number.parseInt(String(raw ?? ''), 10);
  if (!Number.isFinite(parsed) || parsed <= 0) return fallbackSeconds;
  return Math.max(60, Math.min(60 * 60 * 24 * 7, parsed));
}

async function regenerateExportSignedUrl(exportJobId, url, res) {
  const academyId = String(url.searchParams.get('academyId') || '').trim();
  if (!isUuid(academyId) || !isUuid(exportJobId)) {
    sendJson(res, 400, { ok: false, error: 'academyId/exportJobId must be uuid' });
    return;
  }
  const ttlSeconds = normalizeSignedUrlTtlSeconds(url.searchParams.get('ttlSeconds'));
  const { data: job, error: jobErr } = await supa
    .from('pb_exports')
    .select('*')
    .eq('id', exportJobId)
    .eq('academy_id', academyId)
    .maybeSingle();
  if (jobErr) {
    sendJson(res, 500, { ok: false, error: `export_job_lookup_failed:${jobErr.message}` });
    return;
  }
  if (!job) {
    sendJson(res, 404, { ok: false, error: 'export_job_not_found' });
    return;
  }
  if (String(job.status || '').trim() !== 'completed') {
    sendJson(res, 409, { ok: false, error: 'export_job_not_completed' });
    return;
  }
  const bucket = String(job.output_storage_bucket || 'problem-exports').trim() || 'problem-exports';
  const path = String(job.output_storage_path || '').trim();
  if (!path) {
    sendJson(res, 409, { ok: false, error: 'export_output_path_empty' });
    return;
  }
  const { data: signed, error: signErr } = await supa.storage
    .from(bucket)
    .createSignedUrl(path, ttlSeconds);
  if (signErr) {
    sendJson(res, 500, { ok: false, error: `export_signed_url_failed:${signErr.message}` });
    return;
  }
  const signedUrl = String(signed?.signedUrl || '').trim();
  if (!signedUrl) {
    sendJson(res, 500, { ok: false, error: 'export_signed_url_empty' });
    return;
  }

  const nowIso = new Date().toISOString();
  const summary = normalizeJsonObject(job.result_summary, {});
  const issuedCountRaw = Number.parseInt(
    String(summary.signed_url_issued_count ?? summary.signedUrlIssuedCount ?? '0'),
    10,
  );
  const issuedCount = Number.isFinite(issuedCountRaw) && issuedCountRaw > 0
    ? issuedCountRaw + 1
    : 1;
  try {
    await supa
      .from('pb_exports')
      .update({
        updated_at: nowIso,
        result_summary: {
          ...summary,
          signed_url_issued_count: issuedCount,
          signed_url_last_issued_at: nowIso,
        },
      })
      .eq('id', exportJobId)
      .eq('academy_id', academyId);
  } catch (_) {
    // audit update best-effort
  }

  sendJson(res, 200, {
    ok: true,
    exportJobId,
    signedUrl,
    expiresInSeconds: ttlSeconds,
    outputStorageBucket: bucket,
    outputStoragePath: path,
  });
}

function isSavedSettingsDocumentMeta(rawMeta) {
  const meta = normalizeJsonObject(rawMeta, {});
  const saved = meta.saved_settings || meta.savedSettings;
  return saved && typeof saved === 'object';
}

async function cleanupLegacySavedSettings(body, res) {
  const academyId = String(body?.academyId || '').trim();
  if (!isUuid(academyId)) {
    sendJson(res, 400, { ok: false, error: 'academyId must be uuid' });
    return;
  }
  const dryRun = normalizeBool(body?.dryRun, true);
  const limit = normalizeLimit(body?.limit, 300, 5000);
  const { data: rows, error: listErr } = await supa
    .from('pb_documents')
    .select('id,source_filename,created_at,meta')
    .eq('academy_id', academyId)
    .order('created_at', { ascending: false })
    .limit(limit);
  if (listErr) {
    sendJson(res, 500, { ok: false, error: `legacy_documents_list_failed:${listErr.message}` });
    return;
  }
  const legacyDocs = (rows || [])
    .filter((row) => isSavedSettingsDocumentMeta(row?.meta))
    .map((row) => ({
      id: String(row?.id || '').trim(),
      sourceFilename: String(row?.source_filename || '').trim(),
      createdAt: row?.created_at || null,
    }))
    .filter((row) => isUuid(row.id));

  if (legacyDocs.length === 0) {
    sendJson(res, 200, {
      ok: true,
      dryRun,
      scanned: Number(rows?.length || 0),
      legacyDocumentCount: 0,
      deletedDocumentCount: 0,
      deletedPresetCount: 0,
      documents: [],
    });
    return;
  }

  if (dryRun) {
    sendJson(res, 200, {
      ok: true,
      dryRun: true,
      scanned: Number(rows?.length || 0),
      legacyDocumentCount: legacyDocs.length,
      deletedDocumentCount: 0,
      deletedPresetCount: 0,
      documents: legacyDocs,
    });
    return;
  }

  const legacyIds = legacyDocs.map((row) => row.id);
  let deletedPresetCount = 0;
  for (const idChunk of chunkArray(legacyIds, 200)) {
    const { data: deletedPresets } = await supa
      .from('pb_export_presets')
      .delete()
      .eq('academy_id', academyId)
      .in('document_id', idChunk)
      .select('id');
    deletedPresetCount += Number(Array.isArray(deletedPresets) ? deletedPresets.length : 0);
  }
  let deletedDocumentCount = 0;
  for (const idChunk of chunkArray(legacyIds, 150)) {
    const { data: deletedDocs, error: delErr } = await supa
      .from('pb_documents')
      .delete()
      .eq('academy_id', academyId)
      .in('id', idChunk)
      .select('id');
    if (delErr) {
      sendJson(res, 500, {
        ok: false,
        error: `legacy_documents_delete_failed:${delErr.message}`,
      });
      return;
    }
    deletedDocumentCount += Number(Array.isArray(deletedDocs) ? deletedDocs.length : 0);
  }

  sendJson(res, 200, {
    ok: true,
    dryRun: false,
    scanned: Number(rows?.length || 0),
    legacyDocumentCount: legacyDocs.length,
    deletedDocumentCount,
    deletedPresetCount,
    documents: legacyDocs,
  });
}

async function saveSettingsAsDocument(body, res) {
  const academyId = String(body.academyId || '').trim();
  const sourceDocumentId = String(body.sourceDocumentId || '').trim();
  const createdBy = String(body.createdBy || '').trim();
  const rawDisplayName = body.displayName;
  const rawRenderConfig = normalizeJsonObject(body.renderConfig, {});
  const selectedQuestionUidsOrderedInput = normalizeUuidListOrdered(
    body.selectedQuestionUidsOrdered || body.selectedQuestionUids,
  );
  const selectedQuestionIdsOrderedInput = normalizeUuidListOrdered(
    body.selectedQuestionIdsOrdered || body.selectedQuestionIds,
  );
  if (!isUuid(academyId) || !isUuid(sourceDocumentId)) {
    sendJson(res, 400, {
      ok: false,
      error: 'academyId/sourceDocumentId must be uuid',
    });
    return;
  }
  if (
    selectedQuestionUidsOrderedInput.length === 0
    && selectedQuestionIdsOrderedInput.length === 0
  ) {
    sendJson(res, 400, {
      ok: false,
      error: 'selectedQuestionUidsOrdered or selectedQuestionIdsOrdered must be uuid[]',
    });
    return;
  }

  const sourceDoc = await ensureDocumentBelongs(academyId, sourceDocumentId);
  if (!sourceDoc) {
    sendJson(res, 404, { ok: false, error: 'source_document_not_found' });
    return;
  }

  try {
    const sourceQuestionRowsByUid = new Map();
    const sourceQuestionRowsById = new Map();
    if (selectedQuestionUidsOrderedInput.length > 0) {
      for (const uidChunk of chunkArray(selectedQuestionUidsOrderedInput, 200)) {
        const { data: rows, error: rowErr } = await supa
          .from('pb_questions')
          .select('id,question_uid,document_id')
          .eq('academy_id', academyId)
          .in('question_uid', uidChunk);
        if (rowErr) {
          sendJson(res, 500, {
            ok: false,
            error: `save_settings_question_uid_lookup_failed:${rowErr.message}`,
          });
          return;
        }
        for (const row of rows || []) {
          const uid = String(row?.question_uid || '').trim();
          if (!isUuid(uid)) continue;
          sourceQuestionRowsByUid.set(uid, row);
        }
      }
    } else {
      for (const idChunk of chunkArray(selectedQuestionIdsOrderedInput, 200)) {
        const { data: rows, error: rowErr } = await supa
          .from('pb_questions')
          .select('id,question_uid,document_id')
          .eq('academy_id', academyId)
          .in('id', idChunk);
        if (rowErr) {
          sendJson(res, 500, {
            ok: false,
            error: `save_settings_question_id_lookup_failed:${rowErr.message}`,
          });
          return;
        }
        for (const row of rows || []) {
          const id = String(row?.id || '').trim();
          if (!isUuid(id)) continue;
          sourceQuestionRowsById.set(id, row);
        }
      }
    }

    const orderedSourceRows = [];
    const missingQuestionUids = [];
    const missingQuestionIds = [];
    if (selectedQuestionUidsOrderedInput.length > 0) {
      for (const uid of selectedQuestionUidsOrderedInput) {
        const row = sourceQuestionRowsByUid.get(uid);
        if (!row) {
          missingQuestionUids.push(uid);
          continue;
        }
        orderedSourceRows.push(row);
      }
    } else {
      for (const id of selectedQuestionIdsOrderedInput) {
        const row = sourceQuestionRowsById.get(id);
        if (!row) {
          missingQuestionIds.push(id);
          continue;
        }
        orderedSourceRows.push(row);
      }
    }
    if (missingQuestionUids.length > 0) {
      sendJson(res, 404, {
        ok: false,
        error: 'selected_question_uids_not_found',
        missingQuestionUids: missingQuestionUids,
      });
      return;
    }
    if (missingQuestionIds.length > 0) {
      sendJson(res, 404, {
        ok: false,
        error: 'selected_question_ids_not_found',
        missingQuestionIds: missingQuestionIds,
      });
      return;
    }
    if (orderedSourceRows.length === 0) {
      sendJson(res, 400, {
        ok: false,
        error: 'selected_questions_empty_after_validation',
      });
      return;
    }

    const selectedQuestionIdsOrdered = orderedSourceRows
      .map((row) => String(row?.id || '').trim())
      .filter((id) => isUuid(id));
    const selectedQuestionUidsOrdered = orderedSourceRows
      .map((row) => {
        const uid = String(row?.question_uid || '').trim();
        if (isUuid(uid)) return uid;
        return String(row?.id || '').trim();
      })
      .filter((uid) => isUuid(uid));
    const sourceQuestionDocIds = Array.from(
      new Set(
        orderedSourceRows
          .map((row) => String(row?.document_id || '').trim())
          .filter((id) => isUuid(id)),
      ),
    );
    const templateProfile = normalizeTemplateProfile(
      body.templateProfile || rawRenderConfig.templateProfile,
    );
    const paperSize = normalizePaper(
      body.paperSize || rawRenderConfig.paperSize || 'A4',
    );
    const includeAnswerSheet = normalizeBool(
      body.includeAnswerSheet ?? rawRenderConfig.includeAnswerSheet,
      true,
    );
    const includeExplanation = normalizeBool(
      body.includeExplanation ?? rawRenderConfig.includeExplanation,
      false,
    );
    const includeQuestionScore = normalizeBool(
      body.includeQuestionScore ?? rawRenderConfig.includeQuestionScore,
      false,
    );
    const fallbackQuestionMode = normalizeQuestionMode(
      body.questionMode || rawRenderConfig.questionMode || 'original',
    );
    const sourceQuestionModeByQuestionUid = normalizeQuestionModeMap(
      body.questionModeByQuestionUid || body.questionModeByQuestionId,
      selectedQuestionUidsOrdered,
      fallbackQuestionMode,
    );
    const sourceQuestionScoreByQuestionUid = normalizeQuestionScoreMap(
      body.questionScoreByQuestionUid
        || body.questionScoreByQuestionId
        || rawRenderConfig.questionScoreByQuestionUid
        || rawRenderConfig.questionScoreByQuestionId,
      selectedQuestionUidsOrdered,
    );

    const normalizedRenderConfig = normalizeExportRenderConfig(
      {
        ...rawRenderConfig,
        questionMode: fallbackQuestionMode,
        selectedQuestionUidsOrdered,
        questionModeByQuestionUid: sourceQuestionModeByQuestionUid,
        includeQuestionScore,
        questionScoreByQuestionUid: sourceQuestionScoreByQuestionUid,
      },
      selectedQuestionUidsOrdered,
      {
        questionMode: fallbackQuestionMode,
        subjectTitleText:
          String(rawRenderConfig.subjectTitleText || '').trim() || '수학 영역',
        titlePageTopText:
          String(rawRenderConfig.titlePageTopText || '').replace(/\s+/g, ' ').trim()
            || DEFAULT_TITLE_PAGE_TOP_TEXT,
        timeLimitText:
          String(rawRenderConfig.timeLimitText || rawRenderConfig.examTimeLimitText || '')
            .replace(/\s+/g, ' ')
            .trim(),
        includeAcademyLogo: normalizeBool(rawRenderConfig.includeAcademyLogo, false),
        includeCoverPage: normalizeBool(rawRenderConfig.includeCoverPage, false),
        coverPageTexts: normalizeJsonObject(rawRenderConfig.coverPageTexts, {}),
        includeQuestionScore,
        questionScoreByQuestionUid: sourceQuestionScoreByQuestionUid,
      },
    );

    const renderConfig = {
      ...normalizedRenderConfig,
      templateProfile,
      paperSize,
      includeAnswerSheet,
      includeExplanation,
      includeQuestionScore,
      selectedQuestionUidsOrdered,
      questionModeByQuestionUid: sourceQuestionModeByQuestionUid,
      questionScoreByQuestionUid: sourceQuestionScoreByQuestionUid,
      // Legacy aliases kept during rollout.
      selectedQuestionIdsOrdered: selectedQuestionUidsOrdered,
      questionModeByQuestionId: sourceQuestionModeByQuestionUid,
      questionScoreByQuestionId: sourceQuestionScoreByQuestionUid,
    };
    const presetDisplayName = normalizePresetDisplayName(
      rawDisplayName,
      String(sourceDoc.source_filename || '').trim() || '문제은행 프리셋',
    );

    const { data: preset, error: presetErr } = await supa
      .from('pb_export_presets')
      .insert({
        academy_id: academyId,
        source_document_id: sourceDocumentId,
        document_id: null,
        source_document_ids: sourceQuestionDocIds,
        render_config: renderConfig,
        selected_question_uids: selectedQuestionUidsOrdered,
        selected_question_ids: selectedQuestionIdsOrdered,
        question_mode_by_question_uid: sourceQuestionModeByQuestionUid,
        question_mode_by_question_id: sourceQuestionModeByQuestionUid,
        display_name: presetDisplayName,
        created_by: isUuid(createdBy) ? createdBy : null,
      })
      .select('*')
      .maybeSingle();
    if (presetErr || !preset) {
      throw new Error(
        `save_settings_preset_save_failed:${presetErr?.message || 'unknown'}`,
      );
    }

    sendJson(res, 201, {
      ok: true,
      preset,
      copiedQuestionCount: 0,
      selectedQuestionIds: selectedQuestionIdsOrdered,
      selectedQuestionUids: selectedQuestionUidsOrdered,
      sourceDocumentIds: sourceQuestionDocIds,
      sourceDocumentId,
      mode: 'reference_preset',
    });
  } catch (err) {
    sendJson(res, 500, {
      ok: false,
      error: `save_settings_failed:${compact(err?.message || err, 400)}`,
    });
  }
}

async function getDocumentExportPreset(documentId, url, res) {
  const academyId = String(url.searchParams.get('academyId') || '').trim();
  if (!isUuid(documentId) || !isUuid(academyId)) {
    sendJson(res, 400, { ok: false, error: 'documentId/academyId must be uuid' });
    return;
  }
  const doc = await ensureDocumentBelongs(academyId, documentId);
  if (!doc) {
    sendJson(res, 404, { ok: false, error: 'document_not_found' });
    return;
  }
  const { data, error } = await supa
    .from('pb_export_presets')
    .select('*')
    .eq('academy_id', academyId)
    .or(
      [
        `source_document_id.eq.${documentId}`,
        `source_document_ids.cs.{${documentId}}`,
      ].join(','),
    )
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();
  if (error) {
    sendJson(res, 500, { ok: false, error: `export_preset_get_failed:${error.message}` });
    return;
  }
  sendJson(res, 200, { ok: true, preset: data || null });
}

async function listExportPresets(url, res) {
  const academyId = String(url.searchParams.get('academyId') || '').trim();
  if (!isUuid(academyId)) {
    sendJson(res, 400, { ok: false, error: 'academyId must be uuid' });
    return;
  }
  const limit = normalizeLimit(url.searchParams.get('limit'), 100, 500);
  const offsetRaw = Number.parseInt(
    String(url.searchParams.get('offset') || '0'),
    10,
  );
  const offset = Number.isFinite(offsetRaw) && offsetRaw > 0 ? offsetRaw : 0;

  const { data: rows, error } = await supa
    .from('pb_export_presets')
    .select(
      [
        'id',
        'academy_id',
        'source_document_id',
        'source_document_ids',
        'document_id',
        'display_name',
        'render_config',
        'selected_question_uids',
        'selected_question_ids',
        'question_mode_by_question_uid',
        'question_mode_by_question_id',
        'created_at',
        'updated_at',
      ].join(','),
    )
    .eq('academy_id', academyId)
    .order('created_at', { ascending: false })
    .range(offset, offset + limit - 1);
  if (error) {
    sendJson(res, 500, { ok: false, error: `export_presets_list_failed:${error.message}` });
    return;
  }

  const documentIds = Array.from(
    new Set(
      (rows || [])
        .flatMap((row) => [
          String(row?.source_document_id || '').trim(),
          ...(Array.isArray(row?.source_document_ids)
            ? row.source_document_ids.map((one) => String(one || '').trim())
            : []),
          String(row?.document_id || '').trim(),
        ])
        .filter((id) => isUuid(id)),
    ),
  );
  const documentNameMap = new Map();
  for (const chunk of chunkArray(documentIds, 250)) {
    const { data: docs, error: docErr } = await supa
      .from('pb_documents')
      .select('id,source_filename')
      .eq('academy_id', academyId)
      .in('id', chunk);
    if (docErr) {
      sendJson(res, 500, {
        ok: false,
        error: `export_presets_document_lookup_failed:${docErr.message}`,
      });
      return;
    }
    for (const doc of docs || []) {
      const id = String(doc?.id || '').trim();
      if (!isUuid(id)) continue;
      documentNameMap.set(id, String(doc?.source_filename || '').trim());
    }
  }

  const presets = (rows || []).map((row) => {
    const sourceDocumentId = String(row?.source_document_id || '').trim();
    const sourceDocumentIds = Array.isArray(row?.source_document_ids)
      ? row.source_document_ids
        .map((one) => String(one || '').trim())
        .filter((id) => isUuid(id))
      : [];
    const documentId = String(row?.document_id || '').trim();
    const renderConfig = normalizeJsonObject(row?.render_config, {});
    const selectedQuestionUids = Array.isArray(row?.selected_question_uids)
      ? row.selected_question_uids
      : [];
    const selectedQuestionIds = Array.isArray(row?.selected_question_ids)
      ? row.selected_question_ids
      : [];
    const fallbackName = documentNameMap.get(sourceDocumentId)
      || documentNameMap.get(sourceDocumentIds[0])
      || documentNameMap.get(documentId)
      || `세팅저장 ${String(row?.created_at || '').slice(0, 10)}`;
    const questionModeByQuestionUid = normalizeJsonObject(
      row?.question_mode_by_question_uid || row?.question_mode_by_question_id,
      {},
    );
    return {
      id: String(row?.id || '').trim(),
      academyId: String(row?.academy_id || '').trim(),
      sourceDocumentId,
      sourceDocumentIds,
      documentId,
      displayName: normalizePresetDisplayName(row?.display_name, fallbackName),
      sourceDocumentName:
        documentNameMap.get(sourceDocumentId)
        || documentNameMap.get(sourceDocumentIds[0])
        || '',
      documentName: documentNameMap.get(documentId) || '',
      selectedQuestionUids,
      selectedQuestionIds: selectedQuestionUids,
      selectedQuestionCount: selectedQuestionUids.length || selectedQuestionIds.length,
      renderConfig,
      questionModeByQuestionUid,
      questionModeByQuestionId: questionModeByQuestionUid,
      templateProfile: String(renderConfig.templateProfile || '').trim(),
      paperSize: String(renderConfig.paperSize || '').trim(),
      includeAnswerSheet: renderConfig.includeAnswerSheet === true,
      includeExplanation: renderConfig.includeExplanation === true,
      includeQuestionScore: renderConfig.includeQuestionScore === true,
      includeAcademyLogo: renderConfig.includeAcademyLogo === true,
      createdAt: row?.created_at || null,
      updatedAt: row?.updated_at || null,
    };
  });

  sendJson(res, 200, {
    ok: true,
    presets,
    paging: { offset, limit },
  });
}

async function renameExportPreset(presetId, body, res) {
  const academyId = String(body?.academyId || '').trim();
  const displayName = normalizePresetDisplayName(body?.displayName);
  if (!isUuid(academyId) || !isUuid(presetId)) {
    sendJson(res, 400, { ok: false, error: 'academyId/presetId must be uuid' });
    return;
  }
  if (!displayName) {
    sendJson(res, 400, { ok: false, error: 'displayName required' });
    return;
  }

  const { data: preset, error: presetErr } = await supa
    .from('pb_export_presets')
    .update({
      display_name: displayName,
      updated_at: new Date().toISOString(),
    })
    .eq('id', presetId)
    .eq('academy_id', academyId)
    .select('*')
    .maybeSingle();
  if (presetErr) {
    sendJson(res, 500, {
      ok: false,
      error: `export_preset_rename_failed:${presetErr.message}`,
    });
    return;
  }
  if (!preset) {
    sendJson(res, 404, { ok: false, error: 'export_preset_not_found' });
    return;
  }

  sendJson(res, 200, { ok: true, preset });
}

async function deleteExportPreset(presetId, body, res) {
  const academyId = String(body?.academyId || '').trim();
  if (!isUuid(academyId) || !isUuid(presetId)) {
    sendJson(res, 400, { ok: false, error: 'academyId/presetId must be uuid' });
    return;
  }
  const { data, error } = await supa
    .from('pb_export_presets')
    .delete()
    .eq('academy_id', academyId)
    .eq('id', presetId)
    .select('id')
    .limit(1);
  if (error) {
    sendJson(res, 500, {
      ok: false,
      error: `export_preset_delete_failed:${error.message}`,
    });
    return;
  }
  if (!Array.isArray(data) || data.length === 0) {
    sendJson(res, 404, { ok: false, error: 'export_preset_not_found' });
    return;
  }
  sendJson(res, 200, { ok: true, deletedPresetId: presetId });
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

async function previewQuestions(res, req) {
  let body;
  try { body = await readJson(req); } catch (_) {
    sendJson(res, 400, { ok: false, error: 'invalid_json' });
    return;
  }

  const academyId = String(body?.academyId || '').trim();
  const questionIds = Array.isArray(body?.questionIds) ? body.questionIds.map(String) : [];
  const layout = body?.layout || {};
  const force = body?.force === true;
  const mathEngine = body?.mathEngine || undefined;

  if (!academyId || questionIds.length === 0) {
    sendJson(res, 400, { ok: false, error: 'academyId and questionIds[] required' });
    return;
  }

  const { data: rows, error: fetchErr } = await supa
    .from('pb_questions')
    .select('*')
    .eq('academy_id', academyId)
    .in('id', questionIds);

  if (fetchErr) {
    sendJson(res, 500, { ok: false, error: `fetch_failed:${fetchErr.message}` });
    return;
  }

  try {
    const previews = await generateQuestionPreviews({
      questions: rows || [],
      academyId,
      layout,
      supabaseClient: supa,
      force,
      mathEngine,
    });
    sendJson(res, 200, { ok: true, previews });
  } catch (err) {
    sendJson(res, 500, { ok: false, error: `preview_failed:${compact(err?.message || err)}` });
  }
}

async function previewHtml(res, req) {
  let body;
  try { body = await readJson(req); } catch (_) {
    sendJson(res, 400, { ok: false, error: 'invalid_json' });
    return;
  }

  const academyId = String(body?.academyId || '').trim();
  const questionIds = Array.isArray(body?.questionIds) ? body.questionIds.map(String) : [];
  const layout = body?.layout || {};
  const mode = String(body?.mode || 'single');

  if (mode === 'document') {
    try {
      const { data: rows, error: fetchErr } = await supa
        .from('pb_questions')
        .select('*')
        .eq('academy_id', academyId)
        .in('id', questionIds);
      if (fetchErr) {
        sendJson(res, 500, { ok: false, error: `fetch_failed:${fetchErr.message}` });
        return;
      }
      const html = await buildDocumentHtmlForPreview({
        questions: rows || [],
        renderConfig: body?.renderConfig || {},
        profile: body?.profile || 'naesin',
        paper: body?.paper || 'B4',
        baseLayout: body?.baseLayout || {},
        maxQuestionsPerPage: body?.maxQuestionsPerPage || 4,
        supabaseClient: supa,
      });
      sendJson(res, 200, { ok: true, html });
    } catch (err) {
      sendJson(res, 500, { ok: false, error: `html_failed:${compact(err?.message || err)}` });
    }
    return;
  }

  if (!academyId || questionIds.length === 0) {
    sendJson(res, 400, { ok: false, error: 'academyId and questionIds[] required' });
    return;
  }

  const { data: rows, error: fetchErr } = await supa
    .from('pb_questions')
    .select('*')
    .eq('academy_id', academyId)
    .in('id', questionIds);

  if (fetchErr) {
    sendJson(res, 500, { ok: false, error: `fetch_failed:${fetchErr.message}` });
    return;
  }

  try {
    const results = await buildPreviewHtmlBatch({
      questions: rows || [],
      layout,
      supabaseClient: supa,
    });
    sendJson(res, 200, { ok: true, questions: results });
  } catch (err) {
    sendJson(res, 500, { ok: false, error: `html_failed:${compact(err?.message || err)}` });
  }
}

async function previewUrls(res, req) {
  let body;
  try { body = await readJson(req); } catch (_) {
    sendJson(res, 400, { ok: false, error: 'invalid_json' });
    return;
  }

  const academyId = String(body?.academyId || '').trim();
  const questionIds = Array.isArray(body?.questionIds) ? body.questionIds.map(String) : [];

  if (!academyId || questionIds.length === 0) {
    sendJson(res, 400, { ok: false, error: 'academyId and questionIds[] required' });
    return;
  }

  const { data: rows, error: fetchErr } = await supa
    .from('pb_questions')
    .select('id,stem,choices,equations,figure_refs,meta')
    .eq('academy_id', academyId)
    .in('id', questionIds);

  if (fetchErr) {
    sendJson(res, 500, { ok: false, error: `fetch_failed:${fetchErr.message}` });
    return;
  }

  try {
    const previews = await getStoredPreviewUrls({
      questions: rows || [],
      academyId,
      supabaseClient: supa,
    });
    sendJson(res, 200, { ok: true, previews });
  } catch (err) {
    sendJson(res, 500, { ok: false, error: `urls_failed:${compact(err?.message || err)}` });
  }
}

function inferQuestionModeFromRow(row) {
  const rawType = String(row?.question_type || row?.questionType || '')
    .replace(/\s+/g, '')
    .toLowerCase();
  if (rawType.includes('서술') || rawType.includes('essay')) return 'essay';
  if (rawType.includes('객관') || rawType.includes('objective')) return 'objective';
  if (rawType.includes('주관') || rawType.includes('subjective')) return 'subjective';
  const choices = Array.isArray(row?.choices) ? row.choices : [];
  return choices.length >= 2 ? 'objective' : 'subjective';
}

async function previewPdfArtifacts(res, req) {
  let body;
  try {
    body = await readJson(req);
  } catch (_) {
    sendJson(res, 400, { ok: false, error: 'invalid_json' });
    return;
  }

  const academyId = String(body?.academyId || '').trim();
  const rawQuestionIds = Array.isArray(body?.questionIds)
    ? body.questionIds.map((v) => String(v || '').trim())
    : [];
  const invalidQuestionIds = rawQuestionIds.filter((id) => !isUuid(id));
  const questionIds = normalizeUuidListOrdered(rawQuestionIds);
  const requestedDocumentId = String(body?.documentId || '').trim();
  const createJobs = body?.createJobs !== false;

  if (!isUuid(academyId) || questionIds.length === 0) {
    sendJson(res, 400, {
      ok: false,
      error: 'academyId must be uuid and questionIds[] must be non-empty',
    });
    return;
  }
  if (invalidQuestionIds.length > 0) {
    sendJson(res, 400, { ok: false, error: 'questionIds must be uuid[]' });
    return;
  }
  if (requestedDocumentId && !isUuid(requestedDocumentId)) {
    sendJson(res, 400, { ok: false, error: 'documentId must be uuid' });
    return;
  }
  if (requestedDocumentId) {
    const doc = await ensureDocumentBelongs(academyId, requestedDocumentId);
    if (!doc) {
      sendJson(res, 404, { ok: false, error: 'document_not_found' });
      return;
    }
  }

  const { data: questionRowsById, error: fetchErr } = await supa
    .from('pb_questions')
    .select('id,question_uid,document_id,question_type,choices')
    .eq('academy_id', academyId)
    .in('id', questionIds);
  if (fetchErr) {
    sendJson(res, 500, { ok: false, error: `fetch_failed:${fetchErr.message}` });
    return;
  }

  let questionRows = questionRowsById || [];
  const foundById = new Set(questionRows.map((r) => String(r?.id || '').trim()));
  const missingByIdIds = questionIds.filter((id) => !foundById.has(id));
  if (missingByIdIds.length > 0) {
    const { data: byUidRows } = await supa
      .from('pb_questions')
      .select('id,question_uid,document_id,question_type,choices')
      .eq('academy_id', academyId)
      .in('question_uid', missingByIdIds);
    if (byUidRows && byUidRows.length > 0) {
      questionRows = [...questionRows, ...byUidRows];
    }
  }

  const rowById = new Map();
  for (const row of questionRows) {
    const id = String(row?.id || '').trim();
    const uid = String(row?.question_uid || '').trim();
    if (id) rowById.set(id, row);
    if (uid && uid !== id) rowById.set(uid, row);
  }
  const baseOptions = {
    ...normalizeJsonObject(body?.options, {}),
    ...normalizeJsonObject(body?.renderConfig, {}),
    ...normalizeJsonObject(body?.layout, {}),
  };
  const templateProfile = normalizeTemplateProfile(
    body?.templateProfile || body?.profile || baseOptions.templateProfile,
  );
  const paperSize = normalizePaper(
    body?.paperSize || body?.paper || baseOptions.paperSize || baseOptions.paper,
  );
  const includeAnswerSheet = normalizeBool(
    body?.includeAnswerSheet ?? baseOptions.includeAnswerSheet,
    false,
  );
  const includeExplanation = normalizeBool(
    body?.includeExplanation ?? baseOptions.includeExplanation,
    false,
  );
  const forcedMathEngine = normalizeMathEngine(
    body?.mathEngine || baseOptions.mathEngine || 'xelatex',
  );

  const descriptors = [];
  const immediateArtifacts = [];
  for (const questionId of questionIds) {
    const row = rowById.get(questionId);
    if (!row) {
      immediateArtifacts.push({
        questionId,
        questionUid: '',
        status: 'failed',
        jobId: '',
        previewOnly: true,
        pdfUrl: '',
        thumbnailUrl: '',
        thumbnailBucket: '',
        thumbnailPath: '',
        thumbnailWidth: 0,
        thumbnailHeight: 0,
        error: 'question_not_found',
      });
      continue;
    }
    const questionUid = String(row?.question_uid || row?.id || '').trim();
    const questionDocumentId = String(row?.document_id || '').trim();
    if (!questionUid || !questionDocumentId) {
      immediateArtifacts.push({
        questionId,
        questionUid,
        status: 'failed',
        jobId: '',
        previewOnly: true,
        pdfUrl: '',
        thumbnailUrl: '',
        thumbnailBucket: '',
        thumbnailPath: '',
        thumbnailWidth: 0,
        thumbnailHeight: 0,
        error: 'invalid_question_row',
      });
      continue;
    }
    if (requestedDocumentId && requestedDocumentId !== questionDocumentId) {
      immediateArtifacts.push({
        questionId,
        questionUid,
        status: 'failed',
        jobId: '',
        previewOnly: true,
        pdfUrl: '',
        thumbnailUrl: '',
        thumbnailBucket: '',
        thumbnailPath: '',
        thumbnailWidth: 0,
        thumbnailHeight: 0,
        error: 'question_document_mismatch',
      });
      continue;
    }

    const inferredMode = inferQuestionModeFromRow(row);
    const selectedQuestionUids = [questionUid];
    const sourceDocumentIds = [questionDocumentId];
    const optionsForRender = {
      ...baseOptions,
      questionMode: baseOptions.questionMode || baseOptions.question_mode || inferredMode,
      layoutColumns:
        baseOptions.layoutColumns ||
        baseOptions.layout_columns ||
        baseOptions.columns ||
        (templateProfile === 'mock' || templateProfile === 'csat' ? 2 : 1),
      maxQuestionsPerPage:
        baseOptions.maxQuestionsPerPage ||
        baseOptions.max_questions_per_page ||
        baseOptions.perPage ||
        baseOptions.questionsPerPage ||
        4,
      includeCoverPage: false,
      includeAcademyLogo: false,
      hidePreviewHeader: true,
      hideQuestionNumber: true,
      includeAnswerSheet,
      includeExplanation,
      mathEngine: forcedMathEngine,
    };
    const renderConfig = normalizeExportRenderConfig(optionsForRender, selectedQuestionUids, {
      questionMode: optionsForRender.questionMode,
      layoutColumns: optionsForRender.layoutColumns,
      maxQuestionsPerPage: optionsForRender.maxQuestionsPerPage,
    });
    if (!renderConfig.mathEngine) {
      renderConfig.mathEngine = forcedMathEngine;
    }
    const renderHash = computeRenderHash(
      buildRenderHashPayload({
        renderConfig,
        templateProfile,
        paperSize,
        includeAnswerSheet,
        includeExplanation,
      }),
    );
    const options = buildExportOptions({
      rawOptions: optionsForRender,
      sourceDocumentIds,
      renderConfig,
      templateProfile,
      paperSize,
      includeAnswerSheet,
      includeExplanation,
      renderHash,
      previewOnly: true,
    });

    descriptors.push({
      questionId,
      questionUid,
      renderHash,
      payload: {
        academy_id: academyId,
        document_id: questionDocumentId,
        requested_by: null,
        status: 'queued',
        template_profile: templateProfile,
        paper_size: paperSize,
        include_answer_sheet: includeAnswerSheet,
        include_explanation: includeExplanation,
        selected_question_ids: [questionId],
        render_hash: renderHash,
        preview_only: true,
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
      },
    });
  }

  const existingByHash = await loadExistingPreviewJobsByRenderHashes(
    academyId,
    descriptors.map((one) => one.renderHash),
  );
  const artifacts = [...immediateArtifacts];
  for (const one of descriptors) {
    let job = existingByHash.get(one.renderHash) || null;
    const status = String(job?.status || '').trim().toLowerCase();
    const existingThumb = extractPreviewThumbnailMeta(job?.result_summary);
    const completedThumbBroken =
      status === 'completed'
      && !existingThumb.path
      && !existingThumb.url
      && String(existingThumb.error || '').trim().length > 0;
    const shouldCreateNew =
      !job ||
      status === 'failed' ||
      status === 'cancelled' ||
      status === 'error' ||
      completedThumbBroken;
    if (shouldCreateNew && createJobs) {
      try {
        job = await insertExportJobWithFallback(one.payload);
      } catch (err) {
        artifacts.push({
          questionId: one.questionId,
          questionUid: one.questionUid,
          status: 'failed',
          jobId: '',
          previewOnly: true,
          pdfUrl: '',
          thumbnailUrl: '',
          thumbnailBucket: '',
          thumbnailPath: '',
          thumbnailWidth: 0,
          thumbnailHeight: 0,
          error: compact(err?.message || err),
        });
        continue;
      }
    }
    if (!job) {
      artifacts.push({
        questionId: one.questionId,
        questionUid: one.questionUid,
        status: 'queued',
        jobId: '',
        previewOnly: true,
        pdfUrl: '',
        thumbnailUrl: '',
        thumbnailBucket: '',
        thumbnailPath: '',
        thumbnailWidth: 0,
        thumbnailHeight: 0,
        error: createJobs ? 'job_unavailable' : '',
      });
      continue;
    }

    const artifact = await buildPdfArtifactFromJob(job);
    artifacts.push({
      questionId: one.questionId,
      questionUid: one.questionUid,
      ...artifact,
    });
  }

  const hasPending = artifacts.some((one) => {
    const status = String(one?.status || '').trim().toLowerCase();
    return status === 'queued' || status === 'running' || status === 'processing';
  });
  sendJson(res, 200, {
    ok: true,
    artifacts,
    pollAfterMs: hasPending ? 1800 : 0,
  });
}

const BATCH_THUMB_BUCKET = process.env.PB_PREVIEW_THUMB_BUCKET || 'problem-previews';
const BATCH_THUMB_WIDTH_PX = 820;
const BATCH_THUMB_EXPIRES_SEC = 60 * 60 * 24 * 7;

async function batchRenderThumbnails(res, req) {
  console.log('[pb-api] POST /pb/preview/batch-render');
  let body;
  try { body = await readJson(req); } catch (_) {
    sendJson(res, 400, { ok: false, error: 'invalid_json' }); return;
  }

  const academyId = String(body?.academyId || '').trim();
  const rawQuestionIds = Array.isArray(body?.questionIds)
    ? body.questionIds.map((v) => String(v || '').trim())
    : [];
  const questionIds = normalizeUuidListOrdered(rawQuestionIds);
  const requestedDocumentId = String(body?.documentId || '').trim();

  if (!isUuid(academyId) || questionIds.length === 0) {
    sendJson(res, 400, { ok: false, error: 'academyId(uuid) and questionIds(uuid[]) required' });
    return;
  }

  const { data: questionRowsById } = await supa
    .from('pb_questions')
    .select('id,question_uid,document_id,question_type,stem,choices,allow_objective,allow_subjective,objective_choices,objective_answer_key,subjective_answer,objective_generated,figure_refs,equations,confidence,flags,reviewer_notes,source_page,source_order,meta,question_number')
    .eq('academy_id', academyId)
    .in('id', questionIds);
  let questionRows = questionRowsById || [];
  const foundById = new Set(questionRows.map((r) => String(r?.id || '').trim()));
  const missingByIdIds = questionIds.filter((id) => !foundById.has(id));
  if (missingByIdIds.length > 0) {
    const { data: byUidRows } = await supa
      .from('pb_questions')
      .select('id,question_uid,document_id,question_type,stem,choices,allow_objective,allow_subjective,objective_choices,objective_answer_key,subjective_answer,objective_generated,figure_refs,equations,confidence,flags,reviewer_notes,source_page,source_order,meta,question_number')
      .eq('academy_id', academyId)
      .in('question_uid', missingByIdIds);
    if (byUidRows?.length) questionRows = [...questionRows, ...byUidRows];
  }

  const rowById = new Map();
  for (const row of questionRows) {
    const id = String(row?.id || '').trim();
    const uid = String(row?.question_uid || '').trim();
    if (id) rowById.set(id, row);
    if (uid && uid !== id) rowById.set(uid, row);
  }

  const clientModeMap = body?.questionModeByQuestionUid || {};
  const orderedQuestions = [];
  const qidOrder = [];
  for (const qid of questionIds) {
    const row = rowById.get(qid);
    if (!row) continue;
    const uid = String(row?.question_uid || row?.id || '').trim();
    const clientMode = clientModeMap[qid] || clientModeMap[uid] || '';
    const mode = (clientMode === 'subjective' || clientMode === 'essay')
      ? clientMode
      : inferQuestionModeFromRow(row);
    orderedQuestions.push({ ...row, mode, questionMode: mode });
    qidOrder.push(qid);
  }

  if (orderedQuestions.length === 0) {
    sendJson(res, 200, { ok: true, thumbnails: {} });
    return;
  }

  const baseOptions = {
    ...normalizeJsonObject(body?.options, {}),
    ...normalizeJsonObject(body?.renderConfig, {}),
  };
  const templateProfile = normalizeTemplateProfile(
    body?.templateProfile || body?.profile || baseOptions.templateProfile || 'csat',
  );
  const paperSize = normalizePaper(
    body?.paperSize || body?.paper || baseOptions.paperSize || 'A4',
  );

  const PREVIEW_PAGE_WIDTH_MM = 115;
  const PREVIEW_PAGE_HEIGHT_MM = 800;
  const previewGeometry = `paperwidth=${PREVIEW_PAGE_WIDTH_MM}mm,paperheight=${PREVIEW_PAGE_HEIGHT_MM}mm,left=5mm,right=5mm,top=5mm,bottom=5mm`;
  const batchFont = resolveBatchPreviewFont();

  try {
    const rendered = await renderPdfWithXeLatex({
      questions: orderedQuestions,
      renderConfig: {
        hidePreviewHeader: true,
        hideQuestionNumber: true,
        mathEngine: 'xelatex',
        ...baseOptions,
        geometryOverride: previewGeometry,
      },
      profile: templateProfile,
      paper: paperSize,
      modeByQuestionId: Object.fromEntries(
        orderedQuestions.map((q) => [String(q.question_uid || q.id), q.mode]),
      ),
      questionMode: 'objective',
      layoutColumns: 1,
      maxQuestionsPerPage: 1,
      renderConfigVersion: EXPORT_RENDER_CONFIG_VERSION,
      fontFamilyRequested: batchFont.family,
      fontFamilyResolved: batchFont.family,
      fontRegularPath: batchFont.path,
      fontBoldPath: '',
      fontSize: 11,
      supabaseClient: supa,
    });

    const pdfBytes = rendered.bytes;
    const pageCount = rendered.pageCount || 0;

    const tmpDir = path.join(os.tmpdir(), `pb-batch-${randomUUID()}`);
    fs.mkdirSync(tmpDir, { recursive: true });
    const tmpPdf = path.join(tmpDir, 'doc.pdf');
    fs.writeFileSync(tmpPdf, pdfBytes);

    try {
      const dpi = Math.max(150, Math.round((BATCH_THUMB_WIDTH_PX / PREVIEW_PAGE_WIDTH_MM) * 25.4));
      const pngBase = path.join(tmpDir, 'page');
      await execFileAsync(
        'pdftoppm',
        ['-png', '-r', String(dpi), tmpPdf, pngBase],
        { timeout: 120_000 },
      );

      const allFiles = fs.readdirSync(tmpDir)
        .filter((f) => /^page-\d+\.png$/.test(f))
        .sort();
      let pngFiles = allFiles.map((f) => path.join(tmpDir, f));

      if (pngFiles.length === 0) {
        const singlePath = `${pngBase}.png`;
        pngFiles = fs.existsSync(singlePath) ? [singlePath] : [];
      }

      const thumbnails = {};
      const uploadPromises = [];

      for (let i = 0; i < Math.min(pngFiles.length, qidOrder.length); i++) {
        const qid = qidOrder[i];
        const pngPath = pngFiles[i];
        if (!fs.existsSync(pngPath)) continue;

        uploadPromises.push(
          (async () => {
            const raw = fs.readFileSync(pngPath);
            const meta = await sharp(raw).metadata();
            const origW = meta.width || 1;
            const origH = meta.height || 1;

            let contentBottom = origH;
            try {
              const trimResult = await sharp(raw)
                .trim({ background: { r: 255, g: 255, b: 255, alpha: 1 }, threshold: 10 })
                .toBuffer({ resolveWithObject: true });
              const tTop = Number(trimResult.info.trimOffsetTop) || 0;
              const tH = Number(trimResult.info.height) || origH;
              const padding = Math.max(100, Math.round(origH * 0.03));
              contentBottom = Math.min(origH, tTop + tH + padding);
            } catch (_) { /* keep full height */ }

            const minH = Math.max(80, Math.round(origH * 0.05));
            const cropH = Math.max(minH, contentBottom);
            const cropped = await sharp(raw)
              .extract({ left: 0, top: 0, width: origW, height: cropH })
              .resize({ width: BATCH_THUMB_WIDTH_PX })
              .png({ compressionLevel: 9 })
              .toBuffer();

            const storagePath = `${academyId}/batch-preview/${qid}.png`;
            const { error: upErr } = await supa.storage
              .from(BATCH_THUMB_BUCKET)
              .upload(storagePath, cropped, { contentType: 'image/png', upsert: true });
            if (upErr) {
              thumbnails[qid] = { error: upErr.message };
              return;
            }
            const { data: signedData } = await supa.storage
              .from(BATCH_THUMB_BUCKET)
              .createSignedUrl(storagePath, BATCH_THUMB_EXPIRES_SEC);
            thumbnails[qid] = {
              url: signedData?.signedUrl || '',
              width: BATCH_THUMB_WIDTH_PX,
              storagePath,
            };
          })(),
        );
      }

      await Promise.all(uploadPromises);
      sendJson(res, 200, { ok: true, thumbnails, pageCount, questionCount: qidOrder.length });
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  } catch (err) {
    sendJson(res, 500, { ok: false, error: `render_failed: ${compact(err?.message || err)}` });
  }
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
    if (method === 'GET' && /^\/pb\/jobs\/export\/[^/]+\/signed-url$/.test(url.pathname)) {
      const jobId = url.pathname.split('/')[4];
      await regenerateExportSignedUrl(jobId, url, res);
      return;
    }

    if (method === 'POST' && url.pathname === '/pb/documents/save-settings') {
      const body = await readJson(req);
      await saveSettingsAsDocument(body, res);
      return;
    }
    if (method === 'GET' && /^\/pb\/documents\/[^/]+\/export-preset$/.test(url.pathname)) {
      const documentId = url.pathname.split('/')[3];
      await getDocumentExportPreset(documentId, url, res);
      return;
    }
    if (method === 'GET' && url.pathname === '/pb/export-presets') {
      await listExportPresets(url, res);
      return;
    }
    if (method === 'POST' && /^\/pb\/export-presets\/[^/]+\/rename$/.test(url.pathname)) {
      const presetId = url.pathname.split('/')[3];
      const body = await readJson(req);
      await renameExportPreset(presetId, body, res);
      return;
    }
    if (method === 'POST' && /^\/pb\/export-presets\/[^/]+\/delete$/.test(url.pathname)) {
      const presetId = url.pathname.split('/')[3];
      const body = await readJson(req);
      await deleteExportPreset(presetId, body, res);
      return;
    }
    if (method === 'POST' && url.pathname === '/pb/admin/cleanup-legacy-saved-settings') {
      const body = await readJson(req);
      await cleanupLegacySavedSettings(body, res);
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

    if (method === 'POST' && url.pathname === '/pb/preview/questions') {
      await previewQuestions(res, req);
      return;
    }

    if (method === 'POST' && url.pathname === '/pb/preview/html') {
      await previewHtml(res, req);
      return;
    }

    if (method === 'POST' && url.pathname === '/pb/preview/urls') {
      await previewUrls(res, req);
      return;
    }

    if (method === 'POST' && url.pathname === '/pb/preview/pdf-artifacts') {
      await previewPdfArtifacts(res, req);
      return;
    }

    if (method === 'POST' && url.pathname === '/pb/preview/batch-render') {
      await batchRenderThumbnails(res, req);
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


