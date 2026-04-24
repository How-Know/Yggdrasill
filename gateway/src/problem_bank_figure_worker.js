import 'dotenv/config';
import AdmZip from 'adm-zip';
import { createClient } from '@supabase/supabase-js';
import sharp from 'sharp';
import bmp from 'bmp-js';

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
// pb_figure_jobs 가 status='rendering' 으로 오래 남아 있으면 워커가 비정상
// 종료된 것으로 간주하고 복구한다. 기본 5분. (pb-extract-worker 와 동일 기준)
const STALE_RENDERING_MS = Math.max(
  60_000,
  Number.parseInt(process.env.PB_FIGURE_STALE_MS || '300000', 10),
);
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
const FIGURE_MIN_SIDE_PX = Math.max(
  1024,
  Number.parseInt(process.env.PB_FIGURE_MIN_SIDE_PX || '3072', 10),
);
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
  return Math.min(2.2, Math.max(0.3, n));
}

function normalizeJobOptions(job) {
  const raw = job?.options;
  if (!raw || typeof raw !== 'object') return {};
  return raw;
}

function parseRequestedMinSidePx(job) {
  const options = normalizeJobOptions(job);
  const raw = Number.parseInt(
    String(options.minSidePx ?? options.min_side_px ?? FIGURE_MIN_SIDE_PX),
    10,
  );
  if (!Number.isFinite(raw)) return FIGURE_MIN_SIDE_PX;
  return Math.max(1024, Math.min(4096, raw));
}

function parseHorizontalPairHint(question, job) {
  const options = normalizeJobOptions(job);
  const fromOptions = Array.isArray(options.figureHorizontalPairs)
    ? options.figureHorizontalPairs
    : [];
  const meta =
    question?.meta && typeof question.meta === 'object' ? question.meta : {};
  const fromMeta = Array.isArray(meta.figure_horizontal_pairs)
    ? meta.figure_horizontal_pairs
    : [];
  const source = fromOptions.length > 0 ? fromOptions : fromMeta;
  const pairs = [];
  for (const pair of source) {
    if (!pair || typeof pair !== 'object') continue;
    const a = normalizeWhitespace(pair.a ?? pair.left ?? '');
    const b = normalizeWhitespace(pair.b ?? pair.right ?? '');
    if (!a || !b || a === b) continue;
    pairs.push(`${a}+${b}`);
  }
  return pairs.join(', ');
}

function buildFigurePrompt(
  question,
  {
    referenceImages = [],
    customPrompt = '',
    requestedMinSidePx = FIGURE_MIN_SIDE_PX,
    horizontalPairHint = '',
  } = {},
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
  const safeHorizontalPairHint = normalizeWhitespace(horizontalPairHint);
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
    `- 결과 이미지는 고해상도로 생성하고, 출력 짧은 변 기준 최소 ${requestedMinSidePx}px 수준을 목표로 할 것`,
    '- 업스케일된 흐릿한 품질이 아닌 선명한 원본 품질로 생성할 것',
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
    safeHorizontalPairHint ? `[가로 배치 힌트] ${safeHorizontalPairHint}` : '',
    safeCustomPrompt ? `[추가 사용자 지시] ${safeCustomPrompt}` : '',
  ].join('\n');
}

function buildSingleFigurePrompt(
  question,
  {
    referenceImage = null,
    figureIndex = 1,
    totalFigures = 1,
    customPrompt = '',
    requestedMinSidePx = FIGURE_MIN_SIDE_PX,
  } = {},
) {
  const safeCustomPrompt = normalizeWhitespace(customPrompt);
  return [
    '첨부된 이미지의 모든 요소를 빠짐없이 고해상도로 깔끔하게 다시 그려라.',
    '',
    '규칙:',
    '- 첨부 이미지에 보이는 모든 것(도형, 선, 화살표, 괄호, 치수선, 라벨, 기호)을 빠짐없이 재현하라. 어떤 요소도 생략하지 마라.',
    '- 첨부 이미지에 없는 것은 추가하지 마라.',
    '- 형태, 비율, 방향, 위치를 원본과 동일하게 유지하라.',
    '- 직선은 직선, 곡선은 곡선, 실선은 실선, 점선은 점선으로 유지하라. 선의 종류를 바꾸지 마라.',
    '- 흰 배경, 검정 선, 시험지 인쇄 스타일. 선은 선명하고 일정한 굵기로 그려라.',
    `- 짧은 변 기준 최소 ${requestedMinSidePx}px 고해상도.`,
    totalFigures > 1 ? `- 이 문항에 그림이 ${totalFigures}개 있지만 지금은 ${figureIndex}번째만 그려라.` : '',
    safeCustomPrompt || '',
  ].filter(Boolean).join('\n');
}

function extensionFromMime(mimeType) {
  const m = String(mimeType || '').toLowerCase();
  if (m.includes('png')) return 'png';
  if (m.includes('jpeg') || m.includes('jpg')) return 'jpg';
  if (m.includes('webp')) return 'webp';
  return 'png';
}

// Supabase Storage(problem-previews 버킷) 의 allowed_mime_types 는
// png/jpeg/webp 만 허용한다. HWPX BinData 에는 종종 BMP(=image/bmp) 가 섞여
// 있어 업로드 단계에서 "mime type image/bmp is not supported" 로 실패하고,
// 그 결과 매니저 UI 에는 [그림] placeholder 만 남고 실제 이미지가 비는
// 증상이 생긴다. 업로드 직전에 BMP/알 수 없는 포맷을 PNG 로 강제 변환해
// 이 간극을 메운다.
//
// 주의: sharp(=libvips) 의 prebuilt 바이너리는 BMP 읽기를 지원하지 않는다
// ("Input buffer contains unsupported image format"). 따라서 BMP 디코드는
// pure-JS 경량 디코더인 `bmp-js` 로 처리하고, 결과 raw RGBA 픽셀을 sharp 에
// raw 모드로 넘겨 PNG 로 인코딩한다.
function looksLikeBmp(bytes) {
  if (!bytes || bytes.length < 2) return false;
  return bytes[0] === 0x42 && bytes[1] === 0x4d; // "BM"
}

function bmpToPngBuffer(bytes) {
  // bmp-js 는 동기 함수. 픽셀 배열은 ABGR 순서(per-pixel 4 bytes:
  //   data[i+0]=A, data[i+1]=B, data[i+2]=G, data[i+3]=R)
  // 로 반환되므로 sharp 의 raw RGBA 입력 규격에 맞게 swap 한다.
  const decoded = bmp.decode(Buffer.isBuffer(bytes) ? bytes : Buffer.from(bytes));
  if (!decoded || !decoded.data || !decoded.width || !decoded.height) {
    throw new Error('bmp_decode_empty');
  }
  const src = decoded.data;
  // 대부분의 BMP(BMPv3, 24bpp) 는 alpha 채널이 없고, bmp-js 는 그런 경우
  // data[i+0]=A 자리를 0 으로 채워 반환한다. 이 0 을 그대로 PNG alpha 로
  // 넘기면 전체 이미지가 완전 투명(Alpha=0) 으로 인코딩되어, 업로드 자체는
  // 성공하지만 매니저 UI 에는 빈 흰색만 보이는 증상이 난다(2026-04 경신중
  // 2학년 q9/q11/q20 등). 따라서 "전 픽셀 A=0" 인 경우만 BMPv3/24bpp 로
  // 간주해 강제 불투명(255) 으로 복원하고, 실제 alpha 가 있는 BMPv5 등은
  // 원본 값을 보존한다.
  let allAlphaZero = true;
  for (let i = 0; i < src.length; i += 4) {
    if (src[i] !== 0) {
      allAlphaZero = false;
      break;
    }
  }
  const dst = Buffer.allocUnsafe(src.length);
  for (let i = 0; i < src.length; i += 4) {
    dst[i + 0] = src[i + 3];
    dst[i + 1] = src[i + 2];
    dst[i + 2] = src[i + 1];
    dst[i + 3] = allAlphaZero ? 255 : src[i + 0];
  }
  return sharp(dst, {
    raw: { width: decoded.width, height: decoded.height, channels: 4 },
  })
    .png()
    .toBuffer();
}

async function normalizeUploadableImage(mimeType, bytes) {
  const m = String(mimeType || '').toLowerCase();
  const declaredBmp = m.includes('bmp');
  const magicBmp = looksLikeBmp(bytes);
  if (!declaredBmp && !magicBmp) {
    return { mimeType: mimeType || 'image/png', bytes };
  }
  // 1차 경로: bmp-js + sharp(raw→png)
  try {
    const png = await bmpToPngBuffer(bytes);
    return { mimeType: 'image/png', bytes: png };
  } catch (errPrimary) {
    // 2차 경로(보험): 매직이 BM 이 아닌데 mime 만 bmp 로 잘못 선언된
    // 케이스(실제는 png/jpeg 등) 가 있을 수 있어 sharp 로 재시도.
    try {
      const png = await sharp(bytes, { failOn: 'none' }).png().toBuffer();
      return { mimeType: 'image/png', bytes: png };
    } catch (errSecondary) {
      throw new Error(
        `bmp_to_png_failed:${compact(errPrimary?.message || errPrimary) || 'bmp_unknown_error'}` +
          `|fallback:${compact(errSecondary?.message || errSecondary) || 'sharp_unknown_error'}`,
      );
    }
  }
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

// 비정상 종료된 워커가 남긴 orphan 'rendering' job 을 다시 'queued' 로 되돌린다.
// pb_figure_jobs 는 extract 테이블과 달리 retry_count/max_retries 컬럼이 없는
// 단순 큐라서, stale lock 은 무조건 'queued' 로 재투입한다. 영속적으로 실패하는
// 작업은 워커가 처리한 뒤 markFailed() 가 한 번 더 업데이트하므로 무한 루프는
// 형성되지 않는다. (실제 실패 원인은 error_message 로 이력 보존.)
async function reclaimStaleRenderingJobs() {
  const cutoffIso = new Date(Date.now() - STALE_RENDERING_MS).toISOString();
  const { data: stale, error } = await supa
    .from('pb_figure_jobs')
    .select('id,worker_name,updated_at,started_at')
    .eq('status', 'rendering')
    .lt('updated_at', cutoffIso)
    .limit(50);
  if (error) {
    console.warn(
      '[pb-figure-worker] reclaim_stale_query_failed',
      compact(error.message || error),
    );
    return { requeued: 0, failed: 0 };
  }
  if (!stale || stale.length === 0) return { requeued: 0, failed: 0 };

  let requeued = 0;
  for (const row of stale) {
    const ageMs =
      Date.now() - new Date(row.updated_at || row.started_at || 0).getTime();
    const nowIso = new Date().toISOString();
    const { data: updated } = await supa
      .from('pb_figure_jobs')
      .update({
        status: 'queued',
        started_at: null,
        finished_at: null,
        error_code: 'worker_stalled',
        error_message: `reclaimed stale rendering lock after ${Math.round(ageMs / 1000)}s (prev worker=${row.worker_name || '-'})`,
        updated_at: nowIso,
      })
      .eq('id', row.id)
      .eq('status', 'rendering')
      .select('id')
      .maybeSingle();
    if (updated) requeued += 1;
  }
  if (requeued > 0) {
    console.warn(
      '[pb-figure-worker] reclaim_stale',
      JSON.stringify({
        requeued,
        thresholdMs: STALE_RENDERING_MS,
      }),
    );
  }
  return { requeued, failed: 0 };
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
  const requestedMinSidePx = parseRequestedMinSidePx(job);
  const horizontalPairHint = parseHorizontalPairHint(question, job);
  const promptText = buildFigurePrompt(question, {
    referenceImages,
    customPrompt: job.prompt_text,
    requestedMinSidePx,
    horizontalPairHint,
  });
  const modelName = normalizeWhitespace(job.model_name) || FIGURE_MODEL;
  const forceRegen =
    job.options?.forceRegenerate === true || job.force_regenerate === true;
  const shouldPassthrough =
    FIGURE_REFERENCE_PASSTHROUGH && referenceImages.length > 0 && !forceRegen;
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
  } else if (referenceImages.length <= 1) {
    const generated = await callGeminiImage(promptText, modelName, referenceImages);
    generatedOutputs.push({
      mimeType: generated.mimeType,
      bytes: generated.bytes,
      referenceEntry: referenceImages[0]?.entryName || '',
      figureIndex: 1,
    });
  } else {
    for (let ri = 0; ri < referenceImages.length; ri++) {
      const singleRef = [referenceImages[ri]];
      const perFigurePrompt = buildSingleFigurePrompt(question, {
        referenceImage: referenceImages[ri],
        figureIndex: ri + 1,
        totalFigures: referenceImages.length,
        customPrompt: job.prompt_text,
        requestedMinSidePx,
      });
      const generated = await callGeminiImage(perFigurePrompt, modelName, singleRef);
      generatedOutputs.push({
        mimeType: generated.mimeType,
        bytes: generated.bytes,
        referenceEntry: referenceImages[ri]?.entryName || '',
        figureIndex: ri + 1,
      });
    }
  }
  const uploaded = [];
  for (const output of generatedOutputs) {
    // HWPX BinData 에 들어있는 BMP 등 Storage 가 거부하는 포맷은
    // 업로드 전에 PNG 로 변환한다. 변환 결과물로 mime_type/ext 도 동기화해
    // DB 의 figure_assets[].mime_type 과 실제 파일이 어긋나지 않게 한다.
    const normalized = await normalizeUploadableImage(
      output.mimeType,
      output.bytes,
    );
    const uploadMime = normalized.mimeType;
    const uploadBytes = normalized.bytes;
    const ext = extensionFromMime(uploadMime);
    const suffix = generatedOutputs.length > 1 ? `_${output.figureIndex}` : '';
    const objectPath =
      `${job.academy_id}/${job.document_id}/${job.question_id}/` +
      `${job.id}${suffix}.${ext}`;
    const { error: uploadErr } = await supa.storage
      .from('problem-previews')
      .upload(objectPath, uploadBytes, {
        contentType: uploadMime || `image/${ext}`,
        upsert: true,
      });
    if (uploadErr) {
      throw new Error(`figure_upload_failed:${uploadErr.message}`);
    }
    uploaded.push({
      ...output,
      mimeType: uploadMime,
      bytes: uploadBytes,
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
    requested_min_side_px: requestedMinSidePx,
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
  const figureLayoutItems = newAssets.map((asset) => {
    const key = Number.isFinite(asset.figure_index) && asset.figure_index > 0
      ? `idx:${asset.figure_index}`
      : `ord:1`;
    const isMultiple = newAssets.length >= 2;
    const widthEm = isMultiple ? 12.0 : 20.0;
    return {
      assetKey: key,
      widthEm,
      position: 'below-stem',
      anchor: 'center',
      offsetXEm: 0,
      offsetYEm: 0,
    };
  });
  const figureLayoutGroups = [];
  if (figureLayoutItems.length === 2) {
    figureLayoutGroups.push({
      type: 'horizontal',
      members: figureLayoutItems.map((it) => it.assetKey),
      gap: 0.5,
    });
  }
  const figureLayout = prevMeta.figure_layout && typeof prevMeta.figure_layout === 'object'
    ? prevMeta.figure_layout
    : { version: 1, items: figureLayoutItems, groups: figureLayoutGroups };

  const nextMeta = {
    ...prevMeta,
    figure_assets: nextAssets,
    figure_layout: figureLayout,
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
    requestedMinSidePx,
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
      staleRenderingMs: STALE_RENDERING_MS,
    }),
  );

  try {
    await reclaimStaleRenderingJobs();
  } catch (err) {
    console.error(
      '[pb-figure-worker] reclaim_startup_failed',
      compact(err?.message || err),
    );
  }

  let lastReclaimAt = Date.now();
  const reclaimIntervalMs = Math.max(30_000, Math.floor(STALE_RENDERING_MS / 2));

  while (true) {
    try {
      if (Date.now() - lastReclaimAt >= reclaimIntervalMs) {
        await reclaimStaleRenderingJobs().catch((err) => {
          console.warn(
            '[pb-figure-worker] reclaim_periodic_failed',
            compact(err?.message || err),
          );
        });
        lastReclaimAt = Date.now();
      }
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
