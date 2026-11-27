// 이미 있는 개념 유형으로만 표기를 바꾼다. 새 유형은 만들지 않는다.
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { insertConcept, openConceptTestDb, seedConcepts } from '../concept_fixture.mjs';

let t;
let S;
let root;

before(async () => {
  t = await openConceptTestDb();
  S = await seedConcepts(t);
  root = (await t.one(`insert into concept_categories (name, code, depth, sort_order) values ('대수', 'ALG', 0, 1) returning id`)).id;
});
after(() => t?.close());

const op = (fn) => t.asSuperadmin(fn, S.operator);

test('운영자는 있던 유형으로만 바꾸고, 없는 유형·다른 사람·직접 쓰기는 막는다', async () => {
  const id = await insertConcept(t, '소수 뜻', root, '1과 자신만으로 나누어지는 수');
  await op(() => t.one(`select concept_set_type($1::uuid, '주의')`, [id]));
  const link = await t.one(
    `select t.name, c.kind, c.sub_type
       from concepts c
       join concept_type_links l on l.concept_id = c.id
       join concept_types t on t.id = l.type_id
      where c.id = $1::uuid`,
    [id],
  );
  assert.equal(link.name, '주의');
  assert.equal(link.kind, 'theorem');
  assert.equal(link.sub_type, '정리');

  await op(() => t.one(`select concept_set_type($1::uuid, '정의')`, [id]));
  const again = await t.one(`select kind, sub_type from concepts where id = $1::uuid`, [id]);
  assert.equal(again.kind, 'definition');
  assert.equal(again.sub_type, '정의');
  assert.equal((await t.all(`select concept_id from concept_type_links where concept_id = $1::uuid`, [id])).length, 1);

  await op(() => t.rejects(`select concept_set_type($1::uuid, '새유형')`, [id], /concept_type_unknown/));
  assert.equal((await t.one(`select kind from concepts where id = $1::uuid`, [id])).kind, 'definition');

  await t.asUser(() => t.rejects(`select concept_set_type($1::uuid, '주의')`, [id], /concept_type_forbidden/));
  await op(() => t.rejects(
    `insert into concept_type_links (concept_id, type_id) select $1::uuid, id from concept_types where name = '주의'`,
    [id],
    /permission denied/,
  ));
});
