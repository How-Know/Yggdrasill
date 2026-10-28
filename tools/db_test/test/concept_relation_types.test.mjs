// 개념 관계 유형 여섯 가지: 방향·맥락·근거·결정 기록·다시 검토할 관계, 직접 저장의 판 확인, 관계 고치기 카드.
// 카드는 승인한 항목만 반영하고, 제안 뒤 두 개념의 글이나 관계가 바뀐 항목은 반영하지 않으며, 빼기는 개념을 지우지 않는다.
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { insertConcept, openConceptTestDb, seedConcepts } from '../concept_fixture.mjs';

let t;
let S;
let conv;
let f;

before(async () => {
  t = await openConceptTestDb();
  S = await seedConcepts(t);
  conv = (await t.one(`insert into ai_conversations (title) values ('개념 관계') returning id`)).id;
  f = (await t.one(`insert into concept_categories (name) values ('관계 유형') returning id`)).id;
});
after(() => t?.close());

const op = (sql, params = []) => t.asSuperadmin(() => t.one(sql, params), S.operator);
const opRejects = (sql, params, pattern) => t.asSuperadmin(() => t.rejects(sql, params, pattern), S.operator);

const SAVE = `select concept_relation_save($1::uuid, $2::int, $3::uuid, $4::uuid, $5, $6, $7, $8) as r`;
const save = async ({ id = null, rev = null, from, to, kind, context = null, basis = null, note = null }) =>
  (await op(SAVE, [id, rev, from, to, kind, context, basis, note])).r;
const saveRejects = ({ id = null, rev = null, from, to, kind, context = null, basis = null, note = null }, pattern) =>
  opRejects(SAVE, [id, rev, from, to, kind, context, basis, note], pattern);
const list = async (id) => (await op(`select concept_relation_list($1::uuid) as r`, [id])).r;
const textRev = async (id) => (await list(id)).text_rev;
const rows = async (from, to) =>
  (await t.all(`select * from concept_relations where concept_id = $1::uuid and related_id = $2::uuid order by created_at, id`, [from, to]));
const relCount = async () => (await t.one(`select count(*)::int as n from concept_relations`)).n;
const events = async (relationId) =>
  t.all(`select * from concept_relation_events where relation_id = $1::uuid order by created_at, id`, [relationId]);

const PROPOSE = `select * from course_think_action_propose($1::uuid, 'concept_relation_change', $2::jsonb)`;
const propose = (items, reason = '관계를 정리한다') => op(PROPOSE, [conv, JSON.stringify({ items, reason })]);
const proposeRejects = (items, pattern) => opRejects(PROPOSE, [conv, JSON.stringify({ items, reason: '관계' })], pattern);
const APPLY = `select * from course_think_action_apply($1::uuid, $2::jsonb)`;
const apply = (id, overrides = {}) => op(APPLY, [id, JSON.stringify(overrides)]);
const statusOf = async (id) => (await t.one(`select status from ai_actions where id = $1::uuid`, [id])).status;

const add = async (from, to, kind, over = {}) => ({
  op: 'add',
  concept_id: from,
  related_id: to,
  kind,
  concept_revision: await textRev(from),
  related_revision: await textRev(to),
  reason: '두 개념 본문을 읽고 판단',
  ...over,
});
// rel 은 표의 한 줄(concept_id·related_id)이나 concept_relation_save 결과(from·to)
const ends = (rel) => [rel.concept_id ?? rel.from.id, rel.related_id ?? rel.to.id];
const change = async (rel, over = {}) => ({
  op: 'change',
  relation_id: rel.id,
  rev: rel.rev,
  concept_revision: await textRev(ends(rel)[0]),
  related_revision: await textRev(ends(rel)[1]),
  reason: '맥락을 더 정확히 적는다',
  ...over,
});
const remove = async (rel, over = {}) => ({
  op: 'remove',
  relation_id: rel.id,
  rev: rel.rev,
  concept_revision: await textRev(ends(rel)[0]),
  related_revision: await textRev(ends(rel)[1]),
  reason: '관계가 맞지 않는다',
  ...over,
});
const relRow = async (id) => t.one(`select * from concept_relations where id = $1::uuid`, [id]);

test('새 유형 넷과 방향: "이 개념 → 기준 개념"으로 저장되고, 두 쪽 목록에서 상대와 방향이 맞게 보인다', async () => {
  const square = await insertConcept(t, '정사각형', f, '네 변의 길이가 같고 네 각이 직각인 사각형');
  const rect = await insertConcept(t, '직사각형', f, '네 각이 직각인 사각형');
  const r = await save({ from: square, to: rect, kind: 'kind_of', context: '사각형 분류', basis: '정의에 네 각이 직각이 들어 있다' });
  assert.equal(r.direction, 'out');
  assert.deepEqual([r.from.id, r.from.name, r.to.id, r.to.name], [square, '정사각형', rect, '직사각형']);
  assert.deepEqual([r.kind, r.context, r.basis, r.origin, r.rev], ['kind_of', '사각형 분류', '정의에 네 각이 직각이 들어 있다', 'manual', 1]);
  assert.equal(r.decision.recorded, true);
  assert.equal(r.decision.via, 'manual');
  assert.deepEqual(r.judged, { recorded: true, from_changed: false, to_changed: false });
  assert.equal(r.rereview, false);

  const fromRect = (await list(rect)).relations.find((x) => x.id === r.id);
  assert.equal(fromRect.direction, 'in', '기준 개념 쪽에서는 들어오는 관계');
  assert.deepEqual([fromRect.from.id, fromRect.to.id], [square, rect], '방향을 뒤집어 적지 않는다');
  const row = await relRow(r.id);
  assert.deepEqual([row.concept_id, row.related_id, row.decided_by], [square, rect, S.operator]);

  const side = await insertConcept(t, '변', f, '다각형을 이루는 선분');
  const part = await save({ from: side, to: rect, kind: 'part_of' });
  assert.equal(part.kind, 'part_of');
  const ev = await events(r.id);
  assert.equal(ev.length, 1);
  assert.deepEqual([ev[0].event, ev[0].concept_name, ev[0].related_name, ev[0].via], ['add', '정사각형', '직사각형', 'manual']);
  assert.equal(ev[0].before, null);
  assert.equal(ev[0].after.kind, 'kind_of');
});

test('근거·유도와 학습 의존은 맥락이 있어야 하고, 맥락 없는 줄은 표에도 들어가지 않는다', async () => {
  const a = await insertConcept(t, '근의 공식', f, '이차방정식의 해를 계수로 나타낸 식');
  const b = await insertConcept(t, '완전제곱식', f, '어떤 다항식의 제곱으로 나타낸 식');
  await saveRejects({ from: a, to: b, kind: 'derived_from' }, /concept_relation_context_required/);
  await saveRejects({ from: a, to: b, kind: 'depends_on', context: '   ' }, /concept_relation_context_required/);
  await assert.rejects(
    t.exec(`insert into concept_relations (concept_id, related_id, kind, origin) values ('${a}', '${b}', 'depends_on', 'manual')`),
    /concept_relations_context_required_chk/,
  );
  const d = await save({ from: a, to: b, kind: 'derived_from', context: '완전제곱식으로 고쳐 유도' });
  assert.equal(d.context, '완전제곱식으로 고쳐 유도');
  await saveRejects({ from: a, to: b, kind: 'depends_on', context: 'x'.repeat(301) }, /concept_relation_too_long/);
  await saveRejects({ from: a, to: b, kind: 'same', context: '유도' }, /concept_relation_bad_kind/);
});

test('한 쌍 규칙: 유형이 다르면 함께 두고, 같은 쌍·유형·맥락은 한 줄, 종류·구성은 반대 방향을 막고, 학습 의존은 맥락이 다르면 반대도 둔다', async () => {
  const a = await insertConcept(t, '쌍 가', f, '가');
  const b = await insertConcept(t, '쌍 나', f, '나');
  const dep = await save({ from: a, to: b, kind: 'depends_on', context: '증명하기' });
  await save({ from: a, to: b, kind: 'derived_from', context: '증명하기' });
  await save({ from: a, to: b, kind: 'extends' });
  await saveRejects({ from: a, to: b, kind: 'depends_on', context: '  증명하기 ' }, /concept_relation_exists/);
  await save({ from: a, to: b, kind: 'depends_on', context: '계산하기' });
  await saveRejects({ from: b, to: a, kind: 'depends_on', context: '증명하기' }, /concept_relation_reverse_exists/);
  await save({ from: b, to: a, kind: 'depends_on', context: '그래프 그리기' });
  assert.equal((await rows(a, b)).length, 4);
  await save({ from: a, to: b, kind: 'derived_from', context: 'Proof by AM-GM' });
  await saveRejects({ from: a, to: b, kind: 'derived_from', context: 'proof BY am-gm ' }, /concept_relation_exists/);

  const c = await insertConcept(t, '쌍 다', f, '다');
  const d = await insertConcept(t, '쌍 라', f, '라');
  await save({ from: c, to: d, kind: 'kind_of', context: '분류 하나' });
  await saveRejects({ from: d, to: c, kind: 'kind_of', context: '분류 둘' }, /concept_relation_reverse_exists/);
  await save({ from: c, to: d, kind: 'part_of' });
  await saveRejects({ from: d, to: c, kind: 'part_of' }, /concept_relation_reverse_exists/);
  await save({ from: d, to: c, kind: 'depends_on', context: '쓰기' });

  // 확장·특수한 경우는 전과 같다: 한 방향에 한 줄, 옛 넣기는 종류를 바꾸고, 반대 방향은 막는다.
  const legacy = (await op(`select concept_relation_set($1::uuid, $2::uuid, 'special_case') as r`, [a, b])).r;
  const ext = (await rows(a, b)).find((r) => r.kind === 'special_case');
  assert.equal(legacy.id, ext.id);
  await opRejects(`select concept_relation_set($1::uuid, $2::uuid, 'extends')`, [b, a], /concept_relation_reverse_exists/);
  await saveRejects({ from: a, to: b, kind: 'extends' }, /concept_relation_exists/);
  assert.equal(dep.kind, 'depends_on');
});

test('이 기능 전 관계는 결정·판단 지문이 "기록 없음"이고, 판단 뒤 두 개념의 글이 바뀌면 다시 검토할 관계로 보인다', async () => {
  const a = await insertConcept(t, '옛 가', f, '옛 본문 가');
  const b = await insertConcept(t, '옛 나', f, '옛 본문 나');
  const old = (await t.one(
    `insert into concept_relations (concept_id, related_id, kind, origin) values ($1::uuid, $2::uuid, 'extends', 'draft') returning id`,
    [a, b],
  )).id;
  const before = (await list(a)).relations.find((x) => x.id === old);
  assert.deepEqual(before.decision, { recorded: false });
  assert.deepEqual(before.judged, { recorded: false });
  assert.equal(before.rereview, null, '판단 때 지문이 없으면 다시 검토할지 모른다');
  assert.equal(before.origin, 'draft');

  const c = await insertConcept(t, '새 가', f, '새 본문');
  const r = await save({ from: c, to: b, kind: 'kind_of' });
  await t.exec(`update concepts set content = '고친 본문 나' where id = '${b}'`);
  const now = (await list(c)).relations.find((x) => x.id === r.id);
  assert.equal(now.rereview, true);
  assert.deepEqual(now.judged, { recorded: true, from_changed: false, to_changed: true });
  await t.exec(`update concepts set name = '이름만 바꿈' where id = '${c}'`);
  assert.equal((await list(c)).relations.find((x) => x.id === r.id).judged.from_changed, true);
});

test('직접 고치기는 읽은 판이 지금과 같아야 하고, 바뀐 게 없으면 막고, 빼기도 판을 본다', async () => {
  const a = await insertConcept(t, '판 가', f, '가');
  const b = await insertConcept(t, '판 나', f, '나');
  const r = await save({ from: a, to: b, kind: 'depends_on', context: '풀기' });
  const r2 = await save({ id: r.id, rev: 1, from: a, to: b, kind: 'depends_on', context: '풀기', basis: '교과서 예제에서 씀' });
  assert.equal(r2.rev, 2);
  assert.equal(r2.basis, '교과서 예제에서 씀');
  await saveRejects({ id: r.id, rev: 1, from: a, to: b, kind: 'depends_on', context: '다른 맥락' }, /concept_relation_stale/);
  await saveRejects({ id: r.id, rev: 2, from: a, to: b, kind: 'depends_on', context: '풀기', basis: '교과서 예제에서 씀' },
    /concept_relation_unchanged/);
  await saveRejects({ id: r.id, from: a, to: b, kind: 'depends_on', context: '풀기' }, /concept_relation_rev_required/);
  await opRejects(`select concept_relation_remove($1::uuid, 1)`, [r.id], /concept_relation_stale/);
  const ev = await events(r.id);
  assert.deepEqual(ev.map((e) => e.event), ['add', 'change']);
  assert.equal(ev[1].before.basis, null);
  assert.equal(ev[1].after.basis, '교과서 예제에서 씀');
  assert.deepEqual(await op(`select concept_relation_remove($1::uuid, 2) as r`, [r.id]).then((x) => x.r), { id: r.id, removed: true });
  assert.equal((await events(r.id)).at(-1).event, 'remove');
});

test('카드: 미리보기에 두 개념·방향·전후가 보이고, 제안만으로는 아무것도 저장하지 않으며, 고른 항목만 반영한다', async () => {
  const a = await insertConcept(t, '카드 가', f, '가');
  const b = await insertConcept(t, '카드 나', f, '나');
  const c = await insertConcept(t, '카드 다', f, '다');
  const keep = await save({ from: a, to: c, kind: 'part_of', context: '처음 맥락' });
  const n0 = await relCount();
  const card = await propose([
    await add(a, b, 'depends_on', { context: '증명하기', basis: '증명 첫 줄에서 씀', uncertainty: '다른 증명도 있음' }),
    await add(b, c, 'kind_of'),
    await change(keep, { context: '바꾼 맥락' }),
  ]);
  assert.equal(card.kind, 'concept_relation_change');
  assert.equal(await relCount(), n0, '제안은 저장하지 않는다');
  const p = card.preview.items;
  assert.deepEqual([p[0].from.name, p[0].to.name, p[0].op], ['카드 가', '카드 나', 'add']);
  assert.deepEqual(p[0].after, { kind: 'depends_on', context: '증명하기', basis: '증명 첫 줄에서 씀', note: null });
  assert.equal(p[0].uncertainty, '다른 증명도 있음');
  assert.equal(p[0].before, null);
  assert.equal(p[2].before.context, '처음 맥락');
  assert.equal(p[2].after.context, '바꾼 맥락');
  assert.deepEqual(card.preview.counts, { add: 2, change: 1, remove: 0 });
  assert.equal((await list(a)).pending.length, 2, '승인을 기다리는 항목이 개념 쪽에서 보인다');

  const done = await apply(card.id, { skip: [2] });
  assert.equal(done.status, 'applied');
  assert.deepEqual(done.result.items.map((x) => [x.i, x.status]), [[1, 'applied'], [2, 'skipped'], [3, 'applied']]);
  assert.equal((await rows(b, c)).length, 0, '고르지 않은 항목은 넣지 않는다');
  const added = (await rows(a, b))[0];
  assert.deepEqual([added.kind, added.context, added.origin, added.decided_via, added.action_id, added.decided_by],
    ['depends_on', '증명하기', 'think', 'think', card.id, S.operator]);
  const changed = await relRow(keep.id);
  assert.deepEqual([changed.context, changed.rev, changed.origin, changed.decided_via], ['바꾼 맥락', 2, 'manual', 'think'],
    '바꾼 줄의 출처(origin)는 그대로, 결정은 이 카드');
  const ev = (await events(added.id))[0];
  assert.deepEqual([ev.via, ev.action_id, ev.action_item, ev.uncertainty], ['think', card.id, 1, '다른 증명도 있음']);
  await opRejects(APPLY, [card.id, '{}'], /action_not_pending/);
});

test('출처와 결정은 섞지 않는다: 초안에서 온 옛 관계를 카드로 고쳐도 출처는 초안, 결정 기록은 카드와 승인한 사람', async () => {
  const a = await insertConcept(t, '출처 가', f, '가');
  const b = await insertConcept(t, '출처 나', f, '나');
  const old = (await t.one(
    `insert into concept_relations (concept_id, related_id, kind, origin) values ($1::uuid, $2::uuid, 'extends', 'draft') returning *`,
    [a, b],
  ));
  const card = await propose([await change(old, { basis: '본문에서 정의역을 넓힌다고 씀' })]);
  assert.equal(card.preview.items[0].before.origin, 'draft');
  assert.equal(card.preview.items[0].before.decided, false);
  await apply(card.id);
  const r = (await list(a)).relations.find((x) => x.id === old.id);
  assert.equal(r.origin, 'draft');
  assert.equal(r.decision.via, 'think');
  assert.equal(r.decision.action_id, card.id);
});

test('거절한 카드는 아무것도 저장하지 않는다', async () => {
  const a = await insertConcept(t, '거절 가', f, '가');
  const b = await insertConcept(t, '거절 나', f, '나');
  const n0 = await relCount();
  const e0 = (await t.one(`select count(*)::int as n from concept_relation_events`)).n;
  const card = await propose([await add(a, b, 'kind_of')]);
  await op(`select * from ai_action_reject($1::uuid)`, [card.id]);
  assert.equal(await statusOf(card.id), 'rejected');
  assert.equal(await relCount(), n0);
  assert.equal((await t.one(`select count(*)::int as n from concept_relation_events`)).n, e0);
  await opRejects(APPLY, [card.id, '{}'], /action_not_pending/);
  await opRejects(APPLY, [(await propose([await add(a, b, 'kind_of')])).id, JSON.stringify({ skip: [1] })],
    /course_think_nothing_selected/);
});

test('오래된 제안은 새 직접 고침을 덮어쓰지 않는다: 관계의 판이나 두 개념의 글이 바뀐 항목은 반영하지 않는다', async () => {
  const a = await insertConcept(t, '늦은 가', f, '가');
  const b = await insertConcept(t, '늦은 나', f, '나');
  const c = await insertConcept(t, '늦은 다', f, '다');
  const r = await save({ from: a, to: b, kind: 'depends_on', context: '처음' });
  const card = await propose([
    await change(r, { context: '카드가 바꾸려는 맥락' }),
    await add(a, c, 'kind_of'),
  ]);
  await save({ id: r.id, rev: 1, from: a, to: b, kind: 'depends_on', context: '사람이 직접 고친 맥락' });
  await t.exec(`update concepts set content = '다를 고침' where id = '${c}'`);
  await opRejects(APPLY, [card.id, '{}'], /course_think_all_failed:concept_relation_stale/);
  assert.equal(await statusOf(card.id), 'proposed');
  assert.equal((await relRow(r.id)).context, '사람이 직접 고친 맥락');
  assert.equal((await rows(a, c)).length, 0);

  const d = await insertConcept(t, '늦은 라', f, '라');
  const card2 = await propose([await add(a, d, 'part_of'), await add(b, d, 'part_of')]);
  await t.exec(`update concepts set name = '늦은 라 고침' where id = '${d}'`);
  const e = await insertConcept(t, '늦은 마', f, '마');
  const card3 = await propose([await add(a, e, 'part_of'), await add(b, e, 'part_of')]);
  await t.exec(`update concepts set content = '가 고침' where id = '${a}'`);
  const res = await apply(card3.id);
  assert.deepEqual(res.result.items.map((x) => [x.i, x.status, x.code ?? null]),
    [[1, 'failed', 'concept_relation_concept_stale'], [2, 'applied', null]]);
  await opRejects(APPLY, [card2.id, '{}'], /course_think_all_failed:concept_relation_concept_stale/);

  const stale = { ...(await change(await relRow(r.id), { context: '또' })), rev: 1 };
  await proposeRejects([stale], /concept_relation_bad_item:1:concept_relation_stale/);
  const staleText = { ...(await add(b, c, 'kind_of')), related_revision: 'aaaaaaaaaaaa-x-y' };
  await proposeRejects([staleText], /concept_relation_bad_item:1:concept_relation_concept_stale/);
});

test('빼기는 관계만 빼고 개념은 지우지 않는다. 남은 이력은 개념 지우기를 막지 않는다', async () => {
  const a = await insertConcept(t, '빼기 가', f, '가');
  const b = await insertConcept(t, '빼기 나', f, '나');
  const r = await save({ from: a, to: b, kind: 'kind_of' });
  const check0 = (await op(`select concept_delete_check($1::uuid) as r`, [a])).r;
  assert.equal(check0.deletable, false, '관계가 붙은 개념은 지우지 않는다(1단계 보호)');
  const card = await propose([await remove(await relRow(r.id))]);
  assert.equal(card.preview.items[0].after, null);
  await apply(card.id);
  assert.equal((await t.one(`select count(*)::int as n from concepts where id in ($1::uuid, $2::uuid)`, [a, b])).n, 2);
  assert.equal((await rows(a, b)).length, 0);
  const ev = await events(r.id);
  assert.deepEqual(ev.map((e) => e.event), ['add', 'remove']);
  assert.equal(ev[1].before.kind, 'kind_of');

  const check = (await op(`select concept_delete_check($1::uuid) as r`, [a])).r;
  assert.equal(check.deletable, true, '이력은 붙은 것으로 세지 않는다');
  await op(`select concept_delete($1::uuid) as r`, [a]);
  const kept = await events(r.id);
  assert.equal(kept.length, 2, '개념을 지워도 이력은 남는다');
  assert.equal(kept[1].concept_name, '빼기 가');
});

test('겹치는 요청은 겹친 줄을 만들지 않는다: 한 카드 안 같은 항목, 같은 넣기를 담은 두 카드', async () => {
  const a = await insertConcept(t, '겹침 가', f, '가');
  const b = await insertConcept(t, '겹침 나', f, '나');
  const one = await add(a, b, 'depends_on', { context: '풀기' });
  await proposeRejects([one, { ...one, context: ' 풀기 ' }], /concept_relation_bad_item:2:concept_relation_duplicate/);
  const c1 = await propose([one]);
  const c2 = await propose([one]);
  assert.equal(c2.preview.items[0].pending_elsewhere, 1, '같은 쌍을 다루는 다른 카드가 있음을 알린다');
  await apply(c1.id);
  await opRejects(APPLY, [c2.id, '{}'], /course_think_all_failed:concept_relation_exists/);
  assert.equal((await rows(a, b)).length, 1);
  await proposeRejects([one], /concept_relation_bad_item:1:concept_relation_exists/);

  const r = (await rows(a, b))[0];
  await proposeRejects([await change(r, { context: '바꿈' }), await remove(r)], /concept_relation_bad_item:2:concept_relation_duplicate/);
  // 같은 카드에서 빼고 다시 넣는 것은 된다(빼기를 먼저 반영한다).
  const swap = await propose([await add(a, b, 'depends_on', { context: '풀기' }), await remove(r)]);
  const res = await apply(swap.id);
  assert.deepEqual(res.result.items.map((x) => x.status), ['applied', 'applied']);
  assert.equal((await rows(a, b)).length, 1);
});

test('조건이 있는 관계는 맥락과 함께 보이고, 같은 개념 검토가 열린 쌍은 미리보기에 알린다', async () => {
  const a = await insertConcept(t, '조건 가', f, '가');
  const b = await insertConcept(t, '조건 나', f, '나');
  await save({ from: a, to: b, kind: 'depends_on', context: '삼각형 넓이 공식으로 증명할 때' });
  const r = (await list(a)).relations[0];
  assert.equal(r.kind, 'depends_on');
  assert.equal(r.context, '삼각형 넓이 공식으로 증명할 때');
  const detail = (await op(`select concept_think_detail($1::uuid) as r`, [a])).r;
  assert.equal(detail.relations[0].context, '삼각형 넓이 공식으로 증명할 때');

  await op(`select concept_review_open($1::uuid, $2::uuid, '같은지 확인') as r`, [a, b]);
  const card = await propose([await add(b, a, 'derived_from', { context: '정의에서 바로' })]);
  assert.equal(card.preview.items[0].open_same_concept_review, true);
  await proposeRejects([await add(a, b, 'kind_of', { reason: '' })], /concept_relation_bad_item:1:concept_relation_text_required/);
  await proposeRejects([{ op: 'move', reason: '이동' }], /concept_relation_bad_item:1:concept_relation_bad_op/);
  await proposeRejects([await add(a, b, 'depends_on')], /concept_relation_bad_item:1:concept_relation_context_required/);
  await proposeRejects([{ ...(await add(a, b, 'kind_of')), concept_revision: null }],
    /concept_relation_bad_item:1:concept_relation_revision_required/);
  const many = await add(a, b, 'kind_of');
  await proposeRejects(Array.from({ length: 21 }, () => many), /concept_relation_too_many/);
  await proposeRejects([], /concept_relation_no_items/);
});

test('권한: 일반 사용자는 읽기·저장·빼기를 못 하고, 내부 함수와 이력 표에 직접 쓰지 못한다', async () => {
  const a = await insertConcept(t, '권한 가', f, '가');
  const b = await insertConcept(t, '권한 나', f, '나');
  const r = await save({ from: a, to: b, kind: 'kind_of' });
  await t.asUser(() => t.rejects(`select concept_relation_list($1::uuid)`, [a], /concept_relation_forbidden/));
  await t.asUser(() => t.rejects(SAVE, [null, null, b, a, 'part_of', null, null, null], /concept_relation_forbidden/));
  await t.asUser(() => t.rejects(`select concept_relation_remove($1::uuid, 1)`, [r.id], /concept_relation_forbidden/));
  await opRejects(
    `select concept_relation_write(null, null, $1::uuid, $2::uuid, 'part_of', null, null, null, 'manual', null, null, null, null, null, true)`,
    [b, a], /permission denied/);
  await opRejects(`select concept_relation_drop($1::uuid, null, 'manual', null, null, null, null)`, [r.id], /permission denied/);
  await opRejects(`select course_think_propose_relation($1::uuid, '{}'::jsonb, 'x')`, [conv], /permission denied/);
  await opRejects(`insert into concept_relation_events (relation_id, event, concept_id, related_id, via)
    values ($1::uuid, 'add', $2::uuid, $3::uuid, 'manual')`, [r.id, a, b], /permission denied/);
  assert.equal((await t.asUser(() => t.all(`select id from concept_relation_events`))).length, 0);
  const features = (await op(`select ai_think_db_features() as r`)).r;
  assert.equal(features.concept_relation_change, 1);
  assert.equal(features.concept_review, 1);
});

test('관계 범위 검토의 판은 맥락이 바뀌면 바뀌고, 관계가 없는 개념의 판은 그대로다', async () => {
  const a = await insertConcept(t, '지문 가', f, '가');
  const b = await insertConcept(t, '지문 나', f, '나');
  const relMark = async (id) => (await t.one(`select concept_review_relation_mark($1::uuid) as r`, [id])).r;
  const empty = await relMark(a);
  assert.equal(empty, (await t.one(`select md5('[]') as r`)).r);
  const r = await save({ from: a, to: b, kind: 'depends_on', context: '처음' });
  const m1 = await relMark(a);
  await save({ id: r.id, rev: 1, from: a, to: b, kind: 'depends_on', context: '다음' });
  assert.notEqual(await relMark(a), m1);
});
