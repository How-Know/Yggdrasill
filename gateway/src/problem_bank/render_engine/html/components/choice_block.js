import { composeLineV1 } from '../line_composer.js';
import {
  escapeHtml,
  normalizeMathLatex,
  isFractionLatex,
} from '../../utils/text.js';

function visualLength(text) {
  const stripped = text
    .replace(/\\(?:times|div|cdot|pm|mp|leq|geq|neq|approx|equiv|sim|lt|gt|le|ge)\b/g, ' X ')
    .replace(/\\(?:frac|over)\b/g, ' FRAC ')
    .replace(/\\(?:left|right|mathrm|mathbf|mathit|text|operatorname)\b/g, '')
    .replace(/\\[a-zA-Z]+/g, ' S ')
    .replace(/[{}$\\]/g, '')
    .replace(/\^/g, '')
    .replace(/_/g, '')
    .replace(/\s+/g, ' ')
    .trim();
  let len = 0;
  for (const ch of stripped) {
    len += /[\u3000-\u9FFF\uAC00-\uD7AF]/.test(ch) ? 2 : 1;
  }
  return len;
}

function looksLikeNumericMathChoice(text) {
  const value = String(text || '').trim();
  if (!value) return false;
  if (/[가-힣ㄱ-ㅎㅏ-ㅣA-Za-z]/.test(value)) return false;
  // Pure number or simple numeric expression/parenthesized value.
  if (/^[()\[\]{}0-9+\-−*/÷×·=<>≤≥≠±%.,:\s]+$/.test(value)) return true;
  return false;
}

function wrapMathLine(svg, latex, hasFraction, dot = '') {
  const lineProfile = hasFraction ? 'fraction' : 'normal';
  const mathClass = hasFraction ? 'math-inline fraction' : 'math-inline';
  return `<span class="lc-line lc-${lineProfile}" data-lc-profile="${lineProfile}">`
    + `<span class="${mathClass}" data-latex="${escapeHtml(latex)}" data-render-path="forced">${svg}${dot}</span>`
    + '</span>';
}

export function renderChoiceItem(choice, mathRenderer, equations, opts) {
  const label = String(choice?.label || '').trim() || '-';
  const text = String(choice?.text || '');
  const forceNumericMath = looksLikeNumericMathChoice(text);
  const rendered = composeLineV1(
    text,
    mathRenderer,
    forceNumericMath ? [] : equations,
    opts,
  );
  let html = rendered.html;
  let hasFraction = rendered.hasFraction;
  if (
    mathRenderer
    && !/class="math-inline\b/.test(html)
    && forceNumericMath
  ) {
    const latex = normalizeMathLatex(text);
    const math = latex ? mathRenderer.renderInline(latex) : { ok: false, svg: '' };
    if (math.ok && math.svg) {
      hasFraction = isFractionLatex(latex);
      const dot = opts?.debugDots ? '<span class="math-debug-dot dot-forced"></span>' : '';
      html = wrapMathLine(math.svg, latex, hasFraction, dot);
    }
  }
  return {
    label,
    html,
    hasFraction,
    textLength: visualLength(text),
  };
}

export function chooseLayout(items) {
  if (items.length !== 5) return 'stack';
  const maxLen = Math.max(...items.map((it) => it.textLength));
  const totalLen = items.reduce((s, it) => s + it.textLength, 0);
  if (maxLen > 22) return 'stack';
  if (totalLen > 55) return 'stack';
  if (maxLen > 12 || totalLen > 40) return 'row2';
  if (maxLen > 6 || totalLen > 25) return 'row2';
  return 'row1';
}

export function renderChoiceContainer(items, layout) {
  const cell = (it) => {
    const cls = it.hasFraction ? 'choice has-fraction' : 'choice';
    return `<div class="${cls}"><span class="choice-label">${escapeHtml(it.label)}</span><span class="choice-text">${it.html}</span></div>`;
  };

  if (layout === 'row1') {
    return `<div class="choice-grid-row1">${items.map(cell).join('')}</div>`;
  }

  if (layout === 'row2') {
    const top3 = items.slice(0, 3);
    const bot2 = items.slice(3, 5);
    const topHtml = top3.map(cell).join('');
    const botHtml = bot2.map(cell).join('');
    return `<div class="choice-grid-row2">
      <div class="choice-grid-row2-top">${topHtml}</div>
      <div class="choice-grid-row2-bot">${botHtml}</div>
    </div>`;
  }

  const anyFrac = items.some((it) => it.hasFraction);
  const containerClass = anyFrac ? 'choice-list has-fraction' : 'choice-list';
  return `<div class="${containerClass}">${items.map(cell).join('')}</div>`;
}

function splitBlankChoiceCells(text, columnCount) {
  const parts = String(text || '')
    .split(/\s*,\s*/)
    .map((v) => v.trim());
  while (parts.length < columnCount) parts.push('');
  return parts.slice(0, columnCount);
}

function normalizeBlankChoiceLabels(labels) {
  const fallback = ['(가)', '(나)', '(다)'];
  const raw = Array.isArray(labels) ? labels : [];
  return fallback.map((label, idx) => {
    const value = String(raw[idx] || '').trim();
    return value || label;
  });
}

export function isBlankChoiceQuestion(question) {
  const meta = question?.meta && typeof question.meta === 'object' ? question.meta : {};
  return meta.is_blank_choice_question === true || meta.choice_layout === 'blank_table';
}

function blankChoiceWidthScale(question) {
  const meta = question?.meta && typeof question.meta === 'object' ? question.meta : {};
  const scales = meta.table_scales && typeof meta.table_scales === 'object'
    ? meta.table_scales
    : {};
  const raw = scales['blank_choice:1'] || meta.blank_choice_scale || null;
  const parsed = Number(raw?.widthScale ?? raw?.w ?? raw);
  if (!Number.isFinite(parsed)) return 1;
  return Math.max(0.5, Math.min(2.0, parsed));
}

function blankChoiceColumnScales(question, columnCount) {
  const meta = question?.meta && typeof question.meta === 'object' ? question.meta : {};
  const scales = meta.table_scales && typeof meta.table_scales === 'object'
    ? meta.table_scales
    : {};
  const raw = scales['blank_choice:1'] || null;
  const values = Array.isArray(raw?.columnScales) ? raw.columnScales : [];
  return Array.from({ length: columnCount }, (_, idx) => {
    const parsed = Number(values[idx]);
    if (!Number.isFinite(parsed)) return 1;
    return Math.max(0.5, Math.min(2.0, parsed));
  });
}

export function renderBlankChoiceContainer(question, choices, mathRenderer, equations, opts) {
  if (!Array.isArray(choices) || choices.length !== 5) return '';
  const meta = question?.meta && typeof question.meta === 'object' ? question.meta : {};
  const labels = normalizeBlankChoiceLabels(meta.blank_choice_labels);
  const widthScale = blankChoiceWidthScale(question);
  const columnScales = blankChoiceColumnScales(question, labels.length);
  const baseEm = [4.4, 4.4, 9.2];
  const gridColumns = [
    '2.2em',
    ...columnScales.map((scale, idx) =>
      `minmax(calc(${baseEm[idx] || 5.0}em * ${widthScale * scale}), max-content)`),
  ].join(' ');
  const header = [''].concat(labels)
    .map((label) => `<div class="blank-choice-header">${escapeHtml(label)}</div>`)
    .join('');
  const rows = choices.map((choice, rowIdx) => {
    const label = String(choice?.label || '').trim() || String(rowIdx + 1);
    const cells = splitBlankChoiceCells(choice?.text, labels.length)
      .map((cellText) => {
        const rendered = composeLineV1(cellText, mathRenderer, equations, opts);
        return `<div class="blank-choice-cell">${rendered.html}</div>`;
      })
      .join('');
    return `<div class="blank-choice-label">${escapeHtml(label)}</div>${cells}`;
  }).join('');
  return `<div class="blank-choice-table" style="--blank-choice-cols:${labels.length + 1};--blank-choice-width-scale:${widthScale};grid-template-columns:${gridColumns};">${header}${rows}</div>`;
}
