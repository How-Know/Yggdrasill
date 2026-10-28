// 개념 검수 참조 상한. 각 필드는 중복을 뺀 뒤 고유 20개까지고, 넘으면 그 위치만 미결로 남는다.
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
  conv = (await t.one(`insert into ai_conversations (title) values ('참조 상한') returning id`)).id;
});
after(() => t?.close());

const op = (sql, params = []) => t.asSuperadmin(() => t.one(sql, params), S.operator);
const opRejects = (sql, params, pattern) => t.asSuperadmin(() => t.rejects(sql, params, pattern), S.operator);
const r = async (sql, params) => (await op(sql, params)).r;
const arr = (ids) => `{${ids.join(',')}}`;
const revision = async (id) => (await t.one(`select concept_review_revision(concept_review_marks($1::uuid)) as r`, [id])).r;
const markOf = async (id) => (await t.one(`select concept_review_text_mark($1::uuid) as r`, [id])).r;
const walk = (filter) => r(`select concept_review_walk(null, $1::jsonb, 0, 60) as r`, [JSON.stringify(filter)]);
const start = (walkId) => r(`select concept_review_job_start($1::uuid, '참조 상한') as r`, [walkId]);
const claim = async (job) => (await r(`select concept_review_job_claim($1::uuid, 'run', 'take') as r`, [job])).gen;
const targets = (job, gen, n = 50) => r(`select concept_review_job_targets($1::uuid, $2::bigint, $3) as r`, [job, gen, n]);
const save = (job, gen, items) => r(`select concept_review_job_save($1::uuid, $2::bigint, $3::jsonb) as r`, [job, gen, JSON.stringify(items)]);
const submit = (job, gen) => r(`select concept_review_job_submit($1::uuid, $2::bigint, $3::uuid, '참조 상한', null) as r`, [job, gen, conv]);
const status = (job) => r(`select concept_review_job_status($1::uuid, 60) as r`, [job]);
const begin = (job, gen) => r(`select concept_review_job_batch_begin($1::uuid, $2::bigint) as r`, [job, gen]);
const apply = (id) => op(`select * from course_think_action_apply($1::uuid, '{}'::jsonb)`, [id]);
const refs = (ids, self) => t.one(`select concept_review_refs($1::jsonb, $2::uuid) as r`, [JSON.stringify(ids), self]);
const refsRejects = (ids, self, pattern) => t.rejects(
  `select concept_review_refs($1::jsonb, $2::uuid)`,
  [JSON.stringify(ids), self],
  pattern,
);
const PROPOSE = `select * from course_think_action_propose($1::uuid, 'concept_review_record', $2::jsonb)`;
const propose = (items) => op(PROPOSE, [conv, JSON.stringify({ items, reason: '참조를 남긴다' })]);
const proposeRejects = (items, pattern) => opRejects(PROPOSE, [conv, JSON.stringify({ items, reason: '참조' })], pattern);
const itemRow = (job, pos) => t.one(`select * from concept_review_job_items where job_id = $1::uuid and pos = $2`, [job, pos]);
const reviewCount = async (id) => (await t.one(
  `select count(*)::int as n from concept_quality_reviews where concept_id = $1::uuid`,
  [id],
)).n;

const review = (scope, over = {}) => ({
  scope, outcome: 'no_issue_found', checked: `${scope} 확인`, findings: '이번에 본 범위에서 문제를 찾지 못함', basis: '본문 전체를 읽음',
  unverified: null, follow_up: null, compared_ids: [], to_compare_ids: [], ...over,
});
const foundationOk = () => review('foundation', {
  checked: '필요한 초등 기초 개념을 검색해 본문과 비교', findings: '추가할 기초 개념 없음', basis: '대상 본문을 읽음',
  detail: { needs: [{ name: '약수', why: '정의에 쓰임', terms: ['약수'], candidates: [], decision: 'reuse', reuse_id: null }] },
});
const placementOk = () => review('placement', {
  checked: '출처와 지금 배치를 대조', findings: '배치 유지', basis: '출처 메타데이터',
  detail: { basis_kind: 'source', viewed_original: false },
});
const four = () => [review('notation'), review('meaning'), foundationOk(), placementOk()];
const drafted = async (position, concept, reviews) => ({
  position, concept_id: concept, state: 'drafted', revision: await revision(concept), read_complete: true,
  unread: null, reviews, next_action: null, reason: null, rework: false,
});
const cardItem = async (concept, scope, over = {}) => ({
  concept_id: concept, revision: await revision(concept), scope, outcome: 'no_issue_found',
  checked: '이름·본문의 표기', findings: '이번에 본 범위에서 오타를 찾지 못함', basis: '본문 전체를 읽음',
  unverified: null, follow_up: null, compared_ids: [], to_compare_ids: [], ...over,
});
const block = (position, concept, limit = 20) => ({
  position, concept_id: concept, state: 'deferred', read_complete: true, reviews: null,
  reason: `concept_review_too_many_refs:notation:compared_ids:21:${limit}`,
  next_action: '판이 바뀌거나 상한이 커지기 전에는 자동으로 다시 판단하지 않는다',
});

let seq = 0;
async function concepts(n, label) {
  const folder = (await t.one(`insert into concept_categories (name) values ($1) returning id`, [`${label} ${randomUUID().slice(0, 6)}`])).id;
  const ids = [];
  for (let i = 0; i < n; i += 1) {
    seq += 1;
    ids.push(await insertConcept(t, `${label} ${seq}`, folder, `${label} ${seq}의 본문`));
  }
  return ids;
}

async function jobOf(n) {
  const folder = (await t.one(`insert into concept_categories (name) values ($1) returning id`, [`참조작업 ${randomUUID().slice(0, 6)}`])).id;
  const course = (await r(`select course_maps_list() as r`)).find((c) => c.name === '2-1');
  const map = await r(`select course_map_get($1::uuid) as r`, [course.id]);
  const leaf = map.units.filter((u) => u.depth === 3)[0];
  const ids = [];
  for (let i = 0; i < n; i += 1) {
    seq += 1;
    const id = await insertConcept(t, `참조작업 개념 ${seq}`, folder, `참조작업 개념 ${seq}은 약수를 써서 정의한다.`);
    await t.exec(`insert into concept_sources (concept_id, academy_id, book_id, grade_label, raw_page, display_page, unit_path)
                  values ('${id}', '${S.academy}', '${S.book}', '중2-1', ${80 + seq}, ${70 + seq}, '{"Ⅰ. 수와 식","1. 유리수"}')`);
    ids.push(id);
  }
  await r(`select course_placement_add($1::uuid, $2::uuid[]) as r`, [leaf.id, arr(ids)]);
  const w = await walk({ folder_id: folder });
  const job = (await start(w.walk_id)).job_id;
  const gen = await claim(job);
  await targets(job, gen, n);
  return { job, gen, ids: w.items.map((i) => i.id), leaf };
}

test('같은 id는 하나로 세고, 필드마다 고유 20개까지 저장하며 21개는 자르지 않는다', async () => {
  assert.equal(Number((await t.one(`select concept_review_ref_limit() as n`)).n), 20);
  const [self, ...rest] = await concepts(23, '참조직접');
  const twenty = rest.slice(0, 20);
  const twentyOne = rest.slice(0, 21);
  const other = rest[0];

  const dup = await refs(Array(11).fill(other), self);
  assert.equal(dup.r.length, 1);
  assert.equal(dup.r[0].id, other);
  const ordered = await refs([rest[1], other, rest[1], other], self);
  assert.deepEqual(ordered.r.map((x) => x.id), [rest[1], other]);
  assert.equal((await refs(twenty.slice(0, 10), self)).r.length, 10);
  assert.equal((await refs(twenty.slice(0, 11), self)).r.length, 11);
  assert.equal((await refs(twenty, self)).r.length, 20);
  await refsRejects(twentyOne, self, /concept_review_too_many_refs/);
  await refsRejects([self], self, /concept_review_ref_not_found/);
  await refsRejects([randomUUID()], self, /concept_review_ref_not_found/);
  await refsRejects([other, 'not-a-uuid'], self, /concept_review_ref_not_found/);
  await refsRejects([other, 1], self, /concept_review_ref_not_found/);
  await t.rejects(`select concept_review_refs($1::jsonb, $2::uuid)`, [JSON.stringify({ id: other }), self], /concept_review_bad_refs/);
  assert.deepEqual((await t.one(`select concept_review_refs(null, $1::uuid) as r`, [self])).r, []);

  const beforeCards = (await t.one(`select count(*)::int as n from ai_actions where kind = 'concept_review_record'`)).n;
  await proposeRejects([await cardItem(self, 'notation', { compared_ids: twentyOne })], /concept_review_too_many_refs/);
  await proposeRejects([await cardItem(self, 'notation', { compared_ids: [other], to_compare_ids: twentyOne })], /concept_review_too_many_refs/);
  await proposeRejects([await cardItem(self, 'notation', { compared_ids: [self] })], /concept_review_ref_not_found/);
  assert.equal((await t.one(`select count(*)::int as n from ai_actions where kind = 'concept_review_record'`)).n, beforeCards);

  const witness = rest[21];
  const meaning = await propose([await cardItem(self, 'meaning')]);
  await apply(meaning.id);
  const kept = (await t.one(
    `select id from concept_quality_reviews where concept_id = $1::uuid and scope = 'meaning'`,
    [self],
  )).id;
  const both = await propose([await cardItem(self, 'unit', { compared_ids: twenty, to_compare_ids: twenty })]);
  const stored = (await t.one(`select payload from ai_actions where id = $1::uuid`, [both.id])).payload.items[0];
  assert.equal(stored.compared.length, 20);
  assert.equal(stored.to_compare.length, 20);
  assert.equal(stored.to_compare[19].text, undefined);
  assert.equal(stored.compared[19].id, twenty[19]);
  assert.equal(stored.compared[19].text, await markOf(twenty[19]));
  const mixed = await propose([
    await cardItem(witness, 'notation'),
    await cardItem(self, 'notation', { compared_ids: twenty }),
  ]);
  const card = (await t.one(`select payload from ai_actions where id = $1::uuid`, [mixed.id])).payload;
  const mark = await markOf(twenty[19]);
  assert.equal(card.items[1].compared.length, 20);
  assert.equal(card.items[1].compared[19].text, mark);
  await t.exec(`update concepts set content = '스무 번째 비교 대상을 고침' where id = '${twenty[19]}'`);
  assert.notEqual(await markOf(twenty[19]), mark);
  const failed = await apply(mixed.id);
  assert.equal(failed.result.items.find((x) => x.i === 2).code, 'concept_review_compared_changed');
  assert.equal(failed.result.items.find((x) => x.i === 1).status, 'applied');
  assert.equal(await reviewCount(self), 1, '바뀐 20번째 비교 근거가 있으면 그 항목은 승인되지 않는다');
  assert.equal((await t.one(`select id from concept_quality_reviews where concept_id = $1::uuid and scope = 'meaning'`, [self])).id, kept);
});

test('한 위치의 상한 초과는 그 초안만 거절하고, 미결은 완료로 세거나 바로 다시 판단하지 않는다', async () => {
  const { job, gen, ids } = await jobOf(3);
  await save(job, gen, [await drafted(1, ids[0], four())]);
  const approved = await submit(job, gen);
  await apply(approved.action.id);
  const kept = (await t.one(
    `select id from concept_quality_reviews where concept_id = $1::uuid and scope = 'notation'`,
    [ids[0]],
  )).id;
  let st = await status(job);
  assert.equal(st.counts.complete, 1);
  assert.equal(st.first_pass.met, 1);

  const side = await concepts(21, '참조옆');
  const twenty = side.slice(0, 20);
  const prior = await propose([await cardItem(ids[2], 'notation')]);
  await apply(prior.id);
  assert.equal(await reviewCount(ids[2]), 1);

  const overflow = await save(job, gen, [
    await drafted(2, ids[1], [review('notation', { compared_ids: twenty })]),
    await drafted(3, ids[2], [review('meaning', { compared_ids: side })]),
  ]);
  assert.equal(overflow.saved, 1);
  assert.equal(overflow.items.find((x) => x.position === 2).status, 'saved');
  assert.match(overflow.items.find((x) => x.position === 3).code, /concept_review_too_many_refs/);
  assert.equal(await t.one(
    `select count(*)::int as n from concept_review_job_items where job_id = $1::uuid and pos = 3`,
    [job],
  ).then((x) => x.n), 0);
  assert.equal(await reviewCount(ids[2]), 1);
  const draft = (await itemRow(job, 2)).draft[0];
  assert.equal(draft.compared_ids.length, 20);
  assert.equal(draft.compared_text[twenty[19]], await markOf(twenty[19]));

  const sent = await submit(job, gen);
  const payload = sent.action.payload.items[0];
  assert.equal(payload.compared.length, 20);
  assert.equal(payload.compared[19].id, twenty[19]);
  assert.equal(payload.compared[19].text, await markOf(twenty[19]));
  await t.exec(`update concepts set content = '작업 카드의 스무 번째를 고침' where id = '${twenty[19]}'`);
  const changed = await apply(sent.action.id);
  assert.equal(changed.result.items[0].code, 'concept_review_compared_changed');
  assert.equal(await reviewCount(ids[1]), 0);
  assert.equal((await t.one(`select id from concept_quality_reviews where id = $1::uuid`, [kept])).id, kept);

  await save(job, gen, [{
    position: 3, concept_id: ids[2], state: 'failed', read_complete: true, reviews: null,
    reason: 'judge_invalid: concept_review_too_many_refs', next_action: '다음 검수 요청에서 다시 판단',
  }]);
  assert.deepEqual((await begin(job, gen)).retry.map((x) => x.position), [3]);
  assert.equal((await itemRow(job, 3)).reason, 'judge_invalid: concept_review_too_many_refs');
  await save(job, gen, [block(3, ids[2])]);
  const blocked = await itemRow(job, 3);
  assert.equal(blocked.state, 'deferred');
  assert.equal(blocked.revision, await revision(ids[2]));
  assert.equal(blocked.draft, null);
  assert.match(blocked.reason, /^concept_review_too_many_refs:notation:compared_ids:21:20$/);
  assert.deepEqual((await begin(job, gen)).retry, []);
  assert.deepEqual((await targets(job, gen)).batch.map((b) => b.position), []);
  st = await status(job);
  assert.equal(st.counts.complete, 1);
  assert.equal(st.first_pass.met, 1);
  assert.equal(st.progress_line, '3개 중 1개 통합 완료');

  await t.one(
    `update concept_review_job_items set reason = 'concept_review_too_many_refs:notation:compared_ids:21:10'
      where job_id = $1::uuid and pos = 3 returning pos`,
    [job],
  );
  assert.deepEqual((await targets(job, gen)).batch.map((b) => b.position), [3], '기록된 상한보다 지금 상한이 크면 다시 고른다');
  await t.one(
    `update concept_review_job_items set reason = 'concept_review_too_many_refs:notation:compared_ids:21:20'
      where job_id = $1::uuid and pos = 3 returning pos`,
    [job],
  );
  assert.deepEqual((await targets(job, gen)).batch.map((b) => b.position), []);
  await t.exec(`update concepts set content = content || ' 판이 바뀜' where id = '${ids[2]}'`);
  assert.deepEqual((await targets(job, gen)).batch.map((b) => b.position), [3], '판이 바뀌면 기존 대상 고르기로 다시 들어온다');
});

test('상한이 커진 위치는 고정 목록 순서를 유지하고, 보류의 의존은 남긴 채 다시 꺼내지 않는다', async () => {
  const { job, gen, ids } = await jobOf(2);
  await save(job, gen, [block(1, ids[0], 10), block(2, ids[1], 10)]);
  assert.deepEqual((await targets(job, gen)).batch.map((b) => b.position), [1, 2]);

  const { job: heldJob, gen: heldGen, ids: heldIds } = await jobOf(1);
  const name = `참조 기초 ${randomUUID().slice(0, 4)}`;
  await save(heldJob, heldGen, [await drafted(1, heldIds[0], [
    review('notation'),
    review('meaning'),
    review('foundation', {
      outcome: 'issue_found', findings: '기초 개념이 없다',
      detail: { needs: [{ name, terms: ['분수'], candidates: [], decision: 'add' }] },
      fix: { kind: 'library', ops: [{ op: 'create', name, type: '정의', folder: ['소인수분해', '초등 기초'], content: '전체를 똑같이 나눈 부분' }] },
    }),
  ])]);
  const first = await submit(heldJob, heldGen);
  assert.equal((await itemRow(heldJob, 1)).state, 'held');
  const lib = first.fix_actions.find((a) => a.kind === 'concept_library_change');
  await apply(first.action.id);
  await apply(lib.id);
  const fixes = JSON.stringify((await itemRow(heldJob, 1)).held_fixes);
  const draft = JSON.stringify((await itemRow(heldJob, 1)).draft);
  assert.ok((await begin(heldJob, heldGen)).recheck.some((x) => x.position === 1 && x.scopes.includes('foundation')));

  const side = await concepts(21, '보류참조');
  const denied = await save(heldJob, heldGen, [await drafted(1, heldIds[0], [review('notation', { compared_ids: side })])]);
  assert.match(denied.items[0].code, /concept_review_too_many_refs/);
  assert.equal(JSON.stringify((await itemRow(heldJob, 1)).held_fixes), fixes);
  assert.equal(JSON.stringify((await itemRow(heldJob, 1)).draft), draft);

  await save(heldJob, heldGen, [block(1, heldIds[0])]);
  const row = await itemRow(heldJob, 1);
  assert.equal(row.state, 'held');
  assert.equal(JSON.stringify(row.held_fixes), fixes);
  assert.match(row.reason, /^concept_review_too_many_refs:/);
  assert.equal(row.revision, await revision(heldIds[0]));
  await targets(heldJob, heldGen);
  assert.match((await itemRow(heldJob, 1)).reason, /^concept_review_too_many_refs:/);
  assert.deepEqual((await begin(heldJob, heldGen)).recheck, []);
  assert.deepEqual((await targets(heldJob, heldGen)).batch, []);
  await t.exec(`update concepts set content = content || ' 보류 판 변경' where id = '${heldIds[0]}'`);
  const again = await begin(heldJob, heldGen);
  assert.ok(again.recheck.some((x) => x.position === 1 && x.scopes.includes('foundation')));
});
