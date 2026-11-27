// 개념 하나와 그 개념에만 붙은 줄을 지운다. 다른 개념 행은 남는다.
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { insertConcept, openConceptTestDb, seedConcepts } from '../concept_fixture.mjs';

let t;
let S;
let root;

before(async () => {
  t = await openConceptTestDb();
  S = await seedConcepts(t);
  root = (await t.one(`insert into concept_categories (name, code, depth, sort_order) values ('대수', 'ALG2', 0, 2) returning id`)).id;
});
after(() => t?.close());

const op = (fn) => t.asSuperadmin(fn, S.operator);

test('붙은 자료가 있는 개념을 지워도 관계의 다른 개념은 남는다', async () => {
  const gone = await insertConcept(t, '지울 개념', root, '필요 없는 본문');
  const stay = await insertConcept(t, '남을 개념', root, '남는 본문');
  await t.one(
    `insert into concept_relations (concept_id, related_id, kind, origin) values ($1::uuid, $2::uuid, 'extends', 'manual')`,
    [gone, stay],
  );
  await op(() => t.one(`select concept_set_type($1::uuid, '주의')`, [gone]));

  await op(() => t.one(`select concept_force_delete($1::uuid)`, [gone]));

  assert.equal((await t.all(`select id from concepts where id = $1::uuid`, [gone])).length, 0);
  assert.equal((await t.one(`select name from concepts where id = $1::uuid`, [stay])).name, '남을 개념');
  assert.equal((await t.all(`select id from concept_relations where concept_id = $1::uuid or related_id = $1::uuid`, [gone])).length, 0);
  assert.equal((await t.all(`select concept_id from concept_type_links where concept_id = $1::uuid`, [gone])).length, 0);

  await t.asUser(() => t.rejects(`select concept_force_delete($1::uuid)`, [stay], /concept_delete_forbidden/));
  assert.equal((await t.one(`select name from concepts where id = $1::uuid`, [stay])).name, '남을 개념');
});
