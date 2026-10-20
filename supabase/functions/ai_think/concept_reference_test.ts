import { assert, assertEquals } from 'jsr:@std/assert@1';
import { FakeAiProvider } from '../_shared/ai/fake.ts';
import type { AiInputItem, AiRequest } from '../_shared/ai/types.ts';
import { runThinkChat, type ChatInput } from './chat.ts';
import { CONCEPT_REFERENCE_MAX_CHARS, type ConceptRecord, type ConceptStatementRecord } from './concept_reference.ts';
import { EventLog, MemoryThinkStore, RunLog, memory, testEnv } from './test_support.ts';

const CONCEPT_ID = '6f1d2c3b-4a5e-4f60-8a7b-9c0d1e2f3a4b';

function itemText(i: AiInputItem): string {
  if (i.kind === 'context') return i.text;
  if (i.kind === 'message') return i.parts.map((p) => (p.type === 'text' ? p.text : '')).join('');
  return '';
}

const allText = (req: AiRequest) => req.input.map(itemText).join('\n');

function concept(partial: Partial<ConceptRecord> = {}): ConceptRecord {
  return {
    id: CONCEPT_ID,
    kind: 'definition',
    sub_type: null,
    name: '소인수분해',
    content: 'OLD_BODY 자연수를 소수의 곱으로 나타낸다',
    level: 1,
    main_category_id: 'cat-1',
    updated_at: '2026-10-15T01:00:00Z',
    ...partial,
  };
}

async function setup() {
  const store = new MemoryThinkStore();
  const conv = await store.createConversation('개념 정리');
  store.concepts.set(CONCEPT_ID, concept());
  store.memories.push(memory({ id: 'm-note', kind: 'note', title: '소인수분해 정리 기준', content: '소인수분해는 소수의 곱' }));
  return { store, conversationId: conv.id };
}

async function ask(store: MemoryThinkStore, conversationId: string, statementId: string | null = null) {
  const provider = new FakeAiProvider([{ text: '정리했습니다.' }]);
  const events = new EventLog();
  const input: ChatInput = {
    userId: 'user-1',
    safetyId: 'hash',
    conversationId,
    conceptId: CONCEPT_ID,
    conceptStatementId: statementId,
    message: '소인수분해 정의를 학생 눈높이로 다듬어 줘',
    attachments: [],
    deep: false,
    webSearch: false,
    signal: new AbortController().signal,
    startedAt: Date.now(),
    wallClockMs: 140000,
  };
  const out = await runThinkChat(input, { provider, store, recordRun: new RunLog().record, emit: events.emit, env: testEnv });
  const context = events.of('conversation')[0]?.context as Record<string, unknown> | undefined;
  return { out, req: provider.requests[0], meta: context?.concept as Record<string, unknown> | null | undefined };
}

Deno.test('개념 탭: 저장값이 바뀌면 다음 질문은 바뀐 저장본을 읽고, 원문은 저장하지 않는다', async () => {
  const { store, conversationId } = await setup();
  const first = await ask(store, conversationId);
  assertEquals(first.out.status, 'complete');
  const block = first.req.input.at(-2)!;
  assertEquals(block.kind, 'message', '지시가 아니라 사용자 메시지 자리에 넣는다');
  assert(itemText(block).includes('OLD_BODY'), '고른 개념의 저장본이 이번 질문 바로 앞에 들어간다');
  assert(itemText(first.req.input.at(-3)!).includes('m-note'), '관련 기억 뒤에 둔다');
  assertEquals(first.meta?.status, 'ok');

  store.concepts.set(
    CONCEPT_ID,
    concept({ name: '소인수분해(수정)', content: 'NEW_BODY 1보다 큰 자연수를 소수만의 곱으로', updated_at: '2026-10-15T02:00:00Z' }),
  );
  const second = await ask(store, conversationId);
  const text = allText(second.req);
  assert(text.includes('NEW_BODY') && text.includes('소인수분해(수정)'));
  assert(!text.includes('OLD_BODY'), '앞 질문 때의 본문은 다시 넣지 않는다');
  assertEquals(second.meta?.updated_at, '2026-10-15T02:00:00Z');
  assertEquals(store.conceptReads, [CONCEPT_ID, CONCEPT_ID], '요청마다 다시 읽는다');

  const saved = JSON.stringify(store.messages) + JSON.stringify(store.snapshots);
  assert(!saved.includes('OLD_BODY') && !saved.includes('NEW_BODY'), '원문은 메시지·스냅샷에 남기지 않는다');
  assert(!JSON.stringify(second.meta).includes('NEW_BODY'), 'SSE에는 상태만 보낸다');
});

Deno.test('개념 탭: 다시 읽지 못하면 옛 본문을 쓰지 않고, 오류·없음·잘림·경로 불완전을 구분한다', async () => {
  const { store, conversationId } = await setup();
  await ask(store, conversationId);

  store.conceptReadFails.add(CONCEPT_ID);
  const failed = await ask(store, conversationId);
  assertEquals(failed.out.status, 'complete', '개념을 못 읽어도 답은 한다');
  assertEquals(failed.meta?.status, 'error');
  assert(!allText(failed.req).includes('OLD_BODY'));
  assert(itemText(failed.req.input.at(-2)!).includes('읽지 못했다'));

  store.conceptReadFails.clear();
  store.concepts.delete(CONCEPT_ID);
  const missing = await ask(store, conversationId);
  assertEquals(missing.meta?.status, 'not_found');
  assert(!allText(missing.req).includes('OLD_BODY'));

  store.concepts.set(CONCEPT_ID, concept({ content: 'x'.repeat(CONCEPT_REFERENCE_MAX_CHARS + 500) }));
  store.conceptPaths.set(CONCEPT_ID, { categoryPath: ['소인수분해'], pathComplete: false });
  const long = await ask(store, conversationId);
  assertEquals(long.meta?.status, 'truncated');
  assertEquals(long.meta?.delivered_chars, CONCEPT_REFERENCE_MAX_CHARS);
  assertEquals(long.meta?.path_complete, false);
});

Deno.test('개념 탭: 사용자가 이은 기준·출처만 넣고, 읽지 못하면 없다고 하지 않는다', async () => {
  const { store, conversationId } = await setup();
  const none = await ask(store, conversationId);
  const noneText = itemText(none.req.input.at(-2)!);
  assert(noneText.includes('연결된 정리 기준: 없음') && noneText.includes('출처: 없음'));
  assertEquals(none.meta?.linked_criteria, 0);
  assertEquals(none.meta?.sources, 0);

  store.conceptLinkedCriteria.set(CONCEPT_ID, [
    { id: 'crit-1', title: '지식 분류 기준', version: 2, draft_title: '지식 분류 기준' },
    { id: 'crit-2', title: null, version: 0, draft_title: '노드 분리 기준' },
  ]);
  store.conceptSources.set(CONCEPT_ID, [
    { book_name: '개념+유형 중1-1', grade_label: '중1-1', raw_page: 12, display_page: 10, unit_path: ['소인수분해', '소수와 합성수'] },
    { book_name: null, grade_label: '중1-1', raw_page: 40, display_page: null, unit_path: [] },
  ]);
  const linked = await ask(store, conversationId);
  const text = itemText(linked.req.input.at(-2)!);
  assert(text.includes('"지식 분류 기준" — 확정 v2, 저장된 초안 있음 (criterion id: crit-1)'));
  assert(text.includes('"노드 분리 기준" — 아직 확정 전 초안 (criterion id: crit-2)'));
  assert(text.includes('개념+유형 중1-1 · 중1-1 · 소인수분해 > 소수와 합성수 · 본문 10쪽(PDF 12쪽)'));
  assert(text.includes('(책 이름을 볼 수 없음) · 중1-1 · (단원 없음) · PDF 40쪽'), '볼 수 없는 책 이름을 추측하지 않는다');
  assert(text.includes('같은 뜻으로 보거나 자동으로 대응시키지 않는다'), '기존 종류를 새 지식 분류로 대응하지 않는다');
  assertEquals(linked.meta?.linked_criteria, 2);
  assertEquals(linked.meta?.sources, 2);
  assert(!JSON.stringify(linked.meta).includes('지식 분류 기준'), 'SSE에는 개수만 보낸다');

  store.conceptLinkedCriteria.set(CONCEPT_ID, null);
  store.conceptSources.set(CONCEPT_ID, null);
  const unread = await ask(store, conversationId);
  const unreadText = itemText(unread.req.input.at(-2)!);
  assert(unreadText.includes('연결된 정리 기준: 읽지 못함') && unreadText.includes('출처: 읽지 못함'));
  assert(!unreadText.includes('연결된 정리 기준: 없음'));
  assertEquals(unread.meta?.linked_criteria, null);
  assertEquals(unread.meta?.sources, null);
});

const ST_HIGH = '7a1d2c3b-4a5e-4f60-8a7b-9c0d1e2f3a01';
const ST_OTHER = '7a1d2c3b-4a5e-4f60-8a7b-9c0d1e2f3a02';

function statementRow(partial: Partial<ConceptStatementRecord> & { id: string }): ConceptStatementRecord {
  return {
    role: 'statement',
    version: 0,
    content: null,
    confirmed_at: null,
    draft: null,
    draft_origin: null,
    draft_saved_at: null,
    ...partial,
  };
}

function withStatements(store: MemoryThinkStore) {
  store.conceptStatements.set(CONCEPT_ID, [
    statementRow({
      id: 'core-1',
      role: 'core',
      version: 1,
      content: { meaning: 'CORE_MEANING 1보다 큰 자연수를 소수의 곱으로' },
      confirmed_at: '2026-10-19T01:00:00Z',
    }),
    statementRow({
      id: ST_HIGH,
      version: 2,
      content: { title: '고등 서술', body: 'HIGH_CONFIRMED 소인수분해의 유일성까지', basis: 'organized', supplement_note: 'SUPPLEMENT 조건 보완' },
      confirmed_at: '2026-10-19T02:00:00Z',
      draft: { title: '고등 서술', body: 'HIGH_DRAFT 유일성 증명 포함', basis: 'organized' },
      draft_origin: 'owner',
      draft_saved_at: '2026-10-20T03:00:00Z',
    }),
    statementRow({
      id: ST_OTHER,
      draft: { title: '중학 서술', body: 'OTHER_BODY 보지 말아야 할 본문', basis: 'verbatim' },
      draft_origin: 'owner',
      draft_saved_at: '2026-10-20T04:00:00Z',
    }),
  ]);
  store.conceptAppearances.set(CONCEPT_ID, [
    { statement_id: null, curriculum_code: 'rev_2015', school_level: '중', course_label: '중1', unit_path: ['소인수분해'], note: null },
    { statement_id: ST_HIGH, curriculum_code: null, school_level: '고', course_label: '수학', unit_path: [], note: null },
  ]);
  store.conceptSources.set(CONCEPT_ID, [
    { book_name: '개념+유형 중1-1', grade_label: '중1-1', raw_page: 12, display_page: 10, unit_path: ['소인수분해'], statement_id: ST_HIGH },
  ]);
}

Deno.test('개념 탭 서술: 고른 서술의 확정본·저장된 초안을 따로 넣고, 다른 서술은 제목·상태만 넣는다', async () => {
  const { store, conversationId } = await setup();
  withStatements(store);
  const picked = await ask(store, conversationId, ST_HIGH);
  assertEquals(picked.out.status, 'complete');
  const text = itemText(picked.req.input.at(-2)!);
  assert(text.includes('<고른 서술 확정본>') && text.includes('HIGH_CONFIRMED'));
  assert(text.includes('<고른 서술 저장된 초안>') && text.includes('HIGH_DRAFT'));
  assert(text.indexOf('HIGH_CONFIRMED') < text.indexOf('HIGH_DRAFT'), '확정본과 초안을 섞지 않고 따로 둔다');
  assert(text.includes('SUPPLEMENT'), '보완한 점을 함께 넣는다');
  assert(text.includes('OLD_BODY'), '기본 서술(개념 본문)도 함께 넣는다');
  assert(text.includes('"중학 서술"') && !text.includes('OTHER_BODY'), '다른 서술은 제목만, 본문은 넣지 않는다');
  assert(text.includes('CORE_MEANING'), '공통 내용 확정본을 넣는다');
  assert(text.includes('[서술 1 "고등 서술"]'), '출처·등장 위치가 어느 서술의 것인지 밝힌다');
  assert(text.includes('교육과정 판 미기록'), '비어 있는 교육과정 판을 추측해 채우지 않는다');
  assert(text.includes('2015 개정 · 중 · 중1'));
  assertEquals(picked.meta?.statements, 2);
  assertEquals(picked.meta?.appearances, 2);
  assertEquals(picked.meta?.has_core, true);
  const st = picked.meta?.statement as Record<string, unknown>;
  assertEquals(st.status, 'ok');
  assertEquals(st.id, ST_HIGH);
  assertEquals(st.version, 2);
  assertEquals(st.has_draft, true);
  assertEquals(st.draft_saved_at, '2026-10-20T03:00:00Z');
  const sse = JSON.stringify(picked.meta);
  assert(!sse.includes('HIGH_') && !sse.includes('고등 서술'), 'SSE에는 상태만 보낸다');

  const rows = store.conceptStatements.get(CONCEPT_ID)!;
  rows[1] = { ...rows[1], draft: { title: '고등 서술', body: 'HIGH_DRAFT2 바뀐 초안', basis: 'organized' }, draft_saved_at: '2026-10-20T05:00:00Z' };
  const again = await ask(store, conversationId, ST_HIGH);
  const all = allText(again.req);
  assert(all.includes('HIGH_DRAFT2') && !all.includes('HIGH_DRAFT 유일성'), '요청마다 서술 저장본을 다시 읽는다');
  const saved = JSON.stringify(store.messages) + JSON.stringify(store.snapshots);
  assert(!saved.includes('HIGH_CONFIRMED') && !saved.includes('HIGH_DRAFT'), '서술 원문은 메시지·스냅샷에 남기지 않는다');
});

Deno.test('개념 탭 서술: 기본 서술·확정 전 서술·못 찾음·읽지 못함을 구분하고 다른 서술로 대신하지 않는다', async () => {
  const { store, conversationId } = await setup();
  withStatements(store);
  const base = await ask(store, conversationId);
  const baseText = itemText(base.req.input.at(-2)!);
  assert(baseText.includes('사용자가 고른 서술: 기본 서술(개념 본문)'));
  assert(!baseText.includes('HIGH_CONFIRMED') && !baseText.includes('OTHER_BODY'), '기본 서술을 고르면 다른 서술 본문은 넣지 않는다');
  assertEquals((base.meta?.statement as Record<string, unknown>).status, 'base');

  const draftOnly = await ask(store, conversationId, ST_OTHER);
  const draftText = itemText(draftOnly.req.input.at(-2)!);
  assert(draftText.includes('OTHER_BODY') && draftText.includes('확정본: 없음'));
  assert(draftText.includes('원문 그대로 옮긴 글'));
  assertEquals((draftOnly.meta?.statement as Record<string, unknown>).version, 0);

  const missing = await ask(store, conversationId, '7a1d2c3b-4a5e-4f60-8a7b-9c0d1e2f3aff');
  const missingText = itemText(missing.req.input.at(-2)!);
  assertEquals((missing.meta?.statement as Record<string, unknown>).status, 'not_found');
  assert(!missingText.includes('HIGH_CONFIRMED') && !missingText.includes('OTHER_BODY'));
  assert(missingText.includes('찾지 못했다'));

  store.conceptStatements.set(CONCEPT_ID, null);
  store.conceptAppearances.set(CONCEPT_ID, null);
  const unread = await ask(store, conversationId, ST_HIGH);
  const unreadText = itemText(unread.req.input.at(-2)!);
  assertEquals((unread.meta?.statement as Record<string, unknown>).status, 'unread');
  assertEquals(unread.meta?.statements, null);
  assertEquals(unread.meta?.has_core, null);
  assertEquals(unread.meta?.appearances, null);
  assert(unreadText.includes('공통 내용·서술 목록: 읽지 못함') && !unreadText.includes('공통 내용: 없음'));
  assert(unreadText.includes('등장 위치: 읽지 못함'));
  assert(unread.out.status === 'complete', '서술을 못 읽어도 답은 한다');

  store.conceptReadFails.add(CONCEPT_ID);
  const failed = await ask(store, conversationId, ST_HIGH);
  assertEquals(failed.meta?.status, 'error');
  assertEquals((failed.meta?.statement as Record<string, unknown>).status, 'unread');
  assert(itemText(failed.req.input.at(-2)!).includes(ST_HIGH), '무엇을 골랐는지는 밝힌다');
});

Deno.test('개념 탭 서술: 서술이 없으면 없다고, 고른 서술 본문이 길면 잘림을 알린다', async () => {
  const { store, conversationId } = await setup();
  const none = await ask(store, conversationId);
  const noneText = itemText(none.req.input.at(-2)!);
  assert(noneText.includes('공통 내용: 없음') && noneText.includes('서술 목록(기본 서술 포함 1개)'));
  assert(noneText.includes('등장 위치: 없음'));
  assertEquals(none.meta?.statements, 0);
  assertEquals(none.meta?.has_core, false);

  store.conceptStatements.set(CONCEPT_ID, [
    statementRow({
      id: ST_HIGH,
      draft: { title: '긴 서술', body: 'y'.repeat(CONCEPT_REFERENCE_MAX_CHARS + 10), basis: 'organized' },
      draft_origin: 'owner',
      draft_saved_at: '2026-10-20T03:00:00Z',
    }),
  ]);
  const long = await ask(store, conversationId, ST_HIGH);
  assertEquals((long.meta?.statement as Record<string, unknown>).status, 'truncated');
  assertEquals(long.meta?.status, 'ok', '개념 본문 상태와 서술 상태를 따로 알린다');
  assert(!itemText(long.req.input.at(-2)!).includes('y'.repeat(CONCEPT_REFERENCE_MAX_CHARS + 1)));
});
