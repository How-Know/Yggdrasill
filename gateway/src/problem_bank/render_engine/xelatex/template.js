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

const PARAGRAPH_MARKER_RE = /\[문단\]/g;
const BOGI_MARKER_RE = /\[박스시작\]|\[박스끝\]/g;

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
    if (raw !== latex && result.includes(raw)) {
      result = result.replaceAll(raw, latex);
    }
  }
  return result;
}

function normalizeMathSegment(mathContent) {
  let out = String(mathContent || '');

  out = out.replace(/\\left\s*\{/g, '\\left\\{');
  out = out.replace(/\\left\s*\}/g, '\\left\\}');
  out = out.replace(/\\right\s*\{/g, '\\right\\{');
  out = out.replace(/\\right\s*\}/g, '\\right\\}');

  out = out.replace(/\\left\s+([()\[\]|.])/g, '\\left$1');
  out = out.replace(/\\right\s+([()\[\]|.])/g, '\\right$1');

  out = out.replace(/\\left\s+\\([a-zA-Z]+)/g, '\\left\\\\$1');
  out = out.replace(/\\right\s+\\([a-zA-Z]+)/g, '\\right\\\\$1');

  return out;
}

function smartTexLine(text, equations) {
  const clean = stripMarkers(text).trim();
  if (!clean) return '';

  const lookup = buildEquationLookup(equations);

  const parts = [];
  let lastEnd = 0;

  for (const m of clean.matchAll(KOREAN_SEG_RE)) {
    if (m.index > lastEnd) {
      parts.push({ type: 'math', value: clean.substring(lastEnd, m.index) });
    }
    parts.push({ type: 'text', value: m[0] });
    lastEnd = m.index + m[0].length;
  }
  if (lastEnd < clean.length) {
    parts.push({ type: 'math', value: clean.substring(lastEnd) });
  }
  if (parts.length === 0) {
    parts.push({ type: 'math', value: clean });
  }

  return parts
    .map((seg) => {
      if (seg.type === 'text') return escapeLatexText(seg.value);

      let math = seg.value.trim();
      if (!math) return '';
      math = applyEquationLookup(math, lookup);
      math = normalizeMathSegment(math);
      return `$\\displaystyle ${math}$`;
    })
    .join('');
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
    const hasBogi = boxLines.some((l) => BOGI_RE.test(l));
    segments.push({ type: hasBogi ? 'bogi' : 'deco', lines: [...boxLines] });
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
    const hasBogi = boxLines.some((l) => BOGI_RE.test(l));
    segments.push({ type: hasBogi ? 'bogi' : 'deco', lines: [...boxLines] });
  }
  flushText();
  return segments;
}

/* ------------------------------------------------------------------ */
/*  Box rendering: tcolorbox environments                              */
/* ------------------------------------------------------------------ */

function renderBogiItems(lines, equations) {
  const cleaned = lines
    .map((l) => l.replace(BOGI_RE, '').trim())
    .filter((l) => l);
  const joined = cleaned.join(' ');
  const items = joined.split(BOGI_ITEM_SPLIT_RE).filter((s) => s.trim());

  const rendered = [];
  for (const item of items) {
    const match = item.match(BOGI_ITEM_RE);
    if (match) {
      const label = match[1] || match[2];
      const text = item.replace(BOGI_ITEM_RE, '').trim();
      const labelTex = label.match(/^[ㄱ-ㅎ]$/)
        ? `${label}.`
        : `(${label})`;
      rendered.push(
        `\\hangindent=2em\\hangafter=1\\noindent\\makebox[2em][l]{${escapeLatexText(labelTex)}}${smartTexLine(text, equations)}\\par`,
      );
    } else {
      const tex = smartTexLine(item.trim(), equations);
      if (tex.trim()) rendered.push(`\\noindent ${tex}\\par`);
    }
  }
  return rendered.join('\n');
}

function renderBogiBoxLatex(lines, equations) {
  const content = renderBogiItems(lines, equations);
  return [
    '\\begin{tcolorbox}[',
    '  colback=white, colframe=black, boxrule=0.4pt,',
    '  arc=0pt, outer arc=0pt,',
    '  title={\\hfill\\normalsize 보\\enspace\\enspace기\\hfill},',
    '  fonttitle=\\bfseries,',
    '  coltitle=black, colbacktitle=white,',
    '  attach boxed title to top center={yshift=-0.5\\baselineskip},',
    '  boxed title style={colback=white, colframe=white, boxrule=0pt},',
    '  left=8pt, right=8pt, top=6pt, bottom=4pt',
    ']',
    content,
    '\\end{tcolorbox}',
  ].join('\n');
}

function renderDecoBoxLatex(lines, equations) {
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
        const rendered = smartTexLine(sub, equations);
        if (rendered.trim()) contentParts.push(rendered);
      }
    }
  }
  return [
    '\\begin{tcolorbox}[',
    '  colback=white, colframe=black, boxrule=0.4pt,',
    '  arc=0pt, left=8pt, right=8pt, top=4pt, bottom=4pt',
    ']',
    contentParts.join('\n'),
    '\\end{tcolorbox}',
  ].join('\n');
}

/* ------------------------------------------------------------------ */
/*  Choices                                                            */
/* ------------------------------------------------------------------ */

function visualLength(text) {
  const clean = stripMarkers(text).trim();
  let len = 0;
  for (const ch of clean) {
    len += ch.codePointAt(0) > 0x7F ? 2 : 1;
  }
  return len;
}

function chooseChoiceLayout(choices) {
  if (choices.length !== 5) return 'stack';
  const lengths = choices.map((c) => {
    const text = typeof c === 'string' ? c : c?.text || c?.label || '';
    return visualLength(text);
  });
  const maxLen = Math.max(...lengths);
  const totalLen = lengths.reduce((a, b) => a + b, 0);
  if (maxLen > 22) return 'stack';
  if (totalLen > 55) return 'stack';
  if (maxLen > 12 || totalLen > 40) return 'row2';
  if (maxLen > 6 || totalLen > 25) return 'row2';
  return 'row1';
}

function renderChoicesLatex(choices, equations) {
  if (!Array.isArray(choices) || choices.length === 0) return '';

  const layout = chooseChoiceLayout(choices);

  const renderItem = (c, idx) => {
    const text = typeof c === 'string' ? c : c?.text || c?.label || '';
    const label = `\\textcircled{\\small ${idx + 1}}`;
    const content = smartTexLine(text, equations);
    return `${label}\\enspace ${content}`;
  };

  const CHOICE_STRETCH = '\\setstretch{1.4}';

  if (layout === 'row1') {
    const cells = choices.map((c, i) => renderItem(c, i));
    const w = '\\dimexpr0.2\\linewidth-0.2em\\relax';
    return [
      '{' + CHOICE_STRETCH,
      '\\noindent%',
      cells.map((cell) => `\\makebox[${w}][l]{${cell}}`).join('%\n'),
      '}',
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
      '\\par\\vspace{0.4em}\\noindent%',
      bot2 + '%',
      '}',
    ].join('\n');
  }

  const items = [];
  for (const c of choices) {
    const text = typeof c === 'string' ? c : c?.text || c?.label || '';
    items.push(`  \\item ${smartTexLine(text, equations)}`);
  }
  return [
    '{' + CHOICE_STRETCH,
    '\\begin{enumerate}[label=\\textcircled{\\small\\arabic*},itemsep=0pt,parsep=0pt,topsep=0pt,leftmargin=2em]',
    ...items,
    '\\end{enumerate}',
    '}',
  ].join('\n');
}

/* ------------------------------------------------------------------ */
/*  Page geometry & fonts                                              */
/* ------------------------------------------------------------------ */

function paperGeometry(paper) {
  const p = String(paper || 'B4').toUpperCase();
  if (p === 'A4') return 'a4paper,margin=20mm';
  if (p === 'A3') return 'a3paper,margin=20mm';
  return 'b4paper,margin=20mm';
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
}) {
  const geom = paperGeometry(paper);
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
  lines.push('\\usepackage{kotex}');
  lines.push('\\usepackage{graphicx}');
  lines.push('\\usepackage{xcolor}');
  lines.push('\\usepackage{enumitem}');
  lines.push('\\usepackage{multicol}');
  lines.push('\\usepackage{fancyhdr}');
  lines.push('\\usepackage{setspace}');
  lines.push('\\usepackage[most]{tcolorbox}');
  lines.push('');
  lines.push(mainDirective);
  lines.push(hangulDirective);
  lines.push('');

  if (isMock && subjectTitle) {
    lines.push('\\pagestyle{fancy}');
    lines.push('\\fancyhf{}');
    lines.push(`\\fancyhead[L]{\\small ${escapeLatexText(subjectTitle)}}`);
    lines.push('\\fancyhead[R]{\\small \\thepage}');
    lines.push('\\renewcommand{\\headrulewidth}{0.4pt}');
    lines.push('\\fancyfoot{}');
  } else {
    lines.push('\\pagestyle{fancy}');
    lines.push('\\fancyhf{}');
    lines.push('\\renewcommand{\\headrulewidth}{0pt}');
    lines.push('\\fancyfoot[C]{\\thepage}');
  }

  lines.push('');
  lines.push('\\setstretch{1.8}');
  lines.push('\\setlength{\\parindent}{0pt}');
  lines.push('\\setlength{\\parskip}{0.3em}');
  lines.push('\\setlength{\\columnsep}{1.5em}');
  if (isMock) lines.push('\\setlength{\\columnseprule}{0.4pt}');
  lines.push('');

  return lines.join('\n');
}

/* ------------------------------------------------------------------ */
/*  Render one question                                                */
/* ------------------------------------------------------------------ */

function renderOneQuestion(question, { sectionLabel } = {}) {
  const qNum = question?.question_number || question?.questionNumber || '';
  const stem = question?.stem || '';
  const equations = question?.equations || [];
  const choices = question?.choices || [];

  const parts = [];

  if (sectionLabel) {
    parts.push(`\\noindent\\fbox{${escapeLatexText(sectionLabel)}}\\vspace{4pt}\\par`);
  }

  parts.push('\\begingroup');
  parts.push('\\leftskip=1em');

  if (qNum) {
    parts.push(
      `\\noindent\\hspace{-1em}\\textbf{${escapeLatexText(String(qNum))}.}\\enspace`,
    );
  }

  const segments = parseStemSegments(stem);

  for (const seg of segments) {
    if (seg.type === 'text') {
      for (const line of seg.lines) {
        const trimmed = line.trim();
        if (!trimmed) {
          parts.push('\\par');
          continue;
        }
        const subLines = trimmed.split(PARAGRAPH_MARKER_RE);
        for (let i = 0; i < subLines.length; i++) {
          if (i > 0) parts.push('\\par');
          const sub = subLines[i].trim();
          if (sub) {
            const rendered = smartTexLine(sub, equations);
            if (rendered.trim()) parts.push(rendered);
          }
        }
      }
    } else if (seg.type === 'bogi') {
      parts.push('\\vspace{4pt}');
      parts.push(renderBogiBoxLatex(seg.lines, equations));
      parts.push('\\vspace{4pt}');
    } else if (seg.type === 'deco') {
      parts.push('\\vspace{4pt}');
      parts.push(renderDecoBoxLatex(seg.lines, equations));
      parts.push('\\vspace{4pt}');
    }
  }

  if (choices.length > 0) {
    parts.push('\\vspace{4pt}');
    parts.push(renderChoicesLatex(choices, equations));
  }

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
  } = options;

  const lines = [
    '\\documentclass[12pt,varwidth=16cm]{standalone}',
    '\\usepackage{fontspec}',
    '\\usepackage{amsmath,amssymb}',
    '\\usepackage{kotex}',
    '\\usepackage{graphicx}',
    '\\usepackage{xcolor}',
    '\\usepackage{enumitem}',
    '\\usepackage{setspace}',
    '\\usepackage[most]{tcolorbox}',
    '',
    `\\setmainfont{${fontFamily}}[`,
    `  BoldFont = ${fontBold},`,
    ']',
    `\\setmainhangulfont{${fontFamily}}[`,
    `  BoldFont = ${fontBold},`,
    ']',
    '',
    '\\pagestyle{empty}',
    '\\setstretch{1.8}',
    '\\setlength{\\parindent}{0pt}',
    '\\setlength{\\parskip}{0.4em}',
    '',
    '\\begin{document}',
  ];

  return lines.join('\n') + '\n' + renderOneQuestion(question) + '\n\\end{document}\n';
}

/* ------------------------------------------------------------------ */
/*  Full document (multi-question, PDF)                                */
/* ------------------------------------------------------------------ */

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
  } = options;

  const preamble = buildPreamble({
    paper, fontFamily, fontBold, fontRegularPath, fontSize,
    subjectTitle, profile,
  });

  const parts = [preamble];
  parts.push('\\begin{document}\n');

  if (titlePageTopText || subjectTitle) {
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

  const qList = Array.isArray(questions) ? questions : [];
  const isMock = profile === 'mock' || profile === 'csat';
  let lastMode = null;

  for (let i = 0; i < qList.length; i++) {
    if (i > 0) parts.push('\\vspace{10pt}\n');

    const q = qList[i];
    let sectionLabel = null;

    if (isMock) {
      const mode = q?.mode || q?.questionMode || 'objective';
      if (mode !== lastMode) {
        if (mode === 'objective') sectionLabel = '5지선다형';
        else if (mode === 'essay') sectionLabel = '서술형';
        else sectionLabel = '단답형';
        lastMode = mode;
      }
    }

    parts.push(renderOneQuestion(q, { sectionLabel }));
    parts.push('\n');
  }

  if (columns >= 2) {
    parts.push('\\end{multicols}\n');
  }

  parts.push('\\end{document}\n');
  return parts.join('\n');
}
