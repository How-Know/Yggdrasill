// 테스트 전용 메모리 저장소. 실제 DB 없이 Think 흐름을 검증한다.

import type { AiRunRecord } from '../_shared/ai/usage.ts';
import type { ConversationRow, NewMessage, ThinkStore } from './chat.ts';
import type { ConversationAccessState, DeliveredMaterial, DepartmentId } from './access_context.ts';
import type { ThinkRoleId } from './prompts.ts';
import type { AttachmentRef, LinkedDocumentBody, MemoryDetail, MemoryRow, MessageRow } from './context.ts';
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
import type {
  ConceptAppearanceRecord,
  ConceptLinkedCriterion,
  ConceptRecord,
  ConceptReferenceRead,
  ConceptSourceRecord,
  ConceptStatementRecord,
} from './concept_reference.ts';
import type { CriterionLinkedConcept, CriterionRecord, CriterionReferenceRead } from './criterion_reference.ts';
import type { ConceptDraftReferenceRead } from './concept_draft_reference.ts';
import type { RelayConversationHit, RelayReservation, RelayReserveInput } from './store.ts';
import type { CriteriaInput, DepartmentCriteria, OrganizeMessageRow, ProgressSummaryInput } from './organize.ts';

export function memory(partial: Partial<MemoryRow> & { id: string; kind: string; title: string }): MemoryRow {
  return {
    status: 'active',
    content: '',
    decision_context: null,
    decision_reason: null,
    alternatives: [],
    tags: [],
    sort_order: 0,
    version: 1,
    updated_at: '2026-09-01T00:00:00Z',
    ...partial,
  };
}

/** getMemory가 MemoryDetail로 확장할 때 쓰는 테스트 전용 필드 */
export type TestMemoryRow = MemoryRow & {
  source_conversation_id?: string | null;
  approved_at?: string | null;
  created_at?: string | null;
};

export class MemoryThinkStore implements ThinkStore {
  memories: TestMemoryRow[] = [];
  conversations: ConversationRow[] = [];
  messages: (MessageRow & { conversation_id: string; excluded?: boolean; important?: boolean; extra?: NewMessage })[] = [];
  signFails = new Set<string>();
  searchCalls: string[][] = [];
  folders: TreeFolderRow[] = [];
  treeItems: TreeItemRow[] = [];
  codeRequests: CodeRequestDetail[] = [];
  codeDiffs: Record<string, string> = {};
  actions: ActionRow[] = [];
  attached: { ids: string[]; messageId: string }[] = [];
  linkedDocumentBodies: LinkedDocumentBody[] = [];
  accessByConversation = new Map<string, ConversationAccessState>();
  snapshots: { messageId: string; thinkRoleId?: string; roleProfileVersion: string | null; materials: DeliveredMaterial[] }[] = [];
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
    const fetchLimit = Math.min(30, Math.max(1, limit) + 30);
    const hits = this.memories
      .filter((m) => m.status === 'active' || m.status === 'draft')
      .map((m) => ({ m, score: terms.filter((t) => `${m.title} ${m.content}`.toLowerCase().includes(t)).length }))
      .filter((x) => x.score > 0)
      .sort((a, b) => b.score - a.score)
      .map((x) => x.m);
    return Promise.resolve(
      hits.slice(0, fetchLimit).filter((m) => m.status === 'active').slice(0, Math.max(1, limit)),
    );
  }

  listMessages(conversationId: string, limit: number): Promise<MessageRow[]> {
    const rows = this.messages.filter((m) => m.conversation_id === conversationId && !m.excluded);
    return Promise.resolve(rows.slice(-limit));
  }

  signAttachment(path: string): Promise<string | null> {
    return Promise.resolve(this.signFails.has(path) ? null : `https://signed.example/${path}`);
  }

  readCalls: string[] = [];
  answerFiles: { path: string; name: string; mime: string; bytes: Uint8Array }[] = [];

  readAttachment(path: string): Promise<Uint8Array> {
    this.readCalls.push(path);
    if (this.signFails.has(path)) return Promise.reject(new Error('not found'));
    return Promise.resolve(new TextEncoder().encode(`bytes:${path}`));
  }

  saveAnswerFile(userId: string, name: string, mime: string, bytes: Uint8Array): Promise<AttachmentRef> {
    const path = `${userId}/out/${this.answerFiles.length + 1}-${name}`;
    this.answerFiles.push({ path, name, mime, bytes });
    return Promise.resolve({ path, name, mime, size: bytes.byteLength });
  }

  getMemory(id: string): Promise<MemoryDetail | null> {
    const m = this.memories.find((x) => x.id === id);
    if (!m) return Promise.resolve(null);
    return Promise.resolve({
      ...m,
      supersedes_id: null,
      source_conversation_id: m.source_conversation_id ?? null,
      approved_at: m.approved_at ?? null,
      created_at: m.created_at ?? null,
    });
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

  concepts = new Map<string, ConceptRecord>();
  conceptPaths = new Map<string, { categoryPath: string[]; pathComplete: boolean }>();
  conceptReadFails = new Set<string>();
  conceptReads: string[] = [];

  /** 개념별 이은 기준·출처. 값이 null이면 그 목록을 읽지 못한 것으로 돌려준다. */
  conceptLinkedCriteria = new Map<string, ConceptLinkedCriterion[] | null>();
  conceptSources = new Map<string, ConceptSourceRecord[] | null>();
  /** 개념별 공통 내용·서술, 등장 위치. 값이 null이면 읽지 못한 것으로 돌려준다. */
  conceptStatements = new Map<string, ConceptStatementRecord[] | null>();
  conceptAppearances = new Map<string, ConceptAppearanceRecord[] | null>();

  getConceptReference(conceptId: string): Promise<ConceptReferenceRead> {
    this.conceptReads.push(conceptId);
    if (this.conceptReadFails.has(conceptId)) return Promise.reject(new Error('concepts: connection reset'));
    const concept = this.concepts.get(conceptId) ?? null;
    if (!concept) return Promise.resolve({ concept: null, categoryPath: [], pathComplete: false });
    const path = this.conceptPaths.get(conceptId) ?? { categoryPath: ['수와 연산', '소인수분해'], pathComplete: true };
    const linked = this.conceptLinkedCriteria.has(conceptId) ? this.conceptLinkedCriteria.get(conceptId)! : [];
    const sources = this.conceptSources.has(conceptId) ? this.conceptSources.get(conceptId)! : [];
    const statements = this.conceptStatements.has(conceptId) ? this.conceptStatements.get(conceptId)! : [];
    const appearances = this.conceptAppearances.has(conceptId) ? this.conceptAppearances.get(conceptId)! : [];
    return Promise.resolve({
      concept: { ...concept },
      ...path,
      linkedCriteria: linked ? linked.map((c) => ({ ...c })) : null,
      sources: sources ? sources.map((x) => ({ ...x, unit_path: [...x.unit_path] })) : null,
      statements: statements ? statements.map((x) => structuredClone(x)) : null,
      appearances: appearances ? appearances.map((x) => ({ ...x, unit_path: [...x.unit_path] })) : null,
    });
  }

  /** 개념 탭 정리 기준(concept_criteria). 부서 기준(criteria)과 다르다. */
  conceptCriteria = new Map<string, CriterionRecord>();
  criterionLinkedConcepts = new Map<string, CriterionLinkedConcept[] | null>();
  criterionReadFails = new Set<string>();
  criterionReads: string[] = [];

  getCriterionReference(criterionId: string): Promise<CriterionReferenceRead> {
    this.criterionReads.push(criterionId);
    if (this.criterionReadFails.has(criterionId)) return Promise.reject(new Error('concept_criteria: connection reset'));
    const criterion = this.conceptCriteria.get(criterionId) ?? null;
    if (!criterion) return Promise.resolve({ criterion: null });
    const linked = this.criterionLinkedConcepts.has(criterionId) ? this.criterionLinkedConcepts.get(criterionId)! : [];
    return Promise.resolve({ criterion: { ...criterion }, linkedConcepts: linked ? linked.map((c) => ({ ...c })) : null });
  }

  /** 개념 초안 검토 창의 초안. 값을 바꾸면 다음 질문이 바뀐 저장본을 읽는다. */
  conceptDrafts = new Map<string, ConceptDraftReferenceRead>();
  conceptDraftReads: string[] = [];
  conceptDraftReadFails = new Set<string>();
  /** 제안 RPC가 낼 오류(예: 'concept_draft_change_unknown_item'). */
  conceptDraftProposeError: string | null = null;
  conceptDraftProposals: { conversationId: string; kind: ActionKind; payload: Record<string, unknown> }[] = [];

  getConceptDraftReference(draftId: string): Promise<ConceptDraftReferenceRead> {
    this.conceptDraftReads.push(draftId);
    if (this.conceptDraftReadFails.has(draftId)) return Promise.reject(new Error('concept_drafts: connection reset'));
    const got = this.conceptDrafts.get(draftId);
    return Promise.resolve(got ? structuredClone(got) : { draft: null });
  }

  proposeConceptDraftAction(conversationId: string, kind: ActionKind, payload: Record<string, unknown>): Promise<ActionRow> {
    if (this.conceptDraftProposeError) return Promise.reject(new Error(`concept_draft_action_propose: ${this.conceptDraftProposeError}`));
    this.conceptDraftProposals.push({ conversationId, kind, payload: structuredClone(payload) });
    const row: ActionRow = {
      id: this.id('act'),
      conversation_id: conversationId,
      message_id: null,
      kind,
      status: 'proposed',
      payload,
      preview: { title: kind, reason: payload.reason },
      result: null,
      error: null,
      superseded: false,
      created_at: new Date().toISOString(),
    };
    this.actions.push(row);
    return Promise.resolve(row);
  }

  searchBehaviorCards(_query: string | null, _limit: number): Promise<BehaviorCard[]> {
    return Promise.resolve([]);
  }

  listTreeFolders(opts?: { department?: boolean }): Promise<{ folders: TreeFolderRow[]; items: TreeItemRow[] }> {
    this.folderListCalls.push(opts ?? {});
    const folders = opts?.department ? this.folders : this.folders.map(({ department: _d, ...f }) => f);
    return Promise.resolve({ folders, items: this.treeItems });
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
      documents: this.treeItems.filter((i) => i.kind === 'document' && i.conversation_id === id).length,
      code_requests: this.codeRequests.filter((r) => r.conversation_id === id).length,
    });
  }

  listCodeRequests(query: string | null, limit: number): Promise<CodeRequestHit[]> {
    return Promise.resolve(this.codeRequests.filter((r) => !query || r.title.includes(query)).slice(0, limit));
  }

  getCodeRequestDiff(id: string): Promise<string | null> {
    return Promise.resolve(this.codeDiffs[id] ?? null);
  }

  getCodeRequest(id: string): Promise<CodeRequestDetail | null> {
    return Promise.resolve(this.codeRequests.find((r) => r.id === id) ?? null);
  }

  /** 다음 proposeAction이 이 메시지로 실패한다(DB 오류 흉내). 한 번 쓰면 지운다. */
  proposeFailure: string | null = null;

  proposeAction(conversationId: string, kind: ActionKind, payload: Record<string, unknown>, preview: Record<string, unknown>): Promise<ActionRow> {
    if (this.proposeFailure) {
      const message = this.proposeFailure;
      this.proposeFailure = null;
      return Promise.reject(new Error(`ai_action_propose: ${message}`));
    }
    const memoryCard = kind === 'save_memory' || kind === 'memory_card_change';
    for (const a of this.actions) {
      if (!memoryCard && a.conversation_id === conversationId && a.kind === kind && a.status === 'proposed') {
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

  /** 'limit'이면 하루 한도 초과 오류를 낸다. */
  planStartFailure: 'limit' | null = null;
  plansStarted: { conversationId: string; title: string; spec: Record<string, unknown> }[] = [];

  startCodePlan(conversationId: string, title: string, spec: Record<string, unknown>): Promise<ActionRow> {
    if (this.planStartFailure === 'limit') return Promise.reject(new Error('ai_code_plan_start: code_request_daily_limit'));
    this.plansStarted.push({ conversationId, title, spec });
    const row: ActionRow = {
      id: this.id('act'),
      conversation_id: conversationId,
      message_id: null,
      kind: 'code_plan',
      status: 'applied',
      payload: { title, spec },
      preview: { title, mode: 'plan' },
      result: { code_request_id: this.id('req') },
      error: null,
      superseded: false,
      created_at: new Date().toISOString(),
    };
    this.actions.push(row);
    return Promise.resolve(row);
  }

  /** 설정하면 다음 나누기 제안이 이 코드로 실패한다(예: 'split_expired'). */
  splitFailure: string | null = null;
  splitCalls: {
    conversationId: string;
    startMessageId: string;
    payload: Record<string, unknown>;
    preview: Record<string, unknown>;
    userRequested: boolean;
  }[] = [];

  proposeSplit(
    conversationId: string,
    startMessageId: string,
    payload: Record<string, unknown>,
    preview: Record<string, unknown>,
    userRequested: boolean,
  ): Promise<ActionRow> {
    this.splitCalls.push({ conversationId, startMessageId, payload, preview, userRequested });
    if (this.splitFailure) return Promise.reject(new Error(`ai_conversation_split_propose: ${this.splitFailure}`));
    const conv = this.conversations.find((c) => c.id === conversationId);
    if (conv?.auto_split_suggestions === false && !userRequested) {
      return Promise.reject(new Error('ai_conversation_split_propose: split_suppressed'));
    }
    for (const a of this.actions) {
      if (a.conversation_id === conversationId && a.kind === 'split_conversation' && a.status === 'proposed') {
        a.status = 'rejected';
        a.superseded = true;
      }
    }
    const row: ActionRow = {
      id: this.id('act'),
      conversation_id: conversationId,
      message_id: null,
      kind: 'split_conversation',
      status: 'proposed',
      payload: { ...payload, start_message_id: startMessageId, user_requested: userRequested },
      preview,
      result: null,
      error: null,
      superseded: false,
      created_at: new Date().toISOString(),
    };
    this.actions.push(row);
    return Promise.resolve(row);
  }

  /** 설정하면 다음 넘기기 제안이 이 코드로 실패한다(예: 'handover_same_department'). */
  handoverFailure: string | null = null;
  folderListCalls: { department?: boolean }[] = [];

  proposeHandover(conversationId: string, toDepartment: string, reason: string): Promise<ActionRow> {
    if (this.handoverFailure) return Promise.reject(new Error(`ai_department_handover_propose: ${this.handoverFailure}`));
    const from = this.accessByConversation.get(conversationId)?.thinkRoleId ?? 'lead';
    for (const a of this.actions) {
      if (a.conversation_id === conversationId && a.kind === 'handover_department' && a.status === 'proposed') {
        a.status = 'rejected';
        a.superseded = true;
      }
    }
    const row: ActionRow = {
      id: this.id('act'),
      conversation_id: conversationId,
      message_id: null,
      kind: 'handover_department',
      status: 'proposed',
      payload: { to_department: toDepartment, reason },
      preview: { title: this.conversations.find((c) => c.id === conversationId)?.title ?? '', from_department: from, to_department: toDepartment, reason },
      result: null,
      error: null,
      superseded: false,
      created_at: new Date().toISOString(),
    };
    this.actions.push(row);
    return Promise.resolve(row);
  }

  // --- 자동 정리 제안 ---
  /** null이면 설정 읽기가 실패한다. */
  autoOrganize: boolean | null = true;
  criteria = new Map<string, DepartmentCriteria>();
  /** 설정하면 다음 정리 제안이 이 코드로 실패한다(예: 'organize_rejected_before'). */
  organizeFailure: string | null = null;
  organizeCalls: { kind: ActionKind; conversationId: string; args: Record<string, unknown> }[] = [];

  listOrganizeMessages(conversationId: string, limit: number): Promise<OrganizeMessageRow[]> {
    const rows = this.messages.filter((m) => m.conversation_id === conversationId && !m.excluded).slice(-limit);
    return Promise.resolve(
      rows.map((m) => ({ id: m.id, role: m.role, content: m.content, created_at: m.created_at, marked_important: m.important === true })),
    );
  }

  private organizeAction(
    kind: ActionKind,
    conversationId: string,
    args: Record<string, unknown>,
    preview: Record<string, unknown>,
    supersedeWhen: (a: ActionRow) => boolean,
  ): Promise<ActionRow> {
    this.organizeCalls.push({ kind, conversationId, args });
    if (this.organizeFailure) {
      const code = this.organizeFailure;
      this.organizeFailure = null;
      return Promise.reject(new Error(`organize: ${code}`));
    }
    for (const a of this.actions) {
      if (a.conversation_id === conversationId && a.kind === kind && a.status === 'proposed' && supersedeWhen(a)) {
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
      payload: args,
      preview,
      result: null,
      error: null,
      superseded: false,
      created_at: new Date().toISOString(),
    };
    this.actions.push(row);
    return Promise.resolve(row);
  }

  proposeExclusion(conversationId: string, messageIds: string[], reason: string, impact: string, userRequested: boolean): Promise<ActionRow> {
    return this.organizeAction(
      'exclude_context',
      conversationId,
      { message_ids: messageIds, reason, impact, user_requested: userRequested },
      { title: `메시지 ${messageIds.length}개`, count: messageIds.length, reason, impact },
      () => true,
    );
  }

  proposeImportance(conversationId: string, messageIds: string[], reason: string, userRequested: boolean): Promise<ActionRow> {
    return this.organizeAction(
      'mark_important',
      conversationId,
      { message_ids: messageIds, reason, user_requested: userRequested },
      { title: `메시지 ${messageIds.length}개`, count: messageIds.length, reason },
      () => true,
    );
  }

  proposeProgressSummary(conversationId: string, summary: ProgressSummaryInput, reason: string, throughMessageId: string): Promise<ActionRow> {
    return this.organizeAction(
      'progress_summary',
      conversationId,
      { summary, reason, through_message_id: throughMessageId },
      { title: summary.purpose.slice(0, 80), summary, reason },
      () => true,
    );
  }

  proposeCriteriaChange(conversationId: string, department: string, criteria: CriteriaInput, reason: string): Promise<ActionRow> {
    return this.organizeAction(
      'department_criteria_change',
      conversationId,
      { department, criteria, reason },
      { title: `${department} 부서 기준`, department, reason },
      (a) => a.payload.department === department,
    );
  }

  getAutoOrganizeEnabled(): Promise<boolean> {
    return this.autoOrganize === null ? Promise.reject(new Error('settings unavailable')) : Promise.resolve(this.autoOrganize);
  }

  getDepartmentCriteria(department: string): Promise<DepartmentCriteria | null> {
    return Promise.resolve(
      this.criteria.get(department) ?? { department, questions: [], risks: [], priority_memory_ids: [], version: 0 },
    );
  }

  countPendingOrganize(conversationId: string): Promise<number> {
    const kinds = new Set([
      'place_conversation', 'split_conversation', 'save_memory', 'memory_card_change', 'handover_department',
      'exclude_context', 'mark_important', 'progress_summary', 'department_criteria_change',
    ]);
    return Promise.resolve(
      this.actions.filter((a) => a.conversation_id === conversationId && a.status === 'proposed' && !a.superseded && kinds.has(a.kind)).length,
    );
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

  createConversation(title: string, origin?: 'cursor'): Promise<ConversationRow> {
    const row = { id: this.id('conv'), title, status: 'active', scope_type: 'general', scope_id: null, origin: origin ?? 'owner' };
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
      asked_by: msg.asked_by ?? null,
      extra: msg,
    });
    return Promise.resolve(id);
  }

  listLinkedDocumentBodies(_conversationId: string, allowedNodeIds: Set<string>): Promise<LinkedDocumentBody[]> {
    return Promise.resolve(this.linkedDocumentBodies.filter((d) => allowedNodeIds.has(d.id)));
  }

  loadConversationAccess(conversationId: string, rolesFeatureReady: boolean): Promise<ConversationAccessState> {
    const existing = this.accessByConversation.get(conversationId);
    if (existing) return Promise.resolve({ ...existing, rolesFeatureReady });
    return Promise.resolve({
      conversationId,
      thinkRoleId: 'lead',
      extraRefDepartments: [],
      linkedMemoryIds: new Set(),
      linkedDocumentNodeIds: new Set(),
      rolesFeatureReady,
    });
  }

  /** 설정하면 역할 저장 RPC가 이 메시지로 실패한다. */
  setRoleFailure: string | null = null;
  roleCalls: { conversationId: string; role: ThinkRoleId; extraRefs: DepartmentId[] }[] = [];

  setConversationRole(conversationId: string, role: ThinkRoleId, extraRefs: DepartmentId[], _profileVersion: string): Promise<void> {
    this.roleCalls.push({ conversationId, role, extraRefs });
    if (this.setRoleFailure) return Promise.reject(new Error(this.setRoleFailure));
    const prev = this.accessByConversation.get(conversationId);
    this.accessByConversation.set(conversationId, {
      conversationId,
      thinkRoleId: role,
      extraRefDepartments: extraRefs,
      linkedMemoryIds: prev?.linkedMemoryIds ?? new Set(),
      linkedDocumentNodeIds: prev?.linkedDocumentNodeIds ?? new Set(),
      rolesFeatureReady: true,
    });
    return Promise.resolve();
  }

  saveMessageContextSnapshot(input: {
    messageId: string;
    thinkRoleId?: string;
    roleProfileVersion?: string | null;
    materials: DeliveredMaterial[];
  }): Promise<void> {
    this.snapshots.push({
      messageId: input.messageId,
      thinkRoleId: input.thinkRoleId,
      roleProfileVersion: input.roleProfileVersion ?? null,
      materials: input.materials,
    });
    return Promise.resolve();
  }

  getMessage(id: string): Promise<(MessageRow & { conversation_id: string; context_excluded: boolean }) | null> {
    const m = this.messages.find((x) => x.id === id);
    if (!m) return Promise.resolve(null);
    return Promise.resolve({
      id: m.id,
      conversation_id: m.conversation_id,
      role: m.role,
      content: m.content,
      status: m.status,
      attachments: m.attachments ?? [],
      created_at: m.created_at ?? '',
      context_excluded: m.excluded === true,
    });
  }
}

/** 커서 연결(relay) RPC의 메모리 구현. reserveError를 넣으면 다음 접수가 그 메시지로 실패한다. */
export class MemoryRelayStore extends MemoryThinkStore {
  reserveError: string | null = null;
  reservations: (RelayReserveInput & { id: string })[] = [];
  finished: { id: string; status: string; conversationId: string | null; runId: string | null; error: string | null }[] = [];
  /** 작업자 질문이 이어 물을 대화(요청 id → 대화 id). */
  workerConversations = new Map<string, string>();

  listConversationsForRelay(query: string | null, limit: number, includeArchived: boolean): Promise<RelayConversationHit[]> {
    return Promise.resolve(
      this.conversations
        .filter((c) => (includeArchived || c.status === 'active') && (!query || c.title.includes(query)))
        .slice(0, limit)
        .map((c) => ({
          id: c.id,
          title: c.title,
          status: c.status,
          origin: c.origin ?? 'owner',
          message_count: this.messages.filter((m) => m.conversation_id === c.id).length,
          last_message_at: null,
        })),
    );
  }

  reserveRelay(input: RelayReserveInput): Promise<RelayReservation> {
    if (this.reserveError) return Promise.reject(new Error(`ai_relay_reserve: ${this.reserveError}`));
    const id = `ask-${this.reservations.length + 1}`;
    this.reservations.push({ ...input, id });
    let conversationId = input.conversationId;
    if (input.asker === 'cursor_ide' && conversationId) {
      const c = this.conversations.find((x) => x.id === conversationId);
      if (!c) return Promise.reject(new Error('ai_relay_reserve: relay_conversation_not_found'));
      if (c.origin !== 'cursor') return Promise.reject(new Error('ai_relay_reserve: relay_conversation_not_cursor'));
    }
    if (input.asker === 'cursor_worker') conversationId = (input.requestId && this.workerConversations.get(input.requestId)) || null;
    return Promise.resolve({
      id,
      conversation_id: conversationId,
      request_title: input.asker === 'cursor_worker' ? '조율 요청' : null,
      request_mode: input.asker === 'cursor_worker' ? 'plan' : null,
      request_round: input.asker === 'cursor_worker' ? 1 : null,
    });
  }

  finishRelay(id: string, status: 'answered' | 'needs_owner' | 'error', conversationId: string | null, runId: string | null, error: string | null): Promise<void> {
    this.finished.push({ id, status, conversationId, runId, error });
    const r = this.reservations.find((x) => x.id === id);
    if (r?.asker === 'cursor_worker' && r.requestId && conversationId) this.workerConversations.set(r.requestId, conversationId);
    return Promise.resolve();
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
