// 기본 서술(개념 본문) 수정안: 수정안은 따로 저장되고, 운영자가 이유를 적어 확정해야 본문이 바뀐다.
// 수정안을 쓴 뒤 본문이 바뀌면 확정을 막는다. 확률 예시는 시험 DB에만 쓴다.
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { insertConcept, openConceptTestDb, seedConcepts } from '../concept_fixture.mjs';

let t;
let S;

before(async () => {
  t = await openConceptTestDb();
  S = await seedConcepts(t);
});
after(() => t?.close());

const op = (fn) => t.asSuperadmin(fn, S.operator);
const md5 = (s) => createHash('md5').update(s, 'utf8').digest('hex');

const save = (concept, content, base, expected = null, note = null) =>
  op(async () =>
    (await t.one(
      `select concept_content_save_draft($1::uuid, $2, $3, $4, $5::timestamptz) as r`,
      [concept, content, note, md5(base), expected],
    )).r);

const confirm = (concept, savedAt, note) =>
  op(async () =>
    (await t.one(`select concept_content_confirm($1::uuid, $2::timestamptz, $3) as r`, [concept, savedAt, note])).r);

const discard = (concept, savedAt) =>
  op(async () => (await t.one(`select concept_content_discard_draft($1::uuid, $2::timestamptz) as r`, [concept, savedAt])).r);

const contentOf = async (concept) => (await t.one(`select content from concepts where id = $1::uuid`, [concept])).content;
const draftOf = (concept) =>
  op(() => t.one(`select content, note, origin, base_md5, saved_at from concept_content_drafts where concept_id = $1::uuid`, [concept]));
const revisionsOf = (concept) =>
  op(() =>
    t.all(
      `select content, via, note, draft_origin from concept_content_revisions where concept_id = $1::uuid order by changed_at, id`,
      [concept],
    ));

const BASE = '모든 경우의 수에 대한 사건 $A$가 일어나는 경우의 수의 비율';
const PROPOSAL = '각 경우가 일어날 가능성이 같을 때, 모든 경우의 수에 대한 사건 $A$가 일어나는 경우의 수의 비율';

test('수정안을 저장해도 본문은 그대로이고, 운영자만 쓰고 읽는다', async () => {
  const concept = await insertConcept(t, '확률(수정안 시험)', S.folder, BASE);
  await t.asUser(() =>
    t.rejects(
      `select concept_content_save_draft($1::uuid, $2, null, $3, null)`,
      [concept, PROPOSAL, md5(BASE)],
      /concept_statement_forbidden/,
    ));
  await t.asAnon(() =>
    t.rejects(`select concept_content_save_draft($1::uuid, $2, null, $3, null)`, [concept, PROPOSAL, md5(BASE)], /permission denied/));

  const row = await save(concept, PROPOSAL, BASE, null, '조건(같은 정도로 기대됨)이 빠져 있음');
  assert.equal(row.content, PROPOSAL);
  assert.equal(row.origin, 'owner');
  assert.equal(row.base_md5, md5(BASE));
  assert.equal(await contentOf(concept), BASE, '확정 전에는 본문이 바뀌지 않는다');
  assert.equal((await revisionsOf(concept)).length, 0);
  assert.equal((await t.asUser(() => t.all(`select 1 from concept_content_drafts`))).length, 0);
  await op(() =>
    t.rejects(`update concept_content_drafts set content = 'x' where concept_id = $1::uuid`, [concept], /permission denied/));
  await op(() =>
    t.rejects(
      `insert into concept_content_drafts (concept_id, content, base_md5, saved_at) values ($1::uuid, 'x', $2, now())`,
      [concept, md5(BASE)],
      /permission denied/,
    ));
});

test('그사이 바뀐 수정안·본문은 저장을 막는다', async () => {
  const concept = await insertConcept(t, '확률(그사이 바뀜)', S.folder, BASE);
  const first = await save(concept, PROPOSAL, BASE);
  await op(() => t.rejects(`select concept_content_save_draft($1::uuid, 'x', null, $2, null)`, [concept, md5(BASE)], /concept_content_draft_stale/));
  const second = await save(concept, `${PROPOSAL}.`, BASE, first.saved_at);
  assert.notEqual(second.saved_at, first.saved_at);
  await op(() =>
    t.rejects(
      `select concept_content_save_draft($1::uuid, 'y', null, $2, $3::timestamptz)`,
      [concept, md5(BASE), first.saved_at],
      /concept_content_draft_stale/,
    ));
  await op(() =>
    t.rejects(
      `select concept_content_save_draft($1::uuid, 'y', null, $2, $3::timestamptz)`,
      [concept, md5('옛 본문'), second.saved_at],
      /concept_content_stale/,
    ));
  await op(() =>
    t.rejects(
      `select concept_content_save_draft($1::uuid, '   ', null, $2, $3::timestamptz)`,
      [concept, md5(BASE), second.saved_at],
      /concept_content_required/,
    ));
});

test('지금 본문과 같은 글로 저장하면 수정안을 지운다', async () => {
  const concept = await insertConcept(t, '확률(되돌림)', S.folder, BASE);
  const row = await save(concept, PROPOSAL, BASE);
  const back = await save(concept, BASE, BASE, row.saved_at);
  assert.equal(back.removed, true);
  assert.equal(await draftOf(concept), undefined);
});

test('확정하면 본문이 바뀌고 고치기 전 값과 이유가 남는다. 이유 없이는 확정하지 않는다', async () => {
  const concept = await insertConcept(t, '확률(확정)', S.folder, BASE);
  const row = await save(concept, PROPOSAL, BASE, null, '조건 보완');
  await op(() =>
    t.rejects(`select concept_content_confirm($1::uuid, $2::timestamptz, '  ')`, [concept, row.saved_at], /concept_content_note_required/));
  await op(() =>
    t.rejects(`select concept_content_confirm($1::uuid, null, '이유')`, [concept], /concept_content_no_draft/));
  const out = await confirm(concept, row.saved_at, '다른 교재에 조건이 적혀 있어 보완');
  assert.equal(out.content, PROPOSAL);
  assert.equal(await contentOf(concept), PROPOSAL);
  assert.equal(await draftOf(concept), undefined, '확정하면 수정안은 비워진다');
  const revs = await revisionsOf(concept);
  assert.equal(revs.length, 1);
  assert.equal(revs[0].content, BASE);
  assert.equal(revs[0].via, 'draft');
  assert.equal(revs[0].note, '다른 교재에 조건이 적혀 있어 보완');
  assert.equal(revs[0].draft_origin, 'owner');

  await op(() => t.exec(`update concepts set content = '바로 고친 본문' where id = '${concept}'`));
  const after = await revisionsOf(concept);
  assert.equal(after.length, 2);
  assert.equal(after[1].via, 'direct', '같은 연결에서 바로 고친 것은 이유가 따라붙지 않는다');
  assert.equal(after[1].note, null);
});

test('수정안을 쓴 뒤 본문이 바뀌면 확정을 막고, 지금 본문과 비교해 다시 저장하면 풀린다', async () => {
  const concept = await insertConcept(t, '확률(바탕 바뀜)', S.folder, BASE);
  const row = await save(concept, PROPOSAL, BASE);
  await op(() => t.exec(`update concepts set content = '다른 창에서 고친 본문' where id = '${concept}'`));
  await op(() =>
    t.rejects(`select concept_content_confirm($1::uuid, $2::timestamptz, '이유')`, [concept, row.saved_at], /concept_content_base_changed/));
  assert.equal(await contentOf(concept), '다른 창에서 고친 본문');
  const rebased = await save(concept, PROPOSAL, '다른 창에서 고친 본문', row.saved_at);
  const out = await confirm(concept, rebased.saved_at, '다시 비교함');
  assert.equal(out.content, PROPOSAL);
});

test('수정안을 버리면 본문은 그대로다. 수정안이 있는 개념은 지우지 않고 수정안도 남는다', async () => {
  const concept = await insertConcept(t, '확률(버림)', S.folder, BASE);
  const row = await save(concept, PROPOSAL, BASE);
  await op(() => t.rejects(`select concept_content_discard_draft($1::uuid, now())`, [concept], /concept_content_draft_stale/));
  const out = await discard(concept, row.saved_at);
  assert.equal(out.removed, true);
  assert.equal(await contentOf(concept), BASE);
  assert.equal((await revisionsOf(concept)).length, 0);

  const again = await insertConcept(t, '확률(지움)', S.folder, BASE);
  await save(again, PROPOSAL, BASE);
  await t.rejects(`delete from concepts where id = $1::uuid`, [again], /concept_delete_attached/);
  assert.equal((await t.all(`select 1 from concept_content_drafts where concept_id = $1::uuid`, [again])).length, 1);
});

test('없는 개념에는 수정안을 쓰지 않는다', async () => {
  await op(() =>
    t.rejects(
      `select concept_content_save_draft($1::uuid, 'x', null, $2, null)`,
      [S.folder, md5('')],
      /concept_content_concept_not_found/,
    ));
});
