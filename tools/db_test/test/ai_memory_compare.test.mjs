// 기억 비교 근거: 원문을 읽은 판만 제안·승인에 쓰인다. 발췌·임의 version·조회 실패는 근거가 아니다.
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { openAiTestDb } from '../harness.mjs';

const USER = '33333333-3333-4333-8333-333333333333';
let t;
let conv;

before(async () => {
  t = await openAiTestDb();
  await t.exec(`insert into auth.users (id) values ('${USER}')`);
  conv = (await su(() => t.one(`insert into ai_conversations (title) values ('비교') returning id`))).id;
});

after(() => t?.close());

const su = (fn) => t.asSuperadmin(fn, USER);
const memory = (over = {}) => ({
  kind: 'decision',
  title: '비교 결정',
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

async function search(id, terms = ['없는말']) {
  return (await su(() => t.one(`select ai_memory_search($1, $2, $3::text[]) as r`, [id, terms.join(' '), terms]))).r;
}

async function read(id, memoryId, offset = 0) {
  return (await su(() => t.one(`select ai_memory_read($1, $2, $3) as r`, [id, memoryId, offset]))).r;
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
        basis: { fake: true, version: 999 },
      }),
    ]),
  );

const apply = (actionId, over = {}) => su(() => t.one(`select * from ai_action_apply($1, $2::jsonb)`, [actionId, JSON.stringify(over)]));

test('검색 0건은 새 제안의 근거가 되고, 검색 실패·미검색은 그렇지 않다', async () => {
  const empty = await session();
  const found = await search(empty, ['zzzzqqqq']);
  assert.equal(found.status, 'empty');
  assert.equal(found.hit_count, 0);
  assert.equal(found.excerpt_only, true);
  const card = await propose(empty, { memory: { title: '검색 없음' } });
  assert.equal(card.payload.basis.relation, 'distinct');
  assert.equal(card.payload.basis.fake, undefined, '클라이언트가 실은 비교 표식은 버린다');
  assert.equal(card.payload.basis.searches[0].status, 'empty');

  const failed = await session();
  const bad = await search(failed, ['a']);
  assert.equal(bad.status, 'error');
  await assert.rejects(() => propose(failed, { memory: { title: '검색 실패' } }), /memory_search_failed/);

  const noted = await session();
  await su(() => t.one(`select ai_memory_note_outcome($1, 'search', 'timeout', null)`, [noted]));
  await assert.rejects(() => propose(noted, { memory: { title: '시간 초과' } }), /memory_search_failed/);
  await assert.rejects(() => su(() => t.one(`select ai_memory_note_outcome($1, 'search', 'ok', null)`, [noted])), /memory_outcome_invalid/);

  const late = await session();
  assert.equal((await search(late, ['zzzzqqqq'])).status, 'empty');
  await su(() => t.one(`select ai_memory_note_outcome($1, 'search', 'timeout', null)`, [late]));
  await assert.rejects(() => propose(late, { memory: { title: '성공 뒤 시간 초과' } }), /memory_search_failed/);

  await assert.rejects(() => propose(null, { memory: { title: '세션 없음' } }), /memory_search_required|memory_read_session_invalid/);
  const n = await su(() => t.one(`select count(*)::int as n from ai_memories where title in ('검색 실패', '시간 초과', '세션 없음', '성공 뒤 시간 초과')`));
  assert.equal(n.n, 0);
});

test('발췌가 아니라 원문을 끝까지 읽어야 하고, 읽는 중 판이 바뀌면 다시 읽는다', async () => {
  const old = (
    await su(() =>
      t.one(
        `insert into ai_memories (kind, status, title, content) values ('decision', 'active', '긴 기억', $1) returning id, version`,
        ['가'.repeat(7000)],
      ),
    )
  );
  const id = await session();
  await search(id, ['zzzzqqqq']);
  const first = await read(id, old.id, 0);
  assert.equal(first.complete, false);
  assert.equal(first.status, 'truncated');
  assert.equal(first.id, old.id);
  assert.equal(first.version, old.version);
  assert.equal(typeof first.document, 'string');
  assert.ok(!first.document.includes('가'.repeat(7000)));
  await assert.rejects(
    () => propose(id, { memory: { title: '덜 읽음', supersedes_id: old.id }, relation: 'supplement' }),
    /memory_read_incomplete/,
  );

  await su(() => t.exec(`update ai_memories set content = content || '나' where id = '${old.id}'`));
  const changed = await read(id, old.id, first.next_offset);
  assert.equal(changed.status, 'version_changed');
  assert.notEqual(changed.version, old.version);
  const again = await read(id, old.id, 0);
  assert.equal(again.complete, false);
  let offset = again.next_offset;
  let last = again;
  for (let i = 0; i < 6 && offset != null; i += 1) {
    last = await read(id, old.id, offset);
    offset = last.next_offset;
  }
  assert.equal(last.complete, true);
  assert.equal(last.version, changed.version);
  const card = await propose(id, { memory: { title: '다 읽음', supersedes_id: old.id }, relation: 'supplement' });
  assert.equal(card.payload.basis.reads[0].version, changed.version);
  assert.equal(card.payload.basis.reads[0].id, old.id);
});

test('승인 전에 비교한 판이 바뀌거나 근거가 없으면 기억도 승인 표시도 남지 않는다', async () => {
  const old = (
    await su(() => t.one(`insert into ai_memories (kind, status, title, content) values ('principle', 'active', '판 대상', '원문') returning id, version`))
  );
  const id = await session();
  await search(id, ['zzzzqqqq']);
  const full = await read(id, old.id, 0);
  assert.equal(full.complete, true);
  const card = await propose(id, { memory: { title: '판 교체', supersedes_id: old.id }, relation: 'conflict' });
  await su(() => t.exec(`update ai_memories set content = '바뀐 원문' where id = '${old.id}'`));
  await assert.rejects(() => apply(card.id), /memory_version_conflict/);
  const pending = await su(() => t.one(`select status from ai_actions where id = $1`, [card.id]));
  assert.equal(pending.status, 'proposed');
  const created = await su(() => t.one(`select count(*)::int as n from ai_memories where title = '판 교체'`));
  assert.equal(created.n, 0);
  const still = await su(() => t.one(`select status from ai_memories where id = $1`, [old.id]));
  assert.equal(still.status, 'active');

  await t.exec(`update ai_actions set payload = payload - 'basis' where id = '${card.id}'`);
  await assert.rejects(() => apply(card.id), /memory_basis_missing/);
  assert.equal((await su(() => t.one(`select status from ai_actions where id = $1`, [card.id]))).status, 'proposed');
});

test('비교한 다른 기억의 판이 바뀌면 거절하고, 본문만 고친 승인은 그 판이 그대로일 때 된다', async () => {
  const compared = (
    await su(() => t.one(`insert into ai_memories (kind, status, title, content) values ('decision', 'active', '비교 대상', '같은 내용') returning id, version`))
  );
  const id = await session();
  await search(id, ['zzzzqqqq']);
  assert.equal((await read(id, compared.id)).complete, true);
  const card = await propose(id, {
    memory: { title: '다른 제목' },
    relation: 'distinct',
    compared_ids: [compared.id],
  });
  await su(() => t.exec(`update ai_memories set title = '비교 대상 수정' where id = '${compared.id}'`));
  await assert.rejects(() => apply(card.id), /memory_version_conflict/);
  assert.equal((await su(() => t.one(`select count(*)::int as n from ai_memories where title = '다른 제목'`))).n, 0);

  const fresh = await session();
  await search(fresh, ['zzzzqqqq']);
  const current = await su(() => t.one(`select version from ai_memories where id = $1`, [compared.id]));
  assert.equal((await read(fresh, compared.id)).complete, true);
  const ok = await propose(fresh, {
    memory: { title: '다른 제목 확정', content: '같은 내용' },
    relation: 'distinct',
    compared_ids: [compared.id],
  });
  assert.equal(ok.payload.basis.reads[0].version, current.version);
  const done = await apply(ok.id, { memory: { ...memory({ title: '다른 제목 확정', content: '고친 본문' }) } });
  assert.equal(done.status, 'applied');
  assert.equal(done.result.edited, true);
  await assert.rejects(() => apply(ok.id), /action_not_pending/);
  assert.equal((await su(() => t.one(`select count(*)::int as n from ai_memories where supersedes_id = $1`, [compared.id]))).n, 0);
});

test('중복으로 판단하면 새 기억을 만들지 않고, 다른 제목의 같은 본문을 별개로 단정하지 않는다', async () => {
  const existing = (
    await su(() => t.one(`insert into ai_memories (kind, status, title, content) values ('decision', 'active', '이미 있음', '동일한 본문') returning id`))
  ).id;
  const id = await session();
  await search(id, ['zzzzqqqq']);
  await read(id, existing);
  await assert.rejects(
    () => propose(id, { memory: { title: '다른 이름', content: '동일한 본문' }, relation: 'duplicate', compared_ids: [existing] }),
    new RegExp(`memory_duplicate_classified:${existing}`),
  );
  assert.equal((await su(() => t.one(`select count(*)::int as n from ai_memories where title = '다른 이름'`))).n, 0);

  const distinct = await propose(id, { memory: { title: '별개 이름', content: '동일한 본문' }, relation: 'distinct', compared_ids: [existing] });
  assert.equal(distinct.status, 'proposed');
  const before = await su(() => t.one(`select count(*)::int as n from ai_memories where title = '별개 이름'`));
  assert.equal(before.n, 0, '승인 전에는 기억이 생기지 않는다');
});

test('같은 제목은 의미 판정이 아니라 기존 중복 제약으로 막히고, 범위가 달라도 그렇다', async () => {
  const id = await session();
  await search(id, ['zzzzqqqq']);
  await propose(id, { memory: { title: '같은 제목', memory_scope: 'common' } });
  await assert.rejects(
    () => propose(id, { memory: { title: '같은  제목', memory_scope: 'department', scope_department: 'education' } }),
    /memory_proposal_pending|memory_duplicate_active/,
  );
});

test('독립 일괄 승인은 항목마다 성공하고, 판이 어긋난 항목만 대기 상태로 남는다', async () => {
  const target = (
    await su(() => t.one(`insert into ai_memories (kind, status, title, content) values ('decision', 'active', '일괄 대상', 'x') returning id`))
  ).id;
  const staleSession = await session();
  await search(staleSession, ['zzzzqqqq']);
  await read(staleSession, target);
  const stale = await propose(staleSession, { memory: { title: '일괄 실패', supersedes_id: target }, relation: 'supplement' });
  await su(() => t.exec(`update ai_memories set content = 'y' where id = '${target}'`));

  const okSession = await session();
  await search(okSession, ['zzzzqqqq']);
  const fresh = await propose(okSession, { memory: { title: '일괄 성공' } });
  const batch = await su(() =>
    t.one(`select ai_action_apply_batch($1::jsonb) as r`, [
      JSON.stringify([{ id: stale.id }, { id: fresh.id }]),
    ]),
  );
  const rows = batch.r;
  assert.equal(rows.find((x) => x.id === stale.id).ok, false);
  assert.match(rows.find((x) => x.id === stale.id).code, /memory_version_conflict/);
  assert.equal(rows.find((x) => x.id === fresh.id).ok, true);
  assert.equal((await su(() => t.one(`select status from ai_actions where id = $1`, [stale.id]))).status, 'proposed');
  assert.equal((await su(() => t.one(`select count(*)::int as n from ai_memories where title = '일괄 실패'`))).n, 0);
  assert.equal((await su(() => t.one(`select count(*)::int as n from ai_memories where title = '일괄 성공'`))).n, 1);
});

test('거절된 같은 제목·같은 본문은 다시 제안하지 않고, 본문이 다르면 막지 않는다', async () => {
  const id = await session();
  await search(id, ['zzzzqqqq']);
  const card = await propose(id, { memory: { title: '거절 동일', content: '같은 본문' } });
  await su(() => t.one(`select * from ai_action_reject($1)`, [card.id]));
  await assert.rejects(
    () => propose(id, { memory: { title: '거절 동일', content: '같은 본문' } }),
    /memory_proposal_rejected/,
  );
  const other = await propose(id, { memory: { title: '거절 동일', content: '다른 본문' } });
  assert.equal(other.status, 'proposed');
  assert.equal((await su(() => t.one(`select count(*)::int as n from ai_memories where title = '거절 동일'`))).n, 0);
});

test('대화 역할 밖의 기억은 승인 근거가 되지 않는다', async () => {
  const edu = (await su(() => t.one(`insert into ai_conversations (title, think_role_id) values ('교육', 'education') returning id`))).id;
  const hidden = (
    await su(() =>
      t.one(
        `insert into ai_memories (kind, status, title, content, memory_scope, scope_department)
         values ('decision', 'active', '문제풀이만', '숨은 본문', 'department', 'product') returning id, version`,
      ),
    )
  );
  const id = (await su(() => t.one(`select ai_memory_read_open($1) as id`, [edu]))).id;
  await su(() => t.one(`select ai_memory_search($1, '없음', array['없음'])`, [id]));
  const hiddenRead = await su(() => t.one(`select ai_memory_read($1, $2, 0) as r`, [id, hidden.id]));
  assert.equal(hiddenRead.r.status, 'forbidden');
  assert.equal(hiddenRead.r.document, undefined);
  const card = await su(() =>
    t.one(`select * from ai_action_propose($1, 'save_memory', $2::jsonb, '{}'::jsonb)`, [
      edu,
      JSON.stringify({
        memory: memory({ title: '권한 밖 제안' }),
        reason: 'x',
        read_session: id,
        relation: 'distinct',
        compared_ids: [],
      }),
    ]),
  );
  await t.exec(
    `update ai_actions set payload = jsonb_set(payload, '{basis,reads}', '${JSON.stringify([{ id: hidden.id, version: hidden.version, title: '문제풀이만', role: 'compared' }]).replaceAll("'", "''")}'::jsonb) where id = '${card.id}'`,
  );
  await assert.rejects(() => su(() => t.one(`select * from ai_action_apply($1, '{}'::jsonb)`, [card.id])), /memory_basis_forbidden/);
  assert.equal((await su(() => t.one(`select status from ai_actions where id = $1`, [card.id]))).status, 'proposed');
  assert.equal((await su(() => t.one(`select count(*)::int as n from ai_memories where title = '권한 밖 제안'`))).n, 0);
});
