import 'dotenv/config';
import AdmZip from 'adm-zip';
import { XMLParser } from 'fast-xml-parser';
import hePkg from 'he';
import { createClient } from '@supabase/supabase-js';
import { generateQuestionPreviews } from './problem_bank_preview_service.js';

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
  const meta = doc?.meta && typeof doc.meta === 'object' ? doc.meta : {};
  const sourceRaw =
    meta.source_classification && typeof meta.source_classification === 'object'
      ? meta.source_classification
      : {};
  const naesinRaw = sourceRaw.naesin && typeof sourceRaw.naesin === 'object' ? sourceRaw.naesin : {};
  const legacySourceType = toBoolean(sourceRaw.private_material)
    ? 'market_book'
    : toBoolean(sourceRaw.mock_past_exam)
      ? 'mock_past'
      : toBoolean(sourceRaw.school_past_exam)
        ? 'school_past'
        : 'school_past';
  const semesterCandidate = normalizeWhitespace(naesinRaw.semester);
  const examTermCandidate = normalizeWhitespace(naesinRaw.exam_term);
  return {
    curriculum_code: normalizeCurriculumCode(doc?.curriculum_code, 'rev_2022'),
    source_type_code: normalizeSourceTypeCode(
      doc?.source_type_code,
      legacySourceType,
    ),
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

function objectiveAnswerToSubjective(answerKey, choices = []) {
  const raw = normalizeWhitespace(String(answerKey || ''));
  if (!raw) return '';
  const tokens = raw
    .split(/[,/]/)
    .map((t) => normalizeWhitespace(t))
    .filter(Boolean);
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
  if (/^[①②③④⑤⑥⑦⑧⑨⑩]$/.test(raw)) return raw;
  if (/^\d{1,2}$/.test(raw)) return toCircledNumber(raw);
  if (/^\d{1,2}(\s*[,/]\s*\d{1,2})+$/.test(raw)) {
    return raw
      .split(/[,/]/)
      .map((token) => toCircledNumber(token))
      .join(', ');
  }
  if (/^[①②③④⑤⑥⑦⑧⑨⑩](\s*[,/]\s*[①②③④⑤⑥⑦⑧⑨⑩])+$/.test(raw)) {
    return raw
      .split(/[,/]/)
      .map((token) => normalizeWhitespace(token))
      .filter(Boolean)
      .join(', ');
  }
  return raw;
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
  if (/^[①②③④⑤⑥⑦⑧⑨⑩]$/.test(raw)) return raw;
  if (/^\d{1,2}$/.test(raw)) return toCircledNumber(raw);
  if (/^\d{1,2}(\s*[,/]\s*\d{1,2})+$/.test(raw)) {
    return raw
      .split(/[,/]/)
      .map((token) => toCircledNumber(token))
      .join(', ');
  }
  return raw;
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
  return /(그림|도표|도형|표\s*\d*|자료|그래프|지도)/.test(line);
}

function isFigureReferenceLine(line) {
  const input = normalizeWhitespace(line);
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

function transformParagraphBodyToLines(body) {
  let s = String(body || '');
  s = s.replace(
    /<hp:autoNum[^>]*num="(\d+)"[^>]*>[\s\S]*?<\/hp:autoNum>/gi,
    ' $1 ',
  );
  s = s.replace(/<hp:pic[\s\S]*?<\/hp:pic>/gi, ' [그림] ');
  s = s.replace(/<hp:shape[\s\S]*?<\/hp:shape>/gi, ' [도형] ');
  s = replaceHwpSoftBreakElements(s);
  s = s.replace(
    /<\/(hp:run|hp:r|hp:span|hp:ctrl|hp:subList|hp:tc|hp:tr|tr|li)>/gi,
    ' ',
  );
  s = s.replace(/<[^>]+>/g, ' ');
  s = htmlDecode(s);
  return splitParagraphTextToLines(s);
}

function flattenBoxXmlToRows(match, { table = false, alignResolver = null } = {}) {
  let inner = String(match || '')
    .replace(/<hp:pic[\s\S]*?<\/hp:pic>/gi, ' [그림] ')
    .replace(/<hp:shape[\s\S]*?<\/hp:shape>/gi, ' [도형] ');
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
      const normalized = splitKoreanConditionMarkersInBoxText(line)
        .split('\n')
        .map((part) => normalizeWhitespace(part))
        .filter(Boolean);
      for (const one of normalized) {
        rows.push({
          text: one,
          align,
        });
      }
    }
  }
  if (rows.length > 0) return rows;
  const fallback = splitKoreanConditionMarkersInBoxText(
    inner.replace(/<[^>]+>/g, ' '),
  )
    .split('\n')
    .map((line) => normalizeWhitespace(line))
    .filter(Boolean);
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
  let purifiedXml = replacedXml
    .replace(/<hp:endNote[\s\S]*?<\/hp:endNote>/gi, ' ')
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
      /^\[(박스시작|박스끝|문단)\]$/.test(paragraphLines[0]);
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
    q.meta = {
      ...(q.meta || {}),
      answer_key: normalizeWhitespace(String(q?.answer_key || q?.meta?.answer_key || '')),
      allow_objective: q.allow_objective !== false,
      allow_subjective: q.allow_subjective !== false,
      objective_answer_key: normalizeWhitespace(String(q.objective_answer_key || '')),
      subjective_answer: normalizeWhitespace(String(q.subjective_answer || '')),
      objective_generated: q.objective_generated === true,
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
    const line = row.text;
    if (!line) continue;

    if (/모의고사|학력평가|전국연합/.test(line)) {
      stats.mockMarkers += 1;
    }
    if (/대학수학능력시험|수능/.test(line)) {
      stats.csatMarkers += 1;
    }

    const start = parseQuestionStart(line);
    if (start) {
      splitAfterScoreAnnotation = false;
      // score_only ("[3.00점]") 라인이 이미 stem이 있는 현재 문항 바로 뒤에 나오면
      // 새 문항이 아니라 현재 문항의 배점 메타데이터로 취급한다.
      // 번호 없는 문서에서 stem → [배점] → 선택지 순서를 올바르게 처리하기 위함.
      if (
        start.style === 'score_only' &&
        current &&
        current.stemLines.length > 0 &&
        current.choices.length === 0
      ) {
        current.score_point = start.scorePoint ?? current.score_point;
        current.sourcePatterns.push('score_annotation');
        const lastNonStructuralStem = (() => {
          for (let si = current.stemLines.length - 1; si >= 0; si--) {
            const c = normalizeWhitespace(current.stemLines[si]);
            if (c && !/^\[(문단|박스시작|박스끝|그림|도형)\]$/.test(c)) return c;
          }
          return '';
        })();
        if (looksLikeQuestionTerminalLine(lastNonStructuralStem)) {
          splitAfterScoreAnnotation = true;
        }
        continue;
      }
      const questionNumber = reserveQuestionNumber(start.number, {
        allowFallback: start.style === 'score_only',
      });
      if (!questionNumber) {
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
      continue;
    }

    if (splitAfterScoreAnnotation && current) {
      const peekCleaned = stripPotentialWatermarkText(
        normalizeWhitespace(
          line.replace(/\[\[PB_EQ_[^\]]+\]\] ?/g, (match) => {
            const token = match.replace(/ $/, '');
            const eq = equationMap.get(token);
            const rendered = normalizeWhitespace(eq?.latex || eq?.raw || '');
            return rendered || '[수식]';
          }),
        ),
      );
      const isStructuralOrEmpty =
        !peekCleaned ||
        /^\[(문단|박스시작|박스끝|그림|도형)\]$/.test(peekCleaned);
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
      const firstLineCandidate = stripPotentialWatermarkText(
        normalizeWhitespace(
          line.replace(/\[\[PB_EQ_[^\]]+\]\] ?/g, (match) => {
            const token = match.replace(/ $/, '');
            const eq = equationMap.get(token);
            const rendered = normalizeWhitespace(eq?.latex || eq?.raw || '');
            return rendered || '[수식]';
          }),
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

    const cleanedLine = stripPotentialWatermarkText(
      normalizeWhitespace(
        line.replace(/\[\[PB_EQ_[^\]]+\]\] ?/g, (match) => {
          const token = match.replace(/ $/, '');
          const eq = equationMap.get(token);
          const rendered = normalizeWhitespace(eq?.latex || eq?.raw || '');
          return rendered || '[수식]';
        }),
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
        if (candidate && !/^\[(문단|박스시작|박스끝|그림|도형)\]$/.test(candidate)) {
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
    if (
      canSplitAfterChoices ||
      canSplitAfterTerminal
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
      current.answer_key = parsedAnswerKey;
      current.sourcePatterns.push('answer_key');
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
    if (isFigureLine(cleanedLine) || /\[(그림|표|도형)\]/.test(cleanedLine)) {
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
  if (/timeout/i.test(msg)) return 'TIMEOUT';
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

function buildQuestionWritePayload({
  question,
  classification,
  academyId,
  documentId,
  extractJobId,
  questionUid = '',
}) {
  const safeQuestionUid = normalizeWhitespace(questionUid);
  return {
    academy_id: academyId,
    document_id: documentId,
    extract_job_id: extractJobId,
    ...(safeQuestionUid ? { question_uid: safeQuestionUid } : {}),
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
        'exam_profile',
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

  const parsed = parseHwpxBuffer(buffer);
  const xmlBuilt = buildQuestionRows({
    academyId: job.academy_id,
    documentId: job.document_id,
    extractJobId: job.id,
    parsed: { sections: parsed.sections },
    threshold: REVIEW_CONFIDENCE_THRESHOLD,
  });
  let built = xmlBuilt;
  let parseMode = 'xml';
  let previewBuilt = null;
  let previewStemPatched = 0;
  let previewChoicePatched = 0;
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

  let geminiTried = false;
  let geminiUsed = false;
  let geminiError = '';
  let geminiCandidateQuestions = 0;
  let geminiRejectedReason = '';
  let geminiEnrichedQuestions = 0;
  let geminiStemPatched = 0;
  let geminiChoicePatched = 0;
  if (shouldAttemptGemini(parsed, built)) {
    geminiTried = true;
    try {
      const sourceText = buildGeminiSourceText(parsed);
      const examProfileHint = doc.exam_profile || built.stats.examProfile || '';
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

  const dualModeResult = await enrichQuestionsWithDualMode({
    questions: built.questions || [],
    examProfileHint: doc.exam_profile || built?.stats?.examProfile || '',
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
    .select('id,question_number,question_uid,source_order')
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

    if (AUTO_QUEUE_FIGURE_JOBS && questions.length > 0) {
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
        const figureJobRows = (insertedQuestions || [])
          .filter(
            (row) => Array.isArray(row.figure_refs) && row.figure_refs.length > 0,
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
    totalQuestions: questions.length,
    lowConfidenceCount: stats.lowConfidenceCount,
    circledChoices: stats.circledChoices,
    viewBlocks: stats.viewBlocks,
    figureLines: stats.figureLines,
    equationRefs: stats.equationRefs,
    sourceLineCount: stats.sourceLineCount,
    segmentedLineCount: stats.segmentedLineCount,
    answerHintCount: Number(stats.answerHintCount || 0),
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
      parser: 'pb_extract_worker_v1',
      processed_at: nowIso,
      parse_mode: parseMode,
      file_name: doc.source_filename || '',
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

  const { error: docUpdateErr } = await supa
    .from('pb_documents')
    .update({
      status: docStatus,
      exam_profile: stats.examProfile,
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

  while (true) {
    try {
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
};
