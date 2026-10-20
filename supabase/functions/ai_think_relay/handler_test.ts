import { assert, assertEquals } from 'jsr:@std/assert@1';
import { sha256Hex } from '../_shared/hash.ts';
import type { RelayAskResult } from '../ai_think/relay.ts';
import { MemoryRelayStore, memory } from '../ai_think/test_support.ts';
import { CONVERSATION_CHARS, handleRelay, type RelayHandlerDeps } from './handler.ts';

const TOKEN = 'relay-token-for-tests';
const MEM = '11111111-1111-4111-8111-111111111111';
const DRAFT = '22222222-2222-4222-8222-222222222222';

async function harness(opts: { token?: string | null; ask?: RelayHandlerDeps['ask'] } = {}) {
  const store = new MemoryRelayStore();
  store.memories.push(
    memory({ id: MEM, kind: 'decision', title: '수업 기록은 날짜순', content: '날짜순' }),
    memory({ id: DRAFT, kind: 'decision', title: '초안', content: '승인 전', status: 'draft' }),
  );
  const asked: { question: string; conversationId: string | null }[] = [];
  const deps: RelayHandlerDeps = {
    tokenSha256: opts.token === undefined ? await sha256Hex(TOKEN) : opts.token,
    hash: sha256Hex,
    store,
    dailyLimit: 60,
    ask: opts.ask ??
      ((input) => {
        asked.push(input);
        return Promise.resolve<RelayAskResult>({
          ok: true,
          ask_id: 'ask-1',
          conversation_id: 'conv-1',
          verdict: 'answered',
          answer: '날짜순',
          basis: [{ id: MEM, kind: 'decision', title: '수업 기록은 날짜순' }],
          owner_questions: [],
          downgraded: null,
        });
      }),
  };
  return { store, deps, asked };
}

function post(body: unknown, token: string | null = TOKEN): Request {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  if (token) headers.Authorization = `Bearer ${token}`;
  return new Request('http://localhost/ai_think_relay', { method: 'POST', headers, body: JSON.stringify(body) });
}

const call = async (deps: RelayHandlerDeps, body: unknown, token?: string | null) => {
  const res = await handleRelay(post(body, token === undefined ? TOKEN : token), deps);
  return { status: res.status, body: await res.json() };
};

Deno.test('비밀값이 없으면 503, 토큰이 틀리거나 없으면 401', async () => {
  const off = await harness({ token: null });
  assertEquals((await call(off.deps, { action: 'status' })).status, 503);
  const h = await harness();
  assertEquals((await call(h.deps, { action: 'status' }, 'wrong')).status, 401);
  assertEquals((await call(h.deps, { action: 'status' }, null)).status, 401);
  const ok = await call(h.deps, { action: 'status' });
  assertEquals(ok.body, { ok: true, asker: 'cursor_ide', daily_limit: 60 });
  assertEquals((await call(h.deps, { action: 'drop_table' })).status, 400);
});

Deno.test('기억은 승인된 것만 읽는다', async () => {
  const h = await harness();
  const list = await call(h.deps, { action: 'list_memories' });
  assertEquals(list.body.memories.map((m: { id: string }) => m.id), [MEM]);
  const search = await call(h.deps, { action: 'search_memories', query: '초안 승인' });
  assert(!search.body.memories.some((m: { id: string }) => m.id === DRAFT));
  assertEquals((await call(h.deps, { action: 'get_memory', id: MEM })).body.memory.title, '수업 기록은 날짜순');
  assertEquals((await call(h.deps, { action: 'get_memory', id: DRAFT })).status, 404);
  assertEquals((await call(h.deps, { action: 'get_memory', id: 'x' })).status, 400);
  assertEquals((await call(h.deps, { action: 'search_memories', query: ' ' })).status, 400);
});

Deno.test('코드 요청: 기본은 짧은 요약, section이면 구간, 잘못된 section은 400', async () => {
  const h = await harness();
  const id = '33333333-3333-4333-8333-333333333333';
  h.store.codeRequests.push({
    id,
    title: '수정',
    status: 'ready',
    mode: 'change',
    conversation_id: null,
    created_at: '2026-10-13T00:00:00Z',
    request: { goal: 'g', background: '긴 배경 '.repeat(10_000) },
    round: 1,
    max_rounds: 1,
    review_status: null,
    last_error: null,
    latest: { round: 1, status: 'finished', result: { summary: '고침', diff_stats: { files: 1, additions: 1, deletions: 0, list: [] } }, result_text: 'r' },
  });
  h.store.codeDiffs[id] = 'diff --git a/x b/x';
  const brief = await call(h.deps, { action: 'get_code_request', id });
  assert(JSON.stringify(brief.body).length < 12_000);
  assertEquals(brief.body.code_request.checks.verdict, 'no_record');
  const part = await call(h.deps, { action: 'get_code_request', id, section: 'request', offset: 7000 });
  assertEquals(part.body.code_request.offset, 7000);
  assert(part.body.code_request.next_offset > 7000);
  assertEquals((await call(h.deps, { action: 'get_code_request', id, section: 'diff' })).body.code_request.text, 'diff --git a/x b/x');
  assertEquals((await call(h.deps, { action: 'get_code_request', id, section: 'env' })).status, 400);
});

Deno.test('대화 본문: 답변에서 제외한 문답은 빠지고, 커서 질문은 표시가 남는다', async () => {
  const h = await harness();
  const conv = await h.store.createConversation('커리큘럼');
  conv.id = '33333333-3333-4333-8333-333333333333';
  await h.store.insertMessage({ conversation_id: conv.id, role: 'user', content: '보이는 질문', status: 'complete' });
  await h.store.insertMessage({ conversation_id: conv.id, role: 'user', content: '커서 질문', status: 'complete', asked_by: 'cursor_ide' });
  await h.store.insertMessage({ conversation_id: conv.id, role: 'user', content: '제외한 질문', status: 'complete' });
  h.store.messages[h.store.messages.length - 1].excluded = true;

  const out = await call(h.deps, { action: 'get_conversation', conversation_id: conv.id });
  assertEquals(out.status, 200);
  assertEquals(out.body.conversation.origin, 'owner');
  assertEquals(out.body.messages.map((m: { content: string }) => m.content), ['보이는 질문', '커서 질문']);
  assertEquals(out.body.messages[1].asked_by, 'cursor_ide');
  assertEquals((await call(h.deps, { action: 'get_conversation', conversation_id: '44444444-4444-4444-8444-444444444444' })).status, 404);

  const list = await call(h.deps, { action: 'list_conversations' });
  assertEquals(list.body.conversations[0].message_count, 3);
});

Deno.test('대화 본문이 길면 오래된 메시지부터 빼고 수를 알려 준다', async () => {
  const h = await harness();
  const conv = await h.store.createConversation('긴 대화');
  conv.id = '55555555-5555-4555-8555-555555555555';
  const count = Math.ceil(CONVERSATION_CHARS / 8000) + 3;
  for (let i = 0; i < count; i++) {
    await h.store.insertMessage({ conversation_id: conv.id, role: 'assistant', content: `${i}`.padEnd(9000, '가'), status: 'complete' });
  }
  const out = await call(h.deps, { action: 'get_conversation', conversation_id: conv.id, limit: 200 });
  assert(out.body.older_messages_dropped > 0);
  assert(out.body.messages.every((m: { clipped: boolean }) => m.clipped));
  assertEquals(out.body.messages.at(-1).content.startsWith(`${count - 1}`), true, '최근 메시지는 남는다');
});

Deno.test('ask: 질문과 이어 물을 대화를 넘기고, 실패는 상태 코드 그대로', async () => {
  const h = await harness();
  const ok = await call(h.deps, { action: 'ask', question: '순서는?' });
  assertEquals(ok.body.verdict, 'answered');
  assertEquals(h.asked[0], { question: '순서는?', conversationId: null });
  assertEquals((await call(h.deps, { action: 'ask', question: 'q', conversation_id: 'bad' })).status, 400);

  const limited = await harness({
    ask: () => Promise.resolve({ ok: false, status: 429, error: 'relay_daily_limit', message: '한도', conversation_id: null }),
  });
  const res = await call(limited.deps, { action: 'ask', question: 'q' });
  assertEquals(res.status, 429);
  assertEquals(res.body.error, 'relay_daily_limit');
});
