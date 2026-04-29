import 'dotenv/config';
import AdmZip from 'adm-zip';
import { XMLParser } from 'fast-xml-parser';
import hePkg from 'he';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';
import { generateQuestionPreviews } from './problem_bank_preview_service.js';
import { runVlmExtraction } from './problem_bank/extract_engines/vlm/runner.js';

const htmlDecode = hePkg.decode;

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const WORKER_INTERVAL_MS = Number.parseInt(
  process.env.PB_WORKER_INTERVAL_MS || '4000',
  10,
);
const BATCH_SIZE = Math.max(
  1,
  Number.parseInt(process.env.PB_WORKER_BATCH_SIZE || '2', 10),
);
const REVIEW_CONFIDENCE_THRESHOLD = Number.parseFloat(
  process.env.PB_REVIEW_CONFIDENCE_THRESHOLD || '0.85',
);
const PROCESS_ONCE =
  process.argv.includes('--once') || process.env.PB_WORKER_ONCE === '1';
const WORKER_NAME =
  process.env.PB_WORKER_NAME || `pb-extract-worker-${process.pid}`;
// status='extracting' 인 채 N ms 이상 업데이트가 없는 job 은 워커가 비정상 종료된
// 것으로 간주하고 자동 복구한다. (기본 5분). 환경변수로 조정 가능.
// 지나치게 짧으면 정상 처리 중인 long job 이 뺏길 수 있으니 VLM 최대 타임아웃
// (PB_VLM_TIMEOUT_MS) 의 1.5배 이상으로 잡는 게 안전.
const STALE_EXTRACTING_MS = Math.max(
  60_000,
  Number.parseInt(process.env.PB_EXTRACT_STALE_MS || '300000', 10),
);
const GEMINI_API_KEY = String(
  process.env.GEMINI_API_KEY || process.env.GOOGLE_API_KEY || '',
).trim();
const GEMINI_MODEL = String(
  process.env.PB_GEMINI_MODEL || 'gemini-2.5-pro',
).trim();
const GEMINI_KEY_CONFIGURED = GEMINI_API_KEY.length > 0;
const GEMINI_TIMEOUT_MS = Math.max(
  3000,
  Number.parseInt(process.env.PB_GEMINI_TIMEOUT_MS || '60000', 10),
);
const GEMINI_INPUT_MAX_CHARS = Math.max(
  3000,
  Number.parseInt(process.env.PB_GEMINI_INPUT_MAX_CHARS || '18000', 10),
);
const GEMINI_MIN_FALLBACK_QUESTIONS = Math.max(
  0,
  Number.parseInt(process.env.PB_GEMINI_MIN_FALLBACK_QUESTIONS || '1', 10),
);
const GEMINI_PRIORITY = String(
  process.env.PB_GEMINI_PRIORITY || 'always',
).trim().toLowerCase();
const GEMINI_ENABLED =
  (process.env.PB_GEMINI_ENABLED === '1' || GEMINI_KEY_CONFIGURED) &&
  GEMINI_MODEL.length > 0;
const AUTO_QUEUE_FIGURE_JOBS = process.env.PB_AUTO_QUEUE_FIGURE_JOBS !== '0';

// --- VLM (PDF-first) 엔진 설정 ---
// PDF 가 붙어 있는 문서는 VLM 엔진으로 분기한다. HWPX 파이프라인은 "PDF 가 없는 문서" 에 한해
// 계속 동작하며, VLM 품질이 충분히 정착되면 이 분기만 남기고 HWPX 쪽 코드를 제거하면 된다.
const VLM_MODEL = String(
  process.env.PB_VLM_MODEL || process.env.PB_GEMINI_MODEL || 'gemini-3.1-pro-preview',
).trim();
const VLM_TIMEOUT_MS = Math.max(
  10_000,
  Number.parseInt(process.env.PB_VLM_TIMEOUT_MS || '180000', 10),
);
// VLM 엔진은 PB_VLM_ENABLED 를 명시적으로 '0' 으로 두지 않으면 기본 on.
const VLM_ENABLED = process.env.PB_VLM_ENABLED !== '0';

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

if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
  console.error(
    '[pb-extract-worker] Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY',
  );
  process.exit(1);
}

const supa = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

const xmlParser = new XMLParser({
  ignoreAttributes: false,
  attributeNamePrefix: '@_',
  preserveOrder: false,
  processEntities: true,
  trimValues: true,
});

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function compact(value, max = 240) {
  const s = String(value ?? '').replace(/\s+/g, ' ').trim();
  if (s.length <= max) return s;
  return `${s.slice(0, max)}...`;
}

function clamp(v, min, max) {
  if (v < min) return min;
  if (v > max) return max;
  return v;
}

function round4(v) {
  return Math.round(v * 10000) / 10000;
}

function withTimeout(signal, timeoutMs) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);
  if (signal) {
    signal.addEventListener(
      'abort',
      () => {
        clearTimeout(timer);
        ctrl.abort();
      },
      { once: true },
    );
  }
  return { signal: ctrl.signal, clear: () => clearTimeout(timer) };
}

function safeToString(value) {
  if (value == null) return '';
  if (typeof value === 'string') return value;
  if (typeof value === 'number' || typeof value === 'boolean') {
    return String(value);
  }
  if (Array.isArray(value)) {
    return value.map((v) => safeToString(v)).join(' ');
  }
  if (typeof value === 'object') {
    const parts = [];
    for (const v of Object.values(value)) {
      const s = safeToString(v);
      if (s) parts.push(s);
    }
    return parts.join(' ');
  }
  return '';
}

function stripCodeFence(value) {
  const raw = String(value ?? '').trim();
  const m = raw.match(/```(?:json)?\s*([\s\S]*?)```/i);
  if (m) return m[1].trim();
  return raw;
}

function parseJsonLoose(value) {
  const raw = stripCodeFence(value);
  if (!raw) return null;
  try {
    return JSON.parse(raw);
  } catch (_) {
    // continue
  }

  const startObj = raw.indexOf('{');
  const endObj = raw.lastIndexOf('}');
  if (startObj >= 0 && endObj > startObj) {
    try {
      return JSON.parse(raw.slice(startObj, endObj + 1));
    } catch (_) {
      // continue
    }
  }
  const startArr = raw.indexOf('[');
  const endArr = raw.lastIndexOf(']');
  if (startArr >= 0 && endArr > startArr) {
    try {
      return JSON.parse(raw.slice(startArr, endArr + 1));
    } catch (_) {
      return null;
    }
  }
  return null;
}

function normalizeWhitespace(value) {
  return String(value ?? '')
    .replace(/\u00A0/g, ' ')
    .replace(/\u200B/g, '')
    .replace(/\u3000/g, ' ')
    .replace(/[ \t]+/g, ' ')
    .replace(/\s+\n/g, '\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

/** HWPX/OWPML에서 쓰는 다양한 줄바꿈 태그를 \n 으로 통일 (제네릭 태그 제거 전에 호출) */
function replaceHwpSoftBreakElements(s) {
  return String(s || '')
    .replace(/<(?:[\w-]+:)?lineBreak\b[^>]*\/?>/gi, '\n')
    .replace(/<\/(?:[\w-]+:)?lineBreak>/gi, '\n')
    .replace(/<w:br\b[^>]*\/?>/gi, '\n')
    .replace(/<br\b[^>]*\/?>/gi, '\n')
    .replace(/<(?:[\w-]+:)?columnBreak\b[^>]*\/?>/gi, '\n');
}

/**
 * 태그 제거·디코드 후 문단 본문: CR/LF·유니코드 줄바꿈 보존, 줄마다 공백만 정리
 */
function splitParagraphTextToLines(s) {
  let t = String(s ?? '')
    .replace(/\r\n/g, '\n')
    .replace(/\r/g, '\n')
    .replace(/\u2028|\u2029/g, '\n')
    .replace(/\u000b/g, '\n');
  return t
    .split('\n')
    .map((line) => normalizeWhitespace(line))
    .filter((line) => line.length > 0);
}

function escapeRegex(source) {
  return String(source || '').replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function normalizeParagraphAlign(raw) {
  const value = String(raw || '').trim().toLowerCase();
  if (!value) return '';
  if (
    value === 'left'
    || value === 'right'
    || value === 'center'
    || value === 'justify'
  ) {
    return value;
  }
  if (value === 'both' || value === 'distributed' || value === 'distribute') {
    return 'justify';
  }
  if (value === 'middle') return 'center';
  return '';
}

function normalizeParagraphAlignSafe(raw) {
  const normalized = normalizeParagraphAlign(raw);
  return normalized || 'left';
}

function extractXmlAttrValue(attrs, keyCandidates = []) {
  const src = String(attrs || '');
  for (const key of keyCandidates) {
    const m = src.match(
      new RegExp(`\\b${escapeRegex(key)}\\s*=\\s*["']?([^"'\\s>]+)`, 'i'),
    );
    if (m && m[1]) return String(m[1]).trim();
  }
  return '';
}

function extractParagraphAlignFromXmlSnippet(snippet) {
  const src = String(snippet || '');
  const attrRegex = /\b(?:textAlign|text-align|align|horizontal|horzAlign)\s*=\s*["']([^"']+)["']/gi;
  let m = null;
  while ((m = attrRegex.exec(src)) !== null) {
    const aligned = normalizeParagraphAlign(m[1]);
    if (aligned) return aligned;
  }
  const tagRegex = /<(?:[\w-]+:)?align\b[^>]*>([^<]+)<\/(?:[\w-]+:)?align>/gi;
  while ((m = tagRegex.exec(src)) !== null) {
    const aligned = normalizeParagraphAlign(m[1]);
    if (aligned) return aligned;
  }
  return '';
}

function buildHwpxParagraphAlignResolver(zip) {
  const paraAlignById = new Map();
  const styleAlignById = new Map();
  const styleParaRefById = new Map();
  const headerEntries = zip
    .getEntries()
    .filter(
      (entry) =>
        !entry.isDirectory
        && /contents\/(?:header|styles)\.xml$/i.test(String(entry.entryName || '')),
    );
  for (const entry of headerEntries) {
    const xml = decodeZipEntry(entry);
    if (!xml) continue;
    const paraBlockRegex = /<(?:[\w-]+:)?paraPr\b([^>]*)>([\s\S]*?)<\/(?:[\w-]+:)?paraPr>/gi;
    let m = null;
    while ((m = paraBlockRegex.exec(xml)) !== null) {
      const attrs = String(m[1] || '');
      const body = String(m[2] || '');
      const paraId = extractXmlAttrValue(attrs, ['id', 'paraPrID', 'paraPrId']);
      const align = extractParagraphAlignFromXmlSnippet(`${attrs} ${body}`);
      if (paraId && align) {
        paraAlignById.set(paraId, align);
      }
    }
    const paraSelfRegex = /<(?:[\w-]+:)?paraPr\b([^>]*)\/>/gi;
    while ((m = paraSelfRegex.exec(xml)) !== null) {
      const attrs = String(m[1] || '');
      const paraId = extractXmlAttrValue(attrs, ['id', 'paraPrID', 'paraPrId']);
      const align = extractParagraphAlignFromXmlSnippet(attrs);
      if (paraId && align) {
        paraAlignById.set(paraId, align);
      }
    }
    const styleBlockRegex = /<(?:[\w-]+:)?style\b([^>]*)>([\s\S]*?)<\/(?:[\w-]+:)?style>/gi;
    while ((m = styleBlockRegex.exec(xml)) !== null) {
      const attrs = String(m[1] || '');
      const body = String(m[2] || '');
      const styleId = extractXmlAttrValue(attrs, ['id', 'styleID', 'styleId']);
      if (!styleId) continue;
      const align = extractParagraphAlignFromXmlSnippet(`${attrs} ${body}`);
      const paraRef =
        extractXmlAttrValue(attrs, ['paraPrIDRef', 'paraShapeIDRef'])
        || extractXmlAttrValue(body, ['paraPrIDRef', 'paraShapeIDRef']);
      if (align) {
        styleAlignById.set(styleId, align);
      }
      if (paraRef) {
        styleParaRefById.set(styleId, paraRef);
      }
    }
    const styleSelfRegex = /<(?:[\w-]+:)?style\b([^>]*)\/>/gi;
    while ((m = styleSelfRegex.exec(xml)) !== null) {
      const attrs = String(m[1] || '');
      const styleId = extractXmlAttrValue(attrs, ['id', 'styleID', 'styleId']);
      if (!styleId) continue;
      const align = extractParagraphAlignFromXmlSnippet(attrs);
      const paraRef = extractXmlAttrValue(attrs, ['paraPrIDRef', 'paraShapeIDRef']);
      if (align) {
        styleAlignById.set(styleId, align);
      }
      if (paraRef) {
        styleParaRefById.set(styleId, paraRef);
      }
    }
  }
  for (const [styleId, paraRef] of styleParaRefById.entries()) {
    if (styleAlignById.has(styleId)) continue;
    const align = paraAlignById.get(paraRef);
    if (align) {
      styleAlignById.set(styleId, align);
    }
  }
  return {
    paraAlignById,
    styleAlignById,
    styleParaRefById,
  };
}

function resolveParagraphAlign(attrs, body, alignResolver = null) {
  const attrText = String(attrs || '');
  const bodyText = String(body || '');
  const customAlign = normalizeParagraphAlign(
    extractXmlAttrValue(attrText, ['pb-align', 'pbAlign']),
  );
  if (customAlign) return customAlign;
  const direct = extractParagraphAlignFromXmlSnippet(attrText);
  if (direct) return direct;
  const paraRef = extractXmlAttrValue(attrText, ['paraPrIDRef', 'paraShapeIDRef']);
  if (paraRef && alignResolver?.paraAlignById?.has(paraRef)) {
    return alignResolver.paraAlignById.get(paraRef) || 'left';
  }
  const styleRef = extractXmlAttrValue(attrText, ['styleIDRef', 'styleRefID']);
  if (styleRef) {
    const fromStyle = alignResolver?.styleAlignById?.get(styleRef);
    if (fromStyle) return fromStyle;
    const styleParaRef = alignResolver?.styleParaRefById?.get(styleRef);
    if (styleParaRef && alignResolver?.paraAlignById?.has(styleParaRef)) {
      return alignResolver.paraAlignById.get(styleParaRef) || 'left';
    }
  }
  const inlineParaPr = bodyText.match(
    /<(?:[\w-]+:)?paraPr\b([^>]*)>([\s\S]*?)<\/(?:[\w-]+:)?paraPr>|<(?:[\w-]+:)?paraPr\b([^>]*)\/>/i,
  );
  if (inlineParaPr) {
    const inlineAttrs = String(inlineParaPr[1] || inlineParaPr[3] || '');
    const inlineBody = String(inlineParaPr[2] || '');
    const inlineDirect = extractParagraphAlignFromXmlSnippet(
      `${inlineAttrs} ${inlineBody}`,
    );
    if (inlineDirect) return inlineDirect;
    const inlineParaRef = extractXmlAttrValue(inlineAttrs, ['paraPrIDRef', 'paraShapeIDRef']);
    if (inlineParaRef && alignResolver?.paraAlignById?.has(inlineParaRef)) {
      return alignResolver.paraAlignById.get(inlineParaRef) || 'left';
    }
  }
  const bodyDirect = extractParagraphAlignFromXmlSnippet(bodyText);
  if (bodyDirect) return bodyDirect;
  return 'left';
}

function encodeXmlText(value) {
  return String(value || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

function normalizeCurriculumCode(raw, fallback = 'rev_2022') {
  const code = normalizeWhitespace(raw);
  return CURRICULUM_CODES.has(code) ? code : fallback;
}

function normalizeSourceTypeCode(raw, fallback = 'school_past') {
  const code = normalizeWhitespace(raw);
  return SOURCE_TYPE_CODES.has(code) ? code : fallback;
}

function toBoolean(raw) {
  if (raw === true) return true;
  if (raw === false || raw == null) return false;
  const s = String(raw).trim().toLowerCase();
  return s === 'true' || s === '1' || s === 'yes' || s === 'y';
}

function normalizeExamYear(raw) {
  if (raw == null) return null;
  const digits = String(raw).replace(/[^0-9]/g, '').trim();
  if (!digits) return null;
  const n = Number.parseInt(digits, 10);
  if (!Number.isFinite(n) || n <= 0) return null;
  return n;
}

function buildClassificationFromDocument(doc) {
  // draft 문서는 분류 컬럼이 빈 문자열(또는 null)로 저장되어 있다.
  // 추출 단계에서는 빈값을 그대로 유지하여 pb_questions 에 복사한다.
  // 분류 확정은 매니저 '업로드(확정)' 버튼에서
  // `updateQuestionsClassificationForDocument` 가 일괄 처리한다.
  const meta = doc?.meta && typeof doc.meta === 'object' ? doc.meta : {};
  const sourceRaw =
    meta.source_classification && typeof meta.source_classification === 'object'
      ? meta.source_classification
      : {};
  const naesinRaw = sourceRaw.naesin && typeof sourceRaw.naesin === 'object' ? sourceRaw.naesin : {};

  const rawCurriculum = normalizeWhitespace(doc?.curriculum_code || '');
  const rawSourceType = normalizeWhitespace(doc?.source_type_code || '');
  const semesterCandidate = normalizeWhitespace(naesinRaw.semester);
  const examTermCandidate = normalizeWhitespace(naesinRaw.exam_term);

  return {
    // draft 의 빈값은 빈값 그대로 유지한다. 값이 있지만 허용되지 않는 값이면
    // 기본 치환(rev_2022 / school_past) 으로 복구한다.
    curriculum_code: rawCurriculum === ''
      ? ''
      : normalizeCurriculumCode(rawCurriculum, 'rev_2022'),
    source_type_code: rawSourceType === ''
      ? ''
      : normalizeSourceTypeCode(rawSourceType, 'school_past'),
    course_label: normalizeWhitespace(doc?.course_label || ''),
    grade_label: normalizeWhitespace(
      doc?.grade_label || naesinRaw.grade || '',
    ),
    exam_year: normalizeExamYear(doc?.exam_year ?? naesinRaw.year),
    semester_label:
      semesterCandidate === '1학기' || semesterCandidate === '2학기'
        ? semesterCandidate
        : normalizeWhitespace(doc?.semester_label || ''),
    exam_term_label:
      examTermCandidate === '중간' || examTermCandidate === '기말'
        ? examTermCandidate
        : normalizeWhitespace(doc?.exam_term_label || ''),
    school_name: normalizeWhitespace(
      doc?.school_name || naesinRaw.school_name || '',
    ),
    publisher_name: normalizeWhitespace(doc?.publisher_name || ''),
    material_name: normalizeWhitespace(doc?.material_name || ''),
    classification_detail:
      doc?.classification_detail && typeof doc.classification_detail === 'object'
        ? doc.classification_detail
        : {},
  };
}

const PB_SET_TYPES = new Set(['independent_set', 'dependent_set', 'mixed_set']);

function normalizePbSetType(raw, { hasPdfSource = false, meta = {} } = {}) {
  const value = normalizeWhitespace(raw);
  if (PB_SET_TYPES.has(value)) return value;
  const scope = meta?.textbook_scope && typeof meta.textbook_scope === 'object'
    ? meta.textbook_scope
    : {};
  const subKey = normalizeWhitespace(scope.sub_key || scope.subKey).toUpperCase();
  if (hasPdfSource && subKey === 'A') return 'independent_set';
  return 'dependent_set';
}

function collectSetSubLabels(row) {
  const meta = row?.meta && typeof row.meta === 'object' ? row.meta : {};
  const labels = [];
  const push = (value) => {
    const text = normalizeWhitespace(value);
    if (!text) return;
    const label = /^\(.+\)$/.test(text) ? text : `(${text})`;
    if (!labels.includes(label)) labels.push(label);
  };
  for (const part of Array.isArray(meta.answer_parts) ? meta.answer_parts : []) {
    push(part?.sub);
  }
  for (const part of Array.isArray(meta.score_parts) ? meta.score_parts : []) {
    push(part?.sub);
  }
  const stem = String(row?.stem || '');
  for (const match of stem.matchAll(/\(([0-9]+)\)/g)) {
    push(match[1]);
  }
  return labels.length > 0 ? labels : [''];
}

async function reconcileQuestionSetDeliveryUnits({
  academyId,
  documentId,
  rows,
  hasPdfSource,
}) {
  if (!supa || !academyId || !documentId) {
    return { sets: 0, items: 0, deliveryUnits: 0, skipped: true };
  }
  const allRows = Array.isArray(rows) ? rows : [];
  try {
    await supa.from('pb_delivery_units').delete().eq('source_document_id', documentId);
    await supa.from('pb_question_sets').delete().eq('source_document_id', documentId);

    let sets = 0;
    let items = 0;
    let deliveryUnits = 0;
    const deliveryRows = [];

    for (const row of allRows) {
      const meta = row?.meta && typeof row.meta === 'object' ? row.meta : {};
      const isSet = meta.is_set_question === true;
      const questionId = normalizeWhitespace(row?.id || '');
      const questionNumber = normalizeWhitespace(row?.question_number || '');
      const questionUid = normalizeWhitespace(row?.question_uid || '');
      if (!questionId) continue;

      if (!isSet) {
        deliveryRows.push({
          academy_id: academyId,
          source_document_id: documentId,
          question_id: questionId,
          delivery_key: `${documentId}:q:${questionId}`,
          delivery_type: 'single',
          title: questionNumber,
          selectable: true,
          item_refs: [{ question_id: questionId, question_uid: questionUid }],
          render_policy: { version: 1, mode: 'single' },
          source_meta: { question_number: questionNumber },
        });
        continue;
      }

      const setModel = meta.set_model && typeof meta.set_model === 'object' ? meta.set_model : {};
      const setType = normalizePbSetType(setModel.set_type, { hasPdfSource, meta });
      const setKey = normalizeWhitespace(setModel.set_key || questionNumber || questionId);
      const { data: setRow, error: setErr } = await supa
        .from('pb_question_sets')
        .insert({
          academy_id: academyId,
          source_document_id: documentId,
          set_key: setKey,
          set_type: setType,
          common_stem: String(row?.stem || ''),
          render_policy: {
            version: 1,
            mode: setType === 'independent_set'
              ? 'common_stem_with_selectable_items'
              : 'bundle_only',
          },
          source_meta: {
            question_id: questionId,
            question_uid: questionUid,
            question_number: questionNumber,
            compatibility_row: true,
          },
        })
        .select('id')
        .single();
      if (setErr || !setRow?.id) {
        throw new Error(`pb_question_set_insert_failed:${setErr?.message || 'no_id'}`);
      }
      sets += 1;

      const labels = collectSetSubLabels(row);
      const itemRows = labels.map((label, idx) => ({
        academy_id: academyId,
        set_id: setRow.id,
        question_id: questionId,
        question_uid: questionUid || null,
        sub_label: label,
        item_order: idx + 1,
        dependency_group_key: setType === 'independent_set'
          ? `item:${idx + 1}`
          : 'bundle:1',
        item_role: labels.length > 1 ? 'subitem' : 'item',
        meta: { compatibility_question_number: questionNumber },
      }));
      const { data: insertedItems, error: itemErr } = await supa
        .from('pb_question_set_items')
        .insert(itemRows)
        .select('id,sub_label,item_order,dependency_group_key');
      if (itemErr) {
        throw new Error(`pb_question_set_items_insert_failed:${itemErr.message}`);
      }
      const realItems = Array.isArray(insertedItems) ? insertedItems : [];
      items += realItems.length;

      if (setType === 'independent_set') {
        for (const item of realItems) {
          deliveryRows.push({
            academy_id: academyId,
            source_document_id: documentId,
            set_id: setRow.id,
            question_id: questionId,
            delivery_key: `${documentId}:set:${setRow.id}:item:${item.id}`,
            delivery_type: 'independent_item',
            title: `${questionNumber}${item.sub_label || ''}`,
            selectable: true,
            item_refs: [{
              set_item_id: item.id,
              question_id: questionId,
              question_uid: questionUid,
              sub_label: item.sub_label,
            }],
            render_policy: { version: 1, mode: 'common_stem_plus_item' },
            source_meta: { set_type: setType, question_number: questionNumber },
          });
        }
      } else if (setType === 'mixed_set') {
        const byGroup = new Map();
        for (const item of realItems) {
          const group = normalizeWhitespace(item.dependency_group_key || 'bundle:1');
          const bucket = byGroup.get(group) || [];
          bucket.push(item);
          byGroup.set(group, bucket);
        }
        for (const [group, groupItems] of byGroup.entries()) {
          deliveryRows.push({
            academy_id: academyId,
            source_document_id: documentId,
            set_id: setRow.id,
            question_id: questionId,
            delivery_key: `${documentId}:set:${setRow.id}:group:${group}`,
            delivery_type: 'mixed_bundle',
            title: `${questionNumber} ${group}`,
            selectable: true,
            item_refs: groupItems.map((item) => ({
              set_item_id: item.id,
              question_id: questionId,
              question_uid: questionUid,
              sub_label: item.sub_label,
            })),
            render_policy: { version: 1, mode: 'common_stem_plus_dependency_group' },
            source_meta: { set_type: setType, question_number: questionNumber, group },
          });
        }
      } else {
        deliveryRows.push({
          academy_id: academyId,
          source_document_id: documentId,
          set_id: setRow.id,
          question_id: questionId,
          delivery_key: `${documentId}:set:${setRow.id}:bundle`,
          delivery_type: 'dependent_bundle',
          title: questionNumber,
          selectable: true,
          item_refs: realItems.map((item) => ({
            set_item_id: item.id,
            question_id: questionId,
            question_uid: questionUid,
            sub_label: item.sub_label,
          })),
          render_policy: { version: 1, mode: 'bundle_only' },
          source_meta: { set_type: setType, question_number: questionNumber },
        });
      }
    }

    if (deliveryRows.length > 0) {
      const { error: deliveryErr } = await supa
        .from('pb_delivery_units')
        .insert(deliveryRows);
      if (deliveryErr) {
        throw new Error(`pb_delivery_units_insert_failed:${deliveryErr.message}`);
      }
      deliveryUnits = deliveryRows.length;
    }
    return { sets, items, deliveryUnits, skipped: false };
  } catch (err) {
    const msg = compact(err?.message || err);
    console.warn('[pb-extract-worker] set_delivery_reconcile_skip', JSON.stringify({
      documentId,
      message: msg,
    }));
    return { sets: 0, items: 0, deliveryUnits: 0, skipped: true, error: msg };
  }
}

function isLikelyKoreanPersonName(value) {
  const input = normalizeWhitespace(value);
  if (!input) return false;
  if (/^(남궁|황보|제갈|선우|서문|독고|사공)[가-힣]{1,2}$/.test(input)) {
    return true;
  }
  return /^[김이박최정강조윤장임한오서신권황안송류전홍고문양손배백허남심노하곽성차주우구민유나진지엄채원천방공현함변염여추도소석선마길연위표명기반왕금옥육인맹제모][가-힣]{1,2}$/.test(
    input,
  );
}

function stripPotentialWatermarkText(raw, { equation = false } = {}) {
  let s = normalizeWhitespace(raw);
  if (!s) return '';

  s = s
    .replace(/(?:중등|고등)\s*내신기출\s*\d{4}\.\d{2}\.\d{2}/gi, ' ')
    .replace(/무단\s*배포\s*금지/gi, ' ')
    .replace(/수식입니다\.?/gi, ' ')
    .replace(/https?:\/\/\S+/gi, ' ')
    .replace(/www\.\S+/gi, ' ');
  s = normalizeWhitespace(s);
  s = s
    .replace(/^[가-힣]{2,4}[\s\u00A0\u2000-\u200D\u2060]*(?=<\s*보\s*기>)/, '')
    .replace(
      /(^|[\s\u00A0\u2000-\u200D\u2060])[가-힣]{2,4}[\s\u00A0\u2000-\u200D\u2060]*(?=<\s*보\s*기>)/g,
      '$1',
    )
    .trim();

  const lead = s.match(/^([가-힣]{2,4})\s+(.+)$/);
  if (lead && isLikelyKoreanPersonName(lead[1] || '')) {
    const rest = normalizeWhitespace(lead[2] || '');
    const restLooksMath = containsMathSymbol(rest) || /[\d{}_()[\]^\\]/.test(rest);
    const restLooksMeta =
      /^\[?\s*정답/.test(rest) ||
      /^<\s*보\s*기>/.test(rest) ||
      /\[수식\]/.test(rest);
    const restLooksPrompt = /(다음|옳은|설명|구하|계산|고른|것은)/.test(rest);
    if (
      (equation && restLooksMath) ||
      (!equation && (restLooksMath || restLooksMeta || restLooksPrompt))
    ) {
      s = rest;
    }
  }

  return normalizeWhitespace(s);
}

function stripLeadingDialogueDotArtifact(raw) {
  const input = normalizeWhitespace(raw);
  if (!input) return '';
  return normalizeWhitespace(
    input.replace(
      /^(?:\\?cdot|·|∙)\s*(?=[가-힣A-Za-z]{1,8}\s*[:：])/i,
      '',
    ),
  );
}

function isLikelyWatermarkOnlyLine(line) {
  const input = normalizeWhitespace(line);
  if (!input) return false;
  if (/^(?:중등|고등)\s*내신기출\s*\d{4}\.\d{2}\.\d{2}$/.test(input)) {
    return true;
  }
  if (/^무단\s*배포\s*금지$/.test(input)) {
    return true;
  }
  if (/^(https?:\/\/\S+|www\.\S+)$/.test(input)) {
    return true;
  }
  return false;
}

function parseQuestionStart(line) {
  const input = line
    .trim()
    .replace(/．/g, '.')
    .replace(/。/g, '.')
    .replace(/﹒/g, '.')
    .replace(/︒/g, '.');

  const m1 = input.match(/^(\d{1,3})\s*[\.\)]\s*(.+)?$/);
  if (m1) {
    return {
      number: m1[1],
      rest: (m1[2] || '').trim(),
      style: 'dot_number',
      scorePoint: null,
    };
  }
  const m2 = input.match(/^(\d{1,3})\s*번\s*(.+)?$/);
  if (m2) {
    return {
      number: m2[1],
      rest: (m2[2] || '').trim(),
      style: 'beon_number',
      scorePoint: null,
    };
  }
  const m3 = input.match(/^문항\s*(\d{1,3})\s*[:.]?\s*(.+)?$/);
  if (m3) {
    return {
      number: m3[1],
      rest: (m3[2] || '').trim(),
      style: 'label_number',
      scorePoint: null,
    };
  }
  // HWPX preview 텍스트: "[24-1-A] 경신중1 7 [4.00점]" 형태
  const m5 = input.match(/(\d{1,3})\s*\[\s*(\d+(?:\.\d+)?)\s*점\s*\]/);
  if (m5) {
    const scorePoint = Number.parseFloat(m5[2] || '');
    return {
      number: m5[1],
      rest: '',
      style: 'score_header',
      scorePoint: Number.isFinite(scorePoint) ? scorePoint : null,
    };
  }
  // 일부 문서는 문항번호 없이 "[4.00점]" 라인만 먼저 나타난다.
  // 이 경우는 buildQuestionRows에서 미주 정답번호(answerHintMap)와 순서 매칭한다.
  const m6 = input.match(/^\[\s*(\d+(?:\.\d+)?)\s*점\s*\]\s*(.+)?$/);
  if (m6) {
    const scorePoint = Number.parseFloat(m6[1] || '');
    return {
      number: '',
      rest: (m6[2] || '').trim(),
      style: 'score_only',
      scorePoint: Number.isFinite(scorePoint) ? scorePoint : null,
    };
  }
  // 일부 문서는 "5 다음..."처럼 점 없이 시작한다.
  const m4 = input.match(/^(\d{1,3})\s+(.+)$/);
  if (m4) {
    const rest = (m4[2] || '').trim();
    if (
      rest.length >= 6 &&
      /[가-힣A-Za-z]/.test(rest) &&
      !/^[①②③④⑤⑥⑦⑧⑨⑩]/.test(rest)
    ) {
      return {
        number: m4[1],
        rest,
        style: 'space_number',
        scorePoint: null,
      };
    }
  }
  return null;
}

function looksLikePromptLineForImplicitSplit(line) {
  const input = normalizeWhitespace(line);
  if (!input || input.length < 8) return false;
  if (!/[가-힣]/.test(input)) return false;
  if (isSourceMarkerLine(input)) return false;
  if (parseChoiceLine(input)) return false;
  if (parseAnswerLine(input)) return false;
  if (isFigureReferenceLine(input)) return false;
  if (/^([ㄱ-ㅎ]|[①②③④⑤⑥⑦⑧⑨⑩])\s*[\.\)]/.test(input)) return false;
  if (/^[\(（]?\s*[가나다라ㄱㄴㄷㄹ]\s*[\)）]\s/.test(input)) return false;
  return /(다음|옳은|설명|구하|계산|고른|것은|값|함수|수열|부등식|넓이|확률|미분|적분|\?)/.test(
    input,
  );
}

function looksLikeQuestionTerminalLine(line) {
  const input = normalizeWhitespace(line);
  if (!input) return false;
  if (/\?$/.test(input)) return true;
  if (/\?\s*\)$/.test(input)) return true;
  if (/이다\.\s*\)?$/.test(input)) return true;
  if (/\)\s*$/.test(input) && /(단,|이고|이다|상수|자연수)/.test(input)) return true;
  return /(구하시오|고르시오|쓰시오|적으시오|서술하시오|값은|넓이는|옳은 것은|것은|것을)\.?\s*\)?$/.test(
    input,
  );
}

// 세트형(하위문항 (1), (2) ...)임을 암시하는 시그니처가 현재 stem에 이미 존재하는지 검사한다.
// - 직전 stem 라인에 "(1)", "(2)" 등의 소문항 번호 라벨이 보이거나
// - 리드 문장이 "다음을 구하시오/서술하시오/답하시오/차례로 답하시오" 같은 세트형 리드 프롬프트이면 true.
// 이 경우 score_only([N.00점]) 라인은 새 문항 경계가 아니라 같은 문항의
// 소문항 배점 메타데이터로 취급해야 한다.
function hasSetQuestionSignature(stemLines, { answerKey = '' } = {}) {
  const SUB_LABEL_REGEX = /^\s*[\(（]\s*[1-9]\s*[\)）]/;
  // 세트형 리드 프롬프트. "다음 물음에 답하시오"에서 선행 "다음" 이 누락된 경우도
  // 인정한다(HWPX에서 [정답]과 리드가 같은 paragraph로 합쳐져 "다음"이 잘려
  // 들어오는 케이스가 있다).
  const LEAD_PROMPT_REGEX =
    /(다음을\s*(서술|구하|답하|풀|쓰|계산|적)|(?:다음\s*|아래의?\s*)?물음에\s*답하|차례로\s*답하|각각\s*(구하|답하|서술|풀))/;
  const lines = Array.isArray(stemLines) ? stemLines : [];
  for (const raw of lines) {
    const line = normalizeWhitespace(String(raw || ''));
    if (!line) continue;
    if (SUB_LABEL_REGEX.test(line)) return true;
    if (LEAD_PROMPT_REGEX.test(line)) return true;
  }
  // answer_key 가 "(1) x (2) y" 같이 세트형 정답 구조를 가지면 세트형으로 확정한다.
  // (미주 anchor 가 리드 stem 과 합쳐져 들어와 리드 시그니처가 stem 에 아직 없더라도
  //  정답 문자열 자체에서 세트 구조를 확인할 수 있다.)
  const answer = normalizeWhitespace(String(answerKey || ''));
  if (answer) {
    const SET_ANSWER_REGEX =
      /[\(（]\s*1\s*[\)）][^\(（]*[\(（]\s*2\s*[\)）]/;
    if (SET_ANSWER_REGEX.test(answer)) return true;
  }
  return false;
}

// 세트형 stem 의 소문항 라인 앞에 [소문항N] 마커를 주입한다.
//
// 동작:
//  - 라인 시작이 "(1)", "(2)", "（1）" 같은 형태인 라인만 소문항 라벨로 인정.
//    (본문 중간의 "(1)을 이용하여" 같은 인용은 영향 없음.)
//  - 라벨 라인이 2개 이상이고 번호가 단조 증가(중복/역순 없음)일 때만 세트형으로 확신 → 마커 주입.
//  - 원본 라벨 "(N) " 는 그대로 남겨 둔다(렌더러/파서 호환성 유지).
//    렌더러가 추후 마커를 실제로 소비하게 되면 그때 중복 라벨 처리를 정한다.
//  - 이미 [소문항N] 마커가 있는 라인은 건드리지 않는다(idempotent).
//  - 마커는 독립된 라인으로 주입한다 ([문단]/[박스끝] 같은 기존 마커와 같은 스타일).
//
// 반환: { stem: patchedStemString, stemLineAligns, injected: N, alignAdjusted: N }
function injectSubQuestionMarkers(stem, stemLineAligns = null) {
  const text = String(stem || '');
  if (!text) return { stem: text, stemLineAligns, injected: 0, alignAdjusted: 0 };
  const lines = text.split(/\r?\n/);
  const aligns = Array.isArray(stemLineAligns)
    ? stemLineAligns.map((value) => normalizeParagraphAlignSafe(value))
    : null;
  if (aligns) {
    while (aligns.length < lines.length) aligns.push('left');
    if (aligns.length > lines.length) aligns.length = lines.length;
  }
  const SUB_LABEL_LINE_REGEX = /^\s*[\(（]\s*([1-9])\s*[\)）]\s*(.*)$/;
  const EXISTING_MARKER_REGEX = /^\s*\[소문항\s*\d+\]\s*$/;

  // 1) 전수 스캔: 후보 라인들의 (index, num) 수집.
  const candidates = [];
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    if (typeof line !== 'string') continue;
    const m = line.match(SUB_LABEL_LINE_REGEX);
    if (!m) continue;
    const num = Number.parseInt(m[1], 10);
    if (!Number.isFinite(num) || num < 1) continue;
    candidates.push({ index: i, num });
  }
  if (candidates.length < 2) {
    return { stem: text, stemLineAligns: aligns || stemLineAligns, injected: 0, alignAdjusted: 0 };
  }

  // 2) 번호가 단조 증가하는지 검사. (1)(2)(1) 같은 본문 인용 패턴은 제외.
  //    (1)(3) 처럼 건너뛰는 경우는 허용(parseAnswerParts 도 허용).
  for (let i = 1; i < candidates.length; i += 1) {
    if (candidates[i].num <= candidates[i - 1].num) {
      return { stem: text, stemLineAligns: aligns || stemLineAligns, injected: 0, alignAdjusted: 0 };
    }
  }

  // 3) 이미 바로 앞 라인에 [소문항N] 마커가 있으면 해당 후보는 스킵.
  let injected = 0;
  let alignAdjusted = 0;
  // 뒤에서부터 삽입하면 인덱스 밀림 없음.
  for (let ci = candidates.length - 1; ci >= 0; ci -= 1) {
    const { index, num } = candidates[ci];
    const prev = index > 0 ? String(lines[index - 1] || '') : '';
    if (EXISTING_MARKER_REGEX.test(prev)) {
      if (aligns && aligns[index] !== 'left') {
        aligns[index] = 'left';
        alignAdjusted += 1;
      }
      continue;
    }
    lines.splice(index, 0, `[소문항${num}]`);
    if (aligns) {
      aligns.splice(index, 0, 'left');
      if (aligns[index + 1] !== 'left') {
        aligns[index + 1] = 'left';
        alignAdjusted += 1;
      }
    }
    injected += 1;
  }

  if (injected === 0 && alignAdjusted === 0) {
    return { stem: text, stemLineAligns: aligns || stemLineAligns, injected: 0, alignAdjusted: 0 };
  }
  return {
    stem: injected > 0 ? lines.join('\n') : text,
    stemLineAligns: aligns || stemLineAligns,
    injected,
    alignAdjusted,
  };
}

function parseChoiceLine(line) {
  const input = line.trim();
  const circled = input.match(/^([①②③④⑤⑥⑦⑧⑨⑩])\s*(.+)?$/);
  if (circled) {
    return {
      label: circled[1],
      text: (circled[2] || '').trim(),
      style: 'circled',
    };
  }
  const consonant = input.match(/^([ㄱ-ㅎ])\s*[\.\)]\s*(.+)?$/);
  if (consonant) {
    return {
      label: consonant[1],
      text: (consonant[2] || '').trim(),
      style: 'consonant',
    };
  }
  const numeric = input.match(/^\(?([1-5])\)?\s*[\.\)]\s*(.+)?$/);
  if (numeric) {
    return {
      label: numeric[1],
      text: (numeric[2] || '').trim(),
      style: 'numeric',
    };
  }
  return null;
}

function parseAnswerLine(line) {
  const input = normalizeWhitespace(line);
  if (!input) return null;
  const m = input.match(/^\[?\s*정답\s*\]?\s*[:：]?\s*(.+)$/);
  if (!m) return null;
  const raw = stripPotentialWatermarkText(m[1] || '', { equation: true });
  if (!raw) return null;
  if (/^[\[\]]+$/.test(raw)) return null;
  return raw;
}

function parseAnswerLineLoose(line) {
  const input = normalizeWhitespace(line);
  if (!input) return null;
  const marker = input.search(/\[?\s*정답\s*\]?/);
  if (marker < 0) return null;
  return parseAnswerLine(input.slice(marker));
}

// HWPX 에서 [정답] endnote 와 다음 문항의 리드 프롬프트가 같은 paragraph 로 합쳐져
// "[정답] (1) 12 (2) 4 다음 물음에 답하시오." 처럼 한 라인에 들어오는 경우,
// 정답과 stem 리드를 분리한다.
//
// answer 문자열은 parseAnswerLine 을 통해 얻은 "정답" 이후 텍스트.
// 리드 프롬프트는 세트형 리드 패턴(물음에 답하시오 / 다음을 구하시오 …)이거나,
// 새 문항의 시작 패턴("다음 ...를 구하시오?" 같은) 을 포괄한다.
//
// 반환: { answer, lead } (lead 가 없으면 '')
function splitAnswerLineWithTrailingLead(rawAnswer) {
  const answer = normalizeWhitespace(String(rawAnswer || ''));
  if (!answer) return { answer: '', lead: '' };
  // 세트형 정답 구조 "(1) X (2) Y ..." 가 확인되지 않으면 꼬리 리드 분리를 시도하지 않는다.
  // (일반 단일 정답 "12 점을 더 구하시오" 같은 애매한 분리를 방지.)
  const SET_ANSWER_REGEX = /[\(（]\s*1\s*[\)）][^\(（]*[\(（]\s*2\s*[\)）]/;
  if (!SET_ANSWER_REGEX.test(answer)) return { answer, lead: '' };
  // 리드 시작점을 찾는다. 리드 후보:
  //   - "다음 물음에 답하시오" / "물음에 답하시오"
  //   - "다음을 (구하|서술|답하|풀|쓰|계산|적)시오"
  //   - "각각 (구하|서술|답하|풀)시오"
  //   - "아래의? 물음에 답하시오"
  //   - 일반적 새 문항 프롬프트: "다음 ... 구하시오?" 류는 이 분기에선 제외
  //     (세트형 정답이 이미 이 문항의 정답이므로 리드는 곧 이 문항의 stem 리드).
  const LEAD_REGEX =
    /((?:다음\s*|아래의?\s*)?물음에\s*답하[시오]?\s*\.?)|(다음을\s*(?:서술|구하|답하|풀|쓰|계산|적)(?:하)?(?:시오)?\s*\.?)|(차례로\s*답하[시오]?\s*\.?)|(각각\s*(?:구하|답하|서술|풀)(?:하)?(?:시오)?\s*\.?)/;
  const leadMatch = answer.match(LEAD_REGEX);
  if (!leadMatch) return { answer, lead: '' };
  const leadStart = leadMatch.index;
  if (leadStart <= 0) return { answer, lead: '' };
  const head = answer.slice(0, leadStart).trim();
  const tail = answer.slice(leadStart).trim();
  if (!head || !tail) return { answer, lead: '' };
  // head 가 여전히 "(1)...(2)..." 를 포함하는지 확인 (단순히 "(1)" 만 남는 분리는 지양).
  if (!SET_ANSWER_REGEX.test(head)) return { answer, lead: '' };
  return { answer: head, lead: tail };
}

// 세트형 문항의 답 문자열을 부분별로 쪼갠다.
// 지원 형식:
//   "(1) 12 (2) ㄱ, ㄷ (3) 5"    → [{sub:"1", value:"12"}, ...]
//   "① 12 ② ㄱ, ㄷ"             → [{sub:"1", value:"12"}, {sub:"2", value:"ㄱ, ㄷ"}]
//   "1) 12, 2) ㄱ"              → [{sub:"1", value:"12"}, {sub:"2", value:"ㄱ"}]
// 단일 답("12", "①" 등)이거나 부분 번호가 1개뿐이면 null 반환(구조화 불필요).
// 동일한 sub가 중복되거나 번호가 (1)→(3)으로 건너뛰어도 등장 순서대로 그대로 반환한다.
function parseAnswerParts(answer) {
  // 답 문자열에는 워커가 단락 구분용으로 넣은 `[문단]` 마커가 섞여 있을 수 있다.
  // 구조화에서는 무의미하므로 사전에 제거하고, 앞뒤 공백도 정리한다.
  const cleaned = normalizeWhitespace(
    String(answer || '').replace(/\[문단\]/g, ' '),
  );
  if (!cleaned) return null;
  // 번호 라벨 매처: (1), （1）, 1), 1., ①~⑩
  //  - 라벨 뒤에는 공백 또는 문자열 끝이 와야 한다 (숫자만 있는 답의 오분할 방지).
  const labelRegex =
    /(?:[(（]\s*(\d{1,2})\s*[)）]|(\d{1,2})\s*[)．.]|([①②③④⑤⑥⑦⑧⑨⑩]))(?=\s|$)/g;
  const matches = [];
  let m;
  while ((m = labelRegex.exec(cleaned)) !== null) {
    const subRaw = m[1] || m[2] || m[3] || '';
    const sub = /[①②③④⑤⑥⑦⑧⑨⑩]/.test(subRaw) ? circledToNumeric(subRaw) : subRaw;
    if (!sub) continue;
    matches.push({ start: m.index, end: labelRegex.lastIndex, sub });
  }
  if (matches.length < 2) return null;
  // 첫 매치 앞에 공백이 아닌 의미 있는 텍스트가 있으면 "답 전체가 세트형"이라 보기 어렵다.
  // 예: "풀이 (1) x=3 (2) y=5" 같이 답이 아닌 본문이 섞인 경우 구조화를 포기한다.
  const lead = cleaned.slice(0, matches[0].start).trim();
  if (lead) return null;
  const parts = [];
  for (let i = 0; i < matches.length; i += 1) {
    const cur = matches[i];
    const next = matches[i + 1];
    const sliceEnd = next ? next.start : cleaned.length;
    let value = cleaned.slice(cur.end, sliceEnd).trim();
    value = value.replace(/^[,、]\s*/, '').replace(/[,、]\s*$/, '').trim();
    if (!value) continue;
    parts.push({ sub: String(cur.sub), value });
  }
  if (parts.length < 2) return null;
  return parts;
}

// answer_parts 배열을 "(1) 12 (2) ㄱ, ㄷ" 형식의 display 문자열로 포맷한다.
function formatAnswerPartsDisplay(parts) {
  if (!Array.isArray(parts) || parts.length === 0) return '';
  return parts
    .map((p) => {
      const sub = normalizeWhitespace(String(p?.sub || ''));
      const value = normalizeWhitespace(String(p?.value || ''));
      if (!sub || !value) return '';
      return `(${sub}) ${value}`;
    })
    .filter(Boolean)
    .join(' ');
}

function toCircledNumber(value) {
  const n = Number.parseInt(String(value || '').trim(), 10);
  if (!Number.isFinite(n) || n < 1 || n > 10) return String(value || '').trim();
  return String.fromCharCode(0x2460 + n - 1);
}

function circledToNumeric(value) {
  const input = normalizeWhitespace(String(value || ''));
  if (!input) return '';
  const table = {
    '①': '1',
    '②': '2',
    '③': '3',
    '④': '4',
    '⑤': '5',
    '⑥': '6',
    '⑦': '7',
    '⑧': '8',
    '⑨': '9',
    '⑩': '10',
  };
  if (table[input]) return table[input];
  const num = input.match(/^[(（]?\s*(10|[1-9])\s*[)）]?$/);
  if (num) return num[1];
  return '';
}

function answerTokenToChoiceIndex(token) {
  const raw = normalizeWhitespace(String(token || ''));
  if (!raw) return -1;
  const circledMap = {
    '①': 0,
    '②': 1,
    '③': 2,
    '④': 3,
    '⑤': 4,
    '⑥': 5,
    '⑦': 6,
    '⑧': 7,
    '⑨': 8,
    '⑩': 9,
  };
  if (Object.prototype.hasOwnProperty.call(circledMap, raw)) {
    return circledMap[raw];
  }
  const normalized = raw.replace(/[()（）.]/g, '').trim();
  const n = Number.parseInt(normalized, 10);
  if (Number.isFinite(n) && n >= 1) return n - 1;
  return -1;
}

function objectiveAnswerTokens(answerKey) {
  const raw = normalizeWhitespace(String(answerKey || ''));
  if (!raw) return [];

  const circled = raw.match(/[①②③④⑤⑥⑦⑧⑨⑩]/g);
  if (circled && circled.length > 0) {
    const leftover = raw
      .replace(/[①②③④⑤⑥⑦⑧⑨⑩]/g, '')
      .replace(/[,\s/，、ㆍ·()（）.]/g, '')
      .replace(/(?:번|와|과|및|그리고|또는|or|OR)/g, '');
    if (!leftover.trim()) return Array.from(new Set(circled));
  }

  const normalized = raw
    .replace(/[，、ㆍ·]/g, ',')
    .replace(/\s*(?:와|과|및|그리고|또는|or|OR)\s*/g, ',')
    .replace(/\s*\/\s*/g, ',')
    .trim();
  const hasExplicitSeparator = /,/.test(normalized);
  const numericParts = hasExplicitSeparator
    ? normalized.split(',')
    : /^\d{1,2}(?:\s+\d{1,2})+$/.test(normalized)
      ? normalized.split(/\s+/)
      : [normalized];

  const tokens = numericParts
    .map((token) => normalizeWhitespace(token).replace(/[()（）.]/g, '').replace(/번/g, ''))
    .filter(Boolean)
    .map((token) => {
      if (/^(10|[1-9])$/.test(token)) return toCircledNumber(token);
      return token;
    })
    .filter((token) => /^[①②③④⑤⑥⑦⑧⑨⑩]$/.test(token));
  return Array.from(new Set(tokens));
}

function objectiveAnswerToSubjective(answerKey, choices = []) {
  const raw = normalizeWhitespace(String(answerKey || ''));
  if (!raw) return '';
  const tokens = objectiveAnswerTokens(raw);
  if (tokens.length === 0) {
    tokens.push(...raw.split(/[,/]/).map((t) => normalizeWhitespace(t)).filter(Boolean));
  }
  if (tokens.length === 0) tokens.push(raw);
  const normalizedChoices = Array.isArray(choices) ? choices : [];
  const converted = tokens.map((token) => {
    const index = answerTokenToChoiceIndex(token);
    if (index >= 0 && index < normalizedChoices.length) {
      const choice = normalizedChoices[index] || {};
      const text = normalizeWhitespace(String(choice.text || choice.value || ''));
      if (text) return text;
    }
    const numeric = circledToNumeric(token);
    return numeric || token;
  });
  return normalizeWhitespace(converted.join(', '));
}

function normalizeObjectiveAnswerKey(answerKey) {
  const raw = normalizeWhitespace(String(answerKey || ''));
  if (!raw) return '';
  const tokens = objectiveAnswerTokens(raw);
  if (tokens.length > 0) return tokens.join(', ');
  return raw;
}

function expectedObjectiveAnswerCount(question) {
  const stem = normalizeWhitespace(String(question?.stem || ''));
  if (!stem) return 0;
  const digitCount = stem.match(/(?:정답|답|것|설명|보기|문장)?\s*(\d+)\s*개(?:를|을)?\s*(?:고르|찾|택|선택)/);
  if (digitCount) {
    const n = Number.parseInt(digitCount[1], 10);
    if (Number.isFinite(n) && n > 1) return n;
  }
  const koreanCounts = [
    ['두', 2],
    ['둘', 2],
    ['세', 3],
    ['셋', 3],
    ['네', 4],
    ['넷', 4],
  ];
  for (const [word, count] of koreanCounts) {
    const re = new RegExp(`${word}\\s*개(?:를|을)?\\s*(?:고르|찾|택|선택)`);
    if (re.test(stem)) return count;
  }
  if (/(?:모두|전부)\s*(?:고르|찾|택|선택)/.test(stem)) return 2;
  return 0;
}

function shuffleArray(values) {
  const out = [...values];
  for (let i = out.length - 1; i > 0; i -= 1) {
    const j = Math.floor(Math.random() * (i + 1));
    const tmp = out[i];
    out[i] = out[j];
    out[j] = tmp;
  }
  return out;
}

function normalizeAnswerKeyForQuestion(answerKey, question) {
  const raw = normalizeWhitespace(String(answerKey || ''));
  if (!raw) return '';
  const choiceCount = Array.isArray(question?.choices) ? question.choices.length : 0;
  const objectiveHint =
    choiceCount >= 2 ||
    String(question?.question_type || '').trim() === '객관식';
  if (!objectiveHint) return raw;
  return normalizeObjectiveAnswerKey(raw);
}

function renderAnswerEquationTokens(input, equationTokenMap) {
  let out = normalizeWhitespace(
    String(input || '').replace(/\[\[PB_EQ_[^\]]+\]\] ?/g, (match) => {
      const token = match.replace(/ $/, '');
      const eq = equationTokenMap.get(token);
      const rendered = normalizeWhitespace(eq?.latex || eq?.raw || '');
      return rendered || '[수식]';
    }),
  );
  for (let i = 0; i < 4; i += 1) {
    const next = out
      .replace(
        /\{([^{}]+)\}\s*\\over\s*\{([^{}]+)\}/g,
        (_, a, b) => `\\frac{${normalizeWhitespace(a)}}{${normalizeWhitespace(b)}}`,
      )
      .replace(
        /([\-]?\d+(?:\.\d+)?)\s*\\over\s*\{([^{}]+)\}/g,
        (_, a, b) => `\\frac{${normalizeWhitespace(a)}}{${normalizeWhitespace(b)}}`,
      );
    if (next === out) break;
    out = next;
  }
  return normalizeWhitespace(out);
}

function isSourceMarkerLine(line) {
  const input = normalizeWhitespace(line);
  if (!input) return false;
  if (/^\[?\s*출처\s*\]?$/.test(input)) return true;
  if (/^\[?\s*정답\s*\]?\s*[:：]?\s*/.test(input)) return true;
  if (/^\[\d{1,2}\s*-\s*\d\s*-\s*[A-Za-z]\]/.test(input)) return true;
  if (/^제\d+교시$/.test(input)) return true;
  if (/^(수학|국어|영어|과학|사회)영역$/.test(input)) return true;
  if (isLikelyWatermarkOnlyLine(input)) return true;
  return false;
}

function parseInlineCircledChoices(line) {
  const input = line.trim();
  const out = [];
  const re = /([①②③④⑤⑥⑦⑧⑨⑩])\s*([^①②③④⑤⑥⑦⑧⑨⑩]*)(?=[①②③④⑤⑥⑦⑧⑨⑩]|$)/g;
  let m = null;
  while ((m = re.exec(input)) !== null) {
    out.push({
      label: m[1],
      text: normalizeWhitespace(m[2] || ''),
      style: 'inline_circled',
    });
  }
  return out;
}

function leadingStemBeforeInlineChoices(line) {
  const input = normalizeWhitespace(line);
  if (!input) return '';
  const idx = input.search(/[①②③④⑤⑥⑦⑧⑨⑩]/);
  if (idx <= 0) return '';
  return normalizeWhitespace(input.slice(0, idx));
}

function splitLineByQuestionStarts(line) {
  const src = normalizeWhitespace(line)
    .replace(/．/g, '.')
    .replace(/。/g, '.')
    .replace(/﹒/g, '.')
    .replace(/︒/g, '.');
  if (!src) return [];

  const starts = [0];
  const pattern = /(?:^|[\s\]\)])(\d{1,3})\s*[\.\)]\s+/g;
  let m = null;
  while ((m = pattern.exec(src)) !== null) {
    const st = m.index + m[0].indexOf(m[1]);
    if (st > 0) {
      starts.push(st);
    }
  }
  if (starts.length === 1) {
    return [src];
  }
  const uniqueStarts = Array.from(new Set(starts)).sort((a, b) => a - b);
  const out = [];
  for (let i = 0; i < uniqueStarts.length; i += 1) {
    const st = uniqueStarts[i];
    const ed = i + 1 < uniqueStarts.length ? uniqueStarts[i + 1] : src.length;
    const seg = normalizeWhitespace(src.slice(st, ed));
    if (seg) out.push(seg);
  }
  return out.length ? out : [src];
}

function isFigureLine(line) {
  if (/\[\[PB_FIG_[^\]]+\]\]/.test(line)) return true;
  return /(그림|도표|도형|표\s*\d*|자료|그래프|지도)/.test(line);
}

function isFigureReferenceLine(line) {
  const input = normalizeWhitespace(line);
  if (/\[\[PB_FIG_[^\]]+\]\]/.test(input)) return true;
  if (/\[(그림|도표|도형|표\s*\d*|자료|그래프|지도)\]/.test(input)) return true;
  if (/^(그림|도표|도형|그래프|지도)\s*\d*\s*$/i.test(input)) return true;
  return input === '[그림]' || input === '[도형]' || input === '[표]';
}

function isViewBlockLine(line) {
  return /(\[?\s*보기\s*\]?|<보기>|다음\s*자료)/.test(line);
}

function looksLikeEssay(line) {
  return /(서술|논술|풀이\s*과정|설명하시오|구하시오)/.test(line);
}

function containsMathSymbol(line) {
  return /([=+\-*/^]|√|∑|∫|π|∞|≤|≥|≠|sin|cos|tan|log|ln|\bover\b|\[수식\]|[\[\]{}])/i.test(
    line,
  );
}

function normalizeEquationRaw(raw) {
  const s = stripPotentialWatermarkText(raw, { equation: true });
  if (!s) return '';
  return s
    .replace(/`+/g, ' ')
    .replace(/\s+/g, ' ')
    .replace(/\{rm\{([^}]*)\}\}it/gi, '\\mathrm{$1}')
    .replace(/rm\{([^}]*)\}it/gi, '\\mathrm{$1}')
    .replace(/(\{[^{}]*\})\s*over\s*(\{[^{}]*\})/gi, '\\frac$1$2')
    .replace(/\bover\b/gi, '\\over ')
    .replace(/\bLEFT\b/g, '\\left')
    .replace(/\bRIGHT\b/g, '\\right')
    .replace(/\bleft\b/g, '\\left')
    .replace(/\bright\b/g, '\\right')
    .replace(/\bTIMES\b/g, '\\times ')
    .replace(/\btimes\b/g, '\\times ')
    .replace(/\bDIV\b/g, '\\div ')
    .replace(/\bdiv\b/g, '\\div ')
    .replace(/\bRARROW\b/g, '\\Rightarrow ')
    .replace(/\bLARROW\b/g, '\\Leftarrow ')
    .replace(/\bLRARROW\b/g, '\\Leftrightarrow ')
    .replace(/\brarrow\b/g, '\\rightarrow ')
    .replace(/\blarrow\b/g, '\\leftarrow ')
    .replace(/\blrarrow\b/g, '\\leftrightarrow ')
    .replace(/\bSIM\b/g, '\\sim ')
    .replace(/\bAPPROX\b/g, '\\approx ')
    .replace(/\bPROPTO\b/g, '\\propto ')
    .replace(/\bPERMIL\b/g, '\\permil ')
    .replace(/\bDEG\b/g, '^{\\circ}')
    .replace(/\ble\b/gi, '\\le ')
    .replace(/\bge\b/gi, '\\ge ')
    .replace(/\bne\b/gi, '\\ne ')
    .replace(/\blt\b/g, '< ')
    .replace(/\bgt\b/g, '> ')
    .replace(/\bAND\b/g, '\\cap ')
    .replace(/\bOR\b/g, '\\cup ')
    .replace(/\bINF\b/g, '\\infty ')
    .replace(/×/g, '\\times ')
    .replace(/÷/g, '\\div ')
    .replace(/≤/g, '\\le ')
    .replace(/≥/g, '\\ge ')
    .replace(/≠/g, '\\ne ')
    .replace(/∞/g, '\\infty ')
    .replace(/π/g, '\\pi ')
    .replace(/√\s*([a-zA-Z0-9(])/g, '\\sqrt{$1')
    .replace(/\s+/g, ' ')
    .trim();
}

function tryParseXml(raw) {
  try {
    return xmlParser.parse(raw);
  } catch (_) {
    return null;
  }
}

function collectEquationCandidates(xmlText, sectionIndex) {
  const equations = [];
  let eqSeq = 0;
  const replaced = xmlText.replace(
    /<hp:equation[\s\S]*?<\/hp:equation>|<m:oMath[\s\S]*?<\/m:oMath>|<math[\s\S]*?<\/math>/gi,
    (match) => {
      const raw = String(match || '').replace(
        /<hp:shapeComment[\s\S]*?<\/hp:shapeComment>/gi,
        ' ',
      );
      const scriptMatch = raw.match(/<hp:script[^>]*>([\s\S]*?)<\/hp:script>/i);
      const preferred = scriptMatch
        ? htmlDecode(String(scriptMatch[1] || ''))
        : htmlDecode(
            raw
              .replace(/<[^>]+>/g, ' ')
              .replace(/\s+/g, ' ')
              .trim(),
          );
      const text = stripPotentialWatermarkText(preferred, { equation: true });
      const token = `[[PB_EQ_${sectionIndex}_${eqSeq++}]]`;
      equations.push({
        token,
        raw: text || preferred,
        latex: normalizeEquationRaw(text || preferred),
        mathml: '',
        confidence: 0.82,
      });
      return ` ${token} `;
    },
  );
  return { replacedXml: replaced, equations };
}

function extractEndNoteAnswerHints(xmlText, equations = []) {
  const hints = {};
  const equationTokenMap = new Map();
  for (const eq of equations || []) {
    const token = normalizeWhitespace(eq?.token || '');
    if (!token) continue;
    equationTokenMap.set(token, eq);
  }
  const noteRegex = /<hp:endNote\b([^>]*)>([\s\S]*?)<\/hp:endNote>/gi;
  let m = null;
  while ((m = noteRegex.exec(xmlText)) !== null) {
    const attrs = String(m[1] || '');
    const body = String(m[2] || '');
    const n1 = attrs.match(/\bnumber\s*=\s*["']?(\d{1,3})["']?/i);
    const n2 = body.match(/<hp:autoNum[^>]*\bnum="(\d{1,3})"[^>]*>/i);
    const qNumberRaw = n1?.[1] || n2?.[1] || '';
    const qNumber = String(Number.parseInt(qNumberRaw, 10) || '').trim();
    if (!qNumber) continue;

    const textNodes = Array.from(
      body.matchAll(/<hp:t>([\s\S]*?)<\/hp:t>/gi),
      (x) =>
        normalizeWhitespace(
          htmlDecode(String(x[1] || ''))
            .replace(/<[^>]+>/g, ' ')
            .replace(/\s+/g, ' '),
        ),
    ).filter(Boolean);
    const bodyPlain = normalizeWhitespace(
      htmlDecode(body)
        .replace(/<[^>]+>/g, ' ')
        .replace(/\s+/g, ' '),
    );
    const candidates = [
      normalizeWhitespace(textNodes.join(' ')),
      bodyPlain,
      ...textNodes,
    ].filter(Boolean);
    let answer = null;
    for (const candidate of candidates) {
      answer = parseAnswerLine(candidate) || parseAnswerLineLoose(candidate);
      if (answer) break;
    }
    // <hp:t> 만으로 뽑힌 후보는 endnote 내부 equation(수식) 토큰이 빠져 있어
    // "," 같은 구분자만 남아 실제 답으로 쓸 수 없는 경우가 있다.
    // 이때는 bodyPlain(equation 토큰 포함)을 재사용해 답을 다시 만든다.
    const isDegenerateAnswer = (() => {
      if (!answer) return false;
      const compact = String(answer).replace(/[\s,，、·]/g, '');
      if (compact.length === 0) return true;
      // 토큰/수식 없이 쉼표/빈 값만 있으면 비정상으로 판단한다.
      return (
        !/[0-9A-Za-z가-힣]/.test(compact) && !/\[\[PB_EQ_/.test(String(answer))
      );
    })();
    if (!answer || isDegenerateAnswer) {
      const refreshed =
        parseAnswerLine(bodyPlain) || parseAnswerLineLoose(bodyPlain);
      if (refreshed) answer = refreshed;
    }
    if (!answer) continue;
    const rendered = renderAnswerEquationTokens(answer, equationTokenMap);
    if (!rendered || /^[\[\]]+$/.test(rendered)) continue;
    hints[qNumber] = rendered;
  }
  return hints;
}

/**
 * 조건제시 박스에서 (가)(나)(다)… 가 한 줄로 붙을 때 줄바꿈 삽입.
 * 표는 행/셀 경계도 줄바꿈으로 보존한 뒤 동일 규칙 적용.
 */
function splitKoreanConditionMarkersInBoxText(text) {
  const raw = String(text || '');
  const lines = raw.split(/\n/);
  const out = [];
  for (const line of lines) {
    let s = normalizeWhitespace(line);
    if (!s) continue;
    s = s.replace(
      /([^\n])\s*((?:\(|（)\s*[가나다라마바사아자차카타파하]\s*(?:\)|\）))/g,
      '$1\n$2',
    );
    for (const part of s.split('\n')) {
      const t = normalizeWhitespace(part);
      if (t) out.push(t);
    }
  }
  return out.join('\n');
}

// <hp:pic> 블록에서 binaryItemIDRef 속성을 추출해 PB_FIG 토큰으로 치환한다.
//   HWPX(OWPML) 스펙: <hp:pic> 안 <hp:img binaryItemIDRef="imageN" .../> 가 해당 그림의
//   BinData 아이템 ID를 지시한다. Contents/content.hpf 의 <opf:binItem id="imageN"
//   href="BinData/binN.ext"/> 매니페스트와 연결되어 figure_worker 가 직접 바이트를 집어올 수 있다.
//
//   ID 추출에 성공하면 [[PB_FIG_<id>]] 토큰(영문 ID만 안전하게 유지) 으로,
//   실패하면 기존 [그림] 문자열로 폴백한다. 문서에 같은 그림을 두 번 이상 쓸 수 있으므로
//   ID 는 globally unique 하다는 보장은 없다 — 같은 그림의 중복 참조는 의도적이다.
const PB_FIG_ID_SAFE_RE = /^[A-Za-z0-9_.-]{1,128}$/;
function sanitizePbFigId(raw) {
  const v = String(raw || '').trim();
  if (!v) return '';
  return PB_FIG_ID_SAFE_RE.test(v) ? v : '';
}
function replaceHwpPicsWithIdTokens(source) {
  return String(source || '').replace(
    /<hp:pic[\s\S]*?<\/hp:pic>/gi,
    (block) => {
      // 동일 <hp:pic> 블록 안에는 <hp:img binaryItemIDRef="..."> 가 최소 1개.
      //   여러 이미지가 중첩된 복합 pic 은 드물지만, 있다면 첫 번째 ID 만 사용한다.
      const m = block.match(/binaryItemIDRef\s*=\s*"([^"]+)"/i)
        || block.match(/binaryItemIDRef\s*=\s*'([^']+)'/i);
      const id = sanitizePbFigId(m?.[1]);
      if (id) return ` [[PB_FIG_${id}]] `;
      return ' [그림] ';
    },
  );
}
// <hp:shape> 역시 내부에 이미지(hp:img)가 포함되면 동일 ID 연결을 시도한다.
function replaceHwpShapesWithIdTokens(source) {
  return String(source || '').replace(
    /<hp:shape[\s\S]*?<\/hp:shape>/gi,
    (block) => {
      const m = block.match(/binaryItemIDRef\s*=\s*"([^"]+)"/i)
        || block.match(/binaryItemIDRef\s*=\s*'([^']+)'/i);
      const id = sanitizePbFigId(m?.[1]);
      if (id) return ` [[PB_FIG_${id}]] `;
      return ' [도형] ';
    },
  );
}

function transformParagraphBodyToLines(body) {
  let s = String(body || '');
  s = s.replace(
    /<hp:autoNum[^>]*num="(\d+)"[^>]*>[\s\S]*?<\/hp:autoNum>/gi,
    ' $1 ',
  );
  s = replaceHwpPicsWithIdTokens(s);
  s = replaceHwpShapesWithIdTokens(s);
  s = replaceHwpSoftBreakElements(s);
  s = s.replace(
    /<\/(hp:run|hp:r|hp:span|hp:ctrl|hp:subList|hp:tc|hp:tr|tr|li)>/gi,
    ' ',
  );
  s = s.replace(/<[^>]+>/g, ' ');
  s = htmlDecode(s);
  return splitParagraphTextToLines(s);
}

function normalizeBoxTextParts(line) {
  return splitKoreanConditionMarkersInBoxText(line)
    .split('\n')
    .map((part) => normalizeWhitespace(part))
    .filter(Boolean);
}

function flattenTableXmlToRows(tableXml, { alignResolver = null } = {}) {
  const rows = [];
  const rowRegex = /<hp:tr\b[^>]*>([\s\S]*?)<\/hp:tr>/gi;
  let rowMatch = null;
  let hasRow = false;

  while ((rowMatch = rowRegex.exec(String(tableXml || ''))) !== null) {
    hasRow = true;
    const rowBody = String(rowMatch[1] || '');
    rows.push({ text: '[표행]', align: 'left' });

    const cellRegex = /<hp:tc\b[^>]*>([\s\S]*?)<\/hp:tc>/gi;
    let cellMatch = null;
    let hasCell = false;

    while ((cellMatch = cellRegex.exec(rowBody)) !== null) {
      hasCell = true;
      const cellBody = String(cellMatch[1] || '');
      rows.push({ text: '[표셀]', align: 'left' });

      const paragraphRegex = /<hp:p\b([^>]*)>([\s\S]*?)<\/hp:p>/gi;
      let p = null;
      let hasParagraph = false;
      while ((p = paragraphRegex.exec(cellBody)) !== null) {
        hasParagraph = true;
        const attrs = String(p[1] || '');
        const body = String(p[2] || '');
        const align = normalizeParagraphAlignSafe(
          resolveParagraphAlign(attrs, body, alignResolver),
        );
        const paragraphLines = transformParagraphBodyToLines(body);
        for (const line of paragraphLines) {
          for (const text of normalizeBoxTextParts(line)) {
            rows.push({ text, align });
          }
        }
      }

      if (!hasParagraph) {
        const fallbackLines = normalizeBoxTextParts(cellBody.replace(/<[^>]+>/g, ' '));
        for (const text of fallbackLines) {
          rows.push({ text, align: 'left' });
        }
      }
    }

    if (!hasCell) {
      rows.push({ text: '[표셀]', align: 'left' });
      const fallbackLines = normalizeBoxTextParts(rowBody.replace(/<[^>]+>/g, ' '));
      for (const text of fallbackLines) {
        rows.push({ text, align: 'left' });
      }
    }
  }

  if (!hasRow) return [];
  return rows;
}

function shouldEmitTableMarkers(tableXml) {
  const xml = String(tableXml || '');
  if (!xml) return false;

  const rowMatches = xml.match(/<hp:tr\b/gi) || [];
  if (rowMatches.length === 0) return false;

  const cellMatches = xml.match(/<hp:tc\b/gi) || [];
  // 1x1 표는 조건제시 박스로 간주한다.
  if (rowMatches.length <= 1 && cellMatches.length <= 1) return false;

  const plainText = htmlDecode(xml.replace(/<[^>]+>/g, ' '));
  // <보기>가 들어간 표는 기존 보기박스로 처리한다.
  if (/<\s*보\s*기\s*>/.test(plainText)) return false;

  return true;
}

function flattenBoxXmlToRows(match, { table = false, alignResolver = null } = {}) {
  const shouldUseTableMarkers = table && shouldEmitTableMarkers(match);
  if (shouldUseTableMarkers) {
    const tableRows = flattenTableXmlToRows(match, { alignResolver });
    if (tableRows.length > 0) return tableRows;
  }

  let inner = replaceHwpShapesWithIdTokens(
    replaceHwpPicsWithIdTokens(String(match || '')),
  );
  if (table) {
    inner = inner.replace(/<\/hp:tr>/gi, '\n');
    inner = inner.replace(/<\/hp:tc>/gi, '\n');
  }
  const rows = [];
  const paragraphRegex = /<hp:p\b([^>]*)>([\s\S]*?)<\/hp:p>/gi;
  let m = null;
  while ((m = paragraphRegex.exec(inner)) !== null) {
    const attrs = String(m[1] || '');
    const body = String(m[2] || '');
    const align = normalizeParagraphAlignSafe(
      resolveParagraphAlign(attrs, body, alignResolver),
    );
    const paragraphLines = transformParagraphBodyToLines(body);
    for (const line of paragraphLines) {
      const normalized = normalizeBoxTextParts(line);
      for (const one of normalized) {
        rows.push({
          text: one,
          align,
        });
      }
    }
  }
  if (rows.length > 0) return rows;
  const fallback = normalizeBoxTextParts(inner.replace(/<[^>]+>/g, ' '));
  return fallback.map((text) => ({
    text,
    align: 'left',
  }));
}

function flattenBoxXmlToParagraphXml(match, { table = false, alignResolver = null } = {}) {
  const rows = flattenBoxXmlToRows(match, { table, alignResolver });
  if (rows.length === 0) return '';
  const out = ['<hp:p><hp:t>[박스시작]</hp:t></hp:p>'];
  for (const row of rows) {
    const align = normalizeParagraphAlignSafe(row.align);
    out.push(
      `<hp:p pb-align="${align}"><hp:t>${encodeXmlText(row.text)}</hp:t></hp:p>`,
    );
  }
  out.push('<hp:p><hp:t>[박스끝]</hp:t></hp:p>');
  return out.join('');
}

function transformXmlToLines(xmlText, sectionIndex, { alignResolver = null } = {}) {
  const { replacedXml, equations } = collectEquationCandidates(
    xmlText,
    sectionIndex,
  );
  const answerHints = extractEndNoteAnswerHints(replacedXml, equations);
  // 문단 내부/외부에 섞여 있는 미주/각주 본문은 문제 텍스트 추출에서 제외한다.
  // 단, 미주가 있었던 위치는 텍스트 마커([미주])로 남겨둬서 파서가 "어느 문항의 끝"인지
  // 판별할 수 있도록 한다. 세트형 문항에서 연이어 나오는 [N점] 배점 헤더를
  // 같은 문항의 부분 배점으로 병합할지, 새 문항 경계로 분리할지 결정할 때
  // 이 위치 정보가 결정적으로 사용된다.
  let purifiedXml = replacedXml
    .replace(
      /<hp:endNote[\s\S]*?<\/hp:endNote>/gi,
      '<hp:t>[미주]</hp:t>',
    )
    .replace(/<hp:footNote[\s\S]*?<\/hp:footNote>/gi, ' ')
    .replace(/<hp:note[\s\S]*?<\/hp:note>/gi, ' ');

  // hp:tbl (표) → [박스시작]/[박스끝] 마커로 감싸기 (hp:p로 래핑하여 파싱 보장)
  purifiedXml = purifiedXml.replace(/<hp:tbl\b[\s\S]*?<\/hp:tbl>/gi, (match) => {
    return flattenBoxXmlToParagraphXml(match, {
      table: true,
      alignResolver,
    });
  });

  // hp:rect (사각형 도형) → [박스시작]/[박스끝] 마커로 감싸기
  purifiedXml = purifiedXml.replace(/<hp:rect\b[\s\S]*?<\/hp:rect>/gi, (match) => {
    return flattenBoxXmlToParagraphXml(match, {
      table: false,
      alignResolver,
    });
  });

  const lines = [];
  let lineIndex = 0;
  let page = 1;
  let prevParagraphHadContent = false;
  const paragraphRegex = /<hp:p\b([^>]*)>([\s\S]*?)<\/hp:p>/gi;
  let m = null;
  while ((m = paragraphRegex.exec(purifiedXml)) !== null) {
    const attrs = String(m[1] || '');
    const body = String(m[2] || '');
    const paragraphAlign = normalizeParagraphAlignSafe(
      resolveParagraphAlign(attrs, body, alignResolver),
    );
    if (/pageBreak\s*=\s*["']1["']/.test(attrs) && lineIndex > 0) {
      page += 1;
    }
    const paragraphLines = transformParagraphBodyToLines(body);
    if (paragraphLines.length === 0) {
      if (prevParagraphHadContent) {
        lines.push({
          section: sectionIndex,
          index: lineIndex,
          page,
          text: '[문단]',
          align: paragraphAlign,
        });
        lineIndex += 1;
        prevParagraphHadContent = false;
      }
      continue;
    }

    // 이전 문단과 현재 문단 사이에 문단 경계 마커 삽입
    if (prevParagraphHadContent) {
      lines.push({
        section: sectionIndex,
        index: lineIndex,
        page,
        text: '[문단]',
        align: paragraphAlign,
      });
      lineIndex += 1;
    }

    const isStructuralMarker = paragraphLines.length === 1 &&
      /^\[(박스시작|박스끝|문단|표행|표셀)\]$/.test(paragraphLines[0]);
    for (const text of paragraphLines) {
      lines.push({
        section: sectionIndex,
        index: lineIndex,
        page,
        text,
        align: paragraphAlign,
      });
      lineIndex += 1;
    }
    if (!isStructuralMarker) {
      prevParagraphHadContent = paragraphLines.length > 0;
    }
  }

  return { lines, equations, answerHints };
}

function countScoreHeadersFromXml(xmlText) {
  const textNodes = Array.from(
    xmlText.matchAll(/<hp:t>([\s\S]*?)<\/hp:t>/gi),
    (m) =>
      normalizeWhitespace(
        String(m[1] || '')
          .replace(/<[^>]+>/g, ' ')
          .replace(/\s+/g, ' '),
      ),
  ).filter(Boolean);
  return textNodes.filter(
    (line) =>
      /(\d{1,3})\s*\[\s*(\d+(?:\.\d+)?)\s*점\s*\]/.test(line) ||
      /^\[\s*(\d+(?:\.\d+)?)\s*점\s*\]$/.test(line),
  ).length;
}

function extractPreviewTextLines(zip, sectionIndex) {
  const previewEntry = zip
    .getEntries()
    .find((entry) => !entry.isDirectory && /prvtext\.txt$/i.test(entry.entryName));
  if (!previewEntry) {
    return { path: '', lines: [] };
  }
  const raw = decodeZipEntry(previewEntry)
    .replace(/\r\n?/g, '\n')
    .replace(/\t+/g, ' ');
  const lines = normalizeWhitespace(raw)
    .split('\n')
    .map((line) => {
      const cleaned = String(line)
        .replace(/<\s*>/g, ' ')
        .replace(/<<\s*/g, ' ')
        .replace(/\s*>>/g, ' ');
      return normalizeWhitespace(cleaned);
    })
    .filter((line) => line.length > 0)
    .map((text, idx) => ({
      section: sectionIndex,
      index: idx,
      page: 1,
      text,
    }));
  return {
    path: previewEntry.entryName,
    lines,
  };
}

function sectionSortKey(path) {
  const m = path.match(/section(\d+)\.xml/i);
  if (!m) return 1 << 30;
  return Number.parseInt(m[1], 10);
}

function guessQuestionType(question) {
  if (question.choices.length >= 2) return '객관식';
  if (question.flags.includes('essay_hint')) return '서술형';
  if (/서술|논술/.test(question.stem)) return '서술형';
  return '주관식';
}

function scoreQuestion(question) {
  let score = 0.45;
  if (question.question_number) score += 0.2;
  if (question.stem.length >= 20) score += 0.15;
  if (question.choices.length >= 4) score += 0.1;
  if (question.equations.length > 0) score += 0.05;
  if (question.figure_refs.length > 0) score += 0.05;
  if (question.stem.length < 8) score -= 0.2;
  if (question.question_type === '미분류') score -= 0.15;
  return round4(clamp(score, 0, 1));
}

function detectExamProfile(stats) {
  if (stats.mockMarkers > 0) return 'mock';
  if (stats.circledChoices >= Math.max(3, Math.floor(stats.questionCount * 0.6))) {
    return 'csat';
  }
  return 'naesin';
}

function stripEquationPlaceholders(input) {
  return normalizeWhitespace(
    String(input || '')
      .replace(/\[\[PB_EQ_[^\]]+\]\]/g, ' ')
      .replace(/\[수식\]/g, ' ')
      .replace(/`+/g, ''),
  );
}

function placeholderTokenCount(input) {
  const s = String(input || '');
  const m1 = s.match(/\[\[PB_EQ_[^\]]+\]\]/g) || [];
  const m2 = s.match(/\[수식\]/g) || [];
  return m1.length + m2.length;
}

function meaningfulChoiceTextCount(choices) {
  return (choices || []).filter((c) => {
    const text = stripEquationPlaceholders(c?.text || '');
    return text.length > 0;
  }).length;
}

function questionDataQualityMetrics(result) {
  const questions = result?.questions || [];
  let nonEmptyStemCount = 0;
  let meaningfulChoiceQuestionCount = 0;
  let equationQuestionCount = 0;
  for (const q of questions) {
    const stem = stripEquationPlaceholders(q?.stem || '');
    if (stem.length >= 6) nonEmptyStemCount += 1;
    if (meaningfulChoiceTextCount(q?.choices || []) > 0) {
      meaningfulChoiceQuestionCount += 1;
    }
    if ((q?.equations || []).length > 0) {
      equationQuestionCount += 1;
    }
  }
  return {
    nonEmptyStemCount,
    meaningfulChoiceQuestionCount,
    equationQuestionCount,
  };
}

function countPlaceholderTokensInBuilt(result) {
  let count = 0;
  for (const q of result?.questions || []) {
    count += placeholderTokenCount(q?.stem || '');
    for (const c of q?.choices || []) {
      count += placeholderTokenCount(c?.text || '');
    }
  }
  return count;
}

function parseQualityScore(result) {
  const q = Number(result?.questions?.length || 0);
  const eqRefs = Number(result?.stats?.equationRefs || 0);
  const low = Number(result?.stats?.lowConfidenceCount || 0);
  const metrics = questionDataQualityMetrics(result);
  return (
    q * 1000 +
    metrics.nonEmptyStemCount * 45 +
    metrics.meaningfulChoiceQuestionCount * 35 +
    metrics.equationQuestionCount * 25 +
    eqRefs * 4 -
    low * 30
  );
}

function enrichXmlQuestionsWithPreview(xmlBuilt, previewBuilt, threshold) {
  if (!xmlBuilt || !previewBuilt) {
    return { built: xmlBuilt, stemPatched: 0, choicePatched: 0 };
  }
  const previewMap = new Map(
    (previewBuilt.questions || []).map((q) => [String(q.question_number || ''), q]),
  );
  let stemPatched = 0;
  let choicePatched = 0;
  const xmlQuestions = xmlBuilt.questions || [];
  for (const [idx, q] of xmlQuestions.entries()) {
    const pq = previewMap.get(String(q.question_number || ''));
    if (!pq) continue;
    const currentStem = normalizeWhitespace(q.stem || '');
    const previewStem = normalizeWhitespace(pq.stem || '');
    const prevStem = idx > 0 ? normalizeWhitespace(xmlQuestions[idx - 1]?.stem || '') : '';
    const duplicatedPrevStem =
      prevStem.length >= 6 &&
      previewStem.length >= 6 &&
      previewStem === prevStem &&
      String(xmlQuestions[idx - 1]?.question_number || '') !== String(q.question_number || '');
    const currentHasPrompt = /(다음|옳은|설명|구하|계산|만족)/.test(currentStem);
    const previewHasPrompt = /(다음|옳은|설명|구하|계산|만족)/.test(previewStem);
    if (
      previewStem.length >= 6 &&
      !(duplicatedPrevStem && currentStem.length >= 6) &&
      (
        currentStem.length < 6 ||
        /^(김정우|홍길동)$/.test(currentStem) ||
        (previewHasPrompt && !currentHasPrompt)
      )
    ) {
      q.stem = previewStem;
      stemPatched += 1;
    }

    const currentMeaningful = meaningfulChoiceTextCount(q.choices);
    const previewMeaningful = meaningfulChoiceTextCount(pq.choices);
    if (
      (currentMeaningful === 0 && previewMeaningful > 0) ||
      ((q.choices || []).length === 0 && (pq.choices || []).length > 0)
    ) {
      q.choices = (pq.choices || []).map((choice) => ({
        label: choice.label,
        text: choice.text,
      }));
      choicePatched += 1;
    }

    q.question_type = guessQuestionType(q);
    q.confidence = scoreQuestion(q);
    q.flags = Array.from(
      new Set((q.flags || []).filter((f) => f && f !== 'low_confidence')),
    );
    if (q.confidence < threshold) {
      q.flags.push('low_confidence');
    }
    q.meta = {
      ...(q.meta || {}),
      preview_enriched: true,
    };
  }

  if (stemPatched + choicePatched > 0) {
    xmlBuilt.stats = {
      ...(xmlBuilt.stats || {}),
      lowConfidenceCount: (xmlBuilt.questions || []).filter(
        (q) => Number(q.confidence || 0) < threshold,
      ).length,
    };
  }
  return { built: xmlBuilt, stemPatched, choicePatched };
}

function pointToPageWeight(scorePoint) {
  const p = Number(scorePoint || 0);
  if (!Number.isFinite(p) || p <= 0) return 1.0;
  if (p >= 10) return 1.8;
  if (p >= 7) return 1.55;
  if (p >= 5) return 1.3;
  return 1.0;
}

function estimateSourcePagesByPointWeight(questions) {
  if (!questions || questions.length === 0) return;
  const pageCapacity = 4.0;
  let page = 1;
  let used = 0.0;
  for (const q of questions) {
    const scorePoint = Number(q?.meta?.score_point || q?.score_point || 0);
    const weight = pointToPageWeight(scorePoint);
    if (used > 0 && used + weight > pageCapacity + 1e-6) {
      page += 1;
      used = 0.0;
    }
    q.source_page = page;
    q.source_anchors = {
      ...(q.source_anchors || {}),
      page_estimated: true,
      page_weight: weight,
      page_capacity: pageCapacity,
    };
    used += weight;
  }
}

function choiceLabelByIndex(index) {
  const table = ['①', '②', '③', '④', '⑤', '⑥', '⑦', '⑧', '⑨', '⑩'];
  return table[index] || String(index + 1);
}

function normalizeChoiceLabel(label, index) {
  const input = normalizeWhitespace(label);
  if (!input) return choiceLabelByIndex(index);
  if (/^[①②③④⑤⑥⑦⑧⑨⑩]$/.test(input)) return input;
  const numeric = input.match(/^([1-9]|10)$/);
  if (numeric) return choiceLabelByIndex(Number.parseInt(numeric[1], 10) - 1);
  const circledNumeric = input.match(/^[(（]?\s*([1-9]|10)\s*[)）]?$/);
  if (circledNumeric) {
    return choiceLabelByIndex(Number.parseInt(circledNumeric[1], 10) - 1);
  }
  return input;
}

function scoreQuestionRowQuality(q) {
  const stem = normalizeWhitespace(q?.stem || '');
  const equations = Array.isArray(q?.equations) ? q.equations.length : 0;
  const meaningfulChoices = meaningfulChoiceTextCount(q?.choices || []);
  let score = 0;
  score += stem.length;
  score += equations * 40;
  score += meaningfulChoices * 18;
  if ((q?.flags || []).includes('source_marker')) score -= 80;
  if (/^\[?\s*정답\s*\]?/.test(stem)) score -= 160;
  if (stem.length < 4 && equations === 0) score -= 120;
  return score;
}

function mergeQuestionRows(primary, secondary) {
  const out = primary;
  if (!out.answer_key && secondary.answer_key) {
    out.answer_key = secondary.answer_key;
  }
  if ((out.score_point == null || out.score_point === 0) && secondary.score_point) {
    out.score_point = secondary.score_point;
  }
  out.sourcePatterns = Array.from(
    new Set([...(out.sourcePatterns || []), ...(secondary.sourcePatterns || [])]),
  );
  out.flags = Array.from(new Set([...(out.flags || []), ...(secondary.flags || [])]));
  const pStart = Number(out?.source_anchors?.line_start ?? 0);
  const sStart = Number(secondary?.source_anchors?.line_start ?? pStart);
  const pEnd = Number(out?.source_anchors?.line_end ?? pStart);
  const sEnd = Number(secondary?.source_anchors?.line_end ?? pEnd);
  out.source_anchors = {
    ...(out.source_anchors || {}),
    line_start: Math.min(pStart, sStart),
    line_end: Math.max(pEnd, sEnd),
  };
  return out;
}

function dedupeQuestionsByNumber(questions) {
  const byNumber = new Map();
  const order = [];
  for (const q of questions || []) {
    const key = normalizeWhitespace(String(q?.question_number || ''));
    if (!key) continue;
    if (!byNumber.has(key)) {
      byNumber.set(key, q);
      order.push(key);
      continue;
    }
    const current = byNumber.get(key);
    const currentScore = scoreQuestionRowQuality(current);
    const nextScore = scoreQuestionRowQuality(q);
    if (nextScore > currentScore) {
      byNumber.set(key, mergeQuestionRows(q, current));
    } else {
      byNumber.set(key, mergeQuestionRows(current, q));
    }
  }
  return order.map((k) => byNumber.get(k)).filter(Boolean);
}

function normalizeGeminiChoices(rawChoices) {
  const out = [];
  if (Array.isArray(rawChoices)) {
    for (const item of rawChoices) {
      if (item == null) continue;
      if (typeof item === 'string') {
        const parsed = parseChoiceLine(item);
        if (parsed) {
          out.push({
            label: parsed.label,
            text: normalizeWhitespace(parsed.text || ''),
          });
        } else {
          out.push({
            label: '',
            text: normalizeWhitespace(item),
          });
        }
        continue;
      }
      const m = item || {};
      const label = safeToString(m.label || m.key || m.no || '');
      const text = safeToString(m.text || m.value || m.choice || m.content || '');
      if (!label && !text) continue;
      out.push({
        label: normalizeWhitespace(label),
        text: normalizeWhitespace(text),
      });
    }
  } else if (typeof rawChoices === 'string') {
    const inline = parseInlineCircledChoices(rawChoices);
    if (inline.length >= 2) {
      for (const c of inline) {
        out.push({
          label: c.label,
          text: normalizeWhitespace(c.text || ''),
        });
      }
    }
  }

  const normalized = [];
  const dedup = new Set();
  for (const [i, c] of out.entries()) {
    const label = normalizeChoiceLabel(c.label, i);
    const text = normalizeWhitespace(c.text || '');
    const key = `${label}|${text}`;
    if (dedup.has(key)) continue;
    dedup.add(key);
    normalized.push({ label, text });
    if (normalized.length >= 10) break;
  }
  return normalized;
}

function normalizeGeminiDrafts(payload) {
  const list = Array.isArray(payload)
    ? payload
    : Array.isArray(payload?.questions)
      ? payload.questions
      : [];
  const drafts = [];
  for (const [i, item] of list.entries()) {
    const q = item || {};
    const numberRaw = safeToString(
      q.question_number || q.number || q.no || q.index || '',
    );
    const numberMatch = numberRaw.match(/\d{1,3}/);
    const questionNumber = numberMatch ? numberMatch[0] : String(i + 1);
    const stem = normalizeWhitespace(
      safeToString(q.stem || q.question || q.prompt || q.body || q.text || ''),
    );
    const choices = normalizeGeminiChoices(q.choices || q.options || q.items || []);
    if (!stem && choices.length === 0) continue;
    const questionTypeRaw = normalizeWhitespace(
      safeToString(q.question_type || q.type || ''),
    );
    const questionType =
      questionTypeRaw || (choices.length >= 2 ? '객관식' : '주관식');

    let confidence = Number.parseFloat(String(q.confidence ?? ''));
    if (!Number.isFinite(confidence)) {
      if (choices.length >= 4) confidence = 0.9;
      else if (choices.length >= 2) confidence = 0.84;
      else confidence = 0.76;
    }
    drafts.push({
      questionNumber,
      stem,
      choices,
      questionType,
      confidence: round4(clamp(confidence, 0.05, 0.99)),
    });
  }
  return drafts;
}

function buildGeminiQuestionRows({
  academyId,
  documentId,
  extractJobId,
  drafts,
  threshold,
}) {
  const questions = [];
  const stats = {
    circledChoices: 0,
    viewBlocks: 0,
    figureLines: 0,
    mockMarkers: 0,
    csatMarkers: 0,
    equationRefs: 0,
    questionCount: 0,
  };

  for (const [i, draft] of drafts.entries()) {
    if (/모의고사|학력평가|전국연합/.test(draft.stem)) {
      stats.mockMarkers += 1;
    }
    if (/대학수학능력시험|수능/.test(draft.stem)) {
      stats.csatMarkers += 1;
    }
    if (isViewBlockLine(draft.stem)) {
      stats.viewBlocks += 1;
    }
    if (isFigureLine(draft.stem)) {
      stats.figureLines += 1;
    }
    if (containsMathSymbol(draft.stem)) {
      stats.equationRefs += 1;
    }
    stats.circledChoices += draft.choices.filter((c) =>
      /^[①②③④⑤⑥⑦⑧⑨⑩]$/.test(c.label),
    ).length;

    const flags = ['ai_assisted'];
    if (containsMathSymbol(draft.stem)) flags.push('math_symbol');
    if (looksLikeEssay(draft.stem)) flags.push('essay_hint');
    if (isViewBlockLine(draft.stem)) flags.push('view_block');
    if (isFigureLine(draft.stem)) flags.push('contains_figure');

    const confidence = round4(clamp(draft.confidence, 0, 1));
    if (confidence < threshold) {
      flags.push('low_confidence');
    }

    questions.push({
      academy_id: academyId,
      document_id: documentId,
      extract_job_id: extractJobId,
      source_page: 1,
      source_order: i + 1,
      question_number: draft.questionNumber,
      question_type: draft.questionType,
      stem: draft.stem,
      choices: draft.choices,
      figure_refs: isFigureLine(draft.stem) ? [draft.stem] : [],
      equations: [],
      source_anchors: {
        mode: 'gemini',
        line_start: i,
        line_end: i,
      },
      confidence,
      flags: Array.from(new Set(flags)),
      is_checked: false,
      reviewed_by: null,
      reviewed_at: null,
      reviewer_notes: '',
      meta: {
        parse_version: 'gemini_v1',
        source_patterns: ['gemini_fallback'],
        contains_figure: isFigureLine(draft.stem),
        contains_equation: containsMathSymbol(draft.stem),
      },
    });
  }

  stats.questionCount = questions.length;
  const lowConfidenceCount = questions.filter(
    (q) => q.confidence < threshold,
  ).length;
  const examProfile = detectExamProfile(stats);

  return {
    questions,
    stats: {
      ...stats,
      sourceLineCount: drafts.length,
      segmentedLineCount: 0,
      lowConfidenceCount,
      examProfile,
    },
  };
}

function shouldTryGeminiFallback(parsed, built) {
  if (!GEMINI_ENABLED) return false;
  const qCount = Number(built?.questions?.length || 0);
  if (qCount < GEMINI_MIN_FALLBACK_QUESTIONS) return true;
  const expectedFromScoreHeader = Number(parsed?.hints?.scoreHeaderCount || 0);
  if (
    expectedFromScoreHeader > 0 &&
    qCount < Math.max(1, Math.floor(expectedFromScoreHeader * 0.7))
  ) {
    return true;
  }
  const eqCount = Number(built?.stats?.equationRefs || 0);
  if (qCount >= 10 && eqCount === 0) return true;
  const low = Number(built?.stats?.lowConfidenceCount || 0);
  return qCount > 0 && low / Math.max(1, qCount) >= 0.95;
}

function shouldAttemptGemini(parsed, built) {
  if (!GEMINI_ENABLED) return false;
  if (GEMINI_PRIORITY === 'always') return true;
  if (GEMINI_PRIORITY === 'auto') return true;
  return shouldTryGeminiFallback(parsed, built);
}

function shouldAcceptGeminiResult(parsed, baseBuilt, geminiBuilt) {
  const geminiCount = Number(geminiBuilt?.questions?.length || 0);
  if (geminiCount <= 0) return false;

  const expectedFromHeaders = Number(parsed?.hints?.scoreHeaderCount || 0);
  if (
    expectedFromHeaders > 0 &&
    geminiCount < Math.max(1, Math.floor(expectedFromHeaders * 0.5))
  ) {
    return false;
  }

  if (GEMINI_PRIORITY === 'always') {
    return true;
  }
  const geminiScore = parseQualityScore(geminiBuilt);
  const baseScore = parseQualityScore(baseBuilt);
  if (GEMINI_PRIORITY === 'auto') {
    return geminiScore >= baseScore;
  }
  return geminiScore > baseScore;
}

function shouldAllowFullGeminiReplace(parsed, baseBuilt, geminiBuilt) {
  const geminiCount = Number(geminiBuilt?.questions?.length || 0);
  const baseCount = Number(baseBuilt?.questions?.length || 0);
  const expectedFromHeaders = Number(parsed?.hints?.scoreHeaderCount || 0);
  if (geminiCount <= 0) return false;
  if (countPlaceholderTokensInBuilt(geminiBuilt) > 0) return false;
  if (expectedFromHeaders > 0) {
    if (geminiCount < Math.max(1, Math.floor(expectedFromHeaders * 0.85))) {
      return false;
    }
  }
  if (baseCount > 0 && geminiCount < Math.max(1, Math.floor(baseCount * 0.9))) {
    return false;
  }
  const baseMetrics = questionDataQualityMetrics(baseBuilt);
  const geminiMetrics = questionDataQualityMetrics(geminiBuilt);
  if (
    baseMetrics.equationQuestionCount > 0 &&
    geminiMetrics.equationQuestionCount === 0
  ) {
    return false;
  }
  return true;
}

function enrichBuiltWithGemini(baseBuilt, geminiBuilt, threshold) {
  if (!baseBuilt || !geminiBuilt) {
    return { built: baseBuilt, touchedCount: 0, stemPatched: 0, choicePatched: 0 };
  }
  const geminiMap = new Map(
    (geminiBuilt.questions || []).map((q) => [String(q.question_number || ''), q]),
  );

  let touchedCount = 0;
  let stemPatched = 0;
  let choicePatched = 0;
  const baseQuestions = baseBuilt.questions || [];
  for (const [idx, q] of baseQuestions.entries()) {
    const g = geminiMap.get(String(q.question_number || ''));
    if (!g) continue;

    let touched = false;
    const baseStem = normalizeWhitespace(q.stem || '');
    const geminiStem = normalizeWhitespace(g.stem || '');
    const geminiStemSanitized = stripEquationPlaceholders(geminiStem);
    const geminiStemHasPlaceholder = placeholderTokenCount(geminiStem) > 0;
    const prevStem =
      idx > 0 ? normalizeWhitespace(baseQuestions[idx - 1]?.stem || '') : '';
    const duplicatePrevGeminiStem =
      prevStem.length >= 6 &&
      geminiStemSanitized.length >= 6 &&
      geminiStemSanitized === prevStem &&
      String(baseQuestions[idx - 1]?.question_number || '') !==
        String(q.question_number || '');
    const baseHasPrompt = /(다음|옳은|설명|구하|계산|만족)/.test(baseStem);
    const geminiHasPrompt = /(다음|옳은|설명|구하|계산|만족)/.test(
      geminiStemSanitized,
    );
    if (
      !geminiStemHasPlaceholder &&
      geminiStemSanitized.length >= 6 &&
      !(duplicatePrevGeminiStem && baseStem.length >= 6) &&
      (
        baseStem.length < 6 ||
        geminiStemSanitized.length > baseStem.length + 8 ||
        (geminiHasPrompt && !baseHasPrompt)
      )
    ) {
      q.stem = geminiStemSanitized;
      touched = true;
      stemPatched += 1;
    }

    const baseMeaningful = meaningfulChoiceTextCount(q.choices || []);
    const geminiMeaningful = meaningfulChoiceTextCount(g.choices || []);
    const geminiHasPlaceholderChoices = (g.choices || []).some(
      (c) => placeholderTokenCount(c?.text || '') > 0,
    );
    if (!geminiHasPlaceholderChoices && geminiMeaningful > baseMeaningful) {
      q.choices = (g.choices || []).map((c) => ({
        label: c.label,
        text: c.text,
      }));
      touched = true;
      choicePatched += 1;
    }

    if (normalizeWhitespace(g.question_type || '').length > 0) {
      q.question_type = g.question_type;
    } else {
      q.question_type = guessQuestionType(q);
    }

    q.confidence = scoreQuestion(q);
    q.flags = Array.from(
      new Set([...(q.flags || []).filter((f) => f && f !== 'low_confidence'), 'ai_assisted']),
    );
    if (q.confidence < threshold) {
      q.flags.push('low_confidence');
    }
    q.meta = {
      ...(q.meta || {}),
      gemini_enriched: true,
    };

    if (touched) {
      touchedCount += 1;
    }
  }

  if (touchedCount > 0) {
    baseBuilt.stats = {
      ...(baseBuilt.stats || {}),
      lowConfidenceCount: (baseBuilt.questions || []).filter(
        (q) => Number(q.confidence || 0) < threshold,
      ).length,
    };
  }
  return { built: baseBuilt, touchedCount, stemPatched, choicePatched };
}

function buildGeminiSourceText(parsed) {
  const fromXml = [];
  if (Array.isArray(parsed?.sections)) {
    for (const sec of parsed.sections) {
      for (const line of sec.lines || []) {
        fromXml.push(normalizeWhitespace(line.text || ''));
      }
    }
  }
  const fromPreview = [];
  if (parsed?.previewSection?.lines?.length) {
    for (const line of parsed.previewSection.lines) {
      fromPreview.push(normalizeWhitespace(line.text || ''));
    }
  }
  const xmlText = fromXml.filter(Boolean).join('\n');
  const previewText = fromPreview.filter(Boolean).join('\n');
  const joined = xmlText.length >= previewText.length ? xmlText : previewText;
  if (joined.length <= GEMINI_INPUT_MAX_CHARS) return joined;
  return joined.slice(0, GEMINI_INPUT_MAX_CHARS);
}

async function callGeminiQuestionExtractor({ sourceText, examProfileHint }) {
  if (!GEMINI_ENABLED) return [];
  const text = normalizeWhitespace(sourceText || '');
  if (!text) return [];

  const prompt = [
    '너는 한국 중/고등학교 시험지에서 문항을 구조화하는 추출기다.',
    '아래 원문을 읽고 문항 배열을 JSON으로만 반환해라.',
    '반드시 JSON 스키마를 지켜라:',
    '{ "questions": [ { "question_number": "1", "stem": "...", "choices": [ { "label": "①", "text": "..." } ], "question_type": "객관식" } ] }',
    '규칙:',
    '- question_number는 숫자 문자열.',
    '- stem에는 문항 본문을 넣는다.',
    '- 보기(선택지)가 있으면 choices에 최대 10개까지 넣는다.',
    '- 선택지가 없으면 choices는 빈 배열.',
    '- JSON 외의 설명 문구를 절대 출력하지 마라.',
    `- 시험 유형 힌트: ${examProfileHint || 'naesin'}`,
    '',
    '원문:',
    text,
  ].join('\n');

  const url =
    `https://generativelanguage.googleapis.com/v1beta/models/` +
    `${encodeURIComponent(GEMINI_MODEL)}:generateContent?key=` +
    `${encodeURIComponent(GEMINI_API_KEY)}`;

  const body = {
    contents: [{ role: 'user', parts: [{ text: prompt }] }],
    generationConfig: {
      temperature: 0.1,
      responseMimeType: 'application/json',
    },
  };

  const { signal, clear } = withTimeout(null, GEMINI_TIMEOUT_MS);
  let res = null;
  try {
    res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
      signal,
    });
  } finally {
    clear();
  }

  if (!res?.ok) {
    const errText = res ? await res.text() : 'gemini_no_response';
    throw new Error(`gemini_http_${res?.status || 'unknown'}:${compact(errText)}`);
  }

  const payload = await res.json();
  const modelText = (payload?.candidates || [])
    .flatMap((c) => c?.content?.parts || [])
    .map((p) => p?.text || '')
    .join('\n')
    .trim();
  const parsed = parseJsonLoose(modelText);
  if (!parsed) {
    throw new Error('gemini_invalid_json');
  }
  return normalizeGeminiDrafts(parsed);
}

function normalizeGeminiObjectiveDrafts(payload) {
  const list = Array.isArray(payload)
    ? payload
    : Array.isArray(payload?.questions)
      ? payload.questions
      : [];
  const out = [];
  for (const [i, item] of list.entries()) {
    const q = item || {};
    const numberRaw = safeToString(
      q.question_number || q.number || q.no || q.index || '',
    );
    const numberMatch = numberRaw.match(/\d{1,3}/);
    const questionNumber = numberMatch ? numberMatch[0] : String(i + 1);
    const correctText = normalizeWhitespace(
      safeToString(q.correct_text || q.correct || q.answer || q.correct_choice || ''),
    );
    let distractors = [];
    if (Array.isArray(q.distractors)) {
      distractors = q.distractors;
    } else if (Array.isArray(q.wrong_choices)) {
      distractors = q.wrong_choices;
    } else if (Array.isArray(q.wrong)) {
      distractors = q.wrong;
    } else if (Array.isArray(q.choices)) {
      distractors = q.choices
        .filter((c) => c?.is_correct !== true && c?.correct !== true)
        .map((c) => c?.text || c?.value || c?.choice || '');
    }
    const normalizedDistractors = [];
    for (const d of distractors || []) {
      const text = normalizeWhitespace(safeToString(d));
      if (!text) continue;
      normalizedDistractors.push(text);
      if (normalizedDistractors.length >= 8) break;
    }
    if (!questionNumber) continue;
    out.push({
      questionNumber,
      correctText,
      distractors: normalizedDistractors,
    });
  }
  return out;
}

async function callGeminiObjectiveGenerator({
  subjectiveQuestions,
  examProfileHint,
}) {
  if (!GEMINI_ENABLED) return new Map();
  if (!GEMINI_KEY_CONFIGURED) return new Map();
  const list = Array.isArray(subjectiveQuestions) ? subjectiveQuestions : [];
  if (list.length === 0) return new Map();

  const compacted = list
    .map((q) => ({
      questionNumber: String(q.questionNumber || '').trim(),
      stem: compact(normalizeWhitespace(q.stem || ''), 240),
      subjectiveAnswer: compact(normalizeWhitespace(q.subjectiveAnswer || ''), 120),
    }))
    .filter((q) => q.questionNumber && q.stem)
    .slice(0, 50);
  if (compacted.length === 0) return new Map();

  const prompt = [
    '너는 한국 수학 문항을 객관식 보기로 변환하는 생성기다.',
    '각 문항마다 정답 1개와 오답 4개를 만들어 총 5개 보기를 구성해라.',
    '반드시 JSON만 반환해라.',
    '출력 스키마:',
    '{ "questions": [ { "question_number": "1", "correct_text": "...", "distractors": ["...", "...", "...", "..."] } ] }',
    '규칙:',
    '- question_number는 입력과 동일하게 유지',
    '- correct_text는 문항의 정답(수치/수식 가능)',
    '- distractors는 정답과 겹치지 않는 그럴듯한 오답 4개',
    '- JSON 외 설명 문구 금지',
    `- 시험 유형 힌트: ${examProfileHint || 'naesin'}`,
    '',
    '입력 문항:',
    JSON.stringify(compacted),
  ].join('\n');

  const url =
    `https://generativelanguage.googleapis.com/v1beta/models/` +
    `${encodeURIComponent(GEMINI_MODEL)}:generateContent?key=` +
    `${encodeURIComponent(GEMINI_API_KEY)}`;

  const body = {
    contents: [{ role: 'user', parts: [{ text: prompt }] }],
    generationConfig: {
      temperature: 0.45,
      responseMimeType: 'application/json',
    },
  };

  const { signal, clear } = withTimeout(null, GEMINI_TIMEOUT_MS);
  let res = null;
  try {
    res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
      signal,
    });
  } finally {
    clear();
  }

  if (!res?.ok) {
    const errText = res ? await res.text() : 'gemini_no_response';
    throw new Error(`gemini_objective_http_${res?.status || 'unknown'}:${compact(errText)}`);
  }

  const payload = await res.json();
  const modelText = (payload?.candidates || [])
    .flatMap((c) => c?.content?.parts || [])
    .map((p) => p?.text || '')
    .join('\n')
    .trim();
  const parsed = parseJsonLoose(modelText);
  if (!parsed) {
    throw new Error('gemini_objective_invalid_json');
  }

  const map = new Map();
  for (const row of normalizeGeminiObjectiveDrafts(parsed)) {
    map.set(String(row.questionNumber || '').trim(), row);
  }
  return map;
}

function buildFallbackDistractors(correctText) {
  const answer = normalizeWhitespace(correctText || '');
  if (!answer) return [];

  const frac = answer.match(/^(-?\d+)\s*\/\s*(-?\d+)$/);
  if (frac) {
    const a = Number.parseInt(frac[1], 10);
    const b = Number.parseInt(frac[2], 10);
    if (Number.isFinite(a) && Number.isFinite(b) && b !== 0) {
      return [
        `${a + 1}/${b}`,
        `${a - 1}/${b}`,
        `${a}/${b + (b > 0 ? 1 : -1)}`,
        `${b}/${a === 0 ? 1 : a}`,
      ];
    }
  }

  const numeric = Number.parseFloat(answer);
  if (Number.isFinite(numeric)) {
    return [
      String(numeric + 1),
      String(numeric - 1),
      String(numeric * 2),
      String(-numeric),
    ];
  }

  return [
    `${answer} + 1`,
    `${answer} - 1`,
    `${answer}^2`,
    `${answer}/2`,
  ];
}

async function enrichQuestionsWithDualMode({
  questions,
  examProfileHint,
}) {
  const out = Array.isArray(questions) ? questions : [];
  const targets = [];

  for (const q of out) {
    const rawAnswer = normalizeWhitespace(String(q?.answer_key || q?.meta?.answer_key || ''));
    const hasObjectiveChoices = meaningfulChoiceTextCount(q?.choices || []) >= 2;
    const objectiveAnswerKey = hasObjectiveChoices
      ? normalizeObjectiveAnswerKey(
          normalizeAnswerKeyForQuestion(rawAnswer, {
            choices: q?.choices || [],
            question_type: '객관식',
          }),
        )
      : '';

    q.allow_objective = true;
    q.allow_subjective = true;
    q.objective_generated = false;
    q.objective_choices = hasObjectiveChoices
      ? (q.choices || []).map((choice, idx) => ({
          label: normalizeChoiceLabel(choice?.label || '', idx),
          text: normalizeWhitespace(choice?.text || ''),
        }))
      : [];
    q.objective_answer_key = objectiveAnswerKey;
    q.subjective_answer = hasObjectiveChoices
      ? objectiveAnswerToSubjective(
          objectiveAnswerKey || rawAnswer,
          q.objective_choices,
        )
      : normalizeWhitespace(rawAnswer);

    if (hasObjectiveChoices) {
      const expectedCount = expectedObjectiveAnswerCount(q);
      const actualCount = objectiveAnswerTokens(objectiveAnswerKey || rawAnswer).length;
      if (expectedCount > 1 && actualCount > 0 && actualCount < expectedCount) {
        q.flags = Array.from(
          new Set([
            ...(q.flags || []),
            'objective_multi_answer_incomplete_suspected',
          ]),
        );
        q.confidence = Math.min(Number(q.confidence || 1), 0.72);
        q.objective_answer_expected_count = expectedCount;
        q.objective_answer_key_count = actualCount;
      }
    }

    if (!hasObjectiveChoices) {
      targets.push({
        questionNumber: String(q.question_number || '').trim(),
        stem: normalizeWhitespace(q.stem || ''),
        subjectiveAnswer: q.subjective_answer || '',
        question: q,
      });
    }
  }

  if (targets.length > 0) {
    let generatedMap = new Map();
    let generationError = '';
    try {
      generatedMap = await callGeminiObjectiveGenerator({
        subjectiveQuestions: targets,
        examProfileHint,
      });
    } catch (err) {
      generationError = compact(err?.message || err);
    }

    for (const target of targets) {
      const q = target.question;
      const generated = generatedMap.get(target.questionNumber);
      const correctText = normalizeWhitespace(
        generated?.correctText || target.subjectiveAnswer || '',
      );
      const distractors = Array.isArray(generated?.distractors)
        ? generated.distractors
        : [];
      const candidateTexts = [];
      if (correctText) candidateTexts.push(correctText);
      for (const d of distractors) {
        const text = normalizeWhitespace(String(d || ''));
        if (!text) continue;
        if (candidateTexts.some((x) => normalizeWhitespace(x) === text)) continue;
        candidateTexts.push(text);
        if (candidateTexts.length >= 5) break;
      }
      if (candidateTexts.length < 5 && correctText) {
        for (const d of buildFallbackDistractors(correctText)) {
          const text = normalizeWhitespace(String(d || ''));
          if (!text) continue;
          if (candidateTexts.some((x) => normalizeWhitespace(x) === text)) continue;
          candidateTexts.push(text);
          if (candidateTexts.length >= 5) break;
        }
      }

      if (candidateTexts.length >= 5 && correctText) {
        const optionTexts = shuffleArray(candidateTexts.slice(0, 5));
        const correctIndex = optionTexts.findIndex(
          (x) => normalizeWhitespace(x) === normalizeWhitespace(correctText),
        );
        if (correctIndex >= 0) {
          q.objective_choices = optionTexts.map((text, idx) => ({
            label: choiceLabelByIndex(idx),
            text: normalizeWhitespace(text),
          }));
          q.objective_answer_key = choiceLabelByIndex(correctIndex);
          q.objective_generated = true;
          if (!generated) {
            q.flags = Array.from(
              new Set([...(q.flags || []), 'objective_generated_fallback']),
            );
          }
          if (!q.subjective_answer) {
            q.subjective_answer = normalizeWhitespace(correctText);
          }
        } else {
          q.allow_objective = false;
          q.objective_choices = [];
          q.objective_answer_key = '';
          q.flags = Array.from(new Set([...(q.flags || []), 'objective_generation_failed']));
        }
      } else {
        q.allow_objective = false;
        q.objective_choices = [];
        q.objective_answer_key = '';
        q.flags = Array.from(new Set([...(q.flags || []), 'objective_generation_failed']));
      }
      if (generationError && !q.objective_generated) {
        q.flags = Array.from(
          new Set([...(q.flags || []), 'objective_generation_error']),
        );
      }
    }
  }

  for (const q of out) {
    const rawAnswerKey = normalizeWhitespace(
      String(q?.answer_key || q?.meta?.answer_key || ''),
    );
    const rawSubjective = normalizeWhitespace(String(q.subjective_answer || ''));
    // 세트형(하위문항 (1),(2),...) 문항이면 답 문자열을 sub/value 배열로 구조화한다.
    // 채점/렌더링/편집이 답에 어떤 문자(슬래시, 문단 등)가 들어와도 안전하게 동작할 수 있도록,
    // 문자열 answer_key 는 display 용으로 그대로 두고 구조화는 meta.answer_parts 에 둔다.
    // 세트형 시그니처가 stem 에 없거나 parseAnswerParts 가 null 을 내면(단일 답) 필드는 생략한다.
    const stemLines = Array.isArray(q.stem_lines)
      ? q.stem_lines
      : String(q.stem || '').split(/\r?\n/);
    const isSetShape = hasSetQuestionSignature(stemLines, {
      answerKey: rawSubjective || rawAnswerKey,
    });
    const partsSource = rawSubjective || rawAnswerKey;
    const parts = isSetShape ? parseAnswerParts(partsSource) : null;

    // 세트형으로 확정된 문항은 stem 에 [소문항N] 마커를 주입해
    // 렌더러/편집 UI 가 소문항 경계를 명시적으로 인식할 수 있도록 한다.
    // (본문 중간의 "(1)을 이용하여" 같은 인용은 마커가 붙지 않아 영향 없음.)
    let subMarkerCount = 0;
    let patchedStemLineAligns = null;
    if (isSetShape) {
      const existingStemLineAligns = Array.isArray(q.meta?.stem_line_aligns)
        ? q.meta.stem_line_aligns
        : Array.isArray(q.meta?.stemLineAligns)
          ? q.meta.stemLineAligns
          : null;
      const patched = injectSubQuestionMarkers(q.stem, existingStemLineAligns);
      if (patched.injected > 0 || patched.alignAdjusted > 0) {
        q.stem = patched.stem;
        if (Array.isArray(q.stem_lines)) {
          q.stem_lines = q.stem.split(/\r?\n/);
        }
        if (Array.isArray(patched.stemLineAligns)) {
          patchedStemLineAligns = patched.stemLineAligns;
        }
        subMarkerCount = patched.injected;
      }
    }

    q.meta = {
      ...(q.meta || {}),
      answer_key: rawAnswerKey,
      allow_objective: q.allow_objective !== false,
      allow_subjective: q.allow_subjective !== false,
      objective_answer_key: normalizeWhitespace(String(q.objective_answer_key || '')),
      subjective_answer: rawSubjective,
      objective_generated: q.objective_generated === true,
      is_set_question: isSetShape === true,
      ...(q.objective_answer_expected_count
        ? { objective_answer_expected_count: q.objective_answer_expected_count }
        : {}),
      ...(q.objective_answer_key_count
        ? { objective_answer_key_count: q.objective_answer_key_count }
        : {}),
      ...(parts ? { answer_parts: parts } : {}),
      ...(patchedStemLineAligns
        ? {
            stem_line_aligns: patchedStemLineAligns,
            stemLineAligns: patchedStemLineAligns,
          }
        : {}),
      ...(subMarkerCount > 0 ? { sub_question_marker_count: subMarkerCount } : {}),
    };
  }

  const subjectiveTargets = out.filter((q) => meaningfulChoiceTextCount(q?.choices || []) < 2);
  const objectiveGeneratedCount = out.filter((q) => q.objective_generated === true).length;
  const objectiveUnavailableCount = out.filter((q) => q.allow_objective === false).length;

  return {
    questions: out,
    stats: {
      subjectiveTargetCount: subjectiveTargets.length,
      objectiveGeneratedCount,
      objectiveUnavailableCount,
    },
  };
}

// 단일 문항에 대해 AI(Gemini) 기반 5지선다 보기 + 정답 라벨을 생성한다.
// 기존 `enrichQuestionsWithDualMode` 는 "추출 배치" 전체를 훑어 보기가 없는 모든 주관식에
// 일괄 적용하는 형태라, 매니저 UI 에서 "문항 1개만 방금 객관식으로 토글" 하는 시나리오에는
// 그대로 쓰기 어렵다. 그래서 동일한 프롬프트/폴백 파이프라인을 그대로 유지하되
// 반환 타입만 "단일 문항용 draft" 로 좁힌 래퍼를 제공한다.
//
// 반환 객체:
//   choices       : [{label, text}, ...]  // 0개이면 생성 실패
//   answerKey     : '①'|'②'|...|''
//   generated     : boolean               // Gemini 가 실제로 5개를 맞춰 준 경우 true
//   usedFallback  : boolean               // 폴백 distractor(숫자/수식 휴리스틱) 로 보충된 경우 true
//   error         : string|null
export async function generateObjectiveDraftForQuestion({
  questionNumber,
  stem,
  subjectiveAnswer,
  examProfileHint,
} = {}) {
  const normalizedStem = normalizeWhitespace(String(stem || ''));
  const normalizedAnswer = normalizeWhitespace(String(subjectiveAnswer || ''));
  if (!normalizedStem) {
    return {
      choices: [],
      answerKey: '',
      generated: false,
      usedFallback: false,
      error: 'stem_empty',
    };
  }

  const qnum = String(questionNumber || '1').trim() || '1';
  let generatedMap = new Map();
  let error = null;
  try {
    generatedMap = await callGeminiObjectiveGenerator({
      subjectiveQuestions: [
        {
          questionNumber: qnum,
          stem: normalizedStem,
          subjectiveAnswer: normalizedAnswer,
        },
      ],
      examProfileHint,
    });
  } catch (err) {
    error = compact(err?.message || err);
  }

  const generated = generatedMap.get(qnum);
  const correctText = normalizeWhitespace(
    generated?.correctText || normalizedAnswer || '',
  );
  const distractors = Array.isArray(generated?.distractors)
    ? generated.distractors
    : [];

  const candidateTexts = [];
  if (correctText) candidateTexts.push(correctText);
  for (const d of distractors) {
    const text = normalizeWhitespace(String(d || ''));
    if (!text) continue;
    if (candidateTexts.some((x) => normalizeWhitespace(x) === text)) continue;
    candidateTexts.push(text);
    if (candidateTexts.length >= 5) break;
  }

  let usedFallback = false;
  if (candidateTexts.length < 5 && correctText) {
    for (const d of buildFallbackDistractors(correctText)) {
      const text = normalizeWhitespace(String(d || ''));
      if (!text) continue;
      if (candidateTexts.some((x) => normalizeWhitespace(x) === text)) continue;
      candidateTexts.push(text);
      usedFallback = true;
      if (candidateTexts.length >= 5) break;
    }
  }

  if (candidateTexts.length < 5 || !correctText) {
    return {
      choices: [],
      answerKey: '',
      generated: false,
      usedFallback,
      error: error || 'insufficient_choices',
    };
  }

  const optionTexts = shuffleArray(candidateTexts.slice(0, 5));
  const correctIndex = optionTexts.findIndex(
    (x) => normalizeWhitespace(x) === normalizeWhitespace(correctText),
  );
  if (correctIndex < 0) {
    return {
      choices: [],
      answerKey: '',
      generated: false,
      usedFallback,
      error: error || 'correct_not_found',
    };
  }

  return {
    choices: optionTexts.map((text, idx) => ({
      label: choiceLabelByIndex(idx),
      text: normalizeWhitespace(text),
    })),
    answerKey: choiceLabelByIndex(correctIndex),
    generated: Boolean(generated),
    usedFallback,
    error,
  };
}

function buildQuestionRows({ academyId, documentId, extractJobId, parsed, threshold }) {
  const allLines = [];
  let sourceLineCount = 0;
  let segmentedLineCount = 0;
  const equationMap = new Map();
  const answerHintMap = new Map();

  for (const sec of parsed.sections) {
    for (const [k, v] of Object.entries(sec.answerHints || {})) {
      const key = String(Number.parseInt(String(k || ''), 10) || '').trim();
      const value = normalizeWhitespace(String(v || ''));
      if (!key || !value) continue;
      if (!answerHintMap.has(key)) {
        answerHintMap.set(key, value);
      }
    }
    for (const eq of sec.equations) {
      equationMap.set(eq.token, {
        raw: eq.raw,
        latex: eq.latex,
        mathml: '',
        confidence: eq.confidence ?? 0.82,
      });
    }
    for (const line of sec.lines) {
      sourceLineCount += 1;
      const segments = splitLineByQuestionStarts(line.text);
      if (segments.length > 1) {
        segmentedLineCount += segments.length - 1;
      }
      for (const seg of segments) {
        allLines.push({
          section: sec.section,
          lineIndex: line.index,
          page: Number(line.page || 1),
          text: seg,
          align: normalizeParagraphAlignSafe(line.align),
        });
      }
    }
  }

  // fallback: 라인 분할 후에도 없는 경우에는 원본 라인을 그대로 다시 시도한다.
  if (allLines.length === 0) {
    for (const sec of parsed.sections) {
      for (const line of sec.lines) {
        allLines.push({
          section: sec.section,
          lineIndex: line.index,
          page: Number(line.page || 1),
          text: line.text,
          align: normalizeParagraphAlignSafe(line.align),
        });
      }
    }
  }

  const questions = [];
  let current = null;
  let splitAfterScoreAnnotation = false;
  // "[미주]" 마커가 나타난 이후로 아직 score_only([N.00점])를 하나도 보지 못한 상태인지.
  // HWPX에서 미주(endnote)는 각 문항 본문 끝에 anchor되므로, 미주 이후 처음 나오는
  // score_only는 거의 항상 새 문항의 시작이다. 반면 미주 없이 연속되는 score_only는
  // 같은 세트형 문항의 부분 배점(예: (1) 4점 / (2) 7점)일 가능성이 매우 높다.
  let sawEndnoteSinceLastScore = false;
  const stats = {
    circledChoices: 0,
    viewBlocks: 0,
    figureLines: 0,
    mockMarkers: 0,
    csatMarkers: 0,
    equationRefs: 0,
    questionCount: 0,
  };
  const hintedQuestionNumbers = Array.from(answerHintMap.keys())
    .map((key) => Number.parseInt(String(key || ''), 10))
    .filter((n) => Number.isFinite(n) && n > 0)
    .sort((a, b) => a - b)
    .map((n) => String(n));
  let hintedCursor = 0;
  const usedQuestionNumbers = new Set();

  const reserveQuestionNumber = (preferred, { allowFallback = true } = {}) => {
    const normalizedPreferred = normalizeWhitespace(String(preferred || ''));
    if (/^\d{1,3}$/.test(normalizedPreferred)) {
      usedQuestionNumbers.add(normalizedPreferred);
      return normalizedPreferred;
    }
    while (hintedCursor < hintedQuestionNumbers.length) {
      const candidate = hintedQuestionNumbers[hintedCursor++];
      if (!candidate || usedQuestionNumbers.has(candidate)) continue;
      usedQuestionNumbers.add(candidate);
      return candidate;
    }
    if (!allowFallback) return '';
    let seq = Math.max(1, questions.length + 1);
    while (usedQuestionNumbers.has(String(seq))) {
      seq += 1;
    }
    const fallback = String(seq);
    usedQuestionNumbers.add(fallback);
    return fallback;
  };

  const normalizeStemAlign = (raw) => normalizeParagraphAlignSafe(raw);
  const isInsideBoxContext = (stemLines) => {
    let depth = 0;
    for (const one of Array.isArray(stemLines) ? stemLines : []) {
      const line = String(one || '');
      if (/\[박스시작\]/.test(line)) depth += 1;
      if (/\[박스끝\]/.test(line)) depth = Math.max(0, depth - 1);
    }
    return depth > 0;
  };
  const appendStemLine = (target, text, align = 'left') => {
    const safeText = normalizeWhitespace(String(text || ''));
    if (!safeText || !target) return;
    target.stemLines.push(safeText);
    if (!Array.isArray(target.stemLineAligns)) {
      target.stemLineAligns = [];
    }
    target.stemLineAligns.push(normalizeStemAlign(align));
  };
  const rebalanceConsonantChoicesIntoViewBlock = (target) => {
    if (!target) return;
    const choices = Array.isArray(target.choices) ? target.choices : [];
    if (choices.length === 0) return;
    const stemLines = Array.isArray(target.stemLines) ? target.stemLines : [];
    const hasViewBlockContext = stemLines.some((line) =>
      /\[박스시작\]|<\s*보\s*기>|보\s*기/.test(String(line || '')),
    );
    if (!hasViewBlockContext) return;
    const hasObjectiveOptions = choices.some((choice) =>
      /^[①②③④⑤⑥⑦⑧⑨⑩]$/.test(String(choice?.label || '').trim()),
    );
    if (!hasObjectiveOptions) return;
    const consonantChoices = choices.filter((choice) =>
      /^[ㄱ-ㅎ]$/.test(String(choice?.label || '').trim()),
    );
    if (consonantChoices.length === 0) return;
    target.choices = choices.filter(
      (choice) => !/^[ㄱ-ㅎ]$/.test(String(choice?.label || '').trim()),
    );
    if (!Array.isArray(target.stemLineAligns)) {
      target.stemLineAligns = stemLines.map(() => 'left');
    }
    const firstConsonantStemIdx = stemLines.findIndex((line) =>
      /^[ㄱ-ㅎ]\.\s*/.test(String(line || '').trim()),
    );
    const viewMarkerIdx = stemLines.findIndex((line) =>
      /<\s*보\s*기>|보\s*기/.test(String(line || '')),
    );
    const boxEndIdx = stemLines.findIndex((line) =>
      /\[박스끝\]/.test(String(line || '')),
    );
    let insertAt = firstConsonantStemIdx;
    if (insertAt < 0) {
      if (viewMarkerIdx >= 0) {
        insertAt = viewMarkerIdx + 1;
      } else if (boxEndIdx >= 0) {
        insertAt = boxEndIdx;
      } else {
        insertAt = stemLines.length;
      }
    }
    const injectedLines = consonantChoices.map((choice) => {
      const label = String(choice?.label || '').trim();
      const text = normalizeWhitespace(String(choice?.text || ''));
      return text ? `${label}. ${text}` : `${label}.`;
    });
    stemLines.splice(insertAt, 0, ...injectedLines);
    target.stemLineAligns.splice(
      insertAt,
      0,
      ...injectedLines.map(() => 'left'),
    );
    target.sourcePatterns.push('choice_consonant_rebalanced_to_view');
  };

  const createQuestionSeed = ({
    questionNumber,
    row,
    stemLines = [],
    stemLineAligns = [],
    sourcePatterns = [],
    scorePoint = null,
  }) => ({
    academy_id: academyId,
    document_id: documentId,
    extract_job_id: extractJobId,
    source_page: Number(row.page || row.section + 1),
    source_order: questions.length,
    question_number: questionNumber,
    question_type: '미분류',
    stem: '',
    stemLines: [...stemLines],
    stemLineAligns: [...stemLineAligns],
    choices: [],
    figure_refs: [],
    equations: [],
    source_anchors: {
      section: row.section,
      line_start: row.lineIndex,
      line_end: row.lineIndex,
    },
    confidence: 0,
    flags: [],
    sourcePatterns: [...sourcePatterns],
    score_point: scorePoint,
    answer_key: '',
    is_checked: false,
    reviewed_by: null,
    reviewed_at: null,
    reviewer_notes: '',
    meta: {},
  });

  const flushCurrent = () => {
    if (!current) return;
    // stem/choices/equations/figures/score 모두 비어있는 implicit seed는 drop한다.
    // (예: [미주] 마커 이후 새 seed를 열었으나, 곧바로 다른 경로에서 새 문항이 열려
    //      원래 seed에 아무 내용도 쌓이지 않는 경우.)
    const hasAnyStemLine = (current.stemLines || []).some((raw) => {
      const c = normalizeWhitespace(String(raw || ''));
      if (!c) return false;
      if (/^(?:\[(?:문단|박스시작|박스끝|그림|도형|표행|표셀)\]|\[\[PB_FIG_[^\]]+\]\])$/.test(c)) return false;
      return true;
    });
    const isImplicitSeed = (current.sourcePatterns || []).some((p) =>
      /^implicit_/.test(String(p || '')),
    );
    const isEmptySeed =
      isImplicitSeed &&
      !hasAnyStemLine &&
      (current.choices || []).length === 0 &&
      (current.equations || []).length === 0 &&
      (current.figure_refs || []).length === 0 &&
      !current.score_point &&
      !current.answer_key;
    if (isEmptySeed) {
      if (current.question_number) {
        usedQuestionNumbers.delete(String(current.question_number));
      }
      current = null;
      return;
    }
    rebalanceConsonantChoicesIntoViewBlock(current);
    current.stem = normalizeWhitespace(current.stemLines.join('\n'));
    const stemLineAligns = Array.isArray(current.stemLineAligns)
      ? current.stemLineAligns.map((value) => normalizeStemAlign(value))
      : [];
    while (stemLineAligns.length < current.stemLines.length) {
      stemLineAligns.push('left');
    }
    if (stemLineAligns.length > current.stemLines.length) {
      stemLineAligns.length = current.stemLines.length;
    }
    current.stemLineAligns = stemLineAligns;
    current.question_type = guessQuestionType(current);
    if (!current.answer_key) {
      const hinted = answerHintMap.get(String(current.question_number || '').trim());
      if (hinted) {
        current.answer_key = hinted;
        current.sourcePatterns.push('endnote_answer_hint');
      }
    }
    current.answer_key = normalizeAnswerKeyForQuestion(current.answer_key, current);
    current.confidence = scoreQuestion(current);
    if (current.confidence < threshold) {
      current.flags.push('low_confidence');
    }
    current.flags = Array.from(new Set(current.flags));
    current.meta = {
      parse_version: 'v1',
      source_patterns: current.sourcePatterns,
      contains_figure: current.figure_refs.length > 0,
      contains_equation: current.equations.length > 0,
      stem_line_aligns: stemLineAligns,
      stemLineAligns: stemLineAligns,
      score_point: Number(current.score_point || 0) || null,
      answer_key: current.answer_key || '',
    };
    questions.push(current);
    current = null;
  };

  for (const row of allLines) {
    let line = row.text;
    if (!line) continue;

    if (/모의고사|학력평가|전국연합/.test(line)) {
      stats.mockMarkers += 1;
    }
    if (/대학수학능력시험|수능/.test(line)) {
      stats.csatMarkers += 1;
    }

    // 미주([미주]) 마커가 포함된 라인은 "이 문항 본문 종료 지점"을 가리킨다.
    // stem에 남겨도 본문에 도움이 되지 않으므로 텍스트에서 제거하고 상태 플래그만 올린다.
    //
    // HWPX에서는 endnote anchor가 "다음 문항의 시작 paragraph"에 섞여 들어가는 경우가 많다.
    // (예: 같은 hp:p 안에 "<endnote/> 다음 문항 stem 첫 줄" 형태.)
    // 이 경우 [미주]를 제거한 나머지 텍스트는 "이전 문항이 아닌 새 문항의 stem"이므로
    // 현재 문항을 flush하고 다음 문항이 자연스럽게 시작되도록 상태를 정리한다.
    // HWPX에서 endnote anchor는 대부분 "다음 문항의 시작 paragraph"에 섞여 들어간다.
    // (예: 같은 hp:p 안에 "<endNote/> 다음 문항 stem 첫 줄" 형태.)
    // 이때 [미주]를 제거한 나머지 텍스트는 "이전 문항이 아닌 새 문항의 stem"이므로
    // 현재 문항을 flush해 경계를 명확히 하고, 라인 자체는 아래의 일반 stem 처리 경로를 통해
    // 새 문항(또는 곧 이어질 score_only가 여는 새 문항)의 첫 stem 라인으로 흡수되도록 한다.
    if (/\[미주\]/.test(line)) {
      sawEndnoteSinceLastScore = true;
      const stripped = normalizeWhitespace(line.replace(/\[미주\]/g, ' '));
      if (!stripped) continue;
      row.text = stripped;
      line = stripped;
      // [미주] 뒤에 의미있는 본문(한글/영문/숫자/수식 토큰)이 남아있으면
      // 현재 문항을 flush하고 이어지는 stem을 담을 새 seed를 연다.
      // 이때 번호는 곧 이어질 score_only가 채워넣는 배점까지 붙은 뒤 결정되도록
      // 'pending' 상태로 둔다(숫자 reserve를 지연). flushCurrent에서 빈 seed는 drop된다.
      const hasMeaningfulContent =
        /[가-힣A-Za-z0-9]/.test(stripped) || /\[\[PB_EQ_/.test(stripped);
      if (
        hasMeaningfulContent &&
        current &&
        (current.stemLines.length > 0 || (current.choices || []).length > 0)
      ) {
        flushCurrent();
        const implicitNumber = reserveQuestionNumber('', { allowFallback: true });
        if (implicitNumber) {
          current = createQuestionSeed({
            questionNumber: implicitNumber,
            row,
            stemLines: [],
            stemLineAligns: [],
            sourcePatterns: ['implicit_after_endnote'],
          });
          sawEndnoteSinceLastScore = false;
          // 직전 문항에서 [배점] 흡수 후 설정되었을 splitAfterScoreAnnotation 플래그는
          // 새 문항 seed가 열린 시점에 이미 경계가 명시되었으므로 초기화한다.
          // 초기화하지 않으면 이 라인이 narrativeLead로 분류되어 Q17 empty + Q18 중복 생성되는
          // 오분할을 유발한다.
          splitAfterScoreAnnotation = false;
        }
      }
    }

    const start = parseQuestionStart(line);
    if (start) {
      splitAfterScoreAnnotation = false;
      // score_only ("[3.00점]") 라인이 현재 문항 stem 바로 뒤에 나올 때의 처리.
      // 1) 세트형(하위문항 (1), (2) ...)이라면 선택지 유무와 무관하게
      //    같은 문항의 소문항 배점 메타데이터로 흡수한다(새 문항으로 분할하지 않음).
      // 2) 그 외엔 기존처럼 stem→[배점]→선택지 순서 처리를 유지한다.
      if (
        start.style === 'score_only' &&
        current &&
        current.stemLines.length > 0
      ) {
        const setSigPresent = hasSetQuestionSignature(current.stemLines, {
          answerKey: current.answer_key || '',
        });
        // 세트형(하위문항) 흡수는 미주 경계를 넘어가면 금지한다.
        // HWPX에서 endnote는 해당 문항 말미에 anchor되므로, 미주 이후 첫 score_only는
        // 세트형 sub-score가 아닌 "다음 문항의 시작"이다.
        const allowSetAbsorb = setSigPresent && !sawEndnoteSinceLastScore;
        // 단문항 stem-only 흡수(choices === 0)는 stem→[배점]→선택지 순서를 한 문항에 묶기 위해 필요하다.
        // 다만 아래 두 경우는 미주 경계 이후에도 흡수를 허용한다:
        //   1) 현재 stem이 "프롬프트 한 줄" 수준으로 매우 짧음 (의미있는 글자 < 25)
        //      → HWPX 상단 특수 레이아웃에서 이전 문항의 "[정답] …" endnote가 우연히 먼저 보이는 경우.
        //   2) 현재 stem이 이미 종결형 문장("...구하시오/고르시오/...?")으로 끝남
        //      → 이어지는 score_only는 같은 문항의 [배점]이고, 이후에 따라오는 prompt-like 라인은
        //        splitAfterScoreAnnotation 경로에서 새 문항으로 올바르게 분기된다.
        const meaningfulCurrentStemLen = (() => {
          let len = 0;
          for (const raw of current.stemLines || []) {
            const c = normalizeWhitespace(String(raw || ''));
            if (!c) continue;
            if (/^(?:\[(?:문단|박스시작|박스끝|그림|도형|표행|표셀)\]|\[\[PB_FIG_[^\]]+\]\])$/.test(c)) continue;
            len += c.length;
            if (len >= 25) break;
          }
          return len;
        })();
        const lastNonStructuralStemLine = (() => {
          for (let si = (current.stemLines || []).length - 1; si >= 0; si -= 1) {
            const c = normalizeWhitespace(current.stemLines[si]);
            if (c && !/^(?:\[(?:문단|박스시작|박스끝|그림|도형|표행|표셀)\]|\[\[PB_FIG_[^\]]+\]\])$/.test(c)) return c;
          }
          return '';
        })();
        const stemOnlyEndnoteBypass =
          meaningfulCurrentStemLen < 25 ||
          looksLikeQuestionTerminalLine(lastNonStructuralStemLine);
        const allowStemOnlyAbsorb =
          current.choices.length === 0 &&
          (!sawEndnoteSinceLastScore || stemOnlyEndnoteBypass) &&
          !setSigPresent;
        const canAbsorbAsScoreAnnotation = allowSetAbsorb || allowStemOnlyAbsorb;
        if (canAbsorbAsScoreAnnotation) {
          if (!current.score_point) {
            current.score_point = start.scorePoint ?? current.score_point;
          }
          current.sourcePatterns.push(
            allowSetAbsorb ? 'set_question_sub_score' : 'score_annotation',
          );
          if (allowSetAbsorb) {
            // 세트형 내부(미주 없이 연속된 [N점])에서는 새 문항으로 분리하지 않는다.
            splitAfterScoreAnnotation = false;
          } else {
            if (looksLikeQuestionTerminalLine(lastNonStructuralStemLine)) {
              splitAfterScoreAnnotation = true;
            }
          }
          if (start.style === 'score_only') sawEndnoteSinceLastScore = false;
          continue;
        }
      }
      const questionNumber = reserveQuestionNumber(start.number, {
        allowFallback: start.style === 'score_only',
      });
      if (!questionNumber) {
        if (start.style === 'score_only') sawEndnoteSinceLastScore = false;
        continue;
      }
      flushCurrent();
      current = createQuestionSeed({
        questionNumber,
        row,
        stemLines: start.rest ? [start.rest] : [],
        stemLineAligns: start.rest ? [normalizeStemAlign(row.align)] : [],
        sourcePatterns: [start.style],
        scorePoint: start.scorePoint ?? null,
      });
      if (start.style === 'score_only') sawEndnoteSinceLastScore = false;
      continue;
    }

    if (splitAfterScoreAnnotation && current) {
      const inBox = isInsideBoxContext(current.stemLines);
      const peekCleaned = stripLeadingDialogueDotArtifact(
        stripPotentialWatermarkText(
          normalizeWhitespace(
            line.replace(/\[\[PB_EQ_[^\]]+\]\] ?/g, (match) => {
              const token = match.replace(/ $/, '');
              const eq = equationMap.get(token);
              const rendered = normalizeWhitespace(eq?.latex || eq?.raw || '');
              return rendered || '[수식]';
            }),
          ),
        ),
      );
      const isStructuralOrEmpty =
        !peekCleaned ||
        /^(?:\[(?:문단|박스시작|박스끝|그림|도형|표행|표셀)\]|\[\[PB_FIG_[^\]]+\]\])$/.test(peekCleaned);
      const isChoiceLike =
        Boolean(parseChoiceLine(peekCleaned)) ||
        parseInlineCircledChoices(peekCleaned).length >= 2;
      const isViewOrConditionLead =
        isViewBlockLine(peekCleaned) ||
        /^<\s*보\s*기>\s*$/.test(peekCleaned) ||
        /^[\(（]?\s*[가나다라마바사아자차카타파하ㄱ-ㅎ]\s*[\)）]\s*/.test(peekCleaned);
      const looksPromptForSplit = looksLikePromptLineForImplicitSplit(peekCleaned);
      const looksNarrativeLead =
        peekCleaned.length >= 8 &&
        /[가-힣]/.test(peekCleaned) &&
        !/^[\[\(<（]/.test(peekCleaned);
      if (!isStructuralOrEmpty) {
        // [배점] 뒤 분리는 "실제 다음 문항 프롬프트"일 때만 허용한다.
        // (보기 박스/조건 (가)(나)/선택지가 뒤따르는 객관식은 같은 문항으로 유지)
        splitAfterScoreAnnotation = false;
        if (
          !inBox &&
          !isChoiceLike &&
          !isViewOrConditionLead &&
          (looksPromptForSplit || looksNarrativeLead)
        ) {
          const implicitQuestionNumber = reserveQuestionNumber('', {
            allowFallback: true,
          });
          if (implicitQuestionNumber) {
            flushCurrent();
            current = createQuestionSeed({
              questionNumber: implicitQuestionNumber,
              row,
              stemLines: [],
              sourcePatterns: ['implicit_after_score_terminal'],
            });
          }
        }
      }
    }

    if (!current && questions.length === 0) {
      const firstLineCandidate = stripLeadingDialogueDotArtifact(
        stripPotentialWatermarkText(
          normalizeWhitespace(
            line.replace(/\[\[PB_EQ_[^\]]+\]\] ?/g, (match) => {
              const token = match.replace(/ $/, '');
              const eq = equationMap.get(token);
              const rendered = normalizeWhitespace(eq?.latex || eq?.raw || '');
              return rendered || '[수식]';
            }),
          ),
        ),
      );
      const looksPromptLike =
        firstLineCandidate.length >= 8 &&
        /[가-힣]/.test(firstLineCandidate) &&
        /(다음|옳은|설명|구하|계산|고른|것은|값)/.test(firstLineCandidate) &&
        !isSourceMarkerLine(firstLineCandidate) &&
        !parseChoiceLine(firstLineCandidate) &&
        !parseAnswerLine(firstLineCandidate);
      if (looksPromptLike) {
        const implicitQuestionNumber = reserveQuestionNumber('1', {
          allowFallback: true,
        });
        current = createQuestionSeed({
          questionNumber: implicitQuestionNumber,
          row,
          stemLines: [firstLineCandidate],
          stemLineAligns: [normalizeStemAlign(row.align)],
          sourcePatterns: ['implicit_first'],
        });
        continue;
      }
    }

    if (!current) continue;
    current.source_anchors.line_end = row.lineIndex;

    const lineEquationRefs = [];
    const eqTokens = line.match(/\[\[PB_EQ_[^\]]+\]\]/g) || [];
    if (eqTokens.length > 0) {
      stats.equationRefs += eqTokens.length;
      for (const token of eqTokens) {
        const eq = equationMap.get(token);
        if (!eq) continue;
        lineEquationRefs.push(eq);
        current.equations.push(eq);
      }
    }

    const cleanedLine = stripLeadingDialogueDotArtifact(
      stripPotentialWatermarkText(
        normalizeWhitespace(
          line.replace(/\[\[PB_EQ_[^\]]+\]\] ?/g, (match) => {
            const token = match.replace(/ $/, '');
            const eq = equationMap.get(token);
            const rendered = normalizeWhitespace(eq?.latex || eq?.raw || '');
            return rendered || '[수식]';
          }),
        ),
      ),
    );
    if (!cleanedLine) continue;
    if (isLikelyWatermarkOnlyLine(cleanedLine)) {
      current.sourcePatterns.push('watermark_line');
      continue;
    }
    const hasEnoughChoices =
      meaningfulChoiceTextCount(current.choices || []) >= 4 ||
      (current.choices || []).length >= 4;
    const previousStemLine = (() => {
      for (let si = (current.stemLines || []).length - 1; si >= 0; si -= 1) {
        const candidate = normalizeWhitespace(current.stemLines[si]);
        if (candidate && !/^(?:\[(?:문단|박스시작|박스끝|그림|도형|표행|표셀)\]|\[\[PB_FIG_[^\]]+\]\])$/.test(candidate)) {
          return candidate;
        }
      }
      return '';
    })();
    const isChoiceLine = Boolean(parseChoiceLine(cleanedLine));
    const parsedAnswerKey = parseAnswerLine(cleanedLine);
    const isAnswerLine = Boolean(parsedAnswerKey);
    const isSourceLine = isSourceMarkerLine(cleanedLine);
    const isFigureRefOnly = isFigureReferenceLine(cleanedLine);
    const canSplitAfterChoices =
      hasEnoughChoices &&
      !isChoiceLine &&
      !isAnswerLine &&
      !isSourceLine &&
      !isFigureRefOnly &&
      cleanedLine.length >= 8 &&
      /[가-힣A-Za-z]/.test(cleanedLine) &&
      !isLikelyKoreanPersonName(cleanedLine);
    const canSplitAfterTerminal =
      looksLikePromptLineForImplicitSplit(cleanedLine) &&
      looksLikeQuestionTerminalLine(previousStemLine);
    // 세트형 문항에서는 (1)/(2) 소문항의 "... 서술하시오" → 다음 (2) 줄이
    // 새 문항 경계로 오인되지 않도록 암시 분할을 억제한다.
    const insideSetQuestion = hasSetQuestionSignature(current.stemLines, {
      answerKey: current.answer_key || '',
    });
    // 보기 박스/표/도형 박스 내부 라인을 새 문항의 리드 프롬프트로 오인하지 않도록
    // 박스 안쪽에서는 암시 분할을 억제한다. 예: Q10 의 <보기> 박스 안 "A: 4-9≤-2…"
    // 대화 라인이 질문 끝 "…고른 것은?" 뒤에 이어지면 canSplitAfterTerminal 이 true 가
    // 되어 박스 내부 라인부터 새 문항 seed 가 열리는 오분할이 발생했다.
    const insideBoxContext = isInsideBoxContext(current.stemLines);
    if (
      !insideSetQuestion &&
      !insideBoxContext &&
      (canSplitAfterChoices || canSplitAfterTerminal)
    ) {
      const implicitQuestionNumber = reserveQuestionNumber('', {
        allowFallback: true,
      });
      if (lineEquationRefs.length > 0) {
        const movedKeys = new Set(
          lineEquationRefs.map((eq) =>
            JSON.stringify([eq?.raw || '', eq?.latex || '']),
          ),
        );
        current.equations = current.equations.filter(
          (eq) => !movedKeys.has(JSON.stringify([eq?.raw || '', eq?.latex || ''])),
        );
      }
      flushCurrent();
      current = createQuestionSeed({
        questionNumber: implicitQuestionNumber,
        row,
        stemLines: [cleanedLine],
        stemLineAligns: [normalizeStemAlign(row.align)],
        sourcePatterns: ['implicit_after_block'],
      });
      if (lineEquationRefs.length > 0) {
        current.equations.push(...lineEquationRefs);
      }
      continue;
    }
    if (
      isLikelyKoreanPersonName(cleanedLine) &&
      current.stemLines.some((lineText) => /<\s*보\s*기>/.test(String(lineText || '')))
    ) {
      current.sourcePatterns.push('watermark_line');
      continue;
    }
    if (parsedAnswerKey) {
      // 세트형 정답 "(1) X (2) Y" 뒤에 리드 프롬프트("물음에 답하시오")가 같은
      // paragraph 로 합쳐져 들어온 경우, 리드 꼬리는 이어지는 문항의 stem 으로 복원한다.
      const { answer: splitAnswer, lead: splitLead } =
        splitAnswerLineWithTrailingLead(parsedAnswerKey);
      current.answer_key = splitAnswer || parsedAnswerKey;
      current.sourcePatterns.push('answer_key');
      if (splitLead) {
        appendStemLine(current, splitLead, row.align);
        current.sourcePatterns.push('answer_trailing_lead');
      }
      continue;
    }

    if (isSourceLine) {
      current.sourcePatterns.push('source_marker');
      continue;
    }

    const inlineChoices = parseInlineCircledChoices(cleanedLine);
    if (inlineChoices.length >= 2) {
      const leadStem = leadingStemBeforeInlineChoices(cleanedLine);
      if (leadStem) {
        appendStemLine(current, leadStem, row.align);
      }
      stats.circledChoices += inlineChoices.length;
      current.sourcePatterns.push('choice_inline_circled');
      for (const c of inlineChoices) {
        current.choices.push({
          label: c.label,
          text: c.text || '',
        });
      }
      continue;
    }

    const choice = isChoiceLine ? parseChoiceLine(cleanedLine) : null;
    if (choice) {
      const inBox = isInsideBoxContext(current.stemLines);
      if (
        choice.style === 'consonant' &&
        (inBox || current.flags.includes('view_block') || cleanedLine.length >= 20)
      ) {
        // <보기>의 ㄱ/ㄴ/ㄷ 항목은 선택지보다 본문으로 본다.
        appendStemLine(current, cleanedLine, row.align);
        current.sourcePatterns.push('view_item');
        continue;
      }
      // 세트형(하위문항 (1), (2) ...) 문항에서는 (1) / (2) / (3) 라인이 소문항 본문이므로
      // numeric 스타일 choice로 오인식되면 안 된다. stem 라인으로 유지한다.
      // 리드가 stem 에 있는 경우뿐 아니라 answer_key 에 (1)(2) 구조가 이미 포함된 경우에도
      // 세트형으로 간주한다.
      if (
        choice.style === 'numeric' &&
        hasSetQuestionSignature(current.stemLines, {
          answerKey: current.answer_key || '',
        })
      ) {
        appendStemLine(current, cleanedLine, row.align);
        current.sourcePatterns.push('set_question_sub_item');
        continue;
      }
      if (choice.style === 'circled') {
        stats.circledChoices += 1;
      }
      current.sourcePatterns.push(`choice_${choice.style}`);
      current.choices.push({
        label: choice.label,
        text: choice.text || '',
      });
      continue;
    }

    if (isViewBlockLine(cleanedLine)) {
      stats.viewBlocks += 1;
      current.flags.push('view_block');
      current.sourcePatterns.push('view_block');
    }
    if (
      isFigureLine(cleanedLine)
      || /\[(그림|표|도형)\]/.test(cleanedLine)
      || /\[\[PB_FIG_[^\]]+\]\]/.test(cleanedLine)
    ) {
      stats.figureLines += 1;
      current.figure_refs.push(cleanedLine);
      current.flags.push('contains_figure');
      current.sourcePatterns.push('figure_line');
    }
    if (looksLikeEssay(cleanedLine)) {
      current.flags.push('essay_hint');
    }
    if (containsMathSymbol(cleanedLine)) {
      current.flags.push('math_symbol');
    }

    appendStemLine(current, cleanedLine, row.align);
  }

  flushCurrent();

  // endnote(미주) 개수 기반 상한 병합:
  // HWPX 미주 개수는 "정답 힌트가 있는 문항 수"와 동일하므로 실제 문항 수의 상한이 된다.
  // 파서가 [N점] 같은 score_only를 새 문항으로 오분할한 "거의 빈 꼬리 문항"이
  // 남으면 뒤에서부터 가까운 앞 문항에 병합하여 실제 문항 수에 맞춘다.
  //
  // 과도 병합을 막기 위해 아래 조건을 모두 만족할 때만 병합 대상으로 본다.
  //  - sourcePatterns 가 score_only/score_annotation/implicit_after_* 로만 구성
  //  - 선택지가 없고, 의미있는 stem 길이가 매우 짧음 (< 30자)
  //  - equation/figure_refs 도 실질 없음
  const endnoteCap = answerHintMap.size;
  if (endnoteCap > 0 && questions.length > endnoteCap) {
    const MERGE_SAFE_PATTERNS = new Set([
      'score_only',
      'score_annotation',
      'set_question_sub_score',
      'set_question_sub_item',
      'implicit_after_score_terminal',
      'implicit_after_block',
      'merged_score_tail',
    ]);
    const meaningfulStemLength = (q) => {
      const lines = Array.isArray(q?.stemLines) ? q.stemLines : [];
      const joined = lines
        .map((l) => normalizeWhitespace(String(l || '')))
        .filter(
          (l) =>
            l &&
            !/^(?:\[(?:문단|박스시작|박스끝|그림|도형|표행|표셀)\]|\[\[PB_FIG_[^\]]+\]\])$/.test(l),
        )
        .join(' ');
      return joined.length;
    };
    const isMergeSafe = (q) => {
      const patterns = Array.isArray(q?.sourcePatterns) ? q.sourcePatterns : [];
      if (patterns.length === 0) return false;
      if (!patterns.every((p) => MERGE_SAFE_PATTERNS.has(String(p)))) return false;
      if (Array.isArray(q.choices) && q.choices.length > 0) return false;
      if (Array.isArray(q.equations) && q.equations.length > 0) return false;
      if (Array.isArray(q.figure_refs) && q.figure_refs.length > 0) return false;
      if (meaningfulStemLength(q) >= 30) return false;
      return true;
    };
    const mergeQuestionIntoPrev = (prev, tail) => {
      if (!prev || !tail) return;
      const prevLines = Array.isArray(prev.stemLines) ? prev.stemLines : [];
      const tailLines = Array.isArray(tail.stemLines) ? tail.stemLines : [];
      const prevAligns = Array.isArray(prev.stemLineAligns) ? prev.stemLineAligns : [];
      const tailAligns = Array.isArray(tail.stemLineAligns) ? tail.stemLineAligns : [];
      prev.stemLines = [...prevLines, ...tailLines];
      prev.stemLineAligns = [
        ...prevAligns,
        ...(tailAligns.length === tailLines.length
          ? tailAligns
          : tailLines.map(() => 'left')),
      ];
      prev.stem = normalizeWhitespace(prev.stemLines.join('\n'));
      prev.equations = Array.from(
        new Map(
          [...(prev.equations || []), ...(tail.equations || [])].map((e) => [
            JSON.stringify([e?.raw || '', e?.latex || '']),
            e,
          ]),
        ).values(),
      );
      prev.figure_refs = Array.from(
        new Set([...(prev.figure_refs || []), ...(tail.figure_refs || [])]),
      );
      prev.flags = Array.from(new Set([...(prev.flags || []), ...(tail.flags || [])]));
      prev.sourcePatterns = [
        ...(prev.sourcePatterns || []),
        'merged_score_tail',
        ...(tail.sourcePatterns || []),
      ];
      if (!prev.score_point && tail.score_point) {
        prev.score_point = tail.score_point;
      }
      if (tail.source_anchors && prev.source_anchors) {
        prev.source_anchors.line_end = Math.max(
          Number(prev.source_anchors.line_end || 0),
          Number(tail.source_anchors.line_end || 0),
        );
      }
      prev.meta = {
        ...(prev.meta || {}),
        source_patterns: prev.sourcePatterns,
        contains_figure: (prev.figure_refs || []).length > 0,
        contains_equation: (prev.equations || []).length > 0,
      };
    };
    while (questions.length > endnoteCap) {
      let mergedAny = false;
      for (let i = questions.length - 1; i >= 1; i -= 1) {
        const tail = questions[i];
        if (!isMergeSafe(tail)) continue;
        const prev = questions[i - 1];
        mergeQuestionIntoPrev(prev, tail);
        questions.splice(i, 1);
        mergedAny = true;
        break;
      }
      if (!mergedAny) break;
    }
    for (const [idx, q] of questions.entries()) {
      q.source_order = idx;
    }
  }

  const dedupedQuestions = dedupeQuestionsByNumber(questions);
  questions.length = 0;
  questions.push(...dedupedQuestions);
  stats.questionCount = questions.length;

  for (const q of questions) {
    q.source_order = Number(q.source_order) + 1;
    q.equations = Array.from(
      new Map(
        q.equations.map((e) => [JSON.stringify([e.raw, e.latex]), e]),
      ).values(),
    );
  }

  const distinctPages = new Set(questions.map((q) => Number(q.source_page || 0)));
  if (distinctPages.size <= 1) {
    estimateSourcePagesByPointWeight(questions);
  }

  const lowConfidenceCount = questions.filter(
    (q) => q.confidence < threshold,
  ).length;
  const examProfile = detectExamProfile(stats);

  return {
    questions,
    stats: {
      ...stats,
      sourceLineCount,
      segmentedLineCount,
      answerHintCount: hintedQuestionNumbers.length,
      lowConfidenceCount,
      examProfile,
    },
  };
}

function decodeZipEntry(entry) {
  const raw = entry.getData();
  let text = raw.toString('utf8');
  if (text.includes('\u0000')) {
    text = raw.toString('utf16le');
  }
  return text;
}

function parseHwpxBuffer(buffer) {
  const zip = new AdmZip(buffer);
  const alignResolver = buildHwpxParagraphAlignResolver(zip);
  const entries = zip
    .getEntries()
    .filter(
      (entry) =>
        !entry.isDirectory &&
        /contents\/section\d+\.xml$/i.test(entry.entryName),
    )
    .sort((a, b) => sectionSortKey(a.entryName) - sectionSortKey(b.entryName));

  const preview = extractPreviewTextLines(zip, entries.length);

  if (entries.length === 0 && preview.lines.length === 0) {
    throw new Error('HWPX 섹션 XML을 찾을 수 없습니다.');
  }

  const sections = [];
  const hints = {
    scoreHeaderCount: 0,
  };
  for (const [i, entry] of entries.entries()) {
    const rawXml = decodeZipEntry(entry);
    hints.scoreHeaderCount += countScoreHeadersFromXml(rawXml);
    const xmlParsed = tryParseXml(rawXml);
    void xmlParsed; // parse 가능성 점검용 (실패해도 텍스트 파싱은 진행)
    const transformed = transformXmlToLines(rawXml, i, { alignResolver });
    sections.push({
      section: i,
      path: entry.entryName,
      lines: transformed.lines,
      equations: transformed.equations,
      answerHints: transformed.answerHints || {},
    });
  }

  return {
    sections,
    previewSection:
      preview.lines.length > 0
        ? {
            section: sections.length,
            path: preview.path || 'PrvText.txt',
            lines: preview.lines,
            equations: [],
            answerHints: {},
          }
        : null,
    hints: {
      ...hints,
      previewLineCount: preview.lines.length,
    },
  };
}

async function toBufferFromStorageData(data) {
  if (!data) return Buffer.alloc(0);
  if (Buffer.isBuffer(data)) return data;
  if (data instanceof ArrayBuffer) return Buffer.from(data);
  if (typeof data.arrayBuffer === 'function') {
    const arr = await data.arrayBuffer();
    return Buffer.from(arr);
  }
  if (typeof data.stream === 'function') {
    const chunks = [];
    const stream = data.stream();
    for await (const chunk of stream) {
      chunks.push(Buffer.from(chunk));
    }
    return Buffer.concat(chunks);
  }
  throw new Error('Unsupported storage payload type');
}

function toErrorCode(err) {
  const msg = String(err?.message || err || '');
  if (/not\s*found|404/i.test(msg)) return 'NOT_FOUND';
  if (/permission|forbidden|unauthorized|401|403/i.test(msg)) {
    return 'PERMISSION_DENIED';
  }
  if (/timeout|aborted|abort/i.test(msg)) return 'TIMEOUT';
  if (/parse|xml|hwpx|zip/i.test(msg)) return 'PARSE_FAILED';
  return 'UNKNOWN';
}

function normalizeTargetQuestionIdsFromJob(job) {
  const raw = job?.result_summary?.targetQuestionIds;
  if (!Array.isArray(raw)) return [];
  const out = [];
  const seen = new Set();
  for (const value of raw) {
    const id = normalizeWhitespace(value);
    if (!id || seen.has(id)) continue;
    seen.add(id);
    out.push(id);
  }
  return out;
}

// VLM 경로 (PDF 기반) 는 HWPX 의 <hp:pic binaryItemIDRef="..."/> 정보를 전혀 보지 않는다.
// 그 결과 figure_worker 는 기존 positional fallback (BinData 파일명 순서 기반 slice) 으로
// 떨어지는데, VLM 이 그림 개수를 복합 도형 등으로 오인식하면 (예: Q9 에 1개인 그림을 4개로
// 세어버리면) 다음과 같은 체인 반응이 일어난다:
//
//   Q9: count=4 → imageEntries.slice(0,4) = 전체 4장 소진
//   Q11: start=4, count=2 → slice(4,6)=[] → fallback 으로 imageEntries[1] (중복)
//   Q20: start=6, count=1 → slice(6,7)=[] → fallback 으로 imageEntries[2] (중복)
//
// 이 함수는 VLM 경로에서 HWPX 원본을 "추가로" 파싱해 문항 번호별 PB_FIG 토큰 리스트를
// 돌려준다. VLM payload 의 figure 관련 필드 (stem 의 [그림] 마커, figure_refs,
// meta.figure_count) 를 HWPX 기준으로 덮어써 token-first 매칭 경로를 태우기 위함이다.
function buildHwpxFigureMapByQuestionNumber(hwpxBuffer, { threshold, log }) {
  const map = new Map();
  try {
    const hwpxParsed = parseHwpxBuffer(hwpxBuffer);
    const hwpxBuilt = buildQuestionRows({
      academyId: '',
      documentId: '',
      extractJobId: '',
      parsed: { sections: hwpxParsed.sections || [] },
      threshold,
    });
    for (const q of hwpxBuilt.questions || []) {
      const qNo = normalizeWhitespace(q?.question_number || '');
      if (!qNo) continue;
      // figure_refs 에서 PB_FIG 토큰을 순서대로 수집한다.
      //   - 같은 itemID 가 여러 번 쓰이면 (문항 내 같은 그림 재인용) 중복도 보존한다.
      //   - plain [그림] / [도형] 은 폴백 count 에만 기여한다 (토큰이 없으면 넣지 않음).
      const pbTokens = [];
      let plainFigureMarkers = 0;
      for (const raw of Array.isArray(q.figure_refs) ? q.figure_refs : []) {
        const text = String(raw || '');
        const tokenMatches = text.match(/\[\[PB_FIG_([^\]]+)\]\]/g) || [];
        for (const tm of tokenMatches) {
          const inner = tm.replace(/^\[\[PB_FIG_|\]\]$/g, '');
          if (inner) pbTokens.push(inner);
        }
        const plainMatches = text.match(/\[(?:그림|도형)\]/g) || [];
        plainFigureMarkers += plainMatches.length;
      }
      if (pbTokens.length === 0 && plainFigureMarkers === 0) continue;
      // 같은 번호가 두 번 나오는 (HWPX 파서가 double-seed 한) 케이스는 첫 항목만 유지.
      if (map.has(qNo)) continue;
      map.set(qNo, {
        pbTokens,
        plainFigureMarkers,
        figureRefs: Array.isArray(q.figure_refs) ? q.figure_refs.slice() : [],
      });
    }
    if (typeof log === 'function') {
      log('vlm_hwpx_figure_overlay_built', {
        hwpxQuestionCount: (hwpxBuilt.questions || []).length,
        mappedQuestionCount: map.size,
      });
    }
  } catch (err) {
    if (typeof log === 'function') {
      log('vlm_hwpx_figure_overlay_parse_failed', {
        message: String(err?.message || err || ''),
      });
    }
  }
  return map;
}

// VLM 이 내려준 단일 question payload 에 HWPX overlay 를 적용한다.
//   - stem 의 [그림] / [도형] 마커와 기존 [[PB_FIG_...]] 토큰을 HWPX 의 토큰 순서로 교체
//   - figure_refs 를 HWPX 버전으로 교체 (PB_FIG 토큰 포함)
//   - meta.figure_count 를 HWPX 토큰 수로 덮어씀
// HWPX overlay 가 "없으면" 원래 VLM payload 를 그대로 둔다 (HWPX-missing 문항 안전장치).
function applyHwpxFigureOverlayToVlmPayload(payload, overlay) {
  if (!overlay || !payload || typeof payload !== 'object') return payload;
  const pbTokens = Array.isArray(overlay.pbTokens) ? overlay.pbTokens : [];
  const hwpxFigureRefs = Array.isArray(overlay.figureRefs)
    ? overlay.figureRefs
    : [];
  // HWPX 가 이 문항에 대해 어떤 figure 도 인식하지 못했다면 overlay 를 적용하지 않는다.
  //   (VLM 이 본 PDF 에는 있는 그림을 HWPX 파서가 놓쳤을 수 있으므로 VLM 데이터를 살려둔다.)
  if (pbTokens.length === 0 && hwpxFigureRefs.length === 0) return payload;

  const next = { ...payload };

  // stem 덮어쓰기: [그림]/[도형] 과 기존 [[PB_FIG_xxx]] 를 모두 HWPX 토큰 순서로 재배치.
  //   - VLM 마커 수 > HWPX 토큰 수   : 남는 VLM 마커는 제거 (overflow drop)
  //   - VLM 마커 수 < HWPX 토큰 수   : 부족분은 stem 끝에 [문단]\n[[PB_FIG_x]]... 로 append
  if (pbTokens.length > 0) {
    const markerRe = /\[\[PB_FIG_[^\]]+\]\]|\[(?:그림|도형)\]/g;
    let cursor = 0;
    const originalStem = String(next.stem || '');
    const rewritten = originalStem.replace(markerRe, () => {
      if (cursor < pbTokens.length) {
        const id = pbTokens[cursor];
        cursor += 1;
        return `[[PB_FIG_${id}]]`;
      }
      return '';
    });
    let finalStem = rewritten;
    if (cursor < pbTokens.length) {
      const remaining = pbTokens.slice(cursor);
      const appendLine = remaining.map((id) => `[[PB_FIG_${id}]]`).join(' ');
      finalStem = finalStem
        ? `${finalStem}\n[문단]\n${appendLine}`
        : appendLine;
    }
    // 빈 줄 / 연속 공백 정리. 마커만 남아있던 라인을 지웠을 때 정리 목적.
    finalStem = finalStem
      .replace(/[ \t]+/g, ' ')
      .replace(/\n{3,}/g, '\n\n')
      .trim();
    next.stem = finalStem;
  }

  // figure_refs 덮어쓰기: HWPX 원본 refs (PB_FIG 토큰 포함) 그대로 사용.
  if (hwpxFigureRefs.length > 0) {
    next.figure_refs = hwpxFigureRefs.slice();
  }

  // meta.figure_count 를 HWPX 기준으로 재계산. figure_worker.inferQuestionFigureCount 가
  //   이 값을 최우선 참조하므로, positional fallback 이 쓰일 때도 올바른 count 가 간다.
  //   - PB_FIG 토큰이 있으면 토큰 수를 우선 사용 (token-first path).
  //   - 토큰은 없고 plain [그림]/[도형] 만 있으면 plain 마커 수를 사용 (fallback path).
  const prevMeta = next.meta && typeof next.meta === 'object' ? next.meta : {};
  const plainCount = Number.isFinite(overlay.plainFigureMarkers)
    ? overlay.plainFigureMarkers
    : 0;
  const figureCountForMeta = pbTokens.length > 0 ? pbTokens.length : plainCount;
  next.meta = {
    ...prevMeta,
    figure_count: figureCountForMeta,
  };

  return next;
}

function buildQuestionWritePayload({
  question,
  classification,
  academyId,
  documentId,
  extractJobId,
  questionUid = '',
}) {
  const safeQuestionUid =
    normalizeWhitespace(questionUid) ||
    normalizeWhitespace(question?.question_uid || '') ||
    randomUUID();
  return {
    academy_id: academyId,
    document_id: documentId,
    extract_job_id: extractJobId,
    question_uid: safeQuestionUid,
    source_page: question.source_page,
    source_order: question.source_order,
    question_number: question.question_number,
    question_type: question.question_type,
    stem: question.stem,
    choices: question.choices,
    figure_refs: question.figure_refs,
    equations: question.equations,
    source_anchors: question.source_anchors,
    confidence: question.confidence,
    flags: question.flags,
    is_checked: question.is_checked,
    reviewed_by: question.reviewed_by,
    reviewed_at: question.reviewed_at,
    reviewer_notes: question.reviewer_notes,
    allow_objective: question.allow_objective !== false,
    allow_subjective: question.allow_subjective !== false,
    objective_choices: Array.isArray(question.objective_choices)
      ? question.objective_choices
      : [],
    objective_answer_key: String(question.objective_answer_key || ''),
    subjective_answer: String(question.subjective_answer || ''),
    objective_generated: question.objective_generated === true,
    curriculum_code: classification.curriculum_code,
    source_type_code: classification.source_type_code,
    course_label: classification.course_label,
    grade_label: classification.grade_label,
    exam_year: classification.exam_year,
    semester_label: classification.semester_label,
    exam_term_label: classification.exam_term_label,
    school_name: classification.school_name,
    publisher_name: classification.publisher_name,
    material_name: classification.material_name,
    classification_detail: {
      ...(classification.classification_detail || {}),
      extracted_by_worker: true,
    },
    meta: question.meta,
  };
}

// ---------------------------------------------------------------------------
// Stale 'extracting' 락 자동 복구
//
// 배경:
//   - 워커가 job 을 pick 하는 순간 status 를 'extracting' 으로 전환한다.
//   - 워커 프로세스가 그 사이에 비정상 종료(전원 끊김, OOM, 개발 중 Ctrl+C 등)
//     하면 해당 row 는 'extracting' 상태로 영구히 남는다.
//   - processBatch() 는 status='queued' 만 pick 하고, /pb/jobs/extract/:id/retry
//     API 는 'extracting' 상태를 409 로 거부하므로 매니저 UI 에서는 무한 로딩만
//     관찰된다.
//
// 이 함수는 그런 orphan 을 찾아 (updated_at 이 STALE_EXTRACTING_MS 이상 지난
// row) 안전한 상태로 되돌린다.
//   - retry_count < max_retries  → 'queued' 로 다시 큐잉 (자동 재시도)
//   - retry_count >= max_retries → 'failed' 로 마무리 + 문서 status='failed'
//
// lockQueuedJob 이 status='queued' 조건을 WHERE 에 걸고 낙관적 업데이트를 하므로
// reclaim 이후 동시 다중 워커가 떠 있어도 double pick 은 발생하지 않는다.
// ---------------------------------------------------------------------------
async function reclaimStaleExtractingJobs() {
  const cutoffIso = new Date(Date.now() - STALE_EXTRACTING_MS).toISOString();
  const { data: stale, error } = await supa
    .from('pb_extract_jobs')
    .select(
      'id,document_id,retry_count,max_retries,worker_name,updated_at,started_at',
    )
    .eq('status', 'extracting')
    .lt('updated_at', cutoffIso)
    .limit(50);
  if (error) {
    console.warn(
      '[pb-extract-worker] reclaim_stale_query_failed',
      compact(error.message || error),
    );
    return { requeued: 0, failed: 0 };
  }
  if (!stale || stale.length === 0) {
    return { requeued: 0, failed: 0 };
  }

  let requeued = 0;
  let failed = 0;
  for (const row of stale) {
    const retryCount = Number(row.retry_count || 0);
    const maxRetries = Number(row.max_retries || 0);
    const ageMs =
      Date.now() - new Date(row.updated_at || row.started_at || 0).getTime();
    const canRetry = retryCount < maxRetries || maxRetries <= 0;

    if (canRetry) {
      const { data: updated, error: updErr } = await supa
        .from('pb_extract_jobs')
        .update({
          status: 'queued',
          started_at: null,
          finished_at: null,
          error_code: 'worker_stalled',
          error_message: `reclaimed stale extracting lock after ${Math.round(ageMs / 1000)}s (prev worker=${row.worker_name || '-'})`,
          updated_at: new Date().toISOString(),
        })
        .eq('id', row.id)
        .eq('status', 'extracting')
        .select('id')
        .maybeSingle();
      if (updErr) {
        console.warn(
          '[pb-extract-worker] reclaim_requeue_failed',
          compact(updErr.message || updErr),
        );
        continue;
      }
      if (updated) requeued += 1;
    } else {
      const nowIso = new Date().toISOString();
      const { data: updated, error: updErr } = await supa
        .from('pb_extract_jobs')
        .update({
          status: 'failed',
          error_code: 'worker_stalled',
          error_message: `stale extracting lock gave up after ${retryCount}/${maxRetries} retries (age ${Math.round(ageMs / 1000)}s)`,
          finished_at: nowIso,
          updated_at: nowIso,
        })
        .eq('id', row.id)
        .eq('status', 'extracting')
        .select('id,document_id')
        .maybeSingle();
      if (updErr) {
        console.warn(
          '[pb-extract-worker] reclaim_fail_mark_failed',
          compact(updErr.message || updErr),
        );
        continue;
      }
      if (updated) {
        failed += 1;
        if (row.document_id) {
          await supa
            .from('pb_documents')
            .update({ status: 'failed', updated_at: nowIso })
            .eq('id', row.document_id);
        }
      }
    }
  }

  if (requeued > 0 || failed > 0) {
    console.warn(
      '[pb-extract-worker] reclaim_stale',
      JSON.stringify({
        requeued,
        failed,
        thresholdMs: STALE_EXTRACTING_MS,
      }),
    );
  }
  return { requeued, failed };
}

async function lockQueuedJob(row) {
  const nextRetry = Number(row.retry_count || 0) + 1;
  const { data, error } = await supa
    .from('pb_extract_jobs')
    .update({
      status: 'extracting',
      retry_count: nextRetry,
      worker_name: WORKER_NAME,
      started_at: new Date().toISOString(),
      finished_at: null,
      error_code: '',
      error_message: '',
    })
    .eq('id', row.id)
    .eq('status', 'queued')
    .select('*')
    .maybeSingle();
  if (error) throw new Error(`job_lock_failed:${error.message}`);
  if (data) {
    await updateTextbookExtractRunForJob({
      jobId: data.id,
      status: 'extracting',
    });
  }
  return data;
}

async function markJobFailed({
  jobId,
  documentId,
  error,
  skipDocumentStatusUpdate = false,
}) {
  const errMsg = compact(error?.message || error);
  const errCode = toErrorCode(error);
  const nowIso = new Date().toISOString();
  await supa
    .from('pb_extract_jobs')
    .update({
      status: 'failed',
      error_code: errCode,
      error_message: errMsg,
      finished_at: nowIso,
      updated_at: nowIso,
    })
    .eq('id', jobId);
  await updateTextbookExtractRunForJob({
    jobId,
    status: 'failed',
    errorCode: errCode,
    errorMessage: errMsg,
  });
  if (documentId && !skipDocumentStatusUpdate) {
    await supa
      .from('pb_documents')
      .update({
        status: 'failed',
        updated_at: nowIso,
      })
      .eq('id', documentId);
  }
}

async function updateTextbookExtractRunForJob({
  jobId,
  status,
  errorCode = '',
  errorMessage = '',
  resultSummary = null,
}) {
  if (!jobId) return;
  const patch = {
    status,
    error_code: errorCode,
    error_message: errorMessage,
    updated_at: new Date().toISOString(),
  };
  if (resultSummary) patch.result_summary = resultSummary;
  const { error } = await supa
    .from('textbook_pb_extract_runs')
    .update(patch)
    .eq('extract_job_id', jobId);
  if (error && !/relation .* does not exist/i.test(String(error.message || ''))) {
    console.warn(
      '[pb-extract-worker] textbook_run_update_failed',
      compact(error.message || error),
    );
  }
}

async function processOneJob(job) {
  const { data: doc, error: docErr } = await supa
    .from('pb_documents')
    .select(
      [
        'id',
        'academy_id',
        'source_storage_bucket',
        'source_storage_path',
        'source_filename',
        'source_pdf_storage_bucket',
        'source_pdf_storage_path',
        'source_pdf_filename',
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
    .eq('id', job.document_id)
    .eq('academy_id', job.academy_id)
    .maybeSingle();

  if (docErr || !doc) {
    throw new Error(docErr?.message || 'document_not_found');
  }

  const classification = buildClassificationFromDocument(doc);

  // PDF 가 첨부된 문서는 VLM 엔진으로 분기한다. HWPX 파싱·Gemini 보강 블록은 건너뛰고
  // "built / parsed / parseMode / engineMeta" 만 세팅한 뒤 공통 후처리(문항 insert/update,
  // figure job 큐잉, preview 스크린샷, 잡 상태 전이) 를 기존 HWPX 파이프라인과 공유한다.
  const hasPdfSource =
    VLM_ENABLED && compact(doc.source_pdf_storage_path).length > 0;
  // HWPX 원본이 붙어 있으면 figure 이미지를 BinData/*.png 에서 패스스루로 끌어올 수 있다.
  // VLM 경로에서도 HWPX 가 같이 업로드돼 있으면 이 경로를 타게 해서 Gemini 로 그림을 재생성하지
  // 않고 원본을 그대로 사용한다 (품질·정확도 모두 원본이 우월).
  const hasHwpxSource = compact(doc.source_storage_path).length > 0;

  let built;
  let parsed;
  let parseMode;
  let previewBuilt = null;
  let previewStemPatched = 0;
  let previewChoicePatched = 0;

  // Gemini 보강 단계 결과 플래그들. VLM 분기에서는 사용하지 않지만 공통 후처리가
  // resultSummary 에 넣을 수 있도록 미리 초기화한다.
  let geminiTried = false;
  let geminiUsed = false;
  let geminiError = '';
  let geminiCandidateQuestions = 0;
  let geminiRejectedReason = '';
  let geminiEnrichedQuestions = 0;
  let geminiStemPatched = 0;
  let geminiChoicePatched = 0;

  // VLM 엔진 전용 메타 (HWPX 경로에서는 null).
  let engineMeta = null;

  if (hasPdfSource) {
    const vlmResult = await runVlmExtraction({
      job,
      doc,
      supa,
      apiKey: GEMINI_API_KEY,
      model: VLM_MODEL,
      reviewConfidenceThreshold: REVIEW_CONFIDENCE_THRESHOLD,
      timeoutMs: VLM_TIMEOUT_MS,
      log: (event, payload) => {
        try {
          console.log(
            `[pb-extract-worker] vlm_${event}`,
            JSON.stringify({ ...payload }),
          );
        } catch (_) {
          // logging 실패는 무시.
        }
      },
    });
    built = vlmResult.built;
    parsed = vlmResult.parsed;
    parseMode = 'vlm';
    engineMeta = vlmResult.meta || { engine: 'vlm' };

    // HWPX overlay 를 VLM payload 에 적용. HWPX 원본의 <hp:pic binaryItemIDRef>
    //   → PB_FIG 토큰 매핑을 ground truth 로 신뢰해, VLM 이 figure 를 오인식한 경우도
    //   token-first 매칭 경로로 정확히 재배치되도록 한다.
    //
    //   - HWPX 가 없으면 (pdf-only) skip.
    //   - HWPX 파싱 실패 시 overlay 생략 (VLM 원본 사용).
    //   - 문항 번호가 매칭 안 되는 개별 문항은 VLM 원본 유지.
    if (hasHwpxSource) {
      try {
        const hwpxBucket = String(
          doc.source_storage_bucket || 'problem-documents',
        ).trim();
        const hwpxPath = String(doc.source_storage_path || '').trim();
        if (hwpxBucket && hwpxPath) {
          const { data: hwpxBlob, error: hwpxDlErr } = await supa.storage
            .from(hwpxBucket)
            .download(hwpxPath);
          if (hwpxDlErr) {
            throw new Error(
              `vlm_hwpx_overlay_download_failed:${hwpxDlErr.message}`,
            );
          }
          const hwpxBuffer = await toBufferFromStorageData(hwpxBlob);
          if (hwpxBuffer && hwpxBuffer.length > 0) {
            const overlayLog = (event, payload) => {
              try {
                console.log(
                  `[pb-extract-worker] ${event}`,
                  JSON.stringify({ jobId: job.id, ...payload }),
                );
              } catch (_) {
                // logging 실패 무시.
              }
            };
            const figureMap = buildHwpxFigureMapByQuestionNumber(hwpxBuffer, {
              threshold: REVIEW_CONFIDENCE_THRESHOLD,
              log: overlayLog,
            });
            if (figureMap.size > 0) {
              let overlayApplied = 0;
              let overlayUnmatched = 0;
              const overlayedQuestions = (built.questions || []).map((q) => {
                const qNo = normalizeWhitespace(q?.question_number || '');
                const overlay = qNo ? figureMap.get(qNo) : null;
                if (!overlay) {
                  overlayUnmatched += 1;
                  return q;
                }
                overlayApplied += 1;
                return applyHwpxFigureOverlayToVlmPayload(q, overlay);
              });
              built.questions = overlayedQuestions;
              overlayLog('vlm_hwpx_figure_overlay_applied', {
                overlayApplied,
                overlayUnmatched,
                hwpxMappedCount: figureMap.size,
              });
            }
          }
        }
      } catch (err) {
        console.warn(
          '[pb-extract-worker] vlm_hwpx_figure_overlay_skipped',
          JSON.stringify({
            jobId: job.id,
            message: String(err?.message || err || ''),
          }),
        );
      }
    }
  } else {
    const bucket = String(doc.source_storage_bucket || 'problem-documents').trim();
    const path = String(doc.source_storage_path || '').trim();
    if (!path) {
      throw new Error('document_storage_path_empty');
    }

    const { data: fileData, error: dlErr } = await supa.storage
      .from(bucket)
      .download(path);
    if (dlErr || !fileData) {
      throw new Error(dlErr?.message || 'document_download_failed');
    }
    const buffer = await toBufferFromStorageData(fileData);
    if (!buffer || buffer.length === 0) {
      throw new Error('document_buffer_empty');
    }

    parsed = parseHwpxBuffer(buffer);
    const xmlBuilt = buildQuestionRows({
      academyId: job.academy_id,
      documentId: job.document_id,
      extractJobId: job.id,
      parsed: { sections: parsed.sections },
      threshold: REVIEW_CONFIDENCE_THRESHOLD,
    });
    built = xmlBuilt;
    parseMode = 'xml';
    if (parsed.previewSection) {
      previewBuilt = buildQuestionRows({
        academyId: job.academy_id,
        documentId: job.document_id,
        extractJobId: job.id,
        parsed: { sections: [parsed.previewSection] },
        threshold: REVIEW_CONFIDENCE_THRESHOLD,
      });
      if (parseQualityScore(previewBuilt) > parseQualityScore(xmlBuilt)) {
        built = previewBuilt;
        parseMode = 'preview';
      } else {
        const enriched = enrichXmlQuestionsWithPreview(
          xmlBuilt,
          previewBuilt,
          REVIEW_CONFIDENCE_THRESHOLD,
        );
        built = enriched.built;
        previewStemPatched = enriched.stemPatched;
        previewChoicePatched = enriched.choicePatched;
        if (previewStemPatched > 0 || previewChoicePatched > 0) {
          parseMode = 'xml_enriched';
        }
      }
    }

    if (shouldAttemptGemini(parsed, built)) {
      geminiTried = true;
      try {
        const sourceText = buildGeminiSourceText(parsed);
        const examProfileHint = built.stats.examProfile || '';
        let drafts = [];
        try {
          drafts = await callGeminiQuestionExtractor({
            sourceText,
            examProfileHint,
          });
        } catch (firstErr) {
          const firstMsg = String(firstErr?.message || firstErr || '');
          const retryable = /aborted|timeout|408|deadline/i.test(firstMsg);
          if (!retryable || sourceText.length < 7000) {
            throw firstErr;
          }
          // 타임아웃/abort 시 입력을 줄여 1회 재시도한다.
          const retrySourceText = sourceText.slice(0, 9000);
          drafts = await callGeminiQuestionExtractor({
            sourceText: retrySourceText,
            examProfileHint,
          });
        }
        const geminiBuilt = buildGeminiQuestionRows({
          academyId: job.academy_id,
          documentId: job.document_id,
          extractJobId: job.id,
          drafts,
          threshold: REVIEW_CONFIDENCE_THRESHOLD,
        });
        geminiCandidateQuestions = Number(geminiBuilt.questions.length || 0);
        const betterThanCurrent = shouldAcceptGeminiResult(parsed, built, geminiBuilt);
        const currentQuestionCount = built.questions.length;
        if (betterThanCurrent && geminiBuilt.questions.length > 0) {
          if (shouldAllowFullGeminiReplace(parsed, built, geminiBuilt)) {
            built = geminiBuilt;
            parseMode = 'gemini';
            geminiUsed = true;
          } else {
            const enriched = enrichBuiltWithGemini(
              built,
              geminiBuilt,
              REVIEW_CONFIDENCE_THRESHOLD,
            );
            built = enriched.built;
            geminiEnrichedQuestions = enriched.touchedCount;
            geminiStemPatched = enriched.stemPatched;
            geminiChoicePatched = enriched.choicePatched;
            if (geminiEnrichedQuestions > 0) {
              parseMode = `${parseMode}_gemini_enriched`;
              geminiUsed = true;
            } else {
              geminiRejectedReason = 'replace_guard';
            }
          }
        } else if (geminiBuilt.questions.length <= 0) {
          geminiRejectedReason = 'empty_result';
        } else {
          geminiRejectedReason = 'quality_guard';
        }
        console.log(
          '[pb-extract-worker] gemini_probe',
          JSON.stringify({
            jobId: job.id,
            currentQuestions: currentQuestionCount,
            geminiQuestions: geminiBuilt.questions.length,
            geminiUsed,
            geminiPriority: GEMINI_PRIORITY,
            geminiRejectedReason,
            geminiEnrichedQuestions,
          }),
        );
      } catch (err) {
        geminiError = compact(err?.message || err);
        console.error(
          '[pb-extract-worker] gemini_fail',
          JSON.stringify({
            jobId: job.id,
            message: geminiError,
          }),
        );
        geminiRejectedReason = 'gemini_error';
      }
    }
  }

  // VLM 경로는 문항 타입/보기/정답을 자체적으로 결정하므로 dualMode 변환을 건너뛴다.
  // HWPX 경로는 기존대로 "주관식 보기 자동 생성" 보강 단계를 거친다.
  const dualModeResult = hasPdfSource
    ? { questions: built.questions || [], stats: {} }
    : await enrichQuestionsWithDualMode({
        questions: built.questions || [],
        examProfileHint: built?.stats?.examProfile || '',
      });
  built.questions = dualModeResult.questions;

  const { questions, stats } = built;
  const dualModeStats = dualModeResult.stats || {};
  const nowIso = new Date().toISOString();
  const targetQuestionIds = normalizeTargetQuestionIdsFromJob(job);
  const partialReextract = targetQuestionIds.length > 0;
  let figureJobsQueued = 0;
  let figureJobSeedError = '';
  let partialUpdatedCount = 0;
  let partialLowConfidenceCount = 0;
  let partialMissingTargets = [];
  let partialUpdatedQuestionIds = [];

  const { data: existingRows, error: existingErr } = await supa
    .from('pb_questions')
    .select(
      'id,question_number,question_uid,source_order,' +
        'allow_objective,allow_subjective,objective_choices,' +
        'objective_answer_key,objective_generated,meta',
    )
    .eq('academy_id', job.academy_id)
    .eq('document_id', job.document_id)
    .order('source_order', { ascending: true });
  if (existingErr) {
    throw new Error(`current_questions_fetch_failed:${existingErr.message}`);
  }
  const existingById = new Map(
    (existingRows || []).map((row) => [String(row.id || '').trim(), row]),
  );
  const existingQuestionUidQueueByNumber = new Map();
  for (const row of existingRows || []) {
    const questionNumber = normalizeWhitespace(row?.question_number || '');
    const questionUid = normalizeWhitespace(row?.question_uid || '');
    if (!questionNumber || !questionUid) continue;
    const queue = existingQuestionUidQueueByNumber.get(questionNumber) || [];
    queue.push(questionUid);
    existingQuestionUidQueueByNumber.set(questionNumber, queue);
  }
  const consumeQuestionUidByQuestionNumber = (rawQuestionNumber) => {
    const key = normalizeWhitespace(rawQuestionNumber || '');
    if (!key) return '';
    const queue = existingQuestionUidQueueByNumber.get(key);
    if (!Array.isArray(queue) || queue.length === 0) return '';
    const uid = normalizeWhitespace(queue.shift() || '');
    if (queue.length === 0) {
      existingQuestionUidQueueByNumber.delete(key);
    } else {
      existingQuestionUidQueueByNumber.set(key, queue);
    }
    return uid;
  };

  if (partialReextract) {
    const parsedByQuestionNumber = new Map();
    for (const parsedQuestion of questions) {
      const qNo = normalizeWhitespace(parsedQuestion?.question_number || '');
      if (!qNo || parsedByQuestionNumber.has(qNo)) continue;
      parsedByQuestionNumber.set(qNo, parsedQuestion);
    }
    const updateRows = [];
    for (const targetId of targetQuestionIds) {
      const current = existingById.get(targetId);
      if (!current) {
        partialMissingTargets.push({
          questionId: targetId,
          reason: 'question_not_found',
        });
        continue;
      }
      const targetQuestionNumber = normalizeWhitespace(current.question_number || '');
      const parsed = parsedByQuestionNumber.get(targetQuestionNumber);
      if (!parsed) {
        partialMissingTargets.push({
          questionId: targetId,
          questionNumber: targetQuestionNumber,
          reason: 'parsed_question_not_found',
        });
        continue;
      }
      if (Number(parsed?.confidence || 0) < REVIEW_CONFIDENCE_THRESHOLD) {
        partialLowConfidenceCount += 1;
      }

      // 부분 재추출: 사용자가 매니저에서 `allow_objective=false` 로 설정해둔 문항은
      //  - 자동으로 생성된 5지선다 보기/정답을 다시 만들지 않고
      //  - 기존에 비워둔 상태를 그대로 유지한다
      // 이렇게 하지 않으면 재추출할 때마다 AI가 다시 객관식 보기를 만들어내서 사용자 의도를 덮어쓴다.
      if (current.allow_objective === false) {
        parsed.allow_objective = false;
        parsed.objective_choices = [];
        parsed.objective_answer_key = '';
        parsed.objective_generated = false;
        if (parsed.meta && typeof parsed.meta === 'object') {
          parsed.meta.allow_objective = false;
          parsed.meta.objective_answer_key = '';
          delete parsed.meta.objective_generated;
        }
      }
      if (current.allow_subjective === false) {
        parsed.allow_subjective = false;
        if (parsed.meta && typeof parsed.meta === 'object') {
          parsed.meta.allow_subjective = false;
        }
      }

      updateRows.push({
        id: targetId,
        ...buildQuestionWritePayload({
          question: parsed,
          classification,
          academyId: job.academy_id,
          documentId: job.document_id,
          extractJobId: job.id,
          questionUid: normalizeWhitespace(current.question_uid || ''),
        }),
        updated_at: nowIso,
      });
    }
    if (updateRows.length === 0) {
      throw new Error('partial_reextract_no_targets_updated');
    }
    const { error: upsertErr } = await supa.from('pb_questions').upsert(updateRows, {
      onConflict: 'id',
    });
    if (upsertErr) {
      throw new Error(`partial_question_upsert_failed:${upsertErr.message}`);
    }
    partialUpdatedCount = updateRows.length;
    partialUpdatedQuestionIds = updateRows.map((row) => row.id);
  } else {
    await supa.from('pb_questions').delete().eq('document_id', job.document_id);
    // 이 document 의 과거 figure_job 잔재 (queued / processing / succeeded / failed 모두)
    // 까지 싹 지운다. 남아있으면:
    //   1) queued/processing 상태의 dangling job 이 재추출 후 엉뚱한 question_id 를
    //      가리킨 채 worker 에 다시 pick 될 수 있다.
    //   2) figure_worker 는 이번 추출로 새로 생긴 question row 에 prev asset 이 없어도,
    //      같은 document 내 question 간 이동이 생겼을 때 과거 upload 된 asset 이
    //      다른 문항으로 옮겨가서 "Q9/Q11 에 그림이 중복" 되는 관측 증상의 온상이 된다.
    // pb_figure_jobs 는 추출 직후 재생성되므로 (아래 AUTO_QUEUE_FIGURE_JOBS 분기) 선삭제는 안전.
    const { error: figJobCleanupErr } = await supa
      .from('pb_figure_jobs')
      .delete()
      .eq('document_id', job.document_id);
    if (figJobCleanupErr) {
      console.warn(
        '[pb-extract-worker] figure_jobs_cleanup_skipped',
        JSON.stringify({ jobId: job.id, message: compact(figJobCleanupErr.message) }),
      );
    }

    if (questions.length > 0) {
      const chunkSize = 300;
      for (let i = 0; i < questions.length; i += chunkSize) {
        const chunk = questions.slice(i, i + chunkSize).map((q) =>
          buildQuestionWritePayload({
            question: q,
            classification,
            academyId: job.academy_id,
            documentId: job.document_id,
            extractJobId: job.id,
            questionUid: consumeQuestionUidByQuestionNumber(q.question_number),
          }),
        );
        const { error: insertErr } = await supa.from('pb_questions').insert(chunk);
        if (insertErr) {
          throw new Error(`question_insert_failed:${insertErr.message}`);
        }
      }
    }

    // Figure job 큐잉 조건: HWPX 원본이 있어야 한다 (BinData/*.png 를 꺼내 쓰기 위함).
    //
    //   - HWPX-only  : 기존과 동일. figure worker 가 BinData 를 읽고 PASSTHROUGH 로 원본 업로드.
    //   - HWPX+PDF   : VLM 경로에서도 동일하게 큐잉. figure worker 는 HWPX 에서만 이미지를 가져오므로
    //                  Gemini 가 그림을 상상으로 만드는 일 없이 원본 이미지가 그대로 문항에 매핑된다.
    //                  VLM writeback 은 meta.figure_count 를 채워주므로 inferQuestionFigureCount 에서
    //                  figure 매핑 정확도가 올라간다.
    //   - PDF-only   : HWPX 원본이 없으므로 현재는 figure 생성 스킵 (향후 PDF 크롭 fallback 가능).
    if (hasHwpxSource && AUTO_QUEUE_FIGURE_JOBS && questions.length > 0) {
      try {
        const { data: insertedQuestions, error: fetchInsertedErr } = await supa
          .from('pb_questions')
          .select('id,figure_refs')
          .eq('academy_id', job.academy_id)
          .eq('document_id', job.document_id)
          .eq('extract_job_id', job.id);
        if (fetchInsertedErr) {
          throw new Error(`figure_seed_fetch_failed:${fetchInsertedErr.message}`);
        }
        // figure job은 "실제 그림/도형"(<hp:pic> 등)이 있는 문항에만 큐잉한다.
        // 표([표행]/[표셀])만 있는 문항까지 Gemini 이미지를 생성하면
        // 존재하지 않는 그림이 추론되어 엉뚱한 문항에 붙는 문제를 유발했다.
        //
        // 인식 대상:
        //   - plain `[그림]` / `[도형]` (VLM/구버전 추출)
        //   - `[[PB_FIG_<itemID>]]` 토큰 (HWPX binaryItemIDRef 보존 토큰; 현재 기본)
        //   → 둘 중 하나라도 있으면 "실제 그림 있음" 으로 판정.
        //
        // 주의: `[표행]`/`[표셀]` 같은 표 전용 마커는 여기서 걸러져서 큐에 들어가지 않는다.
        const hasRealFigureMarker = (refs) => {
          if (!Array.isArray(refs)) return false;
          return refs.some((ref) => {
            const text = normalizeWhitespace(String(ref || ''));
            if (!text) return false;
            if (text.includes('[그림]')) return true;
            if (text.includes('[도형]')) return true;
            if (/\[\[PB_FIG_[^\]]+\]\]/.test(text)) return true;
            return false;
          });
        };
        const figureJobRows = (insertedQuestions || [])
          .filter(
            (row) =>
              Array.isArray(row.figure_refs) &&
              row.figure_refs.length > 0 &&
              hasRealFigureMarker(row.figure_refs),
          )
          .map((row) => ({
            academy_id: job.academy_id,
            document_id: job.document_id,
            question_id: row.id,
            created_by: job.created_by || null,
            status: 'queued',
            provider: 'gemini',
            model_name: '',
            options: {},
            prompt_text: '',
            worker_name: '',
            result_summary: {},
            output_storage_bucket: 'problem-previews',
            output_storage_path: '',
            error_code: '',
            error_message: '',
            started_at: null,
            finished_at: null,
          }));
        if (figureJobRows.length > 0) {
          const { error: figureInsertErr } = await supa
            .from('pb_figure_jobs')
            .insert(figureJobRows);
          if (figureInsertErr) {
            throw new Error(`figure_job_seed_failed:${figureInsertErr.message}`);
          }
          figureJobsQueued = figureJobRows.length;
        }
      } catch (err) {
        figureJobSeedError = compact(err?.message || err);
        console.warn(
          '[pb-extract-worker] figure_seed_skip',
          JSON.stringify({
            jobId: job.id,
            message: figureJobSeedError,
          }),
        );
      }
    }
  }

  let setDeliveryStats = { sets: 0, items: 0, deliveryUnits: 0, skipped: true };
  if (questions.length > 0) {
    try {
      const { data: setModelRows, error: setModelErr } = await supa
        .from('pb_questions')
        .select('id,question_uid,question_number,stem,meta')
        .eq('academy_id', job.academy_id)
        .eq('document_id', job.document_id)
        .order('source_order', { ascending: true });
      if (setModelErr) {
        throw new Error(`set_model_question_fetch_failed:${setModelErr.message}`);
      }
      setDeliveryStats = await reconcileQuestionSetDeliveryUnits({
        academyId: job.academy_id,
        documentId: job.document_id,
        rows: setModelRows || [],
        hasPdfSource,
      });
    } catch (err) {
      const message = compact(err?.message || err);
      setDeliveryStats = {
        sets: 0,
        items: 0,
        deliveryUnits: 0,
        skipped: true,
        error: message,
      };
      console.warn('[pb-extract-worker] set_model_sync_skip', JSON.stringify({
        jobId: job.id,
        message,
      }));
    }
  }

  let previewScreenshotCount = 0;
  let previewScreenshotError = '';
  if (questions.length > 0) {
    try {
      let previewTargets = [];
      if (partialReextract) {
        const { data: updatedRows, error: fetchUpdatedErr } = await supa
          .from('pb_questions')
          .select('*')
          .eq('academy_id', job.academy_id)
          .eq('document_id', job.document_id)
          .in('id', partialUpdatedQuestionIds);
        if (fetchUpdatedErr) {
          throw new Error(`partial_preview_fetch_failed:${fetchUpdatedErr.message}`);
        }
        previewTargets = updatedRows || [];
      } else {
        const { data: allInserted, error: fetchAllErr } = await supa
          .from('pb_questions')
          .select('*')
          .eq('academy_id', job.academy_id)
          .eq('document_id', job.document_id)
          .eq('extract_job_id', job.id);
        if (fetchAllErr) {
          throw new Error(`preview_fetch_failed:${fetchAllErr.message}`);
        }
        previewTargets = allInserted || [];
      }
      if (previewTargets.length > 0) {
        const results = await generateQuestionPreviews({
          questions: previewTargets,
          academyId: job.academy_id,
          layout: {},
          supabaseClient: supa,
          mathEngine: 'xelatex',
        });
        previewScreenshotCount = results.filter((r) => r.imageUrl).length;
        console.log(
          '[pb-extract-worker] preview_screenshots',
          JSON.stringify({
            jobId: job.id,
            total: previewTargets.length,
            generated: previewScreenshotCount,
            partialReextract,
          }),
        );
      }
    } catch (err) {
      previewScreenshotError = compact(err?.message || err);
      console.warn(
        '[pb-extract-worker] preview_screenshot_skip',
        JSON.stringify({ jobId: job.id, message: previewScreenshotError }),
      );
    }
  }

  const reviewRequired = partialReextract
    ? partialLowConfidenceCount > 0
    : stats.lowConfidenceCount > 0;
  const jobStatus = reviewRequired ? 'review_required' : 'completed';
  const currentDocStatus = normalizeWhitespace(doc.status || '');
  const docStatus = partialReextract
    ? (reviewRequired
      ? 'draft_review_required'
      : (currentDocStatus || 'draft_ready'))
    : (reviewRequired ? 'draft_review_required' : 'draft_ready');

  const resultSummary = {
    engine: hasPdfSource ? 'vlm' : 'hwpx',
    engineModel: hasPdfSource ? VLM_MODEL : (GEMINI_ENABLED ? GEMINI_MODEL : ''),
    vlm: engineMeta
      ? {
          model: engineMeta.model || VLM_MODEL,
          elapsedMs: Number(engineMeta.elapsedMs || 0),
          finishReason: String(engineMeta.finishReason || ''),
          documentMeta: engineMeta.documentMeta || null,
          usage: engineMeta.usage || null,
        }
      : null,
    totalQuestions: questions.length,
    lowConfidenceCount: stats.lowConfidenceCount,
    circledChoices: stats.circledChoices,
    viewBlocks: stats.viewBlocks,
    figureLines: stats.figureLines,
    equationRefs: stats.equationRefs,
    sourceLineCount: stats.sourceLineCount,
    segmentedLineCount: stats.segmentedLineCount,
    answerHintCount: Number(stats.answerHintCount || 0),
    setDelivery: setDeliveryStats,
    scoreHeaderHint: Number(parsed?.hints?.scoreHeaderCount || 0),
    previewLineCount: Number(parsed?.hints?.previewLineCount || 0),
    parseMode,
    previewStemPatched,
    previewChoicePatched,
    geminiEnabled: GEMINI_ENABLED,
    geminiPriority: GEMINI_PRIORITY,
    geminiTried,
    geminiUsed,
    geminiCandidateQuestions,
    geminiRejectedReason,
    geminiEnrichedQuestions,
    geminiStemPatched,
    geminiChoicePatched,
    geminiModel: GEMINI_ENABLED ? GEMINI_MODEL : '',
    geminiError,
    figureJobsQueued,
    figureJobSeedError,
    autoQueueFigureJobs: AUTO_QUEUE_FIGURE_JOBS,
    subjectiveTargetCount: Number(dualModeStats.subjectiveTargetCount || 0),
    objectiveGeneratedCount: Number(dualModeStats.objectiveGeneratedCount || 0),
    objectiveUnavailableCount: Number(dualModeStats.objectiveUnavailableCount || 0),
    examProfileDetected: stats.examProfile,
    reviewThreshold: REVIEW_CONFIDENCE_THRESHOLD,
    partialReextract,
    partialTargetCount: targetQuestionIds.length,
    partialUpdatedCount,
    partialLowConfidenceCount,
    partialMissingTargetCount: partialMissingTargets.length,
    partialMissingTargets,
  };

  const nextDocMeta = {
    ...(doc.meta || {}),
    extraction: {
      parser: hasPdfSource
        ? 'pb_extract_worker_vlm_v1'
        : 'pb_extract_worker_v1',
      processed_at: nowIso,
      parse_mode: parseMode,
      file_name: doc.source_filename || '',
      pdf_file_name: hasPdfSource
        ? String(doc.source_pdf_filename || '').trim()
        : '',
      ...resultSummary,
    },
  };

  const { error: jobUpdateErr } = await supa
    .from('pb_extract_jobs')
    .update({
      status: jobStatus,
      result_summary: resultSummary,
      error_code: '',
      error_message: '',
      finished_at: nowIso,
      updated_at: nowIso,
    })
    .eq('id', job.id);
  if (jobUpdateErr) {
    throw new Error(`job_update_failed:${jobUpdateErr.message}`);
  }
  await updateTextbookExtractRunForJob({
    jobId: job.id,
    status: jobStatus,
    resultSummary,
  });

  const { error: docUpdateErr } = await supa
    .from('pb_documents')
    .update({
      status: docStatus,
      curriculum_code: classification.curriculum_code,
      source_type_code: classification.source_type_code,
      course_label: classification.course_label,
      grade_label: classification.grade_label,
      exam_year: classification.exam_year,
      semester_label: classification.semester_label,
      exam_term_label: classification.exam_term_label,
      school_name: classification.school_name,
      publisher_name: classification.publisher_name,
      material_name: classification.material_name,
      classification_detail: classification.classification_detail,
      meta: nextDocMeta,
      updated_at: nowIso,
    })
    .eq('id', doc.id);
  if (docUpdateErr) {
    throw new Error(`document_update_failed:${docUpdateErr.message}`);
  }

  return {
    jobStatus,
    docStatus,
    questionCount: partialReextract ? partialUpdatedCount : questions.length,
    lowConfidenceCount: partialReextract
      ? partialLowConfidenceCount
      : stats.lowConfidenceCount,
    examProfile: stats.examProfile,
  };
}

async function processBatch() {
  const { data: queue, error } = await supa
    .from('pb_extract_jobs')
    .select(
      'id,academy_id,document_id,status,retry_count,max_retries,created_at,updated_at',
    )
    .eq('status', 'queued')
    .order('created_at', { ascending: true })
    .limit(BATCH_SIZE);

  if (error) {
    throw new Error(`queue_fetch_failed:${error.message}`);
  }
  if (!queue || queue.length === 0) {
    return { processed: 0, success: 0, failed: 0 };
  }

  const summary = { processed: 0, success: 0, failed: 0 };

  for (const row of queue) {
    let locked = null;
    summary.processed += 1;
    try {
      locked = await lockQueuedJob(row);
      if (!locked) {
        continue;
      }
      const retryCount = Number(locked.retry_count || 0);
      const maxRetries = Number(locked.max_retries ?? 3);
      if (retryCount > maxRetries) {
        const partialReextract = normalizeTargetQuestionIdsFromJob(locked).length > 0;
        await markJobFailed({
          jobId: locked.id,
          documentId: locked.document_id,
          error: new Error('max_retries_exceeded'),
          skipDocumentStatusUpdate: partialReextract,
        });
        summary.failed += 1;
        continue;
      }

      const result = await processOneJob(locked);
      console.log(
        '[pb-extract-worker] done',
        JSON.stringify({
          jobId: locked.id,
          docId: locked.document_id,
          questionCount: result.questionCount,
          lowConfidenceCount: result.lowConfidenceCount,
          examProfile: result.examProfile,
          status: result.jobStatus,
        }),
      );
      summary.success += 1;
    } catch (err) {
      const partialReextract = normalizeTargetQuestionIdsFromJob(locked).length > 0;
      console.error(
        '[pb-extract-worker] fail',
        JSON.stringify({
          jobId: locked?.id || row.id,
          docId: locked?.document_id || row.document_id,
          errorCode: toErrorCode(err),
          message: compact(err?.message || err),
          partialReextract,
        }),
      );
      await markJobFailed({
        jobId: locked?.id || row.id,
        documentId: locked?.document_id || row.document_id,
        error: err,
        skipDocumentStatusUpdate: partialReextract,
      });
      summary.failed += 1;
    }
  }
  return summary;
}

async function main() {
  console.log(
    '[pb-extract-worker] start',
    JSON.stringify({
      worker: WORKER_NAME,
      intervalMs: WORKER_INTERVAL_MS,
      batchSize: BATCH_SIZE,
      threshold: REVIEW_CONFIDENCE_THRESHOLD,
      geminiEnabled: GEMINI_ENABLED,
      geminiModel: GEMINI_MODEL,
      geminiPriority: GEMINI_PRIORITY,
      geminiKeyConfigured: GEMINI_KEY_CONFIGURED,
      geminiFlag: process.env.PB_GEMINI_ENABLED || '',
      autoQueueFigureJobs: AUTO_QUEUE_FIGURE_JOBS,
      once: PROCESS_ONCE,
      staleExtractingMs: STALE_EXTRACTING_MS,
    }),
  );
  if (!GEMINI_ENABLED) {
    console.warn(
      '[pb-extract-worker] gemini_disabled',
      JSON.stringify({
        reason: GEMINI_KEY_CONFIGURED
          ? 'PB_GEMINI_ENABLED=0_or_model_empty'
          : 'missing_GEMINI_API_KEY',
      }),
    );
  }

  // 기동 직후: 이전 워커가 비정상 종료되어 'extracting' 에 묶여 있는 job 들을
  // 먼저 풀어준다. 그래야 매니저 UI 의 "무한 로딩" 이 바로 해소된다.
  try {
    await reclaimStaleExtractingJobs();
  } catch (err) {
    console.error(
      '[pb-extract-worker] reclaim_startup_failed',
      compact(err?.message || err),
    );
  }

  // stale 체크를 매 tick 마다 하면 DB 쿼리가 낭비되므로 최소 인터벌을 두고
  // (기본 STALE/2) 만큼 지난 경우에만 재검사한다.
  let lastReclaimAt = Date.now();
  const reclaimIntervalMs = Math.max(30_000, Math.floor(STALE_EXTRACTING_MS / 2));

  while (true) {
    try {
      if (Date.now() - lastReclaimAt >= reclaimIntervalMs) {
        await reclaimStaleExtractingJobs().catch((err) => {
          console.warn(
            '[pb-extract-worker] reclaim_periodic_failed',
            compact(err?.message || err),
          );
        });
        lastReclaimAt = Date.now();
      }
      const summary = await processBatch();
      if (summary.processed > 0) {
        console.log('[pb-extract-worker] batch', JSON.stringify(summary));
      }
      if (PROCESS_ONCE) break;
      await sleep(WORKER_INTERVAL_MS);
    } catch (err) {
      console.error(
        '[pb-extract-worker] batch_error',
        compact(err?.message || err),
      );
      if (PROCESS_ONCE) break;
      await sleep(WORKER_INTERVAL_MS);
    }
  }

  console.log('[pb-extract-worker] exit');
}

import { pathToFileURL } from 'node:url';
const _IS_DIRECT_RUN =
  typeof process.argv[1] === 'string' &&
  process.argv[1].length > 0 &&
  import.meta.url === pathToFileURL(process.argv[1]).href;

if (_IS_DIRECT_RUN) {
  main().catch((err) => {
    console.error('[pb-extract-worker] fatal', compact(err?.message || err));
    process.exit(1);
  });
}

export {
  parseHwpxBuffer as _parseHwpxBuffer,
  buildQuestionRows as _buildQuestionRows,
  normalizeEquationRaw as _normalizeEquationRaw,
  transformXmlToLines as _transformXmlToLines,
  extractEndNoteAnswerHints as _extractEndNoteAnswerHints,
  injectSubQuestionMarkers,
  buildHwpxFigureMapByQuestionNumber as _buildHwpxFigureMapByQuestionNumber,
  applyHwpxFigureOverlayToVlmPayload as _applyHwpxFigureOverlayToVlmPayload,
};
