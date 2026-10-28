// 개념 검수 통합 3조건: 표기·의미 / 초등 기초 개념 / 출처 기반 배치. 세 조건이 모두 승인돼야 통합 완료이고,
// 부족한 범위만 보완하며, 문제 있음은 고치기 카드(개념 고치기·배치)를 함께 내고 그 카드가 반영된 뒤 다시 확인해야 풀린다.
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { insertConcept, openConceptTestDb, seedConcepts } from '../concept_fixture.mjs';

let t;
let S;
let convA;
let convB;

before(async () => {
  t = await openConceptTestDb();
  S = await seedConcepts(t);
  convA = (await t.one(`insert into ai_conversations (title) values ('통합 검수 1') returning id`)).id;
  convB = (await t.one(`insert into ai_conversations (title) values ('통합 검수 2') returning id`)).id;
});
after(() => t?.close());

const op = (sql, params = []) => t.asSuperadmin(() => t.one(sql, params), S.operator);
const opRejects = (sql, params, pattern) => t.asSuperadmin(() => t.rejects(sql, params, pattern), S.operator);
const r = async (sql, params) => (await op(sql, params)).r;
const arr = (ids) => `{${ids.join(',')}}`;
const revision = async (id) => (await t.one(`select concept_review_revision(concept_review_marks($1::uuid)) as r`, [id])).r;

const walk = (filter) => r(`select concept_review_walk(null, $1::jsonb, 0, 60) as r`, [JSON.stringify(filter)]);
const start = (walkId) => r(`select concept_review_job_start($1::uuid, '통합 검수') as r`, [walkId]);
const claim = async (job, holder = 'run') => (await r(`select concept_review_job_claim($1::uuid, $2, 'take') as r`, [job, holder])).gen;
const targets = (job, gen, n = 50) => r(`select concept_review_job_targets($1::uuid, $2::bigint, $3) as r`, [job, gen, n]);
const next = (job, gen, n) => r(`select concept_review_job_next($1::uuid, $2::bigint, $3) as r`, [job, gen, n]);
const material = (job, gen, positions) =>
  r(`select concept_review_job_material($1::uuid, $2::bigint, $3::integer[], '{}'::jsonb, 60000) as r`, [job, gen, positions]);
const save = (job, gen, items) => r(`select concept_review_job_save($1::uuid, $2::bigint, $3::jsonb) as r`, [job, gen, JSON.stringify(items)]);
const submit = (job, gen, conv = convA, max = null) =>
  r(`select concept_review_job_submit($1::uuid, $2::bigint, $3::uuid, '통합 검수 결과', $4) as r`, [job, gen, conv, max]);
const status = (job) => r(`select concept_review_job_status_live($1::uuid, 60) as r`, [job]);
const stateOf = async (id) => (await t.one(`select concept_review_job_concept_state($1::uuid, concept_review_pending_concepts()) as r`, [id])).r;
const apply = (id, overrides = {}) => op(`select * from course_think_action_apply($1::uuid, $2::jsonb)`, [id, JSON.stringify(overrides)]);
const reject = (id) => op(`select * from ai_action_reject($1::uuid)`, [id]);
const records = async (id) => (await t.one(`select count(*)::int as n from concept_quality_reviews where concept_id = $1::uuid`, [id])).n;

const courseByName = async (name) => (await r(`select course_maps_list() as r`)).find((c) => c.name === name);
async function units(name) {
  const course = await courseByName(name);
  const map = await r(`select course_map_get($1::uuid) as r`, [course.id]);
  return { course, leaves: map.units.filter((u) => u.depth === 3) };
}
const place = (unitId, ids) => r(`select course_placement_add($1::uuid, $2::uuid[]) as r`, [unitId, arr(ids)]);
const placementOf = async (concept) =>
  (await t.one(`select id from concept_appearances where concept_id = $1::uuid and course_unit_id is not null`, [concept])).id;

const review = (scope, over = {}) => ({
  scope, outcome: 'no_issue_found', checked: `${scope} 확인`, findings: '이번에 본 범위에서 문제를 찾지 못함', basis: '본문 전체를 읽음',
  unverified: null, follow_up: null, compared_ids: [], to_compare_ids: [], ...over,
});
const foundationOk = (compared = []) => review('foundation', {
  checked: '필요한 초등 기초 개념: 약수. 검색어 "약수"로 찾은 후보 본문을 읽고 비교',
  findings: '기존 개념 "약수(기초)"를 재사용한다. 추가할 기초 개념 없음',
  basis: '대상 본문 첫 문장이 약수를 써서 정의함',
  compared_ids: compared,
  detail: {
    needs: [{ name: '약수', why: '정의에 약수를 씀', terms: ['약수'], candidates: compared, decision: 'reuse', reuse_id: compared[0] ?? null }],
    not_seen: null,
  },
});
const placementOk = () => review('placement', {
  checked: '출처(중2-1, 책 단원)와 지금 배치(2-1)를 대조',
  findings: '출처 학년이 이 과정과 같고 책 단원과 배치 단원이 맞음. 배치 유지',
  basis: '출처 메타데이터(책·학년·책 단원). 교재 원본 쪽은 보지 않음',
  detail: { basis_kind: 'source', viewed_original: false },
});
const drafted = async (position, concept, reviews) => ({
  position, concept_id: concept, state: 'drafted', revision: await revision(concept), read_complete: true,
  unread: null, reviews, next_action: null, reason: null, rework: false,
});

const FOLDER = ['소인수분해', '초등 기초'];
let seq = 0;
/** 출처(중2-1)와 2-1 배치가 있는 개념 n개로 작업을 연다. */
async function setup(n, { printed = true } = {}) {
  const F = (await t.one(`insert into concept_categories (name) values ($1) returning id`, [`통합 ${randomUUID().slice(0, 6)}`])).id;
  const P = await units('2-1');
  const ids = [];
  for (let i = 0; i < n; i++) {
    seq += 1;
    const id = await insertConcept(t, `통합 개념 ${seq}`, F, `통합 개념 ${seq}은 약수를 써서 정의한다.`);
    await t.exec(`insert into concept_sources (concept_id, academy_id, book_id, grade_label, raw_page, display_page, unit_path)
                  values ('${id}', '${S.academy}', '${S.book}', '중2-1', ${40 + i}, ${printed ? 30 + i : 'null'}, '{"Ⅰ. 수와 식","1. 유리수"}')`);
    ids.push(id);
  }
  await place(P.leaves[0].id, ids);
  const w = await walk({ folder_id: F });
  const job = (await start(w.walk_id)).job_id;
  return { job, gen: await claim(job), ids: w.items.map((x) => x.id), P, F };
}

async function approveAll(sub) {
  for (const a of sub.fix_actions ?? []) await apply(a.id);
  await apply(sub.action.id);
}

test('표기만 승인 → 미완료, 부족한 범위만 보완. 표기·의미 승인이어도 기초·배치 전에는 미완료. 위치·순서·이력은 그대로', async () => {
  const { job, gen, ids } = await setup(3);
  const all = await next(job, gen, 3);
  assert.deepEqual(all.batch.map((b) => b.position), [1, 2, 3]);
  await save(job, gen, [await drafted(1, ids[0], [review('notation')]), await drafted(2, ids[1], [review('notation'), review('meaning')])]);
  const first = await submit(job, gen);
  await apply(first.action.id);

  const s1 = await stateOf(ids[0]);
  assert.equal(s1.state, 'todo');
  assert.deepEqual(s1.todo, ['meaning', 'foundation', 'placement'], '표기만 승인 → 의미·기초·배치만 남는다');
  const s2 = await stateOf(ids[1]);
  assert.deepEqual([s2.state, s2.conditions.text, s2.todo], ['todo', 'met', ['foundation', 'placement']]);

  const cardsBefore = await t.all(`select action_id, idem_key, positions from concept_review_job_cards where job_id = $1::uuid order by created_at`, [job]);
  const tg = await targets(job, gen);
  assert.deepEqual(tg.batch.map((b) => [b.position, b.supplement, b.todo]), [
    [1, true, ['meaning', 'foundation', 'placement']],
    [2, true, ['foundation', 'placement']],
    [3, false, ['notation', 'meaning', 'foundation', 'placement']],
  ], '이미 상태가 있는 위치도 보완 대상으로 다시 찾고, 순서는 목록 그대로');
  assert.equal(tg.supplement, 2);
  assert.equal(tg.auto_saved.reused, 0, '보완 대상은 자동 건너뜀으로 세지 않는다');

  const m = await material(job, gen, [1, 2]);
  assert.equal(m.items[0].sources[0].printed_page, 30);
  assert.equal(m.items[0].sources[0].pdf_page, 40, 'PDF 쪽과 인쇄 쪽을 나눠 싣는다');
  assert.equal(m.items[0].sources[0].course_key, 'M2-1');
  assert.equal(m.items[0].placements.length, 1);
  assert.deepEqual(m.items[0].todo, ['meaning', 'foundation', 'placement'], '묶어 읽기에도 부족한 범위가 실린다');

  await save(job, gen, [
    await drafted(1, ids[0], [review('meaning'), foundationOk(), placementOk()]),
    await drafted(2, ids[1], [foundationOk(), placementOk()]),
  ]);
  const second = await submit(job, gen);
  assert.deepEqual(second.positions, [1, 2]);
  assert.equal(second.action.payload.items.length, 5, '부족한 범위만 카드에 든다');
  assert.equal((await status(job)).counts.awaiting, 2);
  assert.equal((await stateOf(ids[0])).state, 'pending', '승인 전에는 완료가 아니다');
  await apply(second.action.id);

  const st = await status(job);
  assert.equal(st.progress_line, '3개 중 2개 통합 완료');
  assert.deepEqual(st.conditions, { text: 2, foundation: 2, placement: 2 });
  assert.equal(st.counts.not_reviewed, 1);
  const cardsAfter = await t.all(`select action_id, idem_key, positions from concept_review_job_cards where job_id = $1::uuid order by created_at`, [job]);
  assert.deepEqual(cardsAfter.slice(0, cardsBefore.length), cardsBefore, '앞서 낸 카드 연결은 그대로다');
  assert.equal(await records(ids[0]), 4, '표기 기록과 보완 기록이 모두 남는다');
  const redo = await save(job, gen, [await drafted(1, ids[0], [review('notation')])]);
  assert.match(redo.items[0].code, /concept_review_job_item_done/, '통합 완료면 이유 없이 다시 검수하지 않는다');
  assert.deepEqual((await targets(job, gen)).batch.map((b) => b.position), [3]);
});

test('기초 개념 추가 불필요: 검색·비교·근거가 기록에 남고 승인 뒤 충족. 비교한 기초 개념이 없어지면 기초만 다시 본다', async () => {
  const { job, gen, ids } = await setup(1);
  const base = await insertConcept(t, `약수(기초) ${randomUUID().slice(0, 4)}`, S.folder, '나누어떨어지게 하는 수');
  await targets(job, gen);
  await save(job, gen, [await drafted(1, ids[0], [review('notation'), review('meaning'), foundationOk([base]), placementOk()])]);
  const sub = await submit(job, gen);
  const item = sub.action.payload.items.find((i) => i.scope === 'foundation');
  assert.equal(item.compared[0].id, base);
  assert.equal(item.detail.needs[0].decision, 'reuse');
  await apply(sub.action.id);
  const rec = await t.one(`select detail, compared, fixes from concept_quality_reviews where concept_id = $1::uuid and scope = 'foundation'`, [ids[0]]);
  assert.deepEqual([rec.detail.needs[0].terms, rec.compared[0].id, rec.fixes], [['약수'], base, []]);
  assert.equal((await stateOf(ids[0])).state, 'complete');

  await op(`select concept_delete($1::uuid) as r`, [base]);
  const after = await stateOf(ids[0]);
  assert.deepEqual([after.state, after.todo], ['todo', ['foundation']], '바뀐 근거에 걸린 조건만 다시 본다');
  assert.deepEqual([after.conditions.text, after.conditions.placement], ['met', 'met']);
});

test('기초 추가·배치 수정: 고치기 카드를 함께 내고, 반영 전에는 미완료, 반영 뒤 다시 확인해 승인돼야 완료', async () => {
  const { job, gen, ids, P } = await setup(2);
  await targets(job, gen);
  const name = `분수의 뜻(초등) ${randomUUID().slice(0, 4)}`;
  const create = { op: 'create', name, type: '정의', folder: FOLDER, content: '전체를 똑같이 나눈 것 중의 부분을 나타내는 수', evidence: '초등 3학년 분수 단원 내용(교육과정 위치 미확인)' };
  const foundationAdd = review('foundation', {
    outcome: 'issue_found', checked: '필요한 초등 기초: 분수의 뜻. 검색어 "분수" 후보 본문 비교', findings: '분수의 뜻을 다루는 개념이 없음',
    basis: '대상 본문이 분수를 전제로 함', detail: { needs: [{ name: '분수의 뜻', terms: ['분수'], candidates: [], decision: 'add' }] },
    fix: { kind: 'library', ops: [create] },
  });
  const placementMove = review('placement', {
    outcome: 'issue_found', checked: '출처 책 단원과 배치 단원 대조', findings: '책 단원과 다른 소단원에 놓임', basis: '출처 메타데이터',
    detail: { basis_kind: 'source', viewed_original: false },
    fix: { kind: 'placement', ops: [{ op: 'move', placement_id: await placementOf(ids[0]), unit_id: P.leaves[1].id, evidence: '책 단원 "1. 유리수"' }] },
  });
  await save(job, gen, [
    await drafted(1, ids[0], [review('notation'), review('meaning'), foundationAdd, placementMove]),
    await drafted(2, ids[1], [review('notation'), review('meaning'), { ...foundationAdd, fix: { kind: 'library', ops: [{ ...create }] } }, placementOk()]),
  ]);
  const sub = await submit(job, gen);
  assert.equal(sub.fix_actions.length, 2, '개념 고치기 카드 한 장 + 과정 배치 카드 한 장');
  const lib = sub.fix_actions.find((a) => a.kind === 'concept_library_change');
  const pl = sub.fix_actions.find((a) => a.kind === 'concept_placement_change');
  assert.equal(lib.payload.items.length, 1, '두 개념이 같은 기초를 원하면 만들기는 하나');
  assert.equal(lib.payload.items[0].place_unit_id, null, '새 기초 개념은 배치하지 않는다(위치 미확인)');
  assert.equal(sub.action.payload.items.find((i) => i.scope === 'foundation'), undefined, '기초 추가에 의존하는 검토는 먼저 내지 않는다');
  assert.equal(sub.action.payload.items.find((i) => i.outcome === 'issue_found'), undefined, '배치 수정에 의존하는 검토는 먼저 내지 않는다');
  assert.ok(sub.action.payload.items.some((i) => i.concept_id === ids[0] && i.scope === 'notation'));
  const held1 = await t.one(`select state, held_fixes from concept_review_job_items where job_id = $1::uuid and pos = 1`, [job]);
  assert.equal(held1.state, 'held');
  assert.deepEqual(held1.held_fixes.map((h) => h.scope), ['foundation', 'placement']);
  assert.equal(held1.held_fixes.find((h) => h.scope === 'foundation').deps[0].action_id, lib.id);
  assert.equal(held1.held_fixes.find((h) => h.scope === 'placement').deps[0].action_id, pl.id);
  const linked = await t.all(`select action_id from concept_review_job_cards where job_id = $1::uuid`, [job]);
  assert.equal(linked.length, 3, '고치기 카드도 작업 카드로 이어져 대기 한도에 든다');

  await apply(sub.action.id);
  assert.notEqual((await stateOf(ids[0])).state, 'complete', '검토만 승인되고 고치기 카드가 대기 중이면 미완료');
  assert.equal(await records(ids[0]), 2, '의존하지 않는 표기·의미만 먼저 기록된다');
  await apply(lib.id);
  await apply(pl.id);
  assert.deepEqual((await stateOf(ids[0])).todo, ['foundation', 'placement'], '반영된 뒤에는 그 범위만 다시 확인할 차례다');

  const tg = await targets(job, gen);
  assert.deepEqual(tg.batch.map((b) => [b.position, b.todo]), [[1, ['foundation', 'placement']], [2, ['foundation']]]);
  const created = (await t.one(`select id from concepts where name = $1`, [name])).id;
  const mat = await material(job, gen, [1]);
  assert.equal(mat.items[0].created_concepts[0].id, created, '생성된 개념 id를 반영 결과에서 읽는다');
  assert.deepEqual(mat.items[0].resume_scopes, ['foundation', 'placement']);
  await save(job, gen, [
    await drafted(1, ids[0], [foundationOk([created]), placementOk()]),
    await drafted(2, ids[1], [foundationOk([created])]),
  ]);
  const again = await submit(job, gen);
  assert.equal(again.fix_actions.length, 0);
  await apply(again.action.id);
  assert.equal((await status(job)).progress_line, '2개 중 2개 통합 완료');
  assert.equal(await records(ids[0]), 4, '먼저 승인된 기록과 다시 판단한 기록이 남는다');
});

test('고치기 거절·승인 때 뺌: 사용자 확인으로 남고 같은 판이면 다시 내지 않으며, 새 기록이 생기면 다시 낸다', async () => {
  const { job, gen, ids, P } = await setup(2);
  await targets(job, gen);
  const move = async (c) => review('placement', {
    outcome: 'issue_found', findings: '다른 단원이 맞아 보임', fix: { kind: 'placement', ops: [{ op: 'move', placement_id: await placementOf(c), unit_id: P.leaves[2].id, evidence: '책 단원' }] },
  });
  await save(job, gen, [
    await drafted(1, ids[0], [review('notation'), review('meaning'), foundationOk(), await move(ids[0])]),
    await drafted(2, ids[1], [review('notation'), review('meaning'), foundationOk(), placementOk()]),
  ]);
  const sub = await submit(job, gen);
  const placementItem = sub.action.payload.items.findIndex((i) => i.scope === 'placement' && i.concept_id === ids[1]) + 1;
  const applied = await apply(sub.action.id, { skip: [placementItem] });
  assert.deepEqual(applied.result.items.filter((x) => x.status !== 'applied'), [{ i: placementItem, status: 'skipped' }]);
  await reject(sub.fix_actions[0].id);
  const st = await status(job);
  assert.equal(st.counts.open, 2);
  assert.match(st.open_items.find((i) => i.position === 1).next_action, /거절/);
  assert.match(st.open_items.find((i) => i.position === 2).next_action, /승인 때 뺀 항목/);
  assert.deepEqual((await targets(job, gen)).batch, [], '거절·생략은 같은 판으로 다시 판단하지 않는다');
  const again = await submit(job, gen);
  assert.equal(again.submitted, false, '거절된 변경을 자동으로 다시 제안하지 않는다');

  // 사용자가 다시 보라고 해서 Think가 직접 기록을 남기면(새 기록) 그 위치는 다시 대상이 된다.
  const PROPOSE = `select * from course_think_action_propose($1::uuid, 'concept_review_record', $2::jsonb)`;
  const direct = await op(PROPOSE, [convA, JSON.stringify({ items: [{ ...placementOk(), concept_id: ids[1], revision: await revision(ids[1]) }], reason: '사용자 확인' })]);
  await apply(direct.id);
  assert.equal((await stateOf(ids[1])).state, 'complete');
  assert.equal((await stateOf(ids[0])).state, 'todo', '거절된 배치 수정은 검토 기록 없이 남고, 작업은 보류로 이유를 보여 준다');
  assert.equal((await t.one(`select state from concept_review_job_items where job_id = $1::uuid and pos = 1`, [job])).state, 'held');
});

test('출처에 인쇄 쪽이 없어도 배치 확인은 된다. 비교 필요·확인 못 함·병합 필요는 통합 완료에서 빠지고 이력·다음 할 일이 남는다', async () => {
  const { job, gen, ids } = await setup(4, { printed: false });
  await targets(job, gen);
  const m = await material(job, gen, [1]);
  const src = m.items[0].sources[0];
  assert.equal(src.printed_page, null, '인쇄 쪽을 PDF 쪽으로 채우지 않는다');
  assert.ok(src.pdf_page >= 40 && src.pdf_page <= 43);
  await save(job, gen, [
    await drafted(1, ids[0], [review('notation'), review('meaning'), foundationOk(), placementOk()]),
    await drafted(2, ids[1], [review('notation'), review('meaning'), review('foundation', { outcome: 'needs_comparison', follow_up: '후보 "약수"와 비교' }), placementOk()]),
    await drafted(3, ids[2], [review('notation'), review('meaning', { outcome: 'unverified', unverified: '원본 조건 확인 못 함' }), foundationOk(), placementOk()]),
    await drafted(4, ids[3], [review('notation'), review('meaning'), foundationOk(), placementOk(), review('unit', { outcome: 'merge_needed' })]),
  ]);
  const sub = await submit(job, gen);
  await apply(sub.action.id);
  const st = await status(job);
  assert.equal(st.progress_line, '4개 중 1개 통합 완료');
  assert.equal(st.counts.open, 3);
  assert.deepEqual(st.open_items.map((i) => [i.position, i.open.map((o) => o.scope)]), [[2, ['foundation']], [3, ['meaning']], [4, ['unit']]]);
  assert.ok(st.open_items.every((i) => /사용자 확인/.test(i.next_action)));
  assert.deepEqual((await targets(job, gen)).batch, [], '미결은 자동으로 다시 판단하지 않는다');
  assert.equal(await records(ids[3]), 5, '이력은 그대로 남는다');
});

test('제출 멱등·응답 유실·같은 이름 만들기 대기 중·고치기 거부: 중복 카드·중복 만들기·유실 없음', async () => {
  const { job, gen, ids, P } = await setup(3);
  await targets(job, gen);
  const name = `대기 중 기초 ${randomUUID().slice(0, 4)}`;
  const PROPOSE = `select * from course_think_action_propose($1::uuid, 'concept_library_change', $2::jsonb)`;
  const outside = await op(PROPOSE, [convA, JSON.stringify({ items: [{ op: 'create', name, type: '정의', folder: FOLDER, content: '이미 다른 카드가 만들려는 개념' }], reason: '따로 낸 카드' })]);
  const add = review('foundation', { outcome: 'issue_found', fix: { kind: 'library', ops: [{ op: 'create', name, type: '정의', folder: FOLDER, content: '같은 이름' }] } });
  const other = await units('1-1');
  const badMove = review('placement', {
    outcome: 'issue_found',
    fix: { kind: 'placement', ops: [{ op: 'move', placement_id: await placementOf(ids[2]), unit_id: other.leaves[0].id, evidence: '다른 과정' }] },
  });
  await save(job, gen, [
    await drafted(1, ids[0], [review('notation'), review('meaning'), add, placementOk()]),
    await drafted(2, ids[1], [review('notation'), review('meaning'), foundationOk(), placementOk()]),
    await drafted(3, ids[2], [review('notation'), review('meaning'), foundationOk(), badMove]),
  ]);
  const sub = await submit(job, gen);
  assert.deepEqual(sub.positions, [1, 2]);
  assert.equal(sub.failed.length, 1);
  assert.match(sub.failed[0].code, /^fix_invalid/, '거부된 고치기 제안의 위치만 빠진다');
  assert.equal(sub.fix_actions.length, 0, '같은 이름 만들기가 다른 대기 카드에 있으면 새로 만들지 않는다');
  assert.equal(sub.action.payload.items.find((i) => i.scope === 'foundation' && i.outcome === 'issue_found'), undefined);
  const held = await t.one(`select held_fixes from concept_review_job_items where job_id = $1::uuid and pos = 1`, [job]);
  assert.equal(held.held_fixes[0].deps[0].action_id, outside.id, '다른 작업의 생성 카드 연결을 보류 정보에 남긴다');

  const failedRow = await t.one(`select state, reason from concept_review_job_items where job_id = $1::uuid and pos = 3`, [job]);
  assert.equal(failedRow.state, 'failed');
  assert.deepEqual((await targets(job, gen)).batch, [], '고치기 거부 위치는 판이 그대로면 다시 내지 않는다');

  await t.exec(`update concept_review_job_items set state = 'drafted' where job_id = '${job}' and pos in (1, 2)`);
  const retry = await submit(job, gen);
  assert.deepEqual([retry.existing, retry.action.id], [true, sub.action.id], '응답을 잃고 다시 내도 같은 카드');
  const cards = (await t.one(`select count(*)::int as n from ai_actions where conversation_id = $1::uuid and status = 'proposed'`, [convA])).n;
  assert.equal(cards, 2, '따로 낸 카드 + 검토 카드뿐');
  assert.equal(retry.fix_actions.length, 0);

  await t.exec(`update concept_review_job_items set draft_version = draft_version + 1 where job_id = '${job}' and pos in (1, 2)`);
  const none = await submit(job, gen, convA, 0);
  assert.deepEqual([none.submitted, none.room], [false, 0], '이번 요청에 낼 수 있는 카드 장수가 0이면 내지 않는다');
});

test('새 대화: 검토·고치기 카드를 함께 옮기고, 상태는 저장된 기록으로 다시 센다. 기능 확인·후보 검색·과정 목록', async () => {
  const { job, gen, ids, P } = await setup(1);
  await targets(job, gen);
  const add = review('foundation', { outcome: 'issue_found', fix: { kind: 'library', ops: [{ op: 'create', type: '정의', folder: FOLDER, name: `새 대화 기초 ${randomUUID().slice(0, 4)}`, content: '초등 개념' }] } });
  await save(job, gen, [await drafted(1, ids[0], [review('notation'), review('meaning'), add, placementOk()])]);
  const sub = await submit(job, gen);
  const g2 = await claim(job, 'new-conversation');
  const here = await r(`select concept_review_job_cards_here($1::uuid, $2::bigint, $3::uuid) as r`, [job, g2, convB]);
  assert.deepEqual(here.cards.map((c) => c.id).sort(), [sub.action.id, sub.fix_actions[0].id].sort());
  assert.ok(here.cards.every((c) => c.conversation_id === convB));
  const st = await status(job);
  assert.equal(st.counts.awaiting, 1);
  assert.deepEqual(st.pending_cards.map((c) => c.kind).sort(), ['concept_library_change', 'concept_review_record']);

  const found = await r(`select concept_review_job_search($1::uuid, $2::bigint, $3::text[], 3) as r`, [job, g2, '{약수,통합 개념}']);
  assert.equal(found.results.length, 2);
  assert.ok(found.types.includes('정의') && found.roots.includes('소인수분해'));
  assert.ok(found.concepts.every((c) => typeof c.content === 'string' && typeof c.truncated === 'boolean' && 'elementary' in c));
  await opRejects(`select concept_review_job_search($1::uuid, $2::bigint, '{}'::text[], 3)`, [job, g2], /concept_review_job_bad_terms/);
  const courses = await r(`select concept_review_job_courses($1::uuid, $2::bigint) as r`, [job, g2]);
  const c21 = courses.find((c) => c.id === P.course.id);
  assert.equal(c21.course_key, 'M2-1');
  assert.ok(c21.units.length > 0 && c21.units.every((u) => u.id && u.path));
  await opRejects(`select concept_review_job_targets($1::uuid, $2::bigint, 5)`, [job, gen], /concept_review_job_lease_lost/);
  await t.asUser(() => t.rejects(`select concept_review_job_courses($1::uuid, $2::bigint)`, [job, g2], /forbidden/));
  const features = await r(`select ai_think_db_features() as r`);
  assert.deepEqual([features.concept_review_jobs, features.concept_review_job_batch], [1, 1]);
});

test('한도: 카드 한 장에 검토 20개까지, 고치기 카드도 대기 카드 장수에 들어 넘치면 다음으로 미룬다', async () => {
  const { job, gen, ids } = await setup(6);
  await t.exec(`update concept_review_jobs set limits = limits || '{"max_pending_cards": 3}'::jsonb where id = '${job}'`);
  await targets(job, gen);
  const withCreate = (i) => review('foundation', {
    outcome: 'issue_found', fix: { kind: 'library', ops: [{ op: 'create', type: '정의', folder: FOLDER, name: `한도 기초 ${seq}-${i}`, content: '초등 개념' }] },
  });
  await save(job, gen, await Promise.all(ids.map((id, i) =>
    drafted(i + 1, id, [review('notation'), review('meaning'), withCreate(i), placementOk()]))));
  const first = await submit(job, gen);
  assert.deepEqual(first.positions, [1, 2, 3, 4, 5, 6], '의존 범위는 카드 칸을 쓰지 않아 여섯 개념이 함께 나간다');
  assert.equal(first.fix_actions[0].payload.items.length, 6, '만들기는 한 카드에 모은다');
  assert.equal(first.action.payload.items.filter((i) => i.scope === 'foundation').length, 0);
  const second = await submit(job, gen);
  assert.equal(second.submitted, false, '이미 낸 범위와 보류 범위는 다시 내지 않는다');

  const tight = await setup(1);
  await t.exec(`update concept_review_jobs set limits = limits || '{"max_pending_cards": 1}'::jsonb where id = '${tight.job}'`);
  await targets(tight.job, tight.gen);
  await save(tight.job, tight.gen, [await drafted(1, tight.ids[0], [
    review('notation'),
    review('foundation', { outcome: 'issue_found', fix: { kind: 'library', ops: [{ op: 'create', type: '정의', folder: FOLDER, name: `한도 하나 ${randomUUID().slice(0, 4)}`, content: '초등 개념' }] } }),
  ])]);
  const blocked = await submit(tight.job, tight.gen);
  assert.equal(blocked.submitted, false, '검토 카드와 고치기 카드를 함께 낼 자리가 없으면 내지 않는다');
  assert.equal(blocked.room, 1);
});

test('고치기 제안 검사: 필수 범위의 문제 있음엔 고치기가 있어야 하고, 남의 배치·새 개념 배치·범위에 안 맞는 고치기는 막는다', async () => {
  const { job, gen, ids, P } = await setup(2);
  await targets(job, gen);
  const bad = await save(job, gen, [
    await drafted(1, ids[0], [review('meaning', { outcome: 'issue_found' })]),
    await drafted(2, ids[1], [review('placement', { outcome: 'issue_found', fix: { kind: 'placement', ops: [{ op: 'remove', placement_id: await placementOf(ids[0]), evidence: '남의 배치' }] } })]),
  ]);
  assert.deepEqual(bad.items.map((i) => i.code.replace(/^.*?(concept_review_\w+).*$/, '$1')), ['concept_review_fix_required', 'concept_review_fix_not_own']);
  const bad2 = await save(job, gen, [
    await drafted(1, ids[0], [review('foundation', { outcome: 'issue_found', fix: { kind: 'library', ops: [{ op: 'create', type: '정의', folder: FOLDER, name: '배치하려는 새 개념', content: '내용', place_unit_id: P.leaves[0].id }] } })]),
    await drafted(2, ids[1], [review('notation', { fix: { kind: 'library', ops: [{ op: 'edit', content: '고친 본문' }] } })]),
  ]);
  assert.deepEqual(bad2.items.map((i) => i.code.replace(/^.*?(concept_review_\w+).*$/, '$1')), ['concept_review_fix_no_place', 'concept_review_bad_fix']);
  const ok = await save(job, gen, [
    await drafted(1, ids[0], [review('notation', { outcome: 'issue_found', fix: { kind: 'library', ops: [{ op: 'edit', name: null, content: '통합 개념은 약수를 써서 정의한다', type: null, folder: null, unit_id: null, placement_id: null }] } })]),
  ]);
  assert.equal(ok.items[0].status, 'saved');
  const sub = await submit(job, gen);
  const edit = sub.fix_actions[0].payload.items[0];
  assert.deepEqual([edit.op, edit.concept_id], ['edit', ids[0]], '고치기는 그 개념에만');
});
