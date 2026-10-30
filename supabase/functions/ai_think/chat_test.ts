import { assert, assertEquals, assertExists } from 'jsr:@std/assert@1';
import { FakeAiProvider } from '../_shared/ai/fake.ts';
import type { AiRequest } from '../_shared/ai/types.ts';
import type { AiRunRecord } from '../_shared/ai/usage.ts';
import { MAX_TOOL_ROUNDS, runThinkChat, type ChatInput } from './chat.ts';
import { REVIEW_JOB_TOOL_NAMES } from './concept_review_job_tools.ts';
import { computeFeatures } from './features.ts';
import { THINK_PROMPT_VERSION, featureStatusNote, thinkInstructions, titleInstructions, toolExecutionLimitNote } from './prompts.ts';
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

function toolLoopOf(run: AiRunRecord | undefined) {
  const loop = run?.features?.tool_loop;
  return (loop && typeof loop === 'object' ? loop : null) as {
    no_function_calls: boolean;
    max_rounds: boolean;
    time_budget: boolean;
    skipped_calls: string[];
    incomplete_reason: string | null;
  } | null;
}

const limitNote = (req: AiRequest) =>
  req.input.filter((i) => i.kind === 'context').map((i) => (i.kind === 'context' ? i.text : '')).find((t) => t.startsWith('[이번 회차 도구 실행')) ?? '';

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
  assertEquals(assistant.tool_calls?.[0]?.ok, true);
  assertEquals(toolLoopOf(chatRun), {
    no_function_calls: true, max_rounds: false, time_budget: false, skipped_calls: [], incomplete_reason: null,
  });
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
  const runs = new RunLog();
  const provider = new FakeAiProvider((req) => {
    if (isTitle(req)) return { text: '제목' };
    if (req.toolChoice === 'none') return { text: '지금까지 확인한 내용으로 답합니다.' };
    return { functionCalls: [{ name: 'list_concept_categories', arguments: { parent_id: null } }] };
  });
  const out = await runThinkChat(chatInput({ startedAt: 0, wallClockMs: 140000 }), {
    provider, store, recordRun: runs.record, emit: new EventLog().emit, env: testEnv, now: () => 0,
  });
  assertEquals(out.status, 'complete');
  assertEquals(MAX_TOOL_ROUNDS, 6);
  const main = provider.requests.filter((r) => !isTitle(r));
  assertEquals(main.length, MAX_TOOL_ROUNDS);
  assertEquals(main.at(-1)?.toolChoice, 'none');
  assert(main.slice(0, -1).every((r) => r.toolChoice === 'auto'));
  assert(limitNote(main.at(-1)!).includes('마지막 회차'));
  assert(!limitNote(main.at(-1)!).includes('65%'));
  assert(main.slice(0, -1).every((r) => limitNote(r) === ''));
  assertEquals(toolLoopOf(runs.runs.find((r) => r.feature === 'think_chat')), {
    no_function_calls: true, max_rounds: true, time_budget: false, skipped_calls: [], incomplete_reason: null,
  });
  assertEquals(store.messages.find((m) => m.role === 'assistant')?.extra?.tool_calls?.length, MAX_TOOL_ROUNDS - 1);
});

Deno.test('도구 실행 실패는 성공과 구분되고, 실행하지 않은 호출로 기록되지 않는다', async () => {
  const store = new MemoryThinkStore();
  const runs = new RunLog();
  const provider = new FakeAiProvider((req) => {
    if (isTitle(req)) return { text: '제목' };
    if (req.input.some((i) => i.kind === 'tool_result')) return { text: '검색은 실패했다.' };
    return { functionCalls: [{ name: 'search_memories', arguments: {} }] };
  });
  const out = await runThinkChat(chatInput({ startedAt: 0, wallClockMs: 140000 }), {
    provider, store, recordRun: runs.record, emit: new EventLog().emit, env: testEnv, now: () => 0,
  });
  assertEquals(out.status, 'complete');
  const trace = store.messages.find((m) => m.role === 'assistant')?.extra?.tool_calls?.[0];
  assertEquals(trace?.name, 'search_memories');
  assertEquals(trace?.ok, false);
  assertEquals(runs.runs.find((r) => r.feature === 'think_chat')?.toolCalls, 1);
  assertEquals(toolLoopOf(runs.runs.find((r) => r.feature === 'think_chat')), {
    no_function_calls: true, max_rounds: false, time_budget: false, skipped_calls: [], incomplete_reason: null,
  });
});

Deno.test('제한된 회차의 함수 호출은 실행·성공·실패로 기록하지 않는다', async () => {
  const store = new MemoryThinkStore();
  const runs = new RunLog();
  const events = new EventLog();
  const provider = new FakeAiProvider((req) => {
    if (isTitle(req)) return { text: '제목' };
    if (req.toolChoice === 'none') {
      return { text: '여기서 멈춘다.', functionCalls: [{ name: 'search_memories', arguments: { query: '실행되면 안 됨' } }] };
    }
    return { functionCalls: [{ name: 'list_concept_categories', arguments: { parent_id: null } }] };
  });
  const out = await runThinkChat(chatInput({ startedAt: 0, wallClockMs: 140000 }), {
    provider, store, recordRun: runs.record, emit: events.emit, env: testEnv, now: () => 0,
  });
  assertEquals(out.content, '여기서 멈춘다.');
  const chat = runs.runs.find((r) => r.feature === 'think_chat')!;
  assertEquals(chat.toolCalls, MAX_TOOL_ROUNDS - 1);
  assertEquals(toolLoopOf(chat)?.skipped_calls, ['search_memories']);
  assertEquals(toolLoopOf(chat)?.max_rounds, true);
  const names = store.messages.find((m) => m.role === 'assistant')?.extra?.tool_calls?.map((t) => t.name) ?? [];
  assert(!names.includes('search_memories'));
  assert(!events.of('tool').some((e) => e.name === 'search_memories'));
});

Deno.test('벽시계 65% 경계 전후는 도구 실행과 기록이 다르다', async () => {
  const wall = 100000;
  const soft = Math.floor(wall * 0.65);
  const runAt = async (clock: number) => {
    const store = new MemoryThinkStore();
    const conv = await store.createConversation('시간');
    const runs = new RunLog();
    const provider = new FakeAiProvider((req) => {
      if (req.toolChoice === 'none') {
        return { text: '막힘', functionCalls: [{ name: 'search_memories', arguments: { query: '경계' } }] };
      }
      if (req.input.some((i) => i.kind === 'tool_result')) return { text: '실행함' };
      return { functionCalls: [{ name: 'search_memories', arguments: { query: '경계' } }] };
    });
    await runThinkChat(chatInput({ conversationId: conv.id, startedAt: 0, wallClockMs: wall, message: '질문' }), {
      provider, store, recordRun: runs.record, emit: new EventLog().emit, env: testEnv, now: () => clock,
    });
    return { provider, runs, store };
  };
  const before = await runAt(soft);
  assertEquals(before.provider.requests[0].toolChoice, 'auto');
  assertEquals(limitNote(before.provider.requests[0]), '');
  assertEquals(before.store.messages.find((m) => m.role === 'assistant')?.extra?.tool_calls?.map((t) => t.name), ['search_memories']);
  assertEquals(toolLoopOf(before.runs.runs[0])?.time_budget, false);
  const after = await runAt(soft + 1);
  assertEquals(after.provider.requests[0].toolChoice, 'none');
  assert(limitNote(after.provider.requests[0]).includes('65%'));
  assert(!limitNote(after.provider.requests[0]).includes('마지막 회차'));
  assertEquals(after.store.messages.find((m) => m.role === 'assistant')?.extra?.tool_calls ?? [], []);
  assertEquals(toolLoopOf(after.runs.runs[0]), {
    no_function_calls: false, max_rounds: false, time_budget: true, skipped_calls: ['search_memories'], incomplete_reason: null,
  });
});

Deno.test('모델이 도구 없이 끝낸 것은 서버 제한과 구분되고, 잘림 사유는 따로 남는다', async () => {
  const store = new MemoryThinkStore();
  const conv = await store.createConversation('종료');
  const runs = new RunLog();
  const provider = new FakeAiProvider(() => ({ text: '도구 없이 답한다.', status: 'incomplete', incompleteReason: 'max_output_tokens' }));
  const out = await runThinkChat(chatInput({ conversationId: conv.id, startedAt: 0, wallClockMs: 140000, message: '질문' }), {
    provider, store, recordRun: runs.record, emit: new EventLog().emit, env: testEnv, now: () => 0,
  });
  assertEquals(out.status, 'complete');
  assertEquals(out.content, '도구 없이 답한다.');
  assertEquals(provider.requests[0].toolChoice, 'auto');
  assertEquals(toolLoopOf(runs.runs[0]), {
    no_function_calls: true, max_rounds: false, time_budget: false, skipped_calls: [], incomplete_reason: 'max_output_tokens',
  });

  const emptyStore = new MemoryThinkStore();
  const emptyConv = await emptyStore.createConversation('잘림');
  const emptyRuns = new RunLog();
  const emptyProvider = new FakeAiProvider(() => ({ text: '', status: 'incomplete', incompleteReason: 'max_output_tokens' }));
  const empty = await runThinkChat(chatInput({ conversationId: emptyConv.id, startedAt: 0, wallClockMs: 140000, message: '질문' }), {
    provider: emptyProvider, store: emptyStore, recordRun: emptyRuns.record, emit: new EventLog().emit, env: testEnv, now: () => 0,
  });
  assertEquals(empty.status, 'error');
  assertEquals(empty.errorCode, 'incomplete');
  assertEquals(toolLoopOf(emptyRuns.runs[0])?.incomplete_reason, 'max_output_tokens');
  assertEquals(toolLoopOf(emptyRuns.runs[0])?.max_rounds, false);
  assertEquals(emptyStore.messages.find((m) => m.role === 'assistant')?.extra?.tool_calls ?? [], []);
});

Deno.test('저장 성공 뒤 제출 호출이 없으면 제출로 기록하지 않고 자동 제출하지 않는다', async () => {
  const store = new MemoryThinkStore();
  const conv = await store.createConversation('검수');
  const features = computeFeatures(
    { ok: true, features: { course_map_actions: 1, concept_review: 1, concept_review_jobs: 1 } },
    { course_map_actions: 1, concept_review: 1 },
    true,
  );
  const rpcs: string[] = [];
  const orig = store.reviewJobRpc.bind(store);
  store.reviewJobRpc = (fn, args) => {
    rpcs.push(fn);
    return orig(fn, args);
  };
  store.reviewJobData.set('concept_review_job_claim', { gen: 3 });
  store.reviewJobData.set('concept_review_job_save', { items: [{ position: 1, status: 'saved' }], saved: 1, checkpoint: 1 });
  store.reviewJobData.set('concept_review_job_submit', { submitted: true, action_ids: ['should-not'] });
  const answer = '위치 1을 저장했다. 카드는 내지 않았다.';
  let main = 0;
  const provider = new FakeAiProvider((req) => {
    main += 1;
    if (main === 1) {
      return {
        functionCalls: [{
          name: 'save_concept_review_progress',
          arguments: { job_id: 'abababab-0000-4000-8000-000000000001', items: [{ position: 1 }] },
        }],
      };
    }
    return { text: answer };
  });
  const runs = new RunLog();
  const out = await runThinkChat(chatInput({
    conversationId: conv.id,
    features,
    message: '1번만 저장해. 다른 위치 초안은 제출하지 마.',
    startedAt: 0,
    wallClockMs: 140000,
  }), { provider, store, recordRun: runs.record, emit: new EventLog().emit, env: testEnv, now: () => 0 });
  assertEquals(out.status, 'complete');
  assertEquals(out.content, answer);
  assertEquals(main, 2);
  assertEquals(rpcs, ['concept_review_job_claim', 'concept_review_job_save']);
  assertEquals(
    store.messages.find((m) => m.role === 'assistant')?.extra?.tool_calls?.map((t) => [t.name, t.ok]),
    [['save_concept_review_progress', true]],
  );
  assertEquals(toolLoopOf(runs.runs.find((r) => r.feature === 'think_chat'))?.skipped_calls, []);
  const req = provider.requests[0];
  for (const n of REVIEW_JOB_TOOL_NAMES) assert((req.tools ?? []).some((t) => t.name === n), n);
  const note = req.input.filter((i) => i.kind === 'context').map((i) => (i.kind === 'context' ? i.text : '')).find((t) => t.startsWith('[실행 환경 기능 상태')) ?? '';
  assert(note.includes('save_concept_review_progress'));
  assert(note.includes('submit_concept_review_drafts'));
  assert(note.includes('설치된 기능'));
  assert(!note.includes('65%'));
});

Deno.test('지시문은 설치 상태와 실행 제한을 나누고, 근거 없는 기능 부재를 말하라고 하지 않는다', () => {
  assertEquals(THINK_PROMPT_VERSION, 'think-2026-10-30b');
  const text = thinkInstructions({
    identity: [], principles: [], decisions: [], today: '2026-10-30',
    limits: { identityChars: 100, principleChars: 100, decisionChars: 100 },
    courseMapReady: true, conceptReviewReady: true, conceptReviewJobsReady: true, conceptReviewBatchReady: true,
  });
  assert(text.includes('호출하지 않음'));
  assert(text.includes('서버가 이번 회차의 도구 실행을 막음'));
  assert(text.includes('저장 성공은 제출이 아니다'));
  assert(text.includes('그 안내가 없으면 기능이 없다, 권한이 없다, 호출 한도에 걸렸다는 이유를 만들지 않는다.'));
  assert(!text.includes('추가 실행을 할 수 없다'));
  assert(!text.includes('현재 기능을 사용할 수 없다'));
  const note = featureStatusNote({
    splitState: 'ready', courseMapState: 'ready', conceptReviewState: 'ready',
    conceptReviewJobState: 'ready', conceptReviewBatchState: 'ready', isNew: false, suppressed: false, userAsked: false,
  });
  for (const n of REVIEW_JOB_TOOL_NAMES) assert(note.includes(n), n);
  const limit = toolExecutionLimitNote({ maxRounds: true, timeBudget: true });
  assert(limit.includes('마지막 회차'));
  assert(limit.includes('65%'));
  assert(limit.includes('기능이 없거나 권한이 없다고 설명하지 않는다.'));
});
