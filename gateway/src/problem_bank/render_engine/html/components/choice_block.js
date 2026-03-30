import { renderInlineMixedContent } from '../render_inline.js';
import { escapeHtml } from '../../utils/text.js';

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

export function renderChoiceItem(choice, mathRenderer, equations) {
  const label = String(choice?.label || '').trim() || '-';
  const text = String(choice?.text || '');
  const rendered = renderInlineMixedContent(text, mathRenderer, equations);
  return {
    label,
    html: rendered.html,
    hasFraction: rendered.hasFraction,
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
