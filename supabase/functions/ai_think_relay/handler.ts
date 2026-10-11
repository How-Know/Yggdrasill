// ai_think_relay 요청 처리. 운영자 PC의 Cursor 작업창(MCP 서버 tools/think_relay)만 부른다.
// 인증은 사용자 JWT가 아니라 전용 토큰(비밀값 THINK_RELAY_TOKEN_SHA256과 비교)이다.
// 읽기는 승인된 기억, 대화 목록·본문('답변에서 제외'한 문답 빼고), 코드 요청 요약(diff 없음)만.
// 쓰기는 ask(Think에게 묻기) 하나이고, 커서가 시작한 대화에만 남는다.

import { ALL_SEARCH, type MemorySearchScope } from '../ai_think/access_context.ts';
import type { MemoryDetail, MemoryRow, MessageRow } from '../ai_think/context.ts';
import type { CodeRequestDetail, CodeRequestHit } from '../ai_think/actions.ts';
import type { ConversationRow } from '../ai_think/chat.ts';
import type { RelayAskResult } from '../ai_think/relay.ts';
import type { RelayConversationHit } from '../ai_think/store.ts';
import { extractSearchTerms } from '../_shared/ai/search_terms.ts';

export interface RelayReadStore {
  listActiveMemories(kinds: string[]): Promise<MemoryRow[]>;
  searchMemories(terms: string[], limit: number, scope?: MemorySearchScope): Promise<MemoryRow[]>;
  getMemory(id: string): Promise<MemoryDetail | null>;
  listConversationsForRelay(query: string | null, limit: number, includeArchived: boolean): Promise<RelayConversationHit[]>;
  getConversation(id: string): Promise<ConversationRow | null>;
  listMessages(conversationId: string, limit: number): Promise<MessageRow[]>;
  listCodeRequests(query: string | null, limit: number): Promise<CodeRequestHit[]>;
  getCodeRequest(id: string): Promise<CodeRequestDetail | null>;
}

export interface RelayHandlerDeps {
  /** 비밀값 THINK_RELAY_TOKEN_SHA256. 없으면 503. */
  tokenSha256: string | null;
  hash(token: string): Promise<string>;
  store: RelayReadStore;
  ask(input: { question: string; conversationId: string | null }): Promise<RelayAskResult>;
  dailyLimit: number;
}

type Body = Record<string, unknown>;

const MEMORY_KINDS = ['identity', 'principle', 'decision', 'note'];
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const MESSAGE_CHARS = 8000;
export const CONVERSATION_CHARS = 150_000;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json; charset=utf-8' } });
}

function fail(status: number, error: string, message?: string): Response {
  return json({ ok: false, error, ...(message ? { message } : {}) }, status);
}

function sameText(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function str(v: unknown, max = 200): string | null {
  if (typeof v !== 'string') return null;
  const t = v.trim();
  return t ? t.slice(0, max) : null;
}

function int(v: unknown, fallback: number, min: number, max: number): number {
  const n = typeof v === 'number' ? v : Number.NaN;
  if (!Number.isFinite(n)) return fallback;
  return Math.max(min, Math.min(max, Math.floor(n)));
}

function kinds(v: unknown, fallback: string[]): string[] {
  if (!Array.isArray(v)) return fallback;
  const out = v.filter((k): k is string => typeof k === 'string' && MEMORY_KINDS.includes(k));
  return out.length > 0 ? out : fallback;
}

function clipText(text: string, max: number): { text: string; clipped: boolean } {
  return text.length <= max ? { text, clipped: false } : { text: `${text.slice(0, max)}…`, clipped: true };
}

function memorySummary(m: MemoryRow) {
  return {
    id: m.id,
    kind: m.kind,
    title: m.title,
    excerpt: clipText(m.content, 400).text,
    updated_at: m.updated_at ?? null,
    memory_scope: m.memory_scope ?? 'legacy_unscoped',
    scope_department: m.scope_department ?? null,
  };
}

async function listMemories(store: RelayReadStore, body: Body): Promise<Response> {
  const wanted = kinds(body.kinds, ['identity', 'principle', 'decision']);
  const rows = (await store.listActiveMemories(wanted)).slice(0, int(body.limit, 100, 1, 300));
  return json({ ok: true, memories: rows.map(memorySummary) });
}

async function searchMemories(store: RelayReadStore, body: Body): Promise<Response> {
  const query = str(body.query);
  if (!query) return fail(400, 'query_required', '검색어를 넣으세요.');
  const wanted = kinds(body.kinds, []);
  const terms = extractSearchTerms(query);
  // 운영자 PC의 읽기 도구라 대화 역할과 무관하다. 목록·단건 조회와 같게 모든 승인 기억에서 찾는다(범위는 결과에 표시).
  const hits = (await store.searchMemories(terms.length > 0 ? terms : [query], 20, ALL_SEARCH))
    .filter((m) => m.status === 'active' && (wanted.length === 0 || wanted.includes(m.kind)))
    .slice(0, int(body.limit, 10, 1, 20));
  return json({ ok: true, memories: hits.map(memorySummary) });
}

async function getMemory(store: RelayReadStore, body: Body): Promise<Response> {
  const id = str(body.id, 64);
  if (!id || !UUID_RE.test(id)) return fail(400, 'id_invalid');
  const m = await store.getMemory(id);
  if (!m || m.status !== 'active') return fail(404, 'memory_not_found', '승인된 기억 중에 없습니다.');
  return json({ ok: true, memory: m });
}

async function listConversations(store: RelayReadStore, body: Body): Promise<Response> {
  const rows = await store.listConversationsForRelay(str(body.query, 100), int(body.limit, 30, 1, 100), body.include_archived === true);
  return json({ ok: true, conversations: rows });
}

/** 최근 메시지부터 글자 예산 안에서. '답변에서 제외'한 문답은 store.listMessages가 이미 뺐다. */
async function getConversation(store: RelayReadStore, body: Body): Promise<Response> {
  const id = str(body.conversation_id, 64);
  if (!id || !UUID_RE.test(id)) return fail(400, 'conversation_id_invalid');
  const conv = await store.getConversation(id);
  if (!conv) return fail(404, 'conversation_not_found', '대화를 찾지 못했습니다.');
  const rows = await store.listMessages(id, int(body.limit, 60, 1, 200));
  let budget = CONVERSATION_CHARS;
  const picked: Record<string, unknown>[] = [];
  let dropped = 0;
  for (let i = rows.length - 1; i >= 0; i--) {
    const m = rows[i];
    const c = clipText(m.content, MESSAGE_CHARS);
    if (budget - c.text.length < 0 && picked.length > 0) {
      dropped = i + 1;
      break;
    }
    budget -= c.text.length;
    picked.unshift({
      id: m.id,
      role: m.role,
      asked_by: m.asked_by ?? null,
      status: m.status,
      content: c.text,
      clipped: c.clipped,
      attachments: m.attachments.map((a) => a.name),
      created_at: m.created_at,
    });
  }
  return json({
    ok: true,
    conversation: {
      id: conv.id,
      title: conv.title,
      status: conv.status,
      origin: conv.origin ?? 'owner',
      split_from_conversation_id: conv.split_from_conversation_id ?? null,
    },
    messages: picked,
    older_messages_dropped: dropped,
  });
}

async function listCodeRequests(store: RelayReadStore, body: Body): Promise<Response> {
  const rows = await store.listCodeRequests(str(body.query, 100), int(body.limit, 20, 1, 50));
  return json({ ok: true, code_requests: rows });
}

async function getCodeRequest(store: RelayReadStore, body: Body): Promise<Response> {
  const id = str(body.id, 64);
  if (!id || !UUID_RE.test(id)) return fail(400, 'id_invalid');
  const r = await store.getCodeRequest(id);
  if (!r) return fail(404, 'code_request_not_found');
  return json({ ok: true, code_request: r });
}

async function ask(deps: RelayHandlerDeps, body: Body): Promise<Response> {
  const question = typeof body.question === 'string' ? body.question : '';
  let conversationId: string | null = null;
  if (body.conversation_id != null) {
    conversationId = str(body.conversation_id, 64);
    if (!conversationId || !UUID_RE.test(conversationId)) return fail(400, 'conversation_id_invalid');
  }
  const out = await deps.ask({ question, conversationId });
  if (!out.ok) return json({ ok: false, error: out.error, message: out.message, conversation_id: out.conversation_id ?? null }, out.status);
  return json(out);
}

export async function handleRelay(req: Request, deps: RelayHandlerDeps): Promise<Response> {
  if (req.method !== 'POST') return fail(405, 'method_not_allowed');
  const expected = deps.tokenSha256?.trim().toLowerCase() ?? '';
  if (!/^[0-9a-f]{64}$/.test(expected)) return fail(503, 'relay_not_configured', '서버에 THINK_RELAY_TOKEN_SHA256 비밀값이 없습니다.');

  const token = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '').trim();
  if (!token || !sameText(await deps.hash(token), expected)) return fail(401, 'unauthorized');

  let body: Body;
  try {
    const parsed = await req.json();
    body = parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? (parsed as Body) : {};
  } catch {
    return fail(400, 'invalid_json');
  }

  try {
    switch (String(body.action ?? '')) {
      case 'status':
        return json({ ok: true, asker: 'cursor_ide', daily_limit: deps.dailyLimit });
      case 'list_memories':
        return await listMemories(deps.store, body);
      case 'search_memories':
        return await searchMemories(deps.store, body);
      case 'get_memory':
        return await getMemory(deps.store, body);
      case 'list_conversations':
        return await listConversations(deps.store, body);
      case 'get_conversation':
        return await getConversation(deps.store, body);
      case 'list_code_requests':
        return await listCodeRequests(deps.store, body);
      case 'get_code_request':
        return await getCodeRequest(deps.store, body);
      case 'ask':
        return await ask(deps, body);
      default:
        return fail(400, 'unknown_action');
    }
  } catch (e) {
    console.error('[ai_think_relay] handler failed:', e instanceof Error ? e.message : String(e));
    return fail(500, 'internal_error');
  }
}
