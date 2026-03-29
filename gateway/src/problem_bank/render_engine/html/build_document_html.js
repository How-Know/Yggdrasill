import { renderQuestionBlock } from './components/question_block.js';
import { escapeHtml } from '../utils/text.js';

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
}) {
  const paperMm = PAPER_MM[paper] || PAPER_MM.A4;
  const pageSizeCss = `${paperMm.width}mm ${paperMm.height}mm`;
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
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: "YggMain", "HCR Batang", "Malgun Gothic", serif;
      font-size: calc(var(--stem-size-pt) * 1pt);
      line-height: calc(var(--line-height-pt) * 1pt);
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
    }
    .question {
      break-inside: avoid;
      margin-bottom: calc(var(--question-gap-pt) * 1pt);
    }
    .q-header {
      display: flex;
      align-items: baseline;
      gap: 2pt;
    }
    .q-num {
      font-weight: 700;
      white-space: nowrap;
      flex-shrink: 0;
    }
    .q-first-line { flex: 1; min-width: 0; }
    .q-body {
      min-width: 0;
    }
    .q-stem { white-space: normal; }
    .stem-line { margin: 0; }
    .choice-list {
      margin-top: calc(var(--line-height-pt) * 1.8 * 1pt - var(--line-height-pt) * 1pt);
      display: grid;
      grid-template-columns: 1fr;
      row-gap: calc(var(--choice-gap-pt) * 1pt);
    }
    .choice-list.has-fraction {
      row-gap: calc((var(--choice-gap-pt) + 1) * 1pt);
    }
    .choice {
      display: inline-flex;
      align-items: baseline;
      gap: 3pt;
      min-width: 0;
    }
    .choice-label { white-space: nowrap; }
    .choice-text {
      min-width: 0;
      overflow-wrap: anywhere;
      word-break: keep-all;
    }
    .choice-grid-row1 {
      margin-top: calc(var(--line-height-pt) * 1.8 * 1pt - var(--line-height-pt) * 1pt);
      display: grid;
      grid-template-columns: repeat(5, 1fr);
      column-gap: 4pt;
      row-gap: calc(var(--choice-gap-pt) * 1pt);
    }
    .choice-grid-row2 {
      margin-top: calc(var(--line-height-pt) * 1.8 * 1pt - var(--line-height-pt) * 1pt);
    }
    .choice-grid-row2-top {
      display: grid;
      grid-template-columns: repeat(3, 1fr);
      column-gap: 4pt;
      row-gap: calc(var(--choice-gap-pt) * 1pt);
    }
    .choice-grid-row2-bot {
      display: grid;
      grid-template-columns: repeat(3, 1fr);
      column-gap: 4pt;
      row-gap: calc(var(--choice-gap-pt) * 1pt);
      margin-top: calc(var(--choice-gap-pt) * 1pt);
    }
    .math-inline {
      display: inline-block;
      line-height: 1;
      margin: 0 0.05em;
    }
    .math-inline svg {
      display: block;
    }
    .math-inline.fraction {
      margin-top: 0.15em;
      margin-bottom: 0.15em;
    }
    .bogi-box {
      margin: 8pt 0;
      border: 0.8pt solid #333;
      padding: 10pt 12pt 8pt;
      position: relative;
    }
    .bogi-title {
      position: absolute;
      top: -0.6em;
      left: 50%;
      transform: translateX(-50%);
      font-size: calc(var(--stem-size-pt) * 1pt);
      color: #111;
      white-space: nowrap;
      line-height: 1;
      background: #fff;
      padding: 0 6pt;
      letter-spacing: 0.15em;
    }
    .bogi-content {
      padding-top: 4pt;
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
    }
    .figure-placeholder {
      margin: 6pt 0;
      padding: 8pt;
      border: 0.8pt solid #bbb;
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
    .answer-item { white-space: nowrap; }
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

function renderAnswerSheet(questions) {
  if (!Array.isArray(questions) || questions.length === 0) return '';
  const rows = questions.map((q) => {
    const answer = String(q?.export_answer || '').trim() || '(미기입)';
    return `<div class="answer-item">${escapeHtml(String(q?.question_number || '?'))} ${escapeHtml(answer)}</div>`;
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
}) {
  const columns = Number(layout?.layoutColumns || 1) === 2 ? 2 : 1;
  const styles = buildStyles({
    paper,
    marginMm: Number(layout?.marginMm || 16.2),
    profile,
    stemSizePt: Number(layout?.stemSizePt || 11.0),
    lineHeightPt: Number(layout?.lineHeightPt || 15.0),
    numberLaneWidthPt: Number(layout?.numberLaneWidthPt || 26),
    numberGapPt: Number(layout?.numberGapPt || 6),
    questionGapPt: Number(layout?.questionGapPt || 10),
    choiceGapPt: Number(layout?.choiceGapPt || 2),
    columns,
    columnGapPt: Number(layout?.columnGapPt || 18),
  });

  const questionHtml = (questions || [])
    .map((q) => renderQuestionBlock(q, mathRenderer))
    .join('');
  const answerSheetHtml = includeAnswerSheet ? renderAnswerSheet(questions) : '';
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
        <section class="question-stream">
          ${questionHtml}
        </section>
        ${answerSheetHtml}
        ${explanationHtml}
      </body>
    </html>
  `;
}
