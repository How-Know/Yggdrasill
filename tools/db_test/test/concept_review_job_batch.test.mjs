// 개념 검수 작업 50개 묶음: 한 번에 50개 내주기, 글자 예산 묶음 읽기·이어 읽기, 판단 저장 뒤 카드 여러 장 제출,
// 항목별 승인과 완료 수, 다시 판단할 실패 위치, 요청별 실행 기록.
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
  conv = (await t.one(`insert into ai_conversations (title) values ('50개 검수') returning id`)).id;
});
after(() => t?.close());

const op = (sql, params = []) => t.asSuperadmin(() => t.one(sql, params), S.operator);
const opRejects = (sql, params, pattern) => t.asSuperadmin(() => t.rejects(sql, params, pattern), S.operator);
const r = async (sql, params) => (await op(sql, params)).r;
const revision = async (id) => (await t.one(`select concept_review_revision(concept_review_marks($1::uuid)) as r`, [id])).r;

const walk = (filter) => r(`select concept_review_walk(null, $1::jsonb, 0, 60) as r`, [JSON.stringify(filter)]);
const start = (walkId) => r(`select concept_review_job_start($1::uuid, '50개 검수') as r`, [walkId]);
const claim = async (job, holder = 'run') => (await r(`select concept_review_job_claim($1::uuid, $2, 'take') as r`, [job, holder])).gen;
const begin = (job, gen) => r(`select concept_review_job_batch_begin($1::uuid, $2::bigint) as r`, [job, gen]);
const next = (job, gen, n) => r(`select concept_review_job_next($1::uuid, $2::bigint, $3) as r`, [job, gen, n]);
const material = (job, gen, positions, offsets = {}, budget = 60000) =>
  r(`select concept_review_job_material($1::uuid, $2::bigint, $3::integer[], $4::jsonb, $5) as r`,
    [job, gen, positions, JSON.stringify(offsets), budget]);
const save = (job, gen, items) => r(`select concept_review_job_save($1::uuid, $2::bigint, $3::jsonb) as r`, [job, gen, JSON.stringify(items)]);
const submit = (job, gen) => r(`select concept_review_job_submit($1::uuid, $2::bigint, $3::uuid, '50개 검수 결과') as r`, [job, gen, conv]);
const status = (job) => r(`select concept_review_job_status($1::uuid, 60) as r`, [job]);
const apply = (id, overrides = {}) => op(`select * from course_think_action_apply($1::uuid, $2::jsonb)`, [id, JSON.stringify(overrides)]);

const review = (scope, findings = '이번에 본 범위에서 문제를 찾지 못함') => ({
  scope, outcome: 'no_issue_found', checked: `${scope} 범위`, findings, basis: '본문 전체를 읽음',
  unverified: null, follow_up: null, compared_ids: [], to_compare_ids: [],
});
const drafted = (m, reviews) => ({
  position: m.position, concept_id: m.concept_id, state: 'drafted', revision: m.revision, read_complete: true,
  unread: null, reviews, next_action: null, reason: null, rework: false,
});

async function setup(n, content = () => undefined) {
  const F = (await t.one(`insert into concept_categories (name) values ($1) returning id`, [`묶음 ${randomUUID().slice(0, 6)}`])).id;
  for (let i = 0; i < n; i++) await insertConcept(t, `묶음 개념 ${String(i + 1).padStart(2, '0')} ${randomUUID().slice(0, 4)}`, F, content(i));
  const w = await walk({ folder_id: F });
  const job = (await start(w.walk_id)).job_id;
  return { job, gen: await claim(job), ids: w.items.map((x) => x.id) };
}

async function submitAll(job, gen) {
  const cards = [];
  for (let i = 0; i < 20; i++) {
    const s = await submit(job, gen);
    if (!s.submitted) break;
    cards.push(s);
  }
  return cards;
}

test('50개·각 1범위: 한 번에 내주고 한 번에 읽고, 10개씩 저장해 카드 3장으로 내며, 다시 내도 카드는 늘지 않는다', async () => {
  const { job, gen, ids } = await setup(50);
  const b = await begin(job, gen);
  assert.deepEqual(
    [b.pending_cards, b.max_pending_cards, b.max_cards_per_request, b.max_batch, b.drafted, b.retry],
    [0, 15, 13, 50, 0, []],
  );
  const n = await next(job, gen, 50);
  assert.equal(n.batch.length, 50, '한 번에 50개까지 내준다');
  const m = await material(job, gen, n.batch.map((x) => x.position));
  assert.deepEqual([m.items.length, m.rest], [50, []]);
  assert.equal(m.items[0].revision, await revision(ids[0]), '본문과 같은 트랜잭션의 판');
  assert.equal(m.items[0].content_next_offset, null);
  assert.ok(m.items.every((x) => Array.isArray(x.sources) && typeof x.source_count === 'number' && Array.isArray(x.placements)));

  for (let i = 0; i < 50; i += 10) {
    const s = await save(job, gen, m.items.slice(i, i + 10).map((x) => drafted(x, [review('notation')])));
    assert.equal(s.saved, 10);
  }
  const cards = await submitAll(job, gen);
  assert.deepEqual(cards.map((c) => c.positions.length), [20, 20, 10], '검토 20개씩 카드 3장');
  assert.ok(cards.every((c) => !c.existing));
  assert.equal((await submit(job, gen)).submitted, false, '응답을 잃고 다시 불러도 새 카드가 없다');
  assert.equal((await t.one(`select count(*)::int as n from concept_review_job_cards where job_id = $1::uuid`, [job])).n, 3);
  assert.equal((await begin(job, gen)).pending_cards, 3);

  assert.equal((await status(job)).counts.awaiting, 50);
  await apply(cards[0].action.id);
  await apply(cards[1].action.id, { skip: [1] });
  const st = await status(job);
  assert.equal(st.progress_line, '50개 중 0개 통합 완료', '표기만 승인된 개념은 통합 완료가 아니다');
  assert.equal(st.counts.open, 1, '승인 때 뺀 항목은 미결');
  assert.equal(st.counts.awaiting, 10);
  assert.equal(st.counts.todo, 39, '표기만 승인된 개념은 부족한 범위를 보완할 대상');
  await opRejects(`select * from course_think_action_apply($1::uuid, '{}'::jsonb)`, [cards[0].action.id], /./);
  assert.equal((await status(job)).counts.todo, 39, '같은 카드를 다시 승인해도 두 번 세지 않는다');
});

test('여러 범위·긴 본문: 글자 예산을 넘으면 나머지는 rest, 긴 본문은 offset 으로 이어 읽고, 카드는 항목 수·크기로 나뉜다', async () => {
  const long = (i) => (i % 5 === 0 ? `긴 본문 ${i} `.repeat(1300) : undefined);
  const { job, gen, ids } = await setup(25, long);
  const n = await next(job, gen, 50);
  assert.equal(n.batch.length, 25);
  const positions = n.batch.map((x) => x.position);

  const first = await material(job, gen, positions, {}, 8000);
  assert.ok(first.items.length < 25 && first.rest.length > 0, '예산을 넘는 위치는 다음 읽기로 넘긴다');
  assert.equal(first.items.length + first.rest.length, 25);
  const head = first.items[0];
  assert.ok(head.content_chars > 7000 && head.content_next_offset > 0, '첫 위치가 예산보다 길면 일부만 준다');
  let text = head.content;
  let offset = head.content_next_offset;
  while (offset != null) {
    const more = await material(job, gen, [head.position], { [head.position]: offset }, 8000);
    assert.equal(more.items[0].revision, head.revision);
    text += more.items[0].content;
    offset = more.items[0].content_next_offset;
  }
  const full = (await t.one(`select content from concepts where id = $1::uuid`, [ids[0]])).content;
  assert.equal(text, full, '이어 읽으면 본문 전체가 빠짐없이 모인다');

  const all = [];
  let rest = positions;
  while (rest.length > 0) {
    const part = await material(job, gen, rest, {}, 60000);
    all.push(...part.items);
    rest = part.rest;
  }
  const scopes = ['notation', 'meaning', 'classification', 'unit', 'relations'];
  const longFindings = '발견 내용 '.repeat(180);
  const items = all.map((x, i) => drafted(x, scopes.slice(0, 1 + (i % 5)).map((s) => review(s, i % 2 ? longFindings : undefined))));
  for (let i = 0; i < items.length; i += 10) await save(job, gen, items.slice(i, i + 10));
  const entries = items.reduce((a, x) => a + x.reviews.length, 0);
  const cards = await submitAll(job, gen);
  const sizes = cards.map((c) => c.action.payload.items.length);
  assert.equal(sizes.reduce((a, x) => a + x, 0), entries, '모든 검토 항목이 어느 카드엔가 들어간다');
  assert.ok(cards.length >= Math.ceil(entries / 20));
  assert.ok(sizes.every((x) => x <= 20));
  for (const c of cards) {
    const bytes = (await t.one(`select octet_length(payload::text)::int as n from ai_actions where id = $1::uuid`, [c.action.id])).n;
    assert.ok(bytes <= 60000, `카드 크기 ${bytes}`);
  }
  assert.deepEqual(cards.flatMap((c) => c.positions).sort((a, b) => a - b), positions, '위치 하나는 카드 하나에만');
});

test('다시 판단할 실패 위치는 시작 때 알려 주고, 미결은 꺼내지 않는다. 실행 기록은 사유를 검사하고 운영자만 남긴다', async () => {
  const { job, gen } = await setup(4);
  const n = await next(job, gen, 4);
  const m = await material(job, gen, n.batch.map((x) => x.position));
  await save(job, gen, [
    drafted(m.items[0], [review('notation')]),
    { ...drafted(m.items[1], null), state: 'failed', reason: 'judge_timeout: 판단 시간 안에 응답 없음', next_action: '다음 검수 요청에서 다시 판단' },
    { ...drafted(m.items[2], null), state: 'deferred', reason: '원본 준비 중', unread: '출처 쪽 그림', next_action: '원본을 읽고 판단' },
    { ...drafted(m.items[3], null), state: 'failed', reason: '본문 읽기 실패', next_action: '다시 읽기' },
  ]);
  const b = await begin(job, gen);
  assert.deepEqual(b.retry.map((x) => x.position), [2], '판단 시간 부족은 다시 판단 대상, 미결·다른 실패는 아니다');
  assert.deepEqual([b.drafted, b.deferred], [1, 1]);

  const again = await save(job, gen, [drafted(m.items[1], [review('meaning')])]);
  assert.equal(again.items[0].status, 'saved', '실패 위치는 다시 판단해 저장할 수 있다');

  const log = { target: 4, served: 4, read: 4, saved: 3, cards: 0, rounds: 2, elapsed_ms: 1200 };
  const id = await r(`select concept_review_job_batch_log($1::uuid, $2::bigint, $3::uuid, 4, 'time_budget', $4::jsonb) as r`,
    [job, gen, conv, JSON.stringify(log)]);
  const row = await t.one(`select end_reason, log, target from concept_review_job_batches where id = $1::uuid`, [id]);
  assert.deepEqual([row.end_reason, row.log.saved, row.target], ['time_budget', 3, 4]);
  await opRejects(`select concept_review_job_batch_log($1::uuid, 1, null, 4, '그냥', '{}'::jsonb)`, [job], /check/);
  await t.asUser(() => t.rejects(`select concept_review_job_batch_log($1::uuid, 1, null, 4, 'time_budget', '{}'::jsonb)`, [job], /forbidden/));
  await t.asUser(() => t.rejects(`select concept_review_job_material($1::uuid, $2::bigint, '{1}', '{}', 1000)`, [job, gen], /forbidden/));

  const g2 = await claim(job, 'other');
  await opRejects(`select concept_review_job_material($1::uuid, $2::bigint, '{1}', '{}', 1000)`, [job, gen], /concept_review_job_lease_lost/);
  assert.ok(g2 > gen);
  const features = await r(`select ai_think_db_features() as r`);
  assert.equal(features.concept_review_job_batch, 1);
});
