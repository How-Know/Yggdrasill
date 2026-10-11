import { assertEquals } from 'jsr:@std/assert@1';
import type { Db } from './db.ts';
import { emptyUsage } from './types.ts';
import { aiRunRow, recordAiRun, type AiRunRecord } from './usage.ts';

const rec = (features?: Record<string, unknown> | null): AiRunRecord => ({
  feature: 'think_chat',
  provider: 'fake',
  model: 'gpt-6-sol',
  status: 'ok',
  usage: emptyUsage(),
  costUsd: null,
  features,
});

function insertDb(results: { data: unknown; error: { code?: string; message: string } | null }[]): { db: Db; rows: Record<string, unknown>[] } {
  const rows: Record<string, unknown>[] = [];
  const db = {
    from: () => ({
      insert: (row: Record<string, unknown>) => {
        rows.push(row);
        const res = results[Math.min(rows.length - 1, results.length - 1)];
        return { select: () => ({ single: () => Promise.resolve(res) }) };
      },
    }),
    rpc: () => null,
  } as unknown as Db;
  return { db, rows };
}

Deno.test('기능 상태는 있을 때만 ai_runs.features로 보낸다', () => {
  assertEquals('features' in aiRunRow(rec()), false);
  assertEquals(aiRunRow(rec({ conversation_split: { state: 'ready' } })).features, { conversation_split: { state: 'ready' } });
});

Deno.test('features 열이 없는 DB(마이그레이션 전)면 그 필드만 빼고 다시 기록한다', async () => {
  const { db, rows } = insertDb([
    { data: null, error: { code: 'PGRST204', message: "Could not find the 'features' column of 'ai_runs' in the schema cache" } },
    { data: { id: 'run-1' }, error: null },
  ]);
  assertEquals(await recordAiRun(db, rec({ conversation_split: { state: 'db_required' } })), 'run-1');
  assertEquals(rows.length, 2);
  assertEquals('features' in rows[1], false);
});

Deno.test('다른 기록 오류는 다시 시도하지 않고 null', async () => {
  const { db, rows } = insertDb([{ data: null, error: { code: '23502', message: 'null value in column "model"' } }]);
  assertEquals(await recordAiRun(db, rec({ conversation_split: { state: 'ready' } })), null);
  assertEquals(rows.length, 1);
});
