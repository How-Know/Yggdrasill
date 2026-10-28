import { assert, assertEquals } from 'jsr:@std/assert@1';
import { FakeAiProvider, type FakeTurn } from '../_shared/ai/fake.ts';
import type { AiRequest } from '../_shared/ai/types.ts';
import { workStateNote } from './actions.ts';
import { runThinkChat, type ChatInput } from './chat.ts';
import {
  CONCEPT_EDIT_READ_TOOL_NAME,
  COURSE_MAPS_TOOL_NAME,
  REVIEW_LIST_TOOL_NAME,
  REVIEW_PROPOSE_TOOL_NAME,
  REVIEW_STATUS_TOOL_NAME,
} from './course_map_tools.ts';
import { computeFeatures } from './features.ts';
import { THINK_PROMPT_VERSION } from './prompts.ts';
import { runThinkTool, thinkToolsFor } from './tools.ts';
import { EventLog, MemoryThinkStore, RunLog, testEnv } from './test_support.ts';

const ALL = {
  conversation_split: 1, think_roles: 1, memory_proposals: 1, department_work: 1, auto_organize: 1, course_map_actions: 1,
  concept_review: 1,
};
const READY = computeFeatures({ ok: true, features: ALL }, ALL, true);
const OLD_APP = computeFeatures({ ok: true, features: ALL }, { ...ALL, concept_review: 0 }, true);
const DB_REQUIRED = computeFeatures({ ok: true, features: { ...ALL, concept_review: 0 } }, ALL, true);
const MAP_OLD_APP = computeFeatures({ ok: true, features: ALL }, { ...ALL, course_map_actions: 0 }, true);

const C1 = 'cccccccc-0000-4000-8000-000000000001';
const C2 = 'cccccccc-0000-4000-8000-000000000002';
const ST = 'eeeeeeee-0000-4000-8000-000000000001';
const WALK = 'ffffffff-0000-4000-8000-000000000001';
const FOLDER = 'abababab-0000-4000-8000-000000000001';
const REV = '0123456789ab-0123456789ab-0123456789ab';
const REVIEW_TOOLS = [REVIEW_LIST_TOOL_NAME, REVIEW_STATUS_TOOL_NAME, REVIEW_PROPOSE_TOOL_NAME];

const ctx = (review = true) => ({
  conversationId: 'conv-x', memoryRefs: [], courseMap: { proposed: new Map<string, number>(), review },
});
const parse = (r: { output: string }) => JSON.parse(r.output);
const call = (store: MemoryThinkStore, name: string, args: unknown, c: ReturnType<typeof ctx> = ctx()) =>
  runThinkTool(name, JSON.stringify(args), store, 8000, c);

const LIST_ARGS = { walk_id: null, folder_id: null, type: null, name: null, placed: null, review: null, review_scope: null, offset: null };
const EDIT_ARGS = { concept_id: C1, part: null, statement_id: null, field: null, offset: null };

function brief(id: string, extra: Record<string, unknown> = {}) {
  return {
    id, name: '소수', type: '정의', folder: ['수와 연산', '소인수분해'], excerpt: '1보다 큰 자연수 중', content_chars: 40,
    statements: 1, sources: 2, placed: 0, relations: 1, same_name: 1, open_same_concept_reviews: 0, revision: REV,
    review: { notation: { record_id: 'r1', outcome: 'no_issue_found', stale: false, records: 1 }, meaning: { outcome: 'issue_found', stale: true } },
    ...extra,
  };
}

function walk(items: unknown[], extra: Record<string, unknown> = {}) {
  return {
    walk_id: WALK, started_at: '2026-10-23T00:00:00Z', filter: { folder_id: FOLDER, placed: 'any', review: 'any' }, total: 3, offset: 0,
    items, next_offset: null, created_after: 0, ...extra,
  };
}

function detail(extra: Record<string, unknown> = {}) {
  return {
    id: C1, name: '소수', type: '정의', folder: ['수와 연산'], content: '1보다 큰 자연수 중 약수가 1과 자기 자신뿐인 수',
    content_draft_pending: false,
    statements: [{ id: ST, role: 'statement', version: 1, has_draft: false, content: { title: '서술', body: '본문', terms: ['약수'] } }],
    source_count: 1,
    sources: [{ book: '개념+유형', grade: '중1-1', course_key: 'M1-1', unit_path: ['Ⅰ', '1'], page: 8, statement_id: null }],
    placements: [],
    attached: { sources: 1, quality_reviews: 1, reviews: 1, total: 3 },
    appearances: [{ id: 'a1', curriculum_code: 'rev_2022', school_level: '중', course_label: '1-1', unit_path: [], note: null }],
    relations: [{ id: 'r1', direction: 'out', kind: 'extends', other_id: C2, other_name: '합성수', origin: 'manual', note: null }],
    same_concept_reviews: [{ id: 'v1', other_id: C2, other_name: '합성수', reason: 'overlap', status: 'open', note: '겹침' }],
    same_concept_review_count: 1,
    review: { notation: { outcome: 'no_issue_found', stale: false, reviewed_at: '2026-10-23', records: 1 } },
    revision: REV,
    statement_versions: [{ id: ST, version: 1 }],
    ...extra,
  };
}

function input(partial: Partial<ChatInput>): ChatInput {
  return {
    userId: 'user-1', safetyId: 'hash', conversationId: null, message: '소인수분해 폴더 개념을 검토해 줘', attachments: [], deep: false,
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

Deno.test('검토 도구 노출: 과정 도구와 검토 기능이 모두 준비된 요청에만, 커서 질문에는 주지 않는다', () => {
  const both = thinkToolsFor({ split: false, courseMap: true, conceptReview: true }).map((t) => t.name);
  for (const n of [...REVIEW_TOOLS, CONCEPT_EDIT_READ_TOOL_NAME]) assert(both.includes(n), n);
  const mapOnly = thinkToolsFor({ split: false, courseMap: true }).map((t) => t.name);
  assert(mapOnly.includes(CONCEPT_EDIT_READ_TOOL_NAME));
  for (const n of REVIEW_TOOLS) assert(!mapOnly.includes(n), n);
  const reviewOnly = thinkToolsFor({ split: false, conceptReview: true }).map((t) => t.name);
  for (const n of REVIEW_TOOLS) assert(!reviewOnly.includes(n), n);
  const relay = thinkToolsFor({ split: false, courseMap: true, conceptReview: true, readOnly: true }).map((t) => t.name);
  for (const n of REVIEW_TOOLS) assert(!relay.includes(n), n);
});

Deno.test('대화: 준비됐으면 검토 도구·지침·기능 상태, 앱·DB가 안 됐으면 도구와 지침 없이 무엇이 필요한지만 알린다', async () => {
  const store = new MemoryThinkStore();
  const conv = await store.createConversation('검토');
  const ready = await run(store, { conversationId: conv.id, features: READY });
  const req = chatRequest(ready.provider);
  for (const n of REVIEW_TOOLS) assert(toolNames(req).includes(n), n);
  assert(req.instructions!.includes('## 개념 검토'));
  assert(featureNote(req).includes('개념 검토 목록·범위별 검토 기록'));
  assert(featureNote(req).includes('개념 검토 목록·범위별 검토 기록(list_concepts_for_review, propose_concept_review): 사용 가능'));
  const f = ready.runs.runs[0].features as Record<string, unknown>;
  assertEquals([f.course_map_tools, f.concept_review_tools], [true, true]);
  assertEquals(ready.runs.runs[0].promptVersion, THINK_PROMPT_VERSION);
  assertEquals(THINK_PROMPT_VERSION, 'think-2026-10-28c');

  const cases: [typeof READY, string, boolean][] = [
    [OLD_APP, '앱 업데이트 필요', true],
    [DB_REQUIRED, 'DB 반영 필요', true],
    [MAP_OLD_APP, '앱 업데이트 필요', false],
  ];
  for (const [features, label, mapTools] of cases) {
    const other = new MemoryThinkStore();
    const c = await other.createConversation('검토');
    const r = await run(other, { conversationId: c.id, features });
    const q = chatRequest(r.provider);
    for (const n of REVIEW_TOOLS) assert(!toolNames(q).includes(n), n);
    assertEquals(toolNames(q).includes(COURSE_MAPS_TOOL_NAME), mapTools);
    assert(!q.instructions!.includes('## 개념 검토'));
    const line = featureNote(q).split('\n').find((l) => l.includes('개념 검토 목록·범위별 검토 기록'))!;
    assert(line.includes(label), line);
    assertEquals((r.runs.runs[0].features as Record<string, unknown>).concept_review_tools, false);
  }
});

Deno.test('검토 목록: 처음엔 조건으로 고정하고, 이어 읽기는 walk_id만 보내며, 남은 범위와 검토 상태를 알린다', async () => {
  const store = new MemoryThinkStore();
  store.courseMapData.set('concept_review_walk', walk([brief(C1), { id: C2, missing: true }], { next_offset: 2, created_after: 2 }));
  const first = await call(store, REVIEW_LIST_TOOL_NAME, { ...LIST_ARGS, folder_id: FOLDER, review: 'not_current', review_scope: 'meaning' });
  assert(first.ok);
  assertEquals(store.courseMapReads.at(-1)!, {
    fn: 'concept_review_walk',
    args: {
      p_walk_id: null,
      p_filter: { folder_id: FOLDER, type: null, name: null, placed: null, review: 'not_current', review_scope: 'meaning' },
      p_offset: 0, p_limit: 40,
    },
  });
  const v = parse(first);
  assertEquals([v.walk_id, v.total, v.from, v.to, v.next_offset, v.done, v.remaining], [WALK, 3, 0, 2, 2, false, 1]);
  assertEquals(v.items[0].folder, '수와 연산 › 소인수분해');
  assertEquals(v.items[0].review, { notation: 'no_issue_found', meaning: 'issue_found, stale' });
  assertEquals('content' in v.items[0], false);
  assertEquals(v.items[1], { id: C2, missing: true });
  assert(v.note.includes('지워진'));
  assert(v.note.includes('2개는 이 목록에 없다'));

  store.courseMapData.set('concept_review_walk', walk([brief(C2)], { offset: 2 }));
  const next = parse(await call(store, REVIEW_LIST_TOOL_NAME, { ...LIST_ARGS, walk_id: WALK, folder_id: FOLDER, offset: 2 }));
  assertEquals(store.courseMapReads.at(-1)!.args, { p_walk_id: WALK, p_filter: null, p_offset: 2, p_limit: 40 });
  assertEquals([next.from, next.to, next.next_offset, next.done, next.remaining], [2, 3, null, true, 0]);

  store.courseMapData.set('concept_review_walk', walk([], { total: 0 }));
  const empty = await call(store, REVIEW_LIST_TOOL_NAME, LIST_ARGS);
  assert(empty.ok);
  assert(parse(empty).note.includes('조회는 성공했다'));
  assertEquals(empty.summary, '조건에 맞는 개념 없음');
});

Deno.test('검토 목록: 출력 한도를 넘으면 앞쪽만 싣고 next_offset을 그만큼만 옮긴다', async () => {
  const store = new MemoryThinkStore();
  const many = Array.from({ length: 40 }, (_, i) =>
    brief(`cccccccc-0000-4000-8000-${String(i).padStart(12, '0')}`, { excerpt: '가'.repeat(120), folder: ['아주 긴 폴더 이름'.repeat(30)] }));
  store.courseMapData.set('concept_review_walk', walk(many, { total: 100, next_offset: 40 }));
  const v = parse(await call(store, REVIEW_LIST_TOOL_NAME, LIST_ARGS));
  assert(v.items.length < 40, String(v.items.length));
  assertEquals(v.next_offset, v.items.length);
  assertEquals(v.remaining, 100 - v.items.length);
  assertEquals(v.truncated, undefined);
});

Deno.test('검토 목록 오류: 없는 목록·권한 없음·조회 실패를 빈 결과와 구분하고, 기능이 없으면 RPC를 부르지 않는다', async () => {
  const store = new MemoryThinkStore();
  store.courseMapReadError = 'concept_review_walk_not_found';
  const gone = parse(await call(store, REVIEW_LIST_TOOL_NAME, { ...LIST_ARGS, walk_id: WALK }));
  assertEquals(gone.error, 'concept_review_walk_not_found');
  assert(gone.next.includes('새 목록'));
  store.courseMapReadError = 'concept_review_forbidden';
  const forbidden = parse(await call(store, REVIEW_LIST_TOOL_NAME, LIST_ARGS));
  assertEquals(forbidden.error, 'concept_review_forbidden');
  assert(forbidden.next.includes('결과가 없다는 뜻이 아니다'));
  store.courseMapReadError = 'connection reset';
  assertEquals(parse(await call(store, REVIEW_LIST_TOOL_NAME, LIST_ARGS)).error, 'lookup_failed');
  store.courseMapReadError = null;
  store.courseMapData.set('concept_review_walk', { unexpected: true });
  assertEquals(parse(await call(store, REVIEW_LIST_TOOL_NAME, LIST_ARGS)).error, 'lookup_failed', '모양이 다른 결과를 빈 목록으로 보지 않는다');

  const reads = store.courseMapReads.length;
  for (const name of REVIEW_TOOLS) {
    const off = parse(await call(store, name, LIST_ARGS, ctx(false)));
    assertEquals(off.error, 'concept_review_unavailable', name);
  }
  assertEquals(store.courseMapReads.length, reads);
  assertEquals(store.courseThinkProposals.length, 0);
  assertEquals(parse(await call(store, REVIEW_LIST_TOOL_NAME, { ...LIST_ARGS, walk_id: 'abc' })).error, 'invalid_id');
});

Deno.test('검토 상태: id를 검사해 그대로 넘기고, 길면 결과·판만 보내며 그렇게 알린다', async () => {
  const store = new MemoryThinkStore();
  for (const ids of [[], [C1, C1], ['abc'], Array.from({ length: 21 }, (_, i) => `cccccccc-0000-4000-8000-${String(i).padStart(12, '0')}`)]) {
    assertEquals(parse(await call(store, REVIEW_STATUS_TOOL_NAME, { concept_ids: ids })).error, 'concept_review_bad_ids');
  }
  assertEquals(store.courseMapReads.length, 0);

  const latest = { outcome: 'needs_comparison', stale: true, reviewed_at: '2026-10-23', findings: '가'.repeat(1900), checked: '나'.repeat(900) };
  const row = (id: string) => ({
    id, name: '소수', revision: REV, pending: [],
    scopes: { notation: null, meaning: { latest, earlier: [], records: 2 }, unit: { latest, earlier: [], records: 1 } },
  });
  store.courseMapData.set('concept_review_status', [row(C1)]);
  const small = parse(await call(store, REVIEW_STATUS_TOOL_NAME, { concept_ids: [C1] }));
  assertEquals(store.courseMapReads.at(-1)!, { fn: 'concept_review_status', args: { p_concept_ids: [C1] } });
  assertEquals(small.concepts[0].scopes.meaning.latest.findings.length, 1900);

  const ids = Array.from({ length: 12 }, (_, i) => `cccccccc-0000-4000-8000-${String(i).padStart(12, '0')}`);
  store.courseMapData.set('concept_review_status', ids.map(row));
  const big = parse(await call(store, REVIEW_STATUS_TOOL_NAME, { concept_ids: ids }));
  assertEquals(big.concepts.length, 12);
  assertEquals(big.concepts[0].scopes.meaning, { outcome: 'needs_comparison', stale: true, reviewed_at: '2026-10-23', records: 2 });
  assert(big.note.includes('다시 읽는다'));
});

Deno.test('개념 읽기: 판·검토 상태·관계·같은 개념 검토·등장 위치를 싣고, 붙은 것 이름에 범위별 검토 기록이 있다', async () => {
  const store = new MemoryThinkStore();
  store.courseMapData.set('concept_think_detail', detail());
  const v = parse(await call(store, CONCEPT_EDIT_READ_TOOL_NAME, EDIT_ARGS));
  assertEquals(v.revision, REV);
  assertEquals(v.unreviewed, ['meaning', 'classification', 'unit', 'relations', 'foundation', 'placement']);
  assertEquals(v.review.notation.outcome, 'no_issue_found');
  assertEquals(v.relations[0], {
    id: 'r1', direction: 'out', kind: 'extends', other_id: C2, other_name: '합성수', origin: 'manual', context: null, note: null,
  });
  assertEquals(v.same_concept_reviews[0].status, 'open');
  assertEquals(v.appearances[0].course_label, '1-1');
  assertEquals(v.delete_blocked_by, ['출처 1', '범위별 검토 기록 1', '같은 개념 검토 1']);
  assertEquals([v.truncated, v.read_more, v.unavailable], [undefined, undefined, undefined]);
  assertEquals(v.content_chars, v.content.length);
});

Deno.test('개념 읽기: 옛 DB라 없는 칸은 읽지 못했다고 하고, 출처가 덜 왔으면 나머지를 읽을 수 없다고 한다', async () => {
  const store = new MemoryThinkStore();
  const old = detail({ source_count: 9 });
  for (const k of ['appearances', 'relations', 'same_concept_reviews', 'same_concept_review_count', 'review', 'revision', 'statement_versions']) {
    delete (old as Record<string, unknown>)[k];
  }
  old.sources = Array.from({ length: 4 }, () => old.sources[0]);
  store.courseMapData.set('concept_think_detail', old);
  const v = parse(await call(store, CONCEPT_EDIT_READ_TOOL_NAME, EDIT_ARGS));
  assertEquals([v.revision, v.review, v.relations, v.appearances], [null, null, null, null]);
  assertEquals(v.unavailable, ['판·범위별 검토 상태', '교육과정 등장 위치', '관계', '같은 개념 검토']);
  assert(v.unavailable_note.includes('없다고 말하지 않고'));
  assertEquals(v.truncated, ['출처']);
  assertEquals(v.read_more, [{ what: '출처', shown: 4, total: 9, part: null, note: '나머지 5개는 지금 읽을 수 없다' }]);
});

Deno.test('개념 읽기: 잘린 본문·서술 칸·출처는 이어 읽을 자리를 알리고, part로 그 부분을 끝까지 읽는다', async () => {
  const store = new MemoryThinkStore();
  const body = '나'.repeat(5000);
  const content = '가'.repeat(30000);
  const sources = Array.from({ length: 45 }, (_, i) => ({ book: '책', grade: '중1-1', unit_path: [], page: i + 1 }));
  store.courseMapData.set('concept_think_detail', detail({
    content, source_count: 45, sources,
    statements: [{ id: ST, role: 'statement', version: 2, has_draft: false, content: { title: '서술', body, terms: ['약수'] } }],
  }));
  const v = parse(await call(store, CONCEPT_EDIT_READ_TOOL_NAME, EDIT_ARGS));
  assertEquals(v.content.length, 16000);
  assertEquals(v.content_chars, 30000);
  assertEquals(v.truncated, ['본문', `서술 ${ST}의 body`, '출처']);
  assertEquals(v.read_more.map((m: Record<string, unknown>) => [m.part, m.offset, m.total]), [
    ['content', 16000, 30000], ['statement', 4000, 5000], ['sources', 30, 45],
  ]);
  assert(v.note.includes('다 읽었다고 하지 않는다'));

  const p1 = parse(await call(store, CONCEPT_EDIT_READ_TOOL_NAME, { ...EDIT_ARGS, part: 'content', offset: 16000 }));
  assertEquals([p1.from, p1.to, p1.total, p1.next_offset, p1.complete, p1.text.length], [16000, 28000, 30000, 28000, false, 12000]);
  const p2 = parse(await call(store, CONCEPT_EDIT_READ_TOOL_NAME, { ...EDIT_ARGS, part: 'content', offset: 28000 }));
  assertEquals([p2.to, p2.next_offset], [30000, null]);
  assertEquals(p1.revision, REV);

  const s = parse(await call(store, CONCEPT_EDIT_READ_TOOL_NAME, { ...EDIT_ARGS, part: 'statement', statement_id: ST, field: 'body', offset: 4000 }));
  assertEquals([s.statement_id, s.field, s.statement_version, s.from, s.to, s.next_offset], [ST, 'body', 2, 4000, 5000, null]);
  const terms = parse(await call(store, CONCEPT_EDIT_READ_TOOL_NAME, { ...EDIT_ARGS, part: 'statement', statement_id: ST, field: 'terms' }));
  assertEquals([terms.text, terms.complete], ['["약수"]', true]);
  const noField = parse(await call(store, CONCEPT_EDIT_READ_TOOL_NAME, { ...EDIT_ARGS, part: 'statement', statement_id: ST, field: 'nope' }));
  assertEquals([noField.error, noField.fields], ['unknown_field', ['title', 'body', 'terms']]);
  const noStatement = parse(await call(store, CONCEPT_EDIT_READ_TOOL_NAME, { ...EDIT_ARGS, part: 'statement', statement_id: C2, field: 'body' }));
  assertEquals(noStatement.error, 'concept_statement_not_found');

  const src = parse(await call(store, CONCEPT_EDIT_READ_TOOL_NAME, { ...EDIT_ARGS, part: 'sources', offset: 30 }));
  assertEquals([src.from, src.to, src.total, src.next_offset, src.sources.length, src.sources[0].page], [30, 45, 45, null, 15, 31]);
  assertEquals(store.courseMapReads.filter((r) => r.fn === 'concept_think_detail').length, 8, '이어 읽기도 매번 지금 내용을 읽는다');
});

Deno.test('검토 기록 제안: 항목을 다듬어 보내고, 항목 번호와 다음 행동이 있는 오류를 돌려주며, 한 답변 2장까지', async () => {
  const store = new MemoryThinkStore();
  store.courseThinkPreview = {
    title: '개념 검토 기록',
    items: [{ i: 1, name: '소수', pending_elsewhere: 1 }, { i: 2, name: '합성수', pending_elsewhere: 0 }],
    counts: { no_issue_found: 1, issue_found: 0, needs_comparison: 0, unverified: 0, merge_needed: 1 },
  };
  const item = {
    concept_id: C1, revision: REV, scope: 'notation', outcome: 'no_issue_found', checked: '본문 표기', findings: '오타를 찾지 못함',
    basis: '본문 전체', unverified: null, follow_up: null, compared_ids: null, to_compare_ids: null, extra: '무시',
  };
  const c = ctx();
  const r = await call(store, REVIEW_PROPOSE_TOOL_NAME, {
    items: [item, { ...item, concept_id: C2, scope: 'unit', outcome: 'merge_needed', compared_ids: [C1] }], reason: '폴더 검토',
  }, c);
  assert(r.ok);
  assert(r.action);
  assertEquals(store.courseThinkProposals[0].kind, 'concept_review_record');
  const sent = store.courseThinkProposals[0].payload.items as Record<string, unknown>[];
  assertEquals(sent[0], {
    concept_id: C1, revision: REV, scope: 'notation', outcome: 'no_issue_found', checked: '본문 표기', findings: '오타를 찾지 못함',
    basis: '본문 전체', unverified: null, follow_up: null, compared_ids: [], to_compare_ids: [],
  });
  assertEquals(sent[1].compared_ids, [C1]);
  const v = parse(r);
  assertEquals([v.status, v.already_pending, v.counts.merge_needed], ['proposed', 1, 1]);
  assert(v.note.includes('승인한 항목만'));

  await call(store, REVIEW_PROPOSE_TOOL_NAME, { items: [item], reason: 'x' }, c);
  const third = parse(await call(store, REVIEW_PROPOSE_TOOL_NAME, { items: [item], reason: 'x' }, c));
  assertEquals(third.error, 'course_think_card_limit');
  assertEquals(store.courseThinkProposals.length, 2);

  store.courseThinkProposeError = 'concept_review_bad_item:3:concept_review_stale';
  const stale = parse(await call(store, REVIEW_PROPOSE_TOOL_NAME, { items: [item], reason: 'x' }));
  assertEquals([stale.error, stale.item], ['concept_review_stale', 3]);
  assert(stale.next.includes('다시 읽고'));
  store.courseThinkProposeError = 'concept_review_bad_item:1:concept_review_merge_scope';
  assertEquals(parse(await call(store, REVIEW_PROPOSE_TOOL_NAME, { items: [item], reason: 'x' })).error, 'concept_review_merge_scope');
  store.courseThinkProposeError = null;
  const malformed = parse(await call(store, REVIEW_PROPOSE_TOOL_NAME, { items: [item, { concept_id: C1 }], reason: 'x' }));
  assertEquals([malformed.error, malformed.item], ['concept_review_bad_op', 2]);
});

Deno.test('개념 검색: 전체 개수·이어 볼 자리·본문이 잘렸는지·같은 이름을 알린다', async () => {
  const store = new MemoryThinkStore();
  store.conceptHits = Array.from({ length: 3 }, (_, i) => ({
    id: `c${i}`, name: i === 0 ? '소수' : `소수 ${i}`, kind: 'definition', level: 1, category_path: '수와 연산', content: '본문', content_chars: i === 0 ? 900 : 2,
  }));
  const r = await runThinkTool('search_concepts', JSON.stringify({ query: '소수', limit: 2, offset: null }), store, 8000);
  const v = parse(r);
  assertEquals([v.total, v.offset, v.next_offset, v.items.length], [3, 0, 2, 2]);
  assertEquals([v.items[0].same_name, v.items[0].excerpt_truncated, v.items[0].match], [true, true, 'name']);
  assertEquals([v.items[1].same_name, v.items[1].excerpt_truncated], [false, false]);
  const rest = parse(await runThinkTool('search_concepts', JSON.stringify({ query: '소수', limit: 2, offset: 2 }), store, 8000));
  assertEquals([rest.items.length, rest.next_offset], [1, null]);
});

Deno.test('작업 상태 메모: 검토 기록 카드는 첫 개념 이름과 개수, 항목별 결과를 보여 준다', () => {
  const note = workStateNote({
    actions: [{
      id: 'a1', conversation_id: 'c', message_id: null, kind: 'concept_review_record', status: 'applied', payload: {}, error: null,
      created_at: '2026-10-23T00:00:00Z', preview: { title: '개념 검토 기록', items: [{ name: '소수' }, { name: '합성수' }] },
      result: { applied: 1, failed: 1, skipped: 0 },
    }],
    codeRequests: [],
  })!;
  assert(note.includes('개념 검토 기록 제안 "소수 외 1개": 사용자가 승인해 실행됨 (반영 1개, 실패 1개, 뺌 0개) (카드 id: a1)'));
});
