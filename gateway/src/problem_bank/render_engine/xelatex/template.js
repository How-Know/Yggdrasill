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

const PARAGRAPH_MARKER_RE = /\[문단\]/g;
const BOGI_MARKER_RE = /\[박스시작\]|\[박스끝\]/g;
// 세트형 문제에서 추출기가 주입하는 하위문항 경계 표식. 라인 하나를 단독으로 차지한다.
// 렌더러는 이 마커를 "소비" 하되 화면에는 표시하지 않고, 마커 사이에 수직 간격만 주입한다.
const SUBQ_MARKER_LINE_RE = /^\s*\[\s*소문항\s*\d+\s*\]\s*$/;
const FIGURE_MARKER_RE = /\[(?:그림|도형|도표)\]/g;

const BOX_START_RE = /\[박스시작\]/;
const BOX_END_RE = /\[박스끝\]/;
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

  // box{~~} (빈 박스) → 3:2 비율 직사각형 빈칸 네모.
  out = out.replace(/box\{~~\}/g, '\\mtemptybox{}');
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

  return out;
}

function smartTexLine(text, equations) {
  const clean = stripMarkers(text).trim();
  if (!clean) return '';

  const lookup = buildEquationLookup(equations);

  const subQMatch = clean.match(/^\((\d+)\)\s+/);
  let prefix = '';
  let body = clean;
  if (subQMatch) {
    prefix = `\\text{(${subQMatch[1]})}\\;`;
    body = clean.substring(subQMatch[0].length);
  }

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
    return `$\\displaystyle ${prefix}$${result}`;
  }
  return result;
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
  // 세트형 하위문항 (1), (2), ...
  const subQ = sub.match(/^\((\d+)\)\s+(.*)$/);
  if (subQ) {
    const labelTex = `(${subQ[1]})\\ `;
    const restTex = smartTexLine(subQ[2], equations);
    // \makebox[\wd0][l] 로 레이블 폭을 고정 → 1행/2행+ 좌측선 정확히 일치.
    return `{\\setbox0=\\hbox{${labelTex}}\\hangindent=\\wd0\\hangafter=1\\noindent\\makebox[\\wd0][l]{${labelTex}}${restTex}\\par}`;
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
      return `{\\setbox0=\\hbox{${labelTex}}\\hangindent=\\wd0\\hangafter=1\\noindent\\makebox[\\wd0][l]{${labelTex}}${restTex}\\par}`;
    }
  }
  return smartTexLine(sub, equations);
}

/* ------------------------------------------------------------------ */
/*  Box parsing: [박스시작]/[박스끝] segment detection                  */
/* ------------------------------------------------------------------ */

function parseStemSegments(stem) {
  const lines = stem.split('\n');
  const segments = [];
  let inBox = false;
  let boxLines = [];
  let textLines = [];

  function flushText() {
    if (textLines.length > 0) {
      segments.push({ type: 'text', lines: [...textLines] });
      textLines = [];
    }
  }

  function flushBox() {
    if (boxLines.length === 0) return;
    const hasTable = boxLines.some((l) => /^\[표행\]$/.test(l.trim()));
    if (hasTable) {
      segments.push({ type: 'table', lines: [...boxLines] });
    } else {
      const hasBogi = boxLines.some((l) => BOGI_RE.test(l));
      segments.push({ type: hasBogi ? 'bogi' : 'deco', lines: [...boxLines] });
    }
    boxLines = [];
  }

  for (const line of lines) {
    const hasStart = BOX_START_RE.test(line);
    const hasEnd = BOX_END_RE.test(line);

    if (hasStart && !inBox) {
      flushText();
      inBox = true;
      const cleaned = line.replace(/\[박스시작\]/g, '').trim();
      if (cleaned) boxLines.push(cleaned);

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
      if (cleaned) boxLines.push(cleaned);
      inBox = false;
      flushBox();
      continue;
    }

    if (inBox) {
      boxLines.push(line);
    } else {
      textLines.push(line);
    }
  }

  if (inBox && boxLines.length > 0) {
    const hasTable = boxLines.some((l) => /^\[표행\]$/.test(l.trim()));
    if (hasTable) {
      segments.push({ type: 'table', lines: [...boxLines] });
    } else {
      const hasBogi = boxLines.some((l) => BOGI_RE.test(l));
      segments.push({ type: hasBogi ? 'bogi' : 'deco', lines: [...boxLines] });
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
  return segments;
}

/* ------------------------------------------------------------------ */
/*  Box rendering: tcolorbox environments                              */
/* ------------------------------------------------------------------ */

function renderBogiItems(lines, equations, replaceFigureMarkers = null) {
  const cleaned = lines
    .map((l) => l.replace(BOGI_RE, '').trim())
    .filter((l) => l);
  const joined = cleaned.join(' ');
  const items = joined.split(BOGI_ITEM_SPLIT_RE).filter((s) => s.trim());

  const rendered = [];
  for (const item of items) {
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
  const content = renderBogiItems(lines, equations, replaceFigureMarkers);
  return [
    '\\begin{tcolorbox}[',
    '  enhanced,',
    '  width=\\dimexpr\\linewidth-1em\\relax,',
    '  colback=white, colframe=black, boxrule=0.4pt,',
    '  arc=0pt, outer arc=0pt,',
    '  before skip=0pt, after skip=0pt,',
    '  attach boxed title to top center={yshift=-\\tcboxedtitleheight/2},',
    '  boxed title style={',
    '    sharp corners, colback=white, colframe=white, boxrule=0pt,',
    '    left=0pt, right=0pt, top=0pt, bottom=0pt,',
    '  },',
    '  title={\\normalfont\\normalsize 〈보\\enspace\\enspace기〉},',
    '  coltitle=black,',
    // 내부 위/아래 여백을 12pt 로 확대 → 항목과 박스 선의 숨통 확보.
    '  left=8pt, right=8pt, top=12pt, bottom=12pt',
    ']',
    '\\setlength{\\parskip}{0pt}',
    '\\lineskiplimit=5pt\\lineskip=1.2em',
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

function renderDecoBoxLatex(lines, equations, replaceFigureMarkers = null) {
  const contentParts = [];
  for (const l of lines) {
    const trimmed = l.trim();
    if (!trimmed) {
      contentParts.push('\\par');
      continue;
    }
    const subLines = trimmed.split(PARAGRAPH_MARKER_RE);
    for (let i = 0; i < subLines.length; i++) {
      if (i > 0) contentParts.push('\\par');
      const sub = subLines[i].trim();
      if (sub) {
        const rendered = renderDecoLine(sub, equations, replaceFigureMarkers);
        if (rendered.trim()) contentParts.push(rendered);
      }
    }
  }
  return [
    '\\begin{tcolorbox}[',
    '  enhanced,',
    '  width=\\dimexpr\\linewidth-1em\\relax,',
    '  colback=white, colframe=black, boxrule=0.4pt,',
    // 내부 위/아래 여백을 12pt 로 확대.
    '  arc=0pt, left=8pt, right=8pt, top=12pt, bottom=12pt,',
    '  before skip=0pt, after skip=0pt',
    ']',
    '\\setlength{\\parskip}{0pt}',
    '\\lineskiplimit=3pt\\lineskip=0.86em',
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

function renderTableLatex(lines, equations) {
  const rows = parseTableLines(lines);
  if (rows.length === 0) return '';
  const maxCols = Math.max(...rows.map((r) => r.length));
  if (maxCols === 0) return '';

  // 각 셀을 고정 높이 \parbox[c][h][c]{w}{\centering ...} 로 감싸 세로/가로 모두
  // 정확히 중앙에 배치한다. column type 은 c (baseline 정렬) — parbox[c] 가 세로 중심을 baseline 에 맞춘다.
  const colSpec = '|' + Array(maxCols).fill('c|').join('');

  const latexRows = rows.map((row) => {
    const cells = [];
    for (let i = 0; i < maxCols; i++) {
      const cellLines = row[i] || [''];
      const content = cellLines.length > 0
        ? cellLines.map((l) => smartTexLine(l, equations)).join(' ')
        : '';
      // \vphantom{X\textsuperscript{2}} 로 모든 셀이 동일한 상한/하한을 갖도록 고정 →
      // 위첨자/일반 문자 셀 간 세로 위치가 완전히 일치.
      cells.push(
        `\\parbox[c][\\tblcellht][c]{\\tblcellwd}{\\centering\\vphantom{X\\textsuperscript{2}g}${content}\\vphantom{X\\textsuperscript{2}g}}`,
      );
    }
    return cells.join(' & ') + ' \\\\';
  });

  const tableWidthFrac = maxCols <= 3 ? 0.5 : maxCols <= 5 ? 0.7 : 0.9;

  return [
    `\\setlength{\\tblcellwd}{\\dimexpr ${tableWidthFrac}\\linewidth/${maxCols} - 2\\tabcolsep - 1.2pt\\relax}`,
    // 모든 셀의 높이를 2.2em 으로 고정 → \parbox 의 [c] 옵션이 내용을 세로 중앙에 배치.
    '\\setlength{\\tblcellht}{2.2em}',
    '\\par\\noindent{\\hfill\\renewcommand{\\arraystretch}{1}%',
    '\\begin{tabular}{' + colSpec + '}',
    '\\hline',
    latexRows.join('\n\\hline\n'),
    '\\hline',
    '\\end{tabular}\\hfill\\null}\\par',
  ].join('\n');
}

/* ------------------------------------------------------------------ */
/*  Choices                                                            */
/* ------------------------------------------------------------------ */

const CIRCLED_DIGITS = ['①', '②', '③', '④', '⑤', '⑥', '⑦', '⑧', '⑨', '⑩'];

function visualLength(text) {
  const clean = stripMarkers(text).trim();
  let len = 0;
  for (const ch of clean) {
    const code = ch.codePointAt(0);
    if (code >= 0xAC00 && code <= 0xD7AF) len += 2;
    else if (code >= 0x3130 && code <= 0x318F) len += 2;
    else if (code > 0x7F) len += 1.5;
    else len += 0.6;
  }
  return Math.round(len);
}

function chooseChoiceLayout(choices) {
  if (choices.length !== 5) return 'stack';
  const lengths = choices.map((c) => {
    const text = typeof c === 'string' ? c : c?.text || c?.label || '';
    return visualLength(text);
  });
  const maxLen = Math.max(...lengths);
  const totalLen = lengths.reduce((a, b) => a + b, 0);
  if (maxLen > 25) return 'stack';
  if (totalLen > 65) return 'stack';
  if (maxLen > 16 || totalLen > 50) return 'row2';
  if (maxLen > 8 || totalLen > 30) return 'row2';
  return 'row1';
}

function renderChoicesLatex(choices, equations) {
  if (!Array.isArray(choices) || choices.length === 0) return '';

  const layout = chooseChoiceLayout(choices);

  const renderItem = (c, idx) => {
    const text = typeof c === 'string' ? c : c?.text || c?.label || '';
    const label = CIRCLED_DIGITS[idx] || String(idx + 1);
    const content = smartTexLine(text, equations);
    return `${label}\\enspace ${content}`;
  };

  // 본문(setstretch 1.7) 과 동일 줄 간격을 사용해 분수/위첨자 포함 줄의
  // 베이스라인 간격이 두 영역에서 동일하게 맞추도록 한다.
  const CHOICE_STRETCH = '\\setstretch{1.7}\\parskip=0pt\\lineskiplimit=5pt\\lineskip=1.2em';

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
  // 좌/우 여백은 사용자 요청으로 30% 축소 (20mm * 0.7 = 14mm). 상/하 여백은 20mm 유지.
  //   - hmargin : 좌우 공통, vmargin : 상하 공통.
  if (p === 'A4') return 'a4paper,hmargin=14mm,vmargin=20mm';
  if (p === 'A3') return 'a3paper,hmargin=14mm,vmargin=20mm';
  return 'b4paper,hmargin=14mm,vmargin=20mm';
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
  const isMock = profile === 'mock' || profile === 'csat';

  const lines = [];
  lines.push(`\\documentclass[${size}pt]{article}`);
  lines.push(`\\usepackage[${geom}]{geometry}`);
  lines.push('\\usepackage{fontspec}');
  lines.push('\\usepackage{amsmath,amssymb}');
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
  lines.push('\\usepackage{enumitem}');
  lines.push('\\usepackage{multicol}');
  lines.push('\\newlength{\\tblcellwd}');
  lines.push('\\newlength{\\tblcellht}');
  // \mtemptybox : 가로:세로 = 3:2 비율의 빈칸 네모 (math/text 모두 안전).
  // 한글 글자 전체 높이(ascender+descender 포함)와 시각적으로 동일하도록 1.05em × 1.575em 으로 설정.
  // (한글 글리프 실제 높이가 약 1.0~1.05em 수준이라 0.9em 이면 작아 보임)
  // \ensuremath + \vcenter 로 수식축(math axis) 에 중앙이 오도록 → 인접 글자와 시각적 정렬.
  lines.push('\\newcommand{\\mtemptybox}{\\ensuremath{\\vcenter{\\hbox{\\setlength{\\fboxsep}{0pt}\\framebox[1.575em][c]{\\rule{0pt}{1.05em}}}}}}');
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
  lines.push('');

  // 학원 로고를 사용할 경우 \includegraphics 에 넘길 정규화된 경로.
  const logoEnabled = includeAcademyLogo && academyLogoPath;
  const logoPathTex = logoEnabled ? String(academyLogoPath).replace(/\\/g, '/') : '';
  // 오른쪽 헤더에 삽입할 로고 이미지 — height=1.4em 로 본문 줄 높이보다 살짝 큼.
  const logoHeadGraphic = logoEnabled
    ? `\\raisebox{-0.2em}{\\includegraphics[height=1.4em,keepaspectratio]{${logoPathTex}}}`
    : '';

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
    //     - fancyhdr 는 '헤더 텍스트' (좌: 과목명, 우: 페이지번호/로고) 만 담당.
    lines.push('\\pagestyle{fancy}');
    lines.push('\\fancyhf{}');
    lines.push(`\\fancyhead[L]{\\small ${escapeLatexText(subjectTitle)}}`);
    if (logoEnabled) {
      lines.push(`\\fancyhead[R]{${logoHeadGraphic}}`);
    } else {
      lines.push('\\fancyhead[R]{\\small \\thepage}');
    }
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

  // 모의고사 '제목 페이지' 전용 스타일: 기본 fancy header 를 끄고, 본문 위에 직접
  // 큰 타이틀 헤더를 그린다. (header rule / pagebox 는 shipout overlay 가 담당.)
  if (isMock) {
    lines.push('\\fancypagestyle{mocktitle}{%');
    lines.push('  \\fancyhf{}%');
    lines.push('  \\renewcommand{\\headrulewidth}{0pt}%');
    lines.push('  \\renewcommand{\\footrulewidth}{0pt}%');
    lines.push('  \\fancyfoot{}%');
    lines.push('}');
  }

  lines.push('');
  lines.push('\\setstretch{1.7}');
  lines.push('\\lineskiplimit=5pt');
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
    lines.push('\\AtBeginDocument{%');
    lines.push('  \\ifdim\\paperheight>\\paperwidth%');
    lines.push('    \\setlength{\\mockPageBoxW}{\\dimexpr0.04\\paperheight\\relax}%');
    lines.push('  \\else%');
    lines.push('    \\setlength{\\mockPageBoxW}{\\dimexpr0.04\\paperwidth\\relax}%');
    lines.push('  \\fi%');
    lines.push('  \\setlength{\\mockPageBoxH}{\\dimexpr0.5\\mockPageBoxW\\relax}%');
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
    lines.push('  \\setlength{\\mockLayVRuleStartY}{\\mockLayTopY}%');
    lines.push('  \\addtolength{\\mockLayVRuleStartY}{-\\mockHeaderBoxHeight}%');
    lines.push('  \\addtolength{\\mockLayVRuleStartY}{-28pt}%');

    lines.push('  \\begin{tikzpicture}[remember picture,overlay]%');
    // 상단 header rule 과 세로 단구분선이 '한 점' 에서 만나도록 공유 y 좌표 사용.
    //   \mockLayRuleY = \mockLayTopY + 3pt (본문 상단선보다 3pt 위, 일반 페이지용).
    lines.push('    \\pgfmathsetlengthmacro{\\mockLayRuleY}{\\mockLayTopY+3pt}%');
    // 상단 header rule + 세로 단구분선.
    //   - 일반 페이지  : 가로선 y = \mockLayRuleY        / 세로선 시작 y = \mockLayRuleY.
    //   - 제목페이지   : 가로선 y = \mockLayVRuleStartY  / 세로선 시작 y = \mockLayVRuleStartY.
    //                   → 제목페이지에선 가로선도 헤더 아래로 내려 세로선 상단과 정확히 교차.
    lines.push('    \\ifmocktitlepage%');
    // 제목페이지: 가로선 (헤더 아래로 내림).
    lines.push('      \\draw[line width=0.4pt]%');
    lines.push('        ([shift={(\\mockLayLeftX,\\mockLayVRuleStartY)}]current page.north west) --%');
    lines.push('        ([shift={(\\mockLayRightX,\\mockLayVRuleStartY)}]current page.north west);%');
    // 제목페이지: 세로선 (헤더 아래 ~ 본문 하단).
    lines.push('      \\draw[line width=0.4pt]%');
    lines.push('        ([shift={(\\mockLayCenterX,\\mockLayVRuleStartY)}]current page.north west) --%');
    lines.push('        ([shift={(\\mockLayCenterX,\\mockLayBotY)}]current page.north west);%');
    lines.push('    \\else%');
    // 일반 페이지: 가로선 (본문 상단보다 3pt 위).
    lines.push('      \\draw[line width=0.4pt]%');
    lines.push('        ([shift={(\\mockLayLeftX,\\mockLayRuleY)}]current page.north west) --%');
    lines.push('        ([shift={(\\mockLayRightX,\\mockLayRuleY)}]current page.north west);%');
    // 일반 페이지: 세로선 (가로선 y ~ 본문 하단).
    lines.push('      \\draw[line width=0.4pt]%');
    lines.push('        ([shift={(\\mockLayCenterX,\\mockLayRuleY)}]current page.north west) --%');
    lines.push('        ([shift={(\\mockLayCenterX,\\mockLayBotY)}]current page.north west);%');
    lines.push('    \\fi%');
    // 페이지박스 (scope 원점 = 박스 좌하단).
    lines.push('    \\begin{scope}[shift={([shift={(\\mockLayBoxX,\\mockLayBoxY)}]current page.north west)}]%');
    lines.push('      \\draw[line width=0.4pt] (0,0) rectangle (\\mockPageBoxW,\\mockPageBoxH);%');
    lines.push('      \\draw[line width=0.4pt] (0,0) -- (\\mockPageBoxW,\\mockPageBoxH);%');
    lines.push('      \\pgfmathsetlengthmacro{\\mockPageBoxFont}{0.46*\\mockPageBoxH}%');
    lines.push('      \\pgfmathsetlengthmacro{\\mockPageBoxLead}{0.55*\\mockPageBoxH}%');
    lines.push('      \\node[anchor=center, inner sep=0pt] at (0.18\\mockPageBoxW,0.65\\mockPageBoxH)%');
    lines.push('        {\\fontsize{\\mockPageBoxFont}{\\mockPageBoxLead}\\selectfont\\thepage};%');
    lines.push('      \\node[anchor=center, inner sep=0pt] at (0.82\\mockPageBoxW,0.35\\mockPageBoxH)%');
    lines.push('        {\\fontsize{\\mockPageBoxFont}{\\mockPageBoxLead}\\selectfont\\pageref{LastPage}};%');
    lines.push('    \\end{scope}%');
    lines.push('  \\end{tikzpicture}%');
    lines.push('}');
  }
  lines.push('\\newlength{\\mockColumnHeight}');
  lines.push('\\newlength{\\mockSlotGap}');
  lines.push('\\newlength{\\mockLeftSlotHeight}');
  lines.push('\\newlength{\\mockRightSlotHeight}');
  // 제목 페이지 상단 헤더(타이틀/부제/hrule) 를 담는 box. 헤더 높이를 측정해
  // 본문 가용 높이(\mockColumnHeight) 계산 시 차감하는 용도.
  lines.push('\\newsavebox{\\mockHeaderBox}');
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

function renderOneQuestion(question, {
  sectionLabel,
  showQuestionNumber = true,
  mode,
  stemSizePt = 11,
  includeQuestionScore = false,
  questionScoreByQuestionId = null,
} = {}) {
  const qNum = question?.question_number || question?.questionNumber || '';
  const stem = question?.stem || '';
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
  const layoutByAssetKey = new Map();
  for (const it of layoutItems) {
    if (it?.assetKey) layoutByAssetKey.set(String(it.assetKey), it);
  }
  let figIdx = 0;

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

  function renderFigureLatex(i) {
    const p = figurePaths[i];
    if (!p) return '';
    const normalized = String(p).replace(/\\/g, '/');
    const layout = layoutForIndex(i) || {};
    // widthEm은 figure_layout.js에서 clamp(2..50)로 정규화되어 저장됨.
    // em 단위는 tcolorbox 안/밖 모두 현재 폰트 크기 기준으로 안정적.
    const widthEmRaw = Number.isFinite(layout.widthEm) ? Number(layout.widthEm) : 20;
    const widthEm = Math.max(2, Math.min(50, widthEmRaw));
    const anchor = String(layout.anchor || 'center').toLowerCase();
    const offsetX = Number.isFinite(layout.offsetXEm) ? Number(layout.offsetXEm) : 0;
    const offsetY = Number.isFinite(layout.offsetYEm) ? Number(layout.offsetYEm) : 0;

    // graphicx 기본 키만 사용한다. (adjustbox의 'max width'는 프리앰블에 없어 keyval 오류가 난다.)
    // widthEm은 figure_layout 에서 2..50 으로 clamp 되며 사용자가 저장한 값이므로 그대로 신뢰한다.
    const widthExpr = `${widthEm.toFixed(2)}em`;
    const img = `\\includegraphics[width=${widthExpr}]{${normalized}}`;

    const hOffset = Math.abs(offsetX) > 1e-3 ? `\\hspace*{${offsetX.toFixed(2)}em}` : '';
    const vOffsetPre = offsetY > 1e-3 ? `\\vspace*{${offsetY.toFixed(2)}em}` : '';
    const vOffsetPost = offsetY < -1e-3 ? `\\vspace*{${offsetY.toFixed(2)}em}` : '';

    let body;
    if (anchor === 'left') {
      body = `\\par\\noindent ${hOffset}${img}\\par`;
    } else if (anchor === 'right') {
      body = `\\par\\noindent\\hfill${img}${hOffset}\\par`;
    } else {
      // center / top: 수평 중앙 정렬. offsetX는 중앙 기준 좌우 밀림.
      // \begin{center} 대신 \hfill 조합: trivlist의 \topsep+\partopsep 간격 제거.
      body = `\\par\\noindent{\\hfill${hOffset}${img}\\hfill\\null}\\par`;
    }
    const pre = vOffsetPre ? `\n${vOffsetPre}` : '';
    const post = vOffsetPost ? `\n${vOffsetPost}` : '';
    return `${pre}\n${body}${post}\n`;
  }

  function replaceFigureMarkers(text) {
    return text.replace(FIGURE_MARKER_RE, () => {
      const i = figIdx++;
      return renderFigureLatex(i);
    });
  }

  const parts = [];

  // sectionLabel box will be implemented later with the labeling feature

  parts.push('\\begingroup');
  // minipage/multicols 내부에서도 자간이 늘어나지 않도록 raggedright 의 파라미터를 명시.
  parts.push('\\rightskip=0pt plus 1fil\\relax');
  parts.push('\\parfillskip=0pt plus 1fil\\relax');
  parts.push('\\parindent=0pt');
  parts.push('\\tolerance=9999\\emergencystretch=0pt');
  parts.push(showQuestionNumber ? '\\leftskip=1em' : '\\leftskip=0pt');

  if (showQuestionNumber && qNum) {
    parts.push(
      `\\noindent\\hspace{-1em}\\textbf{${escapeLatexText(String(qNum))}.}\\enspace`,
    );
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

  const segments = parseStemSegments(stem);

  // 콘텐츠 블록 전환 간격.
  // - BLOCK_GAP (6pt): 표 ↔ text, 그리고 5지선다 앞.
  // - TOP_BIG_GAP (그림/보기/조건제시박스 "위"): "줄과 줄 사이 간격"의 180%.
  //     한글 본문은 \setstretch{1.7} 이므로 한 줄 공간 안에서 "실제 여백(leading)"은 약 0.7\baselineskip.
  //     그 180% ≈ 1.26\baselineskip — 그러나 시각적으로 과도하므로 0.75\baselineskip (=여백만의 약 110%)
  //     정도에서 잘라 박스 전/후 여백이 본문 한 줄 분 정도가 되도록 설정.
  // - BOTTOM_BIG_GAP (9pt): 그림/보기/조건제시박스 "아래" (기존 유지).
  // \par 를 앞에 두어 현재 paragraph 를 강제 종료 → vspace 가 vertical mode 에서 동작.
  const BLOCK_GAP = '\\par\\vspace{6pt}';
  const TOP_BIG_GAP = '\\par\\vspace{0.75\\baselineskip}';
  const BOTTOM_BIG_GAP = '\\par\\vspace{9pt}';
  // 표도 보기/조건제시/그림과 동일한 "블록" 으로 간주 → 위쪽은 TOP_BIG_GAP, 아래는 BOTTOM_BIG_GAP.
  const isBigBlockType = (t) => t === 'bogi' || t === 'deco' || t === 'figure' || t === 'table';

  for (let sIdx = 0; sIdx < segments.length; sIdx++) {
    const seg = segments[sIdx];
    const prev = segments[sIdx - 1];
    const needsGap = prev && (prev.type !== 'text' || seg.type !== 'text');
    if (needsGap) {
      if (isBigBlockType(seg.type)) {
        // 박스/그림이 "지금" 시작됨 → 그 "위" 에 180% 간격.
        parts.push(TOP_BIG_GAP);
      } else if (isBigBlockType(prev.type)) {
        // 박스/그림 바로 "다음" → "아래" 간격 (기존 9pt).
        parts.push(BOTTOM_BIG_GAP);
      } else {
        parts.push(BLOCK_GAP);
      }
    }

    if (seg.type === 'text') {
      // 세트형 [소문항N] 마커가 stem 에 이미 경계를 잡아놓은 경우에는
      // 문장 중간 "(N)" splitAtSubQuestionMarkers 중복 분할을 스킵 → 본문 인용 오분할 방지.
      const hasSubQMarker = seg.lines.some((l) => SUBQ_MARKER_LINE_RE.test(String(l)));
      let subQEmittedAny = false;
      // rawLine 간 누적된 "빈 줄 + 단독 [문단] 라인" 수. 다음 실제 콘텐츠/마커 앞에 수직 간격으로 반영.
      let outerPendingEmpty = 0;
      for (const rawLine of seg.lines) {
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
            if (/\\includegraphics/.test(piece)) {
              parts.push(piece);
            } else {
              const rendered = renderStemTextLine(piece, equations);
              if (rendered.trim()) {
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
      parts.push(renderTableLatex(seg.lines, equations));
    }
  }

  let trailingIsBig = segments.length > 0 && isBigBlockType(segments[segments.length - 1].type);
  if (figurePaths.length > figIdx) {
    for (let i = figIdx; i < figurePaths.length; i++) {
      const rendered = renderFigureLatex(i);
      if (rendered.trim()) {
        // 그림 "위" 간격: 180% (= TOP_BIG_GAP).
        parts.push(TOP_BIG_GAP);
        parts.push(rendered);
        trailingIsBig = true;
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
      parts[partIdx] = `${cur}\\ {\\small [${escapeLatexText(scoreText)}점]}`;
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
    // 5지선다 바로 위 블록이 그림/보기/조건제시박스면 박스 "아래" 간격을 적용.
    parts.push(trailingIsBig ? BOTTOM_BIG_GAP : BLOCK_GAP);
    parts.push(renderChoicesLatex(choices, equations));
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
    '\\usepackage{enumitem}',
    '\\usepackage{setspace}',
    '\\usepackage[most]{tcolorbox}',
    '\\newlength{\\tblcellwd}',
    '\\newlength{\\tblcellht}',
    '\\newcommand{\\mtemptybox}{\\ensuremath{\\vcenter{\\hbox{\\setlength{\\fboxsep}{0pt}\\framebox[1.35em][c]{\\rule{0pt}{0.9em}}}}}}',
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
    '\\lineskiplimit=5pt',
    '\\lineskip=1.2em',
    '\\spaceskip=1.2\\fontdimen2\\font plus 1.2\\fontdimen3\\font minus 1.2\\fontdimen4\\font',
    '\\setlength{\\parindent}{0pt}',
    '\\setlength{\\parskip}{0.4em}',
    '',
    '\\begin{document}',
    '\\raggedright',
    '\\lineskiplimit=5pt\\lineskip=1.2em',
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
  } = {},
) {
  const lines = [];
  const safeSlots = Math.max(1, Number(slotCount || 1));
  const qList = Array.isArray(columnQuestions) ? columnQuestions : [];

  for (let i = 0; i < safeSlots; i += 1) {
    lines.push(`\\begin{minipage}[t][${slotHeightMacro}][t]{\\linewidth}`);
    const question = qList[i];
    if (question) {
      lines.push(renderOneQuestion(question, {
        showQuestionNumber,
        stemSizePt,
        includeQuestionScore,
        questionScoreByQuestionId,
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
    inner.push(
      `{\\fontsize{\\the\\mockTitleTopFontSize}{\\the\\mockTitleTopLead}\\selectfont ${escapeLatexText(titleTop)}}\\par\\vspace{6pt}`,
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
  },
) {
  const safeLeftSlots = Math.max(1, Number(leftSlots || 1));
  const safeRightSlots = Math.max(1, Number(rightSlots || 1));
  const list = Array.isArray(pageQuestions) ? pageQuestions : [];
  const leftQuestions = list.slice(0, safeLeftSlots);
  const rightQuestions = list.slice(safeLeftSlots, safeLeftSlots + safeRightSlots);
  const leftGapExpr = safeLeftSlots > 1 ? `${safeLeftSlots - 1}\\mockSlotGap` : '0pt';
  const rightGapExpr = safeRightSlots > 1 ? `${safeRightSlots - 1}\\mockSlotGap` : '0pt';

  // 공통 좌/우 minipage 내용을 함수로 분리.
  //
  // 컬럼 폭 & 구분선 주변 여백:
  //   - 좌/우 minipage 각 0.4775\linewidth → 합계 0.955\linewidth.
  //   - 남은 0.045\linewidth 가 \hfill 2개 에 균등 분배(페이지 중앙 기준 대칭).
  //   - 세로 단구분선(vrule) 은 이 minipage 사이에 '흐름 기반' 으로 두지 않고,
  //     페이지 중앙 x = \paperwidth/2 에 shipout overlay 로 절대 배치한다.
  //     (페이지별 콘텐츠 양과 무관하게 항상 동일 좌표에 그려지도록.)
  const MOCK_MINIPAGE_WIDTH = '0.4775\\linewidth';
  const buildColumnsBlock = (heightMacro, leftHeightMacro, rightHeightMacro) => [
    '\\noindent',
    `\\begin{minipage}[t][${heightMacro}][t]{${MOCK_MINIPAGE_WIDTH}}`,
    renderMockSlotColumnBody(leftQuestions, safeLeftSlots, leftHeightMacro, {
      showQuestionNumber,
      stemSizePt,
      includeQuestionScore,
      questionScoreByQuestionId,
    }),
    '\\end{minipage}',
    '\\hfill',
    `\\begin{minipage}[t][${heightMacro}][t]{${MOCK_MINIPAGE_WIDTH}}`,
    renderMockSlotColumnBody(rightQuestions, safeRightSlots, rightHeightMacro, {
      showQuestionNumber,
      stemSizePt,
      includeQuestionScore,
      questionScoreByQuestionId,
    }),
    '\\end{minipage}',
  ].join('\n');

  // --- 제목 페이지 경로: outer minipage(\linewidth × \textheight) 안에 헤더 + 좌/우 minipage. ---
  // outer minipage 는 자기 높이가 고정이므로 중간에 페이지 breaker 가 끼어들지 않는다.
  // 좌/우 minipage 높이는 outer 안에서 남은 공간(= \textheight - 헤더 박스 \ht+\dp - 여유) 로 계산.
  if (titleHeader) {
    const headerBlock = renderMockTitlePageHeader(titleHeader);
    // 제목페이지 슬롯을 일반 페이지 대비 '20pt 더 내림'. 헤더 아래 추가 여백 = 28pt (= 8pt + 20pt).
    // 세로선은 헤더 박스 아래, 슬롯 첫 줄 시작 지점과 동일한 y 에서 시작.
    return [
      '\\begingroup',
      // 제목페이지 플래그는 buildDocumentTexSource 의 페이지 루프에서
      //   \AtBeginShipoutNext{\global\mocktitlepagetrue} 로 shipout 타이밍에 세팅.
      //   (여기서 \global 으로 세팅하면 output routine 지연으로 인접 페이지에 새 나갈 수 있음.)
      '\\setlength{\\mockSlotGap}{8pt}',
      '\\noindent\\begin{minipage}[t][\\textheight][t]{\\linewidth}',
      // 헤더 박스 생성 & 출력. renderMockTitlePageHeader 내부의 \setbox 는 로컬이므로
      //   overlay 가 \ht/\dp 를 읽을 땐 이미 스코프가 종료되어 값이 롤백될 수 있다.
      //   → 출력 직후 '전역 dimen' \mockHeaderBoxHeight 로 복사해둔다.
      headerBlock,
      '\\global\\setlength{\\mockHeaderBoxHeight}{\\ht\\mockHeaderBox}%',
      '\\global\\advance\\mockHeaderBoxHeight by \\dp\\mockHeaderBox%',
      // 주의: \mockLayVRuleStartY 는 여기서 계산하면 안 된다.
      //   \mockLayTopY 는 \AddToShipoutPictureFG 의 overlay 본문에서 shipout 시점에
      //   세팅되므로, 페이지 콘텐츠 안에서는 아직 0pt → 부정확한 값이 저장됨.
      //   → overlay 내부에서 \mockLayTopY 세팅 직후 \mockHeaderBoxHeight 를 사용해
      //     \mockLayVRuleStartY 를 계산하도록 위임.
      // 본문 시작 전 추가 수직 공백 — 슬롯 시작 y 를 세로선 시작 y 와 일치시켜
      //   세로선이 타이틀을 뚫고 지나가지 않도록. (headerBlock 끝의 \vspace{8pt} 와 합쳐 28pt.)
      '\\vspace*{20pt}',
      // 남은 컬럼 높이 = \textheight - (헤더 높이 + 28pt 여백).
      '\\setlength{\\mockColumnHeight}{\\dimexpr\\textheight-\\mockHeaderBoxHeight-28pt\\relax}',
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
    return s.replace(/\b(TIMES|DIV|PM|LEQ|GEQ|NEQ)\b/g, (m) => SPECIAL_TOKEN_MAP[m] || m);
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
    for (const ch of Array.from(raw)) {
      const cjk = isCJKCh(ch);
      if (curCJK === null) {
        curCJK = cjk;
        buf = ch;
      } else if (curCJK === cjk) {
        buf += ch;
      } else {
        flush();
        curCJK = cjk;
        buf = ch;
      }
    }
    flush();
    if (!chunks.some((c) => c.cjk)) return `$${raw}$`;
    const parts = chunks.map((c) => (c.cjk ? `\\text{${escapeLatexText(c.text)}}` : c.text));
    return `$${parts.join('')}$`;
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
      // 라벨 바로 뒤의 공백은 소비, 이후 텍스트만 남겨 세그먼트로 포매팅.
      const segment = raw.slice(end, nextIdx).replace(/^\s+/, '').replace(/\s+$/, '');
      // 라벨 앞 공백: 첫 라벨은 없음, 이후 라벨은 두 칸(\ \ ).
      if (i > 0) out.push('\\ \\ ');
      out.push(label); // '(1)', '(2)' 는 text 모드 그대로.
      out.push('\\ '); // 라벨 뒤 한 칸.
      if (segment) out.push(formatAnswerSegment(segment));
    }
    return out.join('');
  }

  function formatAnswerTex(ans) {
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
        cells.push(formatAnswerTex(resolveAnswer(q)));
      } else {
        cells.push('');
        cells.push('');
      }
    }
    rows.push(cells.join(' & ') + ' \\\\');
  }

  return [
    '\\clearpage',
    '\\thispagestyle{plain}',
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
  } = options;

  const logoEnabled = includeAcademyLogo && !!academyLogoPath;

  const preamble = buildPreamble({
    paper, fontFamily, fontBold, fontRegularPath, fontSize,
    subjectTitle, profile,
    hidePreviewHeader,
    geometryOverride,
    includeAcademyLogo: logoEnabled,
    academyLogoPath,
  });

  const parts = [preamble];
  parts.push('\\begin{document}');
  parts.push('\\raggedright');
  parts.push('\\lineskiplimit=5pt\\lineskip=1.2em\n');

  const qList = Array.isArray(questions) ? questions : [];
  const isMock = profile === 'mock' || profile === 'csat';
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
        });
      }
    }
    const buildTitleHeaderForPage = (pageNo) => {
      if (!titlePageSet.has(pageNo)) return null;
      const override = titlePageHeaderMap.get(pageNo) || {};
      const title = override.title || subjectTitle || '';
      const subtitle = override.subtitle || '';
      const titleTop = pageNo === 1 ? (titlePageTopText || '') : '';
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

    for (let i = 0; i < pages.length; i += 1) {
      const pageNo = i + 1;
      const titleHeader = hidePreviewHeader ? null : buildTitleHeaderForPage(pageNo);
      if (i > 0) parts.push('\\newpage\n');
      // 페이지 진입 시 제목페이지 플래그 명시 설정 — shipout overlay 가 세로선
      //   시작 y 를 결정하는 근거. renderMockGridPageLatex 내부에서 true 를 set 하지만
      //   '일반 페이지' 에선 명시적으로 false 로 리셋해야 직전 제목페이지 상태가
      //   이월되지 않는다.
      if (titleHeader) {
        parts.push('\\thispagestyle{mocktitle}');
        // 이 페이지(ship out 직전)에만 제목페이지 플래그 ON.
        //   \AtBeginShipoutNext 는 '다음 1회의 shipout 직전' 실행되므로
        //   \AddToShipoutPictureFG 의 \ifmocktitlepage 분기를 이 페이지에서만 true 로.
        parts.push('\\AtBeginShipoutNext{\\global\\mocktitlepagetrue}');
      } else {
        // 일반 페이지: 혹시 직전 타이틀 페이지에서 true 였다면 이 페이지 shipout 전에 false.
        parts.push('\\AtBeginShipoutNext{\\global\\mocktitlepagefalse}');
        if (i === 0 && logoEnabled && !includeCoverPage) {
          // 첫 페이지 로고 강조(mockfirst) — 표지가 없고 제목 페이지 헤더도 없을 때.
          parts.push('\\thispagestyle{mockfirst}');
        }
      }
      const ov = overrides[i];
      const pageLeftSlots = ov ? ov.left : leftSlots;
      const pageRightSlots = ov ? ov.right : rightSlots;
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
        }),
      );
      parts.push('\n');
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
  return parts.join('\n');
}
