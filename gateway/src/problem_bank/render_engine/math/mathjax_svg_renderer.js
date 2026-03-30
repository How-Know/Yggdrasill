import { mathjax } from 'mathjax-full/js/mathjax.js';
import { TeX } from 'mathjax-full/js/input/tex.js';
import { AllPackages } from 'mathjax-full/js/input/tex/AllPackages.js';
import { SVG } from 'mathjax-full/js/output/svg.js';
import { liteAdaptor } from 'mathjax-full/js/adaptors/liteAdaptor.js';
import { RegisterHTMLHandler } from 'mathjax-full/js/handlers/html.js';

import { normalizeMathLatex, isFractionLatex } from '../utils/text.js';

const mathAdaptor = liteAdaptor();
RegisterHTMLHandler(mathAdaptor);
const mathTex = new TeX({ packages: AllPackages });
const mathSvg = new SVG({ fontCache: 'none' });
const mathDocument = mathjax.document('', {
  InputJax: mathTex,
  OutputJax: mathSvg,
});

function extractSvgRoot(markup) {
  const src = String(markup || '').trim();
  if (!src) return '';
  const match = src.match(/<svg[\s\S]*?<\/svg>/i);
  return match && match[0] ? match[0] : src;
}

function balanceCurlyBraces(value) {
  const src = String(value || '');
  if (!src) return '';
  const out = [];
  const stack = [];
  for (let i = 0; i < src.length; i += 1) {
    const ch = src[i];
    if (ch === '{') {
      stack.push(out.length);
      out.push(ch);
      continue;
    }
    if (ch === '}') {
      if (stack.length > 0) {
        stack.pop();
        out.push(ch);
      }
      continue;
    }
    out.push(ch);
  }
  for (const idx of stack) {
    out[idx] = '';
  }
  return out.join('');
}

function latexCandidates(value) {
  const out = [];
  const seen = new Set();
  const push = (one) => {
    const safe = normalizeMathLatex(one);
    if (!safe || seen.has(safe)) return;
    seen.add(safe);
    out.push(safe);
  };
  const base = normalizeMathLatex(value);
  push(base);
  if (base) {
    push(balanceCurlyBraces(base));
    const noLeftRight = base.replace(/\\left\b/g, '').replace(/\\right\b/g, '');
    push(noLeftRight);
    push(balanceCurlyBraces(noLeftRight));
  }
  return out;
}

const EX_TO_EM = 0.45;

/**
 * Keep MathJax's own sizing but convert ex units to em so that
 * the SVG scales proportionally with the surrounding font-size.
 * Also preserve vertical-align for correct baseline alignment.
 */
function normalizeSvgForInline(svgMarkup) {
  const root = extractSvgRoot(svgMarkup);
  if (!root) return { svg: '', verticalAlign: '' };

  let verticalAlign = '';
  const styleMatch = root.match(/style="([^"]*)"/i);
  if (styleMatch) {
    const vaMatch = styleMatch[1].match(/vertical-align:\s*(-?[\d.]+)ex/);
    if (vaMatch) verticalAlign = `${(parseFloat(vaMatch[1]) * EX_TO_EM).toFixed(3)}em`;
  }

  let widthEm = '';
  const widthMatch = root.match(/width="([\d.]+)ex"/i);
  if (widthMatch) widthEm = `${(parseFloat(widthMatch[1]) * EX_TO_EM).toFixed(3)}em`;

  let heightEm = '';
  const heightMatch = root.match(/height="([\d.]+)ex"/i);
  if (heightMatch) heightEm = `${(parseFloat(heightMatch[1]) * EX_TO_EM).toFixed(3)}em`;

  const inlineStyle = [
    widthEm ? `width:${widthEm}` : '',
    heightEm ? `height:${heightEm}` : '',
  ].filter(Boolean).join(';');

  let svg = root.replace(
    /<svg\b[^>]*>/i,
    (tag) => {
      const cleaned = tag
        .replace(/\sstyle="[^"]*"/gi, '')
        .replace(/\swidth="[^"]*"/gi, '')
        .replace(/\sheight="[^"]*"/gi, '');
      return cleaned.replace(/>$/, ` style="${inlineStyle}">`);
    },
  );

  svg = svg.replace(/<rect\b([^>]*)>/gi, (m, attrs) => {
    const hm = attrs.match(/\bheight="([\d.]+)"/);
    if (!hm) return m;
    const oldH = parseFloat(hm[1]);
    if (!(oldH > 0 && oldH < 200)) return m;
    const newH = oldH * 0.5;
    const delta = (oldH - newH) / 2;
    let patched = attrs.replace(/\bheight="[\d.]+"/, `height="${newH.toFixed(1)}"`);
    const ym = patched.match(/\by="(-?[\d.]+)"/);
    if (ym) {
      const newY = parseFloat(ym[1]) + delta;
      patched = patched.replace(/\by="-?[\d.]+"/, `y="${newY.toFixed(1)}"`);
    }
    return `<rect${patched}>`;
  });

  return { svg, verticalAlign };
}

export function createMathSvgRenderer() {
  const cache = new Map();
  const stats = {
    requested: 0,
    rendered: 0,
    failed: 0,
    cacheHit: 0,
  };

  const renderInline = (latex) => {
    let safeLatex = normalizeMathLatex(latex);
    if (!safeLatex) return { ok: false, svg: '', latex: '' };
    if (isFractionLatex(safeLatex) && !safeLatex.startsWith('\\displaystyle')) {
      safeLatex = `\\displaystyle ${safeLatex}`;
    }
    stats.requested += 1;
    if (cache.has(safeLatex)) {
      stats.cacheHit += 1;
      const cached = cache.get(safeLatex);
      if (!cached.ok) stats.failed += 1;
      return cached;
    }
    try {
      const candidates = latexCandidates(safeLatex);
      for (const candidate of candidates) {
        try {
          const node = mathDocument.convert(candidate, { display: false });
          const raw = mathAdaptor.outerHTML(node);
          const { svg, verticalAlign } = normalizeSvgForInline(raw);
          if (!svg) continue;
          const ok = { ok: true, svg, latex: candidate, verticalAlign };
          cache.set(safeLatex, ok);
          stats.rendered += 1;
          return ok;
        } catch (_) {
          // try next candidate
        }
      }
      const failed = { ok: false, svg: '', latex: safeLatex };
      cache.set(safeLatex, failed);
      stats.failed += 1;
      return failed;
    } catch (_) {
      const failed = { ok: false, svg: '', latex: safeLatex };
      cache.set(safeLatex, failed);
      stats.failed += 1;
      return failed;
    }
  };

  return {
    renderInline,
    stats,
  };
}
