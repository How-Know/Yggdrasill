// Think 자동 정리 제안: 맥락 제외·중요 표시·진행 요약·부서 기준 제안과 승인, 일괄 승인, 분류의 부서 충돌
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { openAiTestDb } from '../harness.mjs';

const USER = '33333333-3333-4333-8333-333333333333';
let t;

before(async () => {
  t = await openAiTestDb();
  await t.exec(`insert into auth.users (id) values ('${USER}')`);
});

after(() => t?.close());

const su = (fn) => t.asSuperadmin(fn, USER);
const newConv = async (title = '정리', role = 'lead') =>
  (await su(() => t.one(`insert into ai_conversations (title, think_role_id) values ($1, $2) returning id`, [title, role]))).id;
const newMsg = async (conv, role, content) =>
  (await su(() => t.one(`insert into ai_messages (conversation_id, role, content) values ($1, $2, $3) returning id`, [conv, role, content])))
    .id;
const msg = (id) => su(() => t.one(`select context_excluded, marked_important from ai_messages where id = $1`, [id]));
const action = (id) => su(() => t.one(`select status, superseded, result from ai_actions where id = $1`, [id]));
const apply = (id, over = {}) => su(() => t.one(`select * from ai_action_apply($1, $2::jsonb)`, [id, JSON.stringify(over)]));
const reject = (id) => su(() => t.one(`select * from ai_action_reject($1)`, [id]));
const undo = (id) => su(() => t.one(`select * from ai_action_undo($1)`, [id]));
const exclude = (conv, ids, reason = '정정돼 더 이상 맞지 않는 설명', userRequested = false) =>
  su(() =>
    t.one(`select * from ai_context_exclusion_propose($1, $2::uuid[], $3, '이후 답변이 옛 설명을 따르지 않는다', $4)`, [
      conv,
      ids,
      reason,
      userRequested,
    ]),
  );
const mark = (conv, ids, reason = '확정된 결정이 나온 답변') =>
  su(() => t.one(`select * from ai_importance_mark_propose($1, $2::uuid[], $3, false)`, [conv, ids, reason]));
const summarize = (conv, summary, through = null) =>
  su(() =>
    t.one(`select * from ai_progress_summary_propose($1, $2::jsonb, '논의가 정리됨', $3)`, [conv, JSON.stringify(summary), through]),
  );
const criteria = (conv, dept, c, reason = '사용자가 이 기준을 꼭 보자고 함') =>
  su(() => t.one(`select * from ai_department_criteria_propose($1, $2, $3::jsonb, $4)`, [conv, dept, JSON.stringify(c), reason]));
const batch = (items) => su(() => t.one(`select ai_action_apply_batch($1::jsonb) as r`, [JSON.stringify(items)])).then((x) => x.r);
const newMemory = async (title, scope = 'common', dept = null) =>
  (
    await su(() =>
      t.one(
        `insert into ai_memories (kind, status, title, content, memory_scope, scope_department) values ('decision', 'active', $1, '본문', $2, $3) returning id`,
        [title, scope, dept],
      ),
    )
  ).id;

test('기능 확인에 auto_organize=1, 자동 제안 설정은 기본 켜짐, 부서 기준 네 칸이 판 0으로 있다', async () => {
  const row = await su(() => t.one(`select ai_think_db_features() as f`));
  assert.equal(row.f.auto_organize, 1);
  const s = await su(() => t.one(`select auto_organize_enabled from ai_platform_settings where id`));
  assert.equal(s.auto_organize_enabled, true);
  const rows = await su(() => t.all(`select department, version, questions from ai_department_criteria order by department`));
  assert.deepEqual(
    rows.map((r) => [r.department, r.version, r.questions.length]),
    [
      ['education', 0, 0],
      ['engineering', 0, 0],
      ['lead', 0, 0],
      ['product', 0, 0],
    ],
  );
  await t.asUser(() => t.rejects(`select ai_think_db_features()`, [], /forbidden/));
});

test('전용 RPC가 있는 종류는 범용 제안으로 만들 수 없다', async () => {
  const c = await newConv();
  for (const kind of ['exclude_context', 'mark_important', 'progress_summary', 'department_criteria_change', 'handover_department']) {
    await assert.rejects(
      () => su(() => t.one(`select * from ai_action_propose($1, $2, '{}'::jsonb, '{}'::jsonb)`, [c, kind])),
      /action_use_dedicated_rpc/,
      kind,
    );
  }
});

test('맥락 제외 제안: 대상·이유를 검사하고, 카드에 대상 발췌와 연결된 문서·기억을 남긴다', async () => {
  const c = await newConv('제외');
  const other = await newConv('다른 대화');
  const q = await newMsg(c, 'user', '처음 질문');
  const a = await newMsg(c, 'assistant', '잘못된   설명\n둘째 줄');
  const foreign = await newMsg(other, 'user', '남의 메시지');
  const doc = (
    await su(() => t.one(`insert into ai_tree_nodes (kind, title, conversation_id) values ('excerpt', '옛 설명 발췌', $1) returning id`, [c]))
  ).id;
  await su(() => t.exec(`insert into ai_tree_node_sources (node_id, message_id) values ('${doc}', '${a}')`));

  await assert.rejects(() => exclude(c, [a], '  '), /exclusion_reason_required/);
  await assert.rejects(() => exclude(c, [a, foreign]), /organize_target_missing/);
  await assert.rejects(() => exclude(c, []), /organize_targets_invalid/);

  const row = await exclude(c, [a, q, a]);
  assert.equal(row.kind, 'exclude_context');
  assert.equal(row.preview.count, 2, '중복 id는 하나로');
  assert.deepEqual(
    row.preview.targets.map((x) => [x.id, x.excerpt]),
    [
      [q, '처음 질문'],
      [a, '잘못된 설명 둘째 줄'],
    ],
  );
  assert.deepEqual(row.preview.linked.documents, [{ id: doc, kind: 'excerpt', title: '옛 설명 발췌' }]);
  assert.equal(row.preview.has_summary, false);
  assert.equal((await msg(a)).context_excluded, false, '승인 전에는 바뀌지 않는다');

  const second = await exclude(c, [a]);
  assert.deepEqual(await action(row.id).then((x) => [x.status, x.superseded]), ['rejected', true], '새 제안이 대체한다');
  await t.asUser(() => t.rejects(`select ai_context_exclusion_propose($1, array[$2]::uuid[], 'x', null, false)`, [c, a], /forbidden/));

  await su(() => t.exec(`update ai_messages set context_excluded = true where id = '${q}'`));
  await assert.rejects(() => exclude(c, [q]), /exclusion_already_excluded/);
  await reject(second.id);
});

test('맥락 제외 승인: 고른 메시지만 제외하고 결과를 남기며, 되돌리면 이 승인으로 바뀐 것만 돌아온다', async () => {
  const c = await newConv('제외 승인');
  const a1 = await newMsg(c, 'assistant', '틀린 설명 1');
  const a2 = await newMsg(c, 'assistant', '틀린 설명 2');
  const keep = await newMsg(c, 'assistant', '맞는 설명');
  const row = await exclude(c, [a1, a2]);
  await assert.rejects(() => apply(row.id, { message_ids: [keep] }), /organize_target_not_proposed/);
  await assert.rejects(() => apply(row.id, { message_ids: [] }), /organize_targets_invalid/);

  const applied = await apply(row.id, { message_ids: [a1] });
  assert.equal(applied.status, 'applied');
  assert.deepEqual(applied.result.excluded_ids, [a1]);
  assert.deepEqual(applied.result.already_excluded_ids, []);
  assert.equal((await msg(a1)).context_excluded, true);
  assert.equal((await msg(a2)).context_excluded, false, '고르지 않은 메시지는 그대로');
  assert.equal((await msg(keep)).context_excluded, false);
  await assert.rejects(() => apply(row.id), /action_not_pending/, '같은 승인을 두 번 실행하지 않는다');

  const undone = await undo(row.id);
  assert.equal(undone.status, 'undone');
  assert.equal((await msg(a1)).context_excluded, false);
});

test('거절한 같은 메시지 묶음은 다시 제안하지 못하고, 사용자가 직접 요청하면 낼 수 있다', async () => {
  const c = await newConv('거절');
  const a = await newMsg(c, 'assistant', '설명');
  const b = await newMsg(c, 'assistant', '설명 2');
  const first = await exclude(c, [a, b]);
  await reject(first.id);
  await assert.rejects(() => exclude(c, [a]), /organize_rejected_before/);
  const asked = await exclude(c, [a], '사용자가 빼 달라고 함', true);
  assert.equal(asked.status, 'proposed');
});

test('중요 표시: 제외된 메시지·이미 표시한 메시지는 막고, 승인·되돌리기는 표시만 바꾼다', async () => {
  const c = await newConv('중요');
  const a = await newMsg(c, 'assistant', '결정이 나온 답변');
  const ex = await newMsg(c, 'assistant', '제외된 답변');
  await su(() => t.exec(`update ai_messages set context_excluded = true where id = '${ex}'`));
  await assert.rejects(() => mark(c, [ex]), /importance_target_excluded/);
  await assert.rejects(() => mark(c, [a], ''), /importance_reason_required/);

  const row = await mark(c, [a]);
  assert.equal(row.preview.targets[0].excerpt, '결정이 나온 답변');
  const applied = await apply(row.id);
  assert.deepEqual(applied.result.marked_ids, [a]);
  assert.deepEqual(await msg(a), { context_excluded: false, marked_important: true });
  await assert.rejects(() => mark(c, [a]), /importance_already_marked/);
  await undo(row.id);
  assert.equal((await msg(a)).marked_important, false);
});

test('진행 요약: 목적이 없으면 막고, 다음 행동을 정리해 저장하며, 승인하면 대화에 하나로 남는다', async () => {
  const c = await newConv('요약');
  const q = await newMsg(c, 'user', '정리해 줘');
  await assert.rejects(() => summarize(c, { purpose: ' ' }), /summary_purpose_required/);
  const row = await summarize(
    c,
    {
      purpose: '자동 정리 설계',
      decided: ['패널로 모은다', ' '],
      open: ['토글 위치'],
      status: '설계 중',
      next: ['DB 먼저', { what: '앱 화면', owner: '개발', done_when: '시험 통과' }, { what: ' ' }, 3],
    },
    q,
  );
  assert.deepEqual(row.payload.summary.decided, ['패널로 모은다']);
  assert.deepEqual(row.payload.summary.next, [
    { what: 'DB 먼저', owner: '', prerequisite: '', done_when: '' },
    { what: '앱 화면', owner: '개발', prerequisite: '', done_when: '시험 통과' },
  ]);
  assert.equal(row.payload.base_action_id, null);
  assert.equal(row.preview.previous, null);

  const applied = await apply(row.id);
  assert.equal(applied.result.edited, false);
  const conv = await su(() => t.one(`select progress_summary from ai_conversations where id = $1`, [c]));
  assert.equal(conv.progress_summary.purpose, '자동 정리 설계');
  assert.equal(conv.progress_summary.action_id, row.id);
  assert.equal(conv.progress_summary.through_message_id, q);

  // 같은 승인본을 기준으로 낸 두 제안: 먼저 승인한 쪽이 기준을 바꾸면 나머지는 충돌이다.
  const a1 = await summarize(c, { purpose: '갱신 A' });
  // 앱 사용자는 ai_actions에 직접 넣을 수 없다. 같은 기준의 두 번째 제안을 시험용으로 소유자 권한에서 만든다.
  const a2 = await t.one(
    `insert into ai_actions (conversation_id, kind, payload, preview) values ($1, 'progress_summary', $2::jsonb, '{}'::jsonb) returning *`,
    [c, JSON.stringify({ summary: { purpose: '갱신 B' }, base_action_id: row.id })],
  );
  assert.equal(a1.payload.base_action_id, row.id);
  const edited = await apply(a1.id, { summary: { purpose: '고친 갱신 A', next: [] } });
  assert.equal(edited.result.edited, true);
  assert.equal(edited.result.previous_action_id, row.id);
  await assert.rejects(() => apply(a2.id), /progress_summary_changed/);
  const after = await su(() => t.one(`select progress_summary from ai_conversations where id = $1`, [c]));
  assert.equal(after.progress_summary.purpose, '고친 갱신 A');
  assert.equal(after.progress_summary.edited, true);
});

test('부서 기준 제안: 그 부서가 볼 수 없는 기억은 막고, 같은 내용은 막고, 승인하면 판이 오르고 기록이 남는다', async () => {
  const c = await newConv('기준', 'education');
  const common = await newMemory('공통 결정');
  const edu = await newMemory('교육 결정', 'department', 'education');
  const eng = await newMemory('개발 결정', 'department', 'engineering');
  await assert.rejects(
    () => criteria(c, 'education', { questions: ['q'], risks: [], priority_memory_ids: [eng] }),
    /criteria_memory_not_allowed/,
  );
  await assert.rejects(() => criteria(c, 'education', { questions: [], risks: [], priority_memory_ids: [] }), /criteria_unchanged/);
  await assert.rejects(() => criteria(c, 'education', { questions: ['q'] }, ' '), /criteria_reason_required/);
  await assert.rejects(() => criteria(c, 'boss', { questions: ['q'] }), /criteria_department_invalid/);

  const lead = await criteria(c, 'lead', { questions: ['우선순위는?'], risks: [], priority_memory_ids: [eng] });
  assert.deepEqual(lead.preview.after.priority_memories, [{ id: eng, title: '개발 결정' }], '총괄은 모든 부서 기억을 고를 수 있다');
  await reject(lead.id);

  const row = await criteria(c, 'education', {
    questions: ['학생 경험이 나빠지지 않나?', ' '],
    risks: ['점수로 학생을 재단'],
    priority_memory_ids: [edu, common],
  });
  assert.equal(row.preview.title, '교육 부서 기준');
  assert.equal(row.preview.base_version, 0);
  assert.deepEqual(row.preview.before, { questions: [], risks: [], priority_memories: [] });
  assert.deepEqual(row.preview.after.questions, ['학생 경험이 나빠지지 않나?']);
  assert.deepEqual(row.preview.after.priority_memories.map((m) => m.title), ['교육 결정', '공통 결정']);

  const stale = await criteria(await newConv('다른 대화', 'education'), 'education', { questions: ['다른 질문'] });
  const applied = await apply(row.id);
  assert.equal(applied.result.version, 1);
  assert.deepEqual(applied.result.before.questions, []);
  const cur = await su(() => t.one(`select * from ai_department_criteria where department = 'education'`));
  assert.equal(cur.version, 1);
  assert.deepEqual(cur.priority_memory_ids, [edu, common]);
  assert.equal(cur.updated_via, `action:${row.id}`);
  await assert.rejects(() => apply(stale.id), /criteria_changed/, '판이 바뀐 뒤의 제안은 충돌');
  const revs = await su(() => t.all(`select version, updated_via from ai_department_criteria_revisions where department = 'education'`));
  assert.deepEqual(revs, [{ version: 1, updated_via: `action:${row.id}` }]);
});

test('운영자가 부서 기준을 직접 고친다: 판이 맞아야 하고 기록이 남는다', async () => {
  const before = await su(() => t.one(`select version from ai_department_criteria where department = 'product'`));
  const saved = await su(() =>
    t.one(`select * from ai_department_criteria_save('product', $1::jsonb, $2)`, [
      JSON.stringify({ questions: ['난이도 근거는?'], risks: ['정답률만 보고 판단'] }),
      before.version,
    ]),
  );
  assert.equal(saved.version, before.version + 1);
  assert.equal(saved.updated_via, 'owner');
  await assert.rejects(
    () => su(() => t.one(`select * from ai_department_criteria_save('product', '{}'::jsonb, $1)`, [before.version])),
    /criteria_changed/,
  );
  await t.asUser(() => t.rejects(`select ai_department_criteria_save('product', '{}'::jsonb, 1)`, [], /forbidden/));
  await t.asUser(async () => {
    const rows = await t.all(`select * from ai_department_criteria`);
    assert.equal(rows.length, 0, '슈퍼관리자가 아니면 읽을 수 없다');
  });
});

test('분류 승인: 제안 뒤 대화 부서가 바뀌어 폴더 부서와 다르면 충돌로 막는다', async () => {
  const c = await newConv('부서 바뀜', 'lead');
  const folder = (
    await su(() => t.one(`insert into ai_tree_nodes (kind, title, department) values ('folder', '총괄 폴더', 'lead') returning id`))
  ).id;
  const placed = await su(() =>
    t.one(`select * from ai_action_propose($1, 'place_conversation', $2::jsonb, '{}'::jsonb)`, [c, JSON.stringify({ folder_id: folder })]),
  );
  await su(() => t.one(`select ai_conversation_move_department($1, 'education')`, [c]));
  await assert.rejects(() => apply(placed.id), /place_department_mismatch/);
  assert.equal((await action(placed.id)).status, 'proposed', '실패하면 제안은 그대로 남는다');
});

test('일괄 승인: 부서 넘기기를 먼저 실행하고, 다른 부서 폴더 배치는 충돌로 남기며, 나머지는 각각 처리한다', async () => {
  const c = await newConv('일괄', 'lead');
  const a = await newMsg(c, 'assistant', '옛 설명');
  const folder = (
    await su(() => t.one(`insert into ai_tree_nodes (kind, title, department) values ('folder', '총괄 칸', 'lead') returning id`))
  ).id;
  const placed = await su(() =>
    t.one(`select * from ai_action_propose($1, 'place_conversation', $2::jsonb, '{}'::jsonb)`, [c, JSON.stringify({ folder_id: folder })]),
  );
  const handover = await su(() => t.one(`select * from ai_department_handover_propose($1, 'engineering', '구현 이야기')`, [c]));
  const ex = await exclude(c, [a]);
  const code = await su(() =>
    t.one(`select * from ai_action_propose($1, 'code_request', $2::jsonb, '{}'::jsonb)`, [
      c,
      JSON.stringify({ title: '조사', spec: { goal: 'x' } }),
    ]),
  );

  // 화면에 보인 순서(분류 → 제외 → 넘기기)와 상관없이 넘기기가 먼저 실행된다.
  const res = await batch([{ id: placed.id }, { id: ex.id }, { id: handover.id }, { id: handover.id }, { id: code.id }, { id: 'nope' }]);
  const byId = Object.fromEntries(res.filter((r) => r.id).map((r) => [r.id, r]));
  assert.deepEqual(
    res.map((r) => r.id),
    [handover.id, placed.id, ex.id, code.id, null],
    '같은 id는 한 번만, 정한 순서대로',
  );
  assert.equal(byId[handover.id].ok, true);
  assert.equal(byId[handover.id].action.status, 'applied');
  assert.equal(byId[placed.id].ok, false);
  assert.equal(byId[placed.id].code, 'place_department_mismatch');
  assert.equal(byId[placed.id].action.status, 'proposed', '실패한 항목은 대기로 남는다');
  assert.equal(byId[ex.id].ok, true);
  assert.equal(byId[code.id].code, 'action_kind_not_in_batch');
  assert.equal(res[4].code, 'action_not_found');
  assert.equal((await msg(a)).context_excluded, true);
  assert.equal((await action(code.id)).status, 'proposed', '코드 요청은 일괄 승인으로 시작되지 않는다');

  // 네트워크 재시도: 이미 승인된 항목은 다시 실행하지 않고 already로 돌려준다.
  const again = await batch([{ id: ex.id }, { id: handover.id }]);
  assert.deepEqual(
    again.map((r) => [r.ok, r.already]),
    [
      [true, true],
      [true, true],
    ],
  );
  await assert.rejects(() => batch([]), /batch_items_invalid/);
  await t.asUser(() => t.rejects(`select ai_action_apply_batch('[{"id":"${ex.id}"}]'::jsonb)`, [], /forbidden/));
});

test('일괄 승인의 수정값은 그 항목에만 적용된다', async () => {
  const c = await newConv('일괄 수정');
  const a1 = await newMsg(c, 'assistant', '하나');
  const a2 = await newMsg(c, 'assistant', '둘');
  const m = await mark(c, [a1, a2]);
  const s = await summarize(c, { purpose: '원래 목적' });
  const res = await batch([
    { id: m.id, overrides: { message_ids: [a2] } },
    { id: s.id, overrides: { summary: { purpose: '고친 목적' } } },
  ]);
  assert.deepEqual(
    res.map((r) => r.ok),
    [true, true],
  );
  assert.equal((await msg(a1)).marked_important, false);
  assert.equal((await msg(a2)).marked_important, true);
  const conv = await su(() => t.one(`select progress_summary from ai_conversations where id = $1`, [c]));
  assert.equal(conv.progress_summary.purpose, '고친 목적');
});
