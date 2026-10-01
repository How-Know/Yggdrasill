// 결정 초안(대화 → 구조화된 결정)과 스펙 내보내기(결정 → 개발 스펙 마크다운).
// 둘 다 결과를 돌려주기만 한다. 저장은 사용자가 확인한 뒤 매니저앱이 한다.

import { denoEnv, estimateCostUsd, maxOutputTokensFor, modelFor, reasoningFor, type EnvReader } from '../_shared/ai/config.ts';
import { emptyUsage, finalText, type AiProvider, type AiResult } from '../_shared/ai/types.ts';
import type { AiRunRecord } from '../_shared/ai/usage.ts';
import type { ConversationRow } from './chat.ts';
import type { MemoryDetail, MemoryRow, MessageRow } from './context.ts';
import {
  DECISION_DRAFT_SCHEMA,
  DECISION_PROMPT_VERSION,
  SPEC_PROMPT_VERSION,
  clip,
  decisionDraftInstructions,
  kstDate,
  specExportInstructions,
} from './prompts.ts';

export interface DraftStore {
  getConversation(id: string): Promise<ConversationRow | null>;
  listMessages(conversationId: string, limit: number): Promise<MessageRow[]>;
  listActiveMemories(kinds: string[]): Promise<MemoryRow[]>;
  getMemory(id: string): Promise<MemoryDetail | null>;
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
  const [messages, memories] = await Promise.all([
    deps.store.listMessages(input.conversationId, 80),
    deps.store.listActiveMemories(['identity', 'principle', 'decision']),
  ]);
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

export async function createSpecExport(
  deps: DraftDeps,
  input: { memoryId: string; userId: string; safetyId: string },
): Promise<DraftOutcome<SpecExport>> {
  const env = deps.env ?? denoEnv;
  const memory = await deps.store.getMemory(input.memoryId);
  if (!memory) return { ok: false, error: 'memory_not_found', message: '기억을 찾을 수 없습니다.' };
  if (memory.kind !== 'decision') return { ok: false, error: 'not_a_decision', message: '결정만 스펙으로 내보낼 수 있습니다.' };

  const [memories, messages] = await Promise.all([
    deps.store.listActiveMemories(['identity', 'principle']),
    memory.source_conversation_id ? deps.store.listMessages(memory.source_conversation_id, 40) : Promise.resolve([]),
  ]);

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
