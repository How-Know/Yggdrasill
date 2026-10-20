import { assert, assertEquals } from 'jsr:@std/assert@1';
import { FakeAiProvider, type FakeTurn } from '../_shared/ai/fake.ts';
import type { AiRequest } from '../_shared/ai/types.ts';
import { HANDOVER_TOOL_NAME, workStateNote } from './actions.ts';
import { runThinkChat, type ChatInput } from './chat.ts';
import { CONSULT_TOOL_NAME, MAX_CONSULTS_PER_ANSWER } from './consult.ts';
import { computeFeatures } from './features.ts';
import { roleProfileSection, ROLE_PROFILE_VERSION } from './prompts.ts';
import { runThinkTool } from './tools.ts';
import { EventLog, memory, MemoryThinkStore, RunLog, testEnv } from './test_support.ts';

const ALL = { conversation_split: 1, think_roles: 1, memory_proposals: 1, department_work: 1 };
const READY = computeFeatures({ ok: true, features: ALL }, ALL, true);
const DB_REQUIRED = computeFeatures(
  { ok: true, features: { conversation_split: 1, think_roles: 1, memory_proposals: 1 } },
  ALL,
  true,
);
const OLD_APP = computeFeatures({ ok: true, features: ALL }, { conversation_split: 1, think_roles: 1, memory_proposals: 1 }, true);
const NO_ROLES = computeFeatures({ ok: true, features: { ...ALL, think_roles: 0 } }, ALL, true);

const OWNER_SECRET = '학생 김OO의 오답 패턴을 보고 싶어';

function input(partial: Partial<ChatInput>): ChatInput {
  return {
    userId: 'user-1',
    safetyId: 'hash',
    conversationId: null,
    message: OWNER_SECRET,
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
const isConsult = (req: AiRequest) => (req.instructions ?? '').includes('## 부서 협의 모드');
const requestText = (req: AiRequest) =>
  JSON.stringify(req.input) + (req.instructions ?? '');

async function educationConversation(store: MemoryThinkStore) {
  const conv = await store.createConversation('오답 분석');
  await store.insertMessage({ conversation_id: conv.id, role: 'user', content: '지난번 대화 원문: 반 평균이 낮다', status: 'complete' });
  await store.insertMessage({ conversation_id: conv.id, role: 'assistant', content: '정리한 답', status: 'complete' });
  store.accessByConversation.set(conv.id, {
    conversationId: conv.id,
    thinkRoleId: 'education',
    extraRefDepartments: [],
    linkedMemoryIds: new Set(),
    linkedDocumentNodeIds: new Set(),
    rolesFeatureReady: true,
  });
  return conv;
}

async function run(store: MemoryThinkStore, partial: Partial<ChatInput>, script?: (req: AiRequest, i: number) => FakeTurn) {
  const provider = new FakeAiProvider(script ?? (() => ({ text: '답변' })));
  const events = new EventLog();
  const runs = new RunLog();
  const out = await runThinkChat(input(partial), { provider, store, recordRun: runs.record, emit: events.emit, env: testEnv });
  return { out, provider, events, runs };
}

Deno.test('문제 풀이 역할 프로필: 문제 은행·채점·교재를 맡고 학생 풀이 과정은 맡지 않는다', () => {
  const text = roleProfileSection('product');
  assert(text.includes('문제 풀이'));
  assert(text.includes('문제 은행'));
  assert(text.includes('채점'));
  assert(text.includes('교재'));
  assert(text.includes('맡지 않는다'));
  assert(!text.includes('(제품)'));
  assertEquals(ROLE_PROFILE_VERSION, 'think-role-2026-10-12');
});

Deno.test('부서 도구는 부서 기능과 역할 기능이 모두 준비된 요청에만 노출되고, 지시문에 부서 절이 들어간다', async () => {
  const store = new MemoryThinkStore();
  const conv = await educationConversation(store);

  const ready = await run(store, { conversationId: conv.id, features: READY });
  const req = ready.provider.requests[0];
  assert(toolNames(req).includes(CONSULT_TOOL_NAME));
  assert(toolNames(req).includes(HANDOVER_TOOL_NAME));
  assert(req.instructions!.includes('## 부서'));

  for (const features of [DB_REQUIRED, OLD_APP, NO_ROLES, undefined]) {
    const off = await run(store, { conversationId: conv.id, features });
    const r = off.provider.requests[0];
    assert(!toolNames(r).includes(CONSULT_TOOL_NAME));
    assert(!toolNames(r).includes(HANDOVER_TOOL_NAME));
    assert(!r.instructions!.includes('consult_department로'));
  }

  const relayed = await run(new MemoryThinkStore(), { features: READY, relay: { asker: 'cursor_ide', title: '질문' } });
  assert(!toolNames(relayed.provider.requests[0]).includes(CONSULT_TOOL_NAME));
});

Deno.test('부서 협의: 질문 받은 부서는 질문·배경과 자기 부서·공통 기억만 보고, 운영자 대화는 보지 않는다', async () => {
  const store = new MemoryThinkStore();
  store.memories.push(
    memory({ id: 'm-eng', kind: 'decision', title: '채점 서버 분리', content: '채점은 별도 함수', memory_scope: 'department', scope_department: 'engineering' }),
    memory({ id: 'm-edu', kind: 'decision', title: '교육 비공개 결정', content: '교육 부서만', memory_scope: 'department', scope_department: 'education' }),
    memory({ id: 'm-common', kind: 'principle', title: '공통 원칙', content: '학생 중심', memory_scope: 'common' }),
  );
  const conv = await educationConversation(store);

  let round = 0;
  const { out, provider, events, runs } = await run(store, { conversationId: conv.id, features: READY }, (req) => {
    if (isConsult(req)) return { text: '개발 의견: 채점은 별도 함수로 두는 것을 추천' };
    round += 1;
    if (round === 1) {
      return {
        functionCalls: [{
          name: CONSULT_TOOL_NAME,
          arguments: { department: 'engineering', question: '오답 통계를 실시간으로 낼 수 있나?', background: '반 단위 통계가 필요하다' },
        }],
      };
    }
    return { text: '교육 관점 답과 개발 의견을 합친 답' };
  });
  assertEquals(out.status, 'complete');

  const consultReq = provider.requests.find(isConsult)!;
  assert(consultReq, '협의 요청이 있었다');
  assertEquals(consultReq.model, 'gpt-6-sol', '기본 모델로 묻는다');
  assertEquals(consultReq.tools, undefined, '협의에는 도구가 없다');
  const text = requestText(consultReq);
  assert(text.includes('오답 통계를 실시간으로 낼 수 있나?'));
  assert(text.includes('반 단위 통계가 필요하다'));
  assert(text.includes('이번 대화 관점 (개발)'));
  assert(text.includes('채점 서버 분리'), '자기 부서 기억');
  assert(text.includes('공통 원칙'), '공통 기억');
  assert(!text.includes('교육 비공개 결정'), '다른 부서 기억은 보지 않는다');
  assert(!text.includes(OWNER_SECRET), '운영자 메시지 원문은 보지 않는다');
  assert(!text.includes('지난번 대화 원문'), '지난 대화도 보지 않는다');

  const consultEvents = events.of('consult');
  assertEquals(consultEvents.map((e) => e.status), ['running', 'done']);
  assertEquals(consultEvents[0].from, 'education');
  assertEquals(consultEvents[0].to, 'engineering');
  assertEquals(consultEvents[1].ok, true);

  const consultRun = runs.runs.find((r) => r.feature === 'think_consult')!;
  assert(consultRun);
  assertEquals(consultRun.status, 'ok');
  assertEquals(consultRun.conversationId, conv.id);
  assertEquals(runs.runs.find((r) => r.feature === 'think_chat')?.features?.consults, 1);

  const answer = store.messages.find((m) => m.id === out.assistantMessageId)!;
  const trace = answer.extra?.tool_calls?.find((t) => t.name === CONSULT_TOOL_NAME);
  assert(trace?.ok);
  assert(trace.detail.includes('오답 통계'), '협의 질문이 답변 기록에 남는다');
});

Deno.test('부서 협의: 지금 부서·잘못된 인자는 막고, 한 답변에 최대 횟수까지만 묻는다', async () => {
  const store = new MemoryThinkStore();
  const conv = await educationConversation(store);
  const outputs: Record<string, unknown>[] = [];
  let round = 0;
  const { provider } = await run(store, { conversationId: conv.id, features: READY }, (req) => {
    if (isConsult(req)) return { text: '의견' };
    round += 1;
    if (round === 1) {
      return {
        functionCalls: [
          { name: CONSULT_TOOL_NAME, arguments: { department: 'education', question: '같은 부서', background: '' } },
          { name: CONSULT_TOOL_NAME, arguments: { department: 'boss', question: '없는 부서', background: '' } },
          { name: CONSULT_TOOL_NAME, arguments: { department: 'engineering', question: '첫째', background: '' } },
          { name: CONSULT_TOOL_NAME, arguments: { department: 'product', question: '둘째', background: '' } },
          { name: CONSULT_TOOL_NAME, arguments: { department: 'lead', question: '셋째', background: '' } },
        ],
      };
    }
    for (const it of req.input) {
      if (it.kind === 'tool_result') outputs.push(JSON.parse(it.output));
    }
    return { text: '답' };
  });
  assertEquals(provider.requests.filter(isConsult).length, MAX_CONSULTS_PER_ANSWER);
  assertEquals(outputs.map((o) => o.error ?? 'ok'), ['consult_same_department', 'department_invalid', 'ok', 'ok', 'consult_limit']);
});

Deno.test('부서 협의 실패는 오류 결과로 돌려주고 답변은 이어진다', async () => {
  const store = new MemoryThinkStore();
  const conv = await educationConversation(store);
  let round = 0;
  const { out, events, runs } = await run(store, { conversationId: conv.id, features: READY }, (req) => {
    if (isConsult(req)) return { error: 'boom' };
    round += 1;
    if (round === 1) {
      return { functionCalls: [{ name: CONSULT_TOOL_NAME, arguments: { department: 'engineering', question: '가능?', background: '' } }] };
    }
    return { text: '협의 없이 답' };
  });
  assertEquals(out.status, 'complete');
  assertEquals(events.of('consult').at(-1)?.ok, false);
  assertEquals(runs.runs.find((r) => r.feature === 'think_consult')?.status, 'error');
});

Deno.test('부서 넘기기 제안: 한 답변에 하나, 지금 부서는 막고, 작업 상태에 부서 변화가 보인다', async () => {
  const store = new MemoryThinkStore();
  const conv = await educationConversation(store);
  const ctx = () => ({ conversationId: conv.id, memoryRefs: [], department: { currentRole: 'education', handoverProposed: false } });

  const same = await runThinkTool(HANDOVER_TOOL_NAME, JSON.stringify({ to_department: 'education', reason: '이유' }), store, 8000, ctx());
  assertEquals(JSON.parse(same.output).error, 'handover_same_department');

  const noReason = await runThinkTool(HANDOVER_TOOL_NAME, JSON.stringify({ to_department: 'product', reason: '' }), store, 8000, ctx());
  assertEquals(JSON.parse(noReason.output).error, 'missing_fields');

  const c = ctx();
  const ok = await runThinkTool(HANDOVER_TOOL_NAME, JSON.stringify({ to_department: 'product', reason: '문항 난이도 이야기가 중심' }), store, 8000, c);
  assert(ok.ok);
  assertEquals(ok.action?.kind, 'handover_department');
  const again = await runThinkTool(HANDOVER_TOOL_NAME, JSON.stringify({ to_department: 'engineering', reason: '구현' }), store, 8000, c);
  assertEquals(JSON.parse(again.output).error, 'handover_already_proposed');

  const off = await runThinkTool(HANDOVER_TOOL_NAME, JSON.stringify({ to_department: 'product', reason: 'x' }), store, 8000, {
    conversationId: conv.id,
    memoryRefs: [],
  });
  assertEquals(JSON.parse(off.output).error, 'handover_unavailable');

  const note = workStateNote(await store.getWorkState(conv.id))!;
  assert(note.includes('부서 넘기기 제안'));
  assert(note.includes('교육 → 문제 풀이'));
});

Deno.test('분류 제안: 부서 기능이 켜지면 다른 부서 폴더는 막고, 폴더 목록에 부서가 보인다', async () => {
  const store = new MemoryThinkStore();
  const conv = await educationConversation(store);
  const EDU = '11111111-1111-4111-8111-111111111111';
  const DEV = '22222222-2222-4222-8222-222222222222';
  store.folders = [
    { id: EDU, parent_id: null, title: '수업', department: 'education' },
    { id: DEV, parent_id: null, title: '구현', department: 'engineering' },
  ];
  const ctx = { conversationId: conv.id, memoryRefs: [], department: { currentRole: 'education', handoverProposed: false } };

  const list = JSON.parse((await runThinkTool('list_tree_folders', '{}', store, 8000, ctx)).output);
  assertEquals(list.folders.map((f: { department: string }) => f.department), ['education', 'engineering']);
  assertEquals(list.current_conversation.department, 'education');

  const other = await runThinkTool('propose_folder', JSON.stringify({ folder_id: DEV, reason: '' }), store, 8000, ctx);
  assertEquals(JSON.parse(other.output).error, 'folder_other_department');
  const otherParent = await runThinkTool(
    'propose_folder',
    JSON.stringify({ folder_id: null, new_folder_title: '새 폴더', new_folder_parent_id: DEV, reason: '' }),
    store,
    8000,
    ctx,
  );
  assertEquals(JSON.parse(otherParent.output).error, 'folder_other_department');
  const same = await runThinkTool('propose_folder', JSON.stringify({ folder_id: EDU, reason: '' }), store, 8000, ctx);
  assert(same.ok);

  store.folderListCalls = [];
  const legacy = await runThinkTool('propose_folder', JSON.stringify({ folder_id: DEV, reason: '' }), store, 8000, {
    conversationId: conv.id,
    memoryRefs: [],
  });
  assert(legacy.ok, '부서 기능 전에는 막지 않는다');
  assertEquals(store.folderListCalls, [{ department: false }], '부서 기능 전에는 부서 열을 읽지 않는다');
});
