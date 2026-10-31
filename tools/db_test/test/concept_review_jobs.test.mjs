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

const targets = (job, gen, n = 50) => r(`select concept_review_job_targets($1::uuid, $2::bigint, $3) as r`, [job, gen, n]);
const stateOf = async (id) =>
  (await t.one(`select concept_review_job_concept_state($1::uuid, concept_review_pending_concepts()) as r`, [id])).r;
const PROPOSE = `select * from course_think_action_propose($1::uuid, 'concept_review_record', $2::jsonb)`;
const proposeReview = (items) => op(PROPOSE, [convA, JSON.stringify({ items, reason: '출처 검수 기록' })]);
const reviewItem = async (concept, scope, over = {}) => ({
  concept_id: concept,
  revision: await revision(concept),
  scope,
  outcome: 'no_issue_found',
  checked: `${scope} 확인`,
  findings: '이번에 본 범위에서 문제를 찾지 못함',
  basis: '본문 전체를 읽음',
  unverified: null,
  follow_up: null,
  compared_ids: [],
  to_compare_ids: [],
  ...over,
});
const foundationFields = {
  checked: '필요한 초등 기초 개념을 검색해 본문과 비교',
  findings: '추가할 기초 개념 없음',
  basis: '대상 본문을 읽음',
  detail: { needs: [{ name: '약수', why: '정의에 쓰임', terms: ['약수'], candidates: [], decision: 'reuse', reuse_id: null }], not_seen: null },
};
const placementFields = {
  checked: '출처와 지금 배치를 대조',
  findings: '배치 유지',
  basis: '출처 메타데이터. 교재 원본 쪽은 보지 않음',
  detail: { basis_kind: 'source', viewed_original: false },
};
const jobSnap = async (jobId) => (await t.one(
  `select jsonb_build_object(
     'id', j.id, 'walk_id', j.walk_id, 'title', j.title, 'status', j.status,
     'total', j.total, 'checkpoint', j.checkpoint, 'served_through', j.served_through,
     'items', (
       select coalesce(jsonb_agg(jsonb_build_object(
         'pos', i.pos, 'concept_id', i.concept_id, 'state', i.state, 'revision', i.revision
       ) order by i.pos), '[]'::jsonb)
         from concept_review_job_items i where i.job_id = j.id
     ),
     'reviews', (
       select coalesce(jsonb_agg(jsonb_build_object(
         'id', q.id, 'concept_id', q.concept_id, 'scope', q.scope, 'outcome', q.outcome, 'findings', q.findings
       ) order by q.created_at, q.id), '[]'::jsonb)
         from concept_quality_reviews q
        where exists (
          select 1
            from concept_review_walks w
            cross join lateral unnest(w.concept_ids) as u(cid)
           where w.id = j.walk_id and u.cid = q.concept_id
        )
     ),
     'concept_ids', (select to_jsonb(w.concept_ids) from concept_review_walks w where w.id = j.walk_id)
   ) as s
     from concept_review_jobs j where j.id = $1::uuid`,
  [jobId],
)).s;

test('기존 폴더 목록의 검토 범위 허용은 그대로다', async () => {
  const F = await folder(`범위 ${randomUUID().slice(0, 6)}`);
  const c = await insertConcept(t, `범위 개념 ${randomUUID().slice(0, 6)}`, F);
  const ok = await walk({ folder_id: F, review: 'unreviewed', review_scope: 'notation' });
  assert.deepEqual(ok.items.map((i) => i.id), [c]);
  assert.equal(ok.filter.review_scope, 'notation');
  await opRejects(`select concept_review_walk(null, $1::jsonb, 0, 40)`, [JSON.stringify({ review_scope: 'all' })], /concept_review_bad_filter/);
  await opRejects(`select concept_review_walk(null, $1::jsonb, 0, 40)`, [JSON.stringify({ review_scope: 'foundation' })], /concept_review_bad_filter/);
});

test('출처 목록으로 새 작업을 열어도 기존 작업·승인 행은 그대로고, 묶음은 재사용·부족한 범위·지워진 개념을 가른다', async () => {
  const { ids, walkId } = await setup([`기존작업 ${randomUUID().slice(0, 6)}`]);
  const opened = await start(walkId, '기존 폴더 검수');
  const oldJob = opened.job_id;
  const g0 = await claim(oldJob, 'keep-old');
  await next(oldJob, g0, 1);
  await save(oldJob, g0, [await drafted(1, ids[0])]);
  const sub = await submit(oldJob, g0);
  assert.equal((await apply(sub.action.id)).status, 'applied');
  const before = await jobSnap(oldJob);

  const tag = randomUUID().slice(0, 8);
  const F = await folder(`출처작업 ${tag}`);
  const geo = (await r(`select course_maps_list() as r`)).find((c) => c.name === '기하');
  const done = await insertConcept(t, `완료 ${tag}`, F);
  const partial = await insertConcept(t, `일부 ${tag}`, F);
  const gone = await insertConcept(t, `삭제 ${tag}`, F);
  await t.exec(`update concepts set sort_order = 0 where id = '${done}'`);
  await t.exec(`update concepts set sort_order = 1 where id = '${partial}'`);
  await t.exec(`update concepts set sort_order = 2 where id = '${gone}'`);
  for (const id of [done, partial, gone]) {
    await t.exec(
      `insert into concept_sources (concept_id, academy_id, book_id, grade_label, raw_page)
       values ('${id}', '${S.academy}', '${S.book}', '기하', 12)`,
    );
  }
  const four = [
    await reviewItem(done, 'notation'),
    await reviewItem(done, 'meaning'),
    await reviewItem(done, 'foundation', foundationFields),
    await reviewItem(done, 'placement', placementFields),
  ];
  await apply((await proposeReview(four)).id);
  await apply((await proposeReview([await reviewItem(partial, 'notation')])).id);
  assert.equal((await stateOf(done)).state, 'complete');
  assert.equal((await stateOf(partial)).state, 'todo');
  assert.deepEqual((await stateOf(partial)).todo, ['meaning', 'foundation', 'placement']);

  const listed = await r(`select concept_review_source_walk($1::uuid, 'all', 0, 60) as r`, [geo.id]);
  assert.deepEqual(listed.items.map((i) => i.id), [done, partial, gone]);
  assert.equal(listed.filter.source_scope, 'all');
  assert.equal(listed.filter.course_key, 'H-geometry');
  await t.exec(`delete from concept_sources where concept_id = '${gone}'`);
  await op(`select concept_delete($1::uuid) as r`, [gone]);
  assert.equal((await stateOf(gone)).state, 'missing');

  const started = await start(listed.walk_id, '기하 출처 검수');
  assert.equal(started.existing, false);
  assert.notEqual(started.job_id, oldJob);
  const row = await t.one(`select walk_id, total from concept_review_jobs where id = $1::uuid`, [started.job_id]);
  assert.equal(row.walk_id, listed.walk_id);
  assert.equal(row.total, 3, '지운 개념도 고정한 총수에 남는다');
  const g = await claim(started.job_id, 'source-run');
  const batch = await targets(started.job_id, g, 50);
  assert.equal(batch.auto_saved.reused, 1);
  assert.equal(batch.auto_saved.missing, 1);
  assert.equal(batch.batch.length, 1);
  assert.equal(batch.batch[0].supplement, false);
  assert.equal(batch.batch[0].concept_id, partial);
  assert.deepEqual(batch.batch[0].todo, ['meaning', 'foundation', 'placement']);
  assert.deepEqual(await jobSnap(oldJob), before, '기존 작업·항목·승인 기록·목록 id는 바꾸지 않는다');
});

test('특정 교재 출처 고정 목록은 그 교재 개념만 묶고, 새 출처가 추가되면 외부 근거 미확인(gap)을 한 번 다시 판단한 뒤 실패 시 다시 gap으로 둔다', async () => {
  const F = await folder(`교재목록 ${randomUUID().slice(0, 6)}`);
  const c1 = await insertConcept(t, '교재개념 ㄱ', F);
  const c2 = await insertConcept(t, '교재개념 ㄴ', F);
  const bookB = randomUUID();
  await t.exec(`insert into resource_files (id, academy_id, name) values ('${bookB}', '${S.academy}', '개념원리 1-1')`);
  await t.exec(
    `insert into concept_sources (concept_id, academy_id, book_id, grade_label, raw_page, created_at)
     values ('${c1}', '${S.academy}', '${S.book}', '중1-1', 10, '2026-10-30T00:00:00Z'),
            ('${c2}', '${S.academy}', '${bookB}', '중1-1', 20, '2026-10-30T00:00:00Z')`,
  );

  // c1: notation·foundation·placement는 met, meaning은 외부 근거 미확인(gap: source)
  await apply((await proposeReview([
    await reviewItem(c1, 'notation'),
    await reviewItem(c1, 'meaning', {
      outcome: 'unverified',
      unverified: '교재 출처 미확인',
      detail: { evidence_gaps: ['source'] },
    }),
    await reviewItem(c1, 'foundation', { detail: { needs: [], none_basis: '추가 기초 없음' } }),
    await reviewItem(c1, 'placement', { detail: { basis_kind: 'source' } }),
  ])).id);

  const st1 = await stateOf(c1);
  assert.equal(st1.scopes.meaning.state, 'gap');
  assert.deepEqual(st1.todo, []);

  // 새 교재(bookB) 출처가 c1에 추가되면 meaning(gap)과 placement가 recheck 대상으로 열린다.
  await t.exec(
    `insert into concept_sources (concept_id, academy_id, book_id, grade_label, raw_page, created_at)
     values ('${c1}', '${S.academy}', '${bookB}', '중1-1', 21, clock_timestamp() + interval '1 second')`,
  );
  const st2 = await stateOf(c1);
  assert.equal(st2.scopes.meaning.state, 'recheck');
  assert.equal(st2.scopes.placement.state, 'recheck');
  assert.deepEqual(st2.todo, ['meaning', 'placement']);

  // 특정 교재(bookB)로 검수 목록을 고정하면 c1, c2가 묶이고 find_concept_review_jobs의 books에도 나온다.
  const found = await r(`select concept_review_jobs_find() as r`);
  const foundBook = found.books.find((b) => b.book_id === bookB);
  assert.ok(foundBook);
  assert.equal(foundBook.book_name, '개념원리 1-1');
  assert.equal(foundBook.concepts, 2);

  const bookWalk = await r(`select concept_review_book_walk($1::uuid, 'all', 0, 40) as r`, [bookB]);
  assert.equal(bookWalk.filter.source_book_id, bookB);
  assert.equal(bookWalk.filter.book_name, '개념원리 1-1');
  assert.deepEqual(bookWalk.items.map((i) => i.id), [c1, c2]);

  // 다시 판단해도 여전히 외부 근거 미확인(gap)으로 승인되면 다시 gap(1차 충족)으로 돌아가고 반복하지 않는다.
  await t.exec(
    `update concept_sources set created_at = clock_timestamp() - interval '1 second'
      where concept_id = '${c1}' and book_id = '${bookB}'`,
  );
  await apply((await proposeReview([
    await reviewItem(c1, 'meaning', {
      outcome: 'unverified',
      unverified: '새 교재에서도 외부 근거 미확인',
      detail: { evidence_gaps: ['source'] },
    }),
    await reviewItem(c1, 'placement', { detail: { basis_kind: 'source' } }),
  ])).id);
  const st3 = await stateOf(c1);
  assert.equal(st3.scopes.meaning.state, 'gap');
  assert.equal(st3.scopes.placement.state, 'met');
  assert.deepEqual(st3.todo, []);
});

