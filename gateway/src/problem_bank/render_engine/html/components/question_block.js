import { renderInlineMixedContent } from '../render_inline.js';
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
  const rendered = renderInlineMixedContent(text, mathRenderer, equations);
  const klass = rendered.hasFraction ? 'stem-line has-fraction' : 'stem-line';
  return {
    html: `<div class="${klass}">${rendered.html}</div>`,
    rawHtml: rendered.html,
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
      const rendered = renderInlineMixedContent(text, mathRenderer, equations);
      result.push(
        `<div class="bogi-item"><span class="bogi-item-label">${escapeHtml(label)}.</span><span class="bogi-item-text">${rendered.html}</span></div>`,
      );
    } else {
      const r = renderOneLine(part, mathRenderer, equations);
      if (r) result.push(r.html);
    }
  }
  return result.join('');
}

function renderStemWithBoxes(stem, mathRenderer, equations) {
  const lines = splitStemByNewline(stem);
  const chunks = [];
  let hasFraction = false;
  let inBox = false;
  let boxLines = [];
  let isFirstLine = true;

  const flushBox = () => {
    if (boxLines.length === 0) return;
    const hasBogi = boxLines.some((l) => BOGI_RE.test(l));
    const title = hasBogi
      ? '<div class="bogi-title"><span>&lt;보 기&gt;</span></div>'
      : '';
    const innerHtml = renderBogiItems(boxLines, mathRenderer, equations);
    if (innerHtml) {
      chunks.push(
        `<div class="bogi-box">${title}<div class="bogi-content">${innerHtml}</div></div>`,
      );
    }
    boxLines = [];
  };

  const result = { firstLineHtml: '', bodyHtml: '', hasFraction: false };

  for (const rawLine of lines) {
    const hasStart = BOX_START.test(rawLine);
    const hasEnd = BOX_END.test(rawLine);

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
    const r = renderOneLine(clean, mathRenderer, equations);
    if (!r) continue;
    if (r.hasFraction) hasFraction = true;

    if (isFirstLine) {
      result.firstLineHtml = r.rawHtml;
      result.hasFraction = r.hasFraction;
      isFirstLine = false;
    } else {
      chunks.push(r.html);
    }
  }
  flushBox();

  result.bodyHtml = chunks.join('');
  result.hasFraction = result.hasFraction || hasFraction;
  return result;
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
  const dotWidth = 0.35;
  const gapWidth = 0.15;
  if (digits <= 1) return (0.55 + dotWidth + gapWidth).toFixed(2);
  return (digits * 0.55 + dotWidth + gapWidth).toFixed(2);
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
    <article class="${questionClass}">
      <div class="q-header">
        <span class="q-num">${escapeHtml(number)}.</span>
        <span class="q-first-line">${stem.firstLineHtml}</span>
      </div>
      <div class="q-body" style="padding-left:${indent}em;">
        <div class="q-stem">${stem.bodyHtml}</div>
        ${renderFigures(question)}
        ${choiceHtml}
      </div>
    </article>
  `;
}
