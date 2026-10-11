// Think 역할·링크·스냅샷·나누기 승계
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { openAiTestDb } from '../harness.mjs';

const USER = '22222222-2222-4222-8222-222222222222';
let t;

before(async () => {
  t = await openAiTestDb();
  await t.exec(`insert into auth.users (id) values ('${USER}')`);
});

after(() => t?.close());

const su = (fn) => t.asSuperadmin(fn, USER);

test('ai_think_db_features에 think_roles=1이 포함된다', async () => {
  const row = await su(() => t.one(`select ai_think_db_features() as f`));
  assert.equal(row.f.think_roles, 1);
});

test('승인 active 기억만 대화에 연결할 수 있다', async () => {
  const conv = (await su(() => t.one(`insert into ai_conversations (title) values ('역할') returning id`))).id;
  const mem = (
    await su(() =>
      t.one(
        `insert into ai_memories (kind, status, title, content, memory_scope, scope_department)
         values ('note', 'active', '교육', '본문', 'department', 'education') returning id`,
      ),
    )
  ).id;
  await su(() => t.one(`select * from ai_conversation_memory_link($1, $2)`, [conv, mem]));
  const draft = (
    await su(() => t.one(`insert into ai_memories (kind, status, title) values ('note', 'draft', 'x') returning id`))
  ).id;
  await assert.rejects(() => su(() => t.one(`select ai_conversation_memory_link($1, $2)`, [conv, draft])), /memory_not_linkable/);
});

test('기존 기억은 레거시 공통이 되고, 부서 범위는 부서가 있어야 한다', async () => {
  const legacy = await su(() =>
    t.one(`insert into ai_memories (kind, status, title) values ('note', 'active', '예전') returning memory_scope, scope_department`),
  );
  assert.equal(legacy.memory_scope, 'legacy_unscoped');
  assert.equal(legacy.scope_department, null);
  await assert.rejects(
    () => su(() => t.one(`insert into ai_memories (kind, status, title, memory_scope) values ('note', 'active', 'x', 'department') returning id`)),
    /scope_department_shape/,
  );
  await assert.rejects(
    () =>
      su(() =>
        t.one(
          `insert into ai_memories (kind, status, title, memory_scope, scope_department)
           values ('note', 'active', 'x', 'common', 'education') returning id`,
        ),
      ),
    /scope_department_shape/,
  );
  await assert.rejects(
    () =>
      su(() =>
        t.one(
          `insert into ai_memories (kind, status, title, memory_scope, scope_department)
           values ('note', 'active', 'x', 'department', 'lead') returning id`,
        ),
      ),
    /check/,
  );
});

test('역할 저장 RPC는 슈퍼관리자만, 정해진 역할·참조 부서만 받는다', async () => {
  const conv = (await su(() => t.one(`insert into ai_conversations (title) values ('역할 저장') returning id, think_role_id`)));
  assert.equal(conv.think_role_id, 'lead');
  const row = await su(() =>
    t.one(`select * from ai_conversation_set_think_role($1, 'education', array['product'], 'think-role-test')`, [conv.id]),
  );
  assert.equal(row.think_role_id, 'education');
  assert.deepEqual(row.extra_ref_departments, ['product']);
  assert.equal(row.role_profile_version, 'think-role-test');
  await assert.rejects(
    () => su(() => t.one(`select ai_conversation_set_think_role($1, 'boss', '{}'::text[], null)`, [conv.id])),
    /think_role_invalid/,
  );
  await assert.rejects(
    () => su(() => t.one(`select ai_conversation_set_think_role($1, 'product', array['lead'], null)`, [conv.id])),
    /extra_ref_invalid/,
  );
  await t.asUser(() => t.rejects(`select ai_conversation_set_think_role($1, 'product', '{}'::text[], null)`, [conv.id], /forbidden/));
  await t.asAnon(() => t.rejects(`select ai_conversation_set_think_role($1, 'product', '{}'::text[], null)`, [conv.id], /permission denied/));
});

test('범위 검색: 모드별로 보이는 부서 기억이 다르고 범위 열을 돌려준다', async () => {
  const ins = (title, scope, dept, status = 'active') =>
    su(() =>
      t.one(
        `insert into ai_memories (kind, status, title, content, memory_scope, scope_department)
         values ('decision', $1, $2, '검색어진도', $3, $4) returning id`,
        [status, title, scope, dept],
      ),
    );
  const legacy = (await ins('레거시', 'legacy_unscoped', null)).id;
  const common = (await ins('공통', 'common', null)).id;
  const edu = (await ins('교육', 'department', 'education')).id;
  const prod = (await ins('제품', 'department', 'product')).id;
  const draft = (await ins('초안', 'common', null, 'draft')).id;
  const search = async (mode, refs = [], linked = []) =>
    (
      await su(() =>
        t.all(`select id, memory_scope, scope_department from ai_search_memories_scoped(array['검색어진도'], 30, $1, $2, $3)`, [
          mode,
          refs,
          linked,
        ]),
      )
    ).map((r) => r.id);
  const has = (ids, id) => ids.includes(id);

  const legacyIds = await search('legacy');
  assert.ok(has(legacyIds, legacy) && has(legacyIds, common));
  assert.ok(!has(legacyIds, edu) && !has(legacyIds, prod) && !has(legacyIds, draft));

  const eduIds = await search('education');
  assert.ok(has(eduIds, edu) && !has(eduIds, prod));

  assert.ok(has(await search('education', ['product']), prod));
  assert.ok(has(await search('education', [], [prod]), prod));
  assert.ok(!has(await search('legacy', ['product'], [prod]), prod), 'legacy 모드는 참조·연결도 무시한다');

  const leadIds = await search('lead');
  assert.ok(has(leadIds, edu) && has(leadIds, prod) && !has(leadIds, draft));
  assert.ok(!has(await search('all'), draft), 'all도 active만');

  const row = await su(() =>
    t.one(`select memory_scope, scope_department from ai_search_memories_scoped(array['검색어진도'], 30, 'lead') where id = $1`, [edu]),
  );
  assert.deepEqual(row, { memory_scope: 'department', scope_department: 'education' });
  await assert.rejects(() => su(() => t.all(`select * from ai_search_memories_scoped(array['x'], 5, 'boss')`)), /memory_search_mode_invalid/);
  await t.asAnon(() => t.rejects(`select * from ai_search_memories_scoped(array['x'])`, [], /permission denied/));
});

test('문서 링크는 종합 문서만 받고, 연결 해제와 비관리자 차단이 된다', async () => {
  const conv = (await su(() => t.one(`insert into ai_conversations (title) values ('문서 원본') returning id`))).id;
  const other = (await su(() => t.one(`insert into ai_conversations (title) values ('문서 사용') returning id`))).id;
  const doc = (
    await su(() =>
      t.one(
        `insert into ai_tree_nodes (kind, conversation_id, title, body) values ('document', $1, '종합', '본문') returning id`,
        [conv],
      ),
    )
  ).id;
  const node = (
    await su(() => t.one(`select id from ai_tree_nodes where conversation_id = $1 and kind = 'conversation'`, [conv]))
  )?.id;
  await su(() => t.one(`select * from ai_conversation_document_link($1, $2)`, [other, doc]));
  await su(() => t.one(`select * from ai_conversation_document_link($1, $2)`, [other, doc]));
  const n = await su(() => t.one(`select count(*)::int as n from ai_conversation_document_links where conversation_id = $1`, [other]));
  assert.equal(n.n, 1, '같은 문서를 두 번 연결해도 한 줄');
  if (node) {
    await assert.rejects(() => su(() => t.one(`select ai_conversation_document_link($1, $2)`, [other, node])), /document_not_found/);
  }
  await t.asUser(() => t.rejects(`select ai_conversation_document_link($1, $2)`, [other, doc], /forbidden/));
  await su(() => t.one(`select ai_conversation_document_unlink($1, $2)`, [other, doc]));
  const after = await su(() => t.one(`select count(*)::int as n from ai_conversation_document_links where conversation_id = $1`, [other]));
  assert.equal(after.n, 0);
});

test('답변 스냅샷·링크 표는 슈퍼관리자만 읽는다', async () => {
  const conv = (await su(() => t.one(`insert into ai_conversations (title) values ('스냅샷') returning id`))).id;
  const msg = (
    await su(() => t.one(`insert into ai_messages (conversation_id, role, content) values ($1, 'assistant', '답') returning id`, [conv]))
  ).id;
  await su(() =>
    t.one(
      `insert into ai_message_context_snapshots (message_id, think_role_id, materials)
       values ($1, 'education', '[{"kind":"memory","id":"m","delivered":true}]'::jsonb) returning message_id`,
      [msg],
    ),
  );
  const rows = await t.asUser(() => t.all(`select * from ai_message_context_snapshots`));
  assert.equal(rows.length, 0);
  const links = await t.asUser(() => t.all(`select * from ai_conversation_memory_links`));
  assert.equal(links.length, 0);
  await assert.rejects(
    () =>
      su(() =>
        t.one(
          `insert into ai_message_context_snapshots (message_id, think_role_id, materials) values ($1, 'education', '{}'::jsonb) returning message_id`,
          [msg],
        ),
      ),
    /check|duplicate/,
  );
});

test('대화 나누기 승인 시 active 기억 링크만 새 대화로 승계된다', async () => {
  const src = (await su(() => t.one(`insert into ai_conversations (title, think_role_id) values ('원본', 'product') returning id`))).id;
  const dstBefore = (await su(() => t.one(`select count(*)::int as n from ai_conversations`))).n;
  const active = (
    await su(() =>
      t.one(`insert into ai_memories (kind, status, title) values ('note', 'active', 'a') returning id`),
    )
  ).id;
  const draft = (
    await su(() => t.one(`insert into ai_memories (kind, status, title) values ('note', 'draft', 'd') returning id`))
  ).id;
  await su(() => t.one(`select ai_conversation_memory_link($1, $2)`, [src, active]));

  const start = (
    await su(() =>
      t.one(
        `insert into ai_messages (conversation_id, role, content, created_at)
         values ($1, 'user', '앞', now() - interval '2 min') returning id`,
        [src],
      ),
    )
  ).id;
  await su(() =>
    t.one(`insert into ai_messages (conversation_id, role, content) values ($1, 'assistant', '앞답')`, [src]),
  );
  const turn = (
    await su(() =>
      t.one(`insert into ai_messages (conversation_id, role, content) values ($1, 'user', '새') returning id`, [src]),
    )
  ).id;
  const ans = (
    await su(() =>
      t.one(
        `insert into ai_messages (conversation_id, role, content, status) values ($1, 'assistant', '새답', 'complete') returning id`,
        [src],
      ),
    )
  ).id;
  const action = (
    await su(() =>
      t.one(
        `select * from ai_conversation_split_propose($1, $2, $3::jsonb, '{}'::jsonb, false)`,
        [
          src,
          turn,
          JSON.stringify({
            title: '나눔',
            summary: { purpose: 'p', background: '', decided: [], open: [], next: [] },
          }),
        ],
      ),
    )
  ).id;
  await su(() => t.one(`select ai_action_attach($1::uuid[], $2)`, [[action], ans]));
  const applied = await su(() => t.one(`select * from ai_action_apply($1, '{}'::jsonb)`, [action]));
  const newId = applied.result.conversation_id;
  assert.ok(newId);
  const links = await su(() =>
    t.all(`select memory_id from ai_conversation_memory_links where conversation_id = $1`, [newId]),
  );
  assert.equal(links.length, 1);
  assert.equal(links[0].memory_id, active);
  const role = await su(() => t.one(`select think_role_id from ai_conversations where id = $1`, [newId]));
  assert.equal(role.think_role_id, 'product');
  assert.equal((await su(() => t.one(`select count(*)::int as n from ai_conversations`))).n, dstBefore + 1);
});
