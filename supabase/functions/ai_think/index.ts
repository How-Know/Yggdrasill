// ai_think: 매니저앱 Think 화면 전용 (슈퍼관리자만).
//   POST { action: 'status' }
//   POST { action: 'chat', conversation_id?, message, attachments?, options?: { deep?, web_search? } }  → text/event-stream
//   POST { action: 'decision_draft', conversation_id }
//   POST { action: 'spec_export', memory_id }
// 설계: docs/architecture/ai.md

import { corsHeaders } from '../_shared/cors.ts';
import { authenticate, errorResponse, isSuperadmin, jsonResponse, safetyIdentifier, type AuthContext } from '../_shared/ai/auth.ts';
import { getBudgetStatus } from '../_shared/ai/budget.ts';
import { aiProviderName, modelFor, thinkWallClockMs } from '../_shared/ai/config.ts';
import { createAiProvider, isAiConfigured } from '../_shared/ai/provider.ts';
import { sseComment, sseEvent } from '../_shared/ai/sse.ts';
import { recordAiRun } from '../_shared/ai/usage.ts';
import { runThinkChat } from './chat.ts';
import { createDecisionDraft, createSpecExport } from './drafts.ts';
import { THINK_PROMPT_VERSION } from './prompts.ts';
import { SupabaseThinkStore, type SupabaseLike } from './store.ts';
import { MAX_MESSAGE_CHARS, parseAttachments, uuidOrNull } from './validate.ts';

declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void } | undefined;

type Body = Record<string, unknown>;

function runInBackground(task: Promise<unknown>) {
  if (typeof EdgeRuntime !== 'undefined' && EdgeRuntime?.waitUntil) EdgeRuntime.waitUntil(task);
}

async function handleStatus(auth: AuthContext): Promise<Response> {
  const budget = await getBudgetStatus(auth.admin).catch(() => null);
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
  });
}

async function handleChat(req: Request, auth: AuthContext, body: Body): Promise<Response> {
  const message = typeof body.message === 'string' ? body.message.trim() : '';
  if (message.length > MAX_MESSAGE_CHARS) return errorResponse(400, 'message_too_long', `메시지는 ${MAX_MESSAGE_CHARS}자 이하여야 합니다.`);
  const attachments = parseAttachments(body.attachments, auth.userId);
  if (typeof attachments === 'string') return errorResponse(400, attachments);
  if (!message && attachments.length === 0) return errorResponse(400, 'message_required', '메시지를 입력하세요.');
  const conversationId = body.conversation_id == null ? null : uuidOrNull(body.conversation_id);
  if (body.conversation_id != null && !conversationId) return errorResponse(400, 'conversation_id_invalid');
  const options = (body.options && typeof body.options === 'object' ? body.options : {}) as Body;

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

  let closed = false;
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
        },
        {
          provider,
          store,
          recordRun: (rec) => recordAiRun(auth.admin, rec),
          emit,
        },
      )
        .catch((e) => {
          console.error('[ai_think] unexpected:', e instanceof Error ? e.message : String(e));
          emit('error', { code: 'internal_error', message: '서버 오류로 답변을 만들지 못했습니다.' });
        })
        .finally(() => {
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
        return await handleStatus(auth);
      case 'chat':
        return await handleChat(req, auth, body);
      case 'decision_draft':
        return await handleDecisionDraft(auth, body);
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
