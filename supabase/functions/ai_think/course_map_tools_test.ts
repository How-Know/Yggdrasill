import { assert, assertEquals } from 'jsr:@std/assert@1';
import { FakeAiProvider, type FakeTurn } from '../_shared/ai/fake.ts';
import type { AiRequest } from '../_shared/ai/types.ts';
import { workStateNote } from './actions.ts';
import { runThinkChat, type ChatInput } from './chat.ts';
import {
  CANDIDATES_TOOL_NAME,
  CONCEPT_CHANGE_TOOL_NAME,
  CONCEPT_EDIT_READ_TOOL_NAME,
  COURSE_CREATE_TOOL_NAME,
  COURSE_MAPS_TOOL_NAME,
  MAP_CHANGE_TOOL_NAME,
  parseProposeError,
  PLACEMENT_TOOL_NAME,
} from './course_map_tools.ts';
import { computeFeatures } from './features.ts';
import { THINK_PROMPT_VERSION } from './prompts.ts';
import { runThinkTool, thinkToolsFor } from './tools.ts';
import { EventLog, MemoryThinkStore, RunLog, testEnv } from './test_support.ts';

const ALL = { conversation_split: 1, think_roles: 1, memory_proposals: 1, department_work: 1, auto_organize: 1, course_map_actions: 1 };
const READY = computeFeatures({ ok: true, features: ALL }, ALL, true);
const OLD_APP = computeFeatures({ ok: true, features: ALL }, { ...ALL, course_map_actions: 0 }, true);
const DB_REQUIRED = computeFeatures({ ok: true, features: { ...ALL, course_map_actions: 0 } }, ALL, true);

const COURSE = '11111111-1111-4111-8111-111111111111';
const U1 = 'aaaaaaaa-0000-4000-8000-000000000001';
const U11 = 'aaaaaaaa-0000-4000-8000-000000000011';
const U111 = 'aaaaaaaa-0000-4000-8000-000000000111';
const U12 = 'aaaaaaaa-0000-4000-8000-000000000012';
const U2 = 'aaaaaaaa-0000-4000-8000-000000000002';
const C1 = 'cccccccc-0000-4000-8000-000000000001';
const P1 = 'dddddddd-0000-4000-8000-000000000001';
const ST = 'eeeeeeee-0000-4000-8000-000000000001';

const PROPOSE_TOOLS = [MAP_CHANGE_TOOL_NAME, COURSE_CREATE_TOOL_NAME, PLACEMENT_TOOL_NAME, CONCEPT_CHANGE_TOOL_NAME];
const READ_TOOLS = [COURSE_MAPS_TOOL_NAME, CANDIDATES_TOOL_NAME, CONCEPT_EDIT_READ_TOOL_NAME];

const ctx = () => ({ conversationId: 'conv-x', memoryRefs: [], courseMap: { proposed: new Map<string, number>() } });
const parse = (r: { output: string }) => JSON.parse(r.output);
const call = (store: MemoryThinkStore, name: string, args: unknown, c: ReturnType<typeof ctx> | null = ctx()) =>
  runThinkTool(name, JSON.stringify(args), store, 8000, c ?? undefined);

function seedMap(store: MemoryThinkStore) {
  store.courseMapData.set('course_map_get', {
    course: { id: COURSE, name: '중1-1', school_level: '중', curriculum_code: 'rev_2022', course_key: 'M1-1', version: 4, archived_at: null },
    units: [
      { id: U1, parent_id: null, depth: 1, name: '소인수분해', sort_order: 0 },
      { id: U11, parent_id: U1, depth: 2, name: '소수와 합성수', sort_order: 0 },
      { id: U111, parent_id: U11, depth: 3, name: '소수', sort_order: 0 },
      { id: U12, parent_id: U1, depth: 2, name: '최대공약수', sort_order: 1 },
      { id: U2, parent_id: null, depth: 1, name: '정수와 유리수', sort_order: 1 },
    ],
    archived: [{ id: 'old', name: '옛 단원' }],
  });
  store.courseMapData.set('course_map_placements', [
    { id: P1, unit_id: U111, concept_id: C1, name: '소수', type: '정의', origin: 'ai', sources: 2, note: '근거' },
    { id: 'p2', unit_id: U2, concept_id: 'c2', name: '정수', type: '정의', origin: 'owner', sources: 0, note: null },
  ]);
}

function input(partial: Partial<ChatInput>): ChatInput {
  return {
    userId: 'user-1',
    safetyId: 'hash',
    conversationId: null,
    message: '중1-1 개념 배치해 줘',
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
const chatRequest = (provider: FakeAiProvider) => provider.requests.find((r) => (r.tools ?? []).length > 0)!;
const featureNote = (req: AiRequest) =>
  req.input.filter((i) => i.kind === 'context').map((i) => (i as { text: string }).text).find((t) => t.startsWith('[실행 환경 기능 상태')) ?? '';

Deno.test('도구 노출: 기능이 준비된 요청에만 주고, 커서 질문(읽기 전용)에는 읽기 도구도 주지 않는다', () => {
  const on = thinkToolsFor({ split: false, courseMap: true }).map((t) => t.name);
  for (const n of [...READ_TOOLS, ...PROPOSE_TOOLS]) assert(on.includes(n), n);
  const off = thinkToolsFor({ split: false }).map((t) => t.name);
  for (const n of [...READ_TOOLS, ...PROPOSE_TOOLS]) assert(!off.includes(n), n);
  const relay = thinkToolsFor({ split: false, courseMap: true, readOnly: true }).map((t) => t.name);
  for (const n of [...READ_TOOLS, ...PROPOSE_TOOLS]) assert(!relay.includes(n), n);
});

Deno.test('대화: 준비됐으면 도구·지침 절·기능 상태가 들어가고, DB·앱이 안 됐으면 도구 없이 상태만 알린다', async () => {
  const store = new MemoryThinkStore();
  const conv = await store.createConversation('배치');
  const ready = await run(store, { conversationId: conv.id, features: READY });
  const req = chatRequest(ready.provider);
  for (const n of [...READ_TOOLS, ...PROPOSE_TOOLS]) assert(toolNames(req).includes(n), n);
  assert(req.instructions!.includes('## 과정 탐색도·개념 배치·개념 고치기'));
  assert(featureNote(req).includes('과정 탐색도·개념 배치·개념 고치기 카드'));
  assertEquals((ready.runs.runs[0].features as Record<string, unknown>).course_map_tools, true);
  assertEquals(ready.runs.runs[0].promptVersion, THINK_PROMPT_VERSION);

  for (const features of [OLD_APP, DB_REQUIRED]) {
    const other = new MemoryThinkStore();
    const c = await other.createConversation('배치');
    const r = await run(other, { conversationId: c.id, features });
    const q = chatRequest(r.provider);
    for (const n of [...READ_TOOLS, ...PROPOSE_TOOLS]) assert(!toolNames(q).includes(n), n);
    assert(!q.instructions!.includes('## 과정 탐색도·개념 배치·개념 고치기'));
    assert(featureNote(q).includes('과정 탐색도·개념 배치·개념 고치기 카드'));
    assertEquals((r.runs.runs[0].features as Record<string, unknown>).course_map_tools, false);
  }
});

Deno.test('과정 목록: 과정마다 놓인 개념 수와 전체 놓인 수를 붙인다', async () => {
  const store = new MemoryThinkStore();
  store.courseMapData.set('course_maps_list', [
    { id: COURSE, name: '중1-1', school_level: '중', curriculum_code: null, course_key: 'M1-1', version: 1, archived_at: null, counts: [2, 3, 1] },
    { id: 'old', name: '옛 과정', school_level: '고', archived_at: '2026-10-01', version: 2, counts: [0, 0, 0] },
  ]);
  store.courseMapData.set('concept_placement_overview', { concepts: 120, placed: 30, courses: { [COURSE]: 41 } });
  const r = await call(store, COURSE_MAPS_TOOL_NAME, { course_id: null, unit_id: null, with_concepts: false });
  assert(r.ok);
  const v = parse(r);
  assertEquals([v.concepts_total, v.concepts_placed], [120, 30]);
  assertEquals(v.courses.map((c: { placed: number; archived: boolean }) => [c.placed, c.archived]), [[41, false], [0, true]]);
});

Deno.test('과정 하나: 단원 번호를 매기고, 놓인 개념은 원할 때만, unit_id면 그 아래만 준다', async () => {
  const store = new MemoryThinkStore();
  seedMap(store);
  const plain = parse(await call(store, COURSE_MAPS_TOOL_NAME, { course_id: COURSE, unit_id: null, with_concepts: false }));
  assertEquals(plain.units.map((u: { no: string }) => u.no), ['1', '1.1', '1.1.1', '1.2', '2']);
  assertEquals(plain.units.map((u: { placed: number }) => u.placed), [0, 0, 1, 0, 1]);
  assertEquals([plain.placed_total, plain.archived_units], [2, 1]);
  assert(plain.units.every((u: Record<string, unknown>) => !('concepts' in u)));

  const focus = parse(await call(store, COURSE_MAPS_TOOL_NAME, { course_id: COURSE, unit_id: U11, with_concepts: true }));
  assertEquals(focus.units.map((u: { id: string }) => u.id), [U11, U111]);
  assertEquals(focus.units[1].concepts, [{ placement_id: P1, concept_id: C1, name: '소수', type: '정의', by: 'think', sources: 2 }]);

  const missing = await call(store, COURSE_MAPS_TOOL_NAME, { course_id: COURSE, unit_id: C1, with_concepts: true });
  assertEquals([missing.ok, parse(missing).error], [false, 'course_placement_unit_not_found']);
  const badId = await call(store, COURSE_MAPS_TOOL_NAME, { course_id: 'abc', unit_id: null, with_concepts: false });
  assertEquals(parse(badId).error, 'invalid_id');
});

Deno.test('후보: 30개씩 읽고 다음 offset을 알려 주며, 알려진 오류는 다음 행동으로 돌려준다', async () => {
  const store = new MemoryThinkStore();
  store.courseMapData.set('concept_placement_candidates', {
    course_name: '중1-1', course_key: 'M1-1', total: 31, offset: 0,
    items: [{
      id: C1, name: '소수', type: '정의', folder: ['수와 연산', '소인수분해'], excerpt: '1보다 큰 자연수 중…', source_count: 1,
      sources: [{ book: '개념+유형', grade: '중1-1', course_key: 'M1-1', unit_path: ['Ⅰ', '1'], page: '8' }], placements: [],
    }],
  });
  const r = await call(store, CANDIDATES_TOOL_NAME, { course_id: COURSE, mode: 'course_sources', query: null, offset: null });
  const v = parse(r);
  assertEquals(v.next_offset, 1);
  assertEquals(v.items[0].folder, '수와 연산 › 소인수분해');
  assertEquals(v.items[0].sources[0].unit, 'Ⅰ › 1');
  assertEquals(store.courseMapReads.at(-1)!.args, { p_course_id: COURSE, p_mode: 'course_sources', p_query: null, p_offset: 0, p_limit: 30 });

  store.courseMapReadError = 'course_placement_bad_query';
  const bad = await call(store, CANDIDATES_TOOL_NAME, { course_id: COURSE, mode: 'search', query: null, offset: null });
  assertEquals([bad.ok, parse(bad).error], [false, 'course_placement_bad_query']);
  store.courseMapReadError = 'connection reset';
  const failed = await call(store, CANDIDATES_TOOL_NAME, { course_id: COURSE, mode: 'unplaced', query: null, offset: null });
  assertEquals([failed.ok, parse(failed).error], [false, 'lookup_failed']);
});

Deno.test('개념 읽기: 유형 목록을 붙이고, 긴 본문은 잘랐다고 알린다', async () => {
  const store = new MemoryThinkStore();
  store.courseMapData.set('concept_think_detail', {
    id: C1, name: '소수', type: '정의', folder: ['수와 연산'], content: '가'.repeat(17000), content_draft_pending: false,
    statements: [{ id: ST, role: 'statement', version: 1, has_draft: false, content: { title: '서술', body: '본문' } }],
    sources: [], placements: [{ id: P1, course_id: COURSE, unit_id: U111, path: '중1-1 › 소인수분해' }], attached: { total: 3 },
  });
  const v = parse(await call(store, CONCEPT_EDIT_READ_TOOL_NAME, { concept_id: C1 }));
  assertEquals(v.types.map((t: { name: string }) => t.name), ['정의', '성질']);
  assertEquals(v.content.length, 16000);
  assertEquals(v.truncated, ['본문']);
  assert(typeof v.note === 'string');
  assertEquals(v.placed[0].placement_id, P1);
});

Deno.test('개념 읽기: 붙은 것 개수로 지울 수 있는지와 막는 것을 알리고, 개수를 못 읽으면 지울 수 있다고 하지 않는다', async () => {
  const store = new MemoryThinkStore();
  const detail = (attached: unknown) =>
    store.courseMapData.set('concept_think_detail', {
      id: C1, name: '소수', type: '정의', folder: [], content: '본문', content_draft_pending: false,
      statements: [], sources: [], placements: [], attached,
    });
  const read = async () => parse(await call(store, CONCEPT_EDIT_READ_TOOL_NAME, { concept_id: C1 }));

  detail({ sources: 2, statements: 0, type_link: 1, content_revisions: 0, other: 0, total: 3 });
  const blocked = await read();
  assertEquals([blocked.deletable, blocked.delete_blocked_by], [false, ['출처 2', '유형 연결 1']]);
  assertEquals(blocked.delete_note, undefined);

  detail({ sources: 0, type_link: 0, total: 0 });
  const bare = await read();
  assertEquals([bare.deletable, bare.delete_blocked_by], [true, []]);

  for (const attached of [undefined, null, { sources: 1 }, { total: '0' }]) {
    detail(attached);
    const unknown = await read();
    assertEquals(unknown.deletable, null);
    assert(typeof unknown.delete_note === 'string');
  }
});

Deno.test('배치 제안: op가 쓰는 칸만 보내고, 카드 미리보기 요약을 돌려주며, 한 답변 4장까지', async () => {
  const store = new MemoryThinkStore();
  store.courseThinkPreview = { title: '개념 배치', course_name: '중1-1', counts: { place: 1, move: 0, remove: 0, reorder: 0 }, judgment: 1 };
  const c = ctx();
  const item = {
    op: 'place', concept_id: C1, placement_id: null, unit_id: U111, basis: 'judgment', evidence: '소수의 뜻', placement_ids: null,
  };
  const r = await call(store, PLACEMENT_TOOL_NAME, { course_id: COURSE, items: [item], reason: '중1-1 배치 요청' }, c);
  assert(r.ok);
  assertEquals(store.courseThinkProposals[0].kind, 'concept_placement_change');
  assertEquals(store.courseThinkProposals[0].payload, {
    course_id: COURSE,
    items: [{ op: 'place', concept_id: C1, unit_id: U111, basis: 'judgment', evidence: '소수의 뜻' }],
    reason: '중1-1 배치 요청',
  });
  const v = parse(r);
  assertEquals([v.status, v.judgment], ['proposed', 1]);
  assert(r.action);

  for (let i = 0; i < 3; i++) await call(store, PLACEMENT_TOOL_NAME, { course_id: COURSE, items: [item], reason: 'x' }, c);
  const fifth = await call(store, PLACEMENT_TOOL_NAME, { course_id: COURSE, items: [item], reason: 'x' }, c);
  assertEquals([fifth.ok, parse(fifth).error], [false, 'course_think_card_limit']);
  assertEquals(store.courseThinkProposals.length, 4);
});

Deno.test('제안 오류: 항목·바꾸기 번호와 다음 행동을 돌려주고, 이유 없는 제안·준비 안 된 요청은 RPC를 부르지 않는다', async () => {
  const store = new MemoryThinkStore();
  store.courseThinkProposeError = 'course_placement_bad_item:2:course_placement_no_source';
  const item = { op: 'place', concept_id: C1, placement_id: null, unit_id: U111, basis: 'source', evidence: '책', placement_ids: null };
  const r = parse(await call(store, PLACEMENT_TOOL_NAME, { course_id: COURSE, items: [item, item], reason: 'x' }));
  assertEquals([r.error, r.item], ['course_placement_no_source', 2]);
  assert(r.next.includes('judgment'));

  store.courseThinkProposeError = 'course_think_cycle:3';
  const op = { op: 'move', key: null, unit: U1, parent: U111, position: null, after: null, name: null, school_level: null, curriculum_code: null };
  const m = parse(await call(store, MAP_CHANGE_TOOL_NAME, { course_id: COURSE, course_action: null, ops: [op], reason: 'x' }));
  assertEquals([m.error, m.op], ['course_think_cycle', 3]);

  store.courseThinkProposeError = 'something_new';
  const unknown = await call(store, MAP_CHANGE_TOOL_NAME, { course_id: COURSE, course_action: null, ops: [op], reason: 'x' });
  assertEquals(parse(unknown).error, 'lookup_failed');

  store.courseThinkProposeError = null;
  const noReason = await call(store, MAP_CHANGE_TOOL_NAME, { course_id: COURSE, course_action: null, ops: [op], reason: ' ' });
  assertEquals(parse(noReason).error, 'course_think_reason_required');
  const off = await call(store, MAP_CHANGE_TOOL_NAME, { course_id: COURSE, course_action: null, ops: [op], reason: 'x' }, null);
  assertEquals(parse(off).error, 'course_map_unavailable');
  const badOp = await call(store, MAP_CHANGE_TOOL_NAME, { course_id: COURSE, course_action: null, ops: [{ op: 'explode' }], reason: 'x' });
  assertEquals([parse(badOp).error, parse(badOp).op], ['course_think_bad_op', 1]);
  assertEquals(store.courseThinkProposals.length, 0);

  assertEquals(parseProposeError('course_think_action_propose: concept_think_bad_item:4:concept_think_verbatim'), {
    code: 'concept_think_verbatim', item: 4, op: null,
  });
});

Deno.test('단원 틀·새 과정 제안: 보관은 ops 없이, move의 null parent는 보내지 않아 지금 위 단원을 지킨다', async () => {
  const store = new MemoryThinkStore();
  const move = { op: 'move', key: null, unit: U12, parent: null, position: 'first', after: null, name: null, school_level: null, curriculum_code: null };
  const course = { op: 'course', key: null, unit: null, parent: null, position: null, after: null, name: null, school_level: null, curriculum_code: '' };
  await call(store, MAP_CHANGE_TOOL_NAME, { course_id: COURSE, course_action: null, ops: [move, course], reason: '순서' });
  assertEquals(store.courseThinkProposals[0].payload.ops, [{ op: 'move', unit: U12, position: 'first' }, { op: 'course', curriculum_code: '' }]);

  await call(store, MAP_CHANGE_TOOL_NAME, { course_id: COURSE, course_action: 'archive', ops: [move], reason: '안 씀' });
  assertEquals(store.courseThinkProposals[1].payload, { course_id: COURSE, course_action: 'archive', ops: null, reason: '안 씀' });

  await call(store, COURSE_CREATE_TOOL_NAME, {
    name: '수학Ⅰ', school_level: '고', curriculum_code: null,
    units: [{ key: 'a', parent_key: null, name: '지수함수' }, { key: 'b', parent_key: 'a', name: '지수' }], reason: '새 과정',
  });
  assertEquals(store.courseThinkProposals[2].kind, 'course_map_create');
  assertEquals(store.courseThinkProposals[2].payload.units, [
    { key: 'a', parent_key: null, name: '지수함수' },
    { key: 'b', parent_key: 'a', name: '지수' },
  ]);
});

Deno.test('개념 제안: 서술은 바꿀 칸만 content로 보내고, 고치기는 null 칸을 빼서 그대로 둔다', async () => {
  const store = new MemoryThinkStore();
  const blank = { concept_id: null, statement_id: null, name: null, type: null, folder: null, content: null, place_unit_id: null, evidence: null, statement_fields: null };
  const fields = { title: null, body: '다듬은 글', approach: null, conditions: null, terms: null, basis: 'organized', supplement_note: '', unverified_note: null, meaning: null, scope: null };
  await call(store, CONCEPT_CHANGE_TOOL_NAME, {
    items: [
      { ...blank, op: 'statement', statement_id: ST, statement_fields: fields },
      { ...blank, op: 'edit', concept_id: C1, name: '소수(素數)' },
      { ...blank, op: 'delete', concept_id: C1, name: '무시' },
    ],
    reason: '사용자와 정한 문장',
  });
  assertEquals(store.courseThinkProposals[0].kind, 'concept_library_change');
  assertEquals(store.courseThinkProposals[0].payload.items, [
    { op: 'statement', statement_id: ST, content: { body: '다듬은 글', basis: 'organized', supplement_note: '' } },
    { op: 'edit', concept_id: C1, name: '소수(素數)' },
    { op: 'delete', concept_id: C1 },
  ]);
});

Deno.test('작업 상태 메모: 과정 카드는 과정 이름·카드 id와 항목별 결과를 보여 준다', () => {
  const base = { conversation_id: 'c', message_id: null, payload: {}, error: null, created_at: '2026-10-23T00:00:00Z' };
  const note = workStateNote({
    actions: [
      { ...base, id: 'a1', kind: 'concept_placement_change', status: 'applied', preview: { title: '개념 배치', course_name: '중1-1' }, result: { applied: 3, failed: 1, skipped: 2 } },
      { ...base, id: 'a2', kind: 'course_map_create', status: 'proposed', preview: { title: '새 과정', name: '수학Ⅰ' }, result: null },
    ],
    codeRequests: [],
  })!;
  assert(note.includes('개념 배치 제안 "중1-1": 사용자가 승인해 실행됨 (반영 3개, 실패 1개, 뺌 2개) (카드 id: a1)'));
  assert(note.includes('새 과정 제안 "수학Ⅰ": 사용자 확인 대기 (카드 id: a2)'));
});
