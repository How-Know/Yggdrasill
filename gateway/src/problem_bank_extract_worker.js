import 'dotenv/config';
import AdmZip from 'adm-zip';
import { XMLParser } from 'fast-xml-parser';
import hePkg from 'he';
import { createClient } from '@supabase/supabase-js';

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
  if (!raw) return '[수식]';
  if (/^[1-5]$/.test(raw)) {
    return String.fromCharCode(0x2460 + Number.parseInt(raw, 10) - 1); // ①
  }
  return raw;
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
    .replace(/`+/g, '')
    .replace(/\{rm\{([^}]*)\}\}it/gi, '\\mathrm{$1}')
    .replace(/rm\{([^}]*)\}it/gi, '\\mathrm{$1}')
    .replace(/\bleft\b/gi, '\\left')
    .replace(/\bright\b/gi, '\\right')
    .replace(/\btimes\b/gi, '\\times ')
    .replace(/\bdiv\b/gi, '\\div ')
    .replace(/\bover\b/gi, '\\over ')
    .replace(/\ble\b/gi, '\\le ')
    .replace(/\bge\b/gi, '\\ge ')
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

function transformXmlToLines(xmlText, sectionIndex) {
  const { replacedXml, equations } = collectEquationCandidates(
    xmlText,
    sectionIndex,
  );
  // 문단 내부/외부에 섞여 있는 미주/각주 본문은 문제 텍스트 추출에서 제외한다.
  const purifiedXml = replacedXml
    .replace(/<hp:endNote[\s\S]*?<\/hp:endNote>/gi, ' ')
    .replace(/<hp:footNote[\s\S]*?<\/hp:footNote>/gi, ' ')
    .replace(/<hp:note[\s\S]*?<\/hp:note>/gi, ' ');
  const lines = [];
  let lineIndex = 0;
  let page = 1;
  const paragraphRegex = /<hp:p\b([^>]*)>([\s\S]*?)<\/hp:p>/gi;
  let m = null;
  while ((m = paragraphRegex.exec(purifiedXml)) !== null) {
    const attrs = String(m[1] || '');
    const body = String(m[2] || '');
    if (/pageBreak\s*=\s*["']1["']/.test(attrs) && lineIndex > 0) {
      page += 1;
    }

    let s = body;
    // 본문 번호를 autoNum으로 표현한 경우 숫자를 살려둔다.
    s = s.replace(
      /<hp:autoNum[^>]*num="(\d+)"[^>]*>[\s\S]*?<\/hp:autoNum>/gi,
      ' $1 ',
    );
    // 표 내부 텍스트를 살리기 위해 hp:tbl 본문은 지우지 않는다.
    s = s.replace(/<hp:pic[\s\S]*?<\/hp:pic>/gi, ' [그림] ');
    s = s.replace(/<hp:shape[\s\S]*?<\/hp:shape>/gi, ' [도형] ');
    s = s.replace(/<br\s*\/?>/gi, '\n');
    s = s.replace(/<hp:lineBreak\s*\/?>/gi, '\n');
    s = s.replace(
      /<\/(hp:run|hp:r|hp:span|hp:ctrl|hp:subList|hp:tc|hp:tr|tr|li)>/gi,
      ' ',
    );
    s = s.replace(/<[^>]+>/g, ' ');
    s = htmlDecode(s);
    s = normalizeWhitespace(s);
    if (!s) continue;

    const paragraphLines = s
      .split('\n')
      .map((line) => normalizeWhitespace(line))
      .filter((line) => line.length > 0);
    for (const text of paragraphLines) {
      lines.push({
        section: sectionIndex,
        index: lineIndex,
        page,
        text,
      });
      lineIndex += 1;
    }
  }

  return { lines, equations };
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
  return textNodes.filter((line) =>
    /(\d{1,3})\s*\[\s*(\d+(?:\.\d+)?)\s*점\s*\]/.test(line),
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
  for (const q of xmlBuilt.questions || []) {
    const pq = previewMap.get(String(q.question_number || ''));
    if (!pq) continue;
    const currentStem = normalizeWhitespace(q.stem || '');
    const previewStem = normalizeWhitespace(pq.stem || '');
    const currentHasPrompt = /(다음|옳은|설명|구하|계산|만족)/.test(currentStem);
    const previewHasPrompt = /(다음|옳은|설명|구하|계산|만족)/.test(previewStem);
    if (
      previewStem.length >= 6 &&
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
  for (const q of baseBuilt.questions || []) {
    const g = geminiMap.get(String(q.question_number || ''));
    if (!g) continue;

    let touched = false;
    const baseStem = normalizeWhitespace(q.stem || '');
    const geminiStem = normalizeWhitespace(g.stem || '');
    const geminiStemSanitized = stripEquationPlaceholders(geminiStem);
    const geminiStemHasPlaceholder = placeholderTokenCount(geminiStem) > 0;
    const baseHasPrompt = /(다음|옳은|설명|구하|계산|만족)/.test(baseStem);
    const geminiHasPrompt = /(다음|옳은|설명|구하|계산|만족)/.test(
      geminiStemSanitized,
    );
    if (
      !geminiStemHasPlaceholder &&
      geminiStemSanitized.length >= 6 &&
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

function buildQuestionRows({ academyId, documentId, extractJobId, parsed, threshold }) {
  const allLines = [];
  let sourceLineCount = 0;
  let segmentedLineCount = 0;
  const equationMap = new Map();

  for (const sec of parsed.sections) {
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
        });
      }
    }
  }

  const questions = [];
  let current = null;
  const stats = {
    circledChoices: 0,
    viewBlocks: 0,
    figureLines: 0,
    mockMarkers: 0,
    csatMarkers: 0,
    equationRefs: 0,
    questionCount: 0,
  };

  const flushCurrent = () => {
    if (!current) return;
    current.stem = normalizeWhitespace(current.stemLines.join('\n'));
    current.question_type = guessQuestionType(current);
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
      flushCurrent();
      current = {
        academy_id: academyId,
        document_id: documentId,
        extract_job_id: extractJobId,
        source_page: Number(row.page || row.section + 1),
        source_order: questions.length,
        question_number: start.number,
        question_type: '미분류',
        stem: '',
        stemLines: start.rest ? [start.rest] : [],
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
        sourcePatterns: [start.style],
        score_point: start.scorePoint ?? null,
        answer_key: '',
        is_checked: false,
        reviewed_by: null,
        reviewed_at: null,
        reviewer_notes: '',
        meta: {},
      };
      continue;
    }

    if (!current && questions.length === 0) {
      const firstLineCandidate = stripPotentialWatermarkText(
        normalizeWhitespace(
          line.replace(/\[\[PB_EQ_[^\]]+\]\]/g, (token) => {
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
        current = {
          academy_id: academyId,
          document_id: documentId,
          extract_job_id: extractJobId,
          source_page: Number(row.page || row.section + 1),
          source_order: questions.length,
          question_number: '1',
          question_type: '미분류',
          stem: '',
          stemLines: [firstLineCandidate],
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
          sourcePatterns: ['implicit_first'],
          score_point: null,
          answer_key: '',
          is_checked: false,
          reviewed_by: null,
          reviewed_at: null,
          reviewer_notes: '',
          meta: {},
        };
        continue;
      }
    }

    if (!current) continue;
    current.source_anchors.line_end = row.lineIndex;

    const eqTokens = line.match(/\[\[PB_EQ_[^\]]+\]\]/g) || [];
    if (eqTokens.length > 0) {
      stats.equationRefs += eqTokens.length;
      for (const token of eqTokens) {
        const eq = equationMap.get(token);
        if (!eq) continue;
        current.equations.push(eq);
      }
    }

    const cleanedLine = stripPotentialWatermarkText(
      normalizeWhitespace(
        line.replace(/\[\[PB_EQ_[^\]]+\]\]/g, (token) => {
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
    if (
      isLikelyKoreanPersonName(cleanedLine) &&
      current.stemLines.some((lineText) => /<\s*보\s*기>/.test(String(lineText || '')))
    ) {
      current.sourcePatterns.push('watermark_line');
      continue;
    }

    const answerKey = parseAnswerLine(cleanedLine);
    if (answerKey) {
      current.answer_key = answerKey;
      current.sourcePatterns.push('answer_key');
      continue;
    }

    if (isSourceMarkerLine(cleanedLine)) {
      current.sourcePatterns.push('source_marker');
      continue;
    }

    const inlineChoices = parseInlineCircledChoices(cleanedLine);
    if (inlineChoices.length >= 2) {
      const leadStem = leadingStemBeforeInlineChoices(cleanedLine);
      if (leadStem) {
        current.stemLines.push(leadStem);
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

    const choice = parseChoiceLine(cleanedLine);
    if (choice) {
      if (
        choice.style === 'consonant' &&
        (current.flags.includes('view_block') || cleanedLine.length >= 20)
      ) {
        // <보기>의 ㄱ/ㄴ/ㄷ 항목은 선택지보다 본문으로 본다.
        current.stemLines.push(cleanedLine);
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

    current.stemLines.push(cleanedLine);
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
    const transformed = transformXmlToLines(rawXml, i);
    sections.push({
      section: i,
      path: entry.entryName,
      lines: transformed.lines,
      equations: transformed.equations,
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

async function markJobFailed({ jobId, documentId, error }) {
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
  if (documentId) {
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
      'id,academy_id,source_storage_bucket,source_storage_path,source_filename,exam_profile,meta',
    )
    .eq('id', job.document_id)
    .eq('academy_id', job.academy_id)
    .maybeSingle();

  if (docErr || !doc) {
    throw new Error(docErr?.message || 'document_not_found');
  }

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

  const { questions, stats } = built;
  const nowIso = new Date().toISOString();

  await supa.from('pb_questions').delete().eq('document_id', job.document_id);

  if (questions.length > 0) {
    const chunkSize = 300;
    for (let i = 0; i < questions.length; i += chunkSize) {
      const chunk = questions.slice(i, i + chunkSize).map((q) => ({
        academy_id: q.academy_id,
        document_id: q.document_id,
        extract_job_id: q.extract_job_id,
        source_page: q.source_page,
        source_order: q.source_order,
        question_number: q.question_number,
        question_type: q.question_type,
        stem: q.stem,
        choices: q.choices,
        figure_refs: q.figure_refs,
        equations: q.equations,
        source_anchors: q.source_anchors,
        confidence: q.confidence,
        flags: q.flags,
        is_checked: q.is_checked,
        reviewed_by: q.reviewed_by,
        reviewed_at: q.reviewed_at,
        reviewer_notes: q.reviewer_notes,
        meta: q.meta,
      }));
      const { error: insertErr } = await supa.from('pb_questions').insert(chunk);
      if (insertErr) {
        throw new Error(`question_insert_failed:${insertErr.message}`);
      }
    }
  }

  const reviewRequired = stats.lowConfidenceCount > 0;
  const jobStatus = reviewRequired ? 'review_required' : 'completed';
  const docStatus = reviewRequired ? 'review_required' : 'ready';

  const resultSummary = {
    totalQuestions: questions.length,
    lowConfidenceCount: stats.lowConfidenceCount,
    circledChoices: stats.circledChoices,
    viewBlocks: stats.viewBlocks,
    figureLines: stats.figureLines,
    equationRefs: stats.equationRefs,
    sourceLineCount: stats.sourceLineCount,
    segmentedLineCount: stats.segmentedLineCount,
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
    examProfileDetected: stats.examProfile,
    reviewThreshold: REVIEW_CONFIDENCE_THRESHOLD,
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
    questionCount: questions.length,
    lowConfidenceCount: stats.lowConfidenceCount,
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
        await markJobFailed({
          jobId: locked.id,
          documentId: locked.document_id,
          error: new Error('max_retries_exceeded'),
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
      console.error(
        '[pb-extract-worker] fail',
        JSON.stringify({
          jobId: locked?.id || row.id,
          docId: locked?.document_id || row.document_id,
          errorCode: toErrorCode(err),
          message: compact(err?.message || err),
        }),
      );
      await markJobFailed({
        jobId: locked?.id || row.id,
        documentId: locked?.document_id || row.document_id,
        error: err,
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

main().catch((err) => {
  console.error('[pb-extract-worker] fatal', compact(err?.message || err));
  process.exit(1);
});
