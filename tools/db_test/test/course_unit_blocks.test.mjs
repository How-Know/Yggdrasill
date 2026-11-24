// 교육과정 흐름 소단원 내 가르치는 단위(수업 블록, course_unit_blocks):
// 블록 생성·이름 수정·순서 변경·개념 소속 이동·블록 삭제 시 개념 유지·다른 단원 이동 시 자동 해제·권한·멱등성 검증.
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { insertConcept, openConceptTestDb, seedConcepts } from '../concept_fixture.mjs';
import { migrationsDir } from '../harness.mjs';

let t;
let S;

before(async () => {
  t = await openConceptTestDb();
  S = await seedConcepts(t);
});
after(() => t?.close());

const op = (sql, params = []) => t.asSuperadmin(() => t.one(sql, params), S.operator);
const opRejects = (sql, params, pattern) => t.asSuperadmin(() => t.rejects(sql, params, pattern), S.operator);
const arr = (ids) => `{${ids.join(',')}}`;

const courseByName = async (name) => (await op(`select course_maps_list() as r`)).r.find((c) => c.name === name);
const getMap = async (id) => (await op(`select course_map_get($1::uuid) as r`, [id])).r;
const blocks = async (courseId) => (await op(`select course_map_blocks($1::uuid) as r`, [courseId])).r;
const placements = async (courseId) => (await op(`select course_map_placements($1::uuid) as r`, [courseId])).r;

test('가르치는 단위(블록) 생성·이름 수정·블록 순서 변경·개념 소속 이동·해제가 원자개념 손실 없이 동작한다', async () => {
  const m11 = await courseByName('1-1');
  const map = await getMap(m11.id);
  const leaves = map.units.filter((u) => u.depth === 3);
  const unitA = leaves[0];
  const unitB = leaves[1];

  const cPrime = S.concept; // '소수'
  const cComp = S.concept2; // '합성수'
  const cPow = await insertConcept(t, '거듭제곱', S.folder);
  const cFact = await insertConcept(t, '소인수분해', S.folder);

  // 1) 단원에 원자개념 3개 먼저 배치
  const initial = (await op(`select course_placement_add($1::uuid, $2::uuid[]) as r`, [unitA.id, arr([cPrime, cComp, cPow])])).r;
  const inUnitA = initial.filter((p) => p.unit_id === unitA.id);
  assert.equal(inUnitA.length, 3);
  assert.ok(inUnitA.every((p) => p.block_id === null));

  // 2) 첫 두 개념을 묶으면서 '소수와 합성수' 블록 생성 + 빈 블록 '거듭제곱과 소인수분해' 생성
  const created1 = (
    await op(`select course_unit_block_create($1::uuid, $2, $3::uuid[]) as r`, [
      unitA.id,
      '  소수와 합성수  ',
      arr([inUnitA[0].id, inUnitA[1].id]),
    ])
  ).r;
  assert.ok(created1.block_id);
  assert.equal(created1.blocks.length, 1);
  assert.equal(created1.blocks[0].name, '소수와 합성수');
  assert.equal(created1.blocks[0].sort, 0);

  const created2 = (
    await op(`select course_unit_block_create($1::uuid, $2, null) as r`, [unitA.id, '거듭제곱과 소인수분해'])
  ).r;
  const block1Id = created1.block_id;
  const block2Id = created2.block_id;
  assert.deepEqual(
    created2.blocks.map((b) => [b.name, b.sort]),
    [
      ['소수와 합성수', 0],
      ['거듭제곱과 소인수분해', 1],
    ],
  );

  // 3) 블록에 개념 추가(이미 단원에 있던 거듭제곱 + 새 개념 소인수분해 동시 투입)
  await op(`select course_unit_block_add_concepts($1::uuid, $2::uuid[]) as r`, [block2Id, arr([cPow, cFact])]);
  let ps = (await placements(m11.id)).filter((p) => p.unit_id === unitA.id);
  assert.equal(ps.length, 4);
  assert.deepEqual(
    ps.filter((p) => p.block_id === block1Id).map((p) => p.name),
    ['소수', '합성수'],
  );
  assert.deepEqual(
    ps.filter((p) => p.block_id === block2Id).map((p) => p.name),
    ['거듭제곱', '소인수분해'],
  );

  // 4) 블록 이름 직접 수정 및 블록 순서 이동
  const renamed = (await op(`select course_unit_block_rename($1::uuid, $2) as r`, [block1Id, '소수·합성수의 뜻'])).r;
  assert.equal(renamed.find((b) => b.id === block1Id).name, '소수·합성수의 뜻');

  const reorderedBlocks = (
    await op(`select course_unit_blocks_reorder($1::uuid, $2::uuid[]) as r`, [unitA.id, arr([block2Id, block1Id])])
  ).r;
  assert.deepEqual(
    reorderedBlocks.map((b) => [b.id, b.sort]),
    [
      [block2Id, 0],
      [block1Id, 1],
    ],
  );

  // 5) 개념 하나를 블록 밖(미지정)으로 빼면서 단원 내 순서 함께 지정
  const powPlacement = ps.find((p) => p.concept_id === cPow);
  const newOrder = [powPlacement.id, ...ps.filter((p) => p.id !== powPlacement.id).map((p) => p.id)];
  ps = (
    await op(`select course_placement_set_block($1::uuid, null, $2::uuid[]) as r`, [powPlacement.id, arr(newOrder)])
  ).r.filter((p) => p.unit_id === unitA.id);
  assert.equal(ps[0].id, powPlacement.id);
  assert.equal(ps[0].block_id, null);

  // 6) 다른 단원으로 옮기면 이전 단원 블록 소속이 자동으로 해제된다
  const primePlacement = ps.find((p) => p.concept_id === cPrime);
  assert.equal(primePlacement.block_id, block1Id);
  const afterMove = (await op(`select course_placement_move($1::uuid, $2::uuid) as r`, [primePlacement.id, unitB.id])).r;
  const movedPrime = afterMove.find((p) => p.id === primePlacement.id);
  assert.equal(movedPrime.unit_id, unitB.id);
  assert.equal(movedPrime.block_id, null);

  // 7) 다른 단원의 블록을 지정하려 하면 거부된다
  await opRejects(
    `select course_placement_set_block($1::uuid, $2::uuid, null)`,
    [movedPrime.id, block1Id],
    /course_block_unit_mismatch/,
  );

  // 8) 블록을 삭제(해제)하면 블록만 사라지고 안의 원자개념 배치는 단원에 그대로 남는다
  const afterDel = (await op(`select course_unit_block_delete($1::uuid) as r`, [block2Id])).r;
  assert.deepEqual(
    afterDel.blocks.map((b) => [b.id, b.sort]),
    [[block1Id, 0]],
  );
  const factAfterDel = afterDel.placements.find((p) => p.concept_id === cFact);
  assert.equal(factAfterDel.unit_id, unitA.id);
  assert.equal(factAfterDel.block_id, null);
});

test('일반 사용자는 블록 표나 RPC에 접근할 수 없고 마이그레이션 재실행이 안전하다', async () => {
  const m11 = await courseByName('1-1');
  await t.asUser(
    () => t.rejects(`select course_map_blocks($1::uuid)`, [m11.id], /course_map_forbidden/),
    S.user,
  );
  await opRejects(`select course_unit_block_create($1::uuid, '   ', null)`, [(await getMap(m11.id)).units[0].id], /course_block_bad_name/);

  // RPC 없이 직접 unit_block_id 수정 시도 차단
  const map = await getMap(m11.id);
  const leaf = map.units.find((u) => u.depth === 3);
  const cExtra = await insertConcept(t, '직접수정방지개념', S.folder);
  const blk = (await op(`select course_unit_block_create($1::uuid, '보호블록', null) as r`, [leaf.id])).r.block_id;
  const added = (await op(`select course_placement_add($1::uuid, $2::uuid[]) as r`, [leaf.id, arr([cExtra])])).r;
  const pid = added.find((p) => p.concept_id === cExtra).id;
  await opRejects(`update concept_appearances set unit_block_id = $1::uuid where id = $2::uuid`, [blk, pid], /permission denied/);
  await t.rejects(`update concept_appearances set unit_block_id = $1::uuid where id = $2::uuid`, [blk, pid], /course_placement_use_rpc/);

  // 마이그레이션 재실행 멱등성
  const sql = readFileSync(join(migrationsDir, '20261124160000_course_unit_blocks.sql'), 'utf8');
  await t.exec(sql);
  assert.ok(Array.isArray(await blocks(m11.id)));
});
