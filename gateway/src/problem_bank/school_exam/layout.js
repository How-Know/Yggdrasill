// 시험지 PDF 에서 본문 글자 크기와 문항 영역을 읽는다. 추출 워커와 검수 준비 API 가 같이 쓴다.
import { PDFDocument } from 'pdf-lib';
import { callGeminiImageJson } from '../../mock_exam/gemini_image.js';
import { logVlmUsage } from '../../textbook/vlm_usage_log.js';
import { detectExamItemRegions, questionHint } from './item_regions.js';
import { readWordBoxes, withTempPdf } from './pdf_tools.js';
import { measureTextEm1k } from './text_em.js';

export function examRegionModel() {
  return String(
    process.env.PB_EXAM_REGION_MODEL ||
      process.env.TEXTBOOK_VLM_MODEL ||
      process.env.PB_VLM_MODEL ||
      'gemini-3.1-pro-preview',
  ).trim();
}

async function pdfPageCount(pdfBuffer, wordPages) {
  if (wordPages.length > 0) return wordPages.length;
  try {
    const doc = await PDFDocument.load(pdfBuffer, { ignoreEncryption: true });
    return doc.getPageCount();
  } catch (_) {
    return 0;
  }
}

/// questions: [{ number, sourcePage, sourceOrder, stem, questionType }]
/// 반환: { textEm1k, emSource, pageCount, regions: Map(번호 → { rawPage, region1k }) }
/// wantRegions 가 false 면 글자 크기만 잰다(AI 호출 없음).
export async function readExamLayout({
  pdfBuffer,
  questions = [],
  apiKey = '',
  model = '',
  timeoutMs = 120_000,
  wantRegions = true,
  log = null,
}) {
  return withTempPdf(pdfBuffer, async (pdfPath, dir) => {
    const wordPages = await readWordBoxes(pdfPath);
    const em = measureTextEm1k(wordPages);
    const pageCount = await pdfPageCount(pdfBuffer, wordPages);
    let regions = new Map();
    const targets = (Array.isArray(questions) ? questions : [])
      .map((q, i) => ({
        key: String(q?.number ?? '').trim(),
        page: Number(q?.sourcePage) || 1,
        order: Number(q?.sourceOrder) || i + 1,
        hint: questionHint(q?.stem),
        kind: String(q?.questionType || '').trim(),
      }))
      .filter((q) => q.key);
    if (wantRegions && targets.length > 0 && pageCount > 0 && String(apiKey || '').trim()) {
      const useModel = String(model || '').trim() || examRegionModel();
      regions = await detectExamItemRegions({
        pdfPath,
        dir,
        pageCount,
        questions: targets,
        log,
        callImageJson: async ({ imageBuffer, prompt, page }) => {
          const res = await callGeminiImageJson({
            imageBuffer,
            prompt,
            model: useModel,
            apiKey,
            timeoutMs,
          });
          logVlmUsage('exam_item_regions', res?.usageMetadata, { page });
          return res?.parsedJson;
        },
      });
    }
    log?.('exam_layout_read', {
      pageCount,
      textEm1k: em.em1k,
      emSource: em.source,
      emSamples: em.samples,
      regionCount: regions.size,
      questionCount: targets.length,
    });
    return { textEm1k: em.em1k, emSource: em.source, pageCount, regions };
  });
}
