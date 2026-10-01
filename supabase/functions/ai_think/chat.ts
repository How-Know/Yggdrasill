// Think 대화 한 턴: 컨텍스트 조립 → 모델 스트리밍 → (도구 호출 반복) → 저장·기록.
// AI 호출이 실패해도 사용자 메시지와 오류 상태는 남긴다.

import { estimateCostUsd, maxOutputTokensFor, modelFor, reasoningFor, type EnvReader, denoEnv } from '../_shared/ai/config.ts';
import {
  AiProviderError,
  addUsage,
  emptyUsage,
  type AiInputItem,
  type AiProvider,
  type AiResult,
  type AiSource,
  type AiUsage,
} from '../_shared/ai/types.ts';
import type { AiRunRecord } from '../_shared/ai/usage.ts';
import { workStateNote, type WorkState } from './actions.ts';
import { buildThinkContext, type AttachmentRef, type ThinkContextStore } from './context.ts';
import { THINK_PROMPT_VERSION, TITLE_PROMPT_VERSION, clip, titleInstructions } from './prompts.ts';
import { THINK_TOOLS, TOOL_LABELS, runThinkTool, type ThinkToolSource } from './tools.ts';

export interface ConversationRow {
  id: string;
  title: string;
  status: string;
  scope_type: string;
  scope_id: string | null;
}

export interface NewMessage {
  conversation_id: string;
  role: 'user' | 'assistant';
  content: string;
  status: 'complete' | 'error' | 'stopped';
  attachments?: AttachmentRef[];
  sources?: AiSource[];
  tool_calls?: ToolTrace[];
  commentary?: string | null;
  model?: string | null;
  run_id?: string | null;
}

export interface ThinkPersistence {
  getConversation(id: string): Promise<ConversationRow | null>;
  createConversation(title: string): Promise<ConversationRow>;
  updateConversationTitle(id: string, title: string): Promise<void>;
  insertMessage(msg: NewMessage): Promise<string>;
  getWorkState(conversationId: string): Promise<WorkState>;
  attachActions(ids: string[], messageId: string): Promise<void>;
}

export type ThinkStore = ThinkContextStore & ThinkToolSource & ThinkPersistence;

export interface ToolTrace {
  name: string;
  label: string;
  detail: string;
  ok: boolean;
}

export type Emit = (event: string, data: Record<string, unknown>) => void;

export interface ChatDeps {
  provider: AiProvider;
  store: ThinkStore;
  recordRun: (rec: AiRunRecord) => Promise<string | null>;
  emit: Emit;
  env?: EnvReader;
  now?: () => number;
}

export interface ChatInput {
  userId: string;
  safetyId: string;
  conversationId: string | null;
  message: string;
  attachments: AttachmentRef[];
  deep: boolean;
  webSearch: boolean;
  signal: AbortSignal;
  startedAt: number;
  wallClockMs: number;
}

export interface ChatOutcome {
  conversationId: string | null;
  userMessageId: string | null;
  assistantMessageId: string | null;
  runId: string | null;
  status: 'complete' | 'error' | 'stopped';
  errorCode?: string;
}

export const MAX_TOOL_ROUNDS = 6;

function fallbackTitle(message: string): string {
  const firstLine = message.trim().split('\n')[0] ?? '';
  return clip(firstLine, 30) || '새 대화';
}

function sanitizeTitle(raw: string): string | null {
  const t = raw.replace(/["'“”‘’`]/g, '').replace(/[.。]+$/, '').replace(/\s+/g, ' ').trim();
  return t ? clip(t, 40) : null;
}

function abortReason(signal: AbortSignal): 'stopped' | 'timeout' {
  const r = signal.reason;
  if (r === 'client_closed') return 'stopped';
  if (r instanceof DOMException && r.name === 'TimeoutError') return 'timeout';
  return 'stopped';
}

function dedupeSources(sources: AiSource[]): AiSource[] {
  const seen = new Set<string>();
  return sources.filter((s) => {
    if (!s.url || seen.has(s.url)) return false;
    seen.add(s.url);
    return true;
  });
}

async function generateTitle(deps: ChatDeps, input: ChatInput, conversationId: string): Promise<void> {
  const env = deps.env ?? denoEnv;
  const model = modelFor('fast', env);
  const started = (deps.now ?? Date.now)();
  let result: AiResult | null = null;
  let error: string | null = null;
  try {
    result = await deps.provider.complete(
      {
        model,
        instructions: titleInstructions(),
        input: [{ kind: 'message', role: 'user', parts: [{ type: 'text', text: clip(input.message, 2000) }] }],
        reasoningEffort: reasoningFor('fast', env),
        maxOutputTokens: 60,
        safetyId: input.safetyId,
      },
      input.signal,
    );
    const title = sanitizeTitle(result.messages.map((m) => m.text).join(' '));
    if (title) {
      await deps.store.updateConversationTitle(conversationId, title);
      deps.emit('title', { conversation_id: conversationId, title });
    }
  } catch (e) {
    error = e instanceof Error ? e.message : String(e);
  }
  await deps.recordRun({
    feature: 'think_title',
    provider: deps.provider.name,
    model: result?.model || model,
    promptVersion: TITLE_PROMPT_VERSION,
    status: error ? 'error' : 'ok',
    error,
    usage: result?.usage ?? emptyUsage(),
    costUsd: result ? estimateCostUsd(result.model || model, result.usage, 0, env) : null,
    latencyMs: (deps.now ?? Date.now)() - started,
    conversationId,
    createdBy: input.userId,
  });
}

export async function runThinkChat(input: ChatInput, deps: ChatDeps): Promise<ChatOutcome> {
  const env = deps.env ?? denoEnv;
  const now = deps.now ?? Date.now;
  const tier = input.deep ? 'deep' : 'primary';
  const model = modelFor(tier, env);
  const emit = deps.emit;

  // 1) 대화 준비
  let conversation: ConversationRow | null = null;
  let isNew = false;
  if (input.conversationId) {
    conversation = await deps.store.getConversation(input.conversationId);
    if (!conversation) {
      emit('error', { code: 'conversation_not_found', message: '대화를 찾을 수 없습니다.' });
      return { conversationId: null, userMessageId: null, assistantMessageId: null, runId: null, status: 'error', errorCode: 'conversation_not_found' };
    }
  } else {
    conversation = await deps.store.createConversation(fallbackTitle(input.message));
    isNew = true;
  }
  const conversationId = conversation.id;

  // 2) 컨텍스트는 이번 메시지를 저장하기 전에 만든다(지난 대화에 이번 질문이 중복되지 않도록).
  let workNote: string | null = null;
  if (!isNew) {
    try {
      workNote = workStateNote(await deps.store.getWorkState(conversationId));
    } catch (e) {
      console.error('[ai_think] work state failed:', e instanceof Error ? e.message : String(e));
    }
  }
  const ctx = await buildThinkContext(deps.store, {
    conversationId: isNew ? null : conversationId,
    userMessage: input.message,
    attachments: input.attachments,
    scope: { type: conversation.scope_type, id: conversation.scope_id },
    workNote,
  });
  const toolCtx = { conversationId, memoryRefs: ctx.memoryRefs };
  const actionIds: string[] = [];

  const userMessageId = await deps.store.insertMessage({
    conversation_id: conversationId,
    role: 'user',
    content: input.message,
    status: 'complete',
    attachments: input.attachments,
  });
  emit('conversation', {
    conversation_id: conversationId,
    user_message_id: userMessageId,
    title: conversation.title,
    created: isNew,
    model,
    context: {
      identity: ctx.identityIds.length,
      principles: ctx.principleIds.length,
      decisions: ctx.decisionIds.length,
      relevant: ctx.relevantIds,
      history_used: ctx.historyUsed,
      history_dropped: ctx.historyDropped,
    },
  });

  const titleTask = isNew ? generateTitle(deps, input, conversationId) : Promise.resolve();

  // 3) 모델 호출과 도구 반복
  let usage: AiUsage = emptyUsage();
  let cost = 0;
  let costKnown = true;
  let webSearchCalls = 0;
  let toolCallCount = 0;
  let resolvedModel = model;
  const traces: ToolTrace[] = [];
  const finalParts: string[] = [];
  const commentary: string[] = [];
  const sources: AiSource[] = [];
  const streamed = new Map<string, { phase: string; text: string }>();
  let status: ChatOutcome['status'] = 'complete';
  let errorCode: string | undefined;
  let errorMessage: string | null = null;

  const softDeadline = input.startedAt + Math.floor(input.wallClockMs * 0.65);
  let turnInput: AiInputItem[] = ctx.input;

  try {
    for (let round = 0; round < MAX_TOOL_ROUNDS; round++) {
      const forceFinal = round === MAX_TOOL_ROUNDS - 1 || now() > softDeadline;
      let result: AiResult | null = null;
      streamed.clear();

      const stream = deps.provider.stream(
        {
          model,
          instructions: ctx.instructions,
          input: turnInput,
          tools: THINK_TOOLS,
          webSearch: input.webSearch ? { contextSize: 'medium' } : undefined,
          toolChoice: forceFinal ? 'none' : 'auto',
          reasoningEffort: reasoningFor(tier, env),
          maxOutputTokens: maxOutputTokensFor(tier, env),
          cacheKey: `think:${conversationId}`,
          safetyId: input.safetyId,
        },
        input.signal,
      );

      for await (const ev of stream) {
        switch (ev.type) {
          case 'message_start':
            streamed.set(ev.itemId, { phase: ev.phase, text: '' });
            emit('message_start', { item_id: ev.itemId, phase: ev.phase });
            break;
          case 'text_delta': {
            const s = streamed.get(ev.itemId) ?? { phase: 'final', text: '' };
            s.text += ev.delta;
            streamed.set(ev.itemId, s);
            emit('delta', { item_id: ev.itemId, text: ev.delta });
            break;
          }
          case 'message_done': {
            const s = streamed.get(ev.itemId);
            if (s) s.phase = ev.phase;
            emit('message_done', { item_id: ev.itemId, phase: ev.phase });
            break;
          }
          case 'function_call_start':
            emit('tool', { call_id: ev.callId, name: ev.name, label: TOOL_LABELS[ev.name] ?? ev.name, status: 'running' });
            break;
          case 'web_search':
            emit('tool', {
              call_id: ev.itemId,
              name: 'web_search',
              label: TOOL_LABELS.web_search,
              status: ev.status === 'searching' ? 'running' : 'done',
              ok: true,
              detail: ev.query ?? '',
            });
            break;
          case 'completed':
            result = ev.result;
            break;
        }
      }
      if (!result) throw new AiProviderError('no_result');

      streamed.clear();
      resolvedModel = result.model || model;
      usage = addUsage(usage, result.usage);
      const c = estimateCostUsd(resolvedModel, result.usage, result.webSearchCalls, env);
      if (c === null) costKnown = false;
      else cost += c;
      webSearchCalls += result.webSearchCalls;
      for (const q of result.webSearchQueries) traces.push({ name: 'web_search', label: TOOL_LABELS.web_search, detail: q, ok: true });
      for (const m of result.messages) {
        if (m.phase === 'commentary') {
          if (m.text.trim()) commentary.push(m.text.trim());
        } else {
          if (m.text.trim()) finalParts.push(m.text.trim());
          sources.push(...m.sources);
        }
      }

      if (result.functionCalls.length === 0 || forceFinal) {
        if (result.status === 'incomplete' && finalParts.length === 0) {
          throw new AiProviderError(`incomplete: ${result.incompleteReason ?? 'unknown'}`, undefined, 'incomplete');
        }
        break;
      }

      turnInput = [...turnInput, result.replay];
      for (const fc of result.functionCalls) {
        toolCallCount += 1;
        const r = await runThinkTool(fc.name, fc.arguments, deps.store, 8000, toolCtx);
        const label = TOOL_LABELS[fc.name] ?? fc.name;
        traces.push({ name: fc.name, label, detail: r.summary, ok: r.ok });
        emit('tool', { call_id: fc.callId, name: fc.name, label, status: 'done', ok: r.ok, detail: r.summary });
        if (r.action) {
          actionIds.push(r.action.id);
          emit('action', { action: r.action });
        }
        turnInput.push({ kind: 'tool_result', callId: fc.callId, output: r.output });
      }
    }
  } catch (e) {
    if (input.signal.aborted) {
      const reason = abortReason(input.signal);
      status = reason === 'stopped' ? 'stopped' : 'error';
      errorCode = reason;
      errorMessage = reason === 'timeout' ? '응답 시간이 너무 길어 중단했습니다.' : null;
    } else {
      status = 'error';
      errorCode = e instanceof AiProviderError ? (e.code ?? 'provider_error') : 'internal_error';
      errorMessage = e instanceof Error ? e.message : String(e);
      console.error('[ai_think] chat failed:', errorMessage);
    }
    for (const s of streamed.values()) {
      if (s.phase !== 'commentary' && s.text.trim()) finalParts.push(s.text.trim());
    }
  }

  // 4) 저장·기록
  const content = finalParts.join('\n\n').trim();
  if (status === 'complete' && !content) {
    status = 'error';
    errorCode = 'empty_answer';
    errorMessage = '모델이 빈 답변을 돌려주었습니다.';
  }

  const runId = await deps.recordRun({
    feature: 'think_chat',
    provider: deps.provider.name,
    model: resolvedModel,
    promptVersion: THINK_PROMPT_VERSION,
    status: status === 'complete' ? 'ok' : status === 'stopped' ? 'stopped' : 'error',
    error: errorMessage,
    usage,
    webSearchCalls,
    toolCalls: toolCallCount,
    costUsd: costKnown ? cost : null,
    latencyMs: now() - input.startedAt,
    conversationId,
    createdBy: input.userId,
  });

  let assistantMessageId: string | null = null;
  if (content || status !== 'stopped') {
    try {
      assistantMessageId = await deps.store.insertMessage({
        conversation_id: conversationId,
        role: 'assistant',
        content: content || (errorMessage ? `⚠️ ${clip(errorMessage, 300)}` : ''),
        status,
        sources: dedupeSources(sources),
        tool_calls: traces,
        commentary: commentary.length > 0 ? commentary.join('\n\n') : null,
        model: resolvedModel,
        run_id: runId,
      });
    } catch (e) {
      console.error('[ai_think] assistant message insert failed:', e instanceof Error ? e.message : String(e));
    }
  }
  // 붙이지 못한 제안도 대화에는 남아 화면 끝에 카드로 보인다.
  if (assistantMessageId && actionIds.length > 0) {
    await deps.store.attachActions(actionIds, assistantMessageId).catch((e) => {
      console.error('[ai_think] attach actions failed:', e instanceof Error ? e.message : String(e));
    });
  }

  await titleTask.catch(() => {});

  if (status === 'complete' || status === 'stopped') {
    emit('done', {
      conversation_id: conversationId,
      assistant_message_id: assistantMessageId,
      run_id: runId,
      status,
      model: resolvedModel,
      usage: {
        input_tokens: usage.inputTokens,
        cached_input_tokens: usage.cachedInputTokens,
        output_tokens: usage.outputTokens,
        reasoning_tokens: usage.reasoningTokens,
      },
      web_search_calls: webSearchCalls,
      cost_usd: costKnown ? cost : null,
      sources: dedupeSources(sources),
      action_ids: actionIds,
    });
  } else {
    emit('error', {
      conversation_id: conversationId,
      assistant_message_id: assistantMessageId,
      code: errorCode ?? 'error',
      message: errorMessage ?? '답변을 만들지 못했습니다.',
      action_ids: actionIds,
    });
  }

  return { conversationId, userMessageId, assistantMessageId, runId, status, errorCode };
}
