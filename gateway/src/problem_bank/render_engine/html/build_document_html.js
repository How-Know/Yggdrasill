import { renderQuestionBlock } from './components/question_block.js';
import { composeLineV1 } from './line_composer.js';
import { buildSlotPlan } from './slot_plan.js';
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
  const mockFirstSubjectPt = ((stemSizePt + 20.5) * 1.1).toFixed(2);
  const mockSimpleSubjectPt = ((stemSizePt + 11.2) * 1.1).toFixed(2);
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
      --last-note-box-height: 88pt;
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
      grid-template-columns: repeat(var(--slot-grid-cols, 2), minmax(0, 1fr));
      grid-template-rows: repeat(var(--slot-grid-rows, 2), minmax(0, 1fr));
      column-gap: calc(var(--column-gap-pt) * 1pt);
      row-gap: 0;
      height: ${grid4HeightMm}mm;
      overflow: visible;
    }
    .question-stream-grid4 .question-slot {
      min-width: 0;
      overflow: hidden;
    }
    .question-stream-grid4 .question-slot.question-slot-hidden {
      visibility: hidden;
    }
    .question-stream-grid4 .question-slot[data-has-anchor="1"] {
      position: relative;
      overflow: visible;
    }
    .question-stream-grid4 .slot-label-overlay {
      position: absolute;
      left: 0;
      top: var(--slot-label-top, 9.2pt);
      z-index: 2;
      pointer-events: none;
    }
    .question-stream-grid4 .slot-label-overlay .mock-section-label {
      margin: 0;
      min-height: 22pt;
      padding: 1.1pt 10.3pt 0.88pt;
      transform: none;
    }
    .question-stream-grid4 .slot-anchor-body {
      padding-top: var(--slot-anchor-pad-top, 35.8pt);
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
    .mock-cover-pages { display: none; }
    body.profile-mock .paper-title,
    body.profile-csat .paper-title,
    body.profile-mock .profile-note,
    body.profile-csat .profile-note {
      display: none;
    }
    body.profile-mock .mock-cover-pages,
    body.profile-csat .mock-cover-pages {
      display: block;
    }
    body.profile-mock .mock-pages,
    body.profile-csat .mock-pages {
      display: block;
    }
    .mock-cover-page,
    .mock-cover-blank {
      min-height: ${(paperMm.height - 2 * marginMm).toFixed(1)}mm;
      break-inside: avoid;
      overflow: hidden;
      background: #fff;
    }
    .mock-cover-page {
      padding: 33pt 17pt 30pt;
      display: flex;
    }
    .mock-cover-blank {
      break-after: page;
    }
    .mock-cover-sheet {
      width: 100%;
      min-height: 100%;
      flex: 1 1 auto;
      display: flex;
      flex-direction: column;
      align-items: stretch;
      color: #111;
      font-family: "YggMain", "HCR Batang", "Malgun Gothic", serif;
    }
    .mock-cover-top-row {
      margin-top: 2pt;
      display: grid;
      grid-template-columns: 1fr auto 1fr;
      align-items: end;
      column-gap: 14pt;
    }
    .mock-cover-chip-left {
      justify-self: start;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      min-height: 30.3pt;
      min-width: 84pt;
      border: 0.6pt solid #777;
      border-radius: 999pt;
      padding: 0 11pt;
      margin-left: 10pt;
      align-self: end;
      font-size: calc((var(--stem-size-pt) + 1.9) * 1.1 * 1pt);
      font-weight: 800;
      line-height: 0.96;
      color: #333;
      letter-spacing: 0.01em;
      white-space: nowrap;
      transform: translateY(-10pt);
    }
    .mock-cover-top-title {
      justify-self: center;
      font-size: calc((var(--stem-size-pt) + 4.6) * 1.1 * 1pt);
      font-weight: 700;
      line-height: 1.05;
      letter-spacing: 0;
      color: #202020;
      white-space: nowrap;
    }
    .mock-cover-top-empty {
      justify-self: end;
      width: 1px;
      height: 1px;
    }
    .mock-cover-subject-row {
      margin-top: 20pt;
      display: grid;
      grid-template-columns: 1fr auto 1fr;
      align-items: baseline;
      column-gap: 14pt;
    }
    .mock-cover-chip-right {
      justify-self: end;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      min-height: 42pt;
      min-width: 88pt;
      border: 0.9pt solid #999;
      border-radius: 4pt;
      padding: 0 8.4pt;
      align-self: baseline;
      font-size: calc((var(--stem-size-pt) + 13.5) * 1pt);
      font-weight: 950;
      line-height: 0.95;
      color: #111;
      letter-spacing: -0.01em;
      -webkit-text-stroke: 0.32pt #111;
      text-shadow:
        0.24pt 0 0 #111,
        -0.24pt 0 0 #111;
      white-space: nowrap;
      transform: translate(10pt, -2pt);
    }
    .mock-cover-subject {
      display: flex;
      align-items: baseline;
      justify-content: center;
      gap: 0;
      font-family: "YggSubject", "YggMain", "HCR Batang", "Malgun Gothic", sans-serif;
      line-height: 1;
      white-space: nowrap;
      color: #111;
    }
    .mock-cover-subject-main {
      font-size: calc((var(--stem-size-pt) + 33.8) * 1.05 * 1pt);
      font-weight: 900;
      letter-spacing: -0.01em;
      -webkit-text-stroke: 0.24pt #111;
    }
    .mock-cover-subject-sub {
      font-size: calc((var(--stem-size-pt) + 30.42) * 1.05 * 1pt);
      font-weight: 800;
      letter-spacing: -0.01em;
      -webkit-text-stroke: 0.17pt #111;
    }
    .mock-cover-id-row {
      margin: 20pt auto 0;
      width: 92.5%;
      display: grid;
      grid-template-columns: 1fr 1.9fr;
      column-gap: 9pt;
      align-items: stretch;
    }
    .mock-cover-id-box {
      border: 0.8pt solid #8d8d8d;
      display: flex;
      align-items: stretch;
      min-height: 30.9pt;
      background: #fff;
    }
    .mock-cover-id-label {
      flex: 0 0 auto;
      border-right: 0.8pt solid #8d8d8d;
      min-width: 48pt;
      padding: 0 6pt;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      font-size: calc((var(--stem-size-pt) + 1.0) * 1.2 * 1pt);
      font-weight: 500;
      color: #444;
      white-space: nowrap;
    }
    .mock-cover-id-fill {
      flex: 1 1 auto;
    }
    .mock-cover-id-number-grid {
      flex: 1 1 auto;
      display: grid;
      grid-template-columns: repeat(10, minmax(0, 1fr));
      align-items: stretch;
    }
    .mock-cover-id-number-cell {
      border-left: 0.7pt dotted #8f8f8f;
      display: flex;
      align-items: center;
      justify-content: center;
      color: #666;
      font-size: calc((var(--stem-size-pt) + 0.6) * 1pt);
      line-height: 1;
    }
    .mock-cover-id-number-cell:first-child {
      border-left: 0;
    }
    .mock-cover-info-box {
      margin: 30pt auto 0;
      width: 92.5%;
      border: 0.8pt solid #a2a2a2;
      padding: 12pt 22pt 10pt;
      color: #3b3b3b;
      font-size: calc((var(--stem-size-pt) + 0.45) * 1.3034 * 1pt);
      line-height: 1.962;
    }
    .mock-cover-info-row {
      display: flex;
      align-items: baseline;
      gap: 4.4pt;
    }
    .mock-cover-info-row + .mock-cover-info-row {
      margin-top: 2.8pt;
    }
    .mock-cover-info-bullet {
      flex: 0 0 auto;
      font-size: 1em;
      line-height: 1.35;
      margin-top: 0.12em;
    }
    .mock-cover-info-text {
      flex: 1 1 auto;
      min-width: 0;
    }
    .mock-cover-phrase-box {
      width: 56%;
      margin: 6pt 0 6pt 24pt;
      border: 0.8pt solid #9d9d9d;
      background: #e8e8e8;
      text-align: center;
      padding: 4.4pt 7pt;
      color: #333;
      font-size: calc((var(--stem-size-pt) + 0.2) * 1.3034 * 1pt);
      font-weight: 800;
      -webkit-text-stroke: 0.12pt #333;
      line-height: 1.646;
      white-space: nowrap;
    }
    .mock-cover-subject-box {
      margin: 19.2pt auto 0;
      width: 92.5%;
      border: 0.8pt solid #a2a2a2;
      padding: 9pt 20pt 9pt;
      color: #333;
      font-size: calc((var(--stem-size-pt) + 0.35) * 1.3034 * 1pt);
      line-height: 1.791;
    }
    .mock-cover-subject-head {
      display: flex;
      align-items: center;
      gap: 4pt;
      margin-bottom: 2pt;
      margin-left: -15pt;
      margin-right: -15pt;
      padding: 0 5pt;
      white-space: nowrap;
    }
    .mock-cover-subject-line {
      display: flex;
      align-items: baseline;
      gap: 5pt;
      min-width: 0;
      white-space: nowrap;
    }
    .mock-cover-subject-line + .mock-cover-subject-line {
      margin-top: 2.8pt;
    }
    .mock-cover-subject-indent {
      margin-left: 20pt;
    }
    .mock-cover-subject-item {
      flex: 0 0 auto;
    }
    .mock-cover-subject-item-major {
      font-size: 1.11em;
      font-weight: 800;
      -webkit-text-stroke: 0.1pt #222;
    }
    .mock-cover-subject-item-under {
      margin-left: 1ch;
    }
    .mock-cover-dots {
      flex: 1 1 auto;
      min-width: 24pt;
      border-bottom: 0.8pt dotted #8f8f8f;
      transform: translateY(-2pt);
    }
    .mock-cover-page-range {
      flex: 0 0 auto;
      min-width: 54pt;
      text-align: right;
      white-space: nowrap;
    }
    .mock-cover-bottom-stack {
      margin-top: 25pt;
      width: 100%;
    }
    .mock-cover-warning {
      margin: 0 auto;
      width: 92.5%;
      min-height: 49.4pt;
      border: 0.8pt solid #a2a2a2;
      background: #ededed;
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 0 16pt;
      color: #222;
      font-size: calc((var(--stem-size-pt) + 6.0) * 0.931 * 1pt);
      font-weight: 800;
      -webkit-text-stroke: 0.16pt #222;
      white-space: nowrap;
    }
    .mock-cover-org {
      margin-top: 19.2pt;
      padding-top: 0;
      padding-bottom: 0;
      text-align: center;
      color: #111;
      font-size: calc((var(--stem-size-pt) + 8.4) * 1.62 * 1pt);
      font-weight: 700;
      letter-spacing: -0.01em;
      line-height: 1.05;
      white-space: nowrap;
    }
    .mock-page {
      min-height: ${(paperMm.height - 2 * marginMm).toFixed(1)}mm;
      display: flex;
      flex-direction: column;
      break-inside: avoid;
      overflow: hidden;
    }
    .mock-page.mock-page-title .mock-header-first {
      margin-bottom: 20pt;
    }
    .mock-page-title .mock-header-first-bottom {
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
      font-family: "YggSubject", "YggMain", "HCR Batang", "Malgun Gothic", sans-serif;
      font-size: ${mockFirstSubjectPt}pt;
      font-weight: 900;
      color: #111;
      line-height: 0.9;
      letter-spacing: -0.01em;
      -webkit-text-stroke: 0.3pt #111;
      white-space: nowrap;
    }
    .mock-first-subject,
    .mock-simple-subject {
      display: inline-flex;
      align-items: baseline;
      gap: 0;
    }
    .mock-first-subject .mock-title-main,
    .mock-simple-subject .mock-title-main {
      display: inline-block;
      line-height: 1;
    }
    .mock-first-subject .mock-title-sub,
    .mock-simple-subject .mock-title-sub {
      display: inline-block;
      font-size: 0.9em;
      line-height: 1;
      letter-spacing: 0;
      -webkit-text-stroke: 0.14pt #111;
    }
    .mock-simple-subject {
      font-size: ${mockSimpleSubjectPt}pt;
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
      min-height: 32pt;
      padding: 0 8.2pt;
      border-radius: 4.4pt;
      font-family: "YggSubject", "YggMain", "HCR Batang", "Malgun Gothic", sans-serif;
      font-size: calc((var(--stem-size-pt) + 5.6) * 1pt);
      font-weight: 900;
      -webkit-text-stroke: 0.13pt #111;
      line-height: 1;
    }
    .mock-chip-type-simple {
      min-height: 26.1pt;
      padding: 0 5.0pt;
      border-radius: 3.6pt;
      font-family: "YggSubject", "YggMain", "HCR Batang", "Malgun Gothic", sans-serif;
      font-size: calc((var(--stem-size-pt) + 3.6) * 1pt);
      font-weight: 900;
      -webkit-text-stroke: 0.1pt #111;
      transform: translateY(1.2pt);
    }
    .mock-chip-type-text {
      display: inline-block;
      transform: scaleX(0.95);
      transform-origin: center;
    }
    .mock-chip-type-text-first {
      transform: translateY(1pt) scaleX(0.95);
      transform-origin: center;
    }
    .mock-first-type {
      transform: translateY(5.8pt);
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
      bottom: 3.2pt;
    }
    .mock-page-last .mock-main::before {
      bottom: 5pt;
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
    .mock-section-label-text {
      display: inline-block;
      transform: translateY(0);
    }
    .mock-page-title .question-stream-grid4 .slot-label-overlay .mock-section-label-text {
      transform: translateY(1pt);
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
    .mock-page-with-note .mock-content {
      padding-bottom: calc(var(--page-note-box-height, var(--last-note-box-height)) + 6pt);
    }
    .mock-content .question-stream {
      columns: 2;
      column-gap: calc(var(--column-gap-pt) * 1pt);
      overflow: visible;
      flex: 1 1 auto;
    }
    .mock-page-title .mock-content .question-stream {
      margin-top: -8pt;
    }
    .mock-page-title .question-stream-grid4 .question-slot-firstline {
      height: calc(var(--line-height-pt) * 0.45 * 1pt);
      line-height: calc(var(--line-height-pt) * 0.45 * 1pt);
    }
    .mock-page-title .question-stream-grid4 .question-slot[data-slot-row="1"] .question-slot-firstline {
      height: calc(var(--line-height-pt) * 0.45 * 1pt + 15pt);
      line-height: calc(var(--line-height-pt) * 0.45 * 1pt + 15pt);
    }
    .mock-page-title .question-stream-grid4 .question-slot.slot-r1c2 .question-slot-firstline {
      height: calc(var(--line-height-pt) * 0.45 * 1pt + 11pt);
      line-height: calc(var(--line-height-pt) * 0.45 * 1pt + 11pt);
    }
    .mock-page-title .mock-content .question-stream.question-stream-grid4 {
      row-gap: calc(var(--question-gap-pt) * 0.32 * 1pt);
    }
    .mock-page:not(.mock-page-title) .mock-header-simple {
      margin-bottom: 6.4pt;
    }
    .mock-page:not(.mock-page-title) .mock-content .question-stream {
      margin-top: 0.8pt;
    }
    .mock-page:not(.mock-page-title) .question-stream-grid4 .question-slot-firstline {
      height: calc(var(--line-height-pt) * 0.20 * 1pt);
      line-height: calc(var(--line-height-pt) * 0.20 * 1pt);
    }
    .mock-page:not(.mock-page-title) .question-stream-grid4 .question-slot[data-slot-row="1"] .question-slot-firstline {
      height: calc(var(--line-height-pt) * 0.20 * 1pt + 4.8pt);
      line-height: calc(var(--line-height-pt) * 0.20 * 1pt + 4.8pt);
    }
    .mock-content .question-stream.question-stream-grid4 {
      columns: auto;
      display: grid;
      grid-template-columns: repeat(var(--slot-grid-cols, 2), minmax(0, 1fr));
      grid-template-rows: repeat(var(--slot-grid-rows, 2), minmax(0, 1fr));
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
    .mock-page-note {
      position: absolute;
      right: 0;
      bottom: 5pt;
      width: calc(50% - (var(--column-gap-pt) * 0.5 * 1pt));
      min-height: var(--page-note-box-height, var(--last-note-box-height));
      border: 0.8pt solid #7c7c7c;
      background: #fff;
      color: #111;
      padding: 7.2pt 10pt 8pt;
      font-size: calc((var(--stem-size-pt) - 1.45) * 1pt);
      font-weight: 500;
      line-height: 1.42;
      z-index: 1;
    }
    .mock-page-note.mock-page-note-compact {
      padding: 6.6pt 10pt 7pt;
      line-height: 1.4;
    }
    .mock-page-note.mock-page-note-compact .mock-page-note-title {
      margin-bottom: 4.2pt;
    }
    .mock-page-note-title {
      margin-bottom: 5pt;
      font-weight: 700;
      font-size: 1em;
      line-height: 1.42;
    }
    .mock-page-note-star {
      display: inline-block;
      transform: translateY(0.16em);
    }
    .mock-page-note-row {
      display: flex;
      align-items: flex-start;
      gap: 3.2pt;
    }
    .mock-page-note-row + .mock-page-note-row {
      margin-top: 8pt;
    }
    .mock-page-note-bullet {
      flex: 0 0 auto;
      font-size: 0.7em;
      line-height: 1;
      margin-top: 0.42em;
      transform: none;
    }
    .mock-page-note-text {
      flex: 1 1 auto;
      min-width: 0;
      white-space: normal;
    }
    .mock-page-note-emphasis {
      display: inline-block;
      font-weight: 900;
      font-size: 1.04em;
      -webkit-text-stroke: 0.18pt #111;
      text-shadow:
        0.18pt 0 0 #111,
        -0.18pt 0 0 #111;
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

function computeQuestionVisualScore(question, renderedHtml) {
  const q = question && typeof question === 'object' ? question : {};
  const stemRaw = String(q.stem || '');
  const stemTextLen = stemRaw.replace(/\s+/g, ' ').trim().length;
  const stemBreaks = (stemRaw.match(/\n/g) || []).length;
  const boxCount = (stemRaw.match(/\[박스시작\]/g) || []).length;
  const choices = Array.isArray(q.choices) ? q.choices : [];
  const choiceChars = choices.reduce((sum, one) => {
    return sum + String(one?.text || '').replace(/\s+/g, ' ').trim().length;
  }, 0);
  const figureCount = Array.isArray(q.figure_data_urls)
    ? q.figure_data_urls.length
    : 0;

  const html = String(renderedHtml || '');
  const plain = html
    .replace(/<svg[\s\S]*?<\/svg>/gi, ' ')
    .replace(/<style[\s\S]*?<\/style>/gi, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  const htmlTextLen = plain.length;
  const htmlBreaks = (html.match(/<br\s*\/?>/gi) || []).length;
  const htmlChoiceRows = (html.match(/class="choice\b/g) || []).length;
  const htmlBogiRows = (html.match(/class="bogi-item\b/g) || []).length;

  const scoreFromRaw = stemTextLen
    + Math.round(choiceChars * 0.9)
    + stemBreaks * 26
    + choices.length * 24
    + figureCount * 140
    + boxCount * 90;
  const scoreFromHtml = htmlTextLen
    + htmlBreaks * 24
    + htmlChoiceRows * 20
    + htmlBogiRows * 18;
  return Math.max(scoreFromRaw, scoreFromHtml);
}

function isColumnLongQuestion(question, renderedHtml) {
  const q = question && typeof question === 'object' ? question : {};
  const score = computeQuestionVisualScore(q, renderedHtml);
  const figureCount = Array.isArray(q.figure_data_urls) ? q.figure_data_urls.length : 0;
  const stemBreaks = (String(q.stem || '').match(/\n/g) || []).length;
  if (figureCount >= 2) return score >= 920;
  if (figureCount === 1) return score >= 980;
  if (stemBreaks >= 4) return score >= 900;
  if (stemBreaks >= 2) return score >= 960;
  return score >= 1050;
}

function normalizePageColumnQuestionCounts(raw) {
  if (!Array.isArray(raw)) return [];
  const out = [];
  for (const one of raw) {
    if (!one) continue;
    if (Array.isArray(one) && one.length >= 2) {
      const left = Number.parseInt(String(one[0] ?? ''), 10);
      const right = Number.parseInt(String(one[1] ?? ''), 10);
      if (Number.isFinite(left) && Number.isFinite(right) && left >= 0 && right >= 0) {
        out.push({
          pageIndex: out.length,
          counts: [left, right],
        });
      }
      continue;
    }
    if (typeof one !== 'object') continue;
    const rawPage = Number.parseInt(
      String(
        one.pageIndex
        ?? one.page
        ?? one.pageNo
        ?? one.pageNumber
        ?? '',
      ),
      10,
    );
    const pageIndex = Number.isFinite(rawPage) ? Math.max(0, rawPage - 1) : out.length;
    const left = Number.parseInt(
      String(one.left ?? one.leftCount ?? one.col1 ?? one.l ?? ''),
      10,
    );
    const right = Number.parseInt(
      String(one.right ?? one.rightCount ?? one.col2 ?? one.r ?? ''),
      10,
    );
    if (!Number.isFinite(left) || !Number.isFinite(right)) continue;
    if (left < 0 || right < 0) continue;
    out.push({ pageIndex, counts: [left, right] });
  }
  const dedup = new Map();
  for (const one of out) {
    dedup.set(one.pageIndex, one.counts);
  }
  return [...dedup.entries()]
    .sort((a, b) => a[0] - b[0])
    .map(([pageIndex, counts]) => ({ pageIndex, counts }));
}

function buildQuestionChunks({
  questions,
  renderedQuestions,
  perPage,
  columns,
  pageColumnQuestionCounts,
  autoGuardLongQuestion = false,
}) {
  const safePerPage = Math.max(1, Math.min(99, Number(perPage) || 99));
  const safeColumns = Number(columns || 1) === 2 ? 2 : 1;
  const rendered = Array.isArray(renderedQuestions) ? renderedQuestions : [];
  const sourceQuestions = Array.isArray(questions) ? questions : [];
  if (rendered.length === 0) {
    return {
      chunks: [[]],
      pageColumnCounts: safeColumns === 2 ? [[2, 2]] : [[safePerPage]],
    };
  }
  if (safeColumns !== 2 || safePerPage >= 99) {
    const chunks = [];
    for (let i = 0; i < rendered.length; i += safePerPage) {
      chunks.push(rendered.slice(i, i + safePerPage));
    }
    if (chunks.length === 0) chunks.push([]);
    return {
      chunks,
      pageColumnCounts: chunks.map((chunk) => [chunk.length]),
    };
  }

  const defaultLeft = Math.max(1, Math.ceil(safePerPage / 2));
  const defaultRight = Math.max(0, safePerPage - defaultLeft);
  const overrideMap = new Map();
  for (const one of normalizePageColumnQuestionCounts(pageColumnQuestionCounts)) {
    overrideMap.set(one.pageIndex, one.counts);
  }

  const chunks = [];
  const pageColumnCounts = [];
  let cursor = 0;
  let pageIndex = 0;
  while (cursor < rendered.length) {
    const override = overrideMap.get(pageIndex) || null;
    let leftCap = override ? Number(override[0]) : defaultLeft;
    let rightCap = override ? Number(override[1]) : defaultRight;
    if (!Number.isFinite(leftCap) || leftCap < 0) leftCap = defaultLeft;
    if (!Number.isFinite(rightCap) || rightCap < 0) rightCap = defaultRight;
    if (leftCap + rightCap <= 0) {
      leftCap = 1;
      rightCap = 0;
    }

    // Auto-guard mode: when the top question of a column is very long,
    // reduce that column capacity by 1 to avoid clipping/overlap.
    if (!override && autoGuardLongQuestion && leftCap > 1 && cursor < rendered.length) {
      if (isColumnLongQuestion(sourceQuestions[cursor], rendered[cursor])) {
        leftCap = 1;
      }
    }

    const chunk = [];
    let leftCount = 0;
    for (let i = 0; i < leftCap && cursor < rendered.length; i += 1) {
      chunk.push(rendered[cursor]);
      cursor += 1;
      leftCount += 1;
    }

    if (!override && autoGuardLongQuestion && rightCap > 1 && cursor < rendered.length) {
      if (isColumnLongQuestion(sourceQuestions[cursor], rendered[cursor])) {
        rightCap = 1;
      }
    }

    let rightCount = 0;
    for (let i = 0; i < rightCap && cursor < rendered.length; i += 1) {
      chunk.push(rendered[cursor]);
      cursor += 1;
      rightCount += 1;
    }

    if (chunk.length === 0 && cursor < rendered.length) {
      chunk.push(rendered[cursor]);
      cursor += 1;
      leftCount = 1;
    }

    chunks.push(chunk);
    pageColumnCounts.push([leftCount, rightCount]);
    pageIndex += 1;
  }

  return {
    chunks: chunks.length > 0 ? chunks : [[]],
    pageColumnCounts: pageColumnCounts.length > 0 ? pageColumnCounts : [[defaultLeft, defaultRight]],
  };
}

function normalizeTitlePageIndices(rawIndices, pageCount) {
  const maxPage = Number.isFinite(pageCount)
    ? Math.max(1, Number(pageCount))
    : Number.POSITIVE_INFINITY;
  const out = new Set([1]);
  if (Array.isArray(rawIndices)) {
    for (const one of rawIndices) {
      const parsed = Number.parseInt(String(one ?? ''), 10);
      if (!Number.isFinite(parsed) || parsed < 1) continue;
      if (parsed > maxPage) continue;
      out.add(parsed);
    }
  }
  return [...out].sort((a, b) => a - b);
}

function normalizeTitlePageHeaders(rawHeaders, titlePageIndices, fallbackTitle) {
  const titlePages = normalizeTitlePageIndices(titlePageIndices, Number.POSITIVE_INFINITY);
  const titlePageSet = new Set(titlePages);
  const out = new Map();
  if (Array.isArray(rawHeaders)) {
    for (const one of rawHeaders) {
      if (!one || typeof one !== 'object') continue;
      const page = Number.parseInt(
        String(one.page ?? one.pageIndex ?? one.pageNo ?? one.pageNumber ?? ''),
        10,
      );
      if (!Number.isFinite(page) || page < 1) continue;
      if (!titlePageSet.has(page)) continue;
      const title = String(one.title ?? one.subjectTitleText ?? '')
        .replace(/\s+/g, ' ')
        .trim();
      const subtitle = String(one.subtitle ?? one.subTitle ?? one.sub ?? '')
        .replace(/\s+/g, ' ')
        .trim();
      if (!title && !subtitle) continue;
      out.set(page, {
        page,
        title,
        subtitle,
      });
    }
  }
  const defaultTitle = String(fallbackTitle || '수학 영역')
    .replace(/\s+/g, ' ')
    .trim() || '수학 영역';
  const pageOneTitle = out.get(1)?.title || defaultTitle;
  for (const page of titlePages) {
    const prev = out.get(page);
    out.set(page, {
      page,
      title: String(prev?.title || '').trim() || pageOneTitle,
      subtitle: String(prev?.subtitle || '').replace(/\s+/g, ' ').trim(),
    });
  }
  return [...out.values()].sort((a, b) => a.page - b.page);
}

function normalizeCoverPageTexts(raw) {
  const src = raw && typeof raw === 'object' ? raw : {};
  const fallbackItems = [
    { name: '확률과 통계', pages: '9~12쪽' },
    { name: '미적분', pages: '13~16쪽' },
    { name: '기하', pages: '17~20쪽' },
  ];
  const rawItems = Array.isArray(src.electiveItems) ? src.electiveItems : [];
  const electiveItems = fallbackItems.map((fallback, index) => {
    const row = rawItems[index] && typeof rawItems[index] === 'object'
      ? rawItems[index]
      : {};
    const name = String(row.name || '').replace(/\s+/g, ' ').trim() || fallback.name;
    const pages = String(row.pages || row.pageRange || '').replace(/\s+/g, ' ').trim() || fallback.pages;
    return { name, pages };
  });
  return {
    topTitle:
      String(src.topTitle || '').replace(/\s+/g, ' ').trim() || '2026학년도 대학수학능력시험 문제지',
    subjectTitle:
      String(src.subjectTitle || '').replace(/\s+/g, ' ').trim() || '수학 영역',
    handwritingPhrase:
      String(src.handwritingPhrase || '').replace(/\s+/g, ' ').trim() || '이 많은 별빛이 내린 언덕 위에',
    commonLabel:
      String(src.commonLabel || '').replace(/\s+/g, ' ').trim() || '공통과목',
    electiveLabel:
      String(src.electiveLabel || '').replace(/\s+/g, ' ').trim() || '선택과목',
    electiveItems,
    organization:
      String(src.organization || src.organizationName || '').replace(/\s+/g, ' ').trim() || '한국교육과정평가원',
  };
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
  layoutMeta = null,
}) {
  const isMockStyle = profile === 'mock' || profile === 'csat';
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
    columnGapPt: Number(layout?.columnGapPt || 18) * (isMockStyle ? 1.69 : 1),
    perPage,
  });
  const subjectTitleText = String(layout?.subjectTitleText || '수학 영역')
    .replace(/\s+/g, ' ')
    .trim() || '수학 영역';
  const includeCoverPage = isMockStyle && layout?.includeCoverPage === true;
  const coverPageTexts = normalizeCoverPageTexts(layout?.coverPageTexts);

  const stemSizePt = Number(layout?.stemSizePt || 11.0);
  const allQ = (questions || []).map((q) => renderQuestionBlock(q, mathRenderer, { stemSizePt }));
  const renderStreamSection = (chunk, cls, options = {}) => {
    const pageIndex = Number.isFinite(options?.pageIndex) ? Number(options.pageIndex) : 0;
    const isTitlePage = options?.isTitlePage === true;
    const columnCountsOverride = Array.isArray(options?.columnQuestionCounts)
      ? options.columnQuestionCounts
      : null;
    const perPageForSection = Math.max(
      1,
      Math.min(
        99,
        Number(options?.perPageOverride) || perPage,
      ),
    );
    const slotPlan = buildSlotPlan({
      layoutMode: columnCountsOverride ? 'custom_columns' : (layout?.layoutMode || 'legacy'),
      layoutColumns: columns,
      perPage: perPageForSection,
      chunkLength: chunk.length,
      columnQuestionCounts: columnCountsOverride ?? layout?.columnQuestionCounts,
      columnLabelAnchors: layout?.columnLabelAnchors,
      alignPolicy: layout?.alignPolicy,
      profile,
      pageIndex,
      isTitlePage,
    });
    if (!slotPlan) {
      return `<section class="${cls}">${chunk.join('')}</section>`;
    }
    const sectionStyle = [
      `--slot-grid-cols:${slotPlan.columns}`,
      `--slot-grid-rows:${slotPlan.rowCount}`,
      `grid-template-columns:repeat(${slotPlan.columns}, minmax(0, 1fr))`,
      `grid-template-rows:repeat(${slotPlan.rowCount}, minmax(0, 1fr))`,
    ].join(';');
    const slots = slotPlan.slots.map((slot) => {
      const questionHtml = slot.hasQuestion && Number.isFinite(slot.questionOrder)
        ? (chunk[slot.questionOrder] || '<div class="question-slot-empty">&nbsp;</div>')
        : '<div class="question-slot-empty">&nbsp;</div>';
      const slotClasses = [
        'question-slot',
        `slot-r${slot.row}c${slot.col}`,
        slot.isHiddenPlaceholder ? 'question-slot-hidden' : '',
      ].filter(Boolean).join(' ');
      const slotStyleParts = [
        `grid-row:${slot.row}`,
        `grid-column:${slot.col}`,
      ];
      const columnQuestionCount = Number(
        slotPlan.columnQuestionCounts?.[slot.columnIndex] || 0,
      );
      const isLastQuestionInColumn = slot.expectsQuestion
        && slot.rowIndex === Math.max(0, columnQuestionCount - 1);
      if (
        isLastQuestionInColumn
        && columnQuestionCount > 0
        && columnQuestionCount < slotPlan.rowCount
      ) {
        const spanRows = slotPlan.rowCount - slot.rowIndex;
        if (spanRows > 1) {
          slotStyleParts.push(`grid-row:${slot.row} / span ${spanRows}`);
        }
      }
      if (slot.anchorLabel) {
        slotStyleParts.push(`--slot-label-top:${Number(slot.anchorTopPt || 9.2)}pt`);
        slotStyleParts.push(`--slot-anchor-pad-top:${Number(slot.anchorPaddingTopPt || 35.8)}pt`);
      }
      const firstLine = slot.isHiddenPlaceholder
        ? ''
        : '<div class="question-slot-firstline" aria-hidden="true">&nbsp;</div>';
      const slotBody = slot.anchorLabel && !slot.isHiddenPlaceholder
        ? `<div class="slot-label-overlay"><div class="mock-section-label"><span class="mock-section-label-text">${escapeHtml(slot.anchorLabel)}</span></div></div><div class="slot-anchor-body">${firstLine}${questionHtml}</div>`
        : `${firstLine}${questionHtml}`;
      return `
        <div
          class="${slotClasses}"
          style="${slotStyleParts.join(';')}"
          data-slot-row="${slot.row}"
          data-slot-col="${slot.col}"
          data-slot-index="${slot.slotIndex}"
          data-slot-hidden="${slot.isHiddenPlaceholder ? 1 : 0}"
          data-has-anchor="${slot.anchorLabel ? 1 : 0}"
          data-row-has-anchor="${slot.rowHasAnchor ? 1 : 0}"
        >${slotBody}</div>
      `;
    });
    return `
      <section
        class="${cls} question-stream-grid4 question-stream-slotgrid"
        style="${sectionStyle}"
        data-pair-align="${slotPlan.pairAlignMode}"
        data-skip-anchor-rows="${slotPlan.skipAnchorRows ? 1 : 0}"
      >${slots.join('')}</section>
    `;
  };
  const chunkPlan = buildQuestionChunks({
    questions,
    renderedQuestions: allQ,
    perPage,
    columns,
    pageColumnQuestionCounts: layout?.pageColumnQuestionCounts,
    autoGuardLongQuestion: isMockStyle && columns === 2 && perPage <= 8,
  });
  const questionChunks = chunkPlan.chunks;
  const pageColumnCounts = chunkPlan.pageColumnCounts;
  const titlePageIndices = normalizeTitlePageIndices(
    layout?.titlePageIndices,
    questionChunks.length,
  );
  const titlePageHeaders = normalizeTitlePageHeaders(
    layout?.titlePageHeaders,
    titlePageIndices,
    subjectTitleText,
  );
  const titlePageHeaderMap = new Map(
    titlePageHeaders.map((one) => [Number(one.page || 1), one]),
  );
  const titlePageSet = new Set(titlePageIndices);
  if (layoutMeta && typeof layoutMeta === 'object') {
    layoutMeta.pageColumnQuestionCounts = Array.isArray(pageColumnCounts)
      ? pageColumnCounts.map((counts, idx) => ({
        pageIndex: idx + 1,
        left: Number(counts?.[0] || 0),
        right: Number(counts?.[1] || 0),
      }))
      : [];
    layoutMeta.pageCount = questionChunks.length;
    layoutMeta.titlePageIndices = titlePageIndices;
    layoutMeta.titlePageHeaders = titlePageHeaders;
  }
  let coverHtml = '';
  let questionHtml;
  if (isMockStyle) {
    const totalPages = questionChunks.length;
    const additionalTitlePages = titlePageIndices
      .map((one) => Number.parseInt(String(one ?? ''), 10))
      .filter((one) => Number.isFinite(one) && one > 1 && one <= totalPages);
    const hasAdditionalTitlePages = additionalTitlePages.length > 0;
    const preTitleNoticePages = new Set(
      additionalTitlePages
        .map((one) => one - 1)
        .filter((one) => one >= 1 && one < totalPages),
    );
    const resolveNextTitleSubtitle = (pageNo) => {
      const nextRow = titlePageHeaderMap.get(Number(pageNo || 0) + 1);
      const subtitle = String(nextRow?.subtitle || '')
        .replace(/\s+/g, ' ')
        .trim();
      return subtitle || '확률과 통계';
    };
    const renderNoticeBox = ({ compact = false, electiveSubtitle = '' } = {}) => {
      const safeElectiveSubtitle = escapeHtml(
        String(electiveSubtitle || '').replace(/\s+/g, ' ').trim() || '확률과 통계',
      );
      return `
      <div class="mock-page-note${compact ? ' mock-page-note-compact' : ''}">
        <div class="mock-page-note-title"><span class="mock-page-note-star">*</span> 확인 사항</div>
        <div class="mock-page-note-row">
          <span class="mock-page-note-bullet">○</span>
          <span class="mock-page-note-text">답안지의 해당란에 필요한 내용을 정확히 기입(표기) 했는지 확인하시오.</span>
        </div>
        ${compact
          ? ''
          : `
            <div class="mock-page-note-row">
              <span class="mock-page-note-bullet">○</span>
              <span class="mock-page-note-text">이어서, <span class="mock-page-note-emphasis">「선택과목(${safeElectiveSubtitle})」</span> 문제가 제시되오니, 자신이 선택한 과목인지 확인하시오.</span>
            </div>
          `}
      </div>
    `;
    };
    const renderTitleLine = (pageNo) => {
      const row = titlePageHeaderMap.get(pageNo) || titlePageHeaderMap.get(1);
      const title = escapeHtml(
        String(row?.title || subjectTitleText).replace(/\s+/g, ' ').trim() || '수학 영역',
      );
      const subtitle = escapeHtml(
        String(row?.subtitle || '').replace(/\s+/g, ' ').trim(),
      );
      if (!subtitle) {
        return `<span class="mock-title-main">${title}</span>`;
      }
      return `<span class="mock-title-main">${title}</span><span class="mock-title-sub">(${subtitle})</span>`;
    };
    const renderSimpleTitleLine = () => {
      const row = titlePageHeaderMap.get(1);
      const title = escapeHtml(
        String(row?.title || subjectTitleText).replace(/\s+/g, ' ').trim() || '수학 영역',
      );
      return `<span class="mock-title-main">${title}</span>`;
    };
    const renderCoverSubjectLine = () => {
      const title = escapeHtml(
        String(coverPageTexts.subjectTitle || '수학 영역').replace(/\s+/g, ' ').trim() || '수학 영역',
      );
      return `<span class="mock-cover-subject-main">${title}</span>`;
    };
    const coverElectiveItemLines = (coverPageTexts.electiveItems || []).map((row) => `
      <div class="mock-cover-subject-line mock-cover-subject-indent">
        <span class="mock-cover-subject-item mock-cover-subject-item-major mock-cover-subject-item-under">${escapeHtml(String(row?.name || ''))}</span>
        <span class="mock-cover-dots"></span>
        <span class="mock-cover-page-range">${escapeHtml(String(row?.pages || ''))}</span>
      </div>
    `).join('');
    const renderCoverPages = () => `
      <div class="mock-cover-pages">
        <section class="mock-cover-page">
          <div class="mock-cover-sheet">
            <div class="mock-cover-top-row">
              <span class="mock-cover-chip-left">제 1교시</span>
              <div class="mock-cover-top-title">${escapeHtml(coverPageTexts.topTitle)}</div>
              <span class="mock-cover-top-empty" aria-hidden="true"></span>
            </div>
            <div class="mock-cover-subject-row">
              <span class="mock-cover-top-empty" aria-hidden="true"></span>
              <div class="mock-cover-subject">${renderCoverSubjectLine()}</div>
              <span class="mock-cover-chip-right">홀수형</span>
            </div>
            <div class="mock-cover-id-row">
              <div class="mock-cover-id-box">
                <span class="mock-cover-id-label">성명</span>
                <span class="mock-cover-id-fill"></span>
              </div>
              <div class="mock-cover-id-box">
                <span class="mock-cover-id-label">수험 번호</span>
                <div class="mock-cover-id-number-grid">
                  <span class="mock-cover-id-number-cell"></span>
                  <span class="mock-cover-id-number-cell"></span>
                  <span class="mock-cover-id-number-cell"></span>
                  <span class="mock-cover-id-number-cell"></span>
                  <span class="mock-cover-id-number-cell"></span>
                  <span class="mock-cover-id-number-cell">—</span>
                  <span class="mock-cover-id-number-cell"></span>
                  <span class="mock-cover-id-number-cell"></span>
                  <span class="mock-cover-id-number-cell"></span>
                  <span class="mock-cover-id-number-cell"></span>
                </div>
              </div>
            </div>
            <div class="mock-cover-info-box">
              <div class="mock-cover-info-row">
                <span class="mock-cover-info-bullet">○</span>
                <span class="mock-cover-info-text">문제지의 해당란에 성명과 수험 번호를 정확히 쓰시오.</span>
              </div>
              <div class="mock-cover-info-row">
                <span class="mock-cover-info-bullet">○</span>
                <span class="mock-cover-info-text">답안지의 필적 확인란에 다음의 문구를 정자로 기재하시오.</span>
              </div>
              <div class="mock-cover-phrase-box">${escapeHtml(coverPageTexts.handwritingPhrase)}</div>
              <div class="mock-cover-info-row">
                <span class="mock-cover-info-bullet">○</span>
                <span class="mock-cover-info-text">답안지의 해당란에 성명과 수험 번호를 쓰고, 또 수험 번호,<br/>문형(홀수/짝수), 답을 정확히 표시하시오.</span>
              </div>
              <div class="mock-cover-info-row">
                <span class="mock-cover-info-bullet">○</span>
                <span class="mock-cover-info-text">단답형 답의 숫자에 '0'이 포함되면 그 '0'도 답란에 반드시 표시하시오.</span>
              </div>
              <div class="mock-cover-info-row">
                <span class="mock-cover-info-bullet">○</span>
                <span class="mock-cover-info-text">문항에 따라 배점이 다르니, 각 물음의 끝에 표시된 배점을 참고하시오. 배점은 2점, 3점 또는 4점입니다.</span>
              </div>
              <div class="mock-cover-info-row">
                <span class="mock-cover-info-bullet">○</span>
                <span class="mock-cover-info-text">계산은 문제지의 여백을 활용하시오.</span>
              </div>
            </div>
            <div class="mock-cover-subject-box">
              <div class="mock-cover-subject-head">
                <span>※</span>
                <span>공통과목 및 자신이 선택한 과목의 문제지를 확인하고, 답을 정확히 표시하시오.</span>
              </div>
              <div class="mock-cover-subject-line">
                <span class="mock-cover-subject-item mock-cover-subject-item-major">○ ${escapeHtml(coverPageTexts.commonLabel)}</span>
                <span class="mock-cover-dots"></span>
                <span class="mock-cover-page-range">1~12쪽</span>
              </div>
              <div class="mock-cover-subject-line">
                <span class="mock-cover-subject-item mock-cover-subject-item-major">○ ${escapeHtml(coverPageTexts.electiveLabel)}</span>
              </div>
              ${coverElectiveItemLines}
            </div>
            <div class="mock-cover-bottom-stack">
              <div class="mock-cover-warning">※ 시험이 시작되기 전까지 표지를 넘기지 마시오.</div>
              <div class="mock-cover-org">${escapeHtml(coverPageTexts.organization)}</div>
            </div>
          </div>
        </section>
        <section class="mock-cover-blank page-break"></section>
      </div>
    `;
    const renderMockHeader = (pageNo, isTitlePage) => {
      if (isTitlePage) {
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
              <div class="mock-first-subject">${renderTitleLine(pageNo)}</div>
              <div class="mock-side-right">
                <span class="mock-chip mock-chip-type mock-first-type"><span class="mock-chip-type-text mock-chip-type-text-first">홀수형</span></span>
              </div>
            </div>
          </header>
        `;
      }
      const even = pageNo % 2 === 0;
      const left = even
        ? `<span class="mock-page-no">${pageNo}</span>`
        : '<span class="mock-chip mock-chip-type mock-chip-type-simple"><span class="mock-chip-type-text">홀수형</span></span>';
      const right = even
        ? '<span class="mock-chip mock-chip-type mock-chip-type-simple"><span class="mock-chip-type-text">홀수형</span></span>'
        : `<span class="mock-page-no">${pageNo}</span>`;
      return `
        <header class="mock-header-simple">
          <div class="mock-side-left">${left}</div>
          <div class="mock-simple-subject">${renderSimpleTitleLine()}</div>
          <div class="mock-side-right">${right}</div>
        </header>
      `;
    };
    coverHtml = includeCoverPage ? renderCoverPages() : '';
    questionHtml = `<div class="mock-pages">${questionChunks.map((chunk, idx) => {
      const pageNo = idx + 1;
      const isTitlePage = titlePageSet.has(pageNo);
      const pageBreak = idx === 0 ? '' : ' page-break';
      const firstClass = idx === 0 ? ' mock-page-first' : '';
      const titleClass = isTitlePage ? ' mock-page-title' : '';
      const lastClass = idx === totalPages - 1 ? ' mock-page-last' : '';
      const onePageCounts = columns === 2 && Array.isArray(pageColumnCounts[idx])
        ? pageColumnCounts[idx]
        : null;
      const pagePerPage = onePageCounts
        ? onePageCounts.reduce((sum, one) => sum + (Number(one) || 0), 0)
        : perPage;
      const contentHtml = renderStreamSection(chunk, 'question-stream', {
        pageIndex: idx,
        columnQuestionCounts: onePageCounts,
        perPageOverride: pagePerPage,
        isTitlePage,
      });
      const isLastPage = idx === totalPages - 1;
      const noticeMode = isLastPage
        ? 'compact'
        : ((hasAdditionalTitlePages && preTitleNoticePages.has(pageNo))
          ? 'full'
          : 'none');
      const pageNoteHtml = noticeMode === 'none'
        ? ''
        : renderNoticeBox({
          compact: noticeMode === 'compact',
          electiveSubtitle: noticeMode === 'full'
            ? resolveNextTitleSubtitle(pageNo)
            : '',
        });
      const pageHasNote = noticeMode !== 'none';
      const noteClass = pageHasNote ? ' mock-page-with-note' : '';
      const noteBoxHeightPt = noticeMode === 'compact' ? 58 : 88;
      const sectionStyle = pageHasNote
        ? ` style="--page-note-box-height:${noteBoxHeightPt}pt;"`
        : '';
      return `
        <section class="mock-page${firstClass}${titleClass}${lastClass}${noteClass}${pageBreak}"${sectionStyle}>
          ${renderMockHeader(pageNo, isTitlePage)}
          <div class="mock-main">
            <div class="mock-content">${contentHtml}</div>
            ${pageNoteHtml}
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
    const onePageCounts = columns === 2 && Array.isArray(pageColumnCounts[0])
      ? pageColumnCounts[0]
      : null;
    const onePagePerPage = onePageCounts
      ? onePageCounts.reduce((sum, one) => sum + (Number(one) || 0), 0)
      : perPage;
    questionHtml = renderStreamSection(questionChunks[0], 'question-stream', {
      pageIndex: 0,
      columnQuestionCounts: onePageCounts,
      perPageOverride: onePagePerPage,
    });
  } else {
    questionHtml = questionChunks
      .map((chunk, idx) => renderStreamSection(
        chunk,
        idx === 0 ? 'question-stream' : 'question-stream page-break',
        {
          pageIndex: idx,
          columnQuestionCounts: columns === 2 && Array.isArray(pageColumnCounts[idx])
            ? pageColumnCounts[idx]
            : null,
          perPageOverride: columns === 2 && Array.isArray(pageColumnCounts[idx])
            ? pageColumnCounts[idx].reduce((sum, one) => sum + (Number(one) || 0), 0)
            : perPage,
        },
      ))
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
        ${coverHtml}
        ${questionHtml}
        ${answerSheetHtml}
        ${explanationHtml}
      </body>
    </html>
  `;
}
