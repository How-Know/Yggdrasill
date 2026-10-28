// Think 기억 저장 제안 카드: 제안·중복 막기·승인(active 저장·대체)·대기 카드 수정·대체·삭제
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { openAiTestDb } from '../harness.mjs';

const USER = '33333333-3333-4333-8333-333333333333';
let t;
let conv;

before(async () => {
  t = await openAiTestDb();
  await t.exec(`insert into auth.users (id) values ('${USER}')`);
  conv = (await su(() => t.one(`insert into ai_conversations (title) values ('기억 제안') returning id`))).id;
});

after(() => t?.close());

const su = (fn) => t.asSuperadmin(fn, USER);

const memory = (over = {}) => ({
  kind: 'decision',
  title: '기억 제안 결정',
  content: '본문',
  decision_context: '맥락',
  decision_reason: '이유',
  alternatives: ['대안 A', ' '],
  tags: ['Think'],
  memory_scope: 'common',
  scope_department: null,
  supersedes_id: null,
  ...over,
});

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

async function readySession(c = conv) {
  const session = (await su(() => t.one(`select ai_memory_read_open($1) as id`, [c]))).id;
  await su(() => t.one(`select ai_memory_search($1, '기억', array['기억']) as r`, [session]));
  return session;
}

async function readFull(session, memoryId) {
  let offset = 0;
  for (let i = 0; i < 8; i += 1) {
    const body = (await su(() => t.one(`select ai_memory_read($1, $2, $3) as r`, [session, memoryId, offset]))).r;
    if (body.complete === true || body.next_offset == null || body.status === 'not_found' || body.status === 'forbidden' || body.status === 'version_changed') {
      return body;
    }
    offset = body.next_offset;
  }
  return null;
}

const propose = async (kind, payload, c = conv) => {
  let body = payload;
  const needsBasis = kind === 'save_memory' || (kind === 'memory_card_change' && payload.op !== 'withdraw' && payload.op !== 'move');
  if (needsBasis) {
    const session = payload.read_session ?? (await readySession(c));
    const sup = payload.memory?.supersedes_id;
    const compared = Array.isArray(payload.compared_ids) ? payload.compared_ids : [];
    if (typeof sup === 'string' && UUID_RE.test(sup)) await readFull(session, sup);
    for (const id of compared) {
      if (typeof id === 'string' && UUID_RE.test(id) && id !== sup) await readFull(session, id);
    }
    body = {
      ...payload,
      read_session: session,
      relation: payload.relation ?? (sup ? 'supplement' : 'distinct'),
      compared_ids: compared,
    };
  }
  return su(() => t.one(`select * from ai_action_propose($1, $2, $3::jsonb, '{}'::jsonb)`, [c, kind, JSON.stringify(body)]));
};
const apply = (id, over = {}) => su(() => t.one(`select * from ai_action_apply($1, $2::jsonb)`, [id, JSON.stringify(over)]));

test('ai_think_db_features에 memory_proposals=1이 포함된다', async () => {
  const row = await su(() => t.one(`select ai_think_db_features() as f`));
  assert.equal(row.f.memory_proposals, 1);
});

test('제안은 내용을 정리해 남기고, 승인 전에는 기억을 만들지 않는다', async () => {
  const row = await propose('save_memory', { memory: memory({ title: '정리 확인' }), reason: '사용자가 확정함' });
  assert.equal(row.status, 'proposed');
  assert.deepEqual(row.payload.memory.alternatives, ['대안 A']);
  assert.equal(row.preview.title, '정리 확인');
  assert.equal(row.preview.memory_kind, 'decision');
  assert.equal(row.preview.reason, '사용자가 확정함');
  const n = await su(() => t.one(`select count(*)::int as n from ai_memories where title = '정리 확인'`));
  assert.equal(n.n, 0);
});

test('잘못된 종류·빈 제목·부서 없는 부서 범위·active가 아닌 대체 대상은 막는다', async () => {
  await assert.rejects(() => propose('save_memory', { memory: memory({ kind: 'note' }) }), /memory_kind_invalid/);
  await assert.rejects(() => propose('save_memory', { memory: memory({ title: ' ' }) }), /memory_title_required/);
  await assert.rejects(
    () => propose('save_memory', { memory: memory({ title: '부서', memory_scope: 'department' }) }),
    /scope_department_required/,
  );
  await assert.rejects(
    () => propose('save_memory', { memory: memory({ title: '레거시', memory_scope: 'legacy_unscoped' }) }),
    /memory_scope_invalid/,
  );
  const draft = (await su(() => t.one(`insert into ai_memories (kind, status, title) values ('decision', 'draft', '초안') returning id`))).id;
  await assert.rejects(
    () => propose('save_memory', { memory: memory({ title: '대체', supersedes_id: draft }) }),
    /memory_supersede_not_active/,
  );
  await assert.rejects(
    () => propose('save_memory', { memory: memory({ title: '대체2', supersedes_id: 'not-a-uuid' }) }),
    /memory_supersede_not_active/,
  );
});

test('같은 제목의 확정 기억이나 대기 카드가 있으면 그 id와 함께 막고, 대기 카드는 서로 대체하지 않는다', async () => {
  const active = (
    await su(() => t.one(`insert into ai_memories (kind, status, title, content) values ('principle', 'active', '중복 원칙', 'x') returning id`))
  ).id;
  await assert.rejects(() => propose('save_memory', { memory: memory({ title: '중복  원칙' }) }), new RegExp(`memory_duplicate_active:${active}`));

  const first = await propose('save_memory', { memory: memory({ title: '대기 하나' }) });
  await assert.rejects(() => propose('save_memory', { memory: memory({ title: '대기하나' }) }), new RegExp(`memory_proposal_pending:${first.id}`));
  const other = await propose('save_memory', { memory: memory({ title: '대기 둘' }) });
  const still = await su(() => t.one(`select status, superseded from ai_actions where id = $1`, [first.id]));
  assert.equal(still.status, 'proposed');
  assert.equal(still.superseded, false);
  assert.equal(other.status, 'proposed');
});

test('승인하면 active로 저장하고, 고친 범위를 쓰며, 대체 대상은 superseded가 된다', async () => {
  const old = (
    await su(() => t.one(`insert into ai_memories (kind, status, title, content) values ('decision', 'active', '예전 결정', 'x') returning id`))
  ).id;
  const card = await propose('save_memory', { memory: memory({ title: '새 결정', supersedes_id: old }), reason: '바뀜' });
  assert.equal(card.preview.supersedes_title, '예전 결정');
  const edited = memory({ title: '새 결정(고침)', memory_scope: 'department', scope_department: 'engineering', supersedes_id: old });
  const done = await apply(card.id, { memory: edited });
  assert.equal(done.status, 'applied');
  assert.equal(done.result.edited, true);
  const saved = await su(() =>
    t.one(`select status, title, memory_scope, scope_department, supersedes_id, source_conversation_id, approved_by from ai_memories where id = $1`, [
      done.result.memory_id,
    ]),
  );
  assert.equal(saved.status, 'active');
  assert.equal(saved.title, '새 결정(고침)');
  assert.equal(saved.memory_scope, 'department');
  assert.equal(saved.scope_department, 'engineering');
  assert.equal(saved.supersedes_id, old);
  assert.equal(saved.source_conversation_id, conv);
  assert.equal(saved.approved_by, USER);
  const prev = await su(() => t.one(`select status from ai_memories where id = $1`, [old]));
  assert.equal(prev.status, 'superseded');
  await assert.rejects(() => apply(card.id), /action_not_pending/);
});

test('원칙은 결정 전용 칸을 비우고 저장한다', async () => {
  const card = await propose('save_memory', { memory: memory({ kind: 'principle', title: '원칙 저장' }) });
  const done = await apply(card.id);
  const saved = await su(() =>
    t.one(`select kind, decision_context, alternatives from ai_memories where id = $1`, [done.result.memory_id]),
  );
  assert.equal(saved.kind, 'principle');
  assert.equal(saved.decision_context, null);
  assert.deepEqual(saved.alternatives, []);
});

test('승인 때 같은 제목의 기억이 생겼으면 저장하지 않는다', async () => {
  const card = await propose('save_memory', { memory: memory({ title: '경합 결정' }) });
  await su(() => t.exec(`insert into ai_memories (kind, status, title, content) values ('decision', 'active', '경합 결정', 'x')`));
  await assert.rejects(() => apply(card.id), /memory_duplicate_active/);
  const row = await su(() => t.one(`select status from ai_actions where id = $1`, [card.id]));
  assert.equal(row.status, 'proposed');
});

test('카드 변경: 수정은 대기 카드 내용을 바꾸고 계속 대기로 둔다', async () => {
  const target = await propose('save_memory', { memory: memory({ title: '수정 대상' }) });
  const change = await propose('memory_card_change', {
    target_action_id: target.id,
    op: 'revise',
    memory: memory({ title: '수정 대상(고침)', content: '새 본문' }),
    reason: '사용자가 고침',
  });
  assert.equal(change.preview.target_title, '수정 대상');
  await assert.rejects(
    () => propose('memory_card_change', { target_action_id: target.id, op: 'withdraw' }),
    new RegExp(`memory_card_change_pending:${change.id}`),
  );
  await apply(change.id);
  const row = await su(() => t.one(`select status, payload, preview from ai_actions where id = $1`, [target.id]));
  assert.equal(row.status, 'proposed');
  assert.equal(row.payload.memory.content, '새 본문');
  assert.equal(row.preview.title, '수정 대상(고침)');
  assert.equal(row.preview.revised, true);
});

test('카드 변경: 대체는 이전 카드를 닫고 새 카드를 대기로 만든다', async () => {
  const target = await propose('save_memory', { memory: memory({ title: '대체 대상' }) });
  const change = await propose('memory_card_change', { target_action_id: target.id, op: 'replace', memory: memory({ title: '대체 결과' }) });
  const done = await apply(change.id);
  const old = await su(() => t.one(`select status, superseded, result from ai_actions where id = $1`, [target.id]));
  assert.equal(old.status, 'rejected');
  assert.equal(old.superseded, true);
  assert.equal(old.result.replaced_by_action_id, change.id);
  const fresh = await su(() => t.one(`select kind, status, preview from ai_actions where id = $1`, [done.result.new_action_id]));
  assert.equal(fresh.kind, 'save_memory');
  assert.equal(fresh.status, 'proposed');
  assert.equal(fresh.preview.title, '대체 결과');
});

test('카드 변경: 삭제는 대기 카드를 닫고 기억을 만들지 않는다. 거절하면 아무것도 바뀌지 않는다', async () => {
  const target = await propose('save_memory', { memory: memory({ title: '삭제 대상' }) });
  const rejected = await propose('memory_card_change', { target_action_id: target.id, op: 'withdraw' });
  await su(() => t.one(`select * from ai_action_reject($1)`, [rejected.id]));
  assert.equal((await su(() => t.one(`select status from ai_actions where id = $1`, [target.id]))).status, 'proposed');

  const change = await propose('memory_card_change', { target_action_id: target.id, op: 'withdraw', reason: '필요 없어짐' });
  await apply(change.id);
  const row = await su(() => t.one(`select status, result from ai_actions where id = $1`, [target.id]));
  assert.equal(row.status, 'rejected');
  assert.equal(row.result.withdrawn_by_action_id, change.id);
  const n = await su(() => t.one(`select count(*)::int as n from ai_memories where title = '삭제 대상'`));
  assert.equal(n.n, 0);
});

test('카드 변경 대상은 대기 중인 기억 저장 카드여야 하고, 처리된 대상이면 승인도 막는다', async () => {
  await assert.rejects(
    () => propose('memory_card_change', { target_action_id: '00000000-0000-4000-8000-000000000000', op: 'withdraw' }),
    /memory_card_not_pending/,
  );
  const target = await propose('save_memory', { memory: memory({ title: '먼저 처리됨' }) });
  await assert.rejects(() => propose('memory_card_change', { target_action_id: target.id, op: 'move' }), /memory_card_op_invalid/);
  const change = await propose('memory_card_change', { target_action_id: target.id, op: 'withdraw' });
  await apply(target.id);
  await assert.rejects(() => apply(change.id), /memory_card_not_pending/);
});

test('일반 사용자·익명은 제안·승인할 수 없고, 내부 함수는 직접 부를 수 없다', async () => {
  const card = await propose('save_memory', { memory: memory({ title: '권한 확인' }) });
  await t.asUser(() =>
    t.rejects(`select ai_action_propose($1, 'save_memory', $2::jsonb, '{}'::jsonb)`, [conv, JSON.stringify({ memory: memory() })], /forbidden/),
  );
  await t.asUser(() => t.rejects(`select ai_action_apply($1, '{}'::jsonb)`, [card.id], /forbidden/));
  await t.asUser(() => t.rejects(`select ai_memory_action_apply($1, '{}'::jsonb)`, [card.id], /permission denied/));
  await t.asAnon(() => t.rejects(`select ai_memory_proposal_clean('{}'::jsonb)`, [], /permission denied/));
});
