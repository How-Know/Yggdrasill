// 종합 문서: list_tree_folders·트리 조회에는 본문 없음. buildThinkContext는 대화에 명시 연결된 문서 본문만 넣는다.
import { assert, assertEquals } from 'jsr:@std/assert@1';
import { FakeAiProvider } from '../_shared/ai/fake.ts';
import { dispatchActionTool } from './actions.ts';
import { buildThinkContext } from './context.ts';
import { createDecisionDraft, createSpecExport } from './drafts.ts';
import { SupabaseThinkStore, type SupabaseLike } from './store.ts';
import { MK_CTX_EXCL, MK_DOC_BODY, MK_SRC_MSG } from './document_markers.ts';
import { MemoryThinkStore, RunLog, memory, testEnv } from './test_support.ts';

type Call = [string, ...unknown[]];

function recordingDb(rows: Record<string, unknown>[]): { db: SupabaseLike; calls: Call[] } {
  const calls: Call[] = [];
  const builder: Record<string, unknown> = new Proxy({}, {
    get(_t, prop: string) {
      if (prop === 'then') {
        return (resolve: (v: unknown) => void) => resolve({ data: rows, error: null });
      }
      return (...args: unknown[]) => {
        calls.push([prop, ...args]);
        return builder;
      };
    },
  });
  const db: SupabaseLike = {
    from: (table: string) => {
      calls.push(['from', table]);
      return builder;
    },
    rpc: () => builder,
    storage: { from: () => builder },
  };
  return { db, calls };
}

Deno.test('listTreeFolders는 body·summary·출처 원문 컬럼을 조회하지 않는다', async () => {
  const { db, calls } = recordingDb([
    {
      id: 'n1',
      parent_id: null,
      kind: 'document',
      conversation_id: 'c1',
      title: '제목',
      body: MK_DOC_BODY,
      summary: '요약',
    },
  ]);
  await new SupabaseThinkStore(db).listTreeFolders();
  const selects = calls.filter((c) => c[0] === 'select').map((c) => String(c[1]));
  assert(selects.some((s) => s === 'id,parent_id,title'), 'folder select');
  assert(selects.some((s) => s === 'parent_id,kind,conversation_id'), 'non-folder select');
  assert(!selects.some((s) => s.includes('body') || s.includes('summary')), 'document 본문·요약 컬럼 미조회');
});

Deno.test('list_tree_folders 응답에 종합 문서 본문·출처 메시지 원문 마커가 없다', async () => {
  const store = new MemoryThinkStore();
  const conv = await store.createConversation('분류');
  store.folders.push({ id: 'f1', parent_id: null, title: '폴더' });
  store.treeItems.push({ parent_id: 'f1', kind: 'document', conversation_id: conv.id });
  await store.insertMessage({
    conversation_id: conv.id,
    role: 'user',
    content: MK_SRC_MSG,
    status: 'complete',
  });
  const r = await dispatchActionTool('list_tree_folders', {}, store, { conversationId: conv.id, memoryRefs: [] });
  assert(r.ok);
  assert(!r.output.includes(MK_DOC_BODY), '종합 문서 본문 마커');
  assert(!r.output.includes(MK_SRC_MSG), '출처 메시지 원문은 트리 도구에 넣지 않는다');
});

Deno.test('명시 연결된 종합 문서 본문만 buildThinkContext에 들어간다', async () => {
  const store = new MemoryThinkStore();
  const conv = await store.createConversation('문서');
  store.linkedDocumentBodies = [{ id: 'doc-1', title: '종합', body: MK_DOC_BODY }];
  const access = {
    conversationId: conv.id,
    thinkRoleId: 'lead' as const,
    extraRefDepartments: [],
    linkedMemoryIds: new Set<string>(),
    linkedDocumentNodeIds: new Set(['doc-1']),
    rolesFeatureReady: true,
  };
  store.listLinkedDocumentBodies = async (_cid, allowed) =>
    store.linkedDocumentBodies.filter((d) => allowed.has(d.id));
  const ctx = await buildThinkContext(store, {
    conversationId: conv.id,
    userMessage: '질문',
    attachments: [],
    access,
  });
  const blob = JSON.stringify(ctx.input);
  assert(blob.includes(MK_DOC_BODY));
  assertEquals(ctx.linkedDocumentIds, ['doc-1']);
});

Deno.test('출처로 연결된 일반 메시지는 context_excluded가 아니면 채팅 맥락에 남는다(문서 본문과 별개)', async () => {
  const store = new MemoryThinkStore();
  const conv = await store.createConversation('출처');
  await store.insertMessage({ conversation_id: conv.id, role: 'user', content: MK_SRC_MSG, status: 'complete' });
  await store.insertMessage({ conversation_id: conv.id, role: 'assistant', content: '답', status: 'complete' });
  store.treeItems.push({ parent_id: null, kind: 'document', conversation_id: conv.id });

  const ctx = await buildThinkContext(store, { conversationId: conv.id, userMessage: '질문', attachments: [] });
  const blob = JSON.stringify(ctx.input);
  assert(blob.includes(MK_SRC_MSG), '출처 연결만으로 일반 메시지를 빼지 않는다');
  assert(!blob.includes(MK_DOC_BODY), '문서 본문은 Edge가 조회하지 않아 맥락에 없다');
});

Deno.test('context_excluded 메시지는 채팅 맥락에 넣지 않는다', async () => {
  const store = new MemoryThinkStore();
  const conv = await store.createConversation('제외');
  await store.insertMessage({ conversation_id: conv.id, role: 'user', content: '남김', status: 'complete' });
  await store.insertMessage({ conversation_id: conv.id, role: 'assistant', content: '남김', status: 'complete' });
  await store.insertMessage({ conversation_id: conv.id, role: 'user', content: MK_CTX_EXCL, status: 'complete' });
  for (const m of store.messages.slice(2)) m.excluded = true;

  const ctx = await buildThinkContext(store, { conversationId: conv.id, userMessage: '질문', attachments: [] });
  const blob = JSON.stringify(ctx.input);
  assert(!blob.includes(MK_CTX_EXCL));
});

Deno.test('context_excluded 메시지는 결정 초안 AI 입력에 넣지 않는다', async () => {
  const store = new MemoryThinkStore();
  const conv = await store.createConversation('초안');
  await store.insertMessage({ conversation_id: conv.id, role: 'user', content: '결정할 내용', status: 'complete' });
  await store.insertMessage({ conversation_id: conv.id, role: 'assistant', content: '확인', status: 'complete' });
  await store.insertMessage({ conversation_id: conv.id, role: 'user', content: MK_CTX_EXCL, status: 'complete' });
  for (const m of store.messages.slice(2)) m.excluded = true;

  const provider = new FakeAiProvider();
  const out = await createDecisionDraft(
    { provider, store, recordRun: new RunLog().record, env: testEnv },
    { conversationId: conv.id, userId: 'u', safetyId: 'h' },
  );
  assert(out.ok);
  const blob = JSON.stringify(provider.requests[0].input);
  assert(blob.includes('결정할 내용'));
  assert(!blob.includes(MK_CTX_EXCL));
});

Deno.test('context_excluded 메시지는 스펙 내보내기 참고 대화에 넣지 않는다', async () => {
  const store = new MemoryThinkStore();
  const conv = await store.createConversation('스펙');
  await store.insertMessage({ conversation_id: conv.id, role: 'user', content: '참고 대화', status: 'complete' });
  await store.insertMessage({ conversation_id: conv.id, role: 'user', content: MK_CTX_EXCL, status: 'complete' });
  store.messages[1].excluded = true;
  store.memories.push({
    ...memory({ id: 'd1', kind: 'decision', title: '결정', content: '본문' }),
    source_conversation_id: conv.id,
    approved_at: '2026-10-07T00:00:00Z',
  });

  const provider = new FakeAiProvider([{ text: '# spec\n\nbody' }]);
  const out = await createSpecExport(
    { provider, store, recordRun: new RunLog().record, env: testEnv },
    { memoryId: 'd1', userId: 'u', safetyId: 'h' },
  );
  assert(out.ok);
  const blob = JSON.stringify(provider.requests[0].input);
  assert(blob.includes('참고 대화'));
  assert(!blob.includes(MK_CTX_EXCL));
});
