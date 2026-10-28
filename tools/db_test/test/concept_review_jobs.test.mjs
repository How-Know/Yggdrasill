// 개념 검수 작업: 고정 목록을 대화와 상관없이 이어 가고, 늦은 쓰기를 막고, 같은 초안은 같은 카드로, 완료는 승인 기록으로 센다.
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { insertConcept, openConceptTestDb, seedConcepts } from '../concept_fixture.mjs';

let t;
let S;
let convA;
let convB;

before(async () => {
  t = await openConceptTestDb();
  S = await seedConcepts(t);
  convA = (await t.one(`insert into ai_conversations (title) values ('검수 1') returning id`)).id;
  convB = (await t.one(`insert into ai_conversations (title) values ('검수 2') returning id`)).id;
});
after(() => t?.close());

const op = (sql, params = []) => t.asSuperadmin(() => t.one(sql, params), S.operator);
const opRejects = (sql, params, pattern) => t.asSuperadmin(() => t.rejects(sql, params, pattern), S.operator);
const r = async (sql, params) => (await op(sql, params)).r;
const revision = async (id) => (await t.one(`select concept_review_revision(concept_review_marks($1::uuid)) as r`, [id])).r;
const folder = async (name) => (await t.one(`insert into concept_categories (name) values ($1) returning id`, [name])).id;

const walk = (filter) => r(`select concept_review_walk(null, $1::jsonb, 0, 60) as r`, [JSON.stringify(filter)]);
const start = (walkId, title = '배치 개념 검수') => r(`select concept_review_job_start($1::uuid, $2) as r`, [walkId, title]);
const claim = async (job, holder, mode = 'take') =>
  (await r(`select concept_review_job_claim($1::uuid, $2, $3) as r`, [job, holder, mode])).gen;
const next = (job, gen, n = 5) => r(`select concept_review_job_next($1::uuid, $2::bigint, $3) as r`, [job, gen, n]);
const save = (job, gen, items) => r(`select concept_review_job_save($1::uuid, $2::bigint, $3::jsonb) as r`, [job, gen, JSON.stringify(items)]);
const submit = (job, gen, conv = convA) =>
  r(`select concept_review_job_submit($1::uuid, $2::bigint, $3::uuid, '검수 결과를 남긴다') as r`, [job, gen, conv]);
const status = (job) => r(`select concept_review_job_status_live($1::uuid, 60) as r`, [job]);
const apply = (id) => op(`select * from course_think_action_apply($1::uuid, '{}'::jsonb)`, [id]);
const reject = (id) => op(`select * from ai_action_reject($1::uuid)`, [id]);

const review = (scope = 'notation', over = {}) => ({
  scope,
  outcome: 'no_issue_found',
  checked: '이름·본문의 표기',
  findings: '이번에 본 범위에서 오타를 찾지 못함',
  basis: '본문 전체를 읽음',
  unverified: null,
  follow_up: null,
  compared_ids: [],
  to_compare_ids: [],
  ...over,
});
const drafted = async (position, concept, over = {}) => ({
  position, concept_id: concept, state: 'drafted', revision: await revision(concept), read_complete: true,
  reviews: [review()], ...over,
});

async function setup(names) {
  const F = await folder(`검수 ${randomUUID().slice(0, 6)}`);
  const ids = [];
  for (const n of names) ids.push(await insertConcept(t, n, F));
  const w = await walk({ folder_id: F });
  return { F, ids: w.items.map((i) => i.id), walkId: w.walk_id };
}

test('작업 찾기·시작은 목록을 만들거나 지우지 않고, 작업이 걸린 목록은 30일 지우기에서 빠진다', async () => {
  const before = (await t.one(`select count(*)::int as n from concept_review_walks`)).n;
  const found = await r(`select concept_review_jobs_find() as r`);
  assert.equal((await t.one(`select count(*)::int as n from concept_review_walks`)).n, before, '찾기는 목록을 만들지 않는다');
  assert.ok(Array.isArray(found.jobs));
  await opRejects(`select concept_review_job_start($1::uuid, '없는 목록') as r`, [randomUUID()], /concept_review_walk_not_found/);
  assert.equal((await t.one(`select count(*)::int as n from concept_review_walks`)).n, before, '없는 목록이면 새로 만들지 않는다');

  const { walkId } = await setup(['보존 ㄱ', '보존 ㄴ']);
  const { walkId: other } = await setup(['보존 ㄷ']);
  const job = await start(walkId);
  assert.equal(job.existing, false);
  assert.deepEqual(await start(walkId, '다른 이름'), { job_id: job.job_id, existing: true, status: 'active' });
  await t.exec(`update concept_review_walks set created_at = now() - interval '40 days' where id in ('${walkId}', '${other}')`);
  await walk({});
  assert.ok(await t.one(`select 1 as x from concept_review_walks where id = $1::uuid`, [walkId]), '작업이 걸린 목록은 남는다');
  assert.equal(await t.one(`select 1 as x from concept_review_walks where id = $1::uuid`, [other]), undefined);
  await t.rejects(`delete from concept_review_walks where id = $1::uuid`, [walkId], /foreign key|violates/);
  await t.asUser(() => t.rejects(`select concept_review_jobs_find()`, [], /concept_review_forbidden/));
});

test('내준 위치(A)와 저장된 위치(B)는 따로다: 저장 안 된 위치는 새 실행에 다시 나오고, 넘겨받은 뒤 앞 실행의 쓰기는 거부된다', async () => {
  const { ids, walkId } = await setup(['위치 ㄱ', '위치 ㄴ', '위치 ㄷ', '위치 ㄹ']);
  const job = (await start(walkId)).job_id;
  const g1 = await claim(job, 'run-1');
  const n1 = await next(job, g1, 3);
  assert.deepEqual(n1.batch.map((b) => b.position), [1, 2, 3]);
  assert.equal(n1.batch[0].concept.revision, await revision(ids[0]));
  assert.deepEqual([n1.served_through, n1.checkpoint], [3, 0]);

  const s1 = await save(job, g1, [await drafted(2, ids[1])]);
  assert.equal(s1.items[0].status, 'saved');
  assert.equal(s1.checkpoint, 0, '1번이 비어 있으면 checkpoint 는 오르지 않는다');

  const g2 = await claim(job, 'run-2');
  assert.ok(g2 > g1);
  await opRejects(`select concept_review_job_save($1::uuid, $2::bigint, $3::jsonb)`,
    [job, g1, JSON.stringify([await drafted(1, ids[0])])], /concept_review_job_lease_lost/);
  const n2 = await next(job, g2, 5);
  assert.deepEqual(n2.batch.map((b) => b.position), [1, 3, 4], '내줬지만 저장되지 않은 위치가 먼저 다시 나온다');

  const bad = await save(job, g2, [
    await drafted(1, ids[0], { read_complete: false }),
    await drafted(3, ids[2], { revision: 'aaaaaaaaaaaa-bbbbbbbbbbbb-cccccccccccc' }),
    { position: 4, concept_id: ids[3], state: 'deferred', reason: '비교할 개념을 아직 못 읽음', next_action: null },
    await drafted(1, ids[1]),
  ]);
  assert.deepEqual(bad.items.map((i) => i.code.replace(/^.*?(concept_review_\w+).*$/, '$1')), [
    'concept_review_job_read_incomplete', 'concept_review_stale', 'concept_review_job_next_required', 'concept_review_job_wrong_concept',
  ]);
  assert.equal(bad.saved, 0);

  const ok = await save(job, g2, [
    await drafted(1, ids[0]),
    { position: 3, concept_id: ids[2], state: 'deferred', reason: '원본 확인 필요', next_action: '출처 쪽을 읽고 판단' },
    { position: 4, concept_id: ids[3], state: 'failed', reason: '본문 읽기 실패', next_action: '다시 읽기' },
  ]);
  assert.equal(ok.checkpoint, 4);
  const again = await save(job, g2, [await drafted(1, ids[0])]);
  assert.deepEqual(again.items[0], { position: 1, status: 'unchanged', draft_version: 1 });

  await op(`select concept_review_job_control($1::uuid, 'pause') as r`, [job]);
  await opRejects(`select concept_review_job_next($1::uuid, $2::bigint, 1)`, [job, g2], /concept_review_job_lease_lost/);
  await opRejects(`select concept_review_job_claim($1::uuid, 'run-3', 'take')`, [job], /concept_review_job_not_active/);
  await op(`select concept_review_job_control($1::uuid, 'resume') as r`, [job]);

  const st = await status(job);
  assert.equal(st.progress_line, '4개 중 0개 통합 완료');
  assert.deepEqual([st.counts.drafted, st.counts.open], [2, 2]);
  assert.deepEqual(st.open_items.map((i) => [i.position, i.category]), [[1, 'drafted'], [2, 'drafted'], [3, 'open'], [4, 'open']]);
  assert.equal(st.open_items[2].next_action, '출처 쪽을 읽고 판단');
});

test('제출은 멱등이다: 같은 초안은 같은 카드, 같은 키에 다른 내용은 충돌, 승인하면 완료로 세고 다시 내주지 않는다', async () => {
  const { ids, walkId } = await setup(['제출 ㄱ', '제출 ㄴ', '제출 ㄷ']);
  const job = (await start(walkId)).job_id;
  const g = await claim(job, 'run-1');
  await next(job, g, 3);
  await save(job, g, [await drafted(1, ids[0]), await drafted(2, ids[1], { reviews: [review('notation'), review('meaning')] })]);

  const first = await submit(job, g);
  assert.equal(first.submitted, true);
  assert.equal(first.existing, false);
  assert.deepEqual(first.positions, [1, 2]);
  const act = first.action.id;
  assert.equal(first.action.payload.items.length, 3);
  assert.equal((await submit(job, g)).submitted, false, '이미 낸 초안은 다시 내지 않는다');
  assert.equal((await t.one(`select count(*)::int as n from concept_review_job_cards where job_id = $1::uuid`, [job])).n, 1);

  const pending = await status(job);
  assert.equal(pending.counts.awaiting, 2);
  assert.equal(pending.pending_cards[0].action_id, act);
  assert.equal(pending.pending_cards[0].linked, true);
  const blocked = await save(job, g, [await drafted(1, ids[0])]);
  assert.match(blocked.items[0].code, /concept_review_job_item_pending/);

  const applied = await apply(act);
  assert.equal(applied.status, 'applied');
  const done = await status(job);
  assert.equal(done.progress_line, '3개 중 0개 통합 완료', '표기·의미만 승인된 개념은 통합 완료가 아니다');
  assert.equal(done.conditions.text, 1, '표기·의미 둘 다 승인된 개념만 표기·의미 조건 충족');
  assert.deepEqual([done.counts.todo, done.counts.not_reviewed], [2, 1]);
  assert.deepEqual(done.open_items.find((i) => i.position === 2).todo, ['foundation', 'placement']);
  const unchanged = await save(job, g, [await drafted(1, ids[0])]);
  assert.equal(unchanged.items[0].status, 'saved', '통합 완료가 아니면 보완 판단을 저장할 수 있다');
  assert.equal(unchanged.items[0].draft_version, 2);

  await t.exec(`update concepts set content = '내용이 바뀜' where id = '${ids[1]}'`);
  const changed = await status(job);
  assert.equal(changed.conditions.text, 0, '승인 뒤 내용이 바뀌면 표기·의미 충족에서 빠진다');
  assert.deepEqual(changed.open_items.find((i) => i.position === 2).todo, ['notation', 'meaning', 'foundation', 'placement']);
});

test('거절된 같은 초안은 다시 내지 않고, 고친 초안은 새 판으로 낸다. 판이 바뀐 초안은 제출 때 failed 로 돌린다', async () => {
  const { ids, walkId } = await setup(['거절 ㄱ', '거절 ㄴ']);
  const job = (await start(walkId)).job_id;
  const g = await claim(job, 'run-1');
  await next(job, g, 2);
  await save(job, g, [await drafted(1, ids[0]), await drafted(2, ids[1])]);
  await t.exec(`update concepts set name = '거절 ㄴ 바뀜' where id = '${ids[1]}'`);
  const sub = await submit(job, g);
  assert.deepEqual(sub.positions, [1]);
  assert.deepEqual(sub.failed, [{ position: 2, code: 'concept_review_stale' }]);
  await reject(sub.action.id);

  // 응답을 잃어 같은 초안 판으로 다시 들어온 경우(멱등 키 재사용)
  await t.exec(`update concept_review_job_items set state = 'drafted' where job_id = '${job}' and pos = 1`);
  const retry = await submit(job, g);
  assert.deepEqual([retry.existing, retry.action.id], [true, sub.action.id], '같은 키·같은 내용이면 같은 카드');
  await t.exec(`update concept_review_job_items set draft = jsonb_set(draft, '{0,findings}', '"다른 내용"') where job_id = '${job}' and pos = 1`);
  await opRejects(`select concept_review_job_submit($1::uuid, $2::bigint, $3::uuid, '다시')`, [job, g, convA], /concept_review_job_conflict/);
  await t.exec(`update concept_review_job_items set state = 'submitted', draft = jsonb_set(draft, '{0,findings}', '"이번에 본 범위에서 오타를 찾지 못함"')
                 where job_id = '${job}' and pos = 1`);

  const same = await save(job, g, [await drafted(1, ids[0])]);
  assert.match(same.items[0].code, /concept_review_job_same_as_rejected/);
  const fixed = await save(job, g, [await drafted(1, ids[0], { reviews: [review('notation', { findings: '고친 판단' })] })]);
  assert.deepEqual([fixed.items[0].status, fixed.items[0].draft_version], ['saved', 2]);
  const resub = await submit(job, g);
  assert.notEqual(resub.action.id, sub.action.id);
});

test('예전 대기 카드: 목록 개념만 든 카드는 이어서 새 대화로 옮기고, 섞인 카드는 충돌로 두며, 대기 카드 한도를 지킨다', async () => {
  const { ids, walkId } = await setup(['예전 ㄱ', '예전 ㄴ']);
  const outside = await insertConcept(t, '목록 밖', (await t.one(`select main_category_id as f from concepts where id = $1::uuid`, [ids[0]])).f);
  const item = async (c) => ({ concept_id: c, revision: await revision(c), ...review(), compared_ids: [], to_compare_ids: [] });
  const PROPOSE = `select * from course_think_action_propose($1::uuid, 'concept_review_record', $2::jsonb)`;
  const legacy = await op(PROPOSE, [convA, JSON.stringify({ items: [await item(ids[0])], reason: '예전 카드' })]);
  const mixed = await op(PROPOSE, [convA, JSON.stringify({ items: [await item(ids[1]), await item(outside)], reason: '섞인 카드' })]);

  const job = (await start(walkId)).job_id;
  const g = await claim(job, 'run-new');
  const n = await next(job, g, 5);
  assert.equal(n.auto_saved.waiting, 2, '승인 대기 카드에 든 개념은 다시 판단하지 않는다');
  const here = await r(`select concept_review_job_cards_here($1::uuid, $2::bigint, $3::uuid) as r`, [job, g, convB]);
  assert.deepEqual(here.cards.map((c) => [c.id, c.conversation_id]), [[legacy.id, convB]]);
  assert.deepEqual(here.conflicts.map((c) => c.action_id), [mixed.id]);
  const row = await t.one(`select conversation_id, status, payload from ai_actions where id = $1::uuid`, [mixed.id]);
  assert.equal(row.conversation_id, convA, '섞인 카드는 건드리지 않는다');
  const link = await t.one(`select legacy, origin_conversation_id from concept_review_job_cards where action_id = $1::uuid`, [legacy.id]);
  assert.deepEqual([link.legacy, link.origin_conversation_id], [true, convA]);
  assert.equal((await apply(legacy.id)).status, 'applied', '옮긴 카드도 그대로 승인된다');

  await t.exec(`update concept_review_jobs set limits = limits || '{"max_pending_cards": 0}' where id = '${job}'`);
  await opRejects(`select concept_review_job_submit($1::uuid, $2::bigint, $3::uuid, '한도')`, [job, g, convB], /concept_review_job_pending_full/);
});

test('자동 이어하기 관문은 기본 꺼짐이고, 켜도 한도와 연속 무진척에서 멈춘다', async () => {
  const { walkId } = await setup(['자동 ㄱ', '자동 ㄴ']);
  const job = (await start(walkId)).job_id;
  const gate = () => r(`select concept_review_job_run_gate($1::uuid, 'runner') as r`, [job]);
  assert.deepEqual(await gate(), { allowed: false, reason: 'auto_run_off' });
  await t.exec(`update concept_review_jobs set auto_run = true where id = '${job}'`);
  await claim(job, 'person');
  await opRejects(`select concept_review_job_run_gate($1::uuid, 'runner')`, [job], /concept_review_job_busy/);
  await t.exec(`update concept_review_jobs set lease_until = now() - interval '1 minute' where id = '${job}'`);
  for (let i = 0; i < 2; i++) {
    const g = await gate();
    assert.equal(g.allowed, true);
    await op(`select concept_review_job_run_finish($1::uuid, 0.01) as r`, [g.run_id]);
    await t.exec(`update concept_review_jobs set lease_until = now() - interval '1 minute' where id = '${job}'`);
  }
  assert.deepEqual(await gate(), { allowed: false, reason: 'no_progress' });
  const j = await t.one(`select status, pause_reason from concept_review_jobs where id = $1::uuid`, [job]);
  assert.deepEqual([j.status, j.pause_reason], ['paused', 'no_progress']);
});
