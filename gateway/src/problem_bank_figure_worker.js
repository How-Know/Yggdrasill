import 'dotenv/config';
import AdmZip from 'adm-zip';
import { createClient } from '@supabase/supabase-js';

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const WORKER_INTERVAL_MS = Number.parseInt(
  process.env.PB_FIGURE_WORKER_INTERVAL_MS || '5000',
  10,
);
const BATCH_SIZE = Math.max(
  1,
  Number.parseInt(process.env.PB_FIGURE_WORKER_BATCH_SIZE || '2', 10),
);
const PROCESS_ONCE =
  process.argv.includes('--once') || process.env.PB_FIGURE_WORKER_ONCE === '1';
const WORKER_NAME =
  process.env.PB_FIGURE_WORKER_NAME || `pb-figure-worker-${process.pid}`;
const GEMINI_API_KEY = String(process.env.GEMINI_API_KEY || '').trim();
const FIGURE_MODEL = String(
  process.env.PB_FIGURE_MODEL || 'gemini-2.5-flash-image',
).trim();
const FIGURE_TIMEOUT_MS = Math.max(
  10_000,
  Number.parseInt(process.env.PB_FIGURE_TIMEOUT_MS || '90000', 10),
);
const FIGURE_REFERENCE_IMAGE_LIMIT = Math.max(
  0,
  Number.parseInt(process.env.PB_FIGURE_REFERENCE_IMAGE_LIMIT || '1', 10),
);
const FIGURE_REFERENCE_MAX_BYTES = Math.max(
  64 * 1024,
  Number.parseInt(process.env.PB_FIGURE_REFERENCE_MAX_BYTES || '6000000', 10),
);
const FIGURE_REFERENCE_HWPX_MAX_IMAGES = Math.max(
  1,
  Number.parseInt(process.env.PB_FIGURE_REFERENCE_HWPX_MAX_IMAGES || '80', 10),
);
const FIGURE_REFERENCE_PASSTHROUGH =
  process.env.PB_FIGURE_REFERENCE_PASSTHROUGH !== '0';
const FIGURE_ENABLED =
  process.env.PB_FIGURE_ENABLED !== '0' &&
  GEMINI_API_KEY.length > 0 &&
  FIGURE_MODEL.length > 0;

if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
  console.error(
    '[pb-figure-worker] Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY',
  );
  process.exit(1);
}

const supa = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});
const referenceCacheByDocument = new Map();

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function compact(value, max = 260) {
  const s = String(value ?? '').replace(/\s+/g, ' ').trim();
  if (s.length <= max) return s;
  return `${s.slice(0, max)}...`;
}

function normalizeWhitespace(value) {
  return String(value ?? '').replace(/\s+/g, ' ').trim();
}

function mimeTypeFromPath(path) {
  const p = String(path || '').toLowerCase();
  if (p.endsWith('.png')) return 'image/png';
  if (p.endsWith('.jpg') || p.endsWith('.jpeg')) return 'image/jpeg';
  if (p.endsWith('.webp')) return 'image/webp';
  if (p.endsWith('.gif')) return 'image/gif';
  if (p.endsWith('.bmp')) return 'image/bmp';
  return 'image/png';
}

function parseBinDataOrder(path) {
  const m = String(path || '').match(/bin(\d+)\./i);
  if (!m) return Number.MAX_SAFE_INTEGER;
  const n = Number.parseInt(m[1] || '', 10);
  return Number.isFinite(n) ? n : Number.MAX_SAFE_INTEGER;
}

async function toBufferFromStorageData(data) {
  if (!data) return Buffer.alloc(0);
  if (Buffer.isBuffer(data)) return data;
  if (typeof data.arrayBuffer === 'function') {
    return Buffer.from(await data.arrayBuffer());
  }
  if (typeof data === 'string') {
    return Buffer.from(data);
  }
  if (data?.buffer) {
    return Buffer.from(data.buffer);
  }
  return Buffer.alloc(0);
}

function countFigureMarkersInText(value) {
  const input = String(value || '');
  if (!input) return 0;
  const tokenMatches = input.match(/\[\[PB_FIG_[^\]]+\]\]/g) || [];
  const markerMatches = input.match(/\[(?:그림|도형|도표|표)\]/g) || [];
  return tokenMatches.length + markerMatches.length;
}

function inferQuestionFigureCount(row) {
  let markerCountFromRefs = 0;
  const refs = Array.isArray(row?.figure_refs) ? row.figure_refs : [];
  for (const ref of refs) {
    markerCountFromRefs += countFigureMarkersInText(ref);
  }
  const markerCountFromStem = countFigureMarkersInText(row?.stem || '');
  let markerCount =
    markerCountFromRefs > 0 ? markerCountFromRefs : markerCountFromStem;
  const meta = row?.meta && typeof row.meta === 'object' ? row.meta : {};
  const metaCount = Number.parseInt(
    String(meta.figure_count ?? meta.figure_marker_count ?? ''),
    10,
  );
  if (Number.isFinite(metaCount) && metaCount > markerCount) {
    markerCount = metaCount;
  }
  return Math.max(1, markerCount);
}

function toErrorCode(err) {
  const msg = String(err?.message || err || '');
  if (/not\s*found|404/i.test(msg)) return 'NOT_FOUND';
  if (/permission|forbidden|unauthorized|401|403/i.test(msg)) {
    return 'PERMISSION_DENIED';
  }
  if (/timeout|aborted/i.test(msg)) return 'TIMEOUT';
  if (/upload|storage/i.test(msg)) return 'STORAGE_FAILED';
  if (/gemini|generate|image/i.test(msg)) return 'AI_GENERATE_FAILED';
  return 'UNKNOWN';
}

function withTimeout(ms) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), ms);
  return {
    signal: controller.signal,
    clear() {
      clearTimeout(timer);
    },
  };
}

function parseFigureRenderScale(question) {
  const meta =
    question?.meta && typeof question.meta === 'object' ? question.meta : {};
  const raw =
    meta.figure_render_scale ?? meta.figureScale ?? meta.figure_scale ?? '';
  const n = Number.parseFloat(String(raw));
  if (!Number.isFinite(n)) return 1.0;
  return Math.min(1.8, Math.max(0.7, n));
}

function buildFigurePrompt(
  question,
  { referenceImages = [], customPrompt = '' } = {},
) {
  const stem = compact(question.stem || '', 1600);
  const figureRefs = Array.isArray(question.figure_refs)
    ? question.figure_refs.map((x) => normalizeWhitespace(x)).filter(Boolean)
    : [];
  const equations = Array.isArray(question.equations)
    ? question.equations
        .map((e) => normalizeWhitespace(e?.latex || e?.raw || ''))
        .filter(Boolean)
        .slice(0, 8)
    : [];
  const choices = Array.isArray(question.choices)
    ? question.choices
        .map((c) => `${c?.label || ''} ${normalizeWhitespace(c?.text || '')}`.trim())
        .filter(Boolean)
        .slice(0, 8)
    : [];
  const useReference = referenceImages.length > 0;
  const renderScale = parseFigureRenderScale(question);
  const renderScalePct = Math.round(renderScale * 100);
  const safeCustomPrompt = normalizeWhitespace(customPrompt);
  return [
    '당신은 한국 중고등 수학 시험 문항용 도형/도표 일러스트 생성기다.',
    useReference
      ? '첨부된 참고 이미지를 기준으로 원문 도형과 거의 동일하게 재구성하라.'
      : '문항 텍스트를 보고 문제 이해에 필요한 핵심 도형을 생성하라.',
    '요구사항:',
    '- 흰 배경, 검정/회색 선 중심의 시험지 스타일',
    '- 워터마크/저작권 문구/장식/불필요한 텍스트 금지',
    '- 본문/보기/수식에 나온 문자·숫자 라벨을 누락하지 말 것',
    '- 도형 내부 수식/숫자/알파벳 라벨 크기를 문제 본문 수식의 시각 크기와 동일하게 맞출 것',
    '- 분수/근호/지수 등 2차원 수식의 굵기와 비율을 본문 수식과 일치시킬 것',
    '- 도형 비율, 각도, 선 길이의 상대 관계를 실제 문제와 일치시킬 것',
    '- 축, 화살표, 점선, 음영, 점/꼭짓점 표기 등 시각 요소를 최대한 동일하게 반영',
    useReference
      ? '- 참고 이미지에 보이는 배치와 위치를 우선 복원하고 임의 창작을 금지'
      : '- 참고 이미지가 없으면 본문 설명을 우선해 수학적으로 일관되게 구성',
    '- 최종 결과는 이미지 한 장',
    '',
    `[참고이미지] ${useReference ? `${referenceImages.length}개 제공` : '없음'}`,
    `[문항번호] ${question.question_number || '?'}번`,
    `[문항유형] ${question.question_type || '미분류'}`,
    `[본문] ${stem}`,
    `[보기] ${choices.join(' | ')}`,
    `[도형 힌트] ${figureRefs.join(' | ')}`,
    `[수식 힌트] ${equations.join(' | ')}`,
    `[수식 라벨 배율 힌트] ${renderScalePct}%`,
    safeCustomPrompt ? `[추가 사용자 지시] ${safeCustomPrompt}` : '',
  ].join('\n');
}

function extensionFromMime(mimeType) {
  const m = String(mimeType || '').toLowerCase();
  if (m.includes('png')) return 'png';
  if (m.includes('jpeg') || m.includes('jpg')) return 'jpg';
  if (m.includes('webp')) return 'webp';
  return 'png';
}

async function callGeminiImage(promptText, modelName, referenceImages = []) {
  if (!FIGURE_ENABLED) {
    throw new Error('figure_generation_disabled');
  }
  const url =
    `https://generativelanguage.googleapis.com/v1beta/models/` +
    `${encodeURIComponent(modelName)}:generateContent?key=` +
    `${encodeURIComponent(GEMINI_API_KEY)}`;
  const imageParts = (referenceImages || [])
    .filter((ref) => ref?.bytes && ref.bytes.length > 0)
    .slice(0, FIGURE_REFERENCE_IMAGE_LIMIT)
    .map((ref) => ({
      inlineData: {
        mimeType: ref.mimeType || 'image/png',
        data: ref.bytes.toString('base64'),
      },
    }));
  const body = {
    contents: [{ role: 'user', parts: [{ text: promptText }, ...imageParts] }],
    generationConfig: {
      temperature: imageParts.length > 0 ? 0.05 : 0.2,
      responseModalities: ['TEXT', 'IMAGE'],
    },
  };
  const { signal, clear } = withTimeout(FIGURE_TIMEOUT_MS);
  let res = null;
  try {
    res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
      signal,
    });
  } finally {
    clear();
  }
  if (!res?.ok) {
    const errText = res ? await res.text() : 'gemini_no_response';
    throw new Error(`gemini_http_${res?.status || 'unknown'}:${compact(errText)}`);
  }
  const payload = await res.json();
  const parts = (payload?.candidates || [])
    .flatMap((c) => c?.content?.parts || [])
    .filter(Boolean);
  const imagePart = parts.find((p) => {
    const inline = p?.inlineData || p?.inline_data;
    return Boolean(inline?.data);
  });
  if (!imagePart) {
    throw new Error('gemini_image_not_returned');
  }
  const inline = imagePart.inlineData || imagePart.inline_data || {};
  const mimeType = String(
    inline.mimeType || inline.mime_type || 'image/png',
  ).trim();
  const data = String(inline.data || '').trim();
  if (!data) {
    throw new Error('gemini_image_data_empty');
  }
  return {
    mimeType,
    bytes: Buffer.from(data, 'base64'),
  };
}

async function lockQueuedJob(job) {
  const nowIso = new Date().toISOString();
  const { data, error } = await supa
    .from('pb_figure_jobs')
    .update({
      status: 'rendering',
      worker_name: WORKER_NAME,
      started_at: nowIso,
      finished_at: null,
      error_code: '',
      error_message: '',
      updated_at: nowIso,
    })
    .eq('id', job.id)
    .eq('status', 'queued')
    .select('*')
    .maybeSingle();
  if (error) throw new Error(`figure_job_lock_failed:${error.message}`);
  return data;
}

async function markFailed(jobId, error) {
  const nowIso = new Date().toISOString();
  await supa
    .from('pb_figure_jobs')
    .update({
      status: 'failed',
      error_code: toErrorCode(error),
      error_message: compact(error?.message || error),
      finished_at: nowIso,
      updated_at: nowIso,
    })
    .eq('id', jobId);
}

async function loadQuestionForJob(job) {
  const { data, error } = await supa
    .from('pb_questions')
    .select(
      'id,academy_id,document_id,question_number,question_type,source_order,stem,choices,equations,figure_refs,meta',
    )
    .eq('id', job.question_id)
    .eq('academy_id', job.academy_id)
    .eq('document_id', job.document_id)
    .maybeSingle();
  if (error) {
    throw new Error(`figure_question_lookup_failed:${error.message}`);
  }
  if (!data) {
    throw new Error('figure_question_not_found');
  }
  return data;
}

async function loadDocumentReferencePack(job) {
  const cacheKey = `${job.academy_id}:${job.document_id}`;
  if (referenceCacheByDocument.has(cacheKey)) {
    return referenceCacheByDocument.get(cacheKey);
  }
  const fetchPromise = (async () => {
    const { data: docRow, error: docErr } = await supa
      .from('pb_documents')
      .select('id,academy_id,source_storage_bucket,source_storage_path')
      .eq('id', job.document_id)
      .eq('academy_id', job.academy_id)
      .maybeSingle();
    if (docErr) {
      throw new Error(`figure_doc_lookup_failed:${docErr.message}`);
    }
    if (!docRow) {
      throw new Error('figure_doc_not_found');
    }
    const bucket = normalizeWhitespace(docRow.source_storage_bucket);
    const sourcePath = normalizeWhitespace(docRow.source_storage_path);
    if (!bucket || !sourcePath) {
      return { imageEntries: [], figureQuestions: [] };
    }
    const { data: hwpxBlob, error: downloadErr } = await supa.storage
      .from(bucket)
      .download(sourcePath);
    if (downloadErr) {
      throw new Error(`figure_doc_download_failed:${downloadErr.message}`);
    }
    const hwpxBuffer = await toBufferFromStorageData(hwpxBlob);
    const zip = new AdmZip(hwpxBuffer);
    const imageEntries = zip
      .getEntries()
      .filter(
        (entry) =>
          !entry.isDirectory &&
          /^BinData\/.+\.(png|jpg|jpeg|gif|bmp|webp)$/i.test(entry.entryName),
      )
      .sort((a, b) => {
        const aa = parseBinDataOrder(a.entryName);
        const bb = parseBinDataOrder(b.entryName);
        if (aa !== bb) return aa - bb;
        return a.entryName.localeCompare(b.entryName);
      })
      .slice(0, FIGURE_REFERENCE_HWPX_MAX_IMAGES)
      .map((entry) => ({
        entryName: entry.entryName,
        mimeType: mimeTypeFromPath(entry.entryName),
        bytes: entry.getData(),
      }))
      .filter((entry) => entry.bytes.length > 0);

    const { data: questionRows, error: qErr } = await supa
      .from('pb_questions')
      .select('id,source_order,figure_refs,stem,meta')
      .eq('academy_id', job.academy_id)
      .eq('document_id', job.document_id)
      .order('source_order', { ascending: true });
    if (qErr) {
      throw new Error(`figure_doc_questions_failed:${qErr.message}`);
    }
    const figureQuestions = (questionRows || [])
      .filter((row) => Array.isArray(row.figure_refs) && row.figure_refs.length > 0)
      .map((row) => ({
        id: String(row.id || ''),
        sourceOrder: Number.parseInt(String(row.source_order || '0'), 10) || 0,
        figureCount: inferQuestionFigureCount(row),
      }));

    return { imageEntries, figureQuestions };
  })();
  referenceCacheByDocument.set(cacheKey, fetchPromise);
  try {
    return await fetchPromise;
  } catch (err) {
    referenceCacheByDocument.delete(cacheKey);
    throw err;
  }
}

async function resolveReferenceImagesForQuestion(job, question) {
  if (FIGURE_REFERENCE_IMAGE_LIMIT <= 0) return [];
  try {
    const pack = await loadDocumentReferencePack(job);
    if (!Array.isArray(pack.imageEntries) || pack.imageEntries.length === 0) {
      return [];
    }
    const figureQuestions = Array.isArray(pack.figureQuestions)
      ? pack.figureQuestions
      : [];
    let questionIndex = figureQuestions.findIndex((row) => row.id === question.id);
    if (questionIndex < 0) {
      const sourceOrder = Number.parseInt(String(question.source_order || '0'), 10) || 0;
      if (sourceOrder > 0) {
        questionIndex = Math.max(
          0,
          figureQuestions.filter((row) => row.sourceOrder <= sourceOrder).length - 1,
        );
      }
    }
    if (questionIndex < 0) questionIndex = 0;
    let startIndex = 0;
    for (let i = 0; i < questionIndex; i += 1) {
      const count = Number.parseInt(
        String(figureQuestions[i]?.figureCount || '1'),
        10,
      );
      startIndex += Number.isFinite(count) && count > 0 ? count : 1;
    }
    const targetCountRaw = Number.parseInt(
      String(figureQuestions[questionIndex]?.figureCount || '1'),
      10,
    );
    const targetCount = Number.isFinite(targetCountRaw) && targetCountRaw > 0
      ? targetCountRaw
      : 1;
    let picked = pack.imageEntries.slice(startIndex, startIndex + targetCount);
    if (picked.length === 0) {
      const fallback = pack.imageEntries[
        Math.min(questionIndex, Math.max(0, pack.imageEntries.length - 1))
      ];
      if (!fallback) return [];
      picked = [fallback];
    }
    return picked
      .filter((entry) => entry.bytes.length <= FIGURE_REFERENCE_MAX_BYTES)
      .map((entry) => ({
        bytes: entry.bytes,
        mimeType: entry.mimeType,
        entryName: entry.entryName,
      }));
  } catch (err) {
    console.warn(
      '[pb-figure-worker] reference_skip',
      JSON.stringify({
        documentId: job.document_id,
        questionId: question.id,
        message: compact(err?.message || err),
      }),
    );
    return [];
  }
}

async function processOneJob(job) {
  const question = await loadQuestionForJob(job);
  const refs = Array.isArray(question.figure_refs) ? question.figure_refs : [];
  if (refs.length === 0) {
    throw new Error('figure_refs_empty');
  }
  const referenceImages = await resolveReferenceImagesForQuestion(job, question);
  const promptText = buildFigurePrompt(question, {
    referenceImages,
    customPrompt: job.prompt_text,
  });
  const modelName = normalizeWhitespace(job.model_name) || FIGURE_MODEL;
  const shouldPassthrough =
    FIGURE_REFERENCE_PASSTHROUGH && referenceImages.length > 0;
  const generationMode = shouldPassthrough
    ? 'source_reference'
    : 'ai_generate';
  let generatedOutputs = [];
  if (shouldPassthrough) {
    generatedOutputs = referenceImages.map((ref, idx) => ({
      mimeType: ref.mimeType || 'image/png',
      bytes: ref.bytes,
      referenceEntry: ref.entryName || '',
      figureIndex: idx + 1,
    }));
  } else {
    const generated = await callGeminiImage(promptText, modelName, referenceImages);
    generatedOutputs = [
      {
        mimeType: generated.mimeType,
        bytes: generated.bytes,
        referenceEntry: referenceImages[0]?.entryName || '',
        figureIndex: 1,
      },
    ];
  }
  const uploaded = [];
  for (const output of generatedOutputs) {
    const ext = extensionFromMime(output.mimeType);
    const suffix = generatedOutputs.length > 1 ? `_${output.figureIndex}` : '';
    const objectPath =
      `${job.academy_id}/${job.document_id}/${job.question_id}/` +
      `${job.id}${suffix}.${ext}`;
    const { error: uploadErr } = await supa.storage
      .from('problem-previews')
      .upload(objectPath, output.bytes, {
        contentType: output.mimeType || `image/${ext}`,
        upsert: true,
      });
    if (uploadErr) {
      throw new Error(`figure_upload_failed:${uploadErr.message}`);
    }
    uploaded.push({
      ...output,
      objectPath,
    });
  }
  const primaryOutput = uploaded[0];
  if (!primaryOutput) {
    throw new Error('figure_upload_empty');
  }

  const nowIso = new Date().toISOString();
  const prevMeta =
    question.meta && typeof question.meta === 'object' ? question.meta : {};
  const prevAssets = Array.isArray(prevMeta.figure_assets)
    ? prevMeta.figure_assets
    : [];
  const newAssets = uploaded.map((output, idx) => ({
    id: uploaded.length > 1 ? `${job.id}:${idx + 1}` : job.id,
    source: generationMode,
    provider: 'gemini',
    model: modelName,
    status: shouldPassthrough ? 'copied_from_source' : 'generated',
    approved: false,
    review_required: true,
    bucket: 'problem-previews',
    path: output.objectPath,
    mime_type: output.mimeType,
    confidence: shouldPassthrough ? 0.98 : referenceImages.length > 0 ? 0.74 : 0.6,
    figure_index: output.figureIndex,
    reference_count: referenceImages.length,
    reference_entry: output.referenceEntry || '',
    created_at: nowIso,
  }));
  const nextAssets = [
    ...newAssets,
    ...prevAssets.filter((a) => {
      const id = String(a?.id || '');
      if (!id) return true;
      if (id === String(job.id || '')) return false;
      if (id.startsWith(`${job.id}:`)) return false;
      return true;
    }),
  ];
  const nextMeta = {
    ...prevMeta,
    figure_assets: nextAssets,
    figure_review_required: true,
    figure_last_generated_at: nowIso,
  };
  const { error: qErr } = await supa
    .from('pb_questions')
    .update({
      meta: nextMeta,
      updated_at: nowIso,
    })
    .eq('id', question.id);
  if (qErr) {
    throw new Error(`figure_question_update_failed:${qErr.message}`);
  }

  const resultSummary = {
    questionId: question.id,
    outputBucket: 'problem-previews',
    outputPath: primaryOutput.objectPath,
    outputPaths: uploaded.map((x) => x.objectPath),
    outputCount: uploaded.length,
    model: modelName,
    mimeType: primaryOutput.mimeType,
    referenceCount: referenceImages.length,
    referenceEntry: referenceImages[0]?.entryName || '',
    referenceEntries: referenceImages.map((x) => x.entryName).filter(Boolean),
    generationMode,
  };
  const { error: jobErr } = await supa
    .from('pb_figure_jobs')
    .update({
      status: 'review_required',
      model_name: modelName,
      output_storage_bucket: 'problem-previews',
      output_storage_path: primaryOutput.objectPath,
      result_summary: resultSummary,
      error_code: '',
      error_message: '',
      finished_at: nowIso,
      updated_at: nowIso,
    })
    .eq('id', job.id);
  if (jobErr) {
    throw new Error(`figure_job_update_failed:${jobErr.message}`);
  }
  return {
    questionId: question.id,
    outputPath: primaryOutput.objectPath,
    outputPaths: uploaded.map((x) => x.objectPath),
    outputCount: uploaded.length,
    mimeType: primaryOutput.mimeType,
    referenceCount: referenceImages.length,
    referenceEntry: referenceImages[0]?.entryName || '',
    referenceEntries: referenceImages.map((x) => x.entryName).filter(Boolean),
    generationMode,
  };
}

async function processBatch() {
  const { data: queue, error } = await supa
    .from('pb_figure_jobs')
    .select('*')
    .eq('status', 'queued')
    .order('created_at', { ascending: true })
    .limit(BATCH_SIZE);
  if (error) {
    throw new Error(`figure_queue_fetch_failed:${error.message}`);
  }
  if (!queue || queue.length === 0) {
    return { processed: 0, success: 0, failed: 0 };
  }
  const summary = { processed: 0, success: 0, failed: 0 };
  for (const row of queue) {
    summary.processed += 1;
    let locked = null;
    try {
      locked = await lockQueuedJob(row);
      if (!locked) continue;
      const result = await processOneJob(locked);
      summary.success += 1;
      console.log(
        '[pb-figure-worker] done',
        JSON.stringify({
          jobId: locked.id,
          questionId: result.questionId,
          outputPath: result.outputPath,
          mimeType: result.mimeType,
          referenceCount: result.referenceCount,
          referenceEntry: result.referenceEntry,
          generationMode: result.generationMode,
        }),
      );
    } catch (err) {
      summary.failed += 1;
      console.error(
        '[pb-figure-worker] fail',
        JSON.stringify({
          jobId: locked?.id || row.id,
          errorCode: toErrorCode(err),
          message: compact(err?.message || err),
        }),
      );
      await markFailed(locked?.id || row.id, err);
    }
  }
  return summary;
}

async function main() {
  console.log(
    '[pb-figure-worker] start',
    JSON.stringify({
      worker: WORKER_NAME,
      intervalMs: WORKER_INTERVAL_MS,
      batchSize: BATCH_SIZE,
      once: PROCESS_ONCE,
      figureEnabled: FIGURE_ENABLED,
      model: FIGURE_MODEL,
      timeoutMs: FIGURE_TIMEOUT_MS,
      referenceImageLimit: FIGURE_REFERENCE_IMAGE_LIMIT,
      referenceMaxBytes: FIGURE_REFERENCE_MAX_BYTES,
      referencePassthrough: FIGURE_REFERENCE_PASSTHROUGH,
    }),
  );
  while (true) {
    try {
      const summary = await processBatch();
      if (summary.processed > 0) {
        console.log('[pb-figure-worker] batch', JSON.stringify(summary));
      }
      if (PROCESS_ONCE) break;
      await sleep(WORKER_INTERVAL_MS);
    } catch (err) {
      console.error(
        '[pb-figure-worker] batch_error',
        compact(err?.message || err),
      );
      if (PROCESS_ONCE) break;
      await sleep(WORKER_INTERVAL_MS);
    }
  }
  console.log('[pb-figure-worker] exit');
}

main().catch((err) => {
  console.error('[pb-figure-worker] fatal', compact(err?.message || err));
  process.exit(1);
});
