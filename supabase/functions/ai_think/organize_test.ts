import { assert, assertEquals } from 'jsr:@std/assert@1';
import { FakeAiProvider, type FakeTurn } from '../_shared/ai/fake.ts';
import type { AiRequest } from '../_shared/ai/types.ts';
import { HANDOVER_TOOL_NAME, MEMORY_TOOL_NAME, SPLIT_TOOL_NAME, workStateNote } from './actions.ts';
import { runThinkChat, type ChatInput } from './chat.ts';
import { CONSULT_TOOL_NAME } from './consult.ts';
import { computeFeatures, isExclusionRequest, isImportanceRequest, isOrganizeRequest } from './features.ts';
import {
  CRITERIA_TOOL_NAME,
  EXCLUSION_TOOL_NAME,
  IMPORTANCE_TOOL_NAME,
  LIST_MESSAGES_TOOL_NAME,
  SUMMARY_TOOL_NAME,
} from './organize.ts';
import { THINK_PROMPT_VERSION } from './prompts.ts';
import { runThinkTool } from './tools.ts';
import { EventLog, memory, MemoryThinkStore, RunLog, testEnv } from './test_support.ts';

const ALL = { conversation_split: 1, think_roles: 1, memory_proposals: 1, department_work: 1, auto_organize: 1 };
const READY = computeFeatures({ ok: true, features: ALL }, ALL, true);
const OLD_APP = computeFeatures({ ok: true, features: ALL }, { ...ALL, auto_organize: 0 }, true);
const DB_REQUIRED = computeFeatures({ ok: true, features: { ...ALL, auto_organize: 0 } }, ALL, true);

const M1 = '11111111-1111-4111-8111-111111111111';
const M2 = '22222222-2222-4222-8222-222222222222';
const M3 = '33333333-3333-4333-8333-333333333333';

function input(partial: Partial<ChatInput>): ChatInput {
  return {
    userId: 'user-1',
    safetyId: 'hash',
    conversationId: null,
    message: '다음 단계는 뭐가 좋을까?',
    attachments: [],
    deep: false,
    webSearch: false,
    signal: new AbortController().signal,
    startedAt: Date.now(),
    wallClockMs: 140000,
    ...partial,
  };
}

async function run(store: MemoryThinkStore, partial: Partial<ChatInput>, script?: (req: AiRequest, i: number) => FakeTurn) {
  const provider = new FakeAiProvider(script ?? (() => ({ text: '답변' })));
  const events = new EventLog();
  const runs = new RunLog();
  const out = await runThinkChat(input(partial), { provider, store, recordRun: runs.record, emit: events.emit, env: testEnv });
  return { out, provider, events, runs };
}

const toolNames = (req: AiRequest) => (req.tools ?? []).map((t) => t.name);
const contextTexts = (req: AiRequest) => req.input.filter((i) => i.kind === 'context').map((i) => (i as { text: string }).text);
const featureNote = (req: AiRequest) => contextTexts(req).find((t) => t.startsWith('[실행 환경 기능 상태')) ?? '';

/** 앞 문답이 있는 교육 부서 대화. 메시지 id는 uuid로 넣는다(정리 도구는 uuid만 받는다). */
async function educationConversation(store: MemoryThinkStore) {
  const conv = await store.createConversation('자동 정리 설계');
  store.messages.push(
    { id: M1, conversation_id: conv.id, role: 'user', content: '정답률만으로 난이도를 정하자', status: 'complete', attachments: [], created_at: '2026-10-12T01:00:00Z' },
    { id: M2, conversation_id: conv.id, role: 'assistant', content: '정답률   기준 설명\n(나중에 정정됨)', status: 'complete', attachments: [], created_at: '2026-10-12T01:00:10Z' },
    { id: M3, conversation_id: conv.id, role: 'user', content: '아니, 풀이 시간도 같이 보자', status: 'complete', attachments: [], created_at: '2026-10-12T01:01:00Z' },
  );
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

const organizeCtx = (over: Record<string, unknown> = {}) => ({
  conversationId: 'conv-x',
  memoryRefs: [],
  organize: {
    userMessageId: 'msg-now',
    criteriaDepartment: 'education',
    userAskedExclusion: false,
    userAskedImportance: false,
    proposed: new Set<string>(),
    ...over,
  },
});
const parse = (r: { output: string }) => JSON.parse(r.output);

Deno.test('정리 요청 문구 판정: 직접 정리·제외·중요 표시 요청만 잡는다', () => {
  for (const m of ['이 대화 정리해 줘', '폴더로 분류하자', '요약 좀 해줘', '이건 기억해 둬', '앞 답변은 맥락에서 빼 줘', '부서 기준을 바꾸자']) {
    assert(isOrganizeRequest(m), m);
  }
  for (const m of ['다음 단계는 뭐가 좋을까?', '난이도 산정 방식이 궁금해', '정리된 생각이 아직 없어']) assert(!isOrganizeRequest(m), m);
  assert(isExclusionRequest('그 설명은 맥락에서 빼 줘'));
  assert(!isExclusionRequest('정답률 기준을 다시 설명해 줘'));
  assert(isImportanceRequest('이 답변 중요 표시해 줘'));
  assert(!isImportanceRequest('중요한 건 학생 경험이야'));
});

Deno.test('자동 정리 제안이 켜져 있으면 정리 도구·지침·부서 기준·기능 상태가 들어간다', async () => {
  const store = new MemoryThinkStore();
  const conv = await educationConversation(store);
  store.criteria.set('education', { department: 'education', questions: ['학생 경험이 나빠지지 않나?'], risks: ['점수로 학생을 재단'], priority_memory_ids: [], version: 3 });
  const { provider, events, runs } = await run(store, { conversationId: conv.id, features: READY });
  const req = provider.requests[0];
  for (const name of [LIST_MESSAGES_TOOL_NAME, EXCLUSION_TOOL_NAME, IMPORTANCE_TOOL_NAME, SUMMARY_TOOL_NAME, CRITERIA_TOOL_NAME, 'propose_folder']) {
    assert(toolNames(req).includes(name), name);
  }
  assert(req.instructions!.includes('## 정리 제안'));
  assert(req.instructions!.includes('이 부서(교육)의 기준'));
  assert(req.instructions!.includes('판 3'));
  assert(req.instructions!.includes('학생 경험이 나빠지지 않나?'));
  const note = featureNote(req);
  assert(note.includes('자동 정리 제안'));
  assert(note.includes('자동 제안 설정: 켜짐'));
  assert(note.includes('부서 기준'));
  assert(note.includes('확인을 기다리는 정리 제안: 0건'));
  assertEquals(events.of('conversation')[0].auto_organize, { enabled: true, asked: false, pending: 0 });
  assertEquals((runs.runs[0].features as Record<string, unknown>).organize_tools, true);
  assertEquals(runs.runs[0].promptVersion, THINK_PROMPT_VERSION);
});

Deno.test('자동 제안이 꺼져 있으면 직접 요청하지 않은 턴에는 분류·나누기·기억·넘기기·정리 도구를 모두 뺀다', async () => {
  const store = new MemoryThinkStore();
  const conv = await educationConversation(store);
  store.autoOrganize = false;
  const off = await run(store, { conversationId: conv.id, features: READY });
  const req = off.provider.requests[0];
  for (const name of ['propose_folder', SPLIT_TOOL_NAME, MEMORY_TOOL_NAME, HANDOVER_TOOL_NAME, LIST_MESSAGES_TOOL_NAME, EXCLUSION_TOOL_NAME, SUMMARY_TOOL_NAME]) {
    assert(!toolNames(req).includes(name), name);
  }
  assert(toolNames(req).includes(CONSULT_TOOL_NAME), '부서 협의는 정리 제안이 아니라서 그대로 둔다');
  assert(toolNames(req).includes('propose_code_request'));
  assert(!req.instructions!.includes('## 정리 제안'));
  assert(req.instructions!.includes('이 부서(교육)의 기준'), '승인된 부서 기준은 설정과 상관없이 참고한다');
  assert(featureNote(req).includes('자동 제안 설정: 꺼짐'));
  assert(featureNote(req).includes('직접 요청이 아니라서'));

  const asked = await run(store, { conversationId: conv.id, features: READY, message: '여기까지 정리해 줘' });
  const r2 = asked.provider.requests[0];
  assert(toolNames(r2).includes(SUMMARY_TOOL_NAME));
  assert(toolNames(r2).includes('propose_folder'));
  assert(featureNote(r2).includes('이번에만 정리 제안을 할 수 있다'));

  store.autoOrganize = null;
  const unknown = await run(store, { conversationId: conv.id, features: READY });
  assert(!toolNames(unknown.provider.requests[0]).includes('propose_folder'), '설정을 읽지 못하면 꺼진 것으로 본다');
  assert(featureNote(unknown.provider.requests[0]).includes('확인 불가'));
});

Deno.test('기능이 준비되지 않은 환경(옛 앱·옛 DB)과 커서 질문은 예전처럼 동작하고 정리 도구가 없다', async () => {
  for (const features of [OLD_APP, DB_REQUIRED, undefined]) {
    const store = new MemoryThinkStore();
    const conv = await educationConversation(store);
    store.autoOrganize = false;
    const { provider } = await run(store, { conversationId: conv.id, features });
    const req = provider.requests[0];
    assert(toolNames(req).includes('propose_folder'), '설정이 없는 환경에서는 분류 제안을 막지 않는다');
    assert(!toolNames(req).includes(EXCLUSION_TOOL_NAME));
    assert(!req.instructions!.includes('## 정리 제안'));
    assert(!req.instructions!.includes('의 기준 (사용자가 승인한 내용'));
    assert(!featureNote(req).includes('자동 제안 설정'));
  }
  const relayed = await run(new MemoryThinkStore(), { features: READY, relay: { asker: 'cursor_ide', title: '질문' } });
  const names = toolNames(relayed.provider.requests[0]);
  assert(!names.includes(LIST_MESSAGES_TOOL_NAME));
  assert(!names.includes(EXCLUSION_TOOL_NAME));
});

Deno.test('이번 요청에 주지 않은 도구를 모델이 불러도 실행하지 않는다', async () => {
  const store = new MemoryThinkStore();
  const conv = await educationConversation(store);
  store.autoOrganize = false;
  store.folders = [{ id: '44444444-4444-4444-8444-444444444444', parent_id: null, title: '교육', department: 'education' }];
  const { out, events } = await run(store, { conversationId: conv.id, features: READY }, (_req, i) =>
    i === 0
      ? { functionCalls: [{ name: 'propose_folder', arguments: { folder_id: store.folders[0].id, new_folder_title: null, new_folder_parent_id: null, reason: '분류' } }] }
      : { text: '답변' }
  );
  assertEquals(out.status, 'complete');
  const tool = events.of('tool').find((t) => t.status === 'done' && t.name === 'propose_folder')!;
  assertEquals(tool.ok, false);
  assertEquals(events.of('action').length, 0);
  assertEquals(store.actions.length, 0);
});

Deno.test('맥락 제외 제안: 목록에서 id를 확인해 제안하고, 카드는 답변에 붙으며 한 답변에 하나만 낸다', async () => {
  const store = new MemoryThinkStore();
  const conv = await educationConversation(store);
  store.messages.push({
    id: '55555555-5555-4555-8555-555555555555',
    conversation_id: conv.id,
    role: 'assistant',
    content: '이미 뺀 답변',
    status: 'complete',
    attachments: [],
    created_at: '2026-10-12T01:01:10Z',
    excluded: true,
  });
  const listed: unknown[] = [];
  const { out, events } = await run(store, { conversationId: conv.id, features: READY, message: '앞의 정답률 설명은 맥락에서 빼 줘' }, (req, i) => {
    if (i === 0) return { functionCalls: [{ name: LIST_MESSAGES_TOOL_NAME, arguments: { limit: null } }] };
    if (i === 1) {
      const result = req.input.find((it) => it.kind === 'tool_result') as { output: string };
      listed.push(...JSON.parse(result.output).messages);
      const args = { message_ids: [M2], reason: '사용자가 풀이 시간도 보자고 정정해 정답률만 쓰는 설명은 맞지 않다', impact: '이후 답변이 정답률만 쓰는 설명을 따르지 않는다' };
      return { functionCalls: [{ name: EXCLUSION_TOOL_NAME, arguments: args }, { name: EXCLUSION_TOOL_NAME, arguments: args }] };
    }
    return { text: '답변. 정정된 설명을 맥락에서 빼자고 제안했습니다.' };
  });
  assertEquals(out.status, 'complete');
  const ids = (listed as { id: string; excerpt: string; current?: boolean }[]).map((m) => m.id);
  assert(ids.includes(M2));
  assert(!ids.includes('55555555-5555-4555-8555-555555555555'), '제외된 메시지는 목록에 없다');
  assertEquals((listed as { id: string; excerpt: string }[]).find((m) => m.id === M2)!.excerpt, '정답률 기준 설명 (나중에 정정됨)');
  assert((listed as { current?: boolean }[]).some((m) => m.current === true), '이번 질문 표시');

  const done = events.of('tool').filter((t) => t.status === 'done' && t.name === EXCLUSION_TOOL_NAME);
  assertEquals(done.map((t) => t.ok), [true, false]);
  const cards = store.actions.filter((a) => a.kind === 'exclude_context');
  assertEquals(cards.length, 1);
  assertEquals(store.organizeCalls[0].args.user_requested, true, '사용자가 직접 빼 달라고 했다');
  assertEquals(cards[0].message_id, out.assistantMessageId);
  assertEquals(events.of('action').length, 1);
});

Deno.test('맥락 제외 도구: 형식이 틀린 id·모호한 이유·빠진 값·꺼진 턴·거절된 묶음을 오류로 돌려준다', async () => {
  const store = new MemoryThinkStore();
  const call = (args: Record<string, unknown>, ctx: Record<string, unknown> | undefined = organizeCtx()) =>
    runThinkTool(EXCLUSION_TOOL_NAME, JSON.stringify(args), store, 8000, ctx as never);
  const base = { message_ids: [M1], reason: '정정돼 더 이상 맞지 않는 설명', impact: '옛 설명을 따르지 않는다' };

  assertEquals(parse(await call(base, { conversationId: 'conv-x', memoryRefs: [] })).error, 'organize_unavailable');
  assertEquals(parse(await call({ ...base, message_ids: ['msg-1'] })).error, 'organize_id_invalid');
  assertEquals(parse(await call({ ...base, reason: '틀림' })).error, 'exclusion_reason_too_vague');
  assertEquals(parse(await call({ ...base, impact: ' ' })).missing, ['impact']);
  store.organizeFailure = 'organize_rejected_before';
  const rejected = parse(await call(base));
  assertEquals(rejected.error, 'organize_rejected_before');
  assert(String(rejected.next).includes('다시 제안하지 않는다'));
  assertEquals(store.actions.length, 0);
});

Deno.test('진행 요약 제안: 이번 질문을 반영 범위로 남기고, 담당·전제·완료 기준은 준 것만 남긴다', async () => {
  const store = new MemoryThinkStore();
  const ctx = organizeCtx();
  const r = await runThinkTool(
    SUMMARY_TOOL_NAME,
    JSON.stringify({
      summary: {
        purpose: '자동 정리 설계',
        decided: ['패널로 모은다', ' '],
        open: ['토글 위치'],
        status: 'DB 완료',
        next: [{ what: '앱 화면', owner: null, prerequisite: 'Edge 배포', done_when: null }, { what: ' ', owner: null, prerequisite: null, done_when: null }],
      },
      reason: '논의가 정리됨',
    }),
    store,
    8000,
    ctx as never,
  );
  assert(r.ok);
  const call = store.organizeCalls[0];
  assertEquals(call.args.through_message_id, 'msg-now');
  assertEquals(call.args.summary, {
    purpose: '자동 정리 설계',
    decided: ['패널로 모은다'],
    open: ['토글 위치'],
    status: 'DB 완료',
    next: [{ what: '앱 화면', owner: '', prerequisite: 'Edge 배포', done_when: '' }],
  });
  const again = await runThinkTool(SUMMARY_TOOL_NAME, JSON.stringify({ summary: { purpose: 'x', decided: [], open: [], status: '', next: [] }, reason: 'r' }), store, 8000, ctx as never);
  assertEquals(parse(again).error, 'organize_already_proposed');
  const noPurpose = await runThinkTool(SUMMARY_TOOL_NAME, JSON.stringify({ summary: { purpose: ' ' }, reason: 'r' }), store, 8000, organizeCtx() as never);
  assertEquals(parse(noPurpose).missing, ['summary.purpose']);
});

Deno.test('부서 기준 제안: 이 대화의 부서로만 내고, 역할이 적용되지 않은 턴에는 쓸 수 없다', async () => {
  const store = new MemoryThinkStore();
  const args = { questions: ['학생 경험은?'], risks: [], priority_memory_ids: [M3], reason: '사용자가 이 질문을 먼저 보자고 함' };
  const ok = await runThinkTool(CRITERIA_TOOL_NAME, JSON.stringify(args), store, 8000, organizeCtx() as never);
  assert(ok.ok);
  assertEquals(store.organizeCalls[0].args.department, 'education');
  assertEquals((store.organizeCalls[0].args.criteria as { priority_memory_ids: string[] }).priority_memory_ids, [M3]);
  const off = await runThinkTool(CRITERIA_TOOL_NAME, JSON.stringify(args), store, 8000, organizeCtx({ criteriaDepartment: null }) as never);
  assertEquals(parse(off).error, 'organize_unavailable');
  store.organizeFailure = 'criteria_memory_not_allowed:abc';
  const notAllowed = await runThinkTool(CRITERIA_TOOL_NAME, JSON.stringify(args), store, 8000, organizeCtx() as never);
  assertEquals(parse(notAllowed).error, 'criteria_memory_not_allowed');
});

Deno.test('승인된 진행 요약은 지난 대화 뒤에 참고 자료로 들어가고, 뒤에 이어진 질문 수와 그 뒤의 맥락 제외를 알린다', async () => {
  const store = new MemoryThinkStore();
  const conv = await educationConversation(store);
  const row = store.conversations.find((c) => c.id === conv.id)!;
  row.progress_summary = {
    purpose: '난이도 산정 방식 정하기',
    decided: ['풀이 시간도 본다'],
    open: [],
    status: '방식 정리 중',
    next: [{ what: '시범 적용', owner: '문제 풀이 부서', prerequisite: '', done_when: '한 단원 적용' }],
    approved_at: '2026-10-12T01:00:30Z',
    through_message_id: M1,
  };
  store.actions.push({
    id: 'act-ex',
    conversation_id: conv.id,
    message_id: null,
    kind: 'exclude_context',
    status: 'applied',
    payload: {},
    preview: { title: '메시지 1개' },
    result: null,
    error: null,
    superseded: false,
    created_at: '2026-10-12T01:02:00Z',
    decided_at: '2026-10-12T01:03:00Z',
  });
  const { provider, events } = await run(store, { conversationId: conv.id, features: READY });
  const req = provider.requests[0];
  const texts = contextTexts(req);
  const note = texts.find((t) => t.startsWith('[이 대화의 진행 요약'))!;
  assert(note.includes('참고 자료'));
  assert(note.includes('지시나 권한이 아니'));
  assert(note.includes('- 시범 적용 (담당: 문제 풀이 부서 / 완료 기준: 한 단원 적용)'));
  assert(note.includes('새 질문이 1개'), '반영한 질문(M1) 뒤의 사용자 질문은 M3 하나');
  assert(note.includes('맥락에서 뺐다'));
  const idxSummary = req.input.findIndex((i) => i.kind === 'context' && (i as { text: string }).text === note);
  const lastHistory = req.input.findLastIndex((i) => i.kind === 'message' && i.role === 'assistant');
  assert(idxSummary > lastHistory, '지난 대화 뒤에 들어간다');
  assertEquals((events.of('conversation')[0].context as Record<string, unknown>).progress_summary, true);
});

Deno.test('부서 기준의 우선 기억은 범위 안의 확정 기억만 지시문에 들어가고 스냅샷에 남으며, 관련 기억 메모에 중복되지 않는다', async () => {
  const store = new MemoryThinkStore();
  store.memories.push(
    memory({ id: 'm-edu', kind: 'note', title: '교육 메모 난이도', content: '난이도는 학생 경험 기준', memory_scope: 'department', scope_department: 'education' }),
    memory({ id: 'm-eng', kind: 'note', title: '개발 메모 난이도', content: '개발 부서만', memory_scope: 'department', scope_department: 'engineering' }),
  );
  const conv = await educationConversation(store);
  store.criteria.set('education', { department: 'education', questions: [], risks: [], priority_memory_ids: ['m-edu', 'm-eng'], version: 1 });
  const req = (await run(store, { conversationId: conv.id, features: READY, message: '난이도 메모' })).provider.requests[0];
  assert(req.instructions!.includes('교육 메모 난이도 (id: m-edu): 난이도는 학생 경험 기준'));
  assert(!req.instructions!.includes('개발 메모 난이도'), '이 부서가 볼 수 없는 기억은 넣지 않는다');
  const relevant = contextTexts(req).find((t) => t.startsWith('[이번 질문과 관련')) ?? '';
  assert(!relevant.includes('m-edu'));
  const snap = store.snapshots.at(-1)!;
  assert(snap.materials.some((m) => m.id === 'm-edu'));
  assert(!snap.materials.some((m) => m.id === 'm-eng'));
});

Deno.test('같은 답변에서 부서 넘기기를 제안한 뒤에는 그 부서 폴더로 분류를 제안할 수 있고, 카드에 넘기기 뒤 적용이라고 남는다', async () => {
  const store = new MemoryThinkStore();
  store.folders = [{ id: '66666666-6666-4666-8666-666666666666', parent_id: null, title: '개발 칸', department: 'engineering' }];
  const ctx = { ...organizeCtx(), department: { currentRole: 'lead', handoverProposed: false } };
  const folderArgs = JSON.stringify({ folder_id: store.folders[0].id, new_folder_title: null, new_folder_parent_id: null, reason: '구현 이야기' });
  const before = await runThinkTool('propose_folder', folderArgs, store, 8000, ctx as never);
  assertEquals(parse(before).error, 'folder_other_department');
  const handover = await runThinkTool(HANDOVER_TOOL_NAME, JSON.stringify({ to_department: 'engineering', reason: '구현 이야기로 넘어감' }), store, 8000, ctx as never);
  assert(handover.ok);
  const after = await runThinkTool('propose_folder', folderArgs, store, 8000, ctx as never);
  assert(after.ok);
  assertEquals(after.action!.preview.after_handover, 'engineering');
  const note = workStateNote(await store.getWorkState('conv-x'))!;
  assert(note.includes('부서 넘기기 승인 뒤 적용'));
});

Deno.test('자동 정리 기능이 없는 요청(승인 때 부서를 다시 확인하지 않는 옛 DB)에서는 넘기기를 제안해도 다른 부서 폴더로 분류하지 않는다', async () => {
  const store = new MemoryThinkStore();
  store.folders = [{ id: '66666666-6666-4666-8666-666666666666', parent_id: null, title: '개발 칸', department: 'engineering' }];
  const ctx = { conversationId: 'conv-x', memoryRefs: [], department: { currentRole: 'lead', handoverProposed: false } };
  const handover = await runThinkTool(HANDOVER_TOOL_NAME, JSON.stringify({ to_department: 'engineering', reason: '구현 이야기로 넘어감' }), store, 8000, ctx);
  assert(handover.ok);
  const folderArgs = JSON.stringify({ folder_id: store.folders[0].id, new_folder_title: null, new_folder_parent_id: null, reason: '구현 이야기' });
  const after = parse(await runThinkTool('propose_folder', folderArgs, store, 8000, ctx));
  assertEquals(after.error, 'folder_other_department');
  assert(String(after.next).includes('넘기기가 승인된 뒤'));

  const rule = '같은 답변에서 넘기기를 제안했으면';
  const old = new MemoryThinkStore();
  const oldConv = await educationConversation(old);
  assert(!(await run(old, { conversationId: oldConv.id, features: DB_REQUIRED })).provider.requests[0].instructions!.includes(rule));
  const ready = new MemoryThinkStore();
  const readyConv = await educationConversation(ready);
  assert((await run(ready, { conversationId: readyConv.id, features: READY })).provider.requests[0].instructions!.includes(rule));
});

Deno.test('작업 상태 메모: 새 정리 제안 종류의 상태를 알아볼 수 있게 적는다', () => {
  const base = { conversation_id: 'c', message_id: null, payload: {}, result: null, error: null, superseded: false, created_at: '' };
  const note = workStateNote({
    actions: [
      { ...base, id: 'a1', kind: 'exclude_context', status: 'applied', preview: { title: '메시지 2개' } },
      { ...base, id: 'a2', kind: 'mark_important', status: 'proposed', preview: { title: '메시지 1개' } },
      { ...base, id: 'a3', kind: 'progress_summary', status: 'applied', preview: { title: '자동 정리 설계' } },
      { ...base, id: 'a4', kind: 'department_criteria_change', status: 'rejected', preview: { title: '교육 부서 기준' } },
    ],
    codeRequests: [],
  })!;
  assert(note.includes('- 맥락 제외 제안 "메시지 2개": 사용자가 승인해 실행됨 (이후 답변 맥락에서 빠짐'));
  assert(note.includes('- 중요 표시 제안 "메시지 1개": 사용자 확인 대기'));
  assert(note.includes('- 진행 요약 제안 "자동 정리 설계": 사용자가 승인해 실행됨 (이 대화의 진행 요약으로 저장됨)'));
  assert(note.includes('- 부서 기준 변경 제안 "교육 부서 기준": 사용자가 거절함'));
});
