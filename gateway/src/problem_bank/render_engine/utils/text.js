// `[문단]` 은 기본 문단 구분 마커. `[문단:<속성>]` 는 사용자가 리뷰 UI 에서 직접 수정해
// 라인별 정렬을 지정하는 확장 형태 (ex. `[문단:가운데]`). 렌더러 진입 전에
// applyInlineAlignmentMarkers 로 정규화하여 속성 부분은 stemLineAligns 로 옮기고
// 텍스트에는 plain `[문단]` 만 남긴다. 정규식을 `?:` 형태로 확장해 두면, 만일
// 전처리가 누락되어도 최종 strip 단계에서 마커 자체는 안전하게 제거된다.
const STRUCTURAL_MARKER_REGEX = /\[(?:문단(?::[^\]]*)?|수식줄바꿈(?::[^\]]*)?|수식제시|수식제시줄|수식제시시작|수식제시끝|수식제시줄시작|수식제시줄끝|displaymath|mathline|displaymath(?::|-)(?:start|end)|mathline(?::|-)(?:start|end)|박스시작|박스끝)\]/gi;

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
  const src = String(input ?? '').replace(/\[\\+밑줄\]/g, UNDERLINE_END_MARKER);
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

/**
 * JSON에서 `\notin`의 `\n`이 실제 LF로 해석된 기존 데이터를 복구한다.
 * 예: "\\sqrt{2}\notin R" (LF + "otin") → "\\sqrt{2}\\notin R".
 */
export function recoverMangledLatexNewlineCommands(value) {
  // 한 글자만 남는 \ne · \ni · \nu 는 되돌리지 않는다(2026-11-21 사장님 결정, xelatex_v2/template.js 의
  // sanitizeLatexControlChars 와 같다): 줄 첫머리의 e · i · u 와 구분할 수 없다.
  return String(value ?? '').replace(
    /\x0a(?=(?:abla|atural|e(?:q|g)|otin)(?![A-Za-z]))/g,
    '\\n',
  );
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
  let start = 0;
  let braceDepth = 0;
  const envStack = [];

  for (let i = 0; i < src.length; i += 1) {
    if (src.startsWith('\\begin{', i) || src.startsWith('\\end{', i)) {
      const isBegin = src.startsWith('\\begin{', i);
      const nameStart = i + (isBegin ? '\\begin{'.length : '\\end{'.length);
      const nameEnd = src.indexOf('}', nameStart);
      if (nameEnd > nameStart) {
        const envName = src.slice(nameStart, nameEnd);
        if (isBegin) {
          envStack.push(envName);
        } else {
          const idx = envStack.lastIndexOf(envName);
          if (idx >= 0) envStack.splice(idx, 1);
        }
        i = nameEnd;
        continue;
      }
    }
    const ch = src[i];
    const next = src[i + 1];
    if (ch === '\\') {
      if (next === '\\' && braceDepth === 0 && envStack.length === 0) {
        const row = src.slice(start, i).trim();
        if (row) rows.push(row);
        i += 2;
        while (i < src.length && /\s/.test(src[i])) i += 1;
        if (src[i] === '[') {
          const close = src.indexOf(']', i + 1);
          if (close >= 0) i = close + 1;
        }
        start = i;
        i -= 1;
        continue;
      }
      // Escaped one-character tokens such as \{, \}, \& must not affect depth.
      if (next && !/[a-zA-Z]/.test(next)) i += 1;
      continue;
    }
    if (ch === '{') {
      braceDepth += 1;
    } else if (ch === '}') {
      braceDepth = Math.max(0, braceDepth - 1);
    }
  }
  const tail = src.slice(start).trim();
  if (tail) rows.push(tail);
  return rows;
}

/**
 * 추출 아티팩트 보정: 일부 보기/수식에서 cases 의 행 구분자 `\\` 가 단일
 * 제어 공백 `\ ` 로 유실되어 들어오는 경우가 있다. 이때 cases 는 행 구분자를
 * 찾지 못해 한 줄로 렌더된다. 최상위에 `\\`(실제 행 구분)도 없고 `&`(열 구분)도
 * 없는데 제어 공백으로만 분절된 경우에 한해, 그 제어 공백을 행 구분자로 복구한다.
 * (정상적인 다행/열 분리 cases 는 건드리지 않아 회귀 위험이 없다.)
 */
function recoverCasesControlSpaceRowBreaks(body) {
  const src = String(body || '');
  if (!src) return src;
  let braceDepth = 0;
  const envStack = [];
  const controlSpacePositions = [];
  for (let i = 0; i < src.length; i += 1) {
    if (src.startsWith('\\begin{', i) || src.startsWith('\\end{', i)) {
      const isBegin = src.startsWith('\\begin{', i);
      const nameStart = i + (isBegin ? '\\begin{'.length : '\\end{'.length);
      const nameEnd = src.indexOf('}', nameStart);
      if (nameEnd > nameStart) {
        const envName = src.slice(nameStart, nameEnd);
        if (isBegin) {
          envStack.push(envName);
        } else {
          const idx = envStack.lastIndexOf(envName);
          if (idx >= 0) envStack.splice(idx, 1);
        }
        i = nameEnd;
        continue;
      }
    }
    const ch = src[i];
    const next = src[i + 1];
    if (ch === '\\') {
      const topLevel = braceDepth === 0 && envStack.length === 0;
      if (next === '\\') {
        // 실제 행 구분자가 이미 존재하면 복구하지 않는다.
        if (topLevel) return src;
        i += 1;
        continue;
      }
      if (topLevel && (next === ' ' || next === '\t' || next === '\n' || next === '\r')) {
        controlSpacePositions.push(i);
      }
      if (next && !/[a-zA-Z]/.test(next)) i += 1;
      continue;
    }
    if (ch === '&' && braceDepth === 0 && envStack.length === 0) {
      // 열 구분이 있는 단일행 cases (값 & 조건) 형태는 복구 대상이 아니다.
      return src;
    }
    if (ch === '{') {
      braceDepth += 1;
    } else if (ch === '}') {
      braceDepth = Math.max(0, braceDepth - 1);
    }
  }
  if (controlSpacePositions.length === 0) return src;
  let out = '';
  let cursor = 0;
  for (const idx of controlSpacePositions) {
    out += src.slice(cursor, idx);
    out += '\\\\';
    cursor = idx + 1;
    while (cursor < src.length && /\s/.test(src[cursor])) cursor += 1;
  }
  out += src.slice(cursor);
  return out;
}

function splitLatexTopLevelAmpersands(row) {
  const src = String(row || '');
  const cells = [];
  let start = 0;
  let braceDepth = 0;
  const envStack = [];

  for (let i = 0; i < src.length; i += 1) {
    if (src.startsWith('\\begin{', i) || src.startsWith('\\end{', i)) {
      const isBegin = src.startsWith('\\begin{', i);
      const nameStart = i + (isBegin ? '\\begin{'.length : '\\end{'.length);
      const nameEnd = src.indexOf('}', nameStart);
      if (nameEnd > nameStart) {
        const envName = src.slice(nameStart, nameEnd);
        if (isBegin) {
          envStack.push(envName);
        } else {
          const idx = envStack.lastIndexOf(envName);
          if (idx >= 0) envStack.splice(idx, 1);
        }
        i = nameEnd;
        continue;
      }
    }
    const ch = src[i];
    const next = src[i + 1];
    if (ch === '\\') {
      if (next && !/[a-zA-Z]/.test(next)) i += 1;
      continue;
    }
    if (ch === '{') {
      braceDepth += 1;
    } else if (ch === '}') {
      braceDepth = Math.max(0, braceDepth - 1);
    } else if (ch === '&' && braceDepth === 0 && envStack.length === 0) {
      cells.push(src.slice(start, i));
      start = i + 1;
    }
  }
  cells.push(src.slice(start));
  return cells;
}

function countUnescapedAmpersands(row) {
  return Math.max(0, splitLatexTopLevelAmpersands(row).length - 1);
}

const PROTECTED_TEXT_TOKEN_RE = /\x00LATEXTEXT\d+\x00/g;

/**
 * cases 한 칸이 지면에서 차지하는 폭을 em 으로 어림한다(한글 1, 영문·숫자 0.5, 관계 기호는 양옆 간격까지 1.3).
 * LaTeX 원문 길이는 `\text{ 또는 }`(2글자)가 11자로 세어져 폭과 맞지 않는다. 분수는 분자와 분모를 모두 세므로
 * 실제보다 조금 넓게 나온다. options.resolveProtectedText 가 있으면 \text 보호 토큰을 원래 글로 되돌려 잰다.
 */
export function estimateCaseCellWidthEm(cell, options = {}) {
  let src = String(cell || '');
  if (typeof options?.resolveProtectedText === 'function') {
    src = String(options.resolveProtectedText(src) || '');
  }
  let em = 0;
  // 되돌릴 수 없는 보호 토큰은 안의 글을 모르므로 짧은 말(또는, 이고) 하나로 본다.
  src = src.replace(PROTECTED_TEXT_TOKEN_RE, () => { em += 2.6; return ' '; });
  src = src.replace(/\\text\{([^{}]*)\}/g, (_, body) => {
    for (const ch of body) {
      const code = ch.codePointAt(0);
      if (code >= 0xAC00 && code <= 0xD7AF) em += 1;
      else if (ch === ' ') em += 0.3;
      else em += 0.5;
    }
    return ' ';
  });
  src = src
    .replace(/\\qquad(?![a-zA-Z])/g, () => { em += 2; return ' '; })
    .replace(/\\quad(?![a-zA-Z])/g, () => { em += 1; return ' '; })
    .replace(/\\[,;:!]/g, () => { em += 0.2; return ' '; })
    .replace(/\\(?:left|right|displaystyle|textstyle|mathrm|mathbf|mathit|operatorname|text|dfrac|tfrac|frac|sqrt)(?![a-zA-Z])/g, ' ')
    .replace(/\\(?:le|ge|leq|geq|neq|ne|lt|gt|approx|equiv|sim|in|notin|subset|times|div|cdot|pm|mp)(?![a-zA-Z])/g, () => { em += 1.3; return ' '; })
    .replace(/\\[a-zA-Z]+/g, () => { em += 0.6; return ' '; })
    .replace(/[{}$\\^_\s]/g, '');
  for (const ch of src) {
    const code = ch.codePointAt(0);
    if (code >= 0xAC00 && code <= 0xD7AF) em += 1;
    else if (ch === '=' || ch === '<' || ch === '>') em += 1.3;
    else if (ch === '+' || ch === '-') em += 1;
    else if ('(),.|'.includes(ch)) em += 0.35;
    else em += 0.5;
  }
  return Math.round(em * 10) / 10;
}

function shouldStackCaseConditionCell(cell, options = {}) {
  const {
    wrapCaseConditionCells = false,
    caseRowMaxEm = 22,
    caseMainWidthEm = 0,
  } = options || {};
  if (!wrapCaseConditionCells) return false;

  const trimmed = String(cell || '').trim();

  // 오른쪽 조건 칸 안의 자연어 연결 지점이 있는 조건만 대상으로 한다.
  // 렌더러 경로에서는 \text{...} 가 \x00LATEXTEXT...\x00 보호 토큰인 상태일 수 있다.
  const breakRe = /(?:\\text\{\s*(?:또는|이고|이며|단|if|otherwise)\s*\}|\x00LATEXTEXT\d+\x00)/;
  const match = breakRe.exec(trimmed);
  if (!match || match.index <= 0) return false;

  // 조건을 아래 줄로 내리는 것은 한 줄에 다 들어가지 않을 때뿐이다. 문항 한 줄은 약 30em 이고
  // 앞의 "f(x)=" 와 중괄호가 4~5em 을 쓰므로, 식 칸(가장 넓은 행) + 칸 사이 1em + 조건 칸이 22em 을 넘을 때만 내린다.
  // 예전에는 조건 칸의 LaTeX 원문이 34자 이상이면 내려서, 지면에서는 15em 인
  // "(X가 0 또는 1의 값을 가지는 경우)"(원문 43자)가 식 칸이 "X" 하나인데도 다음 줄로 갔다.
  const rowEm = Number(caseMainWidthEm || 0) + 1 + estimateCaseCellWidthEm(trimmed, options);
  return rowEm > caseRowMaxEm;
}

function formatCaseConditionStackRow(conditionCell, colCount) {
  const trimmed = String(conditionCell || '').trim();
  const span = Math.max(1, Number(colCount || 1));
  return `\\multicolumn{${span}}{@{}r@{}}{\\displaystyle ${trimmed}}`;
}

function formatCaseCell(cell, cellIndex, options = {}) {
  const trimmed = String(cell || '').trim();
  if (!trimmed) return trimmed;
  if (/^\\(?:displaystyle|textstyle|scriptstyle|scriptscriptstyle)\b/.test(trimmed)) {
    return trimmed;
  }
  return `\\displaystyle ${trimmed}`;
}

function applyDisplaystyleToCaseRow(row, options = {}, colCount = 1) {
  const cells = splitLatexTopLevelAmpersands(row);
  const longConditionIndex = cells.findIndex((cell, cellIndex) => (
    cellIndex > 0 && shouldStackCaseConditionCell(cell, options)
  ));
  if (longConditionIndex > 0) {
    const mainCells = cells.map((cell, cellIndex) => (
      cellIndex === longConditionIndex
        ? ''
        : formatCaseCell(cell, cellIndex, options)
    ));
    const stackGap = options.caseConditionStackGap || '-0.10em';
    return [
      mainCells.join(' & '),
      `\\\\[${stackGap}]`,
      formatCaseConditionStackRow(cells[longConditionIndex], colCount),
    ].join('');
  }
  return cells
    .map((cell, cellIndex) => formatCaseCell(cell, cellIndex, options))
    .join(' & ');
}

const CASES_BEGIN = '\\begin{cases}';
const CASES_END = '\\end{cases}';

function findMatchingCasesEnd(src, bodyStart) {
  let depth = 1;
  let pos = bodyStart;
  while (pos < src.length) {
    const nextBegin = src.indexOf(CASES_BEGIN, pos);
    const nextEnd = src.indexOf(CASES_END, pos);
    if (nextEnd < 0) return null;
    if (nextBegin >= 0 && nextBegin < nextEnd) {
      depth += 1;
      pos = nextBegin + CASES_BEGIN.length;
      continue;
    }
    depth -= 1;
    if (depth === 0) {
      return {
        endStart: nextEnd,
        endAfter: nextEnd + CASES_END.length,
      };
    }
    pos = nextEnd + CASES_END.length;
  }
  return null;
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
    arrayStretch = '1',
  } = options || {};

  const src = String(value || '');
  let out = '';
  let pos = 0;
  while (pos < src.length) {
    const begin = src.indexOf(CASES_BEGIN, pos);
    if (begin < 0) {
      out += src.slice(pos);
      break;
    }
    const bodyStart = begin + CASES_BEGIN.length;
    const match = findMatchingCasesEnd(src, bodyStart);
    if (!match) {
      out += src.slice(pos);
      break;
    }
    out += src.slice(pos, begin);

    const rawBody = src.slice(bodyStart, match.endStart);
    // 안쪽 cases 를 먼저 균형 있게 변환해야 바깥 행 분리 시 내부 `\\` 를 건드리지 않는다.
    const body = recoverCasesControlSpaceRowBreaks(
      expandCasesEnvironmentToDisplayArray(rawBody, options),
    );
    const rows = splitLatexRows(body);
    if (rows.length === 0) {
      out += src.slice(begin, match.endAfter);
      pos = match.endAfter;
      continue;
    }
    const colCount = Math.max(
      1,
      ...rows.map((row) => countUnescapedAmpersands(row) + 1),
    );
    const colSpec = `@{}${Array.from({ length: colCount }, () => 'l').join('@{\\quad}')}@{}`;
    // 식 칸은 가장 넓은 행의 폭으로 잡히므로 조건을 내릴지는 그 폭을 기준으로 정한다.
    const rowOptions = options?.wrapCaseConditionCells
      ? {
        ...options,
        caseMainWidthEm: Math.max(0, ...rows.map((row) => {
          const cells = splitLatexTopLevelAmpersands(row);
          return cells.length > 1 ? estimateCaseCellWidthEm(cells.slice(0, -1).join(' '), options) : 0;
        })),
      }
      : options;
    const latexRows = rows
      .map((row) => applyDisplaystyleToCaseRow(row, rowOptions, colCount))
      .join(`\\\\[${rowGap}]`);
    const arrayTex = `\\begingroup\\renewcommand{\\arraystretch}{${arrayStretch}}\\begin{array}{${colSpec}}${latexRows}\\end{array}\\endgroup`;
    if (thinBrace) {
      // XeLaTeX 전용: delimiter 두께를 직접 지정할 수 없으므로 brace만 가로로 살짝
      // 압축해 선을 얇게 보이게 한다. braceYScale 은 행간을 건드리지 않고
      // delimiter 자체의 위아래 과한 여유만 줄이는 용도다.
      // 배열은 별도 math box로 두어 글자폭과 행간은 유지한다.
      out += `\\vcenter{\\hbox{\\scalebox{${braceXScale}}[${braceYScale}]{$\\left\\{\\vphantom{${arrayTex}}\\right.$}${braceGap}$${arrayTex}$}}`;
    } else {
      out += `\\left\\{${braceGap}${arrayTex}\\right.`;
    }
    pos = match.endAfter;
  }
  return out;
}

// 호 표기의 내부 표준형은 \overset{\frown}{AB} 이다.
// VLM/MathJax가 흔히 내보내는 별칭은 엔진마다 지원 범위가 달라 저장·렌더 경로에서
// 그대로 소비하면 XeLaTeX의 undefined control sequence가 될 수 있다.
export function normalizeArcNotation(value) {
  const source = String(value || '');
  if (!/\\(?:overarc|overparen|wideparen)\s*\{/.test(source)) return source;

  let out = '';
  let cursor = 0;
  const commandRe = /\\(?:overarc|overparen|wideparen)\s*\{/g;
  while (true) {
    commandRe.lastIndex = cursor;
    const match = commandRe.exec(source);
    if (!match) {
      out += source.slice(cursor);
      break;
    }

    const openIndex = match.index + match[0].lastIndexOf('{');
    let depth = 1;
    let closeIndex = -1;
    for (let i = openIndex + 1; i < source.length; i += 1) {
      if (source[i] === '\\') {
        i += 1;
        continue;
      }
      if (source[i] === '{') depth += 1;
      else if (source[i] === '}') {
        depth -= 1;
        if (depth === 0) {
          closeIndex = i;
          break;
        }
      }
    }

    out += source.slice(cursor, match.index);
    if (closeIndex < 0) {
      out += source.slice(match.index);
      break;
    }

    const argument = source.slice(openIndex + 1, closeIndex);
    out += `\\overset{\\frown}{${argument}}`;
    cursor = closeIndex + 1;
  }
  return out;
}

export function normalizeMathLatex(value) {
  let out = String(value || '').trim();
  if (!out) return '';
  out = normalizeArcNotation(out);
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
    .replace(/∥/g, '\\mathbin{/\\mkern-2mu/}')
    .replace(/\\parallel(?![a-zA-Z])/g, '\\mathbin{/\\mkern-2mu/}')
    .replace(/π/g, '\\pi ')
    .replace(/([◆◇⬦⬥⋄])\s+/g, '\\text{$1}\\;')
    .replace(/\\(?:diamond|lozenge|blacklozenge)(?![a-zA-Z])\s+/g, (m) => `${m.trim()}\\;`)
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
    if (/[가-힣ㄱ-ㅎㅏ-ㅣ]/.test(trimmed) && looksLikeLatex(trimmed)) {
      const mixed = tokenizeMixedTextLatexLine(line);
      if (mixed.some((token) => token.type === 'math')) {
        tokens.push(...mixed);
        continue;
      }
    }
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

function tokenizeMixedTextLatexLine(line) {
  const src = String(line || '');
  const tokens = [];
  let last = 0;
  let i = 0;
  while (i < src.length) {
    if (src[i] !== '\\') {
      i += 1;
      continue;
    }
    const end = consumeLatexExpression(src, i);
    if (end <= i) {
      i += 1;
      continue;
    }
    if (i > last) tokens.push({ type: 'text', value: src.slice(last, i) });
    tokens.push({ type: 'math', value: src.slice(i, end) });
    i = end;
    last = end;
  }
  if (last < src.length) tokens.push({ type: 'text', value: src.slice(last) });
  return tokens.length > 0 ? tokens : [{ type: 'text', value: src }];
}

function consumeLatexExpression(src, start) {
  const cmd = src.slice(start).match(/^\\([a-zA-Z]+)/);
  if (!cmd) return -1;
  const name = cmd[1];
  let pos = start + cmd[0].length;
  const skipSpaces = () => {
    while (pos < src.length && /\s/.test(src[pos])) pos += 1;
  };
  const consumeGroup = () => {
    skipSpaces();
    if (src[pos] !== '{') return false;
    let depth = 0;
    while (pos < src.length) {
      const ch = src[pos];
      if (ch === '\\') {
        pos += 2;
        continue;
      }
      if (ch === '{') depth += 1;
      if (ch === '}') {
        depth -= 1;
        pos += 1;
        if (depth === 0) return true;
        continue;
      }
      pos += 1;
    }
    return false;
  };

  if (name === 'frac' || name === 'dfrac' || name === 'tfrac') {
    return consumeGroup() && consumeGroup() ? pos : -1;
  }
  if (name === 'sqrt' || name === 'overline' || name === 'underline') {
    return consumeGroup() ? pos : -1;
  }
  if (name === 'text' || name === 'mathrm') {
    return consumeGroup() ? pos : -1;
  }
  return ['times', 'div', 'cdot', 'le', 'leq', 'ge', 'geq', 'ne', 'neq', 'pi']
    .includes(name)
    ? pos
    : -1;
}
