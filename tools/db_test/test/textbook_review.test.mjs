// 교재 검수: 적재 확인이 문제를 찾아 열고, 사장님 결정은 화면에서 본 버전에만 반영되며 모두 이력으로 남는다.
// 학원 직원만 읽고, 직원도 검수 표에 직접 쓰지 못하며, 학생 쪽 코드는 검수 표를 읽지 않는다.
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { openTextbookTestDb, seedAcademy, seedCrop } from '../textbook_fixture.mjs';

let t;
let S;

before(async () => {
  t = await openTextbookTestDb();
  S = await seedAcademy(t);
});
after(() => t?.close());

const refresh = (mid) =>
  t.asMember(S.staff, async () =>
    (await t.one(
      `select textbook_review_refresh_load_checks($1::uuid, $2::uuid, '1-1', 0, $3::int) as r`,
      [S.academy, S.book, mid],
    )).r);

const fingerprint = async (crop) => (await t.one(`select textbook_review_fingerprint($1::uuid) as fp`, [crop])).fp;

const decide = (finding, action, expected, value = null, note = '') =>
  t.asMember(S.staff, async () =>
    (await t.one(
      `select textbook_review_decide($1::uuid, $2, $3::jsonb, $4::jsonb, $5) as r`,
      [finding, action, expected == null ? null : JSON.stringify(expected), value == null ? null : JSON.stringify(value), note],
    )).r);

const findings = (crop) =>
  t.all(
    `select id, check_key, status, resolution from textbook_review_findings
      where crop_id = $1::uuid order by created_at, check_key`,
    [crop],
  );

const answerOf = async (crop) => ({
  ...(await t.one(
    `select answer_kind, answer_text, answer_source from textbook_problem_answers where crop_id = $1::uuid`,
    [crop],
  )),
});

const setAnswer = (crop, text, kind = 'objective') =>
  t.one(
    `insert into textbook_problem_answers (crop_id, academy_id, answer_kind, answer_text, answer_latex_2d, answer_source)
     values ($1::uuid, $2::uuid, $3, $4, $4, 'vlm')
     on conflict (crop_id) do update
       set answer_kind = excluded.answer_kind, answer_text = excluded.answer_text,
           answer_latex_2d = excluded.answer_latex_2d, answer_source = excluded.answer_source
     returning crop_id`,
    [crop, S.academy, kind, text],
  );

const setRef = (crop) =>
  t.one(
    `insert into textbook_problem_solution_refs (crop_id, academy_id, raw_page, number_region_1k)
     values ($1::uuid, $2::uuid, 40, array[10, 10, 40, 200]) returning crop_id`,
    [crop, S.academy],
  );

const linkQuestion = async (crop, pbAnswer, kind) => {
  const q = (await t.one(
    `insert into pb_questions (academy_id, stem, objective_answer_key, subjective_answer)
     values ($1::uuid, '발문', $2, $3) returning id`,
    [S.academy, kind === 'objective' ? pbAnswer : '', kind === 'objective' ? '' : pbAnswer],
  )).id;
  await t.one(
    `insert into textbook_crop_question_links (crop_id, pb_question_id, academy_id) values ($1::uuid, $2::uuid, $3::uuid)
     returning crop_id`,
    [crop, q, S.academy],
  );
};

/** 정답·해설 위치·문제은행 연결이 모두 있는 문항. */
const completeCrop = async (opts, { answer = '③', pbAnswer = '3', kind = 'objective' } = {}) => {
  const crop = await seedCrop(t, S, opts);
  await setAnswer(crop, answer, kind);
  await setRef(crop);
  await linkQuestion(crop, pbAnswer, kind);
  return crop;
};

const insertFinding = async (crop, { base, proposal = null, axis = 'fidelity', errorType = 'answer_link' }) =>
  (await t.one(
    `insert into textbook_review_findings
       (academy_id, crop_id, stage, axis, error_type, severity, source, title, detail, proposal, base_fingerprint)
     values ($1::uuid, $2::uuid, 'compare', $3, $4, 'blocker', 'ai', '검수 항목', '근거', $5::jsonb, $6::jsonb)
     returning id`,
    [S.academy, crop, axis, errorType, proposal == null ? null : JSON.stringify(proposal), JSON.stringify(base)],
  )).id;

test('적재 확인은 빠진 정답·해설 위치·연결, 두 정답 불일치, 실제 파일끼리의 경로 충돌을 연다', async () => {
  const mid = 1;
  const ok = await completeCrop({ mid, number: '1' });
  const bare = await seedCrop(t, S, { mid, number: '2' });
  const mismatch = await completeCrop({ mid, number: '3' }, { answer: '④', pbAnswer: '③' });
  const dupA = await completeCrop({ mid, number: '4', storageKey: 'k/same.png', fileSize: 1200 });
  const dupB = await completeCrop({ mid, number: '4', subIndex: 1, storageKey: 'k/same.png', fileSize: 1300 });
  await completeCrop({ mid, number: '6', storageKey: 'k/placeholder.png' });
  await completeCrop({ mid, number: '6', subIndex: 1, storageKey: 'k/placeholder.png' });
  await seedCrop(t, S, { mid, number: '8~9', setHeader: true });

  const first = await refresh(mid);
  assert.equal(first.items, 7, '세트 머리는 문항으로 세지 않는다');
  assert.equal(first.opened, 6);
  assert.deepEqual(await findings(ok), [], '원문자와 숫자는 같은 정답으로 본다');
  assert.deepEqual(
    (await findings(bare)).map((f) => f.check_key).sort(),
    ['load:answer_missing', 'load:question_link_missing', 'load:solution_ref_missing'],
  );
  assert.deepEqual((await findings(mismatch)).map((f) => f.check_key), ['load:answer_mismatch']);
  assert.deepEqual((await findings(dupA)).map((f) => f.check_key), ['load:storage_collision']);
  assert.deepEqual((await findings(dupB)).map((f) => f.check_key), ['load:storage_collision']);

  const again = await refresh(mid);
  assert.equal(again.opened, 0, '다시 돌려도 같은 항목을 또 만들지 않는다');
  assert.equal(again.updated, 6);

  await setAnswer(bare, '12', 'subjective');
  const fixed = await refresh(mid);
  assert.equal(fixed.cleared, 1);
  const cleared = (await findings(bare)).find((f) => f.check_key === 'load:answer_missing');
  assert.deepEqual({ status: cleared.status, resolution: cleared.resolution }, { status: 'resolved', resolution: 'auto_cleared' });
  const run = await t.one(`select stage, status, summary from textbook_review_runs where id = $1::uuid`, [fixed.run_id]);
  assert.deepEqual({ stage: run.stage, status: run.status, cleared: run.summary.cleared }, { stage: 'load', status: 'done', cleared: 1 });
});

test('"문제 없음"으로 닫은 항목은 그 부분이 바뀌기 전까지 다시 열리지 않는다', async () => {
  const mid = 2;
  const crop = await completeCrop({ mid, number: '1' }, { answer: '④', pbAnswer: '③' });
  await refresh(mid);
  const [f] = await findings(crop);

  const res = await decide(f.id, 'dismiss', await fingerprint(crop), null, '문제은행 쪽이 옛 값');
  assert.equal(res.status, 'dismissed');

  const again = await refresh(mid);
  assert.deepEqual({ opened: again.opened, kept: again.kept_dismissed }, { opened: 0, kept: 1 });

  await setAnswer(crop, '⑤');
  const changed = await refresh(mid);
  assert.equal(changed.opened, 1, '정답이 바뀌면 다시 확인 대상이 된다');
  assert.deepEqual((await findings(crop)).map((x) => x.status), ['dismissed', 'open']);
});

const proposeTwelve = { target: 'answer', after: { answer_kind: 'subjective', answer_text: '12' }, reason: '정답지 3번 상자' };

const decisionOf = async (finding) => {
  const d = await t.one(
    `select action, target, before_value, after_value, note, decided_by from textbook_review_decisions where finding_id = $1::uuid`,
    [finding],
  );
  return { action: d.action, target: d.target, before: d.before_value.answer_text, after: d.after_value.answer_text, note: d.note, by: d.decided_by };
};

test('바뀌지 않은 제안은 그대로 반영하고, 사람이 고친 값으로 쓰고 이력을 남긴다', async () => {
  const mid = 9;
  const crop = await completeCrop({ mid, number: '1' }, { answer: '21', pbAnswer: '21', kind: 'subjective' });
  const fp = await fingerprint(crop);
  const finding = await insertFinding(crop, { base: { answer: fp.answer, problem: fp.problem }, proposal: proposeTwelve });

  const res = await decide(finding, 'apply_proposal', fp, null, '정답지 확인');
  assert.equal(res.status, 'resolved');
  assert.deepEqual(await answerOf(crop), { answer_kind: 'subjective', answer_text: '12', answer_source: 'manual' });
  assert.deepEqual(await decisionOf(finding), {
    action: 'apply_proposal', target: 'answer', before: '21', after: '12', note: '정답지 확인', by: S.staff,
  });
  const closed = await t.one(`select status, resolution from textbook_review_findings where id = $1::uuid`, [finding]);
  assert.deepEqual({ ...closed }, { status: 'resolved', resolution: 'applied' });

  assert.equal(await setAnswer(crop, '99', 'subjective'), undefined, 'VLM 저장은 그 행을 건너뛴다');
  assert.equal((await answerOf(crop)).answer_text, '12', '승인한 값은 VLM 재실행이 덮지 못한다');

  const after = await fingerprint(crop);
  await t.asMember(S.staff, () =>
    t.rejects(`select textbook_review_decide($1::uuid, 'dismiss', $2::jsonb)`, [finding, JSON.stringify(after)], /textbook_review_closed/));
});

test('본 뒤에 정답이 바뀌면 반영하지 않고, 다시 봐도 옛 값 기준 제안은 막으며 직접 고치기로만 쓴다', async () => {
  const mid = 3;
  const crop = await completeCrop({ mid, number: '1' }, { answer: '21', pbAnswer: '21', kind: 'subjective' });
  const base = await fingerprint(crop);
  const finding = await insertFinding(crop, { base: { answer: base.answer, problem: base.problem }, proposal: proposeTwelve });

  const shown = await fingerprint(crop);
  await setAnswer(crop, '13', 'subjective');

  await t.asMember(S.staff, () =>
    t.rejects(
      `select textbook_review_decide($1::uuid, 'apply_proposal', $2::jsonb)`,
      [finding, JSON.stringify(shown)],
      /textbook_review_stale/,
    ));
  assert.equal((await answerOf(crop)).answer_text, '13');
  const live = await t.one(`select status, stale_parts from textbook_review_findings_live where id = $1::uuid`, [finding]);
  assert.deepEqual({ status: live.status, stale: live.stale_parts }, { status: 'open', stale: ['answer'] });

  const now = await fingerprint(crop);
  await t.asMember(S.staff, () =>
    t.rejects(
      `select textbook_review_decide($1::uuid, 'apply_proposal', $2::jsonb)`,
      [finding, JSON.stringify(now)],
      /textbook_review_proposal_stale/,
    ));
  assert.equal((await answerOf(crop)).answer_text, '13', '옛 값 기준 제안은 다시 본 뒤에도 반영하지 않는다');

  const res = await decide(finding, 'manual_edit', now, proposeTwelve, '정답지 확인');
  assert.equal(res.status, 'resolved');
  assert.deepEqual(await answerOf(crop), { answer_kind: 'subjective', answer_text: '12', answer_source: 'manual' });
  assert.deepEqual(await decisionOf(finding), {
    action: 'manual_edit', target: 'answer', before: '13', after: '12', note: '정답지 확인', by: S.staff,
  });
  const closed = await t.one(`select status, resolution from textbook_review_findings where id = $1::uuid`, [finding]);
  assert.deepEqual({ ...closed }, { status: 'resolved', resolution: 'manual_edit' });
});

test('본 지문을 보내지 않거나 고칠 부분을 빠뜨리면 반영하지 않는다', async () => {
  const mid = 4;
  const crop = await completeCrop({ mid, number: '1' });
  const fp = await fingerprint(crop);
  const finding = await insertFinding(crop, { base: { problem: fp.problem } });

  await t.asMember(S.staff, async () => {
    await t.rejects(
      `select textbook_review_decide($1::uuid, 'hold', '{}'::jsonb)`,
      [finding],
      /textbook_review_expected_required/,
    );
    await t.rejects(
      `select textbook_review_decide($1::uuid, 'manual_edit', $2::jsonb, $3::jsonb)`,
      [finding, JSON.stringify({ problem: fp.problem }), JSON.stringify({ target: 'answer', after: { answer_text: '5' } })],
      /textbook_review_expected_required/,
    );
  });
  assert.equal((await answerOf(crop)).answer_text, '③');

  const held = await decide(finding, 'hold', { problem: fp.problem }, null, '원본 확인 후');
  assert.equal(held.status, 'held');
  const reopened = await decide(finding, 'reopen', null);
  assert.equal(reopened.status, 'open');
});

test('항목 없이 직접 고치기, 교정 의견, 보호 해제도 이력으로 남는다', async () => {
  const mid = 5;
  const crop = await completeCrop({ mid, number: '1' }, { answer: '18', pbAnswer: '18', kind: 'subjective' });

  const edited = await t.asMember(S.staff, async () =>
    (await t.one(
      `select textbook_review_edit($1::uuid, $2::jsonb, $3::jsonb, '원본 확인') as r`,
      [crop, JSON.stringify(await fingerprint(crop)), JSON.stringify({ target: 'answer', after: { answer_kind: 'subjective', answer_text: '2 \\times 3^2' } })],
    )).r);
  assert.equal(edited.ok, true);
  assert.deepEqual(await answerOf(crop), { answer_kind: 'subjective', answer_text: '2 \\times 3^2', answer_source: 'manual' });

  const fp = await fingerprint(crop);
  const finding = await insertFinding(crop, { base: { solution_ref: fp.solution_ref }, axis: 'validity', errorType: 'solution_logic' });
  const noted = await decide(finding, 'manual_edit', fp, {
    target: 'correction_note',
    after: { text: '해설 셋째 줄의 곱은 18 이어야 한다', about: 'solution' },
  });
  assert.equal(noted.status, 'resolved');
  assert.equal((await t.one(`select resolution from textbook_review_findings where id = $1::uuid`, [finding])).resolution, 'noted');
  assert.equal((await answerOf(crop)).answer_text, '2 \\times 3^2', '교정 의견은 데이터를 바꾸지 않는다');

  const released = await t.asMember(S.staff, async () =>
    (await t.one(`select textbook_review_release_manual($1::uuid, 'answer', '다시 VLM 으로') as r`, [crop])).r);
  assert.equal(released.released, true);
  await setAnswer(crop, '18', 'subjective');
  assert.deepEqual(await answerOf(crop), { answer_kind: 'subjective', answer_text: '18', answer_source: 'vlm' });

  const actions = (await t.all(
    `select action, target, finding_id is null as free from textbook_review_decisions where crop_id = $1::uuid order by decided_at`,
    [crop],
  )).map((r) => `${r.action}:${r.target}:${r.free ? '항목없음' : '항목'}`);
  assert.deepEqual(actions, ['manual_edit:answer:항목없음', 'manual_edit:correction_note:항목', 'release_manual:answer:항목없음']);
});

test('항목마다 그사이 바뀐 부분만 다시 확인 대상으로 보인다', async () => {
  const mid = 6;
  const crop = await completeCrop({ mid, number: '1' });
  const fp = await fingerprint(crop);
  const onAnswer = await insertFinding(crop, { base: { answer: fp.answer } });
  const onRef = await insertFinding(crop, { base: { solution_ref: fp.solution_ref } });

  await t.exec(`update textbook_problem_solution_refs set raw_page = 41 where crop_id = '${crop}'`);

  const live = Object.fromEntries(
    (await t.all(`select id, stale_parts from textbook_review_findings_live where crop_id = $1::uuid`, [crop]))
      .map((r) => [r.id, r.stale_parts]),
  );
  assert.deepEqual(live[onAnswer], []);
  assert.deepEqual(live[onRef], ['solution_ref']);
});

test('검수 탭 목록은 범위 문항과 축별 열린 항목 수를 돌려준다', async () => {
  const mid = 7;
  const done = await completeCrop({ mid, number: '1' });
  const bare = await seedCrop(t, S, { mid, number: '2' });
  await refresh(mid);

  const rows = await t.asMember(S.staff, () =>
    t.all(`select * from textbook_review_items($1::uuid, $2::uuid, '1-1', 0, 7)`, [S.academy, S.book]));
  assert.deepEqual(rows.map((r) => r.problem_number), ['1', '2']);
  const byId = Object.fromEntries(rows.map((r) => [r.crop_id, r]));
  assert.deepEqual(
    { open: byId[done].open_findings, answer: byId[done].answer_text, linked: Boolean(byId[done].pb_question_id) },
    { open: 0, answer: '③', linked: true },
  );
  assert.equal(byId[bare].open_findings, 3);
  assert.deepEqual(byId[bare].open_by_axis, { fidelity: 3 });
  assert.deepEqual(Object.keys(byId[bare].fingerprint).sort(), ['answer', 'crop', 'problem', 'solution_ref']);
});

test('학원 직원이 아니면 읽지도 실행하지도 못하고, 직원도 검수 표에 직접 쓰지 못한다', async () => {
  const mid = 8;
  const crop = await seedCrop(t, S, { mid, number: '1' });
  await refresh(mid);

  await t.asMember(S.outsider, async () => {
    await t.rejects(
      `select textbook_review_refresh_load_checks($1::uuid, $2::uuid, '1-1', 0, 8)`,
      [S.academy, S.book],
      /textbook_review_forbidden/,
    );
    await t.rejects(`select * from textbook_review_items($1::uuid, $2::uuid, '1-1', 0, 8)`, [S.academy, S.book], /textbook_review_forbidden/);
    assert.equal((await t.one(`select count(*)::int as n from textbook_review_findings`)).n, 0);
    assert.equal((await t.one(`select count(*)::int as n from textbook_review_findings_live`)).n, 0);
    assert.equal((await t.one(`select count(*)::int as n from textbook_review_decisions`)).n, 0);
  });

  await t.asMember(S.staff, async () => {
    assert.equal((await t.one(`select count(*)::int as n from textbook_review_findings where crop_id = $1::uuid`, [crop])).n, 3);
    await t.rejects(
      `insert into textbook_review_findings (academy_id, crop_id, stage, axis, error_type, source, title)
       values ($1::uuid, $2::uuid, 'load', 'fidelity', 'other', 'owner', 'x')`,
      [S.academy, crop],
      /permission denied/,
    );
    await t.rejects(`update textbook_review_findings set status = 'resolved' where crop_id = $1::uuid`, [crop], /permission denied/);
    await t.rejects(`delete from textbook_review_decisions`, [], /permission denied/);
    await t.rejects(`select textbook_review_apply_change($1::uuid, $2::uuid, '{}'::jsonb)`, [crop, S.academy], /permission denied/);
  });

  await t.asAnon(async () => {
    await t.rejects(`select count(*) from textbook_review_findings`, [], /permission denied/);
    await t.rejects(
      `select textbook_review_refresh_load_checks($1::uuid, $2::uuid, '1-1', 0, 8)`,
      [S.academy, S.book],
      /permission denied/,
    );
  });
});

test('학생 쪽 코드(학생 Edge Function, 학생 앱)는 검수 표·함수를 읽지 않는다', () => {
  const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
  const fnRoot = join(repo, 'supabase', 'functions');
  const roots = [
    ...readdirSync(fnRoot).filter((d) => d.startsWith('student_')).map((d) => join(fnRoot, d)),
    join(repo, 'apps', 'yggdrasill_student', 'lib'),
  ];
  const hits = [];
  const walk = (dir) => {
    for (const name of readdirSync(dir)) {
      const full = join(dir, name);
      if (statSync(full).isDirectory()) walk(full);
      else if (/\.(ts|js|mjs|dart)$/.test(name) && readFileSync(full, 'utf8').includes('textbook_review')) hits.push(full);
    }
  };
  roots.forEach(walk);
  assert.ok(roots.length >= 3, '학생 함수 폴더를 찾지 못했다');
  assert.deepEqual(hits, []);
});
