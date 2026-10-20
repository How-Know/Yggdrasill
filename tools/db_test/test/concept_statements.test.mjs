// 개념의 여러 서술: 한 개념에 서술을 여럿 두고 따로 고치고 확정하며, 출처·교육과정 등장 위치를 서술마다 잇는다.
// 기존 개념 본문은 기본 서술로 남고, 고치면 고치기 전 값이 기록된다. 확률 예시는 시험 DB에만 쓴다.
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

const STATEMENT_A = {
  title: '경우의 수로 본 확률',
  body: '모든 경우가 일어날 가능성이 같을 때, 전체 경우의 수에 대한 사건이 일어나는 경우의 수의 비율',
  approach: '경우의 수',
  conditions: '가능한 결과가 유한하고, 각 결과가 일어날 가능성이 같다.',
  conditions_in_source: 'check_context',
  terms: ['경우의 수', '사건'],
};
const STATEMENT_B = {
  title: '표본공간으로 본 확률',
  body: '유한한 표본공간 $S$에서 각 근원사건의 발생 가능성이 같고 $A \\subset S$일 때 $P(A)=\\frac{n(A)}{n(S)}$',
  approach: '집합과 기호',
  conditions_in_source: 'stated',
  terms: ['표본공간', '근원사건', '사건'],
};

const create = (concept, role, content) =>
  op(async () => (await t.one(`select concept_statement_create($1::uuid, $2, $3::jsonb) as r`, [concept, role, content])).r);

const saveDraft = (row, content) =>
  op(async () =>
    (await t.one(
      `select concept_statement_save_draft($1::uuid, $2::jsonb, $3::int, $4::timestamptz) as r`,
      [row.id, content, row.version, row.draft_saved_at],
    )).r);

const confirm = (row, note = null) =>
  op(async () =>
    (await t.one(
      `select concept_statement_confirm($1::uuid, $2::int, $3::timestamptz, $4) as r`,
      [row.id, row.version, row.draft_saved_at, note],
    )).r);

const discard = (row) =>
  op(async () =>
    (await t.one(
      `select concept_statement_discard_draft($1::uuid, $2::int, $3::timestamptz) as r`,
      [row.id, row.version, row.draft_saved_at],
    )).r);

const setStatement = (sourceId, statementId) =>
  op(async () => (await t.one(`select concept_source_set_statement($1::uuid, $2::uuid) as r`, [sourceId, statementId])).r);

const addSource = (concept, page, statementId = null) =>
  op(() =>
    t.one(
      `insert into concept_sources (concept_id, academy_id, book_id, grade_label, raw_page, statement_id)
       values ($1::uuid, $2::uuid, $3::uuid, '1-1', $4::int, $5::uuid) returning id, statement_id`,
      [concept, S.academy, S.book, page, statementId],
    ));

const addAppearance = (concept, statementId, curriculum, level, course, unit = []) =>
  op(() =>
    t.one(
      `insert into concept_appearances (concept_id, statement_id, curriculum_code, school_level, course_label, unit_path)
       values ($1::uuid, $2::uuid, $3, $4, $5, $6::text[]) returning id, created_by`,
      [concept, statementId, curriculum, level, course, unit],
    ));

const statementsOf = (concept) =>
  op(() =>
    t.all(
      `select id, role, version, content, draft from concept_statements where concept_id = $1::uuid order by role, sort_order`,
      [concept],
    ));

let probability;
let draftA;

test('운영자만 서술을 만들고 읽으며, 서술 표에는 직접 쓰지 못한다', async () => {
  probability = await insertConcept(t, '등가능한 유한 경우에서의 확률', S.folder, '기존 개념 본문');
  await t.asUser(() =>
    t.rejects(`select concept_statement_create($1::uuid, 'statement', $2::jsonb)`, [probability, STATEMENT_A], /concept_statement_forbidden/));
  await t.asAnon(() =>
    t.rejects(`select concept_statement_create($1::uuid, 'statement', $2::jsonb)`, [probability, STATEMENT_A], /permission denied/));
  const row = await create(probability, 'statement', STATEMENT_A);
  draftA = row;
  assert.equal(row.version, 0);
  assert.equal(row.content, null);
  assert.equal(row.draft_origin, 'owner');
  assert.equal(row.draft.title, STATEMENT_A.title);
  assert.equal(row.draft.basis, 'organized', '원문 여부를 고르지 않으면 우리가 정리한 글로 남는다');
  assert.equal((await t.asUser(() => t.all(`select id from concept_statements`))).length, 0);
  await op(() =>
    t.rejects(
      `insert into concept_statements (concept_id, role, draft, draft_origin, draft_saved_at) values ($1::uuid, 'statement', '{}'::jsonb, 'owner', now())`,
      [probability],
      /permission denied/,
    ));
  await op(() => t.rejects(`update concept_statements set version = 9 where id = $1::uuid`, [row.id], /permission denied/));
  await op(() => t.rejects(`delete from concept_statements where id = $1::uuid`, [row.id], /permission denied/));
  await op(() =>
    t.rejects(`select concept_statement_create($1::uuid, 'statement', $2::jsonb)`, [S.folder, STATEMENT_A], /concept_statement_concept_not_found/));
  await op(() =>
    t.rejects(`select concept_statement_create($1::uuid, 'definition', $2::jsonb)`, [probability, STATEMENT_A], /concept_statement_bad_role/));
});

test('한 개념에 두 서술을 두고 따로 고쳐 확정해도 다른 서술과 기본 서술은 그대로다', async () => {
  const a = await confirm(draftA, '첫 확정');
  let b = await confirm(await create(probability, 'statement', STATEMENT_B));
  assert.equal(a.version, 1);
  assert.equal(b.version, 1);

  b = await saveDraft(b, { ...STATEMENT_B, body: STATEMENT_B.body + '.' });
  assert.equal(b.content.body, STATEMENT_B.body, '초안을 저장해도 확정본은 그대로다');
  b = await confirm(b, '마침표 추가');
  assert.equal(b.version, 2);

  const all = await statementsOf(probability);
  assert.equal(all.length, 2);
  const aNow = all.find((s) => s.id === a.id);
  assert.equal(aNow.version, 1);
  assert.equal(aNow.content.body, STATEMENT_A.body);
  assert.deepEqual(aNow.content.terms, ['경우의 수', '사건']);
  assert.equal(
    (await t.one(`select content from concepts where id = $1::uuid`, [probability])).content,
    '기존 개념 본문',
  );
  const revs = await op(() =>
    t.all(`select version, content->>'body' as body, note from concept_statement_revisions where statement_id = $1::uuid order by version`, [b.id]));
  assert.deepEqual(revs, [
    { version: 1, body: STATEMENT_B.body, note: null },
    { version: 2, body: STATEMENT_B.body + '.', note: '마침표 추가' },
  ]);
  assert.equal((await t.asUser(() => t.all(`select id from concept_statement_revisions`))).length, 0);
});

test('개념 공통 내용은 개념마다 하나이고 공통 의미가 있어야 한다', async () => {
  await op(() =>
    t.rejects(`select concept_statement_create($1::uuid, 'core', $2::jsonb)`, [probability, { scope: '유한' }], /concept_statement_meaning_required/));
  const core = await create(probability, 'core', {
    meaning: '등가능한 결과가 유한할 때 사건이 일어날 가능성의 정도',
    conditions: '가능한 결과가 유한하며 하나 이상, 각 결과가 일어날 가능성이 같음',
  });
  assert.equal(core.role, 'core');
  await op(() =>
    t.rejects(`select concept_statement_create($1::uuid, 'core', $2::jsonb)`, [probability, { meaning: '둘째' }], /concept_statement_core_exists/));
  await op(() =>
    t.rejects(`select concept_statement_create($1::uuid, 'core', $2::jsonb)`, [probability, { meaning: 'x', title: 'x' }], /concept_statement_unknown_field/));
  await confirm(core);
});

test('내용 검사: 모르는 칸·빠진 제목과 본문·잘못된 값·긴 글을 막고 용어는 정리한다', async () => {
  const bad = (content, pattern) =>
    op(() => t.rejects(`select concept_statement_create($1::uuid, 'statement', $2::jsonb)`, [S.concept, content], pattern));
  await bad({ ...STATEMENT_A, level: '고등' }, /concept_statement_unknown_field/);
  await bad({ ...STATEMENT_A, title: '  ' }, /concept_statement_title_required/);
  await bad({ title: '제목', body: '' }, /concept_statement_body_required/);
  await bad({ ...STATEMENT_A, basis: 'ai' }, /concept_statement_bad_content/);
  await bad({ ...STATEMENT_A, conditions_in_source: 'yes' }, /concept_statement_bad_content/);
  await bad({ ...STATEMENT_A, terms: '사건' }, /concept_statement_bad_content/);
  await bad({ ...STATEMENT_A, title: 3 }, /concept_statement_bad_content/);
  await bad({ ...STATEMENT_A, title: '가'.repeat(201) }, /concept_statement_too_long/);
  await bad({ ...STATEMENT_A, terms: Array.from({ length: 31 }, (_, i) => `용어${i}`) }, /concept_statement_too_long/);
  await op(() => t.rejects(`select concept_statement_create($1::uuid, 'statement', '[]'::jsonb)`, [S.concept], /concept_statement_bad_content/));

  const row = await create(S.concept, 'statement', { title: ' 소수의 뜻 ', body: '1보다 큰 자연수 중…', terms: ['약수', ' ', '약수', ' 자연수 '] });
  assert.equal(row.draft.title, '소수의 뜻');
  assert.deepEqual(row.draft.terms, ['약수', '자연수']);
  assert.equal(row.draft.approach, undefined, '빈 칸은 저장하지 않는다');
  assert.equal((await discard(row)).removed, true);
});

test('원문 그대로인지 우리가 정리한 글인지, 원문·보완 이유·확인 안 된 점을 서술마다 남긴다', async () => {
  const row = await confirm(await create(probability, 'statement', {
    title: '교재 원문',
    body: '(사건 A가 일어나는 경우의 수) / (모든 경우의 수)',
    basis: 'verbatim',
    quote: '어떤 실험이나 관찰에서 각 경우가 일어날 가능성이 같을 때…',
    conditions_in_source: 'omitted',
    supplement_note: '원문 식에는 가능성이 같다는 조건이 없어 조건 칸에 적었다',
    unverified_note: '단원 첫머리 전제에 조건이 있는지 아직 확인하지 않음',
  }));
  assert.equal(row.content.basis, 'verbatim');
  assert.equal(row.content.conditions_in_source, 'omitted');
  assert.match(row.content.supplement_note, /조건 칸에/);
  assert.match(row.content.unverified_note, /확인하지 않음/);
});

test('화면에서 본 판·초안 시각과 다르면 막히고, 확정본과 같게 저장하면 초안이 빈다', async () => {
  const row = await confirm(await create(S.concept2, 'statement', { title: '합성수', body: '약수가 3개 이상' }));
  const saved = await saveDraft(row, { title: '합성수', body: '약수가 세 개 이상' });
  await op(() =>
    t.rejects(
      `select concept_statement_save_draft($1::uuid, $2::jsonb, $3::int, $4::timestamptz)`,
      [row.id, { title: '합성수', body: 'x' }, row.version, row.draft_saved_at],
      /concept_statement_stale/,
    ));
  await op(() =>
    t.rejects(`select concept_statement_confirm($1::uuid, $2::int, $3::timestamptz, null)`, [row.id, row.version, row.draft_saved_at], /concept_statement_stale/));
  const back = await saveDraft(saved, { title: '합성수', body: '약수가 3개 이상' });
  assert.equal(back.draft, null);
  assert.equal(back.draft_saved_at, null);
  await op(() =>
    t.rejects(`select concept_statement_confirm($1::uuid, $2::int, $3::timestamptz, null)`, [back.id, back.version, back.draft_saved_at], /concept_statement_no_draft/));
});

test('한 서술에 여러 출처를 잇고, 기존 출처는 기본 서술에 남으며, 다른 개념의 서술이나 공통 내용에는 잇지 못한다', async () => {
  const rows = await statementsOf(probability);
  const core = rows.find((r) => r.role === 'core');
  const aRow = rows.find((r) => r.content?.title === STATEMENT_A.title);
  const bRow = rows.find((r) => r.content?.title === STATEMENT_B.title);
  const old = await addSource(probability, 20);
  assert.equal(old.statement_id, null, '서술을 고르지 않은 출처는 기본 서술의 출처다');
  const s1 = await addSource(probability, 21, bRow.id);
  const s2 = await addSource(probability, 22, bRow.id);
  assert.equal(s1.statement_id, bRow.id);
  assert.equal(s2.statement_id, bRow.id);

  const moved = await setStatement(old.id, aRow.id);
  assert.equal(moved.statement_id, aRow.id);
  assert.equal((await setStatement(old.id, null)).statement_id, null);

  const other = (await statementsOf(S.concept2))[0];
  await op(() => t.rejects(`select concept_source_set_statement($1::uuid, $2::uuid)`, [old.id, other.id], /concept_statement_other_concept/));
  await op(() => t.rejects(`select concept_source_set_statement($1::uuid, $2::uuid)`, [old.id, core.id], /concept_statement_not_statement/));
  await op(() => t.rejects(`select concept_source_set_statement($1::uuid, $2::uuid)`, [old.id, S.folder], /concept_statement_not_found/));
  await op(() => t.rejects(`select concept_source_set_statement($1::uuid, $2::uuid)`, [S.folder, aRow.id], /concept_statement_source_not_found/));
  await t.asUser(() => t.rejects(`select concept_source_set_statement($1::uuid, $2::uuid)`, [old.id, aRow.id], /concept_statement_forbidden/));
  await op(() =>
    t.rejects(
      `insert into concept_sources (concept_id, academy_id, book_id, grade_label, raw_page, statement_id)
       values ($1::uuid, $2::uuid, $3::uuid, '1-1', 30, $4::uuid)`,
      [S.concept, S.academy, S.book, bRow.id],
      /concept_statement_other_concept/,
    ));
  await op(() => t.rejects(`update concept_sources set statement_id = null where id = $1::uuid`, [s1.id], /permission denied/));
});

test('교육과정 등장 위치는 서술마다 여럿이고, 새 교육과정을 더해도 이전 기록이 남는다', async () => {
  const b = (await statementsOf(probability)).find((r) => r.content?.title === STATEMENT_B.title);
  const r2015 = await addAppearance(probability, b.id, 'rev_2015', '고', '확률과 통계', ['확률', '확률의 뜻과 활용']);
  assert.equal(r2015.created_by, S.operator);
  await addAppearance(probability, b.id, 'rev_2022', '고', '확률과 통계', ['확률', '확률의 뜻과 활용']);
  await addAppearance(probability, null, null, '중', '2-2', ['확률']);
  const rows = await op(() =>
    t.all(`select curriculum_code, school_level, course_label from concept_appearances where concept_id = $1::uuid order by created_at`, [probability]));
  assert.deepEqual(rows, [
    { curriculum_code: 'rev_2015', school_level: '고', course_label: '확률과 통계' },
    { curriculum_code: 'rev_2022', school_level: '고', course_label: '확률과 통계' },
    { curriculum_code: null, school_level: '중', course_label: '2-2' },
  ]);
  await op(() =>
    t.rejects(
      `insert into concept_appearances (concept_id, statement_id, curriculum_code, school_level, course_label, unit_path)
       values ($1::uuid, $2::uuid, 'rev_2015', '고', '확률과 통계', array['확률', '확률의 뜻과 활용'])`,
      [probability, b.id],
      /duplicate key/,
    ));
  await op(() =>
    t.rejects(
      `insert into concept_appearances (concept_id, curriculum_code, school_level, course_label) values ($1::uuid, 'rev_2030', '고', '수학')`,
      [probability],
      /check constraint/,
    ));
  await op(() =>
    t.rejects(
      `insert into concept_appearances (concept_id, statement_id, school_level, course_label) values ($1::uuid, $2::uuid, '중', '1-1')`,
      [S.concept, b.id],
      /concept_statement_other_concept/,
    ));
  await t.asUser(() =>
    t.rejects(`insert into concept_appearances (concept_id, school_level, course_label) values ($1::uuid, '중', '1-1')`, [probability], /row-level security/));
  assert.equal((await t.asUser(() => t.all(`select id from concept_appearances`))).length, 0);
  await op(() => t.rejects(`update concept_appearances set course_label = 'x' where id = $1::uuid`, [r2015.id], /permission denied/));
  await op(() => t.one(`delete from concept_appearances where id = $1::uuid returning id`, [r2015.id]));
});

test('초안 버리기: 확정한 서술은 초안만 비우고, 확정 전 서술은 출처·등장 위치가 없을 때만 지운다', async () => {
  let confirmed = await confirm(await create(S.concept, 'statement', { title: '버리기 시험', body: '처음' }));
  confirmed = await saveDraft(confirmed, { title: '버리기 시험', body: '고침' });
  const kept = await discard(confirmed);
  assert.equal(kept.content.body, '처음');
  assert.equal(kept.draft, null);
  await op(() =>
    t.rejects(`select concept_statement_discard_draft($1::uuid, $2::int, $3::timestamptz)`, [kept.id, kept.version, kept.draft_saved_at], /concept_statement_no_draft/));

  const draftOnly = await create(S.concept, 'statement', { title: '확정 전', body: '초안' });
  const src = await addSource(S.concept, 40, draftOnly.id);
  await op(() =>
    t.rejects(`select concept_statement_discard_draft($1::uuid, $2::int, $3::timestamptz)`, [draftOnly.id, draftOnly.version, draftOnly.draft_saved_at], /concept_statement_in_use/));
  await setStatement(src.id, null);
  const removed = await discard(draftOnly);
  assert.deepEqual(removed, { id: draftOnly.id, removed: true });
});

test('기존 개념 본문을 고치면 고치기 전 값이 남고, 순서만 바꾸면 남지 않는다', async () => {
  const concept = await insertConcept(t, '본문 기록 시험', S.folder, '처음 본문');
  await op(() => t.exec(`update concepts set content = '고친 본문' where id = '${concept}'`));
  await op(() => t.exec(`update concepts set sort_order = 5 where id = '${concept}'`));
  await op(() => t.exec(`update concepts set name = '본문 기록 시험(고침)' where id = '${concept}'`));
  const rows = await op(() =>
    t.all(`select name, content, changed_by from concept_content_revisions where concept_id = $1::uuid order by changed_at, id`, [concept]));
  assert.equal(rows.length, 2);
  assert.deepEqual(rows.map((r) => r.content).sort(), ['고친 본문', '처음 본문']);
  assert.ok(rows.every((r) => r.changed_by === S.operator));
  assert.equal((await t.asUser(() => t.all(`select id from concept_content_revisions`))).length, 0);
  await op(() => t.rejects(`delete from concept_content_revisions where concept_id = $1::uuid`, [concept], /permission denied/));
});

test('개념을 지우면 서술·기록·출처·등장 위치가 함께 사라진다', async () => {
  const concept = await insertConcept(t, '지울 개념', S.folder, '');
  const st = await confirm(await create(concept, 'statement', { title: '서술', body: '본문' }));
  await addSource(concept, 50, st.id);
  await addAppearance(concept, st.id, 'rev_2022', '중', '1-1');
  await t.exec(`update concepts set content = '고침' where id = '${concept}'`);
  await t.exec(`delete from concepts where id = '${concept}'`);
  for (const table of ['concept_statements', 'concept_sources', 'concept_appearances', 'concept_content_revisions']) {
    assert.equal((await t.all(`select 1 from ${table} where concept_id = $1::uuid`, [concept])).length, 0, table);
  }
  assert.equal((await t.all(`select 1 from concept_statement_revisions where statement_id = $1::uuid`, [st.id])).length, 0);
});
