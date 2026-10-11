// 결정 초안(대화 → 구조화된 결정)과 스펙 내보내기(결정 → 개발 스펙 마크다운).
// 둘 다 결과를 돌려주기만 한다. 저장은 사용자가 확인한 뒤 매니저앱이 한다.

import { denoEnv, estimateCostUsd, maxOutputTokensFor, modelFor, reasoningFor, type EnvReader } from '../_shared/ai/config.ts';
import { emptyUsage, finalText, type AiProvider, type AiResult } from '../_shared/ai/types.ts';
import type { AiRunRecord } from '../_shared/ai/usage.ts';
import { scopedMemoriesForConversation } from './access_context.ts';
import type { ConversationRow } from './chat.ts';
import type { MemoryDetail, MemoryRow, MessageRow } from './context.ts';
import {
  DECISION_DRAFT_SCHEMA,
  DECISION_PROMPT_VERSION,
  MEMORY_FEEDBACK_PROMPT_VERSION,
  MEMORY_FEEDBACK_SCHEMA,
  SPEC_PROMPT_VERSION,
  clip,
  decisionDraftInstructions,
  kstDate,
  memoryFeedbackInstructions,
  specExportInstructions,
} from './prompts.ts';

export type FeedbackMessageRow = MessageRow & { conversation_id: string; context_excluded: boolean };

export interface DraftStore {
  getConversation(id: string): Promise<ConversationRow | null>;
  listMessages(conversationId: string, limit: number): Promise<MessageRow[]>;
  getMessage(id: string): Promise<FeedbackMessageRow | null>;
  listActiveMemories(kinds: string[]): Promise<MemoryRow[]>;
  getMemory(id: string): Promise<MemoryDetail | null>;
  loadConversationAccess?(conversationId: string, rolesFeatureReady: boolean): Promise<import('./access_context.ts').ConversationAccessState>;
}

export interface DraftDeps {
  provider: AiProvider;
  store: DraftStore;
  recordRun: (rec: AiRunRecord) => Promise<string | null>;
  env?: EnvReader;
  now?: () => number;
}

export interface DecisionDraft {
  title: string;
  context: string;
  decision: string;
  reason: string;
  alternatives: string[];
  conflicts: string[];
  open_questions: string[];
  tags: string[];
}

export type DraftOutcome<T> = { ok: true; value: T; runId: string | null } | { ok: false; error: string; message: string };

const TRANSCRIPT_CHARS = 40000;

export function transcript(messages: MessageRow[], maxChars = TRANSCRIPT_CHARS): string {
  const lines: string[] = [];
  let used = 0;
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i];
    if (m.status === 'error' || !m.content.trim()) continue;
    const line = `${m.role === 'user' ? '사용자' : 'AI'}: ${clip(m.content, 6000)}`;
    if (used + line.length > maxChars && lines.length > 0) break;
    used += line.length;
    lines.unshift(line);
  }
  return lines.join('\n\n');
}

function strArr(v: unknown, maxItems = 12): string[] {
  return Array.isArray(v)
    ? v.map((x) => (typeof x === 'string' ? x.trim() : '')).filter(Boolean).slice(0, maxItems)
    : [];
}

export function parseDecisionDraft(text: string): DecisionDraft | null {
  let raw: unknown;
  try {
    raw = JSON.parse(text);
  } catch {
    return null;
  }
  if (!raw || typeof raw !== 'object') return null;
  const o = raw as Record<string, unknown>;
  const str = (v: unknown) => (typeof v === 'string' ? v.trim() : '');
  return {
    title: clip(str(o.title), 80),
    context: str(o.context),
    decision: str(o.decision),
    reason: str(o.reason),
    alternatives: strArr(o.alternatives),
    conflicts: strArr(o.conflicts),
    open_questions: strArr(o.open_questions),
    tags: strArr(o.tags, 6).map((t) => clip(t, 20)),
  };
}

function memoryDigest(memories: MemoryRow[]): string {
  const principles = memories.filter((m) => m.kind === 'principle' || m.kind === 'identity');
  const decisions = memories.filter((m) => m.kind === 'decision');
  const lines: string[] = ['[교육철학·원칙]'];
  lines.push(...(principles.length ? principles.map((m) => `- ${m.title}: ${clip(m.content, 300).replace(/\n+/g, ' ')}`) : ['(없음)']));
  lines.push('', '[기존 결정]');
  lines.push(...(decisions.length ? decisions.slice(0, 20).map((m) => `- ${m.title}: ${clip(m.content, 200).replace(/\n+/g, ' ')}`) : ['(없음)']));
  return lines.join('\n');
}

async function callAndRecord(
  deps: DraftDeps,
  feature: string,
  promptVersion: string,
  meta: { userId: string; safetyId: string; conversationId: string | null },
  request: Parameters<AiProvider['complete']>[0],
): Promise<{ result: AiResult | null; runId: string | null; error: string | null }> {
  const now = deps.now ?? Date.now;
  const env = deps.env ?? denoEnv;
  const started = now();
  let result: AiResult | null = null;
  let error: string | null = null;
  try {
    result = await deps.provider.complete(request);
  } catch (e) {
    error = e instanceof Error ? e.message : String(e);
  }
  const runId = await deps.recordRun({
    feature,
    provider: deps.provider.name,
    model: result?.model || request.model,
    promptVersion,
    status: error ? 'error' : 'ok',
    error,
    usage: result?.usage ?? emptyUsage(),
    costUsd: result ? estimateCostUsd(result.model || request.model, result.usage, 0, env) : null,
    latencyMs: now() - started,
    conversationId: meta.conversationId,
    createdBy: meta.userId,
  });
  return { result, runId, error };
}

export async function createDecisionDraft(
  deps: DraftDeps,
  input: { conversationId: string; userId: string; safetyId: string },
): Promise<DraftOutcome<DecisionDraft>> {
  const env = deps.env ?? denoEnv;
  const conversation = await deps.store.getConversation(input.conversationId);
  if (!conversation) return { ok: false, error: 'conversation_not_found', message: '대화를 찾을 수 없습니다.' };
  const [messages, rawMemories] = await Promise.all([
    deps.store.listMessages(input.conversationId, 80),
    deps.store.listActiveMemories(['identity', 'principle', 'decision']),
  ]);
  const memories = await scopedMemoriesForConversation(deps.store, input.conversationId, rawMemories);
  const text = transcript(messages);
  if (!text) return { ok: false, error: 'empty_conversation', message: '정리할 대화 내용이 없습니다.' };

  const model = modelFor('primary', env);
  const { result, runId, error } = await callAndRecord(deps, 'decision_draft', DECISION_PROMPT_VERSION, { ...input }, {
    model,
    instructions: decisionDraftInstructions(),
    input: [
      { kind: 'context', text: memoryDigest(memories) },
      { kind: 'message', role: 'user', parts: [{ type: 'text', text: `[대화 제목] ${conversation.title}\n\n[대화 기록]\n${text}` }] },
    ],
    jsonSchema: { name: 'decision_draft', schema: DECISION_DRAFT_SCHEMA },
    reasoningEffort: reasoningFor('primary', env),
    maxOutputTokens: maxOutputTokensFor('primary', env),
    safetyId: input.safetyId,
  });
  if (!result) return { ok: false, error: 'ai_failed', message: error ?? '초안을 만들지 못했습니다.' };
  const draft = parseDecisionDraft(finalText(result));
  if (!draft) return { ok: false, error: 'invalid_output', message: '초안 형식이 올바르지 않습니다.' };
  if (!draft.title) draft.title = clip(conversation.title, 80);
  return { ok: true, value: draft, runId };
}

export interface SpecExport {
  markdown: string;
  suggestedPath: string;
}

export function specFileName(title: string, date: string): string {
  const slug = title
    .normalize('NFC')
    .replace(/[^\p{L}\p{N}\s-]/gu, ' ')
    .trim()
    .replace(/\s+/g, '-')
    .slice(0, 40)
    .replace(/-+$/, '');
  return `docs/specs/${date.replaceAll('-', '')}-${slug || 'decision'}.md`;
}

export interface MemoryFeedbackCandidate {
  kind: 'note' | 'principle' | 'decision';
  title: string;
  content: string;
  decision_context: string;
  decision_reason: string;
  alternatives: string[];
  tags: string[];
  update_memory_id: string | null;
}

export interface MemoryFeedbackDuplicate {
  candidate_index: number;
  memory_id: string;
  memory_title: string;
  reason: string;
}

export interface MemoryFeedbackDraft {
  candidates: MemoryFeedbackCandidate[];
  duplicate_warnings: MemoryFeedbackDuplicate[];
  insufficient_evidence: boolean;
  notes: string;
}

export interface MemoryFeedbackUpdateBaseline {
  memory_id: string;
  version: number;
}

export type MemoryFeedbackDraftOutcome =
  | { ok: false; error: string; message: string }
  | {
    ok: true;
    value: MemoryFeedbackDraft;
    runId: string | null;
    update_baseline: MemoryFeedbackUpdateBaseline | null;
  };

function normKind(v: unknown): MemoryFeedbackCandidate['kind'] | null {
  const k = typeof v === 'string' ? v.trim() : '';
  return k === 'note' || k === 'principle' || k === 'decision' ? k : null;
}

export function parseMemoryFeedbackDraft(text: string): Omit<MemoryFeedbackDraft, 'duplicate_warnings'> | null {
  let raw: unknown;
  try {
    raw = JSON.parse(text);
  } catch {
    return null;
  }
  if (!raw || typeof raw !== 'object') return null;
  const o = raw as Record<string, unknown>;
  const str = (v: unknown) => (typeof v === 'string' ? v.trim() : '');
  const candidates: MemoryFeedbackCandidate[] = [];
  if (Array.isArray(o.candidates)) {
    for (const item of o.candidates) {
      if (!item || typeof item !== 'object') continue;
      const c = item as Record<string, unknown>;
      const kind = normKind(c.kind);
      if (!kind) continue;
      const updateId = c.update_memory_id == null || c.update_memory_id === '' ? null : str(c.update_memory_id);
      candidates.push({
        kind,
        title: clip(str(c.title), 120),
        content: str(c.content),
        decision_context: kind === 'decision' ? str(c.decision_context) : '',
        decision_reason: kind === 'decision' ? str(c.decision_reason) : '',
        alternatives: kind === 'decision' ? strArr(c.alternatives) : [],
        tags: strArr(c.tags, 6).map((t) => clip(t, 20)),
        update_memory_id: updateId || null,
      });
    }
  }
  return {
    candidates,
    insufficient_evidence: o.insufficient_evidence === true,
    notes: str(o.notes),
  };
}

function duplicateWarnings(
  candidates: MemoryFeedbackCandidate[],
  memories: MemoryRow[],
): MemoryFeedbackDuplicate[] {
  const active = memories.filter((m) => m.status === 'active');
  const out: MemoryFeedbackDuplicate[] = [];
  for (let i = 0; i < candidates.length; i++) {
    const c = candidates[i];
    if (c.update_memory_id) continue;
    const titleKey = c.title.toLowerCase();
    for (const m of active) {
      if (m.kind !== c.kind) continue;
      const sameTitle = m.title.trim().toLowerCase() === titleKey && titleKey.length > 0;
      const overlap = sameTitle || (c.content.length > 20 && m.content.includes(clip(c.content, 80)));
      if (overlap) {
        out.push({
          candidate_index: i,
          memory_id: m.id,
          memory_title: m.title,
          reason: sameTitle ? '제목이 같은 확정 기억이 있습니다' : '내용이 겹치는 확정 기억이 있습니다',
        });
        break;
      }
    }
  }
  return out;
}

export async function createMemoryFeedbackDraft(
  deps: DraftDeps,
  input: {
    conversationId: string;
    assistantMessageId: string;
    userMessageIds: string[];
    feedback: string;
    updateMemoryId?: string | null;
    userId: string;
    safetyId: string;
  },
): Promise<MemoryFeedbackDraftOutcome> {
  const env = deps.env ?? denoEnv;
  const feedback = input.feedback.trim();
  if (!feedback) return { ok: false, error: 'feedback_required', message: '피드백을 입력하세요.' };

  const conversation = await deps.store.getConversation(input.conversationId);
  if (!conversation) return { ok: false, error: 'conversation_not_found', message: '대화를 찾을 수 없습니다.' };

  const assistant = await deps.store.getMessage(input.assistantMessageId);
  if (!assistant || assistant.conversation_id !== input.conversationId) {
    return { ok: false, error: 'message_not_found', message: '답변 메시지를 찾을 수 없습니다.' };
  }
  if (assistant.role !== 'assistant') {
    return { ok: false, error: 'not_assistant_message', message: '선택한 메시지는 AI 답변이 아닙니다.' };
  }
  if (assistant.context_excluded) {
    return { ok: false, error: 'message_excluded', message: '답변에서 제외된 문답은 기억 초안 근거로 쓸 수 없습니다.' };
  }
  if (assistant.status === 'error' || !assistant.content.trim()) {
    return { ok: false, error: 'empty_answer', message: '내용이 없는 답변은 기억 초안을 만들 수 없습니다.' };
  }

  const userRows: FeedbackMessageRow[] = [];
  for (const id of input.userMessageIds) {
    const m = await deps.store.getMessage(id);
    if (!m || m.conversation_id !== input.conversationId) {
      return { ok: false, error: 'related_message_invalid', message: '관련 질문 메시지를 확인할 수 없습니다.' };
    }
    if (m.role !== 'user') {
      return { ok: false, error: 'related_message_invalid', message: '관련 질문만 근거로 쓸 수 있습니다.' };
    }
    if (m.context_excluded) {
      return { ok: false, error: 'message_excluded', message: '답변에서 제외된 문답은 기억 초안 근거로 쓸 수 없습니다.' };
    }
    userRows.push(m);
  }

  let updateMemory: MemoryDetail | null = null;
  if (input.updateMemoryId) {
    updateMemory = await deps.store.getMemory(input.updateMemoryId);
    if (!updateMemory) {
      return { ok: false, error: 'memory_not_found', message: '수정할 기억을 찾을 수 없습니다.' };
    }
    if (updateMemory.status !== 'active' && updateMemory.status !== 'draft') {
      return { ok: false, error: 'memory_not_editable', message: '확정·초안 상태의 기억만 수정 대상으로 고를 수 있습니다.' };
    }
  }

  const updateBaseline: MemoryFeedbackUpdateBaseline | null =
    updateMemory && typeof updateMemory.version === 'number'
      ? { memory_id: updateMemory.id, version: updateMemory.version }
      : null;

  // AI에는 이 대화 범위의 기억만 보인다. 중복 경고는 운영자 화면용이라 전체 active 기억과 비교한다.
  const memories = await deps.store.listActiveMemories(['identity', 'principle', 'decision', 'note']);
  const scoped = await scopedMemoriesForConversation(deps.store, input.conversationId, memories);
  const digest = memoryDigest(scoped.filter((m) => m.status === 'active'));

  const lines = [
    '[운영자 피드백]',
    feedback,
    '',
    '[관련 질문]',
    ...(userRows.length
      ? userRows.map((m) => `사용자: ${clip(m.content, 4000)}`)
      : ['(선택된 질문 없음 — 답변과 피드백만 참고)']),
    '',
    `[AI 답변 (id: ${assistant.id})]`,
    clip(assistant.content, 12000),
  ];
  if (updateMemory) {
    lines.push(
      '',
      `[수정 대상 기억 (id: ${updateMemory.id}, kind: ${updateMemory.kind}, status: ${updateMemory.status})]`,
      `제목: ${updateMemory.title}`,
      `내용: ${clip(updateMemory.content, 2000)}`,
    );
  }

  const model = modelFor('primary', env);
  const { result, runId, error } = await callAndRecord(
    deps,
    'memory_feedback_draft',
    MEMORY_FEEDBACK_PROMPT_VERSION,
    { userId: input.userId, safetyId: input.safetyId, conversationId: input.conversationId },
    {
      model,
      instructions: memoryFeedbackInstructions(),
      input: [
        { kind: 'context', text: digest },
        { kind: 'message', role: 'user', parts: [{ type: 'text', text: lines.join('\n') }] },
      ],
      jsonSchema: { name: 'memory_feedback_draft', schema: MEMORY_FEEDBACK_SCHEMA },
      reasoningEffort: reasoningFor('primary', env),
      maxOutputTokens: maxOutputTokensFor('primary', env),
      safetyId: input.safetyId,
    },
  );
  if (!result) return { ok: false, error: 'ai_failed', message: error ?? '초안을 만들지 못했습니다.' };
  const parsed = parseMemoryFeedbackDraft(finalText(result));
  if (!parsed) return { ok: false, error: 'invalid_output', message: '초안 형식이 올바르지 않습니다.' };

  let candidates = parsed.candidates.filter((c) => c.title.trim() || c.content.trim());
  if (parsed.insufficient_evidence) candidates = [];
  if (!parsed.insufficient_evidence && updateMemory && candidates.every((c) => !c.update_memory_id)) {
    candidates.unshift({
      kind: updateMemory.kind === 'decision' ? 'decision' : updateMemory.kind === 'principle' ? 'principle' : 'note',
      title: updateMemory.title,
      content: updateMemory.content,
      decision_context: updateMemory.decision_context ?? '',
      decision_reason: updateMemory.decision_reason ?? '',
      alternatives: updateMemory.alternatives ?? [],
      tags: updateMemory.tags ?? [],
      update_memory_id: updateMemory.id,
    });
  }
  for (const c of candidates) {
    if (c.update_memory_id && c.update_memory_id !== updateMemory?.id) {
      return { ok: false, error: 'invalid_output', message: '수정 대상 id가 요청과 맞지 않습니다.' };
    }
  }

  const duplicate_warnings = duplicateWarnings(candidates, memories);
  return {
    ok: true,
    value: { ...parsed, candidates, duplicate_warnings },
    runId,
    update_baseline: updateBaseline,
  };
}

export async function createSpecExport(
  deps: DraftDeps,
  input: { memoryId: string; userId: string; safetyId: string },
): Promise<DraftOutcome<SpecExport>> {
  const env = deps.env ?? denoEnv;
  const memory = await deps.store.getMemory(input.memoryId);
  if (!memory) return { ok: false, error: 'memory_not_found', message: '기억을 찾을 수 없습니다.' };
  if (memory.kind !== 'decision') return { ok: false, error: 'not_a_decision', message: '결정만 스펙으로 내보낼 수 있습니다.' };

  // 스펙 본문은 결정 자체에서 만들고, 함께 넣는 철학·원칙은 결정이 나온 대화의 범위로 거른다(대화가 없으면 공통만).
  const [rawMemories, messages] = await Promise.all([
    deps.store.listActiveMemories(['identity', 'principle']),
    memory.source_conversation_id ? deps.store.listMessages(memory.source_conversation_id, 40) : Promise.resolve([]),
  ]);
  const memories = await scopedMemoriesForConversation(deps.store, memory.source_conversation_id, rawMemories);

  const decisionDate = kstDate(new Date(memory.approved_at ?? memory.updated_at ?? memory.created_at ?? Date.now()));
  const body = [
    `[결정] ${memory.title}`,
    `- 상태: ${memory.status} / 결정일: ${decisionDate} / 기억 id: ${memory.id}`,
    '',
    `배경:\n${memory.decision_context ?? ''}`,
    '',
    `결정:\n${memory.content}`,
    '',
    `이유:\n${memory.decision_reason ?? ''}`,
    '',
    `검토한 대안:\n${(memory.alternatives ?? []).map((a) => `- ${a}`).join('\n') || '(없음)'}`,
  ].join('\n');

  const inputItems: Parameters<AiProvider['complete']>[0]['input'] = [{ kind: 'context', text: memoryDigest(memories) }];
  const convo = transcript(messages, 20000);
  if (convo) inputItems.push({ kind: 'context', text: `[결정이 나온 대화 (참고용)]\n${convo}` });
  inputItems.push({ kind: 'message', role: 'user', parts: [{ type: 'text', text: body }] });

  const model = modelFor('primary', env);
  const { result, runId, error } = await callAndRecord(
    deps,
    'spec_export',
    SPEC_PROMPT_VERSION,
    { userId: input.userId, safetyId: input.safetyId, conversationId: memory.source_conversation_id },
    {
      model,
      instructions: specExportInstructions(),
      input: inputItems,
      reasoningEffort: reasoningFor('primary', env),
      maxOutputTokens: maxOutputTokensFor('primary', env),
      safetyId: input.safetyId,
    },
  );
  if (!result) return { ok: false, error: 'ai_failed', message: error ?? '스펙을 만들지 못했습니다.' };
  const markdown = finalText(result).replace(/^```(?:markdown|md)?\s*\n/, '').replace(/\n```\s*$/, '').trim();
  if (!markdown) return { ok: false, error: 'empty_output', message: '빈 문서가 만들어졌습니다.' };
  return { ok: true, value: { markdown: `${markdown}\n`, suggestedPath: specFileName(memory.title, decisionDate) }, runId };
}
