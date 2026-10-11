// Think ↔ Cursor 연결: 질문 접수 한도·자격, 작업자 대화 이어 묻기, 마감, 권한, 새 열 제약
import { after, before, beforeEach, test } from 'node:test';
import assert from 'node:assert/strict';
import { openAiTestDb } from '../harness.mjs';

const USER = '22222222-2222-4222-8222-222222222222';
let t;

before(async () => {
  t = await openAiTestDb();
  await t.exec(`insert into auth.users (id) values ('${USER}')`);
});

after(() => t?.close());

beforeEach(() => t.exec(`delete from ai_relay_asks`));

const reserve = (args) =>
  t.asService(() =>
    t.one(`select ai_relay_reserve($1, $2, $3, $4, $5, $6) as r`, [
      args.asker,
      args.conversationId ?? null,
      args.workerId ?? null,
      args.requestId ?? null,
      args.daily ?? 60,
      args.run ?? 3,
    ]),
  ).then((row) => row.r);

const reserveFails = (args, pattern) =>
  t.asService(() =>
    t.rejects(`select ai_relay_reserve($1, $2, $3, $4, $5, $6)`, [
      args.asker,
      args.conversationId ?? null,
      args.workerId ?? null,
      args.requestId ?? null,
      args.daily ?? 60,
      args.run ?? 3,
    ], pattern),
  );

const finish = (id, status, conv = null) =>
  t.asService(() => t.one(`select ai_relay_finish($1, $2, $3, null, null) as ok`, [id, status, conv])).then((r) => r.ok);

async function codeRequest({ mode = 'plan', status = 'running', worker = 'pc-a', round = 1 } = {}) {
  return (
    await t.one(
      `insert into ai_code_requests (title, status, mode, worker_id, round, max_rounds)
       values ('조율 요청', $1, $2, $3, $4, 3) returning id`,
      [status, mode, worker, round],
    )
  ).id;
}

const conversation = async (origin = 'cursor') =>
  (await t.one(`insert into ai_conversations (title, origin) values ('커서 문의', $1) returning id`, [origin])).id;

test('작업창 질문: 새 대화로 접수하고, 이어 묻기는 커서가 시작한 대화만 된다', async () => {
  const fresh = await reserve({ asker: 'cursor_ide' });
  assert.ok(fresh.id);
  assert.equal(fresh.conversation_id, null);

  const mine = await conversation('cursor');
  const again = await reserve({ asker: 'cursor_ide', conversationId: mine });
  assert.equal(again.conversation_id, mine);

  const owners = await conversation('owner');
  await reserveFails({ asker: 'cursor_ide', conversationId: owners }, /relay_conversation_not_cursor/);
  await reserveFails({ asker: 'cursor_ide', conversationId: '33333333-3333-4333-8333-333333333333' }, /relay_conversation_not_found/);
});

test('하루 한도를 넘으면 접수하지 않는다', async () => {
  await reserve({ asker: 'cursor_ide', daily: 2 });
  await reserve({ asker: 'cursor_ide', daily: 2 });
  await reserveFails({ asker: 'cursor_ide', daily: 2 }, /relay_daily_limit/);
});

test('어제 질문은 오늘 한도에 세지 않는다', async () => {
  await t.exec(`insert into ai_relay_asks (asker, created_at) values ('cursor_ide', now() - interval '2 days')`);
  const r = await reserve({ asker: 'cursor_ide', daily: 1 });
  assert.ok(r.id);
});

test('작업자 질문: 자기가 돌리는 조사·조율 요청만, 회차마다 한도만큼', async () => {
  const req = await codeRequest({ mode: 'plan', round: 2 });
  const first = await reserve({ asker: 'cursor_worker', workerId: 'pc-a', requestId: req, run: 2 });
  assert.equal(first.request_round, 2);
  assert.equal(first.request_mode, 'plan');
  assert.equal(first.request_title, '조율 요청');
  await reserve({ asker: 'cursor_worker', workerId: 'pc-a', requestId: req, run: 2 });
  await reserveFails({ asker: 'cursor_worker', workerId: 'pc-a', requestId: req, run: 2 }, /relay_run_limit/);

  await t.exec(`update ai_code_requests set round = 3 where id = '${req}'`);
  const nextRound = await reserve({ asker: 'cursor_worker', workerId: 'pc-a', requestId: req, run: 2 });
  assert.equal(nextRound.request_round, 3, '새 회차는 한도를 새로 센다');

  await reserveFails({ asker: 'cursor_worker', workerId: 'pc-b', requestId: req }, /relay_request_not_running/);
  await reserveFails({ asker: 'cursor_worker', workerId: 'pc-a', requestId: null }, /relay_request_required/);

  const done = await codeRequest({ status: 'ready' });
  await reserveFails({ asker: 'cursor_worker', workerId: 'pc-a', requestId: done }, /relay_request_not_running/);

  const change = await codeRequest({ mode: 'change' });
  await reserveFails({ asker: 'cursor_worker', workerId: 'pc-a', requestId: change }, /relay_mode_not_allowed/);

  const investigate = await codeRequest({ mode: 'investigate' });
  assert.ok((await reserve({ asker: 'cursor_worker', workerId: 'pc-a', requestId: investigate })).id);
});

test('작업자 질문은 같은 요청의 앞 질문 대화에 이어 묻는다(그 대화가 지워졌으면 새로)', async () => {
  const req = await codeRequest();
  const first = await reserve({ asker: 'cursor_worker', workerId: 'pc-a', requestId: req });
  assert.equal(first.conversation_id, null);
  const conv = await conversation('cursor');
  assert.equal(await finish(first.id, 'answered', conv), true);

  const second = await reserve({ asker: 'cursor_worker', workerId: 'pc-a', requestId: req });
  assert.equal(second.conversation_id, conv);

  await t.exec(`delete from ai_conversations where id = '${conv}'`);
  const third = await reserve({ asker: 'cursor_worker', workerId: 'pc-a', requestId: req });
  assert.equal(third.conversation_id, null);
});

test('작업창 질문은 작업자 요청 칸을 남기지 않는다', async () => {
  const req = await codeRequest();
  const r = await reserve({ asker: 'cursor_ide', workerId: 'pc-a', requestId: req });
  const row = await t.one(`select worker_id, request_id, request_round from ai_relay_asks where id = $1`, [r.id]);
  assert.deepEqual(row, { worker_id: null, request_id: null, request_round: null });
});

test('마감은 한 번만 바뀌고 상태 값을 검사한다', async () => {
  const r = await reserve({ asker: 'cursor_ide' });
  assert.equal(await finish(r.id, 'needs_owner'), true);
  assert.equal(await finish(r.id, 'answered'), false);
  const row = await t.one(`select status, finished_at is not null as done from ai_relay_asks where id = $1`, [r.id]);
  assert.deepEqual(row, { status: 'needs_owner', done: true });
  await t.asService(() => t.rejects(`select ai_relay_finish($1, 'running', null, null, null)`, [r.id], /relay_status_invalid/));
});

test('권한: 접수·마감은 service role만, 기록은 슈퍼관리자가 읽기만 한다', async () => {
  await t.asSuperadmin(
    () => t.rejects(`select ai_relay_reserve('cursor_ide', null, null, null, 60, 3)`, [], /permission denied/),
    USER,
  );
  await t.asUser(() => t.rejects(`select ai_relay_finish(gen_random_uuid(), 'answered', null, null, null)`, [], /permission denied/));
  await t.asAnon(() => t.rejects(`select ai_relay_reserve('cursor_ide', null, null, null, 60, 3)`, [], /permission denied/));

  await reserve({ asker: 'cursor_ide' });
  const seen = await t.asSuperadmin(() => t.all(`select id from ai_relay_asks`), USER);
  assert.equal(seen.length, 1);
  const hidden = await t.asUser(() => t.all(`select id from ai_relay_asks`));
  assert.equal(hidden.length, 0);
  await t.asSuperadmin(() => t.rejects(`insert into ai_relay_asks (asker) values ('cursor_ide')`, [], /permission denied/), USER);
});

test('새 열 제약: origin, asked_by, relay', async () => {
  await t.rejects(`insert into ai_conversations (title, origin) values ('x', 'robot')`, [], /ai_conversations_origin_check/);
  const conv = await conversation('cursor');
  await t.rejects(
    `insert into ai_messages (conversation_id, role, content, asked_by) values ($1, 'user', 'q', 'someone')`,
    [conv],
    /ai_messages_asked_by_check/,
  );
  await t.rejects(
    `insert into ai_messages (conversation_id, role, content, relay) values ($1, 'assistant', 'a', '[1]'::jsonb)`,
    [conv],
    /ai_messages_relay_check/,
  );
  const ok = await t.one(
    `insert into ai_messages (conversation_id, role, content, asked_by) values ($1, 'user', 'q', 'cursor_worker') returning asked_by`,
    [conv],
  );
  assert.equal(ok.asked_by, 'cursor_worker');
  const plain = await t.one(`insert into ai_conversations (title) values ('운영자') returning origin`);
  assert.equal(plain.origin, 'owner');
});
