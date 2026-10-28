// 기억 변경 흐름과 보관 제안, 고른 대화의 작업 맥락.
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { openAiTestDb } from '../harness.mjs';

const USER = '33333333-3333-4333-8333-333333333333';
let t;
let conv;

before(async () => {
  t = await openAiTestDb();
  await t.exec(`insert into auth.users (id) values ('${USER}')`);
  conv = (await su(() => t.one(`insert into ai_conversations (title) values ('흐름') returning id`))).id;
});

after(() => t?.close());

const su = (fn) => t.asSuperadmin(fn, USER);
const memory = (over = {}) => ({
  kind: 'decision',
  title: '흐름 결정',
  content: '본문',
  decision_context: '맥락',
  decision_reason: '이유',
  alternatives: [],
  tags: [],
  memory_scope: 'common',
  scope_department: null,
  supersedes_id: null,
  ...over,
});

async function session() {
  return (await su(() => t.one(`select ai_memory_read_open($1) as id`, [conv]))).id;
}

async function ready(memoryId) {
  const id = await session();
  await su(() => t.one(`select ai_memory_search($1, 'zzzzqqqq', array['zzzzqqqq'])`, [id]));
  if (memoryId) await su(() => t.one(`select ai_memory_read($1, $2, 0)`, [id, memoryId]));
  return id;
}

const propose = (id, over = {}) =>
  su(() =>
    t.one(`select * from ai_action_propose($1, 'save_memory', $2::jsonb, '{}'::jsonb)`, [
      conv,
      JSON.stringify({
        memory: memory(over.memory),
        reason: '확정',
        read_session: id,
        relation: over.relation ?? 'distinct',
        compared_ids: over.compared_ids ?? [],
        flow: over.flow ?? null,
      }),
    ]),
  );

const retire = (id, memoryId, flow) =>
  su(() =>
    t.one(`select * from ai_action_propose($1, 'save_memory', $2::jsonb, '{}'::jsonb)`, [
      conv,
      JSON.stringify({ op: 'retire', memory_id: memoryId, reason: '더 쓰지 않는다', read_session: id, flow: flow ?? null }),
    ]),
  );

const apply = (actionId) => su(() => t.one(`select * from ai_action_apply($1, '{}'::jsonb)`, [actionId]));

test('서로 기대는 변경은 근본 단계가 승인된 뒤에만 다음 단계가 반영된다', async () => {
  const old = (
    await su(() =>
      t.one(
        `insert into ai_memories (kind, status, title, content) values ('principle', 'active', '근본 원칙', '먼저 바뀌어야 하는 내용') returning id, version`,
      ),
    )
  );
  const id = await ready(old.id);
  const flow = { key: 'root1', step: 2, steps: 2 };
  await assert.rejects(() => propose(id, { flow, memory: { title: '뒤 단계' } }), /memory_flow_order/);

  const first = await propose(id, {
    flow: { key: 'root1', step: 1, steps: 2 },
    memory: { title: '근본 결정' },
  });
  const second = await retire(id, old.id, flow);
  assert.equal(second.payload.op, 'retire');
  assert.equal(second.payload.flow.step, 2);

  await assert.rejects(() => apply(second.id), /memory_flow_waiting/);
  const still = await su(() => t.one(`select status from ai_memories where id = $1`, [old.id]));
  assert.equal(still.status, 'active');
  const waiting = await su(() => t.one(`select status from ai_actions where id = $1`, [second.id]));
  assert.equal(waiting.status, 'proposed');

  const applied = await apply(first.id);
  assert.equal(applied.status, 'applied');
  const retired = await apply(second.id);
  assert.equal(retired.status, 'applied');
  assert.equal(retired.result.archived, true);
  const row = await su(() => t.one(`select status from ai_memories where id = $1`, [old.id]));
  assert.equal(row.status, 'archived');
  const n = await su(() => t.one(`select count(*)::int as n from ai_memories where id = $1`, [old.id]));
  assert.equal(n.n, 1);
});

test('고른 대화의 작업은 상태를 구분하고, 진행 요약을 복사하거나 카드를 만들지 않는다', async () => {
  const empty = (await su(() => t.one(`insert into ai_conversations (title) values ('빈 대화') returning id`))).id;
  const source = (
    await su(() =>
      t.one(
        `insert into ai_conversations (title, progress_summary) values ('앞 작업', $1::jsonb) returning id`,
        [JSON.stringify({ purpose: '숙제 시간', decided: ['10분'], open: [], status: '진행', next: [] })],
      ),
    )
  ).id;
  const missing = '99999999-9999-4999-8999-999999999999';

  const notFound = await su(() => t.one(`select ai_conversation_context_lookup($1) as r`, [missing]));
  assert.equal(notFound.r.status, 'not_found');
  const none = await su(() => t.one(`select ai_conversation_context_lookup($1) as r`, [empty]));
  assert.equal(none.r.status, 'empty');
  const ok = await su(() => t.one(`select ai_conversation_context_lookup($1) as r`, [source]));
  assert.equal(ok.r.status, 'ok');
  assert.equal(ok.r.progress_summary.purpose, '숙제 시간');

  const forbidden = await t.asUser(() => t.one(`select ai_conversation_context_lookup($1) as r`, [source]));
  assert.equal(forbidden.r.status, 'forbidden');

  const before = await su(() => t.one(`select count(*)::int as n from ai_actions`));
  await assert.rejects(
    () => su(() => t.one(`select ai_conversation_set_context_source($1, $2)`, [conv, empty])),
    /context_source_empty/,
  );
  await assert.rejects(
    () => su(() => t.one(`select ai_conversation_set_context_source($1, $2)`, [conv, missing])),
    /context_source_not_found/,
  );
  await assert.rejects(
    () => su(() => t.one(`select ai_conversation_set_context_source($1, $1)`, [conv])),
    /context_source_self/,
  );
  await su(() => t.one(`select ai_conversation_set_context_source($1, $2)`, [conv, source]));
  const here = await su(() => t.one(`select context_from_conversation_id, progress_summary from ai_conversations where id = $1`, [conv]));
  assert.equal(here.context_from_conversation_id, source);
  assert.equal(here.progress_summary, null);
  const after = await su(() => t.one(`select count(*)::int as n from ai_actions`));
  assert.equal(after.n, before.n);
  await su(() => t.one(`select ai_conversation_set_context_source($1, null)`, [conv]));
  const cleared = await su(() => t.one(`select context_from_conversation_id from ai_conversations where id = $1`, [conv]));
  assert.equal(cleared.context_from_conversation_id, null);
});
