import { renderQuestionBlock } from './components/question_block.js';

function buildPreviewStyles({ stemSizePt, lineHeightPt, choiceGapPt }) {
  return `
    :root {
      --stem-size-pt: ${stemSizePt};
      --line-height-pt: ${lineHeightPt};
      --choice-gap-pt: ${choiceGapPt};
      --lc-line-normal: calc(var(--line-height-pt) * 1pt);
      --lc-line-fraction: calc((var(--line-height-pt) + 2.2) * 1pt);
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      padding: 8pt;
      font-family: "YggMain", "HCR Batang", "Malgun Gothic", serif;
      font-size: calc(var(--stem-size-pt) * 1pt);
      font-weight: 300;
      font-synthesis: none;
      line-height: calc(var(--line-height-pt) * 1pt);
      word-spacing: 0.15em;
      color: #111;
      background: #fff;
    }
    .question {
      overflow: visible;
      padding-left: 0 !important;
      text-indent: 0 !important;
    }
    .q-num { display: none; }
    .q-stem { white-space: normal; }
    .lc-line {
      display: inline;
      line-height: var(--lc-line-normal);
      -webkit-box-decoration-break: clone;
      box-decoration-break: clone;
    }
    .lc-line.lc-fraction { line-height: var(--lc-line-fraction); }
    .debug-first { display: inline; position: relative; }
    .bogi-box, .figure-container, .choice-list, .choice-grid-row1, .choice-grid-row2 {
      text-indent: 0;
    }
    .choice-list {
      margin-top: calc(var(--line-height-pt) * 0.3 * 1pt);
      display: grid;
      grid-template-columns: 1fr;
      row-gap: calc(var(--choice-gap-pt) * 1pt);
    }
    .choice-list.has-fraction { row-gap: calc((var(--choice-gap-pt) + 1) * 1pt); }
    .choice {
      display: inline-flex;
      align-items: center;
      gap: 4.5pt;
      min-width: 0;
      overflow: visible;
    }
    .choice .math-inline { transform: translateY(-1pt); }
    .choice-label { white-space: nowrap; flex-shrink: 0; }
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
    .math-inline svg { display: block; overflow: visible; }
    .math-inline.fraction {
      vertical-align: middle;
      padding-top: calc(var(--line-height-pt) * 0.25 * 1pt);
      padding-bottom: calc(var(--line-height-pt) * 0.25 * 1pt);
    }
    .bogi-box {
      margin-top: calc(var(--line-height-pt) * 0.8 * 1pt);
      margin-bottom: 8pt;
      border: 0.15pt solid #333;
      padding: 10pt 12pt 8pt;
      position: relative;
    }
    .bogi-title {
      position: absolute;
      top: -0.55em;
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
    }
    .bogi-bracket { display: block; flex-shrink: 0; }
    .bogi-title-text { letter-spacing: 0.25em; margin-right: -0.25em; }
    .bogi-content { padding-top: 4pt; }
    .bogi-item {
      display: grid;
      grid-template-columns: auto 1fr;
      column-gap: 3pt;
      margin-bottom: 2pt;
    }
    .bogi-item-label { white-space: nowrap; font-weight: 400; }
    .bogi-item-text { min-width: 0; }
    .figure-container { margin: 6pt 0; text-align: center; }
    .figure-img { max-width: 100%; height: auto; }
    .figure-placeholder {
      margin: 6pt 0; padding: 8pt;
      border: 0.3pt solid #bbb; border-radius: 2pt;
      color: #555; font-size: calc((var(--stem-size-pt) - 0.6) * 1pt);
      text-align: center;
    }
  `;
}

export function buildPreviewHtml({ question, mathRenderer, fontFaceCss = '', layout = {} }) {
  const stemSizePt = Number(layout.stemSizePt || 11.0);
  const lineHeightPt = Number(layout.lineHeightPt || 15.0);
  const choiceGapPt = Number(layout.choiceGapPt || 2);

  const qHtml = renderQuestionBlock(question, mathRenderer);
  const styles = buildPreviewStyles({ stemSizePt, lineHeightPt, choiceGapPt });

  return `<!doctype html>
<html lang="ko">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <style>${fontFaceCss}</style>
  <style>${styles}</style>
</head>
<body>${qHtml}</body>
</html>`;
}
