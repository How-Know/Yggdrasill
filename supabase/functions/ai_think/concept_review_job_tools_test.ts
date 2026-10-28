import { assert, assertEquals } from 'jsr:@std/assert@1';
import type { ActionToolContext } from './actions.ts';
import {
  JOB_CONTROL_TOOL_NAME,
  JOB_FIND_TOOL_NAME,
  JOB_READ_TOOL_NAME,
  JOB_SAVE_TOOL_NAME,
  JOB_SUBMIT_TOOL_NAME,
  REVIEW_CARDS_PER_REQUEST,
  REVIEW_JOB_TOOL_NAMES,
} from './concept_review_job_tools.ts';
import { computeFeatures } from './features.ts';
import { thinkInstructions } from './prompts.ts';
import { runThinkTool, thinkToolsFor } from './tools.ts';
import { MemoryThinkStore } from './test_support.ts';

const JOB = 'abababab-0000-4000-8000-000000000001';
const C1 = 'cccccccc-0000-4000-8000-000000000001';
const parse = (r: { output: string }) => JSON.parse(r.output);

function ctx(extra: Partial<NonNullable<ActionToolContext['reviewJobs']>> = {}): ActionToolContext {
  return {
    conversationId: 'conv-new',
    memoryRefs: [],
    courseMap: { proposed: new Map<string, number>(), review: true },
    reviewJobs: { holder: 'think:conv-new:1', leases: new Map(), cards: 0, ...extra },
  } as ActionToolContext;
}
const call = (store: MemoryThinkStore, name: string, args: unknown, c: ActionToolContext) =>
  runThinkTool(name, JSON.stringify(args), store, 8000, c);

const STATUS = {
  job: { job_id: JOB, title: '배치 개념 검수', status: 'active', total: 514, checkpoint: 40 },
  progress_line: '514개 중 61개 완료',
  counts: { complete: 61 },
  total_mismatch: false,
  open_items: [],
  pending_cards: [{ action_id: 'act-old', conversation_id: 'conv-old', linked: false }],
};

Deno.test('검수 작업 도구는 검토 기능과 작업 기능이 모두 준비된 요청에만, 커서 질문에는 주지 않는다', () => {
  const names = (o: Parameters<typeof thinkToolsFor>[0]) => new Set(thinkToolsFor(o).map((t) => t.name));
  const on = names({ split: false, courseMap: true, conceptReview: true, reviewJobs: true });
  for (const n of REVIEW_JOB_TOOL_NAMES) assert(on.has(n), n);
  const noJobs = names({ split: false, courseMap: true, conceptReview: true, reviewJobs: false });
  const noReview = names({ split: false, courseMap: true, conceptReview: false, reviewJobs: true });
  const relay = names({ split: false, courseMap: true, conceptReview: true, reviewJobs: true, readOnly: true });
  for (const n of REVIEW_JOB_TOOL_NAMES) assert(!noJobs.has(n) && !noReview.has(n) && !relay.has(n), n);

  const all = { course_map_actions: 1, concept_review: 1, concept_review_jobs: 1 };
  const ready = computeFeatures({ ok: true, features: all }, { course_map_actions: 1, concept_review: 1 }, true);
  assertEquals(ready.concept_review_jobs.state, 'ready', '앱 화면이 바뀌지 않아 앱 버전을 보지 않는다');
  const base = {
    identity: [], principles: [], decisions: [], today: '2026-10-26',
    limits: { identityChars: 1000, principleChars: 1000, decisionChars: 1000 },
    courseMapReady: true, conceptReviewReady: true,
  };
  assert(thinkInstructions({ ...base, conceptReviewJobsReady: true }).includes('## 개념 검수 작업'));
  assert(!thinkInstructions(base).includes('## 개념 검수 작업'));
});

Deno.test('작업 찾기: 여러 개면 고르지 말라고, 없으면 새 목록을 만들지 말라고 알린다', async () => {
  const store = new MemoryThinkStore();
  store.reviewJobData.set('concept_review_jobs_find', { jobs: [{ job_id: JOB }, { job_id: C1 }], walks: [] });
  assert(parse(await call(store, JOB_FIND_TOOL_NAME, {}, ctx())).note.includes('고르지 말고'));
  store.reviewJobData.set('concept_review_jobs_find', { jobs: [], walks: [] });
  assert(parse(await call(store, JOB_FIND_TOOL_NAME, {}, ctx())).note.includes('새 목록을 만들지 말고'));
  store.reviewJobErrors.set('concept_review_jobs_find', 'concept_review_forbidden');
  assertEquals(parse(await call(store, JOB_FIND_TOOL_NAME, {}, ctx())).error, 'concept_review_forbidden');
});

Deno.test('이어 읽기: 한 요청에서 한 번만 넘겨받고, 진행 표시는 서버 집계 그대로, 넘겨받긴 실행은 더 쓰지 않는다', async () => {
  const store = new MemoryThinkStore();
  store.reviewJobData.set('concept_review_job_claim', { gen: 7 });
  store.reviewJobData.set('concept_review_job_status', STATUS);
  store.reviewJobData.set('concept_review_job_next', {
    batch: [{ position: 41, concept_id: C1, state: 'no_record', concept: { name: '소수', folder: ['수', '소인수분해'], revision: 'r' } }],
    auto_saved: { reused: 2, missing: 0, waiting: 0 }, checkpoint: 40, reached_end: false,
  });
  const c = ctx();
  const v = parse(await call(store, JOB_READ_TOOL_NAME, { job_id: JOB, next: 3 }, c));
  assertEquals(v.progress_line, '514개 중 61개 완료');
  assertEquals(v.first_pass_state, 'unaggregated');
  assertEquals(v.first_pass, null);
  assert(v.note.includes('미집계'));
  assertEquals(v.batch[0], { position: 41, concept_id: C1, state: 'no_record', name: '소수', type: null, folder: '수 › 소인수분해', revision: 'r', review: {} });
  assert(v.note.includes('bring_cards'), '이어지지 않은 예전 대기 카드를 알린다');
  await call(store, JOB_READ_TOOL_NAME, { job_id: JOB, next: 1 }, c);
  assertEquals(store.reviewJobCalls.filter((x) => x.fn === 'concept_review_job_claim').length, 1);
  assertEquals(store.reviewJobCalls.filter((x) => x.fn === 'concept_review_job_next').map((x) => x.args.p_gen), [7, 7]);

  store.reviewJobErrors.set('concept_review_job_save', 'concept_review_job_lease_lost');
  const lost = parse(await call(store, JOB_SAVE_TOOL_NAME, { job_id: JOB, items: [{ position: 41 }] }, c));
  assertEquals(lost.error, 'concept_review_job_lease_lost');
  assert(lost.next.includes('더 저장·제출하지 않고'));
  assertEquals(c.reviewJobs!.leases.has(JOB), false);

  const runner = ctx({ leases: new Map([[JOB, 9]]), noTakeover: true, itemsLeft: 1 });
  store.reviewJobErrors.delete('concept_review_job_save');
  store.reviewJobData.set('concept_review_job_save', { items: [{ position: 41, status: 'saved', draft_version: 1 }], saved: 1, checkpoint: 41 });
  await call(store, JOB_SAVE_TOOL_NAME, { job_id: JOB, items: [{ position: 41 }, { position: 42 }] }, runner);
  assertEquals((store.reviewJobCalls.at(-1)!.args.p_items as unknown[]).length, 1, '자동 실행은 저장 한도만큼만 보낸다');
  assertEquals(store.reviewJobCalls.at(-1)!.args.p_gen, 9);
  assertEquals(parse(await call(store, JOB_SAVE_TOOL_NAME, { job_id: JOB, items: [{ position: 42 }] }, runner)).error, 'run_item_limit');
  const claims = store.reviewJobCalls.filter((x) => x.fn === 'concept_review_job_claim').length;
  await call(store, JOB_READ_TOOL_NAME, { job_id: C1, next: 1 }, runner);
  assertEquals(store.reviewJobCalls.filter((x) => x.fn === 'concept_review_job_claim').length, claims, '자동 실행은 넘겨받지 않는다');
});

Deno.test('1차 검수 집계가 있으면 그 수를 그대로 전하고, 조건별 수로 바꾸지 않는다', async () => {
  const store = new MemoryThinkStore();
  const line = '1차 검수 3조건 충족: 250 / 514개(48.6%)';
  store.reviewJobData.set('concept_review_job_status', {
    ...STATUS,
    pending_cards: [],
    conditions: { text: 400, foundation: 300, placement: 200 },
    first_pass: { met: 250, total: 514, percent: 48.6, line },
    first_pass_line: line,
  });
  const v = parse(await call(store, JOB_READ_TOOL_NAME, { job_id: JOB }, ctx()));
  assertEquals(v.first_pass, { met: 250, total: 514, percent: 48.6, line });
  assertEquals(v.first_pass_state, 'counted');
  assertEquals(v.progress_line, '514개 중 61개 완료');
  assert(v.note.includes(line));
  assert(!v.note.includes('미집계'));
});

Deno.test('저장된 실패 진단은 재실행 없이 읽고, 예전 포괄 문장에는 원인을 만들지 않는다', async () => {
  const store = new MemoryThinkStore();
  const specific = 'judge_invalid:fix_evidence_empty:placement:reviews[0].fix.ops[0].evidence:non_empty_text:empty_string';
  const generic = 'judge_invalid: 판단 형식이 맞지 않음(범위·결과·근거·고치기 제안·비교 개념)';
  store.reviewJobData.set('concept_review_job_status', {
    ...STATUS,
    pending_cards: [],
    open_items: [
      { position: 2, concept_id: C1, name: '소수', reason: specific, next_action: '다시 판단' },
      { position: 4, concept_id: C1, name: '소수', reason: generic, next_action: '다시 판단' },
    ],
  });
  store.reviewJobData.set('concept_review_job_failure_page', {
    returned: 1, omitted: 1, next_after: 2,
    items: [{ position: 2, concept_id: C1, name: '소수', reason: specific, next_action: '다시 판단' }],
  });
  const c = ctx();
  const v = parse(await call(store, JOB_READ_TOOL_NAME, { job_id: JOB, next: 0 }, c));
  assertEquals(v.open_items[0].diagnosis, {
    kind: 'specific', code: 'fix_evidence_empty', stage: 'stage1', scope: 'placement',
    field: 'reviews[0].fix.ops[0].evidence', expected: 'non_empty_text', actual_type: 'empty_string',
  });
  assertEquals(v.open_items[1].diagnosis.kind, 'generic');
  assertEquals(v.open_items[1].diagnosis.scope, null);
  assertEquals(v.open_items[1].diagnosis.field, null);
  assertEquals(v.open_items[1].reason, generic);
  assertEquals(v.failures.omitted, 1);
  assertEquals(v.failures.items[0].diagnosis.code, 'fix_evidence_empty');
  assert(String(v.failures.read_more).includes('failure_after'));
  assert(v.note.includes('generic'));
  assertEquals(c.reviewJobs!.leases.size, 0);
  assertEquals(store.reviewJobCalls.filter((x) => x.fn === 'concept_review_job_claim').length, 0);
  await call(store, JOB_READ_TOOL_NAME, { job_id: JOB, next: 0, failure_after: 2 }, c);
  assertEquals(store.reviewJobCalls.filter((x) => x.fn === 'concept_review_job_failure_page').at(-1)!.args.p_after, 2);
});

Deno.test('집계 시간 초과는 바깥에서 단계와 시간을 돌려주고 0으로 채우지 않는다', async () => {
  const store = new MemoryThinkStore();
  store.reviewJobRpc = (fn, args) => {
    store.reviewJobCalls.push({ fn, args: structuredClone(args) });
    if (fn === 'concept_review_job_status') return new Promise(() => {});
    if (fn === 'concept_review_job_status_diag_put') return Promise.resolve({ saved: true });
    return Promise.resolve(null);
  };
  const started = Date.now();
  const r = await runThinkTool(
    JOB_READ_TOOL_NAME,
    JSON.stringify({ job_id: JOB, next: 0, failure_after: null, status_diag_only: null }),
    store,
    40,
    ctx(),
  );
  assert(Date.now() - started < 1500);
  const v = parse(r);
  assertEquals(r.ok, false);
  assertEquals(v.error, 'timeout');
  assertEquals(v.aggregation, 'failed');
  assertEquals(v.first_pass_state, 'failed');
  assertEquals(v.counts, undefined);
  assertEquals(v.first_pass, undefined);
  assertEquals(v.status_diag.code, 'timeout');
  assertEquals(v.status_diag.stage, 'status_rpc');
  assertEquals(v.status_diag.timeout_ms, 40);
  assert(v.status_diag.elapsed_ms >= 40);
  assertEquals(v.status_diag.db_cancel, 'requested');
  assertEquals(v.diag_save, 'saved');
  assert(!JSON.stringify(v).includes('concept_review_marks'));
  const put = store.reviewJobCalls.find((x) => x.fn === 'concept_review_job_status_diag_put');
  assertEquals((put!.args.p_diag as { code: string }).code, 'timeout');
});

Deno.test('집계 필드가 없으면 미집계로 두고, 진단 저장이 실패해도 이번 응답은 남는다', async () => {
  const store = new MemoryThinkStore();
  store.reviewJobData.set('concept_review_job_status', {
    ...STATUS,
    pending_cards: [],
    counts: { complete: 61, awaiting: 3 },
    conditions: { text: 10, foundation: 0, placement: 0 },
  });
  store.reviewJobErrors.set('concept_review_job_status_diag_put', 'concept_review_status_diag_invalid');
  const v = parse(await call(store, JOB_READ_TOOL_NAME, { job_id: JOB, next: 0, failure_after: null, status_diag_only: null }, ctx()));
  assertEquals(v.aggregation, 'unaggregated');
  assertEquals(v.first_pass_state, 'unaggregated');
  assertEquals(v.first_pass, null);
  assertEquals(v.counts, { complete: 61, awaiting: 3 });
  assertEquals(v.progress_line, '514개 중 61개 완료');
  assertEquals(v.status_diag.code, 'unaggregated');
  assertEquals(v.diag_save, 'failed');
  assert(v.note.includes('미집계'));
  assertEquals(v.status_diag.outcome, 'unaggregated');
});

Deno.test('저장된 집계 진단은 집계를 다시 실행하지 않고 읽는다', async () => {
  const store = new MemoryThinkStore();
  const diagnosis = {
    trace_id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    stage: 'status_rpc',
    elapsed_ms: 9000,
    timeout_ms: 8000,
    code: 'timeout',
    outcome: 'failed',
    db_cancel: 'requested',
  };
  store.reviewJobData.set('concept_review_job_status_diag_get', { diagnosis });
  store.reviewJobData.set('concept_review_job_status', STATUS);
  const v = parse(await call(store, JOB_READ_TOOL_NAME, {
    job_id: JOB, next: 5, failure_after: 0, status_diag_only: true,
  }, ctx()));
  assertEquals(v.aggregation, 'not_run');
  assertEquals(v.status_diag, diagnosis);
  assertEquals(store.reviewJobCalls.map((x) => x.fn), ['concept_review_job_status_diag_get']);
});

Deno.test('저장 오류는 위치마다 다음 할 일과 함께, 제출은 새 카드만 화면에 보내고 한 요청 카드 한도까지', async () => {
  const store = new MemoryThinkStore();
  store.reviewJobData.set('concept_review_job_claim', { gen: 1 });
  store.reviewJobData.set('concept_review_job_save', {
    items: [{ position: 41, status: 'saved' }, { position: 42, status: 'error', code: 'concept_review_job_item_done' }], saved: 1, checkpoint: 41,
  });
  const c = ctx();
  const saved = parse(await call(store, JOB_SAVE_TOOL_NAME, { job_id: JOB, items: [{ position: 41 }, { position: 42 }] }, c));
  assertEquals(saved.items[1].code, 'concept_review_job_item_done');
  assert(saved.items[1].next.includes('다시 검수하지 않는다'));

  const action = { id: 'act-1', conversation_id: 'conv-new', kind: 'concept_review_record', status: 'proposed', payload: {}, preview: {} };
  store.reviewJobData.set('concept_review_job_submit', { submitted: true, existing: false, action, positions: [41], failed: [], blocked: [] });
  const first = await call(store, JOB_SUBMIT_TOOL_NAME, { job_id: JOB, reason: '검수' }, c);
  assertEquals(first.actions?.map((a) => a.id), ['act-1']);
  assertEquals(store.reviewJobCalls.at(-1)!.args.p_conversation_id, 'conv-new');
  store.reviewJobData.set('concept_review_job_submit', { submitted: true, existing: true, action, positions: [41], failed: [], blocked: [] });
  const again = await call(store, JOB_SUBMIT_TOOL_NAME, { job_id: JOB, reason: '검수' }, c);
  assertEquals([parse(again).existing, again.actions], [true, undefined], '같은 초안이면 새 카드를 보내지 않는다');
  store.reviewJobData.set('concept_review_job_submit', { submitted: false, failed: [{ position: 43, code: 'concept_review_stale' }], blocked: [] });
  assertEquals(parse(await call(store, JOB_SUBMIT_TOOL_NAME, { job_id: JOB, reason: '검수' }, c)).submitted, false);
  c.reviewJobs!.cards = REVIEW_CARDS_PER_REQUEST;
  assertEquals(parse(await call(store, JOB_SUBMIT_TOOL_NAME, { job_id: JOB, reason: '검수' }, c)).error, 'course_think_card_limit');

  store.reviewJobData.set('concept_review_job_cards_here', { cards: [action, { ...action, id: 'act-old' }], conflicts: [] });
  const moved = await call(store, JOB_CONTROL_TOOL_NAME, { job_id: JOB, action: 'bring_cards' }, c);
  assertEquals(moved.actions?.map((a) => a.id), ['act-1', 'act-old'], '옮긴 카드를 이 대화 화면에 보낸다');
});
