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
import {
  renderPdfWithXeLatex,
  renderAnswerWithXeLatex,
} from './problem_bank/render_engine/xelatex/renderer.js';
import { createMathSvgRenderer } from './problem_bank/render_engine/math/mathjax_svg_renderer.js';
import { generateObjectiveDraftForQuestion } from './problem_bank_extract_worker.js';

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
import {
  createUploadUrl as storageCreateUploadUrl,
  createDownloadUrl as storageCreateDownloadUrl,
  statObject as storageStatObject,
  uploadBytes as storageUploadBytes,
  removeObjectsByPrefix as storageRemoveByPrefix,
  removeObjectsByPrefixInFolder as storageRemoveByNamePrefix,
  buildTextbookStorageKey,
  buildTextbookCropStorageKey,
  DEFAULT_TEXTBOOK_BUCKET,
  DEFAULT_TEXTBOOK_CROPS_BUCKET,
  DEFAULT_TEXTBOOK_DRIVER,
} from './storage/driver.js';
import {
  detectProblemsOnPage,
  normalizeDetectResult,
} from './textbook/vlm_detect_client.js';
import {
  extractAnswersOnPage,
  normalizeAnswerResult,
} from './textbook/vlm_answer_client.js';
import {
  detectSolutionRefsOnPage,
  normalizeSolutionRefsResult,
} from './textbook/vlm_solution_refs_client.js';

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
const answerMathRenderer = createMathSvgRenderer();

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
    const sourceRaw = String(one.source || '').trim().toLowerCase();
    // 'suppressed' 마커는 사용자가 × 로 제거한 slot. label 은 비어있지만 entry 가 있어야
    //   다음 렌더링에서 auto 재생성을 차단할 수 있다.
    const isSuppressed = sourceRaw === 'suppressed';
    if (!label && !isSuppressed) continue;
    const topPt = Number.parseFloat(String(one.topPt ?? ''));
    const paddingTopPt = Number.parseFloat(String(one.paddingTopPt ?? ''));
    const source = isSuppressed
      ? 'suppressed'
      : (sourceRaw === 'auto' ? 'auto' : 'manual');
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

const EXPORT_RENDER_CONFIG_VERSION = 'pb_render_v55_compact_subanswers';
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
  // 클라이언트(Flutter) 가 '새로고침' 이나 'PDF 생성' 시 true 로 넘겨주는 플래그.
  //   true 이면 렌더 엔진은 객관식/유형 전환 기반 자동 라벨을 더 이상 생성하지 않고,
  //   columnLabelAnchors 에 들어있는 항목만 그대로 사용한다.
  //   (최초 미리보기 생성 경로에서는 이 플래그가 없으므로 기존 auto-gen 동작 유지)
  const disableAutoLabels = normalizeBool(
    src.disableAutoLabels ?? src.suppressAutoLabels ?? src.disableAutoColumnLabels,
    normalizeBool(defaults.disableAutoLabels, false),
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
    disableAutoLabels,
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
        'source_pdf_storage_bucket',
        'source_pdf_storage_path',
        'source_pdf_filename',
        'source_pdf_sha256',
        'source_pdf_size_bytes',
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
    // disableAutoLabels 가 true 이면 서버가 auto 라벨을 만들지 않아 출력 PDF 가 달라진다.
    //   캐시 오염을 막기 위해 hash 에 포함.
    disableAutoLabels: renderConfig.disableAutoLabels === true,
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
    // 워커가 옵션을 다시 정규화할 때도 플래그를 살리기 위해 함께 저장.
    disableAutoLabels: renderConfig.disableAutoLabels === true,
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

async function handleStorageSignedUrl(body, res) {
  const bucket = String(body?.bucket || '').trim();
  const objectPath = String(body?.path || body?.object_path || '').trim();
  const ttl = Number.parseInt(String(body?.expires_in_seconds ?? body?.ttl_seconds ?? 3600), 10);
  if (!bucket || !objectPath) {
    sendJson(res, 400, { ok: false, error: 'missing_bucket_or_path' });
    return;
  }
  const signedUrl = await createSignedStorageUrl(
    bucket,
    objectPath,
    Number.isFinite(ttl) && ttl > 0 ? ttl : 3600,
  );
  if (!signedUrl) {
    sendJson(res, 404, { ok: false, error: 'signed_url_unavailable' });
    return;
  }
  sendJson(res, 200, {
    ok: true,
    bucket,
    path: objectPath,
    signed_url: signedUrl,
  });
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
  const textbookPdfOnly =
    body?.textbookPdfOnly === true ||
    body?.textbook_pdf_only === true ||
    String(doc?.meta?.extract_mode || '').trim() === 'textbook_pdf_only' ||
    String(doc?.meta?.textbook_scope?.mode || '').trim() === 'textbook_pdf_only';
  if (!textbookPdfOnly && !String(doc.source_storage_path || '').trim()) {
    sendJson(res, 400, { ok: false, error: 'hwpx_source_required' });
    return;
  }
  if (!String(doc.source_pdf_storage_path || '').trim()) {
    sendJson(res, 400, { ok: false, error: 'pdf_source_required' });
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
    // 워커가 정상 동작 중이면 진짜로 진행 중일 가능성이 높지만, 비정상 종료된
    // 경우 'extracting' 락이 영구히 남아 UI 가 무한 로딩 상태가 된다. 마지막
    // 업데이트가 충분히 오래됐으면(=stale) 사용자의 재시도 요청을 받아 다시
    // queued 로 풀어준다. 기본 임계값은 워커의 stale reclaim 과 동일(5분).
    // 짧게 낮추려면 PB_EXTRACT_STALE_MS 환경변수를 양쪽에 공유.
    const staleMs = Math.max(
      60_000,
      Number.parseInt(process.env.PB_EXTRACT_STALE_MS || '300000', 10),
    );
    const lastTouchIso = oldJob.updated_at || oldJob.started_at || null;
    const ageMs = lastTouchIso
      ? Date.now() - new Date(lastTouchIso).getTime()
      : Number.POSITIVE_INFINITY;
    if (ageMs < staleMs) {
      sendJson(res, 409, {
        ok: false,
        error: 'extract_job_in_progress',
        ageMs,
        staleThresholdMs: staleMs,
      });
      return;
    }
    // stale → 진행 허용. 아래의 queued 전환 update 가 락을 해제한다.
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

// 한 문서에 쌓인 status='failed' 인 figure_jobs 를 일괄 queued 로 되돌린다.
// 사용 시나리오: 워커 측 transient 실패(예: HWPX BMP 디코드 실패) 가 fix 된 직후,
// 이미 failed 로 굳어 자동 재시도되지 않는 잡들을 한 번에 복구하기 위함.
// body:
//   academyId:  uuid (필수)
//   documentId: uuid (필수)
//   errorMessageContains?: string — 실패 메시지 substring 일치 건만 재큐
//     (빈 값이면 모든 failed 재큐). e.g. "bmp_to_png_failed"
async function requeueFailedFigureJobs(body, res) {
  const academyId = String(body.academyId || '').trim();
  const documentId = String(body.documentId || '').trim();
  const pattern = String(body.errorMessageContains || '').trim();
  if (!isUuid(academyId) || !isUuid(documentId)) {
    sendJson(res, 400, {
      ok: false,
      error: 'academyId/documentId must be uuid',
    });
    return;
  }
  const selectFields = 'id,error_code,error_message';
  let q = supa
    .from('pb_figure_jobs')
    .select(selectFields)
    .eq('academy_id', academyId)
    .eq('document_id', documentId)
    .eq('status', 'failed');
  if (pattern) {
    q = q.ilike('error_message', `%${pattern}%`);
  }
  const { data: rows, error: listErr } = await q.limit(500);
  if (listErr) {
    sendJson(res, 500, {
      ok: false,
      error: `figure_job_list_failed:${listErr.message}`,
    });
    return;
  }
  const targetIds = (rows || []).map((r) => r.id);
  if (targetIds.length === 0) {
    sendJson(res, 200, { ok: true, requeued: 0, total: 0 });
    return;
  }
  const nowIso = new Date().toISOString();
  const { data: updatedRows, error: updErr } = await supa
    .from('pb_figure_jobs')
    .update({
      status: 'queued',
      error_code: '',
      error_message: '',
      result_summary: {},
      output_storage_path: '',
      started_at: null,
      finished_at: null,
      updated_at: nowIso,
    })
    .in('id', targetIds)
    .eq('status', 'failed')
    .select('id');
  if (updErr) {
    sendJson(res, 500, {
      ok: false,
      error: `figure_job_requeue_failed:${updErr.message}`,
    });
    return;
  }
  sendJson(res, 200, {
    ok: true,
    requeued: (updatedRows || []).length,
    total: targetIds.length,
  });
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
  const selectedDeliveryUnitIdsRaw = normalizeUuidListOrdered(
    body.selectedDeliveryUnitIdsOrdered || body.selectedDeliveryUnitIds,
  );
  let selectedQuestionUids = selectedQuestionUidsRaw;
  let selectedQuestionIds = [];
  let sourceDocumentIds = [];
  if (selectedDeliveryUnitIdsRaw.length > 0) {
    const { data: unitRows, error: unitErr } = await supa
      .from('pb_delivery_units')
      .select('id,source_document_id,question_id')
      .eq('academy_id', academyId)
      .in('id', selectedDeliveryUnitIdsRaw);
    if (unitErr) {
      sendJson(res, 500, {
        ok: false,
        error: `export_delivery_unit_lookup_failed:${unitErr.message}`,
      });
      return;
    }
    const unitById = new Map((unitRows || []).map((row) => [String(row.id || ''), row]));
    const orderedUnits = selectedDeliveryUnitIdsRaw.map((id) => unitById.get(id)).filter(Boolean);
    selectedQuestionIds = Array.from(new Set(
      orderedUnits.map((row) => String(row?.question_id || '').trim()).filter((id) => isUuid(id)),
    ));
    if (selectedQuestionIds.length === 0) {
      sendJson(res, 400, { ok: false, error: 'selected_delivery_units_invalid' });
      return;
    }
    const { data: selectedRows, error: selectedErr } = await supa
      .from('pb_questions')
      .select('id,document_id,question_uid')
      .eq('academy_id', academyId)
      .in('id', selectedQuestionIds);
    if (selectedErr) {
      sendJson(res, 500, {
        ok: false,
        error: `export_delivery_unit_question_lookup_failed:${selectedErr.message}`,
      });
      return;
    }
    const rowById = new Map((selectedRows || []).map((row) => [String(row.id || ''), row]));
    selectedQuestionUids = selectedQuestionIds
      .map((id) => String(rowById.get(id)?.question_uid || '').trim())
      .filter((uid) => isUuid(uid));
    const seenDocIds = new Set();
    for (const unit of orderedUnits) {
      const docId = String(unit?.source_document_id || '').trim();
      if (!isUuid(docId) || seenDocIds.has(docId)) continue;
      seenDocIds.add(docId);
      sourceDocumentIds.push(docId);
    }
  } else if (selectedQuestionUidsRaw.length > 0) {
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
    selectedDeliveryUnitIdsOrdered: selectedDeliveryUnitIdsRaw,
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
    selectedDeliveryUnitIdsOrdered: selectedDeliveryUnitIdsRaw,
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
  // 선택적 presetId — 전달되면 기존 preset 행을 update 하고, 없으면 새로 insert 한다.
  const presetIdToUpdate = String(body.presetId || '').trim();
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

    let preset;
    let presetErr;
    let responseMode = 'reference_preset';
    let responseStatus = 201;
    if (isUuid(presetIdToUpdate)) {
      // 기존 preset 업데이트 흐름 — academy_id 일치 여부 확인 후 덮어쓴다.
      const { data: existingPreset, error: existingErr } = await supa
        .from('pb_export_presets')
        .select('id')
        .eq('academy_id', academyId)
        .eq('id', presetIdToUpdate)
        .maybeSingle();
      if (existingErr) {
        sendJson(res, 500, {
          ok: false,
          error: `save_settings_preset_lookup_failed:${existingErr.message}`,
        });
        return;
      }
      if (!existingPreset) {
        sendJson(res, 404, { ok: false, error: 'preset_not_found' });
        return;
      }
      const updateResult = await supa
        .from('pb_export_presets')
        .update({
          source_document_id: sourceDocumentId,
          source_document_ids: sourceQuestionDocIds,
          render_config: renderConfig,
          selected_question_uids: selectedQuestionUidsOrdered,
          selected_question_ids: selectedQuestionIdsOrdered,
          question_mode_by_question_uid: sourceQuestionModeByQuestionUid,
          question_mode_by_question_id: sourceQuestionModeByQuestionUid,
          display_name: presetDisplayName,
          updated_at: new Date().toISOString(),
        })
        .eq('academy_id', academyId)
        .eq('id', presetIdToUpdate)
        .select('*')
        .maybeSingle();
      preset = updateResult.data;
      presetErr = updateResult.error;
      responseMode = 'reference_preset_update';
      responseStatus = 200;
    } else {
      const insertResult = await supa
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
      preset = insertResult.data;
      presetErr = insertResult.error;
    }
    if (presetErr || !preset) {
      throw new Error(
        `save_settings_preset_save_failed:${presetErr?.message || 'unknown'}`,
      );
    }

    sendJson(res, responseStatus, {
      ok: true,
      preset,
      copiedQuestionCount: 0,
      selectedQuestionIds: selectedQuestionIdsOrdered,
      selectedQuestionUids: selectedQuestionUidsOrdered,
      sourceDocumentIds: sourceQuestionDocIds,
      sourceDocumentId,
      mode: responseMode,
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

// ---------------------------------------------------------------------------
// 단일 문항의 객관식 보기 + 정답 라벨을 AI(Gemini) 로 자동 생성해 pb_questions 에 기록한다.
//
// 매니저 UI 에서 사용자가 "객관식 허용" 을 새로 켜는 순간 호출된다. 보기가 이미 저장되어
// 있는 문항에는 기본적으로 손대지 않고(skip), 사용자가 force=true 를 명시할 때만 재생성한다.
// ---------------------------------------------------------------------------
async function generateObjectiveForQuestion(questionId, body, res) {
  if (!isUuid(questionId)) {
    sendJson(res, 400, { ok: false, error: 'questionId must be uuid' });
    return;
  }
  const force = body?.force === true;

  const { data: row, error: fetchError } = await supa
    .from('pb_questions')
    .select(
      'id,academy_id,document_id,question_number,question_type,stem,' +
        'allow_objective,allow_subjective,objective_choices,objective_answer_key,' +
        'objective_generated,subjective_answer,flags,source_type_code,meta',
    )
    .eq('id', questionId)
    .maybeSingle();

  if (fetchError) {
    sendJson(res, 500, {
      ok: false,
      error: `question_fetch_failed:${fetchError.message}`,
    });
    return;
  }
  if (!row) {
    sendJson(res, 404, { ok: false, error: 'question_not_found' });
    return;
  }

  const existingChoices = Array.isArray(row.objective_choices)
    ? row.objective_choices
    : [];
  const existingAnswerKey = String(row.objective_answer_key || '').trim();
  const hasUsableChoices =
    existingChoices.filter((c) =>
      String(c?.text || '').trim().length > 0,
    ).length >= 2 && existingAnswerKey.length > 0;

  if (!force && hasUsableChoices) {
    sendJson(res, 200, {
      ok: true,
      skipped: true,
      reason: 'choices_already_exist',
      objective_choices: existingChoices,
      objective_answer_key: existingAnswerKey,
      objective_generated: row.objective_generated === true,
      allow_objective: row.allow_objective === true,
    });
    return;
  }

  const examProfileHint =
    row.source_type_code === 'susi_sunsi' ? 'susi_sunsi' : 'naesin';

  let draft;
  try {
    draft = await generateObjectiveDraftForQuestion({
      questionNumber: row.question_number || '1',
      stem: row.stem || '',
      subjectiveAnswer: row.subjective_answer || '',
      examProfileHint,
    });
  } catch (err) {
    sendJson(res, 500, {
      ok: false,
      error: `objective_generation_failed:${compact(err?.message || err)}`,
    });
    return;
  }

  if (!draft || !Array.isArray(draft.choices) || draft.choices.length < 5 || !draft.answerKey) {
    // 생성 실패 — DB 는 건드리지 않는다. 매니저 UI 가 스낵바로 알림.
    const flags = Array.from(
      new Set([...(Array.isArray(row.flags) ? row.flags : []), 'objective_generation_failed']),
    );
    sendJson(res, 200, {
      ok: true,
      skipped: false,
      success: false,
      error: draft?.error || 'insufficient_choices',
      flags,
    });
    return;
  }

  const generated = draft.generated === true || draft.usedFallback === true;
  const prevFlags = Array.isArray(row.flags) ? row.flags : [];
  const flagSet = new Set(prevFlags.filter(
    (f) => f !== 'objective_generation_failed' && f !== 'objective_generation_error',
  ));
  if (draft.usedFallback) flagSet.add('objective_generated_fallback');
  if (draft.error) flagSet.add('objective_generation_warning');
  const newFlags = Array.from(flagSet);

  const prevMeta = row.meta && typeof row.meta === 'object' ? row.meta : {};
  const newMeta = {
    ...prevMeta,
    allow_objective: true,
    objective_answer_key: draft.answerKey,
    objective_generated: generated,
  };

  const { data: updated, error: updateError } = await supa
    .from('pb_questions')
    .update({
      allow_objective: true,
      objective_choices: draft.choices,
      objective_answer_key: draft.answerKey,
      objective_generated: generated,
      flags: newFlags,
      meta: newMeta,
    })
    .eq('id', questionId)
    .select(
      'id,allow_objective,objective_choices,objective_answer_key,objective_generated,flags,meta',
    )
    .single();

  if (updateError) {
    sendJson(res, 500, {
      ok: false,
      error: `question_update_failed:${updateError.message}`,
    });
    return;
  }

  sendJson(res, 200, {
    ok: true,
    skipped: false,
    success: true,
    used_fallback: draft.usedFallback === true,
    objective_choices: updated.objective_choices,
    objective_answer_key: updated.objective_answer_key,
    objective_generated: updated.objective_generated === true,
    allow_objective: updated.allow_objective === true,
    flags: updated.flags,
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

  let questions = data || [];
  const includeDeliveryUnits =
    String(url.searchParams.get('include_delivery_units') || '').trim() === '1' ||
    String(url.searchParams.get('includeDeliveryUnits') || '').trim() === '1';
  if (includeDeliveryUnits && questions.length > 0) {
    try {
      let unitQ = supa
        .from('pb_delivery_units')
        .select('id,source_document_id,set_id,question_id,delivery_key,delivery_type,title,selectable,item_refs,render_policy,source_meta')
        .eq('academy_id', academyId);
      if (documentId) unitQ = unitQ.eq('source_document_id', documentId);
      else unitQ = unitQ.in('question_id', questions.map((qRow) => qRow.id).filter(Boolean));
      const { data: units, error: unitErr } = await unitQ;
      if (!unitErr && Array.isArray(units) && units.length > 0) {
        const byQuestion = new Map();
        for (const unit of units) {
          const qid = String(unit?.question_id || '').trim();
          if (!qid) continue;
          const bucket = byQuestion.get(qid) || [];
          bucket.push(unit);
          byQuestion.set(qid, bucket);
        }
        questions = questions.map((qRow) => ({
          ...qRow,
          delivery_units: byQuestion.get(String(qRow.id || '').trim()) || [],
        }));
      }
    } catch (_) {
      // Delivery units are an additive model; never fail the legacy question list.
    }
  }

  sendJson(res, 200, {
    ok: true,
    questions,
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
  const mathEngine = body?.mathEngine || 'xelatex';

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
      mathEngine: body?.mathEngine || 'xelatex',
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
const ANSWER_RENDER_BUCKET = process.env.PB_ANSWER_RENDER_BUCKET || 'problem-previews';
const ANSWER_RENDER_EXPIRES_SEC = 60 * 60 * 24 * 7;
const ANSWER_RENDER_STYLE_VERSION = 'answer-xelatex-v5-hires';
const ANSWER_RENDER_PIXEL_RATIO = 5;
const ANSWER_RENDER_CONCURRENCY = Math.max(
  1,
  Math.min(4, Number.parseInt(process.env.PB_ANSWER_RENDER_CONCURRENCY || '2', 10) || 2),
);

function normalizeAnswerRenderColor(raw, fallback = 'EAF2F7') {
  const cleaned = String(raw || fallback).replace(/[^0-9A-Fa-f]/g, '').slice(0, 6);
  return cleaned.length === 6 ? cleaned.toUpperCase() : fallback;
}

function normalizeAnswerRenderFontSize(raw) {
  const parsed = Number(raw);
  if (!Number.isFinite(parsed)) return 19;
  return Math.max(10, Math.min(30, Math.round(parsed)));
}

function normalizeAnswerRenderEngine(raw) {
  const value = String(raw || '').trim().toLowerCase();
  if (value === 'mathjax' || value === 'svg') return 'mathjax';
  return 'xelatex';
}

function svgNumberAttr(svg, name) {
  const match = String(svg || '').match(new RegExp(`${name}="([\\d.]+)(em|px)?"`, 'i'));
  if (!match) return null;
  const value = Number.parseFloat(match[1]);
  if (!Number.isFinite(value) || value <= 0) return null;
  return { value, unit: match[2] || '' };
}

async function renderAnswerWithMathJax({
  answer,
  deviceScaleFactor = 3,
  fontSizePt = 19,
  textColor = 'EAF2F7',
}) {
  const rendered = answerMathRenderer.renderInline(answer || '-');
  if (!rendered?.ok || !rendered.svg) {
    throw new Error('mathjax render failed');
  }
  const pixelRatio = Number(deviceScaleFactor || 3);
  const fontPx = Math.max(1, Number(fontSizePt || 19) * (96 / 72));
  const widthAttr = svgNumberAttr(rendered.svg, 'width');
  const heightAttr = svgNumberAttr(rendered.svg, 'height');
  const viewBoxMatch = rendered.svg.match(/viewBox="([^"]+)"/i);
  const viewBoxParts = viewBoxMatch
    ? viewBoxMatch[1].trim().split(/\s+/).map((v) => Number.parseFloat(v))
    : [];
  const viewBoxWidth = Number.isFinite(viewBoxParts[2]) && viewBoxParts[2] > 0
    ? viewBoxParts[2]
    : 1000;
  const viewBoxHeight = Number.isFinite(viewBoxParts[3]) && viewBoxParts[3] > 0
    ? viewBoxParts[3]
    : 1000;
  const widthCssPx = widthAttr?.unit === 'px'
    ? widthAttr.value
    : ((widthAttr?.value || (viewBoxWidth / 1000)) * fontPx);
  const heightCssPx = heightAttr?.unit === 'px'
    ? heightAttr.value
    : ((heightAttr?.value || (viewBoxHeight / 1000)) * fontPx);
  const width = Math.max(1, Math.ceil(widthCssPx * pixelRatio));
  const height = Math.max(1, Math.ceil(heightCssPx * pixelRatio));
  const color = normalizeAnswerRenderColor(textColor);
  let svg = rendered.svg
    .replace(/currentColor/g, `#${color}`)
    .replace(
      /<svg\b[^>]*>/i,
      (tag) => tag
        .replace(/\swidth="[^"]*"/i, '')
        .replace(/\sheight="[^"]*"/i, '')
        .replace(/\sstyle="[^"]*"/i, '')
        .replace(/>$/, ` width="${width}" height="${height}">`),
    );
  if (!/xmlns=/.test(svg.slice(0, 200))) {
    svg = svg.replace('<svg', '<svg xmlns="http://www.w3.org/2000/svg"');
  }
  const pngBuffer = await sharp(Buffer.from(svg)).png().toBuffer();
  return {
    pngBuffer,
    width,
    height,
    pixelRatio,
    svg,
  };
}

async function loadAnswerRenderStorageMeta(storagePath) {
  try {
    const { data, error } = await supa.storage
      .from(ANSWER_RENDER_BUCKET)
      .download(storagePath);
    if (error || !data) return null;
    const bytes = Buffer.from(await data.arrayBuffer());
    const meta = await sharp(bytes).metadata();
    return {
      width: Number(meta.width || 0),
      height: Number(meta.height || 0),
    };
  } catch (_) {
    return null;
  }
}

async function createAnswerRenderSignedUrl(storagePath) {
  const { data } = await supa.storage
    .from(ANSWER_RENDER_BUCKET)
    .createSignedUrl(storagePath, ANSWER_RENDER_EXPIRES_SEC);
  return String(data?.signedUrl || '').trim();
}

async function previewAnswerRenders(res, req) {
  console.log('[pb-api] POST /pb/preview/answer-renders');
  let body;
  try { body = await readJson(req); } catch (_) {
    sendJson(res, 400, { ok: false, error: 'invalid_json' }); return;
  }

  const academyId = String(body?.academyId || '').trim();
  const rawItems = Array.isArray(body?.items) ? body.items : [];
  if (!isUuid(academyId) || rawItems.length === 0) {
    sendJson(res, 400, { ok: false, error: 'academyId(uuid) and items[] required' });
    return;
  }

  const style = normalizeJsonObject(body?.style, {});
  const textColor = normalizeAnswerRenderColor(style.textColor || style.color || 'EAF2F7');
  const fontSize = normalizeAnswerRenderFontSize(style.fontSize || style.fontSizePt || 19);
  const transparent = style.transparent !== false;
  const engine = normalizeAnswerRenderEngine(body?.engine || style.engine);
  const font = resolveBatchPreviewFont();
  const fontFamily = String(style.fontFamily || font.family || 'Malgun Gothic').trim();
  const fontRegularPath = String(style.fontFamily ? '' : font.path || '').trim();
  const fontBold = String(style.fontBold || `${fontFamily} Bold`).trim();
  const limit = Math.min(rawItems.length, 120);
  const descriptors = [];
  const renderByHash = new Map();

  for (let i = 0; i < limit; i += 1) {
    const rawItem = rawItems[i];
    const key = String(rawItem?.key ?? '').trim();
    const answer = String(rawItem?.answer ?? '').trim();
    if (!key) continue;

    const renderHash = createHash('sha256')
      .update(JSON.stringify({
        version: ANSWER_RENDER_STYLE_VERSION,
        engine,
        answer,
        textColor,
        fontSize,
        transparent,
        fontFamily,
        fontRegularPath,
      }))
      .digest('hex');
    const storagePath = `${academyId}/answer-renders/${renderHash}.png`;
    const descriptor = { key, answer, renderHash, storagePath };
    descriptors.push(descriptor);
    if (!renderByHash.has(renderHash)) renderByHash.set(renderHash, descriptor);
  }

  const renderOne = async (descriptor) => {
    try {
      const cachedMeta = await loadAnswerRenderStorageMeta(descriptor.storagePath);
      if (cachedMeta) {
        const url = await createAnswerRenderSignedUrl(descriptor.storagePath);
        return {
          url,
          width: cachedMeta.width || 0,
          height: cachedMeta.height || 0,
        pixelRatio: ANSWER_RENDER_PIXEL_RATIO,
          cached: true,
          storagePath: descriptor.storagePath,
        };
      }

      let rendered;
      if (engine === 'mathjax') {
        try {
          rendered = await renderAnswerWithMathJax({
            answer: descriptor.answer || '-',
            deviceScaleFactor: ANSWER_RENDER_PIXEL_RATIO,
            fontSizePt: fontSize,
            textColor,
          });
        } catch (err) {
          console.warn('[answer-renders] mathjax failed, fallback to xelatex:', err?.message || err);
        }
      }
      if (!rendered) {
        rendered = await renderAnswerWithXeLatex({
          answer: descriptor.answer || '-',
          viewportWidth: 640,
          deviceScaleFactor: ANSWER_RENDER_PIXEL_RATIO,
          fontFamily,
          fontBold,
          fontRegularPath,
          fontSizePt: fontSize,
          textColor,
        });
      }
      const { error: upErr } = await supa.storage
        .from(ANSWER_RENDER_BUCKET)
        .upload(descriptor.storagePath, rendered.pngBuffer, {
          contentType: 'image/png',
          upsert: true,
        });
      if (upErr) throw upErr;
      const url = await createAnswerRenderSignedUrl(descriptor.storagePath);
      return {
        url,
        width: rendered.width || 0,
        height: rendered.height || 0,
        pixelRatio: rendered.pixelRatio || ANSWER_RENDER_PIXEL_RATIO,
        cached: false,
        storagePath: descriptor.storagePath,
      };
    } catch (err) {
      return {
        url: '',
        width: 0,
        height: 0,
        cached: false,
        error: compact(err?.message || err),
      };
    }
  };

  const byHashResult = new Map();
  const uniqueDescriptors = Array.from(renderByHash.values());
  let cursor = 0;
  const workerCount = Math.min(ANSWER_RENDER_CONCURRENCY, uniqueDescriptors.length);
  await Promise.all(Array.from({ length: workerCount }, async () => {
    while (cursor < uniqueDescriptors.length) {
      const descriptor = uniqueDescriptors[cursor];
      cursor += 1;
      byHashResult.set(descriptor.renderHash, await renderOne(descriptor));
    }
  }));

  const renders = descriptors.map((descriptor) => ({
    key: descriptor.key,
    ...(byHashResult.get(descriptor.renderHash) || {
      url: '',
      width: 0,
      height: 0,
      cached: false,
      error: 'render_unavailable',
    }),
  }));

  sendJson(res, 200, { ok: true, renders });
}

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

      if (pngFiles.length !== qidOrder.length) {
        const missTail =
          pngFiles.length < qidOrder.length
            ? qidOrder.slice(pngFiles.length).join(',')
            : '(extra-pages)';
        console.warn(
          `[pb-api] batch-thumb page/question mismatch: pages=${pngFiles.length} ` +
            `questions=${qidOrder.length} missingOrExtra=${missTail}`,
        );
      }

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

// ---------------------------------------------------------------------------
// Textbook PDF dual-track endpoints
// ---------------------------------------------------------------------------
// These endpoints cover the Dropbox -> Supabase Storage migration for
// `resource_file_links` rows. They are intentionally permissive on input:
// the manager app can pass either `link_id` (preferred, once the row exists)
// or the logical tuple (academy_id + file_id + grade_label + kind) to
// provision a fresh key before the row has a `storage_key`.
//
// AUTH TODO (pre-release):
// - Replace the bare `requireApiKey` gate with per-user JWT validation so we
//   can scope uploads/downloads to the caller's academy memberships.

const VALID_TEXTBOOK_KINDS = new Set(['body', 'ans', 'sol']);
const UPLOAD_URL_TTL_SEC = 60 * 30;
const DOWNLOAD_URL_TTL_SEC = 60 * 60;

function parseGradeComposite(raw) {
  const s = String(raw || '').trim();
  if (!s) return { gradeLabel: '', kind: '' };
  const idx = s.indexOf('#');
  if (idx < 0) return { gradeLabel: s, kind: '' };
  return {
    gradeLabel: s.slice(0, idx).trim(),
    kind: s.slice(idx + 1).trim().toLowerCase(),
  };
}

function buildGradeComposite(gradeLabel, kind) {
  return `${String(gradeLabel || '').trim()}#${String(kind || '').trim().toLowerCase()}`;
}

function inferTextbookCourse(rawLabel) {
  const label = String(rawLabel || '')
    .trim()
    .replace(/\s+/g, '')
    .replace(/중등|고등|과정|학년/g, '');
  const rows = [
    ['M1', 'M1-1', '1-1'],
    ['M1', 'M1-2', '1-2'],
    ['M2', 'M2-1', '2-1'],
    ['M2', 'M2-2', '2-2'],
    ['M3', 'M3-1', '3-1'],
    ['M3', 'M3-2', '3-2'],
    ['H1', 'H1-c1', '공통수학1'],
    ['H1', 'H1-c2', '공통수학2'],
    ['H2', 'H-algebra', '대수'],
    ['H2', 'H-calc1', '미적분1'],
    ['H2', 'H-probstats', '확률과통계'],
    ['H2', 'H-calc2', '미적분2'],
    ['H2', 'H-geometry', '기하'],
  ];
  for (const [gradeKey, courseKey, courseLabel] of rows) {
    if (label === courseLabel.replace(/\s+/g, '')) {
      return { gradeKey, courseKey, courseLabel };
    }
  }
  return { gradeKey: '', courseKey: '', courseLabel: String(rawLabel || '').trim() };
}

async function resolveTextbookLink({
  linkId,
  academyId,
  fileId,
  gradeLabel,
  kind,
}) {
  if (linkId != null && String(linkId).trim() !== '') {
    const { data, error } = await supa
      .from('resource_file_links')
      .select(
        'id, academy_id, file_id, grade, url, storage_driver, storage_bucket, storage_key, migration_status, file_size_bytes, content_hash, uploaded_at',
      )
      .eq('id', Number(linkId))
      .maybeSingle();
    if (error) return { ok: false, error: `link_lookup_failed: ${error.message}` };
    if (!data) return { ok: false, error: 'link_not_found' };
    return { ok: true, row: data };
  }
  if (!academyId || !fileId || !gradeLabel || !kind) {
    return { ok: false, error: 'missing_identifiers' };
  }
  const composite = buildGradeComposite(gradeLabel, kind);
  const { data, error } = await supa
    .from('resource_file_links')
    .select(
      'id, academy_id, file_id, grade, url, storage_driver, storage_bucket, storage_key, migration_status, file_size_bytes, content_hash, uploaded_at',
    )
    .eq('academy_id', academyId)
    .eq('file_id', fileId)
    .eq('grade', composite)
    .maybeSingle();
  if (error) return { ok: false, error: `link_lookup_failed: ${error.message}` };
  return { ok: true, row: data || null, composite };
}

async function handleTextbookUploadUrl(body, res) {
  const academyId = String(body?.academy_id || '').trim();
  const fileId = String(body?.file_id || '').trim();
  const gradeLabel = String(body?.grade_label || '').trim();
  const inferredCourse = inferTextbookCourse(gradeLabel);
  const gradeKey = String(body?.grade_key || inferredCourse.gradeKey || '').trim();
  const courseKey = String(body?.course_key || inferredCourse.courseKey || '').trim();
  const courseLabel = String(
    body?.course_label || inferredCourse.courseLabel || gradeLabel,
  ).trim();
  const kind = String(body?.kind || '').trim().toLowerCase();
  if (!academyId || !fileId || !gradeLabel || !kind) {
    sendJson(res, 400, {
      ok: false,
      error: 'missing_required_fields',
      required: ['academy_id', 'file_id', 'grade_label', 'kind'],
    });
    return;
  }
  if (!VALID_TEXTBOOK_KINDS.has(kind)) {
    sendJson(res, 400, { ok: false, error: `invalid_kind: ${kind}` });
    return;
  }
  const driver = DEFAULT_TEXTBOOK_DRIVER;
  const bucket = DEFAULT_TEXTBOOK_BUCKET;
  let storageKey;
  try {
    storageKey = buildTextbookStorageKey({
      academyId,
      fileId,
      gradeLabel,
      kind,
    });
  } catch (e) {
    sendJson(res, 400, { ok: false, error: `invalid_key: ${e?.message || e}` });
    return;
  }
  const signed = await storageCreateUploadUrl({
    driver,
    bucket,
    key: storageKey,
    upsert: true,
    expiresIn: UPLOAD_URL_TTL_SEC,
  });
  if (!signed.ok) {
    sendJson(res, 500, { ok: false, error: signed.error });
    return;
  }
  sendJson(res, 200, {
    ok: true,
    upload: {
      url: signed.url,
      method: signed.method || 'PUT',
      headers: signed.headers || {},
      token: signed.token || null,
    },
    storage: {
      driver,
      bucket,
      key: storageKey,
    },
    grade_composite: buildGradeComposite(gradeLabel, kind),
    expires_in: UPLOAD_URL_TTL_SEC,
  });
}

async function handleTextbookFinalize(body, res) {
  const linkId = body?.link_id;
  const academyId = String(body?.academy_id || '').trim();
  const fileId = String(body?.file_id || '').trim();
  const gradeLabel = String(body?.grade_label || '').trim();
  const kind = String(body?.kind || '').trim().toLowerCase();
  const storageDriver = String(
    body?.storage_driver || DEFAULT_TEXTBOOK_DRIVER,
  ).trim();
  const storageBucket = String(
    body?.storage_bucket || DEFAULT_TEXTBOOK_BUCKET,
  ).trim();
  const storageKey = String(body?.storage_key || '').trim();
  const fileSizeBytesRaw = body?.file_size_bytes;
  const contentHash = String(body?.content_hash || '').trim() || null;
  const rawDropboxUrl = body?.legacy_url != null ? String(body.legacy_url) : null;
  const desiredStatus = String(body?.migration_status || 'dual').trim();
  const inferredCourse = inferTextbookCourse(gradeLabel);
  const gradeKey = String(body?.grade_key || inferredCourse.gradeKey || '').trim();
  const courseKey = String(body?.course_key || inferredCourse.courseKey || '').trim();
  const courseLabel = String(
    body?.course_label || inferredCourse.courseLabel || gradeLabel,
  ).trim();

  if (!storageKey) {
    sendJson(res, 400, {
      ok: false,
      error: 'missing_storage_key',
    });
    return;
  }
  if (!['legacy', 'dual', 'migrated'].includes(desiredStatus)) {
    sendJson(res, 400, {
      ok: false,
      error: `invalid_migration_status: ${desiredStatus}`,
    });
    return;
  }

  // Verify the object really exists before we flip the DB row.
  const stat = await storageStatObject({
    driver: storageDriver,
    bucket: storageBucket,
    key: storageKey,
  });
  if (!stat.ok) {
    sendJson(res, 409, {
      ok: false,
      error: `object_not_found: ${stat.error}`,
    });
    return;
  }
  const objectSize = Number.isFinite(Number(fileSizeBytesRaw))
    ? Number(fileSizeBytesRaw)
    : Number(stat.size || 0);

  const resolved = await resolveTextbookLink({
    linkId,
    academyId,
    fileId,
    gradeLabel,
    kind,
  });
  if (!resolved.ok) {
    sendJson(res, 400, { ok: false, error: resolved.error });
    return;
  }

  const nowIso = new Date().toISOString();
  const payload = {
    storage_driver: storageDriver,
    storage_bucket: storageBucket,
    storage_key: storageKey,
    migration_status: desiredStatus,
    file_size_bytes: objectSize,
    content_hash: contentHash,
    uploaded_at: nowIso,
    grade_key: gradeKey,
    course_key: courseKey,
    course_label: courseLabel,
  };

  let updatedRow = null;
  if (resolved.row) {
    const { data, error } = await supa
      .from('resource_file_links')
      .update(payload)
      .eq('id', resolved.row.id)
      .select()
      .maybeSingle();
    if (error) {
      sendJson(res, 500, { ok: false, error: `db_update_failed: ${error.message}` });
      return;
    }
    updatedRow = data;
  } else {
    if (!academyId || !fileId || !gradeLabel || !kind) {
      sendJson(res, 400, {
        ok: false,
        error: 'missing_identifiers_for_insert',
      });
      return;
    }
    const insertPayload = {
      academy_id: academyId,
      file_id: fileId,
      grade: buildGradeComposite(gradeLabel, kind),
      url: rawDropboxUrl || '',
      ...payload,
    };
    const { data, error } = await supa
      .from('resource_file_links')
      .insert(insertPayload)
      .select()
      .maybeSingle();
    if (error) {
      sendJson(res, 500, { ok: false, error: `db_insert_failed: ${error.message}` });
      return;
    }
    updatedRow = data;
  }

  sendJson(res, 200, {
    ok: true,
    link: updatedRow,
  });
}

async function handleTextbookStatusPatch(body, res) {
  const linkId = body?.link_id;
  const desiredStatus = String(body?.migration_status || '').trim();
  if (linkId == null || String(linkId).trim() === '') {
    sendJson(res, 400, { ok: false, error: 'missing_link_id' });
    return;
  }
  if (!['legacy', 'dual', 'migrated'].includes(desiredStatus)) {
    sendJson(res, 400, {
      ok: false,
      error: `invalid_migration_status: ${desiredStatus}`,
    });
    return;
  }
  const { data, error } = await supa
    .from('resource_file_links')
    .update({ migration_status: desiredStatus })
    .eq('id', Number(linkId))
    .select()
    .maybeSingle();
  if (error) {
    sendJson(res, 500, { ok: false, error: `db_update_failed: ${error.message}` });
    return;
  }
  if (!data) {
    sendJson(res, 404, { ok: false, error: 'link_not_found' });
    return;
  }
  sendJson(res, 200, { ok: true, link: data });
}

async function handleTextbookDownloadUrl(url, res) {
  const linkIdRaw = url.searchParams.get('link_id');
  const academyId = (url.searchParams.get('academy_id') || '').trim();
  const fileId = (url.searchParams.get('file_id') || '').trim();
  const gradeLabel = (url.searchParams.get('grade_label') || '').trim();
  const kind = (url.searchParams.get('kind') || '').trim().toLowerCase();

  const resolved = await resolveTextbookLink({
    linkId: linkIdRaw,
    academyId,
    fileId,
    gradeLabel,
    kind,
  });
  if (!resolved.ok) {
    sendJson(res, 400, { ok: false, error: resolved.error });
    return;
  }
  const row = resolved.row;
  if (!row) {
    sendJson(res, 404, { ok: false, error: 'link_not_found' });
    return;
  }
  const status = String(row.migration_status || 'legacy');
  const hasStorage =
    !!row.storage_key && !!row.storage_bucket && !!row.storage_driver;

  // legacy rows always resolve to Dropbox URL.
  if (status === 'legacy' || !hasStorage) {
    const legacyUrl = String(row.url || '').trim();
    if (!legacyUrl) {
      sendJson(res, 404, { ok: false, error: 'no_url_available' });
      return;
    }
    sendJson(res, 200, {
      ok: true,
      kind: 'legacy',
      url: legacyUrl,
      migration_status: status,
      link_id: row.id,
    });
    return;
  }

  // dual or migrated rows: prefer storage, fall back to legacy only when dual.
  const signed = await storageCreateDownloadUrl({
    driver: row.storage_driver,
    bucket: row.storage_bucket,
    key: row.storage_key,
    expiresIn: DOWNLOAD_URL_TTL_SEC,
  });
  if (signed.ok) {
    sendJson(res, 200, {
      ok: true,
      kind: 'storage',
      url: signed.url,
      expires_in: signed.expires_in,
      migration_status: status,
      link_id: row.id,
      file_size_bytes: Number(row.file_size_bytes || 0) || null,
      content_hash: row.content_hash || null,
    });
    return;
  }
  if (status === 'dual') {
    const legacyUrl = String(row.url || '').trim();
    if (legacyUrl) {
      sendJson(res, 200, {
        ok: true,
        kind: 'legacy',
        url: legacyUrl,
        migration_status: status,
        link_id: row.id,
        fallback_reason: signed.error,
      });
      return;
    }
  }
  sendJson(res, 500, {
    ok: false,
    error: `download_url_failed: ${signed.error}`,
  });
}

// ----- Textbook VLM (page-level problem number detection) -----
//
// Test-only endpoint that lets the manager UI render a single PDF page to
// PNG and ask Gemini Vision "where are the problem numbers on this page".
// This is *not* a batch job — each call analyzes exactly one rendered page.
//
// SECURITY TODO (pre-release): this route currently shares the `requireApiKey`
// gate at the top of `handler`. Before we expose this beyond internal manager
// testing, add per-user JWT validation + academy membership check here.

const TEXTBOOK_VLM_MODEL =
  (process.env.TEXTBOOK_VLM_MODEL || process.env.PB_VLM_MODEL || 'gemini-3.1-pro-preview').trim();
const TEXTBOOK_VLM_TIMEOUT_MS = Number.parseInt(
  process.env.TEXTBOOK_VLM_TIMEOUT_MS || '120000',
  10,
);
const TEXTBOOK_VLM_VALID_MIMES = new Set(['image/png', 'image/jpeg', 'image/webp']);

async function lookupTextbookPageOffset({ academyId, bookId, gradeLabel }) {
  if (!academyId || !bookId || !gradeLabel) return { pageOffset: 0, found: false };
  const { data, error } = await supa
    .from('textbook_metadata')
    .select('page_offset')
    .eq('academy_id', academyId)
    .eq('book_id', bookId)
    .eq('grade_label', gradeLabel)
    .maybeSingle();
  if (error || !data) return { pageOffset: 0, found: false };
  const raw = Number(data.page_offset);
  return {
    pageOffset: Number.isFinite(raw) ? raw : 0,
    found: true,
  };
}

async function handleTextbookVlmDetectProblems(body, res) {
  const apiKey =
    (process.env.GEMINI_API_KEY || process.env.GOOGLE_API_KEY || '').trim();
  if (!apiKey) {
    sendJson(res, 500, {
      ok: false,
      error: 'gemini_api_key_missing',
      hint: 'Set GEMINI_API_KEY or GOOGLE_API_KEY in the gateway env.',
    });
    return;
  }

  const imageBase64 = String(body?.image_base64 || '').trim();
  if (!imageBase64) {
    sendJson(res, 400, { ok: false, error: 'missing_image_base64' });
    return;
  }
  const mimeType = String(body?.mime_type || 'image/png').trim();
  if (!TEXTBOOK_VLM_VALID_MIMES.has(mimeType)) {
    sendJson(res, 400, {
      ok: false,
      error: `invalid_mime_type: ${mimeType}`,
      allowed: Array.from(TEXTBOOK_VLM_VALID_MIMES),
    });
    return;
  }

  const rawPage = Number.parseInt(String(body?.raw_page ?? ''), 10);
  if (!Number.isFinite(rawPage) || rawPage <= 0) {
    sendJson(res, 400, { ok: false, error: 'invalid_raw_page' });
    return;
  }

  const academyId = String(body?.academy_id || '').trim();
  const bookId = String(body?.book_id || '').trim();
  const gradeLabel = String(body?.grade_label || '').trim();

  const { pageOffset, found: offsetFound } = await lookupTextbookPageOffset({
    academyId,
    bookId,
    gradeLabel,
  });
  const displayPage = rawPage - pageOffset;

  let result;
  let usedFallbackPrompt = false;
  try {
    result = await detectProblemsOnPage({
      imageBase64,
      mimeType,
      rawPage,
      displayPage,
      pageOffset,
      model: TEXTBOOK_VLM_MODEL,
      apiKey,
      timeoutMs: TEXTBOOK_VLM_TIMEOUT_MS,
    });
  } catch (err) {
    try {
      result = await detectProblemsOnPage({
        imageBase64,
        mimeType,
        rawPage,
        displayPage,
        pageOffset,
        model: TEXTBOOK_VLM_MODEL,
        apiKey,
        timeoutMs: TEXTBOOK_VLM_TIMEOUT_MS,
        includeContentGroups: false,
      });
      usedFallbackPrompt = true;
    } catch (fallbackErr) {
      sendJson(res, 502, {
        ok: false,
        error: 'vlm_detect_failed',
        message: compact(err?.message || err),
        fallback_message: compact(fallbackErr?.message || fallbackErr),
      });
      return;
    }
  }

  const normalized = normalizeDetectResult(result.parsedJson);
  sendJson(res, 200, {
    ok: true,
    raw_page: rawPage,
    display_page: displayPage,
    page_offset: pageOffset,
    page_offset_found: offsetFound,
    content_group_fallback: usedFallbackPrompt,
    section: normalized.section,
    page_kind: normalized.page_kind,
    layout: normalized.page_layout,
    items: normalized.items,
    notes: normalized.notes,
    model: TEXTBOOK_VLM_MODEL,
    elapsed_ms: result.elapsedMs,
    usage: result.usageMetadata || null,
    finish_reason: result.finishReason || '',
  });
}

// ---------------------------------------------------------------------------
// Textbook problem crops (PNG + VLM metadata) batch upsert
// ---------------------------------------------------------------------------
//
// Body shape:
// {
//   academy_id, book_id, grade_label,
//   big_order, mid_order, sub_key, big_name?, mid_name?,
//   crops: [
//     {
//       raw_page, display_page, section, problem_number, label,
//       is_set_header, set_from, set_to, column_index,
//       content_group_kind, content_group_label, content_group_title, content_group_order,
//       bbox_1k, item_region_1k,
//       crop_rect_px, padding_px, crop_long_edge_px, deskew_angle_deg,
//       width_px, height_px,
//       png_base64,        // preferred; uploaded to Storage by the gateway
//       content_hash,      // sha256 hex of the PNG bytes (required for dedup)
//       // OR: storage_key — already uploaded via pre-signed URL
//     },
//     ...
//   ]
// }

const MAX_CROP_BATCH = 120;
const MAX_CROP_BYTES = 25 * 1024 * 1024; // matches the bucket limit

function parseIntArray(input, expectedLen) {
  if (!Array.isArray(input)) return null;
  if (typeof expectedLen === 'number' && input.length !== expectedLen) {
    return null;
  }
  const out = [];
  for (const v of input) {
    const n = Number.parseInt(String(v), 10);
    if (!Number.isFinite(n)) return null;
    out.push(n);
  }
  return out;
}

async function handleTextbookCropsBatchUpsert(body, res) {
  const academyId = String(body?.academy_id || '').trim();
  const bookId = String(body?.book_id || '').trim();
  const gradeLabel = String(body?.grade_label || '').trim();
  const bigOrder = Number.parseInt(String(body?.big_order ?? ''), 10);
  const midOrder = Number.parseInt(String(body?.mid_order ?? ''), 10);
  const subKeyRaw = String(body?.sub_key || '').trim().toUpperCase();
  const bigName = body?.big_name != null ? String(body.big_name) : null;
  const midName = body?.mid_name != null ? String(body.mid_name) : null;
  const crops = Array.isArray(body?.crops) ? body.crops : [];
  // New: "regions only" mode. The manager app can now persist the VLM
  // detection coordinates without uploading the PNG. The original crop
  // pipeline (PNG -> Storage -> row) is a superset and still supported;
  // regions_only just skips the Storage upload while reusing the same
  // canonical key as a placeholder. This lets the student app's PDF
  // viewer do tap-to-identify using the `item_region_1k` column without
  // ever downloading images.
  const regionsOnly = body?.regions_only === true;

  if (!academyId || !bookId || !gradeLabel) {
    sendJson(res, 400, {
      ok: false,
      error: 'missing_required_fields',
      required: ['academy_id', 'book_id', 'grade_label'],
    });
    return;
  }
  if (!Number.isFinite(bigOrder) || !Number.isFinite(midOrder)) {
    sendJson(res, 400, { ok: false, error: 'invalid_unit_order' });
    return;
  }
  if (!['A', 'B', 'C'].includes(subKeyRaw)) {
    sendJson(res, 400, { ok: false, error: `invalid_sub_key: ${subKeyRaw}` });
    return;
  }
  if (crops.length === 0) {
    sendJson(res, 400, { ok: false, error: 'empty_crops' });
    return;
  }
  if (crops.length > MAX_CROP_BATCH) {
    sendJson(res, 413, {
      ok: false,
      error: 'crop_batch_too_large',
      limit: MAX_CROP_BATCH,
      got: crops.length,
    });
    return;
  }

  const bucket = DEFAULT_TEXTBOOK_CROPS_BUCKET;
  const uploadedKeys = [];
  const rows = [];
  for (let i = 0; i < crops.length; i += 1) {
    const c = crops[i] || {};
    const rawPage = Number.parseInt(String(c.raw_page ?? ''), 10);
    const problemNumber = String(c.problem_number || '').trim();
    if (!Number.isFinite(rawPage) || rawPage <= 0 || !problemNumber) {
      sendJson(res, 400, {
        ok: false,
        error: `invalid_crop_row_at_${i}`,
        hint: 'raw_page (>0) and problem_number are required',
      });
      return;
    }

    let storageKey;
    try {
      storageKey = buildTextbookCropStorageKey({
        academyId,
        bookId,
        gradeLabel,
        bigOrder,
        midOrder,
        subKey: subKeyRaw,
        problemNumber,
      });
    } catch (e) {
      sendJson(res, 400, {
        ok: false,
        error: `invalid_storage_key_at_${i}: ${e?.message || e}`,
      });
      return;
    }

    const pngBase64 = typeof c.png_base64 === 'string' ? c.png_base64 : '';
    const preUploadedKey = typeof c.storage_key === 'string' ? c.storage_key.trim() : '';

    let fileSizeBytes = null;
    if (pngBase64) {
      let bytes;
      try {
        bytes = Buffer.from(pngBase64, 'base64');
      } catch (e) {
        sendJson(res, 400, {
          ok: false,
          error: `invalid_base64_at_${i}: ${e?.message || e}`,
        });
        return;
      }
      if (!bytes || bytes.length === 0) {
        sendJson(res, 400, {
          ok: false,
          error: `empty_png_at_${i}`,
        });
        return;
      }
      if (bytes.length > MAX_CROP_BYTES) {
        sendJson(res, 413, {
          ok: false,
          error: `crop_too_large_at_${i}`,
          limit_bytes: MAX_CROP_BYTES,
          got_bytes: bytes.length,
        });
        return;
      }
      const uploaded = await storageUploadBytes({
        driver: DEFAULT_TEXTBOOK_DRIVER,
        bucket,
        key: storageKey,
        contentType: 'image/png',
        bytes,
      });
      if (!uploaded.ok) {
        sendJson(res, 502, {
          ok: false,
          error: `storage_upload_failed_at_${i}`,
          detail: uploaded.error,
        });
        return;
      }
      fileSizeBytes = bytes.length;
      uploadedKeys.push(storageKey);
    } else if (preUploadedKey) {
      storageKey = preUploadedKey;
    } else if (regionsOnly) {
      // Regions-only path: keep the canonical storage_key as a placeholder
      // so a later image upload (if we ever resume the crop feature) can
      // overwrite in place. No Storage write here. `file_size_bytes` stays
      // null; the student app knows `storage_key` without file bytes means
      // "coordinates present, image not stored".
    } else {
      sendJson(res, 400, {
        ok: false,
        error: `missing_png_and_key_at_${i}`,
        hint: 'Provide either png_base64, storage_key, or set regions_only=true.',
      });
      return;
    }

    const bbox1k = parseIntArray(c.bbox_1k, 4);
    const itemRegion1k = parseIntArray(c.item_region_1k, 4);
    const cropRectPx = parseIntArray(c.crop_rect_px, 4);

    const displayPage = Number.parseInt(String(c.display_page ?? ''), 10);
    const setFrom = Number.parseInt(String(c.set_from ?? ''), 10);
    const setTo = Number.parseInt(String(c.set_to ?? ''), 10);
    const columnIndex = Number.parseInt(String(c.column_index ?? ''), 10);
    const contentGroupKindRaw = String(c.content_group_kind || '').trim();
    const contentGroupKind = ['basic_subtopic', 'type', 'none'].includes(
      contentGroupKindRaw,
    )
      ? contentGroupKindRaw
      : 'none';
    const contentGroupOrder = Number.parseInt(
      String(c.content_group_order ?? ''),
      10,
    );
    const paddingPx = Number.parseInt(String(c.padding_px ?? ''), 10);
    const cropLongEdgePx = Number.parseInt(String(c.crop_long_edge_px ?? ''), 10);
    const widthPx = Number.parseInt(String(c.width_px ?? ''), 10);
    const heightPx = Number.parseInt(String(c.height_px ?? ''), 10);
    const deskewAngle = Number(c.deskew_angle_deg);

    rows.push({
      academy_id: academyId,
      book_id: bookId,
      grade_label: gradeLabel,
      big_order: bigOrder,
      mid_order: midOrder,
      sub_key: subKeyRaw,
      big_name: bigName,
      mid_name: midName,
      raw_page: rawPage,
      display_page: Number.isFinite(displayPage) ? displayPage : null,
      section: c.section != null ? String(c.section) : null,
      problem_number: problemNumber,
      label: c.label != null ? String(c.label) : '',
      is_set_header: Boolean(c.is_set_header),
      set_from: Number.isFinite(setFrom) ? setFrom : null,
      set_to: Number.isFinite(setTo) ? setTo : null,
      content_group_kind: contentGroupKind,
      content_group_label:
        contentGroupKind === 'none'
          ? ''
          : String(c.content_group_label || '').trim(),
      content_group_title:
        contentGroupKind === 'none'
          ? ''
          : String(c.content_group_title || '').trim(),
      content_group_order: Number.isFinite(contentGroupOrder)
        ? contentGroupOrder
        : null,
      column_index: Number.isFinite(columnIndex) ? columnIndex : null,
      bbox_1k: bbox1k,
      item_region_1k: itemRegion1k,
      storage_bucket: bucket,
      storage_key: storageKey,
      file_size_bytes: fileSizeBytes,
      content_hash: c.content_hash != null ? String(c.content_hash) : null,
      width_px: Number.isFinite(widthPx) ? widthPx : null,
      height_px: Number.isFinite(heightPx) ? heightPx : null,
      crop_rect_px: cropRectPx,
      padding_px: Number.isFinite(paddingPx) ? paddingPx : null,
      crop_long_edge_px: Number.isFinite(cropLongEdgePx) ? cropLongEdgePx : null,
      deskew_angle_deg: Number.isFinite(deskewAngle) ? deskewAngle : null,
      updated_at: new Date().toISOString(),
    });
  }

  const { data, error } = await supa
    .from('textbook_problem_crops')
    .upsert(rows, {
      onConflict:
        'academy_id,book_id,grade_label,big_order,mid_order,sub_key,problem_number',
    })
    .select('id, storage_key, problem_number');
  if (error) {
    sendJson(res, 500, {
      ok: false,
      error: `db_upsert_failed: ${error.message || error}`,
      uploaded_keys: uploadedKeys,
    });
    return;
  }

  sendJson(res, 200, {
    ok: true,
    upserted: Array.isArray(data) ? data.length : 0,
    bucket,
    rows: data || [],
  });
}

async function handleTextbookVlmExtractAnswers(body, res) {
  const apiKey =
    (process.env.GEMINI_API_KEY || process.env.GOOGLE_API_KEY || '').trim();
  if (!apiKey) {
    sendJson(res, 500, {
      ok: false,
      error: 'gemini_api_key_missing',
      hint: 'Set GEMINI_API_KEY or GOOGLE_API_KEY in the gateway env.',
    });
    return;
  }

  const imageBase64 = String(body?.image_base64 || '').trim();
  if (!imageBase64) {
    sendJson(res, 400, { ok: false, error: 'missing_image_base64' });
    return;
  }
  const mimeType = String(body?.mime_type || 'image/png').trim();
  if (!TEXTBOOK_VLM_VALID_MIMES.has(mimeType)) {
    sendJson(res, 400, {
      ok: false,
      error: `invalid_mime_type: ${mimeType}`,
      allowed: Array.from(TEXTBOOK_VLM_VALID_MIMES),
    });
    return;
  }

  const rawPage = Number.parseInt(String(body?.raw_page ?? ''), 10);
  if (!Number.isFinite(rawPage) || rawPage <= 0) {
    sendJson(res, 400, { ok: false, error: 'invalid_raw_page' });
    return;
  }

  const academyId = String(body?.academy_id || '').trim();
  const bookId = String(body?.book_id || '').trim();
  const gradeLabel = String(body?.grade_label || '').trim();

  // expected_numbers can be either ["0001","12"] or [{problem_number:"0001", crop_id:"..."}, ...]
  const expectedRaw = Array.isArray(body?.expected_numbers)
    ? body.expected_numbers
    : [];
  const expectedNumbers = expectedRaw
    .map((v) => {
      if (v == null) return '';
      if (typeof v === 'string') return v.trim();
      if (typeof v === 'object')
        return String(v.problem_number || v.number || '').trim();
      return '';
    })
    .filter((s) => s.length > 0);

  const { pageOffset, found: offsetFound } = await lookupTextbookPageOffset({
    academyId,
    bookId,
    gradeLabel,
  });
  const displayPage = rawPage - pageOffset;

  let result;
  try {
    result = await extractAnswersOnPage({
      imageBase64,
      mimeType,
      rawPage,
      displayPage,
      pageOffset,
      expectedNumbers,
      model: TEXTBOOK_VLM_MODEL,
      apiKey,
      timeoutMs: TEXTBOOK_VLM_TIMEOUT_MS,
    });
  } catch (err) {
    sendJson(res, 502, {
      ok: false,
      error: 'vlm_answer_failed',
      message: compact(err?.message || err),
    });
    return;
  }

  const normalized = normalizeAnswerResult(result.parsedJson);
  sendJson(res, 200, {
    ok: true,
    raw_page: rawPage,
    display_page: displayPage,
    page_offset: pageOffset,
    page_offset_found: offsetFound,
    items: normalized.items,
    notes: normalized.notes,
    model: TEXTBOOK_VLM_MODEL,
    elapsed_ms: result.elapsedMs,
    usage: result.usageMetadata || null,
    finish_reason: result.finishReason || '',
  });
}

async function handleTextbookVlmDetectSolutionRefs(body, res) {
  const apiKey =
    (process.env.GEMINI_API_KEY || process.env.GOOGLE_API_KEY || '').trim();
  if (!apiKey) {
    sendJson(res, 500, {
      ok: false,
      error: 'gemini_api_key_missing',
      hint: 'Set GEMINI_API_KEY or GOOGLE_API_KEY in the gateway env.',
    });
    return;
  }

  const imageBase64 = String(body?.image_base64 || '').trim();
  if (!imageBase64) {
    sendJson(res, 400, { ok: false, error: 'missing_image_base64' });
    return;
  }
  const mimeType = String(body?.mime_type || 'image/png').trim();
  if (!TEXTBOOK_VLM_VALID_MIMES.has(mimeType)) {
    sendJson(res, 400, {
      ok: false,
      error: `invalid_mime_type: ${mimeType}`,
      allowed: Array.from(TEXTBOOK_VLM_VALID_MIMES),
    });
    return;
  }

  const rawPage = Number.parseInt(String(body?.raw_page ?? ''), 10);
  if (!Number.isFinite(rawPage) || rawPage <= 0) {
    sendJson(res, 400, { ok: false, error: 'invalid_raw_page' });
    return;
  }

  const academyId = String(body?.academy_id || '').trim();
  const bookId = String(body?.book_id || '').trim();
  const gradeLabel = String(body?.grade_label || '').trim();

  const expectedRaw = Array.isArray(body?.expected_numbers)
    ? body.expected_numbers
    : [];
  const expectedNumbers = expectedRaw
    .map((v) => {
      if (v == null) return '';
      if (typeof v === 'string') return v.trim();
      if (typeof v === 'object')
        return String(v.problem_number || v.number || '').trim();
      return '';
    })
    .filter((s) => s.length > 0);

  const { pageOffset, found: offsetFound } = await lookupTextbookPageOffset({
    academyId,
    bookId,
    gradeLabel,
  });
  const displayPage = rawPage - pageOffset;

  let result;
  try {
    result = await detectSolutionRefsOnPage({
      imageBase64,
      mimeType,
      rawPage,
      displayPage,
      pageOffset,
      expectedNumbers,
      model: TEXTBOOK_VLM_MODEL,
      apiKey,
      timeoutMs: TEXTBOOK_VLM_TIMEOUT_MS,
    });
  } catch (err) {
    sendJson(res, 502, {
      ok: false,
      error: 'vlm_solref_failed',
      message: compact(err?.message || err),
    });
    return;
  }

  const normalized = normalizeSolutionRefsResult(result.parsedJson);
  sendJson(res, 200, {
    ok: true,
    raw_page: rawPage,
    display_page: displayPage,
    page_offset: pageOffset,
    page_offset_found: offsetFound,
    items: normalized.items,
    notes: normalized.notes,
    model: TEXTBOOK_VLM_MODEL,
    elapsed_ms: result.elapsedMs,
    usage: result.usageMetadata || null,
    finish_reason: result.finishReason || '',
  });
}

// ---------------------------------------------------------------------------
// textbook_problem_answers batch upsert (Stage 2 sidecar)
// ---------------------------------------------------------------------------
//
// Body shape:
// {
//   academy_id, book_id (optional, for log),
//   answers: [
//     {
//       crop_id,                   // required — FK to textbook_problem_crops.id
//       answer_kind: 'objective'|'subjective'|'image',
//       answer_text,               // "①" or 1D LaTeX
//       answer_latex_2d,           // optional 2D render LaTeX
//       answer_image_png_base64,    // optional when answer_kind='image'
//       answer_image_region_1k,     // optional bbox of the image answer
//       answer_source: 'vlm'|'manual',
//       raw_page, display_page,    // where in 답지 PDF this answer was found
//       bbox_1k,                   // optional
//       note,                      // optional (e.g. VLM confidence)
//     },
//     ...
//   ]
// }

const MAX_ANSWER_BATCH = 300;
const MAX_ANSWER_IMAGE_BYTES = 10 * 1024 * 1024;
const TEXTBOOK_ANSWER_IMAGE_BUCKET = 'textbook-answer-images';
const TEXTBOOK_ANSWER_IMAGE_MARKER_RE = /(?:\[\s*image\s*\]|\(\s*image\s*\)|\[그림\])/i;

function normalizeTextbookAnswerValue(input) {
  let out = String(input ?? '');
  for (let i = 0; i < 6; i += 1) {
    const next = out
      .replace(/\\(?:text|mathrm)\s*\{([^{}]*)\}/g, '$1')
      .replace(/\\textstyle\b/g, '')
      .replace(/\\displaystyle\b/g, '');
    if (next === out) break;
    out = next;
  }
  for (let i = 0; i < 4; i += 1) {
    const next = out
      .replace(
        /\\(?:dfrac|tfrac|frac)\s*\{([^{}]+)\}\s*\{([^{}]+)\}/g,
        (_, a, b) => `\\frac{${String(a).trim()}}{${String(b).trim()}}`,
      )
      .replace(
        /\\(?:dfrac|tfrac|frac)\s*\{([^{}]+)\}\s*([A-Za-z0-9])/g,
        (_, a, b) => `\\frac{${String(a).trim()}}{${b}}`,
      )
      .replace(
        /\\(?:dfrac|tfrac|frac)\s*([A-Za-z0-9])\s*\{([^{}]+)\}/g,
        (_, a, b) => `\\frac{${a}}{${String(b).trim()}}`,
      )
      .replace(
        /\\(?:dfrac|tfrac|frac)\s*([A-Za-z0-9])\s*([A-Za-z0-9])/g,
        (_, a, b) => `\\frac{${a}}{${b}}`,
      );
    if (next === out) break;
    out = next;
  }
  return out
    .replace(/\(\s*image\s*\)/gi, '[image]')
    .replace(/\[\s*image\s*\]/gi, '[image]')
    .replace(/\s+/g, ' ')
    .trim();
}

function textbookProblemNumberKey(value) {
  const n = Number.parseInt(String(value ?? '').trim(), 10);
  return Number.isFinite(n) && n > 0 ? String(n) : '';
}

function parseTextbookAnswerPartsFromText(value) {
  const text = String(value || '').replace(/\s+/g, ' ').trim();
  if (!text) return [];
  const matches = [...text.matchAll(/\((\d{1,2})\)\s*/g)];
  if (matches.length < 2) return [];
  const parts = [];
  for (let i = 0; i < matches.length; i += 1) {
    const match = matches[i];
    const sub = String(match[1] || '').trim();
    const start = match.index + match[0].length;
    const end = i + 1 < matches.length ? matches[i + 1].index : text.length;
    const partValue = text.slice(start, end).trim();
    if (sub && partValue) {
      parts.push({ sub, value: partValue });
    }
  }
  return parts.length >= 2 ? parts : [];
}

function buildPbAnswerPatchFromSidecar(question, answer) {
  const kindRaw = String(answer?.answer_kind || '').trim().toLowerCase();
  const rawText = normalizeTextbookAnswerValue(answer?.answer_text);
  const rawLatex = normalizeTextbookAnswerValue(answer?.answer_latex_2d);
  const text = rawText || rawLatex;
  const kind =
    kindRaw === 'image' || TEXTBOOK_ANSWER_IMAGE_MARKER_RE.test(`${rawText} ${rawLatex}`)
      ? 'image'
      : kindRaw;
  const meta =
    question?.meta && typeof question.meta === 'object'
      ? { ...question.meta }
      : {};
  const choices = Array.isArray(question?.objective_choices)
    ? question.objective_choices
    : [];
  const canUseObjective =
    kind === 'objective' &&
    String(question?.question_type || '').includes('객관식') &&
    choices.length > 0;

  let objectiveAnswerKey = canUseObjective ? text : '';
  let subjectiveAnswer = canUseObjective ? '' : text;
  let answerAsset = null;

  if (kind === 'image') {
    const marker = '[[PB_ANSWER_FIG_1]]';
    const withMarker = text
      ? text
          .replace(/\[\s*image\s*\]/gi, marker)
          .replace(/\(\s*image\s*\)/gi, marker)
          .replace(/\[그림\]/g, marker)
          .replace(/\[\[PB_ANSWER_FIG_[^\]]+\]\]/g, marker)
      : marker;
    subjectiveAnswer = withMarker.includes(marker)
      ? withMarker
      : `${withMarker} ${marker}`.trim();
    objectiveAnswerKey = '';
    const imagePath = String(answer?.answer_image_path || '').trim();
    if (imagePath) {
      answerAsset = {
        figure_index: 1,
        bucket:
          String(answer?.answer_image_bucket || '').trim() ||
          TEXTBOOK_ANSWER_IMAGE_BUCKET,
        path: imagePath,
        mime_type: 'image/png',
        approved: true,
        source: String(answer?.answer_source || '').trim() || 'textbook_answer_vlm',
        created_at: String(answer?.updated_at || '').trim() || new Date().toISOString(),
        ...(answer?.answer_image_width_px
          ? { width_px: answer.answer_image_width_px }
          : {}),
        ...(answer?.answer_image_height_px
          ? { height_px: answer.answer_image_height_px }
          : {}),
        ...(answer?.answer_image_size_bytes
          ? { size_bytes: answer.answer_image_size_bytes }
          : {}),
        ...(answer?.answer_image_content_hash
          ? { content_hash: answer.answer_image_content_hash }
          : {}),
      };
    }
  }

  meta.answer_key = subjectiveAnswer || objectiveAnswerKey || '';
  meta.objective_answer_key = objectiveAnswerKey;
  meta.subjective_answer = subjectiveAnswer;
  meta.allow_objective = canUseObjective;
  meta.allow_subjective = true;
  meta.answer_source = String(answer?.answer_source || '').trim() || 'vlm';
  const parsedAnswerParts = parseTextbookAnswerPartsFromText(subjectiveAnswer);
  if (parsedAnswerParts.length > 0) {
    meta.answer_parts = parsedAnswerParts;
  } else if (kind === 'image') {
    delete meta.answer_parts;
  }
  if (answerAsset) {
    meta.answer_figure_assets = [answerAsset];
    meta.answer_figure_layout =
      meta.answer_figure_layout && typeof meta.answer_figure_layout === 'object'
        ? meta.answer_figure_layout
        : {
            version: 1,
            verticalAlign: 'top',
            items: [
              {
                assetKey: 'idx:1',
                widthEm: 10,
                verticalAlign: 'top',
                topOffsetEm: 0.55,
              },
            ],
          };
  }
  meta.vlm = {
    ...(meta.vlm && typeof meta.vlm === 'object' ? meta.vlm : {}),
    answer_sidecar: {
      kind,
      source: meta.answer_source,
      raw_page: answer?.raw_page ?? null,
      display_page: answer?.display_page ?? null,
      updated_at: String(answer?.updated_at || '').trim(),
      has_image_asset: !!answerAsset,
    },
  };

  return {
    objective_answer_key: objectiveAnswerKey,
    subjective_answer: subjectiveAnswer,
    allow_objective: meta.allow_objective,
    allow_subjective: true,
    meta,
  };
}

async function syncTextbookAnswersToProblemBankScope({
  academyId,
  bookId,
  gradeLabel,
  scope,
}) {
  const { data: run, error: runErr } = await supa
    .from('textbook_pb_extract_runs')
    .select('pb_document_id,status')
    .eq('academy_id', academyId)
    .eq('book_id', bookId)
    .eq('grade_label', gradeLabel)
    .eq('big_order', scope.big_order)
    .eq('mid_order', scope.mid_order)
    .eq('sub_key', scope.sub_key)
    .maybeSingle();
  if (runErr) throw new Error(`sync_pb_run_fetch_failed: ${runErr.message || runErr}`);
  const documentId = String(run?.pb_document_id || '').trim();
  if (!documentId) {
    return { updated: 0, skipped: 'missing_pb_document' };
  }

  const { data: crops, error: cropErr } = await supa
    .from('textbook_problem_crops')
    .select('id,problem_number,is_set_header')
    .eq('academy_id', academyId)
    .eq('book_id', bookId)
    .eq('grade_label', gradeLabel)
    .eq('big_order', scope.big_order)
    .eq('mid_order', scope.mid_order)
    .eq('sub_key', scope.sub_key);
  if (cropErr) throw new Error(`sync_pb_crops_fetch_failed: ${cropErr.message || cropErr}`);
  const cropRows = Array.isArray(crops) ? crops : [];
  const cropIds = cropRows
    .map((crop) => String(crop?.id || '').trim())
    .filter(Boolean);
  if (cropIds.length === 0) return { updated: 0, skipped: 'missing_crops' };

  const { data: answers, error: answerErr } = await supa
    .from('textbook_problem_answers')
    .select(
      'crop_id,answer_kind,answer_text,answer_latex_2d,answer_source,' +
        'answer_image_bucket,answer_image_path,answer_image_width_px,' +
        'answer_image_height_px,answer_image_size_bytes,answer_image_content_hash,' +
        'raw_page,display_page,updated_at',
    )
    .in('crop_id', cropIds);
  if (answerErr) throw new Error(`sync_pb_answers_fetch_failed: ${answerErr.message || answerErr}`);
  const answerByCropId = new Map();
  for (const answer of answers || []) {
    const cropId = String(answer?.crop_id || '').trim();
    if (cropId) answerByCropId.set(cropId, answer);
  }
  if (answerByCropId.size === 0) return { updated: 0, skipped: 'missing_answers' };

  const answerByNumber = new Map();
  for (const crop of cropRows) {
    if (crop?.is_set_header === true) continue;
    const key = textbookProblemNumberKey(crop?.problem_number);
    const answer = answerByCropId.get(String(crop?.id || '').trim());
    if (key && answer) answerByNumber.set(key, answer);
  }

  const { data: questions, error: questionErr } = await supa
    .from('pb_questions')
    .select(
      'id,question_number,question_type,objective_choices,objective_answer_key,' +
        'subjective_answer,allow_objective,allow_subjective,meta',
    )
    .eq('academy_id', academyId)
    .eq('document_id', documentId);
  if (questionErr) {
    throw new Error(`sync_pb_questions_fetch_failed: ${questionErr.message || questionErr}`);
  }

  let updated = 0;
  for (const question of questions || []) {
    const key = textbookProblemNumberKey(question?.question_number);
    const answer = key ? answerByNumber.get(key) : null;
    const questionId = String(question?.id || '').trim();
    if (!answer || !questionId) continue;
    const patch = buildPbAnswerPatchFromSidecar(question, answer);
    const { error: updateErr } = await supa
      .from('pb_questions')
      .update(patch)
      .eq('id', questionId);
    if (updateErr) {
      throw new Error(`sync_pb_question_update_failed: ${updateErr.message || updateErr}`);
    }
    updated += 1;
  }

  return { updated, documentId, status: String(run?.status || '').trim() };
}

async function handleTextbookAnswersBatchUpsert(body, res) {
  const academyId = String(body?.academy_id || '').trim();
  if (!academyId) {
    sendJson(res, 400, { ok: false, error: 'missing_academy_id' });
    return;
  }
  const list = Array.isArray(body?.answers) ? body.answers : [];
  if (list.length === 0) {
    sendJson(res, 400, { ok: false, error: 'empty_answers' });
    return;
  }
  if (list.length > MAX_ANSWER_BATCH) {
    sendJson(res, 413, {
      ok: false,
      error: 'answer_batch_too_large',
      limit: MAX_ANSWER_BATCH,
      got: list.length,
    });
    return;
  }

  const rows = [];
  for (let i = 0; i < list.length; i += 1) {
    const a = list[i] || {};
    const cropId = String(a.crop_id || '').trim();
    if (!cropId) {
      sendJson(res, 400, {
        ok: false,
        error: `missing_crop_id_at_${i}`,
      });
      return;
    }
    let kindRaw = String(a.answer_kind || '').trim().toLowerCase();
    const normalizedAnswerText = normalizeTextbookAnswerValue(a.answer_text);
    const normalizedAnswerLatex2d = normalizeTextbookAnswerValue(a.answer_latex_2d);
    if (
      kindRaw !== 'objective' &&
      TEXTBOOK_ANSWER_IMAGE_MARKER_RE.test(`${normalizedAnswerText} ${normalizedAnswerLatex2d}`)
    ) {
      kindRaw = 'image';
    }
    if (!['objective', 'subjective', 'image'].includes(kindRaw)) {
      sendJson(res, 400, {
        ok: false,
        error: `invalid_answer_kind_at_${i}: ${kindRaw}`,
      });
      return;
    }
    const sourceRaw = String(a.answer_source || 'vlm').trim().toLowerCase();
    if (!['vlm', 'manual'].includes(sourceRaw)) {
      sendJson(res, 400, {
        ok: false,
        error: `invalid_answer_source_at_${i}: ${sourceRaw}`,
      });
      return;
    }
    const rawPage = Number.parseInt(String(a.raw_page ?? ''), 10);
    const displayPage = Number.parseInt(String(a.display_page ?? ''), 10);
    const bbox1k = parseIntArray(a.bbox_1k, 4);
    const imageRegion1k = parseIntArray(a.answer_image_region_1k, 4);
    const imageWidthPx = Number.parseInt(String(a.answer_image_width_px ?? ''), 10);
    const imageHeightPx = Number.parseInt(String(a.answer_image_height_px ?? ''), 10);
    let imageBucket = '';
    let imagePath = '';
    let imageSizeBytes = null;
    let imageHash = '';
    if (kindRaw === 'image') {
      const imageBase64 =
        typeof a.answer_image_png_base64 === 'string'
          ? a.answer_image_png_base64
          : '';
      const preUploadedPath =
        typeof a.answer_image_path === 'string' ? a.answer_image_path.trim() : '';
      if (imageBase64) {
        let bytes;
        try {
          bytes = Buffer.from(imageBase64, 'base64');
        } catch (e) {
          sendJson(res, 400, {
            ok: false,
            error: `invalid_answer_image_base64_at_${i}: ${e?.message || e}`,
          });
          return;
        }
        if (!bytes || bytes.length === 0) {
          sendJson(res, 400, { ok: false, error: `empty_answer_image_at_${i}` });
          return;
        }
        if (bytes.length > MAX_ANSWER_IMAGE_BYTES) {
          sendJson(res, 413, {
            ok: false,
            error: `answer_image_too_large_at_${i}`,
            limit_bytes: MAX_ANSWER_IMAGE_BYTES,
            got_bytes: bytes.length,
          });
          return;
        }
        imageHash = createHash('sha256').update(bytes).digest('hex');
        imagePath = `academies/${academyId}/answers/${cropId}.png`;
        const uploaded = await storageUploadBytes({
          driver: DEFAULT_TEXTBOOK_DRIVER,
          bucket: TEXTBOOK_ANSWER_IMAGE_BUCKET,
          key: imagePath,
          contentType: 'image/png',
          bytes,
        });
        if (!uploaded.ok) {
          sendJson(res, 502, {
            ok: false,
            error: `answer_image_upload_failed_at_${i}`,
            detail: uploaded.error,
          });
          return;
        }
        imageBucket = TEXTBOOK_ANSWER_IMAGE_BUCKET;
        imageSizeBytes = bytes.length;
      } else if (preUploadedPath) {
        imageBucket =
          typeof a.answer_image_bucket === 'string'
            ? a.answer_image_bucket.trim()
            : TEXTBOOK_ANSWER_IMAGE_BUCKET;
        imagePath = preUploadedPath;
      }
    }

    const nowIso = new Date().toISOString();
    const row = {
      crop_id: cropId,
      academy_id: academyId,
      answer_kind: kindRaw,
      answer_text: a.answer_text != null ? normalizedAnswerText : null,
      answer_latex_2d:
        a.answer_latex_2d != null ? normalizedAnswerLatex2d : null,
      answer_source: sourceRaw,
      raw_page: Number.isFinite(rawPage) ? rawPage : null,
      display_page: Number.isFinite(displayPage) ? displayPage : null,
      bbox_1k: bbox1k,
      answer_image_bucket: imageBucket,
      answer_image_path: imagePath,
      answer_image_region_1k: imageRegion1k,
      answer_image_width_px: Number.isFinite(imageWidthPx) ? imageWidthPx : null,
      answer_image_height_px: Number.isFinite(imageHeightPx)
        ? imageHeightPx
        : null,
      answer_image_size_bytes: imageSizeBytes,
      answer_image_content_hash: imageHash,
      note: a.note != null ? String(a.note) : null,
    };
    if (sourceRaw === 'manual') {
      row.edited_at = nowIso;
    }
    rows.push(row);
  }

  const { data, error } = await supa
    .from('textbook_problem_answers')
    .upsert(rows, { onConflict: 'crop_id' })
    .select('crop_id, answer_kind, answer_source');
  if (error) {
    sendJson(res, 500, {
      ok: false,
      error: `db_upsert_failed: ${error.message || error}`,
    });
    return;
  }

  sendJson(res, 200, {
    ok: true,
    upserted: Array.isArray(data) ? data.length : 0,
    rows: data || [],
  });
}

async function handleTextbookAnswersSyncProblemBank(body, res) {
  const academyId = String(body?.academy_id || '').trim();
  const bookId = String(body?.book_id || '').trim();
  const gradeLabel = String(body?.grade_label || '').trim();
  const scope = parseStageScope(body);
  if (!academyId || !bookId || !gradeLabel || !scope) {
    sendJson(res, 400, { ok: false, error: 'missing_scope_identity' });
    return;
  }

  try {
    const result = await syncTextbookAnswersToProblemBankScope({
      academyId,
      bookId,
      gradeLabel,
      scope,
    });
    sendJson(res, 200, {
      ok: true,
      scope,
      pb_document_id: result.documentId || '',
      status: result.status || '',
      updated_questions: result.updated || 0,
      skipped: result.skipped || '',
    });
  } catch (err) {
    sendJson(res, 500, {
      ok: false,
      error: compact(err?.message || err, 500),
    });
  }
}

// ---------------------------------------------------------------------------
// textbook_problem_solution_refs batch upsert (Stage 3 sidecar)
// ---------------------------------------------------------------------------
//
// Body shape:
// {
//   academy_id,
//   solution_refs: [
//     {
//       crop_id,                   // required — FK to textbook_problem_crops.id
//       raw_page, display_page,
//       number_region_1k,          // required [ymin,xmin,ymax,xmax]
//       content_region_1k,         // optional
//     },
//     ...
//   ]
// }

const MAX_SOLREF_BATCH = 300;

async function handleTextbookSolutionRefsBatchUpsert(body, res) {
  const academyId = String(body?.academy_id || '').trim();
  if (!academyId) {
    sendJson(res, 400, { ok: false, error: 'missing_academy_id' });
    return;
  }
  const list = Array.isArray(body?.solution_refs) ? body.solution_refs : [];
  if (list.length === 0) {
    sendJson(res, 400, { ok: false, error: 'empty_solution_refs' });
    return;
  }
  if (list.length > MAX_SOLREF_BATCH) {
    sendJson(res, 413, {
      ok: false,
      error: 'solref_batch_too_large',
      limit: MAX_SOLREF_BATCH,
      got: list.length,
    });
    return;
  }

  const rows = [];
  for (let i = 0; i < list.length; i += 1) {
    const r = list[i] || {};
    const cropId = String(r.crop_id || '').trim();
    if (!cropId) {
      sendJson(res, 400, { ok: false, error: `missing_crop_id_at_${i}` });
      return;
    }
    const rawPage = Number.parseInt(String(r.raw_page ?? ''), 10);
    if (!Number.isFinite(rawPage) || rawPage <= 0) {
      sendJson(res, 400, {
        ok: false,
        error: `invalid_raw_page_at_${i}: ${r.raw_page}`,
      });
      return;
    }
    const displayPage = Number.parseInt(String(r.display_page ?? ''), 10);
    const numberRegion = parseIntArray(r.number_region_1k, 4);
    if (!numberRegion) {
      sendJson(res, 400, {
        ok: false,
        error: `invalid_number_region_1k_at_${i}`,
      });
      return;
    }
    const contentRegion = parseIntArray(r.content_region_1k, 4);

    rows.push({
      crop_id: cropId,
      academy_id: academyId,
      raw_page: rawPage,
      display_page: Number.isFinite(displayPage) ? displayPage : null,
      number_region_1k: numberRegion,
      content_region_1k: contentRegion,
      edited_at: r.source === 'manual' ? new Date().toISOString() : null,
    });
  }

  const { data, error } = await supa
    .from('textbook_problem_solution_refs')
    .upsert(rows, { onConflict: 'crop_id' })
    .select('crop_id, raw_page');
  if (error) {
    sendJson(res, 500, {
      ok: false,
      error: `db_upsert_failed: ${error.message || error}`,
    });
    return;
  }

  sendJson(res, 200, {
    ok: true,
    upserted: Array.isArray(data) ? data.length : 0,
    rows: data || [],
  });
}

function parseStageScope(raw) {
  const bigOrder = Number.parseInt(String(raw?.big_order ?? raw?.bigOrder ?? ''), 10);
  const midOrder = Number.parseInt(String(raw?.mid_order ?? raw?.midOrder ?? ''), 10);
  const subKey = String(raw?.sub_key ?? raw?.subKey ?? '').trim();
  if (!Number.isFinite(bigOrder) || bigOrder < 0) return null;
  if (!Number.isFinite(midOrder) || midOrder < 0) return null;
  if (!subKey) return null;
  return { big_order: bigOrder, mid_order: midOrder, sub_key: subKey };
}

async function fetchTextbookStageStatusRows({ academyId, bookId, gradeLabel, scopes }) {
  const statuses = [];
  for (const scope of scopes) {
    const { data: crops, error: cropErr } = await supa
      .from('textbook_problem_crops')
      .select('id,is_set_header')
      .eq('academy_id', academyId)
      .eq('book_id', bookId)
      .eq('grade_label', gradeLabel)
      .eq('big_order', scope.big_order)
      .eq('mid_order', scope.mid_order)
      .eq('sub_key', scope.sub_key);
    if (cropErr) throw new Error(`stage_status_crops_failed: ${cropErr.message || cropErr}`);
    const cropRows = Array.isArray(crops) ? crops : [];
    const cropIds = cropRows.map((r) => String(r?.id || '').trim()).filter(Boolean);
    const answerTargetIds = cropRows
      .filter((r) => r?.is_set_header !== true)
      .map((r) => String(r?.id || '').trim())
      .filter(Boolean);

    let answerDone = 0;
    let solutionDone = 0;
    if (answerTargetIds.length > 0) {
      const { count: answerCount, error: answerErr } = await supa
        .from('textbook_problem_answers')
        .select('crop_id', { count: 'exact', head: true })
        .in('crop_id', answerTargetIds);
      if (answerErr) throw new Error(`stage_status_answers_failed: ${answerErr.message || answerErr}`);
      answerDone = answerCount || 0;

      const { count: solutionCount, error: solutionErr } = await supa
        .from('textbook_problem_solution_refs')
        .select('crop_id', { count: 'exact', head: true })
        .in('crop_id', answerTargetIds);
      if (solutionErr) {
        throw new Error(`stage_status_solution_refs_failed: ${solutionErr.message || solutionErr}`);
      }
      solutionDone = solutionCount || 0;
    }

    statuses.push({
      scope,
      crop_ids: cropIds,
      body: { done: cropRows.length, total: cropRows.length },
      answer: { done: answerDone, total: answerTargetIds.length },
      solution: { done: solutionDone, total: answerTargetIds.length },
      completed_stages:
        (cropRows.length > 0 ? 1 : 0) +
        (answerTargetIds.length > 0 && answerDone >= answerTargetIds.length ? 1 : 0) +
        (answerTargetIds.length > 0 && solutionDone >= answerTargetIds.length ? 1 : 0),
      total_stages: 3,
    });
  }
  return statuses;
}

async function handleTextbookStageStatus(body, res) {
  const academyId = String(body?.academy_id || '').trim();
  const bookId = String(body?.book_id || '').trim();
  const gradeLabel = String(body?.grade_label || '').trim();
  const rawScopes = Array.isArray(body?.scopes) ? body.scopes : [];
  const scopes = rawScopes.map(parseStageScope).filter(Boolean);
  if (!academyId || !bookId || !gradeLabel) {
    sendJson(res, 400, { ok: false, error: 'missing_scope_identity' });
    return;
  }
  if (scopes.length === 0) {
    sendJson(res, 200, { ok: true, statuses: [] });
    return;
  }
  try {
    const statuses = await fetchTextbookStageStatusRows({
      academyId,
      bookId,
      gradeLabel,
      scopes,
    });
    sendJson(res, 200, { ok: true, statuses });
  } catch (err) {
    sendJson(res, 500, { ok: false, error: compact(err?.message || err, 500) });
  }
}

async function removeStoragePaths(bucket, paths, warnings, label) {
  const unique = Array.from(new Set((paths || []).map((p) => String(p || '').trim()).filter(Boolean)));
  if (!bucket || unique.length === 0) return 0;
  let removed = 0;
  for (let i = 0; i < unique.length; i += 200) {
    const chunk = unique.slice(i, i + 200);
    // eslint-disable-next-line no-await-in-loop
    const { error } = await supa.storage.from(bucket).remove(chunk);
    if (error) {
      warnings.push(`${label}: ${error.message || error}`);
    } else {
      removed += chunk.length;
    }
  }
  return removed;
}

async function deleteTextbookPdfOnlyDocumentsForScope({
  academyId,
  bookId,
  gradeLabel,
  scope,
  warnings,
}) {
  const contains = {
    textbook_scope: {
      book_id: bookId,
      grade_label: gradeLabel,
      big_order: scope.big_order,
      mid_order: scope.mid_order,
      sub_key: scope.sub_key,
    },
  };
  const { data: docs, error: docErr } = await supa
    .from('pb_documents')
    .select('id')
    .eq('academy_id', academyId)
    .contains('meta', contains);
  if (docErr) {
    warnings.push(`pb_documents_lookup: ${docErr.message || docErr}`);
    return 0;
  }
  const ids = (docs || []).map((d) => String(d?.id || '').trim()).filter(Boolean);
  if (ids.length === 0) return 0;
  const { data: deleted, error: delErr } = await supa
    .from('pb_documents')
    .delete()
    .eq('academy_id', academyId)
    .in('id', ids)
    .select('id');
  if (delErr) {
    warnings.push(`pb_documents_delete: ${delErr.message || delErr}`);
    return 0;
  }
  return Array.isArray(deleted) ? deleted.length : ids.length;
}

async function handleTextbookStageDelete(body, res) {
  const academyId = String(body?.academy_id || '').trim();
  const bookId = String(body?.book_id || '').trim();
  const gradeLabel = String(body?.grade_label || '').trim();
  const scope = parseStageScope(body);
  const stage = String(body?.stage || '').trim().toLowerCase();
  if (!academyId || !bookId || !gradeLabel || !scope) {
    sendJson(res, 400, { ok: false, error: 'missing_scope_identity' });
    return;
  }
  if (!['body', 'answer', 'solution'].includes(stage)) {
    sendJson(res, 400, { ok: false, error: `invalid_stage: ${stage}` });
    return;
  }

  const removed = {
    crops: 0,
    answers: 0,
    solution_refs: 0,
    answer_images: 0,
    crop_images: 0,
    pb_documents: 0,
    pb_extract_runs: 0,
  };
  const warnings = [];
  try {
    const { data: crops, error: cropErr } = await supa
      .from('textbook_problem_crops')
      .select('id,storage_bucket,storage_key,big_order,mid_order,sub_key')
      .eq('academy_id', academyId)
      .eq('book_id', bookId)
      .eq('grade_label', gradeLabel)
      .eq('big_order', scope.big_order)
      .eq('mid_order', scope.mid_order)
      .eq('sub_key', scope.sub_key);
    if (cropErr) throw new Error(`stage_delete_crops_lookup_failed: ${cropErr.message || cropErr}`);
    const cropRows = Array.isArray(crops) ? crops : [];
    const affectedSubKeys = Array.from(
      new Set(cropRows.map((r) => String(r?.sub_key || '').trim()).filter(Boolean)),
    );
    const expectedSubKey = String(scope.sub_key || '').trim();
    if (affectedSubKeys.some((k) => k !== expectedSubKey)) {
      sendJson(res, 409, {
        ok: false,
        error: 'stage_delete_scope_mismatch',
        requested_scope: scope,
        affected_sub_keys: affectedSubKeys,
        removed,
        warnings,
      });
      return;
    }
    const cropIds = cropRows.map((r) => String(r?.id || '').trim()).filter(Boolean);
    if (cropIds.length === 0) {
      sendJson(res, 200, {
        ok: true,
        stage,
        scope,
        affected_sub_keys: [],
        removed,
        warnings,
      });
      return;
    }

    if (stage === 'body' || stage === 'answer') {
      const { data: answers } = await supa
        .from('textbook_problem_answers')
        .select('answer_image_bucket,answer_image_path')
        .in('crop_id', cropIds);
      const byBucket = new Map();
      for (const answer of answers || []) {
        const bucket = String(answer?.answer_image_bucket || '').trim();
        const imagePath = String(answer?.answer_image_path || '').trim();
        if (!bucket || !imagePath) continue;
        if (!byBucket.has(bucket)) byBucket.set(bucket, []);
        byBucket.get(bucket).push(imagePath);
      }
      for (const [bucket, paths] of byBucket.entries()) {
        // eslint-disable-next-line no-await-in-loop
        removed.answer_images += await removeStoragePaths(
          bucket,
          paths,
          warnings,
          'textbook-answer-images',
        );
      }
    }

    if (stage === 'body' || stage === 'answer' || stage === 'solution') {
      const { data: deletedRefs, error: refErr } = await supa
        .from('textbook_problem_solution_refs')
        .delete()
        .in('crop_id', cropIds)
        .select('crop_id');
      if (refErr) throw new Error(`solution_refs_delete_failed: ${refErr.message || refErr}`);
      removed.solution_refs = Array.isArray(deletedRefs) ? deletedRefs.length : 0;
    }

    if (stage === 'body' || stage === 'answer') {
      const { data: deletedAnswers, error: ansErr } = await supa
        .from('textbook_problem_answers')
        .delete()
        .in('crop_id', cropIds)
        .select('crop_id');
      if (ansErr) throw new Error(`answers_delete_failed: ${ansErr.message || ansErr}`);
      removed.answers = Array.isArray(deletedAnswers) ? deletedAnswers.length : 0;
    }

    if (stage === 'body') {
      const cropPathsByBucket = new Map();
      for (const crop of cropRows) {
        const bucket = String(crop?.storage_bucket || '').trim();
        const key = String(crop?.storage_key || '').trim();
        if (!bucket || !key) continue;
        if (!cropPathsByBucket.has(bucket)) cropPathsByBucket.set(bucket, []);
        cropPathsByBucket.get(bucket).push(key);
      }
      for (const [bucket, paths] of cropPathsByBucket.entries()) {
        // eslint-disable-next-line no-await-in-loop
        removed.crop_images += await removeStoragePaths(bucket, paths, warnings, 'textbook-crops');
      }
      removed.pb_documents = await deleteTextbookPdfOnlyDocumentsForScope({
        academyId,
        bookId,
        gradeLabel,
        scope,
        warnings,
      });
      const { data: deletedRuns, error: runDelErr } = await supa
        .from('textbook_pb_extract_runs')
        .delete()
        .eq('academy_id', academyId)
        .eq('book_id', bookId)
        .eq('grade_label', gradeLabel)
        .eq('big_order', scope.big_order)
        .eq('mid_order', scope.mid_order)
        .eq('sub_key', scope.sub_key)
        .select('id');
      if (runDelErr) warnings.push(`textbook_pb_extract_runs_delete: ${runDelErr.message || runDelErr}`);
      removed.pb_extract_runs = Array.isArray(deletedRuns) ? deletedRuns.length : 0;
      const { data: deletedCrops, error: cropDelErr } = await supa
        .from('textbook_problem_crops')
        .delete()
        .in('id', cropIds)
        .select('id');
      if (cropDelErr) throw new Error(`crops_delete_failed: ${cropDelErr.message || cropDelErr}`);
      removed.crops = Array.isArray(deletedCrops) ? deletedCrops.length : 0;
    }

    sendJson(res, 200, {
      ok: true,
      stage,
      scope,
      affected_sub_keys: affectedSubKeys,
      removed,
      warnings,
    });
  } catch (err) {
    sendJson(res, 500, {
      ok: false,
      error: compact(err?.message || err, 500),
      removed,
      warnings,
    });
  }
}

/**
 * Delete a textbook in three phases:
 *   1) Remove every artifact in Storage:
 *      - textbook-crops: `academies/<academy>/books/<book_id>/` (recursive)
 *      - textbooks:      `academies/<academy>/files/<book_id>/` (recursive)
 *      - resource-covers: `<academy>/resource-covers/<book_id>_*`
 *   2) Delete the `resource_files` row. All related rows
 *      (textbook_metadata, resource_file_links, textbook_problem_crops)
 *      cascade via ON DELETE CASCADE.
 *   3) Return counts for the UI to display.
 */
async function handleTextbookBookDelete(body, res) {
  const academyId = String(body?.academy_id || '').trim();
  const bookId = String(body?.book_id || '').trim();
  if (!academyId || !bookId) {
    sendJson(res, 400, {
      ok: false,
      error: 'missing_required_fields',
      required: ['academy_id', 'book_id'],
    });
    return;
  }

  const driver = DEFAULT_TEXTBOOK_DRIVER;
  const removed = { crops: 0, pdfs: 0, covers: 0 };
  const warnings = [];

  // (1) textbook-crops: academies/<academy>/books/<book_id>/
  {
    const prefix = `academies/${academyId}/books/${bookId}`;
    const r = await storageRemoveByPrefix({
      driver,
      bucket: DEFAULT_TEXTBOOK_CROPS_BUCKET,
      prefix,
    });
    if (!r.ok) {
      warnings.push(`textbook-crops: ${r.error}`);
    } else {
      removed.crops = r.removed || 0;
    }
  }

  // (2) textbooks: academies/<academy>/files/<book_id>/
  {
    const prefix = `academies/${academyId}/files/${bookId}`;
    const r = await storageRemoveByPrefix({
      driver,
      bucket: DEFAULT_TEXTBOOK_BUCKET,
      prefix,
    });
    if (!r.ok) {
      warnings.push(`textbooks: ${r.error}`);
    } else {
      removed.pdfs = r.removed || 0;
    }
  }

  // (3) resource-covers: <academy>/resource-covers/<book_id>_*
  {
    const r = await storageRemoveByNamePrefix({
      driver,
      bucket: 'resource-covers',
      folder: `${academyId}/resource-covers`,
      nameStartsWith: `${bookId}_`,
    });
    if (!r.ok) {
      warnings.push(`resource-covers: ${r.error}`);
    } else {
      removed.covers = r.removed || 0;
    }
  }

  // (4) Delete the DB row (cascade).
  const { error: delErr } = await supa
    .from('resource_files')
    .delete()
    .match({ id: bookId, academy_id: academyId });
  if (delErr) {
    sendJson(res, 500, {
      ok: false,
      error: 'resource_files_delete_failed',
      detail: delErr.message || String(delErr),
      removed,
      warnings,
    });
    return;
  }

  sendJson(res, 200, {
    ok: true,
    book_id: bookId,
    removed,
    warnings,
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
    if (method === 'POST' && url.pathname === '/pb/jobs/figure/requeue-failed') {
      const body = await readJson(req);
      await requeueFailedFigureJobs(body, res);
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

    if (
      method === 'POST' &&
      /^\/pb\/questions\/[^/]+\/generate-objective$/.test(url.pathname)
    ) {
      const questionId = url.pathname.split('/')[3];
      const body = await readJson(req);
      await generateObjectiveForQuestion(questionId, body, res);
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

    if (method === 'POST' && url.pathname === '/pb/preview/answer-renders') {
      await previewAnswerRenders(res, req);
      return;
    }

    if (method === 'POST' && url.pathname === '/pb/preview/batch-render') {
      await batchRenderThumbnails(res, req);
      return;
    }

    if (method === 'POST' && url.pathname === '/storage/signed-url') {
      const body = await readJson(req);
      await handleStorageSignedUrl(body, res);
      return;
    }

    // ----- Textbook PDF dual-track endpoints -----
    // SECURITY TODO (pre-release): replace the shared `requireApiKey` gate on
    // these four routes with per-user JWT validation + academy membership
    // check. Each handler should receive a resolved `{ user_id, academy_ids }`
    // context so it can reject requests that target an academy the caller
    // does not belong to. Insertion point for the auth middleware is right
    // before each `await handleTextbookXxx(...)` call below.
    if (method === 'POST' && url.pathname === '/textbook/pdf/upload-url') {
      const body = await readJson(req);
      await handleTextbookUploadUrl(body, res);
      return;
    }
    if (method === 'POST' && url.pathname === '/textbook/pdf/finalize') {
      const body = await readJson(req);
      await handleTextbookFinalize(body, res);
      return;
    }
    if (method === 'POST' && url.pathname === '/textbook/pdf/status') {
      const body = await readJson(req);
      await handleTextbookStatusPatch(body, res);
      return;
    }
    if (method === 'GET' && url.pathname === '/textbook/pdf/download-url') {
      await handleTextbookDownloadUrl(url, res);
      return;
    }

    // Textbook VLM (test-only) — page-level problem number detection.
    if (method === 'POST' && url.pathname === '/textbook/vlm/detect-problems') {
      const body = await readJson(req);
      await handleTextbookVlmDetectProblems(body, res);
      return;
    }

    // Textbook crop batch upsert — writes PNG to Storage + row to
    // textbook_problem_crops. Used by the manager app's unit authoring dialog.
    if (method === 'POST' && url.pathname === '/textbook/crops/batch-upsert') {
      const body = await readJson(req);
      await handleTextbookCropsBatchUpsert(body, res);
      return;
    }

    // VLM answer-key extraction — Stage 2.
    if (method === 'POST' && url.pathname === '/textbook/vlm/extract-answers') {
      const body = await readJson(req);
      await handleTextbookVlmExtractAnswers(body, res);
      return;
    }

    // VLM solution-reference detection — Stage 3.
    if (
      method === 'POST' &&
      url.pathname === '/textbook/vlm/detect-solution-refs'
    ) {
      const body = await readJson(req);
      await handleTextbookVlmDetectSolutionRefs(body, res);
      return;
    }

    // Stage 2 sidecar upsert.
    if (
      method === 'POST' &&
      url.pathname === '/textbook/answers/batch-upsert'
    ) {
      const body = await readJson(req);
      await handleTextbookAnswersBatchUpsert(body, res);
      return;
    }

    if (method === 'POST' && url.pathname === '/textbook/answers/sync-pb') {
      const body = await readJson(req);
      await handleTextbookAnswersSyncProblemBank(body, res);
      return;
    }

    // Stage 3 sidecar upsert.
    if (
      method === 'POST' &&
      url.pathname === '/textbook/solution-refs/batch-upsert'
    ) {
      const body = await readJson(req);
      await handleTextbookSolutionRefsBatchUpsert(body, res);
      return;
    }

    // Textbook authoring Stage 1/2/3 status and hard-delete operations.
    if (method === 'POST' && url.pathname === '/textbook/stage/status') {
      const body = await readJson(req);
      await handleTextbookStageStatus(body, res);
      return;
    }
    if (method === 'POST' && url.pathname === '/textbook/stage/delete') {
      const body = await readJson(req);
      await handleTextbookStageDelete(body, res);
      return;
    }

    // Delete an entire textbook — sweeps Storage (textbooks, textbook-crops,
    // resource-covers) and deletes the `resource_files` row (cascade).
    if (method === 'POST' && url.pathname === '/textbook/book/delete') {
      const body = await readJson(req);
      await handleTextbookBookDelete(body, res);
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


