/**
 * question data -> .tex source file content
 *
 * Two modes:
 *   buildTexSource(question)         — single question (standalone, for PNG preview)
 *   buildDocumentTexSource(questions) — full document (for PDF export)
 *
 * Strategy:
 *   1. Parse [박스시작]/[박스끝] segments and detect <보기> boxes
 *   2. Split text into Korean-text segments and non-Korean (math) segments
 *   3. Korean segments → escapeLatexText
 *   4. Math segments   → $\displaystyle ...$
 *   5. Render boxes with tcolorbox, apply hanging indent via \leftskip
 */

import { resolveFigureLayout } from '../utils/figure_layout.js';
import {
  applyInlineAlignmentMarkers,
  expandCasesEnvironmentToDisplayArray,
  normalizeLineAlignValue,
  splitBySpaceMarkers,
  splitByUnderlineMarkers,
  SPACE_MARKER_REGEX,
} from '../utils/text.js';

// -----------------------------------------------------------------------------
// LaTeX 제어문자 복구 (렌더 시점 safety net).
//   VLM 경로에서 Gemini 가 \frac / \bullet / \vec / \t... 를 single-escape(\f ..)
//   로 내보내면 JSON.parse 가 이를 제어문자(Form Feed / Backspace / Vertical Tab /
//   Tab)로 "정상 해석" 해서 문자열에 박아버린다. 이 경우 기존 repairLatexBackslashes
//   는 파싱 실패가 아니므로 호출되지 않아 복구 기회를 놓친다.
//   - 1차 방어선: vlm/client.js 의 recoverMangledLatexControls (추출 시점)
//   - 2차 방어선(여기): 이미 DB 에 박혀 저장된 기존 데이터도 LaTeX 로 흘러가기 전에
//                       무조건 복구해서 "! Missing $ inserted" / "^^L rac{...}"
//                       컴파일 실패를 막는다.
//   Form Feed (\x0c) / Backspace (\x08) / VT (\x0b) 는 합법 LaTeX 본문에 등장할
//   이유가 없으므로 무조건 \f / \b / \v 로 되돌린다. Tab (\x09) 은 tabular 사이
//   공백으로 쓰이므로 "뒤에 영문자" 인 경우에만 \t<cmd> 로 복구.
//   CR (\x0d) / LF (\x0a) 는 자연 줄바꿈으로도 쓰이므로 "뒤에 LaTeX 명령 이름 패턴
//   (소문자 영문자들 + `\`/`{`/`^`/`_`)" 인 경우에만 \r<cmd> / \n<cmd> 로 복구.
//   대표 사례: \right\} → JSON.parse → \x0dight\} → "l.120 ight\}$" 컴파일 실패.
function sanitizeLatexControlChars(value) {
  if (typeof value === 'string') {
    let s = value;
    s = s.replace(/\x0c/g, '\\f');
    s = s.replace(/\x08/g, '\\b');
    s = s.replace(/\x0b/g, '\\v');
    s = s.replace(/\x09(?=[A-Za-z])/g, '\\t');
    // terminator 는 LaTeX 명령 뒤에 자주 오는 문자들 전부 커버: \ {} () [] ^ _
    // 과거 실수: ")" terminator 를 빠뜨려 "\right)" 가 "ight)" 로 깨져 재발한 적 있음.
    s = s.replace(/\x0d(?=[a-z][a-zA-Z]*[\\{}()\[\]^_])/g, '\\r');
    s = s.replace(/\x0a(?=[a-z][a-zA-Z]*[\\{}()\[\]^_])/g, '\\n');
    return s;
  }
  if (Array.isArray(value)) return value.map(sanitizeLatexControlChars);
  if (value && typeof value === 'object') {
    const out = {};
    for (const k of Object.keys(value)) {
      out[k] = sanitizeLatexControlChars(value[k]);
    }
    return out;
  }
  return value;
}

// `[문단]` + 속성부 포함 변형 `[문단:가운데]`, `[문단:center]` 등을 모두 매칭.
// 전처리 단계(applyInlineAlignmentMarkers)에서 이미 plain `[문단]` 으로 정규화되지만,
// safety net 으로 속성 변형도 strip/split 대상에 포함해 속성이 LaTeX 본문에 새어
// 나가지 않도록 한다.
const PARAGRAPH_MARKER_RE = /\[문단(?::[^\]]*)?\]/g;
const BOX_ALIGN_MARKER_RE = /^\s*\[(?:정렬|align)\s*:\s*(왼쪽|좌측|left|가운데|중앙|center|오른쪽|우측|right)\]\s*$/i;
const BOGI_MARKER_RE = /\[박스시작\]|\[박스끝\]/g;
const BOX_PARAGRAPH_BREAK = '__PB_BOX_PARAGRAPH_BREAK__';
// 세트형 문제에서 추출기가 주입하는 하위문항 경계 표식. 라인 하나를 단독으로 차지한다.
// 렌더러는 이 마커를 "소비" 하되 화면에는 표시하지 않고, 마커 사이에 수직 간격만 주입한다.
const SUBQ_MARKER_LINE_RE = /^\s*\[\s*소문항\s*\d+\s*\]\s*$/;
// 본문 그림 마커 정규식.
//   - 기존 plain 마커: [그림], [도형], [도표]
//   - HWPX binaryItemIDRef 를 보존한 토큰: [[PB_FIG_<itemID>]]
//   두 형태 모두 하나의 "그림 한 장" 슬롯을 가리킨다.
//   capture group 1: 값이 있으면 PB_FIG itemID, 없으면 plain 마커.
const FIGURE_MARKER_RE = /\[\[PB_FIG_([^\]]+)\]\]|\[(?:그림|도형|도표)\]/g;

// tabular 셀을 안전한 수식/텍스트 모드로 변환.
//   - "\text{...}" 셀: 그대로 (LaTeX 가 tabular 바깥 mode 에서도 문제없이 처리)
//   - "$...$"   셀: 그대로
//   - LaTeX 백슬래시 명령( \times, \frac, \pm, \leq ... ) 이 들어있는 셀: "$...$" 로 감싼다
//   - 한글이 포함된 셀: "\text{...}" 로 감싼다 (tabular bare 한글은 XeTeX 에서도 안전하지만
//     Math-ISH 주변 셀과 시각 정렬을 맞추기 위해 동일 처리).
//   - 빈 셀 / 단순 숫자·기호 셀: 그대로 둠.
function autoWrapTabularCells(rawTexBlock) {
  return rawTexBlock.replace(/\\begin\{tabular\}(\{[^}]*\})([\s\S]*?)\\end\{tabular\}/g, (_, colSpec, body) => {
    const rows = body.split(/\\\\/); // 행 구분은 \\ (LaTeX)
    const patchedRows = rows.map((row) => {
      // tabular 맨 끝의 공백/개행 row 는 그대로.
      if (!row.trim()) return row;
      // \hline 같은 단독 행은 그대로.
      if (/^\s*\\hline\s*$/.test(row)) return row;
      const cells = splitTabularRowCells(row);
      const patchedCells = cells.map((cellRaw) => {
        // 셀 앞뒤 공백/개행은 보존.
        const leading = cellRaw.match(/^\s*/)[0];
        const trailing = cellRaw.match(/\s*$/)[0];
        let inner = cellRaw.slice(leading.length, cellRaw.length - trailing.length);

        // 행 처음 셀 앞에 \hline 이 붙어 있을 수 있음 → 분리 보존.
        const hlineMatch = inner.match(/^((?:\\hline\s*)+)([\s\S]*)$/);
        let hlinePrefix = '';
        if (hlineMatch) {
          hlinePrefix = hlineMatch[1];
          inner = hlineMatch[2];
        }

        if (!inner.trim()) return leading + hlinePrefix + inner + trailing;

        // 이미 $...$ 혹은 \text{...} 로 감싸진 셀: 그대로.
        if (/^\s*\$[\s\S]*\$\s*$/.test(inner)) return leading + hlinePrefix + inner + trailing;
        if (/^\s*\\text\{[\s\S]*\}\s*$/.test(inner)) return leading + hlinePrefix + inner + trailing;

        const hasLatexCmd = /\\[a-zA-Z]+/.test(inner);
        const hasHangul = /[\uAC00-\uD7A3]/.test(inner);
        if (hasLatexCmd) return leading + hlinePrefix + `$${inner.trim()}$` + trailing;
        if (hasHangul) return leading + hlinePrefix + `\\text{${inner.trim()}}` + trailing;
        // 나머지(숫자/영문 알파벳/+,- 등 단순 기호) 도 수식 모드로 감싼다 → 서체 일관성.
        return leading + hlinePrefix + `$${inner.trim()}$` + trailing;
      });
      return patchedCells.join('&');
    });
    return `\\begin{tabular}${colSpec}${patchedRows.join('\\\\')}\\end{tabular}`;
  });
}

function splitTabularRowCells(row) {
  // '&' 로 분리하되 중괄호 깊이를 추적해 \text{a & b} 같은 내부 & 는 분리하지 않는다.
  const cells = [];
  let depth = 0;
  let buf = '';
  for (let i = 0; i < row.length; i += 1) {
    const ch = row[i];
    if (ch === '{') depth += 1;
    else if (ch === '}') depth = Math.max(0, depth - 1);
    if (ch === '&' && depth === 0) {
      cells.push(buf);
      buf = '';
    } else {
      buf += ch;
    }
  }
  cells.push(buf);
  return cells;
}

const BOX_START_RE = /\[박스시작\]/;
const BOX_END_RE = /\[박스끝\]/;
// VLM 추출 경로에서 넣는 "보기" 박스 경계 마커. 기존 HWPX 파이프라인은 `<보기>` 기호가 있는
// [박스시작]...[박스끝] 을 bogi 로 분류하지만, VLM 경로는 [보기시작]/[보기끝] 한 쌍으로
// 내려보낸다. 전처리 단계에서 [박스시작]+<보기>/[박스끝] 로 정규화해 기존 분기를 재사용한다.
const BOGI_MARKER_START_RE = /\[보기시작\]/g;
const BOGI_MARKER_END_RE = /\[보기끝\]/g;
// VLM 추출 경로에서 넣는 "이미 LaTeX tabular 로 재현된 표" 경계 마커.
// parseStemSegments 가 이 마커를 만나면 사이 내용을 그대로 raw LaTeX 블록으로 내보낸다.
const RAW_TABLE_START_RE = /\[표시작\]/;
const RAW_TABLE_END_RE = /\[표끝\]/;
const BOGI_RE = /<\s*보\s*기\s*>/;
const BOGI_ITEM_SPLIT_RE =
  /(?=(?:[ㄱ-ㅎ]\.\s|(?:\(|（)\s*[가나다라마바사아자차카타파하]\s*(?:\)|）)\s))/;
const BOGI_ITEM_RE =
  /^(?:([ㄱ-ㅎ])\.\s*|(?:\(|（)\s*([가나다라마바사아자차카타파하])\s*(?:\)|）)\s*)/;

function stripMarkers(text) {
  return String(text || '')
    .replace(PARAGRAPH_MARKER_RE, ' ')
    .replace(BOGI_MARKER_RE, '');
}

// 방어적 전처리: 외부에서 흘러들어온 MathJax 스타일 수식 구분자(\(...\), \[...\], $...$, $$...$$)
// 를 모두 "구분자만 벗기고 내부 내용은 그대로" 남긴다.
//
// 배경: 이 렌더러의 smartTexLine 은 한국어가 아닌 모든 연속 구간을 자동으로
//   $\displaystyle ...$ 로 감싼다. 그래서 stem/choice 본문에 이미 $...$ 나 \(...\)
//   가 들어 있으면 이중 감싸기가 발생해 xelatex 에서 "Bad math environment" 로 실패한다.
//   DB 에 들어오는 정상 경로(HWPX 추출기)는 구분자 없이 raw LaTeX 명령만 남기므로
//   이 전처리는 "그 규약을 지키지 않은 입력을 한 번 정리" 하는 역할.
function stripMathDelimiters(text) {
  let s = String(text || '');
  if (!s) return s;
  // "\\(" → "\(" / "\\[" → "\[" (오탈자 방어)
  s = s.replace(/\\\\\(/g, '\\(').replace(/\\\\\)/g, '\\)');
  s = s.replace(/\\\\\[/g, '\\[').replace(/\\\\\]/g, '\\]');
  // \[...\] → inner / \(...\) → inner
  s = s.replace(/\\\[([\s\S]*?)\\\]/g, (_, inner) => inner);
  s = s.replace(/\\\(([\s\S]*?)\\\)/g, (_, inner) => inner);
  // $$...$$ → inner / $...$ → inner (개행 미포함, 너무 긴 매치 방지)
  s = s.replace(/\$\$([\s\S]*?)\$\$/g, (_, inner) => inner);
  s = s.replace(/\$([^$\n]+?)\$/g, (_, inner) => inner);
  return s;
}

function escapeLatexText(text) {
  return String(text || '')
    .replace(/\\/g, '\x00BK\x00')
    .replace(/[&%$#_{}]/g, (ch) => `\\${ch}`)
    .replace(/~/g, '\\textasciitilde{}')
    .replace(/\^/g, '\\textasciicircum{}')
    .replace(/\x00BK\x00/g, '\\textbackslash{}');
}

/**
 * Korean segment regex — MUST start with a Hangul syllable.
 * Then continues through Hangul + whitespace + common Korean punctuation.
 * Standalone spaces/commas between non-Korean chars do NOT match,
 * so "x = 6, y = -2" stays as one contiguous math segment.
 */
const KOREAN_SEG_RE =
  /[\uAC00-\uD7AF\u1100-\u11FF\u3130-\u318F가-힣][\uAC00-\uD7AF\u1100-\u11FF\u3130-\u318F가-힣\s,.\u3001\u3002?!:;·…\u00B7]*/g;

function buildEquationLookup(equations) {
  if (!Array.isArray(equations) || equations.length === 0) return [];
  return equations
    .filter((eq) => eq?.latex && (eq.raw || eq.latex))
    .map((eq) => ({ raw: String(eq.raw || eq.latex), latex: String(eq.latex) }))
    .sort((a, b) => b.raw.length - a.raw.length);
}

function applyEquationLookup(mathContent, lookup) {
  if (lookup.length === 0) return mathContent;
  let result = mathContent;
  for (const { raw, latex } of lookup) {
    if (raw === latex) continue;
    if (!result.includes(raw)) continue;
    if (latex === `\\${raw}` && result.includes(latex)) continue;
    const escaped = raw.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const re = new RegExp(`(?<!\\\\)${escaped}`, 'g');
    result = result.replace(re, latex);
  }
  return result;
}

function splitMathAtTopLevelCommaSpace(math) {
  const chunks = [];
  let start = 0;
  let depth = 0;
  for (let i = 0; i < math.length; i++) {
    const ch = math[i];
    // \left ... \right 는 논리적 괄호 쌍이므로 depth 로 추적.
    if (ch === '\\') {
      if (math.startsWith('\\left', i)) {
        depth += 1;
        i += 4;
        continue;
      }
      if (math.startsWith('\\right', i)) {
        depth = Math.max(0, depth - 1);
        i += 5;
        continue;
      }
      // 기타 백슬래시 매크로는 건너뜀 (e.g. \frac, \times) — 그 안의 `, ` 도 현재 depth 그대로 유지.
      continue;
    }
    if (ch === '{' || ch === '(' || ch === '[') depth += 1;
    else if (ch === '}' || ch === ')' || ch === ']') depth = Math.max(0, depth - 1);
    else if (depth === 0 && ch === ',' && i + 1 < math.length && /\s/.test(math[i + 1])) {
      const piece = math.substring(start, i).trim();
      if (piece) chunks.push(piece);
      let j = i + 1;
      while (j < math.length && /\s/.test(math[j])) j += 1;
      start = j;
      i = j - 1;
    }
  }
  const tail = math.substring(start).trim();
  if (tail) chunks.push(tail);
  if (chunks.length === 0) chunks.push(math);
  return chunks;
}

function normalizeMathSegment(mathContent) {
  let out = String(mathContent || '');

  out = out.replace(/×/g, '\\times');
  out = out.replace(/÷/g, '\\div');
  out = out.replace(/(?<!\\)%/g, '\\%');

  // 분수 크기 일관성: \frac 은 주변 math style(text/display) 에 따라 크기가 바뀐다.
  //   본문은 $\displaystyle ...$ 로 감싸지만, 중첩 분수(분자/분모 안의 \frac)는
  //   자동으로 \textstyle 로 축소되어 '큰 분수 안의 작은 분수' 가 생긴다.
  //   → \dfrac 은 어느 컨텍스트에서도 강제 displaystyle 이므로 모든 \frac 을 \dfrac 로 통일.
  //   이미 \dfrac 또는 \tfrac 로 명시된 경우는 건드리지 않는다.
  out = out.replace(/\\frac(?![a-zA-Z])/g, '\\dfrac');

  // 지수 자리에 들어간 빈칸은 일반 답안 빈칸보다 작은 정사각형으로 렌더링.
  out = out.replace(/\^\s*\{\s*box\{~~\}\s*\}/g, '^{\\mtexponentemptybox{}}');
  out = out.replace(/\^\s*box\{~~\}/g, '^{\\mtexponentemptybox{}}');
  out = out.replace(/\^\s*\{\s*\\square\s*\}/g, '^{\\mtexponentemptybox{}}');
  out = out.replace(/\^\s*\\square(?![a-zA-Z])/g, '^{\\mtexponentemptybox{}}');

  // box{~~} (빈 박스) → 3:2 비율 직사각형 빈칸 네모.
  out = out.replace(/box\{~~\}/g, '\\mtemptybox{}');
  out = out.replace(/\\square(?![a-zA-Z])/g, '\\mtemptybox{}');
  // DB 에 이미 들어가 있는 \boxed{\phantom{...}} 형태도 3:2 빈칸 네모로 치환.
  out = out.replace(/\\boxed\s*\{\s*\\phantom\s*\{[^}]*\}\s*\}/g, '\\mtemptybox{}');
  // box{X} (내용이 있는 박스) → \boxed{X}. 빈 경우는 위 규칙이 이미 처리.
  out = out.replace(/(?<!\\)box\{([^}]+)\}/g, '\\boxed{$1}');

  out = out.replace(/\\left\s*\{/g, '\\left\\{');
  out = out.replace(/\\left\s*\}/g, '\\left\\}');
  out = out.replace(/\\right\s*\{/g, '\\right\\{');
  out = out.replace(/\\right\s*\}/g, '\\right\\}');

  out = out.replace(/\\left\s+([()\[\]|.])/g, '\\left$1');
  out = out.replace(/\\right\s+([()\[\]|.])/g, '\\right$1');

  out = out.replace(/\\left\s+\\([a-zA-Z]+)/g, '\\left\\\\$1');
  out = out.replace(/\\right\s+\\([a-zA-Z]+)/g, '\\right\\\\$1');

  out = out.replace(/\\left\|/g, '\\left|\\,');
  out = out.replace(/\\right\|/g, '\\,\\right|');
  out = out.replace(/(?<!\\left|\\right)\|([^|]+)\|/g, '\\left|\\,$1\\,\\right|');
  out = expandCasesEnvironmentToDisplayArray(out, {
    thinBrace: true,
    braceXScale: 0.65,
    braceYScale: 0.72,
    braceGap: '\\hspace{0.22em}',
  });

  return out;
}

/**
 * `[공백:N]` 마커를 `\hspace*{Nem}` 로 치환.
 *   - star 버전(`\hspace*`) 을 써서 줄 시작/끝에서도 collapse 되지 않도록 보장.
 *   - `Nem` 은 em 단위 → 본문 폰트 크기에 비례해 한글 글자 폭과 일관.
 */
function spaceMarkerToTex(amount) {
  const n = Number.isFinite(amount) ? amount : 1;
  return `\\hspace*{${n}em}`;
}

/**
 * 텍스트를 [공백:N] 마커로 분해한 뒤, 텍스트 조각은 smartTexLineCore 로,
 * 공백 조각은 `\hspace*{Nem}` 로 각각 변환해 이어 붙인다.
 *
 * 마커를 smartTexLineCore 안쪽까지 흘려보내면 KOREAN_SEG_RE 가 `[` / `]` / 숫자에서
 * 세그먼트를 끊어서 math 모드로 잘못 분류되거나 사라질 수 있다. 최상단에서 미리
 * 분리해 처리하면 rendering hint 가 안전하게 LaTeX 공간 명령으로 치환된다.
 */
function smartTexLine(text, equations) {
  const raw = String(text ?? '');
  if (!raw) return '';

  if (raw.includes('[밑줄]')) {
    const pieces = splitByUnderlineMarkers(raw);
    if (!pieces.some((piece) => piece.type === 'underline')) {
      return smartTexLineCore(raw.replace(/\[\/?밑줄\]/g, ''), equations);
    }
    const rendered = [];
    for (const piece of pieces) {
      if (piece.type === 'underline') {
        const inner = smartTexLine(piece.value, equations);
        if (inner) rendered.push(`\\uline{${inner}}`);
        continue;
      }
      const tex = smartTexLine(piece.value, equations);
      if (tex) rendered.push(tex);
    }
    return rendered.join('');
  }

  // 공백 마커가 없는 일반 경로: 기존 동작과 완전히 동일.
  if (!raw.includes('[공백:')) {
    return smartTexLineCore(raw, equations);
  }

  const pieces = splitBySpaceMarkers(raw);
  const parts = [];
  for (const piece of pieces) {
    if (piece.type === 'space') {
      parts.push(spaceMarkerToTex(piece.amount));
      continue;
    }
    const tex = smartTexLineCore(piece.value, equations);
    if (tex) parts.push(tex);
  }
  return parts.join('');
}

function protectLatexTextBlocks(input) {
  const source = String(input || '');
  if (!source.includes('\\text{')) {
    return {
      text: source,
      restore: (value) => value,
    };
  }

  const blocks = [];
  let out = '';
  let cursor = 0;
  while (cursor < source.length) {
    const start = source.indexOf('\\text{', cursor);
    if (start < 0) {
      out += source.slice(cursor);
      break;
    }

    let i = start + '\\text{'.length;
    let depth = 1;
    while (i < source.length && depth > 0) {
      const ch = source[i];
      if (ch === '\\') {
        i += 2;
        continue;
      }
      if (ch === '{') depth += 1;
      if (ch === '}') depth -= 1;
      i += 1;
    }

    if (depth !== 0) {
      out += source.slice(cursor);
      break;
    }

    const token = `\u0000LATEXTEXT${blocks.length}\u0000`;
    blocks.push(source.slice(start, i));
    out += source.slice(cursor, start) + token;
    cursor = i;
  }

  return {
    text: out,
    restore(value) {
      let restored = String(value || '');
      for (let i = 0; i < blocks.length; i += 1) {
        restored = restored.replaceAll(`\u0000LATEXTEXT${i}\u0000`, blocks[i]);
      }
      return restored;
    },
  };
}

function smartTexLineCore(text, equations) {
  // 외부 경로로 들어온 \(...\)/$...$ 이중 감싸기 방지를 위해 진입 시 한 번 벗긴다.
  const clean = stripMathDelimiters(stripMarkers(text)).trim();
  if (!clean) return '';

  const lookup = buildEquationLookup(equations);

  const subQMatch = clean.match(/^\((\d+)\)\s+/);
  let prefix = '';
  let body = clean;
  if (subQMatch) {
    prefix = `\\text{(${subQMatch[1]})}\\;`;
    body = clean.substring(subQMatch[0].length);
  }
  const protectedText = protectLatexTextBlocks(body);
  body = protectedText.text;

  const parts = [];
  let lastEnd = 0;

  for (const m of body.matchAll(KOREAN_SEG_RE)) {
    if (m.index > lastEnd) {
      parts.push({ type: 'math', value: body.substring(lastEnd, m.index) });
    }
    parts.push({ type: 'text', value: m[0] });
    lastEnd = m.index + m[0].length;
  }
  if (lastEnd < body.length) {
    parts.push({ type: 'math', value: body.substring(lastEnd) });
  }
  if (parts.length === 0) {
    parts.push({ type: 'math', value: body });
  }

  const result = parts
    .map((seg) => {
      if (seg.type === 'text') return escapeLatexText(seg.value);

      const raw = seg.value;
      const leadSp = /^\s/.test(raw) ? ' ' : '';
      const trailSp = /\s$/.test(raw) ? ' ' : '';
      let math = raw.trim();
      if (!math) return (leadSp || trailSp) ? ' ' : '';
      math = applyEquationLookup(math, lookup);
      math = normalizeMathSegment(math);
      // 최상위 깊이의 ", "는 math mode 안에서 좁게 붙어서, 한글 띄어쓰기 폭과
      // 맞지 않는다. 괄호/대괄호/중괄호 밖 `, `는 math를 빠져나와 text mode
      // 콤마+공백으로 렌더한 뒤 다시 math 로 진입한다. (`x, y` → `$x$, $y$`)
      const mathChunks = splitMathAtTopLevelCommaSpace(math);
      const rendered = mathChunks
        .map((chunk) => `$\\displaystyle ${chunk}$`)
        .join(', ');
      return `${leadSp}${rendered}${trailSp}`;
    })
    .join('');

  if (prefix) {
    return protectedText.restore(`$\\displaystyle ${prefix}$${result}`);
  }
  return protectedText.restore(result);
}

/**
 * 본문에서 세트형 하위문항 마커 "(N) " 가 중간에 오는 경우 (문장 중간에 (1), (2))
 * 을 별개의 paragraph 로 분리한다. "(N)" 은 반드시 앞뒤가 공백이어야 하며,
 * "(1)을 이용하여" 처럼 뒤가 한글 조사로 붙는 경우는 분할하지 않는다.
 */
function splitAtSubQuestionMarkers(sub) {
  const re = /(?:^|\s)(\(\d+\))(?=\s)/g;
  const cuts = [];
  let m;
  while ((m = re.exec(sub)) !== null) {
    // 매치의 시작을 "(" 위치로 맞춤 (앞 공백은 제외).
    const parenIdx = sub.indexOf('(', m.index);
    if (parenIdx >= 0) cuts.push(parenIdx);
  }
  if (cuts.length === 0) return [sub];
  if (cuts[0] !== 0) cuts.unshift(0);
  const pieces = [];
  for (let i = 0; i < cuts.length; i += 1) {
    const start = cuts[i];
    const end = i + 1 < cuts.length ? cuts[i + 1] : sub.length;
    const piece = sub.substring(start, end).trim();
    if (piece) pieces.push(piece);
  }
  return pieces;
}

/**
 * 본문 텍스트 라인 하나에 대해 대화형/세트형 하위문항 패턴을 감지해
 * 2번째 줄부터 들여쓰기(hangindent) 되도록 LaTeX 을 생성한다.
 * hangindent 는 paragraph 단위로만 유효하므로, 결과 말미에 반드시 \par 을 넣어
 * 그룹/마진이 닫히기 전에 현재 paragraph 의 line-break 가 결정되도록 한다.
 */
function renderStemTextLine(sub, equations) {
  // 사용자 요청 23차: 문항 본문(stem text) 줄간격을 본문 기본(\setstretch{1.7}) 대비
  //   10% 축소하여 `\setstretch{1.53}` (=1.7×0.9) 로 조판한다.
  //   → 보기박스/조건박스/그림/표/5지선다형 보기는 별도 경로로 조판되므로 영향 없음
  //     (이들은 renderStemTextLine 을 거치지 않음 — seg.type !== 'text').
  //   래퍼: `{\setstretch{1.53} <inner> \par}` 로 감싸 해당 paragraph 스코프에만 적용.
  //   grouping `{}` 로 외부 stretch(1.7) 로 정확히 원복 → 이후 다른 요소에 오염 없음.
  //
  // 사용자 요청 24차: stem 줄간격 축소(1.7→1.53) 로 `\baselineskip` 이 10% 줄어들면서
  //   분수/큰 수식이 포함된 행의 위·아래 여백이 TeX 의 `\lineskip` fallback 값(기본 1pt)
  //   으로 떨어져 붙어 보이는 부작용이 발생. → 본문 stem 영역에서도 `\lineskip` 과
  //   `\lineskiplimit` 를 em 기반으로 설정해, baseline 부족 상황에서 최소 간격을 보장한다.
  //   (choice 영역의 `\lineskip=1.2em` 과 유사한 접근, 값은 보수적으로 0.6em 로 설정해
  //    일반 본문 행간까지 과도하게 늘어나지 않도록.)
  const STEM_STRETCH = '1.53';
  const wrapStem = (inner) => `{\\setstretch{${STEM_STRETCH}}\\lineskiplimit=0.4em\\lineskip=0.6em${inner}\\par}`;
  // 세트형 하위문항 (1), (2), ...
  const subQ = sub.match(/^\((\d+)\)\s+(.*)$/);
  if (subQ) {
    const labelTex = `(${subQ[1]})\\ `;
    const restTex = smartTexLine(subQ[2], equations);
    return wrapStem(`{\\setbox0=\\hbox{${labelTex}}\\hangindent=\\wd0\\hangafter=1\\noindent\\makebox[\\wd0][l]{${labelTex}}${restTex}\\par}`);
  }
  // 대화형 "이름 : 내용" (이름은 12자 이내).
  const dialogue = sub.match(/^([^:\n]{1,12}?)\s*:\s+(.*)$/);
  if (dialogue) {
    const namePart = dialogue[1].trim();
    const rest = dialogue[2];
    if (namePart) {
      const nameTex = smartTexLine(namePart, equations);
      const restTex = smartTexLine(rest, equations);
      const labelTex = `${nameTex}\\ :\\ `;
      return wrapStem(`{\\setbox0=\\hbox{${labelTex}}\\hangindent=\\wd0\\hangafter=1\\noindent\\makebox[\\wd0][l]{${labelTex}}${restTex}\\par}`);
    }
  }
  return wrapStem(smartTexLine(sub, equations));
}

/* ------------------------------------------------------------------ */
/*  Box parsing: [박스시작]/[박스끝] segment detection                  */
/* ------------------------------------------------------------------ */

function parseStemSegments(stem, stemLineAligns = []) {
  // VLM 이 보내는 [보기시작]/[보기끝] 을 기존 [박스시작]+<보기> 표기로 정규화.
  //   [보기시작]          →  [박스시작]\n<보기>
  //   [보기끝]            →  [박스끝]
  // 이렇게 바꾸면 아래 기존 분기(BOGI_RE) 가 자연스럽게 bogi 세그먼트로 분류해 준다.
  //
  // stemLineAligns 는 stem 을 "\n 기준" 으로 split 했을 때 각 라인의 문단 정렬값
  // ('left'|'center'|'right'|'justify') 병렬 배열. 여기서는 BOGI 정규화로 라인 수가
  // 변할 수 있으므로, 원본 라인 기준으로 정렬값을 한 번 매핑한 뒤 확장 라인에 전파.
  const rawLines = String(stem).split('\n');
  const rawAligns = Array.isArray(stemLineAligns) ? stemLineAligns.slice() : [];
  while (rawAligns.length < rawLines.length) rawAligns.push('left');
  rawAligns.length = rawLines.length;

  const lines = [];
  const lineAligns = [];
  for (let i = 0; i < rawLines.length; i += 1) {
    const one = rawLines[i];
    const align = String(rawAligns[i] || 'left').toLowerCase();
    const expanded = one
      .replace(BOGI_MARKER_START_RE, '[박스시작]\n<보기>')
      .replace(BOGI_MARKER_END_RE, '[박스끝]')
      .split('\n');
    for (const piece of expanded) {
      lines.push(piece);
      lineAligns.push(align);
    }
  }
  const segments = [];
  let inBox = false;
  let boxLines = [];
  let boxLineAligns = [];
  let inRawTable = false;
  let rawTableLines = [];
  let rawTableLineAligns = [];
  let textLines = [];
  let textLineAligns = [];

  function flushText() {
    if (textLines.length > 0) {
      segments.push({
        type: 'text',
        lines: [...textLines],
        lineAligns: [...textLineAligns],
      });
      textLines = [];
      textLineAligns = [];
    }
  }

  function flushBox() {
    if (boxLines.length === 0) return;
    const hasTable = boxLines.some((l) => /^\[표행\]$/.test(l.trim()));
    if (hasTable) {
      segments.push({
        type: 'table',
        lines: [...boxLines],
        lineAligns: [...boxLineAligns],
      });
    } else {
      const hasBogi = boxLines.some((l) => BOGI_RE.test(l));
      segments.push({
        type: hasBogi ? 'bogi' : 'deco',
        lines: [...boxLines],
        lineAligns: [...boxLineAligns],
      });
    }
    boxLines = [];
    boxLineAligns = [];
  }

  function flushRawTable() {
    if (rawTableLines.length === 0) return;
    segments.push({
      type: 'raw_tabular',
      lines: [...rawTableLines],
      lineAligns: [...rawTableLineAligns],
    });
    rawTableLines = [];
    rawTableLineAligns = [];
  }

  for (let lineIdx = 0; lineIdx < lines.length; lineIdx += 1) {
    const line = lines[lineIdx];
    const lineAlign = lineAligns[lineIdx] || 'left';
    // [표시작]/[표끝] 은 "VLM 이 이미 LaTeX tabular 를 써 둔" 구간. 그대로 통과시킨다.
    if (!inRawTable && RAW_TABLE_START_RE.test(line)) {
      flushText();
      if (inBox) {
        // 박스 내부에서 표 시작은 정상 경로가 아님 → 박스부터 닫는다.
        inBox = false;
        flushBox();
      }
      inRawTable = true;
      const cleaned = line.replace(RAW_TABLE_START_RE, '').trim();
      if (cleaned) { rawTableLines.push(cleaned); rawTableLineAligns.push(lineAlign); }
      if (RAW_TABLE_END_RE.test(cleaned)) {
        const idx = rawTableLines.length - 1;
        if (idx >= 0) rawTableLines[idx] = rawTableLines[idx].replace(RAW_TABLE_END_RE, '').trim();
        inRawTable = false;
        flushRawTable();
      }
      continue;
    }
    if (inRawTable) {
      if (RAW_TABLE_END_RE.test(line)) {
        const cleaned = line.replace(RAW_TABLE_END_RE, '').trim();
        if (cleaned) { rawTableLines.push(cleaned); rawTableLineAligns.push(lineAlign); }
        inRawTable = false;
        flushRawTable();
      } else {
        rawTableLines.push(line);
        rawTableLineAligns.push(lineAlign);
      }
      continue;
    }

    const hasStart = BOX_START_RE.test(line);
    const hasEnd = BOX_END_RE.test(line);

    if (hasStart && !inBox) {
      flushText();
      inBox = true;
      const cleaned = line.replace(/\[박스시작\]/g, '').trim();
      if (cleaned) { boxLines.push(cleaned); boxLineAligns.push(lineAlign); }

      if (hasEnd) {
        const idx = boxLines.length - 1;
        if (idx >= 0)
          boxLines[idx] = boxLines[idx].replace(/\[박스끝\]/g, '').trim();
        inBox = false;
        flushBox();
      }
      continue;
    }

    if (hasEnd && inBox) {
      const cleaned = line.replace(/\[박스끝\]/g, '').trim();
      if (cleaned) { boxLines.push(cleaned); boxLineAligns.push(lineAlign); }
      inBox = false;
      flushBox();
      continue;
    }

    if (inBox) {
      boxLines.push(line);
      boxLineAligns.push(lineAlign);
    } else {
      textLines.push(line);
      textLineAligns.push(lineAlign);
    }
  }

  if (inRawTable && rawTableLines.length > 0) {
    segments.push({
      type: 'raw_tabular',
      lines: [...rawTableLines],
      lineAligns: [...rawTableLineAligns],
    });
  }
  if (inBox && boxLines.length > 0) {
    const hasTable = boxLines.some((l) => /^\[표행\]$/.test(l.trim()));
    if (hasTable) {
      segments.push({
        type: 'table',
        lines: [...boxLines],
        lineAligns: [...boxLineAligns],
      });
    } else {
      const hasBogi = boxLines.some((l) => BOGI_RE.test(l));
      segments.push({
        type: hasBogi ? 'bogi' : 'deco',
        lines: [...boxLines],
        lineAligns: [...boxLineAligns],
      });
    }
  }

  // 꼬리 정리: text 세그먼트의 마지막 라인이 공백이거나 [문단]만 남아있으면 제거.
  // 박스/표/그림 뒤에 불필요한 \par 가 붙어 세로 간격이 벌어지는 것을 방지한다.
  for (const seg of segments) {
    if (seg.type !== 'text') continue;
    while (seg.lines.length > 0) {
      const last = seg.lines[seg.lines.length - 1];
      const stripped = String(last || '').replace(PARAGRAPH_MARKER_RE, '').trim();
      if (stripped === '') {
        seg.lines.pop();
        if (Array.isArray(seg.lineAligns)) seg.lineAligns.pop();
      } else {
        break;
      }
    }
    // 마지막 라인 내부의 꼬리 [문단] 도 제거 (abc[문단][문단][문단] -> abc).
    if (seg.lines.length > 0) {
      const idx = seg.lines.length - 1;
      seg.lines[idx] = String(seg.lines[idx] || '').replace(/(?:\s*\[문단\]\s*)+\s*$/, '');
    }
  }
  // 완전히 빈 text 세그먼트는 제거.
  for (let i = segments.length - 1; i >= 0; i--) {
    if (segments[i].type === 'text' && segments[i].lines.length === 0) {
      segments.splice(i, 1);
    }
  }
  flushText();

  // ─── 후처리: text 세그먼트 안에 섞여 있는 [그림] 마커를 별도 'figure' segment 로 승격 ───
  //   목적: 표/박스와 동일하게 블록 전환 gap 로직(isBigBlockType / gapBefore·gapAfter)이
  //         그림에도 그대로 적용되도록 한다. 그림 앞쪽 gap 이 0.40em (outerPendingEmpty)
  //         로 들어가고 뒤쪽이 6pt (BLOCK_GAP) 로 끝나던 문제 해결.
  //   규칙:
  //     - seg.lines 를 순회하며 각 라인을 [그림] 마커 경계로 split.
  //     - 마커가 있으면 그 앞 텍스트 조각 → text seg flush, 마커 자체 → figure seg,
  //       마커 뒤 조각 → 다음 text seg 에 이어붙임.
  //     - 원래 [그림] 마커는 한 개씩 다시 방출(여러 개 그림은 각각 별도 figure seg) →
  //       replaceFigureMarkers 가 기존대로 figIdx 를 순차 소비.
  //     - 마커가 없는 라인은 그대로 현재 text seg 에 누적.
  // split 경계에는 plain [그림]/[도형]/[도표] 와 [[PB_FIG_id]] 두 형태 모두 포함.
  //   split() 은 capture group 을 결과에 남기므로 단순 (그룹) 하나로 감쌌다.
  const FIGURE_SPLIT_RE = /(\[\[PB_FIG_[^\]]+\]\]|\[(?:그림|도형|도표)\])/g;
  const FIGURE_ANY_RE = /\[\[PB_FIG_[^\]]+\]\]|\[(?:그림|도형|도표)\]/;
  const FIGURE_SINGLE_RE = /^\[\[PB_FIG_[^\]]+\]\]$|^\[(?:그림|도형|도표)\]$/;
  const out = [];
  for (const seg of segments) {
    if (seg.type !== 'text') { out.push(seg); continue; }
    let bufLines = [];
    let bufAligns = [];
    const flushTextBuf = () => {
      const hasContent = bufLines.some((l) => {
        const s = String(l || '').replace(PARAGRAPH_MARKER_RE, '').trim();
        return s.length > 0;
      });
      if (hasContent) {
        out.push({
          type: 'text',
          lines: bufLines.slice(),
          lineAligns: bufAligns.slice(),
        });
      }
      bufLines = [];
      bufAligns = [];
    };
    const segAligns = Array.isArray(seg.lineAligns) ? seg.lineAligns : [];
    for (let rawIdx = 0; rawIdx < seg.lines.length; rawIdx += 1) {
      const rawLine = seg.lines[rawIdx];
      const rawAlign = segAligns[rawIdx] || 'left';
      const line = String(rawLine || '');
      if (!FIGURE_ANY_RE.test(line)) {
        bufLines.push(line);
        bufAligns.push(rawAlign);
        continue;
      }
      const pieces = line.split(FIGURE_SPLIT_RE);
      for (let i = 0; i < pieces.length; i += 1) {
        const piece = pieces[i];
        if (!piece) continue;
        if (FIGURE_SINGLE_RE.test(piece)) {
          flushTextBuf();
          out.push({ type: 'figure', lines: [piece], lineAligns: [rawAlign] });
        } else {
          bufLines.push(piece);
          bufAligns.push(rawAlign);
        }
      }
    }
    flushTextBuf();
  }
  return out;
}

/* ------------------------------------------------------------------ */
/*  Box rendering: tcolorbox environments                              */
/* ------------------------------------------------------------------ */

function flattenBoxParagraphLines(lines, { stripBogi = false } = {}) {
  const out = [];
  for (const l of lines) {
    let src = String(l || '');
    if (stripBogi) src = src.replace(BOGI_RE, '');
    if (!src.trim()) continue;
    const pieces = src.split(PARAGRAPH_MARKER_RE);
    const markers = src.match(PARAGRAPH_MARKER_RE) || [];
    for (let i = 0; i < pieces.length; i += 1) {
      const text = pieces[i].trim();
      if (text) out.push(text);
      if (i < markers.length) out.push(BOX_PARAGRAPH_BREAK);
    }
  }
  return out;
}

function renderBogiItems(lines, equations, replaceFigureMarkers = null) {
  const cleaned = flattenBoxParagraphLines(lines, { stripBogi: true });
  const items = [];
  for (const line of cleaned) {
    if (line === BOX_PARAGRAPH_BREAK) {
      items.push(line);
      continue;
    }
    items.push(...line.split(BOGI_ITEM_SPLIT_RE).filter((s) => s.trim()));
  }

  const rendered = [];
  for (const item of items) {
    if (item === BOX_PARAGRAPH_BREAK) {
      rendered.push('\\par\\vspace{0.45em}');
      continue;
    }
    const withFigs = replaceFigureMarkers ? replaceFigureMarkers(item) : item;
    // figure 마커만 있었던 항목은 \includegraphics 블록으로 바뀌어 내려온다.
    // smartTexLine을 거치면 백슬래시가 이스케이프되어 버리므로 그대로 삽입한다.
    if (/\\includegraphics/.test(withFigs)) {
      rendered.push(withFigs);
      continue;
    }
    const match = withFigs.match(BOGI_ITEM_RE);
    if (match) {
      const label = match[1] || match[2];
      const text = withFigs.replace(BOGI_ITEM_RE, '').trim();
      const labelTex = label.match(/^[ㄱ-ㅎ]$/)
        ? `${label}.`
        : `(${label})`;
      // 대화형/조건제시박스와 동일한 \wd0 측정 방식으로 통일 → 정확히 "라벨 + 1공백" 폭.
      const labelFull = `${escapeLatexText(labelTex)}\\ `;
      rendered.push(
        `{\\setbox0=\\hbox{${labelFull}}\\hangindent=\\wd0\\hangafter=1\\noindent\\makebox[\\wd0][l]{${labelFull}}${smartTexLine(text, equations)}\\par}`,
      );
    } else {
      const tex = smartTexLine(withFigs.trim(), equations);
      if (tex.trim()) rendered.push(`\\noindent ${tex}\\par`);
    }
  }
  return rendered.join('\n');
}

function renderBogiBoxLatex(lines, equations, replaceFigureMarkers = null) {
  let content = renderBogiItems(lines, equations, replaceFigureMarkers);
  // 보기박스 본문에 "정렬 힌트가 될 글자" 가 전혀 없으면 가운데 정렬.
  // (예: Q5 보기박스의 `-0.7, -\frac{6}{3}, 0, ...` 처럼 숫자/수식만 있는 케이스)
  if (boxContentIsCenteredOnly(lines)) {
    const cleaned = content
      .replace(/\\noindent\s*/g, '')
      .replace(/\\par\s*$/g, '');
    content = `\\begin{center}${cleaned}\\end{center}`;
  }
  // 사용자 요청 27차: "보 기" 사이 공백을 한 글자 폭(≈1em) 으로 확장.
  //   `smartTexLine` 은 기본적으로 Hangul 구간 내 공백을 그대로 넘기기 때문에
  //   xetexko 의 Hangul glue 로 좁게 조판됨. text-mode `\hspace{1em}` 으로 치환해
  //   시각적 한 글자 만큼 간격을 확보한다.
  let bogiLabelTex = smartTexLine('<보 기>', []);
  bogiLabelTex = bogiLabelTex.replace('보 기', '보\\hspace{0.8em}기');
  // 사용자 요청 29차: 꺽쇠 양쪽 여백이 과하게 보이는 문제 해결.
  //   원인 (중첩):
  //     (a) TikZ 노드의 `inner xsep=3pt` 가 fill=white 영역을 bbox 기준 좌·우 3pt 씩 확장
  //         → 선이 글리프에서 3pt 떨어진 지점에서 끊어진 것처럼 보임 (주범).
  //     (b) math-mode `<`/`>` 글리프의 자연 side-bearing. math 경계라 `\thickmuskip` 은
  //         추가되지 않으나, 폰트 고유의 sidebearing 이 약간 남음.
  //   해결:
  //     1) 아래 overlay 에서 `inner xsep=0pt` 로 노드 좌우 패딩 제거.
  //     2) 여기서 label 양 끝에 `\kern-0.5pt` 를 넣어 bbox 를 소폭 당겨, 남아있는 글리프
  //        side-bearing 까지 상쇄 → 꺽쇠 꼬리가 선 안쪽으로 박히는 느낌을 만든다.
  //   사용자 요청 30차: "보 기" 문자 간격을 1em → 0.8em 으로 축소 (기존 대비 80%).
  bogiLabelTex = `\\kern-0.5pt ${bogiLabelTex}\\kern-0.5pt`;
  return [
    '\\begin{tcolorbox}[',
    '  enhanced,',
    '  width=\\dimexpr\\linewidth-1em\\relax,',
    '  colback=white, colframe=black, boxrule=0.4pt,',
    '  arc=0pt, outer arc=0pt,',
    '  before skip=0pt, after skip=0pt,',
    // 사용자 요청 25차: `boxed title` / `attach boxed title to top center` 조합은
    //   내부 padding 과 `\tcboxedtitleheight` 연산식 때문에 상단선과 〈 기호 사이 gap 을
    //   완벽히 제거하기 어렵고, `fonttitle` 로도 late styling 이 간헐적으로 적용되어
    //   본문 폰트와 일치시키는 것도 불안정했다. → `overlay` + TikZ node 방식으로 전환.
    //   - TikZ `\node` 를 frame.north 중앙에 배치하고 `fill=white` 로 선을 덮어 박힌 형태
    //     재현.
    //   - `anchor=center` + `inner ysep=1pt` 로 상단선이 타이틀 y-center 를 가로지르게
    //     → 〈/〉 상·하단이 선과 맞닿아 보이도록.
    //   - `inner xsep=3pt` 로 좌우 패딩만 미세하게 확보 (상단선 끊어지는 폭).
    //   - 미세 조정이 필요하면 `at ([yshift=...pt]frame.north)` 의 yshift 값으로 수직 위치
    //     조절 가능.
    // 사용자 요청 26차: 꺽쇠 글리프가 본문 stem 과 달라 보이는 문제 해결.
    //   원인: 본문의 비-한글 문자(꺽쇠 포함)는 `smartTexLine` 에서 math-mode `$\displaystyle …$`
    //     로 분기되어 "math font 의 < >" 로 조판되는 반면, 라벨은 text-mode `\normalfont`
    //     경로로 "main hangul font 의 〈 〉" 가 되어 문자 자체와 글리프 디자인 모두 다르다.
    //   해결: 라벨 원문을 본문에서 실제로 사용되는 ASCII `<` `>` 로 교체하고, 동일한
    //     `smartTexLine` 경로를 통과시켜 본문과 같은 조판 파이프라인을 그대로 따르게 한다.
    //     결과 LaTeX = `$\displaystyle <$보 기$\displaystyle >$`
    //     → 꺽쇠는 본문 math-mode 와 동일 폰트/글리프, "보 기" 는 본문과 동일 hangul font.
    // 사용자 요청 28차: 라벨이 상단선과 "박혀 있는" 느낌이 되도록 `\raisebox` 트릭으로
    //   노드 content 의 bbox 크기를 0 으로 선언하고, TikZ anchor 계산을 확정화.
    //   - `\raisebox{-0.5ex}[0pt][0pt]{...}`:
    //       실제 글리프는 baseline 기준 -0.5ex 로 내려 배치되지만, 외부가 인식하는 ht/dp 는 0.
    //       → TikZ 노드 bbox 가 inner ysep 만큼만 확장 → anchor=center 계산이
    //         "bbox center = baseline" 으로 확정되어 frame.north 에 정확히 정렬.
    //   - `inner ysep=0.5ex` + `fill=white`:
    //       bbox 가 상하 0.5ex 씩 확장되고 흰 배경으로 채워져, 글자 영역에서 박스 상단선이
    //       정확히 가려져 "선에 박힌 느낌" 이 연출된다.
    //   - 수직 위치 미세 조정: `\raisebox{-0.5ex}` 값 하나만 ±0.1ex 단위로 조절하면 됨.
    //     (ex 단위라 폰트 크기에 비례해 자동 스케일)
    //   - 수평 여백 미세 조정: `inner xsep` (노드 패딩) + label 양끝 `\kern` 값으로 제어.
    //     현재는 `inner xsep=0pt` + 양끝 `\kern-0.5pt` → 꺽쇠가 선에 박힌 느낌.
    //     더 박히게: kern 을 -1pt 로 / 덜 박히게 (여백 확보): xsep 을 1~2pt 로 상향.
    //   - 수직 위치 미세 조정: `at ([yshift=-Npt]frame.north)` 의 yshift 값으로 라벨을
    //     위/아래로 이동 (음수 = 아래). 사용자 요청 30/31/32/33차 누적 조정: -0.5pt.
    '  overlay={\\node[anchor=center, fill=white, inner xsep=0pt, inner ysep=0.5ex]'
      + ' at ([yshift=-0.5pt]frame.north)'
      + ` {\\raisebox{-0.5ex}[0pt][0pt]{\\normalfont\\mdseries\\normalsize ${bogiLabelTex}}};},`,
    // 내부 위/아래 여백을 12pt 로 확대 → 항목과 박스 선의 숨통 확보.
    '  left=8pt, right=8pt, top=12pt, bottom=12pt',
    ']',
    '\\setlength{\\parskip}{0pt}',
    // lineskip/lineskiplimit 을 em 기반으로 지정해 폰트 크기에 비례 확장되도록 한다.
    //   \dfrac 포함 줄의 추가 수직 간격은 \lineskip 에 의해 결정되며, 폰트가 클수록 간격도 커진다.
    '\\lineskiplimit=0.4em\\lineskip=1.2em',
    // 〈보 기〉 타이틀이 윗변에 걸쳐 있으므로, 첫 항목과의 수직 간격을 미세하게 더 확보.
    '\\vspace*{2pt}',
    content,
    '\\end{tcolorbox}',
  ].join('\n');
}

function renderDecoLine(text, equations, replaceFigureMarkers = null) {
  const withFigs = replaceFigureMarkers ? replaceFigureMarkers(text) : text;
  // [그림] 마커가 \includegraphics 로 치환된 경우: smartTexLine 우회 후 그대로 삽입.
  if (/\\includegraphics/.test(withFigs)) {
    // figure 앞뒤 텍스트가 섞여 있을 수 있으므로, \begin{center}...\end{center} 블록과
    // 일반 텍스트를 순서대로 분리해 별도의 \par 로 배치한다.
    const segments = withFigs.split(/(\n?\\begin\{center\}[\s\S]*?\\end\{center\}\n?)/);
    const lines = [];
    for (const seg of segments) {
      if (!seg) continue;
      if (/\\includegraphics/.test(seg)) {
        lines.push(seg.trim());
      } else {
        const tex = smartTexLine(seg.trim(), equations);
        if (tex.trim()) lines.push(`\\noindent ${tex}`);
      }
    }
    return lines.join('\n\\par\n');
  }

  const labelMatch = withFigs.match(BOGI_ITEM_RE);
  if (labelMatch) {
    const label = labelMatch[1] || labelMatch[2];
    const rest = withFigs.replace(BOGI_ITEM_RE, '');
    const labelTex = label.match(/^[ㄱ-ㅎ]$/) ? `${label}.` : `(${label})`;
    const content = smartTexLine(rest, equations);
    // 레이블 + 1공백 폭(\wd0) 을 측정해 hangindent/첫줄 label 영역에 동일 적용 →
    // 내용 1행의 좌단과 2행+의 좌단이 정확히 일치.
    const labelFull = `${escapeLatexText(labelTex)}\\ `;
    return `{\\setbox0=\\hbox{${labelFull}}\\hangindent=\\wd0\\hangafter=1\\noindent\\makebox[\\wd0][l]{${labelFull}}${content}\\par}`;
  }

  // 대화형(이름 : 내용) 라인 처리.
  // - "이름:", "이름 :", "이름  :  " 등 공백/콜론 조합을 허용.
  // - 레이블(이름 + " : ")의 픽셀 폭을 측정해 2행부터 내용 시작 위치에 맞춰 hangindent.
  // - 콜론 뒤 공백은 \hbox 말미에서 drop 되므로, 마지막 공백을 \ (고정폭 공백)으로 치환한다.
  const dialogueMatch = withFigs.match(/^([^:\n]{1,12}?)\s*:\s+(.*)$/);
  if (dialogueMatch) {
    const namePart = dialogueMatch[1].trim();
    const restPart = dialogueMatch[2];
    if (namePart) {
      const nameTex = smartTexLine(namePart, equations);
      const contentTex = smartTexLine(restPart, equations);
      // "\ :\ " = 고정폭 공백 + 콜론 + 고정폭 공백. \hbox 내에서도 trailing space 손실 없이 폭이 보존됨.
      const labelTex = `${nameTex}\\ :\\ `;
      // \makebox[\wd0][l] 로 레이블 영역의 실제 폭을 고정 → 1행 content 의 좌측선과
      // hangindent 에 따른 2행+ 좌측선이 정확히 일치하도록 보장한다.
      return `{\\setbox0=\\hbox{${labelTex}}\\hangindent=\\wd0\\hangafter=1\\noindent\\makebox[\\wd0][l]{${labelTex}}${contentTex}\\par}`;
    }
  }

  return smartTexLine(withFigs, equations);
}

// 박스(보기/조건) 내용에 "정렬 힌트가 될 만한 글자" — 한글 낱자(문장부호 제외), ㄱㄴㄷ 라벨,
// \bullet, (가)/(나) 라벨, ㄱ./ㄴ. 라벨 — 이 하나도 없으면 "가운데 정렬" 모드로 렌더.
// 입력: 이미 flush 된 텍스트 라인(Array<string>). 마커(\[그림\] 등)는 무시하고 순수 본문만 본다.
function boxContentIsCenteredOnly(lines) {
  const joined = lines
    .map((l) =>
      String(l || '')
        .replace(PARAGRAPH_MARKER_RE, ' ')
        .replace(BOGI_RE, ''),
    )
    .join('\n')
    .trim();
  if (!joined) return false;
  if (/[가-힣ㄱ-ㅎ]/.test(joined)) return false;
  if (/\\bullet\b/.test(joined)) return false;
  if (BOGI_ITEM_RE.test(joined)) return false;
  return true;
}

// "\bullet" 로 시작하는 라인 여부. 앞쪽에 공백만 허용.
const BULLET_LINE_RE = /^\s*\\bullet\b\s*/;

// 한 줄짜리 \bullet 항목 → "bullet + 고정폭 공백 + 본문" 형태의 LaTeX 라인으로 렌더.
//   - \wd0 = "\bullet\ " 의 폭으로 측정 → hangindent/첫줄 라벨 영역을 동일 폭으로 고정
//   - 본문은 smartTexLine 을 거쳐 수식/텍스트 자동 처리
//   - \ (backslash-space) 를 뒤에 붙여 bullet 뒤 1공백을 LaTeX 에서 절대 소멸하지 않도록 보장
function renderBulletLine(rawLine, equations, replaceFigureMarkers = null) {
  const stripped = rawLine.replace(BULLET_LINE_RE, '');
  const withFigs = replaceFigureMarkers
    ? replaceFigureMarkers(stripped)
    : stripped;
  const contentTex = smartTexLine(withFigs, equations);
  const labelTex = `$\\bullet$\\ `;
  return `{\\setbox0=\\hbox{${labelTex}}\\hangindent=\\wd0\\hangafter=1\\noindent\\makebox[\\wd0][l]{${labelTex}}${contentTex}\\par}`;
}

function decoSectionLabelTex(rawLine) {
  const line = String(rawLine || '').trim();
  if (BULLET_LINE_RE.test(line)) return `$\\bullet$\\ `;
  const labelMatch = line.match(BOGI_ITEM_RE);
  if (!labelMatch) return '';
  const label = labelMatch[1] || labelMatch[2];
  const labelText = label.match(/^[ㄱ-ㅎ]$/) ? `${label}.` : `(${label})`;
  return `${escapeLatexText(labelText)}\\ `;
}

function renderDecoContinuationLine(
  rawLine,
  labelTex,
  equations,
  replaceFigureMarkers = null,
) {
  if (!labelTex) return renderDecoLine(rawLine, equations, replaceFigureMarkers);
  const withFigs = replaceFigureMarkers ? replaceFigureMarkers(rawLine) : rawLine;
  // 그림 블록은 자체 center 환경을 포함하므로 라벨 폭 들여쓰기와 섞지 않는다.
  if (/\\includegraphics/.test(withFigs)) {
    return renderDecoLine(rawLine, equations, replaceFigureMarkers);
  }
  const contentTex = smartTexLine(withFigs, equations);
  if (!contentTex.trim()) return '';
  return `{\\setbox0=\\hbox{${labelTex}}\\leftskip=\\wd0\\relax\\noindent ${contentTex}\\par}`;
}

function renderDecoBoxLatex(lines, equations, replaceFigureMarkers = null) {
  // 1) 박스 내부의 "본문 라인" 목록을 평탄화하되, [문단] 마커는 간격 sentinel 로 보존한다.
  const rawFlatLines = flattenBoxParagraphLines(lines);
  let forcedAlign = '';
  const flatLines = rawFlatLines.filter((line) => {
    const marker = String(line || '').match(BOX_ALIGN_MARKER_RE);
    if (!marker) return true;
    forcedAlign = normalizeLineAlignValue(marker[1]);
    return false;
  });

  // 2) \bullet / (가) / ㄱ. 라벨은 구역 시작 신호다.
  //    이후 새 라벨이 나오기 전까지의 라인은 같은 구역의 후속 줄로 보고,
  //    라벨 폭만큼 들여써서 본문 시작 위치에 맞춘다.
  const hasSectionLabels = flatLines.some((l) => decoSectionLabelTex(l));
  // 3) 가운데 정렬 여부: 한글/ㄱㄴㄷ/bullet/라벨 모두 없으면 가운데 정렬.
  const centerMode = forcedAlign === 'left' ? false : boxContentIsCenteredOnly(flatLines);

  const contentParts = [];
  if (hasSectionLabels) {
    let activeLabelTex = '';
    for (const line of flatLines) {
      if (line === BOX_PARAGRAPH_BREAK) {
        contentParts.push('\\par\\vspace{0.45em}');
        activeLabelTex = '';
        continue;
      }
      if (BULLET_LINE_RE.test(line)) {
        activeLabelTex = decoSectionLabelTex(line);
        contentParts.push(
          renderBulletLine(line, equations, replaceFigureMarkers),
        );
      } else if (BOGI_ITEM_RE.test(line)) {
        activeLabelTex = decoSectionLabelTex(line);
        const rendered = renderDecoLine(line, equations, replaceFigureMarkers);
        if (rendered.trim()) contentParts.push(rendered);
      } else if (activeLabelTex) {
        const rendered = renderDecoContinuationLine(
          line,
          activeLabelTex,
          equations,
          replaceFigureMarkers,
        );
        if (rendered.trim()) contentParts.push(rendered);
      } else {
        const rendered = renderDecoLine(line, equations, replaceFigureMarkers);
        if (rendered.trim()) contentParts.push(rendered);
      }
    }
  } else {
    for (const line of flatLines) {
      if (line === BOX_PARAGRAPH_BREAK) {
        contentParts.push('\\par\\vspace{0.45em}');
        continue;
      }
      const rendered = renderDecoLine(line, equations, replaceFigureMarkers);
      if (rendered.trim()) {
        if (centerMode) {
          // \noindent/hangindent 계열 prefix 가 있으면 가운데 정렬이 씹히므로 제거.
          // 단 renderDecoLine 가 이미 \begin{center}... 를 넣은 경우는 손대지 않는다.
          if (/\\begin\{center\}/.test(rendered)) {
            contentParts.push(rendered);
          } else {
            const cleaned = rendered
              .replace(/\\noindent\s*/g, '')
              .replace(/\\par\s*$/g, '');
            contentParts.push(`\\begin{center}${cleaned}\\end{center}`);
          }
        } else {
          contentParts.push(rendered);
        }
      }
    }
  }

  return [
    '\\begin{tcolorbox}[',
    '  enhanced,',
    '  width=\\dimexpr\\linewidth-1em\\relax,',
    '  colback=white, colframe=black, boxrule=0.4pt,',
    '  arc=0pt, left=8pt, right=8pt, top=12pt, bottom=12pt,',
    '  before skip=0pt, after skip=0pt',
    ']',
    '\\setlength{\\parskip}{0pt}',
    // lineskip/lineskiplimit 을 em 기반으로 지정 (폰트 크기에 비례).
    '\\lineskiplimit=0.27em\\lineskip=0.86em',
    contentParts.join('\n'),
    '\\end{tcolorbox}',
  ].join('\n');
}

/* ------------------------------------------------------------------ */
/*  Table rendering: [표행]/[표셀] → LaTeX tabular                     */
/* ------------------------------------------------------------------ */

function parseTableLines(lines) {
  const rows = [];
  let currentRow = null;
  let currentCell = null;
  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed === '[표행]') {
      if (currentRow) rows.push(currentRow);
      currentRow = [];
      currentCell = null;
    } else if (trimmed === '[표셀]') {
      if (currentRow) {
        currentCell = [];
        currentRow.push(currentCell);
      }
    } else if (currentCell !== null && trimmed) {
      currentCell.push(trimmed);
    }
  }
  if (currentRow) rows.push(currentRow);
  return rows;
}

// raw tabular block (\begin{tabular}{...} ... \end{tabular}) 을
// struct 와 같은 rows 구조(List<List<string[]>>) 로 해체한다.
// - 셀 자동 감싸기(autoWrapTabularCells) 는 호출 전에 이미 수행됐다고 가정.
// - `\\\\` 로 행 구분, `&` 로 셀 구분(중괄호 깊이 추적), `\hline` 은 무시.
// - 반환: rows[][cells][lines] 형태로 parseTableLines 결과와 호환.
function parseRawTabularToRows(rawTexBlock) {
  const match = String(rawTexBlock).match(/\\begin\{tabular\}\{[^}]*\}([\s\S]*?)\\end\{tabular\}/);
  if (!match) return [];
  const body = match[1];
  // 행 구분. \\ 두 개가 연속일 때 행 경계. 정규식은 \\\\\\\\ (JS 문자열) = \\\\ (실제 문자열).
  const rawRows = body.split(/\\\\/);
  const rows = [];
  for (const rowSrc of rawRows) {
    // 라인 끝에 공백/개행만 있는 빈 row 는 스킵.
    const trimmed = rowSrc.trim();
    if (!trimmed) continue;
    // \hline 만 있는 row 도 스킵 (구분자만을 가진 행).
    if (/^\s*(?:\\hline\s*)+$/.test(trimmed)) continue;
    // 셀 분리.
    const cells = splitTabularRowCells(rowSrc);
    // 각 셀 앞의 \hline 제거(뒤따르는 실제 내용만 취함).
    const cleanedCells = cells.map((raw) => {
      let s = raw;
      // 선행 \hline 들을 모두 제거.
      s = s.replace(/^\s*(?:\\hline\s*)+/, '');
      return [s.trim()];
    });
    rows.push(cleanedCells);
  }
  return rows;
}

// tableScale: { widthScale, heightScale, columnScales? } — 사용자 지정 크기 배율.
//   widthScale      : 표 전체 폭 (× \linewidth).
//   heightScale     : 셀 고정 높이 (2.2em × 배수). 폰트 크기는 본문 그대로.
//   columnScales[i] : 컬럼별 상대 가중치. 합으로 정규화되어 각 컬럼 폭 비율을 정한다.
//
// rows 는 parseTableLines 결과 또는 parseRawTabularToRows 결과. 둘 다 동일한
// `rows[][cells][lines]` 구조이므로 이 함수 내부에서는 구분 없이 처리.
function renderTableLatex(rows, equations, tableScale = null) {
  if (!Array.isArray(rows) || rows.length === 0) return '';
  const maxCols = Math.max(...rows.map((r) => r.length));
  if (maxCols === 0) return '';

  const widthScale = clampTableScale(tableScale?.widthScale);
  const heightScale = clampTableScale(tableScale?.heightScale);
  const baseWidthFrac = maxCols <= 3 ? 0.5 : maxCols <= 5 ? 0.7 : 0.9;
  // 표 전체 폭 분수. 1.0(=\linewidth) 이 상한.
  const effWidthFrac = Math.max(0.05, Math.min(1.0, baseWidthFrac * widthScale));
  const cellHeightEm = (2.2 * heightScale).toFixed(2);

  // 컬럼별 상대 가중치. meta.table_scales[...].columnScales 가 있으면 그것을,
  // 없거나 길이가 다르면 전부 1.0 (균등) 으로.
  const rawColScales = Array.isArray(tableScale?.columnScales)
    ? tableScale.columnScales
    : null;
  const colWeights = [];
  for (let i = 0; i < maxCols; i += 1) {
    const w = rawColScales && rawColScales.length === maxCols
      ? clampTableScale(rawColScales[i])
      : 1.0;
    colWeights.push(w);
  }
  const weightSum = colWeights.reduce((a, b) => a + b, 0) || maxCols;
  // 각 컬럼 폭 분수 (0~1). 모두 합하면 effWidthFrac.
  const colFracs = colWeights.map((w) => (w / weightSum) * effWidthFrac);

  // 컬럼 스펙은 `c` 유지 — 각 셀을 \parbox 로 고정 폭 감싸므로 실제 컬럼 폭은 \parbox 폭.
  const colSpec = '|' + Array(maxCols).fill('c|').join('');

  // 컬럼별 개별 폭 레지스터 이름 \tblcelwdA..\tblcelwdZ.
  const colWidthVar = (i) => `\\tblcelwd${String.fromCharCode(0x41 + i)}`;

  const latexRows = rows.map((row) => {
    const cells = [];
    for (let i = 0; i < maxCols; i++) {
      const cellLines = row[i] || [''];
      // raw tabular 해체 경로에서는 셀이 이미 $...$ / \text{...} 로 감싸져 있을 수 있다.
      // struct 경로에서는 평문 셀이므로 smartTexLine 을 적용. 두 경로 모두 안전하도록
      // "이미 수식 구분자로 감싸진 셀은 smartTexLine 을 건너뛴다" 로직이 필요하지만
      // smartTexLine 은 이중 감싸기를 방어하므로 그대로 통과시켜도 동작함.
      const content = cellLines.length > 0
        ? cellLines
          .map((l) => renderCellContent(l, equations))
          .filter((s) => s && s.trim())
          .join(' ')
        : '';
      // 세로·가로 정가운데 배치 (LaTeX 관용구):
      //   - \parbox[c][h][c]{w} : 외부 baseline c, 고정 높이 h, 내부 수직 정렬 c
      //   - \vspace*{\fill} 위아래 : 남는 세로 공간을 균등 분배 → 한 줄/여러 줄 모두 정확히 중앙
      //       (* 는 페이지 끝에서도 공간 흡수되지 않게 강제)
      //   - \centering : paragraph-level 가로 중앙 (content 가 길어 줄바꿈 돼도 중앙)
      //   - vphantom 사용 X : baseline 에 붙은 phantom 이 시각적 하향 쏠림 유발.
      cells.push(
        `\\parbox[c][\\tblcellht][c]{${colWidthVar(i)}}{\\vspace*{\\fill}\\centering ${content}\\par\\vspace*{\\fill}}`,
      );
    }
    return cells.join(' & ') + ' \\\\';
  });

  // 컬럼 폭 레지스터 선언 + 할당.
  // 각 컬럼 폭 = (colFrac_i × \linewidth) - 2\tabcolsep - 1.2pt (보더/여백 보정).
  const lengthDefs = [];
  for (let i = 0; i < maxCols; i += 1) {
    const name = colWidthVar(i);
    lengthDefs.push(
      `\\makeatletter\\@ifundefined{${name.slice(1)}}{\\newlength{${name}}}{}\\makeatother`,
    );
    lengthDefs.push(
      `\\setlength{${name}}{\\dimexpr ${colFracs[i].toFixed(6)}\\linewidth - 2\\tabcolsep - 1.2pt\\relax}`,
    );
  }

  return [
    ...lengthDefs,
    `\\setlength{\\tblcellht}{${cellHeightEm}em}`,
    '\\par\\noindent{\\hfill\\renewcommand{\\arraystretch}{1}%',
    '\\begin{tabular}{' + colSpec + '}',
    '\\hline',
    latexRows.join('\n\\hline\n'),
    '\\hline',
    '\\end{tabular}\\hfill\\null}\\par',
  ].join('\n');
}

// 셀 내용 1 줄을 렌더 가능한 LaTeX 텍스트로 변환.
// - 이미 $...$ 또는 \text{...} 로 감싸진 경우: 그대로 둔다 (raw tabular 해체 경로).
// - 그 외: smartTexLine 으로 한국어/수식 분리 처리.
function renderCellContent(line, equations) {
  const s = String(line || '').trim();
  if (!s) return '';
  // $...$ 로 시작해서 $...$ 로 끝나면서 내부에 $가 한 쌍만 있는 단순 수식 셀.
  if (/^\$[\s\S]*\$$/.test(s)) {
    // 안쪽에 중첩된 $가 있으면 이상한 셀 → 그대로 smartTexLine 에 맡긴다.
    const inner = s.slice(1, -1);
    if (!/\$/.test(inner)) return s;
  }
  // \text{...} 로 완전히 감싸진 셀.
  if (/^\\text\{[\s\S]*\}$/.test(s)) return s;
  // 그 외는 struct 경로처럼 smartTexLine.
  return smartTexLine(s, equations);
}

// 표 스케일 값 정규화. 0.3 ~ 2.5 사이로 clamp. 비정상 값은 1.0.
// struct 표는 cellwd/cellht 에, raw 표는 \tabcolsep/\arraystretch 에 반영된다.
function clampTableScale(v) {
  const n = Number(v);
  if (!Number.isFinite(n) || n <= 0) return 1.0;
  return Math.max(0.3, Math.min(2.5, n));
}

// meta.table_scales 에서 특정 표(type: 'struct' | 'raw', index: 1-based)의
// 스케일 { widthScale, heightScale, columnScales? } 을 찾아 반환.
// 없으면 table_scale_default, 그것도 없으면 { widthScale: 1, heightScale: 1 }.
// columnScales 는 struct 표에서만 의미가 있고, 길이는 renderTableLatex 에서 maxCols 와 비교해 검증.
function resolveTableScale(question, type, index) {
  const meta = question?.meta && typeof question.meta === 'object' ? question.meta : {};
  const scales = meta.table_scales && typeof meta.table_scales === 'object'
    ? meta.table_scales
    : {};
  const def = meta.table_scale_default && typeof meta.table_scale_default === 'object'
    ? meta.table_scale_default
    : null;
  // 탐색 우선순위:
  //   1) 타입별 키: struct:1 / raw:1
  //   2) 통합 키   : table:1 (struct+raw 를 하나로 세는 외부 네임스페이스 사용 케이스)
  const keys = [`${type}:${index}`];
  const lookup = (k) => (scales[k] && typeof scales[k] === 'object' ? scales[k] : null);

  const toColumnScales = (raw) => {
    if (!Array.isArray(raw)) return null;
    const out = [];
    for (const v of raw) {
      const n = Number(v);
      if (Number.isFinite(n) && n > 0) {
        out.push(clampTableScale(n));
      } else {
        out.push(1.0);
      }
    }
    return out.length ? out : null;
  };

  for (const k of keys) {
    const hit = lookup(k);
    if (hit) return {
      widthScale: clampTableScale(hit.widthScale ?? hit.w ?? 1),
      heightScale: clampTableScale(hit.heightScale ?? hit.h ?? 1),
      columnScales: toColumnScales(hit.columnScales ?? hit.cols ?? null),
    };
  }
  if (def) return {
    widthScale: clampTableScale(def.widthScale ?? def.w ?? 1),
    heightScale: clampTableScale(def.heightScale ?? def.h ?? 1),
    columnScales: toColumnScales(def.columnScales ?? def.cols ?? null),
  };
  return { widthScale: 1.0, heightScale: 1.0, columnScales: null };
}

/* ------------------------------------------------------------------ */
/*  Choices                                                            */
/* ------------------------------------------------------------------ */

const CIRCLED_DIGITS = ['①', '②', '③', '④', '⑤', '⑥', '⑦', '⑧', '⑨', '⑩'];

// 선택지 시각폭 측정 — HTML 엔진 `choice_block.js` 의 visualLength 와 동일한
//   전처리(LaTeX 토큰 스트리핑) 를 적용해 두 엔진의 레이아웃 결정 기준을 통일한다.
//
// 전처리 후 남은 "가시 글리프 근사 문자열" 에 대해 XeLaTeX 본 렌더 스케일에
//   맞춘 가중치(Hangul=2, Non-ASCII=1.5, ASCII=0.6) 로 합산한다.
//
//   - `\frac`/`\dfrac`/`\tfrac`/`\over` : 가로로 넓고 세로가 큰 분수 → "FRAC"
//   - `\sqrt` : 제곱근 기호 → "SQRT"
//   - `\times`/`\div`/`\le`/`\ge`/…     : 단일 연산자 기호 → "X"
//   - `\left`/`\right`/`\mathrm`/`\text{}` 류: 폭 기여 거의 없음 → 제거
//   - 기타 `\[a-zA-Z]+` 매크로         : 일반 기호 1개 → "S"
function visualLength(text) {
  const stripped = stripMarkers(text)
    .replace(/\\(?:times|div|cdot|pm|mp|le|ge|leq|geq|neq|approx|equiv|sim|lt|gt)\b/g, ' X ')
    .replace(/\\(?:frac|dfrac|tfrac|over)\b/g, ' FRAC ')
    .replace(/\\sqrt\b/g, ' SQRT ')
    .replace(/\\(?:left|right|mathrm|mathbf|mathit|text|operatorname|displaystyle|textstyle)\b/g, '')
    .replace(/\\[a-zA-Z]+/g, ' S ')
    .replace(/[{}$\\^_]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
  let len = 0;
  for (const ch of stripped) {
    const code = ch.codePointAt(0);
    if (code >= 0xAC00 && code <= 0xD7AF) len += 2;
    else if (code >= 0x3130 && code <= 0x318F) len += 2;
    else if (code > 0x7F) len += 1.5;
    else len += 0.6;
  }
  return Math.round(len);
}

// 레이아웃 결정 전에 equation placeholder 를 실제 LaTeX 로 펼친 뒤 측정한다.
//   choice.text 에는 DB 규약상 짧은 raw 토큰(예: "R1") 이 들어있을 수 있고,
//   실제 렌더는 smartTexLine → applyEquationLookup 으로 긴 수식으로 확장된다.
//   측정이 그 확장을 무시하면 row1 로 잘못 내려가 \makebox 에서 오버플로우가 발생한다.
//
// Tier 2 — 칼럼 폭 인지:
//   row1 cell = 0.2 × \linewidth. 1단에서는 \linewidth ≈ textwidth, 2단에서는 그 절반.
//   즉 2단 페이지에서는 같은 선택지라도 "보기 셀 대비 차지하는 비율" 이 2배.
//   임계값을 고정한 채 **측정 길이에 widthFactor(=layoutColumns) 를 곱해** 동일 폭 기준으로
//   정규화한다. 결과: 2단에서는 더 쉽게 row2/stack 으로 내려간다.
function chooseChoiceLayout(choices, equations, layoutColumns = 1) {
  if (choices.length !== 5) return 'stack';
  const lookup = buildEquationLookup(equations);
  const widthFactor = Math.max(1, Number(layoutColumns) || 1);
  const lengths = choices.map((c) => {
    const raw = typeof c === 'string' ? c : c?.text || c?.label || '';
    const expanded = applyEquationLookup(raw, lookup);
    return visualLength(expanded) * widthFactor;
  });
  const maxLen = Math.max(...lengths);
  const totalLen = lengths.reduce((a, b) => a + b, 0);
  if (maxLen > 25) return 'stack';
  if (totalLen > 65) return 'stack';
  if (maxLen > 16 || totalLen > 50) return 'row2';
  if (maxLen > 8 || totalLen > 30) return 'row2';
  return 'row1';
}

function isBlankChoiceQuestion(question) {
  const meta = question?.meta && typeof question.meta === 'object' ? question.meta : {};
  return meta.is_blank_choice_question === true || meta.choice_layout === 'blank_table';
}

function blankChoiceLabels(question) {
  const meta = question?.meta && typeof question.meta === 'object' ? question.meta : {};
  const raw = Array.isArray(meta.blank_choice_labels) ? meta.blank_choice_labels : [];
  const fallback = ['(가)', '(나)', '(다)'];
  return fallback.map((label, idx) => {
    const value = String(raw[idx] || '').trim();
    return value || label;
  });
}

function blankChoiceCells(text, columnCount) {
  const parts = String(text || '')
    .split(/\s*,\s*/)
    .map((v) => v.trim());
  while (parts.length < columnCount) parts.push('');
  return parts.slice(0, columnCount);
}

function renderBlankChoicesLatex(question, choices, equations) {
  if (!Array.isArray(choices) || choices.length !== 5) return renderChoicesLatex(choices, equations);
  const labels = blankChoiceLabels(question);
  const header = [''].concat(labels.map(escapeLatexText)).join(' & ');
  const rows = choices.map((choice, idx) => {
    const label = typeof choice === 'string'
      ? (CIRCLED_DIGITS[idx] || String(idx + 1))
      : (String(choice?.label || '').trim() || CIRCLED_DIGITS[idx] || String(idx + 1));
    const rawText = typeof choice === 'string' ? choice : choice?.text || '';
    const cells = blankChoiceCells(rawText, labels.length)
      .map((cell) => smartTexLine(cell, equations));
    return [label].concat(cells).join(' & ');
  });
  return [
    '{\\setstretch{1.7}\\parskip=0pt\\lineskiplimit=0.4em\\lineskip=1.2em',
    '\\noindent\\begin{tabular}{@{}lccc@{}}',
    header + ' \\\\',
    rows.join(' \\\\\n'),
    '\\end{tabular}\\par}',
  ].join('\n');
}

function renderChoicesLatex(choices, equations, layoutColumns = 1) {
  if (!Array.isArray(choices) || choices.length === 0) return '';

  const layout = chooseChoiceLayout(choices, equations, layoutColumns);

  const renderItem = (c, idx) => {
    const text = typeof c === 'string' ? c : c?.text || c?.label || '';
    const label = CIRCLED_DIGITS[idx] || String(idx + 1);
    const content = smartTexLine(text, equations);
    return `${label}\\enspace ${content}`;
  };

  // 본문(setstretch 1.7) 과 동일 줄 간격을 사용해 분수/위첨자 포함 줄의
  // 베이스라인 간격이 두 영역에서 동일하게 맞추도록 한다.
  // lineskip / lineskiplimit 을 em 기반으로 → 폰트 크기에 비례해 분수 포함 줄의 여유 간격도 스케일.
  const CHOICE_STRETCH = '\\setstretch{1.7}\\parskip=0pt\\lineskiplimit=0.4em\\lineskip=1.2em';

  if (layout === 'row1') {
    const cells = choices.map((c, i) => renderItem(c, i));
    const w = '\\dimexpr0.2\\linewidth-0.2em\\relax';
    return [
      '{' + CHOICE_STRETCH,
      '\\noindent%',
      cells.map((cell) => `\\makebox[${w}][l]{${cell}}`).join('%\n') + '%',
      '\\par}',
    ].join('\n');
  }

  if (layout === 'row2') {
    const cells = choices.map((c, i) => renderItem(c, i));
    const w = '\\dimexpr0.3333\\linewidth-0.3333em\\relax';
    const top3 = cells.slice(0, 3).map((cell) => `\\makebox[${w}][l]{${cell}}`).join('%\n');
    const bot2 = cells.slice(3, 5).map((cell) => `\\makebox[${w}][l]{${cell}}`).join('%\n');
    return [
      '{' + CHOICE_STRETCH,
      '\\noindent%',
      top3 + '%',
      '\\par\\noindent%',
      bot2 + '%',
      '\\par}',
    ].join('\n');
  }

  const items = choices.map((c, i) => {
    const text = typeof c === 'string' ? c : c?.text || c?.label || '';
    const label = CIRCLED_DIGITS[i] || String(i + 1);
    const content = smartTexLine(text, equations);
    return `\\hangindent=1.5em\\hangafter=1\\noindent\\makebox[1.5em][l]{${label}}${content}`;
  });
  return [
    '{' + CHOICE_STRETCH,
    items.join('\\par\n'),
    '\\par}',
  ].join('\n');
}

/* ------------------------------------------------------------------ */
/*  Page geometry & fonts                                              */
/* ------------------------------------------------------------------ */

function paperGeometry(paper) {
  const p = String(paper || 'B4').toUpperCase();
  // 좌/우 여백은 사용자 요청으로 30% 축소 (20mm * 0.7 = 14mm).
  // 상단 여백(top) :
  //   - 기본 20mm → 초기 28mm 확장(가로선 위 영역 ~50% 증가) → 추가 +5pt 조정(사용자 요청 2차).
  //   - 최종 84.4pt ≈ 29.76mm. 일반 페이지 body top 과 가로선(=body top - 14pt) 이 함께 +5pt 하향.
  //   - 제목 페이지는 overlay 의 VRuleStartY offset(28pt → 13pt) + 콘텐츠 앞 `\vspace*{-15pt}` 삽입으로
  //     **-10pt** 순 이동(본 geometry 증가분 +5pt 를 상쇄하고도 -10pt 추가로 올라감).
  //   - 하단 여백(bottom)은 20mm 유지 → \mockLayBotY / 세로선 끝 / 페이지박스 위치 **불변**.
  // 일반페이지 헤더/디바이더 간격 조정:
  //   - top 을 34mm → 32.06mm 로 줄여 slot 시작점을 위로 이동
  //   - headsep 을 25pt → 19.5pt 로 줄여 페이지라벨과 가로선 간격을 약 절반 수준으로 축소
  //   - (사용자 요청 17차) top 을 32.06mm → 29.95mm 로 추가 6pt 축소. 헤더/본문/디바이더가
  //     통째로 6pt 위로 이동한다. 페이지번호는 뒤쪽에서 `\raisebox` 값을 6pt 줄여(9.37→3.37)
  //     절대 위치를 고정. 홀수형/수학영역은 보정 없이 6pt 상승.
  // headheight 54pt : 페이지번호/홀수형 박스를 \raisebox 로 올릴 공간 확보.
  const vmargins = 'top=29.95mm,bottom=20mm,headheight=54pt,headsep=19.5pt';
  if (p === 'A4') return `a4paper,hmargin=14mm,${vmargins}`;
  if (p === 'A3') return `a3paper,hmargin=14mm,${vmargins}`;
  return `b4paper,hmargin=14mm,${vmargins}`;
}

function fontSpecDirective(fontPath, fontFamily, fontBold) {
  if (fontPath) {
    const escapedPath = fontPath.replace(/\\/g, '/');
    return `\\setmainfont{${fontFamily}}[
  Path = ${escapedPath.replace(/[^/]+$/, '')},
  Extension = .${escapedPath.split('.').pop()},
  UprightFont = ${escapedPath.split('/').pop()},
  BoldFont = ${escapedPath.split('/').pop()},
  BoldFeatures = {FakeBold=1.5},
]`;
  }
  return `\\setmainfont{${fontFamily}}[
  BoldFont = ${fontBold || fontFamily + ' Bold'},
]`;
}

function hangulFontDirective(fontPath, fontFamily, fontBold) {
  if (fontPath) {
    const escapedPath = fontPath.replace(/\\/g, '/');
    return `\\setmainhangulfont{${fontFamily}}[
  Path = ${escapedPath.replace(/[^/]+$/, '')},
  Extension = .${escapedPath.split('.').pop()},
  UprightFont = ${escapedPath.split('/').pop()},
  BoldFont = ${escapedPath.split('/').pop()},
  BoldFeatures = {FakeBold=1.5},
]`;
  }
  return `\\setmainhangulfont{${fontFamily}}[
  BoldFont = ${fontBold || fontFamily + ' Bold'},
]`;
}

/* ------------------------------------------------------------------ */
/*  Preamble (document PDF)                                            */
/* ------------------------------------------------------------------ */

function buildPreamble({
  paper, fontFamily, fontBold, fontRegularPath, fontSize,
  subjectFontPath = '',
  subjectTitle, profile,
  hidePreviewHeader = false,
  geometryOverride = '',
  includeAcademyLogo = false,
  academyLogoPath = '',
}) {
  const geom = geometryOverride || paperGeometry(paper);
  const mainFont = fontFamily || 'Malgun Gothic';
  const boldFont = fontBold || `${mainFont} Bold`;
  const size = fontSize || 11;
  const mainDirective = fontSpecDirective(fontRegularPath, mainFont, boldFont);
  const hangulDirective = hangulFontDirective(fontRegularPath, mainFont, boldFont);
  // 사용자 요청 7차: HTML/MathJax 엔진의 `YggSubject` 폰트(기본 AppleSDGothicNeoB.ttf)
  //   를 XeLaTeX 에도 `\YggSubject` 로 등록. subjectFontPath 가 빈 값이면
  //   noop 매크로로 선언 (폴백 = 메인 폰트).
  const subjectFontDirective = subjectFontPath
    ? (() => {
      const normalized = subjectFontPath.replace(/\\/g, '/');
      const fileName = normalized.split('/').pop();
      const dir = normalized.replace(/[^/]+$/, '');
      const ext = fileName.includes('.') ? fileName.split('.').pop() : 'ttf';
      return `\\newfontfamily\\YggSubject{${fileName}}[\n`
        + `  Path = ${dir},\n`
        + `  Extension = .${ext},\n`
        + `  UprightFont = ${fileName},\n`
        + `  BoldFont = ${fileName},\n`
        + `  BoldFeatures = {FakeBold=1.3},\n`
        + `]`;
    })()
    : '\\newcommand{\\YggSubject}{}';
  // 제목페이지 부제/메인타이틀/큰 홀수형 박스는 HTML `.mock-first-subject`, `.mock-chip-type`
  // 와 같은 YggSubject 계열을 명시적으로 사용한다.
  const subjectDisplayFontDirective = subjectFontPath
    ? (() => {
      const normalized = subjectFontPath.replace(/\\/g, '/');
      const fileName = normalized.split('/').pop();
      const dir = normalized.replace(/[^/]+$/, '');
      const ext = fileName.includes('.') ? fileName.split('.').pop() : 'ttf';
      return `\\newfontfamily\\YggSubjectDisplay{${fileName}}[\n`
        + `  Path = ${dir},\n`
        + `  Extension = .${ext},\n`
        + `  UprightFont = ${fileName},\n`
        + `  BoldFont = ${fileName},\n`
        + `  BoldFeatures = {FakeBold=1.3},\n`
        + `]`;
    })()
    : '\\newcommand{\\YggSubjectDisplay}{\\YggSubject}';
  const topLabelFontDirective = '\\newfontfamily\\YggTopLabel{Malgun Gothic}[\n'
    + '  BoldFont = {Malgun Gothic Bold},\n'
    + ']';
  const isMock = profile === 'mock' || profile === 'csat';

  const lines = [];
  // 모의고사형은 일반 페이지 헤더가 짝수/홀수 페이지 레이아웃이 달라야 하므로 `twoside` 활성화.
  //   - 좌/우 여백은 hmargin=14mm 으로 대칭이라 twoside 전환이 시각적 여백에는 영향을 주지 않음.
  //   - fancyhdr `[LE,LO,RE,RO,CE,CO]` 구분이 활성화된다.
  const docClassOpts = isMock ? `${size}pt,twoside` : `${size}pt`;
  lines.push(`\\documentclass[${docClassOpts}]{article}`);
  lines.push(`\\usepackage[${geom}]{geometry}`);
  lines.push('\\usepackage{fontspec}');
  lines.push('\\usepackage{amsmath,amssymb}');
  // ─── \dfrac / \frac / \tfrac 재정의: ht/dp 를 대칭화하여 "분수 때문에 늘어난 수직 여유" 를 위·아래 반반씩 분배 ───
  //   기본 분수 명령은 분자 쪽 ht (≈10pt) 이 분모 쪽 dp (≈5pt) 보다 커서 비대칭.
  //   → TeX 의 baselineskip 규칙상 위쪽 line 과의 간격이 크게 늘어나고 아래쪽은 덜 늘어남.
  //   재정의: \raisebox 의 `[height][depth]` 옵션으로 content 는 제자리(raise=0) 에 두고
  //     box 가 "대외적으로 주장하는" ht/dp 만 (natural_ht + natural_dp)/2 로 균등화.
  //     → 위·아래 여유가 같은 양씩 확보되어 시각적 수직 대칭이 성립.
  //     raisebox 안 `\height`, `\depth` 는 content 측정값을 참조하므로 재귀/동적 크기에 안전.
  //   사용자 요청 23차: 기존엔 `\dfrac` 만 재정의되어 있어 본문 대부분이 쓰는 `\frac` / `\tfrac`
  //     은 비대칭 상태로 남아 "위쪽만 여백이 크게 늘어나는" 현상이 남아 있었다.
  //     → `\frac`, `\tfrac` 도 동일 패턴으로 재정의하여 모든 분수가 대칭화되도록 보강한다.
  // 사용자 요청 24차: 분수 가로선(rule) 을 약간 더 길게 보이도록 분자/분모 양쪽에 `\,` 를
  //   주입. `\,` 는 3mu ≈ 0.167em 의 얇은 공백으로, 분자·분모 폭을 넓혀 LaTeX 이 rule 길이를
  //   max(분자, 분모) 기준으로 그릴 때 약 0.33em 만큼 더 길어진다. math-mode 전용 공백이라
  //   텍스트 조판에는 영향 없음.
  const symFrac = (orig) => '\\mathchoice'
    + `{\\raisebox{0pt}[\\dimexpr 0.5\\height+0.5\\depth\\relax][\\dimexpr 0.5\\height+0.5\\depth\\relax]{$\\displaystyle\\${orig}{\\,#1\\,}{\\,#2\\,}$}}`
    + `{\\raisebox{0pt}[\\dimexpr 0.5\\height+0.5\\depth\\relax][\\dimexpr 0.5\\height+0.5\\depth\\relax]{$\\textstyle\\${orig}{\\,#1\\,}{\\,#2\\,}$}}`
    + `{\\raisebox{0pt}[\\dimexpr 0.5\\height+0.5\\depth\\relax][\\dimexpr 0.5\\height+0.5\\depth\\relax]{$\\scriptstyle\\${orig}{\\,#1\\,}{\\,#2\\,}$}}`
    + `{\\raisebox{0pt}[\\dimexpr 0.5\\height+0.5\\depth\\relax][\\dimexpr 0.5\\height+0.5\\depth\\relax]{$\\scriptscriptstyle\\${orig}{\\,#1\\,}{\\,#2\\,}$}}`;
  lines.push('\\let\\origdfrac\\dfrac');
  lines.push(`\\renewcommand{\\dfrac}[2]{${symFrac('origdfrac')}}`);
  lines.push('\\let\\origfrac\\frac');
  lines.push(`\\renewcommand{\\frac}[2]{${symFrac('origfrac')}}`);
  lines.push('\\let\\origtfrac\\tfrac');
  lines.push(`\\renewcommand{\\tfrac}[2]{${symFrac('origtfrac')}}`);
  lines.push('\\usepackage{array}');
  lines.push('\\usepackage{kotex}');
  // 어절 중간에서 줄바꿈 금지: kotex 가 기본 설정한 ICU 한국어 줄바꿈 로케일을
  // 비워 공백(어절 경계)에서만 개행하도록 한다.
  lines.push('\\XeTeXlinebreaklocale ""');
  lines.push('\\XeTeXlinebreakskip=0pt plus 0pt minus 0pt');
  // 자간(띄어쓰기 포함)은 항상 균일. 줄 끝에 공간이 남으면 \raggedright 로
  // 좌측 정렬한 채 비워둔다 (양쪽 정렬로 인한 공백 스트레칭 방지).
  lines.push('\\tolerance=9999');
  lines.push('\\emergencystretch=0pt');
  lines.push('\\usepackage{graphicx}');
  // adjustbox: \includegraphics 에 'max width' 같은 확장 키 사용.
  lines.push('\\usepackage[export]{adjustbox}');
  lines.push('\\usepackage{xcolor}');
  lines.push('\\usepackage[normalem]{ulem}');
  lines.push('\\usepackage{enumitem}');
  lines.push('\\usepackage{multicol}');
  lines.push('\\newlength{\\tblcellwd}');
  lines.push('\\newlength{\\tblcellht}');
  // \mtemptybox : 가로:세로 = 3:2 비율의 빈칸 네모 (math/text 모두 안전).
  // 한글 글자 전체 높이(ascender+descender 포함)와 시각적으로 동일하도록 1.05em × 1.575em 으로 설정.
  // (한글 글리프 실제 높이가 약 1.0~1.05em 수준이라 0.9em 이면 작아 보임)
  // \ensuremath + \vcenter 로 수식축(math axis) 에 중앙이 오도록 → 인접 글자와 시각적 정렬.
  lines.push('\\newcommand{\\mtemptybox}{\\ensuremath{\\vcenter{\\hbox{\\setlength{\\fboxsep}{0pt}\\framebox[1.575em][c]{\\rule{0pt}{1.05em}}}}}}');
  // 지수 전용 빈칸: 정사각형이며 일반 빈칸보다 작다.
  lines.push('\\newcommand{\\mtexponentemptybox}{\\vcenter{\\hbox{\\scriptsize\\setlength{\\fboxsep}{0pt}\\framebox[0.72em][c]{\\rule{0pt}{0.72em}}}}}');
  lines.push('\\usepackage{fancyhdr}');
  lines.push('\\usepackage{setspace}');
  lines.push('\\usepackage[most]{tcolorbox}');
  // 모의고사형 페이지박스의 "/ 전체페이지" 표기에 \pageref{LastPage} 를 쓰기 위함.
  lines.push('\\usepackage{lastpage}');
  // 모의고사형 페이지박스(대각선 + 좌상/우하 숫자) 용 tikz.
  // tcolorbox 가 tikz 를 이미 적재하지만 명시적으로 추가해도 안전.
  lines.push('\\usepackage{tikz}');
  // tikz overlay 를 모든 페이지 배경/전경에 자동 삽입하기 위한 훅.
  //   \AddToShipoutPictureFG : 페이지 본문 위(전경) 에 그림 — overlay 용도로 적합.
  //   모의고사형 절대좌표 레이아웃(상단 rule + 세로 단구분선 + 페이지박스) 에 사용.
  lines.push('\\usepackage{eso-pic}');
  // \AtBeginShipoutNext 훅 (eso-pic 이 이미 requires 로 불러오지만 명시적 로드로
  //   가용성 보장). 특정 페이지(제목페이지) 의 overlay 분기 플래그를
  //   shipout 타이밍에 세팅/리셋하는 데 사용.
  lines.push('\\usepackage{atbegshi}');
  lines.push('');
  lines.push(mainDirective);
  lines.push(hangulDirective);
  lines.push(subjectFontDirective);
  lines.push(subjectDisplayFontDirective);
  lines.push(topLabelFontDirective);
  // ── 숫자를 한글(HG) charclass 로 국지 편입하는 래퍼 ──────────────────────
  //   배경: xetexko 는 유니코드 charclass (HG/CJ/Latin 등) 에 따라 font instance 를
  //     자동 분기한다. `\newfontfamily\YggTopLabel{Malgun Gothic}` 같은 선언이 있어도
  //     본문에서 ASCII 숫자를 만나면 Latin instance 로, 한글을 만나면 Hangul instance
  //     로 나눠 렌더되어 "같은 Malgun Gothic 이지만 한글-숫자 글리프 디자인 이질성"
  //     문제가 드러난다 (probe 로 instance #1 vs #2 직접 확인).
  //   해결: 숫자 0-9 의 charclass 를 HG 로 임시 편입하면 xetexko 가 숫자도 hangul
  //     instance 로 routing → 한글과 **동일 instance** 에서 렌더되어 시각 이질성 최소화.
  //   주의: `\XeTeXcharclass` 는 **글로벌** 할당이라 `\begingroup…\endgroup` 만으로는
  //     원복되지 않는다. 반드시 `\YggRestoreDigits` 를 명시 호출해 원복해야 본문 숫자가
  //     본문 Latin instance (KoPubWorldBatangPro 등) 로 돌아가 영향이 없다.
  //   적용 범위: 제 2 교시 박스 / 제목페이지 부제(2026…) / 라벨박스(5지선다형…) 등
  //     **헤더·라벨 블록에만** `\YggWithUnifiedDigits{…}` 로 감싸 적용. 본문은 미적용.
  lines.push('\\newcommand{\\YggUnifyDigits}{%');
  lines.push('  \\XeTeXcharclass`\\0=\\XeTeXcharclassHG \\XeTeXcharclass`\\1=\\XeTeXcharclassHG');
  lines.push('  \\XeTeXcharclass`\\2=\\XeTeXcharclassHG \\XeTeXcharclass`\\3=\\XeTeXcharclassHG');
  lines.push('  \\XeTeXcharclass`\\4=\\XeTeXcharclassHG \\XeTeXcharclass`\\5=\\XeTeXcharclassHG');
  lines.push('  \\XeTeXcharclass`\\6=\\XeTeXcharclassHG \\XeTeXcharclass`\\7=\\XeTeXcharclassHG');
  lines.push('  \\XeTeXcharclass`\\8=\\XeTeXcharclassHG \\XeTeXcharclass`\\9=\\XeTeXcharclassHG');
  lines.push('}');
  lines.push('\\newcommand{\\YggRestoreDigits}{%');
  lines.push('  \\XeTeXcharclass`\\0=0 \\XeTeXcharclass`\\1=0 \\XeTeXcharclass`\\2=0 \\XeTeXcharclass`\\3=0');
  lines.push('  \\XeTeXcharclass`\\4=0 \\XeTeXcharclass`\\5=0 \\XeTeXcharclass`\\6=0 \\XeTeXcharclass`\\7=0');
  lines.push('  \\XeTeXcharclass`\\8=0 \\XeTeXcharclass`\\9=0');
  lines.push('}');
  lines.push('\\newcommand{\\YggWithUnifiedDigits}[1]{%');
  lines.push('  \\begingroup\\YggUnifyDigits #1\\YggRestoreDigits\\endgroup');
  lines.push('}');
  lines.push('');

  // 학원 로고를 사용할 경우 \includegraphics 에 넘길 정규화된 경로.
  const logoEnabled = includeAcademyLogo && academyLogoPath;
  const logoPathTex = logoEnabled ? String(academyLogoPath).replace(/\\/g, '/') : '';
  // 오른쪽 헤더에 삽입할 로고 이미지 — height=1.4em 로 본문 줄 높이보다 살짝 큼.
  const logoHeadGraphic = logoEnabled
    ? `\\raisebox{-0.2em}{\\includegraphics[height=1.4em,keepaspectratio]{${logoPathTex}}}`
    : '';

  // 일반/제목 페이지 공통으로 사용하는 헤더 스펙 (모의고사형에서만 의미 있음).
  //   - pageNumSpec : **28.6pt** bold 페이지번호.
  //     사용자 요청 10차: HTML/MathJax 렌더엔진의 `.mock-page-no` 는 body 의
  //     `YggMain` (KoPubWorldBatangPro Light = 본문 명조) 을 상속한다. → XeLaTeX 에서도
  //     `\YggSubject` (고딕) 이 아닌 기본 메인 폰트(동일 = KoPubWorld) 를 쓰도록 제거.
  //     크기도 22pt → **28.6pt (+30%)** 로 증가.
  //   - formBoxSpec : 일반 페이지용 12pt bold "홀수형" + fbox.
  //     (HTML `.mock-chip-type` 이 YggSubject 를 명시 지정하고 있음).
  //   이 두 값은 일반 페이지 `\pagestyle{fancy}` 와 제목 페이지 `mocktitle` 양쪽에서 동일 재사용.
  const pageNumSpec = '{\\fontsize{28.6pt}{34pt}\\selectfont\\bfseries\\thepage}';
  // 사용자 요청 20차: 비제목 페이지 홀수형 박스를 제목 페이지 스타일(titleFormBoxSpec)
  //   참조 tikz 스타일로 교체. 크기는 70% 로 축소.
  //     titleFormBoxSpec : line width=0.8pt, rounded corners=3.0pt, minimum height=35.2pt,
  //                       inner xsep=8.6pt, font=20.7pt, scalebox=0.95
  // 사용자 요청 21차: 높이만 추가 5% 증가 (min-height 24.6 → 25.83pt, rounded corners 2.1 → 2.205pt).
  //     폭/폰트/장평은 그대로 유지.
  const formBoxSpec = '{\\tikz[baseline=(box.center)]'
    + '\\node[draw=black,line width=0.56pt,line join=round,line cap=round,'
    + 'rounded corners=2.205pt,minimum height=25.83pt,inner xsep=6pt,inner ysep=0pt,outer sep=0pt] (box) '
    + '{{\\YggSubjectDisplay\\fontsize{14.5pt}{14.5pt}\\selectfont\\bfseries'
    + '\\scalebox{0.95}[1]{홀수형}}};}';
  // 제목페이지 전용 큰 홀수형 박스. 스크린샷 기준으로 오른쪽에 별도로 배치되며,
  // 텍스트는 장평 95% + 박스 안 수직 중앙 정렬.
  const titleFormBoxSpec = '{\\tikz[baseline=(box.center)]'
    + '\\node[draw=black,line width=0.8pt,line join=round,line cap=round,'
    + 'rounded corners=3.0pt,minimum height=35.2pt,inner xsep=8.6pt,inner ysep=0pt,outer sep=0pt] (box) '
    + '{{\\YggSubjectDisplay\\fontsize{20.7pt}{20.7pt}\\selectfont\\bfseries'
    + '\\scalebox{0.95}[1]{홀수형}}};}';
  // 사용자 요청 20차: 제2교시 박스 높이만 10% 증가 (위치 = box.center baseline 유지).
  //   minimum height: 26pt → 28.6pt, rounded corners: 13pt → 14.3pt (height/2 유지, pill).
  //   폰트/장평/raisebox 는 변경 없음 (위치 그대로).
  // 사용자 요청 22차: '제 2 교시' 의 숫자 '2' 가 한글과 다른 font instance (Malgun Gothic Latin)
  //   로 렌더되는 이질감을 제거하기 위해 박스 내부 텍스트를 `\YggWithUnifiedDigits` 로 감싼다.
  //   → 숫자도 한글 instance (MalgunGothic(1)) 에서 렌더. 래퍼는 지역 scope 에서만 charclass 를
  //     변경 후 즉시 원복하므로 본문 숫자에는 전혀 영향 없음.
  const titleSessionBoxSpec = '{\\tikz[baseline=(box.center)]'
    + '\\node[draw=black,line width=0.8pt,line join=round,line cap=round,'
    + 'rounded corners=14.3pt,minimum height=28.6pt,inner xsep=8pt,inner ysep=0pt,outer sep=0pt] (box) '
    + '{\\YggWithUnifiedDigits{{\\YggTopLabel\\fontsize{20pt}{20pt}\\selectfont\\scalebox{0.90}[1]{제\\,2\\,교시}}}};}';
  const titleRightHeaderSpec = '{'
    + `\\makebox[0pt][r]{\\raisebox{47.53pt}[0pt][0pt]{${pageNumSpec}}}`
    + `\\makebox[0pt][r]{\\raisebox{1.37pt}[0pt][0pt]{${titleFormBoxSpec}}}`
    + '}';

  if (hidePreviewHeader) {
    // 미리보기 헤더를 숨기는 경우에도 로고는 상단에 찍고자 fancy 를 쓰되 테두리 없음.
    if (logoEnabled) {
      lines.push('\\pagestyle{fancy}');
      lines.push('\\fancyhf{}');
      lines.push(`\\fancyhead[R]{${logoHeadGraphic}}`);
      lines.push('\\renewcommand{\\headrulewidth}{0pt}');
      lines.push('\\fancyfoot{}');
    } else {
      lines.push('\\pagestyle{empty}');
    }
  } else if (isMock && subjectTitle) {
    // 모의고사형 레이아웃: 상단 rule / 세로 단구분선 / 하단 페이지박스를
    //   \fancyhead/\fancyfoot 의 '본문 흐름 기반' 위치에 두면 페이지별 콘텐츠 양에
    //   따라 위치가 미세하게 흔들린다(특히 overfull/underfull \vbox 보정 시).
    //
    //   → 이 세 요소를 '절대 좌표' 에 고정한다:
    //     - header rule / column rule / pagebox : \AddToShipoutPictureFG + tikz overlay.
    //     - fancyhdr 는 '헤더 텍스트' (좌: 큰 페이지번호, 중앙: 수학 영역, 우: 홀수형 박스) 만 담당.
    //
    // 사용자 요청(3차) — 수능 시험지 스타일 헤더:
    //   - 짝수 페이지 : [L] 페이지번호(큰 글자), [C] "수학 영역", [R] [홀수형] 박스.
    //   - 홀수 페이지 : [L] [홀수형] 박스, [C] "수학 영역",     [R] 페이지번호(큰 글자).
    //   - documentclass 의 `twoside` 옵션과 함께 [LE,LO,CE,CO,RE,RO] 지시자 사용.
    // 사용자 요청 19차: 비제목 페이지 "수학 영역" 폰트를 페이지라벨(28.6pt) 의 80% 로 맞춤.
    //   28.6 × 0.8 = 22.88pt. lead 는 동일한 비율(1.2×) 유지 → 27.5pt.
    // 사용자 요청 23차: subjectTitle 에 숫자가 포함될 경우(예: "수학 1", "물리 2") 한글/숫자
    //   instance 분기가 일어나지 않도록 `\YggWithUnifiedDigits` 로 감싼다. 래퍼는 scope
    //   종료 시 charclass 를 원복하므로 본문에 영향 없음.
    const centerTitleSpec = `\\YggWithUnifiedDigits{{\\YggSubject\\fontsize{22.88pt}{27.5pt}\\selectfont\\bfseries ${escapeLatexText(subjectTitle)}}}`;
    lines.push('\\pagestyle{fancy}');
    lines.push('\\fancyhf{}');
    // 사용자 요청 12차: 상단 페이지 라벨 전체를 추가로 5pt 더 아래로 이동.
    //   일반 페이지 기준 raisebox = 14.37pt → 9.37pt.
    //   [totalheight][depth] = 0pt 로 layout 에는 영향 없음.
    // 사용자 요청 17차:
    //   - `top=29.95mm` 으로 geometry 를 6pt 위로 이동. 헤더 영역 전체가 6pt 상승.
    //   - 페이지번호는 "절대 위치 고정" 이 필요하므로 raisebox 를 9.37pt → 3.37pt 로 6pt 감소
    //     → geometry 상승분(-6pt) + raisebox 감소분(+6pt) 상쇄 → 페이지번호 y = 불변.
    //   - 홀수형박스는 raisebox 를 9.37pt 유지 → 헤더 상승분(-6pt) 만 반영되어 6pt 위로 이동.
    //   - 가운데 "수학 영역" (centerTitleSpec) 은 raisebox 없음 → 자연히 6pt 위로 이동.
    // 사용자 요청 19차:
    //   - 비제목 페이지 디바이더를 3pt 위로 올림 (아래 mockLayRuleY 11pt→14pt 변경)
    //   - 수학영역/홀수형박스도 3pt 위로 이동해 디바이더와 같이 상승
    //   - 페이지라벨은 "절대 위치 고정" 이므로 raisebox 3.37pt 유지
    //   - 수학영역: fancyhead[C] 전체를 \raisebox{3pt} 로 감싸 3pt 상승
    //   - 홀수형박스: raisebox 9.37pt → 12.37pt (3pt 추가 상승)
    // 사용자 요청 20차:
    //   - 홀수형박스 스펙을 fbox → tikz(box.center) 로 교체 (제목페이지 스타일 참조, 70%).
    //     tikz 박스는 baseline=(box.center) 이므로 raisebox 값은 "박스 중심의 상승량" 이 된다.
    //     기존 fbox 시각 top 위치(≈baseline+28pt) 를 유지하도록 raisebox 12.37 → 15.7pt 로 조정.
    //     (box 높이 24.6pt / 2 = 12.3pt + 15.7pt = 28.0pt, 기존 top 대비 거의 동일)
    // 사용자 요청 21차: 홀수형박스 중심을 "수학 영역" 텍스트 vertical center 와 수평 정렬.
    //   centerTitleSpec : font 22.88pt, 한글 글자 top ≈ baseline + 16pt, descender 없음 →
    //                     visual center ≈ baseline + 8pt.  여기에 \raisebox{3pt} 적용 →
    //                     수학영역 visual center ≈ hbox_baseline + 11pt.
    //   홀수형박스      : tikz baseline=(box.center) 이므로 raisebox 값 = "박스 중심의 상승량".
    //                     수학영역 center(11pt) 와 일치시키기 위해 raisebox 15.7pt → 11pt.
    lines.push(`\\fancyhead[LE,RO]{\\raisebox{3.37pt}[0pt][0pt]{${pageNumSpec}}}`);
    lines.push(`\\fancyhead[C]{\\raisebox{3pt}[0pt][0pt]{${centerTitleSpec}}}`);
    lines.push(`\\fancyhead[LO,RE]{\\raisebox{11pt}[0pt][0pt]{${formBoxSpec}}}`);
    // header rule / footer pagebox 는 절대 좌표로 그리므로 fancyhdr 의 기본 rule 은 끈다.
    lines.push('\\renewcommand{\\headrulewidth}{0pt}');
    lines.push('\\renewcommand{\\footrulewidth}{0pt}');
    // \fancyfoot 는 비워둠 (페이지박스는 \AddToShipoutPictureFG 에서 그림).
  } else {
    lines.push('\\pagestyle{fancy}');
    lines.push('\\fancyhf{}');
    if (logoEnabled) {
      lines.push(`\\fancyhead[R]{${logoHeadGraphic}}`);
    }
    lines.push('\\renewcommand{\\headrulewidth}{0pt}');
    lines.push('\\fancyfoot[C]{\\thepage}');
  }

  // 모의고사 첫 페이지에 로고를 크게 띄우는 mockfirst 스타일 — titlepage 옆에 함께 배치되는
  // 경우를 대비해 별도 pagestyle 로 정의만 해둔다. 사용 여부는 본문에서 결정.
  if (logoEnabled) {
    lines.push('\\fancypagestyle{mockfirst}{%');
    lines.push('  \\fancyhf{}%');
    lines.push(`  \\fancyhead[R]{\\raisebox{-0.3em}{\\includegraphics[height=2.2em,keepaspectratio]{${logoPathTex}}}}%`);
    lines.push('  \\renewcommand{\\headrulewidth}{0pt}%');
    lines.push('  \\renewcommand{\\footrulewidth}{0pt}%');
    lines.push('  \\fancyfoot{}%');
    lines.push('}');
  }

  // 모의고사 '제목 페이지' 전용 스타일 (사용자 요청 7차):
  //   - 일반 페이지와 **동일한 좌우 헤더 요소** (페이지번호 / 홀수형박스) 를 상속.
  //   - 가운데 `[C]` 에 **부제(titleTop) + 큰 타이틀(title)** 을 parbox[b] 로 담는다.
  //     ┌ 부제 "2025 경신중 1학년 내신 기출"       (titleTop × 1.1)
  //     │ \\[11.7pt]                              (= X, 부제 ↔ 제목페이지타이틀 여백)
  //     └ 제목페이지타이틀 "수학 영역"             (title × 1.1, 큰 글씨)
  //     → parbox[b] 로 정렬 → 마지막 줄(수학영역) baseline 이 head box 바닥과 맞춰져
  //       fancyhdr [LE,RO] 페이지번호 baseline 과 일치.
  //   - headsep = 24pt 로 설정 (본문 쪽 newgeometry 에서) → head bottom 이 일반 페이지와
  //     같은 y(72.4pt) 에 오도록 함 → 페이지번호도 일반 페이지와 같은 위치.
  //   - overlay 가로선은 "수학영역 baseline + 여백(= X × 1.2)" 위치에 그려진다.
  //     (타이틀↔부제 여백) : (수학영역↔가로선 여백) = 1.0 : 1.2.
  //   - 사용자 요청 7차 : 수학영역 폰트 크기를 \mockTitleFontSize × 1.1 로 10% 증가.
  //   - 부제/타이틀 텍스트는 각 페이지 진입 시 `\gdef\mockTitlePageSubtitle{…}` /
  //     `\gdef\mockTitlePageMain{…}` 로 글로벌 매크로에 세팅해두므로 여기서 참조.
  //   - headheight 은 `\newgeometry` 로 제목페이지에서만 확장 (본문 쪽에서).
  if (isMock) {
    // 기본 매크로를 빈 값으로 선언해두기(제목페이지 아닌 경우 참조 오류 방지).
    lines.push('\\providecommand{\\mockTitlePageSubtitle}{}');
    lines.push('\\providecommand{\\mockTitlePageMain}{}');
    lines.push('\\fancypagestyle{mocktitle}{%');
    lines.push('  \\fancyhf{}%');
    // 사용자 요청 16차:
    //   - 제목페이지의 부제/페이지라벨 정렬은 유지
    //   - 가로 디바이더와 슬롯 시작점만 더 아래로
    //   - 오른쪽은 페이지번호 + 홀수형 박스 세로 스택
    //   - 왼쪽은 "제 2교시" pill 박스
    lines.push(`  \\fancyhead[LE]{\\raisebox{47.53pt}[0pt][0pt]{${pageNumSpec}}}%`);
    lines.push(`  \\fancyhead[LO]{\\raisebox{13.1pt}[0pt][0pt]{${titleSessionBoxSpec}}}%`);
    lines.push(`  \\fancyhead[RO]{${titleRightHeaderSpec}}%`);
    // 부제(위) → \\[11.7pt] → 수학영역(아래, 큰글씨) 순서.
    //   parbox[b] 로 마지막 줄 baseline 이 head box 바닥에 align.
    lines.push('  \\fancyhead[C]{%');
    lines.push('    \\parbox[b]{\\dimexpr 0.6\\textwidth\\relax}{%');
    lines.push('      \\centering%');
    // 사용자 요청 14차:
    //   - 부제/메인타이틀 폰트를 HTML title row 와 같은 YggSubjectDisplay 로 통일
    //   - 메인타이틀 크기 +10% (기존 1.32 → 1.452)
    //   - 부제↔메인타이틀 간격 +30% (11.7pt → 15.21pt)
    // 사용자 요청 22차: 부제("2026학년도 …") 의 숫자 '2026' 이 한글과 다른 instance 로
    //   분기되는 이질감 제거를 위해 `\YggWithUnifiedDigits` 래퍼로 감싼다. 래퍼는 지역 scope
    //   에서만 0-9 의 charclass 를 HG 로 바꿨다가 즉시 원복하므로 본문 숫자에는 영향 없음.
    lines.push('      \\YggWithUnifiedDigits{{\\YggTopLabel\\fontsize{\\the\\dimexpr 1.1\\mockTitleTopFontSize\\relax}{\\the\\dimexpr 1.1\\mockTitleTopLead\\relax}'
      + '\\selectfont\\mockTitlePageSubtitle}}\\\\[15.21pt]%');
    // 사용자 요청 23차: 제목페이지 메인 타이틀(기본 "수학 영역") 에 숫자가 올 수 있으므로
    //   `\YggWithUnifiedDigits` 로 감싸 한글-숫자 instance 통일. 래퍼 범위는 이 한 줄.
    // 사용자 요청 24차: `\bfseries` + 22pt ↑ 환경에서 한글 어간격이 시각적으로 좁아 보이는
    //   문제("띄어쓰기가 반영이 안된 것처럼 보임") 를 `\spaceskip` 으로 보강. `\spaceskip`
    //   은 0pt 가 아닐 때 interword-glue 를 덮어쓰므로 그룹 내에서만 적용되도록 스코프 유지.
    // 사용자 요청 25차: 0.5em 은 과도 → 80% 수준인 0.4em 로 축소. 한글 사이 공간이
    //   시각적으로 "1글자" 정도로 자연스러워지도록.
    lines.push('      \\YggWithUnifiedDigits{{\\YggSubjectDisplay\\fontsize{\\the\\dimexpr 1.452\\mockTitleFontSize\\relax}{\\the\\dimexpr 1.452\\mockTitleLead\\relax}'
      + '\\selectfont\\bfseries\\spaceskip=0.4em\\xspaceskip=0.4em\\mockTitlePageMain}}%');
    lines.push('    }%');
    lines.push('  }%');
    lines.push('  \\renewcommand{\\headrulewidth}{0pt}%');
    lines.push('  \\renewcommand{\\footrulewidth}{0pt}%');
    lines.push('  \\fancyfoot{}%');
    lines.push('}');
  }

  lines.push('');
  lines.push('\\setstretch{1.7}');
  // 폰트 크기에 비례해 스케일되도록 em 기반으로 지정 (분수 등 큰 수식 포함 줄의 간격도 폰트 크기에 비례).
  lines.push('\\lineskiplimit=0.4em');
  lines.push('\\lineskip=1.2em');
  lines.push('\\spaceskip=1.2\\fontdimen2\\font plus 1.2\\fontdimen3\\font minus 1.2\\fontdimen4\\font');
  lines.push('\\setlength{\\parindent}{0pt}');
  lines.push('\\setlength{\\parskip}{0.3em}');
  lines.push('\\setlength{\\columnsep}{1.5em}');
  // \columnseprule 는 multicol 용. 본 템플릿의 모의고사 2단은 좌/우 minipage 를
  // 나란히 배치하는 방식이며, 단구분선은 shipout overlay 에서 절대좌표로 그린다.

  if (isMock) {
    // 모의고사형 페이지박스: footer 중앙(=단구분선 바로 아래 세로축) 에 "현재 / 총" 페이지 표시.
    //
    // 크기: 폭 = \paperwidth * 4%  (B4 기본 시 약 10.3mm 세로, 지면 크기에 자동 적응).
    //       높이 = 폭 / 2  (가로:세로 = 2:1 유지).
    //       line width = 0.4pt (단구분선/박스 두께 통일).
    //
    // 레이아웃 (2번 스크린샷 "13 / 20" 형태):
    //   ┌──────────┐
    //   │ 13 ╱ 20 │   대각선(좌하→우상)이 숫자들의 가운데 영역을 가로지른다.
    //   └──────────┘  현재 페이지 숫자의 하단과 총 페이지 숫자의 상단이 대각선에
    //                살짝 걸치도록 좌표/크기를 잡음.
    //
    // 구현 메모:
    //   - \mockPageBoxW / \mockPageBoxH 는 아래 전역 \newlength 로 선언.
    //   - 텍스트 크기는 박스 높이에 비례(0.58×H)해서, 용지 크기가 달라도 자연스럽게 스케일링.
    //   - 기준선(baseline) 0 은 박스 하단 과 맞추어 footer 에 자연스럽게 얹힘.
    lines.push('\\newlength{\\mockPageBoxW}');
    lines.push('\\newlength{\\mockPageBoxH}');
    // 폭 = 용지 "긴 변" 의 4%  ( B4(257x364mm) 세로배치 기준 14.56mm ≈ 41pt ).
    //   - \paperwidth < \paperheight  → portrait: 긴 변은 \paperheight.
    //   - 그 외 (landscape 또는 정사각형)  → 긴 변은 \paperwidth.
    // 사용자 요청 21차 (재수정): 너비 10% 증가 + 높이 5% 감소.
    //   W = 0.04×긴변 × 1.10 = 0.044×긴변.
    //   H = 0.5×W × 0.95 / 1.10 × W (원본 대비) → new H/new W = 0.5 × 0.95 / 1.10 = 0.4318.
    //   즉 new H = 0.4318 × new W (= old H × 0.95 = 원본 대비 5% 감소).
    lines.push('\\AtBeginDocument{%');
    lines.push('  \\ifdim\\paperheight>\\paperwidth%');
    lines.push('    \\setlength{\\mockPageBoxW}{\\dimexpr0.044\\paperheight\\relax}%');
    lines.push('  \\else%');
    lines.push('    \\setlength{\\mockPageBoxW}{\\dimexpr0.044\\paperwidth\\relax}%');
    lines.push('  \\fi%');
    lines.push('  \\setlength{\\mockPageBoxH}{\\dimexpr0.4318\\mockPageBoxW\\relax}%');
    // 제목페이지 타이틀 폰트 크기: title = \paperwidth * 4%, titleTop = title * 55%.
    //   B4 가로 257mm 기준 ⇒ title ≈ 10.28mm ≈ 29.2pt, titleTop ≈ 16.1pt.
    //   행간(lead) 은 각각 글자 크기의 1.15배로 설정.
    lines.push('  \\setlength{\\mockTitleFontSize}{\\dimexpr0.04\\paperwidth\\relax}%');
    lines.push('  \\setlength{\\mockTitleLead}{\\dimexpr1.15\\mockTitleFontSize\\relax}%');
    lines.push('  \\setlength{\\mockTitleTopFontSize}{\\dimexpr0.55\\mockTitleFontSize\\relax}%');
    lines.push('  \\setlength{\\mockTitleTopLead}{\\dimexpr1.15\\mockTitleTopFontSize\\relax}%');
    // 페이지박스는 shipout overlay 에서 절대좌표로 그리므로 \footskip 은 기본값 유지.
    lines.push('}');
    lines.push('\\newcommand{\\mockPageBoxDraw}{%');
    lines.push('  \\begin{tikzpicture}[baseline=0pt]%');
    lines.push('    \\draw[line width=0.4pt] (0,0) rectangle (\\mockPageBoxW,\\mockPageBoxH);%');
    // 대각선: 좌하 → 우상 (= '/' 방향).
    lines.push('    \\draw[line width=0.4pt] (0,0) -- (\\mockPageBoxW,\\mockPageBoxH);%');
    // 글자 크기 / 행간: 박스 높이 기준 비율.
    lines.push('    \\pgfmathsetlengthmacro{\\mockPageBoxFont}{0.46*\\mockPageBoxH}%');
    lines.push('    \\pgfmathsetlengthmacro{\\mockPageBoxLead}{0.55*\\mockPageBoxH}%');
    lines.push('    \\node[anchor=center, inner sep=0pt] at (0.18\\mockPageBoxW,0.65\\mockPageBoxH)%');
    lines.push('      {\\fontsize{\\mockPageBoxFont}{\\mockPageBoxLead}\\selectfont\\thepage};%');
    lines.push('    \\node[anchor=center, inner sep=0pt] at (0.82\\mockPageBoxW,0.35\\mockPageBoxH)%');
    lines.push('      {\\fontsize{\\mockPageBoxFont}{\\mockPageBoxLead}\\selectfont\\pageref{LastPage}};%');
    lines.push('  \\end{tikzpicture}%');
    lines.push('}');

    // ── 절대좌표 레이아웃 오버레이 ────────────────────────────────────────
    //
    // 모든 페이지에 동일 좌표로 다음 세 요소를 그린다.
    //   1) 상단 header rule  : 본문 윗 경계 선 (가로선)
    //   2) 세로 단구분선     : 페이지 중앙, 본문 영역 전체 높이
    //   3) 페이지박스        : 세로 단구분선 바로 아래 중앙 (현재/총 페이지)
    //
    // 좌표계: TikZ `remember picture, overlay` + 기준점 `current page.north west`
    //   (페이지 왼쪽 위 모서리, x → 오른쪽, y → 아래로 음수).
    //
    // geometry 변수:
    //   본문 영역 상단 y  = -(1in + \voffset + \topmargin + \headheight + \headsep)
    //                     = - (상단 여백 + header)
    //   본문 영역 하단 y  = 상단 y - \textheight
    //   좌우 본문 x 시작 = 1in + \oddsidemargin (odd page 기준, even 도 대칭이면 동일)
    //   페이지 중앙 x    = 0.5\paperwidth (실제 시각적 중앙)
    // 절대좌표 레이아웃용 dimen 들 (계산은 \AtBeginDocument 하단에서 수행).
    lines.push('\\newlength{\\mockLayTopY}');
    lines.push('\\newlength{\\mockLayBotY}');
    lines.push('\\newlength{\\mockLayLeftX}');
    lines.push('\\newlength{\\mockLayRightX}');
    lines.push('\\newlength{\\mockLayCenterX}');
    lines.push('\\newlength{\\mockLayBoxX}');
    lines.push('\\newlength{\\mockLayBoxY}');

    lines.push('\\AddToShipoutPictureFG{%');
    // 빠른정답(또는 기타 overlay 비활성) 페이지는 overlay 초입에서 바로 탈출.
    //   → 상단 가로선, 세로 단구분선, 페이지박스가 모두 그려지지 않는다.
    //   \quickanswerpage 플래그는 기본 false, 빠른정답 페이지 콘텐츠에서 true 로 세팅.
    lines.push('  \\ifquickanswerpage\\else');
    lines.push('  % 페이지마다 다시 계산: \\textheight, \\topmargin 등은 geometry 로 고정이지만');
    lines.push('  % \\AtBeginDocument 시점엔 일부 값이 확정 안 될 수 있어 매 페이지 갱신.');
    // 본문 영역 상단 y (north-west 기준 음수). geometry 에서 "top margin from paper edge" =
    //   1in + \voffset + \topmargin + \headheight + \headsep.
    lines.push('  \\setlength{\\mockLayTopY}{-1in}%');
    lines.push('  \\addtolength{\\mockLayTopY}{-\\voffset}%');
    lines.push('  \\addtolength{\\mockLayTopY}{-\\topmargin}%');
    lines.push('  \\addtolength{\\mockLayTopY}{-\\headheight}%');
    lines.push('  \\addtolength{\\mockLayTopY}{-\\headsep}%');
    // 본문 영역 하단 y = 상단 y - \textheight.
    lines.push('  \\setlength{\\mockLayBotY}{\\mockLayTopY}%');
    lines.push('  \\addtolength{\\mockLayBotY}{-\\textheight}%');
    // 좌우 본문 가로 경계 x.
    lines.push('  \\setlength{\\mockLayLeftX}{1in}%');
    lines.push('  \\addtolength{\\mockLayLeftX}{\\oddsidemargin}%');
    lines.push('  \\setlength{\\mockLayRightX}{\\mockLayLeftX}%');
    lines.push('  \\addtolength{\\mockLayRightX}{\\textwidth}%');
    // 페이지 중앙 x.
    lines.push('  \\setlength{\\mockLayCenterX}{0.5\\paperwidth}%');
    // 페이지박스 좌하단.
    lines.push('  \\setlength{\\mockLayBoxX}{\\mockLayCenterX}%');
    lines.push('  \\addtolength{\\mockLayBoxX}{-0.5\\mockPageBoxW}%');
    lines.push('  \\setlength{\\mockLayBoxY}{\\mockLayBotY}%');
    lines.push('  \\addtolength{\\mockLayBoxY}{-4pt}%');
    lines.push('  \\addtolength{\\mockLayBoxY}{-\\mockPageBoxH}%');
    // 세로선 시작 y (제목페이지용). \mockLayTopY 는 위에서 이 overlay 안에 세팅됐고,
    //   \mockHeaderBoxHeight 는 제목페이지 콘텐츠가 shipout 에 포함될 때 이미 글로벌로 세팅됨.
    //   일반 페이지에서는 이 값이 사용되지 않으므로 값이 부정확해도 무방.
    // offset (사용자 요청 6차) :
    //   - 제목페이지의 타이틀/부제 블록이 fancyhdr `[C]` parbox[t] 에 담기며,
    //     구조는 [타이틀 "수학 영역"] → vskip 11.7pt (X) → [부제 "2025 …"] 순.
    //   - `headsep=14pt` 로 설정 → parbox top 이 head 영역 top 에 align.
    //     head 영역 top = body_top - headsep - headheight = body_top - 86pt.
    //     parbox[t]: 타이틀 baseline ≈ head 영역 top + ascent ≈ body_top - 86 + 22 = body_top - 64pt.
    //     부제 baseline = 타이틀 baseline + 11.7pt + (lead 차이 보정 ≈ 20pt)
    //                   ≈ body_top - 64 + 31.7 ≈ body_top - 32pt.
    //   - 사용자 요청 7차 :
    //       parbox[b] + `\\[11.7pt]` 로 head bottom (= 72.4pt, 일반 페이지와 동일) 에
    //       수학영역 baseline 이 align. 수학영역 폰트 = mockTitleFontSize × 1.1 ≈ 32pt,
    //       descender ≈ 3.5pt → 수학영역 bottom ≈ head bottom = 72.4pt.
    //       사용자 요구 (수학영역↔가로선 여백) = X × 1.2 ≈ 14pt
    //         → 가로선 y = 72.4 + 14 ≈ 86.4pt = body_top - 10pt.
    //     ⇒ `\mockLayVRuleStartY = \mockLayTopY + 10pt`.
    //   - 슬롯 첫 줄 ≈ body_top + \topskip (≈ body_top + 11pt) → 가로선 아래 ≈ 21pt 간격.
    //   - `\mockHeaderBoxHeight` = 0pt 유지 (본문에 headerBlock 을 찍지 않음).
    //   - 일반 페이지는 \mockLayRuleY 를 사용하므로 이 값은 무관.
    lines.push('  \\setlength{\\mockLayVRuleStartY}{\\mockLayTopY}%');
    lines.push('  \\addtolength{\\mockLayVRuleStartY}{-\\mockHeaderBoxHeight}%');
    // 사용자 요청 15차: 직전 변경에서 제목페이지 디바이더/슬롯 시작점이 과도하게 위로 올라가
    //   상단 여백이 부족해졌으므로, 제목페이지 전용 offset 을 14pt 로 되돌린다.
    lines.push('  \\addtolength{\\mockLayVRuleStartY}{14pt}%');

    lines.push('  \\begin{tikzpicture}[remember picture,overlay]%');
    // 상단 header rule 과 세로 단구분선이 '한 점' 에서 만나도록 공유 y 좌표 사용.
    //   \mockLayRuleY = \mockLayTopY + 11pt (본문 상단선보다 11pt 위, 일반 페이지용).
    //   → 가로선과 슬롯 첫 줄(= \mockLayTopY) 사이 간격 = 11pt.
    // 사용자 요청 17차: +14pt → +11pt 로 3pt 축소 (디바이더가 본문에 더 가까워짐).
    //   효과: 디바이더-라벨박스 top 사이 간격이 10pt → 7pt 로 ~30% 감소.
    //   단, 이 변경만으로는 페이지라벨-디바이더 간격이 3pt 증가하므로
    //   위의 `top=29.95mm` 6pt 축소와 결합해 전체적으로 페이지라벨-디바이더 간격은
    //   14.87pt → 11.87pt (20% 감소) 로 맞춘다.
    // 사용자 요청 19차: +11pt → +14pt 로 3pt 확대. 두 가지 목적 동시 달성:
    //   1) 제목페이지 디바이더-슬롯 간격(14pt)과 일치 → 페이지 간 일관성.
    //   2) 비제목 페이지 디바이더가 3pt 위로 이동 → 페이지라벨과의 간격 ~20% 축소.
    //      (디바이더↔페이지라벨 하단 간격 ≈ 11.85pt → 8.85pt, 약 25% 감소.)
    //   수학영역/홀수형 박스는 위 raisebox 보정으로 3pt 함께 상승.
    lines.push('    \\pgfmathsetlengthmacro{\\mockLayRuleY}{\\mockLayTopY+14pt}%');
    // 상단 header rule + 세로 단구분선.
    //   - 일반 페이지  : 가로선 y = \mockLayRuleY        / 세로선 시작 y = \mockLayRuleY.
    //   - 제목페이지   : 가로선 y = \mockLayVRuleStartY  / 세로선 시작 y = \mockLayVRuleStartY.
    //                   → 제목페이지에선 가로선도 헤더 아래로 내려 세로선 상단과 정확히 교차.
    // 세로선이 페이지박스 위에서 끝나는 y 좌표 (본문 하단 + 5pt). 기존엔 본문 하단(\mockLayBotY)까지
    //   그렸으나 사용자 요청으로 세로선 종료 지점을 5pt 위로 올린다.
    lines.push('    \\pgfmathsetlengthmacro{\\mockLayVRuleEndY}{\\mockLayBotY+5pt}%');
    // 굵기 정책(사용자 요청):
    //   - 가로선 / 페이지박스 : 0.6pt (기존과 동일).
    //   - 세로 단구분선       : 0.8pt (가로선보다 약간 더 두껍게 — "단 구분선만 조금 더 두껍게").
    lines.push('    \\ifmocktitlepage%');
    // 제목페이지: 가로선 (수학영역 아래).
    lines.push('      \\draw[line width=0.6pt]%');
    lines.push('        ([shift={(\\mockLayLeftX,\\mockLayVRuleStartY)}]current page.north west) --%');
    lines.push('        ([shift={(\\mockLayRightX,\\mockLayVRuleStartY)}]current page.north west);%');
    // 사용자 요청 10차: 세로선 시작 y 를 **가로선과 동일**한 \mockLayVRuleStartY 로 맞춤
    //   → 가로선과 세로선이 붙어있음. (메인 타이틀 폰트가 +20% 커졌지만 가로선 offset 을
    //   14pt 로 낮췄기 때문에 여전히 수학영역 아래에 위치 → 관통 없음.)
    lines.push('      \\draw[line width=0.8pt]%');
    lines.push('        ([shift={(\\mockLayCenterX,\\mockLayVRuleStartY)}]current page.north west) --%');
    lines.push('        ([shift={(\\mockLayCenterX,\\mockLayVRuleEndY)}]current page.north west);%');
    lines.push('    \\else%');
    // 일반 페이지: 가로선 (본문 상단보다 14pt 위 = 슬롯 첫 줄과 14pt 간격).
    lines.push('      \\draw[line width=0.6pt]%');
    lines.push('        ([shift={(\\mockLayLeftX,\\mockLayRuleY)}]current page.north west) --%');
    lines.push('        ([shift={(\\mockLayRightX,\\mockLayRuleY)}]current page.north west);%');
    // 일반 페이지: 세로선 (가로선 y ~ 본문 하단 + 5pt).
    lines.push('      \\draw[line width=0.8pt]%');
    lines.push('        ([shift={(\\mockLayCenterX,\\mockLayRuleY)}]current page.north west) --%');
    lines.push('        ([shift={(\\mockLayCenterX,\\mockLayVRuleEndY)}]current page.north west);%');
    lines.push('    \\fi%');
    // 페이지박스 (scope 원점 = 박스 좌하단).
    lines.push('    \\begin{scope}[shift={([shift={(\\mockLayBoxX,\\mockLayBoxY)}]current page.north west)}]%');
    lines.push('      \\draw[line width=0.6pt] (0,0) rectangle (\\mockPageBoxW,\\mockPageBoxH);%');
    lines.push('      \\draw[line width=0.6pt] (0,0) -- (\\mockPageBoxW,\\mockPageBoxH);%');
    lines.push('      \\pgfmathsetlengthmacro{\\mockPageBoxFont}{0.46*\\mockPageBoxH}%');
    lines.push('      \\pgfmathsetlengthmacro{\\mockPageBoxLead}{0.55*\\mockPageBoxH}%');
    lines.push('      \\node[anchor=center, inner sep=0pt] at (0.18\\mockPageBoxW,0.65\\mockPageBoxH)%');
    lines.push('        {\\fontsize{\\mockPageBoxFont}{\\mockPageBoxLead}\\selectfont\\thepage};%');
    lines.push('      \\node[anchor=center, inner sep=0pt] at (0.82\\mockPageBoxW,0.35\\mockPageBoxH)%');
    lines.push('        {\\fontsize{\\mockPageBoxFont}{\\mockPageBoxLead}\\selectfont\\pageref{LastPage}};%');
    lines.push('    \\end{scope}%');
    lines.push('  \\end{tikzpicture}%');
    lines.push('  \\fi'); // \ifquickanswerpage 닫기
    lines.push('}');
    // 빠른정답 페이지 식별 플래그. 기본 false. 빠른정답 블록 진입 시 \global\quickanswerpagetrue.
    lines.push('\\newif\\ifquickanswerpage');
    lines.push('\\quickanswerpagefalse');
  }
  if (!isMock) {
    lines.push('\\newif\\ifquickanswerpage');
    lines.push('\\quickanswerpagefalse');
    lines.push('\\newif\\ifmocktitlepage');
    lines.push('\\mocktitlepagefalse');
  }
  lines.push('\\newlength{\\mockColumnHeight}');
  lines.push('\\newlength{\\mockSlotGap}');
  lines.push('\\newlength{\\mockLeftSlotHeight}');
  lines.push('\\newlength{\\mockRightSlotHeight}');
  // 제목 페이지 상단 헤더(타이틀/부제/hrule) 를 담는 box. 헤더 높이를 측정해
  // 본문 가용 높이(\mockColumnHeight) 계산 시 차감하는 용도.
  lines.push('\\newsavebox{\\mockHeaderBox}');
  // ─── 짝슬롯(row-pair) 문항번호 첫 줄 / 라벨 라인 높이 동기화 ───
  // 방식: 각 slot 첫줄 앞에 \vphantom{<좌 content><우 content>} 를 삽입.
  //       \vphantom 은 인자를 invisible 로 typeset 해 ht/dp 만큼의 strut 을 만들어 주므로,
  //       좌/우 slot 에 같은 argument 를 주면 두 slot 의 첫줄 top/bottom 이 정확히 일치.
  // content 는 페이지별 prelude 에서 \gdef\pair@content@<prefix>@<row>@<L|R> 로 미리 저장.
  // (직전의 \xdef + \rule 방식은 XeLaTeX 환경에서 skip/dimen 토큰 유출로 허상 문자열을
  //  페이지에 찍는 문제가 있어 폐기.)
  // 제목페이지 타이틀/서브타이틀 폰트 크기. \AtBeginDocument 에서 \paperwidth 에 비례해 설정.
  if (isMock) {
    lines.push('\\newlength{\\mockTitleFontSize}');
    lines.push('\\newlength{\\mockTitleLead}');
    lines.push('\\newlength{\\mockTitleTopFontSize}');
    lines.push('\\newlength{\\mockTitleTopLead}');
    // 제목페이지 여부 플래그. shipout overlay 의 세로 단구분선을 제목페이지에서만
    //   '헤더 박스 아래' 부터 그리도록 분기 처리.
    lines.push('\\newif\\ifmocktitlepage');
    lines.push('\\mocktitlepagefalse');
    // 제목페이지의 세로선 시작 y 좌표(= 헤더 박스 하단). \mockHeaderBox 높이를 측정해
    //   \ht + \dp + 여유를 \mockLayTopY 에 더해 내린 값.
    lines.push('\\newlength{\\mockLayVRuleStartY}');
    // 헤더 박스 \ht+\dp 의 전역 스냅샷. \setbox 는 기본적으로 로컬이라 scope 종료 후
    //   값이 롤백될 수 있으므로, 헤더 출력 직후 이 dimen 에 한 번 복사해 ship out
    //   시점 overlay 가 안전하게 참조하도록 한다.
    lines.push('\\newlength{\\mockHeaderBoxHeight}');
  }
  lines.push('');

  return lines.join('\n');
}

/* ------------------------------------------------------------------ */
/*  Render one question                                                */
/* ------------------------------------------------------------------ */

function resolveQuestionScore(question, scoreMapByQuestionId) {
  const questionUid = String(question?.question_uid || '').trim();
  const mapScoreByUid = Number.parseFloat(
    String(scoreMapByQuestionId?.[questionUid] ?? ''),
  );
  if (Number.isFinite(mapScoreByUid) && mapScoreByUid >= 0) {
    return Math.min(999, mapScoreByUid);
  }
  const questionId = String(question?.id || '').trim();
  const mapScore = Number.parseFloat(
    String(scoreMapByQuestionId?.[questionId] ?? ''),
  );
  if (Number.isFinite(mapScore) && mapScore >= 0) {
    return Math.min(999, mapScore);
  }
  const meta = question?.meta && typeof question.meta === 'object' ? question.meta : {};
  const metaScore = Number.parseFloat(
    String(meta.score_point ?? meta.scorePoint ?? ''),
  );
  if (Number.isFinite(metaScore) && metaScore >= 0) {
    return Math.min(999, metaScore);
  }
  return 3;
}

function formatQuestionScore(scoreValue) {
  if (!Number.isFinite(scoreValue)) return '3';
  if (Math.abs(scoreValue - Math.round(scoreValue)) < 0.0001) {
    return String(Math.round(scoreValue));
  }
  return scoreValue.toFixed(1).replace(/\.0$/, '');
}

// meta.score_parts (세트형 하위문항별 배점) 을 "sub(숫자문자열) → 점수" 맵으로 정규화한다.
// score_parts 원본: [{ sub: "1", value: 4 }, ...]
// 숫자 문자열로 매핑 (① → "1", (2) → "2" 등은 extractor 가 이미 정규화).
function resolveSetSubScores(question) {
  const meta = question?.meta && typeof question.meta === 'object' ? question.meta : null;
  if (!meta) return null;
  const raw = meta.score_parts;
  if (!Array.isArray(raw) || raw.length === 0) return null;
  const out = new Map();
  for (const part of raw) {
    if (!part || typeof part !== 'object') continue;
    const sub = String(part.sub ?? '').trim();
    if (!sub) continue;
    const v = Number.parseFloat(String(part.value ?? ''));
    if (!Number.isFinite(v) || v <= 0) continue;
    out.set(sub, Math.min(999, v));
  }
  return out.size > 0 ? out : null;
}

// ─── 짝슬롯 동기화용 "첫 줄 probe" LaTeX 생성 ───
// 슬롯 첫 줄(= 문항번호 라인) 의 최대 height/depth 를 좌/우 slot 사이에 동기화하기 위해,
// 해당 줄 content 를 \sbox 로 측정할 수 있도록 LaTeX 조각을 만들어준다.
//
// 반환 문자열은 한 \hbox 안에 넣을 수 있는 inline content 이며, 줄바꿈·단락 제어문을
// 포함하지 않는다. (호출부가 \sbox 로 감싸 측정한다.)
//
// "stem 의 첫 줄" 을 엄밀히 추출하는 것은 불가능하지만(실제 wrap 위치는 \linewidth 에 의존),
// 분수 등 라인 높이를 키우는 요소는 stem 전체에 퍼져있지 않고 "첫 paragraph 의 앞부분" 에
// 집중되는 경향이 있으므로, "문항번호 + stem 첫 text paragraph 전체" 를 한 \hbox 에 담는
// 것으로 충분한 근사가 된다. \hbox 는 overflow 해도 ht/dp 는 content 의 max 로 계산된다.
function getFirstLineProbeLatex(question, { showQuestionNumber = true } = {}) {
  const qNum = question?.question_number || question?.questionNumber || '';
  const stem = question?.stem || '';
  const equations = question?.equations || [];
  // stem 첫 text paragraph 의 첫 source line 만 추출.
  //   - `[문단]` 같은 마커 줄은 skip.
  //   - `[보기]`, `[표...]`, `[그림]` 마커는 첫 줄에 오지 않도록 skip (probe 측정에 부적합).
  //   - 첫 text line 이 없으면 빈 문자열.
  let firstText = '';
  const lines = String(stem).split(/\n/);
  for (const raw of lines) {
    const s = raw.trim();
    if (!s) continue;
    if (/^\[(문단|소문항\d+|보기|조건|표|표행|표셀|그림|도형|도표)/.test(s)) continue;
    if (/^\[표\]/.test(s)) continue;
    firstText = s;
    break;
  }
  const parts = [];
  if (showQuestionNumber && qNum) {
    parts.push(`\\textbf{${escapeLatexText(String(qNum))}.}\\enspace`);
  }
  if (firstText) {
    parts.push(smartTexLine(firstText, equations));
  }
  // 최소한 strut 역할을 할 수 있도록 "가" (한글) 한 글자라도 보장.
  if (parts.length === 0) parts.push('\\strut');
  return parts.join('');
}

function renderOneQuestion(question, {
  sectionLabel,
  showQuestionNumber = true,
  mode,
  stemSizePt = 11,
  includeQuestionScore = false,
  questionScoreByQuestionId = null,
  // 짝슬롯(row-pair) 동기화용 \vphantom 스니펫. 라벨이 없는 slot 에서 "첫 hbox" 의 ht/dp 를
  // 짝 slot 의 첫 hbox 와 동일하게 맞추기 위해 주입된다.
  //   - 라벨 있는 slot : 라벨박스 자체가 첫 hbox → strut 불필요 (호출부가 빈 문자열 전달).
  //   - 라벨 없는 slot (짝에 라벨 있음) : \vphantom{<labelbox probe>}
  //   - 라벨 없는 slot (짝도 라벨 없음 & 분수 등 ht 편차) : \vphantom{<L stem 첫줄><R stem 첫줄>}
  pairStrutMacro = null,
  // (deprecated) 과거 라벨 라인 전용 strut. 현재는 사용하지 않음(시그니처 호환).
  pairLabelStrutMacro = null,
  // 짝슬롯 공통 상단 vertical padding (pt). row 에 라벨이 하나라도 있으면 양쪽 slot 모두
  // 같은 값을 받아 "첫 hbox 전 공통 간격" 을 대칭으로 확보 → [t] baseline 정렬 유지.
  topPadPt = 0,
  // 문항이 그려지는 페이지의 칼럼 수(1 | 2). 5지선다 레이아웃 선택 시 셀 폭 대비 선택지 길이
  // 비율을 바르게 평가하기 위해 필요. mock/csat 모드는 항상 2단.
  layoutColumns = 1,
} = {}) {
  // DB 에 form feed(^^L) 같은 제어문자가 박혀 저장된 경우(과거 VLM 파이프라인 버그)
  // 렌더 시점에서 한 번 더 복구해서 XeLaTeX 컴파일 실패를 막는다.
  // 새 추출은 vlm/client.js 에서 이미 정리되므로 이 단계는 no-op 이 된다.
  // question 객체는 외부 공유 레퍼런스일 수 있으므로 반드시 새 객체로 복사.
  // eslint-disable-next-line no-param-reassign
  question = sanitizeLatexControlChars(question) || {};
  const qNum = question?.question_number || question?.questionNumber || '';
  // stem 과 stemLineAligns 를 함께 정규화: `[문단:가운데]` 같은 인라인 정렬 마커를
  // plain `[문단]` 으로 바꾸고 속성은 stemLineAligns 에 이식한다. meta 경로(HWPX
  // 추출기가 원본 HWPX textAlign 을 담아둔 값)도 함께 읽어 최종 정렬값을 결정한다.
  const rawStem = question?.stem || '';
  const metaAligns = (() => {
    const meta = question?.meta && typeof question.meta === 'object' ? question.meta : {};
    if (Array.isArray(meta.stem_line_aligns)) return meta.stem_line_aligns;
    if (Array.isArray(meta.stemLineAligns)) return meta.stemLineAligns;
    if (Array.isArray(question?.stemLineAligns)) return question.stemLineAligns;
    return [];
  })();
  const normalizedAlign = applyInlineAlignmentMarkers(rawStem, metaAligns);
  const stem = normalizedAlign.stem;
  const stemLineAlignsResolved = normalizedAlign.stemLineAligns;
  const equations = question?.equations || [];
  const qMode = mode
    || question?.mode
    || question?.questionMode
    || question?.export_mode
    || question?.exportMode
    || 'objective';
  const choices = qMode === 'objective' ? (question?.choices || []) : [];
  const figurePaths = question?.figure_local_paths || [];
  const figureInfos = Array.isArray(question?.figure_local_infos)
    ? question.figure_local_infos
    : [];
  const figureLayout = resolveFigureLayout(question, stemSizePt);
  const layoutItems = Array.isArray(figureLayout?.items) ? figureLayout.items : [];
  const figureGroups = Array.isArray(figureLayout?.groups) ? figureLayout.groups : [];
  // [DEBUG] 렌더 진입 시점의 layout/scale 관찰 로그. 표/그림 설정이 실제 DB → 렌더러로
  //        전달됐는지를 한눈에 확인하기 위함. 진단 후 필요 시 제거 가능.
  if (process.env.PB_RENDER_DEBUG === '1'
      || (question?.meta && (question.meta.figure_layout || question.meta.table_scales))) {
    try {
      const metaSnap = question?.meta && typeof question.meta === 'object'
        ? question.meta : {};
      const flSummary = metaSnap.figure_layout && typeof metaSnap.figure_layout === 'object'
        ? {
            items: Array.isArray(metaSnap.figure_layout.items)
              ? metaSnap.figure_layout.items.length : 0,
            groups: Array.isArray(metaSnap.figure_layout.groups)
              ? metaSnap.figure_layout.groups.map((g) => ({
                  type: g?.type,
                  n: Array.isArray(g?.members) ? g.members.length : 0,
                  members: Array.isArray(g?.members) ? g.members : [],
                }))
              : [],
          }
        : null;
      const resolvedGroupsSummary = figureGroups.map((g) => ({
        type: g.type,
        members: g.members,
      }));
      console.log(
        `[xelatex:render] q=${question?.question_number || question?.id || '?'} `
        + `metaFigLayout=${JSON.stringify(flSummary)} `
        + `resolvedGroups=${JSON.stringify(resolvedGroupsSummary)} `
        + `tableScales=${JSON.stringify(metaSnap.table_scales || null)} `
        + `tableScaleDefault=${JSON.stringify(metaSnap.table_scale_default || null)}`,
      );
    } catch (e) {
      console.warn('[xelatex:render] debug log failed:', e?.message || e);
    }
  }
  const layoutByAssetKey = new Map();
  for (const it of layoutItems) {
    if (it?.assetKey) layoutByAssetKey.set(String(it.assetKey), it);
  }
  // HWPX binaryItemIDRef → 이 문항의 local figure 인덱스(0-based) 룩업.
  //   figure_worker 가 각 asset 에 item_id 를 박아두었고, hydrateFiguresForXeLatex 가
  //   figure_local_infos[i].itemId 에 그대로 흘려준다. 본문의 [[PB_FIG_<id>]] 토큰은
  //   이 맵으로 직접 해결되어 "토큰 → 파일" 이 1:1 로 확정된다.
  //   - 같은 ID 가 여러 번 등장하면 같은 asset 을 반복 사용 (의도된 중복 참조).
  //   - 매핑이 없으면 plain 마커처럼 positional fallback.
  const itemIdToLocalIdx = new Map();
  for (let i = 0; i < figureInfos.length; i += 1) {
    const id = String(figureInfos[i]?.itemId || '').trim();
    if (id && !itemIdToLocalIdx.has(id)) itemIdToLocalIdx.set(id, i);
  }
  let figIdx = 0;
  // 이미 방출한 local figure 인덱스 집합. positional fallback 이 token 경로로 이미 나간
  //   figure 를 중복 방출하지 않도록 하고, trailing fallback 루프의 "누락된 figure" 재방출도
  //   이 집합 기준으로 판단한다.
  const emittedFigIdxs = new Set();

  // figIdx → assetKey 시퀀스를 미리 계산해 두어 그룹 매칭에 사용한다.
  //  - figure_local_infos 가 있으면 그쪽 assetKey 를 우선 사용
  //  - 없으면 ord:N (N = 1-based) 로 폴백
  const figureTotalCount = Math.max(
    figurePaths.length,
    figureInfos.length,
    layoutItems.length,
  );
  const seqAssetKeys = [];
  for (let i = 0; i < figureTotalCount; i += 1) {
    const info = figureInfos[i];
    if (info?.assetKey) {
      seqAssetKeys.push(String(info.assetKey));
    } else if (info?.figureIndex) {
      seqAssetKeys.push(`idx:${info.figureIndex}`);
    } else {
      seqAssetKeys.push(`ord:${i + 1}`);
    }
  }

  // 그룹 시작 figIdx → { members: [figIdx...], gap: em } 맵. "연속된 figIdx 들의 assetKey 집합"
  // 이 group.members 집합과 정확히 일치하는 경우만 그룹 방출 후보로 등록한다.
  // (group.members 순서는 UI 저장 시 정렬될 수 있어 순서 비교 대신 집합 비교.)
  const groupByStartFigIdx = new Map();
  if (figureGroups.length > 0 && seqAssetKeys.length >= 2) {
    const keyToSeqIdx = new Map();
    seqAssetKeys.forEach((k, idx) => {
      if (!keyToSeqIdx.has(k)) keyToSeqIdx.set(k, idx);
    });
    for (const g of figureGroups) {
      if (!g || g.type !== 'horizontal') continue;
      const members = Array.isArray(g.members) ? g.members : [];
      if (members.length < 2) continue;
      const memberIdxs = members
        .map((m) => keyToSeqIdx.get(String(m)))
        .filter((n) => Number.isInteger(n));
      if (memberIdxs.length !== members.length) continue;
      const sorted = [...memberIdxs].sort((a, b) => a - b);
      // 연속성 검사: sorted[k] === sorted[0] + k
      let contiguous = true;
      for (let k = 1; k < sorted.length; k += 1) {
        if (sorted[k] !== sorted[0] + k) { contiguous = false; break; }
      }
      if (!contiguous) continue;
      const start = sorted[0];
      groupByStartFigIdx.set(start, {
        members: sorted,
        gap: Number.isFinite(g.gap) ? g.gap : 0.5,
      });
    }
  }
  // 이미 그룹으로 방출 "예약" 된 figIdx (그룹 첫 멤버 외의 멤버들). 해당 figIdx 의 마커를
  // 만나면 빈 문자열로 치환해 중복 출력 방지.
  const figIdxConsumedByGroup = new Set();
  for (const g of groupByStartFigIdx.values()) {
    for (let k = 1; k < g.members.length; k += 1) figIdxConsumedByGroup.add(g.members[k]);
  }

  function layoutForIndex(i) {
    const info = figureInfos[i];
    if (info?.assetKey && layoutByAssetKey.has(info.assetKey)) {
      return layoutByAssetKey.get(info.assetKey);
    }
    const ordKey = `ord:${i + 1}`;
    if (layoutByAssetKey.has(ordKey)) return layoutByAssetKey.get(ordKey);
    if (info?.figureIndex) {
      const idxKey = `idx:${info.figureIndex}`;
      if (layoutByAssetKey.has(idxKey)) return layoutByAssetKey.get(idxKey);
    }
    return null;
  }

  function figureIncludeExpr(i) {
    const p = figurePaths[i];
    if (!p) return null;
    const normalized = String(p).replace(/\\/g, '/');
    const layout = layoutForIndex(i) || {};
    const widthEmRaw = Number.isFinite(layout.widthEm) ? Number(layout.widthEm) : 20;
    const widthEm = Math.max(2, Math.min(50, widthEmRaw));
    const widthExpr = `${widthEm.toFixed(2)}em`;
    return {
      widthEm,
      widthExpr,
      include: `\\includegraphics[width=${widthExpr}]{${normalized}}`,
    };
  }

  function renderFigureLatex(i) {
    const expr = figureIncludeExpr(i);
    if (!expr) return '';
    const layout = layoutForIndex(i) || {};
    const anchor = String(layout.anchor || 'center').toLowerCase();
    const offsetX = Number.isFinite(layout.offsetXEm) ? Number(layout.offsetXEm) : 0;
    const offsetY = Number.isFinite(layout.offsetYEm) ? Number(layout.offsetYEm) : 0;
    const hOffset = Math.abs(offsetX) > 1e-3 ? `\\hspace*{${offsetX.toFixed(2)}em}` : '';
    const vOffsetPre = offsetY > 1e-3 ? `\\vspace*{${offsetY.toFixed(2)}em}` : '';
    const vOffsetPost = offsetY < -1e-3 ? `\\vspace*{${offsetY.toFixed(2)}em}` : '';
    let body;
    if (anchor === 'left') {
      body = `\\par\\noindent ${hOffset}${expr.include}\\par`;
    } else if (anchor === 'right') {
      body = `\\par\\noindent\\hfill${expr.include}${hOffset}\\par`;
    } else {
      body = `\\par\\noindent{\\hfill${hOffset}${expr.include}\\hfill\\null}\\par`;
    }
    const pre = vOffsetPre ? `\n${vOffsetPre}` : '';
    const post = vOffsetPost ? `\n${vOffsetPost}` : '';
    return `${pre}\n${body}${post}\n`;
  }

  // 그룹(가로 배치) 전체를 한 줄 minipage 묶음으로 방출.
  // 각 멤버의 widthEm 을 그대로 존중해서 서로 다른 크기도 한 줄에 배치 가능.
  function renderFigureGroupLatex(group) {
    const gap = Number.isFinite(group?.gap) ? group.gap : 0.5;
    const pieces = [];
    for (let k = 0; k < group.members.length; k += 1) {
      const i = group.members[k];
      const expr = figureIncludeExpr(i);
      if (!expr) continue;
      if (pieces.length > 0) {
        pieces.push(`\\hspace{${gap.toFixed(2)}em}`);
      }
      pieces.push(
        `\\begin{minipage}[c]{${expr.widthExpr}}\\centering ${expr.include}\\end{minipage}`,
      );
    }
    if (pieces.length === 0) return '';
    // 한 줄 \hbox 안에서 hfill 로 수평 중앙 정렬.
    return `\\par\\noindent\\hbox to \\linewidth{\\hfill${pieces.join('%\n')}\\hfill\\null}\\par\n`;
  }

  function replaceFigureMarkers(text) {
    return text.replace(FIGURE_MARKER_RE, (_match, capturedItemId) => {
      // capturedItemId 가 값이면 [[PB_FIG_<id>]] 토큰, null 이면 plain [그림] 마커.
      //   토큰 경로: itemId → local idx 직접 해결. figIdx 는 마커 위치 카운터로만 소비.
      //   plain 경로: 아직 방출되지 않은 figIdx 를 찾아 1개 소비.
      const trimmedId = capturedItemId ? String(capturedItemId).trim() : '';
      const resolvedIdx = trimmedId ? itemIdToLocalIdx.get(trimmedId) : undefined;

      let i;
      if (Number.isInteger(resolvedIdx)) {
        i = resolvedIdx;
        // 마커 위치 카운터(figIdx)는 "stem 상 마커 순서" 를 대변한다.
        //   그룹/gap 로직이 이 카운터에 의존하므로 매 마커마다 1씩 증가.
        figIdx += 1;
      } else {
        // 이미 token 경로로 먼저 방출된 idx 는 건너뛰어 중복 방지.
        while (emittedFigIdxs.has(figIdx)) figIdx += 1;
        i = figIdx;
        figIdx += 1;
      }

      // 이미 이 idx 를 한 번 방출한 경우(같은 itemId 를 가진 두 번째 토큰 등) — 그대로 다시 방출.
      //   단, 그룹 처리는 첫 번째 한 번만.
      const alreadyEmitted = emittedFigIdxs.has(i);
      emittedFigIdxs.add(i);

      if (figIdxConsumedByGroup.has(i)) return '';
      const group = groupByStartFigIdx.get(i);
      if (group && !alreadyEmitted) return renderFigureGroupLatex(group);
      return renderFigureLatex(i);
    });
  }

  const parts = [];

  parts.push('\\begingroup');
  // minipage/multicols 내부에서도 자간이 늘어나지 않도록 raggedright 의 파라미터를 명시.
  parts.push('\\rightskip=0pt plus 1fil\\relax');
  parts.push('\\parfillskip=0pt plus 1fil\\relax');
  parts.push('\\parindent=0pt');
  parts.push('\\tolerance=9999\\emergencystretch=0pt');
  parts.push(showQuestionNumber ? '\\leftskip=1em' : '\\leftskip=0pt');

  // ─── (주의) 라벨 상단 padding 을 `\vspace*{Npt}` 로 구현하는 것은 불가 ───
  // 실측 결과: minipage[t][h][t] 의 vlist 첫 item 으로 `\vspace*` 를 넣으면
  //   \vspace* 명령 존재 자체(값이 0pt 이든 5pt 이든 무관)가 vtop baseline 재계산을
  //   트리거해 약 15pt 의 **상수** 수직 이동을 유발한다.
  //   - \vspace*{0pt} → labelbox yMin +15.4pt
  //   - \vspace*{5pt} → labelbox yMin +20.4pt  ( = 상수 15.4pt + 선형 5pt )
  // 따라서 "정확히 Npt 만 추가" 하는 수단으로 사용할 수 없어 기능을 제거한다.
  // 상단 여백을 조정하려면 overlay 의 제목페이지 VRuleStartY 오프셋(현재 28pt) 을 조정하거나
  // `\headheight` / `\headsep` 을 바꾸는 방식(간격 1:1 선형)이 권장된다.
  if (topPadPt > 0) {
    // 현재는 noop. 호출부 호환성을 위해 인자는 보존하되 아무 LaTeX 도 내지 않는다.
  }

  // ─── sectionLabel 라인 & 짝슬롯 첫-표시-라인 동기화 ───
  //
  // 목표:
  //   - 라벨이 있는 slot 의 "라벨 박스" 가 라벨이 없는 짝 slot 의 "문항번호 라인" 과
  //     수직 좌표상 정확히 같은 줄에 놓이게 한다.
  //
  // 구조:
  //   - 양쪽 slot 모두 minipage [t] 에서 시작. [t] 는 "첫 hbox 의 baseline" 을 외부 baseline
  //     과 일치시키므로, 첫 hbox 의 ht/dp 가 같으면 top edge 도 같아진다.
  //   - label 있는 slot : 첫 hbox = 라벨 박스 (fbox + 내부 컨텐츠)
  //     label 없는 slot : 첫 hbox = \vphantom{<라벨박스>} + \textbf{N.}... 
  //       → \vphantom 이 라벨 박스의 ht/dp 를 인자로부터 복사해 첫 줄의 ht/dp 를 라벨박스와
  //         동일하게 만든다.
  //
  // 중요(회피한 함정):
  //   - 과거 `\vspace*{5pt}\par` 를 라벨 앞에 넣으면 [t] minipage 의 "첫 줄 baseline = 외부
  //     baseline" 규칙이 깨져 좌측 slot 이 통째로 아래로 밀렸다 (측정 ~19pt). 따라서 상단
  //     vspace 는 제거. 상단 여백은 페이지 헤더 아래 공통 vspace 로 이미 확보됨.
  //   - \vphantom 인자는 "라벨 박스" 단독으로 둔다. 긴 stem 본문까지 포함시키면 hbox 내
  //     overfull 경고가 발생하고 일부 xetex 패턴에서 ht 전달이 불안정할 수 있다.
  //   - 라벨 박스 뒤에는 라벨-번호 시각적 간격을 위해 \vspace{10pt} 유지 (번호 라인만 내려감,
  //     라벨 자체의 top edge 는 그대로).
  const firstLineStrut = pairStrutMacro || '';
  if (sectionLabel) {
    const spaced = Array.from(String(sectionLabel)).map((c) => escapeLatexText(c)).join('\\,');
    // 10% 확대: 폰트 13.2pt(약 \large 의 1.1배), fboxsep 4.4pt, 좌우 \hspace 13.2pt, fboxrule 0.55pt.
    // \hspace{-1em} 으로 leftskip 바깥으로 빼서 slot minipage 왼쪽 경계에 딱 붙임.
    // 사용자 요청 22차: 라벨박스 내부 '5지선다형' 같은 텍스트에서 '5' 만 Latin instance
    //   로 분기되는 이질감을 제거하기 위해 fbox 내부 전체를 `\YggWithUnifiedDigits` 로
    //   감싼다. 래퍼는 지역 scope 에서만 charclass 를 바꾸고 원복하므로 본문 미영향.
    //   (아래 buildLabelProbe 도 동일하게 감싸 ht/dp 계산이 실제 렌더와 1:1 일치하도록 함.)
    const labelBoxInner = '{\\setlength{\\fboxrule}{0.55pt}\\setlength{\\fboxsep}{4.4pt}'
      + '\\fbox{\\YggWithUnifiedDigits{\\YggTopLabel\\hspace{13.2pt}\\fontsize{13.2pt}{15.84pt}\\selectfont '
      + spaced
      + '\\hspace{13.2pt}}}}';
    // labelBox 를 \raisebox 로 감싸 line ht 를 조절한다.
    //   - 사용자 요청 20차 (초안): 가로 구분선-라벨박스 상단 간격을 30% 축소.
    //     기존(raise=0pt, strut +5pt) 기준 gap ≈ 19pt (divider y = body_top-14pt,
    //     labelBox visible top ≈ body_top+5pt).
    //   - 사용자 요청 21차 (수정본):
    //       ① gap 을 기존 13pt → 11.7pt (10% 축소) 만 조정.
    //       ② 라벨박스 text baseline 과 짝슬롯 qNum baseline 이 수평 유지.
    //     구현: `\raisebox{0pt}[\dimexpr\height-2.3pt\relax][\depth]` 로 **baseline 은
    //     그대로 두고 reported ht 만 2.3pt 축소** 한다. (과거 raise=7.3pt 방식은 baseline
    //     자체가 이동해 qNum 과의 수평이 깨지는 부작용이 있어 철회)
    //     → 짝 slot strut 에도 동일한 2.3pt 축소 적용 → line ht = a - 2.3pt, 양쪽 공통
    //       baseline 유지 → labelBox ink top = body_top - 2.3pt → gap = 14 - 2.3 = 11.7pt ✓
    //   - 라벨박스 ↔ 문항번호 간격 (\vspace) 은 10pt → 7pt (30% 축소) 유지.
    const labelBox = `\\raisebox{0pt}[\\dimexpr\\height-2.3pt\\relax][\\depth]{${labelBoxInner}}`;
    parts.push(
      `\\noindent\\hspace{-1em}${labelBox}\\par`,
      '\\vspace{7pt}',
    );
  }

  if (showQuestionNumber && qNum) {
    // 라벨이 있으면 문항번호는 "두 번째 라인" → 이미 라벨 박스가 라인 ht 결정.
    // 라벨이 없으면 문항번호 라인이 "첫 표시 라인" → firstLineStrut(짝 slot 라벨박스 \vphantom)
    // 을 여기서 소비해 라벨박스와 동일 ht 를 가지도록 한다.
    const strut = sectionLabel ? '' : firstLineStrut;
    parts.push(
      `\\noindent\\hspace{-1em}${strut}\\textbf{${escapeLatexText(String(qNum))}.}\\enspace`,
    );
  } else if (!sectionLabel && firstLineStrut) {
    parts.push(`\\noindent${firstLineStrut}`);
  }

  // 점수 표기는 더 이상 문항번호 뒤에 두지 않고 "stem 의 마지막 라인 끝" 에 붙인다.
  // - 세트형(meta.score_parts 있음) : 각 (N) 소문항의 마지막 텍스트 파트 끝에 해당 하위문항 배점.
  // - 단문항                          : stem 마지막 텍스트 파트 끝에 총점(=resolveQuestionScore).
  // 아래에서 텍스트 파트를 push 할 때마다 partsMeta 에 { subQ } 를 함께 기록해
  // 후처리로 suffix 를 덧붙인다.
  const setSubScores = includeQuestionScore ? resolveSetSubScores(question) : null;
  const singleScoreText = includeQuestionScore && !setSubScores
    ? formatQuestionScore(resolveQuestionScore(question, questionScoreByQuestionId || {}))
    : '';
  // parts 인덱스 → { subQ } 메타. subQ: 0 = 본문/비세트, 1..N = 해당 소문항 구간의 텍스트.
  const partsMeta = new Map();
  let currentSubQ = 0;

  const segments = parseStemSegments(stem, stemLineAlignsResolved);

  // 문항 내 표 등장 순서 카운터 (meta.table_scales 키: struct:N / raw:N 와 대응).
  let structTableIdx = 0;
  let rawTableIdx = 0;

  // 콘텐츠 블록 전환 간격.
  // - BLOCK_GAP (6pt): 표 ↔ text, 그리고 5지선다 앞.
  // - BOX_GAP (보기/조건/데코 박스 위·아래 공통): 0.75\baselineskip.
  //     한글 본문은 \setstretch{1.7} 이므로 한 줄 공간 안에서 "실제 여백(leading)"은 약 0.7\baselineskip.
  //     180% 규칙을 그대로 적용하면 시각적으로 과도 → 0.75\baselineskip 에서 잘라 블록 위아래 여백이
  //     본문 한 줄 분 정도가 되도록 설정. "박스는 위아래 여백 일치" 원칙 적용.
  // - TABLE_GAP_TOP / FIG_GAP_TOP : 블록 위쪽 여백. 본문 descender 가 작아 명시적 보강 필요.
  // - TABLE_GAP_BOTTOM / FIG_GAP_BOTTOM : 0pt. 5지선다 첫 줄 ascender 가 자연 여백 제공.
  // \par 를 앞에 두어 현재 paragraph 를 강제 종료 → vspace 가 vertical mode 에서 동작.
  const BLOCK_GAP = '\\par\\vspace{6pt}';
  const BOX_GAP = '\\par\\vspace{0.75\\baselineskip}';
  // 그림·표 모두 위/아래 비대칭.
  // - "위" (본문 → 블록): 본문 descender 가 작아 자연 여백이 거의 없음 → 0.5\baselineskip 보강.
  // - "아래" (블록 → 5지선다): 5지선다(\setstretch{1.7}) 첫 줄의 자연 ascender 가 이미
  //   충분한 여백을 제공함 → 0pt.
  const TABLE_GAP_TOP = '\\par\\vspace{0.78\\baselineskip}';
  // 표 아래는 \hline 이 paragraph 의 물리적 바닥 → 그림 bitmap 의 여분 공간이 없음.
  // 시각적으로 그림과 비슷한 여백이 되도록 5pt 보정.
  const TABLE_GAP_BOTTOM = '\\par\\vspace{10pt}';
  const FIG_GAP_TOP = '\\par\\vspace{0.5\\baselineskip}';
  // 그림 아래는 5지선다 ascender 덕분에 자연 여백이 있지만, 시각 보강으로 3pt 추가.
  const FIG_GAP_BOTTOM = '\\par\\vspace{3pt}';
  const isBoxType = (t) => t === 'bogi' || t === 'deco';
  const isFigureType = (t) => t === 'figure';
  const isTableType = (t) => t === 'table' || t === 'raw_tabular';
  const isFigOrTableType = (t) => isFigureType(t) || isTableType(t);
  const isBigBlockType = (t) => isBoxType(t) || isFigOrTableType(t);
  // 블록의 "앞" (= 해당 블록 앞에 붙이는 여백) 과 "뒤" (= 해당 블록 뒤에 붙이는 여백) 분리.
  const gapBefore = (t) => {
    if (isFigureType(t)) return FIG_GAP_TOP;
    if (isTableType(t)) return TABLE_GAP_TOP;
    return BOX_GAP;
  };
  const gapAfter = (t) => {
    if (isFigureType(t)) return FIG_GAP_BOTTOM;
    if (isTableType(t)) return TABLE_GAP_BOTTOM;
    return BOX_GAP;
  };
  const gapRank = (g) => {
    if (g === TABLE_GAP_TOP) return 5;
    if (g === BOX_GAP) return 4;
    if (g === FIG_GAP_TOP) return 3;
    if (g === TABLE_GAP_BOTTOM) return 2;
    if (g === FIG_GAP_BOTTOM) return 1;
    return 0;
  };
  const maxGap = (a, b) => (gapRank(a) >= gapRank(b) ? a : b);

  // figure segment 가 실제로 본체를 방출할지 사전 판단.
  //   - figIdxConsumedByGroup: 그룹의 2번째 이후 멤버는 본체 렌더 생략 → gap 도 생략해야 함.
  //   - segmentWillEmit: sIdx 기준 해당 seg 가 무언가 push 하게 될지 예측.
  //   이 시점에서 figIdx 는 "지금까지 소비한 마커 수". figure seg 하나 = 마커 하나 소비.
  //   앞 segment 들이 지금까지 소비할 마커 수를 누적 카운트해 정확히 어떤 figIdx 에 닿는지 계산.
  const figMarkerCountUpTo = (upto) => {
    let n = 0;
    for (let i = 0; i < upto; i += 1) {
      const s = segments[i];
      if (!s) continue;
      if (s.type === 'figure') {
        n += 1;
      } else if (s.type === 'text' || s.type === 'bogi' || s.type === 'deco') {
        // 텍스트/박스 내부에도 마커가 남아있을 수 있음 — parseStemSegments 는 text 만
        // 승격하므로 text 안에는 사실상 더 없지만(분할됐음), bogi/deco 에는 남아있다.
        // plain [그림]/[도형]/[도표] 와 [[PB_FIG_<id>]] 토큰 모두 동등하게 "마커 1개" 로 카운트.
        const joined = (s.lines || []).join('\n');
        const m = joined.match(/\[\[PB_FIG_[^\]]+\]\]|\[(?:그림|도형|도표)\]/g);
        if (m) n += m.length;
      }
    }
    return n;
  };
  // 현재 seg 가 renderFigureLatex/Group 을 실제로 방출할지 판정.
  //   - consumed by group 의 2번째+ 멤버: 방출 안 함.
  //   - [[PB_FIG_<id>]] 토큰: itemId 로 asset 해결 가능하면 방출 함.
  //   - plain [그림] 마커: positional figIdx 가 figurePaths 범위 안이면 방출 함.
  const figureSegWillEmit = (sIdx) => {
    const s = segments[sIdx];
    if (!s || s.type !== 'figure') return false;
    const segText = (s.lines || []).join('\n');
    const tokenMatch = segText.match(/\[\[PB_FIG_([^\]]+)\]\]/);
    if (tokenMatch) {
      const id = String(tokenMatch[1] || '').trim();
      const resolved = itemIdToLocalIdx.get(id);
      if (Number.isInteger(resolved)) {
        if (figIdxConsumedByGroup.has(resolved)) return false;
        return resolved < figurePaths.length;
      }
      // itemId 해결 실패 → positional 로 폴백. 아래 로직으로 합류.
    }
    const thisFigIdx = figMarkerCountUpTo(sIdx);
    if (figIdxConsumedByGroup.has(thisFigIdx)) return false;
    if (thisFigIdx >= figurePaths.length) return false;
    return true;
  };

  for (let sIdx = 0; sIdx < segments.length; sIdx++) {
    const seg = segments[sIdx];
    const prev = segments[sIdx - 1];
    const needsGap = prev && (prev.type !== 'text' || seg.type !== 'text');
    // figure seg 가 실제 렌더 생략될 예정이면, 앞쪽 gap 도 생략.
    const segEmits = seg.type === 'figure' ? figureSegWillEmit(sIdx) : true;
    parts.push(`% DBG seg#${sIdx} type=${seg.type} prev=${prev ? prev.type : 'NONE'} needsGap=${needsGap} segEmits=${segEmits} figIdx=${figIdx}`);
    if (needsGap && segEmits) {
      // 블록 전환 gap 선택 규칙:
      //   - 양쪽 모두 Big block 이면 "prev 의 아래 gap" 과 "seg 의 위 gap" 중 더 큰 쪽.
      //     예) 표(TABLE_GAP_TOP=0.78) ↔ 보기박스(BOX_GAP=0.75) → 0.78 (표 기준).
      //   - 한쪽만 Big block 이면 그 쪽의 gap.
      //   - 양쪽 다 Big block 이 아니면 BLOCK_GAP.
      const prevIsBig = isBigBlockType(prev.type);
      const segIsBig = isBigBlockType(seg.type);
      let chosen;
      if (prevIsBig && segIsBig) {
        chosen = maxGap(gapAfter(prev.type), gapBefore(seg.type));
      } else if (segIsBig) {
        chosen = gapBefore(seg.type);
      } else if (prevIsBig) {
        chosen = gapAfter(prev.type);
      } else {
        chosen = BLOCK_GAP;
      }
      parts.push(`% DBG  → chosen=${chosen.replace(/\\/g, '\\\\')}`);
      parts.push(chosen);
    }

    if (seg.type === 'text') {
      // 세트형 [소문항N] 마커가 stem 에 이미 경계를 잡아놓은 경우에는
      // 문장 중간 "(N)" splitAtSubQuestionMarkers 중복 분할을 스킵 → 본문 인용 오분할 방지.
      const hasSubQMarker = seg.lines.some((l) => SUBQ_MARKER_LINE_RE.test(String(l)));
      let subQEmittedAny = false;
      // rawLine 간 누적된 "빈 줄 + 단독 [문단] 라인" 수. 다음 실제 콘텐츠/마커 앞에 수직 간격으로 반영.
      let outerPendingEmpty = 0;
      const segLineAligns = Array.isArray(seg.lineAligns) ? seg.lineAligns : [];
      for (let rawIdx = 0; rawIdx < seg.lines.length; rawIdx += 1) {
        const rawLine = seg.lines[rawIdx];
        const rawLineAlign = normalizeLineAlignValue(segLineAligns[rawIdx]);
        // [소문항N] 은 독립 라인이므로 여기에서 가로챔. 마커 자체는 출력하지 않고
        // 마커 직전까지 누적된 [문단]/빈 줄 수를 수직 간격으로 반영한다.
        //
        // - 첫 마커(본문 → (1) 사이): outerPendingEmpty 만큼만 반영 → "본문 … 서술하시오."
        //   뒤에 한 줄 띄우고 (1) 이 시작되도록.
        // - 두 번째 이후 마커((1) → (2) 사이): outerPendingEmpty 반영 + 기본 0.5줄 추가.
        if (SUBQ_MARKER_LINE_RE.test(String(rawLine))) {
          const extra = subQEmittedAny ? 0.5 : 0.0;
          const factor = extra + 0.4 * outerPendingEmpty;
          if (factor > 0.0001) {
            parts.push(`\\par\\vspace{${factor.toFixed(2)}\\baselineskip}`);
          } else {
            // 최소한 paragraph 종료만 해 두어 이후 (N) 라인이 별도 문단으로 시작되도록.
            parts.push('\\par');
          }
          outerPendingEmpty = 0;
          subQEmittedAny = true;
          // [소문항N] 마커의 N 을 현재 소문항 인덱스로 세팅. 이후 push 되는 텍스트 파트가
          // 이 소문항 그룹에 속한 것으로 기록되어 맨 뒤 텍스트에 [N점] suffix 가 붙는다.
          const m = String(rawLine).match(/\[\s*소문항\s*(\d+)\s*\]/);
          if (m) currentSubQ = Number(m[1]);
          continue;
        }
        // 빈 라인 또는 단독 [문단] (ex. "[문단]", "[문단][문단]") → outerPendingEmpty 증가.
        const rawStripped = String(rawLine || '').replace(PARAGRAPH_MARKER_RE, '').trim();
        if (!rawStripped) {
          // 해당 라인 내 [문단] 출현 횟수를 센다.
          const paragraphMatches = String(rawLine || '').match(PARAGRAPH_MARKER_RE);
          outerPendingEmpty += paragraphMatches ? paragraphMatches.length : 1;
          continue;
        }
        const withFigs = replaceFigureMarkers(rawLine);
        const trimmed = withFigs.trim();
        if (!trimmed) {
          outerPendingEmpty += 1;
          continue;
        }
        const subLines = trimmed.split(PARAGRAPH_MARKER_RE);
        // 연속된 [문단] 마커는 빈 subLine 들로 나타난다. 이를 누적 세어
        // content 사이에 \vspace 로 반영한다 (세트형 (1)/(2) 사이 간격 등).
        // 라인의 첫 콘텐츠 앞에는 outerPendingEmpty 를 선반영한다.
        let pendingEmpty = outerPendingEmpty;
        let emittedAny = false;
        outerPendingEmpty = 0;
        for (let i = 0; i < subLines.length; i++) {
          const sub = subLines[i].trim();
          if (!sub) {
            pendingEmpty += 1;
            continue;
          }
          // 한 sub 안에 "...(1)..." "...(2)..." 가 공백과 함께 섞여있는 경우(HWPX 추출에서
          // [문단] 가 누락되는 케이스)에도, " (N) " 마커 위치에서 분할해 별도 paragraph 로 낸다.
          // 단, 이미 [소문항N] 마커로 경계가 잡혀 있다면 본문 인용 오분할 방지를 위해 스킵.
          const pieces = hasSubQMarker ? [sub] : splitAtSubQuestionMarkers(sub);
          for (let p = 0; p < pieces.length; p += 1) {
            const piece = pieces[p];
            if (emittedAny) {
              parts.push('\\par');
              if (pendingEmpty > 0) {
                parts.push(`\\vspace{${(0.4 * pendingEmpty).toFixed(2)}em}`);
              }
            } else if (pendingEmpty > 0) {
              // 라인 앞쪽에 누적된 빈줄 → 이 라인의 첫 콘텐츠 앞에 반영.
              parts.push(`\\par\\vspace{${(0.4 * pendingEmpty).toFixed(2)}em}`);
            }
            pendingEmpty = 0;
            // extractor 가 [소문항N] 마커를 주입하지 않은 레거시 세트형 대응:
            //   조각이 "(N)" 으로 시작하면 currentSubQ 를 해당 N 으로 갱신.
            if (!hasSubQMarker) {
              const leading = piece.match(/^\s*[（(]\s*(\d+)\s*[)）]/);
              if (leading) currentSubQ = Number(leading[1]);
            }
            const explicitSubQLabel = piece.match(/^\s*[（(]\s*(\d+)\s*[)）]/);
            const isExplicitSubQBodyLine =
              hasSubQMarker
              && currentSubQ > 0
              && explicitSubQLabel
              && Number(explicitSubQLabel[1]) === currentSubQ;
            if (/\\includegraphics/.test(piece)) {
              parts.push(piece);
            } else {
              let rendered = renderStemTextLine(piece, equations);
              if (rendered.trim()) {
                // 라인별 정렬값에 따라 center/right/justify 환경으로 감싼다.
                //   - 원본 HWPX 문단 속성으로 center 가 기록되어 있거나,
                //   - 사용자가 리뷰 UI 에서 `[문단:가운데]` 마커를 넣어 정규화된 경우,
                //   두 경로 모두 seg.lineAligns 에 반영되어 여기로 흘러온다.
                //   \begin{center} 환경은 앞뒤로 `\par` 를 추가하지 않아 본문 흐름을
                //   유지하며, `\vspace`/outerPendingEmpty 기반 간격 계산과 독립적이다.
                // 세트형 소문항 본문 `(N) ...` 은 HWPX 원본에서 우측 정렬 메타가 섞여
                // 들어오는 사례가 있다. [소문항N] 마커로 경계가 확정된 경우 이 라인은
                // 레이아웃용 소문항 텍스트이므로 기존 DB 메타와 무관하게 좌측 정렬한다.
                const effectiveLineAlign = isExplicitSubQBodyLine ? 'left' : rawLineAlign;
                if (effectiveLineAlign === 'center') {
                  rendered = `\\begin{center}\n${rendered}\n\\end{center}`;
                } else if (effectiveLineAlign === 'right') {
                  rendered = `\\begin{flushright}\n${rendered}\n\\end{flushright}`;
                }
                parts.push(rendered);
                // 현재 파트가 속한 소문항 인덱스를 기록.
                partsMeta.set(parts.length - 1, { subQ: currentSubQ });
              }
            }
            emittedAny = true;
          }
        }
      }
    } else if (seg.type === 'bogi') {
      parts.push(renderBogiBoxLatex(seg.lines, equations, replaceFigureMarkers));
    } else if (seg.type === 'deco') {
      parts.push(renderDecoBoxLatex(seg.lines, equations, replaceFigureMarkers));
    } else if (seg.type === 'table') {
      structTableIdx += 1;
      const scale = resolveTableScale(question, 'struct', structTableIdx);
      const rows = parseTableLines(seg.lines);
      parts.push(renderTableLatex(rows, equations, scale));
    } else if (seg.type === 'raw_tabular') {
      // VLM 이 작성한 \begin{tabular}{...}...\end{tabular} 블록.
      // 1) autoWrapTabularCells 로 각 셀을 수식/텍스트 모드로 감싸고
      // 2) parseRawTabularToRows 로 struct 와 같은 rows 구조로 해체한 뒤
      // 3) renderTableLatex 에 넘겨 struct 와 동일한 그리드 렌더 경로로 통일한다.
      //
      // 이렇게 하면 가로 스케일, 세로 스케일, 컬럼별 독립 너비, 셀 정가운데 정렬,
      // 폰트 크기 불변성 모두가 한 가지 메커니즘으로 일관되게 동작한다.
      rawTableIdx += 1;
      const raw = seg.lines.join('\n');
      const patched = autoWrapTabularCells(raw);
      const rows = parseRawTabularToRows(patched);
      const scale = resolveTableScale(question, 'raw', rawTableIdx);
      if (rows.length === 0) {
        // 해체 실패 — 원본을 그대로 중앙 정렬 출력 (fallback).
        parts.push(`\\par\\noindent\\begin{center}\n${patched}\n\\end{center}\\par`);
      } else {
        parts.push(renderTableLatex(rows, equations, scale));
      }
    } else if (seg.type === 'figure') {
      // parseStemSegments 후처리에서 본문 중간의 [그림] 마커를 별도 figure 세그먼트로 승격시킨다.
      // seg.lines 는 ["[그림]"] 한 줄. replaceFigureMarkers 가 figIdx 를 순차 소비하면서
      // renderFigureLatex / renderFigureGroupLatex 의 출력으로 치환한다.
      //   - figIdxConsumedByGroup 에 포함된 마커(그룹의 2번째 이후 멤버)는 replaceFigureMarkers
      //     가 빈 문자열을 반환 → 이 경우 현재 seg 에서는 아무것도 push 하지 않는다
      //     (그룹 대표 figure seg 가 이미 본체를 방출했기 때문).
      const rendered = replaceFigureMarkers(seg.lines[0] || '[그림]');
      if (rendered && rendered.trim()) {
        parts.push(rendered);
      }
    }
  }

  // 마지막으로 방출된 "Big block" 의 타입을 기억해두면, 뒤이어 오는 선택지/5지선다 앞 간격을
  // 그 블록 타입에 맞는 gap (박스/그림·표) 으로 통일할 수 있다.
  let trailingBigType =
    segments.length > 0 && isBigBlockType(segments[segments.length - 1].type)
      ? segments[segments.length - 1].type
      : null;
  parts.push(`% DBG after-stem: figIdx=${figIdx}/${figurePaths.length} trailingBigType=${trailingBigType}`);
  // Trailing fallback: stem 마커 수가 figurePaths 개수보다 적어 누락된 figure 가 있으면 보충.
  //   기존 로직은 figIdx(마커 카운터) 부터 순차 방출이었으나, token 경로에서 같은 itemId 를
  //   반복 참조하거나 stem 마커가 순서를 뒤집는 케이스에서는 이 기준이 맞지 않는다.
  //   따라서 실제로 "한 번도 방출되지 않은" local idx 만 순서대로 보충한다.
  if (emittedFigIdxs.size < figurePaths.length) {
    for (let i = 0; i < figurePaths.length; i += 1) {
      if (emittedFigIdxs.has(i)) continue;
      if (figIdxConsumedByGroup.has(i)) continue;
      const group = groupByStartFigIdx.get(i);
      let rendered;
      if (group) {
        rendered = renderFigureGroupLatex(group);
        // group members 전체를 한 번에 방출 표시.
        for (const m of group.members) emittedFigIdxs.add(m);
      } else {
        rendered = renderFigureLatex(i);
        emittedFigIdxs.add(i);
      }
      if (rendered && rendered.trim()) {
        parts.push('% DBG trailing-fig push');
        parts.push(FIG_GAP_TOP);
        parts.push(rendered);
        trailingBigType = 'figure';
      }
    }
  }

  // ─── 점수 suffix 부착 ───
  // - 세트형(meta.score_parts 있음) : 각 소문항 그룹의 마지막 텍스트 파트 끝에 " [N점]".
  // - 단문항                        : subQ === 0 그룹의 마지막 텍스트 파트 끝에 " [N점]".
  //   (마지막 텍스트 파트가 없으면, 선택지/박스 뒤로 fallback 은 하지 않음.)
  if (includeQuestionScore) {
    // subQ → parts 의 마지막 인덱스 맵 구성.
    const lastIdxBySubQ = new Map();
    for (const [idx, meta] of partsMeta.entries()) {
      lastIdxBySubQ.set(meta.subQ, idx);
    }
    const appendScoreSuffix = (partIdx, scoreText) => {
      if (partIdx == null || partIdx < 0 || partIdx >= parts.length) return;
      const cur = parts[partIdx];
      if (typeof cur !== 'string' || cur.length === 0) return;
      // "\ [N점]" : \ = 고정폭 공백(hbox 내에서도 유지). \enspace 는 단락 종료 전에는 줄바꿈 허용이라
      // 한 줄 끝에서 점수가 다음 줄로 내려가 보일 수 있음 → \ 를 사용해 마지막 어절과 밀착.
      const suffix = `\\ {\\small [${escapeLatexText(scoreText)}점]}`;
      // 세트형 소문항은 "(N) ..." 을 `{\setbox0=\hbox{...} ... \par}` 한 그룹으로 감싸 렌더한다.
      // 이 경우 `\par}` 바깥에 suffix 를 붙이면 그룹이 이미 paragraph 를 종료한 뒤라
      // 점수가 새 paragraph 로 떨어져 "줄바꿈된 상태"로 보이게 된다.
      // → `\par}` 으로 끝나는 파트는 `\par` 직전(그룹 내부 본문 끝)에 suffix 를 삽입해
      //   본문 마지막 어절과 같은 paragraph 에 포함시킨다.
      //
      // 사용자 요청 34차: 세트형 소문항 `(N) ...` 은 실제로 이중 래핑 구조를 가진다.
      //   `renderStemTextLine` 의 출력 말미:
      //     {\setstretch{...}... {\setbox0=\hbox{(N)\ }\hangindent=\wd0\hangafter=1
      //                          \noindent\makebox[\wd0][l]{(N)\ }<본문>\par}\par}
      //                                                                ^^^^^^^^^^
      //                                                          inner \par} + outer \par}
      //   단일 `\par}` 매칭으로는 OUTER 를 잡아 suffix 가 inner 그룹 **바깥** 에 들어가
      //   → hangindent 가 풀린 새 paragraph 로 `[N점]` 이 떨어져 보이는 버그 발생.
      //   해결: 이중 `\par}\par}` 를 우선 탐지해 inner \par 직전에 삽입.
      const nestedParClose = /\\par\}\s*\\par\}\s*$/;
      const hangingParClose = /\\par\}\s*$/;
      if (nestedParClose.test(cur)) {
        parts[partIdx] = cur.replace(nestedParClose, `${suffix}\\par}\\par}`);
      } else if (hangingParClose.test(cur)) {
        parts[partIdx] = cur.replace(hangingParClose, `${suffix}\\par}`);
      } else {
        parts[partIdx] = `${cur}${suffix}`;
      }
    };
    if (setSubScores) {
      // 세트형: 각 소문항별 점수 부착.
      for (const [subKey, value] of setSubScores.entries()) {
        const subNum = Number(subKey);
        if (!Number.isFinite(subNum)) continue;
        const partIdx = lastIdxBySubQ.get(subNum);
        appendScoreSuffix(partIdx, formatQuestionScore(value));
      }
    } else if (singleScoreText) {
      // 단문항: subQ===0 그룹의 마지막 텍스트에 총점.
      // currentSubQ 가 한번도 증가하지 않은 경우 모든 텍스트는 subQ:0 그룹.
      const partIdx = lastIdxBySubQ.get(0);
      appendScoreSuffix(partIdx, singleScoreText);
    }
  }

  if (choices.length > 0) {
    // 5지선다 바로 위 블록이 그림/표/박스면 해당 블록 타입의 "아래" 여백(위 여백과 동일값) 적용.
    const choiceGap = trailingBigType ? gapAfter(trailingBigType) : BLOCK_GAP;
    parts.push(`% DBG choices-gap: trailingBigType=${trailingBigType} gap=${choiceGap.replace(/\\/g, '\\\\')}`);
    parts.push(choiceGap);
    parts.push(isBlankChoiceQuestion(question)
      ? renderBlankChoicesLatex(question, choices, equations)
      : renderChoicesLatex(choices, equations, layoutColumns));
  }

  parts.push('\\par');
  parts.push('\\endgroup');

  return parts.join('\n');
}

/* ------------------------------------------------------------------ */
/*  Single question (standalone, PNG)                                  */
/* ------------------------------------------------------------------ */

export function buildTexSource(question, options = {}) {
  const {
    fontFamily = 'Malgun Gothic',
    fontBold = 'Malgun Gothic Bold',
    stemSizePt = 12,
  } = options;

  const lines = [
    '\\documentclass[12pt,varwidth=16cm]{standalone}',
    '\\usepackage{fontspec}',
    '\\usepackage{amsmath,amssymb}',
    '\\usepackage{array}',
    '\\usepackage{kotex}',
    // 어절 중간에서 줄바꿈 금지: 공백(어절 경계)에서만 개행.
    '\\XeTeXlinebreaklocale ""',
    '\\XeTeXlinebreakskip=0pt plus 0pt minus 0pt',
    // 공백 폭을 절대 늘리지 않도록 tolerance/emergencystretch 를 0.
    '\\tolerance=9999',
    '\\emergencystretch=0pt',
    '\\usepackage{graphicx}',
    // adjustbox: \includegraphics 에 'max width' 같은 확장 키 사용.
    '\\usepackage[export]{adjustbox}',
    '\\usepackage{xcolor}',
    '\\usepackage[normalem]{ulem}',
    '\\usepackage{enumitem}',
    '\\usepackage{setspace}',
    '\\usepackage[most]{tcolorbox}',
    '\\newlength{\\tblcellwd}',
    '\\newlength{\\tblcellht}',
    '\\newcommand{\\mtemptybox}{\\ensuremath{\\vcenter{\\hbox{\\setlength{\\fboxsep}{0pt}\\framebox[1.35em][c]{\\rule{0pt}{0.9em}}}}}}',
    '\\newcommand{\\mtexponentemptybox}{\\vcenter{\\hbox{\\scriptsize\\setlength{\\fboxsep}{0pt}\\framebox[0.72em][c]{\\rule{0pt}{0.72em}}}}}',
    '',
    `\\setmainfont{${fontFamily}}[`,
    `  BoldFont = ${fontBold},`,
    ']',
    `\\setmainhangulfont{${fontFamily}}[`,
    `  BoldFont = ${fontBold},`,
    ']',
    '',
    '\\pagestyle{empty}',
    '\\setstretch{1.7}',
    // em 기반 → 폰트 크기에 비례 스케일 (분수/큰 수식 포함 줄의 여유 간격도 비례).
    '\\lineskiplimit=0.4em',
    '\\lineskip=1.2em',
    '\\spaceskip=1.2\\fontdimen2\\font plus 1.2\\fontdimen3\\font minus 1.2\\fontdimen4\\font',
    '\\setlength{\\parindent}{0pt}',
    '\\setlength{\\parskip}{0.4em}',
    '',
    '\\begin{document}',
    '\\raggedright',
    '\\lineskiplimit=0.4em\\lineskip=1.2em',
  ];

  return lines.join('\n') + '\n' + renderOneQuestion(question, { stemSizePt }) + '\n\\end{document}\n';
}

/* ------------------------------------------------------------------ */
/*  Full document (multi-question, PDF)                                */
/* ------------------------------------------------------------------ */

function parsePositiveInt(raw, fallback) {
  const parsed = Number.parseInt(String(raw ?? ''), 10);
  if (!Number.isFinite(parsed) || parsed <= 0) return fallback;
  return parsed;
}

function chunkQuestionsForMockGrid(questions, questionsPerPage) {
  const list = Array.isArray(questions) ? questions : [];
  const size = Math.max(1, parsePositiveInt(questionsPerPage, 4));
  const pages = [];
  for (let i = 0; i < list.length; i += size) {
    pages.push(list.slice(i, i + size));
  }
  return pages;
}

function renderMockSlotColumnBody(
  columnQuestions,
  slotCount,
  slotHeightMacro,
  {
    showQuestionNumber = true,
    stemSizePt = 11,
    includeQuestionScore = false,
    questionScoreByQuestionId = null,
    // 짝슬롯(row-pair) 동기화 파생 데이터. 길이는 slotCount 와 동일해야 한다.
    sectionLabels = [],            // string | null — 이 slot 이 라벨을 표시해야 하는지
    pairStrutMacros = [],          // \vphantom 스니펫 — 라벨 없는 slot 의 첫 hbox ht 동기화
    pairLabelStrutMacros = [],     // (deprecated) 과거 라벨 전용 strut
    topPadsPt = [],                // row 별 공통 상단 padding (pt). 짝 slot 과 동일 값이어야 함.
    // 슬롯 개별 높이 표현식(LaTeX dimen 식 또는 길이 매크로). 길이는 slotCount 와 동일.
    // 지정되지 않은(또는 falsy) 원소는 slotHeightMacro 로 폴백.
    perSlotHeightExprs = [],
  } = {},
) {
  const lines = [];
  const safeSlots = Math.max(1, Number(slotCount || 1));
  const qList = Array.isArray(columnQuestions) ? columnQuestions : [];

  for (let i = 0; i < safeSlots; i += 1) {
    const slotHeight = perSlotHeightExprs[i] || slotHeightMacro;
    lines.push(`\\begin{minipage}[t][${slotHeight}][t]{\\linewidth}`);
    const question = qList[i];
    if (question) {
      lines.push(renderOneQuestion(question, {
        showQuestionNumber,
        stemSizePt,
        includeQuestionScore,
        questionScoreByQuestionId,
        sectionLabel: sectionLabels[i] || null,
        pairStrutMacro: pairStrutMacros[i] || null,
        pairLabelStrutMacro: pairLabelStrutMacros[i] || null,
        topPadPt: Number(topPadsPt[i] || 0),
        layoutColumns: 2,
      }));
    } else {
      lines.push('\\vspace*{0.6\\baselineskip}');
    }
    lines.push('\\end{minipage}');
    if (i < safeSlots - 1) {
      lines.push('\\vspace{\\mockSlotGap}');
    }
  }
  return lines.join('\n');
}

/**
 * 슬롯별 높이 표현식을 계산한다.
 *
 * 규칙 (사용자 요청):
 *   - 슬롯이 1 개면 : 전체 높이를 그대로 사용 (차등 없음).
 *   - 슬롯이 2 개 이상이면 : "아래쪽 절반" 슬롯이 위쪽 슬롯보다 10% 더 높게.
 *     시각적 균형을 위해 하단 슬롯에 더 많은 공간을 할당.
 *     전체 합은 (colHeight - gaps) 로 유지.
 *
 * 슬롯 비율:
 *   - n=1 : [1.0]
 *   - n=2 : [1.0, 1.1]
 *   - n=3 : [1.0, 1.0, 1.1]
 *   - n=4 : [1.0, 1.0, 1.1, 1.1]  (아래 절반 = floor(n/2) .. n-1)
 *
 * 반환:
 *   - Array<string> : 각 슬롯의 `\dimexpr` 기반 height 표현식. minipage [t][H][t] 에 그대로 주입 가능.
 *   - colHeightMacro : 컬럼 전체 높이 LaTeX 매크로 (예: '\\mockLeftSlotHeight*n' 아닌 'mockColumnHeight' 자체).
 *   - gapExpr        : 슬롯 간 간격 합 표현식 (예: `(n-1)\\mockSlotGap`).
 */
function computePerSlotHeightExprs(slotCount, colHeightMacro, gapExpr) {
  const n = Math.max(1, Number(slotCount || 1));
  if (n === 1) {
    return [`\\dimexpr${colHeightMacro}-${gapExpr}\\relax`];
  }
  const lowerStart = Math.floor(n / 2);
  const ratios = Array.from({ length: n }, (_, i) => (i >= lowerStart ? 1.1 : 1.0));
  // 정수 스케일: 0.1 단위를 정수화(×10) → 분모 10*sum, 분자 ratio*10.
  const numerators = ratios.map((r) => Math.round(r * 10));
  const sumNumerator = numerators.reduce((a, b) => a + b, 0);
  // 각 slot 높이 = (\colHeight - gaps) × numerator / sumNumerator.
  // LaTeX 의 \dimexpr 는 "dimen * int / int" 순서 연산을 지원한다.
  return numerators.map((num) => (
    `\\dimexpr(${colHeightMacro}-${gapExpr})*${num}/${sumNumerator}\\relax`
  ));
}

/**
 * 제목 페이지(title page) 본문 맨 위에 삽입되는 큰 헤더.
 *
 * 레이아웃:
 *             \small  {titleTop}   (작은 상단 안내, 옵션)
 *             {\huge\bfseries {title}}   (큰 타이틀)
 *             \small  {subtitle}   (옵션)
 *   ────────────────────────────────────────────────  (hrule)
 *
 * 반환 문자열은 다음 순서의 LaTeX 시퀀스:
 *   1. \setbox\mockHeaderBox=\vbox to 0pt{\vss ...}  (헤더 내용을 고정 폭 \vbox 로 담아 측정)
 *   2. \noindent\copy\mockHeaderBox                (페이지에 찍되 box 자체는 그대로 보존)
 *   3. \par\vspace{8pt}                            (본문과의 간격)
 *
 * \copy 를 쓰므로 출력 후에도 \ht\mockHeaderBox / \dp\mockHeaderBox 로 헤더 실제 높이를
 * 읽을 수 있다 → 호출부에서 outer minipage 남은 높이 계산에 그대로 활용.
 *
 * `\thispagestyle{mocktitle}` 는 호출부에서 사전 지정해 fancy 헤더를 끈 상태로 사용한다.
 */
function renderMockTitlePageHeader({ titleTop = '', title = '', subtitle = '' } = {}) {
  const inner = [];
  inner.push('\\hsize=\\linewidth');
  inner.push('\\leftskip=0pt\\rightskip=0pt');
  inner.push('\\parindent=0pt');
  inner.push('\\centering');
  if (titleTop) {
    // titleTop : title 의 70% 크기. \the\dimen 으로 pt 문자열을 뽑아 \fontsize 에 전달.
    // 사용자 요청(3차):
    //   - titleTop 에 `\bfseries` 로 굵게 효과 추가.
    //   - titleTop 자체를 5pt 위로 올림 (\raisebox). [\height][\depth] 지정으로 박스 크기는 원본 유지
    //     → 뒤이은 \vspace/\vbox 수직 배치에 영향 없음, 시각적 이동만.
    //   - titleTop ↔ title 간 간격 `\vspace{6pt}` → `\vspace{9pt}` (지금의 1.5배).
    //     결과적으로 title 도 위로 살짝 올라감 (subtitle -5pt + gap +3pt = net -2pt).
    inner.push(
      `\\raisebox{5pt}[\\height][\\depth]{\\fontsize{\\the\\mockTitleTopFontSize}{\\the\\mockTitleTopLead}\\selectfont\\bfseries ${escapeLatexText(titleTop)}}\\par\\vspace{9pt}`,
    );
  }
  if (title) {
    // title : \paperwidth × 18%.
    inner.push(
      `{\\fontsize{\\the\\mockTitleFontSize}{\\the\\mockTitleLead}\\selectfont\\bfseries ${escapeLatexText(title)}}\\par`,
    );
  }
  if (subtitle) {
    inner.push(`\\vspace{6pt}{\\normalsize ${escapeLatexText(subtitle)}}\\par`);
  }
  // 헤더 아래 자체 가로선은 없음 — shipout overlay 의 상단 rule(페이지 상단 경계선)만 유지.

  return [
    // \global\setbox : 현재 scope 가 끝나도 박스의 \ht/\dp 값을 ship out 시점까지 유지.
    `\\global\\setbox\\mockHeaderBox=\\vbox{%\n${inner.join('\n')}%\n}`,
    '\\noindent\\copy\\mockHeaderBox',
    '\\par',
    '\\vspace{8pt}',
  ].join('\n');
}

function renderMockGridPageLatex(
  pageQuestions,
  {
    leftSlots,
    rightSlots,
    showQuestionNumber = true,
    isFirstPage = false,
    stemSizePt = 11,
    includeQuestionScore = false,
    questionScoreByQuestionId = null,
    titleHeader = null, // { titleTop, title, subtitle } (null = 일반 페이지)
    // 페이지 내 문항별 sectionLabel. 길이 = pageQuestions.length. 각 원소는 string | null.
    sectionLabels = [],
    // 페이지 고유 prefix — 여러 페이지에서 중복되지 않는 LaTeX 매크로 이름을 만들기 위해.
    pageMacroPrefix = 'A',
  },
) {
  const safeLeftSlots = Math.max(1, Number(leftSlots || 1));
  const safeRightSlots = Math.max(1, Number(rightSlots || 1));
  const list = Array.isArray(pageQuestions) ? pageQuestions : [];
  const leftQuestions = list.slice(0, safeLeftSlots);
  const rightQuestions = list.slice(safeLeftSlots, safeLeftSlots + safeRightSlots);
  const leftGapExpr = safeLeftSlots > 1 ? `${safeLeftSlots - 1}\\mockSlotGap` : '0pt';
  const rightGapExpr = safeRightSlots > 1 ? `${safeRightSlots - 1}\\mockSlotGap` : '0pt';

  // ─── 짝슬롯(row-pair) 동기화 준비 ───
  //
  // 규칙:
  //   - 같은 row (상단/하단) 의 좌·우 slot 두 개가 "짝".
  //   - 라벨이 하나라도 있는 row 에서는, 라벨 없는 쪽 slot 의 문항번호 라인이
  //     라벨 있는 쪽의 라벨 박스와 **수평 정렬** 되어야 한다.
  //   - 라벨이 둘 다 없는 row 는 아무 strut 도 필요 없음.
  //
  // 구현:
  //   - row 마다 "이 row 에 나타난 라벨 박스 LaTeX" 를 \gdef 로 macro 에 저장.
  //   - 라벨 **없는** slot 의 문항번호 라인 앞에 \vphantom{<라벨박스macro>} 삽입하여
  //     해당 라인의 ht/dp 를 라벨 박스의 ht/dp 와 동일하게 만든다.
  //   - 라벨 있는 slot 은 그 자체가 라벨박스를 출력 → 별도 strut 필요 없음(빈 문자열).
  //
  // 과거와의 차이:
  //   - 과거에는 \vphantom 인자에 (라벨박스 + 긴 stem 본문) 을 함께 넣었는데, xetex 환경에서
  //     ht 전달이 흐려지는 현상이 관찰되었고, 또 \vspace*{5pt}\par 를 라벨 위에 넣어 [t]
  //     minipage 첫 baseline 기준이 어긋나 좌측 slot 이 통째로 밀렸다(측정 ~19pt).
  //     본 구현은 이 두 요인을 제거한다.
  const maxRows = Math.max(safeLeftSlots, safeRightSlots);
  const labelsList = Array.isArray(sectionLabels) ? sectionLabels : [];
  const leftLabels = labelsList.slice(0, safeLeftSlots);
  const rightLabels = labelsList.slice(safeLeftSlots, safeLeftSlots + safeRightSlots);
  const leftStrutMacros = [];
  const rightStrutMacros = [];
  const leftLabelStrutMacros = [];
  const rightLabelStrutMacros = [];
  const leftTopPadsPt = [];
  const rightTopPadsPt = [];
  const pairProbePrelude = [];
  // 라벨 박스 probe — 실제 렌더 스타일과 1:1 동일해야 ht/dp 가 맞는다.
  //   사용자 요청 22차: 실제 labelBoxInner 와 똑같이 `\YggWithUnifiedDigits` 를 적용해야
  //   숫자 glyph 의 ht/dp (hangul instance 기반) 측정이 일치한다.
  const buildLabelProbe = (txt) => {
    if (!txt) return '';
    const spaced = Array.from(String(txt)).map((c) => escapeLatexText(c)).join('\\,');
    return '{\\setlength{\\fboxrule}{0.55pt}\\setlength{\\fboxsep}{4.4pt}'
      + '\\fbox{\\YggWithUnifiedDigits{\\YggTopLabel\\hspace{13.2pt}\\fontsize{13.2pt}{15.84pt}\\selectfont '
      + spaced
      + '\\hspace{13.2pt}}}}';
  };
  // 라벨이 있는 row 는 공통 상단 padding.
  //   (주의) `\vspace*{Npt}` 방식은 minipage[t][h][t] vlist 첫 item 에 삽입 시
  //   약 15pt 의 상수 오프셋이 발생해 "정확히 Npt" 제어가 불가하다.
  //   → 현재는 0pt 로 두고, 상단 여백 조정이 필요하면 overlay 의 VRule offset 또는
  //     `\headsep` 을 조정하는 방식(선형 1:1)으로 처리한다.
  const LABEL_ROW_TOP_PAD_PT = 0;
  for (let r = 0; r < maxRows; r += 1) {
    const labelL = leftLabels[r] || '';
    const labelR = rightLabels[r] || '';
    const qL = leftQuestions[r];
    const qR = rightQuestions[r];

    // --- case 1: row 에 라벨이 하나라도 있음 ---
    //
    // 사용자 요청 21차 (수정본):
    //   목표 ① 가로 구분선 ↔ 라벨박스 상단 gap 을 기존 13pt → 11.7pt (10% 축소).
    //   목표 ② 라벨박스 내부 텍스트 baseline ↔ 짝슬롯 qNum baseline 이 수평 정렬.
    //
    //   구현: strut 을 복원하되 `+5pt` 인플레이션 대신 "baseline 유지 + reported ht 만
    //         2.3pt 축소" 로 바꾼다. 동일한 ht 축소를 labelBox 에도 적용한다.
    //         → line ht = a - 2.3pt (양쪽 동일) 로 line ceiling 이 위로 올라가면서
    //           라벨박스 ink top 이 body_top 보다 2.3pt 위로 돌출 → gap = 14 - 2.3 = 11.7pt ✓
    //         → labelBox external baseline 은 content baseline 그대로 (raise=0) →
    //           짝 slot strut 의 baseline(=labelProbe baseline=labelBox text baseline) 과
    //           외부 line baseline 에서 자동 공유 → qNum baseline = labelBox text baseline ✓
    //   * 짝슬롯 qNum 줄에 분수·큰 수식이 있어 qNum ht 가 strut ht(=a-2.3) 를 초과할 경우
    //     line ceiling 이 그쪽 ht 로 확장 → labelBox 위치도 자연히 그에 맞춰 내려감.
    if (labelL || labelR) {
      const probeText = labelL || labelR;
      const macroName = `pair@labelprobe@${pageMacroPrefix}@${r}`;
      pairProbePrelude.push(
        `% --- pair label probe row ${r} (page ${pageMacroPrefix}) ---`,
        `\\expandafter\\gdef\\csname ${macroName}\\endcsname{${buildLabelProbe(probeText)}}%`,
      );
      const strutSnippet = `\\raisebox{0pt}[\\dimexpr\\height-2.3pt\\relax][\\depth]{\\vphantom{\\csname ${macroName}\\endcsname}}`;
      leftStrutMacros.push(labelL ? '' : strutSnippet);
      rightStrutMacros.push(labelR ? '' : strutSnippet);
      leftLabelStrutMacros.push(null);
      rightLabelStrutMacros.push(null);
      leftTopPadsPt.push(LABEL_ROW_TOP_PAD_PT);
      rightTopPadsPt.push(LABEL_ROW_TOP_PAD_PT);
      continue;
    }

    // --- case 2: row 에 라벨 없음 → 양쪽 stem 첫 줄 ht 의 max 로 동기화 ---
    //   분수(\dfrac), 위·아래첨자 등으로 한쪽 첫 줄 ht 가 커질 경우, 짝 slot 에도 동일 ht 가 주입되어
    //   "첫 hbox top edge" 가 수평으로 맞춰진다. \vphantom 은 width=0 이라 가시적 영향은 없다.
    const probeL = qL ? getFirstLineProbeLatex(qL, { showQuestionNumber }) : '\\strut';
    const probeR = qR ? getFirstLineProbeLatex(qR, { showQuestionNumber }) : '\\strut';
    const macroL = `pair@content@${pageMacroPrefix}@${r}@L`;
    const macroR = `pair@content@${pageMacroPrefix}@${r}@R`;
    pairProbePrelude.push(
      `% --- pair content probe row ${r} (page ${pageMacroPrefix}) ---`,
      `\\expandafter\\gdef\\csname ${macroL}\\endcsname{${probeL}}%`,
      `\\expandafter\\gdef\\csname ${macroR}\\endcsname{${probeR}}%`,
    );
    const strutSnippet = `\\vphantom{\\csname ${macroL}\\endcsname\\csname ${macroR}\\endcsname}`;
    leftStrutMacros.push(strutSnippet);
    rightStrutMacros.push(strutSnippet);
    leftLabelStrutMacros.push(null);
    rightLabelStrutMacros.push(null);
    // 라벨 없는 row : 추가 상단 padding 불필요.
    leftTopPadsPt.push(0);
    rightTopPadsPt.push(0);
  }

  // 공통 좌/우 minipage 내용을 함수로 분리.
  //
  // 컬럼 폭 & 구분선 주변 여백:
  //   - 좌/우 minipage 각 (0.4775\linewidth - 4pt) → 합계 (0.955\linewidth - 8pt).
  //   - 남은 (0.045\linewidth + 8pt) 가 \hfill 2개 에 균등 분배(페이지 중앙 기준 대칭).
  //     → 세로선(페이지 중앙) 과 각 컬럼 사이 여백에 추가로 +4pt 씩 확보.
  //   - 세로 단구분선(vrule) 은 이 minipage 사이에 '흐름 기반' 으로 두지 않고,
  //     페이지 중앙 x = \paperwidth/2 에 shipout overlay 로 절대 배치한다.
  //     (페이지별 콘텐츠 양과 무관하게 항상 동일 좌표에 그려지도록.)
  const MOCK_MINIPAGE_WIDTH = '\\dimexpr 0.4775\\linewidth-4pt\\relax';
  // 사용자 요청: 슬롯 ≥2 개이면 "아래쪽 절반" 슬롯 높이를 10% 더 크게 (1개면 차등 없음).
  //   - 좌/우 컬럼 각각 독립적으로 계산 (좌/우 슬롯 수가 다를 수 있음).
  //   - 전체 합은 (mockColumnHeight - gaps) 로 유지 → 페이지 전체 높이 불변.
  const leftPerSlotHeights = computePerSlotHeightExprs(safeLeftSlots, '\\mockColumnHeight', leftGapExpr);
  const rightPerSlotHeights = computePerSlotHeightExprs(safeRightSlots, '\\mockColumnHeight', rightGapExpr);
  const buildColumnsBlock = (heightMacro, leftHeightMacro, rightHeightMacro) => [
    // row-pair strut 매크로 선언 (페이지 내에서 반드시 컬럼 minipage 전에 실행되어야 함).
    pairProbePrelude.join('\n'),
    '\\noindent',
    `\\begin{minipage}[t][${heightMacro}][t]{${MOCK_MINIPAGE_WIDTH}}`,
    renderMockSlotColumnBody(leftQuestions, safeLeftSlots, leftHeightMacro, {
      showQuestionNumber,
      stemSizePt,
      includeQuestionScore,
      questionScoreByQuestionId,
      sectionLabels: leftLabels,
      pairStrutMacros: leftStrutMacros,
      pairLabelStrutMacros: leftLabelStrutMacros,
      topPadsPt: leftTopPadsPt,
      perSlotHeightExprs: leftPerSlotHeights,
    }),
    '\\end{minipage}',
    '\\hfill',
    `\\begin{minipage}[t][${heightMacro}][t]{${MOCK_MINIPAGE_WIDTH}}`,
    renderMockSlotColumnBody(rightQuestions, safeRightSlots, rightHeightMacro, {
      showQuestionNumber,
      stemSizePt,
      includeQuestionScore,
      questionScoreByQuestionId,
      sectionLabels: rightLabels,
      pairStrutMacros: rightStrutMacros,
      pairLabelStrutMacros: rightLabelStrutMacros,
      topPadsPt: rightTopPadsPt,
      perSlotHeightExprs: rightPerSlotHeights,
    }),
    '\\end{minipage}',
  ].join('\n');

  // --- 제목 페이지 경로: outer minipage(\linewidth × \textheight) 안에 헤더 + 좌/우 minipage. ---
  // outer minipage 는 자기 높이가 고정이므로 중간에 페이지 breaker 가 끼어들지 않는다.
  // 좌/우 minipage 높이는 outer 안에서 남은 공간(= \textheight - 헤더 박스 \ht+\dp - 여유) 로 계산.
  if (titleHeader) {
    // 사용자 요청(5차): 제목페이지 타이틀/부제를 fancyhdr 의 `[C]` parbox[b] 로 이관.
    //   - 제목페이지 전용 `\newgeometry{...,headheight=72pt,headsep=14pt,...}` (호출부에서 적용).
    //   - 본문에서는 headerBlock 출력하지 않음 → `\mockHeaderBoxHeight = 0`.
    //   - 가로선을 "부제 ↔ 타이틀 사이" 로 이동했으므로, 슬롯 시작도 함께 위로 당겨서
    //     타이틀 바로 밑에 자연스러운 간격(≈12pt)만 두고 시작하도록 한다.
    //     → body_top 기준 `\vspace*{-14pt}` 로 슬롯 첫 줄을 14pt 위로 올림.
    //     (타이틀 bottom ≈ body_top - 16pt 이므로 슬롯 label top ≈ body_top - 3pt
    //      ⇒ 타이틀 bottom 과 slot label top 간 ≈ 13pt 간격.)
    return [
      '\\begingroup',
      '\\setlength{\\mockSlotGap}{8pt}',
      '\\global\\setlength{\\mockHeaderBoxHeight}{0pt}%',
      '\\noindent\\begin{minipage}[t][\\textheight][t]{\\linewidth}',
      '\\setlength{\\mockColumnHeight}{\\dimexpr\\textheight-8pt\\relax}',
      '\\ifdim\\mockColumnHeight<180pt\\setlength{\\mockColumnHeight}{180pt}\\fi',
      `\\setlength{\\mockLeftSlotHeight}{\\dimexpr(\\mockColumnHeight-${leftGapExpr})/${safeLeftSlots}\\relax}`,
      `\\setlength{\\mockRightSlotHeight}{\\dimexpr(\\mockColumnHeight-${rightGapExpr})/${safeRightSlots}\\relax}`,
      buildColumnsBlock('\\mockColumnHeight', '\\mockLeftSlotHeight', '\\mockRightSlotHeight'),
      '\\end{minipage}',
      '\\par',
      '\\endgroup',
    ].join('\n');
  }

  // --- 일반/첫 페이지 경로: 좌/우 minipage 직접 배치. ---
  //   이전 버전의 '\vspace*{8pt}' 는 제거 → 사용자 요청대로 슬롯을 '20pt 더 올림'.
  //   (overlay 가로선과 슬롯 첫 줄 사이는 fancyhdr 의 \headsep 기본값에 의존.)
  const heightCalc = isFirstPage
    ? '\\setlength{\\mockColumnHeight}{\\dimexpr\\pagegoal-\\pagetotal-4pt\\relax}'
    : '\\setlength{\\mockColumnHeight}{\\textheight}';

  return [
    '\\begingroup',
    '\\setlength{\\mockSlotGap}{8pt}',
    heightCalc,
    '\\ifdim\\mockColumnHeight<180pt\\setlength{\\mockColumnHeight}{180pt}\\fi',
    `\\setlength{\\mockLeftSlotHeight}{\\dimexpr(\\mockColumnHeight-${leftGapExpr})/${safeLeftSlots}\\relax}`,
    `\\setlength{\\mockRightSlotHeight}{\\dimexpr(\\mockColumnHeight-${rightGapExpr})/${safeRightSlots}\\relax}`,
    buildColumnsBlock('\\mockColumnHeight', '\\mockLeftSlotHeight', '\\mockRightSlotHeight'),
    '\\par',
    '\\endgroup',
  ].join('\n');
}

/**
 * 표지(titlepage) 페이지 LaTeX 을 생성한다. HTML 경로의 renderCoverPages 를 단순화한 버전.
 *
 * 소비 필드 (coverPageTexts):
 *   - topTitle / titleTop    : 상단 안내 (예: "2026학년도 ...")
 *   - subjectTitle / titleMain : 과목명 (크게)
 *   - titleSub                : 부제
 *   - schoolName, subjectName, examType, timeLimit, studentName : 하단 정보표
 */
function renderCoverPageLatex(coverTexts, { academyLogoPath = '' } = {}) {
  const src = (coverTexts && typeof coverTexts === 'object') ? coverTexts : {};
  const topTitle = String(src.titleTop || src.topTitle || '').trim();
  const titleMain = String(src.titleMain || src.subjectTitle || '').trim();
  const titleSub = String(src.titleSub || '').trim();
  const schoolName = String(src.schoolName || '').trim();
  const subjectName = String(src.subjectName || '').trim();
  const examType = String(src.examType || '').trim();
  const timeLimit = String(src.timeLimit || '').trim();
  const studentName = String(src.studentName || '').trim();

  const logoPathTex = academyLogoPath ? String(academyLogoPath).replace(/\\/g, '/') : '';

  const out = [];
  out.push('\\begin{titlepage}');
  out.push('\\thispagestyle{empty}');
  out.push('\\begin{center}');
  if (logoPathTex) {
    out.push(`\\includegraphics[height=3em,keepaspectratio]{${logoPathTex}}\\par`);
    out.push('\\vspace{12pt}');
  }
  if (topTitle) {
    out.push(`{\\large ${escapeLatexText(topTitle)}}\\par`);
    out.push('\\vspace{18pt}');
  }
  // 중앙의 큰 제목/부제 — 수직 중앙에 배치.
  out.push('\\vspace*{\\fill}');
  if (titleMain) {
    out.push(`{\\fontsize{36pt}{42pt}\\selectfont\\bfseries ${escapeLatexText(titleMain)}}\\par`);
  }
  if (titleSub) {
    out.push('\\vspace{12pt}');
    out.push(`{\\LARGE ${escapeLatexText(titleSub)}}\\par`);
  }
  out.push('\\vspace*{\\fill}');
  // 하단 정보표 (있는 항목만 표시).
  const infoRows = [];
  if (schoolName) infoRows.push(['학교', schoolName]);
  if (subjectName) infoRows.push(['과목', subjectName]);
  if (examType) infoRows.push(['유형', examType]);
  if (timeLimit) infoRows.push(['제한시간', timeLimit]);
  infoRows.push(['수험생', studentName || '\\underline{\\hspace{8em}}']);
  if (infoRows.length > 0) {
    out.push('\\vspace{24pt}');
    out.push('\\begin{tabular}{r@{\\hspace{1em}}l}');
    for (const [label, value] of infoRows) {
      // value 가 underline 매크로면 그대로, 아니면 escape.
      const valTex = typeof value === 'string' && value.startsWith('\\underline')
        ? value
        : escapeLatexText(String(value));
      out.push(`${escapeLatexText(label)} : & ${valTex}\\\\[4pt]`);
    }
    out.push('\\end{tabular}\\par');
  }
  out.push('\\end{center}');
  out.push('\\end{titlepage}');
  // 2페이지: 접지용 빈 페이지 (인쇄 시 속지 보호/접지면 확보용).
  // titlepage 환경 내부에서 \clearpage 를 호출하면 다음 빈 페이지도 같은 pagestyle 이 적용됨.
  out.push('\\begingroup');
  out.push('\\thispagestyle{empty}');
  out.push('\\null');
  out.push('\\clearpage');
  out.push('\\endgroup');
  return out.join('\n');
}

/**
 * '빠른정답' 테이블 LaTeX. 마지막 페이지에 삽입 — 문항번호와 정답(export_answer) 을 2열 tabular 로.
 *
 * 컬럼 수는 문항 수에 따라 자동 결정:
 *   - ≤ 10문항: 2 columns (문항번호 | 정답)
 *   - ≤ 20문항: 3 columns × 이를 multicol 로 분할
 *   - 그 이상: 4 columns
 */
function renderQuickAnswerTableLatex(questions) {
  const qs = Array.isArray(questions) ? questions : [];
  if (qs.length === 0) return '';

  // 정답 소스 해석. export_answer → subjective_answer → objective_answer_key 순.
  function resolveAnswer(q) {
    const expAns = String(q?.export_answer || '').trim();
    if (expAns) return expAns;
    const sub = String(q?.subjective_answer || '').trim();
    if (sub) return sub;
    const objKey = String(q?.objective_answer_key || '').trim();
    if (objKey) return objKey;
    return '-';
  }

  // 빠른정답 값 렌더링 정책 (2026-04 개정):
  //
  //   규칙
  //   ────
  //   1) 동그라미 보기 번호(①~⑩) 단독 → 텍스트 그대로.
  //   2) 그 외는 '전체를 수식 모드로 감싸되 한글/CJK 부분만 \text{...} 로 빼기'.
  //      이러면 ^{2}, \frac{}{}, _{n} 같은 기존 math 문법이 그대로 살아난다.
  //
  //   CJK(한글/한자) 판정
  //   ─────────────────
  //     U+AC00..U+D7A3 : 한글 완성형
  //     U+1100..U+11FF : 한글 자모
  //     U+3130..U+318F : 호환 자모 (ㄱ, ㄴ ...)
  //     U+4E00..U+9FFF : CJK 한자
  //   (문장부호 '.', ',', '(', ')' 등은 수식 모드에서도 문제없이 출력되므로 그대로 둔다.)
  //
  //   TIMES 같이 대문자 식별자가 들어오면 그대로 math 에서 이탤릭 출력. 원본
  //   데이터에서 \times 로 변환되지 않은 건 별개 이슈로 HWPX 추출 시 처리.
  // HWPX 추출 단계에서 미변환된 특수 키워드를 LaTeX 수식 명령으로 치환.
  //   - TIMES → \times
  //   - DIV   → \div
  //   - PM    → \pm   (플러스-마이너스)
  //   - LEQ   → \leq  , GEQ → \geq , NEQ → \neq
  // 단어 경계(영문 식별자 경계) 에서만 치환해 변수명 오탐을 피한다.
  const SPECIAL_TOKEN_MAP = {
    TIMES: '\\times ',
    DIV: '\\div ',
    PM: '\\pm ',
    LEQ: '\\leq ',
    GEQ: '\\geq ',
    NEQ: '\\neq ',
  };
  function normalizeSpecialTokens(s) {
    let out = s.replace(/\b(TIMES|DIV|PM|LEQ|GEQ|NEQ)\b/g, (m) => SPECIAL_TOKEN_MAP[m] || m);
    // 본문 normalizeMathSegment 와 동일 규칙: 모든 \frac → \dfrac (강제 displaystyle 분수).
    out = out.replace(/\\frac(?![a-zA-Z])/g, '\\dfrac');
    return out;
  }

  function answerFigureLayoutFor(question, index) {
    const meta = question?.meta && typeof question.meta === 'object' ? question.meta : {};
    const layout = meta.answer_figure_layout && typeof meta.answer_figure_layout === 'object'
      ? meta.answer_figure_layout
      : {};
    const items = Array.isArray(layout.items) ? layout.items : [];
    const wantedKeys = [`idx:${index + 1}`, `ord:${index + 1}`];
    const item = items.find((it) => wantedKeys.includes(String(it?.assetKey || '').trim())) || {};
    return {
      widthEm: Math.max(2, Math.min(30, Number.isFinite(item.widthEm) ? Number(item.widthEm) : 10)),
      verticalAlign: String(item.verticalAlign || layout.verticalAlign || 'top').toLowerCase(),
      topOffsetEm: Math.max(0, Math.min(2, Number.isFinite(item.topOffsetEm) ? Number(item.topOffsetEm) : 0.55)),
    };
  }

  function renderAnswerFigureLatex(question, index) {
    const paths = Array.isArray(question?.answer_figure_local_paths)
      ? question.answer_figure_local_paths
      : [];
    const p = paths[index];
    if (!p) return escapeLatexText('[그림]');
    const normalized = String(p).replace(/\\/g, '/');
    const layout = answerFigureLayoutFor(question, index);
    const include = `\\includegraphics[width=${layout.widthEm.toFixed(2)}em]{${normalized}}`;
    if (layout.verticalAlign === 'top') {
      return `\\raisebox{\\dimexpr\\ht\\strutbox-\\height-${layout.topOffsetEm.toFixed(2)}em\\relax}{${include}}`;
    }
    return include;
  }

  const isCJKCh = (ch) => {
    const code = ch.codePointAt(0);
    if (code === undefined) return false;
    return (
      (code >= 0xAC00 && code <= 0xD7A3) ||
      (code >= 0x1100 && code <= 0x11FF) ||
      (code >= 0x3130 && code <= 0x318F) ||
      (code >= 0x4E00 && code <= 0x9FFF)
    );
  };

  // 한 개 세그먼트(라벨 없는 단순 답) 를 LaTeX 로 포매팅.
  //   - CJK 없음: 전체 $...$.
  //   - CJK 섞임: $ \text{한글} math \text{한글} ... $.
  function formatAnswerSegment(raw) {
    if (!raw) return '';
    const chunks = [];
    let buf = '';
    let curCJK = null;
    const flush = () => {
      if (buf.length === 0) return;
      chunks.push({ cjk: !!curCJK, text: buf });
      buf = '';
      curCJK = null;
    };
    // chunk 분리 규칙:
    //   - CJK / 비CJK 기준으로 나눈다.
    //   - 공백(\s)은 '현재 chunk' 에 합류시켜 CJK 단어 사이 띄어쓰기가 \text{} 안에 보존되게 한다.
    //     (math mode 는 공백을 모두 무시하므로, 공백을 \text{...} 바깥으로 빼면 결과물에서 띄어쓰기가 사라진다.)
    //   - chunk 가 아직 없고(curCJK==null) 공백으로 시작하면 직후 문자의 성격에 따라 결정되므로,
    //     일단 buf 에만 쌓아두고 다음 '비공백' 문자가 오면 그 성격을 curCJK 로 확정.
    for (const ch of Array.from(raw)) {
      const isSpace = /\s/.test(ch);
      const cjk = isSpace ? null : isCJKCh(ch);
      if (curCJK === null) {
        // 아직 성격 미정: 공백/비공백 모두 buf 에 담아두고, 비공백이면 성격을 이 문자로 확정.
        buf += ch;
        if (!isSpace) curCJK = cjk;
      } else if (isSpace) {
        // 공백은 현재 chunk 에 그대로 흡수.
        buf += ch;
      } else if (curCJK === cjk) {
        buf += ch;
      } else {
        flush();
        curCJK = cjk;
        buf = ch;
      }
    }
    flush();
    // 본문(smartTexLine) 의 수식은 전부 $\displaystyle ...$ 로 감싸므로,
    //   빠른정답 셀도 동일하게 displaystyle 로 맞춰 분수 크기 등이 일관되게 보이도록 한다.
    if (!chunks.some((c) => c.cjk)) return `$\\displaystyle ${raw}$`;
    // CJK chunk 는 \text{...}, 비CJK chunk 는 math 그대로.
    //   \text{} 와 math 사이 경계에 math 공백(\,) 을 넣어 한글 단어와 수식 기호 사이 간격 보존.
    //   단, CJK chunk 내부(앞뒤) 에 이미 공백이 포함되어 있다면 별도 간격은 불필요.
    const parts = chunks.map((c) => (c.cjk ? `\\text{${escapeLatexText(c.text)}}` : c.text));
    return `$\\displaystyle ${parts.join('')}$`;
  }

  // 하위문제 라벨 `(N)` (N = 1~9) 이 하나 이상 들어있는 답을 처리한다.
  //   - 라벨 자체는 수식 밖(텍스트) 으로 뽑아내 '(1)' 그대로 렌더.
  //   - 라벨 뒤에는 공백 한 칸(\ ) 유지.
  //   - 두 번째 이후 라벨 앞에는 추가 공백 두 칸(\ \ ) 삽입 (시각적 구분).
  //
  //   예)
  //     입력  "(1) 36=2^{2}\\times 3^{2}, 60=... (2) p+q=..."
  //     출력  "(1)\ $36=2^{2}\\times 3^{2}, 60=...$\ \ (2)\ $p+q=...$"
  function formatAnswerWithSubLabels(raw) {
    // 라벨 위치 찾기 : '(1)' ~ '(9)' 패턴. 공백/문자열 시작 앞뒤를 허용.
    const labelRe = /\((\d)\)/g;
    const matches = [];
    let m;
    while ((m = labelRe.exec(raw)) !== null) {
      matches.push({ idx: m.index, end: m.index + m[0].length, label: m[0] });
    }
    if (matches.length === 0) return formatAnswerSegment(raw.trim());

    const out = [];
    // 첫 라벨 이전 텍스트(거의 없지만 방어).
    if (matches[0].idx > 0) {
      const head = raw.slice(0, matches[0].idx).trim();
      if (head) out.push(formatAnswerSegment(head));
    }
    for (let i = 0; i < matches.length; i += 1) {
      const { end, label } = matches[i];
      const nextIdx = i + 1 < matches.length ? matches[i + 1].idx : raw.length;
      const segment = raw.slice(end, nextIdx).replace(/^\s+/, '').replace(/\s+$/, '');
      // 라벨 간 간격: 두 번째 이후 라벨 앞에 "공백 3칸" 에 해당하는 수평 간격 삽입.
      //   \ \ \  : 고정폭 공백 3개를 명시 → xelatex 에서 축약되지 않고 보장됨.
      if (i > 0) out.push('\\ \\ \\ ');
      out.push(label); // '(1)', '(2)' 는 text 모드 그대로.
      // 라벨 뒤 공백: 단순 "\ " 는 후속 $...$ 의 경계에서 일부 조판기가 스왈로하는 사례가 있음.
      //   → \hspace{0.33em} 로 폭을 물리적으로 고정해 "(1)" 과 수식 사이 1칸 간격을 보장한다.
      out.push('\\hspace{0.33em}');
      if (segment) out.push(formatAnswerSegment(segment));
    }
    return out.join('');
  }

  function formatAnswerTextTex(ans) {
    let raw = String(ans || '').trim();
    if (!raw) return '-';
    raw = normalizeSpecialTokens(raw);
    // 규칙 1. 동그라미 보기 번호 단독.
    if (/^[①②③④⑤⑥⑦⑧⑨⑩]$/.test(raw)) return escapeLatexText(raw);
    // 규칙 2. 하위문제 라벨 `(N)` 이 있으면 전용 처리.
    if (/\(\d\)/.test(raw)) return formatAnswerWithSubLabels(raw);
    // 규칙 3. 단일 세그먼트.
    return formatAnswerSegment(raw);
  }

  function formatAnswerTex(ans, question) {
    const raw = String(ans || '').trim();
    if (!raw) return '-';
    const markerRe = /(\[\[PB_ANSWER_FIG_[^\]]+\]\]|\[그림\])/g;
    if (!markerRe.test(raw)) return formatAnswerTextTex(raw);
    markerRe.lastIndex = 0;
    const out = [];
    let last = 0;
    let figIndex = 0;
    let match;
    while ((match = markerRe.exec(raw)) !== null) {
      const before = raw.slice(last, match.index).trim();
      if (before) out.push(formatAnswerTextTex(before));
      out.push(renderAnswerFigureLatex(question, figIndex));
      figIndex += 1;
      last = match.index + match[0].length;
    }
    const tail = raw.slice(last).trim();
    if (tail) out.push(formatAnswerTextTex(tail));
    return out.join('\\hspace{0.45em}');
  }

  // 문항 수에 따라 표 컬럼 수 결정.
  const n = qs.length;
  const cols = n <= 10 ? 2 : n <= 20 ? 3 : 4;

  // column spec: 각 컬럼은 [번호][정답] 한 쌍. 컬럼 사이 구분선 포함.
  const colSpec = Array.from({ length: cols }, () => 'r@{\\;}l').join('|');

  // 행 채우기: 위에서 아래로, 좌→우 순으로 각 컬럼을 채움 (모의고사 정답표 전통 배치).
  const rowsPerCol = Math.ceil(n / cols);
  const rows = [];
  for (let r = 0; r < rowsPerCol; r += 1) {
    const cells = [];
    for (let c = 0; c < cols; c += 1) {
      const idx = c * rowsPerCol + r;
      const q = qs[idx];
      if (q) {
        const num = String(q?.question_number || '?');
        cells.push(`${escapeLatexText(num)}.`);
        cells.push(formatAnswerTex(resolveAnswer(q), q));
      } else {
        cells.push('');
        cells.push('');
      }
    }
    rows.push(cells.join(' & ') + ' \\\\');
  }

  return [
    '\\clearpage',
    // 빠른정답 페이지는 overlay(가로선/세로 단구분선/페이지박스)와 fancyhdr 페이지번호를
    //   모두 제거한 '깨끗한' 페이지로 출력.
    //   - \thispagestyle{empty} : fancyhdr/plain 기본 요소(페이지번호) 제거.
    //   - \AtBeginShipoutNext{\global\quickanswerpagetrue} : 이 페이지의 shipout 타이밍에
    //     overlay 초입의 \ifquickanswerpage 가 true 가 되어 overlay 를 전부 스킵.
    //   - 또한 직전 페이지가 제목페이지였을 경우 \mocktitlepage 플래그도 false 로 리셋.
    '\\thispagestyle{empty}',
    '\\AtBeginShipoutNext{\\global\\quickanswerpagetrue\\global\\mocktitlepagefalse}',
    '\\begin{center}',
    '{\\Large\\bfseries 빠른정답}\\par',
    '\\vspace{12pt}',
    '\\renewcommand{\\arraystretch}{1.3}',
    `\\begin{tabular}{${colSpec}}`,
    '\\hline',
    rows.join('\n'),
    '\\hline',
    '\\end{tabular}',
    '\\end{center}',
  ].join('\n');
}

function parsePageColumnOverrides(raw) {
  if (!Array.isArray(raw)) return {};
  const out = {};
  for (const entry of raw) {
    const pageIdx = Number(entry?.pageIndex ?? entry?.page ?? entry?.pageNo ?? -1);
    const left = Number(entry?.left ?? entry?.leftCount ?? entry?.col1 ?? -1);
    const right = Number(entry?.right ?? entry?.rightCount ?? entry?.col2 ?? -1);
    if (pageIdx < 1 || left < 0 || right < 0) continue;
    out[pageIdx - 1] = { left: Math.max(1, left), right: Math.max(0, right) };
  }
  return out;
}

export function buildDocumentTexSource(questions, options = {}) {
  const {
    paper = 'B4',
    fontFamily = 'Malgun Gothic',
    fontBold = 'Malgun Gothic Bold',
    fontRegularPath = '',
    subjectFontPath = '',
    fontSize = 11,
    columns = 2,
    subjectTitle = '수학 영역',
    titlePageTopText = '',
    profile = '',
    maxQuestionsPerPage = 0,
    hidePreviewHeader = false,
    hideQuestionNumber = false,
    geometryOverride = '',
    pageColumnQuestionCounts = null,
    includeAcademyLogo = false,
    academyLogoPath = '',
    includeCoverPage = false,
    coverPageTexts = {},
    includeQuestionScore = false,
    questionScoreByQuestionId = null,
    includeQuickAnswer = false,
    // 제목 페이지 인덱스(1-based). 기본은 [1] 이 아니라 빈 배열 → 호출부에서 정함.
    titlePageIndices = [],
    // 제목 페이지별 타이틀/부제 override. [{ page, title, subtitle }, ...]
    titlePageHeaders = [],
    // UI 가 관리하는 컬럼 라벨 앵커. manual/auto/suppressed 3가지 source 를 가진다.
    //   - manual   : 사용자가 직접 입력한 라벨 (auto 를 덮어씀)
    //   - auto     : 서버 기본 생성. 클라이언트가 payload 에 포함해 보내면 그대로 그려진다.
    //   - suppressed : 사용자가 × 로 '제거' 한 slot. 이 slot 에는 auto 라벨도 출력하지 않는다.
    columnLabelAnchors = [],
    // 클라이언트(Flutter) 가 '새로고침' / 'PDF 생성' 경로에서 true 로 넘겨주는 플래그.
    //   true 이면 모드 전환 기반 자동 라벨 생성(예: '5지선다형') 을 전면 중단하고,
    //   columnLabelAnchors 에 들어있는 항목들만 그대로 사용한다.
    disableAutoLabels = false,
    layoutMeta = null,
  } = options;

  const logoEnabled = includeAcademyLogo && !!academyLogoPath;

  const preamble = buildPreamble({
    paper, fontFamily, fontBold, fontRegularPath, fontSize,
    subjectFontPath,
    subjectTitle, profile,
    hidePreviewHeader,
    geometryOverride,
    includeAcademyLogo: logoEnabled,
    academyLogoPath,
  });

  const parts = [preamble];
  parts.push('\\begin{document}');
  parts.push('\\raggedright');
  parts.push('\\lineskiplimit=0.4em\\lineskip=1.2em\n');

  const qList = Array.isArray(questions) ? questions : [];
  const isMock = profile === 'mock' || profile === 'csat';
  const effectiveLayoutMeta = layoutMeta && typeof layoutMeta === 'object' ? layoutMeta : null;
  let lastMode = null;

  // 표지 페이지 삽입 (본문 앞). mock/csat 뿐 아니라 일반 프로파일에서도 옵션이 켜졌으면 허용.
  if (includeCoverPage) {
    parts.push(renderCoverPageLatex(coverPageTexts, {
      academyLogoPath: logoEnabled ? academyLogoPath : '',
    }));
  }

  if (isMock && columns >= 2) {
    const qPerPage = parsePositiveInt(maxQuestionsPerPage, 4);
    const leftSlots = Math.max(1, Math.ceil(qPerPage / 2));
    const rightSlots = Math.max(1, qPerPage - leftSlots);

    // 제목 페이지 인덱스/헤더 정규화.
    // - titlePageIndices 가 비어있으면 기본값 [1] 을 사용(첫 페이지를 제목 페이지로).
    // - 각 페이지별 { title, subtitle } 을 Map<pageNo, ...> 로 뽑는다.
    // - title 이 비어있으면 subjectTitle 을, titleTop 은 titlePageTopText 를 폴백으로 사용.
    const titlePageSet = new Set(
      (Array.isArray(titlePageIndices) && titlePageIndices.length > 0
        ? titlePageIndices
        : [1]
      )
        .map((one) => Number.parseInt(String(one ?? ''), 10))
        .filter((n) => Number.isFinite(n) && n >= 1),
    );
    const titlePageHeaderMap = new Map();
    if (Array.isArray(titlePageHeaders)) {
      for (const row of titlePageHeaders) {
        if (!row || typeof row !== 'object') continue;
        const page = Number.parseInt(
          String(row.page ?? row.pageIndex ?? row.pageNo ?? ''),
          10,
        );
        if (!Number.isFinite(page) || page < 1) continue;
        titlePageHeaderMap.set(page, {
          title: String(row.title ?? row.subjectTitle ?? '').trim(),
          subtitle: String(row.subtitle ?? row.sub ?? '').trim(),
          titleTop: String(row.titleTop ?? row.topTitle ?? '').trim(),
        });
      }
    }
    const buildTitleHeaderForPage = (pageNo) => {
      if (!titlePageSet.has(pageNo)) return null;
      const override = titlePageHeaderMap.get(pageNo) || {};
      const title = override.title || subjectTitle || '';
      const subtitle = override.subtitle || '';
      // titleTop 은 첫 제목페이지뿐 아니라 중간에 추가된 제목페이지에서도 동일하게 표시.
      //   (override.titleTop 이 있으면 우선, 없으면 공용 titlePageTopText 폴백.)
      const titleTop = (override.titleTop || titlePageTopText || '').trim();
      if (!title && !subtitle && !titleTop) return null;
      return { titleTop, title, subtitle };
    };

    const overrides = parsePageColumnOverrides(pageColumnQuestionCounts);
    const hasOverrides = Object.keys(overrides).length > 0;

    let pages;
    if (hasOverrides) {
      pages = [];
      let cursor = 0;
      let pageNo = 0;
      while (cursor < qList.length) {
        const ov = overrides[pageNo];
        const perPage = ov ? (ov.left + ov.right) : qPerPage;
        pages.push(qList.slice(cursor, cursor + perPage));
        cursor += perPage;
        pageNo += 1;
      }
    } else {
      pages = chunkQuestionsForMockGrid(qList, qPerPage);
    }

    // mock 경로 전체에 걸쳐 sectionLabel 결정을 위한 "직전 문항 mode".
    //   페이지 경계를 넘어도 유지되어야, 같은 mode 가 이어지는 경우 중복 라벨을 찍지 않음.
    let lastModeMock = null;
    // 페이지별로 중복되지 않는 macro prefix (알파벳 A, B, C, ... → row 수 늘려야 하면 AA, AB).
    const toPageMacroPrefix = (idx) => {
      // 숫자 → 알파벳 (0 = A, 1 = B, ..., 25 = Z, 26 = AA).
      let n = idx;
      let s = '';
      do {
        s = String.fromCharCode(65 + (n % 26)) + s;
        n = Math.floor(n / 26) - 1;
      } while (n >= 0);
      return s;
    };
    // 제목페이지 전용 geometry (사용자 요청 4차):
    //   - 부제(×1.1) + vskip 11.7pt + 큰 타이틀(\mockTitleFontSize) 을 fancyhdr 의 [C] vbox 로 그림.
    //     vbox 예상 높이 ≈ 22pt(부제 lead) + 11.7pt + 36pt(타이틀 lead) ≈ 70pt ⇒ headheight=72pt.
    //   - headsep=14pt : 헤더 바닥 ↔ body_top 간격. 가로선은 이 범위 혹은 헤더 내부에 배치됨.
    //   - top ≈ 34mm ≈ 96.4pt : headheight+headsep = 86pt 를 top 안에 수용.
    //   - bottom / hmargin 은 일반 페이지와 동일 (세로선 끝 / 페이지박스 위치 유지).
    // 사용자 요청 18차: 제목페이지 부제/페이지라벨 정렬은 유지한 채,
    //   가로 디바이더와 슬롯 시작점을 한 번 더 아래로 보낸다.
    //   body_top 과 headsep 을 동일하게 +4.56pt 확장하면 header bottom 은 유지되고
    //   body_top/디바이더/슬롯만 선형으로 하향된다.
    const titleGeom = `${paper === 'A3' ? 'a3paper' : (paper === 'A4' ? 'a4paper' : 'b4paper')}`
      + ',hmargin=14mm,top=52.59mm,bottom=20mm,headheight=72pt,headsep=38.68pt';
    // 직전 페이지가 제목페이지였는지 기록 (일반 페이지 진입 시 \restoregeometry 삽입용).
    let activeTitleGeom = false;
    const autoColumnLabelAnchors = [];
    // UI 에서 들어온 columnLabelAnchors 를 page→(col,row) 맵으로 정규화.
    //   manual: 해당 slot 의 auto 라벨을 덮어씀.
    //   suppressed: 해당 slot 의 라벨을 완전히 제거 (auto 재생성도 금지).
    //   auto: 현재 XeLaTeX 경로에선 재생성이 기본이므로 참고용.
    //
    // 주의: 서버(api/worker)의 normalizeColumnLabelAnchors 를 거치면
    //   one.page 는 'first' | 'all' | number 중 하나가 될 수 있다.
    //   'first' 는 1페이지, 'all' 은 모든 페이지로 해석해야 한다.
    //   이전에 Number.parseInt 만 쓰면 'first' 가 NaN 이 되어 suppressed
    //   entry 가 drop 되는 버그가 있었음.
    const resolveAnchorPages = (raw, totalPages) => {
      if (raw === 'all' || raw === 'every') {
        const out = [];
        for (let p = 1; p <= totalPages; p += 1) out.push(p);
        return out;
      }
      if (raw === 'first' || raw === '' || raw === null || raw === undefined) {
        return [1];
      }
      const str = String(raw).trim().toLowerCase();
      if (str === 'all' || str === 'every') {
        const out = [];
        for (let p = 1; p <= totalPages; p += 1) out.push(p);
        return out;
      }
      if (!str || str === 'first') return [1];
      const n = Number.parseInt(str, 10);
      if (Number.isFinite(n) && n >= 1) return [n];
      return [];
    };
    const normalizedAnchorByPage = new Map();
    if (Array.isArray(columnLabelAnchors)) {
      for (const one of columnLabelAnchors) {
        if (!one || typeof one !== 'object') continue;
        const colRaw = Number.parseInt(
          String(one.columnIndex ?? one.column ?? one.col ?? ''),
          10,
        );
        const rowRaw = Number.parseInt(
          String(one.rowIndex ?? one.row ?? ''),
          10,
        );
        if (!Number.isFinite(colRaw) || colRaw < 0) continue;
        const rowIdx = Number.isFinite(rowRaw) && rowRaw >= 0 ? rowRaw : 0;
        const sourceRaw = String(one.source || '').trim().toLowerCase();
        const label = String(one.label ?? one.text ?? '')
          .replace(/\s+/g, ' ')
          .trim();
        const rawPage = one.page ?? one.pageIndex ?? one.pageNo ?? 1;
        const pageNos = resolveAnchorPages(rawPage, pages.length);
        for (const pageNoRaw of pageNos) {
          if (!normalizedAnchorByPage.has(pageNoRaw)) {
            normalizedAnchorByPage.set(pageNoRaw, new Map());
          }
          normalizedAnchorByPage
            .get(pageNoRaw)
            .set(`${colRaw}:${rowIdx}`, {
              source: sourceRaw === 'suppressed'
                ? 'suppressed'
                : sourceRaw === 'auto'
                  ? 'auto'
                  : 'manual',
              label,
            });
        }
      }
    }
    for (let i = 0; i < pages.length; i += 1) {
      const pageNo = i + 1;
      const titleHeader = hidePreviewHeader ? null : buildTitleHeaderForPage(pageNo);
      if (i > 0) parts.push('\\newpage\n');
      // 페이지 진입 시 제목페이지 플래그 명시 설정 — shipout overlay 가 세로선
      //   시작 y 를 결정하는 근거. renderMockGridPageLatex 내부에서 true 를 set 하지만
      //   '일반 페이지' 에선 명시적으로 false 로 리셋해야 직전 제목페이지 상태가
      //   이월되지 않는다.
      if (titleHeader) {
        // 제목페이지 진입: geometry 를 headheight 확장 버전으로 전환.
        if (!activeTitleGeom) {
          parts.push(`\\newgeometry{${titleGeom}}`);
          activeTitleGeom = true;
        }
        // `\fancyhead[C]` vbox 가 참조할 글로벌 매크로에 부제/타이틀 텍스트 세팅.
        //   (subtitle 필드는 현재 디자인에서 사용하지 않음 — titleTop=부제, title=메인타이틀.)
        parts.push(`\\gdef\\mockTitlePageSubtitle{${escapeLatexText(titleHeader.titleTop || '')}}`);
        parts.push(`\\gdef\\mockTitlePageMain{${escapeLatexText(titleHeader.title || '')}}`);
        parts.push('\\thispagestyle{mocktitle}');
        // 이 페이지(ship out 직전)에만 제목페이지 플래그 ON.
        //   \AtBeginShipoutNext 는 '다음 1회의 shipout 직전' 실행되므로
        //   \AddToShipoutPictureFG 의 \ifmocktitlepage 분기를 이 페이지에서만 true 로.
        parts.push('\\AtBeginShipoutNext{\\global\\mocktitlepagetrue}');
      } else {
        // 일반 페이지: 직전이 제목페이지였다면 geometry 를 원복.
        if (activeTitleGeom) {
          parts.push('\\restoregeometry');
          activeTitleGeom = false;
        }
        parts.push('\\AtBeginShipoutNext{\\global\\mocktitlepagefalse}');
        if (i === 0 && logoEnabled && !includeCoverPage) {
          // 첫 페이지 로고 강조(mockfirst) — 표지가 없고 제목 페이지 헤더도 없을 때.
          parts.push('\\thispagestyle{mockfirst}');
        }
      }
      const ov = overrides[i];
      const pageLeftSlots = ov ? ov.left : leftSlots;
      const pageRightSlots = ov ? ov.right : rightSlots;
      // 페이지 문항들의 sectionLabel 결정. 문항 mode 가 직전 mode 와 다를 때만 라벨 부여.
      const pageQs = pages[i];
      const pageAnchorMap = normalizedAnchorByPage.get(pageNo) || new Map();
      const pageLabels = pageQs.map((q, idx) => {
        const qMode = q?.mode
          || q?.questionMode
          || q?.export_mode
          || q?.exportMode
          || 'objective';
        const modeChanged = qMode !== lastModeMock;
        lastModeMock = qMode;
        const columnIndex = idx < pageLeftSlots ? 0 : 1;
        const rowIndex = idx < pageLeftSlots ? idx : (idx - pageLeftSlots);
        const anchorKey = `${columnIndex}:${rowIndex}`;
        const override = pageAnchorMap.get(anchorKey);
        // 사용자가 × 로 제거한 slot: 라벨을 완전히 출력하지 않음.
        if (override?.source === 'suppressed') return null;
        // 사용자가 직접 입력한 라벨 / 이전 렌더에서 auto 로 붙었다가 클라이언트가 보관해서
        //   다시 전달한 라벨: 그대로 출력. (auto 든 manual 이든 label 이 있으면 우선.)
        if (override && override.label) {
          return override.label;
        }
        // 새로고침/PDF 생성 경로에서는 모드 전환 기반 자동 라벨 생성을 중단한다.
        //   (최초 렌더 경로에서는 flag 가 false 라 아래 기본 분기로 진입해 auto-gen 됨)
        if (disableAutoLabels) return null;
        if (!modeChanged) return null;
        if (qMode === 'objective') return '5지선다형';
        if (qMode === 'essay') return '서술형';
        return '단답형';
      });
      const defaultTopPt = titleHeader ? 16 : 9.2;
      const defaultPaddingTopPt = titleHeader ? 27 : 35.8;
      pageLabels.forEach((label, idx) => {
        const columnIndex = idx < pageLeftSlots ? 0 : 1;
        const rowIndex = idx < pageLeftSlots ? idx : (idx - pageLeftSlots);
        const anchorKey = `${columnIndex}:${rowIndex}`;
        const override = pageAnchorMap.get(anchorKey);
        if (override?.source === 'suppressed') {
          autoColumnLabelAnchors.push({
            page: pageNo,
            columnIndex,
            rowIndex,
            label: '',
            source: 'suppressed',
            topPt: defaultTopPt,
            paddingTopPt: defaultPaddingTopPt,
          });
          return;
        }
        if (!label) return;
        autoColumnLabelAnchors.push({
          page: pageNo,
          columnIndex,
          rowIndex,
          label,
          source: override?.source === 'manual' ? 'manual' : 'auto',
          topPt: defaultTopPt,
          paddingTopPt: defaultPaddingTopPt,
        });
      });
      parts.push(
        renderMockGridPageLatex(pages[i], {
          leftSlots: pageLeftSlots,
          rightSlots: pageRightSlots,
          showQuestionNumber: !hideQuestionNumber,
          isFirstPage: i === 0 && !titleHeader,
          stemSizePt: fontSize,
          includeQuestionScore,
          questionScoreByQuestionId,
          titleHeader,
          sectionLabels: pageLabels,
          pageMacroPrefix: toPageMacroPrefix(i),
        }),
      );
      parts.push('\n');
    }
    if (effectiveLayoutMeta) {
      effectiveLayoutMeta.columnLabelAnchors = autoColumnLabelAnchors;
    }
  } else {
    if (!hidePreviewHeader && (titlePageTopText || subjectTitle)) {
      parts.push('\\begin{center}');
      if (titlePageTopText) {
        parts.push(`{\\small ${escapeLatexText(titlePageTopText)}}\\\\[4pt]`);
      }
      parts.push(`{\\Large\\bfseries ${escapeLatexText(subjectTitle)}}`);
      parts.push('\\end{center}');
      parts.push('\\vspace{6pt}');
      parts.push('\\hrule\\vspace{8pt}\n');
    }

    if (columns >= 2) {
      parts.push(`\\begin{multicols}{${columns}}\n`);
    }

    const forcePagePerQuestion =
      parsePositiveInt(maxQuestionsPerPage, 0) === 1 && columns < 2;

    for (let i = 0; i < qList.length; i++) {
      if (i > 0) {
        if (forcePagePerQuestion) {
          parts.push('\\newpage\n');
        } else {
          parts.push('\\vspace{10pt}\n');
        }
      }

      const q = qList[i];
      let sectionLabel = null;
      const qMode = q?.mode
        || q?.questionMode
        || q?.export_mode
        || q?.exportMode
        || 'objective';

      if (isMock) {
        if (qMode !== lastMode) {
          if (qMode === 'objective') sectionLabel = '5지선다형';
          else if (qMode === 'essay') sectionLabel = '서술형';
          else sectionLabel = '단답형';
          lastMode = qMode;
        }
      }

      parts.push(
        renderOneQuestion(q, {
          sectionLabel,
          showQuestionNumber: !hideQuestionNumber,
          mode: qMode,
          stemSizePt: fontSize,
          includeQuestionScore,
          questionScoreByQuestionId,
          layoutColumns: columns,
        }),
      );
      parts.push('\n');
    }

    if (columns >= 2) {
      parts.push('\\end{multicols}\n');
    }
  }

  // 빠른정답 표: 마지막 페이지 바닥에 '정답표' 를 삽입.
  if (includeQuickAnswer && qList.length > 0) {
    parts.push('\\clearpage');
    parts.push(renderQuickAnswerTableLatex(qList));
  }

  parts.push('\\end{document}\n');
  if (effectiveLayoutMeta && !Array.isArray(effectiveLayoutMeta.columnLabelAnchors)) {
    effectiveLayoutMeta.columnLabelAnchors = [];
  }
  return parts.join('\n');
}
