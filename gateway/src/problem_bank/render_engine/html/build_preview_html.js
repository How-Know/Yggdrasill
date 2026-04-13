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
    article.question {
      overflow: visible;
      padding-left: 0 !important;
      text-indent: 0 !important;
    }
    .q-num { display: none; }
    .q-stem { white-space: normal; text-indent: 0 !important; }
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
    .bogi-content { padding-top: 4pt; position: relative; z-index: 1; }
    .bogi-item {
      display: grid;
      grid-template-columns: auto 1fr;
      column-gap: 3pt;
      margin-bottom: 2pt;
    }
    .bogi-item-label { white-space: nowrap; font-weight: 400; }
    .bogi-item-text { min-width: 0; }
    .bogi-line { margin-bottom: 2pt; }
    .bogi-line:last-child { margin-bottom: 0; }
    .bogi-line.bogi-line-center { text-align: center; }
    .figure-container { margin: 6pt 0; text-align: center; }
    .figure-img { max-width: 100%; height: auto; display: block; }
    .figure-anchor-center { text-align: center; }
    .figure-anchor-center .figure-img { margin: 0 auto; }
    .figure-anchor-left { text-align: left; }
    .figure-anchor-right { text-align: right; }
    .figure-anchor-right .figure-img { margin-left: auto; }
    .figure-anchor-top { text-align: center; }
    .figure-anchor-top .figure-img { margin: 0 auto; }
    .figure-pos-inline-right { float: right; margin: 0 0 0.5em 0.5em; clear: right; }
    .figure-pos-inline-left { float: left; margin: 0 0.5em 0.5em 0; clear: left; }
    .figure-group-horizontal {
      display: flex; flex-wrap: wrap; justify-content: center;
      align-items: flex-start; margin: 6pt 0;
    }
    .figure-layout-item { flex-shrink: 0; }
    .figure-layout-item .figure-img { width: 100%; }
    .figure-inline-block { display: block; text-align: center; margin: 6pt 0; text-indent: 0; }
    .figure-inline-block .figure-img { max-width: 100%; height: auto; }
    .figure-inline-block.figure-anchor-left { text-align: left; }
    .figure-inline-block.figure-anchor-right { text-align: right; }
    .figure-inline-block.figure-group-horizontal { display: flex; flex-wrap: wrap; justify-content: center; align-items: flex-start; }
    .figure-inline-block.figure-group-horizontal .figure-layout-item { flex-shrink: 0; }
    .figure-inline-block.figure-group-horizontal .figure-layout-item .figure-img { width: 100%; }
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

  const qHtml = renderQuestionBlock(question, mathRenderer, { stemSizePt });
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
