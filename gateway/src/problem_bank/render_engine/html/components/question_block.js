import { composeLineV1, composeLinesV1 } from '../line_composer.js';
import { renderChoiceItem, chooseLayout, renderChoiceContainer } from './choice_block.js';
import {
  escapeHtml,
  splitStemByNewline,
} from '../../utils/text.js';

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

function renderStemWithBoxes(stem, mathRenderer, equations) {
  const lines = splitStemByNewline(stem);
  const blocks = [];
  let hasFraction = false;
  let inBox = false;
  let boxLines = [];
  let inlineBuffer = [];

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
        html: `<div class="bogi-box">${title}<div class="bogi-content">${innerHtml}</div></div>`,
      });
    }
    boxLines = [];
  };

  for (const rawLine of lines) {
    const hasStart = BOX_START.test(rawLine);
    const hasEnd = BOX_END.test(rawLine);

    if (hasEnd && !inBox && !hasStart) {
      const clean = cleanLine(rawLine);
      if (!clean) continue;
      inlineBuffer.push(clean);
      continue;
    }

    if (hasStart && !inBox) {
      inBox = true;
      const clean = cleanLine(rawLine);
      if (clean) boxLines.push(clean);
      if (hasEnd) { inBox = false; flushBox(); }
      continue;
    }
    if (inBox) {
      const clean = cleanLine(rawLine);
      if (clean) boxLines.push(clean);
      if (hasEnd) { inBox = false; flushBox(); }
      continue;
    }

    const clean = cleanLine(rawLine);
    if (!clean) continue;
    inlineBuffer.push(clean);
  }
  flushBox();
  flushInline();

  return { stemHtml: blocks.map((b) => b.html).join(''), hasFraction };
}

function renderFigures(question) {
  const dataUrls = Array.isArray(question?.figure_data_urls) ? question.figure_data_urls : [];
  if (dataUrls.length > 0) {
    return dataUrls
      .map((url) => `<div class="figure-container"><img class="figure-img" src="${url}" /></div>`)
      .join('');
  }
  return '';
}

function numIndentEm(numStr) {
  const digits = numStr.replace(/\D/g, '').length;
  if (digits <= 1) return '0.70';
  return '1.10';
}

export function renderQuestionBlock(question, mathRenderer) {
  const number = String(question?.question_number || '?');
  const equations = Array.isArray(question?.equations) ? question.equations : [];
  const stem = renderStemWithBoxes(question?.stem || '', mathRenderer, equations);
  const choices = Array.isArray(question?.choices) ? question.choices : [];

  let choiceHtml = '';
  if (choices.length > 0) {
    const items = choices.map((ch) => renderChoiceItem(ch, mathRenderer, equations));
    const layout = chooseLayout(items);
    choiceHtml = renderChoiceContainer(items, layout);
  }

  const hasFraction = stem.hasFraction || choiceHtml.includes('has-fraction');
  const questionClass = hasFraction ? 'question has-fraction' : 'question';
  const indent = numIndentEm(number);

  return `
    <article class="${questionClass}" style="padding-left:${indent}em;text-indent:-${indent}em;">
      <div class="q-stem"><span class="q-num">${escapeHtml(number)}.</span> ${stem.stemHtml}</div>
      ${renderFigures(question)}
      ${choiceHtml}
    </article>
  `;
}
