import { assert, assertEquals } from 'jsr:@std/assert@1';
import { FakeAiProvider } from '../_shared/ai/fake.ts';
import type { AiInputItem, AiRequest } from '../_shared/ai/types.ts';
import { runThinkChat, type ChatInput } from './chat.ts';
import type { ConceptRecord } from './concept_reference.ts';
import { CRITERION_TEXT_MAX_CHARS, type CriterionRecord } from './criterion_reference.ts';
import { computeFeatures } from './features.ts';
import { EventLog, MemoryThinkStore, RunLog, memory, testEnv } from './test_support.ts';

/** 실행 기록(features)은 기능 상태를 계산한 요청에만 남는다. 기능 자체는 꺼 둔다. */
const NO_FEATURES = computeFeatures({ ok: true, features: {} }, {}, true);
const CRITERION_ID = '0b1c2d3e-4f50-4a61-8b72-9c83d4e5f6a7';
const CONCEPT_ID = '6f1d2c3b-4a5e-4f60-8a7b-9c0d1e2f3a4b';

function itemText(i: AiInputItem): string {
  if (i.kind === 'context') return i.text;
  if (i.kind === 'message') return i.parts.map((p) => (p.type === 'text' ? p.text : '')).join('');
  return '';
}

const allText = (req: AiRequest) => req.input.map(itemText).join('\n');

function criterion(partial: Partial<CriterionRecord> = {}): CriterionRecord {
  return {
    id: CRITERION_ID,
    title: '지식 분류 기준',
    body: 'CONFIRMED_V1 사실·개념·절차·메타인지로 나눈다',
    version: 1,
    confirmed_at: '2026-10-16T01:00:00Z',
    draft_title: '지식 분류 기준',
    draft_body: 'DRAFT_A 절차적 지식을 둘로 나눈다',
    draft_origin: 'owner',
    draft_saved_at: '2026-10-16T02:00:00.123456Z',
    ...partial,
  };
}

function concept(): ConceptRecord {
  return {
    id: CONCEPT_ID,
    kind: 'definition',
    sub_type: null,
    name: '소인수분해',
    content: 'CONCEPT_BODY 자연수를 소수의 곱으로 나타낸다',
    level: 1,
    main_category_id: 'cat-1',
    updated_at: '2026-10-15T01:00:00Z',
  };
}

async function setup() {
  const store = new MemoryThinkStore();
  const conv = await store.createConversation('개념 정리');
  store.conceptCriteria.set(CRITERION_ID, criterion());
  store.memories.push(memory({ id: 'm-note', kind: 'note', title: '지식 분류 기준 논의', content: '지식 분류는 네 가지' }));
  return { store, conversationId: conv.id };
}

async function ask(
  store: MemoryThinkStore,
  conversationId: string | null,
  ids: { criterionId?: string | null; conceptId?: string | null } = { criterionId: CRITERION_ID },
) {
  const provider = new FakeAiProvider([{ text: '검토했습니다.' }]);
  const events = new EventLog();
  const runs = new RunLog();
  const input: ChatInput = {
    userId: 'user-1',
    safetyId: 'hash',
    conversationId,
    criterionId: ids.criterionId ?? null,
    conceptId: ids.conceptId ?? null,
    message: '이 기준으로 소인수분해를 어떻게 나눌지 봐 줘',
    attachments: [],
    deep: false,
    webSearch: false,
    signal: new AbortController().signal,
    startedAt: Date.now(),
    wallClockMs: 140000,
    features: NO_FEATURES,
  };
  const out = await runThinkChat(input, { provider, store, recordRun: runs.record, emit: events.emit, env: testEnv });
  const context = events.of('conversation')[0]?.context as Record<string, unknown> | undefined;
  return {
    out,
    req: provider.requests[0],
    meta: context?.criterion as Record<string, unknown> | null | undefined,
    conceptMeta: context?.concept as Record<string, unknown> | null | undefined,
    features: runs.runs.find((r) => r.feature === 'think_chat')?.features as Record<string, unknown> | null | undefined,
  };
}

Deno.test('정리 기준: 확정본과 저장된 초안을 나눠 넣고, 저장값이 바뀌면 다음 질문은 바뀐 저장본을 읽는다', async () => {
  const { store, conversationId } = await setup();
  const first = await ask(store, conversationId);
  assertEquals(first.out.status, 'complete');
  const block = first.req.input.at(-2)!;
  assertEquals(block.kind, 'message', '지시가 아니라 사용자 메시지 자리에 넣는다');
  const text = itemText(block);
  const confirmedAt = text.indexOf('<확정 기준 본문>');
  const draftAt = text.indexOf('<저장된 초안 본문>');
  assert(confirmedAt >= 0 && draftAt > confirmedAt, '확정본과 초안이 따로 표시된다');
  assert(text.slice(confirmedAt, draftAt).includes('CONFIRMED_V1') && !text.slice(confirmedAt, draftAt).includes('DRAFT_A'));
  assert(text.slice(draftAt).includes('DRAFT_A'));
  assert(itemText(first.req.input.at(-3)!).includes('m-note'), '관련 기억 뒤에 둔다');
  assertEquals(first.meta?.status, 'ok');
  assertEquals(first.meta?.has_draft, true);
  assertEquals(first.meta?.draft_saved_at, '2026-10-16T02:00:00.123456Z');

  store.conceptCriteria.set(
    CRITERION_ID,
    criterion({
      body: 'CONFIRMED_V2 절차적 지식을 계산 절차와 풀이 전략으로 나눈다',
      version: 2,
      confirmed_at: '2026-10-16T03:00:00Z',
      draft_title: null,
      draft_body: null,
      draft_origin: null,
      draft_saved_at: null,
    }),
  );
  const second = await ask(store, conversationId);
  const all = allText(second.req);
  assert(all.includes('CONFIRMED_V2') && all.includes('저장된 초안: 없음'));
  assert(!all.includes('CONFIRMED_V1') && !all.includes('DRAFT_A'), '앞 질문 때의 확정본·초안은 다시 넣지 않는다');
  assertEquals(second.meta?.version, 2);
  assertEquals(second.meta?.has_draft, false);
  assertEquals(store.criterionReads, [CRITERION_ID, CRITERION_ID], '요청마다 다시 읽는다');
  assertEquals((second.features?.criterion_ref as Record<string, unknown>)?.version, 2, '실행 기록에도 상태를 남긴다');

  const saved = JSON.stringify(store.messages) + JSON.stringify(store.snapshots);
  assert(!saved.includes('CONFIRMED_V') && !saved.includes('DRAFT_A'), '원문은 메시지·스냅샷에 남기지 않는다');
  const metas = JSON.stringify(second.meta) + JSON.stringify(second.features);
  assert(!metas.includes('CONFIRMED_V2') && !metas.includes('지식 분류 기준'), 'SSE·실행 기록에는 상태만 남긴다');
});

Deno.test('정리 기준: 확정 전 기본 틀 초안은 확정 기준이 아니라고 알리고, 이은 개념은 사용자가 이은 것만 넣는다', async () => {
  const { store, conversationId } = await setup();
  store.conceptCriteria.set(
    CRITERION_ID,
    criterion({ title: null, body: null, version: 0, confirmed_at: null, draft_origin: 'template', draft_body: 'TEMPLATE_BODY' }),
  );
  store.criterionLinkedConcepts.set(CRITERION_ID, [{ id: CONCEPT_ID, name: '소인수분해' }]);
  const draftOnly = await ask(store, conversationId);
  const text = itemText(draftOnly.req.input.at(-2)!);
  assert(text.includes('확정본: 없음'));
  assert(text.includes('아직 확정한 적 없는 기준'), '초안을 확정 기준처럼 쓰지 말라는 경계가 붙는다');
  assert(text.includes('기본 틀'), '기본 틀 초안은 사용자 판단이 아니라고 밝힌다');
  assert(!text.includes('<확정 기준 본문>'));
  assert(text.includes(`소인수분해 (concept id: ${CONCEPT_ID})`));
  assertEquals(draftOnly.meta?.version, 0);
  assertEquals(draftOnly.meta?.linked_concepts, 1);

  store.criterionLinkedConcepts.set(CRITERION_ID, null);
  const unread = await ask(store, conversationId);
  assert(itemText(unread.req.input.at(-2)!).includes('연결된 개념: 읽지 못함'), '연결을 못 읽으면 없다고 하지 않는다');
  assertEquals(unread.meta?.linked_concepts, null);

  store.criterionLinkedConcepts.set(CRITERION_ID, []);
  const none = await ask(store, conversationId);
  assert(itemText(none.req.input.at(-2)!).includes('연결된 개념: 없음'));
});

Deno.test('정리 기준: 다시 읽지 못하면 옛 본문을 쓰지 않고, 오류·없음·잘림을 구분한다', async () => {
  const { store, conversationId } = await setup();
  await ask(store, conversationId);

  store.criterionReadFails.add(CRITERION_ID);
  const failed = await ask(store, conversationId);
  assertEquals(failed.out.status, 'complete', '기준을 못 읽어도 답은 한다');
  assertEquals(failed.meta?.status, 'error');
  assert(!allText(failed.req).includes('CONFIRMED_V1') && !allText(failed.req).includes('DRAFT_A'));
  assert(itemText(failed.req.input.at(-2)!).includes('읽지 못했다'));

  store.criterionReadFails.clear();
  store.conceptCriteria.delete(CRITERION_ID);
  const missing = await ask(store, conversationId);
  assertEquals(missing.meta?.status, 'not_found');
  assert(!allText(missing.req).includes('CONFIRMED_V1'));

  store.conceptCriteria.set(CRITERION_ID, criterion({ draft_body: 'y'.repeat(CRITERION_TEXT_MAX_CHARS + 10) }));
  const long = await ask(store, conversationId);
  assertEquals(long.meta?.status, 'truncated');
  const text = itemText(long.req.input.at(-2)!);
  assert(text.includes(`초안 본문이 길어 앞 ${CRITERION_TEXT_MAX_CHARS}자만`));
  assert(!text.includes('y'.repeat(CRITERION_TEXT_MAX_CHARS + 1)));
});

Deno.test('개념 탭: 기준과 개념을 함께 고르면 기준 블록, 개념 블록, 이번 질문 순서로 넣는다', async () => {
  const { store, conversationId } = await setup();
  store.concepts.set(CONCEPT_ID, concept());
  const both = await ask(store, conversationId, { criterionId: CRITERION_ID, conceptId: CONCEPT_ID });
  assert(itemText(both.req.input.at(-3)!).includes('CONFIRMED_V1'));
  assert(itemText(both.req.input.at(-2)!).includes('CONCEPT_BODY'));
  assert(itemText(both.req.input.at(-1)!).includes('소인수분해를 어떻게 나눌지'));
  assertEquals(both.meta?.status, 'ok');
  assertEquals(both.conceptMeta?.status, 'ok');
  assert(both.features?.criterion_ref && both.features?.concept_ref);
});

Deno.test('정리 기준: 새 대화에는 붙지 않는다(이미 있는 대화에만)', async () => {
  const { store } = await setup();
  const fresh = await ask(store, null);
  assertEquals(fresh.out.status, 'complete');
  assertEquals(store.criterionReads, [], '새 대화에서는 기준을 읽지 않는다');
  assertEquals(fresh.meta ?? null, null);
  assert(!allText(fresh.req).includes('CONFIRMED_V1'));
});
