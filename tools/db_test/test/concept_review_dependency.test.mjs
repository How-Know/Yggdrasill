// 수정에 의존하는 검토는 초안으로 보류하고, 다음 검수가 반영 결과를 읽은 뒤 그 범위만 다시 판단한다.
// 반영 실패는 사용자가 뺀 항목과 다르고, 성공한 기록은 남긴다.
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
  conv = (await t.one(`insert into ai_conversations (title) values ('의존 검수') returning id`)).id;
});
after(() => t?.close());

const op = (sql, params = []) => t.asSuperadmin(() => t.one(sql, params), S.operator);
const opRejects = (sql, params, pattern) => t.asSuperadmin(() => t.rejects(sql, params, pattern), S.operator);
const r = async (sql, params) => (await op(sql, params)).r;
const arr = (ids) => `{${ids.join(',')}}`;
const revision = async (id) => (await t.one(`select concept_review_revision(concept_review_marks($1::uuid)) as r`, [id])).r;
const walk = (filter) => r(`select concept_review_walk(null, $1::jsonb, 0, 60) as r`, [JSON.stringify(filter)]);
const start = (walkId) => r(`select concept_review_job_start($1::uuid, '의존 검수') as r`, [walkId]);
const claim = async (job, holder = 'run') => (await r(`select concept_review_job_claim($1::uuid, $2, 'take') as r`, [job, holder])).gen;
const targets = (job, gen, n = 50) => r(`select concept_review_job_targets($1::uuid, $2::bigint, $3) as r`, [job, gen, n]);
const material = (job, gen, positions) =>
  r(`select concept_review_job_material($1::uuid, $2::bigint, $3::integer[], '{}'::jsonb, 60000) as r`, [job, gen, positions]);
const save = (job, gen, items) => r(`select concept_review_job_save($1::uuid, $2::bigint, $3::jsonb) as r`, [job, gen, JSON.stringify(items)]);
const submit = (job, gen) =>
  r(`select concept_review_job_submit($1::uuid, $2::bigint, $3::uuid, '의존 검수 결과', null) as r`, [job, gen, conv]);
const begin = (job, gen) => r(`select concept_review_job_batch_begin($1::uuid, $2::bigint) as r`, [job, gen]);
const status = (job) => r(`select concept_review_job_status_live($1::uuid, 60) as r`, [job]);
const stateOf = async (id) => (await t.one(`select concept_review_job_concept_state($1::uuid, concept_review_pending_concepts()) as r`, [id])).r;
const holdOf = async (job, pos) => (await t.one(
  `select concept_review_job_hold_view(held_fixes) as r from concept_review_job_items where job_id = $1::uuid and pos = $2`,
  [job, pos],
)).r;
const apply = (id, overrides = {}) => op(`select * from course_think_action_apply($1::uuid, $2::jsonb)`, [id, JSON.stringify(overrides)]);
const reject = (id) => op(`select * from ai_action_reject($1::uuid)`, [id]);
const itemRow = (job, pos) => t.one(`select * from concept_review_job_items where job_id = $1::uuid and pos = $2`, [job, pos]);
const cards = (job) => t.all(`select action_id from concept_review_job_cards where job_id = $1::uuid order by created_at`, [job]);

const courseByName = async (name) => (await r(`select course_maps_list() as r`)).find((c) => c.name === name);
async function units(name) {
  const course = await courseByName(name);
  const map = await r(`select course_map_get($1::uuid) as r`, [course.id]);
  return { course, leaves: map.units.filter((u) => u.depth === 3) };
}
const place = (unitId, ids) => r(`select course_placement_add($1::uuid, $2::uuid[]) as r`, [unitId, arr(ids)]);
const placementOf = async (concept) =>
  (await t.one(`select id, course_unit_id from concept_appearances where concept_id = $1::uuid and course_unit_id is not null`, [concept]));

const review = (scope, over = {}) => ({
  scope, outcome: 'no_issue_found', checked: `${scope} 확인`, findings: '이번에 본 범위에서 문제를 찾지 못함', basis: '본문 전체를 읽음',
  unverified: null, follow_up: null, compared_ids: [], to_compare_ids: [], ...over,
});
const foundationOk = (compared = []) => review('foundation', {
  checked: '필요한 초등 기초 개념을 본문과 후보에서 확인',
  findings: '추가할 기초 개념 없음',
  basis: '대상 본문을 읽음',
  compared_ids: compared,
});
const placementOk = () => review('placement', {
  checked: '출처와 지금 배치를 대조', findings: '배치 유지', basis: '출처 메타데이터',
  detail: { basis_kind: 'source', viewed_original: false },
});
const drafted = async (position, concept, reviews, extra = {}) => ({
  position, concept_id: concept, state: 'drafted', revision: await revision(concept), read_complete: true,
  unread: null, reviews, next_action: null, reason: null, rework: false, ...extra,
});

const FOLDER = ['소인수분해', '초등 기초'];
let seq = 0;
async function setup(n) {
  const F = (await t.one(`insert into concept_categories (name) values ($1) returning id`, [`의존 ${randomUUID().slice(0, 6)}`])).id;
  const P = await units('2-1');
  const ids = [];
  for (let i = 0; i < n; i++) {
    seq += 1;
    const id = await insertConcept(t, `의존 개념 ${seq}`, F, `의존 개념 ${seq}은 약수를 써서 정의한다.`);
    await t.exec(`insert into concept_sources (concept_id, academy_id, book_id, grade_label, raw_page, display_page, unit_path)
                  values ('${id}', '${S.academy}', '${S.book}', '중2-1', ${40 + i}, ${30 + i}, '{"Ⅰ. 수와 식","1. 유리수"}')`);
    ids.push(id);
  }
  await place(P.leaves[0].id, ids);
  const w = await walk({ folder_id: F });
  const job = (await start(w.walk_id)).job_id;
  return { job, gen: await claim(job), ids: w.items.map((x) => x.id), P, F };
}

const contentEdit = (text) => review('notation', {
  outcome: 'issue_found', findings: '본문 표기를 고친다',
  fix: { kind: 'library', ops: [{ op: 'edit', content: text }] },
});
const move = async (concept, unitId) => review('placement', {
  outcome: 'issue_found', findings: '책 단원과 다른 소단원에 놓임', basis: '출처 메타데이터',
  detail: { basis_kind: 'source', viewed_original: false },
  fix: { kind: 'placement', ops: [{ op: 'move', placement_id: (await placementOf(concept)).id, unit_id: unitId, evidence: '책 단원 "1. 유리수"' }] },
});

test('무관한 검토는 먼저 내고 의존 범위만 보류한다. 반영 뒤 그 범위만 지금 판으로 다시 판단한다', async () => {
  const { job, gen, ids, P } = await setup(1);
  await targets(job, gen);
  const name = `의존 기초 ${randomUUID().slice(0, 4)}`;
  const foundationAdd = review('foundation', {
    outcome: 'issue_found', findings: '기초 개념이 없다',
    detail: { needs: [{ name, terms: ['분수'], candidates: [], decision: 'add' }] },
    fix: { kind: 'library', ops: [{ op: 'create', name, type: '정의', folder: FOLDER, content: '전체를 똑같이 나눈 부분' }] },
  });
  await save(job, gen, [await drafted(1, ids[0], [
    review('notation'), review('meaning'), foundationAdd, await move(ids[0], P.leaves[1].id),
  ])]);
  const first = await submit(job, gen);
  assert.deepEqual(first.held, [{ position: 1, scopes: ['foundation', 'placement'] }]);
  assert.deepEqual(first.action.payload.items.map((i) => i.scope), ['notation', 'meaning']);
  const lib = first.fix_actions.find((a) => a.kind === 'concept_library_change');
  const pl = first.fix_actions.find((a) => a.kind === 'concept_placement_change');
  const row = await itemRow(job, 1);
  assert.equal(row.state, 'held');
  assert.equal(row.scope_cards.notation.action_id, first.action.id);
  assert.equal(row.held_fixes.find((h) => h.scope === 'foundation').deps[0].action_id, lib.id);
  assert.equal(row.held_fixes.find((h) => h.scope === 'placement').deps[0].mark_key, 'placement');
  assert.equal((await status(job)).counts.complete, 0, '보류가 남아 있으면 통합 완료가 아니다');
  const payloadBefore = (await t.one(`select payload from ai_actions where id = $1::uuid`, [first.action.id])).payload;

  await apply(first.action.id);
  assert.equal((await stateOf(ids[0])).state, 'pending');
  await apply(lib.id);
  await apply(pl.id);
  assert.equal((await placementOf(ids[0])).course_unit_id, P.leaves[1].id, '배치 이동은 실제 배치에서 확인한다');
  const created = (await t.one(`select id from concepts where name = $1`, [name])).id;
  const opened = await begin(job, gen);
  assert.deepEqual(opened.recheck, [{ position: 1, concept_id: ids[0], scopes: ['foundation', 'placement'], reason: 'resume' }]);
  const tg = await targets(job, gen);
  assert.deepEqual(tg.batch[0].todo, ['foundation', 'placement']);
  const mat = await material(job, gen, [1]);
  assert.equal(mat.items[0].created_concepts[0].id, created);
  assert.equal(mat.items[0].revision, await revision(ids[0]), '다시 읽을 판은 반영 뒤의 판이다');
  const saved = await save(job, gen, [await drafted(1, ids[0], [foundationOk([created]), placementOk()], { rework: true })]);
  assert.equal(saved.items[0].status, 'saved');
  assert.equal((await itemRow(job, 1)).revision, mat.items[0].revision);
  const again = await submit(job, gen);
  await apply(again.action.id);
  const after = await itemRow(job, 1);
  assert.equal(after.state, 'submitted');
  assert.equal(after.scope_cards.notation.action_id, first.action.id);
  assert.equal(after.scope_cards.foundation.action_id, again.action.id);
  const linked = (await cards(job)).map((c) => c.action_id);
  assert.ok(linked.includes(first.action.id) && linked.includes(again.action.id) && linked.includes(lib.id));
  assert.deepEqual((await t.one(`select payload from ai_actions where id = $1::uuid`, [first.action.id])).payload, payloadBefore);
  assert.equal((await stateOf(ids[0])).state, 'complete');
});

test('대기·실패·생략·거절을 항목별로 나누고, 카드 전체가 반영돼도 실패한 항목은 성공이 아니다', async () => {
  const { job, gen, ids, P } = await setup(4);
  await targets(job, gen);
  await save(job, gen, [
    await drafted(1, ids[0], [contentEdit('첫째 본문을 고친다'), review('meaning')]),
    await drafted(2, ids[1], [contentEdit('둘째 본문을 고친다'), review('meaning')]),
    await drafted(3, ids[2], [review('notation'), await move(ids[2], P.leaves[1].id)]),
    await drafted(4, ids[3], [review('notation'), await move(ids[3], P.leaves[2].id)]),
  ]);
  const sub = await submit(job, gen);
  const lib = sub.fix_actions.find((a) => a.kind === 'concept_library_change');
  const pl = sub.fix_actions.find((a) => a.kind === 'concept_placement_change');
  await apply(sub.action.id);
  await t.exec(`update concepts set content = '둘째를 사람이 고침' where id = '${ids[1]}'`);
  const partial = await apply(lib.id);
  assert.equal(partial.status, 'applied', '한 항목이라도 반영되면 카드는 applied다');
  assert.deepEqual(partial.result.items.map((x) => x.status), ['applied', 'failed']);
  const h1 = await holdOf(job, 1);
  const h2 = await holdOf(job, 2);
  assert.deepEqual(h1.ready, ['notation', 'meaning']);
  assert.deepEqual(h2.ready, []);
  assert.ok(h2.scopes.every((s) => s.status === 'failed'));
  const resumed = await targets(job, gen);
  const todoOf = (pos) => resumed.batch.find((b) => b.position === pos).todo;
  assert.deepEqual(todoOf(1), ['notation', 'meaning', 'foundation', 'placement']);
  assert.deepEqual(todoOf(2), ['foundation', 'placement'], '실패한 표기 수정은 다시 넣지 않는다');
  assert.deepEqual(todoOf(3), ['meaning', 'foundation'], '승인 대기인 배치 수정은 다시 넣지 않는다');
  assert.deepEqual(todoOf(4), ['meaning', 'foundation']);
  assert.equal((await itemRow(job, 2)).reason, 'hold:failed');
  const second = await targets(job, gen);
  assert.deepEqual(second.batch.find((b) => b.position === 2).todo, ['foundation', 'placement']);

  assert.equal((await holdOf(job, 3)).code, 'pending');
  assert.equal((await holdOf(job, 4)).code, 'pending');
  const skipped = await apply(pl.id, { skip: [2] });
  assert.equal(skipped.status, 'applied');
  assert.deepEqual((await holdOf(job, 3)).ready, ['placement']);
  assert.equal((await holdOf(job, 4)).code, 'skipped');
  assert.equal(await t.one(
    `select concept_review_job_item_skipped($1::uuid, $2::integer[]) as r`,
    [lib.id, [2]],
  ).then((x) => x.r), false, '반영 실패는 사용자가 뺀 항목이 아니다');

  const { job: jobR, gen: genR, ids: idsR, P: PR } = await setup(1);
  await targets(jobR, genR);
  await save(jobR, genR, [await drafted(1, idsR[0], [review('notation'), await move(idsR[0], PR.leaves[2].id)])]);
  const rejected = await submit(jobR, genR);
  await reject(rejected.fix_actions[0].id);
  assert.equal((await holdOf(jobR, 1)).code, 'rejected');
  assert.equal((await submit(jobR, genR)).submitted, false, '거절된 변경을 자동으로 다시 제안하지 않는다');
  assert.match((await status(jobR)).open_items.find((i) => i.position === 1).next_action, /거절/);
});

test('전체 실패는 카드에 남고 내용은 바뀌지 않는다. 원인을 고치면 같은 카드를 다시 승인한다', async () => {
  const { job, gen, ids } = await setup(1);
  await targets(job, gen);
  await save(job, gen, [await drafted(1, ids[0], [review('notation')])]);
  const sub = await submit(job, gen);
  const original = (await t.one(`select content from concepts where id = $1::uuid`, [ids[0]])).content;
  const payload = (await t.one(`select payload from ai_actions where id = $1::uuid`, [sub.action.id])).payload;
  await t.exec(`update concepts set content = '판이 바뀜' where id = '${ids[0]}'`);
  const failed = await apply(sub.action.id);
  assert.equal(failed.status, 'proposed');
  assert.match(failed.error, /course_think_all_failed:concept_review_stale/);
  assert.equal(failed.result.attempt_failed, true);
  assert.equal(failed.decided_at, null);
  assert.equal((await t.one(`select count(*)::int as n from concept_quality_reviews where concept_id = $1::uuid`, [ids[0]])).n, 0);
  assert.deepEqual((await t.one(`select payload from ai_actions where id = $1::uuid`, [sub.action.id])).payload, payload, '판 식별값만 카드에서 바꾸지 않는다');
  assert.deepEqual((await targets(job, gen)).batch, [], '기다리는 카드는 다시 판단 대상이 아니다');
  await t.one(`update concepts set content = $1 where id = $2::uuid returning id`, [original, ids[0]]);
  const again = await apply(sub.action.id);
  assert.equal(again.status, 'applied');
  assert.equal(again.error, null);
});

test('성공한 기록은 남기고, 비교 근거가 바뀐 범위만 다시 판단한다', async () => {
  const { job, gen, ids } = await setup(1);
  const base = await insertConcept(t, `비교 대상 ${randomUUID().slice(0, 4)}`, S.folder, '나누어떨어지게 하는 수');
  await targets(job, gen);
  await save(job, gen, [await drafted(1, ids[0], [
    review('notation'),
    review('meaning', { compared_ids: [base] }),
    foundationOk(),
    placementOk(),
  ])]);
  const sub = await submit(job, gen);
  await t.exec(`update concepts set content = '비교 대상을 고침' where id = '${base}'`);
  const partial = await apply(sub.action.id);
  assert.equal(partial.status, 'applied');
  assert.equal(partial.result.items.find((x) => x.i === 2).code, 'concept_review_compared_changed');
  const notationId = (await t.one(
    `select id from concept_quality_reviews where concept_id = $1::uuid and scope = 'notation'`,
    [ids[0]],
  )).id;
  assert.deepEqual((await stateOf(ids[0])).todo, ['meaning']);
  const tg = await targets(job, gen);
  assert.deepEqual(tg.batch[0].todo, ['meaning']);
  await material(job, gen, [1]);
  await save(job, gen, [await drafted(1, ids[0], [review('meaning', { compared_ids: [base] })], { rework: true })]);
  const again = await submit(job, gen);
  await apply(again.action.id);
  assert.equal((await t.one(
    `select id from concept_quality_reviews where concept_id = $1::uuid and scope = 'notation'`,
    [ids[0]],
  )).id, notationId, '성공한 표기 기록은 그대로다');
  assert.equal((await stateOf(ids[0])).state, 'complete');

  await t.exec(`update concepts set content = '비교 대상을 또 고침' where id = '${base}'`);
  const later = await stateOf(ids[0]);
  assert.deepEqual(later.todo, ['meaning']);
  assert.equal(later.conditions.foundation, 'met');
  assert.equal(later.conditions.placement, 'met');
  assert.equal(later.scopes.notation.state, 'met');
});

test('서로 비교만 하는 검토는 함께 내고, 서로의 글을 고치면 변경 카드만 기다린다', async () => {
  const plain = await setup(2);
  await targets(plain.job, plain.gen);
  await save(plain.job, plain.gen, [
    await drafted(1, plain.ids[0], [review('notation'), review('meaning', { compared_ids: [plain.ids[1]] }), placementOk()]),
    await drafted(2, plain.ids[1], [review('notation'), review('meaning', { compared_ids: [plain.ids[0]] }), placementOk()]),
  ]);
  const both = await submit(plain.job, plain.gen);
  assert.equal(both.fix_actions.length, 0);
  assert.equal(both.held.length, 0);
  assert.equal(both.action.payload.items.length, 6);
  assert.equal((await itemRow(plain.job, 1)).state, 'submitted');
  assert.equal((await itemRow(plain.job, 2)).state, 'submitted');

  const edit = await setup(2);
  await targets(edit.job, edit.gen);
  await save(edit.job, edit.gen, [
    await drafted(1, edit.ids[0], [contentEdit('첫째 글을 고친다'), review('meaning', { compared_ids: [edit.ids[1]] }), placementOk()]),
    await drafted(2, edit.ids[1], [contentEdit('둘째 글을 고친다'), review('meaning', { compared_ids: [edit.ids[0]] }), placementOk()]),
  ]);
  const waited = await submit(edit.job, edit.gen);
  const lib = waited.fix_actions.find((a) => a.kind === 'concept_library_change');
  assert.equal(lib.payload.items.length, 2);
  assert.deepEqual(waited.action.payload.items.map((i) => i.scope), ['placement', 'placement']);
  for (const pos of [1, 2]) {
    const held = await itemRow(edit.job, pos);
    assert.equal(held.state, 'held');
    assert.deepEqual(held.held_fixes.map((h) => h.scope), ['notation', 'meaning']);
    for (const h of held.held_fixes) {
      assert.ok(h.deps.every((d) => d.action_id === lib.id));
    }
  }
});

test('같은 판단은 같은 카드로 다시 찾고, 다른 범위는 나중에 내며, 지난 실행은 새 판단을 덮지 못한다', async () => {
  const { job, gen, ids } = await setup(1);
  await targets(job, gen);
  await save(job, gen, [await drafted(1, ids[0], [review('notation')])]);
  const first = await submit(job, gen);
  await t.exec(`update concept_review_job_items set state = 'drafted' where job_id = '${job}' and pos = 1`);
  const retry = await submit(job, gen);
  assert.equal(retry.existing, true);
  assert.equal(retry.action.id, first.action.id);
  assert.equal((await cards(job)).length, 1);

  await apply(first.action.id);
  await targets(job, gen);
  await save(job, gen, [await drafted(1, ids[0], [review('meaning')])]);
  const second = await submit(job, gen);
  assert.equal(second.existing, false);
  assert.notEqual(second.action.id, first.action.id);
  const row = await itemRow(job, 1);
  assert.equal(row.scope_cards.notation.action_id, first.action.id);
  assert.equal(row.scope_cards.meaning.action_id, second.action.id);
  assert.equal((await cards(job)).length, 2);

  const nextGen = await claim(job, 'run-2');
  assert.ok(nextGen > gen);
  await opRejects(
    `select concept_review_job_save($1::uuid, $2::bigint, $3::jsonb)`,
    [job, gen, JSON.stringify([await drafted(1, ids[0], [review('foundation')])])],
    /concept_review_job_lease_lost/,
  );
  assert.equal((await itemRow(job, 1)).scope_cards.meaning.action_id, second.action.id);
});

test('고른 항목이 없으면 예외이고, 일부만 승인하면 반영된다. 한 요청 상한은 50이다', async () => {
  const { job, gen, ids } = await setup(2);
  await targets(job, gen, 100);
  const cap = await begin(job, gen);
  assert.equal(cap.max_batch, 50);
  await save(job, gen, [
    await drafted(1, ids[0], [review('notation'), review('meaning')]),
    await drafted(2, ids[1], [review('notation')]),
  ]);
  const sub = await submit(job, gen);
  await opRejects(
    `select * from course_think_action_apply($1::uuid, $2::jsonb)`,
    [sub.action.id, JSON.stringify({ skip: [1, 2, 3] })],
    /course_think_nothing_selected/,
  );
  const partial = await apply(sub.action.id, { skip: [2] });
  assert.equal(partial.status, 'applied');
  assert.equal(partial.error, null);
  assert.deepEqual(partial.result.items.map((x) => x.status), ['applied', 'skipped', 'applied']);
  assert.equal((await stateOf(ids[0])).conditions.text, 'missing');
  assert.equal((await stateOf(ids[1])).scopes.notation.state, 'met');
});
