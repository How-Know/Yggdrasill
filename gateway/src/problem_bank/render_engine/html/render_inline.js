import {
  escapeHtml,
  isFractionLatex,
  normalizeMathLatex,
  tokenizeWithEquations,
  splitBySpaceMarkers,
} from '../utils/text.js';

const MATH_EXCEPTION_RE = /^[,?.]+$/;
const BOGAGI_RE = /^<보기>$/;

function debugDotHtml() {
  return '<span class="math-debug-dot dot-forced"></span>';
}

/**
 * `[공백:N]` 마커 → inline-block span (width: Nem).
 *   - `display:inline-block` 으로 `white-space` collapse 영향을 피한다.
 *   - `aria-hidden` 으로 스크린리더 무시.
 */
function spaceMarkerHtml(amount) {
  const n = Number.isFinite(amount) ? amount : 1;
  return `<span class="stem-space" style="display:inline-block;width:${n}em;" aria-hidden="true"></span>`;
}

/**
 * Render mixed text+math content to HTML.
 *
 * @param {string} input - raw text (stem line or choice text)
 * @param {object} mathRenderer - { renderInline(latex) => { ok, svg } }
 * @param {Array} equations - the question's equations array from DB
 * @param {{ debugDots?: boolean }} [opts]
 */
export function renderInlineMixedContent(input, mathRenderer, equations, opts) {
  const src = String(input ?? '');
  // `[공백:N]` 마커를 가장 바깥에서 먼저 분리한다. tokenizeWithEquations 의 text/math
  // 분류에 `[`, `]`, 숫자가 섞이면 오탐이 나므로, 마커 경계를 미리 끊는 게 안전하다.
  const pieces = src.includes('[공백:')
    ? splitBySpaceMarkers(src)
    : [{ type: 'text', value: src }];

  const tokens = [];
  for (const piece of pieces) {
    if (piece.type === 'space') {
      tokens.push({ type: 'space', amount: piece.amount });
      continue;
    }
    const sub = tokenizeWithEquations(piece.value, equations);
    for (const t of sub) tokens.push(t);
  }
  if (tokens.length === 0) return { html: '', hasFraction: false };

  const showDots = opts?.debugDots === true;
  let hasFraction = false;
  const chunks = [];

  for (const token of tokens) {
    if (token.type === 'newline') {
      chunks.push('<br/>');
      continue;
    }
    if (token.type === 'space') {
      chunks.push(spaceMarkerHtml(token.amount));
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
    const isVar = /^[a-zA-Z]$/.test(raw);
    const klass = (fraction ? 'math-inline fraction' : 'math-inline') + (isVar ? ' math-var' : '');
    const dot = showDots ? debugDotHtml() : '';
    chunks.push(
      `<span class="${klass}" data-latex="${escapeHtml(latex)}" data-render-path="forced">${rendered.svg}${dot}</span>`,
    );
  }

  return { html: chunks.join(''), hasFraction };
}
