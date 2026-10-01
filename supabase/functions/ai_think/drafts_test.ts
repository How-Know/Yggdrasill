import { assert, assertEquals } from 'jsr:@std/assert@1';
import { FakeAiProvider } from '../_shared/ai/fake.ts';
import { createDecisionDraft, createSpecExport, parseDecisionDraft, specFileName } from './drafts.ts';
import { MemoryThinkStore, RunLog, memory, testEnv } from './test_support.ts';

Deno.test('결정 초안은 구조화 출력(json_schema)으로 요청하고 형식을 검증한다', async () => {
  const store = new MemoryThinkStore();
  const conv = await store.createConversation('반복 사고');
  await store.insertMessage({ conversation_id: conv.id, role: 'user', content: '반복 사고를 먼저 하자', status: 'complete' });
  await store.insertMessage({ conversation_id: conv.id, role: 'assistant', content: '좋습니다', status: 'complete' });
  const provider = new FakeAiProvider();
  const runs = new RunLog();

  const out = await createDecisionDraft(
    { provider, store, recordRun: runs.record, env: testEnv },
    { conversationId: conv.id, userId: 'u', safetyId: 'h' },
  );

  assert(out.ok);
  assertEquals(provider.requests[0].jsonSchema?.name, 'decision_draft');
  assertEquals(Object.keys(out.value).sort(), ['alternatives', 'conflicts', 'context', 'decision', 'open_questions', 'reason', 'tags', 'title']);
  assertEquals(runs.runs[0].feature, 'decision_draft');
});

Deno.test('빈 대화나 JSON이 아닌 출력은 오류로 돌려준다', async () => {
  const store = new MemoryThinkStore();
  const conv = await store.createConversation('빈 대화');
  const empty = await createDecisionDraft(
    { provider: new FakeAiProvider(), store, recordRun: new RunLog().record, env: testEnv },
    { conversationId: conv.id, userId: 'u', safetyId: 'h' },
  );
  assertEquals(empty.ok, false);
  assertEquals(parseDecisionDraft('not json'), null);
});

Deno.test('스펙 내보내기는 결정만 받는다', async () => {
  const store = new MemoryThinkStore();
  store.memories.push(memory({ id: 'n1', kind: 'note', title: '메모' }), memory({ id: 'd1', kind: 'decision', title: '반복 사고 우선', content: '결정' }));
  const deps = { provider: new FakeAiProvider([{ text: '# 반복 사고 우선\n\n## 배경' }]), store, recordRun: new RunLog().record, env: testEnv };
  const note = await createSpecExport(deps, { memoryId: 'n1', userId: 'u', safetyId: 'h' });
  assertEquals(note.ok, false);
  const decision = await createSpecExport(deps, { memoryId: 'd1', userId: 'u', safetyId: 'h' });
  assert(decision.ok);
  assert(decision.value.suggestedPath.startsWith('docs/specs/'));
  assert(decision.value.suggestedPath.endsWith('.md'));
});

Deno.test('스펙 파일 이름은 날짜와 제목으로 만든다', () => {
  assertEquals(specFileName('반복 사고: 먼저!', '2026-09-28'), 'docs/specs/20260928-반복-사고-먼저.md');
  assertEquals(specFileName('***', '2026-09-28'), 'docs/specs/20260928-decision.md');
});
