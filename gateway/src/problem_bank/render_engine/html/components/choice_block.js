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
  if (maxLen > 18) return 'stack';
  if (maxLen > 6) return 'row2';
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
  const configured = raw
    .map((label) => String(label || '').trim())
    .filter(Boolean);
  if (configured.length >= 2 && configured.length <= 4) return configured;
  return fallback.map((label, idx) => {
    const value = String(raw[idx] || '').trim();
    return value || label;
  });
}

export function isBlankChoiceQuestion(question) {
  const meta = question?.meta && typeof question.meta === 'object' ? question.meta : {};
  return meta.is_blank_choice_question === true || meta.choice_layout === 'blank_table';
}

export function isImageChoiceQuestion(question) {
  const meta = question?.meta && typeof question.meta === 'object' ? question.meta : {};
  const choices = Array.isArray(question?.choices) ? question.choices : [];
  return meta.is_image_choice_question === true
    || meta.choice_layout === 'image_table'
    || (
      choices.length === 5
      && choices.every((choice) => /^\s*\[(?:그림|도형|도표)\]\s*$/.test(String(choice?.text || '')))
    );
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
  // Number column is fixed; data columns grow evenly by widthScale.
  // Per-column differences are represented only by columnScales.
  const baseDataColumnEm = 5.8;
  const gridColumns = [
    '2.2em',
    ...columnScales.map((scale, idx) =>
      `minmax(calc(${baseDataColumnEm}em * ${widthScale * scale}), max-content)`),
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

export function renderImageChoiceContainer(question, choices, dataUrls, figureOffset = 0) {
  if (!Array.isArray(choices) || choices.length !== 5) return '';
  const offset = Number.isInteger(figureOffset) && figureOffset > 0 ? figureOffset : 0;
  // 본문 그림이 앞쪽 offset 개를 소비했으므로, 선지 이미지는 그 다음부터 5개를 사용한다.
  const urls = Array.isArray(dataUrls) ? dataUrls.slice(offset, offset + 5) : [];
  if (urls.length === 0) return '';
  const meta = question?.meta && typeof question.meta === 'object' ? question.meta : {};
  const rowsPref = String(meta.image_choice_layout?.rows || '').trim();
  const rowCount = rowsPref === '3' ? 3 : 2;
  const columnCount = rowCount === 3 ? 2 : 3;
  const groups = rowCount === 3
    ? [choices.slice(0, 2), choices.slice(2, 4), choices.slice(4, 5)]
    : [choices.slice(0, 3), choices.slice(3, 5)];
  // 선지별 크기(widthEm) → 0.35~1.0 스케일. 기본 widthEm(15.5)을 1.0 으로 본다.
  const layoutItems = Array.isArray(meta.figure_layout?.items) ? meta.figure_layout.items : [];
  const choiceWidthScale = (choicePos) => {
    const key = `idx:${choicePos + offset + 1}`;
    const item = layoutItems.find((it) => it && it.assetKey === key);
    const w = item && Number.isFinite(Number(item.widthEm)) ? Number(item.widthEm) : null;
    if (!w) return 1;
    return Math.max(0.35, Math.min(1.0, w / 15.5));
  };
  let cursor = 0;
  const rows = groups.map((rowChoices) => {
    const cells = rowChoices.map((choice) => {
      const url = urls[cursor];
      const scale = choiceWidthScale(cursor);
      cursor += 1;
      const label = escapeHtml(String(choice?.label || '').trim() || String(cursor));
      const imgStyle = scale < 0.999 ? ` style="width:${(scale * 100).toFixed(1)}%"` : '';
      const img = url
        ? `<img class="image-choice-img" src="${url}"${imgStyle} />`
        : '<span class="image-choice-missing">[그림]</span>';
      return `<div class="image-choice-cell"><span class="choice-label">${label}</span>${img}</div>`;
    }).join('');
    const fillers = '<div class="image-choice-cell image-choice-empty"></div>'
      .repeat(Math.max(0, columnCount - rowChoices.length));
    return `<div class="image-choice-row">${cells}${fillers}</div>`;
  }).join('');
  return `<div class="image-choice-table image-choice-rows-${rowCount}" style="--image-choice-cols:${columnCount};">${rows}</div>`;
}
