import fs from 'node:fs';

import { buildDocumentHtml } from './html/build_document_html.js';
import { buildPreviewHtml } from './html/build_preview_html.js';
import { renderHtmlToPdfBuffer, renderHtmlToImageBuffer } from './chrome/render_pdf.js';
import { createMathSvgRenderer } from './math/mathjax_svg_renderer.js';
import { normalizeWhitespace } from './utils/text.js';

function ptToMm(pt) {
  return Number(pt || 0) * 0.3527777778;
}

function normalizeLayoutMode(raw) {
  const mode = String(raw || '').trim().toLowerCase();
  if (mode === 'custom_columns' || mode === 'custom-columns' || mode === 'custom') {
    return 'custom_columns';
  }
  return 'legacy';
}

function toSafeInt(raw, fallback = 0) {
  const parsed = Number.parseInt(String(raw ?? ''), 10);
  if (!Number.isFinite(parsed)) return fallback;
  return parsed;
}

function normalizeColumnQuestionCounts(raw, layoutColumns, maxQuestionsPerPage) {
  if (!Array.isArray(raw)) return [];
  const targetColumns = Math.max(1, toSafeInt(layoutColumns, 1));
  const counts = raw
    .slice(0, targetColumns)
    .map((v) => toSafeInt(v, 0))
    .filter((v) => v > 0);
  if (counts.length !== targetColumns) return [];
  const total = counts.reduce((sum, one) => sum + one, 0);
  if (total <= 0) return [];
  if (Number.isFinite(maxQuestionsPerPage) && maxQuestionsPerPage > 0 && total !== maxQuestionsPerPage) {
    return [];
  }
  return counts;
}

function normalizePageColumnQuestionCounts(raw, layoutColumns) {
  if (!Array.isArray(raw)) return [];
  if (toSafeInt(layoutColumns, 1) !== 2) return [];
  const out = [];
  for (const one of raw) {
    if (!one || typeof one !== 'object') continue;
    const pageRaw = toSafeInt(
      one.pageIndex ?? one.page ?? one.pageNo ?? one.pageNumber,
      out.length + 1,
    );
    const left = toSafeInt(one.left ?? one.leftCount ?? one.col1 ?? one.l, -1);
    const right = toSafeInt(one.right ?? one.rightCount ?? one.col2 ?? one.r, -1);
    if (left < 0 || right < 0) continue;
    if (left + right <= 0) continue;
    out.push({
      pageIndex: Math.max(1, pageRaw),
      left,
      right,
    });
  }
  const dedup = new Map();
  for (const one of out) {
    dedup.set(one.pageIndex, one);
  }
  return [...dedup.values()].sort((a, b) => a.pageIndex - b.pageIndex);
}

function normalizeTitlePageIndices(raw) {
  const out = new Set([1]);
  if (Array.isArray(raw)) {
    for (const one of raw) {
      const page = toSafeInt(one, 0);
      if (page < 1) continue;
      out.add(page);
    }
  }
  return [...out].sort((a, b) => a - b);
}

function normalizeTitlePageHeaders(raw, titlePageIndices, fallbackTitle = '수학 영역') {
  const titlePages = normalizeTitlePageIndices(titlePageIndices);
  const titlePageSet = new Set(titlePages);
  const out = new Map();
  if (Array.isArray(raw)) {
    for (const one of raw) {
      if (!one || typeof one !== 'object') continue;
      const page = toSafeInt(
        one.page ?? one.pageIndex ?? one.pageNo ?? one.pageNumber,
        0,
      );
      if (page < 1 || !titlePageSet.has(page)) continue;
      const title = normalizeWhitespace(one.title || one.subjectTitleText || '');
      const subtitle = normalizeWhitespace(one.subtitle || one.subTitle || one.sub || '');
      if (!title && !subtitle) continue;
      out.set(page, { page, title, subtitle });
    }
  }
  const defaultTitle = normalizeWhitespace(fallbackTitle || '수학 영역') || '수학 영역';
  const pageOneTitle = out.get(1)?.title || defaultTitle;
  for (const page of titlePages) {
    const prev = out.get(page);
    out.set(page, {
      page,
      title: normalizeWhitespace(prev?.title || '') || pageOneTitle,
      subtitle: normalizeWhitespace(prev?.subtitle || ''),
    });
  }
  return [...out.values()].sort((a, b) => a.page - b.page);
}

function normalizeCoverPageItems(rawItems, fallbackItems = []) {
  const src = Array.isArray(rawItems) ? rawItems : [];
  const out = [];
  for (const one of src) {
    if (!one || typeof one !== 'object') continue;
    const name = normalizeWhitespace(one.name || one.label || '');
    const pages = normalizeWhitespace(one.pages || one.pageRange || '');
    if (!name && !pages) continue;
    out.push({ name, pages });
    if (out.length >= 24) break;
  }
  if (out.length > 0) return out;
  return (Array.isArray(fallbackItems) ? fallbackItems : [])
    .map((one) => ({
      name: normalizeWhitespace(one?.name || one?.label || ''),
      pages: normalizeWhitespace(one?.pages || one?.pageRange || ''),
    }))
    .filter((one) => one.name || one.pages)
    .slice(0, 24);
}

function normalizeCoverPageTexts(raw, defaults = {}) {
  const src = raw && typeof raw === 'object' ? raw : {};
  const seed = defaults && typeof defaults === 'object' ? defaults : {};
  const defaultElectiveItemsSrc = Array.isArray(seed.electiveItems) ? seed.electiveItems : [];
  const defaultElectiveItems = [0, 1, 2].map((index) => {
    const item = defaultElectiveItemsSrc[index] && typeof defaultElectiveItemsSrc[index] === 'object'
      ? defaultElectiveItemsSrc[index]
      : {};
    const fallbackName =
      index === 0 ? '확률과 통계' : (index === 1 ? '미적분' : '기하');
    const fallbackPages =
      index === 0 ? '9~12쪽' : (index === 1 ? '13~16쪽' : '17~20쪽');
    return {
      name: normalizeWhitespace(item.name || fallbackName) || fallbackName,
      pages: normalizeWhitespace(item.pages || fallbackPages) || fallbackPages,
    };
  });
  const defaultCommonItems = Array.isArray(seed.commonItems)
    ? normalizeCoverPageItems(seed.commonItems, [])
    : [];
  const topTitle = normalizeWhitespace(
    src.topTitle || seed.topTitle || '2026학년도 대학수학능력시험 문제지',
  ) || '2026학년도 대학수학능력시험 문제지';
  const subjectTitle = normalizeWhitespace(
    src.subjectTitle || seed.subjectTitle || '수학 영역',
  ) || '수학 영역';
  const handwritingPhrase = normalizeWhitespace(
    src.handwritingPhrase || seed.handwritingPhrase || '이 많은 별빛이 내린 언덕 위에',
  ) || '이 많은 별빛이 내린 언덕 위에';
  const fallbackGroups = [
    {
      label: normalizeWhitespace(src.commonLabel || seed.commonLabel || '공통과목') || '공통과목',
      pageRange: normalizeWhitespace(
        src.commonPageRange || src.commonPages || seed.commonPageRange || '1~12쪽',
      ) || '1~12쪽',
      items: normalizeCoverPageItems(src.commonItems, defaultCommonItems),
    },
    {
      label: normalizeWhitespace(src.electiveLabel || seed.electiveLabel || '선택과목') || '선택과목',
      pageRange: normalizeWhitespace(
        src.electivePageRange || src.electivePages || seed.electivePageRange || '',
      ),
      items: normalizeCoverPageItems(src.electiveItems, defaultElectiveItems),
    },
  ];
  const hasExplicitGroups = Array.isArray(src.subjectGroups);
  let subjectGroups = [];
  if (hasExplicitGroups) {
    const rawGroups = Array.isArray(src.subjectGroups) ? src.subjectGroups : [];
    subjectGroups = rawGroups
      .filter((group) => group && typeof group === 'object')
      .map((group, index) => {
        const fallbackLabel = normalizeWhitespace(
          fallbackGroups[index]?.label || `대분류 ${index + 1}`,
        ) || `대분류 ${index + 1}`;
        return {
          label: normalizeWhitespace(group.label || '') || fallbackLabel,
          pageRange: normalizeWhitespace(group.pageRange || group.pages || ''),
          items: normalizeCoverPageItems(group.items, []),
        };
      })
      .slice(0, 24);
  } else {
    subjectGroups = fallbackGroups;
  }
  const commonGroup = subjectGroups[0] || fallbackGroups[0];
  const electiveGroup = subjectGroups[1] || fallbackGroups[1];
  const commonLabel = commonGroup.label || '공통과목';
  const commonPageRange = commonGroup.pageRange || '1~12쪽';
  const commonItems = normalizeCoverPageItems(commonGroup.items, defaultCommonItems);
  const electiveLabel = electiveGroup.label || '선택과목';
  const electivePageRange = normalizeWhitespace(electiveGroup.pageRange || '');
  const electiveItems = normalizeCoverPageItems(electiveGroup.items, defaultElectiveItems);
  const organization = normalizeWhitespace(
    src.organization || src.organizationName || seed.organization || '한국교육과정평가원',
  ) || '한국교육과정평가원';
  return {
    topTitle,
    subjectTitle,
    handwritingPhrase,
    commonLabel,
    commonPageRange,
    commonItems,
    electiveLabel,
    electivePageRange,
    electiveItems,
    subjectGroups,
    organization,
  };
}

function normalizeAnchorPage(raw) {
  const v = String(raw || '').trim().toLowerCase();
  if (!v || v === 'first' || v === '1') return 'first';
  if (v === 'all' || v === 'every') return 'all';
  const n = Number.parseInt(v, 10);
  if (Number.isFinite(n) && n >= 1) return n;
  return 'first';
}

function normalizeColumnLabelAnchors(raw, layoutColumns) {
  if (!Array.isArray(raw)) return [];
  const maxColumns = Math.max(1, toSafeInt(layoutColumns, 1));
  const out = [];
  for (const one of raw) {
    if (!one || typeof one !== 'object') continue;
    const columnIndex = toSafeInt(one.columnIndex, -1);
    if (columnIndex < 0 || columnIndex >= maxColumns) continue;
    const parsedRowIndex = toSafeInt(one.rowIndex, 0);
    const rowIndex = parsedRowIndex >= 0 ? parsedRowIndex : 0;
    const label = normalizeWhitespace(one.label || one.text || '');
    if (!label) continue;
    const topPt = Number(one.topPt);
    const paddingTopPt = Number(one.paddingTopPt);
    const sourceRaw = String(one.source || '').trim().toLowerCase();
    const source = sourceRaw === 'auto' ? 'auto' : 'manual';
    out.push({
      columnIndex,
      rowIndex,
      label,
      source,
      page: normalizeAnchorPage(one.page),
      topPt: Number.isFinite(topPt) ? topPt : 8,
      paddingTopPt: Number.isFinite(paddingTopPt) ? paddingTopPt : 46,
    });
  }
  return out;
}

function normalizeAlignPolicy(raw) {
  const src = raw && typeof raw === 'object' ? raw : {};
  const pairAlignmentRaw = String(src.pairAlignment || src.pairMode || '').trim().toLowerCase();
  const pairAlignment = pairAlignmentRaw === 'none' ? 'none' : 'row';
  return {
    pairAlignment,
    skipAnchorRows: src.skipAnchorRows !== false,
  };
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

function fontFormatForPath(filePath) {
  const lower = String(filePath || '').toLowerCase();
  if (lower.endsWith('.otf')) return { mime: 'font/otf', format: 'opentype' };
  if (lower.endsWith('.woff2')) return { mime: 'font/woff2', format: 'woff2' };
  if (lower.endsWith('.woff')) return { mime: 'font/woff', format: 'woff' };
  return { mime: 'font/ttf', format: 'truetype' };
}

function buildFontFaceCss({ regularPath, boldPath, qnumFontPath, subjectFontPath }) {
  const regularB64 = parseSafeBase64(regularPath);
  const boldB64 = parseSafeBase64(boldPath);
  const qnumB64 = parseSafeBase64(qnumFontPath);
  const subjectB64 = parseSafeBase64(subjectFontPath);
  const chunks = [];
  if (regularB64) {
    const f = fontFormatForPath(regularPath);
    chunks.push(`
      @font-face {
        font-family: "YggMain";
        src: url(data:${f.mime};base64,${regularB64}) format("${f.format}");
        font-weight: 300;
        font-style: normal;
        font-display: swap;
      }
    `);
    chunks.push(`
      @font-face {
        font-family: "YggMain";
        src: url(data:${f.mime};base64,${regularB64}) format("${f.format}");
        font-weight: 400;
        font-style: normal;
        font-display: swap;
      }
    `);
  }
  if (boldB64) {
    const f = fontFormatForPath(boldPath);
    chunks.push(`
      @font-face {
        font-family: "YggMain";
        src: url(data:${f.mime};base64,${boldB64}) format("${f.format}");
        font-weight: 700;
        font-style: normal;
        font-display: swap;
      }
    `);
  }
  if (qnumB64) {
    const f = fontFormatForPath(qnumFontPath);
    chunks.push(`
      @font-face {
        font-family: "YggQNum";
        src: url(data:${f.mime};base64,${qnumB64}) format("${f.format}");
        font-weight: 700;
        font-style: normal;
        font-display: swap;
      }
    `);
  }
  if (subjectB64) {
    const f = fontFormatForPath(subjectFontPath);
    chunks.push(`
      @font-face {
        font-family: "YggSubject";
        src: url(data:${f.mime};base64,${subjectB64}) format("${f.format}");
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

function normalizeQuestionScoreByQuestionId(raw) {
  if (!raw || typeof raw !== 'object') return {};
  const out = {};
  for (const [key, value] of Object.entries(raw)) {
    const id = String(key || '').trim();
    if (!id) continue;
    const parsed = Number.parseFloat(String(value ?? ''));
    if (!Number.isFinite(parsed) || parsed < 0) continue;
    out[id] = Math.min(999, parsed);
  }
  return out;
}

function buildHtmlLayout(renderConfig, baseLayout) {
  const tuning = renderConfig?.layoutTuning || {};
  const marginPt = Number(tuning.pageMargin || baseLayout.margin || 46);
  const stemSizePt = Number(renderConfig?.font?.size || baseLayout.stemSize || 11.0);
  const baseLineHeight = Number(tuning.lineHeight || baseLayout.lineHeight || 15.0);
  const lineHeightPt = Math.round(baseLineHeight * 1.4 * 10) / 10;
  const layoutColumns = Number(renderConfig?.layoutColumns || 1) === 2 ? 2 : 1;
  const parsedMaxQuestionsPerPage = Number.parseInt(
    String(renderConfig?.maxQuestionsPerPage || ''),
    10,
  );
  const maxQuestionsPerPage = Number.isFinite(parsedMaxQuestionsPerPage) && parsedMaxQuestionsPerPage > 0
    ? parsedMaxQuestionsPerPage
    : 0;
  const subjectTitleText = normalizeWhitespace(renderConfig?.subjectTitleText || '수학 영역') || '수학 영역';
  const titlePageTopText =
    normalizeWhitespace(renderConfig?.titlePageTopText || '2026학년도 대학수학능력시험 문제지')
    || '2026학년도 대학수학능력시험 문제지';
  const titlePageIndices = normalizeTitlePageIndices(
    renderConfig?.titlePageIndices || renderConfig?.titlePages,
  );
  const titlePageHeaders = normalizeTitlePageHeaders(
    renderConfig?.titlePageHeaders || renderConfig?.titleHeaders,
    titlePageIndices,
    subjectTitleText,
  );
  const includeCoverPage = renderConfig?.includeCoverPage === true;
  const includeAcademyLogo = renderConfig?.includeAcademyLogo === true;
  const academyLogoDataUrl = includeAcademyLogo
    ? String(renderConfig?.academyLogoDataUrl || '').trim()
    : '';
  const includeQuestionScore = renderConfig?.includeQuestionScore === true;
  const questionScoreByQuestionId = normalizeQuestionScoreByQuestionId(
    renderConfig?.questionScoreByQuestionId,
  );
  const coverPageTexts = normalizeCoverPageTexts(
    renderConfig?.coverPageTexts || renderConfig?.coverTexts || renderConfig?.coverPageTextConfig,
  );
  return {
    marginMm: Math.max(10, ptToMm(marginPt)),
    stemSizePt,
    lineHeightPt,
    numberLaneWidthPt: Number(tuning.numberLaneWidth || 26),
    numberGapPt: Number(tuning.numberGap || 6),
    questionGapPt: Number(tuning.questionGap || baseLayout.questionGap || 30),
    choiceGapPt: Number(tuning.choiceSpacing || 2),
    layoutColumns,
    columnGapPt: Number(tuning.columnGap || 18),
    layoutMode: normalizeLayoutMode(renderConfig?.layoutMode),
    columnQuestionCounts: normalizeColumnQuestionCounts(
      renderConfig?.columnQuestionCounts,
      layoutColumns,
      maxQuestionsPerPage > 0 ? maxQuestionsPerPage : undefined,
    ),
    pageColumnQuestionCounts: normalizePageColumnQuestionCounts(
      renderConfig?.pageColumnQuestionCounts,
      layoutColumns,
    ),
    columnLabelAnchors: normalizeColumnLabelAnchors(
      renderConfig?.columnLabelAnchors,
      layoutColumns,
    ),
    titlePageIndices,
    titlePageHeaders,
    includeCoverPage,
    includeAcademyLogo,
    academyLogoDataUrl,
    includeQuestionScore,
    questionScoreByQuestionId,
    coverPageTexts,
    alignPolicy: normalizeAlignPolicy(renderConfig?.alignPolicy),
    subjectTitleText,
    titlePageTopText,
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
  qnumFontPath,
  subjectFontPath,
  fontSize,
  baseLayout,
  supabaseClient,
}) {
  const mathRenderer = createMathSvgRenderer();
  const htmlQuestions = (questions || []).map(normalizeQuestionForHtml);
  const figureStats = await hydrateFiguresForHtml(htmlQuestions, supabaseClient);
  const layout = buildHtmlLayout(renderConfig, baseLayout || {});
  const layoutMeta = {};
  const html = buildDocumentHtml({
    profile,
    paper,
    layout,
    questions: htmlQuestions,
    includeAnswerSheet: renderConfig?.includeAnswerSheet === true,
    includeExplanation: renderConfig?.includeExplanation === true,
    includeQuestionScore: layout?.includeQuestionScore === true,
    questionScoreByQuestionId: layout?.questionScoreByQuestionId || {},
    mathRenderer,
    fontFaceCss: buildFontFaceCss({
      regularPath: fontRegularPath,
      boldPath: fontBoldPath,
      qnumFontPath: qnumFontPath || '',
      subjectFontPath: subjectFontPath || '',
    }),
    maxQuestionsPerPage: maxQuestionsPerPage || 99,
    layoutMeta,
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
    includeAnswerSheet: renderConfig?.includeAnswerSheet === true,
    includeExplanation: renderConfig?.includeExplanation === true,
    includeQuestionScore: layout?.includeQuestionScore === true,
    questionScoreByQuestionId: layout?.questionScoreByQuestionId || {},
    includeCoverPage: layout?.includeCoverPage === true,
    includeAcademyLogo: layout?.includeAcademyLogo === true,
    coverPageTexts: layout?.coverPageTexts || normalizeCoverPageTexts(null),
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
    columnLabelAnchors: Array.isArray(layoutMeta.columnLabelAnchors)
      ? layoutMeta.columnLabelAnchors
      : (Array.isArray(layout?.columnLabelAnchors)
        ? layout.columnLabelAnchors
        : []),
    titlePageIndices: Array.isArray(layoutMeta.titlePageIndices)
      ? layoutMeta.titlePageIndices
      : (Array.isArray(layout?.titlePageIndices)
        ? layout.titlePageIndices
        : [1]),
    titlePageHeaders: Array.isArray(layoutMeta.titlePageHeaders)
      ? layoutMeta.titlePageHeaders
      : (Array.isArray(layout?.titlePageHeaders)
        ? layout.titlePageHeaders
        : []),
    titlePageTopText: String(
      layoutMeta.titlePageTopText || layout?.titlePageTopText || '',
    ).trim() || '2026학년도 대학수학능력시험 문제지',
    pageColumnQuestionCounts: Array.isArray(layoutMeta.pageColumnQuestionCounts)
      ? layoutMeta.pageColumnQuestionCounts
      : [],
    exportQuestions: htmlQuestions,
  };
}

export async function buildQuestionPreviewHtml({
  question,
  fontRegularPath,
  boldPath,
  qnumFontPath,
  layout,
  supabaseClient,
}) {
  const mathRenderer = createMathSvgRenderer();
  const q = normalizeQuestionForHtml(question);
  await hydrateFiguresForHtml([q], supabaseClient);
  const fontFaceCss = buildFontFaceCss({
    regularPath: fontRegularPath,
    boldPath: boldPath || '',
    qnumFontPath: qnumFontPath || '',
  });
  return buildPreviewHtml({
    question: q,
    mathRenderer,
    fontFaceCss,
    layout: layout || {},
  });
}

export async function buildDocumentPreviewHtml({
  questions,
  renderConfig,
  profile,
  paper,
  fontRegularPath,
  fontBoldPath,
  qnumFontPath,
  subjectFontPath,
  baseLayout,
  supabaseClient,
  maxQuestionsPerPage,
}) {
  const mathRenderer = createMathSvgRenderer();
  const htmlQuestions = (questions || []).map(normalizeQuestionForHtml);
  await hydrateFiguresForHtml(htmlQuestions, supabaseClient);
  const layout = buildHtmlLayout(renderConfig, baseLayout || {});
  const columns = Number(layout.layoutColumns || 1) === 2 ? 2 : 1;
  return buildDocumentHtml({
    profile,
    paper,
    layout,
    questions: htmlQuestions,
    includeAnswerSheet: renderConfig?.includeAnswerSheet === true,
    includeExplanation: renderConfig?.includeExplanation === true,
    includeQuestionScore: layout?.includeQuestionScore === true,
    questionScoreByQuestionId: layout?.questionScoreByQuestionId || {},
    mathRenderer,
    fontFaceCss: buildFontFaceCss({
      regularPath: fontRegularPath,
      boldPath: fontBoldPath || '',
      qnumFontPath: qnumFontPath || '',
      subjectFontPath: subjectFontPath || '',
    }),
    maxQuestionsPerPage: maxQuestionsPerPage || 99,
  });
}

export async function renderQuestionPreview({
  question,
  fontRegularPath,
  boldPath,
  qnumFontPath,
  layout,
  supabaseClient,
  viewportWidth = 400,
  deviceScaleFactor = 3,
}) {
  const html = await buildQuestionPreviewHtml({
    question,
    fontRegularPath,
    boldPath,
    qnumFontPath,
    layout,
    supabaseClient,
  });
  const pngBuffer = await renderHtmlToImageBuffer(html, viewportWidth, deviceScaleFactor);
  return { pngBuffer, html };
}
