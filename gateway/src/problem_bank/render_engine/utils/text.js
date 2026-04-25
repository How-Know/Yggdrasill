// `[문단]` 은 기본 문단 구분 마커. `[문단:<속성>]` 는 사용자가 리뷰 UI 에서 직접 수정해
// 라인별 정렬을 지정하는 확장 형태 (ex. `[문단:가운데]`). 렌더러 진입 전에
// applyInlineAlignmentMarkers 로 정규화하여 속성 부분은 stemLineAligns 로 옮기고
// 텍스트에는 plain `[문단]` 만 남긴다. 정규식을 `?:` 형태로 확장해 두면, 만일
// 전처리가 누락되어도 최종 strip 단계에서 마커 자체는 안전하게 제거된다.
const STRUCTURAL_MARKER_REGEX = /\[(?:문단(?::[^\]]*)?|박스시작|박스끝)\]/g;

// `[공백:N]` 은 사용자가 리뷰 UI 에서 직접 넣는 "고정폭 공백 N em" 마커.
// 렌더 경로가 `\s+` 를 여러 단계에서 collapse 하므로, 의도적으로 넣은 다중 공백은
// 반드시 마커 형태로만 보존된다. N 은 양의 수(정수/소수) 로 허용 범위는 [0.1, 20] em.
// 범위 밖 값은 clamp 하고, 숫자가 아니거나 누락되면 기본 1 em 로 처리한다.
export const SPACE_MARKER_REGEX = /\[공백:([0-9]+(?:\.[0-9]+)?)\]/g;
const SPACE_MARKER_MIN_EM = 0.1;
const SPACE_MARKER_MAX_EM = 20;
const SPACE_MARKER_DEFAULT_EM = 1;
export const UNDERLINE_START_MARKER = '[밑줄]';
export const UNDERLINE_END_MARKER = '[/밑줄]';

/** `[공백:N]` 의 N 문자열을 clamp 된 숫자로 변환 (em 단위). */
export function parseSpaceMarkerAmount(raw) {
  const n = Number.parseFloat(String(raw ?? '').trim());
  if (!Number.isFinite(n) || n <= 0) return SPACE_MARKER_DEFAULT_EM;
  if (n < SPACE_MARKER_MIN_EM) return SPACE_MARKER_MIN_EM;
  if (n > SPACE_MARKER_MAX_EM) return SPACE_MARKER_MAX_EM;
  // 소수 둘째자리까지 고정 (렌더링 polish; 0.1 단위 이내 정확도).
  return Math.round(n * 100) / 100;
}

/**
 * 임의 문자열에서 `[공백:N]` 마커를 순서대로 추출해 text 와 space 조각으로 분리.
 * @param {string} input
 * @returns {Array<{ type: 'text', value: string } | { type: 'space', amount: number }>}
 */
export function splitBySpaceMarkers(input) {
  const src = String(input ?? '');
  if (!src) return [];
  const out = [];
  let last = 0;
  const re = new RegExp(SPACE_MARKER_REGEX.source, 'g');
  let m;
  while ((m = re.exec(src)) !== null) {
    if (m.index > last) out.push({ type: 'text', value: src.slice(last, m.index) });
    out.push({ type: 'space', amount: parseSpaceMarkerAmount(m[1]) });
    last = m.index + m[0].length;
  }
  if (last < src.length) out.push({ type: 'text', value: src.slice(last) });
  if (out.length === 0) out.push({ type: 'text', value: src });
  return out;
}

/**
 * `[밑줄]...[/밑줄]` 구간을 inline fragment 로 분리한다. 중첩은 지원하지 않고,
 * 닫힘 마커가 없으면 원문을 그대로 text 조각으로 돌려 렌더 실패를 피한다.
 */
export function splitByUnderlineMarkers(input) {
  const src = String(input ?? '');
  if (!src.includes(UNDERLINE_START_MARKER)) {
    return src ? [{ type: 'text', value: src }] : [];
  }
  const out = [];
  let cursor = 0;
  while (cursor < src.length) {
    const start = src.indexOf(UNDERLINE_START_MARKER, cursor);
    if (start < 0) {
      if (cursor < src.length) out.push({ type: 'text', value: src.slice(cursor) });
      break;
    }
    if (start > cursor) out.push({ type: 'text', value: src.slice(cursor, start) });
    const contentStart = start + UNDERLINE_START_MARKER.length;
    const end = src.indexOf(UNDERLINE_END_MARKER, contentStart);
    if (end < 0) {
      out.push({ type: 'text', value: src.slice(start) });
      break;
    }
    out.push({ type: 'underline', value: src.slice(contentStart, end) });
    cursor = end + UNDERLINE_END_MARKER.length;
  }
  return out.filter((part) => String(part.value || '').length > 0);
}

/**
 * 문단 정렬 속성 값을 표준 내부값(left/center/right/justify) 으로 변환.
 * - 영어: left/right/center/justify/both/middle
 * - 한국어: 왼쪽/오른쪽/가운데/중앙/양쪽/균등
 * - 기타/빈값: 'left'
 */
export function normalizeLineAlignValue(value) {
  const raw = String(value || '').trim().toLowerCase();
  if (!raw) return 'left';
  if (raw === 'center' || raw === 'middle' || raw === '가운데' || raw === '중앙' || raw === '센터') {
    return 'center';
  }
  if (raw === 'right' || raw === '오른쪽' || raw === '우측') return 'right';
  if (raw === 'justify' || raw === 'both' || raw === 'distribute' || raw === 'distributed'
      || raw === '양쪽' || raw === '균등') {
    return 'justify';
  }
  if (raw === 'left' || raw === '왼쪽' || raw === '좌측') return 'left';
  return 'left';
}

/**
 * stem 텍스트에서 `[문단:가운데]` 같은 속성부 마커를 찾아
 *   1) 해당 라인에서는 plain `[문단]` 만 남기고 속성을 벗겨내며,
 *   2) 속성을 stemLineAligns 병렬 배열의 "다음 콘텐츠 라인" 값으로 옮긴다.
 *
 * 시맨틱:
 *   - 독립 마커 라인 `[문단:가운데]` → 바로 다음 콘텐츠 라인의 정렬을 center 로 설정.
 *   - 속성이 섞인 콘텐츠 라인(`...내용...[문단:가운데]`)도 속성만 추출해 다음 콘텐츠
 *     라인에 적용 (인라인 마커의 속성은 "다음" 기준으로 일관). 속성이 없었다면
 *     기존 값 유지.
 *   - 한국어 속성명(가운데/오른쪽/왼쪽/양쪽) 지원.
 *
 * 반환: { stem, stemLineAligns } — 길이가 입력 stem 의 `\n` 기준 라인 수와 동일.
 *   호출 측은 원래 입력 대신 반환값을 사용해야 한다 (원본은 mutate 하지 않음).
 */
export function applyInlineAlignmentMarkers(stem, stemLineAligns = []) {
  const src = String(stem || '').replace(/\r/g, '');
  const rawLines = src.split('\n');

  const srcAligns = Array.isArray(stemLineAligns) ? stemLineAligns.slice() : [];
  while (srcAligns.length < rawLines.length) srcAligns.push('left');
  srcAligns.length = rawLines.length;

  const STANDALONE_MARKER = /^\s*\[문단(?::([^\]]*))?\]\s*$/;
  const INLINE_MARKER = /\[문단(?::([^\]]*))?\]/g;

  const outLines = [];
  const outAligns = [];
  let pendingAlign = null;

  for (let i = 0; i < rawLines.length; i += 1) {
    const line = rawLines[i];
    const baseAlign = normalizeLineAlignValue(srcAligns[i]);

    const standalone = line.match(STANDALONE_MARKER);
    if (standalone) {
      outLines.push('[문단]');
      outAligns.push(baseAlign);
      const attrVal = standalone[1] ? normalizeLineAlignValue(standalone[1]) : null;
      if (standalone[1]) pendingAlign = attrVal || 'left';
      continue;
    }

    let capturedInline = null;
    const cleaned = line.replace(INLINE_MARKER, (_match, attr) => {
      if (attr && !capturedInline) {
        const v = normalizeLineAlignValue(attr);
        capturedInline = v || 'left';
      }
      return '[문단]';
    });

    let effective = baseAlign;
    if (pendingAlign) {
      effective = pendingAlign;
      pendingAlign = null;
    }
    outLines.push(cleaned);
    outAligns.push(effective);
    if (capturedInline) pendingAlign = capturedInline;
  }

  return { stem: outLines.join('\n'), stemLineAligns: outAligns };
}

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

function splitLatexRows(body) {
  const rows = [];
  const src = String(body || '');
  const rowBreakRe = /\\\\(?:\s*\[[^\]]+\])?/g;
  let last = 0;
  let m;
  while ((m = rowBreakRe.exec(src)) !== null) {
    const row = src.slice(last, m.index).trim();
    if (row) rows.push(row);
    last = m.index + m[0].length;
  }
  const tail = src.slice(last).trim();
  if (tail) rows.push(tail);
  return rows;
}

function countUnescapedAmpersands(row) {
  const matches = String(row || '').match(/(?<!\\)&/g);
  return matches ? matches.length : 0;
}

function applyDisplaystyleToCaseRow(row) {
  return String(row || '')
    .split(/(?<!\\)&/)
    .map((cell) => {
      const trimmed = cell.trim();
      if (!trimmed) return trimmed;
      if (/^\\(?:displaystyle|textstyle|scriptstyle|scriptscriptstyle)\b/.test(trimmed)) {
        return trimmed;
      }
      return `\\displaystyle ${trimmed}`;
    })
    .join(' & ');
}

/**
 * LaTeX 기본 `cases` 는 내부 항목을 textstyle/촘촘한 행간으로 잡아 PDF에서 작게 보인다.
 * 서버 PDF와 HTML(MathJax) 모두에서 더 큰 piecewise/system 스타일이 되도록
 * `\left\{ + array` 로 펼치고 각 셀에 `\displaystyle` 를 적용한다.
 */
export function expandCasesEnvironmentToDisplayArray(value, options = {}) {
  const {
    thinBrace = false,
    braceXScale = 0.78,
    braceYScale = 1,
    braceGap = '\\hspace{0.45em}',
    rowGap = '0.35em',
  } = options || {};

  return String(value || '').replace(
    /\\begin\{cases\}([\s\S]*?)\\end\{cases\}/g,
    (_match, body) => {
      const rows = splitLatexRows(body);
      if (rows.length === 0) return _match;
      const colCount = Math.max(
        1,
        ...rows.map((row) => countUnescapedAmpersands(row) + 1),
      );
      const colSpec = `@{}${Array.from({ length: colCount }, () => 'l').join('@{\\quad}')}@{}`;
      const latexRows = rows
        .map(applyDisplaystyleToCaseRow)
        .join(`\\\\[${rowGap}]`);
      const arrayTex = `\\begin{array}{${colSpec}}${latexRows}\\end{array}`;
      if (thinBrace) {
        // XeLaTeX 전용: delimiter 두께를 직접 지정할 수 없으므로 brace만 가로로 살짝
        // 압축해 선을 얇게 보이게 한다. braceYScale 은 행간을 건드리지 않고
        // delimiter 자체의 위아래 과한 여유만 줄이는 용도다.
        // 배열은 별도 math box로 두어 글자폭과 행간은 유지한다.
        return `\\vcenter{\\hbox{\\scalebox{${braceXScale}}[${braceYScale}]{$\\left\\{\\vphantom{${arrayTex}}\\right.$}${braceGap}$${arrayTex}$}}`;
      }
      return `\\left\\{${braceGap}${arrayTex}\\right.`;
    },
  );
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
    .replace(/(?<!\\)%/g, '\\%')
    .replace(/−/g, '-')
    .replace(/≤/g, '\\le ')
    .replace(/≥/g, '\\ge ')
    .replace(/≠/g, '\\ne ')
    .replace(/π/g, '\\pi ')
    .replace(/\\left\s*\{/g, '\\left\\{')
    .replace(/\\right\s*\}/g, '\\right\\}')
    .replace(/\s+/g, ' ')
    .trim();
  out = out.replace(/\^\s*\{\s*box\{~~\}\s*\}/g, '^{\\square}');
  out = out.replace(/\^\s*box\{~~\}/g, '^{\\square}');
  out = out.replace(/box\{~~\}/g, '\\boxed{\\phantom{0}}');
  out = convertOverToFrac(out);
  out = expandCasesEnvironmentToDisplayArray(out);
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
    .replace(/\[문단(?::[^\]]*)?\]/g, '\n')
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
