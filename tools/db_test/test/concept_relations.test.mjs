// 개념 사이 관계·검토 필요 표시, 초안 확정 때 항목마다 고른 관계(새 개념 / 다른 서술 / 확장 / 특수한 경우 / 검토 필요).
// 이름이 같다는 것만으로 합치거나 관계를 넣지 않고, 기존 개념의 확정본·본문은 바꾸지 않는다.
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

test('운영자만 관계를 넣고 뺀다. 자기 자신·거꾸로 된 쌍·없는 개념·잘못된 종류는 막고 표에 직접 쓰지 못한다', async () => {
  const f = await folder('관계 시험');
  const a = await insertConcept(t, '관계 가', f);
  const b = await insertConcept(t, '관계 나', f);
  const r = await rpc(`concept_relation_set($1::uuid, $2::uuid, 'extends', '넓힘')`, [a, b]);
  assert.equal(r.kind, 'extends');
  assert.equal(r.origin, 'manual');
  const r2 = await rpc(`concept_relation_set($1::uuid, $2::uuid, 'special_case')`, [a, b]);
  assert.equal(r2.id, r.id, '같은 쌍은 종류만 바뀐다');
  assert.equal(r2.kind, 'special_case');

  await op(() => t.rejects(`select concept_relation_set($1::uuid, $2::uuid, 'extends')`, [b, a], /concept_relation_reverse_exists/));
  await op(() => t.rejects(`select concept_relation_set($1::uuid, $1::uuid, 'extends')`, [a], /concept_relation_bad_request/));
  await op(() => t.rejects(`select concept_relation_set($1::uuid, $2::uuid, 'same')`, [a, b], /concept_relation_bad_kind/));
  await op(() => t.rejects(
    `select concept_relation_set($1::uuid, '00000000-0000-4000-8000-00000000ffff'::uuid, 'extends')`, [a], /concept_relation_not_found/));
  await t.asUser(() => t.rejects(`select concept_relation_set($1::uuid, $2::uuid, 'extends')`, [b, a], /concept_relation_forbidden/));
  assert.equal((await t.asUser(() => t.all(`select id from concept_relations`))).length, 0);
  await op(() => t.rejects(
    `insert into concept_relations (concept_id, related_id, kind, origin) values ($1::uuid, $2::uuid, 'extends', 'manual')`,
    [b, a], /permission denied/));
  await op(() => t.rejects(`select concept_relation_put($1::uuid, $2::uuid, 'extends', 'manual', null, null)`, [b, a], /permission denied/));

  assert.deepEqual(await rpc(`concept_relation_remove($1::uuid)`, [r.id]), { id: r.id, removed: true });
  await op(() => t.rejects(`select concept_relation_remove($1::uuid)`, [r.id], /concept_relation_not_found/));
});

test('검토 필요: 열고, 같은 쌍은 하나만 열리고, 판단하면 닫힌다. 확장·특수한 경우만 관계를 넣고 같은 개념은 합치지 않는다', async () => {
  const f = await folder('검토 시험');
  const a = await insertConcept(t, '검토 가', f);
  const b = await insertConcept(t, '검토 나', f);
  const c = await insertConcept(t, '검토 다', f);
  const open = await rpc(`concept_review_open($1::uuid, $2::uuid, '같은지 확인')`, [a, b]);
  assert.equal(open.status, 'open');
  assert.equal((await rpc(`concept_review_open($1::uuid, $2::uuid)`, [b, a])).id, open.id, '반대 방향도 같은 표시');

  const same = await rpc(`concept_review_resolve($1::uuid, 'same', null, '같은 개념')`, [open.id]);
  assert.deepEqual([same.status, same.resolution, same.resolution_note], ['resolved', 'same', '같은 개념']);
  await op(() => t.rejects(`select concept_review_resolve($1::uuid, 'different')`, [open.id], /concept_review_closed/));
  assert.equal(Number((await t.one(`select count(*)::int as n from concepts where id = any($1::uuid[])`, [[a, b]])).n), 2);
  assert.equal((await op(() => t.all(`select id from concept_relations where concept_id = $1::uuid`, [a]))).length, 0);

  const lone = await rpc(`concept_review_open($1::uuid)`, [c]);
  await op(() => t.rejects(`select concept_review_resolve($1::uuid, 'extends')`, [lone.id], /concept_review_other_required/));
  const ext = await rpc(`concept_review_resolve($1::uuid, 'extends', $2::uuid)`, [lone.id, a]);
  assert.equal(ext.other_id, a);
  const rel = await op(() => t.one(`select kind, origin from concept_relations where concept_id = $1::uuid and related_id = $2::uuid`, [c, a]));
  assert.deepEqual([rel.kind, rel.origin], ['extends', 'review']);

  const rev = await rpc(`concept_review_open($1::uuid, $2::uuid)`, [b, c]);
  const reversed = await rpc(`concept_review_resolve($1::uuid, 'special_case', null, null, true)`, [rev.id]);
  assert.deepEqual([reversed.concept_id, reversed.other_id, reversed.resolution], [c, b, 'special_case'], '반대로 고르면 두 쪽을 바꿔 적는다');
  assert.equal((await op(() => t.one(`select kind from concept_relations where concept_id = $1::uuid and related_id = $2::uuid`, [c, b]))).kind,
    'special_case');
  const lone2 = await rpc(`concept_review_open($1::uuid)`, [b]);
  await op(() => t.rejects(`select concept_review_resolve($1::uuid, 'different', null, null, true)`, [lone2.id], /concept_review_other_required/));

  const diff = await rpc(`concept_review_open($1::uuid)`, [b]);
  assert.equal(diff.id, lone2.id, '상대 없는 열린 표시는 하나만');
  assert.equal((await rpc(`concept_review_resolve($1::uuid, 'different')`, [diff.id])).resolution, 'different');
  await t.asUser(() => t.rejects(`select concept_review_open($1::uuid)`, [a], /concept_relation_forbidden/));
});

test('같은 이름 검토 창: 쌍마다 판단을 남기고 양쪽 열린 표시를 닫는다. 개념은 그대로 둔다', async () => {
  const f1 = await folder('같은 이름 1');
  const f2 = await folder('같은 이름 2');
  const a = await insertConcept(t, '쌍 소수', f1, '중1 서술');
  const b = await insertConcept(t, '쌍 소수', f2, '고1 서술');
  await rpc(`concept_review_open($1::uuid, $2::uuid)`, [b, a]);
  const r = await rpc(`concept_review_decide_pair($1::uuid, $2::uuid, 'special_case', '중1은 자연수 범위')`, [a, b]);
  assert.deepEqual([r.reason, r.resolution, r.status], ['same_name', 'special_case', 'resolved']);
  const open = await op(() => t.all(`select id from concept_reviews where status = 'open' and concept_id = any($1::uuid[])`, [[a, b]]));
  assert.equal(open.length, 0);
  assert.equal((await op(() => t.one(`select kind from concept_relations where concept_id = $1::uuid`, [a]))).kind, 'special_case');
  const rows = await t.all(`select content from concepts where id = any($1::uuid[]) order by content`, [[a, b]]);
  assert.deepEqual(rows.map((x) => x.content), ['고1 서술', '중1 서술']);
});

const PREPARED = {
  blocks: [
    { id: 'p8-a0', raw_page: 8, read: 'a', kind: 'concept_box', title: '', text: '소수' },
    { id: 'p8-a1', raw_page: 8, read: 'a', kind: 'concept_box', title: '', text: '합성수' },
    { id: 'p9-a0', raw_page: 9, read: 'a', kind: 'note', title: '', text: '1은 소수도 합성수도 아니다' },
  ],
  furniture: [],
  disagreements: [],
};
const DRAFT = {
  summary: '개념 5개',
  concepts: [
    { title: '관계 초안 가', concept_type: '정의', content: '가 본문', source_blocks: ['p8-a0'], criterion_notes: '', needs_check: '' },
    { title: '관계 초안 나', concept_type: '정의', content: '나 본문', source_blocks: ['p8-a1'], criterion_notes: '', needs_check: '' },
    { title: '관계 초안 다', concept_type: '정의', content: '다 본문', source_blocks: ['p9-a0'], criterion_notes: '', needs_check: '' },
    { title: '관계 초안 라', concept_type: '정의', content: '라 본문', source_blocks: ['p9-a0'], criterion_notes: '', needs_check: '' },
    { title: '관계 초안 마', concept_type: '정의', content: '마 본문', source_blocks: ['p9-a0'], criterion_notes: '', needs_check: '' },
  ],
  excluded: [],
  questions: [],
};

async function insertDraft(folderPlan = null) {
  return t.one(
    `insert into concept_drafts (academy_id, book_id, grade_label, book_name, unit_path, pages, page_meta, model, prompt_version, prepared, draft, checks, folder_plan)
     values ($1::uuid, $2::uuid, '1-1', '개념+유형 중1-1', array['소인수분해'], array[8, 9],
             '[{"raw_page":8,"display_page":18},{"raw_page":9,"display_page":19}]'::jsonb,
             'gpt', 'concept_draft_organize.v3', $3::jsonb, $4::jsonb, '{}'::jsonb, $5::jsonb)
     returning id, review_saved_at`,
    [S.academy, S.book, JSON.stringify(PREPARED), JSON.stringify(DRAFT), folderPlan ? JSON.stringify(folderPlan) : null],
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

async function saveAndConfirm(row, concepts) {
  const saved = await rpc(`concept_draft_save_review($1::uuid, $2::jsonb, $3::timestamptz)`,
    [row.id, JSON.stringify({ concepts }), row.review_saved_at]);
  return rpc(`concept_draft_confirm($1::uuid, $2::timestamptz)`, [row.id, saved.review_saved_at]);
}

test('확정: 다른 서술은 기존 개념에 확정 전 서술로 붙고, 확장·특수한 경우는 관계, 검토 필요·같은 이름·AI 겹침은 표시로 남는다', async () => {
  const f = await folder('확정 기존');
  const target = await insertConcept(t, '확정 대상', f, '원래 본문');
  const base = await insertConcept(t, '확정 기준', f, '기준 본문');
  const sameName = await insertConcept(t, '관계 초안 라', f, '이미 있는 라');
  await t.exec(
    `insert into concept_sources (concept_id, academy_id, book_id, grade_label, raw_page, display_page)
     values ('${target}', '${S.academy}', '${S.book}', '1-1', 9, 19)`,
  );
  const row = await insertDraft({ overlaps: [{ concept: 4, other: '소수의 뜻', reason: '같은 정의' }] });
  const path = ['대수', '관계 초안 폴더'];
  const res = await saveAndConfirm(row, [
    item(0, path, { mark: 'edit', content: '고친 가 본문', relation: { kind: 'statement', concept_id: target }, anchor: 'c1' }),
    item(1, path, { relation: { kind: 'extends', concept_id: base } }),
    item(2, path, { relation: { kind: 'review', concept_id: base }, anchor: 'c1' }),
    item(3, path),
    item(4, path),
  ]);
  const r = res.result;
  assert.deepEqual([r.statements, r.relations, r.reviews, r.anchors], [1, 1, 3, 1]);
  assert.equal(r.concepts.length, 5);
  const by = Object.fromEntries(r.concepts.map((c) => [c.key, c]));
  assert.equal(by.c0.id, target);
  assert.equal(by.c0.relation, 'statement');

  const st = await op(() => t.one(`select * from concept_statements where id = $1::uuid`, [by.c0.statement_id]));
  assert.deepEqual([st.concept_id, st.role, st.version, st.content, st.draft_origin], [target, 'statement', 0, null, 'owner']);
  assert.deepEqual(st.draft, { title: '관계 초안 가', body: '고친 가 본문', basis: 'organized', terms: [] });
  assert.equal((await t.one(`select content from concepts where id = $1::uuid`, [target])).content, '원래 본문');
  const src = await t.all(
    `select raw_page, display_page, statement_id from concept_sources where concept_id = $1::uuid order by raw_page`, [target]);
  assert.deepEqual(src.map((s) => [s.raw_page, s.display_page, s.statement_id]),
    [[8, 18, by.c0.statement_id], [9, 19, null]], '새 쪽만 그 서술에, 이미 있던 쪽은 그대로');
  assert.equal(Number((await t.one(`select count(*)::int as n from concepts where name = '관계 초안 가'`)).n), 0);

  const rel = await op(() => t.one(`select related_id, kind, origin, draft_id from concept_relations where concept_id = $1::uuid`, [by.c1.id]));
  assert.deepEqual([rel.related_id, rel.kind, rel.origin, rel.draft_id], [base, 'extends', 'draft', row.id]);

  const reviews = await op(() => t.all(
    `select concept_id, other_id, reason, note, status from concept_reviews where draft_id = $1::uuid order by reason`, [row.id]));
  const reviewOf = Object.fromEntries(reviews.map((v) => [v.concept_id, v]));
  assert.deepEqual([reviewOf[by.c2.id].reason, reviewOf[by.c2.id].other_id], ['draft', base]);
  assert.deepEqual([reviewOf[by.c3.id].reason, reviewOf[by.c3.id].other_id], ['same_name', sameName]);
  assert.deepEqual([reviewOf[by.c4.id].reason, reviewOf[by.c4.id].other_id, reviewOf[by.c4.id].note],
    ['overlap', null, '소수의 뜻 (같은 정의)']);
  assert.ok(reviews.every((v) => v.status === 'open'));
  assert.equal((await t.one(`select content from concepts where id = $1::uuid`, [sameName])).content, '이미 있는 라');

  const anchor = await t.one(`select concept_id, anchor_id from concept_anchor_links where draft_id = $1::uuid`, [row.id]);
  assert.deepEqual([anchor.concept_id, anchor.anchor_id], [by.c2.id, by.c1.id], '서술로 붙인 항목의 묶음은 잇지 않는다');
});

test('확정: 새 개념으로 고르면 같은 이름이 있어도 표시하지 않고, 대상 없는 관계·없는 개념·모르는 종류는 막는다', async () => {
  const f = await folder('확정 새 개념');
  await insertConcept(t, '관계 초안 가', f, '이미 있는 가');
  const path = ['대수', '관계 초안 폴더 2'];
  const row = await insertDraft();
  const res = await saveAndConfirm(row, [item(0, path, { relation: { kind: 'new' } })]);
  assert.equal(res.result.reviews, 0);
  assert.equal(res.result.concepts[0].relation, 'new');

  for (const [relation, err] of [
    [{ kind: 'statement' }, /concept_draft_relation_target_required/],
    [{ kind: 'extends', concept_id: '00000000-0000-4000-8000-00000000ffff' }, /concept_draft_relation_target_not_found/],
    [{ kind: 'merge', concept_id: S.concept }, /concept_draft_bad_relation/],
    ['statement', /concept_draft_bad_relation/],
  ]) {
    const bad = await insertDraft();
    const before = Number((await t.one(`select count(*)::int as n from concepts`)).n);
    await assert.rejects(saveAndConfirm(bad, [item(1, path), item(0, path, { relation })]), err);
    assert.equal(Number((await t.one(`select count(*)::int as n from concepts`)).n), before, '하나라도 어긋나면 아무것도 들어가지 않는다');
  }
});

test('Think 변경 카드로 항목을 고쳐도 relation 은 남는다', async () => {
  const norm = await t.one(`select concept_draft_item_norm($1::jsonb) as r`,
    [JSON.stringify({ index: 0, relation: { kind: 'extends', concept_id: S.concept }, extra: 1 })]);
  assert.deepEqual(norm.r.relation, { kind: 'extends', concept_id: S.concept });
  assert.equal(norm.r.extra, undefined);
});
