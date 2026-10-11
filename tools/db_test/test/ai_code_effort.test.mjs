// 코드 작업 강도: 회차에 실제로 쓴 강도를 남긴다(20261010110000_ai_code_effort.sql).
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { openAiTestDb } from '../harness.mjs';

let t;
const WORKER = 'pc-test';

before(async () => {
  t = await openAiTestDb();
});
after(() => t?.close());

/** 작업자가 잡고 있는(running) 요청과 1회차 행. */
async function running(spec = { goal: 'g', effort: 'xhigh' }) {
  const id = (await t.one(
    `insert into ai_code_requests (title, request, mode, status, worker_id, round, attempts)
     values ('작업', $1::jsonb, 'change', 'running', $2, 1, 1) returning id`,
    [JSON.stringify(spec), WORKER],
  )).id;
  await t.exec(`insert into ai_code_request_rounds (request_id, round, status) values ('${id}', 1, 'running')`);
  return id;
}
const roundOf = (id) => t.one(`select model, effort, status from ai_code_request_rounds where request_id = $1 and round = 1`, [id]);

test('완료: 실제 모델과 강도를 회차에 남기고, 모르는 강도는 비운다', async () => {
  const a = await running();
  await t.one(`select ai_code_bridge_complete($1, $2, $3::jsonb) as r`, [WORKER, a, JSON.stringify({ model: 'grok-4.7', effort: 'xhigh', parse_ok: true })]);
  assert.deepEqual(await roundOf(a), { model: 'grok-4.7', effort: 'xhigh', status: 'finished' });

  const b = await running();
  await t.one(`select ai_code_bridge_complete($1, $2, $3::jsonb) as r`, [WORKER, b, JSON.stringify({ model: 'grok-4.7', effort: 'ultra' })]);
  assert.equal((await roundOf(b)).effort, null);

  const old = await running();
  await t.one(`select ai_code_bridge_complete($1, $2, $3::jsonb) as r`, [WORKER, old, JSON.stringify({ model: 'composer-2.5' })]);
  assert.deepEqual(await roundOf(old), { model: 'composer-2.5', effort: null, status: 'finished' }, '옛 작업자는 강도 없이 끝난다');
});

test('실패: 보낸 강도만 덮고, 없으면 그대로 둔다', async () => {
  const id = await running();
  await t.exec(`update ai_code_request_rounds set effort = 'high' where request_id = '${id}'`);
  await t.one(`select ai_code_bridge_fail($1, $2, 'run_error', 'boom', false, $3::jsonb) as r`, [WORKER, id, JSON.stringify({ model: 'grok-4.7' })]);
  assert.deepEqual(await roundOf(id), { model: 'grok-4.7', effort: 'high', status: 'error' });

  const low = await running();
  await t.one(`select ai_code_bridge_fail($1, $2, 'timeout', 'slow', false, $3::jsonb) as r`, [WORKER, low, JSON.stringify({ effort: 'low' })]);
  assert.equal((await roundOf(low)).effort, 'low', '지원 강도가 없어 가장 가까운 강도로 돈 경우');
});

test('열 제약: 정해진 강도 말고는 넣을 수 없다', async () => {
  const id = await running();
  await t.rejects(`update ai_code_request_rounds set effort = 'max' where request_id = $1`, [id], /effort_check/);
});
