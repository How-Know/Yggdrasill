import { assert, assertEquals } from 'jsr:@std/assert@1';
import { FakeAiProvider, type FakeTurn } from '../_shared/ai/fake.ts';
import type { AiRequest } from '../_shared/ai/types.ts';
import { workStateNote } from './actions.ts';
import { runThinkChat, type ChatInput } from './chat.ts';
import {
  CONCEPT_EDIT_READ_TOOL_NAME,
  COURSE_MAPS_TOOL_NAME,
  RELATION_PROPOSE_TOOL_NAME,
  RELATION_READ_TOOL_NAME,
  relationMeaning,
} from './course_map_tools.ts';
import { computeFeatures } from './features.ts';
import { THINK_PROMPT_VERSION } from './prompts.ts';
import { runThinkTool, thinkToolsFor } from './tools.ts';
import { EventLog, MemoryThinkStore, RunLog, testEnv } from './test_support.ts';

const ALL = {
  conversation_split: 1, think_roles: 1, memory_proposals: 1, department_work: 1, auto_organize: 1, course_map_actions: 1,
  concept_review: 1, concept_relation_change: 1,
};
const READY = computeFeatures({ ok: true, features: ALL }, ALL, true);
const OLD_APP = computeFeatures({ ok: true, features: ALL }, { ...ALL, concept_relation_change: 0 }, true);
const DB_REQUIRED = computeFeatures({ ok: true, features: { ...ALL, concept_relation_change: 0 } }, ALL, true);
const MAP_OLD_APP = computeFeatures({ ok: true, features: ALL }, { ...ALL, course_map_actions: 0 }, true);

const SQ = 'cccccccc-0000-4000-8000-000000000001';
const RECT = 'cccccccc-0000-4000-8000-000000000002';
const SIDE = 'cccccccc-0000-4000-8000-000000000003';
const R1 = 'dddddddd-0000-4000-8000-000000000001';
const R2 = 'dddddddd-0000-4000-8000-000000000002';
const R3 = 'dddddddd-0000-4000-8000-000000000003';
const TREV = '0123456789ab';
const RELATION_TOOLS = [RELATION_READ_TOOL_NAME, RELATION_PROPOSE_TOOL_NAME];

const ctx = (relations = true) => ({
  conversationId: 'conv-x', memoryRefs: [], courseMap: { proposed: new Map<string, number>(), review: true, relations },
});
const parse = (r: { output: string }) => JSON.parse(r.output);
const call = (store: MemoryThinkStore, name: string, args: unknown, c: ReturnType<typeof ctx> = ctx()) =>
  runThinkTool(name, JSON.stringify(args), store, 8000, c);

const end = (id: string, name: string) => ({ id, name, text_rev: TREV });
const recorded = (via: string) => ({ recorded: true, via, at: '2026-10-23T00:00:00Z', action_id: null });

/** concept_relation_list 결과(직사각형 쪽에서 본 것). */
function relationList(extra: Record<string, unknown> = {}) {
  return {
    id: RECT, name: '직사각형', text_rev: TREV, revision: `${TREV}-${TREV}-${TREV}`,
    relations: [
      {
        id: R1, direction: 'in', from: end(SQ, '정사각형'), to: end(RECT, '직사각형'), kind: 'kind_of', context: '사각형 분류',
        basis: '정의에 네 각이 직각', note: null, origin: 'manual', rev: 2, decision: recorded('manual'),
        judged: { recorded: true, from_changed: false, to_changed: true }, rereview: true,
      },
      {
        id: R2, direction: 'out', from: end(RECT, '직사각형'), to: end(SIDE, '변'), kind: 'depends_on', context: '넓이 공식을 증명할 때',
        basis: null, note: null, origin: 'draft', rev: 1, decision: { recorded: false }, judged: { recorded: false }, rereview: null,
      },
    ],
    relations_review: { outcome: 'needs_comparison', stale: true, reviewed_at: '2026-10-22' },
    pending: [
      { action_id: 'act-1', item: 2, op: 'change', relation_id: R1, concept_id: SQ, related_id: RECT, kind: 'kind_of' },
      { action_id: 'act-1', item: 3, op: 'add', relation_id: null, concept_id: RECT, related_id: SIDE, kind: 'part_of' },
    ],
    events: [{
      event: 'change', relation_id: R1, concept_name: '정사각형', related_name: '직사각형', before: { context: null },
      after: { context: '사각형 분류' }, via: 'manual', reason: null, at: '2026-10-23T00:00:00Z',
    }],
    event_count: 3,
    ...extra,
  };
}

function input(partial: Partial<ChatInput>): ChatInput {
  return {
    userId: 'user-1', safetyId: 'hash', conversationId: null, message: '정사각형과 직사각형 관계를 정리해 줘', attachments: [], deep: false,
    webSearch: false, signal: new AbortController().signal, startedAt: Date.now(), wallClockMs: 140000, ...partial,
  };
}

async function run(store: MemoryThinkStore, partial: Partial<ChatInput>, script?: (req: AiRequest, i: number) => FakeTurn) {
  const provider = new FakeAiProvider(script ?? (() => ({ text: '답변' })));
  const runs = new RunLog();
  await runThinkChat(input(partial), { provider, store, recordRun: runs.record, emit: new EventLog().emit, env: testEnv });
  return { provider, runs };
}

const toolNames = (req: AiRequest) => (req.tools ?? []).map((t) => t.name);
const chatRequest = (provider: FakeAiProvider) => provider.requests.find((r) => (r.tools ?? []).length > 0)!;
const featureNote = (req: AiRequest) =>
  req.input.filter((i) => i.kind === 'context').map((i) => (i as { text: string }).text).find((t) => t.startsWith('[실행 환경 기능 상태')) ?? '';

const ADD = {
  op: 'add', relation_id: null, relation_rev: null, concept_id: SQ, related_id: RECT, kind: 'kind_of', context: null,
  basis: '두 정의를 비교', note: null, concept_revision: TREV, related_revision: TREV, uncertainty: null, reason: '사용자가 분류 정리를 맡김',
};

Deno.test('관계 도구 노출: 과정 도구와 관계 기능이 모두 준비된 요청에만, 커서 질문에는 주지 않는다', () => {
  const both = thinkToolsFor({ split: false, courseMap: true, conceptRelations: true }).map((t) => t.name);
  for (const n of RELATION_TOOLS) assert(both.includes(n), n);
  const mapOnly = thinkToolsFor({ split: false, courseMap: true, conceptReview: true }).map((t) => t.name);
  for (const n of RELATION_TOOLS) assert(!mapOnly.includes(n), n);
  const relationsOnly = thinkToolsFor({ split: false, conceptRelations: true }).map((t) => t.name);
  for (const n of RELATION_TOOLS) assert(!relationsOnly.includes(n), n);
  const relay = thinkToolsFor({ split: false, courseMap: true, conceptRelations: true, readOnly: true }).map((t) => t.name);
  for (const n of RELATION_TOOLS) assert(!relay.includes(n), n);
});

Deno.test('대화: 준비됐으면 관계 도구·지침·기능 상태, 앱·DB가 안 됐으면 도구와 지침 없이 무엇이 필요한지만 알린다', async () => {
  const store = new MemoryThinkStore();
  const conv = await store.createConversation('관계');
  const ready = await run(store, { conversationId: conv.id, features: READY });
  const req = chatRequest(ready.provider);
  for (const n of RELATION_TOOLS) assert(toolNames(req).includes(n), n);
  assert(req.instructions!.includes('## 개념 관계'));
  assert(featureNote(req).includes('개념 관계 읽기·관계 카드(get_concept_relations, propose_concept_relation_change): 사용 가능'));
  const f = ready.runs.runs[0].features as Record<string, unknown>;
  assertEquals([f.course_map_tools, f.concept_relation_tools], [true, true]);
  assertEquals(ready.runs.runs[0].promptVersion, THINK_PROMPT_VERSION);
  assertEquals(THINK_PROMPT_VERSION, 'think-2026-10-28b');

  const cases: [typeof READY, string, boolean][] = [
    [OLD_APP, '앱 업데이트 필요', true],
    [DB_REQUIRED, 'DB 반영 필요', true],
    [MAP_OLD_APP, '앱 업데이트 필요', false],
  ];
  for (const [features, label, mapTools] of cases) {
    const other = new MemoryThinkStore();
    const c = await other.createConversation('관계');
    const r = await run(other, { conversationId: c.id, features });
    const q = chatRequest(r.provider);
    for (const n of RELATION_TOOLS) assert(!toolNames(q).includes(n), n);
    assertEquals(toolNames(q).includes(COURSE_MAPS_TOOL_NAME), mapTools);
    assert(!q.instructions!.includes('## 개념 관계'));
    const line = featureNote(q).split('\n').find((l) => l.includes('개념 관계 읽기·관계 카드'))!;
    assert(line.includes(label), line);
    assertEquals((r.runs.runs[0].features as Record<string, unknown>).concept_relation_tools, false);
  }
});

Deno.test('관계 읽기: 방향과 상대가 맞고, 맥락 있는 관계는 맥락 안에서만 읽히며, 출처·결정·다시 검토를 따로 보여 준다', async () => {
  const store = new MemoryThinkStore();
  store.courseMapData.set('concept_relation_list', relationList());
  const r = await call(store, RELATION_READ_TOOL_NAME, { concept_id: RECT, direction: null, offset: null });
  assert(r.ok);
  assertEquals(store.courseMapReads.at(-1)!, { fn: 'concept_relation_list', args: { p_concept: RECT } });
  const v = parse(r);
  assertEquals(v.concept, { id: RECT, name: '직사각형', text_revision: TREV, revision: `${TREV}-${TREV}-${TREV}` });
  assertEquals([v.total, v.from, v.to, v.next_offset], [2, 0, 2, null]);

  const [kind, dep] = v.relations;
  assertEquals([kind.direction, kind.from.id, kind.to.id, kind.from.text_revision], ['in', SQ, RECT, TREV]);
  assertEquals(kind.meaning, "'정사각형'은(는) '직사각형'의 한 종류다 (맥락: 사각형 분류)");
  assertEquals([kind.kind_label, kind.relation_id, kind.rev], ['종류·특수화', R1, 2]);
  assertEquals(kind.origin, '운영자가 직접 넣음');
  assertEquals(kind.decision.label, '운영자가 직접 저장');
  assertEquals(kind.rereview, true);
  assert(kind.rereview_label.includes('기준 개념의 글이 바뀌었다'), kind.rereview_label);
  assertEquals(kind.pending, [{ action_id: 'act-1', item: 2, op: 'change' }]);

  assertEquals([dep.direction, dep.from.id, dep.to.id], ['out', RECT, SIDE]);
  assert(dep.meaning.includes('"넓이 공식을 증명할 때"'), dep.meaning);
  assert(dep.meaning.includes('맥락 밖의 선수 관계가 아니다'), dep.meaning);
  assertEquals(dep.origin, '교재 초안 확정 때 생김');
  assertEquals(dep.decision, { label: '결정 기록 없음(이 기능 전에 생긴 관계)' }, '출처를 결정으로 바꿔 말하지 않는다');
  assertEquals(dep.rereview, null);
  assert(dep.rereview_label.includes('모른다'));
  assertEquals('pending' in dep, false);

  assertEquals(v.pending_adds, [{ action_id: 'act-1', item: 3, op: 'add', concept_id: RECT, related_id: SIDE, kind: 'part_of' }]);
  assertEquals(v.relations_review, { outcome: 'needs_comparison', stale: true, reviewed_at: '2026-10-22' });
  assertEquals([v.events.length, v.events[0].via, v.event_count], [1, '운영자가 직접 저장', 3]);
  assert(v.note.includes('기록이 없다는 뜻'));

  const onlyIn = parse(await call(store, RELATION_READ_TOOL_NAME, { concept_id: RECT, direction: 'in', offset: null }));
  assertEquals(onlyIn.relations.map((x: { relation_id: string }) => x.relation_id), [R1]);
  assertEquals(onlyIn.total, 1);

  store.courseMapData.set('concept_relation_list', relationList({ relations: [], pending: [], events: [], relations_review: null }));
  const empty = parse(await call(store, RELATION_READ_TOOL_NAME, { concept_id: RECT, direction: null, offset: null }));
  assertEquals([empty.total, empty.relations_review], [0, null]);
  assert(empty.note.includes('조회는 성공했다'));
});

Deno.test('관계 뜻 문장: 맥락이 꼭 있어야 하는 유형은 맥락이 없으면 모른다고 적고, 무조건 선수 관계로 읽지 않는다', () => {
  assert(relationMeaning('depends_on', 'A', 'B', null).includes('기록이 없다'));
  assert(!relationMeaning('depends_on', 'A', 'B', null).includes('필요하다'));
  assert(relationMeaning('derived_from', 'A', 'B', null).includes('어떤 유도인지 모른다'));
  assertEquals(relationMeaning('special_case', 'A', 'B', null), "'A'은(는) 'B'의 특수한 경우다");
  assertEquals(relationMeaning('part_of', '변', '다각형', null), "'변'은(는) '다각형'을(를) 이루는 요소다");
  assertEquals(relationMeaning('extends', 'A', 'B', null), "'A'은(는) 'B'의 정의·범위를 넓힌 개념이다");
});

Deno.test('관계 읽기 오류: 권한 없음·조회 실패를 빈 결과와 구분하고, 기능이 없으면 RPC를 부르지 않는다', async () => {
  const store = new MemoryThinkStore();
  const args = { concept_id: RECT, direction: null, offset: null };
  store.courseMapReadError = 'concept_relation_forbidden';
  const forbidden = parse(await call(store, RELATION_READ_TOOL_NAME, args));
  assertEquals(forbidden.error, 'concept_relation_forbidden');
  assert(forbidden.next.includes('관계가 없다는 뜻이 아니다'));
  store.courseMapReadError = 'concept_relation_not_found';
  assertEquals(parse(await call(store, RELATION_READ_TOOL_NAME, args)).error, 'concept_relation_not_found');
  store.courseMapReadError = 'connection reset';
  assertEquals(parse(await call(store, RELATION_READ_TOOL_NAME, args)).error, 'lookup_failed');
  store.courseMapReadError = null;
  store.courseMapData.set('concept_relation_list', { unexpected: true });
  assertEquals(parse(await call(store, RELATION_READ_TOOL_NAME, args)).error, 'lookup_failed', '모양이 다른 결과를 관계 없음으로 보지 않는다');
  assertEquals(parse(await call(store, RELATION_READ_TOOL_NAME, { ...args, concept_id: 'abc' })).error, 'invalid_id');

  const reads = store.courseMapReads.length;
  for (const name of RELATION_TOOLS) {
    const off = parse(await call(store, name, { ...args, items: [ADD], reason: 'x' }, ctx(false)));
    assertEquals(off.error, 'concept_relation_unavailable', name);
  }
  assertEquals(store.courseMapReads.length, reads);
  assertEquals(store.courseThinkProposals.length, 0);
});

Deno.test('관계 카드: op별 칸만 보내고(relation_rev는 rev로), 미리보기 요약을 알리며, 한 답변 2장까지', async () => {
  const store = new MemoryThinkStore();
  store.courseThinkPreview = {
    title: '개념 관계 고치기',
    items: [
      { i: 1, op: 'add', from: { name: '정사각형' }, to: { name: '직사각형' }, open_same_concept_review: true, pending_elsewhere: 0 },
      { i: 2, op: 'change', from: { name: '직사각형' }, to: { name: '변' }, open_same_concept_review: false, pending_elsewhere: 1 },
      { i: 3, op: 'remove', from: { name: '정사각형' }, to: { name: '직사각형' }, open_same_concept_review: false, pending_elsewhere: 0 },
    ],
    counts: { add: 1, change: 1, remove: 1 },
  };
  const change = { ...ADD, op: 'change', relation_id: R2, relation_rev: 1, concept_id: null, related_id: null, kind: null, context: '', basis: null };
  const remove = { ...ADD, op: 'remove', relation_id: R3, relation_rev: 4, uncertainty: '확신 낮음' };
  const c = ctx();
  const r = await call(store, RELATION_PROPOSE_TOOL_NAME, { items: [ADD, change, remove], reason: '분류 정리' }, c);
  assert(r.ok);
  assert(r.action);
  assertEquals(store.courseThinkProposals[0].kind, 'concept_relation_change');
  const sent = store.courseThinkProposals[0].payload.items as Record<string, unknown>[];
  assertEquals(sent[0], {
    op: 'add', concept_id: SQ, related_id: RECT, kind: 'kind_of', basis: '두 정의를 비교', concept_revision: TREV, related_revision: TREV,
    reason: '사용자가 분류 정리를 맡김',
  });
  assertEquals(sent[1], {
    op: 'change', relation_id: R2, rev: 1, context: '', concept_revision: TREV, related_revision: TREV, reason: '사용자가 분류 정리를 맡김',
  }, 'change는 바꿀 칸만, 빈 글은 비우기로 보낸다');
  assertEquals(sent[2], {
    op: 'remove', relation_id: R3, rev: 4, concept_revision: TREV, related_revision: TREV, uncertainty: '확신 낮음',
    reason: '사용자가 분류 정리를 맡김',
  }, '빼기에는 유형·맥락을 싣지 않는다');
  assertEquals(store.courseThinkProposals[0].payload.reason, '분류 정리');
  const v = parse(r);
  assertEquals([v.status, v.already_pending, v.open_same_concept_review], ['proposed', 1, 1]);
  assertEquals(v.counts, { add: 1, change: 1, remove: 1 });
  assert(v.note.includes('승인한 항목만'));
  assert(v.note.includes('개념은 지우지 않는다'));

  await call(store, RELATION_PROPOSE_TOOL_NAME, { items: [ADD], reason: 'x' }, c);
  const third = parse(await call(store, RELATION_PROPOSE_TOOL_NAME, { items: [ADD], reason: 'x' }, c));
  assertEquals(third.error, 'course_think_card_limit');
  assertEquals(store.courseThinkProposals.length, 2);
});

Deno.test('관계 카드 오류: 항목 번호와 다음 행동을 돌려주고, 같은 개념 의심은 카드로 풀지 말라고 알린다', async () => {
  const store = new MemoryThinkStore();
  store.courseThinkProposeError = 'concept_relation_bad_item:2:concept_relation_reverse_exists';
  const reverse = parse(await call(store, RELATION_PROPOSE_TOOL_NAME, { items: [ADD, ADD], reason: 'x' }));
  assertEquals([reverse.error, reverse.item], ['concept_relation_reverse_exists', 2]);
  assert(reverse.next.includes('같은 개념인지 검토할 일'));
  store.courseThinkProposeError = 'concept_relation_bad_item:1:concept_relation_concept_stale';
  const stale = parse(await call(store, RELATION_PROPOSE_TOOL_NAME, { items: [ADD], reason: 'x' }));
  assertEquals([stale.error, stale.item], ['concept_relation_concept_stale', 1]);
  assert(stale.next.includes('다시 읽고'));
  store.courseThinkProposeError = 'concept_relation_bad_item:1:concept_relation_context_required';
  assert(parse(await call(store, RELATION_PROPOSE_TOOL_NAME, { items: [ADD], reason: 'x' })).next.includes('사용자에게 묻는다'));
  store.courseThinkProposeError = 'concept_relation_too_many';
  assertEquals(parse(await call(store, RELATION_PROPOSE_TOOL_NAME, { items: [ADD], reason: 'x' })).error, 'concept_relation_too_many');
  store.courseThinkProposeError = null;
  const malformed = parse(await call(store, RELATION_PROPOSE_TOOL_NAME, { items: [ADD, { ...ADD, op: 'move' }], reason: 'x' }));
  assertEquals([malformed.error, malformed.item], ['concept_relation_bad_op', 2]);
  assertEquals(parse(await call(store, RELATION_PROPOSE_TOOL_NAME, { items: [ADD], reason: ' ' })).error, 'course_think_reason_required');
  assertEquals(store.courseThinkProposals.length, 0);
});

Deno.test('개념 읽기의 관계 줄에 맥락이 함께 보인다', async () => {
  const store = new MemoryThinkStore();
  store.courseMapData.set('concept_think_detail', {
    id: RECT, name: '직사각형', content: '네 각이 직각인 사각형', statements: [], sources: [], source_count: 0, placements: [], appearances: [],
    relations: [{ id: R2, direction: 'out', kind: 'depends_on', other_id: SIDE, other_name: '변', origin: 'draft', note: null, context: '넓이 공식' }],
    same_concept_reviews: [], same_concept_review_count: 0, attached: { relations: 1, total: 1 }, review: {}, revision: `${TREV}-a-b`,
  });
  const v = parse(await call(store, CONCEPT_EDIT_READ_TOOL_NAME, { concept_id: RECT, part: null, statement_id: null, field: null, offset: null }));
  assertEquals(v.relations[0].context, '넓이 공식');
  assertEquals(v.relations[0].kind, 'depends_on');
});

Deno.test('작업 상태 메모: 관계 카드는 첫 두 개념과 개수, 항목별 결과를 보여 준다', () => {
  const note = workStateNote({
    actions: [{
      id: 'a1', conversation_id: 'c', message_id: null, kind: 'concept_relation_change', status: 'applied', payload: {}, error: null,
      created_at: '2026-10-23T00:00:00Z',
      preview: { title: '개념 관계 고치기', items: [{ from: { name: '정사각형' }, to: { name: '직사각형' } }, { from: { name: '변' }, to: { name: '직사각형' } }] },
      result: { applied: 1, failed: 1, skipped: 0 },
    }],
    codeRequests: [],
  })!;
  assert(note.includes('개념 관계 고치기 제안 "정사각형 → 직사각형 외 1개": 사용자가 승인해 실행됨 (반영 1개, 실패 1개, 뺌 0개) (카드 id: a1)'), note);
});
