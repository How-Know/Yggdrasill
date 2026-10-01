import { assert, assertEquals } from 'jsr:@std/assert@1';
import { THINK_TOOLS, runThinkTool } from './tools.ts';
import { parseAttachments } from './validate.ts';
import { MemoryThinkStore, memory } from './test_support.ts';

Deno.test('도구 스키마는 strict 규칙(모든 필드 required, 추가 필드 금지)을 지킨다', () => {
  for (const tool of THINK_TOOLS) {
    const p = tool.parameters as { properties: Record<string, unknown>; required: string[]; additionalProperties: boolean };
    assertEquals(p.additionalProperties, false, tool.name);
    assertEquals([...p.required].sort(), Object.keys(p.properties).sort(), tool.name);
  }
});

Deno.test('잘못된 인자와 알 수 없는 도구는 예외 없이 오류 결과를 돌려준다', async () => {
  const store = new MemoryThinkStore();
  const bad = await runThinkTool('search_memories', '{not json', store);
  assertEquals(bad.ok, false);
  const unknown = await runThinkTool('drop_table', '{}', store);
  assertEquals(unknown.ok, false);
  const badId = await runThinkTool('get_memory', JSON.stringify({ id: "1; delete from ai_memories" }), store);
  assertEquals(badId.ok, false);
});

Deno.test('기억 검색은 종류로 거를 수 있다', async () => {
  const store = new MemoryThinkStore();
  store.memories.push(
    memory({ id: 'a', kind: 'decision', title: '반복 사고', content: '반복' }),
    memory({ id: 'b', kind: 'note', title: '반복 메모', content: '반복' }),
  );
  const r = await runThinkTool('search_memories', JSON.stringify({ query: '반복', kinds: ['decision'] }), store);
  assert(r.ok);
  assertEquals(JSON.parse(r.output).map((x: { id: string }) => x.id), ['a']);
});

Deno.test('느린 조회는 시간 제한으로 끊는다', async () => {
  const store = new MemoryThinkStore();
  store.listConceptCategories = () => new Promise((resolve) => setTimeout(() => resolve([]), 200));
  const r = await runThinkTool('list_concept_categories', JSON.stringify({ parent_id: null }), store, 20);
  assertEquals(r.ok, false);
  assertEquals(JSON.parse(r.output).error, 'timeout');
  await new Promise((resolve) => setTimeout(resolve, 250));
});

Deno.test('첨부는 본인 폴더의 허용된 형식만 받는다', () => {
  const ok = parseAttachments([{ path: 'user-1/2026-09/a.pdf', name: 'a.pdf', mime: 'application/pdf', size: 10 }], 'user-1');
  assert(Array.isArray(ok));
  assertEquals(parseAttachments([{ path: 'user-2/a.pdf', name: 'a.pdf', mime: 'application/pdf' }], 'user-1'), 'attachment_path_invalid');
  assertEquals(parseAttachments([{ path: 'user-1/../x.pdf', name: 'x.pdf', mime: 'application/pdf' }], 'user-1'), 'attachment_path_invalid');
  assertEquals(parseAttachments([{ path: 'user-1/a.exe', name: 'a.exe', mime: 'application/x-msdownload' }], 'user-1'), 'attachment_type_invalid');
});
