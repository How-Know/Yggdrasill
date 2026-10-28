import { assert, assertEquals } from 'jsr:@std/assert@1';
import { FakeAiProvider, type FakeTurn } from '../_shared/ai/fake.ts';
import { buildResponsesBody } from '../_shared/ai/openai.ts';
import type { AiRequest } from '../_shared/ai/types.ts';
import { runThinkChat, type ChatInput } from './chat.ts';
import {
  type ConceptSourceToolContext,
  SOURCE_ADJACENT_LIMIT,
  SOURCE_IMAGE_LIMIT,
  SOURCE_LIST_TOOL_NAME,
  SOURCE_PAGE_TOOL_NAME,
} from './concept_source_tools.ts';
import { COURSE_MAPS_TOOL_NAME } from './course_map_tools.ts';
import { computeFeatures } from './features.ts';
import { THINK_PROMPT_VERSION } from './prompts.ts';
import { runThinkTool, thinkToolsFor } from './tools.ts';
import { EventLog, MemoryThinkStore, RunLog, testEnv } from './test_support.ts';

const ALL = {
  conversation_split: 1, think_roles: 1, memory_proposals: 1, department_work: 1, auto_organize: 1, course_map_actions: 1,
  concept_review: 1, concept_relation_change: 1, concept_source_pages: 1,
};
const { concept_source_pages: _unused, ...APP_WITHOUT } = ALL;
const READY = computeFeatures({ ok: true, features: ALL }, APP_WITHOUT, true);
const DB_REQUIRED = computeFeatures({ ok: true, features: { ...ALL, concept_source_pages: 0 } }, ALL, true);
const MAP_OLD_APP = computeFeatures({ ok: true, features: ALL }, { ...ALL, course_map_actions: 0 }, true);

const CONCEPT = 'cccccccc-0000-4000-8000-000000000001';
const SRC = 'eeeeeeee-0000-4000-8000-000000000001';
const SRC_B = 'eeeeeeee-0000-4000-8000-000000000002';
const SOURCE_TOOLS = [SOURCE_LIST_TOOL_NAME, SOURCE_PAGE_TOOL_NAME];
const keyOf = (page: number) => `academies/a1/books/b1/links/7/sha256ABCDEF0123_p${page}.png`;

function png(width: number, height: number): Uint8Array {
  const b = new Uint8Array(40);
  b.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], 0);
  b.set([0x49, 0x48, 0x44, 0x52], 12);
  const v = new DataView(b.buffer);
  v.setUint32(16, width);
  v.setUint32(20, height);
  return b;
}

/** 인쇄 쪽과 PDF 쪽이 2쪽 어긋난 책: PDF 12쪽이 인쇄 10쪽. */
function pageContext(offset: number, extra: Record<string, unknown> = {}) {
  const raw = 12 + offset;
  return {
    source: {
      id: SRC, concept_id: CONCEPT, concept_name: '소수', statement_id: null, book_id: 'b1', book_name: '개념+유형 중1-1',
      grade_label: '1-1', raw_page: 12, display_page: 10, unit_path: ['소인수분해', '소수와 합성수'], evidence_scope: 'whole',
      evidence_note: null, draft_id: 'd1', draft_found: true, block_ids: ['p12-a0'],
    },
    page: { raw_page: raw, offset, display_page: offset === 0 ? 10 : null, display_from: offset === 0 ? 'source' : null },
    blocks_from: offset === 0 ? 'draft' : null,
    blocks: offset === 0
      ? [
        { id: 'p12-a0', read: 'a', kind: 'explanation', title: '소수', text: '1보다 큰 자연수 중 약수가 1과 자기 자신뿐인 수', figure_description: '', uncertain: false, linked: true },
        { id: 'p12-a1', read: 'a', kind: 'figure', title: '', text: '', figure_description: '수직선 위에 2, 3, 5가 표시됨', uncertain: true, linked: false },
      ]
      : [],
    linked_missing: [],
    disagreements: offset === 0 ? [{ id: 'p12-a1', type: 'text_differs' }] : [],
    transcript: offset === 0 ? { prompt_version: 'concept_page_read.v2', reads: [1, 2], page_kind: 'mixed', notes: '', created_at: '2026-10-20' } : null,
    masks: offset === 0 ? [{ label: 'M1', bbox_1k: [600, 0, 900, 500], problem_number: '3' }] : null,
    basis: offset === 0 ? { kind: 'base', text: '소수는 1보다 큰 자연수 중 약수가 두 개인 수다.', md5: 'x' } : null,
    ...extra,
  };
}

function readyImage(args: Record<string, unknown>) {
  const page = 12 + Number(args.p_offset);
  return {
    status: 'ready', error: null, raw_page: page, image_bucket: 'concept-source-pages', image_key: keyOf(page), width: 1131, height: 1600,
    bytes: 40, worker_alive: true, worker_seen_at: '2026-10-23T00:00:00Z',
  };
}

function storeWithSource(image: unknown = readyImage) {
  const store = new MemoryThinkStore();
  store.conceptSourceData.set('concept_source_page_context', (a: Record<string, unknown>) => pageContext(Number(a.p_offset)));
  store.conceptSourceData.set('concept_source_page_image', image);
  for (let p = 10; p <= 14; p++) store.conceptSourceImages.set(keyOf(p), png(1131, 1600));
  return store;
}

const ctx = (extra: Partial<ConceptSourceToolContext> = {}) => ({
  conversationId: 'conv-x',
  memoryRefs: [],
  courseMap: { proposed: new Map<string, number>(), review: true, relations: true },
  conceptSources: { imagesLeft: SOURCE_IMAGE_LIMIT, adjacentLeft: SOURCE_ADJACENT_LIMIT, deadline: Date.now() + 60_000, ...extra },
});
const parse = (r: { output: string }) => JSON.parse(r.output);
const read = (store: MemoryThinkStore, args: Record<string, unknown>, c = ctx()) =>
  runThinkTool(SOURCE_PAGE_TOOL_NAME, JSON.stringify({ source_id: SRC, page_offset: null, with_image: true, ...args }), store, 50_000, c);

/** 가짜 시계: sleep 이 시간을 앞당긴다. */
function clock(start = 1_000_000) {
  let t = start;
  const sleeps: number[] = [];
  return {
    now: () => t,
    sleep: (ms: number) => {
      sleeps.push(ms);
      t += ms;
      return Promise.resolve();
    },
    sleeps,
  };
}

function input(partial: Partial<ChatInput>): ChatInput {
  return {
    userId: 'user-1', safetyId: 'hash', conversationId: null, message: '소수 개념의 그림 설명이 이상한데 원본을 확인해 줘', attachments: [],
    deep: false, webSearch: false, signal: new AbortController().signal, startedAt: Date.now(), wallClockMs: 140000, ...partial,
  };
}

async function run(store: MemoryThinkStore, partial: Partial<ChatInput>, script?: (req: AiRequest, i: number) => FakeTurn) {
  const provider = new FakeAiProvider(script ?? (() => ({ text: '답변' })));
  const runs = new RunLog();
  const events = new EventLog();
  await runThinkChat(input(partial), { provider, store, recordRun: runs.record, emit: events.emit, env: testEnv });
  return { provider, runs, events };
}

const toolNames = (req: AiRequest) => (req.tools ?? []).map((t) => t.name);
const chatRequest = (provider: FakeAiProvider) => provider.requests.find((r) => (r.tools ?? []).length > 0)!;
const featureNote = (req: AiRequest) =>
  req.input.filter((i) => i.kind === 'context').map((i) => (i as { text: string }).text).find((t) => t.startsWith('[실행 환경 기능 상태')) ?? '';

Deno.test('출처 원본 도구: 과정 도구와 기능이 모두 준비된 요청에만, 커서 질문에는 주지 않는다. 앱 업데이트 없이 DB·Edge만 보면 된다', () => {
  const both = thinkToolsFor({ split: false, courseMap: true, conceptSources: true }).map((t) => t.name);
  for (const n of SOURCE_TOOLS) assert(both.includes(n), n);
  const mapOnly = thinkToolsFor({ split: false, courseMap: true }).map((t) => t.name);
  for (const n of SOURCE_TOOLS) assert(!mapOnly.includes(n), n);
  const sourcesOnly = thinkToolsFor({ split: false, conceptSources: true }).map((t) => t.name);
  for (const n of SOURCE_TOOLS) assert(!sourcesOnly.includes(n), n);
  const relay = thinkToolsFor({ split: false, courseMap: true, conceptSources: true, readOnly: true }).map((t) => t.name);
  for (const n of SOURCE_TOOLS) assert(!relay.includes(n), n);

  assertEquals(READY.concept_source_pages.state, 'ready', '앱이 기능 번호를 안 보내도 준비됨');
  assertEquals(DB_REQUIRED.concept_source_pages.state, 'db_required');
  assertEquals(MAP_OLD_APP.course_map_actions.state, 'app_update_required');
});

Deno.test('대화: 준비됐으면 도구·지침·기능 상태가 들어가고, DB가 안 됐거나 과정 도구가 없으면 도구 없이 원본을 못 읽는다고 알린다', async () => {
  const store = new MemoryThinkStore();
  const conv = await store.createConversation('출처');
  const ready = await run(store, { conversationId: conv.id, features: READY });
  const req = chatRequest(ready.provider);
  for (const n of SOURCE_TOOLS) assert(toolNames(req).includes(n), n);
  assert(req.instructions!.includes('## 개념 출처 원본 다시 읽기'));
  assert(featureNote(req).includes('개념 출처 원본 다시 읽기(get_concept_sources, read_concept_source_page): 사용 가능'));
  assertEquals((ready.runs.runs[0].features as Record<string, unknown>).concept_source_tools, true);
  assertEquals(ready.runs.runs[0].promptVersion, THINK_PROMPT_VERSION);

  for (const [features, label, mapTools] of [[DB_REQUIRED, 'DB 반영 필요', true], [MAP_OLD_APP, '앱 업데이트 필요', false]] as const) {
    const other = new MemoryThinkStore();
    const c = await other.createConversation('출처');
    const r = await run(other, { conversationId: c.id, features });
    const q = chatRequest(r.provider);
    for (const n of SOURCE_TOOLS) assert(!toolNames(q).includes(n), n);
    assertEquals(toolNames(q).includes(COURSE_MAPS_TOOL_NAME), mapTools);
    assert(!q.instructions!.includes('## 개념 출처 원본 다시 읽기'));
    const note = featureNote(q);
    const line = note.split('\n').find((l) => l.includes('개념 출처 원본 다시 읽기'))!;
    assert(line.includes(label), line);
    assert(note.includes('원본을 봤다고 말하지 않는다'));
    assertEquals((r.runs.runs[0].features as Record<string, unknown>).concept_source_tools, false);
  }
});

Deno.test('출처 목록: PDF 쪽과 인쇄 쪽을 따로 주고, 인쇄 쪽 기록이 없으면 null, 여러 출처·연결 상태를 구별한다', async () => {
  const store = new MemoryThinkStore();
  store.conceptSourceData.set('concept_source_list', {
    concept_id: CONCEPT, name: '소수', total: 2,
    sources: [
      {
        id: SRC, statement_id: null, statement_title: null, book_id: 'b1', book_name: '개념+유형 중1-1', grade_label: '1-1', raw_page: 12,
        display_page: 10, unit_path: ['소인수분해'], evidence_scope: 'whole', block_count: 1, draft: 'found', draft_covers_page: true,
        transcript_reads: 2, member: true, link: 'ok', image: { status: 'ready' },
      },
      {
        id: SRC_B, statement_id: null, statement_title: null, book_id: 'b2', book_name: '쎈 중1-1', grade_label: '1-1', raw_page: 30,
        display_page: null, unit_path: [], evidence_scope: null, block_count: 2, draft: 'missing', draft_covers_page: false,
        transcript_reads: 0, member: false, link: 'link_missing', image: { status: 'link_missing' },
      },
    ],
  });
  const r = await runThinkTool(SOURCE_LIST_TOOL_NAME, JSON.stringify({ concept_id: CONCEPT, offset: null }), store, 20000, ctx());
  assert(r.ok);
  assertEquals(store.conceptSourceReads.at(-1), { fn: 'concept_source_list', args: { p_concept_id: CONCEPT } });
  const v = parse(r);
  assertEquals([v.total, v.next_offset], [2, null]);
  const [a, b] = v.sources;
  assertEquals([a.source_id, a.book, a.pdf_page, a.print_page], [SRC, '개념+유형 중1-1', 12, 10]);
  assertEquals([b.source_id, b.book, b.pdf_page, b.print_page], [SRC_B, '쎈 중1-1', 30, null]);
  assertEquals([a.original_pdf, a.page_image, a.extracted_text, a.transcript], ['원본 PDF 연결됨', '준비됨', '초안 블록 있음', '전사 2회']);
  assert(b.original_pdf.startsWith('연결 끊김'), b.original_pdf);
  assert(b.extracted_text.startsWith('연결 끊김'), b.extracted_text);
  assert(b.image_access.startsWith('접근 실패'), b.image_access);
  assert(v.page_note.includes('추정하지 않는다'));

  store.conceptSourceData.set('concept_source_list', { concept_id: CONCEPT, name: '소수', total: 0, sources: [] });
  const empty = parse(await runThinkTool(SOURCE_LIST_TOOL_NAME, JSON.stringify({ concept_id: CONCEPT, offset: null }), store, 20000, ctx()));
  assert(empty.note.startsWith('자료 없음'), empty.note);
});

Deno.test('쪽 읽기: PDF 쪽으로 고르고 자료를 나눠 주며, 확인한 그 쪽 이미지만 모델 입력용으로 붙인다. 키·주소는 결과에 없다', async () => {
  const store = storeWithSource();
  const r = await read(store, {});
  assert(r.ok);
  assertEquals(store.conceptSourceReads.map((x) => x.fn), ['concept_source_page_context', 'concept_source_page_image']);
  assertEquals(store.conceptSourceReads[0].args, { p_source_id: SRC, p_offset: 0 });
  assertEquals(store.conceptSourceReads[1].args, { p_source_id: SRC, p_offset: 0, p_request: true });
  assertEquals(store.conceptSourceImageReads, [keyOf(12)]);
  const v = parse(r);
  assertEquals(v.status, '조회됨');
  assertEquals(v.page, { pdf_page: 12, print_page: 10, print_page_from: '출처 기록', offset: 0 });
  assertEquals(v.materials.edited_text.kind, '개념 본문(기본 서술)');
  assert(v.materials.edited_text.what.includes('교재 원문이 아니다'));
  assertEquals(v.materials.extracted_text.from, 'draft');
  assertEquals(v.materials.extracted_text.blocks.map((b: { block_id: string; linked: boolean }) => [b.block_id, b.linked]), [['p12-a0', true], ['p12-a1', false]]);
  assert(v.materials.figure_descriptions.what.includes('원본 그림이 아니다'));
  assertEquals(v.materials.figure_descriptions.items, [{ block_id: 'p12-a1', text: '수직선 위에 2, 3, 5가 표시됨' }]);
  assertEquals(v.materials.masked_regions.masked, true);
  assert(v.materials.masked_regions.note.includes('가린 부분은 추출 글에 없다'));
  assertEquals([v.materials.original_image.attached, v.materials.original_image.status], [true, '모델 입력에 포함됨']);
  assertEquals(v.read_disagreements.items, [{ block_id: 'p12-a1', type: 'text_differs' }]);
  assertEquals(r.images?.length, 1);
  assertEquals(r.images![0].detail, 'high');
  assert(r.images![0].url.startsWith('data:image/png;base64,'));
  assertEquals(r.summary, '개념+유형 중1-1 1-1 PDF 12쪽(인쇄 10쪽) · 조회됨 · 원본 이미지 포함');
  for (const s of [r.output, r.summary]) {
    assert(!s.includes('academies/') && !s.includes('base64') && !s.includes('concept-source-pages') && !/https?:/.test(s), s);
  }

  const next = parse(await read(store, { page_offset: 1, with_image: false }));
  assertEquals(next.page, { pdf_page: 13, print_page: null, print_page_from: '기록 없음(추정하지 않음)', offset: 1 });
  assertEquals(next.materials.edited_text, null);
  assertEquals(next.status, '자료 없음', '글도 이미지도 없는 쪽');
  assertEquals(next.materials.masked_regions.known, false);
  assertEquals(next.materials.original_image.status, '요청 안 함');
});

Deno.test('대화 안에서: 원본 쪽 이미지가 다음 모델 요청의 도구 결과에 실제로 들어가고, 화면 이벤트·저장 기록에는 남지 않는다', async () => {
  const store = storeWithSource();
  const conv = await store.createConversation('출처');
  const r = await run(store, { conversationId: conv.id, features: READY }, (_req, i) =>
    i === 0
      ? { functionCalls: [{ name: SOURCE_PAGE_TOOL_NAME, arguments: { source_id: SRC, page_offset: null, with_image: true } }] }
      : { text: '원본 12쪽을 확인했습니다.' });
  const second = r.provider.requests.find((q) => q.input.some((it) => it.kind === 'tool_result'))!;
  const result = second.input.find((it) => it.kind === 'tool_result')!;
  assert(result.kind === 'tool_result');
  assertEquals(result.images?.length, 1);
  const body = buildResponsesBody(second, true);
  const out = (body.input as Record<string, unknown>[]).find((x) => x.type === 'function_call_output')!;
  const parts = out.output as Record<string, unknown>[];
  assertEquals(parts.map((p) => p.type), ['input_text', 'input_image']);
  assert(String(parts[1].image_url).startsWith('data:image/png;base64,'));
  assertEquals(parts[1].detail, 'high');

  const tool = r.events.events.find((e) => e.event === 'tool')!;
  assertEquals(tool.data.label, '개념 출처 원본 읽기');
  const leaked = JSON.stringify(r.events.events) + JSON.stringify(store.messages) + JSON.stringify(r.runs.runs);
  assert(!leaked.includes('base64') && !leaked.includes('academies/'), '이미지·키는 이벤트·메시지·호출 기록에 남지 않는다');
});

Deno.test('이미지를 넣지 못하면 다른 자료로 대신하지 않고, 넣지 못한 까닭을 상태로 나눠 알린다', async () => {
  const cases: [string, unknown, (s: MemoryThinkStore) => void, string, string][] = [
    ['내려받기 실패', readyImage, (s) => s.conceptSourceImages.clear(), '접근 실패', '내려받지 못했다'],
    ['다른 쪽 이미지', (a: Record<string, unknown>) => ({ ...readyImage(a), raw_page: 10, image_key: keyOf(10) }), () => {}, '접근 실패', '이 쪽의 것인지'],
    ['크기 불일치', (a: Record<string, unknown>) => ({ ...readyImage(a), width: 999 }), () => {}, '접근 실패', '기록과 맞지 않아'],
    ['PNG 아님', readyImage, (s) => s.conceptSourceImages.set(keyOf(12), new TextEncoder().encode('<html>not png</html>')), '접근 실패', '기록과 맞지 않아'],
    ['서버 꺼짐', { status: 'queued', raw_page: 12, worker_alive: false }, () => {}, '원본 준비 서버 응답 없음', '서버'],
    ['PDF에 없는 쪽', { status: 'failed', error: 'page_out_of_range', raw_page: 12, worker_alive: true }, () => {}, '자료 없음', 'PDF에 이 쪽이 없다'],
    ['원본 받기 실패', { status: 'failed', error: 'source_download_failed', raw_page: 12, worker_alive: true }, () => {}, '접근 실패', '원본 PDF를 받지 못했다'],
    ['PDF 연결 없음', { status: 'link_missing', raw_page: 12 }, () => {}, '연결 끊김', '연결 끊김'],
    ['연결 여러 개', { status: 'link_ambiguous', raw_page: 12 }, () => {}, '연결 끊김', '여러 개'],
    ['학원 밖', { status: 'forbidden', raw_page: 12 }, () => {}, '접근 실패', '소속'],
  ];
  for (const [what, image, tweak, state, words] of cases) {
    const store = storeWithSource(image);
    tweak(store);
    const r = await read(store, {});
    assert(r.ok, what);
    assertEquals(r.images, undefined, what);
    const v = parse(r);
    assertEquals(v.status, '일부만 조회됨', what);
    assertEquals(v.materials.original_image.attached, false, what);
    assertEquals(v.materials.original_image.status, state, what);
    assert(String(v.materials.original_image.label).includes(words), `${what}: ${v.materials.original_image.label}`);
    assert(v.materials.original_image.note.includes('원본을 봤다고 말하지 않는다'), what);
    const miss = v.missing.find((m: { what: string }) => m.what === '원본 이미지');
    assertEquals(miss?.state, state, what);
    assert(!r.summary.includes('원본 이미지 포함'), what);
  }

  const offline = storeWithSource({ status: 'queued', raw_page: 12, worker_alive: false });
  const c = clock();
  await read(offline, {}, ctx({ now: c.now, sleep: c.sleep }));
  assertEquals(c.sleeps, [], '서버가 꺼져 있으면 기다리지 않는다');
});

Deno.test('준비 중이면 게이트웨이가 만들 때까지 잠깐 기다리고, 시간 안에 안 되면 준비 중으로 알린다', async () => {
  let polls = 0;
  const store = storeWithSource((a: Record<string, unknown>) => {
    polls += 1;
    return polls < 3 ? { status: polls === 1 ? 'queued' : 'working', raw_page: 12, worker_alive: true } : readyImage(a);
  });
  const c = clock();
  const r = await read(store, {}, ctx({ now: c.now, sleep: c.sleep, deadline: c.now() + 60_000 }));
  assertEquals(parse(r).materials.original_image.attached, true);
  assertEquals(store.conceptSourceReads.filter((x) => x.fn === 'concept_source_page_image').map((x) => x.args.p_request), [true, false, false]);
  assertEquals(c.sleeps.length, 2);

  const slow = storeWithSource({ status: 'working', raw_page: 12, worker_alive: true });
  const c2 = clock();
  const s = parse(await read(slow, {}, ctx({ now: c2.now, sleep: c2.sleep, deadline: c2.now() + 10_000 })));
  assertEquals(s.materials.original_image.status, '준비 중');
  assert(s.materials.original_image.label.includes('다시 읽을 수 있다'));
  assert(c2.now() - 1_000_000 <= 10_000, '답변 마감 시각을 넘겨 기다리지 않는다');
});

Deno.test('끊긴 근거·없는 쪽은 그대로 알리고, 앞뒤 쪽·이미지 한도와 쪽 범위를 지킨다', async () => {
  const broken = new MemoryThinkStore();
  broken.conceptSourceData.set('concept_source_page_context', pageContext(0, {
    source: { ...pageContext(0).source, draft_id: null, draft_found: false },
    blocks_from: null, blocks: [], linked_missing: ['p12-a0'], disagreements: [], transcript: null, masks: null, basis: null,
  }));
  const b = parse(await read(broken, { with_image: false }));
  assertEquals(b.status, '연결 끊김');
  const link = b.missing.find((m: { what: string }) => m.what === '근거 블록');
  assertEquals([link.state, link.block_ids], ['연결 끊김', ['p12-a0']]);
  assertEquals(b.materials.extracted_text, null, '다른 쪽 글로 채우지 않는다');

  const store = storeWithSource();
  const c = ctx();
  for (const off of [-2, -1, 1, 2]) assert((await read(store, { page_offset: off, with_image: false }, c)).ok);
  const over = await read(store, { page_offset: 1, with_image: false }, c);
  assertEquals([over.ok, parse(over).error], [false, 'adjacent_limit']);
  assert((await read(store, { page_offset: 0, with_image: false }, c)).ok, '출처 쪽은 앞뒤 한도와 상관없다');

  const before = store.conceptSourceReads.length;
  const far = await read(store, { page_offset: 3 }, ctx());
  assertEquals([far.ok, parse(far).error], [false, 'concept_source_page_bad_offset']);
  assertEquals(store.conceptSourceReads.length, before, '범위 밖 쪽은 조회하지 않는다');

  const images = ctx();
  for (let i = 0; i < SOURCE_IMAGE_LIMIT; i++) assertEquals((await read(store, {}, images)).images?.length, 1);
  const seventh = await read(store, {}, images);
  assertEquals(seventh.images, undefined);
  assertEquals(parse(seventh).materials.original_image.status, '한도 초과');
});

Deno.test('권한 없음·없는 출처는 빈 결과가 아니라 오류로, 기능이 없으면 쓸 수 없다고 돌려준다', async () => {
  const store = new MemoryThinkStore();
  store.conceptSourceReadError = 'concept_statement_forbidden';
  const denied = await read(store, {});
  assertEquals([denied.ok, parse(denied).error, denied.summary], [false, 'concept_statement_forbidden', '접근 실패']);
  store.conceptSourceReadError = 'concept_source_not_found';
  assertEquals(parse(await read(store, {})).error, 'concept_source_not_found');
  store.conceptSourceReadError = null;

  const bad = await read(store, { source_id: 'not-a-uuid' });
  assertEquals(parse(bad).error, 'invalid_id');
  const off = await runThinkTool(SOURCE_PAGE_TOOL_NAME, JSON.stringify({ source_id: SRC, page_offset: 0, with_image: true }), store, 50_000, {
    conversationId: 'conv-x', memoryRefs: [],
  });
  assertEquals(parse(off).error, 'concept_source_unavailable');
});
