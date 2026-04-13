import { renderInlineMixedContent } from './render_inline.js';

function wrapLineHtml(html, profile) {
  if (!html) return '';
  const safeProfile = profile === 'fraction' ? 'fraction' : 'normal';
  return `<span class="lc-line lc-${safeProfile}" data-lc-profile="${safeProfile}">${html}</span>`;
}

export function composeLineV1(text, mathRenderer, equations, opts) {
  const safeText = String(text || '').trim();
  if (!safeText) {
    return {
      html: '',
      profile: 'normal',
      hasFraction: false,
    };
  }
  const rendered = renderInlineMixedContent(safeText, mathRenderer, equations, opts);
  const profile = rendered.hasFraction ? 'fraction' : 'normal';
  return {
    html: wrapLineHtml(rendered.html, profile),
    profile,
    hasFraction: rendered.hasFraction,
  };
}

export function composeLinesV1(lines, mathRenderer, equations, opts) {
  const src = Array.isArray(lines) ? lines : [lines];
  const out = [];
  let hasFraction = false;
  for (const line of src) {
    const one = composeLineV1(line, mathRenderer, equations, opts);
    if (!one.html) continue;
    out.push(one);
    if (one.hasFraction) hasFraction = true;
  }
  return {
    lines: out,
    html: out.map((one) => one.html).join('<br/>'),
    hasFraction,
  };
}
