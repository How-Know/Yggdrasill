// 개념 검토: 순회 목록은 시작할 때 고정되고, 범위별 검토 기록은 승인한 카드로만 남는다.
// 범위마다 무엇이 바뀌면 다시 검토할지가 다르고, 검토를 남기는 일은 개념 내용으로 세지 않는다.
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
  conv = (await t.one(`insert into ai_conversations (title) values ('개념 검토') returning id`)).id;
});
after(() => t?.close());

const op = (sql, params = []) => t.asSuperadmin(() => t.one(sql, params), S.operator);
const opRejects = (sql, params, pattern) => t.asSuperadmin(() => t.rejects(sql, params, pattern), S.operator);
const arr = (ids) => `{${ids.join(',')}}`;

const WALK = `select concept_review_walk($1::uuid, $2::jsonb, $3::int, $4::int) as r`;
const walk = async (walkId, filter, offset = 0, limit = 40) =>
  (await op(WALK, [walkId, filter ? JSON.stringify(filter) : null, offset, limit])).r;
const walkRejects = (filter, pattern) => opRejects(WALK, [null, JSON.stringify(filter), 0, 40], pattern);
const status = async (ids) => (await op(`select concept_review_status($1::uuid[]) as r`, [arr(ids)])).r;
const detail = async (id) => (await op(`select concept_think_detail($1::uuid) as r`, [id])).r;
const marks = async (id) => (await t.one(`select concept_review_marks($1::uuid) as r`, [id])).r;
const revision = async (id) => (await t.one(`select concept_review_revision(concept_review_marks($1::uuid)) as r`, [id])).r;
const folder = async (name, parent = null) =>
  (await t.one(`insert into concept_categories (name, parent_id) values ($1, $2::uuid) returning id`, [name, parent])).id;
const records = async (id) =>
  (await t.one(`select count(*)::int as n from concept_quality_reviews where concept_id = $1::uuid`, [id])).n;

const PROPOSE = `select * from course_think_action_propose($1::uuid, 'concept_review_record', $2::jsonb)`;
const propose = (items, reason = '검토한 내용을 남긴다') => op(PROPOSE, [conv, JSON.stringify({ items, reason })]);
const proposeRejects = (items, pattern) => opRejects(PROPOSE, [conv, JSON.stringify({ items, reason: '검토' })], pattern);
const APPLY = `select * from course_think_action_apply($1::uuid, $2::jsonb)`;
const apply = (id, overrides = {}) => op(APPLY, [id, JSON.stringify(overrides)]);
const statusOf = async (id) => (await t.one(`select status from ai_actions where id = $1::uuid`, [id])).status;

const item = async (concept, scope, over = {}) => ({
  concept_id: concept,
  revision: await revision(concept),
  scope,
  outcome: 'no_issue_found',
  checked: '이름·본문의 표기',
  findings: '이번에 본 범위에서 오타를 찾지 못함',
  basis: '본문 전체를 읽음',
  unverified: null,
  follow_up: null,
  compared_ids: [],
  to_compare_ids: [],
  ...over,
});

const STATEMENT = {
  title: '검토용 서술',
  body: '1보다 큰 자연수 중 1과 자기 자신만을 약수로 가지는 수',
  approach: '약수',
  conditions_in_source: 'stated',
  terms: ['약수'],
};

async function leafUnit() {
  const course = (await op(`select course_maps_list() as r`)).r.find((c) => c.name === '1-1');
  const map = (await op(`select course_map_get($1::uuid) as r`, [course.id])).r;
  return map.units.find((u) => u.depth === 3);
}

test('순회 목록은 시작할 때 고정된다: 이름·폴더가 바뀌거나 지워져도 빠지거나 겹치지 않고, 뒤에 생긴 개념은 따로 센다', async () => {
  const A = await folder('순회 가');
  const A1 = await folder('하위', A);
  const B = await folder('순회 나');
  const a1 = await insertConcept(t, '순회 ㄱ', A);
  const a2 = await insertConcept(t, '순회 ㄴ', A);
  const a3 = await insertConcept(t, '순회 ㄷ', A1);
  const a4 = await insertConcept(t, '순회 ㄹ', A);
  const a5 = await insertConcept(t, '순회 ㅁ', A);
  await insertConcept(t, '순회 밖', B);

  const p0 = await walk(null, { folder_id: A }, 0, 2);
  assert.equal(p0.total, 5, '하위 폴더도 들어간다');
  assert.deepEqual(p0.items.map((i) => i.id), [a1, a2]);
  assert.equal(p0.next_offset, 2);
  assert.equal(p0.created_after, 0);
  assert.equal(p0.filter.folder_id, A);
  const one = p0.items[0];
  assert.equal(one.name, '순회 ㄱ');
  assert.deepEqual(one.folder, ['순회 가']);
  assert.ok(one.revision && one.revision.split('-').length === 4, '판은 text·class·relations·placement 네 칸');
  assert.deepEqual(one.review, {});
  assert.equal(one.placed, 0);
  assert.equal('content' in one, false, '목록은 본문 전체를 싣지 않는다');

  await t.exec(`update concepts set name = '순회 ㅎ' where id = '${a2}'`);
  await t.exec(`update concepts set main_category_id = '${B}' where id = '${a4}'`);
  await op(`select concept_delete($1::uuid) as r`, [a5]);
  const a6 = await insertConcept(t, '순회 ㄱㄱ', A);

  const p1 = await walk(p0.walk_id, null, 2, 2);
  assert.equal(p1.total, 5);
  assert.deepEqual(p1.items.map((i) => i.id), [a4, a5]);
  assert.deepEqual(p1.items[0].folder, ['순회 나'], '옮긴 개념도 목록에 남고 지금 폴더가 보인다');
  assert.deepEqual(p1.items[1], { id: a5, missing: true });
  assert.equal(p1.next_offset, 4);
  const p2 = await walk(p0.walk_id, null, 4, 2);
  assert.deepEqual(p2.items.map((i) => i.id), [a3]);
  assert.equal(p2.next_offset, null);
  assert.ok(p2.created_after >= 1, '시작 뒤 생긴 개념은 개수로 알린다');
  const again = await walk(p0.walk_id, null, 0, 2);
  assert.deepEqual(again.items.map((i) => [i.id, i.name]), [[a1, '순회 ㄱ'], [a2, '순회 ㅎ']]);
  const seen = [...p0.items, ...p1.items, ...p2.items].map((i) => i.id);
  assert.equal(new Set(seen).size, 5);
  assert.equal(seen.includes(a6), false);

  const fresh = await walk(null, { folder_id: A }, 0, 60);
  assert.deepEqual(fresh.items.map((i) => i.id), [a1, a6, a2, a3], '새 목록은 지금 상태로 다시 고정한다');
  await opRejects(WALK, [randomUUID(), null, 0, 10], /concept_review_walk_not_found/);
});

test('목록 조건: 유형·이름·배치·검토 상태, 잘못된 조건과 없는 폴더·유형은 빈 결과가 아니라 오류다', async () => {
  const F = await folder('조건');
  const typed = await insertConcept(t, '조건 정의', F);
  const plain = await insertConcept(t, '조건 없음', F);
  const placed = await insertConcept(t, '조건 배치', F);
  await t.exec(`insert into concept_type_links (concept_id, type_id) select '${typed}', id from concept_types where name = '정의'`);
  await op(`select course_placement_add($1::uuid, $2::uuid[]) as r`, [(await leafUnit()).id, arr([placed])]);

  const ids = async (filter) => (await walk(null, { folder_id: F, ...filter })).items.map((i) => i.id);
  assert.deepEqual(await ids({}), [placed, plain, typed], '배치 안 된 개념도 목록에 든다');
  assert.deepEqual(await ids({ type: '정의' }), [typed]);
  assert.deepEqual(await ids({ type: '유형 없음' }), [placed, plain]);
  assert.deepEqual(await ids({ name: '없음' }), [plain]);
  assert.deepEqual(await ids({ placed: 'placed' }), [placed]);
  assert.deepEqual(await ids({ placed: 'unplaced' }), [plain, typed]);
  assert.deepEqual(await ids({ name: '아무것도 없는 이름' }), []);

  const act = await propose([await item(typed, 'notation')]);
  await apply(act.id);
  assert.deepEqual(await ids({ review: 'unreviewed', review_scope: 'notation' }), [placed, plain]);
  assert.deepEqual(await ids({ review: 'unreviewed', review_scope: 'meaning' }), [placed, plain, typed]);
  assert.deepEqual(await ids({ review: 'stale' }), []);
  await t.exec(`update concepts set content = '고친 본문' where id = '${typed}'`);
  assert.deepEqual(await ids({ review: 'stale', review_scope: 'notation' }), [typed]);
  assert.deepEqual(await ids({ review: 'not_current', review_scope: 'notation' }), [placed, plain, typed]);

  await walkRejects({ folder_id: randomUUID() }, /concept_review_folder_not_found/);
  await walkRejects({ type: '없는 유형' }, /concept_review_unknown_type/);
  await walkRejects({ placed: 'sometimes' }, /concept_review_bad_filter/);
  await walkRejects({ review: 'verified' }, /concept_review_bad_filter/);
  await walkRejects({ review_scope: 'all' }, /concept_review_bad_filter/);
});

test('목록·상태·검토 기록은 운영자만 본다. 기록 표와 목록 표에 직접 쓰지 못한다', async () => {
  await t.asUser(() => t.rejects(WALK, [null, '{}', 0, 10], /concept_review_forbidden/));
  await t.asUser(() => t.rejects(`select concept_review_status($1::uuid[])`, [arr([S.concept])], /concept_review_forbidden/));
  await t.asAnon(() => t.rejects(WALK, [null, '{}', 0, 10], /permission denied/));
  await t.asUser(() =>
    t.rejects(`select * from course_think_action_propose($1::uuid, 'concept_review_record', '{}'::jsonb)`, [conv], /forbidden/));
  await t.asSuperadmin(() =>
    t.rejects(
      `insert into concept_quality_reviews (concept_id, scope, outcome, checked, findings, basis, marks, mark)
       values ($1::uuid, 'notation', 'no_issue_found', 'a', 'b', 'c', '{}'::jsonb, 'x')`,
      [S.concept],
      /permission denied/,
    ), S.operator);
  await t.asSuperadmin(() => t.rejects(`select * from concept_review_walks`, [], /permission denied/), S.operator);
  await t.exec(
    `insert into concept_quality_reviews (concept_id, scope, outcome, checked, findings, basis, marks, mark)
     values ('${S.concept2}', 'notation', 'no_issue_found', 'a', 'b', 'c', '{}'::jsonb, 'x')`,
  );
  const seen = await t.asUser(() => t.one(`select count(*)::int as n from concept_quality_reviews`));
  assert.equal(seen.n, 0);
  const opSeen = await op(`select count(*)::int as n from concept_quality_reviews where concept_id = $1::uuid`, [S.concept2]);
  assert.ok(opSeen.n >= 1);
});

test('판 표시: 범위마다 바뀌는 것만 바뀌고, 순서·바로가기·초안·검토 기록으로는 바뀌지 않는다', async () => {
  const F = await folder('지문');
  const G = await folder('지문 옮길 곳');
  const c = await insertConcept(t, '지문 가', F, '처음 본문');
  const other = await insertConcept(t, '지문 나', F, '상대 본문');
  const m0 = await marks(c);

  await t.exec(`update concepts set sort_order = 9 where id = '${c}'`);
  await t.exec(`insert into concept_shortcuts (category_id, concept_id) values ('${G}', '${c}')`);
  const row = (await op(`select concept_statement_create($1::uuid, 'statement', $2::jsonb) as r`, [c, JSON.stringify(STATEMENT)])).r;
  assert.deepEqual(await marks(c), m0, '확정 안 한 서술 초안은 판에 들지 않는다');
  const act = await propose([await item(c, 'notation')]);
  await apply(act.id);
  assert.deepEqual(await marks(c), m0, '검토를 남겨도 판이 그대로다');

  await op(`select concept_statement_confirm($1::uuid, $2::int, $3::timestamptz, null) as r`, [
    row.id, row.version, row.draft_saved_at,
  ]);
  const m1 = await marks(c);
  assert.notEqual(m1.text, m0.text, '서술을 확정하면 text 가 바뀐다');
  assert.equal(m1.class, m0.class);
  assert.equal(m1.relations, m0.relations);
  assert.deepEqual(m1.statements, [{ id: row.id, version: 1 }]);

  await t.exec(`update concepts set main_category_id = '${G}' where id = '${c}'`);
  const m2 = await marks(c);
  assert.notEqual(m2.class, m1.class, '폴더를 옮기면 class 가 바뀐다');
  assert.equal(m2.text, m1.text);
  await t.exec(`update concept_categories set name = '지문 옮긴 곳' where id = '${G}'`);
  const m3 = await marks(c);
  assert.notEqual(m3.class, m2.class, '폴더 경로 이름이 바뀌어도 class 가 바뀐다');
  await t.exec(`insert into concept_type_links (concept_id, type_id) select '${c}', id from concept_types where name = '성질'`);
  const m4 = await marks(c);
  assert.notEqual(m4.class, m3.class, '유형이 바뀌면 class 가 바뀐다');
  assert.equal(m4.text, m1.text);

  await t.exec(`insert into concept_relations (concept_id, related_id, kind, origin) values ('${c}', '${other}', 'extends', 'manual')`);
  const m5 = await marks(c);
  assert.notEqual(m5.relations, m4.relations, '관계를 더하면 relations 가 바뀐다');
  assert.equal(m5.text, m4.text);
  assert.equal(m5.class, m4.class);
  await t.exec(`update concepts set content = '상대 본문을 고침' where id = '${other}'`);
  const m6 = await marks(c);
  assert.notEqual(m6.relations, m5.relations, '관계 상대의 본문이 바뀌면 relations 가 바뀐다');
  assert.equal(m6.text, m5.text, '상대가 바뀌어도 이 개념의 text 는 그대로다');

  await t.exec(`update concepts set content = '고친 본문' where id = '${c}'`);
  const m7 = await marks(c);
  assert.notEqual(m7.text, m6.text);
  assert.equal(m7.class, m6.class);
  assert.equal(await t.one(`select concept_review_marks($1::uuid) as r`, [randomUUID()]).then((x) => x.r), null);
});

test('카드 제안: 항목을 검사하고 아무것도 남기지 않는다. 읽은 판이 지금과 다르면 막는다', async () => {
  const F = await folder('제안');
  const c = await insertConcept(t, '제안 가', F);
  const d = await insertConcept(t, '제안 나', F);

  await proposeRejects([], /concept_review_no_items/);
  const many = await Promise.all(Array.from({ length: 21 }, () => item(c, 'notation')));
  await proposeRejects(many, /concept_review_too_many/);
  await proposeRejects([{ ...(await item(c, 'notation')), revision: null }], /concept_review_bad_item:1:concept_review_revision_required/);
  await proposeRejects([{ ...(await item(c, 'notation')), revision: 'aaaaaaaaaaaa-bbbbbbbbbbbb-cccccccccccc' }],
    /concept_review_bad_item:1:concept_review_stale/);
  await proposeRejects([await item(c, 'meaning', { outcome: 'merge_needed' })], /concept_review_bad_item:1:concept_review_merge_scope/);
  await proposeRejects([await item(c, 'notation', { outcome: 'verified' })], /concept_review_bad_outcome/);
  await proposeRejects([await item(c, 'everything')], /concept_review_bad_scope/);
  await proposeRejects([await item(c, 'notation'), await item(c, 'notation')], /concept_review_bad_item:2:concept_review_duplicate/);
  await proposeRejects([await item(c, 'notation', { findings: ' ' })], /concept_review_text_required/);
  await proposeRejects([await item(c, 'notation', { basis: 'x'.repeat(1001) })], /concept_review_too_long/);
  await proposeRejects([await item(c, 'unit', { compared_ids: [c] })], /concept_review_ref_not_found/);
  await proposeRejects([await item(c, 'unit', { compared_ids: [randomUUID()] })], /concept_review_ref_not_found/);
  await proposeRejects([{ ...(await item(c, 'notation')), concept_id: randomUUID() }], /concept_review_concept_not_found/);

  // 다른 범위의 판만 바뀌었으면 막지 않는다.
  const old = await item(c, 'classification');
  await t.exec(`update concepts set content = '본문만 고침' where id = '${c}'`);
  const act = await propose([
    old,
    await item(c, 'unit', { outcome: 'merge_needed', findings: '제안 나와 같은 내용', compared_ids: [d, d], to_compare_ids: [d] }),
  ]);
  assert.equal(act.kind, 'concept_review_record');
  assert.equal(act.status, 'proposed');
  assert.equal(await records(c), 0, '제안만으로는 남지 않는다');
  assert.equal(act.preview.title, '개념 검토 기록');
  assert.deepEqual(act.preview.counts, { no_issue_found: 1, issue_found: 0, needs_comparison: 0, unverified: 0, merge_needed: 1 });
  const [p1, p2] = act.preview.items;
  assert.equal(p1.i, 1);
  assert.equal(p1.name, '제안 가');
  assert.deepEqual(p1.folder, ['제안']);
  assert.equal(p1.previous, null);
  assert.deepEqual(p2.compared, [{ id: d, name: '제안 나' }], '같은 개념은 한 번만');
  assert.deepEqual(p2.to_compare, [{ id: d, name: '제안 나' }]);
  assert.equal('marks' in p2, false);
  assert.equal(act.payload.items[1].compared[0].text, (await marks(d)).text, '판단에 쓴 개념의 판을 같이 남긴다');
  assert.equal(act.payload.items[0].marks.class, (await marks(c)).class);
});

test('카드 승인: 고른 항목만 남기고, 그사이 판이 바뀌었거나 비교한 개념이 바뀌면 그 항목은 남기지 않는다', async () => {
  const F = await folder('승인');
  const c = await insertConcept(t, '승인 가', F);
  const d = await insertConcept(t, '승인 나', F);
  const e = await insertConcept(t, '승인 다', F);
  const beforeRow = await t.one(`select name, content, main_category_id, updated_at from concepts where id = $1::uuid`, [c]);

  const act = await propose([
    await item(c, 'notation'),
    await item(c, 'meaning', { outcome: 'issue_found', findings: '조건 1보다 큰이 빠짐', compared_ids: [d], unverified: '다른 교재는 못 봄' }),
    await item(d, 'unit', { outcome: 'merge_needed', compared_ids: [c] }),
  ]);
  const done = await apply(act.id, { skip: [3] });
  assert.equal(done.status, 'applied');
  assert.deepEqual(done.result.items.map((x) => [x.i, x.status]), [[1, 'applied'], [2, 'applied'], [3, 'skipped']]);
  assert.equal(done.result.applied, 2);
  assert.equal(done.result.skipped, 1);
  assert.equal(await records(c), 2);
  assert.equal(await records(d), 0, '뺀 항목은 남지 않는다');
  const saved = await t.one(
    `select outcome, findings, unverified, compared, origin, action_id, action_item, approved_by, mark, marks
       from concept_quality_reviews where concept_id = $1::uuid and scope = 'meaning'`,
    [c],
  );
  assert.equal(saved.outcome, 'issue_found');
  assert.equal(saved.unverified, '다른 교재는 못 봄');
  assert.equal(saved.origin, 'think');
  assert.equal(saved.action_id, act.id);
  assert.equal(saved.action_item, 2);
  assert.equal(saved.approved_by, S.operator);
  assert.equal(saved.mark, saved.marks.text);
  assert.deepEqual(saved.compared.map((x) => x.id), [d]);
  const afterRow = await t.one(`select name, content, main_category_id, updated_at from concepts where id = $1::uuid`, [c]);
  assert.deepEqual(afterRow, beforeRow, '검토를 남겨도 개념은 그대로다');

  const stale = await propose([await item(e, 'notation'), await item(c, 'unit', { compared_ids: [e] })]);
  const originalE = (await t.one(`select content from concepts where id = $1::uuid`, [e])).content;
  const payloadE = (await t.one(`select payload from ai_actions where id = $1::uuid`, [stale.id])).payload;
  await t.exec(`update concepts set content = '그사이 고침' where id = '${e}'`);
  const failedApply = await apply(stale.id);
  assert.equal(failedApply.status, 'proposed', '하나도 못 남기면 카드는 기다리는 채로 남는다');
  assert.match(failedApply.error, /course_think_all_failed:concept_review_stale/);
  assert.equal(failedApply.result.attempt_failed, true);
  assert.equal(await records(e), 0);
  assert.deepEqual((await t.one(`select payload from ai_actions where id = $1::uuid`, [stale.id])).payload, payloadE, '실패한 시도가 카드 내용을 바꾸지 않는다');
  await t.one(`update concepts set content = $1 where id = $2::uuid returning id`, [originalE, e]);
  const retried = await apply(stale.id);
  assert.equal(retried.status, 'applied');
  assert.equal(retried.error, null, '다시 승인하면 이전 실패를 현재 실패로 두지 않는다');

  const G = await folder('승인 옮길 곳');
  const mixed = await propose([await item(e, 'notation'), await item(c, 'classification')]);
  await t.exec(`update concepts set main_category_id = '${G}' where id = '${c}'`);
  const part = await apply(mixed.id);
  assert.deepEqual(part.result.items.map((x) => [x.i, x.status, x.code ?? null]), [
    [1, 'applied', null],
    [2, 'failed', 'concept_review_stale'],
  ]);
  assert.equal(part.result.failed, 1);

  const cmp = await propose([await item(c, 'unit', { compared_ids: [d] })]);
  await t.exec(`update concepts set content = '비교 대상을 고침' where id = '${d}'`);
  const cmpFail = await apply(cmp.id);
  assert.equal(cmpFail.status, 'proposed');
  assert.match(cmpFail.error, /course_think_all_failed:concept_review_compared_changed/);
  assert.equal(cmpFail.result.attempt_failed, true);
  const f = await insertConcept(t, '승인 라', F);
  const gone = await propose([await item(c, 'relations', { compared_ids: [f] })]);
  await op(`select concept_delete($1::uuid) as r`, [f]);
  const goneFail = await apply(gone.id);
  assert.equal(goneFail.status, 'proposed');
  assert.match(goneFail.error, /course_think_all_failed:concept_review_compared_changed/);
  assert.equal(goneFail.result.attempt_failed, true);

  const skipAll = await propose([await item(d, 'notation')]);
  await opRejects(APPLY, [skipAll.id, JSON.stringify({ skip: [1] })], /course_think_nothing_selected/);
  await op(`select * from ai_action_reject($1::uuid)`, [skipAll.id]);
  assert.equal(await statusOf(skipAll.id), 'rejected');
  assert.equal(await records(d), 0, '거절한 카드는 아무것도 남기지 않는다');
  await opRejects(APPLY, [skipAll.id, '{}'], /action_not_pending/);
  await t.rejects(
    `insert into concept_quality_reviews (concept_id, scope, outcome, checked, findings, basis, marks, mark)
     values ($1::uuid, 'meaning', 'merge_needed', 'a', 'b', 'c', '{}'::jsonb, 'x')`,
    [d],
    /concept_quality_reviews_merge_chk/,
  );
});

test('상태: 범위별 최신 기록·앞선 기록·비교한 개념의 변화·기다리는 카드, 내용이 바뀌면 다시 검토 필요', async () => {
  const F = await folder('상태');
  const c = await insertConcept(t, '상태 가', F);
  const d = await insertConcept(t, '상태 나', F);
  await apply((await propose([
    await item(c, 'meaning', { outcome: 'needs_comparison', compared_ids: [d], to_compare_ids: [d], follow_up: '교재 본문과 대조' }),
  ])).id);

  let [s] = await status([c]);
  assert.equal(s.name, '상태 가');
  assert.equal(s.revision, await revision(c));
  assert.equal(s.scopes.notation, null);
  let m = s.scopes.meaning;
  assert.equal(m.records, 1);
  assert.deepEqual(m.earlier, []);
  assert.equal(m.latest.outcome, 'needs_comparison');
  assert.equal(m.latest.follow_up, '교재 본문과 대조');
  assert.equal(m.latest.stale, false);
  assert.deepEqual(m.latest.compared, [{ id: d, name: '상태 나', state: 'same' }]);
  assert.deepEqual(m.latest.to_compare, [{ id: d, name: '상태 나' }]);

  await t.exec(`update concepts set content = '상대를 고침' where id = '${d}'`);
  [s] = await status([c]);
  assert.equal(s.scopes.meaning.latest.stale, true, '비교 근거로 쓴 개념의 글이 바뀌면 그 범위는 다시 확인이 필요하다');
  assert.equal(s.scopes.meaning.latest.compared[0].state, 'changed', '판단에 쓴 상대가 바뀐 것은 따로 보인다');

  const oldRevision = s.revision;
  await t.exec(`update concepts set content = '이 개념을 고침' where id = '${c}'`);
  [s] = await status([c]);
  assert.equal(s.scopes.meaning.latest.stale, true, '내용이 바뀌면 다시 검토 필요');
  assert.equal(s.scopes.meaning.latest.revision, oldRevision, '검토한 판이 남는다');
  assert.notEqual(s.revision, oldRevision);

  const second = await propose([await item(c, 'meaning')]);
  assert.deepEqual(second.preview.items[0].previous.outcome, 'needs_comparison');
  assert.equal(second.preview.items[0].previous.stale, true);
  await apply(second.id);
  [s] = await status([c]);
  m = s.scopes.meaning;
  assert.equal(m.records, 2);
  assert.equal(m.latest.outcome, 'no_issue_found');
  assert.equal(m.latest.stale, false);
  assert.deepEqual(m.earlier.map((x) => [x.outcome, x.revision]), [['needs_comparison', oldRevision]], '앞선 기록은 이력으로 남는다');

  const pend = await propose([await item(c, 'notation')]);
  const again = await propose([await item(c, 'notation')]);
  assert.equal(pend.preview.items[0].pending_elsewhere, 0);
  assert.equal(again.preview.items[0].pending_elsewhere, 1, '같은 범위를 기다리는 다른 카드가 보인다');
  const missing = randomUUID();
  const [withPending, gone] = await status([c, missing]);
  assert.deepEqual(withPending.pending, [
    { action_id: pend.id, item: 1, scope: 'notation' },
    { action_id: again.id, item: 1, scope: 'notation' },
  ]);
  assert.deepEqual(gone, { id: missing, missing: true });

  await opRejects(`select concept_review_status($1::uuid[])`, ['{}'], /concept_review_bad_ids/);
  await opRejects(`select concept_review_status($1::uuid[])`, [arr(Array.from({ length: 21 }, () => randomUUID()))], /concept_review_bad_ids/);
});

test('Think 상세 읽기: 판·범위별 상태·관계(양쪽)·같은 개념 검토·등장 위치·출처 전체', async () => {
  const F = await folder('상세');
  const c = await insertConcept(t, '상세 가', F);
  const d = await insertConcept(t, '상세 나', F);
  await t.exec(`insert into concept_relations (concept_id, related_id, kind, origin, note) values ('${c}', '${d}', 'extends', 'manual', '넓힘')`);
  await t.exec(`insert into concept_reviews (concept_id, other_id, reason, note) values ('${c}', '${d}', 'overlap', '겹침')`);
  await t.exec(`insert into concept_appearances (concept_id, curriculum_code, school_level, course_label) values ('${c}', 'rev_2022', '중', '1-1')`);
  for (let p = 1; p <= 6; p++) {
    await t.exec(`insert into concept_sources (concept_id, academy_id, book_id, grade_label, raw_page)
                  values ('${c}', '${S.academy}', '${S.book}', '1-1', ${p})`);
  }

  const x = await detail(c);
  assert.equal(x.revision, await revision(c));
  assert.deepEqual(x.review, {});
  assert.equal(x.source_count, 6);
  assert.equal(x.sources.length, 6, '출처를 4개로 자르지 않는다');
  assert.equal(x.appearances.length, 1);
  assert.deepEqual(x.relations.map((r) => [r.direction, r.kind, r.other_id, r.other_name, r.note]), [['out', 'extends', d, '상세 나', '넓힘']]);
  assert.equal((await detail(d)).relations[0].direction, 'in');
  assert.deepEqual(x.same_concept_reviews.map((r) => [r.other_id, r.status, r.note]), [[d, 'open', '겹침']]);
  assert.equal(x.same_concept_review_count, 1);
  assert.deepEqual(x.statement_versions, []);
  assert.equal(x.attached.quality_reviews, 0);

  await apply((await propose([await item(c, 'relations', { outcome: 'unverified', findings: '상대 개념 출처를 못 봄', compared_ids: [d] })])).id);
  const y = await detail(c);
  assert.equal(y.review.relations.outcome, 'unverified');
  assert.equal(y.review.relations.stale, false);
  assert.equal(y.attached.quality_reviews, 1);
  await t.asUser(() => t.rejects(`select concept_think_detail($1::uuid)`, [c], /course_map_forbidden/));
});

test('범위별 검토 기록이 있는 개념은 지우지 않고, 기록도 남는다', async () => {
  const c = await insertConcept(t, '검토 뒤 지우기', S.folder);
  await apply((await propose([await item(c, 'unit', { outcome: 'merge_needed', findings: '합칠 개념이 있음' })])).id);
  const check = (await op(`select concept_delete_check($1::uuid) as r`, [c])).r;
  assert.equal(check.deletable, false);
  assert.equal(check.attached.quality_reviews, 1);
  await opRejects(`select concept_delete($1::uuid)`, [c], /concept_delete_attached/);
  assert.equal(await records(c), 1);
});

test('병합 필요·같은 개념 검토는 지우기를 막고, 새 검토·글 고침·시간·검토 종료로 풀리지 않으며 기록은 그대로 남는다', async () => {
  const c = await insertConcept(t, '병합 보류 가', S.folder);
  const d = await insertConcept(t, '병합 보류 나', S.folder);
  const blockedBy = async (id) => {
    const r = (await op(`select concept_delete_check($1::uuid) as r`, [id])).r;
    assert.equal(r.deletable, false);
    await opRejects(`select concept_delete($1::uuid)`, [id], /concept_delete_attached/);
    return Object.fromEntries(Object.entries(r.attached).filter(([k, n]) => k !== 'total' && n > 0));
  };
  const mergeNeeded = async (id) => (await t.one(
    `select count(*)::int as n from concept_quality_reviews where concept_id = $1::uuid and outcome = 'merge_needed'`, [id])).n;

  await apply((await propose([await item(c, 'unit', { outcome: 'merge_needed', findings: '합칠 개념이 있음' })])).id);
  assert.deepEqual(await blockedBy(c), { quality_reviews: 1 });

  await apply((await propose([await item(c, 'notation')])).id);
  await apply((await propose([await item(c, 'unit', { findings: '이번에는 합칠 개념을 찾지 못함' })])).id);
  assert.deepEqual(await blockedBy(c), { quality_reviews: 3 }, '다른 범위·같은 범위의 새 검토로 풀리지 않는다');

  await t.exec(`update concepts set name = '병합 보류 가(고침)' where id = '${c}'`);
  await t.exec(`update concept_quality_reviews set created_at = created_at - interval '400 days' where concept_id = '${c}'`);
  assert.deepEqual(await blockedBy(c), { quality_reviews: 3, content_revisions: 1 }, '글이 바뀌거나 오래돼도 검토 기록은 그대로 센다');
  assert.equal(await mergeNeeded(c), 1);

  const mark = (await t.one(
    `insert into concept_reviews (concept_id, other_id, reason) values ($1::uuid, $2::uuid, 'same_name') returning id`, [c, d])).id;
  assert.deepEqual(await blockedBy(d), { reviews: 1 }, '열린 같은 개념 검토는 두 개념 모두 막는다');
  await t.exec(`update concept_reviews set created_at = created_at - interval '400 days' where id = '${mark}'`);
  assert.deepEqual(await blockedBy(d), { reviews: 1 });

  await op(`select concept_review_resolve($1::uuid, 'different', null, '서로 다른 개념', false) as r`, [mark]);
  const closed = await t.one(`select status, resolution from concept_reviews where id = $1::uuid`, [mark]);
  assert.deepEqual({ ...closed }, { status: 'resolved', resolution: 'different' });
  assert.deepEqual(await blockedBy(d), { reviews: 1 }, '검토를 끝내도 기록이 남아 있으면 지우지 않는다');
  assert.deepEqual(await blockedBy(c), { quality_reviews: 3, content_revisions: 1, reviews: 1 });
  assert.equal(await records(c), 3);
  assert.equal(await mergeNeeded(c), 1);
});

test('30일 지난 순회 목록은 새 목록을 만들 때 지우고, 기능 확인에 concept_review 가 있다', async () => {
  const old = (await t.one(
    `insert into concept_review_walks (filter, concept_ids, created_at) values ('{}', '{}', now() - interval '31 days') returning id`,
  )).id;
  await walk(null, {});
  await opRejects(WALK, [old, null, 0, 10], /concept_review_walk_not_found/);
  const features = (await op(`select ai_think_db_features() as r`)).r;
  assert.equal(features.concept_review, 1);
  assert.equal(features.course_map_actions, 1);
});
