import { assert, assertEquals } from 'jsr:@std/assert@1';
import { FakeAiProvider } from '../_shared/ai/fake.ts';
import type { AiRunRecord } from '../_shared/ai/usage.ts';
import type { NewMessage } from '../ai_think/chat.ts';
import type { MemoryRow, MessageRow } from '../ai_think/context.ts';
import { memory, testEnv } from '../ai_think/test_support.ts';
import { followupPrompt, parseDecisions, parseReview, runCodeReview, type ReviewDeps, type ReviewRequest, type ReviewStore } from './code_review.ts';

class FakeReviewStore implements ReviewStore {
  req: ReviewRequest | null;
  memories: MemoryRow[] = [memory({ id: 'p1', kind: 'principle', title: '학생 중심', content: 'PRINCIPLE_TEXT' })];
  messages: MessageRow[] = [
    { id: 'm1', role: 'user', content: '홈 화면 위젯 어디서 그려?', status: 'complete', attachments: [], created_at: '' },
  ];
  inserted: NewMessage[] = [];
  followups: string[] = [];
  followupQuestions: string[][] = [];
  followupOk = true;
  plans: { requestId: string; messageId: string; title: string; spec: Record<string, unknown>; preview: Record<string, unknown> }[] = [];
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
  listMessages() {
    return Promise.resolve(this.messages);
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
  assertEquals(decisions[0].id, 'q1');
  assertEquals(decisions[0].options.map((o) => [o.id, o.label, o.recommended]), [
    ['q1_1', '최근 10개', true],
    ['q1_2', '전부 보관', false],
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
  const p = store.plans[0];
  assertEquals(p.spec.constraints, ['운영자 결정 — 보관: 전부', '새 제약']);
  assertEquals((p.spec.owner_answers as unknown[]).length, 1);
  assertEquals(p.spec.decisions, []);
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
