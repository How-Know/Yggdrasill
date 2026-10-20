// 개념 탭 정리 기준: 초안 저장은 확정본을 바꾸지 않고, 확정은 화면에서 본 저장 초안만 올리며 기록이 남는다.
// 운영자만 읽고 쓰며, 기준 표에는 직접 쓰지 못한다. 연결·출처는 운영자가 넣은 것만 있고 개념이 지워지면 같이 사라진다.
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { insertConcept, openConceptTestDb, seedConcepts } from '../concept_fixture.mjs';

let t;
let S;

before(async () => {
  t = await openConceptTestDb();
  S = await seedConcepts(t);
});
after(() => t?.close());

const op = (fn) => t.asSuperadmin(fn, S.operator);

const create = (title, body = '', origin = 'owner') =>
  op(async () => (await t.one(`select concept_criteria_create($1, $2, $3) as r`, [title, body, origin])).r);

const saveDraft = (row, title, body) =>
  op(async () =>
    (await t.one(
      `select concept_criteria_save_draft($1::uuid, $2, $3, $4::int, $5::timestamptz) as r`,
      [row.id, title, body, row.version, row.draft_saved_at],
    )).r);

const confirm = (row, note = null) =>
  op(async () =>
    (await t.one(
      `select concept_criteria_confirm($1::uuid, $2::int, $3::timestamptz, $4) as r`,
      [row.id, row.version, row.draft_saved_at, note],
    )).r);

const discard = (row) =>
  op(async () =>
    (await t.one(
      `select concept_criteria_discard_draft($1::uuid, $2::int, $3::timestamptz) as r`,
      [row.id, row.version, row.draft_saved_at],
    )).r);

const revisions = (id) =>
  t.all(`select version, title, body, note from concept_criteria_revisions where criterion_id = $1::uuid order by version`, [id]);

test('운영자만 기준을 만들고 읽는다', async () => {
  await t.asUser(() =>
    t.rejects(`select concept_criteria_create('지식 분류 기준', '', 'owner')`, [], /concept_criteria_forbidden/));
  await t.asAnon(() =>
    t.rejects(`select concept_criteria_create('지식 분류 기준', '', 'owner')`, [], /permission denied/));
  const row = await create('지식 분류 기준', '사실적·개념적·절차적·메타인지');
  assert.equal(row.version, 0);
  assert.equal(row.title, null);
  assert.equal(row.draft_title, '지식 분류 기준');
  assert.equal(row.draft_origin, 'owner');
  const seen = await t.asUser(() => t.all(`select id from concept_criteria`));
  assert.equal(seen.length, 0);
  const mine = await op(() => t.all(`select id from concept_criteria where id = $1::uuid`, [row.id]));
  assert.equal(mine.length, 1);
});

test('기준 표에는 운영자도 직접 쓰지 못한다', async () => {
  const row = await create('표 직접 쓰기');
  await op(() =>
    t.rejects(`insert into concept_criteria (draft_title, draft_body, draft_origin, draft_saved_at) values ('x', '', 'owner', now())`, [], /permission denied/));
  await op(() => t.rejects(`update concept_criteria set title = 'x', version = 1, confirmed_at = now() where id = $1::uuid`, [row.id], /permission denied/));
  await op(() => t.rejects(`delete from concept_criteria where id = $1::uuid`, [row.id], /permission denied/));
  await op(() => t.rejects(`insert into concept_criteria_revisions (criterion_id, version, title, body) values ($1::uuid, 1, 'x', '')`, [row.id], /permission denied/));
});

test('초안을 저장해도 확정본은 그대로이고, 확정하면 판이 오르고 기록이 남는다', async () => {
  let row = await create('노드 분리·통합 기준', '처음 초안');
  row = await confirm(row, '첫 확정');
  assert.equal(row.version, 1);
  assert.equal(row.title, '노드 분리·통합 기준');
  assert.equal(row.body, '처음 초안');
  assert.equal(row.draft_title, null);

  row = await saveDraft(row, '노드 분리·통합 기준', '고친 초안');
  assert.equal(row.version, 1);
  assert.equal(row.body, '처음 초안', '확정본은 초안 저장으로 바뀌지 않는다');
  assert.equal(row.draft_body, '고친 초안');

  row = await confirm(row);
  assert.equal(row.version, 2);
  assert.equal(row.body, '고친 초안');
  assert.deepEqual(await revisions(row.id), [
    { version: 1, title: '노드 분리·통합 기준', body: '처음 초안', note: '첫 확정' },
    { version: 2, title: '노드 분리·통합 기준', body: '고친 초안', note: null },
  ]);
});

test('화면에서 본 판·초안 시각과 다르면 저장·확정·버리기가 막힌다', async () => {
  const row = await create('대표 용어와 다른 표현', 'A');
  const saved = await saveDraft(row, '대표 용어와 다른 표현', 'B');
  await op(() =>
    t.rejects(
      `select concept_criteria_save_draft($1::uuid, 'x', 'C', $2::int, $3::timestamptz)`,
      [row.id, row.version, row.draft_saved_at],
      /concept_criteria_stale/,
    ));
  await op(() =>
    t.rejects(`select concept_criteria_confirm($1::uuid, $2::int, $3::timestamptz, null)`, [row.id, row.version, row.draft_saved_at], /concept_criteria_stale/));
  await op(() =>
    t.rejects(`select concept_criteria_discard_draft($1::uuid, $2::int, $3::timestamptz)`, [row.id, row.version, row.draft_saved_at], /concept_criteria_stale/));
  const confirmed = await confirm(saved);
  assert.equal(confirmed.body, 'B');
});

test('확정본과 같은 내용으로 저장하면 초안이 비고, 초안이 없으면 확정·버리기를 못 한다', async () => {
  let row = await confirm(await create('개념 사이의 관계', '선행·포함'));
  await op(() =>
    t.rejects(`select concept_criteria_confirm($1::uuid, $2::int, $3::timestamptz, null)`, [row.id, row.version, row.draft_saved_at], /concept_criteria_no_draft/));
  row = await saveDraft(row, '개념 사이의 관계', '바꿔 봄');
  row = await saveDraft(row, '개념 사이의 관계', '선행·포함');
  assert.equal(row.draft_title, null);
  assert.equal(row.draft_saved_at, null);
  await op(() =>
    t.rejects(`select concept_criteria_discard_draft($1::uuid, $2::int, $3::timestamptz)`, [row.id, row.version, row.draft_saved_at], /concept_criteria_no_draft/));
});

test('초안 버리기: 확정본이 있으면 초안만 비우고, 확정한 적 없으면 항목을 지운다', async () => {
  let row = await confirm(await create('확정 사례와 예외', '사례 1'));
  row = await saveDraft(row, '확정 사례와 예외', '사례 1, 사례 2');
  row = await discard(row);
  assert.equal(row.body, '사례 1');
  assert.equal(row.draft_title, null);

  const draftOnly = await create('지울 초안');
  const removed = await discard(draftOnly);
  assert.deepEqual(removed, { id: draftOnly.id, removed: true });
  assert.equal((await t.all(`select id from concept_criteria where id = $1::uuid`, [draftOnly.id])).length, 0);
});

test('기본 틀 초안은 template 으로 남고, 운영자가 저장하면 owner 가 된다', async () => {
  const row = await create('지식 분류 기준(기본 틀)', 'Bloom 개정판 네 범주', 'template');
  assert.equal(row.draft_origin, 'template');
  assert.equal(row.version, 0);
  const saved = await saveDraft(row, row.draft_title, '운영자가 고침');
  assert.equal(saved.draft_origin, 'owner');
  await op(() => t.rejects(`select concept_criteria_create('x', '', 'ai')`, [], /concept_criteria_bad_origin/));
});

test('제목이 없거나 너무 길면 막는다', async () => {
  await op(() => t.rejects(`select concept_criteria_create('  ', '', 'owner')`, [], /concept_criteria_title_required/));
  await op(() => t.rejects(`select concept_criteria_create($1, '', 'owner')`, ['가'.repeat(201)], /concept_criteria_too_long/));
  await op(() => t.rejects(`select concept_criteria_create('x', $1, 'owner')`, ['가'.repeat(20001)], /concept_criteria_too_long/));
});

test('기준–개념 연결은 운영자만 넣고 지우며, 개념을 지우면 연결도 사라진다', async () => {
  const row = await create('연결 시험 기준');
  await t.asUser(() =>
    t.rejects(`insert into concept_criterion_links (criterion_id, concept_id) values ($1::uuid, $2::uuid)`, [row.id, S.concept], /row-level security/));
  await op(() =>
    t.one(`insert into concept_criterion_links (criterion_id, concept_id) values ($1::uuid, $2::uuid) returning created_by`, [row.id, S.concept]));
  await op(() =>
    t.one(`insert into concept_criterion_links (criterion_id, concept_id) values ($1::uuid, $2::uuid) returning created_by`, [row.id, S.concept2]));
  const links = await op(() => t.all(`select concept_id, created_by from concept_criterion_links where criterion_id = $1::uuid order by created_at`, [row.id]));
  assert.equal(links.length, 2);
  assert.equal(links[0].created_by, S.operator);
  assert.equal((await t.asUser(() => t.all(`select * from concept_criterion_links`))).length, 0);
  await op(() => t.rejects(`update concept_criterion_links set concept_id = $1::uuid`, [S.concept], /permission denied/));

  const temp = await insertConcept(t, '임시', S.folder, '');
  await op(() => t.one(`insert into concept_criterion_links (criterion_id, concept_id) values ($1::uuid, $2::uuid) returning concept_id`, [row.id, temp]));
  await t.exec(`delete from concepts where id = '${temp}'`);
  assert.equal((await t.all(`select 1 from concept_criterion_links where concept_id = $1::uuid`, [temp])).length, 0);

  await op(() => t.one(`delete from concept_criterion_links where criterion_id = $1::uuid and concept_id = $2::uuid returning concept_id`, [row.id, S.concept2]));
  assert.equal((await t.all(`select 1 from concept_criterion_links where criterion_id = $1::uuid`, [row.id])).length, 1);
});

test('개념 출처는 운영자가 볼 수 있는 학원 교재 쪽만 넣고, 같은 쪽은 한 번만, 개념과 함께 사라진다', async () => {
  const insert = (concept, academy, book, page) =>
    t.one(
      `insert into concept_sources (concept_id, academy_id, book_id, grade_label, raw_page, display_page, unit_path)
       values ($1::uuid, $2::uuid, $3::uuid, '1-1', $4::int, $4::int, array['소인수분해', '소인수분해', '소수와 합성수'])
       returning id, created_by`,
      [concept, academy, book, page],
    );
  const src = await op(() => insert(S.concept, S.academy, S.book, 8));
  assert.equal(src.created_by, S.operator);
  await op(() => t.rejects(
    `insert into concept_sources (concept_id, academy_id, book_id, grade_label, raw_page) values ($1::uuid, $2::uuid, $3::uuid, '1-1', 8)`,
    [S.concept, S.academy, S.book],
    /duplicate key/,
  ));
  await op(() => t.rejects(
    `insert into concept_sources (concept_id, academy_id, book_id, grade_label, raw_page) values ($1::uuid, $2::uuid, $3::uuid, '1-1', 3)`,
    [S.concept, S.otherAcademy, S.otherBook],
    /row-level security/,
  ));
  await op(() => t.rejects(
    `insert into concept_sources (concept_id, academy_id, book_id, grade_label, raw_page) values ($1::uuid, $2::uuid, $3::uuid, '1-1', 3)`,
    [S.concept, S.otherAcademy, S.book],
    /row-level security/,
  ));
  await t.asUser(() => t.rejects(
    `insert into concept_sources (concept_id, academy_id, book_id, grade_label, raw_page) values ($1::uuid, $2::uuid, $3::uuid, '1-1', 9)`,
    [S.concept, S.academy, S.book],
    /row-level security/,
  ));
  await t.asSuperadmin(() => t.rejects(
    `insert into concept_sources (concept_id, academy_id, book_id, grade_label, raw_page) values ($1::uuid, $2::uuid, $3::uuid, '1-1', 9)`,
    [S.concept, S.academy, S.book],
    /row-level security/,
  ), S.otherOperator);
  assert.equal((await t.asUser(() => t.all(`select * from concept_sources`))).length, 0);
  await op(() => t.rejects(`update concept_sources set raw_page = 10 where id = $1::uuid`, [src.id], /permission denied/));

  const temp = await insertConcept(t, '임시 출처', S.folder, '');
  await op(() => insert(temp, S.academy, S.book, 9));
  await t.exec(`delete from concepts where id = '${temp}'`);
  assert.equal((await t.all(`select 1 from concept_sources where concept_id = $1::uuid`, [temp])).length, 0);
});
