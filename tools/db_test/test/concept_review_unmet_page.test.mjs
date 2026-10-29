// 1차 검수 미충족은 같은 공개본에서만 위치 순으로 읽고, 저장 사유를 추정하지 않는다.
// 한 RPC 호출 도중에 커밋이 끼어드는 동시성 시험은 없다. 공개본 교체 전후만 본다.
import { after, test } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { insertConcept, openConceptTestDb, seedConcepts } from '../concept_fixture.mjs';

let t;

after(() => t?.close());

test('미충족 페이지는 같은 공개본의 first_pass=false만 읽고 옛 버전과 갱신 중은 거절한다', async () => {
  t = await openConceptTestDb();
  const S = await seedConcepts(t);
  const op = (sql, params = []) => t.asSuperadmin(() => t.one(sql, params), S.operator);
  const page = (job, version, after = 0, limit = 50) => op(
    `select concept_review_job_unmet_page($1::uuid, $2::bigint, $3, $4) as r`,
    [job, version, after, limit],
  ).then((row) => row.r);
  const status = (job) => op(
    `select concept_review_job_status($1::uuid, 20) as r`,
    [job],
  ).then((row) => row.r);

  const authExec = await t.one(
    `select has_function_privilege('authenticated', 'public.concept_review_job_unmet_page(uuid,bigint,integer,integer)', 'execute') as ok`,
  );
  const anonExec = await t.one(
    `select has_function_privilege('anon', 'public.concept_review_job_unmet_page(uuid,bigint,integer,integer)', 'execute') as ok`,
  );
  const tableRead = await t.one(
    `select has_table_privilege('authenticated', 'public.concept_review_progress_positions', 'select') as ok`,
  );
  assert.equal(authExec.ok, true);
  assert.equal(anonExec.ok, false);
  assert.equal(tableRead.ok, false);
  await t.asUser(() => t.rejects('select * from concept_review_progress_positions', [], /permission denied/));
  await t.asAnon(() => t.rejects(
    `select concept_review_job_unmet_page('${randomUUID()}'::uuid, null, 0, 50)`,
    [],
    /permission denied/,
  ));

  const missing = randomUUID();
  await t.asSuperadmin(
    () => t.rejects(`select concept_review_job_unmet_page('${missing}'::uuid, null, 0, 50)`, [], /concept_review_job_not_found/),
    S.operator,
  );
  await t.asUser(() => t.rejects(
    `select concept_review_job_unmet_page('${missing}'::uuid, null, 0, 50)`,
    [],
    /concept_review_forbidden/,
  ));

  const F = (await t.one(`insert into concept_categories (name) values ($1) returning id`, [`미충족 ${randomUUID().slice(0, 6)}`])).id;
  const cid = await insertConcept(t, `미충족 기준 ${randomUUID().slice(0, 4)}`, F, '약수를 써서 정의한다.');
  for (const name of ['미충족 나', '미충족 다', '미충족 라']) {
    await insertConcept(t, `${name} ${randomUUID().slice(0, 4)}`, F);
  }
  const w = await op(
    `select concept_review_walk(null, $1::jsonb, 0, 60) as r`,
    [JSON.stringify({ folder_id: F })],
  ).then((row) => row.r);
  const job = (await op(`select concept_review_job_start($1::uuid, '미충족') as r`, [w.walk_id])).r.job_id;
  const beforeReviews = (await t.one(`select count(*)::int as n from concept_quality_reviews`)).n;

  await t.one(
    `insert into concept_review_progress_positions
       (job_id, pos, concept_id, category, cond_text, cond_foundation, cond_placement, first_pass,
        open_payload, dirty_token, published_token)
     select $1::uuid, g, $2::uuid, 'open', false, false, false, g <= 8, null, 0, 0
       from generate_series(1, 60) g`,
    [job, cid],
  );
  await t.one(
    `update concept_review_progress_positions
        set first_pass = false, cond_text = true, cond_foundation = true, cond_placement = true, category = 'open'
      where job_id = $1::uuid and pos = 9`,
    [job],
  );
  await t.one(
    `update concept_review_progress_positions
        set open_payload = $2::jsonb
      where job_id = $1::uuid and pos = 10`,
    [job, JSON.stringify({
      name: '스냅샷 이름', item_state: 'deferred', reason: '스냅샷 사유', next_action: '스냅샷 다음',
      conditions: { text: 'met' }, todo: ['notation'], open: [],
    })],
  );
  await t.one(
    `update concept_review_progress_positions
        set open_payload = $2::jsonb
      where job_id = $1::uuid and pos = 11`,
    [job, JSON.stringify({ name: '이름만', item_state: 'failed' })],
  );
  await t.one(
    `insert into concept_review_job_items (job_id, pos, concept_id, state, reason, next_action)
     values
       ($1::uuid, 9, $2::uuid, 'deferred', null, null),
       ($1::uuid, 10, $2::uuid, 'deferred', '항목 사유', '항목 다음'),
       ($1::uuid, 11, $2::uuid, 'failed', '항목에만 있는 사유', '항목에 적힌 다음')`,
    [job, cid],
  );
  const conv = (await t.one(`insert into ai_conversations (title) values ('미충족 카드') returning id`)).id;
  const applied = (await t.one(
    `insert into ai_actions (conversation_id, kind, status, payload) values ($1::uuid, 'concept_review_record', 'applied', '{}'::jsonb) returning id`,
    [conv],
  )).id;
  const rejected = (await t.one(
    `insert into ai_actions (conversation_id, kind, status, payload) values ($1::uuid, 'concept_review_record', 'rejected', '{}'::jsonb) returning id`,
    [conv],
  )).id;
  await t.one(`update concept_review_job_items set action_id = $2::uuid where job_id = $1::uuid and pos = 10`, [job, applied]);
  await t.one(`update concept_review_job_items set action_id = $2::uuid where job_id = $1::uuid and pos = 11`, [job, rejected]);
  const publish = async (at) => {
    await t.one(
      `update concept_review_progress_positions
          set published_token = dirty_token
        where job_id = $1::uuid`,
      [job],
    );
    await t.one(
      `update concept_review_progress_jobs
          set published_input_version = input_version,
              needs_rebuild = false,
              active_run_id = null,
              progress_error = null,
              last_success = jsonb_build_object('at', $2::text)
        where job_id = $1::uuid`,
      [job, at],
    );
  };
  await publish('2026-10-29T00:00:00+00:00');
  const version = Number((await t.one(
    `select published_input_version::text as v from concept_review_progress_jobs where job_id = $1`,
    [job],
  )).v);
  const fresh = await status(job);
  const first = await page(job, null, 0, 20);
  assert.equal(fresh.progress_freshness, 'current');
  assert.equal(first.code, 'ok');
  assert.equal(Number(first.published_input_version), version);
  assert.equal(first.snapshot_at, '2026-10-29T00:00:00+00:00');
  assert.equal(first.total, 52);
  assert.equal(first.returned, 20);
  assert.equal(first.omitted, 32);
  assert.equal(first.items.length, 20);

  const seen = [];
  let cursor = 0;
  let guard = 0;
  while (guard < 6) {
    const part = await page(job, cursor === 0 ? null : version, cursor, 20);
    assert.equal(part.code, 'ok');
    assert.equal(part.total, 52);
    assert.equal(part.omitted, Math.max(52 - seen.length - part.returned, 0));
    for (const item of part.items) seen.push(Number(item.snapshot.pos));
    if (part.next_after == null) break;
    cursor = Number(part.next_after);
    guard += 1;
  }
  assert.equal(new Set(seen).size, seen.length);
  assert.deepEqual(seen, Array.from({ length: 52 }, (_, i) => i + 9));

  const capped = await page(job, null, 0, 80);
  assert.equal(capped.returned, 50);
  assert.equal(capped.total, 52);
  assert.equal(capped.omitted, 2);
  const emptyLimit = await page(job, null, 0, 0);
  assert.equal(emptyLimit.code, 'ok');
  assert.equal(emptyLimit.returned, 0);
  assert.equal(emptyLimit.total, 52);
  assert.equal(emptyLimit.omitted, 52);
  assert.equal(emptyLimit.next_after, null);
  const negativeLimit = await page(job, null, 0, -3);
  assert.equal(negativeLimit.returned, 0);
  assert.equal(negativeLimit.total, 52);

  const flags = (await page(job, version, 8, 1)).items[0];
  assert.equal(Number(flags.snapshot.pos), 9);
  assert.equal(flags.snapshot.first_pass, false);
  assert.equal(flags.snapshot.cond_text, true);
  assert.equal(flags.snapshot.cond_foundation, true);
  assert.equal(flags.snapshot.cond_placement, true);
  assert.equal(flags.snapshot.reason, undefined);
  assert.equal(flags.supplement.reason, undefined);
  assert.equal(typeof flags.supplement.item_updated_at, 'string');
  assert.equal(flags.snapshot.item_updated_at, undefined);
  assert.equal(flags.snapshot.card_status, undefined);

  const snap = (await page(job, version, 9, 1)).items[0];
  assert.equal(snap.snapshot.reason, '스냅샷 사유');
  assert.equal(snap.snapshot.next_action, '스냅샷 다음');
  assert.equal(snap.snapshot.name, '스냅샷 이름');
  assert.equal(snap.supplement, null);
  assert.equal(snap.snapshot.card_status, 'applied');

  const filled = (await page(job, version, 10, 1)).items[0];
  assert.equal(filled.snapshot.reason, undefined);
  assert.equal(filled.snapshot.name, '이름만');
  assert.equal(filled.supplement.reason, '항목에만 있는 사유');
  assert.equal(filled.supplement.next_action, '항목에 적힌 다음');
  assert.equal(filled.supplement.state, 'failed');
  assert.equal(filled.snapshot.card_status, 'rejected');
  assert.notEqual(filled.supplement.item_updated_at, first.snapshot_at);

  const plain = (await page(job, version, 11, 1)).items[0];
  assert.equal(plain.snapshot.reason, undefined);
  assert.equal(plain.supplement.reason, undefined);

  const omittedVersion = await page(job, null, -4, 50);
  assert.equal(omittedVersion.code, 'ok');
  assert.equal(Number(omittedVersion.items[0].snapshot.pos), 9);
  const needVersion = await page(job, null, 9, 50);
  assert.equal(needVersion.code, 'version_required');
  assert.equal(needVersion.items, null);
  assert.equal(needVersion.total, null);
  assert.equal(needVersion.returned, null);
  assert.equal(needVersion.omitted, null);
  assert.equal(needVersion.next_after, null);
  assert.equal(Number(needVersion.published_input_version), version);

  const past = await page(job, version, 60, 50);
  assert.equal(past.code, 'ok');
  assert.deepEqual(past.items, []);
  assert.equal(past.total, 52);
  assert.equal(past.returned, 0);
  assert.equal(past.omitted, 0);

  const inputNow = Number((await t.one(
    `select input_version::text as v from concept_review_progress_jobs where job_id = $1`,
    [job],
  )).v);
  const runId = (await t.one(
    `insert into concept_review_progress_runs (job_id, kind, input_version, state, cursor_pos)
     values ($1::uuid, 'rebuild', $2, 'running', 1) returning id`,
    [job, inputNow],
  )).id;
  await t.one(
    `update concept_review_progress_jobs set active_run_id = $2::uuid where job_id = $1::uuid`,
    [job, runId],
  );
  const refreshing = await page(job, version, 0, 50);
  const refreshingStatus = await status(job);
  assert.equal(refreshingStatus.progress_freshness, 'refreshing');
  assert.equal(refreshing.code, 'refreshing');
  assert.equal(Number(refreshing.published_input_version), version);
  assert.equal(refreshing.items, null);
  assert.equal(refreshing.total, null);

  await t.one(`update concepts set name = name || ' 변경' where id = $1::uuid`, [cid]);
  const during = await page(job, version, 9, 50);
  const duringStatus = await status(job);
  assert.equal(duringStatus.progress_freshness, 'stale');
  assert.equal(during.code, 'stale');
  assert.equal(during.items, null);
  assert.equal(during.total, null);
  assert.equal(Number(during.published_input_version), version);

  await t.one(
    `update concept_review_progress_runs
        set state = 'superseded', finished_at = now()
      where id = $1::uuid`,
    [runId],
  );
  await t.one(`update concept_review_progress_jobs set active_run_id = null where job_id = $1::uuid`, [job]);
  const superseded = await page(job, version, 9, 50);
  assert.equal(superseded.code, 'stale');
  assert.equal((await status(job)).progress_freshness, 'stale');
  const replacedVersion = Number((await t.one(
    `select input_version::text as v from concept_review_progress_jobs where job_id = $1`,
    [job],
  )).v);
  assert.notEqual(replacedVersion, inputNow);
  await publish('2026-10-29T06:00:00+00:00');
  const replaced = await page(job, version, 9, 50);
  assert.equal(replaced.code, 'snapshot_replaced');
  assert.equal(replaced.items, null);
  assert.equal(replaced.total, null);
  assert.equal(Number(replaced.published_input_version), replacedVersion);
  assert.equal(replaced.snapshot_at, '2026-10-29T06:00:00+00:00');
  const restarted = await page(job, null, 0, 1);
  assert.equal(restarted.code, 'ok');
  assert.equal(Number(restarted.items[0].snapshot.pos), 9);
  const explicitOld = await page(job, version, 0, 1);
  assert.equal(explicitOld.code, 'snapshot_replaced');

  const failedRun = (await t.one(
    `insert into concept_review_progress_runs (job_id, kind, input_version, state, attempts, error)
     values ($1::uuid, 'partial', $2, 'failed', 5, 'progress_step_failed') returning id`,
    [job, replacedVersion],
  )).id;
  await t.one(
    `update concept_review_progress_jobs
        set active_run_id = $2::uuid, progress_error = 'progress_step_failed'
      where job_id = $1::uuid`,
    [job, failedRun],
  );
  const failed = await page(job, replacedVersion, 0, 50);
  const failedStatus = await status(job);
  assert.equal(failedStatus.progress_freshness, 'failed');
  assert.equal(failed.code, 'failed');
  assert.equal(failed.progress_error, 'progress_step_failed');
  assert.equal(failed.items, null);
  assert.equal(failed.total, null);
  assert.notEqual(failed.total, 0);

  const F2 = (await t.one(`insert into concept_categories (name) values ($1) returning id`, [`미충족 없음 ${randomUUID().slice(0, 6)}`])).id;
  await insertConcept(t, `집계 없는 개념 ${randomUUID().slice(0, 4)}`, F2);
  const emptyWalk = await op(
    `select concept_review_walk(null, $1::jsonb, 0, 60) as r`,
    [JSON.stringify({ folder_id: F2 })],
  ).then((row) => row.r);
  const absentJob = (await op(
    `select concept_review_job_start($1::uuid, '집계 없음') as r`,
    [emptyWalk.walk_id],
  )).r.job_id;
  await t.one(`delete from concept_review_progress_jobs where job_id = $1::uuid`, [absentJob]);
  const absent = await page(absentJob, null, 0, 50);
  const absentStatus = await status(absentJob);
  assert.equal(absentStatus.progress_freshness, 'absent');
  assert.equal(absent.code, 'absent');
  assert.equal(absent.items, null);
  assert.equal(absent.total, null);

  assert.equal((await t.one(`select count(*)::int as n from concept_quality_reviews`)).n, beforeReviews);
  const storedReason = await t.one(
    `select reason from concept_review_job_items where job_id = $1::uuid and pos = 10`,
    [job],
  );
  assert.equal(storedReason.reason, '항목 사유');
});
