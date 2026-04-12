const STRUCTURAL_MARKER_REGEX = /\[(문단|박스시작|박스끝)\]/g;

export function escapeHtml(value) {
  return String(value || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

export function normalizeWhitespace(value) {
  return String(value ?? '').replace(/\s+/g, ' ').trim();
}

export function stripStructuralMarkers(value) {
  return String(value || '')
    .replace(STRUCTURAL_MARKER_REGEX, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

export function normalizeMathLatex(value) {
  let out = String(value || '').trim();
  if (!out) return '';
  out = out
    .replace(/^\$\$/, '')
    .replace(/\$\$$/, '')
    .replace(/^\\\(/, '')
    .replace(/\\\)$/, '')
    .replace(/`+/g, ' ')
    .replace(/\bRARROW\b/g, '\\Rightarrow ')
    .replace(/\bLARROW\b/g, '\\Leftarrow ')
    .replace(/\bLRARROW\b/g, '\\Leftrightarrow ')
    .replace(/\brarrow\b/g, '\\rightarrow ')
    .replace(/\blarrow\b/g, '\\leftarrow ')
    .replace(/\blrarrow\b/g, '\\leftrightarrow ')
    .replace(/\bSIM\b/g, '\\sim ')
    .replace(/\bAPPROX\b/g, '\\approx ')
    .replace(/\bDEG\b/g, '^{\\circ}')
    .replace(/×/g, '\\times ')
    .replace(/÷/g, '\\div ')
    .replace(/·/g, '\\cdot ')
    .replace(/−/g, '-')
    .replace(/≤/g, '\\le ')
    .replace(/≥/g, '\\ge ')
    .replace(/≠/g, '\\ne ')
    .replace(/π/g, '\\pi ')
    .replace(/\\left\s*\{/g, '\\left\\{')
    .replace(/\\right\s*\}/g, '\\right\\}')
    .replace(/\s+/g, ' ')
    .trim();
  out = convertOverToFrac(out);
  return out;
}

/**
 * Convert {A} \over {B} to \frac{A}{B}.
 * \over is a TeX primitive that splits the ENTIRE surrounding group
 * into numerator/denominator, which breaks when \displaystyle is added.
 * \frac{}{} is scoped and safe.
 */
function convertOverToFrac(latex) {
  let result = latex;
  let prev;
  do {
    prev = result;
    result = result.replace(/\{([^{}]*)\}\s*\\over\s*\{([^{}]*)\}/g, '\\frac{$1}{$2}');
  } while (result !== prev);
  return result;
}

export function isHangulSyllableOrJamo(ch) {
  return /[가-힣ㄱ-ㅎㅏ-ㅣ]/.test(String(ch || ''));
}

export function splitStemByNewline(stem) {
  return String(stem || '')
    .replace(/\r/g, '')
    .replace(/\[문단\]/g, '\n')
    .split('\n');
}

export function isFractionLatex(value) {
  const src = normalizeMathLatex(value);
  if (!src) return false;
  if (/\\(?:frac|dfrac|tfrac)\b/.test(src)) return true;
  if (/\\over\b/.test(src)) return true;
  return /[A-Za-z0-9)\]}]\s*\/\s*[A-Za-z0-9({\[]/.test(src);
}

export function compact(value, max = 220) {
  const s = String(value ?? '').replace(/\s+/g, ' ').trim();
  if (s.length <= max) return s;
  return `${s.slice(0, max)}...`;
}

/**
 * Build equation lookup from the question's equations array.
 * Returns an array of { latex, pattern } sorted by descending length
 * so longer matches are tried first.
 */
export function buildEquationIndex(equations) {
  if (!Array.isArray(equations) || equations.length === 0) return [];
  const seen = new Set();
  const entries = [];
  for (const eq of equations) {
    const latex = String(eq?.latex || '').trim();
    if (!latex || seen.has(latex)) continue;
    seen.add(latex);
    entries.push({ latex });
  }
  entries.sort((a, b) => b.latex.length - a.latex.length);
  return entries;
}

/**
 * Tokenize text using the equations array for precise math boundary detection.
 *
 * Strategy:
 * 1. Try to find each equation's latex in the text (longest first).
 * 2. Mark matched regions as 'math' tokens.
 * 3. Everything else becomes 'text' or 'newline' tokens.
 *
 * If no equations match (e.g. choice text IS the equation), check if the
 * entire text matches an equation and treat it as a single math token.
 */
export function tokenizeWithEquations(text, equations) {
  const src = String(text || '').replace(/\r/g, '');
  if (!src) return [];

  const eqIndex = buildEquationIndex(equations);
  if (eqIndex.length === 0) {
    return tokenizeFallback(src);
  }

  const marks = new Array(src.length).fill(false);

  for (const { latex } of eqIndex) {
    let searchFrom = 0;
    while (searchFrom < src.length) {
      const idx = src.indexOf(latex, searchFrom);
      if (idx < 0) break;
      let overlap = false;
      for (let k = idx; k < idx + latex.length; k++) {
        if (marks[k]) { overlap = true; break; }
      }
      if (!overlap) {
        for (let k = idx; k < idx + latex.length; k++) {
          marks[k] = true;
        }
      }
      searchFrom = idx + 1;
    }
  }

  const tokens = [];
  let i = 0;
  while (i < src.length) {
    if (src[i] === '\n') {
      tokens.push({ type: 'newline', value: '\n' });
      i++;
      continue;
    }
    if (marks[i]) {
      let j = i;
      while (j < src.length && marks[j] && src[j] !== '\n') j++;
      tokens.push({ type: 'math', value: src.slice(i, j) });
      i = j;
    } else {
      let j = i;
      while (j < src.length && !marks[j] && src[j] !== '\n') j++;
      tokens.push({ type: 'text', value: src.slice(i, j) });
      i = j;
    }
  }

  return tokens;
}

/**
 * Fallback tokenizer for text that has no equation matches.
 * Checks if the entire trimmed text looks like a LaTeX expression
 * (contains backslash commands, ^, {, etc.) and if so, treats it
 * as a single math token. Otherwise returns it as plain text.
 */
function tokenizeFallback(src) {
  const tokens = [];
  const lines = src.split('\n');
  for (let li = 0; li < lines.length; li++) {
    if (li > 0) tokens.push({ type: 'newline', value: '\n' });
    const line = lines[li];
    if (!line) continue;
    const trimmed = line.trim();
    if (looksLikeLatex(trimmed)) {
      tokens.push({ type: 'math', value: trimmed });
    } else {
      tokens.push({ type: 'text', value: line });
    }
  }
  return tokens;
}

function looksLikeLatex(text) {
  if (!text) return false;
  if (/\\(?:frac|dfrac|tfrac|sqrt|mathrm|times|div|cdot|le|ge|ne|pi|left|right|over)\b/.test(text)) return true;
  if (/\^{/.test(text)) return true;
  if (/_{/.test(text)) return true;
  if (/\\[a-zA-Z]+/.test(text)) return true;
  return false;
}
