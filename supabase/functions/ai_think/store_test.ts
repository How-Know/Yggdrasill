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
