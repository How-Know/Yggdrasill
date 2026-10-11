// Think 대화의 컨텍스트 조립. AI에 들어가는 내용은 여기서만 정한다.
//   지시문: 역할 + 교육철학(identity) + 원칙(principle) + 최근 결정 요약
//   입력:   (나눠 온 대화면 요약) → 지난 대화(글자 수 예산 안에서 최신순) → 이 대화의 작업 상태 → 실행 환경 기능 상태
//           → 관련 기억 메모 → 이번 질문(+첨부)

import { extractSearchTerms } from '../_shared/ai/search_terms.ts';
import type { AiContentPart, AiInputItem } from '../_shared/ai/types.ts';
import type { MemoryRef } from './actions.ts';
import {
  type ConversationAccessState,
  type DeliveredMaterial,
  type MemorySearchScope,
  promptCacheKeyParts,
  scopeMemories,
  searchScopeFor,
  selectLeadMemories,
} from './access_context.ts';
import {
  clip,
  kstDate,
  linkedDocumentsNote,
  relayQuestionLabel,
  relevantMemoriesNote,
  splitSummaryNote,
  thinkInstructions,
  type MemoryBlock,
  type SplitSummary,
  type ThinkRoleId,
} from './prompts.ts';

export interface MemoryRow extends MemoryBlock {
  status: string;
  tags?: string[] | null;
  sort_order?: number | null;
  version?: number | null;
  memory_scope?: string;
  scope_department?: string | null;
}

export interface MemoryDetail extends MemoryRow {
  supersedes_id: string | null;
  source_conversation_id: string | null;
  approved_at: string | null;
  created_at: string | null;
}

export interface AttachmentRef {
  path: string;
  name: string;
  mime: string;
  size?: number | null;
}

export interface MessageRow {
  id: string;
  role: 'user' | 'assistant';
  content: string;
  status: string;
  attachments: AttachmentRef[];
  created_at: string;
  /** 커서가 보낸 질문이면 cursor_ide / cursor_worker. 운영자 메시지는 비어 있다. */
  asked_by?: string | null;
}

export interface LinkedDocumentBody {
  id: string;
  title: string;
  body: string;
  /** 글자 예산 때문에 앞부분만 넣었을 때. */
  truncated?: boolean;
}

export interface ThinkContextStore {
  listActiveMemories(kinds: string[]): Promise<MemoryRow[]>;
  /** scope는 DB 검색 단계의 범위. 생략하면 legacy(철학·공통·레거시만). */
  searchMemories(terms: string[], limit: number, scope?: MemorySearchScope): Promise<MemoryRow[]>;
  listMessages(conversationId: string, limit: number): Promise<MessageRow[]>;
  signAttachment(path: string, expiresInSec: number): Promise<string | null>;
  listLinkedDocumentBodies?(conversationId: string, allowedNodeIds: Set<string>): Promise<LinkedDocumentBody[]>;
}

export const CONTEXT_LIMITS = {
  identityChars: 12000,
  principleChars: 1500,
  decisionCount: 12,
  decisionChars: 400,
  relevantCount: 6,
  relevantChars: 1200,
  documentBodyChars: 12000,
  documentBodyTotalChars: 24000,
  leadDecisionCount: 12,
  leadPrincipleCount: 30,
  historyMessages: 40,
  historyChars: 60000,
  messageChars: 8000,
  attachmentReplayUserTurns: 2,
  signedUrlSeconds: 900,
};

export interface BuildContextInput {
  conversationId: string | null;
  userMessage: string;
  attachments: AttachmentRef[];
  scope?: { type: string; id?: string | null } | null;
  /** 이 대화의 제안·코드 요청 상태 요약. 앞쪽이 그대로라 프롬프트 캐시가 유지된다. */
  workNote?: string | null;
  /** 서버가 이번 요청에서 계산한 기능 상태(featureStatusNote). */
  featureNote?: string | null;
  /** 나눠 온 대화의 요약. 사용자 메시지 자리에 참고 자료로 넣는다. */
  splitSummary?: SplitSummary | null;
  access?: ConversationAccessState | null;
  thinkRole?: ThinkRoleId;
  now?: Date;
}

function textList(v: unknown): string[] {
  return Array.isArray(v) ? v.map((x) => (typeof x === 'string' ? x.trim() : '')).filter(Boolean) : [];
}

/** ai_conversations.split_summary(jsonb). 목적이 비었으면 요약이 없는 것으로 본다. */
export function normalizeSplitSummary(raw: unknown): SplitSummary | null {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const r = raw as Record<string, unknown>;
  const text = (v: unknown) => (typeof v === 'string' ? v.trim() : '');
  const summary = {
    purpose: text(r.purpose),
    background: text(r.background),
    decided: textList(r.decided),
    open: textList(r.open),
    next: textList(r.next),
  };
  return summary.purpose ? summary : null;
}

export interface BuiltContext {
  instructions: string;
  input: AiInputItem[];
  identityIds: string[];
  principleIds: string[];
  decisionIds: string[];
  relevantIds: string[];
  historyUsed: number;
  historyDropped: number;
  /** 코드 요청에 함께 보낼 원칙·결정(최대 8개). */
  memoryRefs: MemoryRef[];
  /** 모델 입력·도구 응답으로 실제 전달된 자료(스냅샷용). */
  deliveredMaterials: DeliveredMaterial[];
  linkedDocumentIds: string[];
  cacheKeySuffix: string | null;
}

export function isImageMime(mime: string): boolean {
  return mime.startsWith('image/');
}

async function attachmentParts(
  store: ThinkContextStore,
  attachments: AttachmentRef[],
): Promise<{ parts: AiContentPart[]; failed: string[] }> {
  const parts: AiContentPart[] = [];
  const failed: string[] = [];
  for (const a of attachments) {
    const url = await store.signAttachment(a.path, CONTEXT_LIMITS.signedUrlSeconds).catch(() => null);
    if (!url) {
      failed.push(a.name);
      continue;
    }
    parts.push(isImageMime(a.mime) ? { type: 'image', url, detail: 'auto' } : { type: 'file', url, filename: a.name });
  }
  return { parts, failed };
}

function attachmentNote(names: string[]): string {
  return `[첨부: ${names.join(', ')}]`;
}

function byUpdatedDesc(a: MemoryRow, b: MemoryRow): number {
  return String(b.updated_at ?? '').localeCompare(String(a.updated_at ?? ''));
}

export async function buildThinkContext(store: ThinkContextStore, input: BuildContextInput): Promise<BuiltContext> {
  const L = CONTEXT_LIMITS;
  const access = input.access ?? null;
  const rolesReady = access?.rolesFeatureReady === true;
  const thinkRole = input.thinkRole ?? access?.thinkRoleId ?? 'lead';

  const [rawMemories, history] = await Promise.all([
    store.listActiveMemories(['identity', 'principle', 'decision', 'note']),
    input.conversationId ? store.listMessages(input.conversationId, L.historyMessages) : Promise.resolve([]),
  ]);
  const memories = scopeMemories(rawMemories, access);

  let identity = memories.filter((m) => m.kind === 'identity');
  let principles = memories.filter((m) => m.kind === 'principle');
  let decisions = memories.filter((m) => m.kind === 'decision').sort(byUpdatedDesc);
  if (thinkRole === 'lead' && rolesReady) {
    const picked = selectLeadMemories(memories, { maxDecisions: L.leadDecisionCount, maxPrinciples: L.leadPrincipleCount });
    identity = picked.filter((m) => m.kind === 'identity');
    principles = picked.filter((m) => m.kind === 'principle');
    decisions = picked.filter((m) => m.kind === 'decision');
  }
  decisions = decisions.slice(0, L.decisionCount);

  const fullyIncluded = new Set([...identity, ...principles, ...decisions].map((m) => m.id));
  const terms = extractSearchTerms(input.userMessage);
  let relevant: MemoryRow[] = [];
  if (terms.length > 0) {
    try {
      const hits = await store.searchMemories(terms, L.relevantCount + fullyIncluded.size, searchScopeFor(access));
      relevant = scopeMemories(hits, access).filter((m) => !fullyIncluded.has(m.id)).slice(0, L.relevantCount);
    } catch {
      relevant = [];
    }
  }

  const deliveredMaterials: DeliveredMaterial[] = [];
  for (const m of [...identity, ...principles, ...decisions, ...relevant]) {
    deliveredMaterials.push({ kind: 'memory', id: m.id, title: m.title, delivered: true });
  }

  let linkedDocs: LinkedDocumentBody[] = [];
  if (input.conversationId && access && store.listLinkedDocumentBodies && access.linkedDocumentNodeIds.size > 0) {
    const fetched = await store.listLinkedDocumentBodies(input.conversationId, access.linkedDocumentNodeIds);
    let remaining = L.documentBodyTotalChars;
    for (const d of fetched) {
      if (!access.linkedDocumentNodeIds.has(d.id)) continue;
      const take = Math.min(d.body.length, L.documentBodyChars, remaining);
      if (take <= 0) break;
      remaining -= take;
      linkedDocs.push({ ...d, body: d.body.slice(0, take), truncated: take < d.body.length });
      deliveredMaterials.push({
        kind: 'document',
        id: d.id,
        title: d.title,
        delivered: true,
        excerpt_chars: take,
        ...(take < d.body.length ? { truncated: true } : {}),
      });
    }
  }

  const instructions = thinkInstructions({
    identity,
    principles,
    decisions,
    scope: input.scope,
    today: kstDate(input.now),
    limits: L,
    thinkRole,
    rolesFeatureReady: rolesReady,
  });

  // 지난 대화: 최신부터 글자 수 예산이 찰 때까지
  const usable = history.filter((m) => m.status !== 'error' && (m.content.trim() || m.attachments.length > 0));
  let budget = L.historyChars;
  const picked: MessageRow[] = [];
  for (let i = usable.length - 1; i >= 0; i--) {
    const len = Math.min(usable[i].content.length, L.messageChars);
    if (budget - len < 0 && picked.length > 0) break;
    budget -= len;
    picked.unshift(usable[i]);
  }

  // 첨부는 최근 사용자 턴에만 다시 보낸다(이번 질문 포함 attachmentReplayUserTurns개).
  const replayIds = new Set<string>();
  let userTurns = 1;
  for (let i = picked.length - 1; i >= 0 && userTurns < L.attachmentReplayUserTurns; i--) {
    if (picked[i].role !== 'user') continue;
    userTurns += 1;
    if (picked[i].attachments.length > 0) replayIds.add(picked[i].id);
  }

  const items: AiInputItem[] = [];
  if (input.splitSummary) {
    items.push({ kind: 'message', role: 'user', parts: [{ type: 'text', text: splitSummaryNote(input.splitSummary) }] });
  }
  for (const m of picked) {
    const text = clip(m.content, L.messageChars);
    if (m.role === 'assistant') {
      if (text) items.push({ kind: 'message', role: 'assistant', parts: [{ type: 'text', text }] });
      continue;
    }
    const parts: AiContentPart[] = [];
    if (text) parts.push({ type: 'text', text: m.asked_by ? `${relayQuestionLabel(m.asked_by)}\n${text}` : text });
    if (m.attachments.length > 0) {
      if (replayIds.has(m.id)) {
        const { parts: files, failed } = await attachmentParts(store, m.attachments);
        parts.push(...files);
        if (failed.length > 0) parts.push({ type: 'text', text: attachmentNote(failed) });
      } else {
        parts.push({ type: 'text', text: attachmentNote(m.attachments.map((a) => a.name)) });
      }
    }
    if (parts.length > 0) items.push({ kind: 'message', role: 'user', parts });
  }

  if (input.workNote) items.push({ kind: 'context', text: input.workNote });
  if (input.featureNote) items.push({ kind: 'context', text: input.featureNote });
  if (linkedDocs.length > 0) {
    items.push({
      kind: 'context',
      text: linkedDocumentsNote(linkedDocs),
    });
  }
  if (relevant.length > 0) items.push({ kind: 'context', text: relevantMemoriesNote(relevant, L.relevantChars) });

  const current: AiContentPart[] = [];
  const question = input.userMessage.trim();
  current.push({ type: 'text', text: question || '첨부한 자료를 살펴보고 핵심을 정리해 줘.' });
  if (input.attachments.length > 0) {
    const { parts: files, failed } = await attachmentParts(store, input.attachments);
    current.push(...files);
    if (failed.length > 0) current.push({ type: 'text', text: `${attachmentNote(failed)} (파일을 열 수 없었음)` });
  }
  items.push({ kind: 'message', role: 'user', parts: current });

  return {
    instructions,
    input: items,
    identityIds: identity.map((m) => m.id),
    principleIds: principles.map((m) => m.id),
    decisionIds: decisions.map((m) => m.id),
    relevantIds: relevant.map((m) => m.id),
    historyUsed: picked.length,
    historyDropped: usable.length - picked.length,
    memoryRefs: [...principles, ...decisions].slice(0, 8).map((m) => ({
      id: m.id,
      kind: m.kind,
      title: m.title,
      version: m.version ?? null,
      content: clip(m.content, 300),
    })),
    deliveredMaterials,
    linkedDocumentIds: linkedDocs.map((d) => d.id),
    cacheKeySuffix: await promptCacheKeyParts(access, linkedDocs.map((d) => d.id)),
  };
}
