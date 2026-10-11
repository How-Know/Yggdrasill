import { test } from 'node:test';
import assert from 'node:assert/strict';
import { aiMigrations, openAiTestDb } from '../harness.mjs';

test('AI 영역 DB 함수 파일이 처음부터 순서대로 모두 적용된다', async () => {
  const files = aiMigrations();
  assert.ok(files.length >= 8);
  const t = await openAiTestDb({ files });
  try {
    const row = await t.one(`select count(*)::int as n from ai_memories where kind = 'identity'`);
    assert.ok(row.n >= 2);
  } finally {
    await t.close();
  }
});
