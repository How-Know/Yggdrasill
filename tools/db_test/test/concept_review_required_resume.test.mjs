// 반영된 보류가 있으면 최신이 아닌 필수 범위를 다시 연다.
// 의미의 근거 미확인과 이미 충족한 배치는 열지 않고, 이번 보완에서는 개념 단위를 빼 둔다.
// 개념 단위만 다시 볼 때와, 보류가 없는 일반 검수는 그대로다.
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { insertConcept, openConceptTestDb, seedConcepts } from '../concept_fixture.mjs';

let t;
let S;
let conv;

before(async () => {
  t = await openConceptTestDb();
  S = await seedConcepts(t);
  conv = (await t.one(`insert into ai_conversations (title) values ('필수 범위 재개') returning id`)).id;
});
after(() => t?.close());

const op = (sql, params = []) => t.asSuperadmin(() => t.one(sql, params), S.operator);
const r = async (sql, params) => (await op(sql, params)).r;
const arr = (ids) => `{${ids.join(',')}}`;
const walk = (filter) => r(`select concept_review_walk(null, $1::jsonb, 0, 60) as r`, [JSON.stringify(filter)]);
const start = (walkId) => r(`select concept_review_job_start($1::uuid, '필수 범위 재개') as r`, [walkId]);
const claim = async (job) => (await r(`select concept_review_job_claim($1::uuid, 'run', 'take') as r`, [job])).gen;
const targets = (job, gen) => r(`select concept_review_job_targets($1::uuid, $2::bigint, 50) as r`, [job, gen]);
const material = (job, gen, positions) =>
  r(`select concept_review_job_material($1::uuid, $2::bigint, $3::integer[], '{}'::jsonb, 60000) as r`, [job, gen, positions]);
const stateOf = async (id) => (await t.one(
  `select concept_review_job_concept_state($1::uuid, concept_review_pending_concepts()) as r`,
  [id],
)).r;

const courseByName = async (name) => (await r(`select course_maps_list() as r`)).find((c) => c.name === name);
async function units(name) {
  const course = await courseByName(name);
  const map = await r(`select course_map_get($1::uuid) as r`, [course.id]);
  return map.units.filter((u) => u.depth === 3);
}
const place = (unitId, ids) => r(`select course_placement_add($1::uuid, $2::uuid[]) as r`, [unitId, arr(ids)]);

const textMark = async (id) => (await t.one(`select concept_review_marks($1::uuid) ->> 'text' as m`, [id])).m;
const placementMark = async (id) => (await t.one(`select concept_review_marks($1::uuid) ->> 'placement' as m`, [id])).m;

async function putReview(conceptId, scope, outcome, mark, detail = {}) {
  await t.one(
    `insert into concept_quality_reviews (concept_id, scope, outcome, checked, findings, basis, detail, marks, mark)
     values ($1::uuid, $2, $3, $4, '판단 내용', '본문', $5::jsonb, concept_review_marks($1::uuid), $6)
     returning id`,
    [conceptId, scope, outcome, `${scope} 확인`, JSON.stringify(detail), mark],
  );
}

test('반영된 보류가 있으면 표기·기초 개념을 다시 열고, 근거 미확인·충족 배치·개념 단위는 빼 둔다', async () => {
  const F = (await t.one(`insert into concept_categories (name) values ($1) returning id`, [`재개 ${randomUUID().slice(0, 6)}`])).id;
  const leaf = (await units('2-1'))[0].id;
  const ids = [];
  for (let i = 0; i < 3; i++) {
    const id = await insertConcept(t, `재개 개념 ${randomUUID().slice(0, 8)}`, F, `재개 개념 ${i}은 약수를 써서 정의한다.`);
    await t.exec(`insert into concept_sources (concept_id, academy_id, book_id, grade_label, raw_page, display_page, unit_path)
                  values ('${id}', '${S.academy}', '${S.book}', '중2-1', ${40 + i}, ${30 + i}, '{"Ⅰ. 수와 식","1. 유리수"}')`);
    ids.push(id);
  }
  await place(leaf, ids);
  const w = await walk({ folder_id: F });
  const job = (await start(w.walk_id)).job_id;
  const gen = await claim(job);
  const ordered = w.items.map((x) => x.id);

  const applied = (await t.one(
    `insert into ai_actions (conversation_id, kind, status, payload, result, decided_at)
     values ($1::uuid, 'concept_library_change', 'applied', '{}'::jsonb,
             '{"items":[{"i":1,"status":"applied"}]}'::jsonb, now())
     returning id`,
    [conv],
  )).id;
  const hold = (scopes) => JSON.stringify(scopes.map((scope) => ({ scope, deps: [{ action_id: applied, item: 1 }] })));

  const supplement = ordered[0];
  const plain = ordered[1];
  const unitOnly = ordered[2];
  const stale = 'stale-text-mark';
  await putReview(supplement, 'notation', 'no_issue_found', stale);
  await putReview(supplement, 'meaning', 'unverified', await textMark(supplement), { evidence_gaps: ['figure'] });
  await putReview(supplement, 'placement', 'no_issue_found', await placementMark(supplement));
  await putReview(supplement, 'unit', 'no_issue_found', stale);
  await t.one(
    `insert into concept_review_job_items (job_id, pos, concept_id, state, gen, held_fixes, scope_cards)
     values ($1::uuid, 1, $2::uuid, 'submitted', $3, $4::jsonb, '{"notation":{"action_id":"card"},"foundation":{"action_id":"card"}}'::jsonb)
     returning pos`,
    [job, supplement, gen, hold(['meaning', 'unit'])],
  );

  await t.one(
    `insert into concept_review_job_items (job_id, pos, concept_id, state, gen, held_fixes)
     values ($1::uuid, 2, $2::uuid, 'submitted', $3, '[]'::jsonb)
     returning pos`,
    [job, plain, gen],
  );

  const current = await textMark(unitOnly);
  for (const scope of ['notation', 'meaning', 'foundation']) await putReview(unitOnly, scope, 'no_issue_found', current);
  await putReview(unitOnly, 'placement', 'no_issue_found', await placementMark(unitOnly));
  await putReview(unitOnly, 'unit', 'no_issue_found', stale);
  await t.one(
    `insert into concept_review_job_items (job_id, pos, concept_id, state, gen, held_fixes)
     values ($1::uuid, 3, $2::uuid, 'submitted', $3, $4::jsonb)
     returning pos`,
    [job, unitOnly, gen, hold(['meaning', 'unit'])],
  );

  const supplementState = await stateOf(supplement);
  assert.equal(supplementState.scopes.notation.state, 'recheck');
  assert.equal(supplementState.scopes.meaning.state, 'gap');
  assert.equal(supplementState.scopes.foundation.state, 'missing');
  assert.equal(supplementState.scopes.placement.state, 'met');
  assert.equal(supplementState.scopes.unit.state, 'recheck');

  const unitState = await stateOf(unitOnly);
  assert.equal(unitState.scopes.meaning.state, 'met');
  assert.equal(unitState.scopes.unit.state, 'recheck');

  const plainState = await stateOf(plain);
  assert.deepEqual(plainState.todo, ['notation', 'meaning', 'foundation', 'placement']);

  const tg = await targets(job, gen);
  const byPos = new Map(tg.batch.map((b) => [b.position, b]));
  assert.deepEqual(byPos.get(1).todo, ['notation', 'foundation']);
  assert.deepEqual(byPos.get(1).resume_scopes, ['notation', 'foundation']);
  assert.equal(byPos.get(1).supplement, true);
  assert.equal(byPos.get(2).resume_scopes, undefined);
  assert.deepEqual(byPos.get(2).todo, ['notation', 'meaning', 'foundation', 'placement']);
  assert.equal(byPos.get(2).supplement, true);
  assert.deepEqual(byPos.get(3).todo, ['unit']);
  assert.deepEqual(byPos.get(3).resume_scopes, ['unit']);

  const mat = await material(job, gen, [1, 2, 3]);
  const read = new Map(mat.items.map((item) => [item.position, item]));
  assert.deepEqual(read.get(1).resume_scopes, ['notation', 'foundation']);
  assert.deepEqual(read.get(1).todo, ['notation', 'foundation']);
  assert.deepEqual(read.get(2).resume_scopes, []);
  assert.deepEqual(read.get(2).todo, ['notation', 'meaning', 'foundation', 'placement']);
  assert.deepEqual(read.get(3).resume_scopes, ['unit']);
});
