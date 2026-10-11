// 커서 질문에 대한 Think 답의 판정. 답 끝의 ```relay 블록을 떼어 내고, 서버가 다시 확인한다.
//   answered    : 승인된(active) 기억이 근거로 확인되고, 운영자가 정할 것이 남지 않았다.
//   needs_owner : 그 밖의 모든 경우. 블록이 없거나 깨졌거나, 근거 기억이 확인되지 않아도 여기로 간다(fail-closed).
// 설계: docs/architecture/ai-think.md §12

import type { MemoryDetail } from './context.ts';

export type RelayAsker = 'cursor_ide' | 'cursor_worker';
export const RELAY_ASKERS: readonly RelayAsker[] = ['cursor_ide', 'cursor_worker'];

export interface RelayBasis {
  id: string;
  kind: string;
  title: string;
}

export interface RelayVerdict {
  verdict: 'answered' | 'needs_owner';
  basis: RelayBasis[];
  owner_questions: string[];
  asker: RelayAsker;
  /** needs_owner로 바꾼 이유. 모델이 needs_owner를 고른 경우는 비어 있다. */
  downgraded?: 'no_block' | 'invalid_block' | 'no_basis' | 'open_questions';
}

export const MAX_BASIS = 8;
export const MAX_OWNER_QUESTIONS = 10;

const BLOCK_RE = /```relay[ \t]*\r?\n([\s\S]*?)```/gi;

/** 답에서 마지막 relay 블록을 떼어 낸다. 블록이 여러 개면 모두 지우고 마지막 것만 읽는다. */
export function splitRelayBlock(text: string): { text: string; raw: Record<string, unknown> | null; found: boolean } {
  const blocks = [...text.matchAll(BLOCK_RE)];
  if (blocks.length === 0) return { text: text.trim(), raw: null, found: false };
  const stripped = text.replace(BLOCK_RE, '').replace(/\n{3,}/g, '\n\n').trim();
  try {
    const parsed = JSON.parse(blocks[blocks.length - 1][1]);
    const raw = parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? (parsed as Record<string, unknown>) : null;
    return { text: stripped, raw, found: true };
  } catch {
    return { text: stripped, raw: null, found: true };
  }
}

function stringList(v: unknown, max: number, maxChars: number): string[] {
  if (!Array.isArray(v)) return [];
  const out: string[] = [];
  for (const item of v) {
    const s = typeof item === 'string' ? item.trim() : '';
    if (s && !out.includes(s)) out.push(s.slice(0, maxChars));
    if (out.length >= max) break;
  }
  return out;
}

/** 블록 내용을 서버 기준으로 다시 판정한다. 근거 기억은 active인 것만 남긴다. */
export async function resolveRelayVerdict(
  split: { raw: Record<string, unknown> | null; found: boolean },
  asker: RelayAsker,
  getMemory: (id: string) => Promise<MemoryDetail | null>,
): Promise<RelayVerdict> {
  if (!split.found || !split.raw) {
    return { verdict: 'needs_owner', basis: [], owner_questions: [], asker, downgraded: split.found ? 'invalid_block' : 'no_block' };
  }
  const raw = split.raw;
  const basis: RelayBasis[] = [];
  for (const id of stringList(raw.basis, MAX_BASIS, 64)) {
    const m = await getMemory(id).catch(() => null);
    if (m && m.status === 'active') basis.push({ id: m.id, kind: m.kind, title: m.title });
  }
  const ownerQuestions = stringList(raw.owner_questions, MAX_OWNER_QUESTIONS, 300);
  if (raw.verdict !== 'answered') return { verdict: 'needs_owner', basis, owner_questions: ownerQuestions, asker };
  if (basis.length === 0) return { verdict: 'needs_owner', basis, owner_questions: ownerQuestions, asker, downgraded: 'no_basis' };
  if (ownerQuestions.length > 0) {
    return { verdict: 'needs_owner', basis, owner_questions: ownerQuestions, asker, downgraded: 'open_questions' };
  }
  return { verdict: 'answered', basis, owner_questions: [], asker };
}
