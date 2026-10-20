import { assert, assertEquals } from 'jsr:@std/assert@1';
import { FakeAiProvider } from '../_shared/ai/fake.ts';
import type { AiRunRecord } from '../_shared/ai/usage.ts';
import type { ConversationAccessState } from '../ai_think/access_context.ts';
import type { NewMessage } from '../ai_think/chat.ts';
import type { MemoryRow, MessageRow } from '../ai_think/context.ts';
import { MK_CTX_EXCL } from '../ai_think/document_markers.ts';
import { memory, testEnv } from '../ai_think/test_support.ts';
import {
  changeStatusLine,
  changeContext,
  continuedText,
  decisionScope,
  finalPlanIssues,
  fixSpec,
  followupPrompt,
  MAX_FIX_ATTEMPTS,
  parseChecks,
  parseDecisions,
  parsePlanReview,
  parseReview,
  runCodeReview,
  verificationOf,
  verificationText,
  type ReviewDeps,
  type ReviewRequest,
  type ReviewStore,
  type StartResult,
} from './code_review.ts';

class FakeReviewStore implements ReviewStore {
  req: ReviewRequest | null;
  memories: MemoryRow[] = [memory({ id: 'p1', kind: 'principle', title: '학생 중심', content: 'PRINCIPLE_TEXT' })];
  messages: (MessageRow & { excluded?: boolean })[] = [
    { id: 'm1', role: 'user', content: '홈 화면 위젯 어디서 그려?', status: 'complete', attachments: [], created_at: '' },
  ];
  inserted: NewMessage[] = [];
  followups: string[] = [];
  followupQuestions: string[][] = [];
  followupOk = true;
  plans: { requestId: string; messageId: string; title: string; spec: Record<string, unknown>; preview: Record<string, unknown> }[] = [];
  starts: { planRequestId: string; messageId: string; title: string; spec: Record<string, unknown> }[] = [];
  fixes: { requestId: string; messageId: string; spec: Record<string, unknown> }[] = [];
  startResult: StartResult = { ok: true, codeRequestId: 'chg-1' };
  fixResult: StartResult = { ok: true, codeRequestId: 'fix-1' };
  done: { status: string; messageId: string | null; error: string | null }[] = [];

  constructor(req: Partial<ReviewRequest> | null) {
    this.req = req === null ? null : {
      id: 'req-1',
      title: '홈 화면 조사',
      mode: 'investigate',
      status: 'ready',
      round: 1,
      max_rounds: 2,
      conversation_id: 'conv-1',
      created_by: 'user-1',
      request: { goal: '위젯 위치' },
      rounds: [{ round: 1, result: { summary: 'home_screen.dart에서 그린다', feasibility: 'possible' }, result_text: '원문', think_questions: [] }],
      ...req,
    };
  }
  loadRequest() {
    return Promise.resolve(this.req);
  }
  listMessages(_conversationId: string, limit: number) {
    return Promise.resolve(this.messages.filter((m) => !m.excluded).slice(-limit));
  }
  listActiveMemories() {
    return Promise.resolve(this.memories);
  }
  insertMessage(msg: NewMessage) {
    this.inserted.push(msg);
    return Promise.resolve(`msg-${this.inserted.length}`);
  }
  followup(_id: string, prompt: string, questions: string[]) {
    this.followups.push(prompt);
    this.followupQuestions.push(questions);
    return Promise.resolve(this.followupOk);
  }
  proposePlan(requestId: string, messageId: string, title: string, spec: Record<string, unknown>, preview: Record<string, unknown>) {
    this.plans.push({ requestId, messageId, title, spec, preview });
    return Promise.resolve(`act-${this.plans.length}`);
  }
  startChange(planRequestId: string, messageId: string, title: string, spec: Record<string, unknown>) {
    this.starts.push({ planRequestId, messageId, title, spec });
    return Promise.resolve(this.startResult);
  }
  fixChange(requestId: string, messageId: string, spec: Record<string, unknown>) {
    this.fixes.push({ requestId, messageId, spec });
    return Promise.resolve(this.fixResult);
  }
  reviewDone(_id: string, status: 'done' | 'skipped' | 'error', messageId: string | null, error: string | null) {
    this.done.push({ status, messageId, error });
    return Promise.resolve();
  }
}

function deps(store: FakeReviewStore, provider: FakeAiProvider | null, budget: { exceeded: boolean; mode: string } | null = null) {
  const runs: AiRunRecord[] = [];
  const d: ReviewDeps = {
    provider,
    store,
    recordRun: (rec) => {
      runs.push(rec);
      return Promise.resolve('run-1');
    },
    budget: () => Promise.resolve(budget),
    safetyId: (u) => Promise.resolve(`hash-${u}`),
    env: testEnv,
  };
  return { d, runs };
}

const answer = (o: Record<string, unknown>) => ({ text: JSON.stringify({ answer: '결론입니다.', followup_questions: [], conflicts: [], ...o }) });

Deno.test('검토 답변을 같은 대화에 붙이고 검토 완료로 남긴다', async () => {
  const store = new FakeReviewStore({});
  const provider = new FakeAiProvider([answer({ conflicts: ['원칙 A와 부딪힘'] })]);
  const { d, runs } = deps(store, provider);
  assertEquals(await runCodeReview(d, 'req-1'), 'done');
  assertEquals(store.inserted.length, 1);
  const msg = store.inserted[0];
  assertEquals(msg.conversation_id, 'conv-1');
  assertEquals(msg.role, 'assistant');
  assert(msg.content.includes('원칙 A와 부딪힘'));
  assertEquals(msg.tool_calls?.[0].name, 'code_review');
  assertEquals(store.done, [{ status: 'done', messageId: 'msg-1', error: null }]);
  assertEquals(runs[0].feature, 'code_review');

  const req = provider.requests[0];
  assert(req.jsonSchema?.name === 'code_review');
  assert(req.instructions!.includes('PRINCIPLE_TEXT'));
  const text = JSON.stringify(req.input);
  assert(text.includes('home_screen.dart'));
  assert(text.includes('홈 화면 위젯 어디서 그려?'));
});

Deno.test('context_excluded 메시지는 코드 결과 검토 AI 입력에 넣지 않는다', async () => {
  const store = new FakeReviewStore({});
  store.messages.push({
    id: 'm2',
    role: 'user',
    content: MK_CTX_EXCL,
    status: 'complete',
    attachments: [],
    created_at: '',
    excluded: true,
  });
  const provider = new FakeAiProvider([answer({})]);
  const { d } = deps(store, provider);
  assertEquals(await runCodeReview(d, 'req-1'), 'done');
  assert(!JSON.stringify(provider.requests[0].input).includes(MK_CTX_EXCL));
});

Deno.test('코드 결과 검토는 요청 대화의 역할 범위 기억만 AI에 넣는다', async () => {
  const store = new FakeReviewStore({}) as FakeReviewStore & {
    loadConversationAccess(id: string, ready: boolean): Promise<ConversationAccessState>;
  };
  store.memories.push(
    memory({ id: 'p-edu', kind: 'principle', title: '교육', content: 'EDU_TEXT', memory_scope: 'department', scope_department: 'education' }),
    memory({ id: 'p-eng', kind: 'principle', title: '개발', content: 'ENG_TEXT', memory_scope: 'department', scope_department: 'engineering' }),
    memory({ id: 'p-draft', kind: 'principle', title: '초안', content: 'DRAFT_TEXT', status: 'draft', memory_scope: 'common' }),
  );
  store.loadConversationAccess = (id, ready) =>
    Promise.resolve({
      conversationId: id,
      thinkRoleId: 'engineering',
      extraRefDepartments: [],
      linkedMemoryIds: new Set<string>(),
      linkedDocumentNodeIds: new Set<string>(),
      rolesFeatureReady: ready,
    });
  const provider = new FakeAiProvider([answer({})]);
  const { d } = deps(store, provider);
  assertEquals(await runCodeReview(d, 'req-1'), 'done');
  const instructions = provider.requests[0].instructions!;
  assert(instructions.includes('PRINCIPLE_TEXT'), '레거시 기억');
  assert(instructions.includes('ENG_TEXT'));
  assert(!instructions.includes('EDU_TEXT'));
  assert(!instructions.includes('DRAFT_TEXT'));
});

Deno.test('대화 범위를 읽지 못하는 검토 저장소는 부서 기억을 넣지 않는다', async () => {
  const store = new FakeReviewStore({});
  store.memories.push(
    memory({ id: 'p-eng', kind: 'principle', title: '개발', content: 'ENG_TEXT', memory_scope: 'department', scope_department: 'engineering' }),
  );
  const provider = new FakeAiProvider([answer({})]);
  const { d } = deps(store, provider);
  assertEquals(await runCodeReview(d, 'req-1'), 'done');
  assert(!provider.requests[0].instructions!.includes('ENG_TEXT'));
});

Deno.test('추가 질문이 있고 회차가 남았으면 2회차로 돌리고 답변은 붙이지 않는다', async () => {
  const store = new FakeReviewStore({});
  const { d } = deps(store, new FakeAiProvider([answer({ followup_questions: ['위젯 크기는 어디서 정해?'] })]));
  assertEquals(await runCodeReview(d, 'req-1'), 'followup');
  assertEquals(store.inserted.length, 0);
  assertEquals(store.done.length, 0);
  assert(store.followups[0].includes('위젯 크기는 어디서 정해?'));
  assert(store.followups[0].includes('home_screen.dart'), '앞 회차 요약을 담는다');
});

Deno.test('마지막 회차나 수정 모드에서는 추가 질문을 하지 않는다', async () => {
  for (const partial of [{ round: 2 }, { mode: 'change' }]) {
    const store = new FakeReviewStore(partial);
    const provider = new FakeAiProvider([answer({ followup_questions: ['더?'] })]);
    const { d } = deps(store, provider);
    assertEquals(await runCodeReview(d, 'req-1'), 'done');
    assertEquals(store.followups.length, 0);
    assert(provider.requests[0].instructions!.includes('항상 빈 배열'));
  }
});

Deno.test('수정 모드는 diff 앞부분을 검토에 넣는다', async () => {
  const store = new FakeReviewStore({
    mode: 'change',
    rounds: [{ round: 1, result: { summary: '색 변경', diff: 'diff --git a/x.dart b/x.dart\n+color', diff_stats: { files: 1 } }, result_text: null, think_questions: [] }],
  });
  const provider = new FakeAiProvider([answer({})]);
  const { d } = deps(store, provider);
  await runCodeReview(d, 'req-1');
  const text = JSON.stringify(provider.requests[0].input);
  assert(text.includes('diff --git a/x.dart'));
});

Deno.test('AI가 없거나 한도 차단이면 건너뛰고, 형식이 틀리면 오류로 남긴다', async () => {
  const s1 = new FakeReviewStore({});
  assertEquals(await runCodeReview(deps(s1, null).d, 'req-1'), 'skipped');
  assertEquals(s1.done[0].error, 'ai_not_configured');

  const s2 = new FakeReviewStore({});
  const p2 = new FakeAiProvider([answer({})]);
  assertEquals(await runCodeReview(deps(s2, p2, { exceeded: true, mode: 'block' }).d, 'req-1'), 'skipped');
  assertEquals(p2.requests.length, 0);

  const s3 = new FakeReviewStore({});
  const { d, runs } = deps(s3, new FakeAiProvider([{ text: '그냥 글' }]));
  assertEquals(await runCodeReview(d, 'req-1'), 'error');
  assertEquals(s3.done[0].status, 'error');
  assertEquals(runs[0].status, 'error');
  assertEquals(s3.inserted.length, 0);
});

Deno.test('대화 없는 요청은 검토하지 않는다', async () => {
  const store = new FakeReviewStore({ conversation_id: null });
  const provider = new FakeAiProvider([answer({})]);
  assertEquals(await runCodeReview(deps(store, provider).d, 'req-1'), 'skipped');
  assertEquals(provider.requests.length, 0);
});

Deno.test('검토 출력 해석과 2회차 프롬프트', () => {
  assertEquals(parseReview('{"answer":" ","followup_questions":[],"conflicts":[]}'), null);
  const p = parseReview('{"answer":"a","followup_questions":["1","2","3","4"],"conflicts":[]}');
  assertEquals(p?.followup_questions.length, 3);
  const prompt = followupPrompt(
    { id: 'r', title: 't', mode: 'investigate', status: 'ready', round: 1, max_rounds: 2, conversation_id: 'c', created_by: null, request: {}, rounds: [] },
    ['q1'],
  );
  assert(prompt.includes('2회차'));
  assert(prompt.includes('1. q1'));
});

// ---------------------------------------------------------------------------
// 조율 (plan)
// ---------------------------------------------------------------------------

const planReq: Partial<ReviewRequest> = {
  title: '대화 요약 문서',
  mode: 'plan',
  max_rounds: 3,
  request: { goal: '대화 구간을 문서로', instructions: ['테이블 추가'], background: '배경', memory_refs: [{ id: 'p1' }] },
  rounds: [{ round: 1, result: { summary: 'store.ts에 이미 비슷한 조회가 있다', issues: [{ problem: '중복' }] }, result_text: null, think_questions: [] }],
};

const planAnswer = (o: Record<string, unknown>) => ({
  text: JSON.stringify({
    answer: '조율했습니다.',
    followup_questions: [],
    conflicts: [],
    plan: { title: '요약 문서', goal: '대화 구간을 문서로', instructions: ['기존 조회 재사용', '문서 버전 열 추가'], focus_paths: ['supabase/functions/ai_think'], constraints: [], do_not: ['새 테이블'] },
    decisions: [
      {
        kind: 'disagreement',
        question: '버전을 얼마나 보관할까요?',
        context: 'Think는 전부, Cursor는 최근 10개',
        options: [
          { label: '전부 보관', detail: 'd1', recommended: false },
          { label: '최근 10개', detail: 'd2', recommended: true },
        ],
      },
      { kind: 'owner', question: '요약을 자동으로 만들까요?', context: '', options: [{ label: '예', detail: '', recommended: true }] },
    ],
    ...o,
  }),
});

Deno.test('조율: 다시 물을 것이 있으면 다음 회차로 돌리고, 질문 목록을 함께 남긴다', async () => {
  const store = new FakeReviewStore(planReq);
  const provider = new FakeAiProvider([planAnswer({ followup_questions: ['기존 조회를 그대로 써도 돼?'] })]);
  const { d } = deps(store, provider);
  assertEquals(await runCodeReview(d, 'req-1'), 'followup');
  assertEquals(store.followupQuestions, [['기존 조회를 그대로 써도 돼?']]);
  assert(store.followups[0].includes('질문·반론'));
  assertEquals(store.inserted.length, 0);
  assertEquals(store.plans.length, 0);
  assertEquals(provider.requests[0].jsonSchema?.name, 'code_plan_review');
});

Deno.test('조율: 끝나면 요약을 대화에 붙이고 조율본을 그 답변의 수정 제안으로 올린다', async () => {
  const store = new FakeReviewStore({ ...planReq, round: 2 });
  const { d } = deps(store, new FakeAiProvider([planAnswer({})]));
  assertEquals(await runCodeReview(d, 'req-1'), 'done');
  const msg = store.inserted[0];
  assertEquals(msg.tool_calls?.[0].name, 'code_plan_review');
  assert(msg.content.includes('버전을 얼마나 보관할까요?'), '정할 것을 답변에 알린다');
  assert(!msg.content.includes('요약을 자동으로 만들까요?'), '보기가 하나뿐인 질문은 버린다');
  assertEquals(store.plans.length, 1);
  const p = store.plans[0];
  assertEquals(p.messageId, 'msg-1');
  assertEquals(p.title, '요약 문서');
  assertEquals(p.spec.instructions, ['기존 조회 재사용', '문서 버전 열 추가']);
  assertEquals(p.spec.do_not, ['새 테이블']);
  assertEquals(p.spec.background, '배경');
  assertEquals(p.spec.memory_refs, [{ id: 'p1' }]);
  assertEquals((p.spec.based_on_plan as Record<string, unknown>).rounds, 2);
  assertEquals(p.preview.decisions, 1);
  const decisions = p.spec.decisions as { id: string; options: { id: string; label: string; recommended: boolean }[] }[];
  assertEquals(decisions.length, 1);
  const q = `${decisionScope({ id: 'req-1', round: 2 })}_q1`;
  assertEquals(decisions[0].id, q);
  assertEquals(decisions[0].options.map((o) => [o.id, o.label, o.recommended]), [
    [`${q}_1`, '최근 10개', true],
    [`${q}_2`, '전부 보관', false],
  ]);
  assertEquals(store.done[0].status, 'done');
});

Deno.test('조율 질문 해석: 추천은 하나만 맨 앞, 최대 5개', () => {
  const opt = (label: string, recommended = false) => ({ label, detail: '', recommended });
  const many = Array.from({ length: 7 }, (_, i) => ({ kind: 'owner', question: `Q${i}`, context: '', options: [opt('a'), opt('b')] }));
  assertEquals(parseDecisions(many).length, 5);
  const [d] = parseDecisions([{ kind: '?', question: 'q', context: 'c', options: [opt('a'), opt('b', true), opt('c', true), opt(' ')] }]);
  assertEquals(d.kind, 'owner');
  assertEquals(d.options.map((o) => [o.label, o.recommended]), [['b', true], ['a', false], ['c', false]]);
  assertEquals(parseDecisions([{ question: 'q', options: [opt('a'), opt('b')] }])[0].options.every((o) => !o.recommended), true);
  assertEquals(parseDecisions('x'), []);
});

Deno.test('조율: 운영자 답으로 다시 조율하면 답을 입력에 알리고, 새 조율본에도 운영자 결정을 남긴다', async () => {
  const store = new FakeReviewStore({
    ...planReq,
    round: 1,
    max_rounds: 1,
    request: {
      ...planReq.request,
      constraints: ['c0', '운영자 결정 — 보관: 전부'],
      owner_answers: [{ id: 'q1', question: '보관', answer: '전부' }],
    },
  });
  const provider = new FakeAiProvider([
    planAnswer({
      decisions: [],
      plan: { title: 't', goal: 'g', instructions: ['a'], focus_paths: [], constraints: ['새 제약'], do_not: [] },
    }),
  ]);
  assertEquals(await runCodeReview(deps(store, provider).d, 'req-1'), 'done');
  assert(JSON.stringify(provider.requests[0].input).includes('운영자가 고른 답'));
  assert(provider.requests[0].instructions!.includes('마지막 회차'));
  assertEquals(store.plans.length, 0, '더 물을 것이 없으면 승인 대기 카드 대신 바로 수정을 보낸다');
  const p = store.starts[0];
  assertEquals(p.spec.constraints, ['운영자 결정 — 보관: 전부', '새 제약']);
  assertEquals((p.spec.owner_answers as unknown[]).length, 1);
  assertEquals(p.spec.decisions, []);
});

Deno.test('조율: 물을 것이 없으면 조율본대로 바로 수정을 보내고 답변에 알린다', async () => {
  const store = new FakeReviewStore({ ...planReq, round: 2 });
  const { d } = deps(store, new FakeAiProvider([planAnswer({ decisions: [] })]));
  assertEquals(await runCodeReview(d, 'req-1'), 'done');
  assertEquals(store.plans.length, 0);
  assertEquals(store.starts.length, 1);
  assertEquals(store.starts[0].planRequestId, 'req-1');
  assertEquals(store.starts[0].messageId, 'msg-1');
  assertEquals(store.starts[0].title, '요약 문서');
  assertEquals(store.starts[0].spec.instructions, ['기존 조회 재사용', '문서 버전 열 추가']);
  assertEquals(store.inserted.length, 1);
  assert(store.inserted[0].content.includes('Cursor에게 수정을 맡겼습니다'));
});

Deno.test('조율본 작업 강도: 수정에 맞게 다시 고른 값을 쓰고, 없으면 조율 요청의 강도를 잇는다', async () => {
  const plan = { title: 't', goal: 'g', instructions: ['a'], focus_paths: [], constraints: [], do_not: [] };
  const run = async (planExtra: Record<string, unknown>, request: Record<string, unknown>) => {
    const store = new FakeReviewStore({ ...planReq, round: 2, request: { ...planReq.request, ...request } });
    const provider = new FakeAiProvider([planAnswer({ decisions: [], plan: { ...plan, ...planExtra } })]);
    assertEquals(await runCodeReview(deps(store, provider).d, 'req-1'), 'done');
    return store.starts[0].spec;
  };
  const picked = await run({ effort: 'xhigh', effort_reason: 'DB와 앱을 함께 바꾼다' }, { effort: 'medium', effort_reason: '조사만' });
  assertEquals([picked.effort, picked.effort_reason], ['xhigh', 'DB와 앱을 함께 바꾼다']);
  const kept = await run({ effort: null, effort_reason: null }, { effort: 'medium', effort_reason: '조사만' });
  assertEquals([kept.effort, kept.effort_reason], ['medium', '조사만']);
  const old = await run({}, {});
  assertEquals([old.effort, old.effort_reason], ['high', null]);
});

Deno.test('이어받기: 조율본이 앞 수정 지정을 수정 요청에 넘기고, 검토 입력에 얹힌 패치를 알린다', async () => {
  const from = { request_id: 'prev-1', title: '개인화' };
  const continued = { request_id: 'prev-1', title: '개인화', round: 2, files: 20, additions: 300, deletions: 12, applied: 'merged' };
  const store = new FakeReviewStore({
    ...planReq,
    round: 2,
    request: { ...planReq.request, continue_from: from },
    rounds: [{ round: 2, result: { summary: 's', continued_from: continued }, result_text: null, think_questions: [] }],
  });
  const provider = new FakeAiProvider([planAnswer({ decisions: [] })]);
  assertEquals(await runCodeReview(deps(store, provider).d, 'req-1'), 'done');
  assertEquals(store.starts[0].spec.continue_from, from);
  const input = JSON.stringify(provider.requests[0].input);
  assert(input.includes('이어받은 앞 수정 패치'));
  assert(input.includes('prev-1'));

  assertEquals(continuedText(null, true), '');
  assertEquals(continuedText({ continued_from: 'x' }, true), '');
  assert(continuedText({ continued_from: continued }, true).includes('작업 폴더에 적용하면 앞 수정도'));
  assert(!continuedText({ continued_from: { ...continued, applied: 'already_present' } }, true).includes('작업 폴더에 적용하면'));
  assert(continuedText({ continued_from: continued }, false).includes('읽고 검토'));
  assert(!continuedText({ continued_from: continued }, true).includes('미완성'));
  const stopped = continuedText({ continued_from: { ...continued, partial: 'timeout' } }, true);
  assert(stopped.includes('미완성 패치'));
  assert(stopped.includes('최종 diff 전체'));
});

Deno.test('조율: 바로 보내지 못하면(하루 한도) 승인 대기 카드로 남기고 이유를 알린다', async () => {
  const store = new FakeReviewStore({ ...planReq, round: 2 });
  store.startResult = { ok: false, error: 'code_request_daily_limit' };
  const { d } = deps(store, new FakeAiProvider([planAnswer({ decisions: [] })]));
  assertEquals(await runCodeReview(d, 'req-1'), 'done');
  assertEquals(store.starts.length, 1);
  assertEquals(store.plans.length, 1);
  assertEquals(store.inserted.length, 2);
  assert(store.inserted[1].content.includes('한도'));
});

Deno.test('조율: 운영자에게 물을 것이 있으면 바로 보내지 않는다', async () => {
  const store = new FakeReviewStore({ ...planReq, round: 2 });
  const { d } = deps(store, new FakeAiProvider([planAnswer({})]));
  await runCodeReview(d, 'req-1');
  assertEquals(store.starts.length, 0);
  assertEquals(store.plans.length, 1);
  assert(!store.inserted[0].content.includes('맡겼습니다'));
});

// ---------------------------------------------------------------------------
// 수정 결과 + 자동 검사
// ---------------------------------------------------------------------------

const item = (id: string, status: string, output = '') => ({
  id,
  label: `${id} 검사`,
  status,
  reason: null,
  command: `cmd ${id}`,
  output,
  cwd: null,
  exit_code: null,
  duration_ms: null,
  scope: 'required' as const,
  source: 'auto' as const,
  env: false,
});
const changeReq = (verification: unknown, request: Record<string, unknown> = { goal: 'g', instructions: ['a'] }, status = 'ready'): Partial<ReviewRequest> => ({
  mode: 'change',
  status,
  title: '수정',
  request,
  rounds: [{
    round: 1,
    result: { summary: '고침', diff: 'diff --git a/x.dart b/x.dart\n+x', diff_stats: { files: 1 }, ...(verification === undefined ? {} : { verification }) },
    result_text: null,
    think_questions: [],
  }],
});

Deno.test('수정: 이번 수정 때문에 실패한 검사가 있으면 실패 내용을 붙여 다시 고치게 한다', async () => {
  const v = { items: [item('analyze', 'passed'), item('test', 'failed', 'Expected: 3 Actual: 2'), item('old', 'preexisting', 'OLD'), item('gw', 'skipped')] };
  const store = new FakeReviewStore(changeReq(v));
  const provider = new FakeAiProvider([answer({})]);
  assertEquals(await runCodeReview(deps(store, provider).d, 'req-1'), 'done');
  const input = JSON.stringify(provider.requests[0].input);
  assert(input.includes('통과 1 · 실패 1 · 미실행 1 · 원래도 실패 1'));
  assert(input.includes('Expected: 3 Actual: 2'));
  assert(provider.requests[0].instructions!.includes(`1/${MAX_FIX_ATTEMPTS}회째`));
  assertEquals(store.fixes.length, 1);
  const fix = store.fixes[0];
  assertEquals(fix.requestId, 'req-1');
  assertEquals(fix.messageId, 'msg-1');
  const fixOf = fix.spec.fix_of as Record<string, unknown>;
  assertEquals(fixOf.request_id, 'req-1');
  assertEquals(fixOf.root_id, 'req-1');
  assertEquals(fixOf.attempt, 1);
  assertEquals((fixOf.failed as { label: string }[]).map((f) => f.label), ['test 검사'], '원래도 실패·미실행은 고치게 하지 않는다');
  assertEquals(fix.spec.instructions, ['a']);
  assert(store.inserted[0].content.includes('다시 고치게 했습니다'));
});

Deno.test('수정: 재수정을 다 썼거나 실패가 없으면 다시 보내지 않는다', async () => {
  const failing = { items: [item('test', 'failed', 'x')] };
  const last = new FakeReviewStore(changeReq(failing, { goal: 'g', fix_of: { request_id: 'prev', root_id: 'root', attempt: MAX_FIX_ATTEMPTS } }));
  const p1 = new FakeAiProvider([answer({})]);
  await runCodeReview(deps(last, p1).d, 'req-1');
  assertEquals(last.fixes.length, 0);
  assert(p1.requests[0].instructions!.includes('다 썼거나'));
  assert(p1.requests[0].instructions!.includes(`${MAX_FIX_ATTEMPTS}번째 재수정`));

  for (const v of [{ items: [item('a', 'passed'), item('b', 'preexisting')] }, { items: [], note: '문서만' }]) {
    const store = new FakeReviewStore(changeReq(v));
    await runCodeReview(deps(store, new FakeAiProvider([answer({})])).d, 'req-1');
    assertEquals(store.fixes.length, 0);
    assert(!store.inserted[0].content.includes('다시 고치게'));
  }

  const applied = new FakeReviewStore(changeReq(failing, undefined, 'applied'));
  await runCodeReview(deps(applied, new FakeAiProvider([answer({})])).d, 'req-1');
  assertEquals(applied.fixes.length, 0, '이미 적용한 요청은 다시 고치지 않는다');
});

Deno.test('수정: 검사 기록이 없으면 검사 안 됨으로 보고하게 한다', async () => {
  const store = new FakeReviewStore(changeReq(undefined));
  const provider = new FakeAiProvider([answer({})]);
  await runCodeReview(deps(store, provider).d, 'req-1');
  assert(JSON.stringify(provider.requests[0].input).includes('(검사 기록 없음)'));
  assert(provider.requests[0].instructions!.includes('검사 안 됨'));
  assertEquals(store.fixes.length, 0);
});

Deno.test('수정: 재수정을 보내지 못하면(하루 한도) 이유를 따로 알린다', async () => {
  const store = new FakeReviewStore(changeReq({ items: [item('test', 'failed')] }));
  store.fixResult = { ok: false, error: 'code_request_daily_limit' };
  await runCodeReview(deps(store, new FakeAiProvider([answer({})])).d, 'req-1');
  assertEquals(store.inserted.length, 2);
  assert(store.inserted[1].content.includes('한도'));
});

Deno.test('재수정 요청 내용: 앞 재수정의 뿌리를 잇고, 크기를 줄인다', () => {
  const req: ReviewRequest = {
    id: 'r2', title: 't', mode: 'change', status: 'ready', round: 1, max_rounds: 1, conversation_id: 'c', created_by: null,
    request: { goal: 'g', fix_of: { request_id: 'r1', root_id: 'r0', attempt: 1, failed: [] } },
    rounds: [],
  };
  const big = 'x'.repeat(20_000);
  const spec = fixSpec(req, Array.from({ length: 10 }, (_, i) => ({ ...item(`t${i}`, 'failed', big), status: 'failed' as const })));
  const fixOf = spec.fix_of as { request_id: string; root_id: string; attempt: number; failed: { output: string }[] };
  assertEquals([fixOf.request_id, fixOf.root_id, fixOf.attempt], ['r2', 'r0', 2]);
  assertEquals(fixOf.failed.length, 8);
  assert(new TextEncoder().encode(JSON.stringify(spec)).length <= 45_000);
  assertEquals(spec.goal, 'g');
});

Deno.test('검사 결과 해석: 모르는 상태는 미실행, 요약은 다시 센다', () => {
  const v = verificationOf({ verification: { summary: { passed: 99 }, items: [item('a', 'passed'), item('b', 'weird'), 'x'] } });
  assertEquals(v?.summary, { passed: 1, failed: 0, skipped: 1, preexisting: 0 });
  assertEquals(verificationOf({ verification: 'x' }), null);
  assertEquals(verificationOf(null), null);
});

Deno.test('조율: 단계가 비어도 정할 것이 있으면 조율본 카드를 올린다', async () => {
  const store = new FakeReviewStore({ ...planReq, round: 3 });
  const provider = new FakeAiProvider([
    planAnswer({ plan: { title: 't', goal: 'g', instructions: [], focus_paths: [], constraints: [], do_not: [] } }),
  ]);
  assertEquals(await runCodeReview(deps(store, provider).d, 'req-1'), 'done');
  assertEquals(store.plans.length, 1);
});

Deno.test('조율: 3회차면 더 묻지 않고 끝내며, 하지 않기로 했으면 수정 제안을 올리지 않는다', async () => {
  const store = new FakeReviewStore({ ...planReq, round: 3 });
  const provider = new FakeAiProvider([
    planAnswer({
      followup_questions: ['더?'],
      decisions: [],
      plan: { title: 't', goal: 'g', instructions: [], focus_paths: [], constraints: [], do_not: [] },
    }),
  ]);
  const { d } = deps(store, provider);
  assertEquals(await runCodeReview(d, 'req-1'), 'done');
  assertEquals(store.followups.length, 0);
  assert(provider.requests[0].instructions!.includes('마지막 회차'));
  assertEquals(store.inserted.length, 1);
  assertEquals(store.plans.length, 0);
});

Deno.test('조율: 앞 회차에 Think가 물은 것을 검토 입력에 넣는다', async () => {
  const store = new FakeReviewStore({
    ...planReq,
    round: 2,
    rounds: [
      ...planReq.rounds!,
      { round: 2, result: { summary: '그대로 써도 된다' }, result_text: null, think_questions: ['THINK_Q_MARK'] },
    ],
  });
  const provider = new FakeAiProvider([planAnswer({})]);
  await runCodeReview(deps(store, provider).d, 'req-1');
  const text = JSON.stringify(provider.requests[0].input);
  assert(text.includes('THINK_Q_MARK'));
  assert(text.includes('처음 계획 초안'));
});

// ---------------------------------------------------------------------------
// 운영자 답 반영과 최종 지시 (요청 0cb6972e·8fe0e9c8에서 본 증상)
// ---------------------------------------------------------------------------

const answeredSpec = {
  goal: '원본 비교 준비',
  instructions: ['공통 입력 파일을 만든다', '비교 준비 스크립트를 만든다'],
  constraints: ['운영 DB에 연결하지 않는다', '운영자 결정 — 산출물 범위를 줄일까요?: 전체 유지'],
  checks: [{ cwd: 'gateway', command: 'node --test test/', why: '시험' }],
  owner_answers: [{ id: 'q1', plan_request_id: 'p-old', answer_round: 1, question: '산출물 범위를 줄일까요?', answer: '전체 유지' }],
  discarded_branches: [
    { kind: 'option', decision_id: 'q1', question: '산출물 범위를 줄일까요?', label: '축소', instructions: ['축소안 승인 시 gateway/test에 시험만 추가한다'] },
    { kind: 'hold', decision_id: 'q1', question: '산출물 범위를 줄일까요?', holds: ['산출물 범위는 운영자 답변 전 확정하지 않는다'] },
  ],
};

Deno.test('질문 id는 조율 요청·회차마다 달라 다른 회차의 q1과 겹치지 않는다', () => {
  const raw = [{ kind: 'owner', question: 'q', context: '', holds: ['h'], options: [{ label: 'a', detail: '', recommended: true, instructions: ['A 단계'] }, { label: 'b', detail: '', recommended: false, instructions: [] }] }];
  const a = parseDecisions(raw, decisionScope({ id: '0cb6972e-e8b9-4949-9450-5cd05c950e0e', round: 1 }));
  const b = parseDecisions(raw, decisionScope({ id: '8fe0e9c8-05bc-4a64-b9cb-9041943469af', round: 1 }));
  assertEquals(a[0].id, 'p0cb6972er1_q1');
  assertEquals(b[0].id, 'p8fe0e9c8r1_q1');
  assertEquals(a[0].options[0].id, 'p0cb6972er1_q1_1');
  assertEquals(a[0].options[0].instructions, ['A 단계']);
  assertEquals(a[0].holds, ['h']);
  assertEquals(parseDecisions(raw)[0].id, 'q1', '앞머리가 없으면 예전 모양');
});

Deno.test('필수 검사 해석: 폴더 표기를 맞추고 겹친 것은 하나로', () => {
  assertEquals(parseChecks([
    { cwd: './gateway/', command: 'node   --test test/', why: 'w' },
    { cwd: 'gateway', command: 'node --test test/', why: 'dup' },
    { cwd: '', command: 'node --test tools/v2_a4_compare/test/', why: '' },
    { cwd: 'x', command: ' ', why: '' },
    'x',
  ]), [
    { cwd: 'gateway', command: 'node --test test/', why: 'w' },
    { cwd: '.', command: 'node --test tools/v2_a4_compare/test/', why: '' },
  ]);
});

Deno.test('최종 지시 검사: 남은 분기·대기 조건·버린 분기를 잡고, 운영자 결정 줄과 기능 설명은 두지 않는다', () => {
  const plan = parsePlanReview(JSON.stringify({
    answer: 'a', followup_questions: [], conflicts: [], decisions: [],
    plan: {
      title: 't', goal: 'g', focus_paths: [], do_not: [], checks: [], effort: null, effort_reason: null,
      instructions: [
        '공통 입력 파일을 만든다',
        '운영자가 비교 이미지 묶음을 선택하면 PNG 쌍을 만든다',
        '축소안 승인 시 gateway/test에 시험만 추가한다',
        '답변 대기 조건과 별도의 기존 뷰어용 CSV 구현 분기는 삭제한다',
        '카드에서 사용자가 날짜를 선택하면 목록이 바뀐다',
      ],
      constraints: ['답이 확정되기 전에는 수정 작업을 시작하지 않는다', '운영자 결정 — 비교 형태: 이미지 묶음', '운영 DB에 연결하지 않는다'],
    },
  }))!.plan;
  const flagged = finalPlanIssues(plan, answeredSpec);
  assertEquals(flagged.length, 4);
  assert(flagged.some((f) => f.includes('축소안') && f.includes('버린 분기와 같음')));
  assert(flagged.some((f) => f.startsWith('제약: 답이 확정되기 전')));
  assert(!flagged.some((f) => f.includes('날짜를 선택하면')));
  assert(!flagged.some((f) => f.includes('운영자 결정')));
});

Deno.test('조율: 최종 지시에 분기가 남으면 Think에게 한 번 고치게 하고, 고친 지시로 수정을 시작한다', async () => {
  const store = new FakeReviewStore({ ...planReq, round: 1, max_rounds: 1, request: answeredSpec });
  const dirty = {
    title: 't', goal: 'g', focus_paths: [], do_not: [], checks: [], effort: null, effort_reason: null,
    instructions: ['공통 입력 파일을 만든다', '축소안 승인 시 gateway/test에 시험만 추가한다'],
    constraints: ['비교 형태는 운영자 답변 후 확정한다', '운영자 결정 — 산출물은 전부 유지한다'],
  };
  const clean = { ...dirty, instructions: ['공통 입력 파일을 만든다', '비교 준비 스크립트를 만든다'], constraints: ['운영 DB에 연결하지 않는다'], checks: [] };
  const provider = new FakeAiProvider([planAnswer({ decisions: [], plan: dirty }), planAnswer({ decisions: [], plan: clean })]);
  assertEquals(await runCodeReview(deps(store, provider).d, 'req-1'), 'done');
  assertEquals(provider.requests.length, 2);
  const retry = JSON.stringify(provider.requests[1].input);
  assert(retry.includes('최종 지시 검사'));
  assert(retry.includes('축소안 승인 시'));
  assertEquals(store.starts.length, 1);
  const spec = store.starts[0].spec;
  assertEquals(spec.instructions, ['공통 입력 파일을 만든다', '비교 준비 스크립트를 만든다']);
  assertEquals(spec.constraints, ['운영자 결정 — 산출물 범위를 줄일까요?: 전체 유지', '운영 DB에 연결하지 않는다']);
  assertEquals(spec.checks, answeredSpec.checks, 'Think가 checks를 비우면 앞 요청의 필수 검사를 잇는다');
  assertEquals((spec.discarded_branches as unknown[]).length, 2);
  const fc = spec.final_check as { flagged: string[]; retried: boolean; remaining: string[] };
  assertEquals(fc.retried, true);
  const added = { ...clean, checks: [{ cwd: 'tools/db_test', command: 'node --test test/x.test.mjs', why: '추가' }] };
  const store2 = new FakeReviewStore({ ...planReq, round: 1, max_rounds: 1, request: answeredSpec });
  await runCodeReview(deps(store2, new FakeAiProvider([planAnswer({ decisions: [], plan: added })])).d, 'req-1');
  assertEquals(store2.starts[0].spec.checks, [...(answeredSpec.checks as unknown[]), { cwd: 'tools/db_test', command: 'node --test test/x.test.mjs', why: '추가' }], '요청한 필수 검사는 빠지지 않고 Think가 더한 검사가 뒤에 붙는다');
  assertEquals(fc.flagged.length, 2);
  assertEquals(fc.remaining, []);
  const first = JSON.stringify(provider.requests[0].input);
  assert(first.includes('운영자가 고른 답'));
  assert(first.includes('버린 분기'));
  assert(!first.includes('"discarded_branches"'), '버린 분기는 요청 JSON이 아니라 따로 보인다');
});

Deno.test('조율: 다시 고쳐도 남은 줄은 기능 설명일 수 있어 막지 않되, 버린 분기와 같은 줄과 Think가 쓴 운영자 결정 줄은 뺀다', async () => {
  const store = new FakeReviewStore({ ...planReq, round: 1, max_rounds: 1, request: answeredSpec });
  const plan = {
    title: 't', goal: 'g', focus_paths: [], do_not: [], checks: [], effort: null, effort_reason: null,
    instructions: ['공통 입력 파일을 만든다', '축소안 승인 시 gateway/test에 시험만 추가한다', '운영자가 적용을 승인하면 작업자가 패치를 적용한다'],
    constraints: ['운영자 결정 — 산출물은 전부 유지한다'],
  };
  const provider = new FakeAiProvider([planAnswer({ decisions: [], plan }), planAnswer({ decisions: [], plan })]);
  assertEquals(await runCodeReview(deps(store, provider).d, 'req-1'), 'done');
  const spec = store.starts[0].spec;
  assertEquals(spec.instructions, ['공통 입력 파일을 만든다', '운영자가 적용을 승인하면 작업자가 패치를 적용한다']);
  assertEquals(spec.constraints, ['운영자 결정 — 산출물 범위를 줄일까요?: 전체 유지']);
  assertEquals((spec.final_check as { remaining: string[] }).remaining.length, 2);
});

Deno.test('조율: 정할 것이 남아 있으면 최종 지시 검사를 하지 않는다', async () => {
  const store = new FakeReviewStore({ ...planReq, round: 2 });
  const provider = new FakeAiProvider([planAnswer({})]);
  await runCodeReview(deps(store, provider).d, 'req-1');
  assertEquals(provider.requests.length, 1);
  assertEquals(store.plans[0].spec.final_check, undefined);
});

// ---------------------------------------------------------------------------
// 완료 상태: 코드 작성 / 필수 검사 판정 / 확인할 것 / 적용
// ---------------------------------------------------------------------------

Deno.test('필수 검사 판정: 실행 못 한 필수 검사는 통과가 아니고, 후속 확인은 판정에 넣지 않는다', () => {
  const v = (items: unknown[], extra: Record<string, unknown> = {}) => verificationOf({ verification: { items, ...extra } })!;
  assertEquals(v([item('a', 'passed'), item('b', 'preexisting')]).verdict, 'passed');
  assertEquals(v([item('a', 'passed'), { ...item('gw', 'skipped'), env: true }]).verdict, 'not_run');
  assertEquals(v([item('a', 'passed'), item('b', 'failed')]).verdict, 'failed');
  assertEquals(v([item('a', 'passed'), { ...item('db', 'skipped'), scope: 'followup' }]).verdict, 'passed');
  assertEquals(v([]).verdict, 'none');
  assertEquals(v([item('a', 'passed')], { stopped: true }).verdict, 'not_run');
  assertEquals(v([{ id: 'db-test-other', label: 'x', status: 'skipped' }]).verdict, 'none', '예전 기록의 AI 영역 밖 DB 항목은 후속 확인');
  const text = verificationText(v([
    { ...item('gw', 'passed'), cwd: 'gateway', exit_code: 0, duration_ms: 2400, source: 'request', command: 'node --test test/a.test.js' },
    { ...item('flutter', 'skipped'), env: true, reason: 'flutter를 찾지 못했습니다.' },
  ], { patch_sha256: 'a'.repeat(64) }));
  assert(text.startsWith('필수 검사 일부 실행 못 함'));
  assert(text.includes('검사한 패치 aaaaaaaaaaaa'));
  assert(text.includes('[요청한 검사]'));
  assert(text.includes('폴더 gateway, 종료 코드 0, 2.4초'));
  assert(text.includes('[환경]'));
});

Deno.test('수정 결과 답 끝에 서버가 실행 기록으로 만든 작업 상태를 붙인다', async () => {
  const v = { items: [item('a', 'passed'), { ...item('gw', 'skipped'), env: true }], patch_sha256: 'b'.repeat(64) };
  const store = new FakeReviewStore(changeReq(v));
  store.req!.rounds[0].result!.checks = ['화면 확인'];
  const provider = new FakeAiProvider([answer({ answer: '시험을 모두 통과했습니다.' })]);
  await runCodeReview(deps(store, provider).d, 'req-1');
  const content = store.inserted[0].content;
  assert(content.includes('**작업 상태**'));
  assert(content.includes('코드 작성: 완료 (파일 1개)'));
  assert(content.includes('필수 검사 일부 실행 못 함 (통과 1 · 실패 0 · 실행 못 함 1)'));
  assert(content.includes('확인할 것: 1개'));
  assert(content.includes('작업 폴더 적용은 승인 대기'));
  assert(provider.requests[0].instructions!.includes('실행 기록뿐'));
  assertEquals(store.fixes.length, 0, '환경 때문에 못 돌린 검사는 다시 고치게 하지 않는다');

  const none = new FakeReviewStore(changeReq(undefined));
  await runCodeReview(deps(none, new FakeAiProvider([answer({})])).d, 'req-1');
  assert(none.inserted[0].content.includes('검사 기록 없음 (통과 아님)'));
  assert(none.inserted[0].content.includes('권하지 않음'));
});

Deno.test('재수정은 이번 수정에 필요한 검사 실패만 보고 정한다', () => {
  const r = (items: unknown[]) => changeContext({ ...new FakeReviewStore(changeReq({ items })).req! });
  assertEquals(r([{ ...item('x', 'failed'), scope: 'followup' }]).willFix, false);
  assertEquals(r([item('x', 'failed')]).willFix, true);
  const s = changeStatusLine(new FakeReviewStore(changeReq({ items: [item('x', 'failed')] })).req!, r([item('x', 'failed')]));
  assert(s.includes('다시 고치는 중'));
});
