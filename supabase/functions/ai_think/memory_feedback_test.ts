import { assert, assertEquals } from 'jsr:@std/assert@1';
import { FakeAiProvider } from '../_shared/ai/fake.ts';
import { createMemoryFeedbackDraft, parseMemoryFeedbackDraft } from './drafts.ts';
import { MK_CTX_EXCL } from './document_markers.ts';
import { MemoryThinkStore, RunLog, memory, testEnv } from './test_support.ts';

Deno.test('답변 피드백 초안은 json_schema로 요청하고 후보를 파싱한다', async () => {
  const store = new MemoryThinkStore();
  const conv = await store.createConversation('피드백');
  const q = await store.insertMessage({ conversation_id: conv.id, role: 'user', content: '질문', status: 'complete' });
  const a = await store.insertMessage({ conversation_id: conv.id, role: 'assistant', content: '답', status: 'complete' });
  const provider = new FakeAiProvider([
    {
      text: JSON.stringify({
        candidates: [
          {
            kind: 'note',
            title: '메모',
            content: '내용',
            decision_context: '',
            decision_reason: '',
            alternatives: [],
            tags: ['t'],
            update_memory_id: null,
          },
        ],
        insufficient_evidence: false,
        notes: '',
      }),
    },
  ]);
  const out = await createMemoryFeedbackDraft(
    { provider, store, recordRun: new RunLog().record, env: testEnv },
    {
      conversationId: conv.id,
      assistantMessageId: a,
      userMessageIds: [q],
      feedback: '이 답을 기억에 남기고 싶다',
      userId: 'u',
      safetyId: 'h',
    },
  );
  assert(out.ok);
  assertEquals(provider.requests[0].jsonSchema?.name, 'memory_feedback_draft');
  assertEquals(out.value.candidates.length, 1);
  assertEquals(out.value.candidates[0].kind, 'note');
  assertEquals(out.value.duplicate_warnings.length, 0);
});

Deno.test('context_excluded 답변은 기억 피드백 초안을 막는다', async () => {
  const store = new MemoryThinkStore();
  const conv = await store.createConversation('제외');
  const a = await store.insertMessage({ conversation_id: conv.id, role: 'assistant', content: MK_CTX_EXCL, status: 'complete' });
  store.messages.find((m) => m.id === a)!.excluded = true;
  const out = await createMemoryFeedbackDraft(
    { provider: new FakeAiProvider(), store, recordRun: new RunLog().record, env: testEnv },
    {
      conversationId: conv.id,
      assistantMessageId: a,
      userMessageIds: [],
      feedback: '피드백',
      userId: 'u',
      safetyId: 'h',
    },
  );
  assertEquals(out.ok, false);
  if (!out.ok) assertEquals(out.error, 'message_excluded');
});

Deno.test('확정 기억과 겹치면 duplicate_warnings를 붙인다', async () => {
  const store = new MemoryThinkStore();
  store.memories.push(memory({ id: 'm1', kind: 'note', title: '같은 제목', content: '본문', status: 'active' }));
  const conv = await store.createConversation('중복');
  const a = await store.insertMessage({ conversation_id: conv.id, role: 'assistant', content: '답', status: 'complete' });
  const provider = new FakeAiProvider([
    {
      text: JSON.stringify({
        candidates: [
          {
            kind: 'note',
            title: '같은 제목',
            content: '새 내용',
            decision_context: '',
            decision_reason: '',
            alternatives: [],
            tags: [],
            update_memory_id: null,
          },
        ],
        insufficient_evidence: false,
        notes: '',
      }),
    },
  ]);
  const out = await createMemoryFeedbackDraft(
    { provider, store, recordRun: new RunLog().record, env: testEnv },
    {
      conversationId: conv.id,
      assistantMessageId: a,
      userMessageIds: [],
      feedback: '기억',
      userId: 'u',
      safetyId: 'h',
    },
  );
  assert(out.ok);
  assertEquals(out.value.duplicate_warnings.length, 1);
  assertEquals(out.value.duplicate_warnings[0].memory_id, 'm1');
});

Deno.test('context_excluded 질문은 기억 피드백 초안을 막는다', async () => {
  const store = new MemoryThinkStore();
  const conv = await store.createConversation('질문 제외');
  const q = await store.insertMessage({ conversation_id: conv.id, role: 'user', content: MK_CTX_EXCL, status: 'complete' });
  store.messages.find((m) => m.id === q)!.excluded = true;
  const a = await store.insertMessage({ conversation_id: conv.id, role: 'assistant', content: '답', status: 'complete' });
  const out = await createMemoryFeedbackDraft(
    { provider: new FakeAiProvider(), store, recordRun: new RunLog().record, env: testEnv },
    {
      conversationId: conv.id,
      assistantMessageId: a,
      userMessageIds: [q],
      feedback: '피드백',
      userId: 'u',
      safetyId: 'h',
    },
  );
  assertEquals(out.ok, false);
  if (!out.ok) assertEquals(out.error, 'message_excluded');
});

Deno.test('parseMemoryFeedbackDraft는 잘못된 JSON을 거부한다', () => {
  assertEquals(parseMemoryFeedbackDraft('not json'), null);
});

Deno.test('수정 대상 기억을 고르면 AI 호출 전 version을 update_baseline으로 고정한다', async () => {
  const store = new MemoryThinkStore();
  store.memories.push(
    memory({ id: 'mem-upd', kind: 'note', title: '옛 제목', content: '옛 내용', status: 'active', version: 4 }),
  );
  const conv = await store.createConversation('수정');
  const a = await store.insertMessage({ conversation_id: conv.id, role: 'assistant', content: '답', status: 'complete' });
  const provider = new FakeAiProvider([
    {
      text: JSON.stringify({
        candidates: [
          {
            kind: 'note',
            title: '새 제목',
            content: '새 내용',
            decision_context: '',
            decision_reason: '',
            alternatives: [],
            tags: [],
            update_memory_id: 'mem-upd',
          },
        ],
        insufficient_evidence: false,
        notes: '',
      }),
    },
  ]);
  const out = await createMemoryFeedbackDraft(
    { provider, store, recordRun: new RunLog().record, env: testEnv },
    {
      conversationId: conv.id,
      assistantMessageId: a,
      userMessageIds: [],
      feedback: '수정',
      updateMemoryId: 'mem-upd',
      userId: 'u',
      safetyId: 'h',
    },
  );
  assert(out.ok);
  if (!out.ok) return;
  assertEquals(out.update_baseline, { memory_id: 'mem-upd', version: 4 });
});

Deno.test('AI가 다른 update_memory_id를 제안하면 거부한다', async () => {
  const store = new MemoryThinkStore();
  store.memories.push(memory({ id: 'mem-a', kind: 'note', title: 'A', content: 'A', status: 'draft', version: 2 }));
  const conv = await store.createConversation('id 불일치');
  const a = await store.insertMessage({ conversation_id: conv.id, role: 'assistant', content: '답', status: 'complete' });
  const provider = new FakeAiProvider([
    {
      text: JSON.stringify({
        candidates: [
          {
            kind: 'note',
            title: 't',
            content: 'c',
            decision_context: '',
            decision_reason: '',
            alternatives: [],
            tags: [],
            update_memory_id: 'other-id',
          },
        ],
        insufficient_evidence: false,
        notes: '',
      }),
    },
  ]);
  const out = await createMemoryFeedbackDraft(
    { provider, store, recordRun: new RunLog().record, env: testEnv },
    {
      conversationId: conv.id,
      assistantMessageId: a,
      userMessageIds: [],
      feedback: '수정',
      updateMemoryId: 'mem-a',
      userId: 'u',
      safetyId: 'h',
    },
  );
  assertEquals(out.ok, false);
  if (!out.ok) assertEquals(out.error, 'invalid_output');
});

Deno.test('draft 상태 수정 대상은 초안 후보에 남긴다', async () => {
  const store = new MemoryThinkStore();
  store.memories.push(memory({ id: 'mem-d', kind: 'note', title: '초안', content: '본문', status: 'draft', version: 1 }));
  const conv = await store.createConversation('draft 수정');
  const a = await store.insertMessage({ conversation_id: conv.id, role: 'assistant', content: '답', status: 'complete' });
  const provider = new FakeAiProvider([
    {
      text: JSON.stringify({
        candidates: [],
        insufficient_evidence: false,
        notes: '',
      }),
    },
  ]);
  const out = await createMemoryFeedbackDraft(
    { provider, store, recordRun: new RunLog().record, env: testEnv },
    {
      conversationId: conv.id,
      assistantMessageId: a,
      userMessageIds: [],
      feedback: '고치기',
      updateMemoryId: 'mem-d',
      userId: 'u',
      safetyId: 'h',
    },
  );
  assert(out.ok);
  if (!out.ok) return;
  assertEquals(out.value.candidates.length, 1);
  assertEquals(out.value.candidates[0].update_memory_id, 'mem-d');
});
