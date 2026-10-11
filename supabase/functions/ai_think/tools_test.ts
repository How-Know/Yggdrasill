import { assert, assertEquals } from 'jsr:@std/assert@1';
import { THINK_TOOLS, runThinkTool } from './tools.ts';
import { parseAttachments } from './validate.ts';
import { MemoryThinkStore, memory } from './test_support.ts';

Deno.test('도구 스키마는 strict 규칙(모든 필드 required, 추가 필드 금지)을 지킨다', () => {
  type ObjectSchema = { properties: Record<string, unknown>; required: string[]; additionalProperties: boolean };
  const checkObject = (p: ObjectSchema, where: string) => {
    assertEquals(p.additionalProperties, false, where);
    assertEquals([...p.required].sort(), Object.keys(p.properties).sort(), where);
    for (const [key, value] of Object.entries(p.properties)) {
      const child = value as Partial<ObjectSchema>;
      if (child && child.properties) checkObject(child as ObjectSchema, `${where}.${key}`);
    }
  };
  for (const tool of THINK_TOOLS) checkObject(tool.parameters as ObjectSchema, tool.name);
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

Deno.test('기억 검색·열람은 active만 노출한다', async () => {
  const activeId = '11111111-1111-4111-8111-111111111111';
  const draftId = '22222222-2222-4222-8222-222222222222';
  const store = new MemoryThinkStore();
  store.memories.push(
    memory({ id: activeId, kind: 'note', title: '노출키', content: '노출키 active', status: 'active' }),
    memory({ id: draftId, kind: 'note', title: '노출키', content: '노출키 draft', status: 'draft' }),
  );
  const search = await runThinkTool('search_memories', JSON.stringify({ query: '노출키', kinds: null }), store);
  assert(search.ok);
  assertEquals(JSON.parse(search.output).map((x: { id: string }) => x.id), [activeId]);
  const getDraft = await runThinkTool('get_memory', JSON.stringify({ id: draftId }), store);
  assertEquals(getDraft.ok, false);
  assertEquals(JSON.parse(getDraft.output).error, 'not_found');
  const getActive = await runThinkTool('get_memory', JSON.stringify({ id: activeId }), store);
  assert(getActive.ok);
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
