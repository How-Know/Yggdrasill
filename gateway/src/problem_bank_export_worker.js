import 'dotenv/config';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createClient } from '@supabase/supabase-js';
import fontkit from '@pdf-lib/fontkit';
import { PDFDocument, StandardFonts, rgb } from 'pdf-lib';
import sharp from 'sharp';
import { mathjax } from 'mathjax-full/js/mathjax.js';
import { TeX } from 'mathjax-full/js/input/tex.js';
import { AllPackages } from 'mathjax-full/js/input/tex/AllPackages.js';
import { SVG } from 'mathjax-full/js/output/svg.js';
import { liteAdaptor } from 'mathjax-full/js/adaptors/liteAdaptor.js';
import { RegisterHTMLHandler } from 'mathjax-full/js/handlers/html.js';
import { renderPdfWithHtmlEngine } from './problem_bank/render_engine/index.js';
import { resolveFigureLayout, figureLayoutToWidthPt } from './problem_bank/render_engine/utils/figure_layout.js';

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const WORKER_INTERVAL_MS = Number.parseInt(
  process.env.PB_EXPORT_WORKER_INTERVAL_MS || '4000',
  10,
);
const BATCH_SIZE = Math.max(
  1,
  Number.parseInt(process.env.PB_EXPORT_WORKER_BATCH_SIZE || '2', 10),
);
const PROCESS_ONCE =
  process.argv.includes('--once') || process.env.PB_EXPORT_WORKER_ONCE === '1';
const WORKER_NAME =
  process.env.PB_EXPORT_WORKER_NAME || `pb-export-worker-${process.pid}`;
const FONT_PATH_REGULAR =
  process.env.PB_PDF_FONT_PATH || 'C:\\Windows\\Fonts\\malgun.ttf';
const FONT_PATH_BOLD =
  process.env.PB_PDF_FONT_BOLD_PATH || 'C:\\Windows\\Fonts\\malgunbd.ttf';
const FONT_PATH_HCR_REGULAR = process.env.PB_PDF_FONT_HCRBATANG_PATH || '';
const FONT_PATH_HCR_BOLD = process.env.PB_PDF_FONT_HCRBATANG_BOLD_PATH || '';
const FONT_PATH_KAKAO_SMALL_REGULAR =
  process.env.PB_PDF_FONT_KAKAO_SMALL_REGULAR_PATH || '';
const FONT_PATH_KAKAO_SMALL_BOLD =
  process.env.PB_PDF_FONT_KAKAO_SMALL_BOLD_PATH || '';
const FONT_PATH_NANUM_REGULAR = process.env.PB_PDF_FONT_NANUM_GOTHIC_PATH || '';
const FONT_PATH_NANUM_BOLD =
  process.env.PB_PDF_FONT_NANUM_GOTHIC_BOLD_PATH || '';
const FONT_PATH_KOPUB_BATANG_LIGHT =
  process.env.PB_PDF_FONT_KOPUB_BATANG_LIGHT_PATH || '';
const FONT_PATH_QNUM =
  process.env.PB_PDF_FONT_QNUM_PATH || '';
const FONT_PATH_SUBJECT =
  process.env.PB_PDF_FONT_SUBJECT_PATH || '';
const RENDER_CONFIG_VERSION = 'pb_render_v32g_anchor_pair_ref';
const FIGURE_REGEN_COOLDOWN_MIN = Math.max(
  2,
  Number.parseInt(process.env.PB_EXPORT_REGEN_COOLDOWN_MIN || '12', 10),
);
const FIGURE_MAX_DPI = Math.max(
  300,
  Number.parseInt(process.env.PB_EXPORT_FIGURE_MAX_DPI || '1200', 10),
);
const IS_DIRECT_RUN =
  typeof process.argv[1] === 'string' &&
  process.argv[1].length > 0 &&
  import.meta.url === pathToFileURL(process.argv[1]).href;

if ((!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) && IS_DIRECT_RUN) {
  console.error(
    '[pb-export-worker] Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY',
  );
  process.exit(1);
}

const supa =
  SUPABASE_URL && SUPABASE_SERVICE_ROLE_KEY
    ? createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
        auth: { persistSession: false, autoRefreshToken: false },
      })
    : null;

const PAPER_SIZE = {
  A4: { width: 595, height: 842 },
  B4: { width: 729, height: 1032 },
  '8\uC808': { width: 774, height: 1118 },
};

const PROFILE_LAYOUT = {
  naesin: {
    title: '\uB0B4\uC2E0\uD615 \uC2DC\uD5D8\uC9C0',
    margin: 46,
    headerHeight: 38,
    stemSize: 11.3,
    choiceSize: 10.7,
    lineHeight: 15.4,
    questionGap: 12,
    choiceIndent: 20,
  },
  csat: {
    title: '\uC218\uB2A5\uD615 \uC2DC\uD5D8\uC9C0',
    margin: 44,
    headerHeight: 36,
    stemSize: 11.0,
    choiceSize: 10.4,
    lineHeight: 15.0,
    questionGap: 10,
    choiceIndent: 18,
  },
  mock: {
    title: '\uBAA8\uC758\uACE0\uC0AC\uD615 \uC2DC\uD5D8\uC9C0',
    margin: 44,
    headerHeight: 36,
    stemSize: 11.0,
    choiceSize: 10.4,
    lineHeight: 15.0,
    questionGap: 10,
    choiceIndent: 18,
  },
};

const STRUCTURAL_MARKER_REGEX = /\[(\uBB38\uB2E8|\uBC15\uC2A4\uC2DC\uC791|\uBC15\uC2A4\uB05D)\]/g;
const FIGURE_MARKER_RE_PDF = /\[(?:\uADF8\uB9BC|\uB3C4\uD615|\uB3C4\uD45C|\uD45C)\]/g;
const MODULE_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(MODULE_DIR, '..', '..');

const mathAdaptor = liteAdaptor();
RegisterHTMLHandler(mathAdaptor);
const mathTex = new TeX({
  packages: AllPackages,
});
const mathSvg = new SVG({
  fontCache: 'none',
});
const mathDocument = mathjax.document('', {
  InputJax: mathTex,
  OutputJax: mathSvg,
});

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function normalizeFontFamily(value) {
  const safe = normalizeWhitespace(value || '');
  if (!safe || safe === '\uAE30\uBCF8') return 'KoPubWorldBatangPro';
  return safe;
}

function repoAssetPath(...segments) {
  return path.resolve(REPO_ROOT, ...segments);
}

function pickExistingPath(candidates) {
  for (const candidate of candidates) {
    const safe = String(candidate || '').trim();
    if (!safe) continue;
    if (fs.existsSync(safe)) return safe;
  }
  return '';
}

function resolveSubjectFontPath() {
  return pickExistingPath([
    FONT_PATH_SUBJECT,
    'C:\\Users\\harry\\Downloads\\apple\uC0B0\uB3CC\uACE0\uB515\uB124\uC6242\\apple\uC0B0\uB3CC\uACE0\uB515\uB124\uC6242\\AppleSDGothicNeoB.ttf',
    'C:\\Users\\harry\\Downloads\\apple\uC0B0\uB3CC\uACE0\uB515\uB124\uC6242\\apple\uC0B0\uB3CC\uACE0\uB515\uB124\uC6242\\AppleSDGothicNeoH.ttf',
    'C:\\Users\\harry\\Downloads\\apple\uC0B0\uB3CC\uACE0\uB515\uB124\uC6242\\apple\uC0B0\uB3CC\uACE0\uB515\uB124\uC6242\\AppleSDGothicNeoEB.ttf',
    'C:\\Users\\harry\\Downloads\\apple\uC0B0\uB3CC\uACE0\uB515\uB124\uC6242\\apple\uC0B0\uB3CC\uACE0\uB515\uB124\uC6242\\AppleSDGothicNeoL.ttf',
    FONT_PATH_BOLD,
    FONT_PATH_REGULAR,
  ]);
}

function resolveRequestedFontPaths(requestedFamilyRaw) {
  const requestedFamily = normalizeFontFamily(requestedFamilyRaw);
  const key = requestedFamily.toLowerCase();
  const repoHcrRegular = repoAssetPath(
    'apps',
    'yggdrasill',
    'assets',
    'fonts',
    'hancom',
    'HCRBatang.ttf',
  );
  const repoHcrBold = repoAssetPath(
    'apps',
    'yggdrasill',
    'assets',
    'fonts',
    'hancom',
    'HCRBatang-Bold.ttf',
  );
  const repoKakaoSmallRegular = repoAssetPath(
    'apps',
    'yggdrasill',
    'assets',
    'fonts',
    'kakao',
    '\uCE74\uCE74\uC624\uC791\uC740\uAE00\uC528',
    'TTF',
    'KakaoSmallSans-Regular.ttf',
  );
  const repoKakaoSmallBold = repoAssetPath(
    'apps',
    'yggdrasill',
    'assets',
    'fonts',
    'kakao',
    '\uCE74\uCE74\uC624\uC791\uC740\uAE00\uC528',
    'TTF',
    'KakaoSmallSans-Bold.ttf',
  );

  if (key === 'kakaosmallsans') {
    return {
      requestedFamily,
      resolvedFamily: 'KakaoSmallSans',
      regularPath: pickExistingPath([
        FONT_PATH_KAKAO_SMALL_REGULAR,
        repoKakaoSmallRegular,
        FONT_PATH_REGULAR,
      ]),
      boldPath: pickExistingPath([
        FONT_PATH_KAKAO_SMALL_BOLD,
        repoKakaoSmallBold,
        FONT_PATH_BOLD,
      ]),
    };
  }
  if (key === 'nanumgothic') {
    return {
      requestedFamily,
      resolvedFamily: 'NanumGothic',
      regularPath: pickExistingPath([
        FONT_PATH_NANUM_REGULAR,
        'C:\\Windows\\Fonts\\NanumGothic.ttf',
        FONT_PATH_REGULAR,
      ]),
      boldPath: pickExistingPath([
        FONT_PATH_NANUM_BOLD,
        'C:\\Windows\\Fonts\\NanumGothicBold.ttf',
        FONT_PATH_BOLD,
      ]),
    };
  }
  if (key === 'kopubworldbatangpro') {
    const repoKopubLight = repoAssetPath(
      'apps', 'yggdrasill', 'assets', 'fonts', 'kopub',
      'KoPubWorldBatangProLight.otf',
    );
    return {
      requestedFamily,
      resolvedFamily: 'KoPubWorldBatangPro',
      regularPath: pickExistingPath([
        FONT_PATH_KOPUB_BATANG_LIGHT,
        repoKopubLight,
        FONT_PATH_REGULAR,
      ]),
      boldPath: pickExistingPath([
        FONT_PATH_KOPUB_BATANG_LIGHT,
        repoKopubLight,
        FONT_PATH_BOLD,
      ]),
    };
  }
  return {
    requestedFamily,
    resolvedFamily: 'HCRBatang',
    regularPath: pickExistingPath([
      FONT_PATH_HCR_REGULAR,
      repoHcrRegular,
      FONT_PATH_REGULAR,
    ]),
    boldPath: pickExistingPath([
      FONT_PATH_HCR_BOLD,
      repoHcrBold,
      FONT_PATH_BOLD,
    ]),
  };
}

function compact(value, max = 220) {
  const s = String(value ?? '').replace(/\s+/g, ' ').trim();
  if (s.length <= max) return s;
  return `${s.slice(0, max)}...`;
}

function sanitizeText(value) {
  const raw = stripStructuralMarkers(String(value ?? '').replace(/\r/g, ''));
  if (!raw) return '';
  return normalizeLatexToReadable(raw);
}

function sanitizeTextPreserveLineBreaks(value) {
  const raw = String(value ?? '').replace(/\r/g, '');
  if (!raw.trim()) return '';
  const lines = raw.split('\n').map((line) => sanitizeText(line));
  const compacted = [];
  let prevEmpty = true;
  for (const line of lines) {
    const safe = String(line || '').trim();
    if (!safe) {
      if (compacted.length === 0) continue;
      if (prevEmpty) continue;
      compacted.push('');
      prevEmpty = true;
      continue;
    }
    compacted.push(safe);
    prevEmpty = false;
  }
  while (compacted.length > 0 && compacted[compacted.length - 1] === '') {
    compacted.pop();
  }
  return compacted.join('\n');
}

function normalizeWhitespace(value) {
  return String(value ?? '').replace(/\s+/g, ' ').trim();
}

function stripStructuralMarkers(value) {
  return String(value || '')
    .replace(STRUCTURAL_MARKER_REGEX, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function escapeRegExp(value) {
  return String(value || '').replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function normalizeLatexToReadable(value) {
  let out = String(value || '');
  if (!out) return '';
  out = out
    .replace(/\$\$([\s\S]*?)\$\$/g, '$1')
    .replace(/\\\(([\s\S]*?)\\\)/g, '$1');

  for (let i = 0; i < 4; i += 1) {
    const next = out.replace(
      /\\(?:dfrac|tfrac|frac)\s*\{([^{}]+)\}\s*\{([^{}]+)\}/g,
      '($1)/($2)',
    );
    if (next === out) break;
    out = next;
  }

  out = out
    .replace(/\{([^{}]+)\}\s*\\over\s*\{([^{}]+)\}/g, '($1)/($2)')
    .replace(/\\sqrt\s*\{([^{}]+)\}/g, '\u221A($1)')
    .replace(/\\times\b/g, '\u00D7')
    .replace(/\\cdot\b/g, '\u00B7')
    .replace(/\\div\b/g, '\u00F7')
    .replace(/\\leq?\b/g, '\u2264')
    .replace(/\\geq?\b/g, '\u2265')
    .replace(/\\neq\b/g, '\u2260')
    .replace(/\\pm\b/g, '\u00B1')
    .replace(/\\mp\b/g, '\u2213')
    .replace(/\\infty\b/g, '\u221E')
    .replace(/\\pi\b/g, '\u03C0')
    .replace(/\\theta\b/g, '\u03B8')
    .replace(/\\alpha\b/g, '\u03B1')
    .replace(/\\beta\b/g, '\u03B2')
    .replace(/\\gamma\b/g, '\u03B3')
    .replace(/\\left\b/g, '')
    .replace(/\\right\b/g, '')
    .replace(/\\mathrm\s*\{([^{}]+)\}/g, '$1')
    .replace(/\\text\s*\{([^{}]+)\}/g, '$1')
    .replace(/([A-Za-z0-9\)\]])\s*\^\s*\{([^{}]+)\}/g, '$1^$2')
    .replace(/([A-Za-z0-9\)\]])\s*_\s*\{([^{}]+)\}/g, '$1_$2')
    .replace(/\^([A-Za-z0-9])/g, '^$1')
    .replace(/_([A-Za-z0-9])/g, '_$1')
    .replace(/[{}]/g, '')
    .replace(/\\[a-zA-Z]+/g, ' ')
    .replace(/\\+/g, '')
    .replace(/`+/g, '')
    .replace(/\s+/g, ' ')
    .trim();
  return out;
}

function rawText(value) {
  return stripStructuralMarkers(String(value ?? '').replace(/\r/g, ''));
}

function normalizeMathLatex(value) {
  let out = String(value || '').trim();
  if (!out) return '';
  out = out
    .replace(/^\$\$/, '')
    .replace(/\$\$$/, '')
    .replace(/^\\\(/, '')
    .replace(/\\\)$/, '')
    .replace(/`+/g, '')
    .replace(/\u00D7/g, '\\times ')
    .replace(/\u00F7/g, '\\div ')
    .replace(/\u00B7/g, '\\cdot ')
    .replace(/\u2212/g, '-')
    .replace(/\u2264/g, '\\le ')
    .replace(/\u2265/g, '\\ge ')
    .replace(/\u2260/g, '\\ne ')
    .replace(/\u03C0/g, '\\pi ')
    .replace(/\s+/g, ' ')
    .trim();
  const simpleFraction = out.match(/^([+-]?\d+)\s*\/\s*([+-]?\d+)$/);
  if (simpleFraction) {
    out = `\\frac{${simpleFraction[1]}}{${simpleFraction[2]}}`;
  }
  return out;
}

function unwrapLatexTextForNumericCheck(value) {
  const src = normalizeMathLatex(value);
  if (!src) return '';
  return src
    .replace(/\\(?:mathrm|text)\s*\{([^{}]*)\}/g, '$1')
    .replace(/[{}]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
}

function isSimpleNumericMathLatex(value) {
  const plain = unwrapLatexTextForNumericCheck(value);
  if (!plain) return false;
  return /^[+-]?\d+(?:[.,]\d+)?$/.test(plain);
}

function isHangulSyllableOrJamo(ch) {
  return /[\uAC00-\uD7A3\u3131-\u314E\u314F-\u3163]/.test(String(ch || ''));
}

function isPunctuationLikeMathText(value) {
  const plain = unwrapLatexTextForNumericCheck(value);
  if (!plain) return true;
  return /^[\s\.,;:!?"'`~|\\/()\[\]{}]+$/.test(plain);
}

function isFractionLikeLatex(value) {
  const src = normalizeMathLatex(value);
  if (!src) return false;
  if (/\\(?:frac|dfrac|tfrac)\b/.test(src)) return true;
  if (/\\over\b/.test(src)) return true;
  if (/[A-Za-z0-9)\]}]\s*\/\s*[A-Za-z0-9({\[]/.test(src)) return true;
  return false;
}

function hasTwoDimensionalMathFeature(value) {
  const src = normalizeMathLatex(value);
  if (!src) return false;
  if (isFractionLikeLatex(src)) return true;
  if (/[\^_]/.test(src)) return true;
  if (
    /\\(?:sqrt|sum|int|prod|lim|overline|underline|vec|hat|bar|dot|ddot|binom|begin|end|matrix)/.test(
      src,
    )
  ) {
    return true;
  }
  const strippedSimple = src.replace(
    /\\(?:times|cdot|div|le|ge|ne|left|right|mathrm|text)\b/g,
    '',
  );
  return /\\[a-zA-Z]+/.test(strippedSimple);
}

function hasRenderableMathFeature(value) {
  const src = normalizeMathLatex(value);
  if (!src) return false;
  if (isPunctuationLikeMathText(src)) return false;
  if (/[A-Za-z0-9]/.test(src)) return true;
  if (/[=<>+\-*/\u00D7\u00F7\u00B7\u00B1^_]/.test(src)) return true;
  if (/\\[a-zA-Z]+/.test(src)) return true;
  return isFractionLikeLatex(src);
}

function balanceCurlyBraces(value) {
  const src = String(value || '');
  if (!src) return '';
  const out = [];
  const stack = [];
  for (let i = 0; i < src.length; i += 1) {
    const ch = src[i];
    if (ch === '{') {
      stack.push(out.length);
      out.push(ch);
      continue;
    }
    if (ch === '}') {
      if (stack.length > 0) {
        stack.pop();
        out.push(ch);
      }
      continue;
    }
    out.push(ch);
  }
  for (const idx of stack) {
    out[idx] = '';
  }
  return out.join('');
}

function mathLatexCandidates(value) {
  const candidates = [];
  const seen = new Set();
  const push = (one) => {
    const safe = normalizeMathLatex(one);
    if (!safe) return;
    if (seen.has(safe)) return;
    seen.add(safe);
    candidates.push(safe);
  };
  const base = normalizeMathLatex(value);
  push(base);
  if (base) {
    push(balanceCurlyBraces(base));
    const noLeftRight = base.replace(/\\left\b/g, '').replace(/\\right\b/g, '');
    push(noLeftRight);
    push(balanceCurlyBraces(noLeftRight));
    push(normalizeLatexToReadable(base));
  }
  return candidates;
}

function injectEquationDelimiters(stem, equations = []) {
  let out = rawText(stem);
  if (!out.trim()) return '';
  if (/\\\(|\$\$/.test(out)) return out;
  const shouldInjectEquationCandidate = (value) => {
    const src = normalizeWhitespace(value);
    if (!src) return false;
    const safe = normalizeMathLatex(src);
    if (!safe) return false;
    if (safe.length <= 0) return false;
    return hasRenderableMathFeature(safe);
  };
  const candidates = [];
  const seen = new Set();
  for (const eq of equations || []) {
    const items = [
      normalizeWhitespace(eq?.latex || ''),
      normalizeWhitespace(eq?.raw || ''),
      normalizeLatexToReadable(eq?.latex || ''),
      normalizeLatexToReadable(eq?.raw || ''),
    ];
    for (const item of items) {
      const key = String(item || '').trim();
      if (!key) continue;
      if (!shouldInjectEquationCandidate(key)) continue;
      if (seen.has(key)) continue;
      seen.add(key);
      candidates.push(key);
    }
  }
  candidates.sort((a, b) => b.length - a.length);
  const filtered = [];
  for (const cand of candidates) {
    const duplicatedByLonger = filtered.some((existing) => existing.includes(cand));
    if (!duplicatedByLonger) filtered.push(cand);
  }
  let segments = [{ type: 'text', value: out }];
  for (const cand of filtered) {
    const nextSegments = [];
    for (const seg of segments) {
      if (seg.type !== 'text') {
        nextSegments.push(seg);
        continue;
      }
      const src = String(seg.value || '');
      if (!src.includes(cand)) {
        nextSegments.push(seg);
        continue;
      }
      let cursor = 0;
      while (cursor < src.length) {
        const idx = src.indexOf(cand, cursor);
        if (idx < 0) {
          if (cursor < src.length) {
            nextSegments.push({ type: 'text', value: src.slice(cursor) });
          }
          break;
        }
        if (idx > cursor) {
          nextSegments.push({ type: 'text', value: src.slice(cursor, idx) });
        }
        nextSegments.push({ type: 'math', value: cand });
        cursor = idx + cand.length;
      }
    }
    segments = nextSegments;
  }
  out = segments
    .map((seg) => (seg.type === 'math' ? `\\(${seg.value}\\)` : String(seg.value || '')))
    .join('');
  return out;
}

function splitPlainTextByMathPolicy(text) {
  const src = String(text || '');
  if (!src) return [];
  const pieces = [];
  let run = '';
  let mode = ''; // hangul|other
  const flush = () => {
    if (!run) return;
    const safeRun = String(run || '');
    if (mode === 'other' && hasRenderableMathFeature(safeRun)) {
      pieces.push({
        type: 'math',
        latex: normalizeMathLatex(safeRun),
        display: false,
      });
    } else {
      pieces.push({
        type: 'text',
        text: safeRun,
      });
    }
    run = '';
    mode = '';
  };
  for (let i = 0; i < src.length; i += 1) {
    const ch = src[i];
    if (ch === '\n') {
      flush();
      pieces.push({
        type: 'text',
        text: '\n',
      });
      continue;
    }
    const kind = isHangulSyllableOrJamo(ch) ? 'hangul' : 'other';
    if (!mode) {
      mode = kind;
      run = ch;
      continue;
    }
    if (kind !== mode) {
      flush();
      mode = kind;
      run = ch;
      continue;
    }
    run += ch;
  }
  flush();

  const merged = [];
  for (const one of pieces) {
    const prev = merged.length > 0 ? merged[merged.length - 1] : null;
    if (one.type === 'text' && prev?.type === 'text') {
      prev.text = `${prev.text || ''}${one.text || ''}`;
      continue;
    }
    merged.push(one);
  }
  return merged;
}

function expandTextBlocksByMathPolicy(blocks = []) {
  const out = [];
  for (const b of blocks || []) {
    if (!b || typeof b !== 'object') continue;
    if (b.type !== 'text') {
      out.push(b);
      continue;
    }
    const expanded = splitPlainTextByMathPolicy(b.text || '');
    if (expanded.length === 0) continue;
    out.push(...expanded);
  }
  return out;
}

function splitStemMathBlocks(stem, equations = []) {
  const src = injectEquationDelimiters(stripStructuralMarkers(rawText(stem)), equations);
  const out = [];
  if (!src.trim()) return out;
  const markerRegex = /\\\(([\s\S]*?)\\\)|\$\$([\s\S]*?)\$\$/g;
  let cursor = 0;
  let m = null;
  while ((m = markerRegex.exec(src)) !== null) {
    if (m.index > cursor) {
      out.push({
        type: 'text',
        text: src.slice(cursor, m.index),
      });
    }
    const rawLatex = String(m[1] || m[2] || '');
    const safeLatex = normalizeMathLatex(rawLatex);
    if (safeLatex) {
      const display = Boolean(m[2]);
      if (shouldRenderMathAsImage(safeLatex, { display })) {
        out.push({
          type: 'math',
          latex: safeLatex,
          display,
        });
      } else {
        out.push({
          type: 'text',
          text: normalizeLatexToReadable(rawLatex),
        });
      }
    }
    cursor = m.index + m[0].length;
  }
  if (cursor < src.length) {
    out.push({
      type: 'text',
      text: src.slice(cursor),
    });
  }
  let normalizedBlocks = out;
  if (normalizedBlocks.length === 0) {
    normalizedBlocks = [{ type: 'text', text: src }];
  }
  normalizedBlocks = expandTextBlocksByMathPolicy(normalizedBlocks);
  const hasMath = normalizedBlocks.some((b) => b.type === 'math');
  if (hasMath) return normalizedBlocks;
  const fallback = [];
  const tokenRegex = /[^?-?\s]+/g;
  let cursor2 = 0;
  let tokenMatch = null;
  while ((tokenMatch = tokenRegex.exec(src)) !== null) {
    const tokenStart = tokenMatch.index;
    const tokenEnd = tokenStart + tokenMatch[0].length;
    const token = String(tokenMatch[0] || '');
    const safeToken = normalizeMathLatex(token);
    const punctuationOnly = /^[\.,;:!?()\[\]{}"'`~|\\/]+$/.test(token.trim());
    if (
      !safeToken ||
      punctuationOnly ||
      !looksMathHeavyText(safeToken) ||
      !shouldRenderMathAsImage(safeToken)
    ) {
      continue;
    }
    if (tokenStart > cursor2) {
      fallback.push({
        type: 'text',
        text: src.slice(cursor2, tokenStart),
      });
    }
    fallback.push({
      type: 'math',
      latex: safeToken,
      display: false,
    });
    cursor2 = tokenEnd;
  }
  if (cursor2 < src.length) {
    fallback.push({
      type: 'text',
      text: src.slice(cursor2),
    });
  }
  if (fallback.some((b) => b.type === 'math')) {
    return fallback;
  }
  return normalizedBlocks;
}

function estimateMathBlockHeightPt(fontSize, display = false, latex = '') {
  const safeSize = Math.max(9, Number(fontSize || 11.2));
  if (display) {
    return Math.max(safeSize * 1.95, safeSize + 8);
  }
  if (isFractionLikeLatex(latex)) {
    return Math.max(safeSize * 1.18, safeSize + 4);
  }
  return Math.max(safeSize * 0.86, safeSize - 1.6);
}

function shouldRenderMathAsImage(latex, { display = false } = {}) {
  const src = normalizeMathLatex(latex);
  if (!src) return false;
  if (display) return true;
  return hasRenderableMathFeature(src);
}

function looksMathHeavyText(value) {
  const src = String(value || '').trim();
  if (!src) return false;
  return hasRenderableMathFeature(src);
}

function pickChoiceMathLatex(question, choiceText) {
  const wrapped = injectEquationDelimiters(choiceText, question?.equations || []);
  const inline = wrapped.match(/\\\(([\s\S]*?)\\\)/);
  if (inline && inline[1]) {
    const candidate = normalizeMathLatex(inline[1]);
    if (candidate) return candidate;
  }
  const tokenRegex = /[^?-?\s]+/g;
  const segments = String(choiceText || '').match(tokenRegex) || [];
  const bestToken = segments
    .map((one) => normalizeMathLatex(one))
    .filter((one) => one && looksMathHeavyText(one))
    .sort((a, b) => b.length - a.length)[0];
  if (bestToken) return bestToken;
  const direct = normalizeMathLatex(choiceText);
  if (!direct) return '';
  return hasRenderableMathFeature(direct) ? direct : '';
}

function createMathRenderContext(pdfDoc) {
  return {
    pdfDoc,
    cache: new Map(),
    stats: {
      requested: 0,
      rendered: 0,
      failed: 0,
      cacheHit: 0,
    },
  };
}

function buildMathCacheKey(latex, fontSize, display, maxWidthPt) {
  return [
    display ? 'display' : 'inline',
    Number(fontSize || 0).toFixed(2),
    Math.round(Math.max(1, Number(maxWidthPt || 0))),
    normalizeMathLatex(latex),
  ].join('|');
}

function extractSvgRootFromMathMarkup(markup) {
  const src = String(markup || '').trim();
  if (!src) return '';
  const m = src.match(/<svg[\s\S]*?<\/svg>/i);
  if (m && m[0]) return m[0];
  return src;
}

function parseMathSvgMetrics(svgText) {
  const src = String(svgText || '');
  if (!src) return {};
  const widthEx = Number.parseFloat((src.match(/width="([\-0-9.]+)ex"/i) || [])[1] || '');
  const heightEx = Number.parseFloat((src.match(/height="([\-0-9.]+)ex"/i) || [])[1] || '');
  const verticalAlignEx = Number.parseFloat(
    (src.match(/vertical-align:\s*([\-0-9.]+)ex/i) || [])[1] || '',
  );
  return {
    widthEx: Number.isFinite(widthEx) ? widthEx : null,
    heightEx: Number.isFinite(heightEx) ? heightEx : null,
    verticalAlignEx: Number.isFinite(verticalAlignEx) ? verticalAlignEx : null,
  };
}

async function renderLatexToPngDescriptor(
  latex,
  {
    fontSize = 11.2,
    display = false,
    maxWidthPt = 420,
  } = {},
) {
  const latexCandidates = mathLatexCandidates(latex);
  if (latexCandidates.length === 0) return null;
  const canonicalLatex = normalizeMathLatex(latexCandidates[0] || latex);
  const fractionLike = isFractionLikeLatex(canonicalLatex);
  let svgText = '';
  for (const safeLatex of latexCandidates) {
    try {
      const node = mathDocument.convert(safeLatex, {
        display: display === true,
      });
      svgText = mathAdaptor.outerHTML(node);
      if (svgText) break;
    } catch (_) {
      // try next candidate
    }
  }
  if (!svgText) return null;
  const svgOnly = extractSvgRootFromMathMarkup(svgText);
  if (!svgOnly) return null;
  const svgMetrics = parseMathSvgMetrics(svgOnly);
  let pngBytes = null;
  try {
    const density = Math.max(
      240,
      Math.min(1200, Math.round(Number(fontSize || 11.2) * 34)),
    );
    const rawPng = await sharp(Buffer.from(svgOnly), { density })
      .png({
        compressionLevel: 9,
        adaptiveFiltering: true,
      })
      .toBuffer();
    try {
      const trimmed = await sharp(rawPng)
        .trim()
        .png({
          compressionLevel: 9,
          adaptiveFiltering: true,
        })
        .toBuffer();
      pngBytes = trimmed?.length ? trimmed : rawPng;
    } catch (_) {
      pngBytes = rawPng;
    }
  } catch (_) {
    return null;
  }
  let meta = null;
  try {
    meta = await sharp(pngBytes).metadata();
  } catch (_) {
    meta = null;
  }
  const sourceWidthPx = Math.max(1, Number(meta?.width || 0));
  const sourceHeightPx = Math.max(1, Number(meta?.height || 0));
  if (!Number.isFinite(sourceWidthPx) || !Number.isFinite(sourceHeightPx)) {
    return null;
  }
  const naturalHeightPt = estimateMathBlockHeightPt(
    fontSize,
    display,
    canonicalLatex,
  );
  const naturalWidthPt = (sourceWidthPx / sourceHeightPx) * naturalHeightPt;
  let heightPt = naturalHeightPt;
  let widthPt = naturalWidthPt;
  const widthCap = Math.max(80, Number(maxWidthPt || 0));
  let scaleRatio = 1;
  if (widthPt > widthCap) {
    scaleRatio = widthCap / widthPt;
    widthPt *= scaleRatio;
    heightPt *= scaleRatio;
  }
  const minHeightPt = Math.max(6, Number(fontSize || 11.2) * 0.72);
  const minWidthPt = Math.max(6, Number(fontSize || 11.2) * 0.55);
  const exToPt = Number(fontSize || 11.2) * 0.43;
  const baselineShiftPt = Number.isFinite(svgMetrics?.verticalAlignEx)
    ? svgMetrics.verticalAlignEx * exToPt
    : (fractionLike
      ? -Number(fontSize || 11.2) * 0.2
      : -Number(fontSize || 11.2) * 0.12);
  return {
    pngBytes,
    widthPt: Math.max(minWidthPt, widthPt),
    heightPt: Math.max(minHeightPt, heightPt),
    scaleRatio: Math.max(0, Math.min(1, Number(scaleRatio || 1))),
    naturalWidthPt: Math.max(minWidthPt, naturalWidthPt),
    naturalHeightPt: Math.max(minHeightPt, naturalHeightPt),
    isFraction: fractionLike,
    baselineShiftPt,
  };
}

async function getMathEmbedDescriptor(
  context,
  latex,
  {
    fontSize = 11.2,
    display = false,
    maxWidthPt = 420,
  } = {},
) {
  if (!context?.pdfDoc) return null;
  if (context?.stats) context.stats.requested += 1;
  const key = buildMathCacheKey(latex, fontSize, display, maxWidthPt);
  if (context.cache.has(key)) {
    const cached = context.cache.get(key);
    if (cached && context?.stats) context.stats.cacheHit += 1;
    if (!cached && context?.stats) context.stats.failed += 1;
    return cached;
  }
  const rendered = await renderLatexToPngDescriptor(latex, {
    fontSize,
    display,
    maxWidthPt,
  });
  if (!rendered?.pngBytes) {
    context.cache.set(key, null);
    if (context?.stats) context.stats.failed += 1;
    return null;
  }
  let embed = null;
  try {
    embed = await context.pdfDoc.embedPng(rendered.pngBytes);
  } catch (_) {
    context.cache.set(key, null);
    if (context?.stats) context.stats.failed += 1;
    return null;
  }
  const out = {
    embed,
    widthPt: rendered.widthPt,
    heightPt: rendered.heightPt,
    scaleRatio: rendered.scaleRatio,
    naturalWidthPt: rendered.naturalWidthPt,
    naturalHeightPt: rendered.naturalHeightPt,
    isFraction: rendered.isFraction === true,
    baselineShiftPt: Number(rendered.baselineShiftPt || 0),
  };
  context.cache.set(key, out);
  if (context?.stats) context.stats.rendered += 1;
  return out;
}

function estimateStemMathBlocksHeight(question, fonts, layout, textWidth) {
  const blocks = splitStemMathBlocks(question?.stem || '', question?.equations || []);
  const maxWidth = Math.max(24, Number(textWidth || 0));
  let total = 0;
  let lineWidth = 0;
  let lineHeight = layout.lineHeight;
  let lineUsed = false;
  const flushLine = (force = false) => {
    if (!force && !lineUsed) return;
    total += Math.max(layout.lineHeight, lineHeight);
    lineWidth = 0;
    lineHeight = layout.lineHeight;
    lineUsed = false;
  };
  for (const block of blocks) {
    if (block.type === 'text') {
      const plain = sanitizeTextPreserveLineBreaks(block.text || '');
      if (!plain) continue;
      const parts = plain.split('\n');
      for (let i = 0; i < parts.length; i += 1) {
        const row = parts[i] || '';
        for (const ch of row) {
          const w = fonts.regular.widthOfTextAtSize(ch, layout.stemSize);
          if (lineUsed && lineWidth + w > maxWidth) {
            flushLine();
          }
          lineWidth += w;
          lineUsed = true;
        }
        if (i < parts.length - 1) {
          flushLine(true);
        }
      }
      continue;
    }
    if (block.type === 'math') {
      const fractionLike = isFractionLikeLatex(block.latex || '');
      const inlinePad = fractionLike
        ? Math.max(3, Math.round(layout.stemSize * 0.34))
        : 1;
      if (!shouldRenderMathAsImage(block.latex, { display: block.display })) {
        const fallback = normalizeLatexToReadable(block.latex || '');
        const lines = wrapTextByWidth(
          fallback,
          fonts.regular,
          layout.stemSize,
          maxWidth,
        );
        total += lines.length * layout.lineHeight;
        continue;
      }
      if (block.display) {
        flushLine();
        total += estimateMathBlockHeightPt(layout.stemSize, true) + 6;
        continue;
      }
      const estWidth = Math.min(
        maxWidth,
        Math.max(
          layout.stemSize * 1.6,
          normalizeMathLatex(block.latex || '').replace(/\s+/g, '').length *
            layout.stemSize * 0.56,
        ),
      );
      const estHeight =
        estimateMathBlockHeightPt(layout.stemSize, false, block.latex || '') +
        inlinePad;
      if (lineUsed && lineWidth + estWidth > maxWidth) {
        flushLine();
      }
      lineWidth += estWidth + 2;
      lineHeight = Math.max(lineHeight, estHeight);
      lineUsed = true;
    }
  }
  flushLine();
  return total;
}

async function drawStemBlocks({
  page,
  question,
  fonts,
  layout,
  textStartX,
  textWidth,
  y,
  mathContext,
  figureEmbeds = [],
  figureLayout = null,
}) {
  let curY = y;
  let cursorX = textStartX;
  let lineHeight = layout.lineHeight;
  let lineUsed = false;
  let figureMarkerIndex = 0;
  const maxX = textStartX + textWidth;

  const groupMap = new Map();
  if (figureLayout?.groups) {
    for (const group of figureLayout.groups) {
      if (group.type !== 'horizontal') continue;
      const memberIndices = [];
      for (const memberKey of group.members) {
        const idx = figureEmbeds.findIndex((e) => e?.assetKey === memberKey);
        if (idx >= 0) memberIndices.push(idx);
      }
      if (memberIndices.length >= 2) {
        for (const idx of memberIndices) {
          groupMap.set(idx, { indices: memberIndices, gap: group.gap ?? 0.5 });
        }
      }
    }
  }

  const flushLine = (force = false) => {
    if (!force && !lineUsed) return;
    curY -= Math.max(layout.lineHeight, lineHeight);
    cursorX = textStartX;
    lineHeight = layout.lineHeight;
    lineUsed = false;
  };
  const drawSingleInlineFigure = (embedEntry, widthPt, anchor) => {
    if (!embedEntry?.embed) return;
    const clampedWidth = Math.min(widthPt, textWidth);
    const dims = embedEntry.embed.scale(1);
    const aspect = dims && dims.height > 0 ? dims.height / dims.width : 1;
    const height = clampedWidth * aspect;
    flushLine();
    let drawX = textStartX;
    if (anchor === 'right') drawX += textWidth - clampedWidth;
    else if (anchor !== 'left') drawX += (textWidth - clampedWidth) / 2;
    page.drawImage(embedEntry.embed, {
      x: drawX,
      y: curY - height,
      width: clampedWidth,
      height,
    });
    curY -= height + 4;
  };
  const drawGroupInlineFigures = (indices, gapEm) => {
    const stemSizePt = Number(layout.stemSize || 11);
    const gapPt = gapEm * stemSizePt;
    const totalGap = gapPt * (indices.length - 1);
    const boxes = [];
    let rowHeight = 0;
    for (const idx of indices) {
      const entry = figureEmbeds[idx];
      if (!entry?.embed) continue;
      const widthPt = entry.widthPt || stemSizePt * 15;
      const clampedWidth = Math.min(widthPt, textWidth);
      const dims = entry.embed.scale(1);
      const aspect = dims && dims.height > 0 ? dims.height / dims.width : 1;
      const height = clampedWidth * aspect;
      if (height > rowHeight) rowHeight = height;
      boxes.push({ embed: entry.embed, width: clampedWidth, height });
    }
    if (boxes.length === 0) return;
    flushLine();
    const totalWidth = boxes.reduce((s, b) => s + b.width, 0) + totalGap;
    let offsetX = textStartX;
    if (totalWidth < textWidth) offsetX += (textWidth - totalWidth) / 2;
    for (let i = 0; i < boxes.length; i++) {
      const b = boxes[i];
      page.drawImage(b.embed, {
        x: offsetX,
        y: curY - b.height,
        width: b.width,
        height: b.height,
      });
      offsetX += b.width + gapPt;
    }
    curY -= rowHeight + 4;
  };
  const renderedGroupLeaders = new Set();
  const drawTextFlow = (raw) => {
    const plain = sanitizeTextPreserveLineBreaks(raw);
    if (!plain) return;
    const parts = plain.split('\n');
    for (let i = 0; i < parts.length; i += 1) {
      const row = parts[i] || '';
      for (const ch of row) {
        const charWidth = fonts.regular.widthOfTextAtSize(ch, layout.stemSize);
        if (lineUsed && cursorX + charWidth > maxX) {
          flushLine();
        }
        page.drawText(ch, {
          x: cursorX,
          y: curY,
          size: layout.stemSize,
          font: fonts.regular,
          color: rgb(0.12, 0.12, 0.12),
        });
        cursorX += charWidth;
        lineUsed = true;
      }
      if (i < parts.length - 1) {
        flushLine(true);
      }
    }
  };
  const drawTextWithFigureMarkers = (raw) => {
    const segments = raw.split(FIGURE_MARKER_RE_PDF);
    const markers = raw.match(FIGURE_MARKER_RE_PDF) || [];
    for (let s = 0; s < segments.length; s++) {
      if (segments[s]) drawTextFlow(segments[s]);
      if (s < markers.length) {
        const idx = figureMarkerIndex;
        figureMarkerIndex++;
        const groupInfo = groupMap.get(idx);
        if (groupInfo && idx === groupInfo.indices[0]) {
          renderedGroupLeaders.add(idx);
          drawGroupInlineFigures(groupInfo.indices, groupInfo.gap);
        } else if (groupInfo) {
          // skip: already rendered as part of group
        } else {
          const entry = figureEmbeds[idx];
          if (entry?.embed) {
            const stemSizePt = Number(layout.stemSize || 11);
            const widthPt = entry.widthPt || stemSizePt * 15;
            const anchor = entry.anchor || 'center';
            drawSingleInlineFigure(entry, widthPt, anchor);
          }
        }
      }
    }
  };
  const blocks = splitStemMathBlocks(question?.stem || '', question?.equations || []);
  const hasFigureEmbeds = figureEmbeds.length > 0;
  for (const block of blocks) {
    if (block.type === 'text') {
      if (hasFigureEmbeds && FIGURE_MARKER_RE_PDF.test(block.text || '')) {
        FIGURE_MARKER_RE_PDF.lastIndex = 0;
        drawTextWithFigureMarkers(block.text || '');
      } else {
        drawTextFlow(block.text || '');
      }
      continue;
    }
    if (block.type === 'math') {
      if (!shouldRenderMathAsImage(block.latex, { display: block.display })) {
        drawTextFlow(normalizeLatexToReadable(block.latex || ''));
        continue;
      }
      if (block.display) {
        flushLine();
      }
      const desc = await getMathEmbedDescriptor(
        mathContext,
        block.latex,
        {
          fontSize: layout.stemSize,
          display: block.display,
          maxWidthPt: textWidth,
        },
      );
      if (!desc?.embed) {
        drawTextFlow(normalizeLatexToReadable(block.latex || ''));
        continue;
      }
      const fractionLike = desc.isFraction === true;
      const inlinePad = fractionLike
        ? Math.max(3, Math.round(layout.stemSize * 0.34))
        : 1;
      if (block.display) {
        const drawX = textStartX + (textWidth - desc.widthPt) / 2;
        const drawY = curY - desc.heightPt + layout.lineHeight * 0.24;
        page.drawImage(desc.embed, {
          x: drawX,
          y: drawY,
          width: desc.widthPt,
          height: desc.heightPt,
        });
        curY -= desc.heightPt + 6;
        continue;
      }
      const inlineWidth = Math.min(desc.widthPt, textWidth);
      if (inlineWidth >= textWidth * (fractionLike ? 0.88 : 0.94)) {
        flushLine();
        const drawX = textStartX + (textWidth - desc.widthPt) / 2;
        const baselineShift = Number.isFinite(desc.baselineShiftPt)
          ? desc.baselineShiftPt
          : (fractionLike ? -layout.stemSize * 0.2 : -layout.stemSize * 0.12);
        const drawY = curY + baselineShift;
        page.drawImage(desc.embed, {
          x: drawX,
          y: drawY,
          width: desc.widthPt,
          height: desc.heightPt,
        });
        curY -= desc.heightPt + inlinePad + 2;
        continue;
      }
      if (lineUsed && cursorX + inlineWidth > maxX) {
        flushLine();
      }
      const baselineShift = Number.isFinite(desc.baselineShiftPt)
        ? desc.baselineShiftPt
        : (fractionLike ? -layout.stemSize * 0.2 : -layout.stemSize * 0.12);
      const drawY = curY + baselineShift;
      page.drawImage(desc.embed, {
        x: cursorX,
        y: drawY,
        width: desc.widthPt,
        height: desc.heightPt,
      });
      cursorX += inlineWidth + (fractionLike ? 3 : 1);
      lineHeight = Math.max(
        lineHeight,
        Math.max(layout.lineHeight, desc.heightPt + inlinePad),
      );
      lineUsed = true;
    }
  }
  flushLine();
  return { curY, inlineFigureCount: figureMarkerIndex };
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

function parseAssetPixelSize(asset) {
  const rawWidth =
    asset?.width_px ??
    asset?.pixel_width ??
    asset?.widthPx ??
    asset?.image_width ??
    asset?.width ??
    '';
  const rawHeight =
    asset?.height_px ??
    asset?.pixel_height ??
    asset?.heightPx ??
    asset?.image_height ??
    asset?.height ??
    '';
  const widthPx = Number.parseInt(String(rawWidth), 10);
  const heightPx = Number.parseInt(String(rawHeight), 10);
  return {
    widthPx: Number.isFinite(widthPx) && widthPx > 0 ? widthPx : 0,
    heightPx: Number.isFinite(heightPx) && heightPx > 0 ? heightPx : 0,
  };
}

function listFigureAssets(question) {
  const meta = question?.meta && typeof question.meta === 'object' ? question.meta : {};
  const assets = Array.isArray(meta.figure_assets) ? meta.figure_assets : [];
  const out = [];
  for (const asset of assets) {
    const bucket = normalizeWhitespace(asset?.bucket || '');
    const path = normalizeWhitespace(asset?.path || '');
    if (!bucket || !path) continue;
    const mimeType = normalizeWhitespace(asset?.mime_type || asset?.mimeType || '');
    const { widthPx, heightPx } = parseAssetPixelSize(asset);
    out.push({
      ...asset,
      bucket,
      path,
      mimeType,
      widthPx,
      heightPx,
      approved: asset?.approved === true,
      createdAt: String(asset?.created_at || ''),
    });
  }
  return out;
}

function sortFigureAssetsByOrder(question) {
  const assets = listFigureAssets(question).slice();
  assets.sort((a, b) => {
    const ai = Number.parseInt(String(a?.figure_index ?? ''), 10);
    const bi = Number.parseInt(String(b?.figure_index ?? ''), 10);
    const safeAi = Number.isFinite(ai) && ai > 0 ? ai : 1 << 20;
    const safeBi = Number.isFinite(bi) && bi > 0 ? bi : 1 << 20;
    if (safeAi !== safeBi) return safeAi - safeBi;
    return String(b?.createdAt || '').localeCompare(String(a?.createdAt || ''));
  });
  return assets;
}

function figureScaleKeyForAsset(asset, order = 1) {
  const idx = Number.parseInt(String(asset?.figure_index ?? ''), 10);
  if (Number.isFinite(idx) && idx > 0) return `idx:${idx}`;
  const p = normalizeWhitespace(asset?.path || '');
  if (p) return `path:${p}`;
  return `ord:${Math.max(1, Number(order || 1))}`;
}

function pairKeyForFigure(a, b) {
  const aa = normalizeWhitespace(a || '');
  const bb = normalizeWhitespace(b || '');
  if (!aa || !bb || aa === bb) return '';
  return aa.localeCompare(bb) <= 0 ? `${aa}|${bb}` : `${bb}|${aa}`;
}

function pairParts(pairKey) {
  const i = String(pairKey || '').indexOf('|');
  if (i <= 0) return [];
  const a = pairKey.slice(0, i).trim();
  const b = pairKey.slice(i + 1).trim();
  if (!a || !b || a === b) return [];
  return [a, b];
}

function figureHorizontalPairKeysOf(question) {
  const meta = question?.meta && typeof question.meta === 'object' ? question.meta : {};
  const raw = Array.isArray(meta.figure_horizontal_pairs)
    ? meta.figure_horizontal_pairs
    : [];
  const out = new Set();
  for (const one of raw) {
    if (!one || typeof one !== 'object') continue;
    const key = pairKeyForFigure(one?.a ?? one?.left, one?.b ?? one?.right);
    if (key) out.add(key);
  }
  return out;
}

function figureRenderScaleMapOf(question) {
  const meta = question?.meta && typeof question.meta === 'object' ? question.meta : {};
  const raw = meta.figure_render_scales;
  if (!raw || typeof raw !== 'object') return {};
  const out = {};
  for (const key of Object.keys(raw)) {
    const safeKey = normalizeWhitespace(key);
    if (!safeKey) continue;
    const n = Number.parseFloat(String(raw[key]));
    if (!Number.isFinite(n)) continue;
    out[safeKey] = Math.max(0.3, Math.min(2.2, n));
  }
  return out;
}

function figureRenderScaleDefaultOf(question) {
  const meta = question?.meta && typeof question.meta === 'object' ? question.meta : {};
  const n = Number.parseFloat(
    String(meta.figure_render_scale ?? meta.figureScale ?? meta.figure_scale ?? ''),
  );
  if (!Number.isFinite(n)) return 1.0;
  return Math.max(0.3, Math.min(2.2, n));
}

function figureRenderScaleForAsset(question, asset, order = 1) {
  const map = figureRenderScaleMapOf(question);
  const direct = map[figureScaleKeyForAsset(asset, order)];
  if (Number.isFinite(direct)) return direct;
  const idx = Number.parseInt(String(asset?.figure_index ?? ''), 10);
  if (Number.isFinite(idx)) {
    const byIdx = map[`idx:${idx}`];
    if (Number.isFinite(byIdx)) return byIdx;
  }
  const p = normalizeWhitespace(asset?.path || '');
  if (p) {
    const byPath = map[`path:${p}`];
    if (Number.isFinite(byPath)) return byPath;
  }
  return figureRenderScaleDefaultOf(question);
}

function pickBestFigureAsset(question) {
  const assets = listFigureAssets(question);
  if (assets.length === 0) return null;
  assets.sort((a, b) => {
    if (a.approved !== b.approved) return a.approved ? -1 : 1;
    const aSide = Math.max(a.widthPx || 0, a.heightPx || 0);
    const bSide = Math.max(b.widthPx || 0, b.heightPx || 0);
    if (aSide !== bSide) return bSide - aSide;
    return String(b.createdAt || '').localeCompare(String(a.createdAt || ''));
  });
  return assets[0];
}

function estimateFigureRenderBoxFromEmbed(
  embed,
  contentWidth,
  {
    maxHeight = 170,
    renderScale = 1.0,
  } = {},
) {
  if (!embed) return null;
  const dims = embed.scale(1);
  if (!dims || !Number.isFinite(dims.width) || !Number.isFinite(dims.height)) {
    return null;
  }
  const safeScale = Number.isFinite(renderScale) ? renderScale : 1.0;
  const maxWidth = Math.max(1, Number(contentWidth || 0));
  const scaledMaxHeight = Math.max(24, Number(maxHeight || 170) * safeScale);
  const scale = Math.min(maxWidth / dims.width, scaledMaxHeight / dims.height);
  const fitScale = Number.isFinite(scale) && scale > 0 ? scale : 1;
  const width = Math.max(1, dims.width * fitScale);
  const height = Math.max(1, dims.height * fitScale);
  return { width, height };
}

function estimateFigureRenderBox(question, contentWidth, entry = null) {
  const embed = entry?.embed || question.figure_embed;
  const renderScale = Number.isFinite(entry?.renderScale)
    ? entry.renderScale
    : figureRenderScaleDefaultOf(question);
  return estimateFigureRenderBoxFromEmbed(embed, contentWidth, {
    renderScale,
  });
}

async function queueFigureRegenerationIfNeeded({
  job,
  question,
  minSidePx,
}) {
  const questionId = String(question?.id || '').trim();
  if (!questionId) return { queued: false, reason: 'question_id_empty' };
  const meta = question?.meta && typeof question.meta === 'object' ? question.meta : {};
  const latestGeneratedAt = String(meta.figure_last_generated_at || '').trim();
  if (latestGeneratedAt) {
    const ts = Date.parse(latestGeneratedAt);
    if (Number.isFinite(ts)) {
      const elapsedMs = Date.now() - ts;
      if (elapsedMs >= 0 && elapsedMs < FIGURE_REGEN_COOLDOWN_MIN * 60 * 1000) {
        return { queued: false, reason: 'cooldown' };
      }
    }
  }
  const { data: existing } = await supa
    .from('pb_figure_jobs')
    .select('id,status')
    .eq('academy_id', job.academy_id)
    .eq('document_id', question.document_id || job.document_id)
    .eq('question_id', questionId)
    .in('status', ['queued', 'rendering'])
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();
  if (existing) return { queued: false, reason: 'already_queued', jobId: existing.id };

  const insertPayload = {
    academy_id: job.academy_id,
    document_id: question.document_id || job.document_id,
    question_id: questionId,
    created_by: job.requested_by || null,
    status: 'queued',
    provider: 'gemini',
    model_name: '',
    options: {
      minSidePx,
      requestedBy: 'pb_export_worker',
      source: 'export_highres_fallback',
    },
    prompt_text: '',
    worker_name: '',
    result_summary: {},
    output_storage_bucket: 'problem-previews',
    output_storage_path: '',
    error_code: '',
    error_message: '',
    started_at: null,
    finished_at: null,
  };
  const { data, error } = await supa
    .from('pb_figure_jobs')
    .insert(insertPayload)
    .select('id,status')
    .maybeSingle();
  if (error || !data) {
    return { queued: false, reason: `queue_failed:${error?.message || 'unknown'}` };
  }
  return { queued: true, reason: 'queued', jobId: data.id };
}

async function embedImageFromBytes(pdfDoc, bytes, pathHint = '', mimeHint = '') {
  const path = String(pathHint || '').toLowerCase();
  const mime = String(mimeHint || '').toLowerCase();
  if (mime.includes('jpeg') || mime.includes('jpg') || /\.jpe?g$/i.test(path)) {
    return pdfDoc.embedJpg(bytes);
  }
  if (mime.includes('png') || /\.png$/i.test(path) || mime.includes('image/')) {
    return pdfDoc.embedPng(bytes);
  }
  return null;
}

async function maybeResampleImage(bytes, targetWidthPx) {
  if (!Buffer.isBuffer(bytes) || bytes.length === 0) return null;
  const safeWidth = Math.max(64, Math.round(targetWidthPx || 0));
  try {
    const resized = await sharp(bytes)
      .resize({
        width: safeWidth,
        fit: 'inside',
        withoutEnlargement: false,
      })
      .png()
      .toBuffer();
    const meta = await sharp(resized).metadata();
    return {
      bytes: resized,
      mimeType: 'image/png',
      widthPx: Number(meta.width || 0),
      heightPx: Number(meta.height || 0),
    };
  } catch (_) {
    return null;
  }
}

function estimatePlacedPixelWidth({
  widthPx,
  heightPx,
  contentWidthPt,
  targetDpi,
  renderScale = 1.0,
}) {
  const safeW = Number(widthPx || 0);
  const safeH = Number(heightPx || 0);
  if (safeW <= 0 || safeH <= 0) return 0;
  const safeScale = Number.isFinite(renderScale) ? renderScale : 1.0;
  const maxHeightPt = 170 * Math.max(0.3, Math.min(2.2, safeScale));
  const scale = Math.min(contentWidthPt / safeW, maxHeightPt / safeH);
  const fitScale = Number.isFinite(scale) && scale > 0 ? scale : 1;
  const placedWidthPt = safeW * fitScale;
  const placedWidthInch = placedWidthPt / 72;
  if (placedWidthInch <= 0) return 0;
  return Math.max(1, Math.ceil(placedWidthInch * targetDpi));
}

function effectiveDpiFromPlacement(widthPx, placedWidthPt) {
  const safeWidthPx = Number(widthPx || 0);
  const safePlacedPt = Number(placedWidthPt || 0);
  if (safeWidthPx <= 0 || safePlacedPt <= 0) return 0;
  const inch = safePlacedPt / 72;
  if (inch <= 0) return 0;
  return safeWidthPx / inch;
}

async function hydrateApprovedFigureEmbeds(
  pdfDoc,
  questions,
  {
    job,
    contentWidthPt,
    figureQuality,
  },
) {
  const embedCache = new Map();
  const qualityStats = {
    appliedCount: 0,
    degradedCount: 0,
    resampledCount: 0,
    regenerationQueuedCount: 0,
    effectiveDpiByQuestionId: {},
  };
  for (const q of questions) {
    q.figure_asset = null;
    q.figure_embed = null;
    q.figure_quality = null;
    q.figure_embeds = [];
    const assets = sortFigureAssetsByOrder(q);
    if (assets.length === 0) continue;
    let order = 0;
    for (const asset of assets) {
      order += 1;
      const cacheKey = `${asset.bucket}/${asset.path}`;
      if (!embedCache.has(cacheKey)) {
        try {
          const { data, error } = await supa.storage
            .from(asset.bucket)
            .download(asset.path);
          if (error || !data) {
            embedCache.set(cacheKey, null);
          } else {
            const rawBytes = await toBufferFromStorageData(data);
            let widthPx = Number(asset.widthPx || 0);
            let heightPx = Number(asset.heightPx || 0);
            if (widthPx <= 0 || heightPx <= 0) {
              try {
                const meta = await sharp(rawBytes).metadata();
                widthPx = Number(meta.width || 0);
                heightPx = Number(meta.height || 0);
              } catch (_) {}
            }
            const targetDpi = Math.max(300, Number(figureQuality?.targetDpi || 450));
            const minDpi = Math.max(
              180,
              Math.min(targetDpi, Number(figureQuality?.minDpi || 300)),
            );
            const renderScale = figureRenderScaleForAsset(q, asset, order);
            const targetWidthPx = estimatePlacedPixelWidth({
              widthPx,
              heightPx,
              contentWidthPt,
              targetDpi,
              renderScale,
            });
            const maxHeightPt = 170 * renderScale;
            const scale = Math.min(
              contentWidthPt / Math.max(1, widthPx),
              maxHeightPt / Math.max(1, heightPx),
            );
            const placedWidthPt = Math.max(
              1,
              Math.max(1, widthPx) * (Number.isFinite(scale) && scale > 0 ? scale : 1),
            );
            const effectiveDpi = effectiveDpiFromPlacement(widthPx, placedWidthPt);
            let degraded = effectiveDpi > 0 ? effectiveDpi < minDpi : false;
            let regenerationQueued = false;
            let bytes = rawBytes;
            let mimeType = String(asset.mimeType || '').trim();
            let resampled = false;
            if ((widthPx > 0 && targetWidthPx > widthPx) || degraded) {
              const regenMinSidePx = Math.max(
                1024,
                Math.min(
                  4096,
                  Math.max(targetWidthPx, Math.round((targetWidthPx || 0) * 1.2)),
                ),
              );
              const regenResult = await queueFigureRegenerationIfNeeded({
                job,
                question: q,
                minSidePx: regenMinSidePx,
              });
              regenerationQueued = regenResult.queued === true;
              if (targetWidthPx > 0) {
                const sampled = await maybeResampleImage(bytes, targetWidthPx);
                if (sampled?.bytes) {
                  bytes = sampled.bytes;
                  mimeType = sampled.mimeType;
                  widthPx = sampled.widthPx || widthPx;
                  heightPx = sampled.heightPx || heightPx;
                  resampled = true;
                  degraded = true;
                }
              }
            }
            const embed = await embedImageFromBytes(
              pdfDoc,
              bytes,
              asset.path,
              mimeType,
            );
            embedCache.set(cacheKey, {
              embed,
              asset: {
                ...asset,
                widthPx,
                heightPx,
                mimeType,
              },
              quality: {
                targetDpi,
                minDpi,
                effectiveDpi,
                targetWidthPx,
                degraded,
                resampled,
                regenerationQueued,
              },
            });
          }
        } catch (_) {
          embedCache.set(cacheKey, null);
        }
      }
      const cached = embedCache.get(cacheKey);
      if (!cached?.embed) continue;
      q.figure_embeds.push({
        key: figureScaleKeyForAsset(cached.asset, order),
        order,
        embed: cached.embed,
        asset: cached.asset,
        quality: cached.quality,
        renderScale: figureRenderScaleForAsset(q, cached.asset, order),
      });
    }
    if (!Array.isArray(q.figure_embeds) || q.figure_embeds.length === 0) {
      continue;
    }
    const primary =
      q.figure_embeds.find((one) => one?.asset?.approved === true) ||
      q.figure_embeds[0];
    q.figure_asset = primary.asset;
    q.figure_embed = primary.embed;
    q.figure_quality = primary.quality;
    qualityStats.appliedCount += 1;
    if (primary.quality?.degraded) qualityStats.degradedCount += 1;
    if (primary.quality?.resampled) qualityStats.resampledCount += 1;
    if (primary.quality?.regenerationQueued) qualityStats.regenerationQueuedCount += 1;
    qualityStats.effectiveDpiByQuestionId[q.id] = Number(
      primary.quality?.effectiveDpi || 0,
    );
  }
  return qualityStats;
}

function normalizePaper(raw) {
  const key = String(raw || '').trim();
  return PAPER_SIZE[key] ? key : 'A4';
}

function normalizeProfile(raw) {
  const p = String(raw || '').trim().toLowerCase();
  if (p === 'csat' || p === 'mock' || p === 'naesin') return p;
  return 'naesin';
}

function normalizeQuestionMode(raw) {
  const v = String(raw || '').trim().toLowerCase();
  if (v === 'objective' || v === '\uAC1D\uAD00\uC2DD' || v === 'mcq') return 'objective';
  if (v === 'subjective' || v === '\uC8FC\uAD00\uC2DD') return 'subjective';
  if (v === 'essay' || v === '\uC11C\uC220\uD615') return 'essay';
  return 'original';
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

function normalizeAnchorPage(raw) {
  const s = String(raw || '').trim().toLowerCase();
  if (!s || s === 'first' || s === '1') return 'first';
  if (s === 'all' || s === 'every') return 'all';
  const n = Number.parseInt(s, 10);
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
    const label = normalizeWhitespace(one.label || one.text || '');
    if (!label) continue;
    const topPt = Number(one.topPt);
    const paddingTopPt = Number(one.paddingTopPt);
    out.push({
      columnIndex,
      label,
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

function normalizeNumeric(raw, fallback, min, max) {
  const n = Number.parseFloat(String(raw ?? ''));
  if (!Number.isFinite(n)) return fallback;
  return Math.min(max, Math.max(min, n));
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
    normalizeNumeric(src.targetDpi ?? options.targetDpi, 450, 300, FIGURE_MAX_DPI),
  );
  const minDpi = Math.round(
    normalizeNumeric(src.minDpi ?? options.minDpi, 300, 180, targetDpi),
  );
  return { targetDpi, minDpi };
}

function normalizeSelectedQuestionIdsOrdered(raw, fallbackSelectedIds) {
  const fallback = Array.isArray(fallbackSelectedIds)
    ? fallbackSelectedIds.map((e) => String(e || '').trim()).filter((e) => e.length > 0)
    : [];
  const src = Array.isArray(raw)
    ? raw.map((e) => String(e || '').trim()).filter((e) => e.length > 0)
    : [];
  if (src.length === 0) return fallback;
  const fallbackSet = new Set(fallback);
  const ordered = src.filter((id) => fallbackSet.has(id));
  const orderedSet = new Set(ordered);
  for (const id of fallback) {
    if (!orderedSet.has(id)) ordered.push(id);
  }
  return ordered;
}

function normalizeQuestionModeMap(raw, selectedQuestionIdsOrdered, fallbackMode) {
  const src = raw && typeof raw === 'object' ? raw : {};
  const out = {};
  for (const id of selectedQuestionIdsOrdered) {
    out[id] = normalizeQuestionMode(src[id] || fallbackMode);
  }
  return out;
}

function buildRenderConfigFromJob(job) {
  const options = job.options && typeof job.options === 'object' ? job.options : {};
  const layoutColumns = normalizeLayoutColumns(
    options.layoutColumns ||
      options.layout_columns ||
      options.columnCount ||
      options.columns ||
      1,
  );
  const maxQuestionsPerPage = normalizeMaxQuestionsPerPage(
    options.maxQuestionsPerPage ||
      options.max_questions_per_page ||
      options.perPage ||
      options.questionsPerPage ||
      '',
    layoutColumns,
  );
  const layoutMode = normalizeLayoutMode(options.layoutMode || 'legacy');
  const columnQuestionCounts = normalizeColumnQuestionCounts(
    options.columnQuestionCounts,
    layoutColumns,
    maxQuestionsPerPage,
  );
  const columnLabelAnchors = normalizeColumnLabelAnchors(
    options.columnLabelAnchors,
    layoutColumns,
  );
  const pageColumnQuestionCounts = normalizePageColumnQuestionCounts(
    options.pageColumnQuestionCounts || options.pageColumnCounts,
    layoutColumns,
  );
  const alignPolicy = normalizeAlignPolicy(options.alignPolicy);
  const questionMode = normalizeQuestionMode(
    options.questionMode || options.question_mode || options.mode || 'original',
  );
  const selectedQuestionIdsOrdered = normalizeSelectedQuestionIdsOrdered(
    options.selectedQuestionIdsOrdered,
    Array.isArray(job.selected_question_ids) ? job.selected_question_ids : [],
  );
  const questionModeByQuestionId = normalizeQuestionModeMap(
    options.questionModeByQuestionId,
    selectedQuestionIdsOrdered,
    questionMode,
  );
  const font =
    options.font && typeof options.font === 'object'
      ? {
          family: normalizeWhitespace(options.font.family || ''),
          size: normalizeNumeric(options.font.size, 11.3, 8, 28),
        }
      : {
          family: '',
          size: 11.3,
        };
  const subjectTitleText =
    normalizeWhitespace(options.subjectTitleText || '\uC218\uD559 \uC601\uC5ED') || '\uC218\uD559 \uC601\uC5ED';
  return {
    // Always normalize to current renderer version on worker side.
    renderConfigVersion: RENDER_CONFIG_VERSION,
    templateProfile: normalizeProfile(job.template_profile),
    paperSize: normalizePaper(job.paper_size),
    includeAnswerSheet: job.include_answer_sheet === true,
    includeExplanation: job.include_explanation === true,
    layoutColumns,
    maxQuestionsPerPage,
    layoutMode,
    columnQuestionCounts,
    pageColumnQuestionCounts,
    columnLabelAnchors,
    alignPolicy,
    questionMode,
    layoutTuning: normalizeLayoutTuning(options.layoutTuning, options),
    figureQuality: normalizeFigureQuality(options.figureQuality, options),
    selectedQuestionIdsOrdered,
    questionModeByQuestionId,
    font,
    subjectTitleText,
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

function computeRenderHash(renderConfig) {
  const payload = {
    renderConfigVersion: renderConfig.renderConfigVersion,
    templateProfile: renderConfig.templateProfile,
    paperSize: renderConfig.paperSize,
    includeAnswerSheet: renderConfig.includeAnswerSheet,
    includeExplanation: renderConfig.includeExplanation,
    layoutColumns: renderConfig.layoutColumns,
    maxQuestionsPerPage: renderConfig.maxQuestionsPerPage,
    layoutMode: renderConfig.layoutMode,
    columnQuestionCounts: renderConfig.columnQuestionCounts,
    pageColumnQuestionCounts: renderConfig.pageColumnQuestionCounts,
    columnLabelAnchors: renderConfig.columnLabelAnchors,
    alignPolicy: renderConfig.alignPolicy,
    questionMode: renderConfig.questionMode,
    layoutTuning: renderConfig.layoutTuning,
    figureQuality: renderConfig.figureQuality,
    selectedQuestionIdsOrdered: renderConfig.selectedQuestionIdsOrdered,
    questionModeByQuestionId: renderConfig.questionModeByQuestionId,
    font: renderConfig.font,
    subjectTitleText: renderConfig.subjectTitleText,
  };
  const canonical = JSON.stringify(canonicalizeJson(payload));
  return createHash('sha256').update(canonical).digest('hex');
}

function choiceLabelByIndex(index) {
  const table = [
    '\u2460',
    '\u2461',
    '\u2462',
    '\u2463',
    '\u2464',
    '\u2465',
    '\u2466',
    '\u2467',
    '\u2468',
    '\u2469',
  ];
  return table[index] || String(index + 1);
}

function normalizeChoiceRows(rawChoices) {
  const rows = Array.isArray(rawChoices) ? rawChoices : [];
  const out = [];
  for (let i = 0; i < rows.length; i += 1) {
    const item = rows[i] || {};
    const text = normalizeWhitespace(
      String(item.text ?? item.value ?? item.choice ?? ''),
    );
    if (!text) continue;
    const label = normalizeWhitespace(String(item.label ?? '')) || choiceLabelByIndex(i);
    out.push({ label, text });
    if (out.length >= 10) break;
  }
  return out;
}

function sanitizeAnswerText(value) {
  return normalizeWhitespace(
    String(value || '').replace(/^\[?\s*\uC815\uB2F5\s*\]?\s*[:\uFF1A]?\s*/i, ''),
  );
}

function objectiveAnswerToSubjective(value) {
  const src = sanitizeAnswerText(value);
  if (!src) return '';
  return src.replaceAll(
    /[\u2460\u2461\u2462\u2463\u2464\u2465\u2466\u2467\u2468\u2469]/g,
    (ch) =>
      ({
        '\u2460': '1',
        '\u2461': '2',
        '\u2462': '3',
        '\u2463': '4',
        '\u2464': '5',
        '\u2465': '6',
        '\u2466': '7',
        '\u2467': '8',
        '\u2468': '9',
        '\u2469': '10',
      })[ch] || ch,
  );
}

function resolveObjectiveChoices(question) {
  const fromDedicated = normalizeChoiceRows(question.objective_choices);
  if (fromDedicated.length >= 2) return fromDedicated;
  return normalizeChoiceRows(question.choices);
}

function resolveObjectiveAnswer(question) {
  return sanitizeAnswerText(
    question.objective_answer_key ||
      question?.meta?.objective_answer_key ||
      question?.meta?.answer_key ||
      '',
  );
}

function resolveSubjectiveAnswer(question, objectiveAnswer = '') {
  const dedicated = sanitizeAnswerText(
    question.subjective_answer || question?.meta?.subjective_answer || '',
  );
  if (dedicated) return dedicated;
  return objectiveAnswerToSubjective(objectiveAnswer);
}

function looksObjectiveInOriginal(question, originalChoices = null) {
  const choices = Array.isArray(originalChoices)
    ? originalChoices
    : normalizeChoiceRows(question.choices);
  return choices.length >= 2 || /\uAC1D\uAD00\uC2DD/.test(String(question.question_type || ''));
}

function originalQuestionModeOf(question, originalChoices = null) {
  const type = String(question.question_type || '').trim();
  if (/\uC11C\uC220/.test(type)) return 'essay';
  if (/\uAC1D\uAD00\uC2DD/.test(type)) return 'objective';
  if (/\uC8FC\uAD00\uC2DD/.test(type)) return 'subjective';
  const allowObjective = question.allow_objective !== false;
  const allowSubjective = question.allow_subjective !== false;
  if (allowObjective && !allowSubjective) return 'objective';
  if (!allowObjective && allowSubjective) return 'subjective';
  return looksObjectiveInOriginal(question, originalChoices) ? 'objective' : 'subjective';
}

function selectableQuestionModes(question, originalChoices) {
  const out = [];
  const allowObjective = question.allow_objective !== false;
  const allowSubjective = question.allow_subjective !== false;
  const originalMode = originalQuestionModeOf(question, originalChoices);
  if (allowObjective || originalMode === 'objective') out.push('objective');
  if (allowSubjective || originalMode === 'subjective') out.push('subjective');
  if (/\uC11C\uC220/.test(String(question.question_type || '')) || originalMode === 'essay') {
    out.push('essay');
  }
  if (out.length === 0) out.push(originalMode);
  return [...new Set(out)];
}

function normalizeQuestionModeSelection(question, selectedMode, fallbackMode = 'original') {
  const originalChoices = normalizeChoiceRows(question.choices);
  const selectable = selectableQuestionModes(question, originalChoices);
  const normalizedSelected = normalizeQuestionMode(selectedMode);
  if (normalizedSelected !== 'original' && selectable.includes(normalizedSelected)) {
    return normalizedSelected;
  }
  const normalizedFallback = normalizeQuestionMode(fallbackMode);
  if (normalizedFallback !== 'original' && selectable.includes(normalizedFallback)) {
    return normalizedFallback;
  }
  const originalMode = originalQuestionModeOf(question, originalChoices);
  if (selectable.includes(originalMode)) return originalMode;
  return selectable[0] || 'subjective';
}

function applyQuestionModeForQuestion(question, selectedMode, fallbackMode = 'original') {
  const objectiveChoices = resolveObjectiveChoices(question);
  const objectiveAnswer = resolveObjectiveAnswer(question);
  const subjectiveAnswer = resolveSubjectiveAnswer(question, objectiveAnswer);
  const allowObjective = question.allow_objective !== false;
  const allowSubjective = question.allow_subjective !== false;
  const mode = normalizeQuestionModeSelection(question, selectedMode, fallbackMode);
  const out = {
    ...question,
    allow_objective: allowObjective,
    allow_subjective: allowSubjective,
    objective_choices: objectiveChoices,
    objective_answer_key: objectiveAnswer,
    subjective_answer: subjectiveAnswer,
    export_mode: mode,
    export_answer: '',
  };
  if (mode === 'objective') {
    if (!allowObjective || objectiveChoices.length < 2) {
      throw new Error(`question_mode_incompatible_objective:${question.id || question.question_number || '?'}`);
    }
    return {
      mode,
      question: {
        ...out,
        question_type: '\uAC1D\uAD00\uC2DD',
        choices: objectiveChoices,
        export_answer: objectiveAnswer,
      },
    };
  }
  if (mode === 'subjective' || mode === 'essay') {
    if (!allowSubjective && mode === 'subjective') {
      throw new Error(`question_mode_incompatible_subjective:${question.id || question.question_number || '?'}`);
    }
    return {
      mode,
      question: {
        ...out,
        question_type:
          mode === 'essay'
            ? '\uC11C\uC220\uD615'
            : '\uC8FC\uAD00\uC2DD',
        choices: [],
        export_answer: subjectiveAnswer,
      },
    };
  }
  const originalChoices = normalizeChoiceRows(question.choices);
  const originalLooksObjective = looksObjectiveInOriginal(question, originalChoices);
  return {
    mode: originalLooksObjective ? 'objective' : 'subjective',
    question: {
      ...out,
      choices: originalLooksObjective ? originalChoices : [],
      export_answer: originalLooksObjective ? objectiveAnswer : subjectiveAnswer,
      export_mode: originalLooksObjective ? 'objective' : 'subjective',
      question_type: originalLooksObjective ? '\uAC1D\uAD00\uC2DD' : '\uC8FC\uAD00\uC2DD',
    },
  };
}

function applyQuestionModesForExport(questions, questionModeByQuestionId, fallbackMode) {
  const modeMap = {};
  const normalized = [];
  for (const q of questions || []) {
    const selectedMode = questionModeByQuestionId?.[q.id];
    const applied = applyQuestionModeForQuestion(q, selectedMode, fallbackMode);
    modeMap[q.id] = applied.mode;
    normalized.push(applied.question);
  }
  return { questions: normalized, modeByQuestionId: modeMap };
}

function toErrorCode(err) {
  const msg = String(err?.message || err || '');
  if (/not\s*found|404/i.test(msg)) return 'NOT_FOUND';
  if (/timeout/i.test(msg)) return 'TIMEOUT';
  if (/permission|401|403|forbidden/i.test(msg)) return 'PERMISSION_DENIED';
  if (/pdf|font|render/i.test(msg)) return 'RENDER_FAILED';
  return 'UNKNOWN';
}

async function lockQueuedJob(job) {
  const nowIso = new Date().toISOString();
  const { data, error } = await supa
    .from('pb_exports')
    .update({
      status: 'rendering',
      worker_name: WORKER_NAME,
      started_at: nowIso,
      finished_at: null,
      error_code: '',
      error_message: '',
      updated_at: nowIso,
    })
    .eq('id', job.id)
    .eq('status', 'queued')
    .select('*')
    .maybeSingle();
  if (error) throw new Error(`export_job_lock_failed:${error.message}`);
  return data;
}

async function markFailed(jobId, error) {
  const nowIso = new Date().toISOString();
  await supa
    .from('pb_exports')
    .update({
      status: 'failed',
      error_code: toErrorCode(error),
      error_message: compact(error?.message || error),
      finished_at: nowIso,
      updated_at: nowIso,
    })
    .eq('id', jobId);
}

async function loadFonts(pdfDoc, { requestedFamily = '' } = {}) {
  pdfDoc.registerFontkit(fontkit);
  const fontPaths = resolveRequestedFontPaths(requestedFamily);
  let regular = null;
  let bold = null;
  if (fontPaths.regularPath && fs.existsSync(fontPaths.regularPath)) {
    try {
      regular = await pdfDoc.embedFont(fs.readFileSync(fontPaths.regularPath), {
        subset: true,
      });
    } catch (_) {
      regular = null;
    }
  }
  if (fontPaths.boldPath && fs.existsSync(fontPaths.boldPath)) {
    try {
      bold = await pdfDoc.embedFont(fs.readFileSync(fontPaths.boldPath), {
        subset: true,
      });
    } catch (_) {
      bold = null;
    }
  }
  if (!regular) {
    regular = await pdfDoc.embedFont(StandardFonts.Helvetica);
  }
  if (!bold) {
    bold = await pdfDoc.embedFont(StandardFonts.HelveticaBold);
  }
  return {
    regular,
    bold,
    requestedFamily: fontPaths.requestedFamily,
    resolvedFamily: fontPaths.resolvedFamily,
    regularPath: fontPaths.regularPath,
    boldPath: fontPaths.boldPath,
  };
}

function wrapTextByWidth(text, font, size, maxWidth) {
  const src = sanitizeTextPreserveLineBreaks(text);
  if (!src) return [''];
  const paragraphs = src.split('\n');
  const lines = [];
  for (const p of paragraphs) {
    const paragraph = sanitizeText(p);
    if (!paragraph) {
      lines.push('');
      continue;
    }
    let line = '';
    for (const ch of paragraph) {
      const candidate = `${line}${ch}`;
      const w = font.widthOfTextAtSize(candidate, size);
      if (w <= maxWidth || line.length === 0) {
        line = candidate;
      } else {
        lines.push(line);
        line = ch;
      }
    }
    if (line) lines.push(line);
  }
  return lines;
}

function estimateVisualLengthForChoice(text) {
  let s = String(text || '');
  for (let i = 0; i < 4; i += 1) {
    const next = s.replace(
      /\\(?:d?frac|tfrac)\s*\{([^{}]*)\}\s*\{([^{}]*)\}/g,
      '$1/$2',
    );
    if (next === s) break;
    s = next;
  }
  s = s
    .replace(/\{([^{}]*)\}\s*\\over\s*\{([^{}]*)\}/g, '$1/$2')
    .replace(/\\mathrm\{([^{}]*)\}/g, '$1')
    .replace(/\\[a-zA-Z]+/g, ' ')
    .replace(/[{}]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
  return s.length;
}

function estimateChoiceRequiredWidth(choiceText) {
  const raw = rawText(choiceText || '');
  const visual = estimateVisualLengthForChoice(raw);
  const latex = normalizeMathLatex(raw);
  const hasFraction =
    /\\(?:frac|dfrac|tfrac)/.test(latex) || /(^|[^\\])\d+\s*\/\s*\d+/.test(latex);
  const hasNestedFraction =
    hasFraction &&
    (/\\left|\\right/.test(latex) ||
      /\([^()]*\([^()]+\)/.test(latex) ||
      /\[[^\[\]]*\[[^\[\]]+\]/.test(latex));
  const hasLongMath = /\\(?:sqrt|sum|int|overline|lim|log)/.test(latex);
  const symbolCount =
    (raw.match(/[=+\-<>\u00D7\u00F7\u00B7\u00B1^_]/g) || []).length;
  let width = 30 + visual * 7.2 + symbolCount * 2.4;
  if (hasFraction) width += 22;
  if (hasNestedFraction) width += 42;
  if (hasLongMath) width += 30;
  return width;
}

function resolveChoiceLayoutMode(question, choices, availableWidth) {
  if (!Array.isArray(choices) || choices.length !== 5) return 'stacked';
  const safeWidth = Number.isFinite(availableWidth) && availableWidth > 120
    ? availableWidth
    : 620;
  const singleGaps = 8 * 4;
  const splitGaps = 8 * 2;
  const singleCellWidth = (safeWidth - singleGaps) / 5;
  const splitCellWidth = (safeWidth - splitGaps) / 3;
  const requiredWidths = choices.map((c) =>
    estimateChoiceRequiredWidth(rawText(c?.text || '')));
  const fitsSingle = requiredWidths.every((w) => w <= singleCellWidth);
  if (fitsSingle) return 'single';
  const topFits = requiredWidths.slice(0, 3).every((w) => w <= splitCellWidth);
  const bottomFits = requiredWidths.slice(3).every((w) => w <= splitCellWidth);
  if (topFits && bottomFits) return 'split_3_2';
  return 'stacked';
}

function normalizeFigureEntriesForQuestion(question) {
  const entries = Array.isArray(question?.figure_embeds)
    ? question.figure_embeds.filter((e) => e?.embed)
    : [];
  if (entries.length > 0) return entries;
  if (question?.figure_embed) {
    return [
      {
        key: figureScaleKeyForAsset(question?.figure_asset, 1),
        order: 1,
        embed: question.figure_embed,
        asset: question.figure_asset || null,
        quality: question.figure_quality || null,
        renderScale: figureRenderScaleForAsset(question, question?.figure_asset, 1),
      },
    ];
  }
  return [];
}

function resolveFigurePairEntries(question) {
  const entries = normalizeFigureEntriesForQuestion(question);
  if (entries.length === 0) return { primary: null, secondary: null };
  const byKey = new Map(entries.map((e) => [String(e.key || ''), e]));
  const primary =
    entries.find((e) => e?.asset?.approved === true) ||
    entries[0];
  if (!primary) return { primary: null, secondary: null };
  const pairKeys = figureHorizontalPairKeysOf(question);
  for (const one of pairKeys) {
    const parts = pairParts(one);
    if (parts.length !== 2) continue;
    let partner = null;
    if (parts[0] === primary.key) partner = byKey.get(parts[1]) || null;
    if (parts[1] === primary.key) partner = byKey.get(parts[0]) || null;
    if (!partner) continue;
    if ((partner.order || 0) < (primary.order || 0)) continue;
    return { primary, secondary: partner };
  }
  return { primary, secondary: null };
}

async function buildChoiceDescriptor({
  question,
  choice,
  fonts,
  layout,
  maxWidth,
  mathContext,
}) {
  const safeMaxWidth = Math.max(24, Number(maxWidth || 0));
  const lineHeight = Math.max(11, layout.lineHeight - 1);
  const label = sanitizeText(choice?.label || '') || '-';
  const choiceRaw = rawText(choice?.text || '');
  const labelPrefix = `${label} `;
  const labelWidth = fonts.regular.widthOfTextAtSize(labelPrefix, layout.choiceSize);
  const choiceLatex = pickChoiceMathLatex(question, choiceRaw);
  if (choiceLatex && shouldRenderMathAsImage(choiceLatex, { display: false })) {
    const mathWidth = Math.max(18, safeMaxWidth - labelWidth);
    const desc = await getMathEmbedDescriptor(
      mathContext,
      choiceLatex,
      {
        fontSize: layout.choiceSize,
        display: false,
        maxWidthPt: mathWidth,
      },
    );
    if (desc?.embed && desc.widthPt <= mathWidth + 0.5) {
      const scaleRatio = Number(desc.scaleRatio || 1);
      const fractionLike = desc.isFraction === true;
      // If math was heavily shrunk to fit narrow cells, avoid row layout
      // and let caller reflow choices in stacked mode with larger width.
      const aggressivelyShrunk = scaleRatio < (fractionLike ? 0.96 : 0.9);
      const mathPad = fractionLike
        ? Math.max(4, Math.round(layout.choiceSize * 0.38))
        : 1;
      return {
        kind: 'math',
        label,
        labelPrefix,
        labelWidth,
        math: desc,
        width: Math.min(safeMaxWidth, labelWidth + desc.widthPt),
        height: Math.max(layout.lineHeight + mathPad, desc.heightPt + mathPad),
        singleLine: !aggressivelyShrunk,
      };
    }
  }
  const plain = sanitizeText(choiceRaw);
  const rowText = `${labelPrefix}${plain}`.trim();
  const lines = wrapTextByWidth(
    rowText,
    fonts.regular,
    layout.choiceSize,
    safeMaxWidth,
  );
  const width = lines.reduce((acc, line) => {
    if (!line) return acc;
    return Math.max(acc, fonts.regular.widthOfTextAtSize(line, layout.choiceSize));
  }, 0);
  return {
    kind: 'text',
    lines,
    width,
    height: Math.max(lineHeight, lines.length * lineHeight),
    lineHeight,
    singleLine: lines.length <= 1,
  };
}

function drawChoiceDescriptor({ page, descriptor, x, y, fonts, layout }) {
  if (!descriptor) return;
  if (descriptor.kind === 'math' && descriptor.math?.embed) {
    page.drawText(descriptor.labelPrefix || '', {
      x,
      y,
      size: layout.choiceSize,
      font: fonts.regular,
      color: rgb(0.14, 0.14, 0.14),
    });
    const fractionLike = descriptor.math?.isFraction === true;
    const baselineShift = Number.isFinite(descriptor.math?.baselineShiftPt)
      ? descriptor.math.baselineShiftPt
      : (fractionLike ? -layout.choiceSize * 0.2 : -layout.choiceSize * 0.12);
    const drawY = y + baselineShift;
    page.drawImage(descriptor.math.embed, {
      x: x + descriptor.labelWidth,
      y: drawY,
      width: descriptor.math.widthPt,
      height: descriptor.math.heightPt,
    });
    return;
  }
  const lineHeight = Math.max(11, descriptor.lineHeight || layout.lineHeight - 1);
  let yy = y;
  for (const line of descriptor.lines || []) {
    if (line) {
      page.drawText(line, {
        x,
        y: yy,
        size: layout.choiceSize,
        font: fonts.regular,
        color: rgb(0.14, 0.14, 0.14),
      });
    }
    yy -= lineHeight;
  }
}

function estimateQuestionHeight(question, fonts, layout, contentWidth, startX = 0) {
  void startX;
  const numberLaneWidth = Math.max(0, Number(layout.numberLaneWidth || 0));
  const numberGap = Math.max(0, Number(layout.numberGap || 0));
  const textWidth = Math.max(36, contentWidth - numberLaneWidth - numberGap);
  let h = layout.lineHeight; // number line
  h += estimateStemMathBlocksHeight(question, fonts, layout, textWidth);
  const stemSizePtEst = Number(layout.stemSize || 11);
  const figLayoutEst = resolveFigureLayout(question, stemSizePtEst);
  const entriesEst = normalizeFigureEntriesForQuestion(question);

  const stemMarkerCountEst = ((question?.stem || '').match(FIGURE_MARKER_RE_PDF) || []).length;
  FIGURE_MARKER_RE_PDF.lastIndex = 0;
  const inlineSkipEst = Math.min(stemMarkerCountEst, entriesEst.length, figLayoutEst ? figLayoutEst.items.length : 0);

  if (inlineSkipEst > 0 && figLayoutEst) {
    const inlineGroupMap = new Map();
    if (figLayoutEst.groups) {
      for (const group of figLayoutEst.groups) {
        if (group.type !== 'horizontal') continue;
        const memberIndices = [];
        for (const memberKey of group.members) {
          const idx = figLayoutEst.items.findIndex((it) => it.assetKey === memberKey);
          if (idx >= 0 && idx < inlineSkipEst) memberIndices.push(idx);
        }
        if (memberIndices.length >= 2) {
          for (const idx of memberIndices) {
            inlineGroupMap.set(idx, { indices: memberIndices });
          }
        }
      }
    }
    const estimatedInlineGroups = new Set();
    for (let i = 0; i < inlineSkipEst; i++) {
      const entry = entriesEst[i];
      const layoutItem = figLayoutEst.items[i];
      if (!entry?.embed || !layoutItem) continue;
      const groupInfo = inlineGroupMap.get(i);
      if (groupInfo) {
        if (estimatedInlineGroups.has(groupInfo.indices[0])) continue;
        estimatedInlineGroups.add(groupInfo.indices[0]);
        let rowHeight = 0;
        for (const idx of groupInfo.indices) {
          const ge = entriesEst[idx];
          const gl = figLayoutEst.items[idx];
          if (!ge?.embed || !gl) continue;
          const wp = figureLayoutToWidthPt(gl.widthEm, stemSizePtEst);
          const cw = Math.min(wp, textWidth);
          const dims = ge.embed.scale(1);
          const aspect = dims && dims.height > 0 ? dims.height / dims.width : 1;
          const fh = cw * aspect;
          if (fh > rowHeight) rowHeight = fh;
        }
        h += rowHeight + 4;
      } else {
        const widthPt = figureLayoutToWidthPt(layoutItem.widthEm, stemSizePtEst);
        const clampedWidth = Math.min(widthPt, textWidth);
        const dims = entry.embed.scale(1);
        const aspect = dims && dims.height > 0 ? dims.height / dims.width : 1;
        h += clampedWidth * aspect + 4;
      }
    }
  }

  const remainingEntries = entriesEst.slice(inlineSkipEst);
  const remainingLayoutItems = figLayoutEst ? figLayoutEst.items.slice(inlineSkipEst) : [];
  const skippedKeysEst = new Set(
    (figLayoutEst ? figLayoutEst.items.slice(0, inlineSkipEst) : []).map((it) => it.assetKey),
  );

  const embedByKeyEst = new Map();
  for (const entry of remainingEntries) {
    if (entry?.embed) embedByKeyEst.set(String(entry.key || ''), entry);
  }
  if (figLayoutEst && remainingLayoutItems.length > 0 && embedByKeyEst.size > 0) {
    const groupedEst = new Set();
    for (const group of figLayoutEst.groups) {
      if (group.type !== 'horizontal') continue;
      const memberEntries = group.members
        .filter((key) => !skippedKeysEst.has(key))
        .map((key) => {
          const entry = embedByKeyEst.get(key);
          const item = remainingLayoutItems.find((it) => it.assetKey === key);
          return entry && item ? { entry, item } : null;
        })
        .filter(Boolean);
      if (memberEntries.length < 2) continue;
      memberEntries.forEach((e) => groupedEst.add(e.item.assetKey));
      let rowHeight = 0;
      for (const e of memberEntries) {
        const widthPt = figureLayoutToWidthPt(e.item.widthEm, stemSizePtEst);
        const clampedWidth = Math.min(widthPt, textWidth);
        const dims = e.entry.embed.scale(1);
        const aspect = dims && dims.height > 0 ? dims.height / dims.width : 1;
        const fh = clampedWidth * aspect;
        if (fh > rowHeight) rowHeight = fh;
      }
      h += rowHeight + 8;
    }
    for (const layoutItem of remainingLayoutItems) {
      if (groupedEst.has(layoutItem.assetKey)) continue;
      const entry = embedByKeyEst.get(layoutItem.assetKey);
      if (!entry?.embed) continue;
      const widthPt = figureLayoutToWidthPt(layoutItem.widthEm, stemSizePtEst);
      const clampedWidth = Math.min(widthPt, textWidth);
      const dims = entry.embed.scale(1);
      const aspect = dims && dims.height > 0 ? dims.height / dims.width : 1;
      h += clampedWidth * aspect + 8;
    }
  } else {
    const figures = resolveFigurePairEntries(question);
    if (figures.primary?.embed) {
      if (figures.secondary?.embed) {
        const gap = 8;
        const cellWidth = Math.max(24, (textWidth - gap) / 2);
        const leftBox = estimateFigureRenderBox(question, cellWidth, figures.primary);
        const rightBox = estimateFigureRenderBox(question, cellWidth, figures.secondary);
        const pairHeight = Math.max(leftBox?.height || 0, rightBox?.height || 0);
        h += pairHeight + 8;
      } else {
        const figureBox = estimateFigureRenderBox(question, textWidth, figures.primary);
        if (figureBox) h += figureBox.height + 8;
      }
    } else if (question.figure_refs.length > 0) {
      h += 40;
    }
  }
  if (question.choices.length > 0) {
    const choiceSpacing = Math.max(0, Number(layout.choiceSpacing || 0));
    const choiceLineHeight = Math.max(11, layout.lineHeight - 1);
    const estimateChoiceCellHeight = (c, maxWidth) => {
      const label = sanitizeText(c?.label || '') || '-';
      const choiceRaw = rawText(c?.text || '');
      const choiceLatex = pickChoiceMathLatex(question, choiceRaw);
      if (choiceLatex) {
        const fractionLike = isFractionLikeLatex(choiceLatex);
        const mathPad = fractionLike
          ? Math.max(4, Math.round(layout.choiceSize * 0.38))
          : 1;
        return Math.max(
          layout.lineHeight + mathPad,
          estimateMathBlockHeightPt(layout.choiceSize, false, choiceLatex) + mathPad,
        );
      }
      const row = `${label} ${sanitizeText(choiceRaw)}`.trim();
      const lines = wrapTextByWidth(
        row,
        fonts.regular,
        layout.choiceSize,
        Math.max(24, maxWidth),
      );
      return Math.max(choiceLineHeight, lines.length * choiceLineHeight);
    };
    const mode = resolveChoiceLayoutMode(question, question.choices, textWidth);
    if (mode === 'single') {
      const cellWidth = Math.max(24, (textWidth - 8 * 4) / 5);
      const rowHeight = question.choices.reduce(
        (acc, c) => Math.max(acc, estimateChoiceCellHeight(c, cellWidth)),
        choiceLineHeight,
      );
      h += rowHeight + choiceSpacing;
      return h + layout.questionGap;
    }
    if (mode === 'split_3_2') {
      const cellWidth = Math.max(24, (textWidth - 8 * 2) / 3);
      const topHeight = question.choices.slice(0, 3).reduce(
        (acc, c) => Math.max(acc, estimateChoiceCellHeight(c, cellWidth)),
        choiceLineHeight,
      );
      const bottomHeight = question.choices.slice(3).reduce(
        (acc, c) => Math.max(acc, estimateChoiceCellHeight(c, cellWidth)),
        choiceLineHeight,
      );
      h += topHeight + 6 + bottomHeight + choiceSpacing;
      return h + layout.questionGap;
    }
    const choiceIndent = Math.max(0, Number(layout.hangingIndent || 0));
    const choiceWidth = Math.max(24, textWidth - choiceIndent);
    for (const c of question.choices) {
      const choiceRaw = rawText(c?.text || '');
      const choiceLatex = pickChoiceMathLatex(question, choiceRaw);
      if (choiceLatex) {
        const fractionLike = isFractionLikeLatex(choiceLatex);
        const mathPad = fractionLike
          ? Math.max(4, Math.round(layout.choiceSize * 0.38))
          : 1;
        h += estimateMathBlockHeightPt(layout.choiceSize, false, choiceLatex) + mathPad;
      } else {
        const row = `${sanitizeText(c?.label || '')} ${sanitizeText(choiceRaw)}`.trim();
        const choiceLines = wrapTextByWidth(
          row,
          fonts.regular,
          layout.choiceSize,
          choiceWidth,
        );
        h += choiceLines.length * (layout.lineHeight - 1);
      }
      h += choiceSpacing;
    }
  }
  return h + layout.questionGap;
}

function drawHeader({
  page,
  fonts,
  profile,
  layout,
  paperLabel,
  pageNumber,
}) {
  const size = page.getSize();
  const topY = size.height - layout.margin + 12;
  page.drawText(`${layout.title} \u00B7 ${paperLabel}`, {
    x: layout.margin,
    y: topY,
    size: 11,
    font: fonts.bold,
    color: rgb(0.12, 0.12, 0.12),
  });
  page.drawText(`p.${pageNumber}`, {
    x: size.width - layout.margin - 30,
    y: topY,
    size: 10,
    font: fonts.regular,
    color: rgb(0.35, 0.35, 0.35),
  });
  if (profile === 'mock') {
    page.drawText('\uC804\uAD6D\uC5F0\uD569\uD559\uB825\uD3C9\uAC00 \uD615\uC2DD \uCC38\uACE0', {
      x: layout.margin,
      y: topY - 14,
      size: 9,
      font: fonts.regular,
      color: rgb(0.4, 0.4, 0.4),
    });
  } else if (profile === 'csat') {
    page.drawText('\uC218\uB2A5 \uC2DC\uD5D8\uC9C0 \uB808\uC774\uC544\uC6C3', {
      x: layout.margin,
      y: topY - 14,
      size: 9,
      font: fonts.regular,
      color: rgb(0.4, 0.4, 0.4),
    });
  } else {
    page.drawText('\uD559\uAD50 \uB0B4\uC2E0\uD615 \uB808\uC774\uC544\uC6C3', {
      x: layout.margin,
      y: topY - 14,
      size: 9,
      font: fonts.regular,
      color: rgb(0.4, 0.4, 0.4),
    });
  }
}

async function drawQuestion({
  page,
  y,
  question,
  fonts,
  layout,
  contentWidth,
  startX,
  mathContext,
}) {
  let curY = y;
  const numberLaneWidth = Math.max(0, Number(layout.numberLaneWidth || 0));
  const numberGap = Math.max(0, Number(layout.numberGap || 0));
  const textStartX = startX + numberLaneWidth + numberGap;
  const textWidth = Math.max(36, contentWidth - numberLaneWidth - numberGap);
  const numberLabel = `${question.question_number || '?'}`;
  page.drawText(numberLabel, {
    x: startX,
    y: curY,
    size: layout.stemSize,
    font: fonts.bold,
    color: rgb(0.1, 0.1, 0.1),
  });
  curY -= layout.lineHeight;

  const stemSizePt = Number(layout.stemSize || 11);
  const allEntries = normalizeFigureEntriesForQuestion(question);
  const figLayout = resolveFigureLayout(question, stemSizePt);

  const stemFigureEmbeds = [];
  const stemMarkerCount = ((question?.stem || '').match(FIGURE_MARKER_RE_PDF) || []).length;
  FIGURE_MARKER_RE_PDF.lastIndex = 0;
  if (stemMarkerCount > 0 && allEntries.length > 0 && figLayout && figLayout.items.length > 0) {
    for (let i = 0; i < stemMarkerCount && i < allEntries.length; i++) {
      const entry = allEntries[i];
      const layoutItem = figLayout.items[i];
      const widthPt = layoutItem
        ? figureLayoutToWidthPt(layoutItem.widthEm, stemSizePt)
        : stemSizePt * 15;
      stemFigureEmbeds.push({
        embed: entry?.embed || null,
        widthPt,
        assetKey: layoutItem?.assetKey || '',
        anchor: layoutItem?.anchor || 'center',
      });
    }
  }

  const stemResult = await drawStemBlocks({
    page,
    question,
    fonts,
    layout,
    textStartX,
    textWidth,
    y: curY,
    mathContext,
    figureEmbeds: stemFigureEmbeds,
    figureLayout: figLayout,
  });
  curY = stemResult.curY;
  const inlineSkipCount = stemResult.inlineFigureCount || 0;

  if (question.figure_refs.length > 0 || question.figure_embed || question.figure_embeds) {
    const entries = allEntries.slice(inlineSkipCount);
    const embedByKey = new Map();
    for (const entry of entries) {
      if (entry?.embed) embedByKey.set(String(entry.key || ''), entry);
    }

    const remainingLayoutItems = figLayout ? figLayout.items.slice(inlineSkipCount) : [];
    const skippedKeys = new Set(
      (figLayout ? figLayout.items.slice(0, inlineSkipCount) : []).map((it) => it.assetKey),
    );

    if (figLayout && remainingLayoutItems.length > 0 && embedByKey.size > 0) {
      const grouped = new Set();
      for (const group of figLayout.groups) {
        if (group.type !== 'horizontal') continue;
        const memberEntries = group.members
          .filter((key) => !skippedKeys.has(key))
          .map((key) => {
            const entry = embedByKey.get(key);
            const item = remainingLayoutItems.find((it) => it.assetKey === key);
            return entry && item ? { entry, item } : null;
          })
          .filter(Boolean);
        if (memberEntries.length < 2) continue;
        memberEntries.forEach((e) => grouped.add(e.item.assetKey));
        const gapPt = (group.gap || 0.5) * stemSizePt;
        const totalGap = gapPt * (memberEntries.length - 1);
        let rowHeight = 0;
        const boxes = memberEntries.map((e) => {
          const widthPt = figureLayoutToWidthPt(e.item.widthEm, stemSizePt);
          const clampedWidth = Math.min(widthPt, textWidth);
          const dims = e.entry.embed.scale(1);
          const aspect = dims && dims.height > 0 ? dims.height / dims.width : 1;
          const height = clampedWidth * aspect;
          if (height > rowHeight) rowHeight = height;
          return { entry: e.entry, item: e.item, width: clampedWidth, height };
        });
        const totalWidth = boxes.reduce((s, b) => s + b.width, 0) + totalGap;
        let offsetX = textStartX;
        if (totalWidth < textWidth) offsetX += (textWidth - totalWidth) / 2;
        for (let i = 0; i < boxes.length; i++) {
          const b = boxes[i];
          page.drawImage(b.entry.embed, {
            x: offsetX,
            y: curY - b.height,
            width: b.width,
            height: b.height,
          });
          offsetX += b.width + gapPt;
        }
        curY -= rowHeight + 8;
      }

      for (const layoutItem of remainingLayoutItems) {
        if (grouped.has(layoutItem.assetKey)) continue;
        const entry = embedByKey.get(layoutItem.assetKey);
        if (!entry?.embed) continue;
        const widthPt = figureLayoutToWidthPt(layoutItem.widthEm, stemSizePt);
        const clampedWidth = Math.min(widthPt, textWidth);
        const dims = entry.embed.scale(1);
        const aspect = dims && dims.height > 0 ? dims.height / dims.width : 1;
        const height = clampedWidth * aspect;
        let drawX = textStartX;
        if (layoutItem.anchor === 'center') drawX += (textWidth - clampedWidth) / 2;
        else if (layoutItem.anchor === 'right') drawX += textWidth - clampedWidth;
        page.drawImage(entry.embed, {
          x: drawX,
          y: curY - height,
          width: clampedWidth,
          height,
        });
        curY -= height + 8;
      }
    } else {
      const figures = resolveFigurePairEntries(question);
      if (figures.primary?.embed) {
        if (figures.secondary?.embed) {
          const gap = 8;
          const cellWidth = Math.max(24, (textWidth - gap) / 2);
          const leftBox = estimateFigureRenderBox(question, cellWidth, figures.primary);
          const rightBox = estimateFigureRenderBox(question, cellWidth, figures.secondary);
          if (leftBox && rightBox) {
            const rowHeight = Math.max(leftBox.height, rightBox.height);
            const leftX = textStartX + (cellWidth - leftBox.width) / 2;
            const rightX = textStartX + cellWidth + gap + (cellWidth - rightBox.width) / 2;
            page.drawImage(figures.primary.embed, {
              x: leftX,
              y: curY - leftBox.height,
              width: leftBox.width,
              height: leftBox.height,
            });
            page.drawImage(figures.secondary.embed, {
              x: rightX,
              y: curY - rightBox.height,
              width: rightBox.width,
              height: rightBox.height,
            });
            curY -= rowHeight + 8;
          } else {
            const figureBox = estimateFigureRenderBox(question, textWidth, figures.primary);
            if (figureBox) {
              const drawX = textStartX + (textWidth - figureBox.width) / 2;
              const drawY = curY - figureBox.height;
              page.drawImage(figures.primary.embed, {
                x: drawX,
                y: drawY,
                width: figureBox.width,
                height: figureBox.height,
              });
              curY -= figureBox.height + 8;
            }
          }
        } else {
          const figureBox = estimateFigureRenderBox(question, textWidth, figures.primary);
          if (figureBox) {
            const drawX = textStartX + (textWidth - figureBox.width) / 2;
            const drawY = curY - figureBox.height;
            page.drawImage(figures.primary.embed, {
              x: drawX,
              y: drawY,
              width: figureBox.width,
              height: figureBox.height,
            });
            curY -= figureBox.height + 8;
          }
        }
      } else if (question.figure_refs.length > 0) {
        page.drawRectangle({
          x: textStartX,
          y: curY - 38,
          width: textWidth,
          height: 36,
          borderColor: rgb(0.72, 0.72, 0.72),
          borderWidth: 0.8,
          color: rgb(0.97, 0.97, 0.97),
        });
        curY -= 42;
      }
    }
  }

  if (question.choices.length > 0) {
    const choiceSpacing = Math.max(0, Number(layout.choiceSpacing || 0));
    const choices = question.choices;
    const mode = resolveChoiceLayoutMode(question, choices, textWidth);
    let usedRowLayout = false;
    if (mode === 'single' || mode === 'split_3_2') {
      const rowDefs = mode === 'single'
        ? [{ items: choices, columns: 5, rowGap: 0 }]
        : [
            { items: choices.slice(0, 3), columns: 3, rowGap: 6 },
            { items: choices.slice(3), columns: 3, rowGap: 0 },
          ];
      let canDrawRows = true;
      const preparedRows = [];
      for (const rowDef of rowDefs) {
        const columns = rowDef.columns;
        const gap = 8;
        const cellWidth = Math.max(24, (textWidth - gap * (columns - 1)) / columns);
        const descriptors = [];
        for (const c of rowDef.items) {
          const desc = await buildChoiceDescriptor({
            question,
            choice: c,
            fonts,
            layout,
            maxWidth: cellWidth,
            mathContext,
          });
          if (!desc.singleLine) {
            canDrawRows = false;
            break;
          }
          descriptors.push(desc);
        }
        if (!canDrawRows) break;
        const rowHeight = descriptors.reduce(
          (acc, d) => Math.max(acc, d.height),
          Math.max(11, layout.lineHeight - 1),
        );
        preparedRows.push({
          descriptors,
          columns,
          gap,
          cellWidth,
          rowHeight,
          rowGap: rowDef.rowGap,
        });
      }
      if (canDrawRows && preparedRows.length > 0) {
        usedRowLayout = true;
        for (let r = 0; r < preparedRows.length; r += 1) {
          const row = preparedRows[r];
          for (let i = 0; i < row.columns; i += 1) {
            if (i >= row.descriptors.length) continue;
            const x = textStartX + i * (row.cellWidth + row.gap);
            drawChoiceDescriptor({
              page,
              descriptor: row.descriptors[i],
              x,
              y: curY,
              fonts,
              layout,
            });
          }
          curY -= row.rowHeight;
          if (r < preparedRows.length - 1) {
            curY -= row.rowGap;
          }
        }
        curY -= choiceSpacing;
      }
    }
    if (!usedRowLayout) {
      const choiceIndent = Math.max(0, Number(layout.hangingIndent || 0));
      const choiceWidth = Math.max(24, textWidth - choiceIndent);
      for (const c of choices) {
        const desc = await buildChoiceDescriptor({
          question,
          choice: c,
          fonts,
          layout,
          maxWidth: choiceWidth,
          mathContext,
        });
        drawChoiceDescriptor({
          page,
          descriptor: desc,
          x: textStartX,
          y: curY,
          fonts,
          layout,
        });
        curY -= desc.height;
        curY -= choiceSpacing;
      }
    }
  }

  return curY - layout.questionGap;
}

function drawAnswerSheet({ pdfDoc, fonts, layout, questions, paperLabel }) {
  const page = pdfDoc.addPage([
    PAPER_SIZE[paperLabel].width,
    PAPER_SIZE[paperLabel].height,
  ]);
  drawHeader({
    page,
    fonts,
    profile: 'naesin',
    layout,
    paperLabel,
    pageNumber: pdfDoc.getPageCount(),
  });
  const size = page.getSize();
  const width = size.width - layout.margin * 2;
  let y = size.height - layout.margin - layout.headerHeight;
  page.drawText('\uBE60\uB978 \uC815\uB2F5', {
    x: layout.margin,
    y,
    size: 15,
    font: fonts.bold,
    color: rgb(0.1, 0.1, 0.1),
  });
  y -= 22;
  const colCount = 3;
  const colWidth = width / colCount;
  const rowHeight = 18;
  for (let i = 0; i < questions.length; i++) {
    const row = Math.floor(i / colCount);
    const col = i % colCount;
    const x = layout.margin + col * colWidth;
    const yy = y - row * rowHeight;
    if (yy < layout.margin) break;
    const answer = sanitizeAnswerText(questions[i].export_answer || '');
    const answerText = answer ? compact(answer, 20) : '(\uBBF8\uAE30\uC7AC)';
    const label = `${questions[i].question_number || '?'}  ${answerText}`;
    page.drawText(label, {
      x,
      y: yy,
      size: 10,
      font: fonts.regular,
      color: rgb(0.18, 0.18, 0.18),
    });
  }
}

function drawExplanationPage({ pdfDoc, fonts, layout, questions, paperLabel }) {
  const page = pdfDoc.addPage([
    PAPER_SIZE[paperLabel].width,
    PAPER_SIZE[paperLabel].height,
  ]);
  drawHeader({
    page,
    fonts,
    profile: 'naesin',
    layout,
    paperLabel,
    pageNumber: pdfDoc.getPageCount(),
  });
  const size = page.getSize();
  const contentWidth = size.width - layout.margin * 2;
  let y = size.height - layout.margin - layout.headerHeight;
  page.drawText('\uD574\uC124/\uAC80\uD1A0 \uBA54\uBAA8', {
    x: layout.margin,
    y,
    size: 15,
    font: fonts.bold,
    color: rgb(0.1, 0.1, 0.1),
  });
  y -= 22;
  const numberLaneWidth = Math.max(20, Number(layout.numberLaneWidth || 0));
  const numberGap = Math.max(0, Number(layout.numberGap || 0));
  const textWidth = Math.max(36, contentWidth - numberLaneWidth - numberGap);
  for (const q of questions) {
    const note = sanitizeText(q.reviewer_notes || '');
    const merged =
      note.length === 0
        ? '(\uAC80\uD1A0 \uBA54\uBAA8 \uC5C6\uC74C)'
        : note;
    const numberText = `${q.question_number || '?'}`;
    const lines = wrapTextByWidth(merged, fonts.regular, 10.5, textWidth);
    const needed = Math.max(14, lines.length * 14) + 8;
    if (y - needed < layout.margin) break;
    page.drawText(numberText, {
      x: layout.margin,
      y,
      size: 10.5,
      font: fonts.regular,
      color: rgb(0.15, 0.15, 0.15),
    });
    for (const line of lines) {
      page.drawText(line, {
        x: layout.margin + numberLaneWidth + numberGap,
        y,
        size: 10.5,
        font: fonts.regular,
        color: rgb(0.15, 0.15, 0.15),
      });
      y -= 14;
    }
    y -= 8;
  }
}

async function fetchQuestionsForJob(job, renderConfig) {
  const academyId = String(job.academy_id || '').trim();
  const documentId = String(job.document_id || '').trim();
  const selectedIds = Array.isArray(renderConfig?.selectedQuestionIdsOrdered)
    ? renderConfig.selectedQuestionIdsOrdered
    : (Array.isArray(job.selected_question_ids)
      ? job.selected_question_ids.map((e) => String(e).trim()).filter((e) => e.length > 0)
      : []);
  const options = job.options && typeof job.options === 'object' ? job.options : {};
  const sourceDocumentIds = Array.isArray(options.sourceDocumentIds)
    ? options.sourceDocumentIds.map((e) => String(e).trim()).filter((e) => e.length > 0)
    : [];

  let query = supa
    .from('pb_questions')
    .select(
      'id,document_id,question_number,question_type,stem,choices,allow_objective,allow_subjective,objective_choices,objective_answer_key,subjective_answer,objective_generated,figure_refs,equations,confidence,flags,reviewer_notes,source_page,source_order,meta',
    )
    .eq('academy_id', academyId);

  const selectedIdsSet = new Set(selectedIds);
  if (selectedIdsSet.size > 0) {
    query = query.in('id', selectedIds);
  } else {
    query = query.eq('document_id', documentId).eq('is_checked', true);
  }

  const { data, error } = await query
    .order('source_page', { ascending: true })
    .order('source_order', { ascending: true });
  if (error) {
    throw new Error(`question_fetch_failed:${error.message}`);
  }
  const rows = (data || []).map((row) => ({
    id: String(row.id || ''),
    document_id: String(row.document_id || ''),
    question_number: String(row.question_number || ''),
    question_type: String(row.question_type || ''),
    stem: String(row.stem || ''),
    choices: normalizeChoiceRows(row.choices),
    allow_objective: row.allow_objective !== false,
    allow_subjective: row.allow_subjective !== false,
    objective_choices: normalizeChoiceRows(row.objective_choices),
    objective_answer_key: sanitizeAnswerText(row.objective_answer_key || ''),
    subjective_answer: sanitizeAnswerText(row.subjective_answer || ''),
    objective_generated: row.objective_generated === true,
    figure_refs: Array.isArray(row.figure_refs) ? row.figure_refs : [],
    equations: Array.isArray(row.equations) ? row.equations : [],
    confidence: Number(row.confidence || 0),
    flags: Array.isArray(row.flags) ? row.flags : [],
    reviewer_notes: String(row.reviewer_notes || ''),
    source_page: Number(row.source_page || 0),
    source_order: Number(row.source_order || 0),
    meta: row.meta && typeof row.meta === 'object' ? row.meta : {},
  }));

  if (selectedIdsSet.size > 0) {
    const selectedOrder = new Map(selectedIds.map((id, idx) => [id, idx]));
    const docOrder = new Map(sourceDocumentIds.map((id, idx) => [id, idx]));
    rows.sort((a, b) => {
      const ai = selectedOrder.has(a.id) ? selectedOrder.get(a.id) : Number.MAX_SAFE_INTEGER;
      const bi = selectedOrder.has(b.id) ? selectedOrder.get(b.id) : Number.MAX_SAFE_INTEGER;
      if (ai !== bi) return ai - bi;
      const ad = docOrder.has(a.document_id) ? docOrder.get(a.document_id) : Number.MAX_SAFE_INTEGER;
      const bd = docOrder.has(b.document_id) ? docOrder.get(b.document_id) : Number.MAX_SAFE_INTEGER;
      if (ad !== bd) return ad - bd;
      if (a.source_page !== b.source_page) return a.source_page - b.source_page;
      return a.source_order - b.source_order;
    });
  }

  return rows;
}

async function renderPdf(job, questions, renderConfig) {
  const profile = normalizeProfile(
    renderConfig?.templateProfile || job.template_profile,
  );
  const paper = normalizePaper(renderConfig?.paperSize || job.paper_size);
  const baseLayout = PROFILE_LAYOUT[profile] || PROFILE_LAYOUT.naesin;
  const tuning = normalizeLayoutTuning(renderConfig?.layoutTuning, {});
  const layout = {
    ...baseLayout,
    margin: tuning.pageMargin,
    lineHeight: tuning.lineHeight,
    questionGap: tuning.questionGap,
    numberLaneWidth: tuning.numberLaneWidth,
    numberGap: tuning.numberGap,
    hangingIndent: tuning.hangingIndent,
    choiceSpacing: tuning.choiceSpacing,
  };
  const configuredFontSize = normalizeNumeric(
    renderConfig?.font?.size,
    baseLayout.stemSize,
    8,
    28,
  );
  layout.stemSize = configuredFontSize;
  layout.choiceSize = Math.max(8, configuredFontSize - 0.6);

  const fallbackQuestionMode = normalizeQuestionMode(renderConfig?.questionMode);
  const modeApplied = applyQuestionModesForExport(
    questions,
    renderConfig?.questionModeByQuestionId || {},
    fallbackQuestionMode,
  );
  const exportQuestions = modeApplied.questions;
  const questionMode = fallbackQuestionMode;
  const layoutColumns = normalizeLayoutColumns(renderConfig?.layoutColumns || 1);
  const maxQuestionsPerPage = normalizeMaxQuestionsPerPage(
    renderConfig?.maxQuestionsPerPage || '',
    layoutColumns,
  );

  const requestedFontFamilyHtml = normalizeFontFamily(renderConfig?.font?.family || '');
  const fontPathsHtml = resolveRequestedFontPaths(requestedFontFamilyHtml);
  const repoQnumFont = repoAssetPath(
    'apps', 'yggdrasill', 'assets', 'fonts', 'chosun', 'ChosunNm.ttf',
  );
  return renderPdfWithHtmlEngine({
    questions: modeApplied.questions,
    renderConfig,
    profile,
    paper,
    modeByQuestionId: modeApplied.modeByQuestionId,
    questionMode: fallbackQuestionMode,
    layoutColumns,
    maxQuestionsPerPage,
    renderConfigVersion:
      renderConfig?.renderConfigVersion || RENDER_CONFIG_VERSION,
    fontFamilyRequested: fontPathsHtml.requestedFamily || requestedFontFamilyHtml,
    fontFamilyResolved: fontPathsHtml.resolvedFamily || requestedFontFamilyHtml,
    fontRegularPath: fontPathsHtml.regularPath || '',
    fontBoldPath: fontPathsHtml.boldPath || '',
    qnumFontPath: pickExistingPath([FONT_PATH_QNUM, repoQnumFont]),
    subjectFontPath: resolveSubjectFontPath(),
    fontSize: configuredFontSize,
    baseLayout,
    supabaseClient: supa,
  });

  const pdfDoc = await PDFDocument.create();
  const requestedFontFamily = normalizeFontFamily(renderConfig?.font?.family || '');
  const fonts = await loadFonts(pdfDoc, {
    requestedFamily: requestedFontFamily,
  });
  const mathContext = createMathRenderContext(pdfDoc);
  const pageSize = PAPER_SIZE[paper];
  const pageInnerWidth = Math.max(120, pageSize.width - layout.margin * 2);
  const columnGap = layoutColumns === 2 ? tuning.columnGap : 0;
  const contentWidth =
    layoutColumns === 2 ? (pageInnerWidth - columnGap) / 2 : pageInnerWidth;
  const pageBottom = layout.margin;
  const pageTop = pageSize.height - layout.margin - layout.headerHeight;
  const figureHydration = await hydrateApprovedFigureEmbeds(
    pdfDoc,
    exportQuestions,
    {
      job,
      contentWidthPt: contentWidth,
      figureQuality: renderConfig?.figureQuality,
    },
  );

  let page = pdfDoc.addPage([pageSize.width, pageSize.height]);
  let pageNum = 1;
  let questionCountOnPage = 0;
  let currentColumn = 0;
  const leftColumnQuota =
    layoutColumns === 2 ? Math.ceil(maxQuestionsPerPage / 2) : maxQuestionsPerPage;
  const rightColumnQuota =
    layoutColumns === 2 ? Math.max(0, maxQuestionsPerPage - leftColumnQuota) : 0;
  let leftColumnCountOnPage = 0;
  let rightColumnCountOnPage = 0;
  let startX = layout.margin;
  drawHeader({
    page,
    fonts,
    profile,
    layout,
    paperLabel: paper,
    pageNumber: pageNum,
  });
  let y = pageTop;

  const beginNewPage = () => {
    page = pdfDoc.addPage([pageSize.width, pageSize.height]);
    pageNum += 1;
    questionCountOnPage = 0;
    currentColumn = 0;
    leftColumnCountOnPage = 0;
    rightColumnCountOnPage = 0;
    startX = layout.margin;
    y = pageTop;
    drawHeader({
      page,
      fonts,
      profile,
      layout,
      paperLabel: paper,
      pageNumber: pageNum,
    });
  };

  const moveToNextColumnOrPage = () => {
    if (layoutColumns === 2 && currentColumn === 0 && rightColumnQuota > 0) {
      currentColumn = 1;
      startX = layout.margin + contentWidth + columnGap;
      y = pageTop;
      return;
    }
    beginNewPage();
  };

  for (const q of exportQuestions) {
    if (questionCountOnPage >= maxQuestionsPerPage) {
      beginNewPage();
    }
    if (layoutColumns === 2) {
      if (currentColumn === 0 && leftColumnCountOnPage >= leftColumnQuota) {
        moveToNextColumnOrPage();
      } else if (currentColumn === 1 && rightColumnCountOnPage >= rightColumnQuota) {
        beginNewPage();
      }
    }
    const estimated = estimateQuestionHeight(
      q,
      fonts,
      layout,
      contentWidth,
      startX,
    );
    if (y - estimated < pageBottom) {
      moveToNextColumnOrPage();
      if (y - estimated < pageBottom && currentColumn === 1) {
        beginNewPage();
      }
    }
    y = await drawQuestion({
      page,
      y,
      question: q,
      fonts,
      layout,
      contentWidth,
      startX,
      mathContext,
    });
    questionCountOnPage += 1;
    if (layoutColumns === 2) {
      if (currentColumn === 0) {
        leftColumnCountOnPage += 1;
        if (leftColumnCountOnPage >= leftColumnQuota && rightColumnQuota > 0) {
          currentColumn = 1;
          startX = layout.margin + contentWidth + columnGap;
          y = pageTop;
        }
      } else {
        rightColumnCountOnPage += 1;
      }
    }
    if (y < pageBottom) {
      moveToNextColumnOrPage();
    }
  }

  if (renderConfig?.includeAnswerSheet === true) {
    drawAnswerSheet({
      pdfDoc,
      fonts,
      layout,
      questions: exportQuestions,
      paperLabel: paper,
    });
  }
  if (renderConfig?.includeExplanation === true) {
    drawExplanationPage({
      pdfDoc,
      fonts,
      layout,
      questions: exportQuestions,
      paperLabel: paper,
    });
  }

  const bytes = await pdfDoc.save();
  return {
    bytes,
    pageCount: pdfDoc.getPageCount(),
    profile,
    paper,
    questionMode,
    modeByQuestionId: modeApplied.modeByQuestionId,
    layoutColumns,
    maxQuestionsPerPage,
    renderConfigVersion:
      renderConfig?.renderConfigVersion || RENDER_CONFIG_VERSION,
    fontFamily: fonts.resolvedFamily || requestedFontFamily,
    fontFamilyRequested: fonts.requestedFamily || requestedFontFamily,
    fontRegularPath: fonts.regularPath || '',
    fontBoldPath: fonts.boldPath || '',
    fontSize: configuredFontSize,
    mathRequestedCount: Number(mathContext?.stats?.requested || 0),
    mathRenderedCount: Number(mathContext?.stats?.rendered || 0),
    mathFailedCount: Number(mathContext?.stats?.failed || 0),
    mathCacheHitCount: Number(mathContext?.stats?.cacheHit || 0),
    figureHydration,
    exportQuestions,
  };
}

async function processOneJob(job) {
  const renderConfig = buildRenderConfigFromJob(job);
  const renderHash = computeRenderHash(renderConfig);
  const questions = await fetchQuestionsForJob(job, renderConfig);
  if (!questions.length) {
    throw new Error('selected_questions_empty');
  }
  const rendered = await renderPdf(job, questions, renderConfig);
  const exportQuestions = Array.isArray(rendered.exportQuestions)
    ? rendered.exportQuestions
    : questions;
  const figureAppliedCount = exportQuestions.filter(
    (q) => Boolean(q.figure_embed) || (Array.isArray(q.figure_data_urls) && q.figure_data_urls.length > 0),
  ).length;
  const figureDegradedCount = Number(rendered.figureHydration?.degradedCount || 0);
  const figureResampledCount = Number(rendered.figureHydration?.resampledCount || 0);
  const regenerationQueuedCount = Number(
    rendered.figureHydration?.regenerationQueuedCount || 0,
  );
  const effectiveDpis = Object.values(
    rendered.figureHydration?.effectiveDpiByQuestionId || {},
  )
    .map((v) => Number(v || 0))
    .filter((v) => Number.isFinite(v) && v > 0);
  const minEffectiveDpi = effectiveDpis.length > 0 ? Math.min(...effectiveDpis) : 0;
  const sourceDocumentCount = new Set(
    exportQuestions
      .map((q) => String(q.document_id || '').trim())
      .filter((id) => id.length > 0),
  ).size;
  const objectPath = `${job.academy_id}/${job.id}.pdf`;

  const { error: uploadErr } = await supa.storage
    .from('problem-exports')
    .upload(objectPath, rendered.bytes, {
      contentType: 'application/pdf',
      upsert: true,
    });
  if (uploadErr) {
    throw new Error(`export_upload_failed:${uploadErr.message}`);
  }

  const { data: signed } = await supa.storage
    .from('problem-exports')
    .createSignedUrl(objectPath, 60 * 60 * 24 * 7);
  const outputUrl = String(signed?.signedUrl || '');
  const nowIso = new Date().toISOString();

  const { error: updErr } = await supa
    .from('pb_exports')
    .update({
      status: 'completed',
      output_storage_bucket: 'problem-exports',
      output_storage_path: objectPath,
      output_url: outputUrl,
      page_count: rendered.pageCount,
      render_hash: renderHash,
      preview_only:
        job.preview_only === true || job?.options?.previewOnly === true,
      error_code: '',
      error_message: '',
      result_summary: {
        profile: rendered.profile,
        paper: rendered.paper,
        questionMode: rendered.questionMode || 'original',
        modeByQuestionId: rendered.modeByQuestionId || {},
        layoutColumns: rendered.layoutColumns || 1,
        maxQuestionsPerPage: rendered.maxQuestionsPerPage || 0,
        pageColumnQuestionCounts: rendered.pageColumnQuestionCounts || [],
        columnLabelAnchors: rendered.columnLabelAnchors || [],
        renderConfigVersion:
          rendered.renderConfigVersion || RENDER_CONFIG_VERSION,
        renderHash,
        questionCount: exportQuestions.length,
        figureAppliedCount,
        figureDegradedCount,
        figureResampledCount,
        regenerationQueuedCount,
        minEffectiveDpi,
        sourceDocumentCount,
        fontFamilyRequested: rendered.fontFamilyRequested || '',
        fontFamilyResolved: rendered.fontFamily || '',
        fontRegularPath: rendered.fontRegularPath || '',
        fontBoldPath: rendered.fontBoldPath || '',
        fontSize: rendered.fontSize || 0,
        mathRequestedCount: rendered.mathRequestedCount || 0,
        mathRenderedCount: rendered.mathRenderedCount || 0,
        mathFailedCount: rendered.mathFailedCount || 0,
        mathCacheHitCount: rendered.mathCacheHitCount || 0,
      },
      finished_at: nowIso,
      updated_at: nowIso,
    })
    .eq('id', job.id);
  if (updErr && /render_hash|preview_only/i.test(String(updErr.message || ''))) {
    const { error: fallbackUpdErr } = await supa
      .from('pb_exports')
      .update({
        status: 'completed',
        output_storage_bucket: 'problem-exports',
        output_storage_path: objectPath,
        output_url: outputUrl,
        page_count: rendered.pageCount,
        error_code: '',
        error_message: '',
        result_summary: {
          profile: rendered.profile,
          paper: rendered.paper,
          questionMode: rendered.questionMode || 'original',
          modeByQuestionId: rendered.modeByQuestionId || {},
          layoutColumns: rendered.layoutColumns || 1,
          maxQuestionsPerPage: rendered.maxQuestionsPerPage || 0,
          pageColumnQuestionCounts: rendered.pageColumnQuestionCounts || [],
          columnLabelAnchors: rendered.columnLabelAnchors || [],
          renderConfigVersion:
            rendered.renderConfigVersion || RENDER_CONFIG_VERSION,
          renderHash,
          questionCount: exportQuestions.length,
          figureAppliedCount,
          figureDegradedCount,
          figureResampledCount,
          regenerationQueuedCount,
          minEffectiveDpi,
          sourceDocumentCount,
          fontFamilyRequested: rendered.fontFamilyRequested || '',
          fontFamilyResolved: rendered.fontFamily || '',
          fontRegularPath: rendered.fontRegularPath || '',
          fontBoldPath: rendered.fontBoldPath || '',
          fontSize: rendered.fontSize || 0,
          mathRequestedCount: rendered.mathRequestedCount || 0,
          mathRenderedCount: rendered.mathRenderedCount || 0,
          mathFailedCount: rendered.mathFailedCount || 0,
          mathCacheHitCount: rendered.mathCacheHitCount || 0,
        },
        finished_at: nowIso,
        updated_at: nowIso,
      })
      .eq('id', job.id);
    if (fallbackUpdErr) {
      throw new Error(`export_job_update_failed:${fallbackUpdErr.message}`);
    }
  } else if (updErr) {
    throw new Error(`export_job_update_failed:${updErr.message}`);
  }

  return {
    pageCount: rendered.pageCount,
    questionCount: exportQuestions.length,
    figureAppliedCount,
    figureDegradedCount,
    minEffectiveDpi,
    renderHash,
    renderConfigVersion:
      rendered.renderConfigVersion || RENDER_CONFIG_VERSION,
    fontFamilyRequested: rendered.fontFamilyRequested || '',
    fontFamilyResolved: rendered.fontFamily || '',
    mathRequestedCount: rendered.mathRequestedCount || 0,
    mathRenderedCount: rendered.mathRenderedCount || 0,
    mathFailedCount: rendered.mathFailedCount || 0,
    outputPath: objectPath,
  };
}

async function processBatch() {
  const { data: queue, error } = await supa
    .from('pb_exports')
    .select('*')
    .eq('status', 'queued')
    .order('created_at', { ascending: true })
    .limit(BATCH_SIZE);
  if (error) {
    throw new Error(`export_queue_fetch_failed:${error.message}`);
  }
  if (!queue || queue.length === 0) {
    return { processed: 0, success: 0, failed: 0 };
  }

  const summary = { processed: 0, success: 0, failed: 0 };
  for (const row of queue) {
    summary.processed += 1;
    let locked = null;
    try {
      locked = await lockQueuedJob(row);
      if (!locked) continue;
      const result = await processOneJob(locked);
      summary.success += 1;
      console.log(
        '[pb-export-worker] done',
        JSON.stringify({
          jobId: locked.id,
          questions: result.questionCount,
          pages: result.pageCount,
          figureApplied: result.figureAppliedCount,
          figureDegraded: result.figureDegradedCount,
          minEffectiveDpi: result.minEffectiveDpi,
          renderHash: result.renderHash,
          renderConfigVersion: result.renderConfigVersion,
          fontFamilyRequested: result.fontFamilyRequested,
          fontFamilyResolved: result.fontFamilyResolved,
          mathRequested: result.mathRequestedCount,
          mathRendered: result.mathRenderedCount,
          mathFailed: result.mathFailedCount,
          outputPath: result.outputPath,
        }),
      );
    } catch (err) {
      summary.failed += 1;
      console.error(
        '[pb-export-worker] fail',
        JSON.stringify({
          jobId: locked?.id || row.id,
          errorCode: toErrorCode(err),
          message: compact(err?.message || err),
        }),
      );
      await markFailed(locked?.id || row.id, err);
    }
  }
  return summary;
}

async function main() {
  console.log(
    '[pb-export-worker] start',
    JSON.stringify({
      worker: WORKER_NAME,
      intervalMs: WORKER_INTERVAL_MS,
      batchSize: BATCH_SIZE,
      once: PROCESS_ONCE,
      rendererVersion: RENDER_CONFIG_VERSION,
      mathEngine: 'html-mathjax-svg-chrome',
    }),
  );
  while (true) {
    try {
      const summary = await processBatch();
      if (summary.processed > 0) {
        console.log('[pb-export-worker] batch', JSON.stringify(summary));
      }
      if (PROCESS_ONCE) break;
      await sleep(WORKER_INTERVAL_MS);
    } catch (err) {
      console.error(
        '[pb-export-worker] batch_error',
        compact(err?.message || err),
      );
      if (PROCESS_ONCE) break;
      await sleep(WORKER_INTERVAL_MS);
    }
  }
  console.log('[pb-export-worker] exit');
}

export {
  buildRenderConfigFromJob,
  computeRenderHash,
  normalizeLayoutTuning,
  normalizeFigureQuality,
  applyQuestionModeForQuestion,
  applyQuestionModesForExport,
  normalizeQuestionModeSelection,
  normalizeQuestionMode,
};

if (IS_DIRECT_RUN) {
  main().catch((err) => {
    console.error('[pb-export-worker] fatal', compact(err?.message || err));
    process.exit(1);
  });
}


