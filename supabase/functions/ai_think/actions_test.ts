import { assert, assertEquals, assertExists } from 'jsr:@std/assert@1';
import { FakeAiProvider } from '../_shared/ai/fake.ts';
import type { AiRequest } from '../_shared/ai/types.ts';
import { folderPaths, workStateNote, type CodeRequestDetail } from './actions.ts';
import { runThinkChat, type ChatInput } from './chat.ts';
import { titleInstructions } from './prompts.ts';
import { EventLog, MemoryThinkStore, RunLog, memory, testEnv } from './test_support.ts';
import { runThinkTool } from './tools.ts';

const F_MATH = '11111111-1111-4111-8111-111111111111';
const F_FUNC = '22222222-2222-4222-8222-222222222222';
const REQ_ID = '33333333-3333-4333-8333-333333333333';

function codeRequest(partial: Partial<CodeRequestDetail> = {}): CodeRequestDetail {
  return {
    id: REQ_ID,
    title: '홈 화면 조사',
    status: 'ready',
    mode: 'investigate',
    conversation_id: null,
    created_at: '2026-09-30T00:00:00Z',
    request: { goal: 'g' },
    round: 1,
    max_rounds: 2,
    review_status: null,
    last_error: null,
    latest: { round: 1, status: 'finished', result: { summary: '가능하다', feasibility: 'possible' }, result_text: '원문' },
    ...partial,
  };
}

async function setup() {
  const store = new MemoryThinkStore();
  const conv = await store.createConversation('함수 단원 정리');
  store.folders.push({ id: F_MATH, parent_id: null, title: '수학' }, { id: F_FUNC, parent_id: F_MATH, title: '함수' });
  store.treeItems.push({ parent_id: F_FUNC, kind: 'excerpt', conversation_id: 'other' });
  const ctx = { conversationId: conv.id, memoryRefs: [{ id: 'p1', kind: 'principle', title: '원칙', version: 2, content: '요약' }] };
  const call = (name: string, args: Record<string, unknown>) => runThinkTool(name, JSON.stringify(args), store, 8000, ctx);
  return { store, conv, call };
}

const codeArgs = { title: '홈 화면', goal: '홈 화면 위젯 위치 확인', questions: null, focus_paths: ['apps/yggdrasill'], constraints: null, do_not: null, background: null };

Deno.test('필수 값이 없으면 제안하지 않고 빠진 항목을 돌려준다', async () => {
  const { store, call } = await setup();
  const r = await call('propose_code_request', { ...codeArgs, goal: ' ' });
  assertEquals(r.ok, false);
  const body = JSON.parse(r.output);
  assertEquals(body.error, 'missing_fields');
  assertEquals(body.missing, ['goal']);
  assertEquals(store.actions.length, 0);
  const c = await call('start_code_plan', { ...codeArgs, instructions: [], based_on_request_id: null });
  assertEquals(JSON.parse(c.output).missing, ['instructions']);
  assertEquals(store.plansStarted.length, 0);
});

Deno.test('코드 조사 제안: 제안 1행만 남기고, 원칙 참조를 함께 넣는다', async () => {
  const { store, conv, call } = await setup();
  const r = await call('propose_code_request', codeArgs);
  assert(r.ok);
  assertExists(r.action);
  assertEquals(store.actions.length, 1);
  const a = store.actions[0];
  assertEquals(a.kind, 'code_request');
  assertEquals(a.conversation_id, conv.id);
  const spec = a.payload.spec as Record<string, unknown>;
  assertEquals(spec.focus_paths, ['apps/yggdrasill']);
  assertEquals((spec.memory_refs as unknown[]).length, 1);
  assertEquals(JSON.parse(r.output).status, 'proposed');
});

Deno.test('조율 시작: 승인 카드 없이 바로 시작하고, 계획 초안·확인할 점·근거 결론을 함께 보낸다', async () => {
  const { store, conv, call } = await setup();
  const args = { ...codeArgs, instructions: ['버튼 색 변경'], questions: ['영향 범위'], based_on_request_id: REQ_ID };
  const miss = await call('start_code_plan', args);
  assertEquals(JSON.parse(miss.output).error, 'based_on_request_not_found');
  store.codeRequests.push(codeRequest());
  const r = await call('start_code_plan', args);
  assert(r.ok);
  assertEquals(r.action?.kind, 'code_plan');
  assertEquals(r.action?.status, 'applied');
  assertEquals(JSON.parse(r.output).status, 'started');
  assertEquals(store.plansStarted.length, 1);
  const { spec, conversationId } = store.plansStarted[0];
  assertEquals(conversationId, conv.id);
  assertEquals(spec.instructions, ['버튼 색 변경']);
  assertEquals(spec.questions, ['영향 범위']);
  assertEquals((spec.based_on as Record<string, unknown>).summary, '가능하다');
  assertEquals((spec.memory_refs as unknown[]).length, 1);
  assertEquals(store.actions.filter((a) => a.status === 'proposed').length, 0);
});

Deno.test('조율 시작: 하루 한도를 넘으면 시작하지 않고 모델에게 이유를 돌려준다', async () => {
  const { store, call } = await setup();
  store.planStartFailure = 'limit';
  const r = await call('start_code_plan', { ...codeArgs, instructions: ['a'], based_on_request_id: null });
  assertEquals(r.ok, false);
  assertEquals(JSON.parse(r.output).error, 'daily_limit');
  assertEquals(store.actions.length, 0);
});

Deno.test('분류 제안: 경로를 계산하고, 같은 종류 새 제안은 이전 것을 대체한다', async () => {
  const { store, call } = await setup();
  const r1 = await call('propose_folder', { folder_id: F_FUNC, new_folder_title: null, new_folder_parent_id: null, reason: '함수 단원' });
  assert(r1.ok);
  assertEquals(store.actions[0].preview.path, '수학 > 함수');
  assertEquals(store.actions[0].preview.current, '정리 안 됨');
  const r2 = await call('propose_folder', { folder_id: null, new_folder_title: '일차함수', new_folder_parent_id: F_FUNC, reason: '' });
  assert(r2.ok);
  assertEquals(store.actions[1].preview.path, '수학 > 함수 > 일차함수');
  assertEquals(store.actions[1].preview.is_new, true);
  assertEquals(store.actions[0].superseded, true);

  const both = await call('propose_folder', { folder_id: F_FUNC, new_folder_title: 'x', new_folder_parent_id: null, reason: '' });
  assertEquals(JSON.parse(both.output).error, 'choose_one');
  const none = await call('propose_folder', { folder_id: null, new_folder_title: null, new_folder_parent_id: null, reason: '' });
  assertEquals(JSON.parse(none.output).error, 'missing_fields');
  const bad = await call('propose_folder', { folder_id: REQ_ID, new_folder_title: null, new_folder_parent_id: null, reason: '' });
  assertEquals(JSON.parse(bad.output).error, 'folder_not_found');
});

Deno.test('이미 그 폴더에 있으면 분류 제안을 하지 않는다', async () => {
  const { store, conv, call } = await setup();
  store.treeItems.push({ parent_id: F_FUNC, kind: 'conversation', conversation_id: conv.id });
  const r = await call('propose_folder', { folder_id: F_FUNC, new_folder_title: null, new_folder_parent_id: null, reason: '' });
  assertEquals(JSON.parse(r.output).error, 'already_in_folder');
  const list = await call('list_tree_folders', {});
  const body = JSON.parse(list.output);
  assertEquals(body.current_conversation.location, '수학 > 함수');
  assertEquals(body.folders.find((f: { id: string }) => f.id === F_FUNC).items, 2);
  assert(!list.output.includes('excerpt'), '발췌 노드 정보는 항목 수로만 보인다');
});

Deno.test('삭제 제안: 진행 중 요청은 막고, 폴더·대화는 지워질 내용을 미리보기에 담는다', async () => {
  const { store, conv, call } = await setup();
  store.codeRequests.push(codeRequest({ status: 'running' }));
  const running = await call('propose_delete', { target_kind: 'code_request', target_id: REQ_ID, reason: '' });
  assertEquals(JSON.parse(running.output).error, 'not_deletable');

  const folder = await call('propose_delete', { target_kind: 'folder', target_id: F_MATH, reason: '정리' });
  assert(folder.ok);
  assertEquals(store.actions[0].kind, 'delete_folder');
  assertEquals(store.actions[0].preview.children, 1);

  const old = '44444444-4444-4444-8444-444444444444';
  store.conversations.push({ id: old, title: '지울 대화', status: 'active', scope_type: 'general', scope_id: null });
  await store.insertMessage({ conversation_id: old, role: 'user', content: 'q', status: 'complete' });
  store.treeItems.push({ parent_id: null, kind: 'excerpt', conversation_id: old });
  const c = await call('propose_delete', { target_kind: 'conversation', target_id: old, reason: '' });
  assert(c.ok);
  const p = store.actions.at(-1)!.preview;
  assertEquals([p.title, p.messages, p.excerpts, p.is_current], ['지울 대화', 1, 1, false]);
  assertEquals(store.actions.at(-1)!.conversation_id, conv.id, '제안은 지금 대화에 남는다');

  const badId = await call('propose_delete', { target_kind: 'conversation', target_id: conv.id, reason: '' });
  assertEquals(JSON.parse(badId.output).error, 'missing_fields');
});

Deno.test('작업 상태 메모: 작업이 없으면 없고, 있으면 상태와 결론을 담는다', () => {
  assertEquals(workStateNote({ actions: [], codeRequests: [] }), null);
  const note = workStateNote({
    actions: [{
      id: 'a1', conversation_id: 'c', message_id: null, kind: 'place_conversation', status: 'rejected',
      payload: {}, preview: { path: '수학 > 함수' }, result: null, error: null, created_at: '',
    }],
    codeRequests: [codeRequest()],
  })!;
  assert(note.includes('수학 > 함수'));
  assert(note.includes('거절'));
  assert(note.includes('가능하다'));
  assert(note.includes(REQ_ID));
});

Deno.test('폴더 경로는 순환이 있어도 끝난다', () => {
  const paths = folderPaths([{ id: 'a', parent_id: 'b', title: 'A' }, { id: 'b', parent_id: 'a', title: 'B' }]);
  assert(paths.get('a')!.length > 0);
});

const isTitle = (req: AiRequest) => req.instructions === titleInstructions();

function chatInput(partial: Partial<ChatInput> = {}): ChatInput {
  return {
    userId: 'user-1',
    safetyId: 'hash',
    conversationId: null,
    message: '홈 화면 위젯이 어디서 그려지는지 조사해 줘',
    attachments: [],
    deep: false,
    webSearch: false,
    signal: new AbortController().signal,
    startedAt: Date.now(),
    wallClockMs: 140000,
    ...partial,
  };
}

Deno.test('채팅: 제안 도구를 부르면 action 이벤트가 나가고 제안이 답변 메시지에 붙는다', async () => {
  const store = new MemoryThinkStore();
  store.memories.push(memory({ id: 'm-p', kind: 'principle', title: '원칙', content: '학생 중심' }));
  let calls = 0;
  const provider = new FakeAiProvider((req) => {
    if (isTitle(req)) return { text: '제목' };
    calls += 1;
    if (calls === 1) return { functionCalls: [{ name: 'propose_code_request', arguments: codeArgs }] };
    return { text: '조사 요청을 제안했습니다. 카드를 확인해 주세요.' };
  });
  const events = new EventLog();
  const out = await runThinkChat(chatInput(), { provider, store, recordRun: new RunLog().record, emit: events.emit, env: testEnv });

  assertEquals(out.status, 'complete');
  const actionEvents = events.of('action');
  assertEquals(actionEvents.length, 1);
  const action = actionEvents[0].action as { id: string; kind: string };
  assertEquals(action.kind, 'code_request');
  assertEquals(store.attached, [{ ids: [action.id], messageId: out.assistantMessageId! }]);
  assertEquals(events.of('done')[0].action_ids, [action.id]);
  const spec = store.actions[0].payload.spec as Record<string, unknown>;
  assertEquals((spec.memory_refs as { id: string }[]).map((m) => m.id), ['m-p']);

  // 다음 턴: 작업 상태 메모가 이번 질문 앞(관련 기억 메모보다 앞)에 들어간다.
  const provider2 = new FakeAiProvider([{ text: '아직 확인 대기입니다.' }]);
  await runThinkChat(chatInput({ conversationId: out.conversationId, message: '어떻게 됐어?' }), {
    provider: provider2,
    store,
    recordRun: new RunLog().record,
    emit: new EventLog().emit,
    env: testEnv,
  });
  const req = provider2.requests[0];
  const contexts = req.input.filter((i) => i.kind === 'context');
  assert(contexts.some((c) => c.kind === 'context' && c.text.includes('작업 상태') && c.text.includes('확인 대기')));
  assertEquals(req.input.at(-1)!.kind, 'message');
});

Deno.test('채팅: 정보가 부족하면 도구가 빠진 항목을 모델에게 돌려주고 제안은 생기지 않는다', async () => {
  const store = new MemoryThinkStore();
  let calls = 0;
  const provider = new FakeAiProvider((req) => {
    if (isTitle(req)) return { text: '제목' };
    calls += 1;
    if (calls === 1) return { functionCalls: [{ name: 'start_code_plan', arguments: { ...codeArgs, instructions: [], based_on_request_id: null } }] };
    return { text: '어떤 부분을 바꿀지 알려 주세요.' };
  });
  const events = new EventLog();
  const out = await runThinkChat(chatInput({ message: '홈 화면 고쳐 줘' }), { provider, store, recordRun: new RunLog().record, emit: events.emit, env: testEnv });
  assertEquals(out.status, 'complete');
  assertEquals(events.of('action').length, 0);
  assertEquals(store.actions.length, 0);
  const second = provider.requests.filter((r) => !isTitle(r))[1];
  const toolResult = second.input.find((i) => i.kind === 'tool_result');
  assert(toolResult && toolResult.kind === 'tool_result' && toolResult.output.includes('missing_fields'));
});
