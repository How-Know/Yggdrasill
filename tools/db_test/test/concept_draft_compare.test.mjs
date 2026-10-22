// 새 교재 항목을 기존 개념과 비교해 넣기(여러 교재 설명 통합 3단계). 출처만 연결·대표 수정안·보류는 새 개념을 만들지 않고,
// 기존 본문·확정 서술을 바꾸지 않는다. 수정안이 이미 있으면 덮지 않고 막는다. 보류는 기록으로 남아 다시 열거나 버린다.
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
const rpc = (sql, args) => op(async () => (await t.one(`select ${sql} as r`, args)).r);

async function folder(name) {
  return (await t.one(`insert into concept_categories (name, parent_id, depth) values ($1, $2::uuid, 1) returning id`, [name, root])).id;
}

async function statement(concept, body) {
  return (await rpc(`concept_statement_create($1::uuid, 'statement', $2::jsonb)`,
    [concept, JSON.stringify({ title: '다른 서술', body, basis: 'organized' })])).id;
}

const PREPARED = {
  blocks: [
    { id: 'p8-a0', raw_page: 8, read: 'a', kind: 'concept_box', title: '소수', text: '1보다 큰 자연수 중 1과 자기 자신만을 약수로 가지는 수' },
    { id: 'p8-a1', raw_page: 8, read: 'a', kind: 'example', title: '', text: '2, 3, 5, 7' },
    { id: 'p9-a0', raw_page: 9, read: 'a', kind: 'note', title: '', text: '1은 소수가 아니다' },
  ],
  furniture: [],
  disagreements: [],
};
const DRAFT = {
  summary: '개념 3개',
  concepts: [
    { title: '비교 가', concept_type: '정의', content: '가 본문', source_blocks: ['p8-a0', 'p9-a0'], criterion_notes: '', needs_check: '' },
    { title: '비교 나', concept_type: '정의', content: '나 본문', source_blocks: ['p8-a1'], criterion_notes: '', needs_check: '' },
    { title: '비교 다', concept_type: '정의', content: '다 본문', source_blocks: ['p9-a0'], criterion_notes: '', needs_check: '' },
  ],
  excluded: [],
  questions: [],
};

async function insertDraft() {
  return t.one(
    `insert into concept_drafts (academy_id, book_id, grade_label, book_name, unit_path, pages, page_meta, model, prompt_version, prepared, draft, checks)
     values ($1::uuid, $2::uuid, '1-1', '개념+유형 중1-1', array['소인수분해'], array[8, 9],
             '[{"raw_page":8,"display_page":18},{"raw_page":9,"display_page":19}]'::jsonb,
             'gpt', 'concept_draft_organize.v3', $3::jsonb, $4::jsonb, '{}'::jsonb)
     returning id, review_saved_at`,
    [S.academy, S.book, JSON.stringify(PREPARED), JSON.stringify(DRAFT)],
  );
}

const item = (index, folderPath, extra = {}) => ({
  index,
  key: `c${index}`,
  mark: 'keep',
  title: DRAFT.concepts[index].title,
  content: DRAFT.concepts[index].content,
  type: DRAFT.concepts[index].concept_type,
  folder: folderPath,
  ...extra,
});

async function save(row, concepts) {
  return rpc(`concept_draft_save_review($1::uuid, $2::jsonb, $3::timestamptz)`,
    [row.id, JSON.stringify({ concepts }), row.review_saved_at]);
}

async function saveAndConfirm(row, concepts) {
  const saved = await save(row, concepts);
  return rpc(`concept_draft_confirm($1::uuid, $2::timestamptz)`, [row.id, saved.review_saved_at]);
}

const sources = (concept) => t.all(
  `select raw_page, statement_id, draft_id, block_ids, evidence_scope from concept_sources where concept_id = $1::uuid
    order by raw_page, statement_id nulls first`, [concept]);

test('출처만 연결: 새 개념·서술·본문 없이 기본 서술 또는 고른 서술에 근거 쪽을 잇는다. 이미 있는 쪽은 건너뛴다', async () => {
  const f = await folder('출처만');
  const target = await insertConcept(t, '출처만 대상', f, '원래 본문');
  const st = await statement(target, '다른 교재 설명');
  await t.exec(`insert into concept_sources (concept_id, academy_id, book_id, grade_label, raw_page)
                values ('${target}', '${S.academy}', '${S.book}', '1-1', 8)`);
  const conceptsBefore = Number((await t.one(`select count(*)::int as n from concepts`)).n);
  const statementsBefore = Number((await t.one(`select count(*)::int as n from concept_statements`)).n);

  const row = await insertDraft();
  const res = await saveAndConfirm(row, [
    item(0, [], { relation: { kind: 'source', concept_id: target } }),
    item(1, [], { mark: 'edit', content: '고친 나', relation: { kind: 'source', concept_id: target, statement_id: st } }),
  ]);
  assert.deepEqual(res.result.concepts.map((c) => [c.key, c.id, c.statement_id, c.relation]), [
    ['c0', target, null, 'source'],
    ['c1', target, st, 'source'],
  ]);
  assert.deepEqual([res.result.linked, res.result.sources, res.result.sources_skipped], [2, 2, 1]);
  assert.equal(Number((await t.one(`select count(*)::int as n from concepts`)).n), conceptsBefore, '새 개념 없음');
  assert.equal(Number((await t.one(`select count(*)::int as n from concept_statements`)).n), statementsBefore, '새 서술 없음');
  assert.equal((await t.one(`select content from concepts where id = $1::uuid`, [target])).content, '원래 본문');
  assert.equal((await t.one(`select count(*)::int as n from concept_content_drafts where concept_id = $1::uuid`, [target])).n, 0);

  assert.deepEqual((await sources(target)).map((s) => [s.raw_page, s.statement_id, s.draft_id, s.block_ids, s.evidence_scope]), [
    [8, null, null, [], 'unknown'],
    [8, st, row.id, ['p8-a1'], 'unknown'],
    [9, null, row.id, ['p9-a0'], 'unknown'],
  ], '이미 있던 기본 서술 8쪽은 그대로, 근거 범위는 미확인으로 들어간다');
});

test('출처만 연결은 대상 개념이 있어야 하고, 고른 서술은 그 개념의 다른 서술이어야 한다', async () => {
  const f = await folder('출처만 검사');
  const a = await insertConcept(t, '검사 가', f);
  const b = await insertConcept(t, '검사 나', f);
  const stOfB = await statement(b, '나의 서술');
  for (const [relation, re] of [
    [{ kind: 'source' }, /concept_draft_relation_target_required/],
    [{ kind: 'revise' }, /concept_draft_relation_target_required/],
    [{ kind: 'source', concept_id: a, statement_id: stOfB }, /concept_draft_relation_statement_not_found/],
    [{ kind: 'merge', concept_id: a }, /concept_draft_bad_relation/],
  ]) {
    const row = await insertDraft();
    const saved = await save(row, [item(0, [], { relation })]);
    await op(() => t.rejects(`select concept_draft_confirm($1::uuid, $2::timestamptz)`, [row.id, saved.review_saved_at], re));
  }
});

test('대표 수정안: 본문은 그대로 두고 수정안으로 저장한다. 이미 수정안이 있으면 덮지 않고 확정을 막는다', async () => {
  const f = await folder('수정안');
  const target = await insertConcept(t, '수정안 대상', f, '원래 본문');
  const row = await insertDraft();
  const res = await saveAndConfirm(row, [
    item(0, [], { relation: { kind: 'revise', concept_id: target } }),
    item(1, ['대수', '수정안 폴더']),
  ]);
  const by = Object.fromEntries(res.result.concepts.map((c) => [c.key, c]));
  assert.deepEqual([by.c0.id, by.c0.relation, by.c0.content_draft, res.result.revises], [target, 'revise', true, 1]);
  assert.equal((await t.one(`select content from concepts where id = $1::uuid`, [target])).content, '원래 본문', '본문은 바뀌지 않는다');
  const d = await t.one(`select content, base_md5, origin, note from concept_content_drafts where concept_id = $1::uuid`, [target]);
  assert.deepEqual([d.content, d.base_md5, d.origin], ['가 본문', (await t.one(`select md5('원래 본문') as m`)).m, 'ai']);
  assert.match(d.note, /개념\+유형 중1-1/);
  assert.deepEqual((await sources(target)).map((s) => [s.raw_page, s.statement_id, s.block_ids]),
    [[8, null, ['p8-a0']], [9, null, ['p9-a0']]], '수정안의 출처는 기본 서술 쪽');

  const again = await insertDraft();
  const saved = await save(again, [
    item(2, [], { mark: 'edit', content: '또 다른 수정', relation: { kind: 'revise', concept_id: target } }),
    item(1, ['대수', '수정안 폴더 둘']),
  ]);
  await op(() => t.rejects(`select concept_draft_confirm($1::uuid, $2::timestamptz)`, [again.id, saved.review_saved_at],
    /concept_draft_revise_draft_exists/));
  assert.equal((await t.one(`select content from concept_content_drafts where concept_id = $1::uuid`, [target])).content, '가 본문',
    '기존 수정안을 덮지 않는다');
  assert.equal((await t.one(`select status from concept_drafts where id = $1::uuid`, [again.id])).status, 'open', '막히면 아무것도 넣지 않는다');
  assert.equal((await t.one(`select count(*)::int as n from concepts where name = '비교 나' and main_category_id in
      (select id from concept_categories where name = '수정안 폴더 둘')`)).n, 0);

  const same = await insertConcept(t, '같은 글 대상', f, '다 본문');
  const row3 = await insertDraft();
  const res3 = await saveAndConfirm(row3, [item(2, [], { relation: { kind: 'revise', concept_id: same } })]);
  assert.deepEqual([res3.result.concepts[0].content_draft, res3.result.revises], [false, 0], '본문과 같은 글이면 수정안을 만들지 않는다');
  assert.equal((await t.one(`select count(*)::int as n from concept_content_drafts where concept_id = $1::uuid`, [same])).n, 0);
});

test('보류: 이번 확정에 넣지 않고 기록으로 남긴다. 다시 열면 같은 기록으로 새 검토 초안을 만들고, 버리면 닫힌다', async () => {
  const row = await insertDraft();
  const res = await saveAndConfirm(row, [
    item(0, [], { relation: { kind: 'hold' }, anchor: 'c1' }),
    item(1, [], { mark: 'edit', content: '보류 나', relation: { kind: 'hold' } }),
    item(2, [], { mark: 'drop' }),
  ]);
  assert.deepEqual([res.result.concepts.length, res.result.holds], [0, 2], '보류만 있어도 확정된다');
  assert.equal((await t.one(`select count(*)::int as n from concept_sources where draft_id = $1::uuid`, [row.id])).n, 0, '출처도 넣지 않는다');

  let open = await rpc(`concept_draft_holds_open()`, []);
  const mine = open.filter((h) => h.draft_id === row.id);
  assert.deepEqual(mine.map((h) => [h.item_key, h.title, h.content, h.book_name]).sort(),
    [['c0', '비교 가', '가 본문', '개념+유형 중1-1'], ['c1', '비교 나', '보류 나', '개념+유형 중1-1']]);
  const held = await t.one(`select item from concept_draft_holds where draft_id = $1::uuid and item_key = 'c0'`, [row.id]);
  assert.deepEqual(held.item.blocks, ['p8-a0', 'p9-a0'], '근거 블록을 함께 남긴다');

  await t.asUser(() => t.rejects(`select concept_draft_holds_open()`, [], /concept_draft_forbidden/));
  await op(() => t.rejects(`insert into concept_draft_holds (draft_id, item_key, item) values ($1::uuid, 'x', '{}')`, [row.id],
    /permission denied/));

  const reopened = await rpc(`concept_draft_hold_reopen($1::uuid)`, [row.id]);
  assert.equal(reopened.holds, 2);
  const next = await t.one(`select status, holds_of, pages, review, review_saved_at, prepared from concept_drafts where id = $1::uuid`,
    [reopened.draft_id]);
  assert.deepEqual([next.status, next.holds_of, next.pages], ['open', row.id, [8, 9]]);
  assert.deepEqual(next.review.concepts.map((c) => [c.key, c.content, c.relation, c.anchor ?? null]),
    [['c0', '가 본문', null, null], ['c1', '보류 나', null, null]], '관계·붙일 개념은 비운다');
  assert.deepEqual(next.prepared, PREPARED);
  open = await rpc(`concept_draft_holds_open()`, []);
  assert.equal(open.filter((h) => h.draft_id === row.id).length, 0);
  await op(() => t.rejects(`select concept_draft_hold_reopen($1::uuid)`, [row.id], /concept_draft_no_holds/));

  await rpc(`concept_draft_discard($1::uuid, $2::timestamptz)`, [reopened.draft_id, next.review_saved_at]);
  open = await rpc(`concept_draft_holds_open()`, []);
  assert.equal(open.filter((h) => h.draft_id === row.id).length, 2, '다시 연 초안을 버리면 보류 목록으로 돌아온다');

  const c1 = open.find((h) => h.draft_id === row.id && h.item_key === 'c1');
  const dropped = await rpc(`concept_draft_hold_drop($1::uuid, '다른 책에 있음')`, [c1.id]);
  assert.deepEqual([dropped.status, dropped.note], ['dropped', '다른 책에 있음']);
  await op(() => t.rejects(`select concept_draft_hold_drop($1::uuid, null)`, [c1.id], /concept_draft_hold_closed/));

  const last = await rpc(`concept_draft_hold_reopen($1::uuid)`, [row.id]);
  assert.equal(last.holds, 1, '버린 보류는 다시 열지 않는다');
  const review = (await t.one(`select review from concept_drafts where id = $1::uuid`, [last.draft_id])).review;
  assert.deepEqual(review.concepts.map((c) => c.key), ['c0']);
});

test('비교 대상 읽기: 본문·폴더·다른 서술·출처 수·책·수정안 유무를 고른 순서대로 돌려준다', async () => {
  const f = await folder('비교 대상');
  const a = await insertConcept(t, '대상 가', f, '가 기본');
  const b = await insertConcept(t, '대상 나', f, '나 기본');
  await statement(a, '가의 다른 설명');
  await t.exec(`insert into concept_sources (concept_id, academy_id, book_id, grade_label, raw_page)
                values ('${a}', '${S.academy}', '${S.book}', '1-1', 3), ('${a}', '${S.academy}', '${S.book}', '1-1', 4)`);
  await t.exec(`insert into concept_content_drafts (concept_id, content, base_md5, saved_at) values ('${b}', '나 수정', md5('나 기본'), now())`);

  const rows = await rpc(`concept_compare_targets($1::uuid[])`, [[b, a]]);
  assert.deepEqual(rows.map((r) => [r.name, r.folder, r.content, r.sources, r.content_draft]), [
    ['대상 나', ['대수', '비교 대상'], '나 기본', 0, true],
    ['대상 가', ['대수', '비교 대상'], '가 기본', 2, false],
  ]);
  assert.equal(rows[1].content_md5, (await t.one(`select md5('가 기본') as m`)).m);
  assert.deepEqual(rows[1].statements.map((s) => [s.confirmed, s.text]), [[false, '다른 서술\n가의 다른 설명']]);
  assert.equal(rows[1].books.length, 1);
  await t.asUser(() => t.rejects(`select concept_compare_targets($1::uuid[])`, [[a]], /concept_draft_forbidden/));
});

test('확정 결과에서 새 개념만 주제 묶음을 잇는다. 출처만·수정안 항목을 붙일 개념으로 골라도 잇지 않는다', async () => {
  const f = await folder('묶음');
  const target = await insertConcept(t, '묶음 대상', f, '묶음 본문');
  const row = await insertDraft();
  const path = ['대수', '묶음 폴더'];
  const res = await saveAndConfirm(row, [
    item(0, [], { relation: { kind: 'source', concept_id: target } }),
    item(1, path, { anchor: 'c0' }),
  ]);
  assert.equal(res.result.anchors, 0);
  const by = Object.fromEntries(res.result.concepts.map((c) => [c.key, c]));
  assert.equal((await t.one(`select count(*)::int as n from concept_anchor_links where concept_id = $1::uuid`, [by.c1.id])).n, 0);
});
