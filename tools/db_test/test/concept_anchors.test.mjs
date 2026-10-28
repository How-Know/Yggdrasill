// 개념 주제 묶음: 개념 → 바로 앞에 알아야 하는 개념(같은 폴더). 여러 단계로 이어지고 고리는 막는다.
// 운영자만 RPC로 바꾸고, 초안 확정 때는 검토 항목의 anchor 를 같은 폴더끼리만 잇는다.
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { insertConcept, openConceptTestDb, seedConcepts } from '../concept_fixture.mjs';

let t;
let S;
let root;

before(async () => {
  t = await openConceptTestDb();
  S = await seedConcepts(t);
  root = (await t.one(`insert into concept_categories (name, code, depth, sort_order) values ('대수', 'ALG', 0, 1) returning id`)).id;
});
after(() => t?.close());

const op = (fn) => t.asSuperadmin(fn, S.operator);
const setLinks = (links, origin = 'manual') =>
  op(async () => (await t.one(`select concept_anchor_set($1::jsonb, $2) as r`, [JSON.stringify(links), origin])).r);
const anchorOf = async (id) =>
  (await t.all(`select anchor_id, origin from concept_anchor_links where concept_id = $1::uuid`, [id]))[0] ?? null;

async function folderWith(name, names) {
  const folder = (await t.one(`insert into concept_categories (name, parent_id, depth) values ($1, $2::uuid, 1) returning id`, [name, root])).id;
  const ids = [];
  for (const n of names) ids.push(await insertConcept(t, `${name}·${n}`, folder));
  return { folder, ids };
}

test('운영자는 같은 폴더 개념끼리 여러 단계로 잇고 뺄 수 있다. 다른 사람은 못 하고 표에 직접 쓰지 못한다', async () => {
  const { ids: [gcdBase, gcd, prop] } = await folderWith('약수와 배수', ['공약수', '최대공약수', '공약수와 최대공약수의 약수']);
  const r = await setLinks([
    { concept_id: gcd, anchor_id: gcdBase },
    { concept_id: prop, anchor_id: gcd },
  ], 'proposal');
  assert.deepEqual(r, { set: 2, cleared: 0 });
  assert.equal((await anchorOf(prop)).anchor_id, gcd);
  assert.equal((await anchorOf(gcd)).origin, 'proposal');

  assert.deepEqual(await setLinks([{ concept_id: prop, anchor_id: null }]), { set: 0, cleared: 1 });
  assert.equal(await anchorOf(prop), null);

  await t.asUser(() => t.rejects(`select concept_anchor_set('[]'::jsonb, 'manual')`, [], /concept_draft_forbidden/));
  assert.equal((await t.asUser(() => t.all(`select concept_id from concept_anchor_links`))).length, 0);
  await op(() => t.rejects(
    `insert into concept_anchor_links (concept_id, anchor_id, origin) values ($1::uuid, $2::uuid, 'manual')`,
    [prop, gcd],
    /permission denied/,
  ));
  await op(() => t.rejects(`select concept_anchor_has_cycle(array[$1::uuid])`, [gcd], /permission denied/));
});

test('고리·다른 폴더·자기 자신·없는 개념·잘못된 요청은 막고, 하나라도 어긋나면 아무것도 바뀌지 않는다', async () => {
  const { ids: [a, b, c] } = await folderWith('고리 시험', ['가', '나', '다']);
  const { ids: [other] } = await folderWith('다른 폴더', ['라']);
  await setLinks([{ concept_id: b, anchor_id: a }, { concept_id: c, anchor_id: b }]);

  await op(() => t.rejects(`select concept_anchor_set($1::jsonb, 'manual')`,
    [JSON.stringify([{ concept_id: a, anchor_id: c }])], /concept_anchor_cycle/));
  assert.equal(await anchorOf(a), null, '고리가 생기면 넣지 않는다');

  await op(() => t.rejects(`select concept_anchor_set($1::jsonb, 'manual')`,
    [JSON.stringify([{ concept_id: c, anchor_id: null }, { concept_id: a, anchor_id: other }])], /concept_anchor_other_folder/));
  assert.equal((await anchorOf(c)).anchor_id, b, '앞의 빼기도 되돌린다');

  await op(() => t.rejects(`select concept_anchor_set($1::jsonb, 'manual')`,
    [JSON.stringify([{ concept_id: a, anchor_id: a }])], /concept_anchor_bad_request/));
  await op(() => t.rejects(`select concept_anchor_set($1::jsonb, 'manual')`,
    [JSON.stringify([{ concept_id: a, anchor_id: '00000000-0000-4000-8000-00000000ffff' }])], /concept_anchor_not_found/));
  await op(() => t.rejects(`select concept_anchor_set($1::jsonb, 'draft')`,
    [JSON.stringify([{ concept_id: a, anchor_id: b }])], /concept_anchor_bad_request/));
  await op(() => t.rejects(`select concept_anchor_set($1::jsonb, 'manual')`,
    [JSON.stringify([{ concept_id: a, anchor_id: b }, { concept_id: a, anchor_id: null }])], /concept_anchor_bad_request/));
  await op(() => t.rejects(`select concept_anchor_set('[]'::jsonb, 'manual')`, [], /concept_anchor_bad_request/));
});

test('연결이 나가거나 들어오는 개념은 지우지 않고 연결도 그대로 남는다', async () => {
  const { ids: [a, b, c] } = await folderWith('지우기 시험', ['가', '나', '다']);
  await setLinks([{ concept_id: b, anchor_id: a }, { concept_id: c, anchor_id: b }]);
  for (const id of [a, b, c]) {
    await t.rejects(`delete from concepts where id = $1::uuid`, [id], /concept_delete_attached/);
  }
  assert.equal(Number((await t.one(
    `select count(*)::int as n from concept_anchor_links where concept_id = any($1::uuid[]) or anchor_id = any($1::uuid[])`,
    [[a, b, c]],
  )).n), 2);
});

const PREPARED = {
  blocks: [
    { id: 'p8-a0', raw_page: 8, read: 'a', kind: 'concept_box', title: '', text: '소수' },
    { id: 'p8-a1', raw_page: 8, read: 'a', kind: 'concept_box', title: '', text: '합성수' },
    { id: 'p8-a2', raw_page: 8, read: 'a', kind: 'note', title: '', text: '1은 소수도 합성수도 아니다' },
  ],
  furniture: [],
  disagreements: [],
};
const DRAFT = {
  summary: '개념 4개',
  concepts: [
    { title: '묶음 소수', concept_type: '정의', content: '소수 본문', source_blocks: ['p8-a0'], criterion_notes: '', needs_check: '', anchor: -1 },
    { title: '묶음 합성수', concept_type: '정의', content: '합성수 본문', source_blocks: ['p8-a1'], criterion_notes: '', needs_check: '', anchor: 0 },
    { title: '묶음 1의 분류', concept_type: '주의', content: '1은…', source_blocks: ['p8-a2'], criterion_notes: '', needs_check: '', anchor: 0 },
    { title: '묶음 소수의 성질', concept_type: '성질', content: '성질 본문', source_blocks: ['p8-a0'], criterion_notes: '', needs_check: '', anchor: 0 },
  ],
  excluded: [],
  questions: [],
};

async function insertDraft() {
  return (await t.one(
    `insert into concept_drafts (academy_id, book_id, grade_label, book_name, unit_path, pages, page_meta, model, prompt_version, prepared, draft, checks)
     values ($1::uuid, $2::uuid, '1-1', '개념+유형 중1-1', array['소인수분해'], array[8], '[{"raw_page":8,"display_page":8}]'::jsonb,
             'gpt', 'concept_draft_organize.v3', $3::jsonb, $4::jsonb, '{}'::jsonb)
     returning id, review_saved_at`,
    [S.academy, S.book, JSON.stringify(PREPARED), JSON.stringify(DRAFT)],
  ));
}

const item = (index, folder, extra = {}) => ({
  index,
  key: `c${index}`,
  mark: 'keep',
  title: DRAFT.concepts[index].title,
  content: DRAFT.concepts[index].content,
  type: DRAFT.concepts[index].concept_type,
  folder,
  ...extra,
});

async function saveAndConfirm(row, concepts) {
  const saved = await op(async () =>
    (await t.one(`select concept_draft_save_review($1::uuid, $2::jsonb, $3::timestamptz) as r`,
      [row.id, JSON.stringify({ concepts }), row.review_saved_at])).r);
  return op(async () =>
    (await t.one(`select concept_draft_confirm($1::uuid, $2::timestamptz) as r`, [row.id, saved.review_saved_at])).r);
}

test('확정: 남긴 항목끼리 같은 폴더면 잇고, 합친 항목은 합친 쪽으로, 뺀 항목·다른 폴더·없는 key 는 잇지 않는다', async () => {
  const row = await insertDraft();
  const f = ['대수', '초안 묶음'];
  const res = await saveAndConfirm(row, [
    item(0, f, { anchor: null }),
    item(1, f, { anchor: 'c0' }),
    item(2, f, { mark: 'drop', merged_into: 'c0' }),
    item(3, f, { anchor: 'c2' }),
  ]);
  assert.equal(res.result.anchors, 2);
  const id = Object.fromEntries(res.result.concepts.map((c) => [c.key, c.id]));
  assert.equal((await anchorOf(id.c1)).anchor_id, id.c0);
  assert.equal((await anchorOf(id.c3)).anchor_id, id.c0, '합쳐서 빠진 c2 대신 합친 c0');
  const link = await t.one(`select origin, draft_id from concept_anchor_links where concept_id = $1::uuid`, [id.c1]);
  assert.deepEqual([link.origin, link.draft_id], ['draft', row.id]);

  const row2 = await insertDraft();
  const res2 = await saveAndConfirm(row2, [
    item(0, ['대수', '초안 묶음 2']),
    item(1, ['대수', '초안 묶음 3'], { anchor: 'c0' }),
    item(2, ['대수', '초안 묶음 2'], { anchor: 'c9' }),
    item(3, ['대수', '초안 묶음 2'], { mark: 'drop' }),
  ]);
  assert.equal(res2.result.anchors, 0);
});

test('확정: 검토 항목끼리 고리가 있으면 아무것도 들어가지 않는다', async () => {
  const row = await insertDraft();
  const f = ['대수', '고리 초안'];
  const before = Number((await t.one(`select count(*)::int as n from concepts`)).n);
  await assert.rejects(
    saveAndConfirm(row, [item(0, f, { anchor: 'c1' }), item(1, f, { anchor: 'c0' }), item(2, f), item(3, f)]),
    /concept_anchor_cycle/,
  );
  assert.equal(Number((await t.one(`select count(*)::int as n from concepts`)).n), before);
  assert.equal((await op(() => t.one(`select status from concept_drafts where id = $1::uuid`, [row.id]))).status, 'open');
});

test('Think 변경 카드가 검토 항목을 다시 맞춰도 anchor 는 남는다', async () => {
  const norm = await t.one(
    `select concept_draft_item_norm('{"key":"c1","index":1,"anchor":"c0","title":"합성수"}'::jsonb) as r`,
  );
  assert.equal(norm.r.anchor, 'c0');
  assert.equal((await t.one(`select concept_draft_item_norm('{"index":2}'::jsonb) as r`)).r.anchor, null);
});
