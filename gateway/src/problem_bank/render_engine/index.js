import fs from 'node:fs';

import { buildDocumentHtml } from './html/build_document_html.js';
import { renderHtmlToPdfBuffer } from './chrome/render_pdf.js';
import { createMathSvgRenderer } from './math/mathjax_svg_renderer.js';
import { normalizeWhitespace } from './utils/text.js';

function ptToMm(pt) {
  return Number(pt || 0) * 0.3527777778;
}

function parseSafeBase64(path) {
  const safePath = String(path || '').trim();
  if (!safePath || !fs.existsSync(safePath)) return '';
  try {
    const bytes = fs.readFileSync(safePath);
    return Buffer.from(bytes).toString('base64');
  } catch (_) {
    return '';
  }
}

function buildFontFaceCss({ regularPath, boldPath }) {
  const regularB64 = parseSafeBase64(regularPath);
  const boldB64 = parseSafeBase64(boldPath);
  const chunks = [];
  if (regularB64) {
    chunks.push(`
      @font-face {
        font-family: "YggMain";
        src: url(data:font/ttf;base64,${regularB64}) format("truetype");
        font-weight: 400;
        font-style: normal;
        font-display: swap;
      }
    `);
  }
  if (boldB64) {
    chunks.push(`
      @font-face {
        font-family: "YggMain";
        src: url(data:font/ttf;base64,${boldB64}) format("truetype");
        font-weight: 700;
        font-style: normal;
        font-display: swap;
      }
    `);
  }
  return chunks.join('\n');
}

function sanitizeChoiceRows(rows) {
  return Array.isArray(rows)
    ? rows
      .map((one) => ({
        label: normalizeWhitespace(one?.label || ''),
        text: String(one?.text || ''),
      }))
      .filter((one) => one.label || one.text)
    : [];
}

function normalizeQuestionForHtml(question) {
  return {
    ...question,
    stem: String(question?.stem || ''),
    choices: sanitizeChoiceRows(question?.choices),
    equations: Array.isArray(question?.equations) ? question.equations : [],
    figure_refs: Array.isArray(question?.figure_refs) ? question.figure_refs : [],
    meta: question?.meta && typeof question.meta === 'object' ? question.meta : {},
  };
}

function buildHtmlLayout(renderConfig, baseLayout) {
  const tuning = renderConfig?.layoutTuning || {};
  const marginPt = Number(tuning.pageMargin || baseLayout.margin || 46);
  const stemSizePt = Number(renderConfig?.font?.size || baseLayout.stemSize || 11.2);
  const baseLineHeight = Number(tuning.lineHeight || baseLayout.lineHeight || 15.0);
  const lineHeightPt = Math.round(baseLineHeight * 1.4 * 10) / 10;
  return {
    marginMm: Math.max(10, ptToMm(marginPt)),
    stemSizePt,
    lineHeightPt,
    numberLaneWidthPt: Number(tuning.numberLaneWidth || 26),
    numberGapPt: Number(tuning.numberGap || 6),
    questionGapPt: Number(tuning.questionGap || baseLayout.questionGap || 10),
    choiceGapPt: Number(tuning.choiceSpacing || 2),
    layoutColumns: Number(renderConfig?.layoutColumns || 1) === 2 ? 2 : 1,
    columnGapPt: Number(tuning.columnGap || 18),
  };
}

async function hydrateFiguresForHtml(questions, supabaseClient) {
  if (!supabaseClient) return { appliedCount: 0 };
  let appliedCount = 0;
  for (const q of questions) {
    q.figure_data_urls = [];
    const meta = q.meta && typeof q.meta === 'object' ? q.meta : {};
    const assets = Array.isArray(meta.figure_assets) ? meta.figure_assets : [];
    if (assets.length === 0) continue;

    const byIndex = new Map();
    for (const asset of assets) {
      const idx = asset?.figure_index ?? 0;
      const existing = byIndex.get(idx);
      if (!existing) {
        byIndex.set(idx, asset);
      } else {
        const ec = String(existing.created_at || '');
        const ac = String(asset.created_at || '');
        if (ac > ec) byIndex.set(idx, asset);
      }
    }
    const deduped = [...byIndex.values()].sort(
      (a, b) => (a.figure_index ?? 0) - (b.figure_index ?? 0),
    );

    for (const asset of deduped) {
      const bucket = normalizeWhitespace(asset?.bucket || '');
      const path = normalizeWhitespace(asset?.path || '');
      if (!bucket || !path) continue;
      try {
        const { data, error } = await supabaseClient.storage
          .from(bucket)
          .download(path);
        if (error || !data) continue;
        const buf = Buffer.from(await data.arrayBuffer());
        const mime = normalizeWhitespace(asset?.mime_type || asset?.mimeType || 'image/png');
        const b64 = buf.toString('base64');
        q.figure_data_urls.push(`data:${mime};base64,${b64}`);
        appliedCount += 1;
      } catch (_) {
        // skip failed downloads
      }
    }
  }
  return { appliedCount };
}

export async function renderPdfWithHtmlEngine({
  questions,
  renderConfig,
  profile,
  paper,
  modeByQuestionId,
  questionMode,
  layoutColumns,
  maxQuestionsPerPage,
  renderConfigVersion,
  fontFamilyRequested,
  fontFamilyResolved,
  fontRegularPath,
  fontBoldPath,
  fontSize,
  baseLayout,
  supabaseClient,
}) {
  const mathRenderer = createMathSvgRenderer();
  const htmlQuestions = (questions || []).map(normalizeQuestionForHtml);
  const figureStats = await hydrateFiguresForHtml(htmlQuestions, supabaseClient);
  const layout = buildHtmlLayout(renderConfig, baseLayout || {});
  const html = buildDocumentHtml({
    profile,
    paper,
    layout,
    questions: htmlQuestions,
    includeAnswerSheet: renderConfig?.includeAnswerSheet === true,
    includeExplanation: renderConfig?.includeExplanation === true,
    mathRenderer,
    fontFaceCss: buildFontFaceCss({
      regularPath: fontRegularPath,
      boldPath: fontBoldPath,
    }),
  });
  const rendered = await renderHtmlToPdfBuffer(html);
  return {
    bytes: rendered.bytes,
    pageCount: rendered.pageCount,
    profile,
    paper,
    questionMode,
    modeByQuestionId: modeByQuestionId || {},
    layoutColumns,
    maxQuestionsPerPage,
    renderConfigVersion,
    fontFamily: fontFamilyResolved || fontFamilyRequested || '',
    fontFamilyRequested: fontFamilyRequested || '',
    fontRegularPath: fontRegularPath || '',
    fontBoldPath: fontBoldPath || '',
    fontSize: Number(fontSize || 0),
    mathRequestedCount: Number(mathRenderer.stats.requested || 0),
    mathRenderedCount: Number(mathRenderer.stats.rendered || 0),
    mathFailedCount: Number(mathRenderer.stats.failed || 0),
    mathCacheHitCount: Number(mathRenderer.stats.cacheHit || 0),
    figureHydration: {
      appliedCount: figureStats.appliedCount,
      degradedCount: 0,
      resampledCount: 0,
      regenerationQueuedCount: 0,
      effectiveDpiByQuestionId: {},
    },
    exportQuestions: htmlQuestions,
  };
}
