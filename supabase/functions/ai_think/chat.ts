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
import { workStateNote, type ActionToolContext, type WorkState } from './actions.ts';
import { buildThinkContext, normalizeSplitSummary, type AttachmentRef, type ThinkContextStore } from './context.ts';
import type { DeliveredMaterial, DepartmentId } from './access_context.ts';
import { featureReady, isSplitRequest, type ThinkFeatures } from './features.ts';
import {
  ROLE_PROFILE_VERSION,
  THINK_PROMPT_VERSION,
  TITLE_PROMPT_VERSION,
  clip,
  featureStatusNote,
  relayInstructions,
  titleInstructions,
  type ThinkRoleId,
} from './prompts.ts';
import { resolveRelayVerdict, splitRelayBlock, type RelayAsker, type RelayVerdict } from './relay_verdict.ts';
import { ACTING_TOOL_NAMES, TOOL_LABELS, runThinkTool, thinkToolsFor, type ThinkToolSource } from './tools.ts';

export interface ConversationRow {
  id: string;
  title: string;
  status: string;
  scope_type: string;
  scope_id: string | null;
  /** 'cursor'면 커서가 시작한 대화. 마이그레이션 전 DB에는 열이 없어 비어 있다. */
  origin?: string;
  /** false면 사용자가 나누기 제안을 거절한 대화. 마이그레이션 전 DB에는 열이 없어 비어 있다. */
  auto_split_suggestions?: boolean;
  split_summary?: Record<string, unknown> | null;
  split_from_conversation_id?: string | null;
  think_role_id?: import('./prompts.ts').ThinkRoleId;
  role_profile_version?: string | null;
  extra_ref_departments?: import('./access_context.ts').DepartmentId[];
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
  /** 커서가 보낸 질문(user)일 때만 채운다. 비어 있으면 열을 보내지 않는다(마이그레이션 전 DB 호환). */
  asked_by?: RelayAsker | null;
  /** 커서 질문에 대한 답(assistant)의 판정. */
  relay?: RelayVerdict | null;
}

export interface ThinkPersistence {
  getConversation(id: string): Promise<ConversationRow | null>;
  createConversation(title: string, origin?: 'cursor'): Promise<ConversationRow>;
  updateConversationTitle(id: string, title: string): Promise<void>;
  insertMessage(msg: NewMessage): Promise<string>;
  getWorkState(conversationId: string): Promise<WorkState>;
  attachActions(ids: string[], messageId: string): Promise<void>;
  loadConversationAccess?(conversationId: string, rolesFeatureReady: boolean): Promise<import('./access_context.ts').ConversationAccessState>;
  setConversationRole?(conversationId: string, role: ThinkRoleId, extraRefs: DepartmentId[], profileVersion: string): Promise<void>;
  listLinkedDocumentBodies?(
    conversationId: string,
    allowedNodeIds: Set<string>,
  ): Promise<import('./context.ts').LinkedDocumentBody[]>;
  saveMessageContextSnapshot?(input: {
    messageId: string;
    runId: string | null;
    thinkRoleId: string;
    roleProfileVersion: string | null;
    access: import('./access_context.ts').ConversationAccessState;
    materials: import('./access_context.ts').DeliveredMaterial[];
  }): Promise<void>;
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
  /** 커서 질문(relay)은 사람이 아니라서 빈 문자열이다. 기록에는 null로 남긴다. */
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
  /** 서버가 이번 요청에서 계산한 기능 상태. 없으면 상태 메모를 넣지 않고 기능 도구도 노출하지 않는다. */
  features?: ThinkFeatures | null;
  /**
   * 커서가 보낸 질문(ai_think_relay, ai_code_bridge ask_think). 조회 도구만 주고, 커서가 시작한 대화에만 잇고,
   * 답 끝의 판정 블록을 떼어 서버가 다시 판정한다. title이 있으면 새 대화 제목으로 쓰고 제목을 만들지 않는다.
   */
  relay?: { asker: RelayAsker; title?: string | null } | null;
  /**
   * 새 대화를 만들 때 사용자가 고른 역할·참조 부서. 역할 기능이 준비됐을 때만 대화에 저장하고(ai_conversation_set_think_role),
   * 이어지는 대화에서는 무시한다(저장된 대화 값을 쓴다).
   */
  newConversationRole?: { thinkRoleId: ThinkRoleId; extraRefDepartments: DepartmentId[] } | null;
}

export interface ChatOutcome {
  conversationId: string | null;
  userMessageId: string | null;
  assistantMessageId: string | null;
  runId: string | null;
  status: 'complete' | 'error' | 'stopped';
  errorCode?: string;
  errorMessage?: string | null;
  /** 저장한 답 본문(판정 블록을 뗀 것). */
  content?: string;
  relay?: RelayVerdict | null;
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
    createdBy: input.userId || null,
  });
}

export async function runThinkChat(input: ChatInput, deps: ChatDeps): Promise<ChatOutcome> {
  const env = deps.env ?? denoEnv;
  const now = deps.now ?? Date.now;
  const tier = input.deep ? 'deep' : 'primary';
  const model = modelFor(tier, env);
  const emit = deps.emit;

  // 1) 대화 준비
  const relay = input.relay ?? null;
  const relayTitle = relay?.title ? clip(relay.title, 40) : null;
  let conversation: ConversationRow | null = null;
  let isNew = false;
  if (input.conversationId) {
    conversation = await deps.store.getConversation(input.conversationId);
    if (!conversation) {
      emit('error', { code: 'conversation_not_found', message: '대화를 찾을 수 없습니다.' });
      return { conversationId: null, userMessageId: null, assistantMessageId: null, runId: null, status: 'error', errorCode: 'conversation_not_found' };
    }
    if (relay && conversation.origin !== 'cursor') {
      emit('error', { code: 'relay_conversation_not_cursor', message: '커서는 커서가 시작한 대화에만 이어 물을 수 있습니다.' });
      return {
        conversationId: null,
        userMessageId: null,
        assistantMessageId: null,
        runId: null,
        status: 'error',
        errorCode: 'relay_conversation_not_cursor',
      };
    }
  } else {
    conversation = relay
      ? await deps.store.createConversation(relayTitle ?? fallbackTitle(input.message), 'cursor')
      : await deps.store.createConversation(fallbackTitle(input.message));
    isNew = true;
  }
  const conversationId = conversation.id;

  // 나누기 도구는 기능이 준비됐고, 앞 대화가 있고, 이 대화에서 거절되지 않았거나 사용자가 직접 요청했을 때만 노출한다.
  // 커서 질문에는 노출하지 않는다.
  const features = input.features ?? null;
  const splitSuppressed = conversation.auto_split_suggestions === false;
  const userAskedSplit = isSplitRequest(input.message);
  const splitAllowed = !relay && featureReady(features, 'conversation_split') && !isNew && (!splitSuppressed || userAskedSplit);
  const rolesReady = featureReady(features, 'think_roles');

  // 새 대화에 고른 역할은 첫 답변 전에 저장한다. 저장하지 못하면 총괄로 답하고 그렇게 알린다.
  const wanted = isNew && !relay && rolesReady ? input.newConversationRole ?? null : null;
  if (wanted && (wanted.thinkRoleId !== 'lead' || wanted.extraRefDepartments.length > 0) && deps.store.setConversationRole) {
    try {
      await deps.store.setConversationRole(conversationId, wanted.thinkRoleId, wanted.extraRefDepartments, ROLE_PROFILE_VERSION);
    } catch (e) {
      console.error('[ai_think] set role failed:', e instanceof Error ? e.message : String(e));
      emit('notice', { code: 'role_not_applied' });
    }
  }

  // 2) 컨텍스트는 이번 메시지를 저장하기 전에 만든다(지난 대화에 이번 질문이 중복되지 않도록).
  //    역할·참조 부서·자료 링크는 요청마다 DB에서 다시 읽는다(앱이 보낸 값이 아니라 저장된 값).
  const splitSummary = normalizeSplitSummary(conversation.split_summary);
  const access = deps.store.loadConversationAccess
    ? await deps.store.loadConversationAccess(conversationId, rolesReady)
    : null;
  const deliveredMap = new Map<string, DeliveredMaterial>();
  const recordDelivered = (ref: DeliveredMaterial) => {
    deliveredMap.set(`${ref.kind}:${ref.id}`, ref);
  };
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
    featureNote: features && !relay
      ? featureStatusNote({
        splitState: features.conversation_split.state,
        rolesState: features.think_roles?.state,
        isNew,
        suppressed: splitSuppressed,
        userAsked: userAskedSplit,
      })
      : null,
    splitSummary,
    access,
    thinkRole: access?.thinkRoleId ?? conversation.think_role_id ?? 'lead',
  });
  const instructions = relay ? `${ctx.instructions}\n\n${relayInstructions(relay.asker)}` : ctx.instructions;
  for (const m of ctx.deliveredMaterials) recordDelivered(m);
  const actionIds: string[] = [];

  const userMessageId = await deps.store.insertMessage({
    conversation_id: conversationId,
    role: 'user',
    content: input.message,
    status: 'complete',
    attachments: input.attachments,
    ...(relay ? { asked_by: relay.asker } : {}),
  });
  const toolCtx: ActionToolContext = {
    conversationId,
    memoryRefs: ctx.memoryRefs,
    split: splitAllowed ? { userMessageId, userRequested: userAskedSplit, proposed: false } : undefined,
    access: access ?? undefined,
    recordDelivered,
  };
  const cacheKey = ctx.cacheKeySuffix ? `think:${conversationId}:${ctx.cacheKeySuffix}` : `think:${conversationId}`;
  const tools = thinkToolsFor({ split: splitAllowed, readOnly: relay !== null });
  emit('conversation', {
    conversation_id: conversationId,
    user_message_id: userMessageId,
    title: conversation.title,
    created: isNew,
    model,
    features,
    relay: relay ? { asker: relay.asker } : null,
    think_role: access?.rolesFeatureReady
      ? {
        id: access.thinkRoleId,
        extra_ref_departments: access.extraRefDepartments,
        profile_version: ROLE_PROFILE_VERSION,
      }
      : null,
    split_suggestions: !splitSuppressed,
    context: {
      identity: ctx.identityIds.length,
      principles: ctx.principleIds.length,
      decisions: ctx.decisionIds.length,
      relevant: ctx.relevantIds,
      history_used: ctx.historyUsed,
      history_dropped: ctx.historyDropped,
      split_summary: splitSummary !== null,
    },
  });

  const titleTask = isNew && !relayTitle ? generateTitle(deps, input, conversationId) : Promise.resolve();

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
          instructions,
          input: turnInput,
          tools,
          webSearch: input.webSearch ? { contextSize: 'medium' } : undefined,
          toolChoice: forceFinal ? 'none' : 'auto',
          reasoningEffort: reasoningFor(tier, env),
          maxOutputTokens: maxOutputTokensFor(tier, env),
          cacheKey: rolesReady ? cacheKey : `think:${conversationId}`,
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
        const r = relay && ACTING_TOOL_NAMES.has(fc.name)
          ? { name: fc.name, ok: false, output: JSON.stringify({ error: 'not_available_for_cursor_questions' }), summary: '커서 질문에서는 쓸 수 없음' }
          : await runThinkTool(fc.name, fc.arguments, deps.store, 8000, toolCtx);
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
  let content = finalParts.join('\n\n').trim();
  let relayVerdict: RelayVerdict | null = null;
  if (relay) {
    const split = splitRelayBlock(content);
    content = split.text;
    if (status === 'complete') relayVerdict = await resolveRelayVerdict(split, relay.asker, (id) => deps.store.getMemory(id));
  }
  if (status === 'complete' && !content) {
    status = 'error';
    errorCode = 'empty_answer';
    errorMessage = '모델이 빈 답변을 돌려주었습니다.';
    relayVerdict = null;
  }

  const runId = await deps.recordRun({
    feature: relay ? 'think_relay' : 'think_chat',
    provider: deps.provider.name,
    model: resolvedModel,
    promptVersion: THINK_PROMPT_VERSION,
    roleProfileVersion: rolesReady ? ROLE_PROFILE_VERSION : null,
    status: status === 'complete' ? 'ok' : status === 'stopped' ? 'stopped' : 'error',
    error: errorMessage,
    usage,
    webSearchCalls,
    toolCalls: toolCallCount,
    costUsd: costKnown ? cost : null,
    latencyMs: now() - input.startedAt,
    conversationId,
    createdBy: input.userId || null,
    features: features ? { ...features, split_tool: splitAllowed } : null,
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
        ...(relayVerdict ? { relay: relayVerdict } : {}),
      });
    } catch (e) {
      console.error('[ai_think] assistant message insert failed:', e instanceof Error ? e.message : String(e));
    }
  }
  // 답변별 스냅샷은 역할 기능이 준비된 DB에만 남긴다. 없으면 앱은 '기록 없음'으로 표시한다.
  if (assistantMessageId && access?.rolesFeatureReady && deps.store.saveMessageContextSnapshot) {
    try {
      await deps.store.saveMessageContextSnapshot({
        messageId: assistantMessageId,
        runId,
        thinkRoleId: access.thinkRoleId,
        roleProfileVersion: ROLE_PROFILE_VERSION,
        access,
        materials: [...deliveredMap.values()].filter((m) => m.delivered),
      });
    } catch (e) {
      console.error('[ai_think] context snapshot failed:', e instanceof Error ? e.message : String(e));
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
      relay: relayVerdict,
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

  return { conversationId, userMessageId, assistantMessageId, runId, status, errorCode, errorMessage, content, relay: relayVerdict };
}
