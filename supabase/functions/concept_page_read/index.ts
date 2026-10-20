// concept_page_read: 개념책 한 쪽을 문항 영역만 가린 채 그대로 전사한다(슈퍼관리자 전용).
//   POST { image_base64, mime_type?, book_name, grade_label, unit_path[], raw_page, display_page?, masks[], effort? }
//     → { ok, page, model, usage, cost_usd, latency_ms, prompt_version }   (시범 실행기: 저장하지 않음)
//   POST { save: true, academy_id, book_id, grade_label, read_index: 1|2, raw_page, image_base64, masks[], unit_path[], effort? }
//     → 위 + { transcript_id }   (매니저앱: concept_page_transcripts 에 저장)
//   저장할 때는 책 이름·가림 영역·인쇄 쪽을 서버가 저장된 기록에서 다시 읽는다. 앱이 그린 가림 영역이 다르면 409.
// 사용량은 ai_runs(feature=concept_page_read)에 남는다.

import { corsHeaders } from '../_shared/cors.ts';
import { authenticate, errorResponse, isSuperadmin, jsonResponse, safetyIdentifier } from '../_shared/ai/auth.ts';
import { getBudgetStatus } from '../_shared/ai/budget.ts';
import { estimateCostUsd, modelFor } from '../_shared/ai/config.ts';
import { createAiProvider } from '../_shared/ai/provider.ts';
import { emptyUsage } from '../_shared/ai/types.ts';
import { recordAiRun } from '../_shared/ai/usage.ts';
import { displayPageOf, masksFromCrops, operatorBook, pageCrops, sameMasks } from '../_shared/concept_book.ts';
import { CONCEPT_PAGE_PROMPT_VERSION, readConceptPageBody } from './prompt.ts';
import { readConceptPage } from './read.ts';

const FEATURE = 'concept_page_read';
const RATE_LIMIT_PER_MINUTE = 20;
const EFFORTS = new Set(['none', 'low', 'medium', 'high']);

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return errorResponse(405, 'method_not_allowed');

  const auth = await authenticate(req);
  if (!auth) return errorResponse(401, 'unauthorized');
  if (!(await isSuperadmin(auth))) return errorResponse(403, 'forbidden');

  let body: Record<string, unknown>;
  try {
    const parsed = await req.json();
    body = parsed && typeof parsed === 'object' ? parsed : {};
  } catch {
    return errorResponse(400, 'invalid_json');
  }
  const read = readConceptPageBody(body);
  if (!read.ok) return errorResponse(400, read.error);
  const effortRaw = typeof body.effort === 'string' ? body.effort.trim() : '';
  const effort = EFFORTS.has(effortRaw) ? effortRaw : 'low';

  const save = body.save === true;
  const academyId = String(body.academy_id ?? '');
  const bookId = String(body.book_id ?? '');
  const readIndex = Number(body.read_index);
  if (save) {
    if (readIndex !== 1 && readIndex !== 2) return errorResponse(400, 'invalid_read_index');
    if (!read.input.gradeLabel) return errorResponse(400, 'grade_required');
    const book = await operatorBook(auth, academyId, bookId);
    if (!book) return errorResponse(403, 'book_forbidden');
    const crops = await pageCrops(auth, academyId, bookId, read.input.gradeLabel, read.input.rawPage);
    if (!crops) return errorResponse(502, 'crops_read_failed');
    const masks = masksFromCrops(crops);
    if (!sameMasks(masks, read.input.masks)) return errorResponse(409, 'masks_mismatch');
    read.input.bookName = book.name;
    read.input.masks = masks;
    read.input.displayPage = displayPageOf(crops);
    read.input.unitPath = read.input.unitPath.slice(0, 3);
  }

  const provider = createAiProvider({ timeoutMs: 140000 });
  if (!provider) return errorResponse(503, 'ai_not_configured');

  const since = new Date(Date.now() - 60_000).toISOString();
  const { count } = await auth.admin
    .from('ai_runs')
    .select('id', { count: 'exact', head: true })
    .eq('created_by', auth.userId)
    .eq('feature', FEATURE)
    .gte('created_at', since);
  if ((count ?? 0) >= RATE_LIMIT_PER_MINUTE) return errorResponse(429, 'rate_limited');

  const budget = await getBudgetStatus(auth.admin).catch(() => null);
  if (budget?.exceeded && budget.mode === 'block') return errorResponse(429, 'budget_exceeded');

  const model = modelFor('primary');
  const started = Date.now();
  const outcome = await readConceptPage(provider, {
    model,
    reasoningEffort: effort,
    input: read.input,
    imageBase64: read.imageBase64,
    mimeType: read.mimeType,
    safetyId: await safetyIdentifier(auth.userId),
  });
  const latencyMs = Date.now() - started;
  if (outcome.error) console.error(`[${FEATURE}] p${read.input.rawPage} failed:`, outcome.error);

  const usage = outcome.result?.usage ?? emptyUsage();
  const usedModel = outcome.result?.model || model;
  const costUsd = outcome.result ? estimateCostUsd(usedModel, usage) : null;
  await recordAiRun(auth.admin, {
    feature: FEATURE,
    provider: provider.name,
    model: usedModel,
    promptVersion: CONCEPT_PAGE_PROMPT_VERSION,
    status: outcome.error ? 'error' : 'ok',
    error: outcome.error,
    usage,
    costUsd,
    latencyMs,
    academyId: save ? academyId : null,
    createdBy: auth.userId,
  });

  if (!outcome.page) {
    return jsonResponse(
      { ok: false, error: outcome.error ?? 'ai_failed', model: usedModel, usage, cost_usd: costUsd, latency_ms: latencyMs },
      502,
    );
  }

  let transcriptId: string | null = null;
  if (save) {
    const { data, error } = await auth.admin
      .from('concept_page_transcripts')
      .upsert(
        {
          academy_id: academyId,
          book_id: bookId,
          grade_label: read.input.gradeLabel,
          raw_page: read.input.rawPage,
          display_page: read.input.displayPage ?? null,
          read_index: readIndex,
          prompt_version: CONCEPT_PAGE_PROMPT_VERSION,
          model: usedModel,
          masks: read.input.masks,
          page: outcome.page,
          usage,
          cost_usd: costUsd,
          created_by: auth.userId,
          created_at: new Date().toISOString(),
        },
        { onConflict: 'academy_id,book_id,grade_label,raw_page,read_index,prompt_version' },
      )
      .select('id')
      .single();
    if (error || !data) {
      console.error(`[${FEATURE}] save failed:`, error?.message);
      return errorResponse(502, 'save_failed');
    }
    transcriptId = String((data as Record<string, unknown>).id);
  }

  return jsonResponse({
    ok: true,
    page: outcome.page,
    model: usedModel,
    effort,
    usage,
    cost_usd: costUsd,
    latency_ms: latencyMs,
    prompt_version: CONCEPT_PAGE_PROMPT_VERSION,
    ...(save ? { transcript_id: transcriptId, display_page: read.input.displayPage ?? null } : {}),
  });
});
