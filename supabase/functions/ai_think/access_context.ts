// Think 역할·자료 범위 판정. AI에 넣을 active 기억·종합 문서·get_memory/search 경로가 모두 여기를 통과한다.
// draft 조회(피드백·편집)는 canReadMemoryForEdit / getMemoryForEdit 로 구분한다.

import { sha256Hex } from '../_shared/hash.ts';
import type { MemoryDetail, MemoryRow } from './context.ts';
import { ROLE_PROFILE_VERSION, type ThinkRoleId } from './prompts.ts';

export type DepartmentId = 'education' | 'product' | 'engineering';

export interface ConversationAccessState {
  conversationId: string;
  thinkRoleId: ThinkRoleId;
  extraRefDepartments: DepartmentId[];
  linkedMemoryIds: Set<string>;
  linkedDocumentNodeIds: Set<string>;
  /** think_roles 기능이 준비됐을 때만 역할별 필터를 적용한다. */
  rolesFeatureReady: boolean;
}

export interface MaterialRef {
  kind: 'memory' | 'document';
  id: string;
  title?: string;
}

export interface DeliveredMaterial extends MaterialRef {
  delivered: boolean;
  excerpt_chars?: number;
  truncated?: boolean;
}

const DEPARTMENTS = new Set<DepartmentId>(['education', 'product', 'engineering']);

export function parseDepartmentList(raw: unknown): DepartmentId[] {
  if (!Array.isArray(raw)) return [];
  return raw.filter((x): x is DepartmentId => typeof x === 'string' && DEPARTMENTS.has(x as DepartmentId));
}

export function normalizeThinkRole(raw: unknown): ThinkRoleId {
  if (raw === 'education' || raw === 'product' || raw === 'engineering' || raw === 'lead') return raw;
  return 'lead';
}

/** 레거시·공통·자기 부서·명시 참조 부서·대화 연결 승인 기억 */
export function memoryVisibleToRole(
  m: Pick<MemoryRow, 'id' | 'kind' | 'status' | 'memory_scope' | 'scope_department'>,
  ctx: ConversationAccessState,
): boolean {
  if (m.status !== 'active') return false;
  // 구버전 앱·DB 미반영: 부서 범위 기억은 AI에 노출하지 않는다(철학·공통·레거시만).
  if (!ctx.rolesFeatureReady || legacyVisible(m)) return legacyVisible(m);
  if (ctx.linkedMemoryIds.has(m.id)) return true;
  if (m.memory_scope === 'department') {
    const dept = m.scope_department;
    if (!dept || !DEPARTMENTS.has(dept as DepartmentId)) return false;
    if (ctx.thinkRoleId === 'lead') return true;
    if (ctx.thinkRoleId === dept) return true;
    if (ctx.extraRefDepartments.includes(dept as DepartmentId)) return true;
    return false;
  }
  return false;
}

export function filterMemoriesForAi(memories: MemoryRow[], ctx: ConversationAccessState): MemoryRow[] {
  return memories.filter((m) => memoryVisibleToRole(m, ctx));
}

/** 대화 범위를 모를 때(새 대화, 역할 기능 미준비, 대화와 무관한 AI 경로): 승인된 철학·공통·레거시 기억만. */
export function legacyVisible(m: Pick<MemoryRow, 'kind' | 'status' | 'memory_scope'>): boolean {
  if (m.status !== 'active') return false;
  const scope = m.memory_scope ?? 'legacy_unscoped';
  return m.kind === 'identity' || scope === 'legacy_unscoped' || scope === 'common';
}

export function scopeMemories(memories: MemoryRow[], ctx: ConversationAccessState | null | undefined): MemoryRow[] {
  return ctx ? filterMemoriesForAi(memories, ctx) : memories.filter(legacyVisible);
}

/**
 * DB 검색(ai_search_memories_scoped)에 넘기는 범위. all은 대화와 무관한 운영자 조회(커서 연결 읽기 도구)에만 쓴다.
 * AI에 넣는 경로는 결과를 scopeMemories로 한 번 더 거른다.
 */
export interface MemorySearchScope {
  mode: 'all' | 'legacy' | ThinkRoleId;
  extraRefs: DepartmentId[];
  linkedIds: string[];
}

export const LEGACY_SEARCH: MemorySearchScope = { mode: 'legacy', extraRefs: [], linkedIds: [] };
export const ALL_SEARCH: MemorySearchScope = { mode: 'all', extraRefs: [], linkedIds: [] };

export function searchScopeFor(ctx: ConversationAccessState | null | undefined): MemorySearchScope {
  if (!ctx?.rolesFeatureReady) return LEGACY_SEARCH;
  return { mode: ctx.thinkRoleId, extraRefs: [...ctx.extraRefDepartments], linkedIds: [...ctx.linkedMemoryIds] };
}

/**
 * 대화에 묶인 AI 초안·검토 경로(결정 초안, 기억 피드백, 스펙 내보내기, 코드 결과 검토)의 기억 범위.
 * 앱 기능 신고와 무관하게 DB에 저장된 대화 역할로 판정한다. 대화가 없거나 범위를 읽지 못하면 legacy.
 */
export async function scopedMemoriesForConversation(
  store: { loadConversationAccess?(conversationId: string, rolesFeatureReady: boolean): Promise<ConversationAccessState> },
  conversationId: string | null | undefined,
  memories: MemoryRow[],
): Promise<MemoryRow[]> {
  let ctx: ConversationAccessState | null = null;
  if (conversationId && store.loadConversationAccess) {
    ctx = await store.loadConversationAccess(conversationId, true).catch(() => null);
  }
  return scopeMemories(memories, ctx);
}

/** lead: 관련도·건수 예산으로 principles·decisions 등을 자른다. */
export function selectLeadMemories(
  candidates: MemoryRow[],
  opts: { maxDecisions: number; maxPrinciples: number },
): MemoryRow[] {
  const identity = candidates.filter((m) => m.kind === 'identity');
  const principles = candidates.filter((m) => m.kind === 'principle').slice(0, opts.maxPrinciples);
  const decisions = candidates
    .filter((m) => m.kind === 'decision')
    .sort((a, b) => String(b.updated_at ?? '').localeCompare(String(a.updated_at ?? '')))
    .slice(0, opts.maxDecisions);
  const notes = candidates.filter((m) => m.kind === 'note');
  return [...identity, ...principles, ...decisions, ...notes];
}

export function canProvideMemoryToAi(m: MemoryDetail | MemoryRow | null, ctx: ConversationAccessState): boolean {
  if (!m) return false;
  return memoryVisibleToRole(m, ctx);
}

/** 편집·피드백용 draft 포함 조회. AI 맥락에는 쓰지 않는다. */
export function canReadMemoryForEdit(_m: MemoryDetail | null): boolean {
  return _m != null;
}

export function appliedScopeSnapshot(ctx: ConversationAccessState): Record<string, unknown> {
  return {
    think_role_id: ctx.thinkRoleId,
    extra_ref_departments: ctx.extraRefDepartments,
    linked_memory_ids: [...ctx.linkedMemoryIds],
    linked_document_node_ids: [...ctx.linkedDocumentNodeIds],
    roles_feature_ready: ctx.rolesFeatureReady,
  };
}

/**
 * 프롬프트 캐시 키 꼬리. 역할·프로필 버전·참조 부서·연결 기억·연결 문서 중 하나라도 바뀌면 달라진다.
 * 캐시 키 길이 제한(64자) 때문에 짧은 해시로 줄인다: `think:<대화 id>:<8자>`.
 */
export async function promptCacheKeyParts(ctx: ConversationAccessState | null, linkedDocIds: string[]): Promise<string | null> {
  if (!ctx?.rolesFeatureReady) return null;
  const mem = [...ctx.linkedMemoryIds].sort().join(',');
  const docs = [...linkedDocIds].sort().join(',');
  const refs = [...ctx.extraRefDepartments].sort().join(',');
  return (await sha256Hex(`${ctx.thinkRoleId}|${ROLE_PROFILE_VERSION}|${refs}|${mem}|${docs}`)).slice(0, 8);
}
