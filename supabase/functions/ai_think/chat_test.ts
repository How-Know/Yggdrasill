import { assert, assertEquals, assertExists } from 'jsr:@std/assert@1';
import { FakeAiProvider } from '../_shared/ai/fake.ts';
import type { AiRequest } from '../_shared/ai/types.ts';
import { runThinkChat, type ChatInput } from './chat.ts';
import { titleInstructions } from './prompts.ts';
import { EventLog, MemoryThinkStore, RunLog, memory, testEnv } from './test_support.ts';

function chatInput(partial: Partial<ChatInput> = {}): ChatInput {
  return {
    userId: 'user-1',
    safetyId: 'hash',
    conversationId: null,
    message: '반복 사고 원칙을 커리큘럼에 어떻게 반영할까?',
    attachments: [],
    deep: false,
    webSearch: false,
    signal: new AbortController().signal,
    startedAt: Date.now(),
    wallClockMs: 140000,
    ...partial,
  };
}

const isTitle = (req: AiRequest) => req.instructions === titleInstructions();

Deno.test('도구 호출 후 최종 답변: 메시지·도구 기록·비용이 저장된다', async () => {
  const store = new MemoryThinkStore();
  store.memories.push(
    memory({ id: 'm-identity', kind: 'identity', title: '교육철학', content: '학생은 유형이 아니라 좌표' }),
    memory({ id: 'm-decision', kind: 'decision', title: '반복 사고 우선', content: '반복 사고를 먼저 훈련한다' }),
  );
  let mainCalls = 0;
  const provider = new FakeAiProvider((req) => {
    if (isTitle(req)) return { text: '반복 사고 반영' };
    mainCalls += 1;
    if (mainCalls === 1) {
      return {
        commentary: '기존 결정을 확인하겠습니다.',
        functionCalls: [{ name: 'search_memories', arguments: { query: '반복 사고', kinds: ['decision'] } }],
        usage: { inputTokens: 2000, cachedInputTokens: 1000, outputTokens: 100 },
      };
    }
    return { text: '결론: 단원마다 반복 사고 과제를 둔다.', usage: { inputTokens: 2500, outputTokens: 300 } };
  });
  const runs = new RunLog();
  const events = new EventLog();

  const out = await runThinkChat(chatInput(), { provider, store, recordRun: runs.record, emit: events.emit, env: testEnv });

  assertEquals(out.status, 'complete');
  assertExists(out.conversationId);
  assertEquals(mainCalls, 2);

  // 두 번째 호출에는 첫 호출의 출력 항목과 도구 결과가 그대로 들어간다.
  const second = provider.requests.filter((r) => !isTitle(r))[1];
  assert(second.input.some((i) => i.kind === 'provider_items'));
  assert(second.input.some((i) => i.kind === 'tool_result'));
  assertEquals(second.cacheKey, `think:${out.conversationId}`);

  const saved = store.messages.filter((m) => m.conversation_id === out.conversationId);
  assertEquals(saved.map((m) => m.role), ['user', 'assistant']);
  const assistant = saved[1].extra!;
  assertEquals(assistant.status, 'complete');
  assert(assistant.content.length > 0);
  assertEquals(assistant.tool_calls?.map((t) => t.name), ['search_memories']);
  assert((assistant.commentary ?? '').length > 0);
  assertEquals(assistant.run_id, 'run-2');

  const chatRun = runs.runs.find((r) => r.feature === 'think_chat')!;
  assertEquals(chatRun.status, 'ok');
  assertEquals(chatRun.toolCalls, 1);
  assertEquals(chatRun.usage.inputTokens, 4500);
  assert(chatRun.costUsd !== null && chatRun.costUsd > 0);
  assert(runs.runs.some((r) => r.feature === 'think_title'));

  const names = events.names();
  assertEquals(names[0], 'conversation');
  assert(names.includes('tool'));
  assert(names.includes('delta'));
  assertEquals(names.at(-1), 'done');
  assertEquals(events.of('title').length, 1);
});

Deno.test('지시문에는 확정된 철학·원칙이, 관련 기억은 이번 질문 바로 앞에 들어간다', async () => {
  const store = new MemoryThinkStore();
  store.memories.push(
    memory({ id: 'm-identity', kind: 'identity', title: '교육철학', content: 'IDENTITY_TEXT' }),
    memory({ id: 'm-principle', kind: 'principle', title: '원칙A', content: 'PRINCIPLE_TEXT' }),
    memory({ id: 'm-note', kind: 'note', title: '커리큘럼 메모', content: '커리큘럼 반영 순서 메모' }),
    memory({ id: 'm-draft', kind: 'principle', status: 'draft', title: '초안 원칙', content: 'DRAFT_TEXT' }),
  );
  const provider = new FakeAiProvider((req) => (isTitle(req) ? { text: '제목' } : { text: '답변' }));
  await runThinkChat(chatInput(), { provider, store, recordRun: new RunLog().record, emit: new EventLog().emit, env: testEnv });

  const main = provider.requests.find((r) => !isTitle(r))!;
  assert(main.instructions!.includes('IDENTITY_TEXT'));
  assert(main.instructions!.includes('PRINCIPLE_TEXT'));
  assert(!main.instructions!.includes('DRAFT_TEXT'), '초안 원칙은 지시문에 넣지 않는다');
  const last = main.input.at(-1)!;
  const beforeLast = main.input.at(-2)!;
  assertEquals(last.kind, 'message');
  assertEquals(beforeLast.kind, 'context');
  assert(beforeLast.kind === 'context' && beforeLast.text.includes('m-note'));
});

Deno.test('기존 대화는 지난 메시지를 넣고, 이번 질문은 중복되지 않는다', async () => {
  const store = new MemoryThinkStore();
  const conv = await store.createConversation('기존 대화');
  await store.insertMessage({ conversation_id: conv.id, role: 'user', content: '첫 질문', status: 'complete' });
  await store.insertMessage({ conversation_id: conv.id, role: 'assistant', content: '첫 답변', status: 'complete' });
  await store.insertMessage({ conversation_id: conv.id, role: 'assistant', content: '오류', status: 'error' });
  const provider = new FakeAiProvider([{ text: '두 번째 답변' }]);

  const out = await runThinkChat(chatInput({ conversationId: conv.id, message: '두 번째 질문' }), {
    provider,
    store,
    recordRun: new RunLog().record,
    emit: new EventLog().emit,
    env: testEnv,
  });

  assertEquals(out.status, 'complete');
  assertEquals(provider.requests.length, 1, '기존 대화는 제목을 다시 만들지 않는다');
  const texts = provider.requests[0].input
    .filter((i) => i.kind === 'message')
    .map((i) => (i.kind === 'message' ? i.parts.map((p) => (p.type === 'text' ? p.text : '')).join('') : ''));
  assertEquals(texts, ['첫 질문', '첫 답변', '두 번째 질문']);
});

Deno.test('없는 대화 id면 오류 이벤트만 보내고 저장하지 않는다', async () => {
  const store = new MemoryThinkStore();
  const events = new EventLog();
  const out = await runThinkChat(chatInput({ conversationId: '00000000-0000-0000-0000-000000000000' }), {
    provider: new FakeAiProvider(),
    store,
    recordRun: new RunLog().record,
    emit: events.emit,
    env: testEnv,
  });
  assertEquals(out.status, 'error');
  assertEquals(out.errorCode, 'conversation_not_found');
  assertEquals(store.messages.length, 0);
  assertEquals(events.names(), ['error']);
});

Deno.test('AI 호출이 실패해도 사용자 메시지와 오류 상태·기록이 남는다', async () => {
  const store = new MemoryThinkStore();
  const runs = new RunLog();
  const events = new EventLog();
  const provider = new FakeAiProvider((req) => (isTitle(req) ? { text: '제목' } : { error: 'upstream down' }));

  const out = await runThinkChat(chatInput(), { provider, store, recordRun: runs.record, emit: events.emit, env: testEnv });

  assertEquals(out.status, 'error');
  assertEquals(store.messages.map((m) => m.role), ['user', 'assistant']);
  assertEquals(store.messages[1].status, 'error');
  assertEquals(runs.runs.find((r) => r.feature === 'think_chat')?.status, 'error');
  assertEquals(events.names().at(-1), 'error');
});

Deno.test('사용자가 중단하면 받은 부분까지 stopped로 저장한다', async () => {
  const store = new MemoryThinkStore();
  const runs = new RunLog();
  const controller = new AbortController();
  const events = new EventLog();
  let deltas = 0;
  const provider = new FakeAiProvider((req) =>
    isTitle(req) ? { text: '제목' } : { text: '아주 긴 답변이 조금씩 흘러나오는 중입니다. 계속 이어집니다.', delayMs: 1 }
  );
  const emit = (event: string, data: Record<string, unknown>) => {
    events.emit(event, data);
    if (event === 'delta' && ++deltas === 2) controller.abort('client_closed');
  };

  const out = await runThinkChat(chatInput({ signal: controller.signal }), { provider, store, recordRun: runs.record, emit, env: testEnv });

  assertEquals(out.status, 'stopped');
  const assistant = store.messages.find((m) => m.role === 'assistant');
  assertExists(assistant);
  assertEquals(assistant.status, 'stopped');
  assert(assistant.content.length > 0);
  assertEquals(runs.runs.find((r) => r.feature === 'think_chat')?.status, 'stopped');
});

Deno.test('도구 반복이 끝나지 않으면 마지막 회차는 도구 없이 답하게 한다', async () => {
  const store = new MemoryThinkStore();
  const provider = new FakeAiProvider((req) => {
    if (isTitle(req)) return { text: '제목' };
    if (req.toolChoice === 'none') return { text: '지금까지 확인한 내용으로 답합니다.' };
    return { functionCalls: [{ name: 'list_concept_categories', arguments: { parent_id: null } }] };
  });
  const out = await runThinkChat(chatInput(), { provider, store, recordRun: new RunLog().record, emit: new EventLog().emit, env: testEnv });
  assertEquals(out.status, 'complete');
  const main = provider.requests.filter((r) => !isTitle(r));
  assertEquals(main.at(-1)?.toolChoice, 'none');
});
