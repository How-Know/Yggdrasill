import { assertEquals } from 'jsr:@std/assert@1';
import { SupabaseThinkStore, type SupabaseLike } from './store.ts';

type Call = [string, ...unknown[]];

function recordingDb(rows: Record<string, unknown>[]): { db: SupabaseLike; calls: Call[] } {
  const calls: Call[] = [];
  const builder: Record<string, unknown> = new Proxy({}, {
    get(_t, prop: string) {
      if (prop === 'then') {
        return (resolve: (v: unknown) => void) => resolve({ data: rows, error: null });
      }
      return (...args: unknown[]) => {
        calls.push([prop, ...args]);
        return builder;
      };
    },
  });
  const db: SupabaseLike = {
    from: (table: string) => {
      calls.push(['from', table]);
      return builder;
    },
    rpc: () => builder,
    storage: { from: () => builder },
  };
  return { db, calls };
}

Deno.test('대화는 *로 읽고, 나누기 열이 없는 DB(마이그레이션 전)면 기본값을 쓴다', async () => {
  const before = recordingDb([]);
  (before.db as unknown as { from: unknown }).from = (table: string) => {
    before.calls.push(['from', table]);
    return {
      select: (cols: string) => {
        before.calls.push(['select', cols]);
        return { eq: () => ({ maybeSingle: () => Promise.resolve({ data: { id: 'c1', title: 't', status: 'active', scope_type: 'general' }, error: null }) }) };
      },
    };
  };
  const conv = await new SupabaseThinkStore(before.db).getConversation('c1');
  assertEquals(before.calls.find((c) => c[0] === 'select'), ['select', '*']);
  assertEquals(conv?.auto_split_suggestions, true);
  assertEquals(conv?.split_summary, null);
  assertEquals(conv?.split_from_conversation_id, null);
});

Deno.test('나누기 제안은 전용 RPC에 서버가 정한 시작 메시지와 명시 요청 여부만 넘긴다', async () => {
  const calls: [string, Record<string, unknown>][] = [];
  const db = {
    from: () => {
      throw new Error('테이블에 직접 쓰지 않는다');
    },
    rpc: (fn: string, args: Record<string, unknown>) => {
      calls.push([fn, args]);
      return { single: () => Promise.resolve({ data: { id: 'a1', conversation_id: 'c1', kind: 'split_conversation', status: 'proposed' }, error: null }) };
    },
    storage: { from: () => null },
  } as unknown as SupabaseLike;
  const row = await new SupabaseThinkStore(db).proposeSplit('c1', 'm1', { title: 't' }, { folder_path: null }, true);
  assertEquals(row.kind, 'split_conversation');
  assertEquals(calls, [[
    'ai_conversation_split_propose',
    { p_conversation_id: 'c1', p_start_message_id: 'm1', p_payload: { title: 't' }, p_preview: { folder_path: null }, p_user_requested: true },
  ]]);
});

Deno.test('AI가 읽는 대화 기록 조회는 답변에서 제외한 메시지를 뺀다', async () => {
  const { db, calls } = recordingDb([
    { id: 'm2', role: 'assistant', content: '답', status: 'complete', attachments: [], created_at: '2026-09-29T00:00:02Z' },
    { id: 'm1', role: 'user', content: '질문', status: 'complete', attachments: [], created_at: '2026-09-29T00:00:01Z' },
  ]);
  const rows = await new SupabaseThinkStore(db).listMessages('conv-1', 40);
  const eqs = calls.filter((c) => c[0] === 'eq').map((c) => c.slice(1));
  assertEquals(eqs, [['conversation_id', 'conv-1'], ['context_excluded', false]]);
  assertEquals(rows.map((r) => r.id), ['m1', 'm2']);
});
