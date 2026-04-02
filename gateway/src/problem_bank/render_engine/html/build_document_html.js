import { renderQuestionBlock } from './components/question_block.js';
import { composeLineV1 } from './line_composer.js';
import { escapeHtml, normalizeMathLatex, isFractionLatex } from '../utils/text.js';

const PAPER_MM = {
  A4: { width: 210, height: 297 },
  B4: { width: 257, height: 364 },
  '8절': { width: 273, height: 394 },
};

function profileTitle(profile) {
  if (profile === 'csat') return '수능형 시험지';
  if (profile === 'mock') return '모의고사형 시험지';
  return '내신형 시험지';
}

function buildStyles({
  paper,
  marginMm,
  profile,
  stemSizePt,
  lineHeightPt,
  numberLaneWidthPt,
  numberGapPt,
  questionGapPt,
  choiceGapPt,
  columns,
  columnGapPt,
  perPage,
}) {
  const paperMm = PAPER_MM[paper] || PAPER_MM.A4;
  const pageSizeCss = `${paperMm.width}mm ${paperMm.height}mm`;
  const headerApproxMm = 22;
  const grid4HeightMm = Math.max(100, paperMm.height - 2 * marginMm - headerApproxMm).toFixed(1);
  const title = profileTitle(profile);
  return `
    @page {
      size: ${pageSizeCss};
      margin: ${marginMm}mm;
    }
    :root {
      --stem-size-pt: ${stemSizePt};
      --line-height-pt: ${lineHeightPt};
      --number-lane-pt: ${numberLaneWidthPt};
      --number-gap-pt: ${numberGapPt};
      --question-gap-pt: ${questionGapPt};
      --choice-gap-pt: ${choiceGapPt};
      --column-gap-pt: ${columnGapPt};
      --lc-line-normal: calc(var(--line-height-pt) * 1pt);
      --lc-line-fraction: calc((var(--line-height-pt) + 2.2) * 1pt);
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      max-width: ${(paperMm.width - 2 * marginMm).toFixed(1)}mm;
      font-family: "YggMain", "HCR Batang", "Malgun Gothic", serif;
      font-size: calc(var(--stem-size-pt) * 1pt);
      font-weight: 300;
      font-synthesis: none;
      line-height: calc(var(--line-height-pt) * 1pt);
      word-spacing: 0.15em;
      color: #111;
      background: #fff;
    }
    .paper-title {
      font-size: calc((var(--stem-size-pt) + 1) * 1pt);
      font-weight: 700;
      margin-bottom: 8pt;
      letter-spacing: 0.2pt;
      color: #1f1f1f;
    }
    .question-stream {
      columns: ${columns};
      column-gap: calc(var(--column-gap-pt) * 1pt);
      overflow: visible;
    }
    .question-stream.question-stream-grid4 {
      columns: auto;
      display: grid;
      grid-template-columns: 1fr 1fr;
      grid-template-rows: 1fr 1fr;
      column-gap: calc(var(--column-gap-pt) * 1pt);
      row-gap: 0;
      height: ${grid4HeightMm}mm;
      overflow: visible;
    }
    .question-stream-grid4 .question-slot {
      min-width: 0;
      overflow: hidden;
    }
    .question-stream-grid4 .question-slot-firstline {
      display: block;
      height: calc(var(--line-height-pt) * 1pt);
      line-height: calc(var(--line-height-pt) * 1pt);
      white-space: pre;
    }
    .question-stream-grid4 .question {
      break-inside: initial;
      margin-bottom: 0;
    }
    .question-stream-grid4 .question-slot-empty {
      min-height: calc(var(--line-height-pt) * 1pt);
    }
    .question {
      break-inside: avoid;
      margin-bottom: calc(var(--question-gap-pt) * 1pt);
      overflow: visible;
    }
    .q-num {
      font-family: "YggQNum", "YggMain", serif;
      font-weight: 700;
      font-size: calc((var(--stem-size-pt) + 1) * 1pt);
      -webkit-text-stroke: 0.3pt currentColor;
      display: inline;
      line-height: 1;
      vertical-align: baseline;
      white-space: nowrap;
      margin-right: 0.25em;
    }
    .q-stem {
      white-space: normal;
    }
    .lc-line {
      display: inline;
      line-height: var(--lc-line-normal);
      -webkit-box-decoration-break: clone;
      box-decoration-break: clone;
    }
    .lc-line.lc-fraction {
      line-height: var(--lc-line-fraction);
    }
    .debug-first {
      display: inline;
      position: relative;
    }
    .bogi-box, .figure-container, .choice-list, .choice-grid-row1, .choice-grid-row2 {
      text-indent: 0;
    }
    .choice-list {
      margin-top: calc(var(--line-height-pt) * 0.3 * 1pt);
      display: grid;
      grid-template-columns: 1fr;
      row-gap: calc(var(--choice-gap-pt) * 1pt);
    }
    .choice-list.has-fraction {
      row-gap: calc((var(--choice-gap-pt) + 1) * 1pt);
    }
    .choice {
      display: inline-flex;
      align-items: center;
      gap: 4.5pt;
      min-width: 0;
      overflow: visible;
    }
    .choice .math-inline {
      transform: translateY(-1pt);
    }
    .choice-label {
      white-space: nowrap;
      flex-shrink: 0;
    }
    .choice-text {
      min-width: 0;
      overflow-wrap: anywhere;
      word-break: keep-all;
      overflow: visible;
    }
    .choice-grid-row1 {
      margin-top: calc(var(--line-height-pt) * 0.3 * 1pt);
      display: grid;
      grid-template-columns: repeat(5, 1fr);
      align-items: center;
      column-gap: 4pt;
      row-gap: calc(var(--choice-gap-pt) * 1pt);
      overflow: visible;
    }
    .choice-grid-row2 {
      margin-top: calc(var(--line-height-pt) * 0.3 * 1pt);
      overflow: visible;
    }
    .choice-grid-row2-top {
      display: grid;
      grid-template-columns: repeat(3, 1fr);
      align-items: center;
      column-gap: 4pt;
      row-gap: calc(var(--choice-gap-pt) * 1pt);
      overflow: visible;
    }
    .choice-grid-row2-bot {
      display: grid;
      grid-template-columns: repeat(3, 1fr);
      align-items: center;
      column-gap: 4pt;
      row-gap: calc(var(--choice-gap-pt) * 1pt);
      margin-top: calc(var(--choice-gap-pt) * 1pt);
      overflow: visible;
    }
    .math-inline {
      display: inline-block;
      position: relative;
      line-height: 1;
      margin: 0 0.05em;
      vertical-align: middle;
      overflow: visible;
    }
    .math-inline::before {
      right: 100%;
      margin-right: 0.08em;
    }
    .math-inline::after {
      left: 100%;
      margin-left: 0.08em;
    }
    .math-inline svg {
      display: block;
      overflow: visible;
    }
    .math-inline.fraction {
      vertical-align: middle;
      padding-top: calc(var(--line-height-pt) * 0.25 * 1pt);
      padding-bottom: calc(var(--line-height-pt) * 0.25 * 1pt);
    }
    .bogi-box {
      margin-top: calc(var(--line-height-pt) * 0.8 * 1pt);
      margin-bottom: 8pt;
      border: none;
      padding: 10pt 12pt 8pt;
      position: relative;
    }
    .bogi-box-border {
      position: absolute;
      inset: 0;
      width: 100%;
      height: 100%;
      display: block;
      pointer-events: none;
      z-index: 0;
    }
    .bogi-title {
      position: absolute;
      top: -0.455em;
      left: 50%;
      transform: translateX(-50%);
      font-size: calc(var(--stem-size-pt) * 1pt);
      color: #111;
      white-space: nowrap;
      line-height: 1;
      background: #fff;
      padding: 0;
      display: inline-flex;
      align-items: center;
      gap: 0.15em;
      z-index: 1;
    }
    .bogi-bracket {
      display: block;
      flex-shrink: 0;
    }
    .bogi-title-text {
      display: inline-block;
      transform: translateY(0.04em);
      letter-spacing: 0.25em;
      margin-right: -0.25em;
    }
    .bogi-content {
      padding-top: 4pt;
      position: relative;
      z-index: 1;
    }
    .bogi-item {
      display: grid;
      grid-template-columns: auto 1fr;
      column-gap: 3pt;
      margin-bottom: 2pt;
    }
    .bogi-item-label {
      white-space: nowrap;
      font-weight: 400;
    }
    .bogi-item-text {
      min-width: 0;
    }
    .figure-container {
      margin: 6pt 0;
      text-align: center;
    }
    .figure-img {
      max-width: 100%;
      height: auto;
      display: block;
    }
    .figure-anchor-center { text-align: center; }
    .figure-anchor-center .figure-img { margin: 0 auto; }
    .figure-anchor-left { text-align: left; }
    .figure-anchor-right { text-align: right; }
    .figure-anchor-right .figure-img { margin-left: auto; }
    .figure-anchor-top { text-align: center; }
    .figure-anchor-top .figure-img { margin: 0 auto; }
    .figure-pos-inline-right {
      float: right;
      margin: 0 0 0.5em 0.5em;
      clear: right;
    }
    .figure-pos-inline-left {
      float: left;
      margin: 0 0.5em 0.5em 0;
      clear: left;
    }
    .figure-group-horizontal {
      display: flex;
      flex-wrap: wrap;
      justify-content: center;
      align-items: flex-start;
      margin: 6pt 0;
    }
    .figure-layout-item {
      flex-shrink: 0;
    }
    .figure-layout-item .figure-img {
      width: 100%;
    }
    .figure-inline-block { display: block; text-align: center; margin: 6pt 0; text-indent: 0; }
    .figure-inline-block .figure-img { max-width: 100%; height: auto; }
    .figure-inline-block.figure-anchor-left { text-align: left; }
    .figure-inline-block.figure-anchor-right { text-align: right; }
    .figure-inline-block.figure-group-horizontal { display: flex; flex-wrap: wrap; justify-content: center; align-items: flex-start; }
    .figure-inline-block.figure-group-horizontal .figure-layout-item { flex-shrink: 0; }
    .figure-inline-block.figure-group-horizontal .figure-layout-item .figure-img { width: 100%; }
    .figure-placeholder {
      margin: 6pt 0;
      padding: 8pt;
      border: 0.3pt solid #bbb;
      border-radius: 2pt;
      color: #555;
      font-size: calc((var(--stem-size-pt) - 0.6) * 1pt);
      text-align: center;
    }
    .page-break {
      break-before: page;
      margin-top: 0;
    }
    .sub-title {
      font-size: calc((var(--stem-size-pt) + 1) * 1pt);
      font-weight: 700;
      margin: 0 0 8pt;
    }
    .answer-grid {
      display: grid;
      grid-template-columns: repeat(3, 1fr);
      gap: 6pt 12pt;
      font-size: calc((var(--stem-size-pt) - 0.6) * 1pt);
    }
    .answer-item {
      white-space: nowrap;
      display: inline-flex;
      align-items: center;
      gap: 4.5pt;
      overflow: visible;
    }
    .answer-item .math-inline {
      transform: translateY(-1pt);
    }
    .answer-num {
      font-weight: 700;
    }
    .explain-item {
      margin-bottom: 8pt;
      display: grid;
      grid-template-columns: 22pt 1fr;
      column-gap: 6pt;
    }
    .profile-note {
      font-size: calc((var(--stem-size-pt) - 1.5) * 1pt);
      color: #666;
      margin-bottom: 8pt;
    }
    .profile-note::before {
      content: "${escapeHtml(title)}";
    }
  `;
}

function renderAnswerSheet(questions, mathRenderer) {
  if (!Array.isArray(questions) || questions.length === 0) return '';
  const CIRCLED_RE = /^[①②③④⑤]$/;
  const rows = questions.map((q) => {
    const raw = String(q?.export_answer || '').trim() || '(미기입)';
    let answerHtml;
    if (mathRenderer && raw !== '(미기입)' && !CIRCLED_RE.test(raw)) {
      const latex = normalizeMathLatex(raw) || raw;
      const result = mathRenderer.renderInline(latex);
      if (result.ok && result.svg) {
        const fraction = isFractionLatex(latex);
        const klass = fraction ? 'math-inline fraction' : 'math-inline';
        answerHtml = `<span class="${klass}" data-latex="${escapeHtml(latex)}">${result.svg}</span>`;
      } else {
        const composed = composeLineV1(raw, mathRenderer, q?.equations);
        answerHtml = composed.html;
      }
    } else {
      answerHtml = escapeHtml(raw);
    }
    return `<div class="answer-item"><span class="answer-num">${escapeHtml(String(q?.question_number || '?'))}.</span>${answerHtml}</div>`;
  });
  return `
    <section class="page-break">
      <h2 class="sub-title">정답지</h2>
      <div class="answer-grid">${rows.join('')}</div>
    </section>
  `;
}

function renderExplanationSection(questions) {
  if (!Array.isArray(questions) || questions.length === 0) return '';
  const rows = questions.map((q) => {
    const note = String(q?.reviewer_notes || '').trim() || '(검수 메모 없음)';
    return `
      <div class="explain-item">
        <div>${escapeHtml(String(q?.question_number || '?'))}</div>
        <div>${escapeHtml(note)}</div>
      </div>
    `;
  });
  return `
    <section class="page-break">
      <h2 class="sub-title">해설/검수 메모</h2>
      ${rows.join('')}
    </section>
  `;
}

export function buildDocumentHtml({
  profile,
  paper,
  layout,
  questions,
  includeAnswerSheet,
  includeExplanation,
  mathRenderer,
  fontFaceCss = '',
  maxQuestionsPerPage = 99,
}) {
  const columns = Number(layout?.layoutColumns || 1) === 2 ? 2 : 1;
  const perPage = Math.max(1, Math.min(99, Number(maxQuestionsPerPage) || 99));
  const styles = buildStyles({
    paper,
    marginMm: Number(layout?.marginMm || 16.2),
    profile,
    stemSizePt: Number(layout?.stemSizePt || 11.0),
    lineHeightPt: Number(layout?.lineHeightPt || 15.0),
    numberLaneWidthPt: Number(layout?.numberLaneWidthPt || 26),
    numberGapPt: Number(layout?.numberGapPt || 6),
    questionGapPt: Number(layout?.questionGapPt || 30),
    choiceGapPt: Number(layout?.choiceGapPt || 2),
    columns,
    columnGapPt: Number(layout?.columnGapPt || 18),
    perPage,
  });

  const stemSizePt = Number(layout?.stemSizePt || 11.0);
  const allQ = (questions || []).map((q) => renderQuestionBlock(q, mathRenderer, { stemSizePt }));
  const useFourSplit = columns === 2 && perPage === 4;
  const GRID4_POS = [
    { row: 1, col: 1 },
    { row: 2, col: 1 },
    { row: 1, col: 2 },
    { row: 2, col: 2 },
  ];
  const renderStreamSection = (chunk, cls) => {
    if (!useFourSplit) {
      return `<section class="${cls}">${chunk.join('')}</section>`;
    }
    const slots = [];
    for (let i = 0; i < perPage; i += 1) {
      const pos = GRID4_POS[i];
      const one = chunk[i] || '<div class="question-slot-empty">&nbsp;</div>';
      slots.push(
        `<div class="question-slot" style="grid-row:${pos.row};grid-column:${pos.col}"><div class="question-slot-firstline" aria-hidden="true">&nbsp;</div>${one}</div>`,
      );
    }
    return `<section class="${cls} question-stream-grid4">${slots.join('')}</section>`;
  };
  let questionHtml;
  if (perPage >= 99 || allQ.length <= perPage) {
    questionHtml = renderStreamSection(allQ, 'question-stream');
  } else {
    const pages = [];
    for (let i = 0; i < allQ.length; i += perPage) {
      const chunk = allQ.slice(i, i + perPage);
      const cls = i === 0 ? 'question-stream' : 'question-stream page-break';
      pages.push(renderStreamSection(chunk, cls));
    }
    questionHtml = pages.join('');
  }
  const answerSheetHtml = includeAnswerSheet ? renderAnswerSheet(questions, mathRenderer) : '';
  const explanationHtml = includeExplanation ? renderExplanationSection(questions) : '';

  return `
    <!doctype html>
    <html lang="ko">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <style>${fontFaceCss}</style>
        <style>${styles}</style>
      </head>
      <body>
        <div class="paper-title">${escapeHtml(profileTitle(profile))}</div>
        <div class="profile-note"></div>
        ${questionHtml}
        ${answerSheetHtml}
        ${explanationHtml}
      </body>
    </html>
  `;
}
