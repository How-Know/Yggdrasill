// 종합 문서: 생성·조회·수정·출처 순서·권한·출처/대화 삭제·발췌 유지
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { aiMigrations, openAiTestDb } from '../harness.mjs';

let t;
let USER;
let OTHER;
let CONV;
let M1;
let M2;
let M3;
let FOLDER;

before(async () => {
  t = await openAiTestDb();
  USER = '11111111-1111-4111-8111-111111111111';
  OTHER = '22222222-2222-4222-8222-222222222222';
  await t.exec(`insert into auth.users (id) values ('${USER}'), ('${OTHER}')`);
  CONV = (await t.one(`insert into ai_conversations (title) values ('대화') returning id`)).id;
  M1 = (await t.one(`insert into ai_messages (conversation_id, role, content, created_at) values ($1, 'user', 'q1', now() - interval '2 min') returning id`, [CONV])).id;
  M2 = (await t.one(`insert into ai_messages (conversation_id, role, content, created_at) values ($1, 'assistant', 'a1', now() - interval '1 min') returning id`, [CONV])).id;
  M3 = (await t.one(`insert into ai_messages (conversation_id, role, content) values ($1, 'user', 'q2') returning id`, [CONV])).id;
  FOLDER = (
    await t.asSuperadmin(
      () => t.one(`insert into ai_tree_nodes (kind, title, sort_order) values ('folder', '주제', 0) returning id`),
      USER,
    )
  ).id;
});

after(() => t?.close());

test('요구2: get_id 수정 마이그레이션이 시험 DB 적용 목록에 포함된다', () => {
  const files = aiMigrations();
  assert.ok(files.some((f) => f.startsWith('20261007160000_ai_think_document_get_id_fix')));
});

const createDoc = (ids, parent = FOLDER) =>
  t.asSuperadmin(
    () =>
      t.one(`select ai_tree_create_document($1, $2, '제목', '본문 내용', $3::uuid[]) as id`, [
        CONV,
        parent,
        ids,
      ]),
    USER,
  );

test('요구2·생성: 같은 대화 메시지만, 대화 시간 순으로 출처를 연결한다', async () => {
  const row = await createDoc([M3, M1]);
  const doc = await t.asSuperadmin(() => t.one(`select * from ai_tree_get_document($1)`, [row.id]), USER);
  assert.equal(doc.title, '제목');
  assert.equal(doc.body, '본문 내용');
  assert.deepEqual(doc.source_message_ids, [M1, M3]);
  const orders = await t.all(
    `select message_id, sort_order from ai_tree_node_sources where node_id = $1 order by sort_order`,
    [row.id],
  );
  assert.deepEqual(
    orders.map((r) => r.message_id),
    [M1, M3],
  );
});

test('생성: 메시지 없음·다른 대화·비슈퍼관리자는 거절', async () => {
  await t.asSuperadmin(() => t.rejects(`select ai_tree_create_document($1, $2, 't', 'b', '{}'::uuid[])`, [CONV, FOLDER], /document_needs_messages/), USER);
  const otherConv = (await t.one(`insert into ai_conversations (title) values ('x') returning id`)).id;
  const otherMsg = (await t.one(`insert into ai_messages (conversation_id, role, content) values ($1, 'user', 'o') returning id`, [otherConv])).id;
  await t.asSuperadmin(() => t.rejects(`select ai_tree_create_document($1, $2, 't', 'b', $3::uuid[])`, [CONV, FOLDER, [otherMsg]], /tree_source_invalid/), USER);
  await t.asUser(() => t.rejects(`select ai_tree_create_document($1, $2, 't', 'b', $3::uuid[])`, [CONV, FOLDER, [M1]], /forbidden/));
});

test('요구2·조회: get_id 수정 후 ai_tree_get_document가 id·본문·출처 id를 반환한다', async () => {
  const created = await createDoc([M1, M3]);
  const doc = await t.asSuperadmin(() => t.one(`select * from ai_tree_get_document($1)`, [created.id]), USER);
  assert.equal(doc.id, created.id);
  assert.equal(doc.body, '본문 내용');
  assert.deepEqual(doc.source_message_ids, [M1, M3]);
});

test('요구2·조회·수정: 제목·본문과 낙관적 잠금', async () => {
  const id = (await createDoc([M2])).id;
  const updated = await t.asSuperadmin(
    () => t.one(`select * from ai_tree_update_document($1, '새 제목', '새 본문', 1)`, [id]),
    USER,
  );
  assert.equal(updated.title, '새 제목');
  assert.equal(updated.body, '새 본문');
  assert.equal(updated.version, 2);
  await t.asSuperadmin(() => t.rejects(`select ai_tree_update_document($1, 'x', 'y', 1)`, [id], /document_version_conflict/), USER);
  await t.asSuperadmin(() => t.rejects(`select ai_tree_get_document($1)`, ['00000000-0000-0000-0000-000000000001'], /document_not_found/), USER);
});

test('요구2·삭제: 출처 메시지 DELETE 시 종합 문서 노드 전체 삭제(일회용 데이터)', async () => {
  const id = (await createDoc([M1, M2])).id;
  await t.exec(`delete from ai_messages where id = '${M1}'`);
  const left = await t.one(`select count(*)::int as n from ai_tree_nodes where id = $1`, [id]);
  assert.equal(left.n, 0);
  assert.equal((await t.one(`select count(*)::int as n from ai_tree_node_sources where node_id = $1`, [id])).n, 0);
});

test('요구2·삭제: 대화 DELETE cascade 시 종합 문서도 함께 삭제(일회용 데이터)', async () => {
  const conv = (await t.one(`insert into ai_conversations (title) values ('지울') returning id`)).id;
  const m = (await t.one(`insert into ai_messages (conversation_id, role, content) values ($1, 'user', 'q') returning id`, [conv])).id;
  const id = (
    await t.asSuperadmin(() => t.one(`select ai_tree_create_document($1, null, 't', 'b', $2::uuid[]) as id`, [conv, [m]]), USER)
  ).id;
  await t.exec(`delete from ai_conversations where id = '${conv}'`);
  assert.equal((await t.one(`select count(*)::int as n from ai_tree_nodes where id = $1`, [id])).n, 0);
});

test('문서 노드 직접 삭제: 출처 연결도 정리', async () => {
  const id = (await createDoc([M3])).id;
  await t.asSuperadmin(() => t.exec(`delete from ai_tree_nodes where id = '${id}'`), USER);
  assert.equal((await t.one(`select count(*)::int as n from ai_tree_node_sources where node_id = $1`, [id])).n, 0);
});

test('요구2·발췌: 출처 메시지 삭제 후 노드는 유지(일회용 데이터)', async () => {
  const conv = (await t.one(`insert into ai_conversations (title) values ('발췌') returning id`)).id;
  const m = (await t.one(`insert into ai_messages (conversation_id, role, content) values ($1, 'user', 'q') returning id`, [conv])).id;
  const ex = (
    await t.asSuperadmin(() => t.one(`select ai_tree_create_excerpt($1, null, '발췌', '요약', $2::uuid[]) as id`, [conv, [m]]), USER)
  ).id;
  await t.exec(`delete from ai_messages where id = '${m}'`);
  assert.equal((await t.one(`select count(*)::int as n from ai_tree_nodes where id = $1`, [ex])).n, 1);
  assert.equal((await t.one(`select count(*)::int as n from ai_tree_node_sources where node_id = $1`, [ex])).n, 0);
});

test('PGlite 한계: RLS는 is_superadmin 스텁으로만 확인 (운영 Supabase JWT·정책 미검증)', async () => {
  assert.ok(true, '슈퍼관리자/일반 사용자 분기는 asSuperadmin·asUser로만 검증함');
});
