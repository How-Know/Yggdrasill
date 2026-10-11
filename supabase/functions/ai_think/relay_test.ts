import { assert, assertEquals } from 'jsr:@std/assert@1';
import { FakeAiProvider, type FakeTurn } from '../_shared/ai/fake.ts';
import type { AiRequest } from '../_shared/ai/types.ts';
import { runThinkChat } from './chat.ts';
import { relayQuestionLabel } from './prompts.ts';
import { runRelayAsk, type RelayAskInput } from './relay.ts';
import { resolveRelayVerdict, splitRelayBlock } from './relay_verdict.ts';
import { ACTING_TOOL_NAMES } from './tools.ts';
import { EventLog, MemoryRelayStore, RunLog, memory, testEnv } from './test_support.ts';

const block = (v: Record<string, unknown>) => `\n\n\`\`\`relay\n${JSON.stringify(v)}\n\`\`\``;

function storeWithMemories() {
  const store = new MemoryRelayStore();
  store.memories.push(
    memory({ id: 'm-active', kind: 'decision', title: '수업 기록은 날짜순', content: '수업 기록은 날짜순으로 보여 준다' }),
    memory({ id: 'm-draft', kind: 'decision', title: '초안 결정', content: '아직 승인 안 됨', status: 'draft' }),
  );
  return store;
}

function askInput(partial: Partial<RelayAskInput> = {}): RelayAskInput {
  return { asker: 'cursor_ide', question: '수업 기록은 어떤 순서로 보여 주기로 했어?', conversationId: null, dailyLimit: 60, wallClockMs: 140000, ...partial };
}

async function ask(store: MemoryRelayStore, script: (req: AiRequest, i: number) => FakeTurn, partial: Partial<RelayAskInput> = {}, budget: unknown = null) {
  const provider = new FakeAiProvider(script);
  const runs = new RunLog();
  const out = await runRelayAsk(
    { provider, store, recordRun: runs.record, budget: () => Promise.resolve(budget as never), safetyId: 'hash', env: testEnv },
    askInput(partial),
  );
  return { out, provider, runs };
}

const mainRequest = (provider: FakeAiProvider) => provider.requests.find((r) => r.tools)!;

Deno.test('판정 블록: 떼어 내고, 마지막 블록만 읽고, 깨진 블록은 needs_owner', async () => {
  const s = splitRelayBlock(`결론입니다.${block({ verdict: 'needs_owner' })}\n\n추가${block({ verdict: 'answered', basis: ['m-active'] })}`);
  assertEquals(s.text, '결론입니다.\n\n추가');
  assertEquals(s.raw?.verdict, 'answered');

  const broken = splitRelayBlock('답\n```relay\n{not json\n```');
  assertEquals(broken.found, true);
  assertEquals(broken.raw, null);
  const v = await resolveRelayVerdict(broken, 'cursor_ide', () => Promise.resolve(null));
  assertEquals(v.verdict, 'needs_owner');
  assertEquals(v.downgraded, 'invalid_block');

  const none = await resolveRelayVerdict(splitRelayBlock('블록 없는 답'), 'cursor_ide', () => Promise.resolve(null));
  assertEquals(none.downgraded, 'no_block');
});

Deno.test('판정: answered는 승인된 근거가 있고 운영자 질문이 없을 때만', async () => {
  const store = storeWithMemories();
  const get = (id: string) => store.getMemory(id);
  const answered = await resolveRelayVerdict(splitRelayBlock(block({ verdict: 'answered', basis: ['m-active', 'm-active', 'nope'] })), 'cursor_worker', get);
  assertEquals(answered.verdict, 'answered');
  assertEquals(answered.basis, [{ id: 'm-active', kind: 'decision', title: '수업 기록은 날짜순' }]);
  assertEquals(answered.asker, 'cursor_worker');

  const draftOnly = await resolveRelayVerdict(splitRelayBlock(block({ verdict: 'answered', basis: ['m-draft'] })), 'cursor_ide', get);
  assertEquals(draftOnly.verdict, 'needs_owner');
  assertEquals(draftOnly.downgraded, 'no_basis', '초안 기억은 근거가 아니다');

  const open = await resolveRelayVerdict(
    splitRelayBlock(block({ verdict: 'answered', basis: ['m-active'], owner_questions: ['범위를 넓힐지'] })),
    'cursor_ide',
    get,
  );
  assertEquals(open.verdict, 'needs_owner');
  assertEquals(open.downgraded, 'open_questions');
  assertEquals(open.owner_questions, ['범위를 넓힐지']);
});

Deno.test('작업창 질문: 커서 대화를 새로 만들고, 조회 도구만 주고, 블록을 뗀 답과 판정을 저장한다', async () => {
  const store = storeWithMemories();
  const { out, provider, runs } = await ask(store, (req) =>
    req.tools ? { text: `날짜순으로 정했습니다(m-active).${block({ verdict: 'answered', basis: ['m-active'], owner_questions: [] })}` } : { text: '수업 기록 순서' }
  );
  assert(out.ok);
  assertEquals(out.verdict, 'answered');
  assertEquals(out.answer, '날짜순으로 정했습니다(m-active).');
  assertEquals(out.basis.map((b) => b.id), ['m-active']);

  const conv = store.conversations.find((c) => c.id === out.conversation_id)!;
  assertEquals(conv.origin, 'cursor');
  const [question, answer] = store.messages.filter((m) => m.conversation_id === conv.id);
  assertEquals(question.asked_by, 'cursor_ide');
  assert(!answer.content.includes('```relay'), '저장한 답에는 판정 블록이 없다');
  assertEquals(answer.extra?.relay?.verdict, 'answered');

  const offered = (mainRequest(provider).tools ?? []).map((t) => t.name);
  assert(offered.includes('search_memories'));
  for (const name of ACTING_TOOL_NAMES) assert(!offered.includes(name), `${name}는 커서 질문에 주지 않는다`);
  assert((mainRequest(provider).instructions ?? '').includes('```relay'), '커서 문의 모드 지침이 붙는다');

  const relayRun = runs.runs.findIndex((r) => r.feature === 'think_relay');
  assert(relayRun >= 0);
  assertEquals(runs.runs[relayRun].createdBy, null);
  assertEquals(store.finished, [{ id: 'ask-1', status: 'answered', conversationId: conv.id, runId: `run-${relayRun + 1}`, error: null }]);
});

Deno.test('모델이 제안 도구를 불러도 커서 질문에서는 실행하지 않는다', async () => {
  const store = storeWithMemories();
  const { out } = await ask(store, (req, i) => {
    if (!req.tools) return { text: '제목' };
    if (i <= 1) return { functionCalls: [{ name: 'propose_folder', arguments: { name: '새 폴더', parent_id: null } }] };
    return { text: `제안은 못 합니다.${block({ verdict: 'needs_owner', owner_questions: ['폴더를 만들지'] })}` };
  });
  assert(out.ok);
  assertEquals(out.verdict, 'needs_owner');
  assertEquals(store.actions.length, 0);
});

Deno.test('블록이 없으면 needs_owner로 저장한다', async () => {
  const store = storeWithMemories();
  const { out } = await ask(store, (req) => (req.tools ? { text: '아마 날짜순일 겁니다.' } : { text: '제목' }));
  assert(out.ok);
  assertEquals(out.verdict, 'needs_owner');
  assertEquals(out.downgraded, 'no_block');
  assertEquals(store.finished[0].status, 'needs_owner');
});

Deno.test('이어 묻기: 커서 대화는 이어지고, 운영자 대화에는 남기지 않는다', async () => {
  const store = storeWithMemories();
  const reply = (req: AiRequest): FakeTurn => (req.tools ? { text: `답${block({ verdict: 'needs_owner' })}` } : { text: '제목' });
  const first = await ask(store, reply);
  assert(first.out.ok);
  const second = await ask(store, reply, { conversationId: first.out.conversation_id });
  assert(second.out.ok);
  assertEquals(second.out.conversation_id, first.out.conversation_id);
  assertEquals(store.messages.filter((m) => m.conversation_id === first.out.conversation_id).length, 4);

  const owners = await store.createConversation('운영자 대화');
  const blocked = await ask(store, reply, { conversationId: owners.id });
  assert(!blocked.out.ok);
  assertEquals(blocked.out.status, 403);
  assertEquals(store.messages.filter((m) => m.conversation_id === owners.id).length, 0);
});

Deno.test('작업자 질문: 요청 제목으로 대화를 만들고, 같은 요청의 다음 질문은 그 대화에 잇는다', async () => {
  const store = storeWithMemories();
  const reply = (req: AiRequest): FakeTurn => (req.tools ? { text: `답${block({ verdict: 'needs_owner' })}` } : { text: '만든 제목' });
  const first = await ask(store, reply, { asker: 'cursor_worker', workerId: 'pc-a', requestId: 'req-1' });
  assert(first.out.ok);
  const conv = store.conversations.find((c) => c.id === first.out.conversation_id)!;
  assertEquals(conv.title, '작업자 문의: 조율 요청');
  assert(!first.provider.requests.some((r) => !r.tools), '제목을 따로 만들지 않는다');
  assertEquals(store.reservations[0].runLimit, 3);

  const second = await ask(store, reply, { asker: 'cursor_worker', workerId: 'pc-a', requestId: 'req-1' });
  assert(second.out.ok);
  assertEquals(second.out.conversation_id, conv.id);
  assertEquals(store.messages.find((m) => m.conversation_id === conv.id)?.asked_by, 'cursor_worker');
});

Deno.test('접수 실패는 상태 코드로 바꾸고 Think를 부르지 않는다', async () => {
  const cases: [string, number, string][] = [
    ['relay_daily_limit', 429, 'relay_daily_limit'],
    ['relay_run_limit', 429, 'relay_run_limit'],
    ['relay_request_not_running', 409, 'relay_request_not_running'],
    ['relay_mode_not_allowed', 403, 'relay_mode_not_allowed'],
    ['Could not find the function public.ai_relay_reserve(p_asker) in the schema cache', 503, 'db_required'],
    ['boom', 500, 'internal_error'],
  ];
  for (const [error, status, code] of cases) {
    const store = storeWithMemories();
    store.reserveError = error;
    const { out, provider } = await ask(store, () => ({ text: '답' }));
    assert(!out.ok);
    assertEquals([out.status, out.error], [status, code]);
    assertEquals(provider.requests.length, 0);
  }
});

Deno.test('한도 차단·빈 질문·키 없음은 접수 전에 막는다', async () => {
  const store = storeWithMemories();
  const blocked = await ask(store, () => ({ text: '답' }), {}, { exceeded: true, mode: 'block', limitUsd: 10, spentUsd: 11, webSearchEnabled: true });
  assert(!blocked.out.ok);
  assertEquals(blocked.out.status, 429);
  const empty = await ask(store, () => ({ text: '답' }), { question: '   ' });
  assert(!empty.out.ok);
  assertEquals(empty.out.error, 'question_required');
  const noKey = await runRelayAsk(
    { provider: null, store, recordRun: new RunLog().record, budget: () => Promise.resolve(null), safetyId: 'h' },
    askInput(),
  );
  assert(!noKey.ok);
  assertEquals(noKey.status, 503);
  assertEquals(store.reservations.length, 0);
});

Deno.test('Think가 실패하면 질문을 error로 마감한다', async () => {
  const store = storeWithMemories();
  const { out } = await ask(store, (req) => (req.tools ? { error: 'upstream' } : { text: '제목' }));
  assert(!out.ok);
  assertEquals(store.finished[0].status, 'error');
  assert(out.conversation_id, '질문은 대화에 남는다');
});

Deno.test('운영자가 커서 대화에 이어 말하면, 지난 커서 질문은 표시를 붙여 맥락에 넣는다', async () => {
  const store = storeWithMemories();
  const first = await ask(store, (req) => (req.tools ? { text: `답${block({ verdict: 'needs_owner' })}` } : { text: '제목' }));
  assert(first.out.ok);
  const provider = new FakeAiProvider(() => ({ text: '운영자에게 답' }));
  await runThinkChat(
    {
      userId: 'user-1',
      safetyId: 'hash',
      conversationId: first.out.conversation_id,
      message: '그건 날짜순으로 하자',
      attachments: [],
      deep: false,
      webSearch: false,
      signal: new AbortController().signal,
      startedAt: Date.now(),
      wallClockMs: 140000,
    },
    { provider, store, recordRun: new RunLog().record, emit: new EventLog().emit, env: testEnv },
  );
  const req = provider.requests[0];
  const texts = req.input.flatMap((i) => (i.kind === 'message' && i.role === 'user' ? i.parts : [])).map((p) => (p.type === 'text' ? p.text : ''));
  assert(texts.some((t) => t.startsWith(relayQuestionLabel('cursor_ide'))), '커서 질문에 표시가 붙는다');
  assert(texts.some((t) => t === '그건 날짜순으로 하자'), '운영자 메시지는 그대로');
  assert(!(req.instructions ?? '').includes('```relay'), '운영자 대화에는 커서 문의 지침을 붙이지 않는다');
  const owner = store.messages.find((m) => m.content === '그건 날짜순으로 하자')!;
  assertEquals(owner.asked_by, null);
});
