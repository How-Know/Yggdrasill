import { assert, assertEquals } from 'jsr:@std/assert@1';
import { FakeAiProvider, type FakeTurn } from '../_shared/ai/fake.ts';
import type { AiInputItem, AiRequest } from '../_shared/ai/types.ts';
import { runThinkChat, type ChatInput } from './chat.ts';
import { CONCEPT_DRAFT_CHAT_TITLE, type ConceptDraftRecord, type ConceptDraftReferenceRead } from './concept_draft_reference.ts';
import {
  DRAFT_CHANGE_TOOL_NAME,
  DRAFT_CRITERION_TOOL_NAME,
  DRAFT_RERUN_TOOL_NAME,
  cleanOp,
} from './concept_draft_tools.ts';
import { computeFeatures } from './features.ts';
import { EventLog, MemoryThinkStore, RunLog, testEnv } from './test_support.ts';

const ROLES = computeFeatures({ ok: true, features: { think_roles: 1 } }, { think_roles: 1 }, true);
const DRAFT_ID = '3c2b1a09-8f7e-4d6c-9b5a-4e3f2d1c0b9a';
const CRITERION_ID = '0b1c2d3e-4f50-4a61-8b72-9c83d4e5f6a7';

function itemText(i: AiInputItem): string {
  if (i.kind === 'context') return i.text;
  if (i.kind === 'message') return i.parts.map((p) => (p.type === 'text' ? p.text : '')).join('');
  return '';
}
const allText = (req: AiRequest) => req.input.map(itemText).join('\n');

function draftRow(partial: Partial<ConceptDraftRecord> = {}): ConceptDraftRecord {
  return {
    id: DRAFT_ID,
    status: 'open',
    book_name: '개념책',
    grade_label: '중1',
    unit_path: ['수와 연산', '소인수분해'],
    pages: [8, 9],
    page_meta: [{ raw_page: 8, display_page: 10 }, { raw_page: 9, display_page: 11 }],
    criteria: [{ id: CRITERION_ID, title: '지식 분류 기준', version: 1, state: 'confirmed' }],
    prepared: {
      blocks: [
        { id: 'p8-a1', raw_page: 8, kind: 'definition', title: '소수', text: 'BLOCK_TEXT_A 1보다 큰 자연수 중', figure_description: '', uncertain: false },
        { id: 'p9-a1', raw_page: 9, kind: 'example', title: '', text: 'BLOCK_TEXT_B 12를 소인수분해', figure_description: '', uncertain: true },
      ],
    },
    draft: {
      summary: '소수와 소인수분해',
      concepts: [
        { title: '소수', concept_type: '정의', content: 'AI_CONTENT_0', source_blocks: ['p8-a1'], criterion_notes: '', needs_check: '' },
        { title: '소인수분해', concept_type: '방법', content: 'AI_CONTENT_1', source_blocks: ['p9-a1'], criterion_notes: '', needs_check: '', anchor: 0 },
      ],
      new_types: [],
      excluded: [],
      questions: [],
    },
    checks: {},
    folder_plan: null,
    review: {},
    review_saved_at: null,
    replaced_by: null,
    ...partial,
  };
}

function reference(partial: Partial<ConceptDraftRecord> = {}): ConceptDraftReferenceRead {
  return {
    draft: draftRow(partial),
    criteria: [{
      id: CRITERION_ID,
      title: '지식 분류 기준',
      body: 'CRITERION_CONFIRMED',
      version: 1,
      draft_title: '지식 분류 기준',
      draft_body: 'CRITERION_DRAFT',
      draft_saved_at: '2026-10-17T01:00:00Z',
    }],
    types: [
      { name: '정의', description: '', legacy_sub_type: '정의' },
      { name: '방법', description: '', legacy_sub_type: '연산' },
    ],
    roots: ['수와 연산'],
  };
}

const SAVED = {
  review: {
    concepts: [
      { key: 'c0', index: 0, mark: 'edit', title: '소수(고침)', content: 'SAVED_CONTENT_0', type: '정의', folder: ['수와 연산', '소수'] },
      { key: 'c1', index: 1, mark: 'keep', title: '소인수분해', content: 'AI_CONTENT_1', type: '방법', folder: [], anchor: 'c0' },
    ],
    new_types: [],
  },
  review_saved_at: '2026-10-17T02:00:00Z',
};

async function ask(
  store: MemoryThinkStore,
  conversationId: string | null,
  script: FakeTurn[] | ((req: AiRequest, i: number) => FakeTurn) = [{ text: '검토했습니다.' }],
  draftId: string | null = DRAFT_ID,
) {
  const provider = new FakeAiProvider(script);
  const events = new EventLog();
  const runs = new RunLog();
  const input: ChatInput = {
    userId: 'user-1',
    safetyId: 'hash',
    conversationId,
    conceptDraftId: draftId,
    newConversationRole: draftId ? { thinkRoleId: 'education', extraRefDepartments: [] } : null,
    message: '소수 정의를 교과서 문장대로 고쳐 줘',
    attachments: [],
    deep: false,
    webSearch: false,
    signal: new AbortController().signal,
    startedAt: Date.now(),
    wallClockMs: 140000,
    features: ROLES,
  };
  const out = await runThinkChat(input, { provider, store, recordRun: runs.record, emit: events.emit, env: testEnv });
  const conv = events.of('conversation')[0];
  return {
    out,
    provider,
    req: provider.requests[0],
    events,
    conv,
    meta: (conv?.context as Record<string, unknown> | undefined)?.draft as Record<string, unknown> | null | undefined,
    features: runs.runs.find((r) => r.feature === 'think_chat')?.features as Record<string, unknown> | null | undefined,
    runs,
  };
}

const toolNames = (req: AiRequest) => (req.tools ?? []).map((t) => t.name);

Deno.test('검토 창 첫 질문: 새 대화를 교육 부서·고정 제목으로 만들고, 초안 저장본을 읽어 넣는다', async () => {
  const store = new MemoryThinkStore();
  store.conceptDrafts.set(DRAFT_ID, reference());
  const r = await ask(store, null);
  assertEquals(r.out.status, 'complete');
  assertEquals(store.conversations[0].title, CONCEPT_DRAFT_CHAT_TITLE);
  assertEquals(r.conv?.title, CONCEPT_DRAFT_CHAT_TITLE);
  assertEquals(store.roleCalls[0]?.role, 'education');
  assertEquals(r.runs.runs.filter((x) => x.feature === 'think_title').length, 0, '제목을 만들지 않는다');
  assertEquals(store.conceptDraftReads, [DRAFT_ID]);

  const block = itemText(r.req.input.at(-2)!);
  assertEquals(r.req.input.at(-2)!.kind, 'message', '지시가 아니라 사용자 메시지 자리에 넣는다');
  assert(block.includes('[c0] 소수') && block.includes('[c1] 소인수분해'), '항목을 key로 보여 준다');
  assert(block.includes('AI_CONTENT_0') && block.includes('BLOCK_TEXT_A'));
  assert(block.includes('CRITERION_CONFIRMED') && block.includes('CRITERION_DRAFT'), '쓴 기준의 확정본·초안을 함께 넣는다');
  assert(block.includes('저장된 검토가 아직 없다'));
  assert(block.includes('8→10'), '원본 쪽과 책 표시 쪽은 저장값만 쓴다');
  assert(block.includes('주제 묶음: [c0]에 붙임'), 'AI 초안의 묶음 번호를 key로 보여 준다');

  assertEquals(r.meta?.status, 'ok');
  assertEquals(r.meta?.items, 2);
  const names = toolNames(r.req);
  assert(!names.includes(DRAFT_CHANGE_TOOL_NAME), '저장된 검토가 없으면 변경 도구를 주지 않는다');
  assert(names.includes(DRAFT_CRITERION_TOOL_NAME) && names.includes(DRAFT_RERUN_TOOL_NAME));

  const saved = JSON.stringify(store.messages) + JSON.stringify(store.snapshots);
  assert(!saved.includes('AI_CONTENT_0') && !saved.includes('BLOCK_TEXT_A') && !saved.includes('CRITERION_CONFIRMED'), '원문은 저장하지 않는다');
  const metas = JSON.stringify(r.meta) + JSON.stringify(r.features);
  assert(!metas.includes('AI_CONTENT') && !metas.includes('소인수분해'), 'SSE·실행 기록에는 상태만');
  assert(r.features?.concept_draft_ref);
});

Deno.test('검토 창: 저장된 검토가 있으면 저장본 항목을 읽고 변경 도구를 주며, 요청마다 다시 읽는다', async () => {
  const store = new MemoryThinkStore();
  const conv = await store.createConversation(CONCEPT_DRAFT_CHAT_TITLE);
  store.conceptDrafts.set(DRAFT_ID, reference({
    ...SAVED,
    folder_plan: { placements: [], overlaps: [{ concept: 0, other: 'OVERLAP_OTHER', reason: 'OVERLAP_WHY' }, { concept: 7, other: 'NOPE' }] },
  }));
  const first = await ask(store, conv.id);
  const text = allText(first.req);
  assert(text.includes('소수(고침)') && text.includes('SAVED_CONTENT_0') && !text.includes('AI_CONTENT_0'));
  assert(text.includes('수와 연산 > 소수'));
  assert(text.includes('주제 묶음: [c0]에 붙임'));
  assert(text.includes('OVERLAP_OTHER(OVERLAP_WHY)') && !text.includes('NOPE'), '폴더 제안의 겹침을 항목에 붙인다');
  assert(toolNames(first.req).includes(DRAFT_CHANGE_TOOL_NAME));
  assertEquals(first.meta?.review_saved_at, SAVED.review_saved_at);

  store.conceptDrafts.set(DRAFT_ID, reference({ ...SAVED, review: { ...SAVED.review, concepts: [{ ...SAVED.review.concepts[0], content: 'SAVED_V2' }] } }));
  const second = await ask(store, conv.id);
  assert(allText(second.req).includes('SAVED_V2') && !allText(second.req).includes('SAVED_CONTENT_0'), '앞 질문 때 저장본을 다시 넣지 않는다');
  assertEquals(store.conceptDraftReads, [DRAFT_ID, DRAFT_ID]);
});

Deno.test('검토 창: 닫힌 초안·읽기 실패에는 제안 도구를 주지 않고, 옛 본문을 쓰지 않는다', async () => {
  const store = new MemoryThinkStore();
  const conv = await store.createConversation(CONCEPT_DRAFT_CHAT_TITLE);
  store.conceptDrafts.set(DRAFT_ID, reference({ ...SAVED, status: 'replaced' }));
  const closed = await ask(store, conv.id);
  assertEquals(closed.meta?.draft_status, 'replaced');
  assert(allText(closed.req).includes('이 초안은 닫혔다'));
  assert(!toolNames(closed.req).some((n) => n.startsWith('propose_concept_')));

  store.conceptDraftReadFails.add(DRAFT_ID);
  const failed = await ask(store, conv.id);
  assertEquals(failed.out.status, 'complete');
  assertEquals(failed.meta?.status, 'error');
  assert(!allText(failed.req).includes('SAVED_CONTENT_0'));
  assert(!toolNames(failed.req).some((n) => n.startsWith('propose_concept_')));

  store.conceptDraftReadFails.clear();
  store.conceptDrafts.delete(DRAFT_ID);
  const missing = await ask(store, conv.id);
  assertEquals(missing.meta?.status, 'not_found');

  const plain = await ask(store, conv.id, [{ text: '답' }], null);
  assertEquals(plain.meta ?? null, null, '검토 창이 아니면 초안을 읽지 않는다');
  assert(!toolNames(plain.req).some((n) => n.startsWith('propose_concept_')));
});

Deno.test('검토 창 제안: 초안 id는 서버가 넣고, op는 쓰는 칸만 보내며, 카드가 SSE로 간다', async () => {
  const store = new MemoryThinkStore();
  const conv = await store.createConversation(CONCEPT_DRAFT_CHAT_TITLE);
  store.conceptDrafts.set(DRAFT_ID, reference(SAVED));
  const op = {
    op: 'edit', key: 'c0', keys: null, into: null, title: '소수', content: '1보다 큰 자연수 중 1과 자기 자신만을 약수로 가지는 수',
    mark: null, type: null, folder: null, parts: null, name: null, description: null, legacy_sub_type: null, closest_existing: null, reason: null,
  };
  const r = await ask(store, conv.id, (_req, i) =>
    i === 0
      ? {
        functionCalls: [
          { name: DRAFT_CHANGE_TOOL_NAME, arguments: { ops: [op], reason: '사용자가 교과서 문장대로 고치자고 함', draft_id: 'other' } },
          { name: DRAFT_CHANGE_TOOL_NAME, arguments: { ops: [op], reason: '두 번째' } },
          { name: DRAFT_RERUN_TOOL_NAME, arguments: { criterion_ids: [CRITERION_ID, CRITERION_ID], reason: '기준을 바꿈' } },
          { name: DRAFT_CRITERION_TOOL_NAME, arguments: { criterion_id: '11111111-2222-4333-8444-555555555555', title: 't', body: 'b', reason: 'r' } },
        ],
      }
      : { text: '카드를 확인해 주세요.' });
  assertEquals(r.out.status, 'complete');
  assertEquals(store.conceptDraftProposals.length, 2, '같은 종류는 한 답변에 하나, 이 초안의 기준이 아니면 RPC 전에 막는다');
  const change = store.conceptDraftProposals[0];
  assertEquals(change.kind, 'concept_draft_change');
  assertEquals(change.payload.draft_id, DRAFT_ID, '모델이 준 초안 id는 쓰지 않는다');
  assertEquals(change.payload.ops, [{ op: 'edit', key: 'c0', title: '소수', content: op.content }]);
  assertEquals(store.conceptDraftProposals[1].payload.criterion_ids, [CRITERION_ID]);
  assertEquals(r.events.of('action').length, 2);
  assertEquals(store.attached[0]?.ids.length, 2, '카드는 답변 메시지에 붙는다');
});

Deno.test('검토 창 제안: RPC 오류는 다음 행동과 함께 모델에게 돌려준다', async () => {
  const store = new MemoryThinkStore();
  const conv = await store.createConversation(CONCEPT_DRAFT_CHAT_TITLE);
  store.conceptDrafts.set(DRAFT_ID, reference(SAVED));
  store.conceptDraftProposeError = 'concept_draft_change_unknown_item';
  let toolOutput = '';
  const r = await ask(store, conv.id, (req, i) => {
    if (i === 0) {
      return {
        functionCalls: [{
          name: DRAFT_CHANGE_TOOL_NAME,
          arguments: { ops: [{ op: 'mark', key: 'c9', mark: 'drop' }], reason: '중복' },
        }],
      };
    }
    toolOutput = (req.input.find((x) => x.kind === 'tool_result') as { output: string }).output;
    return { text: '없는 항목이었습니다.' };
  });
  assertEquals(r.out.status, 'complete');
  assertEquals(JSON.parse(toolOutput).error, 'concept_draft_change_unknown_item');
  assert(JSON.parse(toolOutput).next);
  assertEquals(r.events.of('action').length, 0);
});

Deno.test('cleanOp: op마다 쓰는 칸만 남기고 모르는 op는 거른다', () => {
  assertEquals(cleanOp({ op: 'mark', key: 'c1', mark: 'drop', title: 'x', parts: null }), { op: 'mark', key: 'c1', mark: 'drop' });
  assertEquals(
    cleanOp({ op: 'merge', keys: ['c0', 'c1'], into: 'c0', title: 't', content: 'c', type: null, key: 'c0' }),
    { op: 'merge', keys: ['c0', 'c1'], into: 'c0', title: 't', content: 'c' },
  );
  assertEquals(cleanOp({ op: 'rename', key: 'c0' }), null);
  assertEquals(cleanOp('edit'), null);
});
