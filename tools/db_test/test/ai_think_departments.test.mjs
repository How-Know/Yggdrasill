// Think 부서별 트리: 폴더 부서·기존 폴더 배치·부서 간 옮기기·부서 넘기기 제안
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { aiMigrations, migrationsDir, openAiTestDb } from '../harness.mjs';

const USER = '33333333-3333-4333-8333-333333333333';
const DEPT_FILE = '20261012100000_ai_think_departments.sql';
let t;

before(async () => {
  t = await openAiTestDb();
  await t.exec(`insert into auth.users (id) values ('${USER}')`);
});

after(() => t?.close());

const su = (fn) => t.asSuperadmin(fn, USER);
const newConv = async (title, role = 'lead') =>
  (await su(() => t.one(`insert into ai_conversations (title, think_role_id) values ($1, $2) returning id`, [title, role]))).id;
const newFolder = async (title, parentId = null, department = null) =>
  (
    await su(() =>
      t.one(
        `insert into ai_tree_nodes (kind, title, parent_id, department, sort_order) values ('folder', $1, $2, $3, 0) returning id`,
        [title, parentId, department],
      ),
    )
  ).id;
const deptOf = async (id) => (await su(() => t.one(`select department from ai_tree_nodes where id = $1`, [id]))).department;
const roleOf = async (id) => (await su(() => t.one(`select think_role_id from ai_conversations where id = $1`, [id]))).think_role_id;
const nodeOf = async (convId) =>
  su(() => t.one(`select id, parent_id from ai_tree_nodes where kind = 'conversation' and conversation_id = $1`, [convId]));

test('ai_think_db_features에 department_work=1이 포함된다', async () => {
  const row = await su(() => t.one(`select ai_think_db_features() as f`));
  assert.equal(row.f.department_work, 1);
});

test('기존 최상위 폴더는 가장 많은 대화 부서로, 동률·빈 폴더는 총괄로 배치되고 하위 폴더가 따른다', async () => {
  const db = await openAiTestDb({ files: aiMigrations().filter((f) => f < DEPT_FILE) });
  try {
    await db.exec(`insert into auth.users (id) values ('${USER}')`);
    const s = (fn) => db.asSuperadmin(fn, USER);
    const conv = async (role) =>
      (await s(() => db.one(`insert into ai_conversations (title, think_role_id) values ('c', $1) returning id`, [role]))).id;
    const folder = async (title, parent = null) =>
      (await s(() => db.one(`insert into ai_tree_nodes (kind, title, parent_id) values ('folder', $1, $2) returning id`, [title, parent]))).id;
    const place = (c, f) => s(() => db.one(`select ai_tree_place_conversation($1, $2, 0)`, [c, f]));

    const eduRoot = await folder('교육 위주');
    const eduChild = await folder('하위', eduRoot);
    await place(await conv('education'), eduRoot);
    await place(await conv('education'), eduChild);
    await place(await conv('engineering'), eduChild);
    const tie = await folder('동률');
    await place(await conv('product'), tie);
    await place(await conv('engineering'), tie);
    const empty = await folder('빈 폴더');

    await db.exec(readFileSync(join(migrationsDir, DEPT_FILE), 'utf8'));
    const d = async (id) => (await s(() => db.one(`select department from ai_tree_nodes where id = $1`, [id]))).department;
    assert.equal(await d(eduRoot), 'education');
    assert.equal(await d(eduChild), 'education');
    assert.equal(await d(tie), 'lead');
    assert.equal(await d(empty), 'lead');
    const roles = await s(() => db.all(`select think_role_id from ai_conversations order by think_role_id`));
    assert.deepEqual(
      roles.map((r) => r.think_role_id),
      ['education', 'education', 'engineering', 'engineering', 'product'],
      '배치 중 대화 역할은 바뀌지 않는다',
    );
  } finally {
    await db.close();
  }
});

test('새 폴더: 최상위는 정한 부서(없으면 총괄), 하위는 상위를 따르고, 폴더가 아니면 부서가 없다', async () => {
  const root = await newFolder('개발 폴더', null, 'engineering');
  const child = await newFolder('하위', root, 'education');
  const plain = await newFolder('기본');
  assert.equal(await deptOf(root), 'engineering');
  assert.equal(await deptOf(child), 'engineering');
  assert.equal(await deptOf(plain), 'lead');
  const conv = await newConv('대화');
  const node = (
    await su(() =>
      t.one(`insert into ai_tree_nodes (kind, conversation_id, department) values ('conversation', $1, 'education') returning department`, [conv]),
    )
  );
  assert.equal(node.department, null);
  await assert.rejects(
    () => su(() => t.one(`insert into ai_tree_nodes (kind, title, department) values ('folder', 'x', 'boss') returning id`)),
    /check/,
  );
});

test('최상위 폴더를 다른 부서로 옮기면 하위 폴더 부서와 안의 대화 역할이 함께 바뀐다', async () => {
  const root = await newFolder('옮길 폴더', null, 'lead');
  const child = await newFolder('하위', root);
  const a = await newConv('a', 'lead');
  const b = await newConv('b', 'education');
  await su(() => t.one(`select ai_tree_place_conversation($1, $2, 0)`, [a, root]));
  await su(() => t.one(`select ai_tree_place_conversation($1, $2, 0)`, [b, child]));
  await su(() => t.exec(`update ai_conversations set extra_ref_departments = array['education','engineering'] where id = '${a}'`));

  const res = await su(() => t.one(`select ai_tree_move_department($1, null, null, 0, 'education') as r`, [root]));
  assert.equal(res.r.department, 'education');
  assert.equal(res.r.roles_changed, 1, '이미 교육인 대화는 세지 않는다');
  assert.equal(await deptOf(root), 'education');
  assert.equal(await deptOf(child), 'education');
  assert.equal(await roleOf(a), 'education');
  const refs = await su(() => t.one(`select extra_ref_departments from ai_conversations where id = $1`, [a]));
  assert.deepEqual(refs.extra_ref_departments, ['engineering'], '새 부서는 추가 참조에서 빠진다');
});

test('미분류 대화를 다른 부서 폴더에 놓으면 트리에 들어가고 역할이 그 폴더 부서가 된다', async () => {
  const folder = await newFolder('개발 칸', null, 'engineering');
  const c = await newConv('미분류', 'lead');
  const res = await su(() => t.one(`select ai_tree_move_department(null, $1, $2, 0, null) as r`, [c, folder]));
  assert.equal(res.r.department, 'engineering');
  assert.equal(res.r.roles_changed, 1);
  assert.equal((await nodeOf(c)).parent_id, folder);
  assert.equal(await roleOf(c), 'engineering');
  await assert.rejects(() => su(() => t.one(`select ai_tree_move_department(null, $1, null, 0, null)`, [c])), /tree_department_invalid/);
  await t.asUser(() => t.rejects(`select ai_tree_move_department(null, $1, null, 0, 'lead')`, [c], /forbidden/));
  await t.asAnon(() => t.rejects(`select ai_tree_move_department(null, $1, null, 0, 'lead')`, [c], /permission denied/));
});

test('다른 부서 미분류로 옮기기: 역할이 바뀌고 트리에서 빠진다', async () => {
  const folder = await newFolder('교육 칸', null, 'education');
  const c = await newConv('옮김', 'education');
  await su(() => t.one(`select ai_tree_place_conversation($1, $2, 0)`, [c, folder]));
  const res = await su(() => t.one(`select ai_conversation_move_department($1, 'product') as r`, [c]));
  assert.equal(res.r.from_department, 'education');
  assert.equal(res.r.unfiled, true);
  assert.equal(await roleOf(c), 'product');
  assert.equal(await nodeOf(c), undefined);
  await t.asUser(() => t.rejects(`select ai_conversation_move_department($1, 'lead')`, [c], /forbidden/));
});

test('역할 칩으로 역할을 바꿔 폴더 부서와 달라지면 미분류로 빠지고, 같으면 그대로 둔다', async () => {
  const folder = await newFolder('교육 폴더', null, 'education');
  const c = await newConv('칩', 'education');
  await su(() => t.one(`select ai_tree_place_conversation($1, $2, 0)`, [c, folder]));
  await su(() => t.one(`select * from ai_conversation_set_think_role($1, 'education', array['product'], null)`, [c]));
  assert.equal((await nodeOf(c)).parent_id, folder, '같은 부서면 그대로');
  await su(() => t.one(`select * from ai_conversation_set_think_role($1, 'engineering', '{}'::text[], null)`, [c]));
  assert.equal(await nodeOf(c), undefined);

  const top = await newConv('최상위', 'lead');
  await su(() => t.one(`select ai_tree_place_conversation($1, null, 0)`, [top]));
  await su(() => t.one(`select * from ai_conversation_set_think_role($1, 'product', '{}'::text[], null)`, [top]));
  assert.ok(await nodeOf(top), '최상위 대화는 역할을 따라 칸만 바뀐다');
});

test('부서 넘기기 제안: 같은 부서·빈 이유는 막고, 새 제안이 이전 제안을 대체하고, 승인하면 역할을 바꿔 미분류로', async () => {
  const folder = await newFolder('총괄 폴더', null, 'lead');
  const c = await newConv('넘김', 'lead');
  await su(() => t.one(`select ai_tree_place_conversation($1, $2, 0)`, [c, folder]));
  await assert.rejects(
    () => su(() => t.one(`select * from ai_department_handover_propose($1, 'lead', '이유')`, [c])),
    /handover_same_department/,
  );
  await assert.rejects(
    () => su(() => t.one(`select * from ai_department_handover_propose($1, 'education', '  ')`, [c])),
    /handover_reason_required/,
  );
  const first = await su(() => t.one(`select * from ai_department_handover_propose($1, 'education', '수업 운영 이야기')`, [c]));
  const second = await su(() => t.one(`select * from ai_department_handover_propose($1, 'product', '문항 난이도 이야기')`, [c]));
  assert.equal(second.kind, 'handover_department');
  assert.deepEqual(second.preview, {
    title: '넘김',
    from_department: 'lead',
    to_department: 'product',
    reason: '문항 난이도 이야기',
  });
  const old = await su(() => t.one(`select status, superseded from ai_actions where id = $1`, [first.id]));
  assert.deepEqual(old, { status: 'rejected', superseded: true });

  const applied = await su(() => t.one(`select * from ai_action_apply($1, '{}'::jsonb)`, [second.id]));
  assert.equal(applied.status, 'applied');
  assert.equal(applied.result.to_department, 'product');
  assert.equal(applied.result.unfiled, true);
  assert.equal(await roleOf(c), 'product');
  assert.equal(await nodeOf(c), undefined);

  const again = await su(() => t.one(`select * from ai_department_handover_propose($1, 'engineering', '구현')`, [c]));
  await su(() => t.one(`select ai_conversation_set_think_role($1, 'engineering', '{}'::text[], null)`, [c]));
  await assert.rejects(() => su(() => t.one(`select * from ai_action_apply($1, '{}'::jsonb)`, [again.id])), /handover_same_department/);
  await t.asUser(() => t.rejects(`select ai_department_handover_propose($1, 'lead', 'x')`, [c], /forbidden/));
});

test('Think의 새 폴더 배치 제안은 대화 부서의 폴더를 만든다', async () => {
  const c = await newConv('배치', 'engineering');
  const action = (
    await su(() =>
      t.one(`select * from ai_action_propose($1, 'place_conversation', $2::jsonb)`, [
        c,
        JSON.stringify({ new_folder_title: '개발 새 폴더' }),
      ]),
    )
  ).id;
  const applied = await su(() => t.one(`select * from ai_action_apply($1, '{}'::jsonb)`, [action]));
  assert.equal(await deptOf(applied.result.created_folder_id), 'engineering');
});
