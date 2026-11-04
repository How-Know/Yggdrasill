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
import { runThinkChat, REVIEW_BATCH_FINAL_RESERVE_MS } from './chat.ts';
import { runReviewBatch } from './concept_review_batch.ts';
import { CONCEPT_REFERENCE_VERSION } from './concept_reference.ts';
import { CRITERION_REFERENCE_VERSION } from './criterion_reference.ts';
import { CONCEPT_DRAFT_REFERENCE_VERSION } from './concept_draft_reference.ts';
import { createDecisionDraft, createMemoryFeedbackDraft, createSpecExport } from './drafts.ts';
import { computeFeatures, parseClientFeatures, type DbFeatureCheck, type ThinkFeatures } from './features.ts';
import { THINK_PROMPT_VERSION } from './prompts.ts';
import { SupabaseThinkStore, type SupabaseLike } from './store.ts';
import { handleTextbookProblemFix } from './textbook_problem_fix.ts';
import { handleTextbookProblemRenderCheck, handleTextbookProblemReview } from './textbook_problem_review.ts';
import { MAX_MESSAGE_CHARS, parseAttachments, uuidOrNull } from './validate.ts';

declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void } | undefined;

type Body = Record<string, unknown>;

function runInBackground(task: Promise<unknown>) {
  if (typeof EdgeRuntime !== 'undefined' && EdgeRuntime?.waitUntil) EdgeRuntime.waitUntil(task);
}

/**
 * 긴 JSON 응답(book_review 등)이 Supabase 게이트웨이의 150초 유휴 제한(504 Request idle timeout)에 끊기지 않도록
 * 200 헤더와 공백을 10초마다 먼저 흘려보낸 뒤 완료 시 JSON 본문(원래 상태 코드는 http_status)을 기록한다.
 */
function keepAliveJson(work: () => Promise<Response>, intervalMs = 10_000): Response {
  const enc = new TextEncoder();
  let timer: ReturnType<typeof setInterval> | undefined;
  let closed = false;
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      const push = (s: string) => {
        if (closed) return;
        try {
          controller.enqueue(enc.encode(s));
        } catch {
          closed = true;
        }
      };
      push(' ');
      timer = setInterval(() => push(' '), intervalMs);
      void (async () => {
        let out: Record<string, unknown>;
        try {
          const res = await work();
          const text = await res.text();
          let parsed: unknown = null;
          try {
            parsed = JSON.parse(text);
          } catch {
            parsed = null;
          }
          const obj = parsed && typeof parsed === 'object' && !Array.isArray(parsed)
            ? (parsed as Record<string, unknown>)
            : { ok: false, error: 'invalid_response' };
          out = { ...obj, http_status: res.status };
        } catch (e) {
          console.error('[ai_think] keepalive work failed:', e instanceof Error ? e.message : String(e));
          out = { ok: false, error: 'internal_error', message: '서버 오류가 발생했습니다.', http_status: 500 };
        }
        clearInterval(timer);
        push(JSON.stringify(out));
        if (!closed) {
          closed = true;
          try {
            controller.close();
          } catch {
            // 이미 닫힘
          }
        }
      })();
    },
    cancel() {
      closed = true;
      clearInterval(timer);
    },
  });
  return new Response(stream, { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
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

async function handleBookReview(req: Request, auth: AuthContext, body: Body): Promise<Response> {
  const subAction = body.sub_action === 'approve' ? 'approve' : 'run';
  const bookId = uuidOrNull(body.book_id);
  const bookName = typeof body.book_name === 'string' ? body.book_name.trim() : '';
  let jobId = uuidOrNull(body.job_id);
  let walkId: string | null = null;
  let conversationId = uuidOrNull(body.conversation_id);

  const wallClockMs = thinkWallClockMs();
  const provider = createAiProvider({ timeoutMs: wallClockMs + 5000 });
  if (!provider) return errorResponse(503, 'ai_not_configured', 'OPENAI_API_KEY 비밀값이 설정되지 않았습니다.');
  const budget = await getBudgetStatus(auth.admin).catch(() => null);
  if (budget?.exceeded && budget.mode === 'block') return errorResponse(429, 'budget_exceeded', '이번 달 AI 한도를 넘었습니다.');

  const store = new SupabaseThinkStore(auth.userClient as unknown as SupabaseLike);
  if (!conversationId) {
    const conv = await store.createConversation(`교재 개념 추가 검수: ${bookName || '새 교재'}`.slice(0, 120));
    conversationId = conv.id;
  }
  if (!jobId) {
    if (!bookId) return errorResponse(400, 'book_id_required', '교재 id가 필요합니다.');
    const walkRes = (await store.courseMapRead('concept_review_book_walk', {
      p_source_book_id: bookId,
      p_source_scope: 'all',
      p_offset: 0,
      p_limit: 40,
    })) as Record<string, unknown>;
    walkId = typeof walkRes.walk_id === 'string' ? walkRes.walk_id : null;
    if (!walkId) return errorResponse(502, 'walk_create_failed', '교재 검수 목록을 만들지 못했습니다.');
    const startRes = (await store.reviewJobRpc('concept_review_job_start', {
      p_walk_id: walkId,
      p_title: `${bookName || '새 교재'} 개념 추가 검수`.slice(0, 120),
    })) as Record<string, unknown>;
    jobId = typeof startRes.job_id === 'string' ? startRes.job_id : null;
    if (!jobId) return errorResponse(502, 'job_start_failed', '교재 검수 작업을 열지 못했습니다.');
  }

  const safetyId = await safetyIdentifier(auth.userId);
  const batchWallMs = Math.min(wallClockMs, 115_000);
  const runBatchOnce = async () => {
    const startedAt = Date.now();
    const signal = AbortSignal.any([req.signal, AbortSignal.timeout(batchWallMs + 15_000)]);
    const out = await runReviewBatch(
      {
        callId: `book_review_${startedAt}`,
        rawArguments: JSON.stringify({ job_id: jobId, target: 25 }),
        conversationId: conversationId!,
        userId: auth.userId,
        safetyId,
        signal,
        deadline: startedAt + batchWallMs - REVIEW_BATCH_FINAL_RESERVE_MS,
        round: 1,
        startedAt,
      },
      { holder: `think:${conversationId}:${startedAt}`, leases: new Map(), cards: 0 },
      { provider, store, recordRun: (rec) => recordAiRun(auth.admin, rec), env: Deno.env, now: Date.now },
    );
    try {
      return JSON.parse(out.output) as Record<string, unknown>;
    } catch {
      return { error: 'batch_parse_failed' } as Record<string, unknown>;
    }
  };

  const applyPendingCards = async () => {
    const stRes = await auth.userClient.rpc('concept_review_job_status', { p_job_id: jobId, p_open_limit: 20 });
    const st = (stRes.data ?? {}) as Record<string, unknown>;
    const fromStatus = Array.isArray(st.pending_cards) ? (st.pending_cards as Record<string, unknown>[]) : [];
    const { data: convActions } = await auth.admin
      .from('ai_actions')
      .select('id,kind,status')
      .eq('conversation_id', conversationId!)
      .eq('status', 'proposed')
      .order('created_at', { ascending: true });
    const byId = new Map<string, { action_id: string; kind: string }>();
    for (const c of fromStatus) {
      const id = typeof c.action_id === 'string' ? c.action_id : '';
      if (id) byId.set(id, { action_id: id, kind: String(c.kind ?? '') });
    }
    for (const a of (convActions ?? []) as Record<string, unknown>[]) {
      const id = typeof a.id === 'string' ? a.id : '';
      if (id && !byId.has(id)) byId.set(id, { action_id: id, kind: String(a.kind ?? '') });
    }
    const ordered = [...byId.values()].sort((a, b) => {
      const ka = a.kind === 'concept_review_record' ? 0 : 1;
      const kb = b.kind === 'concept_review_record' ? 0 : 1;
      return ka - kb;
    });
    let appliedReviews = 0;
    let appliedFixes = 0;
    for (const card of ordered) {
      const res = await auth.userClient.rpc('course_think_action_apply', { p_id: card.action_id, p_overrides: {} });
      if (!res.error) {
        if (card.kind === 'concept_review_record') appliedReviews += 1;
        else appliedFixes += 1;
      } else {
        console.error('[ai_think] book_review apply card error:', card.action_id, res.error.message);
      }
    }
    return { appliedReviews, appliedFixes };
  };

  const submitRemainingDrafts = async (): Promise<boolean> => {
    const { count } = await auth.admin
      .from('concept_review_job_items')
      .select('pos', { count: 'exact', head: true })
      .eq('job_id', jobId!)
      .eq('state', 'drafted');
    if (!count || count <= 0) return false;
    const claimRes = await auth.userClient.rpc('concept_review_job_claim', {
      p_job_id: jobId,
      p_holder: `think:${conversationId}:${Date.now()}`,
      p_mode: 'take',
    });
    const gen = Number((claimRes.data as Record<string, unknown> | null)?.gen ?? 0);
    if (!Number.isFinite(gen) || gen <= 0) return false;
    for (let i = 0; i < 6; i += 1) {
      const subRes = await auth.userClient.rpc('concept_review_job_submit', {
        p_job_id: jobId,
        p_gen: gen,
        p_conversation_id: conversationId,
        p_reason: `개념 검수 작업 묶음 검수 결과(${new Date().toISOString().slice(0, 10)})`,
        p_max_cards: 13,
      });
      const sub = (subRes.data ?? {}) as Record<string, unknown>;
      if (subRes.error || sub.submitted !== true) break;
    }
    return true;
  };

  const syncProgressSnapshot = async () => {
    for (let i = 0; i < 4; i += 1) {
      const step = await auth.userClient.rpc('concept_review_progress_step', { p_job_id: jobId, p_limit: 100 });
      const data = (step.data ?? {}) as Record<string, unknown>;
      if (step.error || data.more !== true) break;
    }
  };

  const readFastStatus = async (): Promise<Record<string, unknown>> => {
    const stRes = await auth.userClient.rpc('concept_review_job_status', { p_job_id: jobId, p_open_limit: 20 });
    const st = ((stRes.data ?? {}) as Record<string, unknown>);
    if (typeof st.progress_line === 'string' && st.progress_line) return st;
    const last = (st.progress_last_success ?? {}) as Record<string, unknown>;
    return {
      ...st,
      progress_line: typeof last.progress_line === 'string' ? last.progress_line : null,
      first_pass_line: typeof last.first_pass_line === 'string' ? last.first_pass_line : null,
      condition_line: typeof last.condition_line === 'string' ? last.condition_line : null,
    };
  };

  if (subAction === 'approve') {
    let totalReviews = 0;
    let totalFixes = 0;
    for (let pass = 0; pass < 4; pass += 1) {
      const applied = await applyPendingCards();
      totalReviews += applied.appliedReviews;
      totalFixes += applied.appliedFixes;
      const submittedMore = await submitRemainingDrafts();
      if (!submittedMore && applied.appliedReviews === 0 && applied.appliedFixes === 0) break;
    }
    await syncProgressSnapshot();
    const live = await readFastStatus();
    return jsonResponse({
      ok: true,
      job_id: jobId,
      conversation_id: conversationId,
      applied_reviews: totalReviews,
      applied_fixes: totalFixes,
      live,
    });
  }

  const batch = await runBatchOnce();
  await syncProgressSnapshot();
  const live = await readFastStatus();
  const endReason = String(batch.end_reason ?? '');
  const hasMore = endReason === 'target_reached' || endReason === 'time_budget';
  return jsonResponse({
    ok: true,
    job_id: jobId,
    walk_id: walkId,
    conversation_id: conversationId,
    batch,
    live,
    has_more: hasMore,
  });
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
      case 'book_review':
        return keepAliveJson(() => handleBookReview(req, auth, body));
      case 'textbook_problem_review':
        return await handleTextbookProblemReview(req, auth, body);
      case 'textbook_problem_render_check':
        return await handleTextbookProblemRenderCheck(req, auth, body);
      case 'textbook_problem_fix':
        return await handleTextbookProblemFix(req, auth, body);
      default:
        return errorResponse(400, 'unknown_action');
    }
  } catch (e) {
    console.error('[ai_think] handler failed:', e instanceof Error ? e.message : String(e));
    return errorResponse(500, 'internal_error', '서버 오류가 발생했습니다.');
  }
});
