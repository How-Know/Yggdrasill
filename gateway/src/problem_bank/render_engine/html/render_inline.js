import {
  escapeHtml,
  isFractionLatex,
  normalizeMathLatex,
  tokenizeWithEquations,
} from '../utils/text.js';

const MATH_EXCEPTION_RE = /^[,?.]+$/;
const BOGAGI_RE = /^<보기>$/;

/**
 * Render mixed text+math content to HTML.
 *
 * @param {string} input - raw text (stem line or choice text)
 * @param {object} mathRenderer - { renderInline(latex) => { ok, svg } }
 * @param {Array} equations - the question's equations array from DB
 */
export function renderInlineMixedContent(input, mathRenderer, equations) {
  const tokens = tokenizeWithEquations(input, equations);
  if (tokens.length === 0) return { html: '', hasFraction: false };

  let hasFraction = false;
  const chunks = [];

  for (const token of tokens) {
    if (token.type === 'newline') {
      chunks.push('<br/>');
      continue;
    }
    if (token.type === 'text') {
      chunks.push(escapeHtml(token.value));
      continue;
    }

    const raw = String(token.value || '').trim();
    if (!raw || MATH_EXCEPTION_RE.test(raw) || BOGAGI_RE.test(raw)) {
      chunks.push(escapeHtml(token.value));
      continue;
    }

    const latex = normalizeMathLatex(raw);
    if (!latex) {
      chunks.push(escapeHtml(raw));
      continue;
    }

    const rendered = mathRenderer.renderInline(latex);
    if (!rendered.ok || !rendered.svg) {
      chunks.push(escapeHtml(raw));
      continue;
    }

    const fraction = isFractionLatex(latex);
    if (fraction) hasFraction = true;
    const klass = fraction ? 'math-inline fraction' : 'math-inline';
    const vaStyle = fraction
      ? ' style="vertical-align:middle"'
      : (rendered.verticalAlign ? ` style="vertical-align:${rendered.verticalAlign}"` : '');
    chunks.push(
      `<span class="${klass}"${vaStyle} data-latex="${escapeHtml(latex)}">${rendered.svg}</span>`,
    );
  }

  return { html: chunks.join(''), hasFraction };
}
