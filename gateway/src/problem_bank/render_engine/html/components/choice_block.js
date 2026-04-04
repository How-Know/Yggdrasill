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

function wrapMathLine(svg, latex, hasFraction) {
  const lineProfile = hasFraction ? 'fraction' : 'normal';
  const mathClass = hasFraction ? 'math-inline fraction' : 'math-inline';
  return `<span class="lc-line lc-${lineProfile}" data-lc-profile="${lineProfile}">`
    + `<span class="${mathClass}" data-latex="${escapeHtml(latex)}">${svg}</span>`
    + '</span>';
}

export function renderChoiceItem(choice, mathRenderer, equations) {
  const label = String(choice?.label || '').trim() || '-';
  const text = String(choice?.text || '');
  const forceNumericMath = looksLikeNumericMathChoice(text);
  // Avoid partial equation-index matches (e.g. "1" in "10") on AI-generated
  // objective choices by bypassing equation-token slicing for numeric options.
  const rendered = composeLineV1(
    text,
    mathRenderer,
    forceNumericMath ? [] : equations,
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
      html = wrapMathLine(math.svg, latex, hasFraction);
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
