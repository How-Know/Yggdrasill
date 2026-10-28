// 개념 검수 실패 사유는 기존 reason에 남고, 실패만 위치 순서대로 나눠 읽는다.
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { insertConcept, openConceptTestDb, seedConcepts } from '../concept_fixture.mjs';

let t;
let S;

before(async () => {
  t = await openConceptTestDb();
  S = await seedConcepts(t);
});
after(() => t?.close());

const op = (sql, params = []) => t.asSuperadmin(() => t.one(sql, params), S.operator);
const r = async (sql, params) => (await op(sql, params)).r;
const revision = async (id) => (await t.one(`select concept_review_revision(concept_review_marks($1::uuid)) as r`, [id])).r;
const walk = (filter) => r(`select concept_review_walk(null, $1::jsonb, 0, 60) as r`, [JSON.stringify(filter)]);
const start = (walkId) => r(`select concept_review_job_start($1::uuid, '실패 원인') as r`, [walkId]);
const claim = async (job) => (await r(`select concept_review_job_claim($1::uuid, 'run', 'take') as r`, [job])).gen;
const next = (job, gen, n) => r(`select concept_review_job_next($1::uuid, $2::bigint, $3) as r`, [job, gen, n]);
const save = (job, gen, items) => r(`select concept_review_job_save($1::uuid, $2::bigint, $3::jsonb) as r`, [job, gen, JSON.stringify(items)]);
const status = (job) => r(`select concept_review_job_status_live($1::uuid, 60) as r`, [job]);
const begin = (job, gen) => r(`select concept_review_job_batch_begin($1::uuid, $2::bigint) as r`, [job, gen]);
const page = (job, after = 0, limit = 50) =>
  r(`select concept_review_job_failure_page($1::uuid, $2, $3) as r`, [job, after, limit]);

const SPECIFIC = 'judge_invalid:fix_evidence_empty:placement:reviews[0].fix.ops[0].evidence:non_empty_text:empty_string';
const GENERIC = 'judge_invalid: 판단 형식이 맞지 않음(범위·결과·근거·고치기 제안·비교 개념)';

test('저장된 실패 사유는 그대로 이어 읽고, 다른 위치·승인·완료 수는 바꾸지 않는다', async () => {
  const F = (await t.one(`insert into concept_categories (name) values ($1) returning id`, [`실패 ${randomUUID().slice(0, 6)}`])).id;
  for (const name of ['실패 ㄱ', '실패 ㄴ', '실패 ㄷ', '실패 ㄹ']) await insertConcept(t, `${name} ${randomUUID().slice(0, 4)}`, F);
  const w = await walk({ folder_id: F });
  const job = (await start(w.walk_id)).job_id;
  const gen = await claim(job);
  const n = await next(job, gen, 4);
  const beforeReviews = (await t.one(`select count(*)::int as n from concept_quality_reviews`)).n;
  const beforeStatus = await status(job);

  const failed = (m, reason) => ({
    position: m.position, concept_id: m.concept_id, state: 'failed', revision: m.revision, read_complete: true,
    unread: null, reviews: null, reason, next_action: '다음 검수 요청에서 다시 판단', rework: false,
  });
  const saved = await save(job, gen, [
    failed(n.batch[0], SPECIFIC),
    {
      position: n.batch[1].position, concept_id: n.batch[1].concept_id, state: 'drafted', revision: n.batch[1].concept.revision,
      read_complete: true, unread: null, reviews: [{
        scope: 'notation', outcome: 'no_issue_found', checked: '표기', findings: '문제 없음', basis: '본문',
        unverified: null, follow_up: null, compared_ids: [], to_compare_ids: [],
      }], next_action: null, reason: null, rework: false,
    },
    failed(n.batch[2], GENERIC),
    {
      position: n.batch[3].position, concept_id: n.batch[3].concept_id, state: 'deferred',
      revision: await revision(n.batch[3].concept_id), read_complete: true, unread: null, reviews: null,
      reason: 'concept_review_too_many_refs:notation:compared_ids:21:20',
      next_action: '판이 바뀌거나 상한이 커지기 전에는 자동으로 다시 판단하지 않는다', rework: false,
    },
  ]);
  assert.equal(saved.saved, 4);

  const first = await page(job, 0, 1);
  assert.equal(first.returned, 1);
  assert.equal(first.omitted, 1);
  assert.equal(Number(first.next_after), n.batch[0].position);
  assert.equal(first.items[0].reason, SPECIFIC);
  assert.equal(first.items[0].name.startsWith('실패 ㄱ'), true);
  const second = await page(job, Number(first.next_after), 50);
  assert.equal(second.returned, 1);
  assert.equal(second.omitted, 0);
  assert.equal(second.next_after, null);
  assert.equal(second.items[0].reason, GENERIC);
  assert.equal(second.items[0].position, n.batch[2].position);

  const all = await page(job);
  assert.deepEqual(all.items.map((i) => i.position), [n.batch[0].position, n.batch[2].position]);
  const stored = await t.one(
    `select reason from concept_review_job_items where job_id = $1::uuid and pos = $2`,
    [job, n.batch[2].position],
  );
  assert.equal(stored.reason, GENERIC);

  const st = await status(job);
  assert.equal(st.counts.complete, beforeStatus.counts.complete);
  assert.equal(st.first_pass.met, beforeStatus.first_pass.met);
  const openSpecific = st.open_items.find((i) => i.position === n.batch[0].position);
  assert.equal(openSpecific.reason, SPECIFIC);
  const draft = await t.one(
    `select state, draft is not null as has_draft from concept_review_job_items where job_id = $1::uuid and pos = $2`,
    [job, n.batch[1].position],
  );
  assert.deepEqual([draft.state, draft.has_draft], ['drafted', true]);
  assert.equal((await t.one(`select count(*)::int as n from concept_quality_reviews`)).n, beforeReviews);

  const retry = await begin(job, gen);
  assert.deepEqual(retry.retry.map((i) => i.position), [n.batch[0].position, n.batch[2].position]);

  await t.asUser(() => t.rejects(
    `select concept_review_job_failure_page($1::uuid, 0, 50)`,
    [job],
    /concept_review_forbidden/,
  ));
});
