import { assertEquals } from 'jsr:@std/assert@1';
import type { SupabaseLike } from '../ai_think/store.ts';
import { SupabaseReviewStore } from './review_store.ts';

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

Deno.test('ReviewStore.listMessages는 SupabaseThinkStore와 같이 context_excluded=false만 조회한다', async () => {
  const { db, calls } = recordingDb([]);
  await new SupabaseReviewStore(db).listMessages('conv-1', 30);
  const eqs = calls.filter((c) => c[0] === 'eq').map((c) => c.slice(1));
  assertEquals(eqs, [['conversation_id', 'conv-1'], ['context_excluded', false]]);
});
