// Think 역할별 자료 접근: 맥락·검색·get_memory·문서 본문·캐시 키·스냅샷·초안 경로·구버전 호환.
import { assert, assertEquals, assertNotEquals } from 'jsr:@std/assert@1';
import { FakeAiProvider } from '../_shared/ai/fake.ts';
import type { AiRequest } from '../_shared/ai/types.ts';
import type { ConversationAccessState } from './access_context.ts';
import { runThinkChat, type ChatInput } from './chat.ts';
import { buildThinkContext, CONTEXT_LIMITS } from './context.ts';
import { createDecisionDraft, createSpecExport } from './drafts.ts';
import { computeFeatures, type ThinkFeatures } from './features.ts';
import { titleInstructions } from './prompts.ts';
import { SupabaseThinkStore, type SupabaseLike } from './store.ts';
import { runThinkTool } from './tools.ts';
import { EventLog, MemoryThinkStore, RunLog, memory, testEnv } from './test_support.ts';

const isTitle = (req: AiRequest) => req.instructions === titleInstructions();

const READY: ThinkFeatures = computeFeatures(
  { ok: true, features: { conversation_split: 1, think_roles: 1 } },
  { conversation_split: 1, think_roles: 1 },
  true,
);
const OLD_APP: ThinkFeatures = computeFeatures(
  { ok: true, features: { conversation_split: 1, think_roles: 1 } },
  { conversation_split: 1 },
  true,
);

const PRODUCT_ID = '00000000-0000-4000-8000-0000000000a2';

function access(partial: Partial<ConversationAccessState> = {}): ConversationAccessState {
  return {
    conversationId: 'c1',
    thinkRoleId: 'education',
    extraRefDepartments: [],
    linkedMemoryIds: new Set(),
    linkedDocumentNodeIds: new Set(),
    rolesFeatureReady: true,
    ...partial,
  };
}

function seededStore(): MemoryThinkStore {
  const store = new MemoryThinkStore();
  store.memories.push(
    memory({ id: 'p-legacy', kind: 'principle', title: '레거시 원칙', content: 'LEGACY_PRINCIPLE' }),
    memory({ id: 'p-common', kind: 'principle', title: '공통 원칙', content: 'COMMON_PRINCIPLE', memory_scope: 'common' }),
    memory({
      id: 'd-edu',
      kind: 'decision',
      title: '교육 결정',
      content: 'EDU_DECISION',
      memory_scope: 'department',
      scope_department: 'education',
    }),
    memory({
      id: PRODUCT_ID,
      kind: 'decision',
      title: '제품 결정',
      content: 'PRODUCT_DECISION',
      memory_scope: 'department',
      scope_department: 'product',
    }),
    memory({
      id: 'd-draft',
      kind: 'decision',
      title: '초안 결정',
      content: 'DRAFT_DECISION',
      status: 'draft',
      memory_scope: 'common',
    }),
  );
  return store;
}

function chatInput(partial: Partial<ChatInput> = {}): ChatInput {
  return {
    userId: 'user-1',
    safetyId: 'hash',
    conversationId: null,
    message: '이번 학기 진도 운영을 어떻게 할까?',
    attachments: [],
    deep: false,
    webSearch: false,
    signal: new AbortController().signal,
    startedAt: Date.now(),
    wallClockMs: 140000,
    ...partial,
  };
}

Deno.test('교육 역할 맥락에는 레거시·공통·교육 부서 승인 기억만 들어간다', async () => {
  const store = seededStore();
  const ctx = await buildThinkContext(store, {
    conversationId: 'c1',
    userMessage: '질문',
    attachments: [],
    access: access(),
  });
  assert(ctx.instructions.includes('LEGACY_PRINCIPLE'));
  assert(ctx.instructions.includes('COMMON_PRINCIPLE'));
  assert(ctx.instructions.includes('EDU_DECISION'));
  assert(!ctx.instructions.includes('PRODUCT_DECISION'), '다른 부서 결정');
  assert(!ctx.instructions.includes('DRAFT_DECISION'), '미승인 기억');
  assertEquals(
    ctx.deliveredMaterials.map((m) => m.id).sort(),
    ['d-edu', 'p-common', 'p-legacy'],
  );
});

Deno.test('총괄은 모든 부서 승인 기억을, 명시 참조·연결은 그 기억만 더 받는다', async () => {
  const store = seededStore();
  const lead = await buildThinkContext(store, {
    conversationId: 'c1',
    userMessage: '질문',
    attachments: [],
    access: access({ thinkRoleId: 'lead' }),
  });
  assert(lead.instructions.includes('PRODUCT_DECISION'));
  assert(!lead.instructions.includes('DRAFT_DECISION'));

  const ref = await buildThinkContext(store, {
    conversationId: 'c1',
    userMessage: '질문',
    attachments: [],
    access: access({ thinkRoleId: 'engineering', extraRefDepartments: ['product'] }),
  });
  assert(ref.instructions.includes('PRODUCT_DECISION'));
  assert(!ref.instructions.includes('EDU_DECISION'));

  const linked = await buildThinkContext(store, {
    conversationId: 'c1',
    userMessage: '질문',
    attachments: [],
    access: access({ thinkRoleId: 'engineering', linkedMemoryIds: new Set(['d-edu', 'd-draft']) }),
  });
  assert(linked.instructions.includes('EDU_DECISION'));
  assert(!linked.instructions.includes('DRAFT_DECISION'), '연결해도 미승인 기억은 넣지 않는다');
});

Deno.test('역할 기능이 준비되지 않으면 부서 기억을 빼고 레거시·공통만 쓴다', async () => {
  const store = seededStore();
  const ctx = await buildThinkContext(store, {
    conversationId: 'c1',
    userMessage: '질문',
    attachments: [],
    access: access({ thinkRoleId: 'lead', rolesFeatureReady: false }),
  });
  assert(ctx.instructions.includes('COMMON_PRINCIPLE'));
  assert(!ctx.instructions.includes('EDU_DECISION'));
  assert(!ctx.instructions.includes('PRODUCT_DECISION'));
  assertEquals(ctx.cacheKeySuffix, null);
});

Deno.test('캐시 키 꼬리는 역할·참조·연결이 바뀌면 달라지고 8자다', async () => {
  const store = seededStore();
  const build = (a: ConversationAccessState) =>
    buildThinkContext(store, { conversationId: 'c1', userMessage: '질문', attachments: [], access: a });
  const edu = (await build(access())).cacheKeySuffix!;
  const product = (await build(access({ thinkRoleId: 'product' }))).cacheKeySuffix!;
  const withRef = (await build(access({ extraRefDepartments: ['product'] }))).cacheKeySuffix!;
  const withLink = (await build(access({ linkedMemoryIds: new Set([PRODUCT_ID]) }))).cacheKeySuffix!;
  assertEquals(edu.length, 8);
  assertNotEquals(edu, product);
  assertNotEquals(edu, withRef);
  assertNotEquals(edu, withLink);
  assertEquals((await build(access())).cacheKeySuffix, edu, '같은 범위면 같은 키');
  assert(`think:${crypto.randomUUID()}:${edu}`.length <= 64);
});

Deno.test('search_memories·get_memory는 범위 밖 기억을 없는 기억처럼 다룬다', async () => {
  const store = seededStore();
  const delivered: string[] = [];
  const toolCtx = {
    conversationId: 'c1',
    memoryRefs: [],
    access: access(),
    recordDelivered: (m: { id: string }) => delivered.push(m.id),
  };
  const search = await runThinkTool('search_memories', JSON.stringify({ query: '결정' }), store, 8000, toolCtx);
  assert(search.ok);
  assert(search.output.includes('EDU_DECISION'));
  assert(!search.output.includes('PRODUCT_DECISION'));
  assert(!search.output.includes('DRAFT_DECISION'));

  const hidden = await runThinkTool('get_memory', JSON.stringify({ id: PRODUCT_ID }), store, 8000, toolCtx);
  assert(!hidden.ok);
  assert(hidden.output.includes('not_found'));
  assert(!delivered.includes(PRODUCT_ID), '거절한 기억은 전달 기록에 남기지 않는다');

  const linkedCtx = { ...toolCtx, access: access({ linkedMemoryIds: new Set([PRODUCT_ID]) }) };
  const shown = await runThinkTool('get_memory', JSON.stringify({ id: PRODUCT_ID }), store, 8000, linkedCtx);
  assert(shown.ok);
  assert(delivered.includes(PRODUCT_ID));
});

Deno.test('get_memory는 대화 범위를 모르면 레거시·공통만 준다', async () => {
  const store = seededStore();
  const r = await runThinkTool('get_memory', JSON.stringify({ id: PRODUCT_ID }), store, 8000, {
    conversationId: 'c1',
    memoryRefs: [],
  });
  assert(!r.ok);
});

Deno.test('문서 본문은 연결된 문서만, 문서별·전체 예산 안에서 잘라 넣는다', async () => {
  const store = new MemoryThinkStore();
  const per = CONTEXT_LIMITS.documentBodyChars;
  const total = CONTEXT_LIMITS.documentBodyTotalChars;
  store.linkedDocumentBodies = [
    { id: 'doc-a', title: 'A', body: 'A'.repeat(per + 500) },
    { id: 'doc-b', title: 'B', body: 'B'.repeat(per) },
    { id: 'doc-c', title: 'C', body: 'C'.repeat(100) },
    { id: 'doc-unlinked', title: 'U', body: 'UNLINKED_BODY' },
  ];
  const ctx = await buildThinkContext(store, {
    conversationId: 'c1',
    userMessage: '질문',
    attachments: [],
    access: access({ linkedDocumentNodeIds: new Set(['doc-a', 'doc-b', 'doc-c']) }),
  });
  const docs = ctx.deliveredMaterials.filter((m) => m.kind === 'document');
  const sum = docs.reduce((n, d) => n + (d.excerpt_chars ?? 0), 0);
  assert(sum <= total, `전체 예산 ${sum} <= ${total}`);
  assertEquals(docs[0].id, 'doc-a');
  assertEquals(docs[0].truncated, true);
  assertEquals(docs[0].excerpt_chars, per);
  assert(!docs.some((d) => d.id === 'doc-unlinked'));
  assert(!JSON.stringify(ctx.input).includes('UNLINKED_BODY'));
});

Deno.test('연결이 끊긴(접근 범위에서 빠진) 문서는 본문을 넣지 않는다', async () => {
  const store = new MemoryThinkStore();
  store.linkedDocumentBodies = [{ id: 'doc-a', title: 'A', body: 'REVOKED_BODY' }];
  const ctx = await buildThinkContext(store, {
    conversationId: 'c1',
    userMessage: '질문',
    attachments: [],
    access: access({ linkedDocumentNodeIds: new Set() }),
  });
  assert(!JSON.stringify(ctx.input).includes('REVOKED_BODY'));
  assertEquals(ctx.linkedDocumentIds, []);
});

Deno.test('새 대화에서 고른 역할을 첫 답변 전에 저장하고 스냅샷·이벤트·기록에 남긴다', async () => {
  const store = seededStore();
  const provider = new FakeAiProvider((req) => (isTitle(req) ? { text: '진도' } : { text: '답변' }));
  const events = new EventLog();
  const runs = new RunLog();
  const out = await runThinkChat(
    chatInput({ features: READY, newConversationRole: { thinkRoleId: 'education', extraRefDepartments: [] } }),
    { provider, store, recordRun: runs.record, emit: events.emit, env: testEnv },
  );
  assertEquals(out.status, 'complete');
  assertEquals(store.roleCalls.map((c) => c.role), ['education']);
  const main = provider.requests.find((r) => !isTitle(r))!;
  assert(main.instructions!.includes('EDU_DECISION'));
  assert(!main.instructions!.includes('PRODUCT_DECISION'));
  assert(/^think:[^:]+:[0-9a-f]{8}$/.test(main.cacheKey ?? ''), main.cacheKey);

  const conv = events.of('conversation')[0];
  assertEquals((conv.think_role as { id: string }).id, 'education');
  assertEquals(store.snapshots.length, 1);
  assertEquals(store.snapshots[0].thinkRoleId, 'education');
  assert(store.snapshots[0].roleProfileVersion);
  assert(store.snapshots[0].materials.every((m) => m.delivered));
  assert(store.snapshots[0].materials.some((m) => m.id === 'd-edu'));
  assert(!store.snapshots[0].materials.some((m) => m.id === PRODUCT_ID));
  assert(runs.runs.find((r) => r.feature === 'think_chat')!.roleProfileVersion);
});

Deno.test('역할 저장에 실패하면 총괄로 답하고 알린다', async () => {
  const store = seededStore();
  store.setRoleFailure = 'boom';
  const provider = new FakeAiProvider((req) => (isTitle(req) ? { text: '제목' } : { text: '답변' }));
  const events = new EventLog();
  await runThinkChat(
    chatInput({ features: READY, newConversationRole: { thinkRoleId: 'product', extraRefDepartments: [] } }),
    { provider, store, recordRun: new RunLog().record, emit: events.emit, env: testEnv },
  );
  assert(events.of('notice').some((n) => n.code === 'role_not_applied'));
  assertEquals((events.of('conversation')[0].think_role as { id: string }).id, 'lead');
});

Deno.test('구버전 앱(think_roles 미신고)은 역할을 저장하지 않고 스냅샷도 남기지 않는다', async () => {
  const store = seededStore();
  const provider = new FakeAiProvider((req) => (isTitle(req) ? { text: '제목' } : { text: '답변' }));
  const events = new EventLog();
  const runs = new RunLog();
  await runThinkChat(
    chatInput({ features: OLD_APP, newConversationRole: { thinkRoleId: 'education', extraRefDepartments: [] } }),
    { provider, store, recordRun: runs.record, emit: events.emit, env: testEnv },
  );
  assertEquals(store.roleCalls, []);
  assertEquals(store.snapshots, []);
  assertEquals(events.of('conversation')[0].think_role, null);
  const main = provider.requests.find((r) => !isTitle(r))!;
  assert(!main.instructions!.includes('EDU_DECISION'));
  assert(!main.instructions!.includes('PRODUCT_DECISION'));
  assert(main.instructions!.includes('COMMON_PRINCIPLE'));
  assertEquals(runs.runs.find((r) => r.feature === 'think_chat')!.roleProfileVersion, null);
});

Deno.test('이어지는 대화는 요청의 역할이 아니라 저장된 역할을 쓴다', async () => {
  const store = seededStore();
  const conv = await store.createConversation('기존');
  store.accessByConversation.set(conv.id, access({ conversationId: conv.id, thinkRoleId: 'product' }));
  const provider = new FakeAiProvider([{ text: '답변' }]);
  const events = new EventLog();
  await runThinkChat(
    chatInput({
      conversationId: conv.id,
      features: READY,
      newConversationRole: { thinkRoleId: 'education', extraRefDepartments: [] },
    }),
    { provider, store, recordRun: new RunLog().record, emit: events.emit, env: testEnv },
  );
  assertEquals(store.roleCalls, []);
  assertEquals((events.of('conversation')[0].think_role as { id: string }).id, 'product');
  assert(provider.requests[0].instructions!.includes('PRODUCT_DECISION'));
  assert(!provider.requests[0].instructions!.includes('EDU_DECISION'));
});

Deno.test('결정 초안은 대화에 저장된 역할 범위의 기억만 AI에 넣는다', async () => {
  const store = seededStore();
  const conv = await store.createConversation('초안');
  store.accessByConversation.set(conv.id, access({ conversationId: conv.id, thinkRoleId: 'education' }));
  await store.insertMessage({ conversation_id: conv.id, role: 'user', content: '정할 것', status: 'complete' });
  const provider = new FakeAiProvider();
  const out = await createDecisionDraft(
    { provider, store, recordRun: new RunLog().record, env: testEnv },
    { conversationId: conv.id, userId: 'u', safetyId: 'h' },
  );
  assert(out.ok);
  const blob = JSON.stringify(provider.requests[0]);
  assert(blob.includes('EDU_DECISION'));
  assert(!blob.includes('PRODUCT_DECISION'));
});

Deno.test('스펙 내보내기는 원본 대화 역할 범위의 원칙만 참고로 넣는다', async () => {
  const store = new MemoryThinkStore();
  const conv = await store.createConversation('스펙');
  store.accessByConversation.set(conv.id, access({ conversationId: conv.id, thinkRoleId: 'engineering' }));
  store.memories.push(
    memory({
      id: 'p-edu',
      kind: 'principle',
      title: '교육 원칙',
      content: 'EDU_PRINCIPLE',
      memory_scope: 'department',
      scope_department: 'education',
    }),
    memory({ id: 'p-common', kind: 'principle', title: '공통', content: 'COMMON_PRINCIPLE', memory_scope: 'common' }),
    {
      ...memory({ id: 'dec', kind: 'decision', title: '결정', content: '본문' }),
      source_conversation_id: conv.id,
      approved_at: '2026-10-10T00:00:00Z',
    },
  );
  const provider = new FakeAiProvider([{ text: '# spec\n\nbody' }]);
  const out = await createSpecExport(
    { provider, store, recordRun: new RunLog().record, env: testEnv },
    { memoryId: 'dec', userId: 'u', safetyId: 'h' },
  );
  assert(out.ok);
  const blob = JSON.stringify(provider.requests[0]);
  assert(blob.includes('COMMON_PRINCIPLE'));
  assert(!blob.includes('EDU_PRINCIPLE'));
});

function rpcDb(handler: (fn: string, args: Record<string, unknown>) => { data: unknown; error: unknown }) {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  const db = {
    from: () => {
      throw new Error('unexpected table access');
    },
    rpc: (fn: string, args: Record<string, unknown>) => {
      calls.push({ fn, args });
      return Promise.resolve(handler(fn, args));
    },
    storage: { from: () => ({}) },
  } as unknown as SupabaseLike;
  return { db, calls };
}

const ROW = {
  id: 'm1',
  kind: 'decision',
  status: 'active',
  title: 't',
  content: 'c',
  memory_scope: 'department',
  scope_department: 'education',
};

Deno.test('store.searchMemories는 범위 RPC에 역할·참조·연결을 넘긴다', async () => {
  const { db, calls } = rpcDb(() => ({ data: [ROW], error: null }));
  const rows = await new SupabaseThinkStore(db).searchMemories(['진도'], 8, {
    mode: 'engineering',
    extraRefs: ['education'],
    linkedIds: ['x'],
  });
  assertEquals(calls.map((c) => c.fn), ['ai_search_memories_scoped']);
  assertEquals(calls[0].args.p_mode, 'engineering');
  assertEquals(calls[0].args.p_extra_refs, ['education']);
  assertEquals(calls[0].args.p_linked_ids, ['x']);
  assertEquals(rows[0].memory_scope, 'department');
});

Deno.test('범위 RPC가 없는 DB는 기존 검색으로 내려가고, 다른 오류는 숨기지 않는다', async () => {
  const missing = rpcDb((fn) =>
    fn === 'ai_search_memories_scoped'
      ? { data: null, error: { code: 'PGRST202', message: 'Could not find the function' } }
      : { data: [{ ...ROW, memory_scope: undefined, scope_department: undefined }], error: null }
  );
  const rows = await new SupabaseThinkStore(missing.db).searchMemories(['진도'], 8);
  assertEquals(missing.calls.map((c) => c.fn), ['ai_search_memories_scoped', 'ai_search_memories']);
  assertEquals(rows.length, 1);

  const broken = rpcDb(() => ({ data: null, error: { code: '42501', message: 'permission denied' } }));
  let threw = false;
  try {
    await new SupabaseThinkStore(broken.db).searchMemories(['진도'], 8);
  } catch {
    threw = true;
  }
  assert(threw);
  assertEquals(broken.calls.length, 1);
});

Deno.test('think_roles 기능 상태: DB 미반영·앱 미신고·준비', () => {
  const dbMissing = computeFeatures({ ok: true, features: { conversation_split: 1 } }, { think_roles: 1 }, true);
  assertEquals(dbMissing.think_roles.state, 'db_required');
  assertEquals(OLD_APP.think_roles.state, 'app_update_required');
  assertEquals(READY.think_roles.state, 'ready');
  const unknown = computeFeatures({ ok: false, missing: false, error: 'timeout' }, { think_roles: 1 }, true);
  assertEquals(unknown.think_roles.state, 'unknown');
});
