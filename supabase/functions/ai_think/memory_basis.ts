// 기억 제안의 비교 근거. 서버가 이번 요청에서 실제로 넘긴 검색·원문만 인정한다.
// 모델이 적은 id·version이나 검색 발췌는 원문을 읽은 것으로 치지 않는다.
// SQL(ai_memory_read·ai_memory_collect_basis)과 같은 규칙이다. 구간 길이는 양쪽이 3500이다.

import type { ConversationAccessState } from './access_context.ts';
import { canProvideMemoryToAi, legacyVisible } from './access_context.ts';
import type { MemoryRow } from './context.ts';

/** 한 구간. 따옴표가 이스케이프돼도 도구 출력 한도 안에 id·version·complete가 남게 잡는다. */
export const MEMORY_READ_CHUNK = 3500;

export const MEMORY_RELATIONS = ['duplicate', 'supplement', 'conflict', 'distinct', 'hold', 'retire'] as const;
export type MemoryRelation = (typeof MEMORY_RELATIONS)[number];

export interface MemoryDelivery {
  kind: 'search' | 'read';
  status: string;
  memoryId?: string | null;
  version?: number | null;
  query?: string | null;
  hitCount?: number | null;
  scope?: string | null;
  offsetChars?: number | null;
  deliveredChars?: number | null;
  contentChars?: number | null;
  title?: string | null;
}

export interface MemoryReadBody {
  status: string;
  id: string;
  complete: boolean;
  version?: number;
  previous_version?: number;
  title?: string;
  kind?: string;
  offset?: number;
  next_offset?: number | null;
  content_chars?: number;
  document?: string;
  excerpt_only?: boolean;
}

export function memoryDocument(m: {
  content?: string | null;
  decision_context?: string | null;
  decision_reason?: string | null;
  alternatives?: string[] | null;
  tags?: string[] | null;
}): string {
  return JSON.stringify({
    content: m.content ?? '',
    decision_context: m.decision_context ?? null,
    decision_reason: m.decision_reason ?? null,
    alternatives: m.alternatives ?? [],
    tags: m.tags ?? [],
  });
}

export function isMemoryRelation(v: unknown): v is MemoryRelation {
  return typeof v === 'string' && (MEMORY_RELATIONS as readonly string[]).includes(v);
}

/** 마지막 검색의 상태. 성공 뒤의 실패가 있으면 그 성공은 제안 근거가 아니다. */
export function latestMemorySearch(rows: MemoryDelivery[]): MemoryDelivery | null {
  for (let i = rows.length - 1; i >= 0; i--) {
    if (rows[i].kind === 'search') return rows[i];
  }
  return null;
}

function covered(rows: MemoryDelivery[], memoryId: string, version: number, total: number): boolean {
  let end = 0;
  const parts = rows
    .filter((r) =>
      r.kind === 'read' && r.memoryId === memoryId && r.version === version &&
      (r.status === 'ok' || r.status === 'truncated') && r.offsetChars != null && r.deliveredChars != null
    )
    .sort((a, b) => (a.offsetChars ?? 0) - (b.offsetChars ?? 0));
  for (const r of parts) {
    const off = r.offsetChars ?? 0;
    if (off > end) return false;
    end = Math.max(end, off + (r.deliveredChars ?? 0));
  }
  return end >= total;
}

export interface MemoryReadTarget {
  id: string;
  version: number;
  title: string;
  kind: string;
  status: string;
  document: string;
  visible: boolean;
}

/** 원문 한 구간을 읽고 기록할 행을 만든다. version 인자는 받지 않는다. */
export function nextMemoryRead(
  rows: MemoryDelivery[],
  target: MemoryReadTarget | null,
  offset: number,
): { delivery: MemoryDelivery; body: MemoryReadBody } {
  const id = target?.id ?? '';
  if (!target || target.status !== 'active') {
    return {
      delivery: { kind: 'read', status: 'not_found', memoryId: id },
      body: { status: 'not_found', id, complete: false },
    };
  }
  if (!target.visible) {
    return {
      delivery: { kind: 'read', status: 'forbidden', memoryId: id, version: target.version },
      body: { status: 'forbidden', id, complete: false },
    };
  }
  let prev: number | null = null;
  for (let i = rows.length - 1; i >= 0; i--) {
    const r = rows[i];
    if (r.kind === 'read' && r.memoryId === id && (r.status === 'ok' || r.status === 'truncated') && r.version != null) {
      prev = r.version;
      break;
    }
  }
  if (offset > 0 && prev != null && prev !== target.version) {
    return {
      delivery: { kind: 'read', status: 'version_changed', memoryId: id, version: target.version, title: target.title },
      body: {
        status: 'version_changed',
        id,
        version: target.version,
        previous_version: prev,
        complete: false,
        offset: 0,
        next_offset: 0,
      },
    };
  }
  const total = target.document.length;
  const off = offset > total ? total : Math.max(0, offset);
  const slice = target.document.slice(off, off + MEMORY_READ_CHUNK);
  const delivery: MemoryDelivery = {
    kind: 'read',
    status: 'truncated',
    memoryId: id,
    version: target.version,
    title: target.title,
    offsetChars: off,
    deliveredChars: slice.length,
    contentChars: total,
  };
  const withThis = [...rows, delivery];
  const complete = covered(withThis, id, target.version, total);
  if (complete) delivery.status = 'ok';
  return {
    delivery,
    body: {
      status: complete ? 'ok' : 'truncated',
      id,
      version: target.version,
      title: target.title,
      kind: target.kind,
      offset: off,
      next_offset: off + slice.length < total ? off + slice.length : null,
      complete,
      content_chars: total,
      document: slice,
      excerpt_only: false,
    },
  };
}

export interface MemoryPlate {
  id: string;
  version: number;
  title: string;
  status: string;
  contentChars: number;
  visible: boolean;
}

/** 제안 카드를 만들기 전에 호출한다. 실패하면 예외 메시지가 오류 코드다. 카드를 만들지 않는다. */
export function assessMemoryProposal(input: {
  rows: MemoryDelivery[];
  relation: string;
  supersedesId: string | null;
  comparedIds: string[];
  plate: (id: string) => MemoryPlate | null;
}): Record<string, unknown> {
  if (!isMemoryRelation(input.relation)) throw new Error('memory_relation_required');
  const search = latestMemorySearch(input.rows);
  if (!search) throw new Error('memory_search_required');
  if (search.status !== 'ok' && search.status !== 'empty') throw new Error('memory_search_failed');

  const ids = [...new Set(input.comparedIds.filter((id) => id.length > 0))].slice(0, 8);
  if (input.supersedesId && !ids.includes(input.supersedesId)) ids.push(input.supersedesId);
  ids.sort();
  const reads: Record<string, unknown>[] = [];
  for (const id of ids) {
    const plate = input.plate(id);
    if (!plate || plate.status !== 'active') throw new Error(`memory_read_missing:${id}`);
    if (!plate.visible) throw new Error(`memory_basis_forbidden:${id}`);
    const mine = input.rows.filter((r) => r.kind === 'read' && r.memoryId === id);
    const full = mine.some((r) => r.status === 'ok' && r.version === plate.version && r.contentChars === plate.contentChars);
    if (!full) {
      if (mine.some((r) => r.status === 'truncated' && r.version === plate.version)) throw new Error(`memory_read_incomplete:${id}`);
      if (mine.some((r) => (r.status === 'ok' || r.status === 'truncated' || r.status === 'version_changed') && r.version != null && r.version !== plate.version)) {
        throw new Error(`memory_reread_required:${id}`);
      }
      if (mine.some((r) => r.status === 'forbidden')) throw new Error(`memory_basis_forbidden:${id}`);
      throw new Error(`memory_read_missing:${id}`);
    }
    reads.push({
      id,
      version: plate.version,
      title: plate.title,
      role: id === input.supersedesId ? 'supersede' : 'compared',
    });
  }
  if (input.relation === 'duplicate') {
    const target = input.supersedesId ?? ids[0];
    if (!target) throw new Error('memory_duplicate_target_required');
    throw new Error(`memory_duplicate_classified:${target}`);
  }
  if (input.relation === 'hold') throw new Error('memory_comparison_held');
  if (input.relation === 'retire' && ids.length === 0) throw new Error('memory_retire_target_required');
  if ((input.relation === 'supplement' || input.relation === 'conflict') && !input.supersedesId && ids.length === 0) {
    throw new Error('memory_compare_target_required');
  }
  const searches = input.rows
    .filter((r) => r.kind === 'search' && (r.status === 'ok' || r.status === 'empty'))
    .slice(-8)
    .map((r) => ({ query: r.query ?? null, status: r.status, hit_count: r.hitCount ?? 0, scope: r.scope ?? null }));
  return {
    relation: input.relation,
    searches,
    reads,
    limit: 'searched_only',
  };
}

export function memoryVisible(m: MemoryRow | null, access: ConversationAccessState | null | undefined): boolean {
  if (!m || m.status !== 'active') return false;
  return access ? canProvideMemoryToAi(m, access) : legacyVisible(m);
}
