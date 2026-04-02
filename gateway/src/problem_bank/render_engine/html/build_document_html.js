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
      height: calc(var(--line-height-pt) * 0.5 * 1pt);
      line-height: calc(var(--line-height-pt) * 0.5 * 1pt);
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

    /* ── mock/csat exam-paper layout ── */
    .mock-pages { display: none; }
    body.profile-mock .paper-title,
    body.profile-csat .paper-title,
    body.profile-mock .profile-note,
    body.profile-csat .profile-note {
      display: none;
    }
    body.profile-mock .mock-pages,
    body.profile-csat .mock-pages {
      display: block;
    }
    .mock-page {
      min-height: ${(paperMm.height - 2 * marginMm).toFixed(1)}mm;
      display: flex;
      flex-direction: column;
      break-inside: avoid;
      overflow: hidden;
    }
    .mock-page.mock-page-first .mock-header-first {
      margin-bottom: 20pt;
    }
    .mock-page-first .mock-header-first-bottom {
      transform: translateY(8pt);
    }
    .mock-header-first {
      margin-bottom: 2pt;
      display: flex;
      flex-direction: column;
      gap: 2.4pt;
    }
    .mock-header-first-top,
    .mock-header-first-bottom,
    .mock-header-simple {
      display: grid;
      grid-template-columns: 1fr auto 1fr;
      gap: 10pt;
    }
    .mock-header-first-top {
      align-items: end;
    }
    .mock-header-first-bottom {
      align-items: center;
      margin-top: 8pt;
    }
    .mock-header-simple {
      margin-bottom: 2pt;
      align-items: end;
    }
    .mock-first-title {
      grid-column: 2;
      justify-self: center;
      font-size: calc((var(--stem-size-pt) + 5.0) * 1pt);
      font-weight: 700;
      color: #111;
      letter-spacing: 0.01em;
      line-height: 1;
      white-space: nowrap;
    }
    .mock-first-subject,
    .mock-simple-subject {
      grid-column: 2;
      justify-self: center;
      font-size: calc((var(--stem-size-pt) + 20.5) * 1pt);
      font-weight: 900;
      color: #111;
      line-height: 0.9;
      letter-spacing: -0.01em;
      -webkit-text-stroke: 0.3pt #111;
      white-space: nowrap;
    }
    .mock-simple-subject {
      font-size: calc((var(--stem-size-pt) + 11.2) * 1pt);
      font-weight: 900;
      line-height: 0.96;
      letter-spacing: 0;
      -webkit-text-stroke: 0.16pt #111;
    }
    .mock-side-left { justify-self: start; text-align: left; }
    .mock-side-right { justify-self: end; text-align: right; }
    .mock-chip {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      border: 0.8pt solid #111;
      color: #111;
      background: #fff;
    }
    .mock-chip-session {
      min-height: 22.5pt;
      padding: 0 7.5pt;
      border-radius: 999pt;
      font-size: calc((var(--stem-size-pt) + 1.4) * 1pt);
      font-weight: 900;
      -webkit-text-stroke: 0.14pt #111;
      line-height: 1;
    }
    .mock-chip-condensed {
      display: inline-block;
      transform: scaleX(0.9);
      transform-origin: center;
    }
    .mock-chip-type {
      min-height: 35pt;
      padding: 0 8.5pt;
      border-radius: 4.6pt;
      font-size: calc((var(--stem-size-pt) + 5.6) * 1pt);
      font-weight: 900;
      -webkit-text-stroke: 0.1pt #111;
      line-height: 1;
    }
    .mock-chip-type-simple {
      min-height: 24pt;
      padding: 0 4.8pt;
      border-radius: 3.8pt;
      font-size: calc((var(--stem-size-pt) + 1.8) * 1pt);
      font-weight: 800;
      -webkit-text-stroke: 0.05pt #111;
    }
    .mock-first-type {
      transform: translateY(8.8pt);
    }
    .mock-page-no {
      display: inline-block;
      font-size: calc((var(--stem-size-pt) + 15.8) * 1pt);
      font-weight: 900;
      color: #111;
      line-height: 0.95;
      min-width: 0.85em;
      text-align: center;
    }
    .mock-page-no-first {
      transform: translateY(4pt);
    }
    .mock-main {
      flex: 1 1 0;
      display: flex;
      flex-direction: column;
      min-height: 0;
      position: relative;
      border-top: 1pt solid #111;
      padding-top: 0;
    }
    .mock-main::before {
      content: '';
      position: absolute;
      left: 50%;
      top: 0;
      bottom: 3.2pt;
      border-left: 1pt solid #111;
      transform: translateX(-0.5pt);
      pointer-events: none;
    }
    .mock-page-first .mock-main::before {
      bottom: 22pt;
    }
    .mock-section-label {
      display: inline-flex;
      width: fit-content;
      max-width: max-content;
      align-self: flex-start;
      white-space: nowrap;
      justify-content: center;
      align-items: center;
      border: 0.7pt solid #111;
      background: #fff;
      color: #111;
      padding: 1pt 8.5pt 0.8pt;
      font-size: calc((var(--stem-size-pt) + 2.3) * 1pt);
      font-weight: 700;
      margin-top: 5pt;
      margin-bottom: 4pt;
      line-height: 1.2;
      letter-spacing: 0.16em;
    }
    .mock-page-first .mock-section-label {
      transform: translateY(8pt);
    }
    .mock-content {
      position: relative;
      padding-top: 0;
      flex: 1 1 0;
      min-height: 0;
      display: flex;
      flex-direction: column;
      min-height: ${(paperMm.height - 2 * marginMm - 44).toFixed(1)}mm;
    }
    .mock-content .question-stream {
      columns: 2;
      column-gap: calc(var(--column-gap-pt) * 1pt);
      overflow: visible;
      flex: 1 1 auto;
    }
    .mock-page-first .mock-content .question-stream {
      margin-top: -6pt;
    }
    .mock-page-first .question-stream-grid4 .question-slot-firstline {
      height: calc(var(--line-height-pt) * 0.45 * 1pt);
      line-height: calc(var(--line-height-pt) * 0.45 * 1pt);
    }
    .mock-page-first .mock-content .question-stream.question-stream-grid4 {
      row-gap: calc(var(--question-gap-pt) * 0.32 * 1pt);
    }
    .mock-page-first .question-stream-grid4 .question-slot.slot-r1c2 {
      margin-top: -8pt;
    }
    .mock-page:not(.mock-page-first) .mock-header-simple {
      margin-bottom: 8pt;
    }
    .mock-page:not(.mock-page-first) .mock-content .question-stream {
      margin-top: -2pt;
    }
    .mock-page:not(.mock-page-first) .question-stream-grid4 .question-slot-firstline {
      height: calc(var(--line-height-pt) * 0.25 * 1pt);
      line-height: calc(var(--line-height-pt) * 0.25 * 1pt);
    }
    .mock-content .question-stream.question-stream-grid4 {
      columns: auto;
      display: grid;
      grid-template-columns: 1fr 1fr;
      grid-template-rows: repeat(2, minmax(0, 1fr));
      column-gap: calc(var(--column-gap-pt) * 1pt);
      row-gap: calc(var(--question-gap-pt) * 0.18 * 1pt);
      height: 100%;
      min-height: 0;
      align-items: stretch;
      overflow: visible;
    }
    .mock-footer-row {
      margin-top: 6pt;
      display: grid;
      grid-template-columns: 1fr auto 1fr;
      align-items: end;
      gap: 8pt;
    }
    .mock-page-box {
      position: relative;
      width: 38pt;
      height: 22pt;
      border: 0.8pt solid #666;
      color: #111;
      font-weight: 700;
      font-size: calc((var(--stem-size-pt) - 0.2) * 1pt);
      overflow: hidden;
      background: #fff;
    }
    .mock-page-box::before {
      content: '';
      position: absolute;
      inset: 0;
      background: linear-gradient(to bottom right,
        transparent calc(50% - 0.4pt),
        #888 calc(50% - 0.1pt),
        #888 calc(50% + 0.1pt),
        transparent calc(50% + 0.4pt)
      );
      pointer-events: none;
    }
    .mock-page-box-cur {
      position: absolute;
      left: 4pt;
      top: 2pt;
      line-height: 1;
    }
    .mock-page-box-total {
      position: absolute;
      right: 4pt;
      bottom: 2pt;
      line-height: 1;
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
      const slotClass = `question-slot slot-r${pos.row}c${pos.col}`;
      slots.push(
        `<div class="${slotClass}" style="grid-row:${pos.row};grid-column:${pos.col}"><div class="question-slot-firstline" aria-hidden="true">&nbsp;</div>${one}</div>`,
      );
    }
    return `<section class="${cls} question-stream-grid4">${slots.join('')}</section>`;
  };
  const questionChunks = [];
  if (perPage >= 99 || allQ.length <= perPage) {
    questionChunks.push(allQ);
  } else {
    for (let i = 0; i < allQ.length; i += perPage) {
      questionChunks.push(allQ.slice(i, i + perPage));
    }
  }
  if (questionChunks.length === 0) questionChunks.push([]);

  const isMockStyle = profile === 'mock' || profile === 'csat';
  let questionHtml;
  if (isMockStyle) {
    const totalPages = questionChunks.length;
    const renderMockHeader = (pageNo) => {
      if (pageNo === 1) {
        return `
          <header class="mock-header-first">
            <div class="mock-header-first-top">
              <div></div>
              <div class="mock-first-title">2026학년도 대학수학능력시험 문제지</div>
              <div class="mock-side-right"><span class="mock-page-no mock-page-no-first">${pageNo}</span></div>
            </div>
            <div class="mock-header-first-bottom">
              <div class="mock-side-left">
                <span class="mock-chip mock-chip-session"><span class="mock-chip-condensed">제 2 교시</span></span>
              </div>
              <div class="mock-first-subject">수학 영역</div>
              <div class="mock-side-right">
                <span class="mock-chip mock-chip-type mock-first-type">홀수형</span>
              </div>
            </div>
          </header>
        `;
      }
      const even = pageNo % 2 === 0;
      const left = even
        ? `<span class="mock-page-no">${pageNo}</span>`
        : '<span class="mock-chip mock-chip-type mock-chip-type-simple">홀수형</span>';
      const right = even
        ? '<span class="mock-chip mock-chip-type mock-chip-type-simple">홀수형</span>'
        : `<span class="mock-page-no">${pageNo}</span>`;
      return `
        <header class="mock-header-simple">
          <div class="mock-side-left">${left}</div>
          <div class="mock-simple-subject">수학 영역</div>
          <div class="mock-side-right">${right}</div>
        </header>
      `;
    };
    questionHtml = `<div class="mock-pages">${questionChunks.map((chunk, idx) => {
      const pageNo = idx + 1;
      const stream = renderStreamSection(chunk, 'question-stream');
      const pageBreak = idx === 0 ? '' : ' page-break';
      const firstClass = idx === 0 ? ' mock-page-first' : '';
      const sectionLabel = idx === 0 ? '<div class="mock-section-label">5지선다형</div>' : '';
      return `
        <section class="mock-page${firstClass}${pageBreak}">
          ${renderMockHeader(pageNo)}
          <div class="mock-main">
            ${sectionLabel}
            <div class="mock-content">${stream}</div>
          </div>
          <div class="mock-footer-row">
            <div></div>
            <div class="mock-page-box">
              <span class="mock-page-box-cur">${pageNo}</span>
              <span class="mock-page-box-total">${totalPages}</span>
            </div>
            <div></div>
          </div>
        </section>
      `;
    }).join('')}</div>`;
  } else if (questionChunks.length === 1) {
    questionHtml = renderStreamSection(questionChunks[0], 'question-stream');
  } else {
    questionHtml = questionChunks
      .map((chunk, idx) => renderStreamSection(chunk, idx === 0 ? 'question-stream' : 'question-stream page-break'))
      .join('');
  }
  const answerSheetHtml = includeAnswerSheet ? renderAnswerSheet(questions, mathRenderer) : '';
  const explanationHtml = includeExplanation ? renderExplanationSection(questions) : '';
  const bodyClass = isMockStyle ? `profile-${profile}` : '';

  return `
    <!doctype html>
    <html lang="ko">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <style>${fontFaceCss}</style>
        <style>${styles}</style>
      </head>
      <body class="${bodyClass}">
        <div class="paper-title">${escapeHtml(profileTitle(profile))}</div>
        <div class="profile-note"></div>
        ${questionHtml}
        ${answerSheetHtml}
        ${explanationHtml}
      </body>
    </html>
  `;
}
