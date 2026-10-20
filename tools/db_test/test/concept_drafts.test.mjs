// 개념 초안: AI 결과는 서버만 쓰고, 운영자 검토는 저장한 것만 남으며, 확정할 때만 폴더·개념·출처가 한 번에 들어간다.
// 출처 쪽은 초안이 근거로 든 블록의 쪽에서만 붙는다. 하나라도 어긋나면 아무것도 들어가지 않는다.
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { insertConcept, openConceptTestDb, seedConcepts } from '../concept_fixture.mjs';

let t;
let S;
let root;
let existingFolder;

before(async () => {
  t = await openConceptTestDb();
  S = await seedConcepts(t);
  root = (await t.one(`insert into concept_categories (name, code, depth, sort_order) values ('대수', 'ALG', 0, 1) returning id`)).id;
  await t.one(`insert into concept_categories (name, code, depth, sort_order) values ('기하', 'GEOM', 0, 4) returning id`);
  existingFolder = (await t.one(
    `insert into concept_categories (name, parent_id, depth, sort_order) values ('수와 연산', $1::uuid, 1, 0) returning id`,
    [root],
  )).id;
});
after(() => t?.close());

const op = (fn) => t.asSuperadmin(fn, S.operator);

const PREPARED = {
  blocks: [
    { id: 'p8-a0', raw_page: 8, read: 'a', kind: 'concept_box', title: '', text: '소수: 1보다 큰 자연수 중 1과 자기 자신만을 약수로 가지는 수' },
    { id: 'p8-a1', raw_page: 8, read: 'a', kind: 'example', title: '', text: '예: 2, 3, 5, 7' },
    { id: 'p9-a0', raw_page: 9, read: 'a', kind: 'concept_box', title: '', text: '합성수: 1보다 큰 자연수 중 소수가 아닌 수' },
    { id: 'p10-b2', raw_page: 10, read: 'b', kind: 'note', title: '', text: '1은 소수도 합성수도 아니다.' },
  ],
  furniture: [],
  disagreements: [],
};

const DRAFT = {
  summary: '개념 3개',
  concepts: [
    { title: '소수', concept_type: 'definition', content: '소수 본문', source_blocks: ['p8-a0', 'p8-a1'], criterion_notes: '', needs_check: '' },
    { title: '합성수', concept_type: 'definition', content: '합성수 본문', source_blocks: ['p9-a0', 'p10-b2'], criterion_notes: '', needs_check: '' },
    { title: '1의 분류', concept_type: 'caution', content: '1은…', source_blocks: ['p10-b2'], criterion_notes: '', needs_check: '' },
  ],
  excluded: [],
  questions: [],
};

/** Edge 함수(서버 키)가 만드는 초안 한 줄. */
async function insertDraft({ academy = S.academy, book = S.book } = {}) {
  return (await t.one(
    `insert into concept_drafts (academy_id, book_id, grade_label, book_name, unit_path, pages, page_meta, model, prompt_version, prepared, draft, checks)
     values ($1::uuid, $2::uuid, '1-1', '개념+유형 중1-1', array['소인수분해', '소인수분해', '소수와 합성수'], array[8, 9, 10],
             $3::jsonb, 'gpt', 'concept_draft_organize.v1', $4::jsonb, $5::jsonb, '{}'::jsonb)
     returning id, review_saved_at`,
    [academy, book, JSON.stringify([{ raw_page: 8, display_page: 8 }, { raw_page: 9, display_page: 9 }, { raw_page: 10, display_page: null }]),
      JSON.stringify(PREPARED), JSON.stringify(DRAFT)],
  ));
}

const saveReview = (row, review) =>
  op(async () =>
    (await t.one(`select concept_draft_save_review($1::uuid, $2::jsonb, $3::timestamptz) as r`, [row.id, JSON.stringify(review), row.review_saved_at])).r);

const confirm = (row, as = S.operator) =>
  t.asSuperadmin(async () =>
    (await t.one(`select concept_draft_confirm($1::uuid, $2::timestamptz) as r`, [row.id, row.review_saved_at])).r, as);

const item = (index, folder, extra = {}) => ({
  index,
  mark: 'keep',
  title: DRAFT.concepts[index].title,
  content: DRAFT.concepts[index].content,
  type: '정의',
  folder,
  ...extra,
});

test('초안은 운영자만 읽고, 표에는 운영자도 직접 쓰지 못한다', async () => {
  const row = await insertDraft();
  assert.equal((await t.asUser(() => t.all(`select id from concept_drafts`))).length, 0);
  assert.equal((await op(() => t.all(`select id from concept_drafts where id = $1::uuid`, [row.id]))).length, 1);
  await t.asAnon(() => t.rejects(`select id from concept_drafts`, [], /permission denied/));
  await op(() => t.rejects(`update concept_drafts set draft = '{}'::jsonb where id = $1::uuid`, [row.id], /permission denied/));
  await op(() => t.rejects(`delete from concept_drafts where id = $1::uuid`, [row.id], /permission denied/));
  await op(() => t.rejects(
    `insert into concept_page_transcripts (academy_id, book_id, grade_label, raw_page, read_index, prompt_version, model, page)
     values ($1::uuid, $2::uuid, '1-1', 8, 1, 'v1', 'gpt', '{}'::jsonb)`,
    [S.academy, S.book],
    /permission denied/,
  ));
  await t.asUser(() => t.rejects(`select concept_draft_save_review($1::uuid, '{"concepts":[]}'::jsonb, null)`, [row.id], /concept_draft_forbidden/));
  await t.asUser(() => t.rejects(`select concept_draft_confirm($1::uuid, null)`, [row.id], /concept_draft_forbidden/));
});

test('쪽 전사는 같은 쪽·같은 회차를 한 번만 둔다', async () => {
  const ins = (read) =>
    t.one(
      `insert into concept_page_transcripts (academy_id, book_id, grade_label, raw_page, read_index, prompt_version, model, page)
       values ($1::uuid, $2::uuid, '1-1', 8, $3::int, 'concept_page_read.v1', 'gpt', '{"blocks":[]}'::jsonb) returning id`,
      [S.academy, S.book, read],
    );
  await ins(1);
  await ins(2);
  await t.rejects(
    `insert into concept_page_transcripts (academy_id, book_id, grade_label, raw_page, read_index, prompt_version, model, page)
     values ($1::uuid, $2::uuid, '1-1', 8, 1, 'concept_page_read.v1', 'gpt', '{}'::jsonb)`,
    [S.academy, S.book],
    /duplicate key/,
  );
  await t.rejects(
    `insert into concept_page_transcripts (academy_id, book_id, grade_label, raw_page, read_index, prompt_version, model, page)
     values ($1::uuid, $2::uuid, '1-1', 9, 3, 'concept_page_read.v1', 'gpt', '{}'::jsonb)`,
    [S.academy, S.book],
    /check constraint/,
  );
  assert.equal((await op(() => t.all(`select id from concept_page_transcripts`))).length, 2);
  assert.equal((await t.asUser(() => t.all(`select id from concept_page_transcripts`))).length, 0);
});

test('검토 저장은 화면에서 본 저장 시각과 같을 때만 되고 AI 결과는 그대로다', async () => {
  const row = await insertDraft();
  const saved = await saveReview(row, { concepts: [item(0, ['대수', '새 폴더'])] });
  assert.ok(saved.review_saved_at);
  await op(() => t.rejects(
    `select concept_draft_save_review($1::uuid, '{"concepts":[]}'::jsonb, null)`,
    [row.id],
    /concept_draft_stale/,
  ));
  await op(() => t.rejects(
    `select concept_draft_save_review($1::uuid, '{"concepts":{}}'::jsonb, $2::timestamptz)`,
    [row.id, saved.review_saved_at],
    /concept_draft_bad_review/,
  ));
  const after = await op(() => t.one(`select draft, review from concept_drafts where id = $1::uuid`, [row.id]));
  assert.deepEqual(after.draft, DRAFT);
  assert.equal(after.review.concepts[0].folder[1], '새 폴더');
});

test('확정: 있는 폴더는 쓰고 없는 폴더만 만들며, 개념·출처(근거 블록의 쪽)를 한 번에 넣는다', async () => {
  const row = await insertDraft();
  const before = Number((await t.one(`select count(*)::int as n from concept_categories`)).n);
  const saved = await saveReview(row, {
    concepts: [
      item(0, ['대수', '수와 연산', '소인수분해']),
      item(1, ['대수', '수와 연산', '소인수분해'], { mark: 'edit', title: '합성수', content: '고친 합성수 본문', type: '성질' }),
      item(2, ['대수', '수와 연산'], { mark: 'drop' }),
    ],
  });
  const res = await confirm({ id: row.id, review_saved_at: saved.review_saved_at });
  assert.equal(res.status, 'confirmed');
  assert.equal(res.result.concepts.length, 2);
  assert.equal(res.result.folders.length, 1, '수와 연산은 이미 있어 소인수분해만 새로 만든다');
  assert.deepEqual(res.result.folders[0].path, ['대수', '수와 연산', '소인수분해']);
  assert.equal(Number((await t.one(`select count(*)::int as n from concept_categories`)).n), before + 1);

  const folder = await t.one(`select id, parent_id, depth from concept_categories where id = $1::uuid`, [res.result.folders[0].id]);
  assert.equal(folder.parent_id, existingFolder);
  assert.equal(folder.depth, 2);

  const concepts = await t.all(
    `select c.name, c.kind, c.sub_type, c.content, c.level, c.main_category_id, c.version_label, f.canonical_name
       from concepts c join concept_families f on f.id = c.family_id
      where c.id = any($1::uuid[]) order by c.sort_order`,
    [res.result.concepts.map((c) => c.id)],
  );
  assert.deepEqual(concepts.map((c) => [c.name, c.kind, c.sub_type, c.level]), [
    ['소수', 'definition', '정의', 1],
    ['합성수', 'theorem', '정리', 1],
  ]);
  assert.equal(concepts[1].content, '고친 합성수 본문');
  const links = await t.all(
    `select c.name, ct.name as type_name, l.draft_id
       from concept_type_links l join concepts c on c.id = l.concept_id join concept_types ct on ct.id = l.type_id
      where l.concept_id = any($1::uuid[]) order by c.sort_order`,
    [res.result.concepts.map((c) => c.id)],
  );
  assert.deepEqual(links.map((l) => [l.name, l.type_name]), [['소수', '정의'], ['합성수', '성질']]);
  assert.ok(links.every((l) => l.draft_id === row.id));
  assert.deepEqual(res.result.types, []);
  assert.ok(concepts.every((c) => c.main_category_id === folder.id && c.canonical_name === c.name));
  // seed 에 같은 이름(소수·합성수)이 이미 있어 같은 묶음의 다른 판으로 들어간다.
  assert.ok(concepts.every((c) => c.version_label === '기본'));

  const sources = await t.all(
    `select c.name, s.raw_page, s.display_page, s.unit_path, s.book_id, s.created_by
       from concept_sources s join concepts c on c.id = s.concept_id
      where s.concept_id = any($1::uuid[]) order by c.name, s.raw_page`,
    [res.result.concepts.map((c) => c.id)],
  );
  assert.deepEqual(sources.map((s) => [s.name, s.raw_page, s.display_page]), [
    ['소수', 8, 8],
    ['합성수', 9, 9],
    ['합성수', 10, null],
  ]);
  assert.ok(sources.every((s) => s.book_id === S.book && s.created_by === S.operator));
  assert.deepEqual(sources[0].unit_path, ['소인수분해', '소인수분해', '소수와 합성수']);
  assert.equal(res.result.sources, 3);

  await op(() => t.rejects(`select concept_draft_confirm($1::uuid, $2::timestamptz)`, [row.id, saved.review_saved_at], /concept_draft_closed/));
});

test('확정한 출처에는 그 쪽 블록 중 근거 블록이 처음 나온 자리를 남기고, 직접 이은 출처는 비워 둔다', async () => {
  const row = await insertDraft();
  const folder = ['대수', '수와 연산', '쪽 순서'];
  const saved = await saveReview(row, {
    concepts: [
      item(0, folder),
      { ...item(1, folder), key: 'c1', blocks: ['p10-b2', 'p8-a1'] },
      item(2, folder, { mark: 'drop' }),
    ],
  });
  const res = await confirm({ id: row.id, review_saved_at: saved.review_saved_at });
  const sources = await t.all(
    `select c.name, s.raw_page, s.page_order
       from concept_sources s join concepts c on c.id = s.concept_id
      where s.concept_id = any($1::uuid[]) order by s.raw_page, s.page_order, c.name`,
    [res.result.concepts.map((c) => c.id)],
  );
  assert.deepEqual(sources.map((s) => [s.raw_page, s.page_order, s.name]), [
    [8, 1, '소수'],
    [8, 2, '합성수'],
    [10, 1, '합성수'],
  ], '8쪽 블록은 p8-a0, p8-a1 순서라 근거가 p8-a1 인 합성수가 소수 뒤다');

  const manual = await op(() => t.one(
    `insert into concept_sources (concept_id, academy_id, book_id, grade_label, raw_page)
     values ($1::uuid, $2::uuid, $3::uuid, '1-1', 12) returning page_order`,
    [S.concept, S.academy, S.book],
  ));
  assert.equal(manual.page_order, null);
  await op(() => t.rejects(
    `insert into concept_sources (concept_id, academy_id, book_id, grade_label, raw_page, page_order)
     values ($1::uuid, $2::uuid, $3::uuid, '1-1', 13, 0)`,
    [S.concept, S.academy, S.book],
    /check constraint/,
  ));
});

test('같은 이름 개념이 이미 같은 판 이름을 쓰면 다음 판 이름을 쓴다', async () => {
  const folder = (await t.one(`insert into concept_categories (name, parent_id, depth) values ('판 시험', $1::uuid, 1) returning id`, [root])).id;
  const existing = await insertConcept(t, '1의 분류', folder);
  await t.exec(`update concepts set version_label = '기본' where id = '${existing}'`);
  const row = await insertDraft();
  const saved = await saveReview(row, { concepts: [item(2, ['대수', '판 시험'], { type: '주의' })] });
  const res = await confirm({ id: row.id, review_saved_at: saved.review_saved_at });
  const c = await t.one(`select version_label, family_id from concepts where id = $1::uuid`, [res.result.concepts[0].id]);
  const e = await t.one(`select family_id from concepts where id = $1::uuid`, [existing]);
  assert.equal(c.version_label, '기본-2');
  assert.equal(c.family_id, e.family_id);
});

test('하나라도 어긋나면 아무것도 들어가지 않는다', async () => {
  const counts = async () => (await t.one(
    `select (select count(*) from concept_categories)::int as f, (select count(*) from concepts)::int as c, (select count(*) from concept_sources)::int as s`,
  ));
  const before = await counts();
  const row = await insertDraft();
  let saved = await saveReview(row, {
    concepts: [item(0, ['대수', '원자성 시험']), item(1, ['없는 영역', '폴더'])],
  });
  await t.asSuperadmin(() => t.rejects(
    `select concept_draft_confirm($1::uuid, $2::timestamptz)`, [row.id, saved.review_saved_at], /concept_draft_unknown_root/), S.operator);
  assert.deepEqual(await counts(), before);

  saved = await saveReview({ id: row.id, review_saved_at: saved.review_saved_at }, { concepts: [item(0, ['대수'])] });
  await t.asSuperadmin(() => t.rejects(
    `select concept_draft_confirm($1::uuid, $2::timestamptz)`, [row.id, saved.review_saved_at], /concept_draft_bad_folder/), S.operator);

  saved = await saveReview({ id: row.id, review_saved_at: saved.review_saved_at }, { concepts: [item(0, ['대수', 'x'], { title: '  ' })] });
  await t.asSuperadmin(() => t.rejects(
    `select concept_draft_confirm($1::uuid, $2::timestamptz)`, [row.id, saved.review_saved_at], /concept_draft_text_required/), S.operator);

  saved = await saveReview({ id: row.id, review_saved_at: saved.review_saved_at }, { concepts: [item(0, ['대수', 'x']), item(0, ['대수', 'y'])] });
  await t.asSuperadmin(() => t.rejects(
    `select concept_draft_confirm($1::uuid, $2::timestamptz)`, [row.id, saved.review_saved_at], /concept_draft_bad_review/), S.operator);

  saved = await saveReview({ id: row.id, review_saved_at: saved.review_saved_at }, { concepts: [item(0, ['대수', 'x'], { mark: 'drop' })] });
  await t.asSuperadmin(() => t.rejects(
    `select concept_draft_confirm($1::uuid, $2::timestamptz)`, [row.id, saved.review_saved_at], /concept_draft_nothing_kept/), S.operator);
  assert.deepEqual(await counts(), before);
  const still = await op(() => t.one(`select status from concept_drafts where id = $1::uuid`, [row.id]));
  assert.equal(still.status, 'open');
});

test('검토를 저장하기 전에는 확정하지 못하고, 저장 시각이 다르면 막힌다', async () => {
  const row = await insertDraft();
  await t.asSuperadmin(() => t.rejects(`select concept_draft_confirm($1::uuid, null)`, [row.id], /concept_draft_review_required/), S.operator);
  const saved = await saveReview(row, { concepts: [item(0, ['대수', 'x'])] });
  await t.asSuperadmin(() => t.rejects(`select concept_draft_confirm($1::uuid, null)`, [row.id], /concept_draft_stale/), S.operator);
  assert.ok(saved.review_saved_at);
});

test('교재 학원에 속하지 않은 운영자는 확정하지 못한다', async () => {
  const row = await insertDraft();
  const saved = await t.asSuperadmin(async () =>
    (await t.one(`select concept_draft_save_review($1::uuid, $2::jsonb, null) as r`, [row.id, JSON.stringify({ concepts: [item(0, ['대수', 'x'])] })])).r,
  S.otherOperator);
  await t.asSuperadmin(() => t.rejects(
    `select concept_draft_confirm($1::uuid, $2::timestamptz)`, [row.id, saved.review_saved_at], /concept_draft_book_forbidden/), S.otherOperator);
});

test('개념 유형은 기본 다섯 가지로 시작하고(수학 순서), 운영자만 읽으며 직접 쓰지 못한다', async () => {
  const types = await op(() => t.all(`select name, legacy_sub_type, origin from concept_types order by sort_order`));
  assert.deepEqual(types.map((r) => [r.name, r.legacy_sub_type]), [
    ['정의', '정의'], ['표현', '정의'], ['주의', '정리'], ['성질', '정리'], ['방법', '연산'],
  ]);
  assert.ok(types.every((r) => r.origin === 'seed'));
  assert.equal((await t.asUser(() => t.all(`select id from concept_types`))).length, 0);
  await op(() => t.rejects(
    `insert into concept_types (name, legacy_sub_type, origin) values ('새것', '정리', 'draft')`, [], /permission denied/));
  await op(() => t.rejects(`delete from concept_type_links`, [], /permission denied/));
  // 기존 개념에는 유형을 붙이지 않는다.
  assert.equal(Number((await t.one(`select count(*)::int as n from concept_type_links where concept_id = $1::uuid`, [S.concept])).n), 0);
});

test('받아들인 새 유형은 목록에 더해지고 그 기존 구분으로 넣는다. 거절한 유형을 쓰면 막힌다', async () => {
  const row = await insertDraft();
  const proposal = { name: '판정', description: '어떤 수가 소수인지 가리는 기준', legacy_sub_type: '연산' };
  let saved = await saveReview(row, {
    new_types: [{ ...proposal, accept: false }],
    concepts: [item(0, ['대수', '유형 시험'], { type: '판정' })],
  });
  await t.asSuperadmin(() => t.rejects(
    `select concept_draft_confirm($1::uuid, $2::timestamptz)`, [row.id, saved.review_saved_at], /concept_draft_unknown_type/), S.operator);
  assert.equal(Number((await t.one(`select count(*)::int as n from concept_types where name = '판정'`)).n), 0);

  saved = await saveReview({ id: row.id, review_saved_at: saved.review_saved_at }, {
    new_types: [{ ...proposal, accept: true }, { name: ' 성질 ', description: '', legacy_sub_type: '정의', accept: true }],
    concepts: [item(0, ['대수', '유형 시험'], { type: '판정' }), item(1, ['대수', '유형 시험'], { type: '성질' })],
  });
  const res = await confirm({ id: row.id, review_saved_at: saved.review_saved_at });
  assert.equal(res.result.types.length, 1, '이미 있는 이름(성질)은 새로 만들지 않는다');
  const added = await t.one(`select name, description, legacy_sub_type, origin, draft_id from concept_types where name = '판정'`);
  assert.deepEqual([added.legacy_sub_type, added.origin, added.draft_id], ['연산', 'draft', row.id]);
  const concepts = await t.all(
    `select c.name, c.kind, c.sub_type from concepts c where c.id = any($1::uuid[]) order by c.sort_order`,
    [res.result.concepts.map((c) => c.id)],
  );
  assert.deepEqual(concepts.map((c) => [c.name, c.kind, c.sub_type]), [['소수', 'theorem', '연산'], ['합성수', 'theorem', '정리']]);
  assert.equal(
    (await t.one(`select legacy_sub_type from concept_types where name = '성질'`)).legacy_sub_type,
    '정리',
    '이미 있는 유형의 기존 구분은 바꾸지 않는다',
  );
});

test('유형이 없거나 새 유형 형식이 틀리면 아무것도 들어가지 않는다', async () => {
  const counts = async () => (await t.one(
    `select (select count(*) from concept_types)::int as ty, (select count(*) from concepts)::int as c, (select count(*) from concept_categories)::int as f`,
  ));
  const before = await counts();
  const row = await insertDraft();
  let saved = await saveReview(row, { concepts: [item(0, ['대수', '유형 없음'], { type: ' ' })] });
  await t.asSuperadmin(() => t.rejects(
    `select concept_draft_confirm($1::uuid, $2::timestamptz)`, [row.id, saved.review_saved_at], /concept_draft_type_required/), S.operator);
  saved = await saveReview({ id: row.id, review_saved_at: saved.review_saved_at }, {
    new_types: [{ name: '새 유형', description: '', legacy_sub_type: '기타', accept: true }],
    concepts: [item(0, ['대수', '유형 없음'])],
  });
  await t.asSuperadmin(() => t.rejects(
    `select concept_draft_confirm($1::uuid, $2::timestamptz)`, [row.id, saved.review_saved_at], /concept_draft_bad_type/), S.operator);
  saved = await saveReview({ id: row.id, review_saved_at: saved.review_saved_at }, {
    new_types: [{ name: '새 유형', description: '', legacy_sub_type: '정리', accept: true }],
    concepts: [item(0, ['없는 영역', '폴더'])],
  });
  await t.asSuperadmin(() => t.rejects(
    `select concept_draft_confirm($1::uuid, $2::timestamptz)`, [row.id, saved.review_saved_at], /concept_draft_unknown_root/), S.operator);
  assert.deepEqual(await counts(), before, '받아들인 새 유형도 확정이 실패하면 남지 않는다');
});

test('버린 초안은 다시 저장·확정하지 못한다', async () => {
  const row = await insertDraft();
  const res = await op(async () => (await t.one(`select concept_draft_discard($1::uuid, null) as r`, [row.id])).r);
  assert.equal(res.status, 'discarded');
  await op(() => t.rejects(`select concept_draft_save_review($1::uuid, '{"concepts":[]}'::jsonb, null)`, [row.id], /concept_draft_closed/));
  await op(() => t.rejects(`select concept_draft_confirm($1::uuid, null)`, [row.id], /concept_draft_closed/));
});

test('초안 쪽 수는 1~20쪽이다', async () => {
  const insertPages = (n) =>
    `insert into concept_drafts (academy_id, book_id, grade_label, unit_path, pages, model, prompt_version, prepared, draft)
     values ('${S.academy}'::uuid, '${S.book}'::uuid, '1-1', array['소인수분해'], (select array_agg(g) from generate_series(1, ${n}) g),
             'gpt', 'concept_draft_organize.v1', '{}'::jsonb, '{}'::jsonb)
     returning cardinality(pages) as n`;
  assert.equal((await t.one(insertPages(20))).n, 20);
  await t.rejects(insertPages(21), [], /concept_drafts_pages_check/);
  await t.rejects(insertPages(0), [], /concept_drafts_pages_check|null value/);
});
