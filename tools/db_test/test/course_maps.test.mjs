// 기준 과정 탐색도: 초기 자료, 저장·되살리기, 순서·부모 무결성, 낡은 판 막기, 권한, 다시 실행.
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { migrationsDir, openAiTestDb } from '../harness.mjs';

const FILE = '20261023100000_course_maps.sql';
const OP = '00000000-0000-4000-8000-0000000000c1';

const SEEDED = [
  ['1-1', 'M1-1', '중', [3, 6, 15]],
  ['1-2', 'M1-2', '중', [4, 7, 19]],
  ['2-1', 'M2-1', '중', [3, 6, 16]],
  ['2-2', 'M2-2', '중', [3, 7, 18]],
  ['3-1', 'M3-1', '중', [3, 7, 17]],
  ['3-2', 'M3-2', '중', [3, 6, 12]],
  ['공통수학1', 'H1-c1', '고', [4, 11, 35]],
  ['공통수학2', 'H1-c2', '고', [3, 10, 33]],
  ['대수', 'H-algebra', '고', [3, 10, 32]],
  ['미적분1', 'H-calc1', '고', [3, 7, 25]],
  ['확률과 통계', 'H-probstats', '고', [3, 6, 22]],
  ['미적분2', 'H-calc2', '고', [3, 9, 35]],
  ['기하', 'H-geometry', '고', [3, 7, 31]],
];

let t;

before(async () => {
  t = await openAiTestDb({ files: [FILE] });
  await t.exec(`insert into auth.users (id) values ('${OP}')`);
});
after(() => t?.close());

const arr = (ids) => `{${ids.join(',')}}`;
const op = (sql, params = []) => t.asSuperadmin(() => t.one(sql, params), OP);
const opRejects = (sql, params, pattern) => t.asSuperadmin(() => t.rejects(sql, params, pattern), OP);
const list = async () => (await op(`select course_maps_list() as r`)).r;
const get = async (id) => (await op(`select course_map_get($1::uuid) as r`, [id])).r;
const courseByName = async (name) => (await list()).find((c) => c.name === name);

const SAVE = `select course_map_save($1::uuid, $2::int, $3::jsonb, $4::jsonb, $5::uuid[]) as r`;
const payload = (units) => JSON.stringify(units.map((u) => ({ id: u.id, parent_id: u.parent_id, name: u.name })));
const saveParams = (map, units, archive = [], course = {}) => [
  map.course.id,
  map.course.version,
  JSON.stringify({
    name: map.course.name,
    school_level: map.course.school_level,
    curriculum_code: map.course.curriculum_code,
    ...course,
  }),
  payload(units),
  arr(archive),
];
const save = async (map, units, archive, course) => (await op(SAVE, saveParams(map, units, archive, course))).r;

const childrenOf = (units, parentId) => units.filter((u) => u.parent_id === parentId);

// 살아 있는 단원: 같은 부모 안 순서가 0부터 빈칸·겹침 없이, 부모는 같은 과정의 살아 있는 단원, 깊이는 부모 + 1.
async function assertIntegrity() {
  const gaps = await t.all(`
    select course_id, parent_id, array_agg(sort_order order by sort_order) as orders
      from course_map_units where archived_at is null
     group by course_id, parent_id`);
  for (const g of gaps) {
    assert.deepEqual(g.orders, g.orders.map((_, i) => i), `순서 빈칸: ${g.course_id}/${g.parent_id}`);
  }
  const bad = await t.all(`
    select u.id from course_map_units u
      left join course_map_units p on p.id = u.parent_id
     where u.archived_at is null and (
       (u.parent_id is null and u.depth <> 1)
       or (u.parent_id is not null and (p.id is null or p.course_id <> u.course_id or p.archived_at is not null
           or u.depth <> p.depth + 1))
     )`);
  assert.deepEqual(bad, []);
}

const snapshot = async (courseId) =>
  t.all(
    `select id, parent_id, depth, name, sort_order, archived_at from course_map_units where course_id = $1::uuid order by id`,
    [courseId],
  );

test('초기 자료: 13개 과정·450개 단원이 목록 순서·이름·계층 그대로 들어간다', async () => {
  const courses = await list();
  assert.deepEqual(
    courses.map((c) => [c.name, c.course_key, c.school_level, c.counts]),
    SEEDED,
  );
  assert.ok(courses.every((c) => c.curriculum_code === 'rev_2022' && c.seeded && c.version === 1 && !c.archived_at));
  assert.deepEqual(courses.map((c) => c.sort_order), SEEDED.map((_, i) => i));
  assert.equal((await t.one(`select count(*)::int as n from course_map_units`)).n, 450);
  assert.equal((await t.one(`select count(*)::int as n from course_map_revisions where action = 'seed'`)).n, 13);
  await assertIntegrity();

  const m11 = await get(courses[0].id);
  assert.deepEqual(childrenOf(m11.units, null).map((u) => u.name), ['수와 연산', '문자와 식', '좌표평면과 그래프']);
  const first = childrenOf(m11.units, null)[0];
  assert.deepEqual(childrenOf(m11.units, first.id).map((u) => u.name), ['소인수분해', '정수와 유리수']);
  assert.deepEqual(
    childrenOf(m11.units, childrenOf(m11.units, first.id)[0].id).map((u) => u.name),
    ['소인수분해', '최대공약수와 최소공배수'],
  );
  // 위에서 아래로 늘어놓은 순서: 대단원 다음에 그 중단원, 그 소단원.
  assert.deepEqual(m11.units.slice(0, 4).map((u) => u.depth), [1, 2, 3, 3]);
  assert.deepEqual(m11.archived, []);
});

test('권한: 운영자가 아니면 읽기·쓰기 모두 막히고, 표에 직접 쓸 수 없고, 초기 자료 함수는 부를 수 없다', async () => {
  const id = (await t.one(`select id from course_maps order by sort_order limit 1`)).id;
  await t.asUser(async () => {
    await t.rejects(`select course_maps_list()`, [], /course_map_forbidden/);
    await t.rejects(`select course_map_get($1::uuid)`, [id], /course_map_forbidden/);
    await t.rejects(`select course_map_create('x', '중', null)`, [], /course_map_forbidden/);
    assert.equal((await t.all(`select id from course_maps`)).length, 0);
    await t.rejects(`insert into course_maps (name, school_level, sort_order) values ('x', '중', 99)`, [], /permission denied/);
    await t.rejects(`update course_map_units set name = 'x'`, [], /permission denied/);
    await t.rejects(`delete from course_map_revisions`, [], /permission denied/);
  });
  await t.asAnon(async () => {
    await t.rejects(`select course_maps_list()`, [], /permission denied/);
    await t.rejects(`select id from course_maps`, [], /permission denied/);
  });
  await t.asSuperadmin(async () => {
    await t.rejects(`select course_map_seed('[]'::jsonb)`, [], /permission denied/);
    await t.rejects(`update course_maps set name = 'x'`, [], /permission denied/);
    assert.equal((await t.all(`select id from course_maps`)).length, 13);
  }, OP);
  // 로그인 없이 슈퍼관리자 표시만 있는 경우도 막는다.
  await t.asSuperadmin(() => t.rejects(`select course_maps_list()`, [], /course_map_forbidden/));
});

test('저장: 이름 바꾸기·같은 부모 안 순서·새 단원·다른 중단원으로 옮기기가 한 번에 저장되고 id가 유지된다', async () => {
  const map = await get((await courseByName('1-2')).id);
  const before = map.units.map((u) => ({ ...u }));
  const units = map.units.map((u) => ({ ...u }));
  const l1 = childrenOf(units, null);
  const l2a = childrenOf(units, l1[0].id)[0];
  const l2b = childrenOf(units, l1[0].id)[1] ?? childrenOf(units, l1[1].id)[0];
  const [s0, s1] = childrenOf(units, l2a.id);

  // 이름
  s0.name = '바꾼 이름';
  // 같은 부모 안에서 s1을 s0 앞으로
  const i0 = units.indexOf(s0);
  const i1 = units.indexOf(s1);
  [units[i0], units[i1]] = [units[i1], units[i0]];
  // 새 대단원과 그 아래 중단원
  const n1 = { id: randomUUID(), parent_id: null, name: '새 대단원' };
  const n2 = { id: randomUUID(), parent_id: n1.id, name: '새 중단원' };
  units.push(n1, n2);
  // 소단원 하나를 다른 중단원 맨 끝으로
  const moved = childrenOf(units, l2a.id).at(-1);
  units.splice(units.indexOf(moved), 1);
  moved.parent_id = l2b.id;
  units.push(moved);

  const saved = await save(map, units);
  assert.equal(saved.course.version, 2);

  const again = await get(map.course.id);
  assert.deepEqual(again, saved);
  const byId = new Map(again.units.map((u) => [u.id, u]));
  for (const u of before) assert.ok(byId.has(u.id), `id 유지: ${u.name}`);
  assert.equal(byId.get(s0.id).name, '바꾼 이름');
  const l2aKids = childrenOf(again.units, l2a.id);
  assert.equal(l2aKids[0].id, s1.id);
  assert.equal(l2aKids[1].id, s0.id);
  assert.ok(!l2aKids.some((u) => u.id === moved.id));
  assert.equal(childrenOf(again.units, l2b.id).at(-1).id, moved.id);
  assert.equal(byId.get(moved.id).depth, 3);
  assert.equal(byId.get(n1.id).depth, 1);
  assert.equal(byId.get(n2.id).depth, 2);
  assert.equal(childrenOf(again.units, null).at(-1).id, n1.id);
  assert.equal(again.units.length, before.length + 2);
  await assertIntegrity();

  const rev = await t.one(
    `select action, version, jsonb_array_length(snapshot->'units') as n from course_map_revisions
      where course_id = $1::uuid order by version desc limit 1`,
    [map.course.id],
  );
  assert.deepEqual(rev, { action: 'save', version: 2, n: before.length + 2 });
});

test('저장: 과정 이름·학교급·교육과정 코드를 함께 바꾼다', async () => {
  const map = await get((await courseByName('2-1')).id);
  const saved = await save(map, map.units, [], { name: '중2-1', curriculum_code: null });
  assert.equal(saved.course.name, '중2-1');
  assert.equal(saved.course.curriculum_code, null);
  assert.equal(saved.course.course_key, 'M2-1');
  await opRejects(SAVE, saveParams(saved, saved.units, [], { name: ' ' }), /course_map_bad_name/);
  await opRejects(SAVE, saveParams(saved, saved.units, [], { school_level: '대' }), /course_map_bad_level/);
  await opRejects(SAVE, saveParams(saved, saved.units, [], { curriculum_code: 'rev_2030' }), /course_map_bad_curriculum/);
});

test('낡은 판으로 저장하면 막고, 먼저 저장한 내용을 덮지 않는다', async () => {
  const map = await get((await courseByName('2-2')).id);
  const mine = map.units.map((u) => ({ ...u }));
  mine[0].name = '먼저 저장';
  await save(map, mine);
  const theirs = map.units.map((u) => ({ ...u }));
  theirs[0].name = '나중 저장';
  await opRejects(SAVE, saveParams(map, theirs), /course_map_stale/);
  assert.equal((await get(map.course.id)).units[0].name, '먼저 저장');
});

test('잘못된 저장은 모두 막히고 아무것도 바뀌지 않는다', async () => {
  const other = await get((await courseByName('3-1')).id);
  const map = await get((await courseByName('3-2')).id);
  const before = await snapshot(map.course.id);
  const units = () => map.units.map((u) => ({ ...u }));
  const l1 = childrenOf(map.units, null);
  const l2 = childrenOf(map.units, l1[0].id)[0];
  const l3 = childrenOf(map.units, l2.id)[0];
  const cases = [
    // 빠진 단원(보관 목록에도 없음)
    [units().slice(1), [], /course_map_unit_missing/],
    // 순환: 대단원을 자기 소단원 아래로
    [units().map((u) => (u.id === l1[0].id ? { ...u, parent_id: l3.id } : u)), [], /course_map_cycle/],
    // 자기 자신을 부모로
    [units().map((u) => (u.id === l2.id ? { ...u, parent_id: l2.id } : u)), [], /course_map_cycle/],
    // 소단원 아래 단원
    [[...units(), { id: randomUUID(), parent_id: l3.id, name: '네 번째 단계' }], [], /course_map_too_deep/],
    // 중단원(자식 있음)을 소단원 아래로 → 깊이 4
    [units().map((u) => (u.id === l2.id ? { ...u, parent_id: childrenOf(map.units, childrenOf(map.units, l1[1].id)[0].id)[0].id } : u)), [], /course_map_too_deep/],
    // 보내지 않은 부모
    [[...units(), { id: randomUUID(), parent_id: randomUUID(), name: '부모 없음' }], [], /course_map_bad_parent/],
    // 다른 과정의 단원
    [[...units(), { ...other.units[0], parent_id: null }], [], /course_map_unit_foreign/],
    // 같은 id 두 번
    [[...units(), units()[0]], [], /course_map_bad_units/],
    // 빈 이름
    [units().map((u, i) => (i === 0 ? { ...u, name: '  ' } : u)), [], /course_map_bad_name/],
    // 보관하면서 보내기
    [units(), [l2.id], /course_map_unit_conflict/],
    // 다른 과정의 단원 보관
    [units(), [other.units[0].id], /course_map_unit_not_found/],
  ];
  for (const [u, archive, pattern] of cases) {
    await opRejects(SAVE, saveParams(map, u, archive), pattern);
  }
  await opRejects(SAVE, [map.course.id, map.course.version, '{}', '{"a":1}', '{}'], /course_map_bad_units/);
  await opRejects(SAVE, [map.course.id, map.course.version, '{}', '[{"id":"x","name":"a"}]', '{}'], /course_map_bad_units/);
  assert.deepEqual(await snapshot(map.course.id), before);
  assert.equal((await get(map.course.id)).course.version, map.course.version);
});

test('보관: 아래 단원까지 함께 숨기고, 되살리면 같은 id로 부모 맨 끝에 붙는다', async () => {
  const map = await get((await courseByName('공통수학1')).id);
  const l1 = childrenOf(map.units, null)[0];
  const l2s = childrenOf(map.units, l1.id);
  const target = l2s[0];
  const kids = childrenOf(map.units, target.id);
  const keep = map.units.filter((u) => u.id !== target.id && u.parent_id !== target.id);

  const saved = await save(map, keep, [target.id]);
  assert.equal(saved.units.length, map.units.length - 1 - kids.length);
  assert.deepEqual(childrenOf(saved.units, l1.id).map((u) => u.id), l2s.slice(1).map((u) => u.id));
  assert.equal(saved.archived.length, 1);
  assert.deepEqual(saved.archived[0], {
    ...saved.archived[0],
    id: target.id,
    name: target.name,
    count: 1 + kids.length,
    path: [l1.name],
    parent_active: true,
  });
  await assertIntegrity();

  // 보관한 단원은 저장 내용에 넣을 수 없다(되살리기로만).
  await opRejects(SAVE, saveParams(saved, [...saved.units, target]), /course_map_unit_archived/);

  // 낡은 판으로 되살리기는 막는다.
  const RESTORE = `select course_map_unit_restore($1::uuid, $2::int, $3::uuid) as r`;
  await opRejects(RESTORE, [map.course.id, map.course.version, target.id], /course_map_stale/);
  await opRejects(RESTORE, [map.course.id, saved.course.version, kids[0].id], /course_map_parent_archived/);
  await opRejects(RESTORE, [map.course.id, saved.course.version, l1.id], /course_map_unit_not_found/);

  const back = (await op(RESTORE, [map.course.id, saved.course.version, target.id])).r;
  assert.equal(back.course.version, saved.course.version + 1);
  assert.deepEqual(back.archived, []);
  assert.deepEqual(childrenOf(back.units, l1.id).map((u) => u.id), [...l2s.slice(1), target].map((u) => u.id));
  assert.deepEqual(childrenOf(back.units, target.id).map((u) => u.id), kids.map((u) => u.id));
  await assertIntegrity();
});

test('보관: 같은 저장에서 다른 곳으로 옮긴 아래 단원은 함께 보관하지 않는다', async () => {
  const map = await get((await courseByName('미적분1')).id);
  const [a, b] = childrenOf(map.units, null);
  const [moved, ...rest] = childrenOf(map.units, a.id);
  const movedKids = childrenOf(map.units, moved.id);
  const restIds = new Set(rest.flatMap((u) => [u.id, ...childrenOf(map.units, u.id).map((k) => k.id)]));
  const units = map.units
    .filter((u) => u.id !== a.id && !restIds.has(u.id) && u.id !== moved.id && u.parent_id !== moved.id)
    .map((u) => ({ ...u }));
  units.push({ ...moved, parent_id: b.id }, ...movedKids);
  const saved = await save(map, units, [a.id]);
  assert.equal(childrenOf(saved.units, b.id).at(-1).id, moved.id);
  assert.deepEqual(childrenOf(saved.units, moved.id).map((u) => u.id), movedKids.map((u) => u.id));
  assert.deepEqual(saved.archived.map((x) => [x.id, x.count]), [[a.id, 1 + restIds.size]]);
  await assertIntegrity();
});

test('보관: 따로 보관한 아래 단원은 부모를 되살려도 보관 상태로 남는다', async () => {
  const map = await get((await courseByName('공통수학2')).id);
  const l2 = childrenOf(map.units, childrenOf(map.units, null)[0].id)[0];
  const [k0, ...restKids] = childrenOf(map.units, l2.id);
  const s1 = await save(map, map.units.filter((u) => u.id !== k0.id), [k0.id]);
  const s2 = await save(s1, s1.units.filter((u) => u.id !== l2.id && u.parent_id !== l2.id), [l2.id]);
  assert.deepEqual(new Set(s2.archived.map((a) => a.id)), new Set([l2.id, k0.id]));
  assert.equal(s2.archived.find((a) => a.id === k0.id).parent_active, false);
  assert.equal(s2.archived.find((a) => a.id === l2.id).count, 1 + restKids.length);

  const back = (await op(`select course_map_unit_restore($1::uuid, $2::int, $3::uuid) as r`, [map.course.id, s2.course.version, l2.id])).r;
  assert.deepEqual(childrenOf(back.units, l2.id).map((u) => u.id), restKids.map((u) => u.id));
  assert.deepEqual(back.archived.map((a) => [a.id, a.parent_active]), [[k0.id, true]]);
  await assertIntegrity();
});

test('되살리기: 보관 뒤 부모의 깊이가 바뀌면 지금 부모 기준으로 맞추고, 4단계가 되면 막는다', async () => {
  const RESTORE = `select course_map_unit_restore($1::uuid, $2::int, $3::uuid) as r`;
  const moveTo = (units, id, parentId) => {
    const copy = units.map((u) => ({ ...u }));
    const m = copy.find((u) => u.id === id);
    copy.splice(copy.indexOf(m), 1);
    m.parent_id = parentId;
    copy.push(m);
    return copy;
  };
  const map = await get((await courseByName('대수')).id);
  const [a, b] = childrenOf(map.units, null);
  const [p, q] = childrenOf(map.units, a.id);
  const pKids = childrenOf(map.units, p.id);
  const qKids = childrenOf(map.units, q.id);

  // p의 소단원을 모두 보관하고 p를 대단원으로 올린다 → 되살린 소단원은 깊이 2.
  const s1 = await save(map, map.units.filter((u) => u.parent_id !== p.id), pKids.map((u) => u.id));
  const s2 = await save(s1, moveTo(s1.units, p.id, null));
  assert.equal(s2.units.find((u) => u.id === p.id).depth, 1);
  const back = (await op(RESTORE, [map.course.id, s2.course.version, pKids[0].id])).r;
  const restored = back.units.find((u) => u.id === pKids[0].id);
  assert.equal(restored.parent_id, p.id);
  assert.equal(restored.depth, 2);
  await assertIntegrity();

  // q의 소단원을 모두 보관하고 q를 다른 중단원 아래 소단원으로 내린다 → 되살리면 4단계라 막는다.
  const target = childrenOf(back.units, b.id)[0];
  const s3 = await save(back, back.units.filter((u) => u.parent_id !== q.id), qKids.map((u) => u.id));
  const s4 = await save(s3, moveTo(s3.units, q.id, target.id));
  assert.equal(s4.units.find((u) => u.id === q.id).depth, 3);
  await opRejects(RESTORE, [map.course.id, s4.course.version, qKids[0].id], /course_map_too_deep/);
  assert.equal((await get(map.course.id)).course.version, s4.course.version);
});

test('과정: 만들기·순서 바꾸기·보관·되살리기, 낡은 순서는 막는다', async () => {
  const created = (await op(`select course_map_create($1, $2, $3) as r`, ['중등 심화', '중', null])).r;
  assert.equal(created.course.version, 1);
  assert.equal(created.course.seeded, false);
  assert.deepEqual(created.units, []);
  await opRejects(`select course_map_create($1, $2, $3)`, ['', '중', null], /course_map_bad_name/);

  let courses = await list();
  assert.equal(courses.at(-1).id, created.course.id);
  const ids = courses.map((c) => c.id);
  const reversed = [...ids].reverse();
  const REORDER = `select course_maps_reorder($1::uuid[], $2::uuid[]) as r`;
  await opRejects(REORDER, [arr(reversed), arr(ids)], /course_map_list_stale/);
  await opRejects(REORDER, [arr(ids), arr(ids.slice(1))], /course_map_bad_order/);
  await opRejects(REORDER, [arr(ids), arr([...ids.slice(1), ids[1]])], /course_map_bad_order/);
  courses = (await op(REORDER, [arr(ids), arr(reversed)])).r;
  assert.deepEqual(courses.map((c) => c.id), reversed);
  assert.deepEqual(courses.map((c) => c.sort_order), reversed.map((_, i) => i));

  // 새 과정에 단원 저장
  const n1 = { id: randomUUID(), parent_id: null, name: '대단원' };
  const n2 = { id: randomUUID(), parent_id: n1.id, name: '중단원' };
  const n3 = { id: randomUUID(), parent_id: n2.id, name: '소단원' };
  const filled = await save(created, [n1, n2, n3]);
  assert.deepEqual(filled.units.map((u) => [u.id, u.depth, u.sort_order]), [[n1.id, 1, 0], [n2.id, 2, 0], [n3.id, 3, 0]]);

  await opRejects(`select course_map_archive($1::uuid, $2::int)`, [created.course.id, 1], /course_map_stale/);
  courses = (await op(`select course_map_archive($1::uuid, $2::int) as r`, [created.course.id, filled.course.version])).r;
  const archived = courses.at(-1);
  assert.equal(archived.id, created.course.id);
  assert.ok(archived.archived_at);
  assert.deepEqual(courses.filter((c) => !c.archived_at).map((c) => c.sort_order), reversed.slice(0, -1).map((_, i) => i));
  await opRejects(SAVE, saveParams((await get(created.course.id)), filled.units), /course_map_archived/);
  assert.equal((await t.one(`select count(*)::int as n from course_map_units where course_id = $1::uuid`, [created.course.id])).n, 3);

  courses = (await op(`select course_map_restore($1::uuid) as r`, [created.course.id])).r;
  assert.equal(courses.at(-1).id, created.course.id);
  assert.equal(courses.at(-1).archived_at, null);
  assert.deepEqual(courses.map((c) => c.sort_order), courses.map((_, i) => i));
  await opRejects(`select course_map_restore($1::uuid)`, [created.course.id], /course_map_not_found/);
  assert.deepEqual((await get(created.course.id)).units.map((u) => u.id), [n1.id, n2.id, n3.id]);
});

test('DB 검사: RPC를 거치지 않은 잘못된 부모·깊이는 거래 끝에서 막힌다', async () => {
  const [a, b] = await t.all(`select id from course_maps where seed_key is not null order by sort_order limit 2`);
  const foreignParent = (await t.one(
    `select id from course_map_units where course_id = $1::uuid and depth = 1 and archived_at is null limit 1`,
    [b.id],
  )).id;
  await t.rejects(
    `insert into course_map_units (course_id, parent_id, depth, name, sort_order) values ($1::uuid, $2::uuid, 2, 'x', 999)`,
    [a.id, foreignParent],
    /course_map_bad_parent/,
  );
  const l1 = (await t.one(
    `select id from course_map_units where course_id = $1::uuid and depth = 1 and archived_at is null limit 1`,
    [a.id],
  )).id;
  await t.rejects(
    `insert into course_map_units (course_id, parent_id, depth, name, sort_order) values ($1::uuid, $2::uuid, 3, 'x', 999)`,
    [a.id, l1],
    /course_map_bad_parent/,
  );
  await t.rejects(`update course_map_units set archived_at = now() where id = $1::uuid`, [l1], /course_map_bad_parent/);
});

test('마이그레이션을 다시 실행해도 과정·단원이 늘거나 고친 내용이 덮이지 않는다', async () => {
  const before = await t.all(`select id, name, version, sort_order, archived_at from course_maps order by id`);
  const unitsBefore = await t.all(`select id, parent_id, name, sort_order, archived_at from course_map_units order by id`);
  const revisions = (await t.one(`select count(*)::int as n from course_map_revisions`)).n;
  await t.exec(readFileSync(join(migrationsDir, FILE), 'utf8'));
  assert.deepEqual(await t.all(`select id, name, version, sort_order, archived_at from course_maps order by id`), before);
  assert.deepEqual(await t.all(`select id, parent_id, name, sort_order, archived_at from course_map_units order by id`), unitsBefore);
  assert.equal((await t.one(`select count(*)::int as n from course_map_revisions`)).n, revisions);
  assert.equal((await t.one(`select name from course_maps where course_key = 'M2-1'`)).name, '중2-1');

  // 같은 seed 가 있으면 내용이 달라도 건너뛴다.
  const n = (await t.one(`select course_map_seed('[{"seed":"roadmap:M1-1","course_key":"M1-1","name":"1-1","school_level":"중","units":[]}]'::jsonb) as n`)).n;
  assert.equal(n, 0);
});
