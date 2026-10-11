// 코드 요청 흐름: 재시도, 적용 전 확인, 조율본 자동 시작, 자동 검사 실패 재수정.
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { openAiTestDb } from '../harness.mjs';

let t;
let C;
let M;
const USER = '11111111-1111-4111-8111-111111111111';
const BASE = 'a'.repeat(40);

before(async () => {
  t = await openAiTestDb();
  await t.exec(`insert into auth.users (id) values ('${USER}')`);
  await t.exec(`update ai_platform_settings set code_request_daily_limit = 100`);
  C = (await t.one(`insert into ai_conversations (title) values ('c') returning id`)).id;
  M = (await t.one(`insert into ai_messages (conversation_id, role, content) values ($1, 'assistant', 'm') returning id`, [C])).id;
});
after(() => t?.close());

const count = async (table) => (await t.one(`select count(*)::int as n from ${table}`)).n;
const request = async ({ mode = 'change', status = 'ready', spec = { goal: 'g', instructions: ['a'] }, conv = C } = {}) =>
  (await t.one(
    `insert into ai_code_requests (conversation_id, source_message_ids, title, request, mode, status, max_rounds, created_by)
     values ($1, array[$2]::uuid[], '작업', $3::jsonb, $4, $5, 1, $6) returning id`,
    [conv, M, JSON.stringify(spec), mode, status, USER],
  )).id;
const round = (id, result, parseOk = true) =>
  t.one(
    `insert into ai_code_request_rounds (request_id, round, status, result, parse_ok) values ($1, 1, 'finished', $2::jsonb, $3) returning id`,
    [id, JSON.stringify(result), parseOk],
  );
const withLimit = async (n, fn) => {
  await t.exec(`update ai_platform_settings set code_request_daily_limit = ${n}`);
  try {
    return await fn();
  } finally {
    await t.exec(`update ai_platform_settings set code_request_daily_limit = 100`);
  }
};
const todayCount = async () =>
  (await t.one(`select count(*)::int as n from ai_code_requests
                 where submitted_at >= (date_trunc('day', now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul')`)).n;

test('대기열 넣기: 앱은 슈퍼관리자만, 내부 함수는 서버만', async () => {
  const id = await t.one(`insert into ai_code_requests (title, request, mode) values ('d', '{"goal":"g"}', 'change') returning id`);
  await t.asUser(() => t.rejects(`select ai_code_request_submit($1)`, [id.id], /forbidden/));
  await t.asSuperadmin(() => t.rejects(`select ai_code_request_enqueue($1)`, [id.id], /permission denied/));
  const row = await t.asSuperadmin(() => t.one(`select * from ai_code_request_submit($1)`, [id.id]));
  assert.equal(row.status, 'queued');
  await t.asSuperadmin(() => t.rejects(`select ai_code_request_submit($1)`, [id.id], /code_request_not_draft/));
});

test('같은 내용으로 다시 수정: 끝나지 않은 수정 요청만, 하루 한도 안에서', async () => {
  const spec = { goal: 'g', instructions: ['a'], based_on_plan: { id: 'p', title: '조율본', rounds: 2 } };
  for (const s of ['needs_review', 'failed', 'cancelled']) {
    const id = await request({ status: s, spec });
    const row = await t.asSuperadmin(() => t.one(`select * from ai_code_change_retry($1)`, [id]));
    assert.notEqual(row.id, id);
    assert.equal(row.status, 'queued');
    assert.deepEqual(row.request, spec);
  }
  for (const s of ['ready', 'queued', 'running']) {
    const id = await request({ status: s });
    await t.asSuperadmin(() => t.rejects(`select ai_code_change_retry($1)`, [id], /code_retry_not_allowed/));
  }
  const id = await request({ status: 'failed' });
  await t.asUser(() => t.rejects(`select ai_code_change_retry($1)`, [id], /forbidden/));
  const before = await count('ai_code_requests');
  await withLimit(await todayCount(), () => t.asSuperadmin(() => t.rejects(`select ai_code_change_retry($1)`, [id], /code_request_daily_limit/)));
  assert.equal(await count('ai_code_requests'), before);
});

test('작업 폴더 적용: 형식 확인 통과 + diff가 있어야 대기열에 넣는다', async () => {
  const none = await request();
  await t.asSuperadmin(() => t.rejects(`select ai_code_request_apply($1)`, [none], /code_request_no_round/));
  const bad = await request();
  await round(bad, { diff: 'diff --git a/x b/x\n' }, false);
  await t.asSuperadmin(() => t.rejects(`select ai_code_request_apply($1)`, [bad], /code_request_parse_not_ok/));
  const empty = await request();
  await round(empty, { diff: '  ' });
  await t.asSuperadmin(() => t.rejects(`select ai_code_request_apply($1)`, [empty], /code_request_diff_missing/));
  const ok = await request();
  await round(ok, { diff: 'diff --git a/x b/x\n', verification: { summary: { failed: 1 } } });
  const row = await t.asSuperadmin(() => t.one(`select * from ai_code_request_apply($1)`, [ok]));
  assert.equal(row.status, 'apply_queued', '검사 실패는 서버가 막지 않는다(앱이 경고)');
});

test('조율본 자동 시작: 수정 요청을 바로 보내고 대화 카드용 행을 남긴다', async () => {
  const plan = await request({ mode: 'plan', status: 'ready' });
  const pending = (await t.one(
    `insert into ai_actions (conversation_id, kind, payload) values ($1, 'code_change', '{"title":"old"}') returning id`,
    [C],
  )).id;
  const spec = { goal: 'g', instructions: ['1단계'], based_on_plan: { id: plan, title: '조율', rounds: 2 } };
  await t.asSuperadmin(() => t.rejects(`select ai_code_bridge_start_change($1, $2, 't', $3::jsonb)`, [plan, M, JSON.stringify(spec)], /permission denied/));
  await t.asAnon(() => t.rejects(`select ai_code_bridge_start_change($1, $2, 't', $3::jsonb)`, [plan, M, JSON.stringify(spec)], /permission denied/));

  const out = (await t.asService(() => t.one(`select ai_code_bridge_start_change($1, $2, '조율대로 수정', $3::jsonb) as j`, [plan, M, JSON.stringify(spec)]))).j;
  assert.equal(out.ok, true);
  const req = await t.one(`select * from ai_code_requests where id = $1`, [out.code_request_id]);
  assert.equal(req.mode, 'change');
  assert.equal(req.status, 'queued');
  assert.equal(req.max_rounds, 1);
  assert.equal(req.created_by, USER);
  assert.deepEqual(req.source_message_ids, [M]);
  assert.deepEqual(req.request, spec);
  const act = await t.one(`select * from ai_actions where id = $1`, [out.action_id]);
  assert.equal(act.kind, 'code_change');
  assert.equal(act.status, 'applied');
  assert.equal(act.message_id, M);
  assert.equal(act.result.code_request_id, out.code_request_id);
  assert.equal(act.preview.auto, true);
  const old = await t.one(`select status, superseded from ai_actions where id = $1`, [pending]);
  assert.deepEqual(old, { status: 'rejected', superseded: true });

  const again = (await t.asService(() => t.one(`select ai_code_bridge_start_change($1, $2, 't', $3::jsonb) as j`, [plan, M, JSON.stringify(spec)]))).j;
  assert.deepEqual(again, { ok: false, error: 'already_started' });
});

test('조율본 자동 시작: 단계가 없거나 조율 요청이 아니거나 한도면 아무것도 만들지 않는다', async () => {
  const plan = await request({ mode: 'plan' });
  const before = [await count('ai_code_requests'), await count('ai_actions')];
  const call = (id, spec) => t.asService(async () => (await t.one(`select ai_code_bridge_start_change($1, $2, 't', $3::jsonb) as j`, [id, M, JSON.stringify(spec)])).j);
  assert.equal((await call(plan, { goal: 'g', instructions: [] })).error, 'no_instructions');
  assert.equal((await call(await request(), { goal: 'g', instructions: ['a'] })).error, 'not_plan');
  const limited = await withLimit(await todayCount(), () => call(plan, { goal: 'g', instructions: ['a'], based_on_plan: { id: plan } }));
  assert.deepEqual(limited, { ok: false, error: 'code_request_daily_limit' });
  assert.deepEqual([await count('ai_code_requests'), await count('ai_actions')], [before[0] + 1, before[1]]);
});

test('재수정: 앞 수정 위에서 최대 2회, 한 요청에 한 번만', async () => {
  const first = await request({ spec: { goal: 'g', instructions: ['a'] } });
  await round(first, { diff: 'diff --git a/x b/x\n', base_commit: BASE });
  const fixSpec = (prev, attempt) => ({ goal: 'g', instructions: ['a'], fix_of: { request_id: prev, attempt, max: 2, failed: [{ label: 'x' }] } });
  const fix = (prev, spec) => t.asService(async () => (await t.one(`select ai_code_bridge_fix($1, $2, $3::jsonb) as j`, [prev, M, JSON.stringify(spec)])).j);

  await t.asSuperadmin(() => t.rejects(`select ai_code_bridge_fix($1, $2, $3::jsonb)`, [first, M, JSON.stringify(fixSpec(first, 1))], /permission denied/));
  await t.asService(() => t.rejects(`select ai_code_bridge_fix($1, $2, $3::jsonb)`, [first, M, JSON.stringify(fixSpec(first, 2))], /fix_spec_invalid/));

  const one = await fix(first, fixSpec(first, 1));
  assert.equal(one.ok, true);
  assert.equal(one.attempt, 1);
  const r1 = await t.one(`select * from ai_code_requests where id = $1`, [one.code_request_id]);
  assert.equal(r1.status, 'queued');
  assert.equal(r1.title, '작업');
  assert.equal(r1.request.fix_of.request_id, first);
  const act = await t.one(`select * from ai_actions where id = $1`, [one.action_id]);
  assert.equal(act.status, 'applied');
  assert.equal(act.result.code_request_id, one.code_request_id);
  assert.equal(act.preview.fix_attempt, 1);
  assert.deepEqual(await fix(first, fixSpec(first, 1)), { ok: false, error: 'already_fixing' });

  const src = (await t.asService(() => t.one(`select ai_code_bridge_fix_source($1) as j`, [first]))).j;
  assert.deepEqual(src, { diff: 'diff --git a/x b/x\n', base_commit: BASE });
  await t.asSuperadmin(() => t.rejects(`select ai_code_bridge_fix_source($1)`, [first], /permission denied/));

  await t.exec(`update ai_code_requests set status = 'ready' where id = '${one.code_request_id}'`);
  await round(one.code_request_id, { diff: 'diff --git a/y b/y\n', base_commit: BASE });
  const two = await fix(one.code_request_id, fixSpec(one.code_request_id, 2));
  assert.equal(two.attempt, 2);
  await t.exec(`update ai_code_requests set status = 'ready' where id = '${two.code_request_id}'`);
  await round(two.code_request_id, { diff: 'diff --git a/z b/z\n', base_commit: BASE });
  assert.deepEqual(await fix(two.code_request_id, fixSpec(two.code_request_id, 3)), { ok: false, error: 'fix_limit' });
});

test('재수정: 끝나지 않았거나 diff·기준 커밋이 없으면 하지 않는다', async () => {
  const fix = (prev) =>
    t.asService(async () => (await t.one(`select ai_code_bridge_fix($1, $2, $3::jsonb) as j`, [prev, M, JSON.stringify({ goal: 'g', fix_of: { request_id: prev, attempt: 1 } })])).j);
  const running = await request({ status: 'running' });
  assert.equal((await fix(running)).error, 'not_fixable');
  const applied = await request({ status: 'applied' });
  assert.equal((await fix(applied)).error, 'not_fixable');
  const noBase = await request();
  await round(noBase, { diff: 'diff --git a/x b/x\n' });
  assert.equal((await fix(noBase)).error, 'no_diff');
  const ok = await request();
  await round(ok, { diff: 'diff --git a/x b/x\n', base_commit: BASE });
  const before = await count('ai_code_requests');
  assert.deepEqual(await withLimit(await todayCount(), () => fix(ok)), { ok: false, error: 'code_request_daily_limit' });
  assert.equal(await count('ai_code_requests'), before);
});

test('이어받기 패치: 최종 회차의 완전한 패치만, 대체됐으면 최종 요청을 알린다', async () => {
  const src = (id) => t.asService(async () => (await t.one(`select ai_code_bridge_patch_source($1) as j`, [id])).j);
  const at = (id, n, result, parseOk = true) =>
    t.exec(
      `insert into ai_code_request_rounds (request_id, round, status, result, parse_ok) values ('${id}', ${n}, 'finished', '${JSON.stringify(result)}'::jsonb, ${parseOk})`,
    );
  const stats = { files: 1, additions: 1, deletions: 0 };

  const prev = await request({ status: 'ready' });
  await at(prev, 1, { diff: 'diff --git a/old b/old\n', diff_stats: stats, base_commit: 'b'.repeat(40) });
  await at(prev, 2, { diff: 'diff --git a/x b/x\n', diff_stats: stats, base_commit: BASE });
  assert.deepEqual(await src(prev), {
    ok: true,
    request_id: prev,
    title: '작업',
    status: 'ready',
    round: 2,
    diff: 'diff --git a/x b/x\n',
    diff_stats: stats,
    base_commit: BASE,
  });
  for (const fn of [t.asSuperadmin, t.asUser, t.asAnon]) {
    await fn(() => t.rejects(`select ai_code_bridge_patch_source($1)`, [prev], /permission denied/));
  }

  assert.deepEqual(await src('99999999-9999-4999-8999-999999999999'), { ok: false, error: 'not_found' });
  assert.equal((await src(await request({ mode: 'plan' }))).error, 'not_change');
  for (const s of ['queued', 'running', 'needs_review', 'failed', 'cancelled']) {
    const id = await request({ status: s });
    await at(id, 1, { diff: 'diff --git a/x b/x\n', diff_stats: stats, base_commit: BASE });
    assert.deepEqual(await src(id), { ok: false, error: 'not_final', status: s });
  }
  assert.equal((await src(await request())).error, 'no_patch');

  // 앞 회차가 멀쩡해도 최종 회차가 불완전하면 앞 회차로 내려가지 않는다
  for (const [result, parseOk] of [
    [{ diff: 'diff --git a/x b/x\n', diff_stats: stats, base_commit: BASE }, false],
    [{ diff: 'diff --git a/x b/x\n', diff_stats: stats }, true],
    [{ diff: 'diff --git a/x b/x\n', base_commit: BASE }, true],
  ]) {
    const id = await request();
    await at(id, 1, { diff: 'diff --git a/x b/x\n', diff_stats: stats, base_commit: BASE });
    await at(id, 2, result, parseOk);
    assert.deepEqual(await src(id), { ok: false, error: 'incomplete', round: 2 });
  }

  const fixed = await request();
  await at(fixed, 1, { diff: 'diff --git a/x b/x\n', diff_stats: stats, base_commit: BASE });
  const fix = await request({ status: 'running', spec: { goal: 'g', fix_of: { request_id: fixed, attempt: 1 } } });
  assert.deepEqual(await src(fixed), { ok: false, error: 'superseded', superseded_by: fix, superseded_status: 'running' });
  await t.exec(`update ai_code_requests set status = 'failed' where id = '${fix}'`);
  assert.equal((await src(fixed)).ok, true, '재수정이 실패하면 앞 요청이 최종');
});

test('이어받기 패치: 시간 초과로 멈춘 수정은 미완성 표시와 함께 내주고, 다른 확인 필요는 계속 거절한다', async () => {
  const src = (id) => t.asService(async () => (await t.one(`select ai_code_bridge_patch_source($1) as j`, [id])).j);
  const stats = { files: 1, additions: 1, deletions: 0 };
  const patch = { diff: 'diff --git a/x b/x\n', diff_stats: stats, base_commit: BASE };
  const stopped = async (result) => {
    const id = await request({ status: 'needs_review' });
    await round(id, result, false);
    return id;
  };

  const marked = await stopped({ ...patch, partial: 'timeout', summary: '60분 안에 끝나지 않아 멈췄습니다. 여기까지' });
  const got = await src(marked);
  assert.equal(got.ok, true);
  assert.equal(got.partial, 'timeout');
  assert.equal(got.status, 'needs_review');
  assert.equal(got.diff, patch.diff);

  const legacy = await stopped({ ...patch, summary: '30분 안에 끝나지 않아 멈췄습니다. 여기까지 고친 내용입니다(완성되지 않음).' });
  assert.equal((await src(legacy)).partial, 'timeout', '표시 없는 예전 행은 요약 문구로만 알아본다');

  assert.deepEqual(await src(await stopped({ ...patch, summary: '형식이 맞지 않는 답' })), { ok: false, error: 'not_final', status: 'needs_review' });
  assert.deepEqual(await src(await stopped({ ...patch, partial: 'other' })), { ok: false, error: 'not_final', status: 'needs_review' });
  assert.deepEqual(await src(await stopped({ diff: patch.diff, diff_stats: stats, partial: 'timeout' })), { ok: false, error: 'incomplete', round: 1 });
  assert.deepEqual(await src(await stopped({ partial: 'timeout', summary: 's' })), { ok: false, error: 'no_patch' });

  const done = await request({ status: 'ready' });
  await round(done, patch);
  assert.equal((await src(done)).partial, undefined, '정상 완료 패치에는 미완성 표시가 없다');
  for (const s of ['failed', 'cancelled']) {
    const id = await request({ status: s });
    await round(id, { ...patch, partial: 'timeout' }, false);
    assert.deepEqual(await src(id), { ok: false, error: 'not_final', status: s });
  }
});
