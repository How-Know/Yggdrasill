// 개념 초안 검토 대화: Think는 제안 카드만 남기고, 운영자가 승인할 때만 저장된 검토·기준 초안이 바뀐다.
// 제안 때 건드린 항목이 그사이 바뀌었으면 반영하지 않는다. 나누기·합치기는 항목 근거 블록으로 출처가 붙는다.
// 다시 정리는 새 초안이 생긴 뒤 마무리 RPC로 지금 초안을 닫는다.
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { openConceptTestDb, seedConcepts } from '../concept_fixture.mjs';

let t;
let S;
let conv;

before(async () => {
  t = await openConceptTestDb();
  S = await seedConcepts(t);
  await t.one(`insert into concept_categories (name, code, depth, sort_order) values ('대수', 'ALG', 0, 1) returning id`);
  conv = (await t.one(`insert into ai_conversations (title) values ('개념 초안 검토') returning id`)).id;
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
    { title: '소수', concept_type: '정의', content: '소수 본문', source_blocks: ['p8-a0', 'p8-a1'], criterion_notes: '', needs_check: '' },
    { title: '합성수', concept_type: '정의', content: '합성수 본문', source_blocks: ['p9-a0'], criterion_notes: '', needs_check: '' },
    { title: '1의 분류', concept_type: '주의', content: '1은…', source_blocks: ['p10-b2'], criterion_notes: '', needs_check: '' },
  ],
  new_types: [],
  excluded: [],
  questions: [],
};

async function createCriterion(title = '지식 분류 기준', body = '정의와 성질을 나눈다.') {
  return op(async () => (await t.one(`select concept_criteria_create($1, $2, 'owner') as r`, [title, body])).r);
}

async function insertDraft(criteria = []) {
  return (await t.one(
    `insert into concept_drafts (academy_id, book_id, grade_label, book_name, unit_path, pages, page_meta, model, prompt_version,
                                 criteria, prepared, draft, checks)
     values ($1::uuid, $2::uuid, '1-1', '개념+유형 중1-1', array['소인수분해', '소인수분해', '소수와 합성수'], array[8, 9, 10],
             '[]'::jsonb, 'gpt', 'concept_draft_organize.v2', $3::jsonb, $4::jsonb, $5::jsonb, '{}'::jsonb)
     returning id, review_saved_at`,
    [S.academy, S.book, JSON.stringify(criteria), JSON.stringify(PREPARED), JSON.stringify(DRAFT)],
  ));
}

const item = (index, extra = {}) => ({
  index,
  mark: 'keep',
  title: DRAFT.concepts[index].title,
  content: DRAFT.concepts[index].content,
  type: DRAFT.concepts[index].concept_type,
  folder: ['대수', '수와 연산'],
  ...extra,
});

async function saveReview(row, review) {
  const r = await op(async () =>
    (await t.one(`select concept_draft_save_review($1::uuid, $2::jsonb, $3::timestamptz) as r`, [row.id, JSON.stringify(review), row.review_saved_at])).r);
  return { id: row.id, review_saved_at: r.review_saved_at };
}

async function savedDraft() {
  const row = await insertDraft();
  return saveReview(row, { concepts: [item(0), item(1), item(2)] });
}

const propose = (kind, payload) =>
  op(async () => (await t.one(`select * from concept_draft_action_propose($1::uuid, $2, $3::jsonb)`, [conv, kind, JSON.stringify(payload)])));

const apply = (id) => op(async () => t.one(`select * from concept_draft_action_apply($1::uuid)`, [id]));

const reviewOf = async (id) => (await op(() => t.one(`select review, review_saved_at, status from concept_drafts where id = $1::uuid`, [id])));

test('제안·승인은 운영자만 하고, 저장된 검토가 없으면 변경을 제안하지 못한다', async () => {
  const row = await insertDraft();
  const payload = { draft_id: row.id, reason: '이름을 줄인다', ops: [{ op: 'edit', key: 'c0', title: '소수(素數)' }] };
  await t.asUser(() => t.rejects(`select concept_draft_action_propose($1::uuid, 'concept_draft_change', $2::jsonb)`,
    [conv, JSON.stringify(payload)], /forbidden/));
  await t.asAnon(() => t.rejects(`select concept_draft_action_propose($1::uuid, 'concept_draft_change', $2::jsonb)`,
    [conv, JSON.stringify(payload)], /permission denied/));
  await op(() => t.rejects(`select concept_draft_action_propose($1::uuid, 'concept_draft_change', $2::jsonb)`,
    [conv, JSON.stringify(payload)], /concept_draft_review_not_saved/));
  await op(() => t.rejects(`select concept_draft_action_propose($1::uuid, 'concept_draft_change', $2::jsonb)`,
    [conv, JSON.stringify({ ...payload, reason: '' })], /concept_draft_action_reason_required/));
  await op(() => t.rejects(`select concept_draft_change_run(d, '[]'::jsonb) from concept_drafts d limit 1`, [], /permission denied/));
});

test('잘못된 변경은 제안 단계에서 막는다(모르는 항목·유형·영역·근거 블록, 뺀 항목 나누기)', async () => {
  const row = await savedDraft();
  const bad = async (ops, pattern) =>
    op(() => t.rejects(`select concept_draft_action_propose($1::uuid, 'concept_draft_change', $2::jsonb)`,
      [conv, JSON.stringify({ draft_id: row.id, reason: '시험', ops })], pattern));
  await bad([{ op: 'edit', key: 'c9', title: 'x' }], /concept_draft_change_unknown_item/);
  await bad([{ op: 'type', key: 'c0', type: '없는유형' }], /concept_draft_change_bad_type/);
  await bad([{ op: 'folder', key: 'c0', folder: ['없는영역', '수'] }], /concept_draft_change_bad_folder/);
  await bad([{ op: 'split', key: 'c0', parts: [
    { title: '소수의 뜻', content: 'a', type: '정의', blocks: ['p8-a0'] },
    { title: '소수의 예', content: 'b', type: '정의', blocks: ['zz'] },
  ] }], /concept_draft_change_bad_blocks/);
  await bad([{ op: 'new_type', name: '성질', description: '', legacy_sub_type: '정리', closest_existing: '성질', reason: '' }],
    /concept_draft_change_type_exists/);
  await bad([{ op: 'mark', key: 'c0', mark: 'drop' }, { op: 'split', key: 'c0', parts: [
    { title: 'a', content: 'a', type: '정의', blocks: ['p8-a0'] },
    { title: 'b', content: 'b', type: '정의', blocks: ['p8-a1'] },
  ] }], /concept_draft_change_dropped/);
  await bad([{ op: 'rename' }], /concept_draft_change_bad_op/);
  const n = await op(() => t.one(`select count(*)::int as n from ai_actions where payload ->> 'draft_id' = $1`, [row.id]));
  assert.equal(n.n, 0);
});

test('승인하면 저장된 검토에 반영된다: 이름·유형·새 유형·폴더·빼기, 승인 전에는 그대로', async () => {
  const row = await savedDraft();
  const a = await propose('concept_draft_change', {
    draft_id: row.id,
    reason: '판정법은 따로 유형을 둔다',
    ops: [
      { op: 'edit', key: 'c0', title: '소수의 뜻' },
      { op: 'new_type', name: '판정', description: '어떤 수가 조건을 만족하는지 가리는 방법', legacy_sub_type: '연산', closest_existing: '방법', reason: '판정법이 반복된다' },
      { op: 'type', key: 'c1', type: '판정' },
      { op: 'folder', key: 'c1', folder: ['대수', '수와 연산', '소수와 합성수'] },
      { op: 'mark', key: 'c2', mark: 'drop' },
    ],
  });
  assert.equal(a.kind, 'concept_draft_change');
  assert.equal(a.status, 'proposed');
  assert.deepEqual(Object.keys(a.payload.base).sort(), ['c0', 'c1', 'c2']);
  assert.equal(a.preview.new_types[0].name, '판정');
  assert.equal((await reviewOf(row.id)).review.concepts[0].title, '소수');

  const done = await apply(a.id);
  assert.equal(done.status, 'applied');
  const after = await reviewOf(row.id);
  assert.notEqual(after.review_saved_at, row.review_saved_at);
  const [c0, c1, c2] = after.review.concepts;
  assert.equal(c0.title, '소수의 뜻');
  assert.equal(c0.mark, 'edit');
  assert.equal(c0.key, 'c0');
  assert.equal(c1.type, '판정');
  assert.deepEqual(c1.folder, ['대수', '수와 연산', '소수와 합성수']);
  assert.equal(c1.mark, 'keep');
  assert.equal(c2.mark, 'drop');
  assert.deepEqual(after.review.new_types.map((x) => [x.name, x.accept, x.closest_existing]), [['판정', null, '방법']]);
  await op(() => t.rejects(`select concept_draft_action_apply($1::uuid)`, [a.id], /action_not_pending/));
  const types = await t.one(`select count(*)::int as n from concept_types where name = '판정'`);
  assert.equal(types.n, 0, '새 유형은 확정 때 받아들여야만 더해진다');
});

test('제안 뒤 그 항목을 고쳤으면 승인을 막고, 다른 항목만 바뀌었으면 반영한다', async () => {
  const row = await savedDraft();
  const a = await propose('concept_draft_change', { draft_id: row.id, reason: '이름', ops: [{ op: 'edit', key: 'c0', title: '소수란' }] });
  const b = await propose('concept_draft_change', { draft_id: row.id, reason: '내용', ops: [{ op: 'edit', key: 'c1', content: '합성수: 약수가 셋 이상' }] });
  const moved = await saveReview(row, { concepts: [item(0, { title: '운영자가 고친 이름', mark: 'edit' }), item(1), item(2)] });
  await op(() => t.rejects(`select concept_draft_action_apply($1::uuid)`, [a.id], /concept_draft_change_stale/));
  assert.equal((await op(() => t.one(`select status from ai_actions where id = $1::uuid`, [a.id]))).status, 'proposed');
  await apply(b.id);
  const after = await reviewOf(moved.id);
  assert.equal(after.review.concepts[0].title, '운영자가 고친 이름');
  assert.equal(after.review.concepts[1].content, '합성수: 약수가 셋 이상');
  await op(() => t.one(`select * from ai_action_reject($1::uuid)`, [a.id]));
});

test('나누기·합치기: 조각은 근거 블록을 따로 갖고, 확정하면 그 블록의 쪽이 출처가 된다', async () => {
  const row = await savedDraft();
  const a = await propose('concept_draft_change', {
    draft_id: row.id,
    reason: '뜻과 예를 나누고, 1의 분류는 합성수에 합친다',
    ops: [
      { op: 'split', key: 'c0', parts: [
        { title: '소수의 뜻', content: '1보다 큰 자연수 중…', type: '정의', blocks: ['p8-a0'] },
        { title: '소수의 예', content: '2, 3, 5, 7', type: '표현', blocks: ['p8-a1'] },
      ] },
      { op: 'merge', keys: ['c1', 'c2'], into: 'c1', title: '합성수와 1', content: '합성수의 뜻과 1의 분류' },
    ],
  });
  assert.deepEqual(a.preview.after.map((x) => x.key).sort(), ['c0.1', 'c0.2', 'c1', 'c2']);
  await apply(a.id);
  const after = await reviewOf(row.id);
  assert.deepEqual(after.review.concepts.map((x) => [x.key, x.index, x.mark]), [
    ['c0.1', 0, 'edit'], ['c0.2', 0, 'edit'], ['c1', 1, 'edit'], ['c2', 2, 'drop'],
  ]);
  assert.deepEqual(after.review.concepts[2].blocks, ['p9-a0', 'p10-b2']);
  assert.equal(after.review.concepts[3].merged_into, 'c1');

  const res = await t.asSuperadmin(async () =>
    (await t.one(`select concept_draft_confirm($1::uuid, $2::timestamptz) as r`, [row.id, after.review_saved_at])).r, S.operator);
  const made = res.result.concepts;
  assert.deepEqual(made.map((x) => x.key), ['c0.1', 'c0.2', 'c1']);
  const pages = async (id) =>
    (await t.all(`select raw_page from concept_sources where concept_id = $1::uuid order by raw_page`, [id])).map((r) => r.raw_page);
  assert.deepEqual(await pages(made[0].id), [8]);
  assert.deepEqual(await pages(made[1].id), [8]);
  assert.deepEqual(await pages(made[2].id), [9, 10]);
  const sub = await t.one(`select sub_type, kind from concepts where id = $1::uuid`, [made[1].id]);
  assert.deepEqual([sub.sub_type, sub.kind], ['정의', 'definition']);
});

test('확정은 초안에 없는 근거 블록과 겹치는 key를 막는다', async () => {
  const row = await insertDraft();
  let saved = await saveReview(row, { concepts: [item(0, { key: 'a', blocks: ['nope'] })] });
  await t.asSuperadmin(() => t.rejects(`select concept_draft_confirm($1::uuid, $2::timestamptz)`,
    [row.id, saved.review_saved_at], /concept_draft_bad_review/), S.operator);
  saved = await saveReview(saved, { concepts: [item(0, { key: 'a' }), item(1, { key: 'a' })] });
  await t.asSuperadmin(() => t.rejects(`select concept_draft_confirm($1::uuid, $2::timestamptz)`,
    [row.id, saved.review_saved_at], /concept_draft_bad_review/), S.operator);
  assert.equal((await t.one(`select status from concept_drafts where id = $1::uuid`, [row.id])).status, 'open');
});

test('기준 고치기: 이 초안에 쓴 기준만, 승인하면 기준 초안으로만 저장되고 그사이 바뀌었으면 막는다', async () => {
  const crit = await createCriterion();
  const other = await createCriterion('다른 기준');
  const row = await insertDraft([{ id: crit.id, title: crit.draft_title, version: 0, state: 'draft' }]);
  await op(() => t.rejects(`select concept_draft_action_propose($1::uuid, 'concept_criterion_change', $2::jsonb)`,
    [conv, JSON.stringify({ draft_id: row.id, criterion_id: other.id, title: 'x', body: 'y', reason: '시험' })],
    /concept_criterion_not_in_draft/));
  await op(() => t.rejects(`select concept_draft_action_propose($1::uuid, 'concept_criterion_change', $2::jsonb)`,
    [conv, JSON.stringify({ draft_id: row.id, criterion_id: crit.id, title: crit.draft_title, body: crit.draft_body, reason: '시험' })],
    /concept_criterion_change_unchanged/));
  const first = await propose('concept_criterion_change',
    { draft_id: row.id, criterion_id: crit.id, title: '지식 분류 기준', body: '정의·성질·방법을 나눈다.', reason: '방법을 더한다' });
  const second = await propose('concept_criterion_change',
    { draft_id: row.id, criterion_id: crit.id, title: '지식 분류 기준', body: '정의·성질·방법·주의를 나눈다.', reason: '주의도 더한다' });
  const firstNow = await op(() => t.one(`select status, superseded from ai_actions where id = $1::uuid`, [first.id]));
  assert.deepEqual([firstNow.status, firstNow.superseded], ['rejected', true]);
  assert.equal(second.preview.before.body, '정의와 성질을 나눈다.');

  const done = await apply(second.id);
  assert.equal(done.status, 'applied');
  const c = await t.one(`select version, title, draft_body, draft_origin from concept_criteria where id = $1::uuid`, [crit.id]);
  assert.deepEqual([c.version, c.title, c.draft_body, c.draft_origin], [0, null, '정의·성질·방법·주의를 나눈다.', 'owner']);

  const third = await propose('concept_criterion_change',
    { draft_id: row.id, criterion_id: crit.id, title: '지식 분류 기준', body: '다시 바꾼다.', reason: '시험' });
  const savedAt = (await t.one(`select draft_saved_at from concept_criteria where id = $1::uuid`, [crit.id])).draft_saved_at;
  await op(() => t.one(`select concept_criteria_save_draft($1::uuid, '지식 분류 기준', '운영자가 먼저 고침', 0, $2::timestamptz)`,
    [crit.id, savedAt]));
  await op(() => t.rejects(`select concept_draft_action_apply($1::uuid)`, [third.id], /concept_criteria_stale/));
});

test('다시 정리: 승인은 정리 함수가 새 초안을 만든 뒤 마무리 RPC로 지금 초안을 닫는다', async () => {
  const crit = await createCriterion('다시 정리 기준');
  const row = await savedDraft();
  const first = await propose('concept_draft_rerun', { draft_id: row.id, criterion_ids: [crit.id], reason: '기준을 바꿨다' });
  const a = await propose('concept_draft_rerun', { draft_id: row.id, criterion_ids: [crit.id], reason: '기준을 또 바꿨다' });
  assert.equal((await op(() => t.one(`select status from ai_actions where id = $1::uuid`, [first.id]))).status, 'rejected');
  assert.equal(a.preview.criteria[0].title, '다시 정리 기준');
  await op(() => t.rejects(`select concept_draft_action_apply($1::uuid)`, [a.id], /concept_draft_rerun_use_organize/));

  const stray = await insertDraft();
  await op(() => t.rejects(`select concept_draft_rerun_finish($1::uuid, $2::uuid)`, [a.id, stray.id], /concept_draft_not_found/));
  const fresh = (await t.one(
    `insert into concept_drafts (academy_id, book_id, grade_label, book_name, unit_path, pages, model, prompt_version, prepared, draft, rerun_of)
     values ($1::uuid, $2::uuid, '1-1', '개념+유형 중1-1', array['소인수분해'], array[8, 9, 10], 'gpt', 'v2', $3::jsonb, $4::jsonb, $5::uuid)
     returning id`,
    [S.academy, S.book, JSON.stringify(PREPARED), JSON.stringify(DRAFT), row.id],
  )).id;
  await t.asUser(() => t.rejects(`select concept_draft_rerun_finish($1::uuid, $2::uuid)`, [a.id, fresh], /forbidden/));
  const done = await op(() => t.one(`select * from concept_draft_rerun_finish($1::uuid, $2::uuid)`, [a.id, fresh]));
  assert.equal(done.status, 'applied');
  assert.equal(done.result.draft_id, fresh);
  const old = await t.one(`select status, replaced_by, closed_at from concept_drafts where id = $1::uuid`, [row.id]);
  assert.equal(old.status, 'replaced');
  assert.equal(old.replaced_by, fresh);
  assert.ok(old.closed_at);
  await op(() => t.rejects(`select concept_draft_save_review($1::uuid, '{"concepts":[]}'::jsonb, $2::timestamptz)`,
    [row.id, row.review_saved_at], /concept_draft_closed/));
  await op(() => t.rejects(`select concept_draft_action_propose($1::uuid, 'concept_draft_rerun', $2::jsonb)`,
    [conv, JSON.stringify({ draft_id: row.id, criterion_ids: [], reason: '시험' })], /concept_draft_closed/));
});

test('기존 승인 함수는 새 종류를 실행하지 않는다', async () => {
  const row = await savedDraft();
  const a = await propose('concept_draft_change', { draft_id: row.id, reason: '시험', ops: [{ op: 'mark', key: 'c2', mark: 'drop' }] });
  await op(() => t.rejects(`select ai_action_apply($1::uuid, '{}'::jsonb)`, [a.id], /action_kind_not_appliable/));
});
