import { assert, assertEquals } from 'jsr:@std/assert@1';
import { FakeAiProvider } from '../_shared/ai/fake.ts';
import type { AiRequest } from '../_shared/ai/types.ts';
import { MEMORY_RETIRE_TOOL_NAME, MEMORY_TOOL_NAME, restoredContextNote } from './actions.ts';
import { runThinkChat, type ChatInput } from './chat.ts';
import { computeFeatures } from './features.ts';
import { runThinkTool } from './tools.ts';
import { EventLog, MemoryThinkStore, RunLog, memory, testEnv } from './test_support.ts';

const READY = computeFeatures(
  { ok: true, features: { conversation_split: 1, think_roles: 1, memory_proposals: 1 } },
  { conversation_split: 1, think_roles: 1, memory_proposals: 1 },
  true,
);

const READ_ID = '55555555-5555-4555-8555-555555555555';

Deno.test('복원 안내는 없음·못 찾음·실패를 구분하고, 대기 카드를 확정으로 말하지 않는다', () => {
  assert(restoredContextNote({ status: 'empty', title: '앞 대화' }).includes('없다'));
  assert(restoredContextNote({ status: 'not_found' }).includes('찾지 못했다'));
  assert(restoredContextNote({ status: 'error' }).includes('읽지 못했다'));
  assert(!restoredContextNote({ status: 'not_found' }).includes('없다'));
  const ok = restoredContextNote({
    status: 'ok',
    title: '앞 작업',
    purpose: '숙제 시간',
    decided: ['10분'],
    workNote: '[이 대화의 작업 상태. 승인 대기]',
  });
  assert(ok.includes('복사하지 않았다'));
  assert(ok.includes('확정 지침이 아니다'));
  assert(ok.includes('숙제 시간'));
});

Deno.test('고른 대화의 요약은 다음 답변의 참고로만 들어가고, 이 대화의 진행 요약은 바뀌지 않는다', async () => {
  const store = new MemoryThinkStore();
  const source = await store.createConversation('앞 작업');
  source.progress_summary = {
    purpose: '숙제 시간',
    decided: ['10분'],
    open: [],
    status: '진행',
    next: [],
    approved_at: '2026-10-27T00:00:00Z',
  };
  const current = await store.createConversation('새 대화');
  current.context_from_conversation_id = source.id;
  await store.insertMessage({ conversation_id: current.id, role: 'user', content: '이어서', status: 'complete' });
  const provider = new FakeAiProvider(() => ({ text: '이어서 답한다' }));
  const input: ChatInput = {
    userId: 'user-1',
    safetyId: 'hash',
    conversationId: current.id,
    message: '앞에서 정한 숙제 시간으로 이어 가자',
    features: READY,
    attachments: [],
    deep: false,
    webSearch: false,
    signal: new AbortController().signal,
    startedAt: Date.now(),
    wallClockMs: 140000,
  };
  await runThinkChat(input, { provider, store, recordRun: new RunLog().record, emit: new EventLog().emit, env: testEnv });
  const texts = (provider.requests[0] as AiRequest).input
    .flatMap((item) => ('parts' in item && item.parts ? item.parts : []))
    .map((part) => ('text' in part ? part.text : ''))
    .join('\n');
  const contextTexts = (provider.requests[0] as AiRequest).input
    .map((item) => ('text' in item && typeof item.text === 'string' ? item.text : ''))
    .join('\n');
  const blob = `${texts}\n${contextTexts}`;
  assert(blob.includes('다른 대화 "앞 작업"에서 읽어 온 참고'));
  assert(blob.includes('복사하지 않았다'));
  assertEquals(current.progress_summary, null);
});

Deno.test('생성·수정·보관은 카드로만 제안하고, 서로 기대는 변경은 근본부터 순서대로 낸다', async () => {
  const store = new MemoryThinkStore();
  store.memories.push(memory({ id: READ_ID, kind: 'principle', title: '근본 원칙', content: '먼저 바뀌어야 하는 내용', version: 3 }));
  const c = { conversationId: 'conv-flow', memoryRefs: [], memory: { proposed: false } };
  const search = await runThinkTool('search_memories', JSON.stringify({ query: 'zzzz없는말', kinds: null }), store, 8000, c);
  assert(search.ok, search.output);
  const read = await runThinkTool('get_memory', JSON.stringify({ id: READ_ID, offset: 0 }), store, 8000, c);
  assert(read.ok, read.output);
  const early = await runThinkTool(
    MEMORY_RETIRE_TOOL_NAME,
    JSON.stringify({ memory_id: READ_ID, reason: '뒤 단계', flow: { key: 'root', step: 2, steps: 2 } }),
    store,
    8000,
    c,
  );
  assert(!early.ok);
  assert(early.output.includes('memory_flow_order'));
  const first = await runThinkTool(
    MEMORY_TOOL_NAME,
    JSON.stringify({
      memory: {
        kind: 'decision',
        title: '근본을 고친 결정',
        content: '먼저 이렇게 바꾼다',
        decision_context: '순서',
        decision_reason: '근본',
        alternatives: [],
        tags: [],
        memory_scope: 'common',
        scope_department: null,
        supersedes_id: READ_ID,
      },
      reason: '사용자가 근본부터 고치자고 했다',
      relation: 'supplement',
      compared_ids: [READ_ID],
      flow: { key: 'root', step: 1, steps: 2 },
    }),
    store,
    8000,
    c,
  );
  assert(first.ok, first.output);
  const second = await runThinkTool(
    MEMORY_RETIRE_TOOL_NAME,
    JSON.stringify({ memory_id: READ_ID, reason: '앞 단계가 승인되면 이 원칙은 보관한다', flow: { key: 'root', step: 2, steps: 2 } }),
    store,
    8000,
    c,
  );
  assert(second.ok, second.output);
  assertEquals(store.actions.map((a) => a.payload.flow && (a.payload.flow as { step: number }).step), [1, 2]);
  assertEquals(store.memories.filter((m) => m.id === READ_ID)[0].status, 'active');
  const extra = await runThinkTool(
    MEMORY_TOOL_NAME,
    JSON.stringify({
      memory: {
        kind: 'principle',
        title: '흐름 밖의 원칙',
        content: '이건 별개다',
        decision_context: null,
        decision_reason: null,
        alternatives: null,
        tags: null,
        memory_scope: 'common',
        scope_department: null,
        supersedes_id: null,
      },
      reason: '별개',
      relation: 'distinct',
      compared_ids: null,
      flow: null,
    }),
    store,
    8000,
    c,
  );
  assert(!extra.ok);
  assert(extra.output.includes('memory_already_proposed'));
});
