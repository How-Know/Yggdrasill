import { composeLineV1, composeLinesV1 } from '../line_composer.js';
import { renderChoiceItem, chooseLayout, renderChoiceContainer } from './choice_block.js';
import {
  escapeHtml,
  splitStemByNewline,
} from '../../utils/text.js';
import { resolveFigureLayout } from '../../utils/figure_layout.js';

const STRUCTURAL_STRIP = /\[(문단)\]/g;
const BOX_START = /\[박스시작\]/;
const BOX_END = /\[박스끝\]/;
const BOGI_RE = /<\s*보\s*기\s*>/;
const FIGURE_MARKER_RE = /\[(?:그림|도형|도표|표)\]/g;
const BOGI_ITEM_SPLIT_RE = /(?=([ㄱ-ㅎ])\.\s)/;
const BOGI_ITEM_RE = /^([ㄱ-ㅎ])\.\s*/;

function cleanLine(line) {
  return line
    .replace(STRUCTURAL_STRIP, ' ')
    .replace(BOX_START, '')
    .replace(BOX_END, '')
    .replace(FIGURE_MARKER_RE, '')
    .replace(/\s+/g, ' ')
    .trim();
}

/**
 * Replace [그림]/[도형]/[도표]/[표] markers with {{FIG_N}} placeholders.
 * Returns { text, count } where count is the number of markers replaced
 * starting from `startIndex`.
 */
function replaceMarkersWithPlaceholders(line, startIndex) {
  let idx = startIndex;
  const text = line.replace(FIGURE_MARKER_RE, () => `{{FIG_${idx++}}}`);
  return { text, count: idx - startIndex };
}

function buildSingleFigureHtml(url, layoutItem) {
  if (!url) return '';
  const w = layoutItem?.widthEm;
  const anchor = layoutItem?.anchor || 'center';
  const position = layoutItem?.position || 'below-stem';
  const posClass = `figure-pos-${position}`;
  const anchorClass = `figure-anchor-${anchor}`;
  const widthStyle = w ? `width:${w}em;max-width:100%;` : 'max-width:100%;';
  return `<div class="figure-inline-block ${posClass} ${anchorClass}">`
    + `<img class="figure-img" src="${url}" style="${widthStyle}" />`
    + `</div>`;
}

function buildGroupFigureHtml(members, dataUrls, layoutItems, gapEm) {
  const innerHtml = members
    .map((idx) => {
      const url = dataUrls[idx];
      if (!url) return '';
      const item = layoutItems ? layoutItems[idx] : null;
      const w = item?.widthEm;
      const style = w ? `flex:0 0 ${w}em;max-width:${w}em;` : '';
      return `<div class="figure-layout-item" style="${style}">`
        + `<img class="figure-img" src="${url}" />`
        + `</div>`;
    })
    .join('');
  return `<div class="figure-inline-block figure-group-horizontal" style="gap:${gapEm}em;">${innerHtml}</div>`;
}

function replacePlaceholdersWithImages(html, dataUrls, layoutItems, figureLayout) {
  const groups = figureLayout?.groups || [];
  const indexToGroup = new Map();
  for (const group of groups) {
    if (group.type !== 'horizontal') continue;
    const memberIndices = [];
    for (const memberKey of group.members) {
      const idx = layoutItems.findIndex((it) => it.assetKey === memberKey);
      if (idx >= 0) memberIndices.push(idx);
    }
    if (memberIndices.length >= 2) {
      for (const idx of memberIndices) {
        indexToGroup.set(idx, { indices: memberIndices, gap: group.gap ?? 0.5 });
      }
    }
  }

  const rendered = new Set();
  return html.replace(/\{\{FIG_(\d+)\}\}/g, (_, numStr) => {
    const idx = parseInt(numStr, 10);
    if (rendered.has(idx)) return '';
    rendered.add(idx);

    const groupInfo = indexToGroup.get(idx);
    if (groupInfo && idx === groupInfo.indices[0]) {
      groupInfo.indices.forEach((i) => rendered.add(i));
      return buildGroupFigureHtml(groupInfo.indices, dataUrls, layoutItems, groupInfo.gap);
    }
    if (groupInfo) return '';

    const url = dataUrls[idx];
    if (!url) return '';
    const item = layoutItems ? layoutItems[idx] : null;
    return buildSingleFigureHtml(url, item);
  });
}

function renderOneLine(text, mathRenderer, equations) {
  if (!text) return null;
  const rendered = composeLineV1(text, mathRenderer, equations);
  return {
    html: rendered.html,
    hasFraction: rendered.hasFraction,
  };
}

function splitBogiItemsFromText(text) {
  const cleaned = text.replace(BOGI_RE, '').trim();
  if (!cleaned) return [];
  const parts = cleaned.split(BOGI_ITEM_SPLIT_RE).filter(Boolean);
  const items = [];
  for (let i = 0; i < parts.length; i++) {
    const part = parts[i].trim();
    if (!part) continue;
    if (/^[ㄱ-ㅎ]$/.test(part) && i + 1 < parts.length) continue;
    items.push(part);
  }
  return items;
}

function renderBogiItems(lines, mathRenderer, equations) {
  const allParts = [];
  let hasFraction = false;
  for (const line of lines) {
    const items = splitBogiItemsFromText(line);
    if (items.length > 0) {
      allParts.push(...items);
    } else {
      const clean = line.replace(BOGI_RE, '').trim();
      if (clean) allParts.push(clean);
    }
  }

  const result = [];
  for (const part of allParts) {
    const match = part.match(BOGI_ITEM_RE);
    if (match) {
      const label = match[1];
      const text = part.slice(match[0].length).trim();
      const rendered = composeLineV1(text, mathRenderer, equations);
      if (rendered.hasFraction) hasFraction = true;
      result.push(
        `<div class="bogi-item"><span class="bogi-item-label">${escapeHtml(label)}.</span><span class="bogi-item-text">${rendered.html}</span></div>`,
      );
    } else {
      const r = renderOneLine(part, mathRenderer, equations);
      if (r) {
        if (r.hasFraction) hasFraction = true;
        result.push(r.html);
      }
    }
  }
  return {
    html: result.join(''),
    hasFraction,
  };
}

function countFigureMarkers(stem) {
  const m = stem.match(FIGURE_MARKER_RE);
  return m ? m.length : 0;
}

function cleanLineKeepingPlaceholders(line) {
  return line
    .replace(STRUCTURAL_STRIP, ' ')
    .replace(BOX_START, '')
    .replace(BOX_END, '')
    .replace(/\s+/g, ' ')
    .trim();
}

function renderStemWithBoxes(stem, mathRenderer, equations, { dataUrls = [], layoutItems = [], figureLayout = null } = {}) {
  const totalMarkers = countFigureMarkers(stem);
  const hasInlineFigures = totalMarkers > 0 && dataUrls.length > 0;

  const lines = splitStemByNewline(stem);
  const blocks = [];
  let hasFraction = false;
  let inBox = false;
  let boxLines = [];
  let inlineBuffer = [];
  let figureCounter = 0;

  const prepareLine = (rawLine) => {
    if (hasInlineFigures) {
      let line = rawLine
        .replace(STRUCTURAL_STRIP, ' ')
        .replace(BOX_START, '')
        .replace(BOX_END, '');
      const result = replaceMarkersWithPlaceholders(line, figureCounter);
      figureCounter += result.count;
      return result.text.replace(/\s+/g, ' ').trim();
    }
    return cleanLine(rawLine);
  };

  const flushInline = () => {
    if (inlineBuffer.length === 0) return;
    const composed = composeLinesV1(inlineBuffer, mathRenderer, equations);
    if (!composed.html) {
      inlineBuffer = [];
      return;
    }
    if (composed.hasFraction) hasFraction = true;
    blocks.push({ type: 'inline', html: composed.html });
    inlineBuffer = [];
  };

  const flushBox = () => {
    if (boxLines.length === 0) return;
    flushInline();
    const hasBogi = boxLines.some((l) => BOGI_RE.test(l));
    const boxSvg = '<svg class="bogi-box-border" viewBox="0 0 100 100" preserveAspectRatio="none" aria-hidden="true"><rect x="0.5" y="0.5" width="99" height="99" fill="none" stroke="#333" stroke-width="0.5" vector-effect="non-scaling-stroke" shape-rendering="geometricPrecision"/></svg>';
    const bogiSvgLeft = '<svg class="bogi-bracket" viewBox="0 0 7 14" width="0.55em" height="1.05em"><path d="M7 0 L0 7 L7 14" fill="none" stroke="#333" stroke-width="0.35"/></svg>';
    const bogiSvgRight = '<svg class="bogi-bracket" viewBox="0 0 7 14" width="0.55em" height="1.05em"><path d="M0 0 L7 7 L0 14" fill="none" stroke="#333" stroke-width="0.35"/></svg>';
    const title = hasBogi
      ? `<div class="bogi-title">${bogiSvgLeft}<span class="bogi-title-text">보 기</span>${bogiSvgRight}</div>`
      : '';
    const inner = renderBogiItems(boxLines, mathRenderer, equations);
    if (inner.hasFraction) hasFraction = true;
    const innerHtml = inner.html;
    if (innerHtml) {
      blocks.push({
        type: 'block',
        html: `<div class="bogi-box">${boxSvg}${title}<div class="bogi-content">${innerHtml}</div></div>`,
      });
    }
    boxLines = [];
  };

  for (const rawLine of lines) {
    const hasStart = BOX_START.test(rawLine);
    const hasEnd = BOX_END.test(rawLine);

    if (hasEnd && !inBox && !hasStart) {
      const clean = prepareLine(rawLine);
      if (!clean) continue;
      inlineBuffer.push(clean);
      continue;
    }

    if (hasStart && !inBox) {
      inBox = true;
      const clean = prepareLine(rawLine);
      if (clean) boxLines.push(clean);
      if (hasEnd) { inBox = false; flushBox(); }
      continue;
    }
    if (inBox) {
      const clean = prepareLine(rawLine);
      if (clean) boxLines.push(clean);
      if (hasEnd) { inBox = false; flushBox(); }
      continue;
    }

    const clean = prepareLine(rawLine);
    if (!clean) continue;
    inlineBuffer.push(clean);
  }
  flushBox();
  flushInline();

  let stemHtml = blocks.map((b) => b.html).join('');
  const inlineCount = hasInlineFigures ? Math.min(figureCounter, dataUrls.length) : 0;

  if (inlineCount > 0) {
    stemHtml = replacePlaceholdersWithImages(stemHtml, dataUrls, layoutItems, figureLayout);
  }

  return { stemHtml, hasFraction, inlineCount };
}

function renderFigures(question, { stemSizePt = 11, skipCount = 0 } = {}) {
  const dataUrls = Array.isArray(question?.figure_data_urls) ? question.figure_data_urls : [];
  if (dataUrls.length === 0) return '';

  const remainingUrls = skipCount > 0 ? dataUrls.slice(skipCount) : dataUrls;
  if (remainingUrls.length === 0) return '';

  const layout = resolveFigureLayout(question, stemSizePt);
  if (!layout || layout.items.length === 0) {
    return remainingUrls
      .map((url) => `<div class="figure-container"><img class="figure-img" src="${url}" /></div>`)
      .join('');
  }

  const remainingItems = skipCount > 0 ? layout.items.slice(skipCount) : layout.items;

  const urlByKey = new Map();
  remainingItems.forEach((item, i) => {
    const url = remainingUrls[i];
    if (url) urlByKey.set(item.assetKey, { url, item });
  });

  const skippedKeys = new Set(layout.items.slice(0, skipCount).map((it) => it.assetKey));

  const grouped = new Set();
  const parts = [];

  for (const group of layout.groups) {
    if (group.type !== 'horizontal') continue;
    const memberEntries = group.members
      .filter((key) => !skippedKeys.has(key))
      .map((key) => urlByKey.get(key))
      .filter(Boolean);
    if (memberEntries.length < 2) continue;
    memberEntries.forEach((e) => grouped.add(e.item.assetKey));
    const gapEm = Number.isFinite(group.gap) ? group.gap : 0.5;
    const innerHtml = memberEntries
      .map((e) => {
        const w = e.item.widthEm;
        return `<div class="figure-layout-item" style="flex:0 0 ${w}em;max-width:${w}em;">`
          + `<img class="figure-img" src="${e.url}" />`
          + `</div>`;
      })
      .join('');
    parts.push(
      `<div class="figure-group-horizontal" style="gap:${gapEm}em;">${innerHtml}</div>`,
    );
  }

  for (const [key, entry] of urlByKey) {
    if (grouped.has(key)) continue;
    const { url, item } = entry;
    const posClass = `figure-pos-${item.position}`;
    const anchorClass = `figure-anchor-${item.anchor}`;
    const widthStyle = `width:${item.widthEm}em;max-width:100%;`;
    parts.push(
      `<div class="figure-container ${posClass} ${anchorClass}">`
      + `<img class="figure-img" src="${url}" style="${widthStyle}" />`
      + `</div>`,
    );
  }

  return parts.join('');
}

function numIndentEm(numStr) {
  const digits = numStr.replace(/\D/g, '').length;
  if (digits <= 1) return '0.70';
  return '1.10';
}

function resolveQuestionScore(question, scoreMapByQuestionId) {
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

function appendScoreToStemHtml(
  stemHtml,
  scoreHtml,
  { preferBeforeTrailingFigure = false } = {},
) {
  function findMatchingDivEnd(source, openIdx) {
    const tagRe = /<\/?div\b[^>]*>/gi;
    tagRe.lastIndex = openIdx;
    let depth = 0;
    let sawOpen = false;
    let match = tagRe.exec(source);
    while (match) {
      const token = String(match[0] || '');
      const isClose = /^<\//.test(token);
      if (isClose) {
        if (sawOpen) depth -= 1;
      } else {
        depth += 1;
        sawOpen = true;
      }
      if (sawOpen && depth === 0) return tagRe.lastIndex;
      match = tagRe.exec(source);
    }
    return -1;
  }

  function findTrailingDivContainerStart(source, marker) {
    const start = source.lastIndexOf(marker);
    if (start < 0) return -1;
    const end = findMatchingDivEnd(source, start);
    if (end < 0) return -1;
    if (source.slice(end).trim().length > 0) return -1;
    return start;
  }

  function findTrailingTableStart(source) {
    const start = source.lastIndexOf('<table');
    if (start < 0) return -1;
    const closeIdx = source.indexOf('</table>', start);
    if (closeIdx < 0) return -1;
    const end = closeIdx + '</table>'.length;
    if (source.slice(end).trim().length > 0) return -1;
    return start;
  }

  const base = String(stemHtml || '');
  const score = String(scoreHtml || '');
  if (!base.trim()) return score;
  if (preferBeforeTrailingFigure) {
    // 보기/박스가 포함된 문제는 점수를 박스 내부가 아니라 박스 앞에 붙인다.
    const lastBogiBoxStart = base.lastIndexOf('<div class="bogi-box');
    if (lastBogiBoxStart >= 0) {
      return `${base.slice(0, lastBogiBoxStart)}&nbsp;${score}${base.slice(lastBogiBoxStart)}`;
    }

    // Case 1) Stem ends with block-like containers such as 보기 박스/그림/표.
    // Score should be attached to statement text, so place it before these blocks.
    const trailingMarkers = [
      '<div class="figure-container',
      '<div class="figure-inline-block',
      '<div class="figure-group-horizontal',
    ];
    for (const marker of trailingMarkers) {
      const start = findTrailingDivContainerStart(base, marker);
      if (start >= 0) {
        return `${base.slice(0, start)}&nbsp;${score}${base.slice(start)}`;
      }
    }
    const tableStart = findTrailingTableStart(base);
    if (tableStart >= 0) {
      return `${base.slice(0, tableStart)}&nbsp;${score}${base.slice(tableStart)}`;
    }

    // Case 2) Inline line ends with figure block(s) inside `.lc-line`.
    // Insert score before the trailing figure block, not after it.
    const trailingInlineLineFigureRe =
      /(<span class="lc-line[^"]*"[^>]*>[\s\S]*?)(<div class="figure-inline-block[\s\S]*<\/div>)(\s*<\/span>\s*)$/;
    if (trailingInlineLineFigureRe.test(base)) {
      return base.replace(trailingInlineLineFigureRe, `$1&nbsp;${score}$2$3`);
    }
  }
  return `${base}&nbsp;${score}`;
}

export function renderQuestionBlock(
  question,
  mathRenderer,
  {
    stemSizePt = 11,
    includeQuestionScore = false,
    questionScoreByQuestionId = {},
  } = {},
) {
  const number = String(question?.question_number || '?');
  const equations = Array.isArray(question?.equations) ? question.equations : [];
  const dataUrls = Array.isArray(question?.figure_data_urls) ? question.figure_data_urls : [];

  const figureLayout = resolveFigureLayout(question, stemSizePt);
  const layoutItems = figureLayout ? figureLayout.items : [];

  const stem = renderStemWithBoxes(question?.stem || '', mathRenderer, equations, {
    dataUrls,
    layoutItems,
    figureLayout,
  });

  const choices = Array.isArray(question?.choices) ? question.choices : [];
  let choiceHtml = '';
  if (choices.length > 0) {
    const items = choices.map((ch) => renderChoiceItem(ch, mathRenderer, equations));
    const layout = chooseLayout(items);
    choiceHtml = renderChoiceContainer(items, layout);
  }

  const inlineCount = stem.inlineCount || 0;
  const figureHtml = renderFigures(question, { stemSizePt, skipCount: inlineCount });

  const hasFraction = stem.hasFraction || choiceHtml.includes('has-fraction');
  const questionClass = hasFraction ? 'question has-fraction' : 'question';
  const indent = numIndentEm(number);
  const scoreSuffix = includeQuestionScore
    ? `<span class="q-score">[${escapeHtml(formatQuestionScore(
      resolveQuestionScore(question, questionScoreByQuestionId),
    ))}점]</span>`
    : '';
  const stemRawHtml = String(stem.stemHtml || '');
  const hasTrailingContainerLikeContent =
    /<div class="(?:bogi-box|figure-inline-block|figure-group-horizontal|figure-container)[^"]*"|<table[\s>]/.test(stemRawHtml);
  const hasFigureLikeContent =
    hasTrailingContainerLikeContent
    || inlineCount > 0
    || String(figureHtml || '').trim().length > 0;
  const stemHtml = scoreSuffix
    ? appendScoreToStemHtml(stemRawHtml, scoreSuffix, {
      preferBeforeTrailingFigure: hasFigureLikeContent,
    })
    : stemRawHtml;

  return `
    <article class="${questionClass}" style="padding-left:${indent}em;text-indent:-${indent}em;">
      <div class="q-stem"><span class="q-num">${escapeHtml(number)}.</span> ${stemHtml}</div>
      ${figureHtml}
      ${choiceHtml}
    </article>
  `;
}
