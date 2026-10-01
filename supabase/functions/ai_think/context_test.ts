import { assert, assertEquals } from 'jsr:@std/assert@1';
import { CONTEXT_LIMITS, buildThinkContext } from './context.ts';
import { MemoryThinkStore } from './test_support.ts';

Deno.test('지난 대화는 글자 수 예산 안에서 최신 메시지부터 남긴다', async () => {
  const store = new MemoryThinkStore();
  const conv = await store.createConversation('긴 대화');
  const big = 'ㄱ'.repeat(CONTEXT_LIMITS.messageChars);
  for (let i = 0; i < 12; i++) {
    await store.insertMessage({ conversation_id: conv.id, role: i % 2 === 0 ? 'user' : 'assistant', content: `${i}:${big}`, status: 'complete' });
  }
  const ctx = await buildThinkContext(store, { conversationId: conv.id, userMessage: '질문', attachments: [] });
  const expected = Math.floor(CONTEXT_LIMITS.historyChars / CONTEXT_LIMITS.messageChars);
  assertEquals(ctx.historyUsed, expected);
  assertEquals(ctx.historyDropped, 12 - expected);
  const first = ctx.input[0];
  assert(first.kind === 'message' && first.parts[0].type === 'text' && first.parts[0].text.startsWith(`${12 - expected}:`));
});

Deno.test('첨부는 최근 사용자 턴에만 다시 보내고, 오래된 첨부는 이름만 남긴다', async () => {
  const store = new MemoryThinkStore();
  const conv = await store.createConversation('첨부 대화');
  const pdf = (n: number) => [{ path: `u/${n}.pdf`, name: `${n}.pdf`, mime: 'application/pdf' }];
  await store.insertMessage({ conversation_id: conv.id, role: 'user', content: '오래된 첨부', status: 'complete', attachments: pdf(1) });
  await store.insertMessage({ conversation_id: conv.id, role: 'assistant', content: '확인', status: 'complete' });
  await store.insertMessage({ conversation_id: conv.id, role: 'user', content: '최근 첨부', status: 'complete', attachments: pdf(2) });
  await store.insertMessage({ conversation_id: conv.id, role: 'assistant', content: '확인', status: 'complete' });

  const ctx = await buildThinkContext(store, {
    conversationId: conv.id,
    userMessage: '이번 질문',
    attachments: [{ path: 'u/3.png', name: '3.png', mime: 'image/png' }],
  });
  const users = ctx.input.filter((i) => i.kind === 'message' && i.role === 'user');
  const kinds = users.map((u) => (u.kind === 'message' ? u.parts.map((p) => p.type) : []));
  assertEquals(kinds, [['text', 'text'], ['text', 'file'], ['text', 'image']]);
});

Deno.test('답변에서 제외한 문답은 대화 기록에 넣지 않는다', async () => {
  const store = new MemoryThinkStore();
  const conv = await store.createConversation('제외 대화');
  await store.insertMessage({ conversation_id: conv.id, role: 'user', content: '남길 질문', status: 'complete' });
  await store.insertMessage({ conversation_id: conv.id, role: 'assistant', content: '남길 답', status: 'complete' });
  await store.insertMessage({ conversation_id: conv.id, role: 'user', content: '뺄 질문', status: 'complete' });
  await store.insertMessage({ conversation_id: conv.id, role: 'assistant', content: '뺄 답', status: 'complete' });
  for (const m of store.messages.slice(2)) m.excluded = true;

  const ctx = await buildThinkContext(store, { conversationId: conv.id, userMessage: '이번 질문', attachments: [] });
  assertEquals(ctx.historyUsed, 2);
  const texts = ctx.input.flatMap((i) => (i.kind === 'message' ? i.parts : [])).map((p) => (p.type === 'text' ? p.text : ''));
  assert(!texts.some((t) => t.includes('뺄')));
});

Deno.test('서명 URL을 만들 수 없는 첨부는 이름으로 알린다', async () => {
  const store = new MemoryThinkStore();
  store.signFails.add('u/broken.pdf');
  const ctx = await buildThinkContext(store, {
    conversationId: null,
    userMessage: '',
    attachments: [{ path: 'u/broken.pdf', name: 'broken.pdf', mime: 'application/pdf' }],
  });
  const current = ctx.input.at(-1)!;
  assert(current.kind === 'message');
  assertEquals(current.parts.map((p) => p.type), ['text', 'text']);
  assert(current.parts[1].type === 'text' && current.parts[1].text.includes('broken.pdf'));
});
