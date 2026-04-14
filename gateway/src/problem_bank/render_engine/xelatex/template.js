/**
 * question data -> .tex source file content
 *
 * Two modes:
 *   buildTexSource(question)         — single question (standalone, for PNG preview)
 *   buildDocumentTexSource(questions) — full document (for PDF export)
 *
 * Strategy (no placeholders):
 *   1. Strip [문단] / [박스시작] / [박스끝] markers
 *   2. Split line into Korean-text segments and non-Korean (math) segments
 *      using a regex that only starts a match on a Hangul syllable
 *   3. Korean segments → escapeLatexText
 *   4. Math segments   → $\displaystyle ...$
 *      Before wrapping, replace known equation raws with their LaTeX form.
 */

const PARAGRAPH_MARKER_RE = /\[문단\]/g;
const BOGI_MARKER_RE = /\[박스시작\]|\[박스끝\]/g;

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

  // Canonicalize \left/\right delimiters so XeLaTeX does not fail on
  // source like "\left {" or "\right }".
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

function renderChoicesLatex(choices, equations) {
  if (!Array.isArray(choices) || choices.length === 0) return '';
  const items = [];
  for (const c of choices) {
    const text = typeof c === 'string' ? c : c?.text || c?.label || '';
    items.push(`  \\item ${smartTexLine(text, equations)}`);
  }
  return [
    '\\begin{enumerate}[label=\\textcircled{\\small\\arabic*},itemsep=4pt,leftmargin=2em]',
    ...items,
    '\\end{enumerate}',
  ].join('\n');
}

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

function buildPreamble({ paper, fontFamily, fontBold, fontRegularPath, fontSize }) {
  const geom = paperGeometry(paper);
  const mainFont = fontFamily || 'Malgun Gothic';
  const boldFont = fontBold || `${mainFont} Bold`;
  const size = fontSize || 11;
  const mainDirective = fontSpecDirective(fontRegularPath, mainFont, boldFont);
  const hangulDirective = hangulFontDirective(fontRegularPath, mainFont, boldFont);

  return String.raw`\documentclass[${size}pt]{article}
\usepackage[${geom}]{geometry}
\usepackage{fontspec}
\usepackage{amsmath,amssymb}
\usepackage{kotex}
\usepackage{graphicx}
\usepackage{xcolor}
\usepackage{enumitem}
\usepackage{multicol}
\usepackage{fancyhdr}

${mainDirective}
${hangulDirective}

\pagestyle{fancy}
\fancyhf{}
\renewcommand{\headrulewidth}{0pt}
\fancyfoot[C]{\thepage}

\setlength{\parindent}{0pt}
\setlength{\parskip}{0.3em}
\setlength{\columnsep}{1.5em}
`;
}

function renderOneQuestion(question) {
  const qNum = question?.question_number || question?.questionNumber || '';
  const stem = question?.stem || '';
  const equations = question?.equations || [];
  const choices = question?.choices || [];

  const parts = [];

  if (qNum) {
    parts.push(`\\noindent\\textbf{${escapeLatexText(String(qNum))}.}\\enspace`);
  }

  const stemLines = stem.split('\n');
  for (const line of stemLines) {
    const trimmed = line.trim();
    if (!trimmed) {
      parts.push('\\par');
      continue;
    }
    const rendered = smartTexLine(trimmed, equations);
    if (rendered.trim()) parts.push(rendered);
  }

  if (choices.length > 0) {
    parts.push('\\vspace{4pt}');
    parts.push(renderChoicesLatex(choices, equations));
  }

  return parts.join('\n');
}

// --- Single question (standalone, PNG) ---

export function buildTexSource(question, options = {}) {
  const {
    fontFamily = 'Malgun Gothic',
    fontBold = 'Malgun Gothic Bold',
  } = options;

  const preamble = String.raw`\documentclass[12pt,varwidth=16cm]{standalone}
\usepackage{fontspec}
\usepackage{amsmath,amssymb}
\usepackage{kotex}
\usepackage{graphicx}
\usepackage{xcolor}
\usepackage{enumitem}

\setmainfont{${fontFamily}}[
  BoldFont = ${fontBold},
]
\setmainhangulfont{${fontFamily}}[
  BoldFont = ${fontBold},
]

\pagestyle{empty}
\setlength{\parindent}{0pt}
\setlength{\parskip}{0.4em}

\begin{document}
`;

  return preamble + renderOneQuestion(question) + '\n\\end{document}\n';
}

// --- Full document (multi-question, PDF) ---

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
  } = options;

  const preamble = buildPreamble({ paper, fontFamily, fontBold, fontRegularPath, fontSize });
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
  for (let i = 0; i < qList.length; i++) {
    if (i > 0) parts.push('\\vspace{10pt}\n');
    parts.push(renderOneQuestion(qList[i]));
    parts.push('\n');
  }

  if (columns >= 2) {
    parts.push('\\end{multicols}\n');
  }

  parts.push('\\end{document}\n');
  return parts.join('\n');
}
