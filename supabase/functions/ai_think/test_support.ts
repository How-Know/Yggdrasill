// 테스트 전용 메모리 저장소. 실제 DB 없이 Think 흐름을 검증한다.

import type { AiRunRecord } from '../_shared/ai/usage.ts';
import type { ConversationRow, NewMessage, ThinkStore } from './chat.ts';
import type { MemoryDetail, MemoryRow, MessageRow } from './context.ts';
import type {
  ActionKind,
  ActionRow,
  CodeRequestDetail,
  CodeRequestHit,
  ConversationHit,
  ConversationStats,
  TreeFolderRow,
  TreeItemRow,
  WorkState,
} from './actions.ts';
import type { BehaviorCard, ConceptCategory, ConceptHit, CurriculumNode, CurriculumOutlineQuery } from './tools.ts';

export function memory(partial: Partial<MemoryRow> & { id: string; kind: string; title: string }): MemoryRow {
  return {
    status: 'active',
    content: '',
    decision_context: null,
    decision_reason: null,
    alternatives: [],
    tags: [],
    sort_order: 0,
    updated_at: '2026-09-01T00:00:00Z',
    ...partial,
  };
}

export class MemoryThinkStore implements ThinkStore {
  memories: MemoryRow[] = [];
  conversations: ConversationRow[] = [];
  messages: (MessageRow & { conversation_id: string; excluded?: boolean; extra?: NewMessage })[] = [];
  signFails = new Set<string>();
  searchCalls: string[][] = [];
  folders: TreeFolderRow[] = [];
  treeItems: TreeItemRow[] = [];
  codeRequests: CodeRequestDetail[] = [];
  actions: ActionRow[] = [];
  attached: { ids: string[]; messageId: string }[] = [];
  private seq = 0;

  private id(prefix: string): string {
    this.seq += 1;
    return `${prefix}-${String(this.seq).padStart(4, '0')}`;
  }

  listActiveMemories(kinds: string[]): Promise<MemoryRow[]> {
    return Promise.resolve(this.memories.filter((m) => kinds.includes(m.kind) && m.status === 'active'));
  }

  searchMemories(terms: string[], limit: number): Promise<MemoryRow[]> {
    this.searchCalls.push(terms);
    const hits = this.memories
      .filter((m) => m.status === 'active' || m.status === 'draft')
      .map((m) => ({ m, score: terms.filter((t) => `${m.title} ${m.content}`.toLowerCase().includes(t)).length }))
      .filter((x) => x.score > 0)
      .sort((a, b) => b.score - a.score)
      .map((x) => x.m);
    return Promise.resolve(hits.slice(0, limit));
  }

  listMessages(conversationId: string, limit: number): Promise<MessageRow[]> {
    const rows = this.messages.filter((m) => m.conversation_id === conversationId && !m.excluded);
    return Promise.resolve(rows.slice(-limit));
  }

  signAttachment(path: string): Promise<string | null> {
    return Promise.resolve(this.signFails.has(path) ? null : `https://signed.example/${path}`);
  }

  getMemory(id: string): Promise<MemoryDetail | null> {
    const m = this.memories.find((x) => x.id === id);
    return Promise.resolve(
      m ? { ...m, supersedes_id: null, source_conversation_id: null, approved_at: null, created_at: null } : null,
    );
  }

  curriculumOutline(_q: CurriculumOutlineQuery): Promise<CurriculumNode[]> {
    return Promise.resolve([{ name: '2022 개정', children: [{ name: '중 1-1' }] }]);
  }

  searchConcepts(query: string, limit: number): Promise<ConceptHit[]> {
    return Promise.resolve(
      [{ id: 'c1', name: '소인수분해', kind: 'definition', level: 1, category_path: '수와 연산', content: '...' }]
        .filter((c) => c.name.includes(query))
        .slice(0, limit),
    );
  }

  listConceptCategories(_parentId: string | null): Promise<ConceptCategory[]> {
    return Promise.resolve([{ id: 'cat1', name: '수와 연산', depth: 0, description: null, child_count: 2 }]);
  }

  searchBehaviorCards(_query: string | null, _limit: number): Promise<BehaviorCard[]> {
    return Promise.resolve([]);
  }

  listTreeFolders(): Promise<{ folders: TreeFolderRow[]; items: TreeItemRow[] }> {
    return Promise.resolve({ folders: this.folders, items: this.treeItems });
  }

  listConversations(query: string | null, limit: number): Promise<ConversationHit[]> {
    return Promise.resolve(
      this.conversations
        .filter((c) => !query || c.title.includes(query))
        .slice(0, limit)
        .map((c) => ({ id: c.id, title: c.title, last_message_at: null })),
    );
  }

  conversationStats(id: string): Promise<ConversationStats | null> {
    const c = this.conversations.find((x) => x.id === id);
    if (!c) return Promise.resolve(null);
    return Promise.resolve({
      id,
      title: c.title,
      messages: this.messages.filter((m) => m.conversation_id === id).length,
      excerpts: this.treeItems.filter((i) => i.kind === 'excerpt' && i.conversation_id === id).length,
      code_requests: this.codeRequests.filter((r) => r.conversation_id === id).length,
    });
  }

  listCodeRequests(query: string | null, limit: number): Promise<CodeRequestHit[]> {
    return Promise.resolve(this.codeRequests.filter((r) => !query || r.title.includes(query)).slice(0, limit));
  }

  getCodeRequest(id: string): Promise<CodeRequestDetail | null> {
    return Promise.resolve(this.codeRequests.find((r) => r.id === id) ?? null);
  }

  proposeAction(conversationId: string, kind: ActionKind, payload: Record<string, unknown>, preview: Record<string, unknown>): Promise<ActionRow> {
    for (const a of this.actions) {
      if (a.conversation_id === conversationId && a.kind === kind && a.status === 'proposed') {
        a.status = 'rejected';
        a.superseded = true;
      }
    }
    const row: ActionRow = {
      id: this.id('act'),
      conversation_id: conversationId,
      message_id: null,
      kind,
      status: 'proposed',
      payload,
      preview,
      result: null,
      error: null,
      superseded: false,
      created_at: new Date().toISOString(),
    };
    this.actions.push(row);
    return Promise.resolve(row);
  }

  attachActions(ids: string[], messageId: string): Promise<void> {
    this.attached.push({ ids, messageId });
    for (const a of this.actions) if (ids.includes(a.id)) a.message_id = messageId;
    return Promise.resolve();
  }

  getWorkState(conversationId: string): Promise<WorkState> {
    return Promise.resolve({
      actions: this.actions.filter((a) => a.conversation_id === conversationId && !a.superseded).reverse(),
      codeRequests: this.codeRequests.filter((r) => r.conversation_id === conversationId),
    });
  }

  getConversation(id: string): Promise<ConversationRow | null> {
    return Promise.resolve(this.conversations.find((c) => c.id === id) ?? null);
  }

  createConversation(title: string): Promise<ConversationRow> {
    const row = { id: this.id('conv'), title, status: 'active', scope_type: 'general', scope_id: null };
    this.conversations.push(row);
    return Promise.resolve(row);
  }

  updateConversationTitle(id: string, title: string): Promise<void> {
    const c = this.conversations.find((x) => x.id === id);
    if (c) c.title = title;
    return Promise.resolve();
  }

  insertMessage(msg: NewMessage): Promise<string> {
    const id = this.id('msg');
    this.messages.push({
      id,
      conversation_id: msg.conversation_id,
      role: msg.role,
      content: msg.content,
      status: msg.status,
      attachments: msg.attachments ?? [],
      created_at: new Date(Date.UTC(2026, 8, 1, 0, 0, this.seq)).toISOString(),
      extra: msg,
    });
    return Promise.resolve(id);
  }
}

export class RunLog {
  runs: AiRunRecord[] = [];
  record = (rec: AiRunRecord): Promise<string | null> => {
    this.runs.push(rec);
    return Promise.resolve(`run-${this.runs.length}`);
  };
}

export class EventLog {
  events: { event: string; data: Record<string, unknown> }[] = [];
  emit = (event: string, data: Record<string, unknown>) => {
    this.events.push({ event, data });
  };
  names(): string[] {
    return this.events.map((e) => e.event);
  }
  of(event: string) {
    return this.events.filter((e) => e.event === event).map((e) => e.data);
  }
}

export const testEnv = {
  get: (name: string): string | undefined =>
    ({ AI_MODEL_PRIMARY: 'gpt-6-sol', AI_MODEL_DEEP: 'gpt-6-astra', AI_MODEL_FAST: 'gpt-6-luna' } as Record<string, string>)[name],
};
