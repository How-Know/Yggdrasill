// 출처 근거 범위·근거 블록(여러 교재 설명 통합 2단계). 출처 한 줄은 (개념, 서술, 책, 학년, 쪽) 단위이고,
// 근거 블록은 초안 기록에서 정확히 찾은 것만 잇는다. 범위는 운영자가 정하거나 운영자가 AI 제안을 받아들일 때만 바뀐다.
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

async function source(concept, page, statement = null) {
  return (await t.one(
    `insert into concept_sources (concept_id, academy_id, book_id, grade_label, raw_page, statement_id)
     values ($1::uuid, $2::uuid, $3::uuid, '1-1', $4, $5::uuid) returning id`,
    [concept, S.academy, S.book, page, statement],
  )).id;
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
  summary: '개념 2개',
  concepts: [
    { title: '근거 초안 가', concept_type: '정의', content: '가 본문', source_blocks: ['p8-a0', 'p9-a0'], criterion_notes: '', needs_check: '' },
    { title: '근거 초안 나', concept_type: '정의', content: '나 본문', source_blocks: ['p8-a1'], criterion_notes: '', needs_check: '' },
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

async function saveAndConfirm(row, concepts) {
  const saved = await rpc(`concept_draft_save_review($1::uuid, $2::jsonb, $3::timestamptz)`,
    [row.id, JSON.stringify({ concepts }), row.review_saved_at]);
  return rpc(`concept_draft_confirm($1::uuid, $2::timestamptz)`, [row.id, saved.review_saved_at]);
}

test('출처 한 줄은 서술까지 포함한 단위다. 같은 쪽이 기본 서술과 다른 서술을 함께 뒷받침할 수 있고, 같은 서술의 같은 쪽은 하나뿐이다', async () => {
  const f = await folder('단위');
  const c = await insertConcept(t, '단위 개념', f);
  const st = await statement(c, '다른 교재 설명');
  await source(c, 3);
  await source(c, 3, st);
  await assert.rejects(source(c, 3), /duplicate key/);
  await assert.rejects(source(c, 3, st), /duplicate key/);
  const moving = await source(c, 4, st);
  await source(c, 4);
  await op(() => t.rejects(`select concept_source_set_statement($1::uuid, null)`, [moving], /duplicate key/));
  const rows = await t.all(`select evidence_scope, evidence_origin, block_ids from concept_sources where concept_id = $1::uuid`, [c]);
  assert.ok(rows.every((r) => r.evidence_scope === 'unknown' && r.evidence_origin === null && r.block_ids.length === 0),
    '기존·직접 이은 출처는 범위 미확인, 근거 블록 없음');
});

test('초안 확정은 출처에 그 쪽의 근거 블록을 적고, 근거 조회는 블록 글과 서술 글을 돌려준다', async () => {
  const f = await folder('확정 근거');
  const target = await insertConcept(t, '근거 대상', f, '원래 본문');
  await source(target, 8);
  const row = await insertDraft();
  const path = ['대수', '근거 초안 폴더'];
  const res = await saveAndConfirm(row, [
    item(0, path, { relation: { kind: 'statement', concept_id: target } }),
    item(1, path, { blocks: ['p8-a1', 'p8-a0'] }),
  ]);
  const by = Object.fromEntries(res.result.concepts.map((c) => [c.key, c]));

  const attached = await t.all(
    `select raw_page, statement_id, draft_id, block_ids from concept_sources where concept_id = $1::uuid order by raw_page, statement_id nulls first`,
    [target]);
  assert.deepEqual(attached.map((s) => [s.raw_page, s.statement_id, s.draft_id, s.block_ids]), [
    [8, null, null, []],
    [8, by.c0.statement_id, row.id, ['p8-a0']],
    [9, by.c0.statement_id, row.id, ['p9-a0']],
  ], '이미 기본 서술의 출처였던 쪽도 다른 서술의 출처로 들어간다');
  assert.equal(res.result.sources_skipped, 0);

  const created = await t.one(`select block_ids from concept_sources where concept_id = $1::uuid`, [by.c1.id]);
  assert.deepEqual(created.block_ids, ['p8-a0', 'p8-a1'], '검토에서 고른 블록을 쪽 안 순서로');

  const ev = await rpc(`concept_source_evidence($1::uuid)`, [target]);
  assert.equal(ev.groups.length, 2);
  const base = ev.groups.find((g) => g.statement_id === null);
  assert.deepEqual([base.kind, base.text], ['base', '원래 본문']);
  const other = ev.groups.find((g) => g.statement_id === by.c0.statement_id);
  assert.equal(other.kind, 'draft');
  assert.match(other.text, /가 본문/);
  const p8 = ev.sources.find((s) => s.raw_page === 8 && s.statement_id === by.c0.statement_id);
  assert.deepEqual([p8.book_name, p8.draft_found, p8.evidence_scope, p8.basis_changed], ['개념+유형 중1-1', true, 'unknown', false]);
  assert.deepEqual(p8.blocks.map((b) => [b.id, b.kind, b.text]),
    [['p8-a0', 'concept_box', PREPARED.blocks[0].text]]);
  assert.deepEqual(ev.sources.find((s) => s.statement_id === null).blocks, []);

  await t.asUser(() => t.rejects(`select concept_source_evidence($1::uuid)`, [target], /concept_statement_forbidden/));
  await op(() => t.rejects(`select concept_source_evidence('00000000-0000-4000-8000-00000000ffff'::uuid)`, [], /concept_source_concept_not_found/));
});

test('기존 확정 초안 잇기: 기록과 개념·서술·책·학년·쪽이 모두 맞고 블록이 없는 출처만 채운다', async () => {
  const f = await folder('잇기');
  const row = await insertDraft();
  const path = ['대수', '잇기 폴더'];
  const res = await saveAndConfirm(row, [item(0, path), item(1, path)]);
  const by = Object.fromEntries(res.result.concepts.map((c) => [c.key, c]));
  await t.exec(`update concept_sources set draft_id = null, block_ids = '{}' where concept_id in ('${by.c0.id}', '${by.c1.id}')`);

  const st = await statement(by.c0.id, '옮긴 서술');
  const p9 = (await t.one(`select id from concept_sources where concept_id = $1::uuid and raw_page = 9`, [by.c0.id])).id;
  await rpc(`concept_source_set_statement($1::uuid, $2::uuid)`, [p9, st]);
  const other = await insertConcept(t, '기록에 없는 개념', f);
  await source(other, 8);
  await t.exec(`update concept_sources set block_ids = array['직접'] where concept_id = '${by.c1.id}'`);

  const n = (await t.one(`select concept_source_link_draft($1::uuid, $2::jsonb) as n`, [row.id, JSON.stringify(res.result.concepts)])).n;
  assert.equal(n, 1);
  const rows = await t.all(
    `select concept_id, raw_page, draft_id, block_ids from concept_sources where concept_id = any($1::uuid[]) order by concept_id, raw_page`,
    [[by.c0.id, by.c1.id, other]]);
  const of = (id, page) => rows.find((r) => r.concept_id === id && r.raw_page === page);
  assert.deepEqual([of(by.c0.id, 8).draft_id, of(by.c0.id, 8).block_ids], [row.id, ['p8-a0']]);
  assert.deepEqual(of(by.c0.id, 9).block_ids, [], '확정 뒤 다른 서술로 옮긴 줄은 기록과 맞지 않아 비워 둔다');
  assert.deepEqual(of(by.c1.id, 8).block_ids, ['직접'], '이미 블록이 있으면 덮지 않는다');
  assert.deepEqual(of(other, 8).block_ids, [], '기록에 없는 개념은 잇지 않는다');

  assert.equal((await t.one(`select concept_source_link_draft($1::uuid, '{"x":1}'::jsonb) as n`, [row.id])).n, 0);
  await op(() => t.rejects(`select concept_source_link_draft($1::uuid, '[]'::jsonb)`, [row.id], /permission denied/));
});

test('근거 범위: 운영자가 정하고, 본 시각이 다르면 막고, AI 제안은 제안이 본 서술 글이 지금과 같을 때만 받아들인다', async () => {
  const f = await folder('범위');
  const c = await insertConcept(t, '범위 개념', f, '범위 본문');
  const id = await source(c, 5);

  const set = await rpc(`concept_source_set_evidence($1::uuid, 'part', '  정의만 있음 ', null)`, [id]);
  assert.deepEqual([set.evidence_scope, set.evidence_note, set.evidence_origin], ['part', '정의만 있음', 'owner']);
  await op(() => t.rejects(`select concept_source_set_evidence($1::uuid, 'whole', null, null)`, [id], /concept_source_evidence_stale/));
  await op(() => t.rejects(`select concept_source_set_evidence($1::uuid, 'all', null, $2::timestamptz)`, [id, set.evidence_set_at],
    /concept_source_bad_scope/));
  await op(() => t.rejects(`select concept_source_set_evidence($1::uuid, 'whole', $2, $3::timestamptz)`,
    [id, 'ㄱ'.repeat(501), set.evidence_set_at], /concept_source_note_too_long/));

  await op(() => t.rejects(`select concept_source_set_evidence($1::uuid, 'whole', null, $2::timestamptz, 'ai', 'x')`,
    [id, set.evidence_set_at], /concept_source_basis_changed/));
  const md5 = (await rpc(`concept_source_evidence($1::uuid)`, [c])).groups[0].md5;
  const ai = await rpc(`concept_source_set_evidence($1::uuid, 'whole', null, $2::timestamptz, 'ai', $3)`, [id, set.evidence_set_at, md5]);
  assert.deepEqual([ai.evidence_scope, ai.evidence_origin, ai.evidence_note], ['whole', 'ai', null]);

  let ev = await rpc(`concept_source_evidence($1::uuid)`, [c]);
  assert.equal(ev.sources[0].basis_changed, false);
  await t.exec(`update concepts set content = '바뀐 본문' where id = '${c}'`);
  ev = await rpc(`concept_source_evidence($1::uuid)`, [c]);
  assert.equal(ev.sources[0].basis_changed, true, '범위를 정한 뒤 서술이 바뀌면 다시 확인 대상');
  assert.equal(ev.sources[0].evidence_scope, 'whole', '범위를 자동으로 되돌리지 않는다');

  await t.asUser(() => t.rejects(`select concept_source_set_evidence($1::uuid, 'whole', null, null)`, [id], /concept_statement_forbidden/));
  await op(() => t.rejects(`update concept_sources set evidence_scope = 'whole' where id = $1::uuid`, [id], /permission denied/));
  await op(() => t.rejects(`select concept_source_set_evidence('00000000-0000-4000-8000-00000000ffff'::uuid, 'whole', null, null)`, [],
    /concept_statement_source_not_found/));
});
