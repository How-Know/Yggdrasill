// ai_search_memories active-only 마이그레이션: draft 제외·승인 기억 검색 한도
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { aiMigrations, openAiTestDb } from '../harness.mjs';

test('active-only 마이그레이션이 AI 파일 목록에 포함된다', () => {
  const files = aiMigrations();
  assert.ok(files.some((f) => f.startsWith('20261008210000_ai_search_memories_active_only')));
});

test('같은 검색어에 active만 반환하고 draft는 빠진다', async () => {
  const t = await openAiTestDb();
  try {
    const USER = '33333333-3333-4333-8333-333333333333';
    await t.exec(`insert into auth.users (id) values ('${USER}')`);
    const activeId = (
      await t.asSuperadmin(
        () =>
          t.one(
            `insert into ai_memories (kind, status, title, content, tags)
             values ('note', 'active', '슬롯키워드 active', '본문 슬롯키워드', array['t'])
             returning id`,
          ),
        USER,
      )
    ).id;
    await t.asSuperadmin(
      () =>
        t.one(
          `insert into ai_memories (kind, status, title, content, tags)
           values ('note', 'draft', '슬롯키워드 draft', '본문 슬롯키워드', array['t'])
           returning id`,
        ),
      USER,
    );
    const rows = await t.asSuperadmin(
      () => t.all(`select id, kind, status, title, score from ai_search_memories($1::text[], 10)`, [['슬롯키워드']]),
      USER,
    );
    assert.equal(rows.length, 1);
    assert.equal(rows[0].id, activeId);
    assert.equal(rows[0].status, 'active');
    assert.ok(rows[0].score > 0);
    assert.equal(rows[0].title, '슬롯키워드 active');
  } finally {
    await t.close();
  }
});

test('p_limit만큼 active 결과를 자른다', async () => {
  const t = await openAiTestDb();
  try {
    const USER = '44444444-4444-4444-8444-444444444444';
    await t.exec(`insert into auth.users (id) values ('${USER}')`);
    for (let i = 0; i < 5; i++) {
      await t.asSuperadmin(
        () =>
          t.one(
            `insert into ai_memories (kind, status, title, content)
             values ('note', 'active', $1, '한도키워드 본문') returning id`,
            [`한도키워드-${i}`],
          ),
        USER,
      );
    }
    const rows = await t.asSuperadmin(
      () => t.all(`select id from ai_search_memories($1::text[], 3)`, [['한도키워드']]),
      USER,
    );
    assert.equal(rows.length, 3);
  } finally {
    await t.close();
  }
});
