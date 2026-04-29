// VLM(PDF) 추출 엔진의 런타임 진입점.
//
// 운영 워커(problem_bank_extract_worker.js) 의 processOneJob 이 "문서에 PDF 가 붙어
// 있는 경우" 호출한다. 이 모듈은 다음 책임만 진다:
//
//   1. Supabase Storage 에서 PDF 버퍼 다운로드
//   2. Gemini(VLM) 호출 → JSON 파싱
//   3. 결과 questions[] 를 "기존 HWPX 파이프라인이 기대하는 buildQuestionWritePayload
//      호환 shape" 으로 변환 (stem 포맷·객관식/주관식 구분·allow_* 플래그 포함)
//
// DB write, 잡 상태 전이, figure-job 큐잉 같은 후처리는 호출 측(processOneJob) 이
// 이미 가진 공통 코드로 처리하도록 맡긴다. 즉 이 runner 는 "파서 교체 판" 역할만 함.

import { PDFDocument } from 'pdf-lib';
import { callGeminiWithPdf } from './client.js';
import { normalizeVlmQuestion, buildRowUpdate } from './writeback.js';

function compact(v) {
  return String(v || '').trim();
}

const TEXTBOOK_ANSWER_IMAGE_BUCKET = 'textbook-answer-images';
const ANSWER_IMAGE_MARKER_RE = /(?:\[\s*image\s*\]|\(\s*image\s*\)|\[그림\]|\[\[PB_ANSWER_FIG_[^\]]+\]\])/i;
const TEXTBOOK_VLM_CHUNK_MAX_PAGES = Math.max(
  1,
  Number.parseInt(process.env.PB_TEXTBOOK_VLM_CHUNK_PAGES || '4', 10) || 4,
);

function parsePositiveInt(v) {
  const n = Number.parseInt(String(v ?? '').trim(), 10);
  return Number.isFinite(n) && n > 0 ? n : null;
}

function problemNumberKey(v) {
  const n = Number.parseInt(String(v ?? '').trim(), 10);
  return Number.isFinite(n) && n > 0 ? String(n) : '';
}

function normalizeCompactFractionCommands(input) {
  let out = String(input || '');
  for (let i = 0; i < 4; i += 1) {
    const next = out
      .replace(
        /\\(?:dfrac|tfrac|frac)\s*\{([^{}]+)\}\s*\{([^{}]+)\}/g,
        (_, a, b) => `\\frac{${String(a).trim()}}{${String(b).trim()}}`,
      )
      .replace(
        /\\(?:dfrac|tfrac|frac)\s*\{([^{}]+)\}\s*([A-Za-z0-9])/g,
        (_, a, b) => `\\frac{${String(a).trim()}}{${b}}`,
      )
      .replace(
        /\\(?:dfrac|tfrac|frac)\s*([A-Za-z0-9])\s*\{([^{}]+)\}/g,
        (_, a, b) => `\\frac{${a}}{${String(b).trim()}}`,
      )
      .replace(
        /\\(?:dfrac|tfrac|frac)\s*([A-Za-z0-9])\s*([A-Za-z0-9])/g,
        (_, a, b) => `\\frac{${a}}{${b}}`,
      );
    if (next === out) break;
    out = next;
  }
  return out;
}

function normalizeSidecarAnswerText(input) {
  let out = String(input || '');
  for (let i = 0; i < 6; i += 1) {
    const next = out
      .replace(/\\(?:text|mathrm)\s*\{([^{}]*)\}/g, '$1')
      .replace(/\\textstyle\b/g, '')
      .replace(/\\displaystyle\b/g, '');
    if (next === out) break;
    out = next;
  }
  return normalizeCompactFractionCommands(out)
    .replace(/\(\s*image\s*\)/gi, '[image]')
    .replace(/\[\s*image\s*\]/gi, '[image]')
    .replace(/\s+/g, ' ')
    .trim();
}

function resolveTextbookPageRange(textbookScope, pageCount) {
  const from = parsePositiveInt(textbookScope?.raw_page_from);
  const to = parsePositiveInt(textbookScope?.raw_page_to);
  if (!from || !to || !Number.isFinite(pageCount) || pageCount <= 0) {
    return null;
  }
  const start = Math.min(Math.max(from, 1), pageCount);
  const end = Math.min(Math.max(to, 1), pageCount);
  if (end < start) return null;
  return { start, end };
}

async function slicePdfPages(pdfBuffer, pageRange) {
  if (!pageRange) {
    return {
      buffer: pdfBuffer,
      originalPageCount: null,
      slicedPageCount: null,
      pageRange: null,
    };
  }
  const src = await PDFDocument.load(pdfBuffer);
  const originalPageCount = src.getPageCount();
  const resolved = resolveTextbookPageRange(pageRange, originalPageCount);
  if (!resolved) {
    return {
      buffer: pdfBuffer,
      originalPageCount,
      slicedPageCount: originalPageCount,
      pageRange: null,
    };
  }
  if (resolved.start === 1 && resolved.end === originalPageCount) {
    return {
      buffer: pdfBuffer,
      originalPageCount,
      slicedPageCount: originalPageCount,
      pageRange: resolved,
    };
  }

  // copyPages preserves the source page contents/resources; it does not rasterize.
  const out = await PDFDocument.create();
  const indices = [];
  for (let p = resolved.start; p <= resolved.end; p += 1) {
    indices.push(p - 1);
  }
  const pages = await out.copyPages(src, indices);
  for (const page of pages) out.addPage(page);
  const sliced = Buffer.from(await out.save({ useObjectStreams: false }));
  return {
    buffer: sliced,
    originalPageCount,
    slicedPageCount: pages.length,
    pageRange: resolved,
  };
}

function buildTextbookScopeForPageRange(textbookScope, pageRange) {
  if (!textbookScope || typeof textbookScope !== 'object' || !pageRange) {
    return textbookScope;
  }
  const rawFrom = parsePositiveInt(textbookScope.raw_page_from);
  const displayFrom = parsePositiveInt(textbookScope.display_page_from);
  const pageOffset =
    rawFrom && displayFrom ? rawFrom - displayFrom : null;
  return {
    ...textbookScope,
    raw_page_from: pageRange.start,
    raw_page_to: pageRange.end,
    ...(Number.isFinite(pageOffset)
      ? {
          display_page_from: pageRange.start - pageOffset,
          display_page_to: pageRange.end - pageOffset,
        }
      : {}),
  };
}

async function slicePdfPagesFromLoadedDocument(src, pageRange) {
  // copyPages preserves the source page contents/resources; it does not rasterize.
  const out = await PDFDocument.create();
  const indices = [];
  for (let p = pageRange.start; p <= pageRange.end; p += 1) {
    indices.push(p - 1);
  }
  const pages = await out.copyPages(src, indices);
  for (const page of pages) out.addPage(page);
  return Buffer.from(await out.save({ useObjectStreams: false }));
}

async function buildVlmPdfInputs({
  originalPdfBuffer,
  textbookScope,
  maxPagesPerChunk = TEXTBOOK_VLM_CHUNK_MAX_PAGES,
}) {
  const src = await PDFDocument.load(originalPdfBuffer);
  const originalPageCount = src.getPageCount();
  const resolved = resolveTextbookPageRange(textbookScope, originalPageCount);
  if (!resolved) {
    return {
      originalPageCount,
      fullPageRange: null,
      inputs: [
        {
          buffer: originalPdfBuffer,
          pageRange: null,
          slicedPageCount: originalPageCount,
          textbookScope,
          chunkIndex: 1,
          totalChunks: 1,
        },
      ],
    };
  }

  const ranges = [];
  const maxPages = Math.max(1, Number(maxPagesPerChunk) || 1);
  for (let start = resolved.start; start <= resolved.end; start += maxPages) {
    ranges.push({
      start,
      end: Math.min(resolved.end, start + maxPages - 1),
    });
  }
  const inputs = [];
  for (let i = 0; i < ranges.length; i += 1) {
    const pageRange = ranges[i];
    const buffer =
      ranges.length === 1 &&
      pageRange.start === 1 &&
      pageRange.end === originalPageCount
        ? originalPdfBuffer
        : await slicePdfPagesFromLoadedDocument(src, pageRange);
    inputs.push({
      buffer,
      pageRange,
      slicedPageCount: pageRange.end - pageRange.start + 1,
      textbookScope: buildTextbookScopeForPageRange(textbookScope, pageRange),
      chunkIndex: i + 1,
      totalChunks: ranges.length,
    });
  }
  return { originalPageCount, fullPageRange: resolved, inputs };
}

function rebaseSourcePageToOriginal(sourcePage, pageRange, slicedPageCount) {
  const page = Number(sourcePage);
  if (!Number.isFinite(page) || page <= 0 || !pageRange) return sourcePage;
  if (page >= pageRange.start && page <= pageRange.end) return page;
  if (Number.isFinite(slicedPageCount) && page >= 1 && page <= slicedPageCount) {
    return pageRange.start + page - 1;
  }
  return page;
}

function mergeUsageMetadata(usages) {
  const rows = Array.isArray(usages) ? usages.filter(Boolean) : [];
  if (rows.length === 0) return null;
  const out = {};
  const numericKeys = [
    'promptTokenCount',
    'candidatesTokenCount',
    'totalTokenCount',
    'cachedContentTokenCount',
  ];
  for (const key of numericKeys) {
    const sum = rows.reduce((acc, row) => acc + Number(row?.[key] || 0), 0);
    if (sum > 0) out[key] = sum;
  }
  const detailByModality = new Map();
  for (const row of rows) {
    for (const detail of row?.promptTokensDetails || []) {
      const modality = compact(detail?.modality || 'UNKNOWN') || 'UNKNOWN';
      const prev = detailByModality.get(modality) || 0;
      detailByModality.set(modality, prev + Number(detail?.tokenCount || 0));
    }
  }
  if (detailByModality.size > 0) {
    out.promptTokensDetails = Array.from(detailByModality.entries()).map(
      ([modality, tokenCount]) => ({ modality, tokenCount }),
    );
  }
  return out;
}

function mergeVlmDocumentMeta(chunkResults, questionCount, sentPageCount) {
  const metas = (chunkResults || [])
    .map((result) => result?.parsedJson?.document_meta)
    .filter((meta) => meta && typeof meta === 'object');
  const confidenceRank = { low: 0, medium: 1, high: 2 };
  let confidence = 'high';
  for (const meta of metas) {
    const next = compact(meta.confidence || 'high');
    if ((confidenceRank[next] ?? 2) < (confidenceRank[confidence] ?? 2)) {
      confidence = next;
    }
  }
  return {
    total_questions: questionCount,
    page_count: sentPageCount,
    confidence,
  };
}

async function callGeminiChunkWithRetry({
  input,
  model,
  apiKey,
  timeoutMs,
  log = null,
}) {
  const maxAttempts = Math.max(
    1,
    Number.parseInt(process.env.PB_TEXTBOOK_VLM_CHUNK_RETRIES || '2', 10) || 2,
  );
  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    try {
      if (typeof log === 'function') {
        log('vlm_chunk_call_start', {
          chunkIndex: input.chunkIndex,
          totalChunks: input.totalChunks,
          attempt,
          pageRange: input.pageRange,
          pdfBytes: input.buffer.length,
        });
      }
      const result = await callGeminiWithPdf({
        pdfBuffer: input.buffer,
        model,
        apiKey,
        timeoutMs,
        textbookScope: input.textbookScope,
      });
      if (typeof log === 'function') {
        log('vlm_chunk_call_done', {
          chunkIndex: input.chunkIndex,
          totalChunks: input.totalChunks,
          attempt,
          pageRange: input.pageRange,
          elapsedMs: result?.elapsedMs || 0,
          questionCount: Array.isArray(result?.parsedJson?.questions)
            ? result.parsedJson.questions.length
            : 0,
          finishReason: result?.finishReason || '',
        });
      }
      return result;
    } catch (err) {
      const msg = compact(err?.message || err);
      const retryable = /aborted|abort|timeout|deadline|429|500|502|503|504/i.test(msg);
      if (typeof log === 'function') {
        log('vlm_chunk_call_error', {
          chunkIndex: input.chunkIndex,
          totalChunks: input.totalChunks,
          attempt,
          pageRange: input.pageRange,
          retryable,
          message: msg,
        });
      }
      if (!retryable || attempt >= maxAttempts) throw err;
      await new Promise((resolve) => setTimeout(resolve, 1000 * attempt));
    }
  }
  throw new Error('vlm_chunk_retry_exhausted');
}

// 기존 pb_questions 행 리스트를 "question_number → row" 맵으로 구성.
// 같은 번호가 여러 개 있으면 첫 번째만 사용 (메타 보존 목적).
function indexExistingByQuestionNumber(rows) {
  const map = new Map();
  for (const r of rows || []) {
    const key = problemNumberKey(r?.question_number);
    if (!key) continue;
    if (!map.has(key)) map.set(key, r);
  }
  return map;
}

async function fetchTextbookAnswerSidecars({ supa, academyId, textbookScope, log = null }) {
  if (!supa || !textbookScope || typeof textbookScope !== 'object') return new Map();
  const bookId = compact(textbookScope.book_id || textbookScope.bookId);
  const gradeLabel = compact(textbookScope.grade_label || textbookScope.gradeLabel);
  const subKey = compact(textbookScope.sub_key || textbookScope.subKey);
  const bigOrder = Number.parseInt(String(textbookScope.big_order ?? ''), 10);
  const midOrder = Number.parseInt(String(textbookScope.mid_order ?? ''), 10);
  if (
    !academyId ||
    !bookId ||
    !gradeLabel ||
    !subKey ||
    !Number.isFinite(bigOrder) ||
    !Number.isFinite(midOrder)
  ) {
    return new Map();
  }

  try {
    const { data: crops, error: cropErr } = await supa
      .from('textbook_problem_crops')
      .select('id,problem_number')
      .eq('academy_id', academyId)
      .eq('book_id', bookId)
      .eq('grade_label', gradeLabel)
      .eq('big_order', bigOrder)
      .eq('mid_order', midOrder)
      .eq('sub_key', subKey);
    if (cropErr || !Array.isArray(crops) || crops.length === 0) {
      if (typeof log === 'function') {
        log('vlm_textbook_answer_sidecar_skip', {
          reason: cropErr?.message || 'no_crops',
          bookId,
          gradeLabel,
          subKey,
        });
      }
      return new Map();
    }

    const cropById = new Map();
    const cropIds = [];
    for (const crop of crops) {
      const cropId = compact(crop?.id);
      const key = problemNumberKey(crop?.problem_number);
      if (!cropId || !key) continue;
      cropIds.push(cropId);
      cropById.set(cropId, { key, problemNumber: compact(crop.problem_number) });
    }
    if (cropIds.length === 0) return new Map();

    const { data: answers, error: answerErr } = await supa
      .from('textbook_problem_answers')
      .select(
        'crop_id,answer_kind,answer_text,answer_latex_2d,answer_source,' +
          'answer_image_bucket,answer_image_path,answer_image_width_px,' +
          'answer_image_height_px,answer_image_size_bytes,answer_image_content_hash,' +
          'raw_page,display_page,updated_at',
      )
      .in('crop_id', cropIds);
    if (answerErr || !Array.isArray(answers) || answers.length === 0) {
      if (typeof log === 'function') {
        log('vlm_textbook_answer_sidecar_skip', {
          reason: answerErr?.message || 'no_answers',
          cropCount: cropIds.length,
        });
      }
      return new Map();
    }

    const out = new Map();
    for (const answer of answers) {
      const crop = cropById.get(compact(answer?.crop_id));
      if (!crop) continue;
      out.set(crop.key, answer);
    }
    if (typeof log === 'function') {
      log('vlm_textbook_answer_sidecar_loaded', {
        cropCount: cropIds.length,
        answerCount: out.size,
      });
    }
    return out;
  } catch (err) {
    if (typeof log === 'function') {
      log('vlm_textbook_answer_sidecar_skip', {
        reason: compact(err?.message || err),
      });
    }
    return new Map();
  }
}

async function fetchTextbookCropPages({ supa, academyId, textbookScope, log = null }) {
  if (!supa || !textbookScope || typeof textbookScope !== 'object') return new Map();
  const bookId = compact(textbookScope.book_id || textbookScope.bookId);
  const gradeLabel = compact(textbookScope.grade_label || textbookScope.gradeLabel);
  const subKey = compact(textbookScope.sub_key || textbookScope.subKey);
  const bigOrder = Number.parseInt(String(textbookScope.big_order ?? ''), 10);
  const midOrder = Number.parseInt(String(textbookScope.mid_order ?? ''), 10);
  if (
    !academyId ||
    !bookId ||
    !gradeLabel ||
    !subKey ||
    !Number.isFinite(bigOrder) ||
    !Number.isFinite(midOrder)
  ) {
    return new Map();
  }
  try {
    const { data: crops, error } = await supa
      .from('textbook_problem_crops')
      .select('problem_number,raw_page,display_page')
      .eq('academy_id', academyId)
      .eq('book_id', bookId)
      .eq('grade_label', gradeLabel)
      .eq('big_order', bigOrder)
      .eq('mid_order', midOrder)
      .eq('sub_key', subKey);
    if (error || !Array.isArray(crops) || crops.length === 0) {
      if (typeof log === 'function') {
        log('vlm_textbook_crop_page_skip', {
          reason: error?.message || 'no_crops',
          bookId,
          gradeLabel,
          subKey,
        });
      }
      return new Map();
    }
    const out = new Map();
    for (const crop of crops) {
      const key = problemNumberKey(crop?.problem_number);
      const rawPage = Number(crop?.raw_page);
      if (!key || !Number.isFinite(rawPage) || rawPage <= 0) continue;
      out.set(key, {
        rawPage,
        displayPage: Number.isFinite(Number(crop?.display_page))
          ? Number(crop.display_page)
          : null,
      });
    }
    if (typeof log === 'function') {
      log('vlm_textbook_crop_page_loaded', {
        cropPageCount: out.size,
      });
    }
    return out;
  } catch (err) {
    if (typeof log === 'function') {
      log('vlm_textbook_crop_page_skip', {
        reason: compact(err?.message || err),
      });
    }
    return new Map();
  }
}

function applyTextbookAnswerSidecar(vlmQ, sidecar) {
  if (!sidecar || typeof sidecar !== 'object') return vlmQ;
  const kindRaw = compact(sidecar.answer_kind).toLowerCase();
  const rawText = normalizeSidecarAnswerText(sidecar.answer_text);
  const rawLatex = normalizeSidecarAnswerText(sidecar.answer_latex_2d);
  // answer_text is the canonical human-facing answer. answer_latex_2d may carry
  // renderer-only wrappers such as \text{...}, so keep it as fallback only.
  const text = rawText || rawLatex;
  const hasImageMarker = ANSWER_IMAGE_MARKER_RE.test(`${rawText} ${rawLatex}`);
  const kind = kindRaw === 'image' || hasImageMarker ? 'image' : kindRaw;
  const next = { ...(vlmQ || {}) };
  const answer = {
    ...(next.answer && typeof next.answer === 'object' ? next.answer : {}),
  };
  if (kind === 'objective' && text) {
    answer.objective_key = text;
  } else if (kind === 'subjective' && text) {
    answer.subjective = text;
  } else if (kind === 'image') {
    const marker = '[[PB_ANSWER_FIG_1]]';
    const withMarker = text
      ? text
          .replace(/\[\s*image\s*\]/gi, marker)
          .replace(/\(\s*image\s*\)/gi, marker)
          .replace(/\[그림\]/g, marker)
          .replace(/\[\[PB_ANSWER_FIG_[^\]]+\]\]/g, marker)
      : marker;
    answer.subjective = withMarker.includes(marker) ? withMarker : `${withMarker} ${marker}`.trim();
    const imagePath = compact(sidecar.answer_image_path);
    if (imagePath) {
      next.answer_figure_assets = [
        {
          figure_index: 1,
          bucket: compact(sidecar.answer_image_bucket) || TEXTBOOK_ANSWER_IMAGE_BUCKET,
          path: imagePath,
          mime_type: 'image/png',
          approved: true,
          source: 'textbook_answer_vlm',
          created_at: compact(sidecar.updated_at) || new Date().toISOString(),
          width_px: sidecar.answer_image_width_px || undefined,
          height_px: sidecar.answer_image_height_px || undefined,
          size_bytes: sidecar.answer_image_size_bytes || undefined,
          content_hash: sidecar.answer_image_content_hash || undefined,
        },
      ];
    }
  }
  next.answer = answer;
  next.textbook_answer_sidecar = {
    kind,
    source: compact(sidecar.answer_source) || 'vlm',
    raw_page: sidecar.raw_page ?? null,
    display_page: sidecar.display_page ?? null,
    updated_at: compact(sidecar.updated_at),
    has_image_asset: !!compact(sidecar.answer_image_path),
  };
  return next;
}

// VLM question 하나를 "buildQuestionWritePayload" 가 먹을 수 있는 형태로 변환한다.
// existingRow 가 있으면 그쪽의 figure_assets / figure_layout / question_uid 등을 보존.
function toPayloadQuestion({
  vlmQ,
  existingRow,
  sourceOrder,
  modelName,
  reviewConfidenceThreshold,
  textbookScope = null,
  sourcePageRange = null,
  slicedPageCount = null,
}) {
  const rebasedVlmQ = {
    ...(vlmQ || {}),
    source_page: rebaseSourcePageToOriginal(
      vlmQ?.source_page,
      sourcePageRange,
      slicedPageCount,
    ),
  };
  const normalized = normalizeVlmQuestion(rebasedVlmQ);
  const update = buildRowUpdate(existingRow || null, normalized, {
    modelName,
    keepTypeFromDb: false,
  });

  // VLM 은 "uncertain_fields" 길이가 0 이면 high, 아니면 medium 이라고 자체 보고한다.
  // 워커의 lowConfidenceCount 집계는 숫자 confidence 기준이므로 여기서도 숫자로 환산.
  //   high    → 0.9  (임계치 위)
  //   medium  → reviewConfidenceThreshold - 0.05  (임계치 바로 아래 → review_required 유도)
  //   low     → 0.4
  const uncertainCount = Array.isArray(normalized?.uncertain_fields)
    ? normalized.uncertain_fields.length
    : 0;
  const declaredConf = compact(normalized?.vlm_confidence || '');
  let confidence =
    declaredConf === 'low'
      ? 0.4
      : uncertainCount > 0 || declaredConf === 'medium'
        ? Math.max(0, Number(reviewConfidenceThreshold || 0.6) - 0.05)
        : 0.9;

  const updateFlags = Array.isArray(update?.flags) ? update.flags : [];
  const flags = Array.from(
    new Set([
      ...(Array.isArray(normalized?.flags) ? normalized.flags : []),
      ...updateFlags,
    ]),
  ).filter(
    (flag) => flag !== 'contains_figure' || updateFlags.includes('contains_figure'),
  );
  if (flags.includes('objective_multi_answer_incomplete_suspected')) {
    confidence = Math.min(
      confidence,
      Math.max(0, Number(reviewConfidenceThreshold || 0.6) - 0.05),
    );
  }
  const sourcePage = Number.isFinite(Number(normalized?.source_page))
    ? Number(normalized.source_page)
    : null;

  return {
    question_number: String(normalized?.question_number ?? '').trim(),
    source_page: sourcePage,
    source_order: sourceOrder,
    question_type: update.question_type,
    stem: update.stem,
    choices: Array.isArray(normalized?.choices) ? normalized.choices : [],
    figure_refs: update.figure_refs,
    equations: [], // VLM 경로는 수식 token/raw 분리 안 함 (stem 안에 LaTeX 로 그대로 표기)
    source_anchors: [],
    confidence,
    flags,
    is_checked: false,
    reviewed_by: null,
    reviewed_at: null,
    reviewer_notes: '',
    allow_objective: update.allow_objective,
    allow_subjective: update.allow_subjective,
    objective_choices: update.objective_choices,
    objective_answer_key: update.objective_answer_key,
    subjective_answer: update.subjective_answer,
    objective_generated: update.objective_generated,
    meta: {
      ...(update.meta || {}),
      ...(textbookScope ? { textbook_scope: textbookScope } : {}),
      ...(vlmQ?.textbook_crop_page ? { textbook_crop_page: vlmQ.textbook_crop_page } : {}),
    },
  };
}

// processOneJob 이 호출하는 메인 엔트리.
// 반환 shape 은 HWPX 경로의 buildQuestionRows 결과 + parsed.hints 를 흉내 낸다.
export async function runVlmExtraction({
  job,
  doc,
  supa,
  apiKey,
  model,
  reviewConfidenceThreshold = 0.6,
  timeoutMs = 180000,
  log = null,
}) {
  const pdfBucket = compact(
    doc.source_pdf_storage_bucket || doc.source_storage_bucket || 'problem-documents',
  );
  const pdfPath = compact(doc.source_pdf_storage_path);
  if (!pdfPath) {
    throw new Error('vlm_pdf_path_empty');
  }

  const { data: fileData, error: dlErr } = await supa.storage
    .from(pdfBucket)
    .download(pdfPath);
  if (dlErr || !fileData) {
    throw new Error(`vlm_pdf_download_failed:${dlErr?.message || 'no_data'}`);
  }
  const pdfArrayBuf = await fileData.arrayBuffer();
  const originalPdfBuffer = Buffer.from(pdfArrayBuf);
  if (!originalPdfBuffer.length) {
    throw new Error('vlm_pdf_buffer_empty');
  }

  const textbookScope =
    doc?.meta?.textbook_scope && typeof doc.meta.textbook_scope === 'object'
      ? doc.meta.textbook_scope
      : null;
  const pdfInputs = await buildVlmPdfInputs({
    originalPdfBuffer,
    textbookScope,
  });

  if (typeof log === 'function') {
    log('vlm_call_start', {
      jobId: job.id,
      documentId: job.document_id,
      originalPdfBytes: originalPdfBuffer.length,
      pdfBytes: pdfInputs.inputs.reduce((acc, input) => acc + input.buffer.length, 0),
      originalPageCount: pdfInputs.originalPageCount,
      slicedPageCount: pdfInputs.inputs.reduce(
        (acc, input) => acc + Number(input.slicedPageCount || 0),
        0,
      ),
      pageRange: pdfInputs.fullPageRange,
      chunked: pdfInputs.inputs.length > 1,
      chunks: pdfInputs.inputs.map((input) => ({
        chunkIndex: input.chunkIndex,
        totalChunks: input.totalChunks,
        pageRange: input.pageRange,
        slicedPageCount: input.slicedPageCount,
        pdfBytes: input.buffer.length,
      })),
      model,
    });
  }

  const chunkResults = [];
  const vlmQuestions = [];
  for (const input of pdfInputs.inputs) {
    const geminiResult = await callGeminiChunkWithRetry({
      input,
      model,
      apiKey,
      timeoutMs,
      log,
    });
    chunkResults.push(geminiResult);
    const chunkQuestions = Array.isArray(geminiResult?.parsedJson?.questions)
      ? geminiResult.parsedJson.questions
      : [];
    for (const rawQuestion of chunkQuestions) {
      vlmQuestions.push({
        ...(rawQuestion || {}),
        source_page: rebaseSourcePageToOriginal(
          rawQuestion?.source_page,
          input.pageRange,
          input.slicedPageCount,
        ),
      });
    }
  }

  if (vlmQuestions.length === 0) {
    throw new Error('vlm_no_questions_in_response');
  }

  // 기존 pb_questions 를 한 번 조회해 figure_assets / figure_layout / question_uid 보존.
  // 첫 추출 케이스에서는 rows=[] 라 단순히 새 문항을 insert 하게 된다.
  const { data: existingRows, error: existingErr } = await supa
    .from('pb_questions')
    .select('id,question_number,question_uid,meta,question_type')
    .eq('academy_id', job.academy_id)
    .eq('document_id', job.document_id);
  if (existingErr) {
    throw new Error(`vlm_existing_fetch_failed:${existingErr.message}`);
  }
  const existingByNum = indexExistingByQuestionNumber(existingRows || []);
  const answerSidecars = await fetchTextbookAnswerSidecars({
    supa,
    academyId: job.academy_id,
    textbookScope,
    log,
  });
  const cropPagesByNumber = await fetchTextbookCropPages({
    supa,
    academyId: job.academy_id,
    textbookScope,
    log,
  });

  // 문항 번호 기준 오름차순으로 source_order 부여. 번호가 비어있는 케이스는 맨 뒤로 밀어낸다.
  const ordered = vlmQuestions.slice().sort((a, b) => {
    const na = Number.parseInt(String(a?.question_number || '').trim(), 10);
    const nb = Number.parseInt(String(b?.question_number || '').trim(), 10);
    if (!Number.isFinite(na) && !Number.isFinite(nb)) return 0;
    if (!Number.isFinite(na)) return 1;
    if (!Number.isFinite(nb)) return -1;
    return na - nb;
  });

  let lowConfidenceCount = 0;
  const payloadQuestions = ordered.map((vlmQ, idx) => {
    const qKey = problemNumberKey(vlmQ?.question_number);
    const existingRow = qKey ? existingByNum.get(qKey) || null : null;
    let enrichedVlmQ = qKey
      ? applyTextbookAnswerSidecar(vlmQ, answerSidecars.get(qKey))
      : vlmQ;
    const cropPage = qKey ? cropPagesByNumber.get(qKey) : null;
    if (cropPage?.rawPage) {
      enrichedVlmQ = {
        ...(enrichedVlmQ || {}),
        source_page: cropPage.rawPage,
        textbook_crop_page: {
          raw_page: cropPage.rawPage,
          display_page: cropPage.displayPage,
          source: 'textbook_problem_crops',
        },
      };
    }
    const payload = toPayloadQuestion({
      vlmQ: enrichedVlmQ,
      existingRow,
      sourceOrder: idx + 1,
      modelName: model,
      reviewConfidenceThreshold,
      textbookScope,
      sourcePageRange: null,
      slicedPageCount: null,
    });
    if (Number(payload.confidence || 0) < Number(reviewConfidenceThreshold || 0.6)) {
      lowConfidenceCount += 1;
    }
    return payload;
  });

  const stats = {
    circledChoices: payloadQuestions.filter(
      (q) => q.question_type === '객관식' && (q.objective_choices || []).length > 0,
    ).length,
    viewBlocks: payloadQuestions.filter((q) =>
      /\[보기시작\]/.test(String(q.stem || '')),
    ).length,
    figureLines: payloadQuestions.reduce(
      (acc, q) =>
        acc + (String(q.stem || '').match(/\[그림\]/g) || []).length,
      0,
    ),
    mockMarkers: 0,
    csatMarkers: 0,
    equationRefs: 0,
    questionCount: payloadQuestions.length,
    sourceLineCount: 0,
    segmentedLineCount: 0,
    answerHintCount: 0,
    lowConfidenceCount,
    examProfile: '',
  };

  return {
    built: { questions: payloadQuestions, stats },
    parsed: { hints: { scoreHeaderCount: 0, previewLineCount: 0 } },
    meta: {
      engine: 'vlm',
      model,
      documentMeta: mergeVlmDocumentMeta(
        chunkResults,
        payloadQuestions.length,
        pdfInputs.inputs.reduce((acc, input) => acc + Number(input.slicedPageCount || 0), 0),
      ),
      pdfInput: {
        originalBytes: originalPdfBuffer.length,
        sentBytes: pdfInputs.inputs.reduce((acc, input) => acc + input.buffer.length, 0),
        originalPageCount: pdfInputs.originalPageCount,
        sentPageCount: pdfInputs.inputs.reduce(
          (acc, input) => acc + Number(input.slicedPageCount || 0),
          0,
        ),
        pageRange: pdfInputs.fullPageRange,
        chunked: pdfInputs.inputs.length > 1,
        chunkCount: pdfInputs.inputs.length,
        chunks: pdfInputs.inputs.map((input, idx) => ({
          chunkIndex: input.chunkIndex,
          pageRange: input.pageRange,
          sentBytes: input.buffer.length,
          sentPageCount: input.slicedPageCount,
          questionCount: Array.isArray(chunkResults[idx]?.parsedJson?.questions)
            ? chunkResults[idx].parsedJson.questions.length
            : 0,
          elapsedMs: chunkResults[idx]?.elapsedMs || 0,
          finishReason: chunkResults[idx]?.finishReason || '',
        })),
        preservesOriginalPages: true,
      },
      usage: mergeUsageMetadata(chunkResults.map((result) => result?.usageMetadata)),
      elapsedMs: chunkResults.reduce((acc, result) => acc + Number(result?.elapsedMs || 0), 0),
      finishReason: chunkResults.map((result) => result?.finishReason || '').filter(Boolean).join(','),
    },
  };
}
