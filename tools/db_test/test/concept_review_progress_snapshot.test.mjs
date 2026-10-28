// 저장 집계가 전수 판정과 같은지, 바뀐 위치만 다시 계산하는지, 구간을 이어 가도 수가 늘지 않는지 본다.
import { after, test } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { insertConcept, openConceptTestDb, seedConcepts } from '../concept_fixture.mjs';

let t;

after(() => t?.close());

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

function core(st) {
  const items = Array.isArray(st.open_items) ? st.open_items : [];
  return {
    progress_line: st.progress_line ?? null,
    condition_line: st.condition_line ?? null,
    counts: st.counts ?? null,
    conditions: st.conditions ?? null,
    met: st.first_pass?.met ?? null,
    total: st.first_pass?.total ?? null,
    line: st.first_pass?.line ?? null,
    first_pass_line: st.first_pass_line ?? null,
    total_mismatch: st.total_mismatch ?? null,
    open: items.map((i) => ({ position: Number(i.position), category: i.category, item_state: i.item_state ?? null })),
  };
}

test('저장 집계·변경 전파·구간 재개가 전수 판정과 맞고 조회는 다시 계산하지 않는다', async () => {
  t = await openConceptTestDb();
  const S = await seedConcepts(t);
  const op = (sql, params = []) => t.asSuperadmin(() => t.one(sql, params), S.operator);
  const r = async (sql, params) => (await op(sql, params)).r;
  const revision = async (id) => (await t.one(`select concept_review_revision(concept_review_marks($1::uuid)) as r`, [id])).r;
  const stored = (job) => r(`select concept_review_job_status($1::uuid, 60) as r`, [job]);
  const live = (job) => r(`select concept_review_job_status_live($1::uuid, 60) as r`, [job]);
  // PGlite는 프로시저 안의 commit을 거절한다. 거절되면 같은 step을 반복해 다음 구간이 이어지는지만 본다.
  let procedureCommit = 'untried';
  const drive = async (job, limit = 8) => {
    if (procedureCommit === 'untried') {
      try {
        await t.db.exec(`call public.concept_review_progress_drive('${job}'::uuid, 30000, ${limit})`);
        procedureCommit = 'ok';
        return;
      } catch (e) {
        if (!String(e.message).includes('invalid transaction termination')) throw e;
        procedureCommit = 'pglite_rejects_commit';
      }
    }
    for (let i = 0; i < 40; i += 1) {
      const out = await step(job, limit);
      if (out.more !== true) {
        if (out.outcome === 'failed') throw new Error(JSON.stringify(out));
        return out;
      }
    }
    throw new Error('drive did not finish');
  };
  const step = (job, limit) => r(`select concept_review_progress_step($1::uuid, $2::int) as r`, [job, limit]);
  const versionOf = async (job) => (await t.one(
    `select input_version::text as v from concept_review_progress_jobs where job_id = $1`,
    [job],
  )).v;
  const dirtyPos = async (job) => (await t.all(
    `select pos::int as pos from concept_review_progress_positions
      where job_id = $1 and dirty_token > published_token order by pos`,
    [job],
  )).map((x) => Number(x.pos));
  const conv = (await t.one(`insert into ai_conversations (title) values ('저장 집계') returning id`)).id;

  const body = (await t.one(`select pg_get_functiondef('public.concept_review_job_status(uuid,integer)'::regprocedure) as d`)).d;
  for (const name of ['concept_review_marks', 'concept_review_job_concept_state', 'concept_review_first_pass_met', 'concept_review_job_status_counts']) {
    assert.equal(body.includes(name), false, name);
  }
  const touch = (await t.one(`select pg_get_functiondef('public.concept_review_progress_touch(uuid[],boolean)'::regprocedure) as d`)).d;
  assert.equal(touch.includes('concept_review_marks'), false);
  assert.equal(touch.includes('concept_review_job_concept_state'), false);
  const proc = (await t.one(`select pg_get_functiondef('public.concept_review_progress_drive(uuid,integer,integer)'::regprocedure) as d`)).d;
  assert.match(proc, /concept_review_progress_step/);
  assert.match(proc, /\bcommit\b/i);
  await t.asUser(() => t.rejects('select * from concept_review_progress_jobs', [], /permission denied/));

  const F = (await t.one(`insert into concept_categories (name) values ($1) returning id`, [`집계 ${randomUUID().slice(0, 6)}`])).id;
  const course = (await r(`select course_maps_list() as r`)).find((c) => c.name === '2-1');
  const map = await r(`select course_map_get($1::uuid) as r`, [course.id]);
  const leaf = map.units.filter((u) => u.depth === 3)[0];
  const made = [];
  for (const name of ['집계 가', '집계 나', '집계 다', '집계 라']) {
    const id = await insertConcept(t, `${name} ${randomUUID().slice(0, 4)}`, F, `${name}은 약수를 써서 정의한다.`);
    await t.exec(
      `insert into concept_sources (concept_id, academy_id, book_id, grade_label, raw_page, display_page, unit_path)
       values ('${id}', '${S.academy}', '${S.book}', '중2-1', 50, 40, '{"Ⅰ. 수와 식","1. 유리수"}')`,
    );
    made.push(id);
  }
  await r(`select course_placement_add($1::uuid, $2::uuid[]) as r`, [leaf.id, `{${made.join(',')}}`]);
  const w = await r(`select concept_review_walk(null, $1::jsonb, 0, 60) as r`, [JSON.stringify({ folder_id: F })]);
  const order = await t.all(
    `select x.pos::int as pos, x.cid::text as cid
       from concept_review_walks w
       cross join lateral unnest(w.concept_ids) with ordinality as x(cid, pos)
      where w.id = $1::uuid order by x.pos`,
    [w.walk_id],
  );
  assert.equal(order.length, 4);
  const idAt = (pos) => order.find((x) => Number(x.pos) === pos).cid;
  const job = (await r(`select concept_review_job_start($1::uuid, '저장 집계') as r`, [w.walk_id])).job_id;
  const gen = (await r(`select concept_review_job_claim($1::uuid, 'run', 'take') as r`, [job])).gen;
  await r(`select concept_review_job_targets($1::uuid, $2::bigint, 4) as r`, [job, gen]);
  const drafted = async (pos, reviews, rework = false) => ({
    position: pos, concept_id: idAt(pos), state: 'drafted', revision: await revision(idAt(pos)), read_complete: true,
    unread: null, reviews, next_action: null, reason: null, rework,
  });
  const save = (items) => r(`select concept_review_job_save($1::uuid, $2::bigint, $3::jsonb) as r`, [job, gen, JSON.stringify(items)]);
  const saved = await save([
    await drafted(1, four()),
    await drafted(2, four()),
    { position: 3, concept_id: idAt(3), state: 'deferred', read_complete: true, reviews: null, reason: '원본 확인 필요', next_action: '출처 쪽을 읽고 판단' },
  ]);
  assert.equal(saved.saved, 3);
  const sub = await r(`select concept_review_job_submit($1::uuid, $2::bigint, $3::uuid, '저장 집계', null) as r`, [job, gen, conv]);
  if (sub.action) await op(`select * from course_think_action_apply($1::uuid, '{}'::jsonb)`, [sub.action.id]);
  for (const a of sub.fix_actions ?? []) await op(`select * from course_think_action_apply($1::uuid, '{}'::jsonb)`, [a.id]);
  const again = await save([await drafted(1, [review('notation', {
    outcome: 'issue_found', findings: '표기가 틀림',
    fix: { kind: 'library', ops: [{ op: 'edit', name: `고친 ${randomUUID().slice(0, 4)}` }] },
  })], true)]);
  assert.equal(again.saved, 1);
  await t.one(
    `insert into ai_actions (conversation_id, kind, status, payload) values ($1::uuid, 'concept_review_record', 'proposed', $2::jsonb) returning id`,
    [conv, JSON.stringify({ items: [{ concept_id: idAt(2), scope: 'relations', outcome: 'needs_comparison' }] })],
  );

  const before = await stored(job);
  assert.equal(before.progress_freshness, 'absent');
  assert.equal(before.progress_line, null);
  assert.equal(before.first_pass, null);
  assert.equal(before.counts, null);
  const liveBefore = core(await live(job));
  assert.equal(liveBefore.counts.complete, 1);
  assert.equal(liveBefore.met, 1);
  assert.deepEqual(liveBefore.conditions, { text: 2, foundation: 2, placement: 2 });

  const cardsBefore = Number((await t.one(`select count(*)::int as n from ai_actions`)).n);
  const jobBefore = await t.one(`select status, served_through, total from concept_review_jobs where id = $1`, [job]);
  const first = await step(job, 1);
  if (first.outcome !== 'chunk') console.log('FIRST_STEP', JSON.stringify(first));
  assert.equal(first.outcome, 'chunk');
  assert.equal(first.more, true);
  assert.notEqual((await stored(job)).progress_freshness, 'current');
  const run = await t.one(
    `select id::text as id, input_version::text as v, cursor_pos::int as cursor
       from concept_review_progress_runs where job_id = $1 and state = 'running'`,
    [job],
  );
  assert.equal(Number(run.cursor), 2);
  const staged = Number((await t.one(`select count(*)::int as n from concept_review_progress_stage where run_id = $1`, [run.id])).n);
  await t.one(`update concept_review_progress_runs set cursor_pos = 1, updated_at = now() - interval '10 minutes' where id = $1 returning id`, [run.id]);
  const replay = await step(job, 1);
  assert.equal(replay.outcome, 'chunk');
  assert.equal(
    Number((await t.one(`select count(*)::int as n from concept_review_progress_stage where run_id = $1`, [run.id])).n),
    staged,
  );
  await drive(job, 1);
  const after = await stored(job);
  assert.equal(after.progress_freshness, 'current');
  assert.equal(after.progress_last_success, null);
  assert.deepEqual(core(after), liveBefore);
  assert.deepEqual(core(after), core(await live(job)));
  const jobAfter = await t.one(`select status, served_through, total from concept_review_jobs where id = $1`, [job]);
  assert.equal(jobAfter.status, jobBefore.status);
  assert.equal(Number(jobAfter.served_through), Number(jobBefore.served_through));
  assert.equal(Number(jobAfter.total), Number(jobBefore.total));
  assert.equal(Number((await t.one(`select count(*)::int as n from ai_actions`)).n), cardsBefore);

  const ver = await versionOf(job);
  await t.exec(`update concepts set sort_order = coalesce(sort_order, 0) + 1 where id = '${idAt(1)}'`);
  assert.equal(await versionOf(job), ver);
  assert.equal((await stored(job)).progress_freshness, 'current');
  assert.deepEqual(await dirtyPos(job), []);

  await t.exec(`update concepts set name = name || ' 고침' where id = '${idAt(1)}'`);
  assert.deepEqual(await dirtyPos(job), [1]);
  const stale = await stored(job);
  assert.equal(stale.progress_freshness, 'stale');
  assert.equal(stale.progress_line, null);
  assert.equal(stale.first_pass, null);
  assert.equal(stale.counts, null);
  assert.equal(stale.progress_last_success.progress_line, liveBefore.progress_line);
  assert.notEqual(stale.progress_last_success.progress_line, null);
  await drive(job, 4);
  const edited = await stored(job);
  assert.equal(edited.progress_freshness, 'current');
  assert.deepEqual(core(edited), core(await live(job)));
  assert.notEqual(edited.counts.complete, liveBefore.counts.complete);

  const outside = await insertConcept(t, `바깥 ${randomUUID().slice(0, 4)}`, F, '바깥 개념의 본문');
  await t.exec(`
    insert into concept_quality_reviews (
      concept_id, scope, outcome, checked, findings, basis, marks, mark, compared
    ) values (
      '${idAt(4)}', 'notation', 'no_issue_found', '표기 확인', '문제 없음', '본문',
      concept_review_marks('${idAt(4)}'::uuid),
      concept_review_marks('${idAt(4)}'::uuid) ->> 'text',
      jsonb_build_array(jsonb_build_object(
        'id', '${outside}', 'name', '바깥', 'text', concept_review_text_mark('${outside}'::uuid)
      ))
    )
  `);
  assert.deepEqual(await dirtyPos(job), [4]);
  await drive(job, 4);
  assert.equal((await stored(job)).progress_freshness, 'current');
  await t.exec(`update concepts set name = name || ' 바뀜' where id = '${outside}'`);
  assert.deepEqual(await dirtyPos(job), [4]);
  const comparedStale = await stored(job);
  assert.equal(comparedStale.progress_freshness, 'stale');
  assert.equal(comparedStale.progress_line, null);
  await drive(job, 4);
  assert.deepEqual(core(await stored(job)), core(await live(job)));

  const partner = await insertConcept(t, `상대 ${randomUUID().slice(0, 4)}`, F, '관계 상대의 본문');
  await t.exec(
    `insert into concept_relations (concept_id, related_id, kind, origin)
     values ('${idAt(3)}', '${partner}', 'extends', 'manual')`,
  );
  await drive(job, 4);
  await t.exec(`update concepts set name = name || ' 상대변경' where id = '${partner}'`);
  assert.deepEqual(await dirtyPos(job), [3]);
  await drive(job, 4);
  assert.deepEqual(core(await stored(job)), core(await live(job)));

  await t.exec(`delete from concept_appearances where concept_id = '${idAt(4)}' and course_unit_id = '${leaf.id}'`);
  await drive(job, 4);
  await t.exec(`update course_map_units set archived_at = now() where id = '${leaf.id}'`);
  assert.deepEqual(await dirtyPos(job), [1, 2, 3]);
  await drive(job, 4);
  assert.deepEqual(core(await stored(job)), core(await live(job)));

  const oldRun = run.id;
  await r(`select concept_review_progress_request($1::uuid, true) as r`, [job]);
  const started = await step(job, 1);
  assert.equal(started.outcome, 'chunk');
  const rebuilding = await t.one(
    `select id::text as id, input_version::text as v from concept_review_progress_runs
      where job_id = $1 and state = 'running'`,
    [job],
  );
  assert.notEqual(rebuilding.id, oldRun);
  await t.exec(`update concepts set content = content || ' 도중' where id = '${idAt(2)}'`);
  await drive(job, 1);
  const superseded = await t.one(`select state from concept_review_progress_runs where id = $1`, [rebuilding.id]);
  assert.equal(superseded.state, 'superseded');
  const published = await stored(job);
  assert.equal(published.progress_freshness, 'current');
  assert.notEqual(
    (await t.one(`select published_input_version::text as v from concept_review_progress_jobs where job_id = $1`, [job])).v,
    rebuilding.v,
  );
  assert.deepEqual(core(published), core(await live(job)));

  const bulkFolder = (await t.one(`insert into concept_categories (name) values ('합성4000') returning id`)).id;
  await t.exec(`
    insert into concept_families (canonical_name)
    select '대량 ' || lpad(i::text, 4, '0') from generate_series(1, 4000) i;
    insert into concepts (name, content, main_category_id, family_id, version_label)
    select f.canonical_name, '본문 ' || f.canonical_name, '${bulkFolder}', f.id, 'v0'
      from concept_families f
     where f.canonical_name like '대량 %';
  `);
  const bulkWalk = await r(`select concept_review_walk(null, $1::jsonb, 0, 60) as r`, [JSON.stringify({ folder_id: bulkFolder })]);
  assert.equal(bulkWalk.total, 4000);
  const bulkJob = (await r(`select concept_review_job_start($1::uuid, '합성 4000') as r`, [bulkWalk.walk_id])).job_id;
  const bulk1 = await step(bulkJob, 30);
  assert.equal(bulk1.outcome, 'chunk');
  const bulkRun = await t.one(
    `select id::text as id, cursor_pos::int as cursor from concept_review_progress_runs
      where job_id = $1 and state = 'running'`,
    [bulkJob],
  );
  assert.equal(Number(bulkRun.cursor), 31);
  await t.one(`update concept_review_progress_runs set updated_at = now() - interval '10 minutes' where id = $1 returning id`, [bulkRun.id]);
  const bulk2 = await step(bulkJob, 30);
  assert.equal(bulk2.outcome, 'chunk');
  const bulkStage = Number((await t.one(`select count(*)::int as n from concept_review_progress_stage where run_id = $1`, [bulkRun.id])).n);
  assert.equal(bulkStage, 60);
  const t0 = performance.now();
  const bulkStatus = await stored(bulkJob);
  const statusMs = Math.round(performance.now() - t0);
  assert.equal(bulkStatus.progress_freshness, 'refreshing');
  assert.equal(bulkStatus.progress_line, null);
  assert.equal(bulkStatus.first_pass, null);
  assert.equal(bulkStatus.counts, null);
  assert.ok(statusMs < 5000, `status_ms=${statusMs}`);
  console.log(`PROGRESS_STATUS_MS status_ms=${statusMs} concepts=4000 stored_read=1 procedure=${procedureCommit}`);
});
