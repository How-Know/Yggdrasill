// 개념 배치 기록과 최근 변경 목록: 배치의 넣기·옮기기·빼기는 어느 길로 바뀌든 기록되고(순서·글 칸 맞추기는 아님),
// Think 카드로 바뀐 것은 카드 id와 함께 남는다. 최근 변경은 배치 기록·본문 고친 기록·서술 확정 기록을 읽기만 한다.
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { insertConcept, openConceptTestDb, seedConcepts } from '../concept_fixture.mjs';

let t;
let S;
let conv;

before(async () => {
  t = await openConceptTestDb();
  S = await seedConcepts(t);
  conv = (await t.one(`insert into ai_conversations (title) values ('배치 기록') returning id`)).id;
});
after(() => t?.close());

const op = (sql, params = []) => t.asSuperadmin(() => t.one(sql, params), S.operator);
const opExec = (sql) => t.asSuperadmin(() => t.exec(sql), S.operator);
const opRejects = (sql, params, pattern) => t.asSuperadmin(() => t.rejects(sql, params, pattern), S.operator);
const arr = (ids) => `{${ids.join(',')}}`;

const courseByName = async (name) => (await op(`select course_maps_list() as r`)).r.find((c) => c.name === name);
const getMap = async (id) => (await op(`select course_map_get($1::uuid) as r`, [id])).r;
const placements = async (courseId) => (await op(`select course_map_placements($1::uuid) as r`, [courseId])).r;
const add = async (unitId, conceptIds) =>
  (await op(`select course_placement_add($1::uuid, $2::uuid[]) as r`, [unitId, arr(conceptIds)])).r;
const saveMap = (map, units, course = {}) =>
  op(`select course_map_save($1::uuid, $2::int, $3::jsonb, $4::jsonb, $5::uuid[]) as r`, [
    map.course.id,
    map.course.version,
    JSON.stringify(course),
    JSON.stringify(units.map((u) => ({ id: u.id, parent_id: u.parent_id, name: u.name }))),
    '{}',
  ]);
const propose = (kind, payload) =>
  op(`select * from course_think_action_propose($1::uuid, $2, $3::jsonb)`, [conv, kind, JSON.stringify(payload)]);
const apply = (id, overrides = {}) =>
  op(`select * from course_think_action_apply($1::uuid, $2::jsonb)`, [id, JSON.stringify(overrides)]);
const logOf = (conceptId) =>
  t.all(
    `select action, origin, action_id, note, course_name, unit_id, unit_path, from_unit_id, from_path, concept_name, actor
       from course_placement_log where concept_id = $1::uuid order by seq`,
    [conceptId],
  );
const changes = async (args = {}) =>
  (await op(`select course_recent_changes($1::text[], $2::timestamptz, $3, $4) as r`, [
    args.kinds ? arr(args.kinds) : null,
    args.beforeAt ?? null,
    args.beforeKey ?? null,
    args.limit ?? 60,
  ])).r;

async function pick(name) {
  const course = await courseByName(name);
  const map = await getMap(course.id);
  const kids = (id) => map.units.filter((u) => u.parent_id === id);
  const L1 = kids(null)[0];
  const M1 = kids(L1.id)[0];
  return { course, map, L1, M1, S1: kids(M1.id)[0], S2: kids(M1.id)[1] };
}

test('운영자 직접: 넣기·옮기기·빼기와 개념 상세의 줄 빼기는 기록되고, 순서 바꾸기·과정 저장은 기록되지 않는다', async () => {
  const P = await pick('1-1');
  const a = await insertConcept(t, '기록 가', S.folder);
  const b = await insertConcept(t, '기록 나', S.folder);
  let list = await add(P.S1.id, [a, b]);
  const pa = list.find((p) => p.concept_id === a).id;
  const pb = list.find((p) => p.concept_id === b).id;
  const path1 = [P.L1.name, P.M1.name, P.S1.name];
  const path2 = [P.L1.name, P.M1.name, P.S2.name];

  let rows = await logOf(a);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].action, 'add');
  assert.equal(rows[0].origin, 'owner');
  assert.equal(rows[0].action_id, null);
  assert.equal(rows[0].course_name, '1-1');
  assert.equal(rows[0].unit_id, P.S1.id);
  assert.deepEqual(rows[0].unit_path, path1);
  assert.deepEqual(rows[0].from_path, []);
  assert.equal(rows[0].concept_name, '기록 가');
  assert.equal(rows[0].actor, S.operator);

  await op(`select course_placement_reorder($1::uuid, $2::uuid[]) as r`, [P.S1.id, arr([pb, pa])]);
  await op(`select course_placement_move($1::uuid, $2::uuid) as r`, [pa, P.S2.id]);
  rows = await logOf(a);
  assert.deepEqual(rows.map((r) => r.action), ['add', 'move']);
  assert.equal(rows[1].from_unit_id, P.S1.id);
  assert.deepEqual(rows[1].from_path, path1);
  assert.deepEqual(rows[1].unit_path, path2);
  assert.equal((await logOf(b)).length, 1, '순서 바꾸기와 옮긴 뒤 번호 다시 매기기는 기록하지 않는다');

  // 과정을 저장하면 놓인 줄의 글 칸을 다시 맞춘다. 단원이 바뀐 것이 아니라 기록하지 않고, 지난 기록의 경로도 그대로다.
  await saveMap(P.map, P.map.units.map((u) => (u.id === P.M1.id ? { ...u, name: '이름 바꾼 중단원' } : u)));
  assert.equal((await logOf(a)).length, 2);
  assert.deepEqual((await logOf(a))[1].unit_path, path2);

  await op(`select course_placement_remove($1::uuid) as r`, [pb]);
  await op(`delete from concept_appearances where id = $1::uuid returning id`, [pa]);
  const removedB = (await logOf(b)).at(-1);
  assert.equal(removedB.action, 'remove');
  assert.equal(removedB.origin, 'owner');
  assert.equal(removedB.unit_id, null);
  assert.deepEqual(removedB.from_path, [P.L1.name, '이름 바꾼 중단원', P.S1.name]);
  const removedA = (await logOf(a)).at(-1);
  assert.equal(removedA.action, 'remove', '개념 상세에서 뺀 줄도 기록된다');
  assert.equal(removedA.from_unit_id, P.S2.id);

  // 글로 적은 등장 위치는 배치가 아니라 기록하지 않는다.
  await op(
    `insert into concept_appearances (concept_id, school_level, course_label, unit_path) values ($1::uuid, '중', '1-1', '{가}') returning id`,
    [a],
  );
  assert.equal((await logOf(a)).length, 3);

  const back = await getMap(P.course.id);
  await saveMap(back, back.units.map((u) => (u.id === P.M1.id ? { ...u, name: P.M1.name } : u)));
});

test('Think 카드 승인: 넣기·옮기기·빼기가 Think와 카드 id로 남고, 승인이 끝나면 카드 id가 남지 않는다', async () => {
  const P = await pick('1-2');
  const a = await insertConcept(t, '카드 가', S.folder);
  const b = await insertConcept(t, '카드 나', S.folder);
  const act = await propose('concept_placement_change', {
    course_id: P.course.id, reason: '배치',
    items: [
      { op: 'place', concept_id: a, unit_id: P.S1.id, basis: 'judgment', evidence: '이름으로 판단' },
      { op: 'place', concept_id: b, unit_id: P.S1.id, basis: 'judgment', evidence: '이름으로 판단' },
    ],
  });
  assert.equal((await logOf(a)).length, 0, '제안만으로는 기록되지 않는다');
  await apply(act.id);
  let rows = await logOf(a);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].origin, 'ai');
  assert.equal(rows[0].action_id, act.id);
  assert.equal(rows[0].note, '이름으로 판단');

  const list = await placements(P.course.id);
  const mv = await propose('concept_placement_change', {
    course_id: P.course.id, reason: '정리',
    items: [
      { op: 'move', placement_id: list.find((p) => p.concept_id === a).id, unit_id: P.S2.id, evidence: '둘째 소단원' },
      { op: 'remove', placement_id: list.find((p) => p.concept_id === b).id, evidence: '잘못 놓음' },
    ],
  });
  await apply(mv.id);
  rows = await logOf(a);
  assert.deepEqual(rows.map((r) => [r.action, r.origin, r.action_id]), [['add', 'ai', act.id], ['move', 'ai', mv.id]]);
  assert.equal(rows[1].note, '둘째 소단원');
  const removed = (await logOf(b)).at(-1);
  assert.deepEqual([removed.action, removed.origin, removed.action_id], ['remove', 'ai', mv.id]);

  const moved = (await placements(P.course.id)).find((p) => p.concept_id === a);
  await op(`select course_placement_remove($1::uuid) as r`, [moved.id]);
  const last = (await logOf(a)).at(-1);
  assert.deepEqual([last.action, last.origin, last.action_id], ['remove', 'owner', null]);
});

test('최근 변경: 배치·본문·서술을 시각 역순으로, 기록 전 배치는 놓은 시각과 지금 위치만, 종류 거르기와 다음 쪽', async () => {
  const P = await pick('2-1');
  const old = await insertConcept(t, '기록 전 개념', S.folder);
  await t.exec(`alter table concept_appearances disable trigger trg_concept_appearances_placement_log`);
  await add(P.S1.id, [old]);
  await t.exec(`alter table concept_appearances enable trigger trg_concept_appearances_placement_log`);

  const renamed = await insertConcept(t, '예전 이름', S.folder, '예전 본문');
  await opExec(`update concepts set name = '새 이름', content = '새 본문' where id = '${renamed}'`);
  const stated = await insertConcept(t, '서술 개념', S.folder);
  const created = (await op(`select concept_statement_create($1::uuid, 'statement', $2::jsonb) as r`, [
    stated,
    JSON.stringify({ title: '다른 설명', body: '다른 교재의 설명' }),
  ])).r;
  await op(`select concept_statement_confirm($1::uuid, $2::int, $3::timestamptz, $4) as r`, [
    created.id, created.version, created.draft_saved_at, '교재 비교',
  ]);
  const fresh = await insertConcept(t, '새로 놓은 개념', S.folder);
  await add(P.S1.id, [fresh]);

  const all = await changes();
  const at = all.items.map((x) => Date.parse(x.at));
  assert.ok(at.every((x, i) => i === 0 || at[i - 1] >= x), '시각 역순');
  assert.equal(all.items[0].concept_id, fresh, '가장 최근 것이 맨 앞');

  const first = all.items.find((x) => x.concept_id === fresh);
  assert.equal(first.kind, 'placement');
  assert.equal(first.action, 'add');
  assert.equal(first.before_log, false);
  assert.equal(first.course_name, '2-1');
  assert.deepEqual(first.path, [P.L1.name, P.M1.name, P.S1.name]);

  const before = all.items.find((x) => x.concept_id === old);
  assert.equal(before.before_log, true);
  assert.equal(before.action, 'add');
  assert.deepEqual(before.path, [P.L1.name, P.M1.name, P.S1.name]);
  assert.equal(all.items.filter((x) => x.concept_id === old).length, 1);

  const content = all.items.find((x) => x.kind === 'content' && x.concept_id === renamed);
  assert.equal(content.renamed, true);
  assert.equal(content.before_name, '예전 이름');
  assert.equal(content.after_name, '새 이름');
  assert.equal(content.concept_name, '새 이름');
  assert.equal(content.content_changed, true);
  assert.equal(content.via, 'direct');

  const statement = all.items.find((x) => x.kind === 'statement' && x.concept_id === stated);
  assert.equal(statement.role, 'statement');
  assert.equal(statement.title, '다른 설명');
  assert.equal(statement.version, 1);
  assert.equal(statement.note, '교재 비교');
  assert.ok(all.items.every((x) => typeof x.key === 'string' && x.key.length > 2));

  const only = await changes({ kinds: ['statement'] });
  assert.ok(only.items.length >= 1 && only.items.every((x) => x.kind === 'statement'));
  await opRejects(`select course_recent_changes($1::text[])`, ['{relation}'], /course_changes_bad_kinds/);
  await opRejects(`select course_recent_changes($1::text[])`, ['{}'], /course_changes_bad_kinds/);

  const pages = [];
  let page = await changes({ limit: 2 });
  assert.equal(page.items.length, 2);
  assert.equal(page.more, true);
  pages.push(...page.items);
  while (page.more) {
    const lastItem = page.items.at(-1);
    page = await changes({ limit: 2, beforeAt: lastItem.at, beforeKey: lastItem.key });
    pages.push(...page.items);
  }
  assert.deepEqual(pages.map((x) => x.key), all.items.map((x) => x.key), '다음 쪽은 겹치거나 빠지지 않는다');
});

test('기록은 읽기 RPC로만 보이고 개념 지우기를 막지 않는다. 지운 개념은 기록의 이름으로 남는다', async () => {
  await t.asUser(() => t.rejects(`select course_recent_changes()`, [], /course_map_forbidden/), S.user);
  await t.asUser(() => t.rejects(`select count(*) from course_placement_log`, [], /permission denied/), S.operator);

  const P = await pick('2-2');
  const gone = await insertConcept(t, '지울 개념', S.folder);
  const list = await add(P.S1.id, [gone]);
  await op(`select course_placement_remove($1::uuid) as r`, [list.find((p) => p.concept_id === gone).id]);
  const res = await op(`select concept_delete($1::uuid) as r`, [gone]);
  assert.ok(res.r);
  assert.equal((await t.one(`select count(*)::int as n from concepts where id = $1::uuid`, [gone])).n, 0);

  const items = (await changes({ kinds: ['placement'] })).items.filter((x) => x.concept_id === gone);
  assert.deepEqual(items.map((x) => [x.action, x.concept_name]), [['remove', '지울 개념'], ['add', '지울 개념']]);
});
