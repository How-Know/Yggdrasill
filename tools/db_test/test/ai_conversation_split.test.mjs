// 대화 나누기: 제안 범위·승인(복사·연결·요약·폴더·멱등·되돌림)·만료·거절 억제·권한·기능 확인·첨부 참조
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { openAiTestDb } from '../harness.mjs';

const USER = '11111111-1111-4111-8111-111111111111';
const ATTACHMENT = { path: `${USER}/202610/a-x.png`, name: 'x.png', mime: 'image/png', size: 10 };
let t;

before(async () => {
  t = await openAiTestDb();
  await t.exec(`insert into auth.users (id) values ('${USER}')`);
});

after(() => t?.close());

const su = (fn) => t.asSuperadmin(fn, USER);
const count = async (sql, params = []) => (await t.one(`select count(*)::int as n from (${sql}) q`, params)).n;

/** 앞 문답 1개 + 이번 턴의 사용자 메시지(시작). 답변은 answer()로 따로 넣는다. */
async function conversationWithTurn({ attachment = ATTACHMENT } = {}) {
  const conv = (await t.one(`insert into ai_conversations (title) values ('커리큘럼') returning id`)).id;
  const msg = (role, content, minutesAgo, attachments = []) =>
    t.one(
      `insert into ai_messages (conversation_id, role, content, attachments, created_at)
       values ($1, $2, $3, $4::jsonb, now() - make_interval(mins => $5)) returning id`,
      [conv, role, content, JSON.stringify(attachments), minutesAgo],
    );
  const q1 = (await msg('user', '앞 질문', 10)).id;
  const a1 = (await msg('assistant', '앞 답변', 9)).id;
  const start = (await msg('user', '새 주제 질문', 8, [attachment])).id;
  return { conv, q1, a1, start };
}

async function answer(conv, { status = 'complete', minutesAgo = 7 } = {}) {
  return (
    await t.one(
      `insert into ai_messages (conversation_id, role, content, status, model, created_at)
       values ($1, 'assistant', '새 주제 답변', $2, 'gpt-test', now() - make_interval(mins => $3)) returning id`,
      [conv, status, minutesAgo],
    )
  ).id;
}

const payload = (extra = {}) => ({
  title: '수업 기록 화면',
  reason: '커리큘럼에서 화면 설계로 넘어감',
  folder_id: null,
  summary: { purpose: '수업 기록 화면 설계', background: '반복 사고 원칙', decided: ['날짜순'], open: [], next: ['시안'] },
  ...extra,
});

const propose = (conv, start, p = payload(), userRequested = false) =>
  su(() =>
    t.one(`select * from ai_conversation_split_propose($1, $2, $3::jsonb, '{"folder_path":null}'::jsonb, $4)`, [
      conv,
      start,
      JSON.stringify(p),
      userRequested,
    ]),
  );
const attach = (actionId, messageId) => su(() => t.one(`select ai_action_attach($1::uuid[], $2)`, [[actionId], messageId]));
const apply = (id, overrides = {}) => su(() => t.one(`select * from ai_action_apply($1, $2::jsonb)`, [id, JSON.stringify(overrides)]));
const rejectsAs = (sql, params, pattern) => su(() => t.rejects(sql, params, pattern));

/** 제안 → 답변 저장 → 답변에 붙이기까지(승인 직전 상태). */
async function proposedTurn(p = payload(), opts = {}) {
  const turn = await conversationWithTurn(opts);
  const action = await propose(turn.conv, turn.start, p);
  const ans = await answer(turn.conv);
  await attach(action.id, ans);
  return { ...turn, action, ans };
}

test('제안: 승인 전에는 제안 1행만 남고 대화·메시지·폴더는 만들지 않는다', async () => {
  const before = {
    convs: await count(`select 1 from ai_conversations`),
    msgs: await count(`select 1 from ai_messages`),
    nodes: await count(`select 1 from ai_tree_nodes`),
  };
  const { conv, start } = await conversationWithTurn();
  const row = await propose(conv, start, payload({ summary: { purpose: '  목적  ', decided: ['', ' 확정 '], extra: 'x' } }));
  assert.equal(row.kind, 'split_conversation');
  assert.equal(row.status, 'proposed');
  assert.equal(row.message_id, null);
  assert.equal(row.payload.start_message_id, start);
  assert.deepEqual(row.payload.summary, { purpose: '목적', background: '', decided: ['확정'], open: [], next: [] });
  assert.equal(row.preview.start_preview, '새 주제 질문');
  assert.equal(await count(`select 1 from ai_conversations`), before.convs + 1, '테스트용 원본 대화 1개만 늘었다');
  assert.equal(await count(`select 1 from ai_messages`), before.msgs + 3);
  assert.equal(await count(`select 1 from ai_tree_nodes`), before.nodes);
});

test('제안: 범위는 이 대화의 사용자 메시지만, 앞 대화가 있어야 하고, 뒤에 사용자 메시지가 있으면 만료', async () => {
  const { conv, a1, start } = await conversationWithTurn();
  await rejectsAs(`select ai_conversation_split_propose($1, $2, $3::jsonb)`, [conv, a1, JSON.stringify(payload())], /split_range_invalid/);
  const other = await conversationWithTurn();
  await rejectsAs(`select ai_conversation_split_propose($1, $2, $3::jsonb)`, [conv, other.start, JSON.stringify(payload())], /split_range_invalid/);

  const lone = (await t.one(`insert into ai_conversations (title) values ('첫 문답') returning id`)).id;
  const first = (await t.one(`insert into ai_messages (conversation_id, role, content) values ($1, 'user', 'q') returning id`, [lone])).id;
  await rejectsAs(`select ai_conversation_split_propose($1, $2, $3::jsonb)`, [lone, first, JSON.stringify(payload())], /split_nothing_before/);

  await t.one(`insert into ai_messages (conversation_id, role, content) values ($1, 'user', '다음 질문') returning id`, [conv]);
  await rejectsAs(`select ai_conversation_split_propose($1, $2, $3::jsonb)`, [conv, start, JSON.stringify(payload())], /split_expired/);
});

test('제안: 제목·목적·폴더를 확인하고, 일반 제안 RPC로는 나누기를 만들 수 없다', async () => {
  const { conv, start } = await conversationWithTurn();
  await rejectsAs(`select ai_conversation_split_propose($1, $2, $3::jsonb)`, [conv, start, JSON.stringify(payload({ title: ' ' }))], /split_title_required/);
  await rejectsAs(
    `select ai_conversation_split_propose($1, $2, $3::jsonb)`,
    [conv, start, JSON.stringify(payload({ summary: { purpose: '' } }))],
    /split_summary_required/,
  );
  await rejectsAs(
    `select ai_conversation_split_propose($1, $2, $3::jsonb)`,
    [conv, start, JSON.stringify(payload({ folder_id: '00000000-0000-4000-8000-000000000009' }))],
    /tree_folder_not_found/,
  );
  await rejectsAs(`select ai_action_propose($1, 'split_conversation', '{}'::jsonb)`, [conv], /split_use_dedicated_rpc/);
  await t.asUser(() => t.rejects(`select ai_conversation_split_propose($1, $2, $3::jsonb)`, [conv, start, JSON.stringify(payload())], /forbidden/));
});

test('제안: 같은 대화의 새 나누기 제안은 이전 대기 제안을 대체한다', async () => {
  const { conv, start } = await conversationWithTurn();
  const first = await propose(conv, start);
  const second = await propose(conv, start, payload({ title: '다른 제목' }));
  const old = await t.one(`select status, superseded from ai_actions where id = $1`, [first.id]);
  assert.deepEqual(old, { status: 'rejected', superseded: true });
  assert.equal(second.status, 'proposed');
});

test('승인: 답변이 저장되기 전(스트리밍 중)이나 답변이 완료되지 않았으면 나누지 않는다', async () => {
  const { conv, start } = await conversationWithTurn();
  const action = await propose(conv, start);
  await rejectsAs(`select ai_action_apply($1)`, [action.id], /split_answer_pending/);
  const stopped = await answer(conv, { status: 'stopped' });
  await attach(action.id, stopped);
  await rejectsAs(`select ai_action_apply($1)`, [action.id], /split_answer_incomplete/);
  assert.equal((await t.one(`select status from ai_actions where id = $1`, [action.id])).status, 'proposed');
});

test('승인: 새 대화에 두 메시지를 복사하고 원본은 그대로 둔다(순서·시각·출처·제외·첨부·실행 기록·개수)', async () => {
  const { conv, start, action, ans } = await proposedTurn();
  const run = (await t.one(`insert into ai_runs (feature, provider, model, status) values ('think_chat', 'fake', 'gpt-test', 'ok') returning id`)).id;
  await t.one(`update ai_messages set run_id = $2, context_excluded = true where id = $1 returning id`, [ans, run]);
  const originalBefore = await t.one(`select message_count, last_message_at from ai_conversations where id = $1`, [conv]);

  const applied = await apply(action.id);
  assert.equal(applied.status, 'applied');
  const newId = applied.result.conversation_id;
  assert.ok(newId);
  assert.deepEqual(applied.result.copied_message_ids, [start, ans]);

  const created = await t.one(`select * from ai_conversations where id = $1`, [newId]);
  assert.equal(created.title, '수업 기록 화면');
  assert.equal(created.split_from_conversation_id, conv);
  assert.equal(created.split_from_action_id, action.id);
  assert.equal(created.split_summary.purpose, '수업 기록 화면 설계');
  assert.deepEqual(created.split_summary.decided, ['날짜순']);
  assert.equal(created.message_count, 2);
  assert.equal(created.created_by, USER);

  const copies = await t.all(
    `select c.*, s.created_at as src_created_at, s.content as src_content
       from ai_messages c join ai_messages s on s.id = c.source_message_id
      where c.conversation_id = $1 order by c.created_at`,
    [newId],
  );
  assert.deepEqual(copies.map((m) => m.role), ['user', 'assistant']);
  assert.deepEqual(copies.map((m) => m.source_message_id), [start, ans]);
  for (const m of copies) {
    assert.equal(m.created_at.getTime(), m.src_created_at.getTime(), '원래 시각을 유지한다');
    assert.equal(m.content, m.src_content);
    assert.equal(m.run_id, null, '실행 기록은 원본에만 남는다');
  }
  assert.deepEqual(copies[0].attachments, [ATTACHMENT], '첨부는 같은 파일을 가리킨다');
  assert.equal(copies[1].context_excluded, true, '답변에서 제외한 메시지는 제외 상태 그대로');
  assert.ok(created.last_message_at.getTime() > copies[1].created_at.getTime(), '새 대화가 최근 목록 위로 온다');

  const originalAfter = await t.one(`select message_count, last_message_at from ai_conversations where id = $1`, [conv]);
  assert.deepEqual(originalAfter, originalBefore, '원본 대화는 바뀌지 않는다');
  assert.equal(await count(`select 1 from ai_messages where conversation_id = $1`, [conv]), 4);
  assert.equal(await count(`select 1 from ai_actions where conversation_id = $1`, [newId]), 0, '제안 카드는 복사하지 않는다');
  assert.equal(await count(`select 1 from ai_tree_nodes where conversation_id = $1`, [newId]), 0, '폴더를 고르지 않으면 미분류');
});

test('승인: 사용자가 고친 제목·요약·폴더로 만들고, 다시 눌러도 같은 대화를 돌려준다', async () => {
  const folder = (await su(() => t.one(`insert into ai_tree_nodes (kind, title, sort_order) values ('folder', '설계', 0) returning id`))).id;
  const { action } = await proposedTurn();
  const overrides = {
    title: '  고친 제목 ',
    folder_id: folder,
    summary: { purpose: '고친 목적', background: '', decided: [], open: ['남은 것'], next: [] },
  };
  const first = await apply(action.id, overrides);
  const second = await apply(action.id, overrides);
  assert.equal(second.result.conversation_id, first.result.conversation_id);
  assert.equal(await count(`select 1 from ai_conversations where split_from_action_id = $1`, [action.id]), 1);
  assert.equal(first.result.edited, true);

  const created = await t.one(`select title, split_summary from ai_conversations where id = $1`, [first.result.conversation_id]);
  assert.equal(created.title, '고친 제목');
  assert.deepEqual(created.split_summary.open, ['남은 것']);
  const node = await t.one(`select parent_id from ai_tree_nodes where kind = 'conversation' and conversation_id = $1`, [first.result.conversation_id]);
  assert.equal(node.parent_id, folder);
});

test('승인: 폴더를 미분류(null)로 고치면 트리에 놓지 않는다', async () => {
  const folder = (await su(() => t.one(`insert into ai_tree_nodes (kind, title, sort_order) values ('folder', '기본', 0) returning id`))).id;
  const { action } = await proposedTurn(payload({ folder_id: folder }));
  const applied = await apply(action.id, { folder_id: null });
  assert.equal(await count(`select 1 from ai_tree_nodes where conversation_id = $1`, [applied.result.conversation_id]), 0);
});

test('승인: 복사하지 않은 것(다른 카드·코드 요청·발췌·이 문답이 아닌 메시지)을 결과에 남긴다', async () => {
  const { conv, start, action, ans } = await proposedTurn();
  const place = await su(() => t.one(`select * from ai_action_propose($1, 'delete_folder', '{}'::jsonb)`, [conv]));
  await attach(place.id, ans);
  await t.one(`insert into ai_code_requests (conversation_id, source_message_ids, title) values ($1, $2::uuid[], '조사') returning id`, [conv, [ans]]);
  await su(() => t.one(`select ai_tree_create_excerpt($1, null, '발췌', '요약', $2::uuid[]) as id`, [conv, [start]]));
  await answer(conv, { minutesAgo: 6 });

  const applied = await apply(action.id);
  assert.deepEqual(applied.result.not_copied, { actions: 1, code_requests: 1, tree_nodes: 1, other_messages: 1 });
  assert.equal(await count(`select 1 from ai_messages where conversation_id = $1`, [applied.result.conversation_id]), 2);
});

test('승인 실패는 모두 되돌린다(새 대화·복사·배치 없음, 제안은 대기 그대로)', async () => {
  const folder = (await su(() => t.one(`insert into ai_tree_nodes (kind, title, sort_order) values ('folder', '되돌림', 0) returning id`))).id;
  const { conv, start, action } = await proposedTurn(payload({ folder_id: folder }));
  await t.exec(`
    create function test_fail_place() returns trigger language plpgsql as $$ begin raise exception 'test_place_failed'; end $$;
    create trigger test_fail_place before insert on ai_tree_nodes for each row when (new.kind = 'conversation') execute function test_fail_place();
  `);
  try {
    await rejectsAs(`select ai_action_apply($1)`, [action.id], /test_place_failed/);
  } finally {
    await t.exec(`drop trigger test_fail_place on ai_tree_nodes; drop function test_fail_place();`);
  }
  assert.equal(await count(`select 1 from ai_conversations where split_from_action_id = $1`, [action.id]), 0);
  assert.equal(await count(`select 1 from ai_messages where source_message_id = $1`, [start]), 0);
  assert.equal((await t.one(`select status from ai_actions where id = $1`, [action.id])).status, 'proposed');
  assert.equal((await t.one(`select message_count from ai_conversations where id = $1`, [conv])).message_count, 4);

  const retried = await apply(action.id);
  assert.equal(retried.status, 'applied');
});

test('만료: 제안 뒤 같은 대화에 사용자 메시지가 저장되면 대기 제안이 닫히고 승인할 수 없다', async () => {
  const { conv, action } = await proposedTurn();
  await t.one(`insert into ai_messages (conversation_id, role, content) values ($1, 'assistant', '검토 답변') returning id`, [conv]);
  assert.equal((await t.one(`select status from ai_actions where id = $1`, [action.id])).status, 'proposed', '답변(검토 등)은 만료시키지 않는다');

  await t.one(`insert into ai_messages (conversation_id, role, content) values ($1, 'user', '이어서 질문') returning id`, [conv]);
  const row = await t.one(`select status, error from ai_actions where id = $1`, [action.id]);
  assert.deepEqual(row, { status: 'expired', error: 'conversation_continued' });
  await rejectsAs(`select ai_action_apply($1)`, [action.id], /split_expired/);
  assert.equal(await count(`select 1 from ai_conversations where split_from_action_id = $1`, [action.id]), 0);
});

test('승인 뒤 원본에 새 메시지가 와도 이미 나눈 결과는 그대로다', async () => {
  const { conv, action } = await proposedTurn();
  const applied = await apply(action.id);
  await t.one(`insert into ai_messages (conversation_id, role, content) values ($1, 'user', '원본에서 계속') returning id`, [conv]);
  assert.equal((await t.one(`select status from ai_actions where id = $1`, [action.id])).status, 'applied');
  assert.equal(await count(`select 1 from ai_messages where conversation_id = $1`, [applied.result.conversation_id]), 2);
});

test('거절: 그 대화의 자동 제안을 끄고, 사용자가 직접 요청하면 다시 제안할 수 있다', async () => {
  const { conv, start, action } = await proposedTurn();
  const rejected = await su(() => t.one(`select * from ai_action_reject($1)`, [action.id]));
  assert.equal(rejected.status, 'rejected');
  assert.equal((await t.one(`select auto_split_suggestions from ai_conversations where id = $1`, [conv])).auto_split_suggestions, false);
  await rejectsAs(`select ai_conversation_split_propose($1, $2, $3::jsonb)`, [conv, start, JSON.stringify(payload())], /split_suppressed/);
  const asked = await propose(conv, start, payload(), true);
  assert.equal(asked.payload.user_requested, true);

  const other = await conversationWithTurn();
  assert.equal((await propose(other.conv, other.start)).status, 'proposed', '다른 대화에는 영향이 없다');

  await t.one(`update ai_conversations set auto_split_suggestions = true where id = $1 returning id`, [conv]);
  assert.equal((await propose(conv, start)).status, 'proposed', '앱에서 다시 켜면 자동 제안이 돌아온다');
});

test('다른 종류의 제안 거절·승인은 그대로 동작한다', async () => {
  const folder = (await su(() => t.one(`insert into ai_tree_nodes (kind, title, sort_order) values ('folder', '분류', 0) returning id`))).id;
  const { conv } = await conversationWithTurn();
  const place = await su(() => t.one(`select * from ai_action_propose($1, 'place_conversation', $2::jsonb)`, [conv, JSON.stringify({ folder_id: folder })]));
  const applied = await apply(place.id);
  assert.equal(applied.status, 'applied');
  assert.equal(applied.result.folder_id, folder);
  const del = await su(() => t.one(`select * from ai_action_propose($1, 'delete_folder', '{}'::jsonb)`, [conv]));
  await su(() => t.one(`select * from ai_action_reject($1)`, [del.id]));
  assert.equal((await t.one(`select auto_split_suggestions from ai_conversations where id = $1`, [conv])).auto_split_suggestions, true);

  const odd = (await t.one(`insert into ai_actions (conversation_id, kind) values ($1, 'code_plan') returning id`, [conv])).id;
  await rejectsAs(`select ai_action_apply($1)`, [odd], /action_kind_not_appliable/);
});

test('권한: 승인은 ai_action_apply로만, 슈퍼관리자만. 나누기는 되돌리기 대상이 아니다', async () => {
  const { action } = await proposedTurn();
  await rejectsAs(`select ai_conversation_split_apply($1, '{}'::jsonb)`, [action.id], /permission denied/);
  await rejectsAs(`select ai_split_summary_clean('{}'::jsonb)`, [], /permission denied/);
  await t.asUser(() => t.rejects(`select ai_action_apply($1)`, [action.id], /forbidden/));
  const applied = await apply(action.id);
  await rejectsAs(`select ai_action_undo($1)`, [applied.id], /action_not_undoable/);
});

test('기능 확인: 읽기 전용(STABLE) 함수가 반영된 기능 버전을 돌려준다', async () => {
  const row = await su(() => t.one(`select ai_think_db_features() as f`));
  assert.equal(row.f.conversation_split, 1);
  await t.asUser(() => t.rejects(`select ai_think_db_features()`, [], /forbidden/));
  const fn = await t.one(`select provolatile from pg_proc where proname = 'ai_think_db_features'`);
  assert.equal(fn.provolatile, 's');
});

test('첨부 참조: 복사본이 같은 파일을 가리키면 대화를 지울 때 남겨야 할 경로로 알려 준다', async () => {
  const own = { ...ATTACHMENT, path: `${USER}/202610/split-only.png` };
  const { conv, action } = await proposedTurn(payload(), { attachment: own });
  const paths = [own.path, `${USER}/202610/none.png`];
  const inUse = async (except) => (await su(() => t.one(`select ai_attachment_paths_in_use($1::text[], $2) as p`, [paths, except]))).p;
  assert.deepEqual(await inUse(conv), [], '나누기 전에는 다른 대화가 가리키지 않는다');
  const applied = await apply(action.id);
  assert.deepEqual(await inUse(conv), [own.path], '원본을 지워도 복사본이 쓰는 파일');
  assert.deepEqual(await inUse(applied.result.conversation_id), [own.path], '복사본을 지워도 원본이 쓰는 파일');
});

test('PGlite 한계: 한 연결뿐이라 승인과 메시지 저장의 실제 동시 실행(잠금 대기)은 검사하지 못한다', () => {
  assert.ok(true, '잠금 순서(대화 → 제안)는 코드 검토로만 확인. 순서대로 일어나는 경우(만료 후 승인, 승인 후 메시지)는 위에서 검사');
});
