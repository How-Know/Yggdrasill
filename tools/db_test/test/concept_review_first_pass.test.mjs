// 1차 검수 3조건 동시 충족. 통합 완료 수·조건별 합계는 그대로 두고, 필수 네 범위의 현재 미해결만 따로 뺀다.
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { insertConcept, openConceptTestDb, seedConcepts } from '../concept_fixture.mjs';

let t;
let S;
let conv;

before(async () => {
  t = await openConceptTestDb();
  S = await seedConcepts(t);
  conv = (await t.one(`insert into ai_conversations (title) values ('1차 검수 집계') returning id`)).id;
});
after(() => t?.close());

const op = (sql, params = []) => t.asSuperadmin(() => t.one(sql, params), S.operator);
const r = async (sql, params) => (await op(sql, params)).r;
const arr = (ids) => `{${ids.join(',')}}`;
const revision = async (id) => (await t.one(`select concept_review_revision(concept_review_marks($1::uuid)) as r`, [id])).r;
const walk = (filter) => r(`select concept_review_walk(null, $1::jsonb, 0, 60) as r`, [JSON.stringify(filter)]);
const start = (walkId) => r(`select concept_review_job_start($1::uuid, '1차 검수') as r`, [walkId]);
const claim = async (job) => (await r(`select concept_review_job_claim($1::uuid, 'run', 'take') as r`, [job])).gen;
const targets = (job, gen, n = 50) => r(`select concept_review_job_targets($1::uuid, $2::bigint, $3) as r`, [job, gen, n]);
const save = (job, gen, items) => r(`select concept_review_job_save($1::uuid, $2::bigint, $3::jsonb) as r`, [job, gen, JSON.stringify(items)]);
const submit = (job, gen) => r(`select concept_review_job_submit($1::uuid, $2::bigint, $3::uuid, '1차 검수', null) as r`, [job, gen, conv]);
const status = (job) => r(`select concept_review_job_status($1::uuid, 60) as r`, [job]);
const stateOf = async (id) => (await t.one(`select concept_review_job_concept_state($1::uuid, '{}'::uuid[]) as r`, [id])).r;
const apply = (id, overrides = {}) => op(`select * from course_think_action_apply($1::uuid, $2::jsonb)`, [id, JSON.stringify(overrides)]);
const reject = (id) => op(`select * from ai_action_reject($1::uuid)`, [id]);

const review = (scope, over = {}) => ({
  scope, outcome: 'no_issue_found', checked: `${scope} 확인`, findings: '이번에 본 범위에서 문제를 찾지 못함', basis: '본문 전체를 읽음',
  unverified: null, follow_up: null, compared_ids: [], to_compare_ids: [], ...over,
});
const foundationOk = () => review('foundation', {
  checked: '필요한 초등 기초 개념을 검색해 본문과 비교', findings: '추가할 기초 개념 없음', basis: '대상 본문을 읽음',
  detail: { needs: [{ name: '약수', why: '정의에 쓰임', terms: ['약수'], candidates: [], decision: 'reuse', reuse_id: null }], not_seen: null },
});
const placementOk = () => review('placement', {
  checked: '출처와 지금 배치를 대조', findings: '배치 유지', basis: '출처 메타데이터. 교재 원본 쪽은 보지 않음',
  detail: { basis_kind: 'source', viewed_original: false },
});
const four = () => [review('notation'), review('meaning'), foundationOk(), placementOk()];
const drafted = async (position, concept, reviews, rework = false) => ({
  position, concept_id: concept, state: 'drafted', revision: await revision(concept), read_complete: true,
  unread: null, reviews, next_action: null, reason: null, rework,
});

const FOLDER = ['소인수분해', '초등 기초'];
let seq = 0;
async function setup(n) {
  const F = (await t.one(`insert into concept_categories (name) values ($1) returning id`, [`1차 ${randomUUID().slice(0, 6)}`])).id;
  const course = (await r(`select course_maps_list() as r`)).find((c) => c.name === '2-1');
  const map = await r(`select course_map_get($1::uuid) as r`, [course.id]);
  const leaf = map.units.filter((u) => u.depth === 3)[0];
  const ids = [];
  for (let i = 0; i < n; i++) {
    seq += 1;
    const id = await insertConcept(t, `1차 개념 ${seq}`, F, `1차 개념 ${seq}은 약수를 써서 정의한다.`);
    await t.exec(`insert into concept_sources (concept_id, academy_id, book_id, grade_label, raw_page, display_page, unit_path)
                  values ('${id}', '${S.academy}', '${S.book}', '중2-1', ${50 + seq}, ${40 + seq}, '{"Ⅰ. 수와 식","1. 유리수"}')`);
    ids.push(id);
  }
  await r(`select course_placement_add($1::uuid, $2::uuid[]) as r`, [leaf.id, arr(ids)]);
  const w = await walk({ folder_id: F });
  const job = (await start(w.walk_id)).job_id;
  const gen = await claim(job);
  await targets(job, gen, n);
  return { job, gen, ids, leaf };
}

async function approve(job, gen, items) {
  await save(job, gen, items);
  const sub = await submit(job, gen);
  if (sub.action) await apply(sub.action.id);
  for (const a of sub.fix_actions ?? []) await apply(a.id);
  return sub;
}

const card = (kind, payload, extra = {}) => t.one(
  `insert into ai_actions (conversation_id, kind, status, payload, result, decided_at)
   values ($1::uuid, $2, $3, $4::jsonb, $5::jsonb, $6) returning id`,
  [conv, kind, extra.status ?? 'proposed', JSON.stringify({ items: payload }), extra.result ? JSON.stringify(extra.result) : null, extra.decidedAt ?? null],
);
const drop = (id) => t.one(`delete from ai_actions where id = $1::uuid returning id`, [id]);

test('네 범위가 승인되면 포함하고, 조건별 합계나 관계·분류 미결로 세지 않는다', async () => {
  const { job, gen, ids } = await setup(3);
  await approve(job, gen, [
    await drafted(1, ids[0], four()),
    await drafted(2, ids[1], four()),
    await drafted(3, ids[2], [review('notation')]),
  ]);
  let st = await status(job);
  assert.equal(st.progress_line, '3개 중 2개 통합 완료');
  assert.deepEqual(st.conditions, { text: 2, foundation: 2, placement: 2 });
  assert.equal(st.first_pass.met, 2);
  assert.equal(st.first_pass.total, 3);
  assert.equal(st.first_pass.line, '1차 검수 3조건 충족: 2 / 3개(66.7%)');
  assert.equal(st.first_pass_line, st.first_pass.line);
  assert.equal(st.total_mismatch, false);

  await approve(job, gen, [await drafted(3, ids[2], [review('meaning'), foundationOk(), placementOk()], true)]);
  st = await status(job);
  assert.equal(st.counts.complete, 3);
  assert.deepEqual(st.conditions, { text: 3, foundation: 3, placement: 3 });
  assert.equal(st.first_pass.line, '1차 검수 3조건 충족: 3 / 3개(100.0%)');

  await approve(job, gen, [await drafted(2, ids[1], [review('classification', {
    outcome: 'needs_comparison', findings: '분류를 더 봐야 함',
  })], true)]);
  st = await status(job);
  assert.equal(st.counts.complete, 2, '분류 미결은 통합 완료에서 빠진다');
  assert.equal(st.conditions.text, 3, '조건별 합계는 그대로다');
  assert.equal(st.first_pass.met, 3, '분류 미결만으로 1차 검수 수에서 빼지 않는다');

  const rel = await card('concept_review_record', [{ concept_id: ids[0], scope: 'relations', outcome: 'needs_comparison' }]);
  st = await status(job);
  assert.equal(st.counts.complete, 1, '관계 대기 카드가 있으면 기존 통합 완료는 그 개념을 뺀다');
  assert.equal(st.first_pass.met, 3, '관계 대기만으로 1차 검수 수에서 빼지 않는다');
  await drop(rel.id);

  const unit = await card('concept_review_record', [{ concept_id: ids[0], scope: 'unit', outcome: 'merge_needed' }]);
  const folder = await card('concept_library_change', [{ op: 'edit', concept_id: ids[0], type: '정의', folder: FOLDER }]);
  st = await status(job);
  assert.equal(st.first_pass.met, 3, '개념 단위 대기와 분류만 고치는 카드는 1차 검수 수에 남긴다');
  assert.equal(st.counts.complete < 3, true);
  await drop(unit.id);
  await drop(folder.id);
  st = await status(job);
  assert.equal(st.counts.complete, 2);
  assert.equal(st.first_pass.met, 3);
});

test('필수 범위의 미해결은 빼고, 해소되거나 무관한 초안은 다시 넣는다. 분모는 저장된 총수다', async () => {
  const { job, gen, ids } = await setup(2);
  await approve(job, gen, [
    await drafted(1, ids[0], four()),
    await drafted(2, ids[1], four()),
  ]);
  let st = await status(job);
  assert.equal(st.counts.complete, 2);
  assert.equal(st.first_pass.met, 2);

  await save(job, gen, [await drafted(1, ids[0], [review('notation', {
    outcome: 'issue_found', findings: '표기가 틀림',
    fix: { kind: 'library', ops: [{ op: 'edit', name: `고친 ${randomUUID().slice(0, 4)}` }] },
  })], true)]);
  st = await status(job);
  assert.equal(st.counts.complete, 2, '승인 기록이 그대로면 통합 완료 수는 초안 때문에 바뀌지 않는다');
  assert.equal(st.conditions.text, 2);
  assert.equal(st.first_pass.met, 1, '같은 판의 문제 초안이 있으면 1차 검수에서 뺀다');

  await save(job, gen, [await drafted(1, ids[0], [review('notation', { outcome: 'needs_comparison', findings: '비교가 더 필요' })], true)]);
  assert.equal((await status(job)).first_pass.met, 1);
  await save(job, gen, [await drafted(1, ids[0], [review('notation', { outcome: 'unverified', findings: '확인 못 함' })], true)]);
  assert.equal((await status(job)).first_pass.met, 1);

  await save(job, gen, [await drafted(1, ids[0], [review('notation')], true)]);
  st = await status(job);
  assert.equal(st.first_pass.met, 2, '같은 판의 무문제 초안만으로는 빼지 않는다');
  assert.equal(st.counts.complete, 2);

  const row = await t.one(`select draft from concept_review_job_items where job_id = $1::uuid and pos = 1`, [job]);
  row.draft.push({ ...review('meaning', { outcome: 'issue_found', findings: '이미 지난 판' }), revision: 'stale-stale-stale-stale' });
  await t.one(`update concept_review_job_items set draft = $2::jsonb where job_id = $1::uuid and pos = 1 returning pos`, [job, JSON.stringify(row.draft)]);
  assert.equal((await status(job)).first_pass.met, 2, '판이 다른 옛 문제 초안은 빼지 않는다');

  await save(job, gen, [await drafted(1, ids[0], [review('meaning', { outcome: 'needs_comparison', findings: '비교가 더 필요' })], true)]);
  assert.equal((await status(job)).first_pass.met, 1, '지금 판의 비교 필요 초안은 뺀다');
  await save(job, gen, [await drafted(1, ids[0], [review('meaning')], true)]);
  assert.equal((await status(job)).first_pass.met, 2);

  const outside = await card('concept_review_record', [{ concept_id: ids[1], scope: 'foundation', outcome: 'no_issue_found' }]);
  st = await status(job);
  assert.equal(st.conditions.foundation, 2, '대기 카드가 있어도 조건별 합계는 승인 기록 그대로다');
  assert.equal(st.first_pass.met, 1, '작업 밖 필수 범위 검토 대기도 뺀다');
  await drop(outside.id);
  assert.equal((await status(job)).first_pass.met, 2);

  const edit = await card('concept_library_change', [{ op: 'edit', concept_id: ids[1], content: '본문을 고친다' }]);
  assert.equal((await status(job)).first_pass.met, 1, '본문 고치기 대기는 표기·의미의 미해결이다');
  await drop(edit.id);
  assert.equal((await status(job)).first_pass.met, 2);
});

test('보류·거절·반영 실패는 재확인 전까지 빼고, 분모 0과 불일치는 숨기지 않는다', async () => {
  const { job, gen, ids, leaf } = await setup(1);
  let st = await status(job);
  assert.equal(st.first_pass.line, '1차 검수 3조건 충족: 0 / 1개(0.0%)');
  assert.equal(st.counts.complete, 0);

  await approve(job, gen, [await drafted(1, ids[0], four())]);
  await save(job, gen, [await drafted(1, ids[0], [review('notation', {
    outcome: 'issue_found', findings: '표기를 고쳐야 함',
    fix: { kind: 'library', ops: [{ op: 'edit', name: `다시 ${randomUUID().slice(0, 4)}` }] },
  })], true)]);
  const sub = await submit(job, gen);
  assert.equal(sub.action, null, '고치기에 의존하는 표기 검토는 카드로 바로 나가지 않는다');
  st = await status(job);
  assert.equal(st.conditions.text, 1, '예전 승인 기록은 met로 남는다');
  assert.equal(st.first_pass.met, 0, '그 승인과 새 보류가 함께 있으면 1차 검수에서는 뺀다');
  const fix = sub.fix_actions[0];
  await reject(fix.id);
  assert.equal((await status(job)).first_pass.met, 0, '고치기 거절만으로 다시 넣지 않는다');

  await approve(job, gen, [await drafted(1, ids[0], [review('notation')], true)]);
  st = await status(job);
  assert.equal(st.first_pass.met, 1, '거절 뒤 그 범위를 다시 승인하면 넣는다');
  assert.equal(st.counts.complete, 1);
  assert.equal(st.progress_line, '1개 중 1개 통합 완료');

  const failed = await card('concept_review_record', [
    { concept_id: ids[0], scope: 'placement', outcome: 'issue_found' },
  ], {
    status: 'applied',
    result: { items: [{ i: 1, status: 'failed', code: 'concept_review_stale' }] },
    decidedAt: new Date().toISOString(),
  });
  assert.equal((await status(job)).first_pass.met, 0, '반영에 실패한 필수 범위 문제는 대기 상태가 아니어도 뺀다');
  await approve(job, gen, [await drafted(1, ids[0], [placementOk()], true)]);
  assert.equal((await status(job)).first_pass.met, 1, '그 뒤 배치를 다시 승인하면 넣는다');
  await drop(failed.id);
  const skipped = await card('concept_review_record', [
    { concept_id: ids[0], scope: 'meaning', outcome: 'no_issue_found' },
  ], {
    status: 'applied',
    result: { items: [{ i: 1, status: 'skipped' }] },
    decidedAt: new Date().toISOString(),
  });
  assert.equal((await status(job)).first_pass.met, 1, '문제 없는 항목을 승인 때 뺀 것만으로는 빼지 않는다');
  await drop(skipped.id);

  const move = await card('concept_placement_change', [{
    op: 'move', placement_id: (await t.one(`select id from concept_appearances where concept_id = $1::uuid and course_unit_id is not null`, [ids[0]])).id,
    unit_id: leaf.id, evidence: '확인',
  }]);
  assert.equal((await status(job)).first_pass.met, 0, '작업 밖 배치 고치기 대기도 뺀다');
  await drop(move.id);
  assert.equal((await status(job)).first_pass.met, 1);

  const appliedFix = await card('concept_library_change', [{ op: 'create', name: `기초 ${randomUUID().slice(0, 4)}` }], {
    status: 'applied',
    result: { items: [{ i: 1, status: 'applied' }] },
    decidedAt: new Date().toISOString(),
  });
  const pendingFix = await card('concept_library_change', [{ op: 'create', name: `다른 기초 ${randomUUID().slice(0, 4)}` }]);
  const hold = (deps) => JSON.stringify([{ scope: 'foundation', deps }]);
  await t.one(
    `update concept_review_job_items set state = 'held', held_fixes = $2::jsonb where job_id = $1::uuid and pos = 1 returning pos`,
    [job, hold([{ action_id: appliedFix.id, item: 1 }, { action_id: pendingFix.id, item: 1 }])],
  );
  await t.one(
    `insert into concept_quality_reviews (concept_id, scope, outcome, checked, findings, basis, marks, mark)
     select $1::uuid, 'foundation', 'no_issue_found', '반영 뒤 다시 확인', '문제 없음', '지금 본문',
            concept_review_marks($1::uuid), concept_review_marks($1::uuid) ->> concept_review_scope_mark('foundation')
     returning id`,
    [ids[0]],
  );
  st = await status(job);
  assert.equal(st.conditions.foundation, 1, '나중 승인이 있으면 조건별 합계는 그대로다');
  assert.equal(st.first_pass.met, 0, '같은 범위에 아직 대기인 고치기가 있으면 그 승인만으로 넣지 않는다');
  await t.one(
    `update concept_review_job_items set held_fixes = $2::jsonb where job_id = $1::uuid and pos = 1 returning pos`,
    [job, hold([{ action_id: appliedFix.id, item: 1 }])],
  );
  assert.equal((await status(job)).first_pass.met, 1, '대기 고치기가 빠지고 그 뒤 승인이 있으면 다시 넣는다');
  await t.one(
    `update concept_review_job_items set state = 'submitted', held_fixes = '[]'::jsonb where job_id = $1::uuid and pos = 1 returning pos`,
    [job],
  );
  await drop(appliedFix.id);
  await drop(pendingFix.id);
  st = await status(job);
  assert.equal(st.counts.complete, 1);
  assert.equal(st.first_pass.met, 1);

  await t.one(`update concepts set content = content || ' 더' where id = $1::uuid returning id`, [ids[0]]);
  st = await status(job);
  assert.notEqual((await stateOf(ids[0])).conditions.text, 'met');
  assert.equal(st.first_pass.met, 0, '본문이 바뀌어 재확인이 필요하면 뺀다');
  assert.equal(st.counts.complete, 0, '통합 완료도 기존 정의대로 빠진다');

  await t.one(`update concept_review_jobs set total = 0 where id = $1::uuid returning id`, [job]);
  st = await status(job);
  assert.equal(st.first_pass.total, 0);
  assert.equal(st.first_pass.percent, null);
  assert.equal(st.first_pass.line, '1차 검수 3조건 충족: 0 / 0개');
  assert.equal(st.progress_line, '0개 중 0개 통합 완료');
  assert.equal(st.total_mismatch, true, '분모가 0이어도 불일치를 숨기지 않는다');

  await t.one(`update concept_review_jobs set total = 9 where id = $1::uuid returning id`, [job]);
  st = await status(job);
  assert.equal(st.first_pass.line, '1차 검수 3조건 충족: 0 / 9개(0.0%)');
  assert.equal(st.progress_line, '9개 중 0개 통합 완료');
  assert.equal(st.total_mismatch, true);
  assert.equal(st.walk_total, 1);
});
