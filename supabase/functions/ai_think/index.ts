// ai_think: 매니저앱 Think 화면 전용 (슈퍼관리자만).
//   POST { action: 'status', client?: { features } }
//   POST { action: 'chat', conversation_id?, concept_id?, criterion_id?, message, attachments?, options?: { deep?, web_search? }, role?: { think_role_id, extra_ref_departments }, client?: { features } }  → text/event-stream
//   role은 새 대화(conversation_id 없음)에서만 쓴다. 이어지는 대화는 DB에 저장된 역할을 쓴다.
//   concept_id·criterion_id는 개념 탭이 고른 개념·정리 기준. 기존 대화에만 붙고, 서버가 요청마다 저장본을 다시 읽는다(본문은 받지 않는다).
//   draft_id는 개념 초안 검토 창의 초안. 새 대화에도 붙는다(교육 부서, 제목 '개념 초안 검토'). 본문·미저장 편집은 받지 않는다.
//   client.features: 앱이 지원하는 기능 버전(예: { conversation_split: 1 }). 기능 상태는 요청마다 features.ts로 계산한다.
//   POST { action: 'decision_draft', conversation_id }
//   POST { action: 'spec_export', memory_id }
//   POST { action: 'memory_feedback_draft', ... } → { draft, run_id, update_baseline?{memory_id,version} }
//   POST { action: 'review_job_continue', job_id, conversation_id, client? } → text/event-stream (기본 꺼짐, 409 review_runner_off)
// 설계: docs/architecture/ai.md

import { corsHeaders } from '../_shared/cors.ts';
import { authenticate, errorResponse, isSuperadmin, jsonResponse, safetyIdentifier, type AuthContext } from '../_shared/ai/auth.ts';
import { getBudgetStatus } from '../_shared/ai/budget.ts';
import { aiProviderName, modelFor, thinkWallClockMs } from '../_shared/ai/config.ts';
import { createAiProvider, isAiConfigured } from '../_shared/ai/provider.ts';
import { sseComment, sseEvent } from '../_shared/ai/sse.ts';
import { recordAiRun } from '../_shared/ai/usage.ts';
import { normalizeThinkRole, parseDepartmentList } from './access_context.ts';
import { runThinkChat } from './chat.ts';
import { CONCEPT_REFERENCE_VERSION } from './concept_reference.ts';
import { CRITERION_REFERENCE_VERSION } from './criterion_reference.ts';
import { CONCEPT_DRAFT_REFERENCE_VERSION } from './concept_draft_reference.ts';
import { createDecisionDraft, createMemoryFeedbackDraft, createSpecExport } from './drafts.ts';
import { computeFeatures, parseClientFeatures, type DbFeatureCheck, type ThinkFeatures } from './features.ts';
import { THINK_PROMPT_VERSION } from './prompts.ts';
import { SupabaseThinkStore, type SupabaseLike } from './store.ts';
import { MAX_MESSAGE_CHARS, parseAttachments, uuidOrNull } from './validate.ts';

declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void } | undefined;

type Body = Record<string, unknown>;

function runInBackground(task: Promise<unknown>) {
  if (typeof EdgeRuntime !== 'undefined' && EdgeRuntime?.waitUntil) EdgeRuntime.waitUntil(task);
}

// 슈퍼관리자 확인(Deno.serve)을 통과한 요청만 여기 온다.
async function thinkFeatures(store: SupabaseThinkStore, body: Body): Promise<{ features: ThinkFeatures; db: DbFeatureCheck }> {
  const db = await store.dbFeatures();
  return { features: computeFeatures(db, parseClientFeatures(body.client), true), db };
}

async function handleStatus(auth: AuthContext, body: Body): Promise<Response> {
  const budget = await getBudgetStatus(auth.admin).catch(() => null);
  const { features, db } = await thinkFeatures(new SupabaseThinkStore(auth.userClient as unknown as SupabaseLike), body);
  return jsonResponse({
    ok: true,
    configured: isAiConfigured(),
    provider: aiProviderName(),
    models: { primary: modelFor('primary'), deep: modelFor('deep'), fast: modelFor('fast') },
    web_search_enabled: budget?.webSearchEnabled ?? true,
    budget: budget
      ? { limit_usd: budget.limitUsd, mode: budget.mode, spent_usd: budget.spentUsd, exceeded: budget.exceeded }
      : null,
    prompt_version: THINK_PROMPT_VERSION,
    features,
    features_db_error: db.ok || db.missing ? null : db.error.slice(0, 300),
    // DB·앱 버전과 무관한 Edge 기능. 앱은 없으면 옛 Edge로 본다.
    capabilities: {
      concept_reference: CONCEPT_REFERENCE_VERSION,
      criterion_reference: CRITERION_REFERENCE_VERSION,
      concept_draft_reference: CONCEPT_DRAFT_REFERENCE_VERSION,
    },
  });
}

interface ReviewJobRun {
  jobId: string;
  gen: number;
  maxItems: number;
  runId: string;
}

async function handleChat(req: Request, auth: AuthContext, body: Body, reviewRun: ReviewJobRun | null = null): Promise<Response> {
  const message = typeof body.message === 'string' ? body.message.trim() : '';
  if (message.length > MAX_MESSAGE_CHARS) return errorResponse(400, 'message_too_long', `메시지는 ${MAX_MESSAGE_CHARS}자 이하여야 합니다.`);
  const attachments = parseAttachments(body.attachments, auth.userId);
  if (typeof attachments === 'string') return errorResponse(400, attachments);
  if (!message && attachments.length === 0) return errorResponse(400, 'message_required', '메시지를 입력하세요.');
  const conversationId = body.conversation_id == null ? null : uuidOrNull(body.conversation_id);
  if (body.conversation_id != null && !conversationId) return errorResponse(400, 'conversation_id_invalid');
  // 개념 탭이 고른 개념. 대화 ID와 따로 받고, 본문은 받지 않는다(서버가 저장본을 다시 읽는다).
  const conceptId = body.concept_id == null ? null : uuidOrNull(body.concept_id);
  if (body.concept_id != null && !conceptId) return errorResponse(400, 'concept_id_invalid');
  if (conceptId && !conversationId) {
    return errorResponse(400, 'concept_requires_conversation', '개념 참고는 이미 있는 대화에만 붙일 수 있습니다.');
  }
  // 개념 상세에서 고른 서술. 없으면 기본 서술(개념 본문). 서술 글도 받지 않는다.
  const conceptStatementId = body.statement_id == null ? null : uuidOrNull(body.statement_id);
  if (body.statement_id != null && !conceptStatementId) return errorResponse(400, 'statement_id_invalid');
  if (conceptStatementId && !conceptId) {
    return errorResponse(400, 'statement_requires_concept', '서술 참고는 개념을 고른 질문에만 붙일 수 있습니다.');
  }
  const criterionId = body.criterion_id == null ? null : uuidOrNull(body.criterion_id);
  if (body.criterion_id != null && !criterionId) return errorResponse(400, 'criterion_id_invalid');
  if (criterionId && !conversationId) {
    return errorResponse(400, 'criterion_requires_conversation', '정리 기준 참고는 이미 있는 대화에만 붙일 수 있습니다.');
  }
  // 개념 초안 검토 창의 초안. 새 대화에도 붙고(교육 부서·고정 제목), 본문은 받지 않는다.
  const conceptDraftId = body.draft_id == null ? null : uuidOrNull(body.draft_id);
  if (body.draft_id != null && !conceptDraftId) return errorResponse(400, 'draft_id_invalid');
  const options = (body.options && typeof body.options === 'object' ? body.options : {}) as Body;
  const roleBody = (body.role && typeof body.role === 'object' ? body.role : null) as Body | null;
  const newConversationRole = !conversationId && conceptDraftId
    ? { thinkRoleId: 'education' as const, extraRefDepartments: roleBody ? parseDepartmentList(roleBody.extra_ref_departments) : [] }
    : !conversationId && roleBody
    ? {
      thinkRoleId: normalizeThinkRole(roleBody.think_role_id),
      extraRefDepartments: parseDepartmentList(roleBody.extra_ref_departments),
    }
    : null;

  const wallClockMs = thinkWallClockMs();
  const provider = createAiProvider({ timeoutMs: wallClockMs + 5000 });
  if (!provider) return errorResponse(503, 'ai_not_configured', 'OPENAI_API_KEY 비밀값이 설정되지 않았습니다.');

  const budget = await getBudgetStatus(auth.admin).catch(() => null);
  if (budget?.exceeded && budget.mode === 'block') {
    return errorResponse(429, 'budget_exceeded', `이번 달 AI 한도($${budget.limitUsd})를 넘었습니다. 사용량 탭에서 한도를 조정하세요.`);
  }
  const wantsWebSearch = options.web_search === true;
  const webSearch = wantsWebSearch && (budget?.webSearchEnabled ?? true);

  const startedAt = Date.now();
  const clientAbort = new AbortController();
  const signal = AbortSignal.any([clientAbort.signal, req.signal, AbortSignal.timeout(wallClockMs)]);
  const safetyId = await safetyIdentifier(auth.userId);
  const store = new SupabaseThinkStore(auth.userClient as unknown as SupabaseLike);
  const { features } = await thinkFeatures(store, body);

  let closed = false;
  let runCost: number | null = null;
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      const push = (chunk: Uint8Array) => {
        if (closed) return;
        try {
          controller.enqueue(chunk);
        } catch {
          closed = true;
        }
      };
      const emit = (event: string, data: Record<string, unknown>) => push(sseEvent(event, data));
      const ping = setInterval(() => push(sseComment('ping')), 15000);

      if (budget?.exceeded) {
        emit('notice', { code: 'budget_warning', spent_usd: budget.spentUsd, limit_usd: budget.limitUsd });
      }
      if (wantsWebSearch && !webSearch) emit('notice', { code: 'web_search_disabled' });

      const task = runThinkChat(
        {
          userId: auth.userId,
          safetyId,
          conversationId,
          message,
          attachments,
          deep: options.deep === true,
          webSearch,
          signal,
          startedAt,
          wallClockMs,
          features,
          newConversationRole,
          conceptId,
          conceptStatementId,
          criterionId,
          conceptDraftId,
          reviewJobRun: reviewRun ? { jobId: reviewRun.jobId, gen: reviewRun.gen, maxItems: reviewRun.maxItems } : null,
        },
        {
          provider,
          store,
          recordRun: (rec) => recordAiRun(auth.admin, rec),
          emit,
        },
      )
        .then((outcome) => {
          runCost = outcome.costUsd ?? null;
        })
        .catch((e) => {
          console.error('[ai_think] unexpected:', e instanceof Error ? e.message : String(e));
          emit('error', { code: 'internal_error', message: '서버 오류로 답변을 만들지 못했습니다.' });
        })
        .finally(async () => {
          if (reviewRun) {
            await store.reviewJobRunFinish(reviewRun.runId, runCost).catch((e) => {
              console.error('[ai_think] review run finish failed:', e instanceof Error ? e.message : String(e));
            });
          }
          clearInterval(ping);
          if (!closed) {
            closed = true;
            try {
              controller.close();
            } catch {
              // 이미 닫힘
            }
          }
        });
      runInBackground(task);
    },
    cancel() {
      closed = true;
      clientAbort.abort('client_closed');
    },
  });

  return new Response(stream, {
    headers: {
      ...corsHeaders,
      'Content-Type': 'text/event-stream; charset=utf-8',
      'Cache-Control': 'no-cache',
      'X-Accel-Buffering': 'no',
    },
  });
}

const REVIEW_RUN_MESSAGE =
  '[자동 이어하기] 이 검수 작업을 한 묶음 이어서 한다. 판단·초안 저장·카드 제출까지만 하고, 진행 표시 한 줄과 저장한 위치를 알린다.';

/**
 * 답변 뒤 자동 이어하기 한 번. 환경 스위치(THINK_REVIEW_RUNNER=on)와 작업별 auto_run이 모두 켜져야 하고(둘 다 기본 꺼짐),
 * DB 관문이 한도·대기 카드·연속 무진척을 보고 임대를 넘겨받은 뒤에만 채팅 한 번을 돈다. 승인은 하지 않는다.
 */
async function handleReviewJobContinue(req: Request, auth: AuthContext, body: Body): Promise<Response> {
  const jobId = uuidOrNull(body.job_id);
  const conversationId = uuidOrNull(body.conversation_id);
  if (!jobId || !conversationId) return errorResponse(400, 'invalid_request', '작업과 대화 id가 필요합니다.');
  if (Deno.env.get('THINK_REVIEW_RUNNER') !== 'on') {
    return errorResponse(409, 'review_runner_off', '답변 뒤 자동 이어하기가 꺼져 있습니다.');
  }
  const store = new SupabaseThinkStore(auth.userClient as unknown as SupabaseLike);
  let gate: Record<string, unknown>;
  try {
    gate = await store.reviewJobRunGate(jobId, `runner:${crypto.randomUUID()}`);
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    return errorResponse(409, 'review_runner_blocked', message.slice(message.lastIndexOf(': ') + 2).slice(0, 120));
  }
  if (gate.allowed !== true || typeof gate.run_id !== 'string') {
    return errorResponse(409, 'review_runner_blocked', String(gate.reason ?? 'unknown'));
  }
  return await handleChat(req, auth, { ...body, conversation_id: conversationId, message: REVIEW_RUN_MESSAGE, attachments: [] }, {
    jobId,
    gen: Number(gate.gen),
    maxItems: Number(gate.max_items) || 5,
    runId: gate.run_id,
  });
}

async function handleDecisionDraft(auth: AuthContext, body: Body): Promise<Response> {
  const conversationId = uuidOrNull(body.conversation_id);
  if (!conversationId) return errorResponse(400, 'conversation_id_invalid');
  const provider = createAiProvider({ timeoutMs: 120000 });
  if (!provider) return errorResponse(503, 'ai_not_configured', 'OPENAI_API_KEY 비밀값이 설정되지 않았습니다.');
  const budget = await getBudgetStatus(auth.admin).catch(() => null);
  if (budget?.exceeded && budget.mode === 'block') return errorResponse(429, 'budget_exceeded', '이번 달 AI 한도를 넘었습니다.');

  const out = await createDecisionDraft(
    {
      provider,
      store: new SupabaseThinkStore(auth.userClient as unknown as SupabaseLike),
      recordRun: (rec) => recordAiRun(auth.admin, rec),
    },
    { conversationId, userId: auth.userId, safetyId: await safetyIdentifier(auth.userId) },
  );
  if (!out.ok) return errorResponse(out.error === 'conversation_not_found' ? 404 : 422, out.error, out.message);
  return jsonResponse({ ok: true, draft: out.value, run_id: out.runId });
}

function uuidList(v: unknown, max = 20): string[] {
  if (!Array.isArray(v)) return [];
  const out: string[] = [];
  for (const item of v) {
    const id = uuidOrNull(item);
    if (id) out.push(id);
    if (out.length >= max) break;
  }
  return out;
}

async function handleMemoryFeedbackDraft(auth: AuthContext, body: Body): Promise<Response> {
  const conversationId = uuidOrNull(body.conversation_id);
  const assistantMessageId = uuidOrNull(body.assistant_message_id);
  if (!conversationId || !assistantMessageId) return errorResponse(400, 'invalid_request', '대화와 답변 id가 필요합니다.');
  const feedback = typeof body.feedback === 'string' ? body.feedback.trim() : '';
  if (!feedback) return errorResponse(400, 'feedback_required', '피드백을 입력하세요.');
  const provider = createAiProvider({ timeoutMs: 120000 });
  if (!provider) return errorResponse(503, 'ai_not_configured', 'OPENAI_API_KEY 비밀값이 설정되지 않았습니다.');
  const budget = await getBudgetStatus(auth.admin).catch(() => null);
  if (budget?.exceeded && budget.mode === 'block') return errorResponse(429, 'budget_exceeded', '이번 달 AI 한도를 넘었습니다.');

  const out = await createMemoryFeedbackDraft(
    {
      provider,
      store: new SupabaseThinkStore(auth.userClient as unknown as SupabaseLike),
      recordRun: (rec) => recordAiRun(auth.admin, rec),
    },
    {
      conversationId,
      assistantMessageId,
      userMessageIds: uuidList(body.user_message_ids),
      feedback,
      updateMemoryId: uuidOrNull(body.update_memory_id),
      userId: auth.userId,
      safetyId: await safetyIdentifier(auth.userId),
    },
  );
  if (!out.ok) {
    const status = out.error === 'conversation_not_found' || out.error === 'message_not_found' || out.error === 'memory_not_found'
      ? 404
      : 422;
    return errorResponse(status, out.error, out.message);
  }
  return jsonResponse({
    ok: true,
    draft: out.value,
    run_id: out.runId,
    update_baseline: out.update_baseline,
  });
}

async function handleSpecExport(auth: AuthContext, body: Body): Promise<Response> {
  const memoryId = uuidOrNull(body.memory_id);
  if (!memoryId) return errorResponse(400, 'memory_id_invalid');
  const provider = createAiProvider({ timeoutMs: 120000 });
  if (!provider) return errorResponse(503, 'ai_not_configured', 'OPENAI_API_KEY 비밀값이 설정되지 않았습니다.');
  const budget = await getBudgetStatus(auth.admin).catch(() => null);
  if (budget?.exceeded && budget.mode === 'block') return errorResponse(429, 'budget_exceeded', '이번 달 AI 한도를 넘었습니다.');

  const out = await createSpecExport(
    {
      provider,
      store: new SupabaseThinkStore(auth.userClient as unknown as SupabaseLike),
      recordRun: (rec) => recordAiRun(auth.admin, rec),
    },
    { memoryId, userId: auth.userId, safetyId: await safetyIdentifier(auth.userId) },
  );
  if (!out.ok) return errorResponse(out.error === 'memory_not_found' ? 404 : 422, out.error, out.message);
  return jsonResponse({ ok: true, markdown: out.value.markdown, suggested_path: out.value.suggestedPath, run_id: out.runId });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return errorResponse(405, 'method_not_allowed');

  const auth = await authenticate(req);
  if (!auth) return errorResponse(401, 'unauthorized', '로그인이 필요합니다.');
  if (!(await isSuperadmin(auth))) return errorResponse(403, 'forbidden', '슈퍼관리자만 사용할 수 있습니다.');

  let body: Body;
  try {
    const parsed = await req.json();
    body = parsed && typeof parsed === 'object' ? (parsed as Body) : {};
  } catch {
    return errorResponse(400, 'invalid_json');
  }

  try {
    switch (String(body.action ?? '')) {
      case 'status':
        return await handleStatus(auth, body);
      case 'chat':
        return await handleChat(req, auth, body);
      case 'review_job_continue':
        return await handleReviewJobContinue(req, auth, body);
      case 'decision_draft':
        return await handleDecisionDraft(auth, body);
      case 'memory_feedback_draft':
        return await handleMemoryFeedbackDraft(auth, body);
      case 'spec_export':
        return await handleSpecExport(auth, body);
      default:
        return errorResponse(400, 'unknown_action');
    }
  } catch (e) {
    console.error('[ai_think] handler failed:', e instanceof Error ? e.message : String(e));
    return errorResponse(500, 'internal_error', '서버 오류가 발생했습니다.');
  }
});
