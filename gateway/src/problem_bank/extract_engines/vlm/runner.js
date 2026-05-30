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

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFile as execFileCb } from 'node:child_process';
import { promisify } from 'node:util';
import { PDFDocument } from 'pdf-lib';
import { createHash, randomUUID } from 'node:crypto';
import sharp from 'sharp';
import { callGeminiWithPdf } from './client.js';
import { normalizeVlmQuestion, buildRowUpdate } from './writeback.js';

const execFileAsync = promisify(execFileCb);

function compact(v) {
  return String(v || '').trim();
}

const TEXTBOOK_ANSWER_IMAGE_BUCKET = 'textbook-answer-images';
const PDF_FIGURE_BUCKET = 'problem-previews';
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

function stableShortHash(value) {
  return createHash('sha1').update(String(value || '')).digest('hex').slice(0, 12);
}

function parseBbox1k(raw) {
  const source = Array.isArray(raw)
    ? raw
    : Array.isArray(raw?.bbox_1k)
      ? raw.bbox_1k
      : Array.isArray(raw?.bbox)
        ? raw.bbox
        : Array.isArray(raw?.region_1k)
          ? raw.region_1k
          : null;
  if (!source || source.length !== 4) return null;
  const values = source.map((v) => Number(v));
  if (values.some((v) => !Number.isFinite(v))) return null;
  const [y1, x1, y2, x2] = values.map((v) => Math.max(0, Math.min(1000, Math.round(v))));
  if (y2 <= y1 || x2 <= x1) return null;
  if ((y2 - y1) < 8 || (x2 - x1) < 8) return null;
  return [y1, x1, y2, x2];
}

function safeObjectPathPart(value, fallback = 'item') {
  const safe = String(value || '')
    .trim()
    .replace(/[^A-Za-z0-9_.-]+/g, '_')
    .replace(/^_+|_+$/g, '');
  return safe || fallback;
}

async function renderPdfPageToPng(pdfBuffer, pageNumber, { dpi = 220 } = {}) {
  const page = Number.parseInt(String(pageNumber ?? ''), 10);
  if (!Number.isFinite(page) || page <= 0) return null;
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pb-pdf-figure-'));
  const pdfPath = path.join(dir, 'source.pdf');
  const outBase = path.join(dir, 'page');
  try {
    fs.writeFileSync(pdfPath, pdfBuffer);
    await execFileAsync(
      'pdftoppm',
      ['-png', '-f', String(page), '-l', String(page), '-singlefile', '-r', String(dpi), pdfPath, outBase],
      { timeout: 60_000, cwd: dir, windowsHide: true },
    );
    const pngPath = `${outBase}.png`;
    if (!fs.existsSync(pngPath)) return null;
    return fs.readFileSync(pngPath);
  } finally {
    try {
      fs.rmSync(dir, { recursive: true, force: true });
    } catch (_) {}
  }
}

async function cropPdfFigureFromPagePng(pagePng, bbox1k) {
  if (!Buffer.isBuffer(pagePng) || pagePng.length === 0 || !bbox1k) return null;
  const meta = await sharp(pagePng).metadata();
  const width = Number(meta.width || 0);
  const height = Number(meta.height || 0);
  if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) {
    return null;
  }
  const [y1, x1, y2, x2] = bbox1k;
  // VLM bbox already includes the detected figure; keep only a small guard band
  // so adjacent problem text is not pulled into the initial crop.
  const pad = Math.max(4, Math.round(Math.min(width, height) * 0.006));
  const left = Math.max(0, Math.floor((x1 / 1000) * width) - pad);
  const top = Math.max(0, Math.floor((y1 / 1000) * height) - pad);
  const right = Math.min(width, Math.ceil((x2 / 1000) * width) + pad);
  const bottom = Math.min(height, Math.ceil((y2 / 1000) * height) + pad);
  const cropWidth = Math.max(1, right - left);
  const cropHeight = Math.max(1, bottom - top);
  if (cropWidth < 16 || cropHeight < 16) return null;
  const bytes = await sharp(pagePng)
    .extract({ left, top, width: cropWidth, height: cropHeight })
    .png({ compressionLevel: 9, adaptiveFiltering: true })
    .toBuffer();
  const croppedMeta = await sharp(bytes).metadata();
  return {
    bytes,
    width: Number(croppedMeta.width || cropWidth),
    height: Number(croppedMeta.height || cropHeight),
    cropRectPx: { left, top, width: cropWidth, height: cropHeight },
  };
}

function textbookSubKey(textbookScope) {
  return compact(textbookScope?.sub_key || textbookScope?.subKey).toUpperCase();
}

function stripStructuralPreviewMarkers(lines) {
  return lines.filter((line) => {
    const s = compact(line);
    if (!s) return false;
    return !/^\[(?:문단|박스시작|박스끝)\]$/.test(s);
  });
}

function splitRepeatedIndependentCommonStem(stem) {
  const rawLines = String(stem || '').split(/\r?\n/);
  const lines = stripStructuralPreviewMarkers(rawLines);
  if (lines.length < 2) return null;
  const first = compact(lines[0]);
  if (!first) return null;
  const commonPromptVerbs =
    '(?:나타내시오|구하시오|답하시오|쓰시오|써넣으시오|계산하시오|완성하시오|고르시오|서술하시오|푸시오|이항하시오|비교하시오|판별하시오)';
  const trailingCondition = '(?:\\.?\\s*\\([^)]*\\))?\\.?$';
  const looksLikeCommonPrompt =
    new RegExp(`(?:다음|아래|보기).*${commonPromptVerbs}${trailingCondition}`).test(first) ||
    new RegExp(`(?:거듭제곱|제곱근|인수분해|소인수분해|식|값).*${commonPromptVerbs}${trailingCondition}`).test(first);
  if (!looksLikeCommonPrompt) return null;
  const rest = lines.slice(1).join('\n').trim();
  if (!rest) return null;
  return { commonStem: first, itemStem: rest };
}

function independentCommonStemCompareKey(commonStem) {
  return compact(commonStem)
    .replace(/\[+\s*공백\s*:\s*\d+\s*\]+/g, '[공백]')
    .replace(/\s+/g, ' ');
}

function contentLinesWithoutStructuralMarkers(value) {
  return String(value || '')
    .split(/\r?\n/)
    .map((line) => compact(line))
    .filter((line) => line && !/^\[(?:문단|박스시작|박스끝)\]$/.test(line));
}

function trimTrailingStructuralMarkers(value) {
  const lines = String(value || '')
    .split(/\r?\n/)
    .map((line) => compact(line))
    .filter(Boolean);
  while (lines.length > 0 && /^\[(?:문단|박스시작|박스끝)\]$/.test(lines[lines.length - 1])) {
    lines.pop();
  }
  return lines.join('\n').trim();
}

function stripItemStemFromIndependentCommonStem(commonStem, itemStem) {
  const common = compact(commonStem);
  if (!common) return '';
  const itemLines = contentLinesWithoutStructuralMarkers(itemStem);
  if (itemLines.length === 0) return trimTrailingStructuralMarkers(common);
  const itemText = itemLines.join('\n').trim();
  const commonLines = contentLinesWithoutStructuralMarkers(common);
  const commonText = commonLines.join('\n').trim();
  if (!itemText || !commonText.endsWith(itemText)) {
    return trimTrailingStructuralMarkers(common);
  }
  const prefix = commonText.slice(0, commonText.length - itemText.length).trim();
  return trimTrailingStructuralMarkers(prefix || common);
}

function normalizeSetHeaderRange(crop) {
  const headerNumber = compact(crop?.problem_number);
  let from = Number.parseInt(String(crop?.set_from ?? ''), 10);
  let to = Number.parseInt(String(crop?.set_to ?? ''), 10);
  if (!Number.isFinite(from) || !Number.isFinite(to)) {
    const match = headerNumber.match(/(\d+)\s*[~\-\u2013\u2014\u301c]\s*(\d+)/);
    if (match) {
      from = Number.parseInt(match[1], 10);
      to = Number.parseInt(match[2], 10);
    }
  }
  if (!Number.isFinite(from) || !Number.isFinite(to) || from <= 0 || to < from) {
    return null;
  }
  return {
    from,
    to,
    headerNumber,
    rawPage: Number.isFinite(Number(crop?.raw_page)) ? Number(crop.raw_page) : null,
    displayPage: Number.isFinite(Number(crop?.display_page)) ? Number(crop.display_page) : null,
  };
}

function emptyTextbookCropIndex() {
  return { byNumber: new Map(), setHeaderRanges: [] };
}

function normalizeIndependentSetPayloadQuestions(
  payloadQuestions,
  textbookScope,
  setHeaderRanges = [],
) {
  const rows = Array.isArray(payloadQuestions) ? payloadQuestions : [];
  const isBasicDrill = textbookSubKey(textbookScope) === 'A';
  if (!isBasicDrill || rows.length < 1) return rows;

  const candidates = rows.map((row) => {
    const split = splitRepeatedIndependentCommonStem(row?.stem);
    return { row, split };
  });

  let i = 0;
  while (i < candidates.length) {
    const split = candidates[i].split;
    if (!split) {
      i += 1;
      continue;
    }
    let j = i + 1;
    while (
      j < candidates.length &&
      candidates[j].split &&
      independentCommonStemCompareKey(candidates[j].split.commonStem) ===
        independentCommonStemCompareKey(split.commonStem)
    ) {
      j += 1;
    }
    const groupSize = j - i;
    if (groupSize >= 2) {
      const scopeKey = [
        textbookScope?.book_id || textbookScope?.bookId || '',
        textbookScope?.grade_label || textbookScope?.gradeLabel || '',
        textbookScope?.big_order ?? textbookScope?.bigOrder ?? '',
        textbookScope?.mid_order ?? textbookScope?.midOrder ?? '',
        textbookScope?.sub_key || textbookScope?.subKey || '',
      ].join(':');
      const setKey = `independent:${stableShortHash(`${scopeKey}:${split.commonStem}:${i}`)}`;
      for (let k = i; k < j; k += 1) {
        const { row, split: oneSplit } = candidates[k];
        const prevMeta = row.meta && typeof row.meta === 'object' ? row.meta : {};
        row.stem = oneSplit.itemStem;
        row.meta = {
          ...prevMeta,
          is_set_question: true,
          set_model: {
            ...(prevMeta.set_model && typeof prevMeta.set_model === 'object'
              ? prevMeta.set_model
              : {}),
            version: 1,
            set_type: 'independent_set',
            set_key: setKey,
            common_stem: split.commonStem,
            item_label: String(row.question_number || '').trim(),
            item_order: k - i + 1,
            delivery_policy: 'independent_items_with_common_stem',
          },
        };
      }
    }
    i = j;
  }

  const rangeByQuestionKey = new Map();
  const scopeKey = [
    textbookScope?.book_id || textbookScope?.bookId || '',
    textbookScope?.grade_label || textbookScope?.gradeLabel || '',
    textbookScope?.big_order ?? textbookScope?.bigOrder ?? '',
    textbookScope?.mid_order ?? textbookScope?.midOrder ?? '',
    textbookScope?.sub_key || textbookScope?.subKey || '',
  ].join(':');
  for (const range of Array.isArray(setHeaderRanges) ? setHeaderRanges : []) {
    const from = Number(range?.from);
    const to = Number(range?.to);
    if (!Number.isFinite(from) || !Number.isFinite(to) || to < from) continue;
    const rangeKey = compact(range?.headerNumber) || `${from}-${to}`;
    const setKey = `textbook:${stableShortHash(`${scopeKey}:${rangeKey}:${from}:${to}`)}`;
    for (let n = from; n <= to; n += 1) {
      rangeByQuestionKey.set(String(n), { ...range, setKey, itemOrder: n - from + 1 });
    }
  }

  if (rangeByQuestionKey.size > 0) {
    const commonBySetKey = new Map();
    const commonByHeaderSetKey = new Map();
    for (const row of rows) {
      const setModel = row?.meta?.set_model && typeof row.meta.set_model === 'object'
        ? row.meta.set_model
        : {};
      const setKey = compact(setModel.set_key || setModel.setKey);
      const common = stripItemStemFromIndependentCommonStem(
        setModel.common_stem || setModel.commonStem,
        row?.stem,
      );
      if (setKey && common && !commonBySetKey.has(setKey)) {
        commonBySetKey.set(setKey, common);
      }
      const range = rangeByQuestionKey.get(problemNumberKey(row?.question_number));
      if (range && common && !commonByHeaderSetKey.has(range.setKey)) {
        commonByHeaderSetKey.set(range.setKey, common);
      }
    }
    for (const row of rows) {
      const qKey = problemNumberKey(row?.question_number);
      const range = rangeByQuestionKey.get(qKey);
      if (!range) continue;
      const prevMeta = row.meta && typeof row.meta === 'object' ? row.meta : {};
      const prevSet = prevMeta.set_model && typeof prevMeta.set_model === 'object'
        ? prevMeta.set_model
        : {};
      const ownCommonStem = stripItemStemFromIndependentCommonStem(
        prevSet.common_stem || prevSet.commonStem,
        row?.stem,
      );
      const commonStem = ownCommonStem
        || commonBySetKey.get(range.setKey)
        || commonByHeaderSetKey.get(range.setKey)
        || '';
      const nextFlags = Array.from(new Set([
        ...(Array.isArray(row.flags) ? row.flags : []),
        ...(!commonStem ? ['independent_set_common_stem_missing'] : []),
      ]));
      row.flags = nextFlags;
      row.meta = {
        ...prevMeta,
        is_set_question: true,
        set_model: {
          ...prevSet,
          version: 1,
          set_type: 'independent_set',
          set_key: range.setKey,
          ...(commonStem ? { common_stem: commonStem } : {}),
          item_label: String(row.question_number || '').trim(),
          item_order: range.itemOrder,
          delivery_policy: 'independent_items_with_common_stem',
          source: 'textbook_problem_crops.set_header',
          header_number: range.headerNumber || `${range.from}-${range.to}`,
          range_from: range.from,
          range_to: range.to,
        },
      };
    }
  }
  return rows;
}

function expectedQuestionKeys(numbers) {
  return (Array.isArray(numbers) ? numbers : [])
    .map((number) => problemNumberKey(number))
    .filter(Boolean);
}

function missingExpectedQuestionNumbers(questions, expectedNumbers) {
  const expected = expectedQuestionKeys(expectedNumbers);
  if (expected.length === 0) return [];
  const found = new Set(
    (Array.isArray(questions) ? questions : [])
      .map((question) => problemNumberKey(question?.question_number))
      .filter(Boolean),
  );
  return expected.filter((key) => !found.has(key));
}

function isDailyQuotaExceededMessage(input) {
  const text = String(input || '').toLowerCase();
  return (
    text.includes('resource_exhausted') &&
    (text.includes('generate_requests_per_model_per_day') ||
      text.includes('please retry in'))
  );
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
        expectedQuestionNumbers: input.expectedQuestionNumbers,
        expectedIndependentSetRanges: input.expectedIndependentSetRanges,
      });
      const chunkQuestions = Array.isArray(result?.parsedJson?.questions)
        ? result.parsedJson.questions
        : [];
      const missingExpected = missingExpectedQuestionNumbers(
        chunkQuestions,
        input.expectedQuestionNumbers,
      );
      if (missingExpected.length > 0) {
        throw new Error(
          `vlm_missing_expected_questions:${missingExpected.join(',')}`,
        );
      }
      if (typeof log === 'function') {
        log('vlm_chunk_call_done', {
          chunkIndex: input.chunkIndex,
          totalChunks: input.totalChunks,
          attempt,
          pageRange: input.pageRange,
          expectedQuestionCount: Array.isArray(input.expectedQuestionNumbers)
            ? input.expectedQuestionNumbers.length
            : 0,
          elapsedMs: result?.elapsedMs || 0,
          questionCount: chunkQuestions.length,
          finishReason: result?.finishReason || '',
        });
      }
      return result;
    } catch (err) {
      const msg = compact(err?.message || err);
      const retryable =
        !isDailyQuotaExceededMessage(msg) &&
        /aborted|abort|timeout|deadline|429|500|502|503|504|missing_expected_questions/i.test(
          msg,
        );
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
  if (!supa || !textbookScope || typeof textbookScope !== 'object') {
    return emptyTextbookCropIndex();
  }
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
    return emptyTextbookCropIndex();
  }
  try {
    const { data: crops, error } = await supa
      .from('textbook_problem_crops')
      .select('problem_number,raw_page,display_page,label,is_set_header,set_from,set_to,content_group_kind,content_group_label,content_group_title,content_group_order,item_region_1k')
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
      return emptyTextbookCropIndex();
    }
    const out = new Map();
    const setHeaderRanges = [];
    for (const crop of crops) {
      if (crop?.is_set_header === true) {
        const range = normalizeSetHeaderRange(crop);
        if (range) setHeaderRanges.push(range);
        continue;
      }
      const key = problemNumberKey(crop?.problem_number);
      const rawPage = Number(crop?.raw_page);
      if (!key || !Number.isFinite(rawPage) || rawPage <= 0) continue;
      out.set(key, {
        problemNumber: compact(crop?.problem_number),
        rawPage,
        displayPage: Number.isFinite(Number(crop?.display_page))
          ? Number(crop.display_page)
          : null,
        problemLabel: compact(crop?.label),
        contentGroup: {
          kind: compact(crop?.content_group_kind),
          label: compact(crop?.content_group_label),
          title: compact(crop?.content_group_title),
          order: Number.isFinite(Number(crop?.content_group_order))
            ? Number(crop.content_group_order)
            : null,
        },
      });
    }
    if (typeof log === 'function') {
      log('vlm_textbook_crop_page_loaded', {
        cropPageCount: out.size,
        setHeaderRangeCount: setHeaderRanges.length,
      });
    }
    setHeaderRanges.sort((a, b) => {
      const pageDelta = Number(a.rawPage || 0) - Number(b.rawPage || 0);
      if (pageDelta !== 0) return pageDelta;
      return Number(a.from || 0) - Number(b.from || 0);
    });
    return { byNumber: out, setHeaderRanges };
  } catch (err) {
    if (typeof log === 'function') {
      log('vlm_textbook_crop_page_skip', {
        reason: compact(err?.message || err),
      });
    }
    return emptyTextbookCropIndex();
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

async function attachPdfFigureAssets({
  supa,
  pdfBuffer,
  job,
  doc,
  vlmQ,
  cropPage = null,
  pagePngCache = null,
  log = null,
}) {
  const figures = Array.isArray(vlmQ?.figures) ? vlmQ.figures : [];
  if (figures.length === 0) return vlmQ;
  const candidates = figures
    .map((figure, idx) => ({
      figure,
      index: Number.isFinite(Number(figure?.order)) && Number(figure.order) > 0
        ? Number(figure.order)
        : idx + 1,
      bbox1k: parseBbox1k(figure),
    }))
    .filter((x) => x.bbox1k);
  if (candidates.length === 0) return vlmQ;

  const rawPage = Number(cropPage?.rawPage || cropPage?.raw_page || vlmQ?.source_page);
  if (!Number.isFinite(rawPage) || rawPage <= 0) return vlmQ;

  let pagePng = null;
  try {
    const cacheKey = String(rawPage);
    if (pagePngCache instanceof Map && pagePngCache.has(cacheKey)) {
      pagePng = pagePngCache.get(cacheKey);
    } else {
      pagePng = await renderPdfPageToPng(pdfBuffer, rawPage, {
        dpi: Number.parseInt(process.env.PB_PDF_FIGURE_RENDER_DPI || '220', 10) || 220,
      });
      if (pagePngCache instanceof Map && pagePng) {
        pagePngCache.set(cacheKey, pagePng);
      }
    }
  } catch (err) {
    if (typeof log === 'function') {
      log('vlm_pdf_figure_render_failed', {
        questionNumber: vlmQ?.question_number,
        rawPage,
        message: compact(err?.message || err),
      });
    }
    return vlmQ;
  }
  if (!pagePng) return vlmQ;

  const nowIso = new Date().toISOString();
  const docPart = safeObjectPathPart(doc?.id || job?.document_id, 'document');
  const jobPart = safeObjectPathPart(job?.id, 'job');
  const questionPart = safeObjectPathPart(vlmQ?.question_number, 'question');
  const assets = [];
  for (const candidate of candidates) {
    try {
      const cropped = await cropPdfFigureFromPagePng(pagePng, candidate.bbox1k);
      if (!cropped) continue;
      const hash = createHash('sha256').update(cropped.bytes).digest('hex');
      const objectPath =
        `${job.academy_id}/${docPart}/pdf-figures/${jobPart}/` +
        `${questionPart}_${candidate.index}_${randomUUID()}.png`;
      const { error: uploadErr } = await supa.storage
        .from(PDF_FIGURE_BUCKET)
        .upload(objectPath, cropped.bytes, {
          contentType: 'image/png',
          upsert: true,
        });
      if (uploadErr) {
        throw new Error(uploadErr.message);
      }
      assets.push({
        id: randomUUID(),
        source: 'textbook_pdf_crop',
        status: 'cropped_from_pdf',
        approved: true,
        review_required: false,
        bucket: PDF_FIGURE_BUCKET,
        path: objectPath,
        mime_type: 'image/png',
        figure_index: candidate.index,
        confidence: 0.86,
        bbox_1k: candidate.bbox1k,
        source_page: rawPage,
        width_px: cropped.width,
        height_px: cropped.height,
        size_bytes: cropped.bytes.length,
        content_hash: hash,
        crop_rect_px: cropped.cropRectPx,
        created_at: nowIso,
      });
    } catch (err) {
      if (typeof log === 'function') {
        log('vlm_pdf_figure_crop_failed', {
          questionNumber: vlmQ?.question_number,
          rawPage,
          figureIndex: candidate.index,
          message: compact(err?.message || err),
        });
      }
    }
  }
  if (assets.length === 0) return vlmQ;

  if (typeof log === 'function') {
    log('vlm_pdf_figure_crops_uploaded', {
      questionNumber: vlmQ?.question_number,
      rawPage,
      assetCount: assets.length,
    });
  }
  return {
    ...(vlmQ || {}),
    pdf_figure_assets: assets,
  };
}

function buildDefaultPdfFigureLayout(assets) {
  const rows = Array.isArray(assets) ? assets : [];
  const items = rows.map((asset, idx) => {
    const figureIndex = Number.isFinite(Number(asset?.figure_index)) && Number(asset.figure_index) > 0
      ? Number(asset.figure_index)
      : idx + 1;
    return {
      assetKey: `idx:${figureIndex}`,
      widthEm: rows.length >= 2 ? 12.0 : 20.0,
      position: 'below-stem',
      anchor: 'center',
      offsetXEm: 0,
      offsetYEm: 0,
    };
  });
  const groups = items.length === 2
    ? [{ type: 'horizontal', members: items.map((item) => item.assetKey), gap: 0.5 }]
    : [];
  return { version: 1, items, groups };
}

function expectedQuestionNumbersForInput(cropPagesByNumber, input) {
  if (!(cropPagesByNumber instanceof Map) || cropPagesByNumber.size === 0) {
    return [];
  }
  const pageRange = input?.pageRange || null;
  const rows = Array.from(cropPagesByNumber.values()).filter((row) => {
    const rawPage = Number(row?.rawPage);
    if (!Number.isFinite(rawPage) || rawPage <= 0) return false;
    if (!pageRange) return true;
    return rawPage >= Number(pageRange.start) && rawPage <= Number(pageRange.end);
  });
  rows.sort((a, b) => {
    const pageDelta = Number(a.rawPage || 0) - Number(b.rawPage || 0);
    if (pageDelta !== 0) return pageDelta;
    return (
      Number.parseInt(String(a.problemNumber || ''), 10) -
      Number.parseInt(String(b.problemNumber || ''), 10)
    );
  });
  return rows.map((row) => row.problemNumber).filter(Boolean);
}

function expectedIndependentSetRangesForInput(setHeaderRanges, input) {
  const ranges = Array.isArray(setHeaderRanges) ? setHeaderRanges : [];
  if (ranges.length === 0) return [];
  const pageRange = input?.pageRange || null;
  return ranges
    .filter((range) => {
      const rawPage = Number(range?.rawPage);
      if (!Number.isFinite(rawPage) || rawPage <= 0) return true;
      if (!pageRange) return true;
      return rawPage >= Number(pageRange.start) && rawPage <= Number(pageRange.end);
    })
    .map((range) => ({
      label: compact(range?.headerNumber) || `${range?.from || ''}~${range?.to || ''}`,
      from: range?.from,
      to: range?.to,
      rawPage: range?.rawPage,
      displayPage: range?.displayPage,
    }))
    .filter((range) => range.label || (range.from && range.to));
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
  const pdfFigureAssets = Array.isArray(normalized?.pdf_figure_assets)
    ? normalized.pdf_figure_assets
    : [];

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
      ...(pdfFigureAssets.length > 0
        ? {
            figure_assets: pdfFigureAssets,
            figure_layout: buildDefaultPdfFigureLayout(pdfFigureAssets),
            figure_review_required: false,
            figure_last_generated_at: new Date().toISOString(),
            figure_crop_source: 'textbook_pdf_crop',
          }
        : {}),
      ...(textbookScope ? { textbook_scope: textbookScope } : {}),
      ...(vlmQ?.textbook_difficulty_label
        ? { textbook_difficulty_label: compact(vlmQ.textbook_difficulty_label) }
        : {}),
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

  const cropIndex = await fetchTextbookCropPages({
    supa,
    academyId: job.academy_id,
    textbookScope,
    log,
  });
  const cropPagesByNumber = cropIndex.byNumber instanceof Map
    ? cropIndex.byNumber
    : new Map();
  const setHeaderRanges = Array.isArray(cropIndex.setHeaderRanges)
    ? cropIndex.setHeaderRanges
    : [];
  for (const input of pdfInputs.inputs) {
    input.expectedQuestionNumbers = expectedQuestionNumbersForInput(
      cropPagesByNumber,
      input,
    );
    input.expectedIndependentSetRanges = expectedIndependentSetRangesForInput(
      setHeaderRanges,
      input,
    );
  }

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
        expectedQuestionCount: Array.isArray(input.expectedQuestionNumbers)
          ? input.expectedQuestionNumbers.length
          : 0,
        independentSetRangeCount: Array.isArray(input.expectedIndependentSetRanges)
          ? input.expectedIndependentSetRanges.length
          : 0,
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
  const payloadQuestionsRaw = [];
  const figurePagePngCache = new Map();
  for (let idx = 0; idx < ordered.length; idx += 1) {
    const vlmQ = ordered[idx];
    const qKey = problemNumberKey(vlmQ?.question_number);
    const existingRow = qKey ? existingByNum.get(qKey) || null : null;
    let enrichedVlmQ = qKey
      ? applyTextbookAnswerSidecar(vlmQ, answerSidecars.get(qKey))
      : vlmQ;
    const cropPage = qKey ? cropPagesByNumber.get(qKey) : null;
    if (cropPage?.rawPage) {
      enrichedVlmQ = {
        ...(enrichedVlmQ || {}),
        source_page: cropPage.displayPage || cropPage.rawPage,
        textbook_crop_page: {
          raw_page: cropPage.rawPage,
          display_page: cropPage.displayPage,
          ...(cropPage.problemLabel
            ? { difficulty_label: cropPage.problemLabel, label: cropPage.problemLabel }
            : {}),
          ...(cropPage.contentGroup?.kind
            ? { content_group: cropPage.contentGroup }
            : {}),
          source: 'textbook_problem_crops',
        },
        ...(cropPage.problemLabel
          ? { textbook_difficulty_label: cropPage.problemLabel }
          : {}),
        ...(cropPage.contentGroup?.kind
          ? { textbook_content_group: cropPage.contentGroup }
          : {}),
      };
    }
    enrichedVlmQ = await attachPdfFigureAssets({
      supa,
      pdfBuffer: originalPdfBuffer,
      job,
      doc,
      vlmQ: enrichedVlmQ,
      cropPage,
      pagePngCache: figurePagePngCache,
      log,
    });
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
    payloadQuestionsRaw.push(payload);
  }
  const payloadQuestions = normalizeIndependentSetPayloadQuestions(
    payloadQuestionsRaw,
    textbookScope,
    setHeaderRanges,
  );

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
          expectedQuestionCount: Array.isArray(input.expectedQuestionNumbers)
            ? input.expectedQuestionNumbers.length
            : 0,
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
