import { assert, assertEquals } from 'jsr:@std/assert@1';
import { FakeAiProvider, type FakeTurn } from '../_shared/ai/fake.ts';
import type { AiRequest } from '../_shared/ai/types.ts';
import { MEMORY_CHANGE_TOOL_NAME, MEMORY_TOOL_NAME, workStateNote, type ActionRow } from './actions.ts';
import { runThinkChat, type ChatInput } from './chat.ts';
import { computeFeatures } from './features.ts';
import { runThinkTool } from './tools.ts';
import { EventLog, MemoryThinkStore, RunLog, memory, testEnv } from './test_support.ts';

const ALL = { conversation_split: 1, think_roles: 1, memory_proposals: 1 };
const READY = computeFeatures({ ok: true, features: ALL }, ALL, true);
const DB_REQUIRED = computeFeatures({ ok: true, features: { conversation_split: 1, think_roles: 1 } }, ALL, true);
const OLD_APP = computeFeatures({ ok: true, features: ALL }, { conversation_split: 1, think_roles: 1 }, true);

const PENDING_ID = '33333333-3333-4333-8333-333333333333';
const MEMORY_ID = '44444444-4444-4444-8444-444444444444';

const memoryArgs = (memory: Record<string, unknown> = {}) => ({
  memory: {
    kind: 'decision',
    title: '숙제 확인은 수업 시작 10분 안에',
    content: '수업 시작 후 10분 안에 숙제 확인을 끝낸다.',
    decision_context: '숙제 확인이 길어져 수업이 밀렸다',
    decision_reason: '수업 시간을 지키기 위해',
    alternatives: ['수업 끝에 확인'],
    tags: ['숙제'],
    memory_scope: 'common',
    scope_department: null,
    supersedes_id: null,
    ...memory,
  },
  reason: '사용자가 "10분 안에 끝내자"고 확정했다',
  relation: 'distinct',
  compared_ids: null,
});

function input(partial: Partial<ChatInput>): ChatInput {
  return {
    userId: 'user-1',
    safetyId: 'hash',
    conversationId: null,
    message: '좋아, 숙제 확인은 10분 안에 끝내는 걸로 하자',
    attachments: [],
    deep: false,
    webSearch: false,
    signal: new AbortController().signal,
    startedAt: Date.now(),
    wallClockMs: 140000,
    ...partial,
  };
}

const toolNames = (req: AiRequest) => (req.tools ?? []).map((t) => t.name);

async function existingConversation(store: MemoryThinkStore) {
  const conv = await store.createConversation('숙제 확인');
  await store.insertMessage({ conversation_id: conv.id, role: 'user', content: '숙제 확인 시간', status: 'complete' });
  await store.insertMessage({ conversation_id: conv.id, role: 'assistant', content: '정리한 답', status: 'complete' });
  return conv;
}

async function run(store: MemoryThinkStore, partial: Partial<ChatInput>, script?: (req: AiRequest, i: number) => FakeTurn) {
  const provider = new FakeAiProvider(script ?? (() => ({ text: '답변' })));
  const events = new EventLog();
  const out = await runThinkChat(input(partial), { provider, store, recordRun: new RunLog().record, emit: events.emit, env: testEnv });
  return { out, provider, events };
}

const ctx = () => ({ conversationId: 'conv-x', memoryRefs: [], memory: { proposed: false as boolean, sessionId: undefined as string | undefined } });
const parse = (r: { output: string }) => JSON.parse(r.output) as Record<string, unknown>;

async function searchFirst(store: MemoryThinkStore, c: ReturnType<typeof ctx>, query = 'zzzz없는말') {
  const r = await runThinkTool('search_memories', JSON.stringify({ query, kinds: null }), store, 8000, c);
  assert(r.ok, r.output);
  return parse(r);
}

Deno.test('기억 제안 도구는 기능이 준비됐을 때만 노출되고, 지시문도 그에 맞게 바뀐다', async () => {
  const store = new MemoryThinkStore();
  const conv = await existingConversation(store);

  const ready = await run(store, { conversationId: conv.id, features: READY });
  const req = ready.provider.requests[0];
  assert(toolNames(req).includes(MEMORY_TOOL_NAME));
  assert(toolNames(req).includes(MEMORY_CHANGE_TOOL_NAME));
  assert(req.instructions!.includes('## 기억 저장 제안'));

  for (const features of [DB_REQUIRED, OLD_APP, undefined]) {
    const off = await run(store, { conversationId: conv.id, features });
    const r = off.provider.requests[0];
    assert(!toolNames(r).includes(MEMORY_TOOL_NAME));
    assert(!toolNames(r).includes(MEMORY_CHANGE_TOOL_NAME));
    assert(!r.instructions!.includes('## 기억 저장 제안'));
  }
});

Deno.test('기억 카드는 한 답변에 하나만 남고, 앞 대기 카드를 밀어내지 않는다', async () => {
  const store = new MemoryThinkStore();
  const conv = await existingConversation(store);
  await store.actions.push({
    id: 'act-seed',
    conversation_id: conv.id,
    message_id: null,
    kind: 'save_memory',
    status: 'proposed',
    payload: { memory: { title: '앞 카드' } },
    preview: { title: '앞 카드' },
    result: null,
    error: null,
    superseded: false,
    created_at: '2026-10-11T00:00:00Z',
  });

  const { out, events } = await run(store, { conversationId: conv.id, features: READY }, (_req, i) =>
    i === 0
      ? {
        functionCalls: [
          { name: 'search_memories', arguments: { query: 'zzzz없는말', kinds: null } },
          { name: MEMORY_TOOL_NAME, arguments: memoryArgs() },
          { name: MEMORY_CHANGE_TOOL_NAME, arguments: { target_action_id: PENDING_ID, op: 'withdraw', memory: null, reason: '중복', relation: null, compared_ids: null } },
        ],
      }
      : { text: '답변' }
  );

  assertEquals(out.status, 'complete');
  const tools = events.of('tool').filter((t) => t.status === 'done' && (t.name === MEMORY_TOOL_NAME || t.name === MEMORY_CHANGE_TOOL_NAME));
  assertEquals(tools.map((t) => t.ok), [true, false]);
  const cards = store.actions.filter((a) => a.kind === 'save_memory');
  assertEquals(cards.length, 2);
  assert(cards.every((a) => a.status === 'proposed' && !a.superseded), '기억 카드는 서로 대체하지 않는다');
  assertEquals(store.actions.filter((a) => a.kind === 'memory_card_change').length, 0);
});

Deno.test('기억 제안: 빠진 값을 알려 주고, 쓸 수 없는 턴이면 거부한다', async () => {
  const store = new MemoryThinkStore();

  const off = await runThinkTool(MEMORY_TOOL_NAME, JSON.stringify(memoryArgs()), store, 8000, { conversationId: 'conv-x', memoryRefs: [] });
  assertEquals(parse(off).error, 'memory_unavailable');

  const missing = await runThinkTool(
    MEMORY_TOOL_NAME,
    JSON.stringify(memoryArgs({ kind: 'note', title: ' ', memory_scope: 'department', scope_department: null })),
    store,
    8000,
    ctx(),
  );
  assertEquals(parse(missing).missing, ['memory.kind', 'memory.title', 'memory.scope_department']);

  const reviseNoMemory = await runThinkTool(
    MEMORY_CHANGE_TOOL_NAME,
    JSON.stringify({ target_action_id: PENDING_ID, op: 'revise', memory: null, reason: '' }),
    store,
    8000,
    ctx(),
  );
  assert((parse(reviseNoMemory).missing as string[]).includes('memory.title'));
  assertEquals(store.actions.length, 0);

  const withdraw = await runThinkTool(
    MEMORY_CHANGE_TOOL_NAME,
    JSON.stringify({ target_action_id: PENDING_ID, op: 'withdraw', memory: { title: '무시됨' }, reason: '중복' }),
    store,
    8000,
    ctx(),
  );
  assert(withdraw.ok);
  assertEquals(store.actions[0].payload.memory, null, '삭제 제안에는 기억 내용을 싣지 않는다');
});

Deno.test('원칙 제안은 결정 전용 항목을 비운다', async () => {
  const store = new MemoryThinkStore();
  const c = ctx();
  const found = await searchFirst(store, c);
  assertEquals(found.status, 'empty');
  assertEquals(found.excerpt_only, true);
  const r = await runThinkTool(MEMORY_TOOL_NAME, JSON.stringify(memoryArgs({ kind: 'principle' })), store, 8000, c);
  assert(r.ok);
  const memory = store.actions[0].payload.memory as Record<string, unknown>;
  assertEquals(memory.decision_context, null);
  assertEquals(memory.alternatives, []);
  const basis = store.actions[0].payload.basis as Record<string, unknown>;
  assertEquals(basis.relation, 'distinct');
  assertEquals((basis as { fake?: unknown }).fake, undefined);
});

Deno.test('DB 중복 오류는 대상 id와 다음 할 일로 바꾸고, 같은 답변에서 변경 카드를 낼 수 있다', async () => {
  const store = new MemoryThinkStore();
  const c = ctx();

  store.proposeFailure = `memory_duplicate_active:${MEMORY_ID}`;
  const dup = parse(await runThinkTool(MEMORY_TOOL_NAME, JSON.stringify(memoryArgs()), store, 8000, c));
  assertEquals(dup.error, 'memory_duplicate_active');
  assertEquals(dup.memory_id, MEMORY_ID);

  store.proposeFailure = `memory_proposal_pending:${PENDING_ID}`;
  const pending = parse(await runThinkTool(MEMORY_TOOL_NAME, JSON.stringify(memoryArgs()), store, 8000, c));
  assertEquals(pending.error, 'memory_proposal_pending');
  assertEquals(pending.pending_action_id, PENDING_ID);
  assertEquals(c.memory.proposed, false, '실패한 제안은 한 장으로 세지 않는다');

  await searchFirst(store, c);
  const change = await runThinkTool(
    MEMORY_CHANGE_TOOL_NAME,
    JSON.stringify({ target_action_id: PENDING_ID, op: 'replace', ...memoryArgs({ title: '숙제 확인은 15분 안에' }) }),
    store,
    8000,
    c,
  );
  assert(change.ok);
  assertEquals(store.actions.map((a) => a.kind), ['memory_card_change']);
});

Deno.test('알 수 없는 DB 오류는 삼키지 않는다', async () => {
  const store = new MemoryThinkStore();
  store.proposeFailure = 'permission denied';
  const r = await runThinkTool(MEMORY_TOOL_NAME, JSON.stringify(memoryArgs()), store, 8000, ctx());
  assert(!r.ok);
  assert(parse(r).error !== 'memory_proposal_pending');
});

Deno.test('작업 상태 메모는 대기 중인 기억 카드의 id와 저장 결과를 알린다', () => {
  const row = (kind: ActionRow['kind'], status: string, preview: Record<string, unknown> = { title: '숙제 확인' }): ActionRow => ({
    id: `a-${kind}-${status}`,
    conversation_id: 'c',
    message_id: 'm',
    kind,
    status,
    payload: {},
    preview,
    result: null,
    error: null,
    created_at: '',
  });
  const note = workStateNote({
    actions: [
      row('save_memory', 'proposed'),
      row('save_memory', 'applied'),
      row('memory_card_change', 'proposed', { title: '숙제 확인 15분', op: 'replace', target_title: '숙제 확인' }),
    ],
    codeRequests: [],
  })!;
  assert(note.includes('a-save_memory-proposed'));
  assert(note.includes('확정 지침이 아니다'));
  assert(note.includes('대체'));
});

const READ_ID = '55555555-5555-4555-8555-555555555555';
const HIDDEN_ID = '66666666-6666-4666-8666-666666666666';

Deno.test('검색 실패와 미조회는 빈 결과가 아니고, 임의 version으로는 원문을 읽은 것이 되지 않는다', async () => {
  const store = new MemoryThinkStore();
  store.memories.push(memory({
    id: READ_ID,
    kind: 'decision',
    title: '기존 결정',
    content: '가'.repeat(4000),
    status: 'active',
    version: 3,
    memory_scope: 'common',
  }));
  const c = ctx();

  const failed = parse(await runThinkTool('search_memories', JSON.stringify({ query: 'a', kinds: null }), store, 8000, c));
  assertEquals(failed.error, 'memory_search_failed');
  const blocked = parse(await runThinkTool(MEMORY_TOOL_NAME, JSON.stringify(memoryArgs()), store, 8000, c));
  assertEquals(blocked.error, 'memory_search_failed');
  assertEquals(store.actions.length, 0);

  const again = ctx();
  const empty = await searchFirst(store, again);
  assertEquals(empty.status, 'empty');
  assertEquals(empty.hit_count, 0);
  const unread = parse(await runThinkTool(
    MEMORY_TOOL_NAME,
    JSON.stringify(memoryArgs({ supersedes_id: READ_ID, relation: 'supplement', compared_ids: [READ_ID], basis: { fake: true, version: 1 } })),
    store,
    8000,
    again,
  ));
  assertEquals(unread.error, 'memory_read_missing');

  const first = parse(await runThinkTool('get_memory', JSON.stringify({ id: READ_ID, offset: null, version: 1 }), store, 8000, again));
  assertEquals(first.version, 3);
  assertEquals(first.complete, false);
  assertEquals(first.excerpt_only, false);
  const partial = parse(await runThinkTool(
    MEMORY_TOOL_NAME,
    JSON.stringify({ ...memoryArgs({ supersedes_id: READ_ID }), relation: 'supplement', compared_ids: null }),
    store,
    8000,
    again,
  ));
  assertEquals(partial.error, 'memory_read_incomplete');
  assertEquals(store.actions.length, 0);

  store.memories[0].version = 4;
  store.memories[0].content = `${store.memories[0].content}나`;
  const changed = parse(await runThinkTool('get_memory', JSON.stringify({ id: READ_ID, offset: first.next_offset }), store, 8000, again));
  assertEquals(changed.status, 'version_changed');
  assertEquals(changed.version, 4);
  let offset: unknown = 0;
  let last: Record<string, unknown> = {};
  for (let i = 0; i < 6 && offset != null; i += 1) {
    last = parse(await runThinkTool('get_memory', JSON.stringify({ id: READ_ID, offset }), store, 8000, again));
    offset = last.next_offset;
  }
  assertEquals(last.complete, true);
  assertEquals(last.version, 4);
  const card = await runThinkTool(
    MEMORY_TOOL_NAME,
    JSON.stringify({ ...memoryArgs({ title: '다른 제목', content: '가'.repeat(20), supersedes_id: READ_ID }), relation: 'supplement' }),
    store,
    8000,
    again,
  );
  assert(card.ok);
  const basis = store.actions[0].payload.basis as { reads: { version: number }[]; fake?: unknown };
  assertEquals(basis.reads[0].version, 4);
  assertEquals(basis.fake, undefined);
  assertEquals(store.memories.filter((m) => m.title === '다른 제목').length, 0, '승인 전에는 기억이 생기지 않는다');
});

Deno.test('중복으로 판단하면 카드를 만들지 않고, 다른 제목의 같은 본문은 별개 카드로 남긴다', async () => {
  const store = new MemoryThinkStore();
  store.memories.push(memory({
    id: READ_ID,
    kind: 'decision',
    title: '이미 있음',
    content: '동일한 본문',
    status: 'active',
    memory_scope: 'common',
  }));
  const c = ctx();
  await searchFirst(store, c);
  const full = parse(await runThinkTool('get_memory', JSON.stringify({ id: READ_ID, offset: null }), store, 8000, c));
  assertEquals(full.complete, true);
  const dup = parse(await runThinkTool(
    MEMORY_TOOL_NAME,
    JSON.stringify({ ...memoryArgs({ title: '다른 이름', content: '동일한 본문' }), relation: 'duplicate', compared_ids: [READ_ID] }),
    store,
    8000,
    c,
  ));
  assertEquals(dup.error, 'memory_duplicate_classified');
  assertEquals(dup.memory_id, READ_ID);
  assertEquals(store.actions.length, 0);

  const distinct = await runThinkTool(
    MEMORY_TOOL_NAME,
    JSON.stringify({ ...memoryArgs({ title: '별개 이름', content: '동일한 본문' }), relation: 'distinct', compared_ids: [READ_ID] }),
    store,
    8000,
    c,
  );
  assert(distinct.ok);
  assertEquals(store.actions.length, 1);
  assertEquals(store.memories.length, 1);
});

Deno.test('대화 범위 밖 기억은 없는 기억처럼 보이고, 비교 근거가 되지 않는다', async () => {
  const store = new MemoryThinkStore();
  store.memories.push(memory({
    id: HIDDEN_ID,
    kind: 'decision',
    title: '문제풀이만',
    content: '숨은 본문',
    status: 'active',
    memory_scope: 'department',
    scope_department: 'product',
  }));
  const c = {
    ...ctx(),
    access: {
      conversationId: 'conv-x',
      thinkRoleId: 'education' as const,
      extraRefDepartments: [],
      linkedMemoryIds: new Set<string>(),
      linkedDocumentNodeIds: new Set<string>(),
      rolesFeatureReady: true,
    },
  };
  await searchFirst(store, c);
  const hidden = parse(await runThinkTool('get_memory', JSON.stringify({ id: HIDDEN_ID, offset: null }), store, 8000, c));
  assertEquals(hidden.error, 'not_found');
  assertEquals(hidden.document, undefined);
  const proposed = parse(await runThinkTool(
    MEMORY_TOOL_NAME,
    JSON.stringify({ ...memoryArgs({ title: '권한 밖' }), relation: 'distinct', compared_ids: [HIDDEN_ID] }),
    store,
    8000,
    c,
  ));
  assertEquals(proposed.error, 'memory_basis_forbidden');
  assertEquals(store.actions.length, 0);
});

