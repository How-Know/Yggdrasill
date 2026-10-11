import { assert, assertEquals } from 'jsr:@std/assert@1';
import { FakeAiProvider, type FakeTurn } from '../_shared/ai/fake.ts';
import type { AiRequest } from '../_shared/ai/types.ts';
import { SPLIT_TOOL_NAME, workStateNote, type ActionRow } from './actions.ts';
import { runThinkChat, type ChatInput } from './chat.ts';
import { computeFeatures, type ThinkFeatures } from './features.ts';
import { THINK_PROMPT_VERSION } from './prompts.ts';
import { runThinkTool } from './tools.ts';
import { EventLog, MemoryThinkStore, RunLog, testEnv } from './test_support.ts';

const READY = computeFeatures({ ok: true, features: { conversation_split: 1 } }, { conversation_split: 1 }, true);
const DB_REQUIRED = computeFeatures({ ok: false, missing: true, error: 'missing' }, { conversation_split: 1 }, true);

const splitArgs = (extra: Record<string, unknown> = {}) => ({
  title: '수업 기록 화면',
  reason: '커리큘럼 이야기에서 수업 기록 화면 설계로 넘어갔다',
  folder_id: null,
  summary: { purpose: '수업 기록 화면을 설계한다', background: '', decided: [], open: ['표시 순서'], next: [] },
  ...extra,
});

async function existingConversation(store: MemoryThinkStore, extra: Record<string, unknown> = {}) {
  const conv = await store.createConversation('커리큘럼');
  Object.assign(conv, extra);
  await store.insertMessage({ conversation_id: conv.id, role: 'user', content: '반복 사고 원칙', status: 'complete' });
  await store.insertMessage({ conversation_id: conv.id, role: 'assistant', content: '정리한 답', status: 'complete' });
  return conv;
}

function input(partial: Partial<ChatInput>): ChatInput {
  return {
    userId: 'user-1',
    safetyId: 'hash',
    conversationId: null,
    message: '이제 수업 기록 화면을 어떻게 보여줄지 정하자',
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

async function run(store: MemoryThinkStore, partial: Partial<ChatInput>, script?: (req: AiRequest, i: number) => FakeTurn) {
  const provider = new FakeAiProvider(script ?? (() => ({ text: '답변' })));
  const runs = new RunLog();
  const events = new EventLog();
  const out = await runThinkChat(input(partial), { provider, store, recordRun: runs.record, emit: events.emit, env: testEnv });
  return { out, provider, runs, events };
}

Deno.test('나누기 도구는 기능이 준비됐고 앞 대화가 있을 때만 노출된다', async () => {
  const store = new MemoryThinkStore();
  const conv = await existingConversation(store);

  const ready = await run(store, { conversationId: conv.id, features: READY });
  assert(toolNames(ready.provider.requests[0]).includes(SPLIT_TOOL_NAME));

  const notMigrated = await run(store, { conversationId: conv.id, features: DB_REQUIRED });
  assert(!toolNames(notMigrated.provider.requests[0]).includes(SPLIT_TOOL_NAME));

  const unknown = await run(store, { conversationId: conv.id });
  assert(!toolNames(unknown.provider.requests[0]).includes(SPLIT_TOOL_NAME), '기능 상태가 없으면 노출하지 않는다');

  const fresh = await run(new MemoryThinkStore(), { features: READY }, (req) => (req.tools ? { text: '답변' } : { text: '제목' }));
  const main = fresh.provider.requests.find((r) => r.tools)!;
  assert(!toolNames(main).includes(SPLIT_TOOL_NAME), '첫 문답은 나눌 앞 대화가 없다');
});

Deno.test('거절한 대화에서는 노출하지 않고, 사용자가 직접 요청하면 다시 노출한다', async () => {
  const store = new MemoryThinkStore();
  const conv = await existingConversation(store, { auto_split_suggestions: false });

  const quiet = await run(store, { conversationId: conv.id, features: READY });
  assert(!toolNames(quiet.provider.requests[0]).includes(SPLIT_TOOL_NAME));
  const note = quiet.provider.requests[0].input.find((i) => i.kind === 'context' && i.text.includes('실행 환경 기능 상태'));
  assert(note && note.kind === 'context' && note.text.includes('거절'));
  assertEquals(quiet.events.of('conversation')[0].split_suggestions, false);

  const asked = await run(store, { conversationId: conv.id, features: READY, message: '이건 새 대화로 나눠서 이어가자' });
  assert(toolNames(asked.provider.requests[0]).includes(SPLIT_TOOL_NAME));
});

Deno.test('나누기 제안: 범위는 서버가 저장한 이번 사용자 메시지로 정하고, 한 답변에 하나만 남는다', async () => {
  const store = new MemoryThinkStore();
  const conv = await existingConversation(store);
  const { out, events, runs } = await run(store, { conversationId: conv.id, features: READY }, (_req, i) =>
    i === 0
      ? {
        functionCalls: [
          { name: SPLIT_TOOL_NAME, arguments: splitArgs({ start_message_id: 'msg-0001' }) },
          { name: SPLIT_TOOL_NAME, arguments: splitArgs({ title: '두 번째' }) },
        ],
      }
      : { text: '답변 끝. 새 대화로 나누자고 제안했습니다.' }
  );

  assertEquals(out.status, 'complete');
  assertEquals(store.splitCalls.length, 1);
  assertEquals(store.splitCalls[0].startMessageId, out.userMessageId, '모델 인자가 아니라 서버가 저장한 사용자 메시지 id');
  assertEquals(store.splitCalls[0].userRequested, false);
  assertEquals(events.of('action').length, 1);
  const tools = events.of('tool').filter((t) => t.status === 'done' && t.name === SPLIT_TOOL_NAME);
  assertEquals(tools.map((t) => t.ok), [true, false]);

  const split = store.actions.find((a) => a.kind === 'split_conversation')!;
  assertEquals(split.message_id, out.assistantMessageId, '답변이 저장된 뒤 그 답변에 붙는다');
  assertEquals((split.payload.summary as Record<string, unknown>).open, ['표시 순서']);

  const chatRun = runs.runs.find((r) => r.feature === 'think_chat')!;
  assertEquals(chatRun.promptVersion, THINK_PROMPT_VERSION);
  const recorded = chatRun.features as Record<string, unknown>;
  assertEquals((recorded.conversation_split as ThinkFeatures['conversation_split']).state, 'ready');
  assertEquals(recorded.split_tool, true);
});

Deno.test('나누기 제안 실패(거절로 꺼짐 등)는 오류 결과로 돌려주고 카드를 만들지 않는다', async () => {
  const store = new MemoryThinkStore();
  const conv = await existingConversation(store);
  store.splitFailure = 'split_suppressed';
  const { out, events } = await run(store, { conversationId: conv.id, features: READY }, (_req, i) =>
    i === 0 ? { functionCalls: [{ name: SPLIT_TOOL_NAME, arguments: splitArgs() }] } : { text: '답변' }
  );
  assertEquals(out.status, 'complete');
  assertEquals(events.of('action').length, 0);
  assertEquals(store.actions.length, 0);
});

Deno.test('나누기 도구: 필수 값·폴더를 확인하고, 쓸 수 없는 턴이면 거부한다', async () => {
  const store = new MemoryThinkStore();
  store.folders = [{ id: '11111111-1111-4111-8111-111111111111', parent_id: null, title: '설계' }];
  const ctx = () => ({ conversationId: 'conv-x', memoryRefs: [], split: { userMessageId: 'msg-x', userRequested: false, proposed: false } });

  const noSplit = await runThinkTool(SPLIT_TOOL_NAME, JSON.stringify(splitArgs()), store, 8000, { conversationId: 'conv-x', memoryRefs: [] });
  assertEquals(JSON.parse(noSplit.output).error, 'split_unavailable');

  const missing = await runThinkTool(SPLIT_TOOL_NAME, JSON.stringify(splitArgs({ title: ' ', summary: { purpose: '' } })), store, 8000, ctx());
  assertEquals(JSON.parse(missing.output).missing, ['title', 'summary.purpose']);

  const badFolder = await runThinkTool(SPLIT_TOOL_NAME, JSON.stringify(splitArgs({ folder_id: '22222222-2222-4222-8222-222222222222' })), store, 8000, ctx());
  assertEquals(JSON.parse(badFolder.output).error, 'folder_not_found');
  assertEquals(store.splitCalls.length, 0);

  const ok = await runThinkTool(SPLIT_TOOL_NAME, JSON.stringify(splitArgs({ folder_id: store.folders[0].id })), store, 8000, ctx());
  assert(ok.ok);
  assertEquals(store.splitCalls[0].preview.folder_path, '설계');
  assertEquals(store.splitCalls[0].startMessageId, 'msg-x');
});

Deno.test('나눠 온 대화는 요약을 참고 자료(사용자 메시지 자리)로 맨 앞에 넣는다', async () => {
  const store = new MemoryThinkStore();
  const conv = await existingConversation(store, {
    split_summary: { purpose: '수업 기록 화면 설계', background: '', decided: ['날짜순'], open: [], next: ['시안 보기'] },
    split_from_conversation_id: 'conv-origin',
  });
  const { provider, events } = await run(store, { conversationId: conv.id, features: READY, message: '시안부터 보자' });
  assertEquals((events.of('conversation')[0].context as Record<string, unknown>).split_summary, true);
  const first = provider.requests[0].input[0];
  assert(first.kind === 'message' && first.role === 'user');
  const text = first.kind === 'message' && first.parts[0].type === 'text' ? first.parts[0].text : '';
  assert(text.includes('참고 자료'));
  assert(text.includes('날짜순'));
  assert(!provider.requests[0].input.some((i) => i.kind === 'context' && i.text.includes('날짜순')), '개발자 메시지로 넣지 않는다');
  assert(!provider.requests[0].instructions!.includes('날짜순'), '지시문에 넣지 않는다');
});

Deno.test('작업 상태 메모는 나누기 제안의 만료·실행을 알린다', () => {
  const row = (status: string): ActionRow => ({
    id: `a-${status}`,
    conversation_id: 'c',
    message_id: 'm',
    kind: 'split_conversation',
    status,
    payload: {},
    preview: { title: '수업 기록 화면' },
    result: null,
    error: null,
    created_at: '',
  });
  const note = workStateNote({ actions: [row('expired'), row('applied')], codeRequests: [] })!;
  assert(note.includes('만료'));
  assert(note.includes('그대로 남아'));
});
