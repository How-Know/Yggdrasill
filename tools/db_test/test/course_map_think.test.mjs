// 개념 배치(기준 단원 ↔ 개념)와 Think 승인 카드: 배치는 RPC로만 들어가고 탐색도를 따라 글 칸이 바뀐다.
// 카드는 제안만으로 아무것도 바꾸지 않고, 운영자 승인 때 항목별로 반영된다. 붙은 것이 있는 개념은 지우지 않는다.
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { insertConcept, openConceptTestDb, seedConcepts } from '../concept_fixture.mjs';

let t;
let S;
let conv;

before(async () => {
  t = await openConceptTestDb();
  S = await seedConcepts(t);
  conv = (await t.one(`insert into ai_conversations (title) values ('과정 탐색도 정리') returning id`)).id;
});
after(() => t?.close());

const op = (sql, params = []) => t.asSuperadmin(() => t.one(sql, params), S.operator);
const opAll = (sql, params = []) => t.asSuperadmin(() => t.all(sql, params), S.operator);
const opRejects = (sql, params, pattern) => t.asSuperadmin(() => t.rejects(sql, params, pattern), S.operator);
const arr = (ids) => `{${ids.join(',')}}`;

const courseByName = async (name) => (await op(`select course_maps_list() as r`)).r.find((c) => c.name === name);
const getMap = async (id) => (await op(`select course_map_get($1::uuid) as r`, [id])).r;
const placements = async (courseId) => (await op(`select course_map_placements($1::uuid) as r`, [courseId])).r;
const add = async (unitId, conceptIds) =>
  (await op(`select course_placement_add($1::uuid, $2::uuid[]) as r`, [unitId, arr(conceptIds)])).r;
const rowOf = (id) =>
  op(
    `select concept_id, course_unit_id, unit_sort_order, origin, note, school_level, course_label, curriculum_code, unit_path
       from concept_appearances where id = $1::uuid`,
    [id],
  );
const saveMap = async (map, units, archive = [], course = {}) =>
  (await op(`select course_map_save($1::uuid, $2::int, $3::jsonb, $4::jsonb, $5::uuid[]) as r`, [
    map.course.id,
    map.course.version,
    JSON.stringify(course),
    JSON.stringify(units.map((u) => ({ id: u.id, parent_id: u.parent_id, name: u.name }))),
    arr(archive),
  ])).r;

const PROPOSE = `select * from course_think_action_propose($1::uuid, $2, $3::jsonb)`;
const propose = (kind, payload) => op(PROPOSE, [conv, kind, JSON.stringify(payload)]);
const proposeRejects = (kind, payload, pattern) => opRejects(PROPOSE, [conv, kind, JSON.stringify(payload)], pattern);
const APPLY = `select * from course_think_action_apply($1::uuid, $2::jsonb)`;
const apply = (id, overrides = {}) => op(APPLY, [id, JSON.stringify(overrides)]);
const statusOf = async (id) => (await t.one(`select status, superseded from ai_actions where id = $1::uuid`, [id]));

// 과정 하나의 단원을 깊이별로 고른다: 첫 대단원 L1, 그 첫 중단원 M1, 그 첫 소단원 S1, 둘째 대단원의 첫 중단원 M2.
async function pick(name) {
  const course = await courseByName(name);
  const map = await getMap(course.id);
  const kids = (id) => map.units.filter((u) => u.parent_id === id);
  const roots = kids(null);
  const L1 = roots[0];
  const M1 = kids(L1.id)[0];
  const S1 = kids(M1.id)[0];
  const S2 = kids(M1.id)[1];
  const M2 = kids(roots[1].id)[0];
  return { course, map, L1, M1, S1, S2, M2, leaves: map.units.filter((u) => u.depth === 3) };
}

test('기준 단원 줄은 RPC로만 들어가고, 글 칸은 탐색도에서 채워지며 과정을 고치면 따라 바뀐다', async () => {
  const P = await pick('1-1');
  await opRejects(
    `insert into concept_appearances (concept_id, school_level, course_label, course_unit_id, unit_sort_order)
     values ($1::uuid, '중', '1-1', $2::uuid, 0)`,
    [S.concept, P.S1.id],
    /course_placement_use_rpc/,
  );
  await t.asUser(() =>
    t.rejects(`select course_placement_add($1::uuid, $2::uuid[])`, [P.S1.id, arr([S.concept])], /course_map_forbidden/));

  const list = await add(P.S1.id, [S.concept, S.concept2, S.concept]);
  const here = list.filter((p) => p.unit_id === P.S1.id);
  assert.deepEqual(here.map((p) => [p.concept_id, p.sort, p.origin]), [
    [S.concept, 0, 'owner'],
    [S.concept2, 1, 'owner'],
  ]);
  const row = await rowOf(here[0].id);
  assert.equal(row.school_level, '중');
  assert.equal(row.course_label, '1-1');
  assert.deepEqual(row.unit_path, [P.L1.name, P.M1.name, P.S1.name]);
  await opRejects(`select course_placement_add($1::uuid, $2::uuid[])`, [P.S1.id, arr([S.concept])], /course_placement_exists/);

  // 같은 글로 적은 등장 위치는 따로 남는다(기준 단원 줄과 겹침 검사가 다르다).
  await op(
    `insert into concept_appearances (concept_id, school_level, course_label, unit_path)
     values ($1::uuid, '중', '1-1', $2::text[]) returning id`,
    [S.concept, `{${[P.L1.name, P.M1.name, P.S1.name].map((x) => `"${x}"`).join(',')}}`],
  );

  const units = P.map.units.map((u) => (u.id === P.M1.id ? { ...u, name: '이름 바꾼 중단원' } : u));
  await saveMap(P.map, units, [], { name: '중1-1', curriculum_code: 'rev_2022' });
  const moved = await rowOf(here[0].id);
  assert.deepEqual(moved.unit_path, [P.L1.name, '이름 바꾼 중단원', P.S1.name]);
  assert.equal(moved.course_label, '중1-1');
  assert.equal(moved.curriculum_code, 'rev_2022');
  const text = await op(
    `select course_label, unit_path from concept_appearances where concept_id = $1::uuid and course_unit_id is null`,
    [S.concept],
  );
  assert.equal(text.course_label, '1-1', '글로 적은 등장 위치는 그대로다');
  const back = await getMap(P.course.id);
  await saveMap(back, back.units.map((u) => (u.id === P.M1.id ? { ...u, name: P.M1.name } : u)), [], { name: '1-1' });
});

test('운영자 직접: 옮기기·순서·빼기, 어긋난 순서 목록은 막고, 보관한 단원의 배치는 남는다', async () => {
  const P = await pick('1-2');
  const a = await insertConcept(t, '배치 가', S.folder);
  const b = await insertConcept(t, '배치 나', S.folder);
  const c = await insertConcept(t, '배치 다', S.folder);
  let list = await add(P.S1.id, [a, b, c]);
  const ids = list.filter((p) => p.unit_id === P.S1.id).map((p) => p.id);

  await opRejects(`select course_placement_reorder($1::uuid, $2::uuid[])`, [P.S1.id, arr([ids[2], ids[0]])], /course_placement_stale/);
  list = (await op(`select course_placement_reorder($1::uuid, $2::uuid[]) as r`, [P.S1.id, arr([ids[2], ids[0], ids[1]])])).r;
  assert.deepEqual(list.filter((p) => p.unit_id === P.S1.id).map((p) => p.id), [ids[2], ids[0], ids[1]]);

  await opRejects(`select course_placement_move($1::uuid, $2::uuid)`, [ids[0], P.S1.id], /course_placement_same_unit/);
  list = (await op(`select course_placement_move($1::uuid, $2::uuid) as r`, [ids[0], P.S2.id])).r;
  assert.deepEqual(list.filter((p) => p.unit_id === P.S1.id).map((p) => [p.id, p.sort]), [[ids[2], 0], [ids[1], 1]]);
  assert.equal(list.find((p) => p.id === ids[0]).unit_id, P.S2.id);

  list = (await op(`select course_placement_remove($1::uuid) as r`, [ids[2]])).r;
  assert.deepEqual(list.filter((p) => p.unit_id === P.S1.id).map((p) => [p.id, p.sort]), [[ids[1], 0]]);

  await saveMap(P.map, P.map.units.filter((u) => u.parent_id !== P.M1.id && u.id !== P.M1.id), [P.M1.id]);
  assert.equal((await placements(P.course.id)).length, 0, '보관한 단원의 배치는 목록에서 빠진다');
  assert.equal((await t.one(`select count(*)::int as n from concept_appearances where id = any($1::uuid[])`, [arr([ids[0], ids[1]])])).n, 2);
  await opRejects(`select course_placement_add($1::uuid, $2::uuid[])`, [P.S1.id, arr([c])], /course_placement_unit_not_found/);
  await op(`delete from concept_appearances where id = $1::uuid returning id`, [ids[1]]);
});

test('후보: 출처 학년이 과정 키로 읽히는 개념, 출처 없는 개념, 놓으면 후보에서 빠진다', async () => {
  const P = await pick('2-1');
  const sourced = await insertConcept(t, '일차함수(후보)', S.folder);
  const bare = await insertConcept(t, '출처 없는 개념(후보)', S.folder);
  await t.exec(`insert into concept_sources (concept_id, academy_id, book_id, grade_label, raw_page, unit_path)
                values ('${sourced}', '${S.academy}', '${S.book}', '중2-1', 52, '{"Ⅲ. 일차함수","1. 일차함수와 그래프"}')`);
  const cand = async (mode, q = null) =>
    (await op(`select concept_placement_candidates($1::uuid, $2, $3, 0, 50) as r`, [P.course.id, mode, q])).r;

  let r = await cand('course_sources');
  assert.deepEqual(r.items.map((x) => x.id), [sourced]);
  assert.equal(r.items[0].sources[0].course_key, 'M2-1');
  assert.deepEqual(r.items[0].sources[0].unit_path, ['Ⅲ. 일차함수', '1. 일차함수와 그래프']);
  assert.equal(r.items[0].sources[0].book, '개념+유형 중1-1');
  assert.ok((await cand('no_source')).items.some((x) => x.id === bare));
  assert.ok(!(await cand('no_source')).items.some((x) => x.id === sourced));
  assert.deepEqual((await cand('search', '후보')).items.map((x) => x.name).sort(), ['일차함수(후보)', '출처 없는 개념(후보)']);
  await opRejects(`select concept_placement_candidates($1::uuid, 'search', null, 0, 10)`, [P.course.id], /course_placement_bad_query/);

  await add(P.S1.id, [sourced]);
  r = await cand('course_sources');
  assert.equal(r.total, 0);
  const detail = (await op(`select concept_think_detail($1::uuid) as r`, [sourced])).r;
  assert.equal(detail.attached.sources, 1);
  assert.equal(detail.attached.placements, 1);
  assert.equal(detail.placements[0].path.startsWith('2-1 › '), true);
  const overview = (await op(`select concept_placement_overview() as r`)).r;
  assert.ok(overview.placed >= 1 && overview.concepts >= overview.placed);
});

test('단원 바꾸기 카드: 제안은 시험 저장 뒤 되돌리고, 승인하면 한 번에 바뀐다', async () => {
  const P = await pick('2-2');
  const pl = (await add(P.S1.id, [S.concept])).find((p) => p.unit_id === P.S1.id);
  const before = (await courseByName('2-2')).version;
  const ops = [
    { op: 'add', key: 'n1', parent: P.L1.id, position: 'first', after: null, name: 'Think 중단원' },
    { op: 'add', key: 'n2', parent: 'n1', position: 'last', after: null, name: 'Think 소단원' },
    { op: 'rename', unit: P.S1.id, name: '바뀐 소단원' },
    { op: 'move', unit: P.S1.id, parent: 'n1', position: 'after', after: 'n2' },
    { op: 'archive', unit: P.M2.id },
    { op: 'course', name: null, school_level: null, curriculum_code: 'rev_2015' },
  ];
  const act = await propose('course_map_change', { course_id: P.course.id, ops, reason: '단원 정리' });
  assert.equal(act.status, 'proposed');
  assert.equal(act.preview.lines.length, 6);
  assert.match(act.preview.lines[3].text, /옮기기 · .* → .*Think 중단원 › 바뀐 소단원/);
  assert.equal((await courseByName('2-2')).version, before, '제안은 과정을 바꾸지 않는다');
  assert.equal((await getMap(P.course.id)).units.length, P.map.units.length);

  const done = await apply(act.id);
  assert.equal(done.status, 'applied');
  const map = await getMap(P.course.id);
  const n1 = map.units.find((u) => u.id === act.payload.keys.n1);
  const n2 = map.units.find((u) => u.id === act.payload.keys.n2);
  assert.deepEqual([n1.parent_id, n1.depth, n1.sort_order, n1.name], [P.L1.id, 2, 0, 'Think 중단원']);
  assert.deepEqual([n2.parent_id, n2.sort_order], [n1.id, 0]);
  const s1 = map.units.find((u) => u.id === P.S1.id);
  assert.deepEqual([s1.parent_id, s1.sort_order, s1.name], [n1.id, 1, '바뀐 소단원']);
  assert.ok(!map.units.some((u) => u.id === P.M2.id));
  assert.equal(map.course.curriculum_code, 'rev_2015');
  const row = await rowOf(pl.id);
  assert.deepEqual(row.unit_path, [P.L1.name, 'Think 중단원', '바뀐 소단원']);
  assert.equal(row.curriculum_code, 'rev_2015');
});

test('단원 바꾸기 카드: 막히는 바꾸기는 몇 번째인지 알려 주고, 같은 과정 새 제안이 대체하며, 그사이 바뀌면 막는다', async () => {
  const P = await pick('3-1');
  await proposeRejects('course_map_change', {
    course_id: P.course.id, reason: 'x', ops: [{ op: 'move', unit: P.L1.id, parent: P.M1.id }],
  }, /course_think_cycle:1/);
  await proposeRejects('course_map_change', {
    course_id: P.course.id, reason: 'x', ops: [{ op: 'rename', unit: P.S1.id, name: '가' }, { op: 'add', key: 'k', parent: P.S1.id, name: '너무 깊음' }],
  }, /course_think_too_deep:2/);
  await proposeRejects('course_map_change', {
    course_id: P.course.id, reason: 'x', ops: [{ op: 'rename', unit: '00000000-0000-4000-8000-000000000999', name: '가' }],
  }, /course_think_unit_not_found:1/);
  await proposeRejects('course_map_change', { course_id: P.course.id, reason: '', ops: [] }, /course_think_reason_required/);

  const first = await propose('course_map_change', {
    course_id: P.course.id, reason: '첫 제안', ops: [{ op: 'rename', unit: P.S1.id, name: '첫 이름' }],
  });
  const second = await propose('course_map_change', {
    course_id: P.course.id, reason: '두 번째', ops: [{ op: 'rename', unit: P.S1.id, name: '둘째 이름' }],
  });
  assert.deepEqual(await statusOf(first.id), { status: 'rejected', superseded: true });
  await saveMap(P.map, P.map.units.map((u) => (u.id === P.S2.id ? { ...u, name: '운영자가 먼저 고침' } : u)));
  await opRejects(APPLY, [second.id, '{}'], /course_map_stale/);
  assert.equal((await statusOf(second.id)).status, 'proposed');
});

test('새 과정 카드: 제안은 과정을 만들지 않고, 승인하면 단원과 함께 생긴다', async () => {
  await proposeRejects('course_map_create', { name: '1-1', school_level: '중', curriculum_code: null, units: [], reason: 'x' },
    /course_think_course_exists/);
  await proposeRejects('course_map_create', {
    name: '수학Ⅰ', school_level: '고', curriculum_code: 'rev_2015', reason: 'x',
    units: [{ key: 'a', parent_key: null, name: '지수' }, { key: 'b', parent_key: 'zz', name: '고아' }],
  }, /course_think_unit_not_found:2/);
  const count = (await op(`select count(*)::int as n from course_maps`)).n;
  const act = await propose('course_map_create', {
    name: '수학Ⅰ', school_level: '고', curriculum_code: 'rev_2015', reason: '2015 과정 추가',
    units: [
      { key: 'a', parent_key: null, name: '지수함수와 로그함수' },
      { key: 'b', parent_key: null, name: '삼각함수' },
      { key: 'a1', parent_key: 'a', name: '지수와 로그' },
      { key: 'a1x', parent_key: 'a1', name: '거듭제곱근' },
    ],
  });
  assert.deepEqual(act.preview.units.map((u) => [u.depth, u.name]), [
    [1, '지수함수와 로그함수'], [2, '지수와 로그'], [3, '거듭제곱근'], [1, '삼각함수'],
  ]);
  assert.deepEqual(act.preview.counts, [2, 1, 1]);
  assert.equal((await op(`select count(*)::int as n from course_maps`)).n, count);
  const done = await apply(act.id);
  const map = await getMap(done.result.course_id);
  assert.equal(map.course.name, '수학Ⅰ');
  assert.deepEqual(map.units.map((u) => [u.id, u.name]), [
    [act.payload.keys.a, '지수함수와 로그함수'],
    [act.payload.keys.a1, '지수와 로그'],
    [act.payload.keys.a1x, '거듭제곱근'],
    [act.payload.keys.b, '삼각함수'],
  ]);
});

test('배치 카드: 출처 근거 확인, 항목 오류 번호, 승인 때 빼기·단원 바꾸기와 항목별 결과', async () => {
  const P = await pick('3-2');
  const src = await insertConcept(t, '원의 성질(배치)', S.folder);
  const plain = await insertConcept(t, '접선(배치)', S.folder);
  const third = await insertConcept(t, '할선(배치)', S.folder);
  await t.exec(`insert into concept_sources (concept_id, academy_id, book_id, grade_label, raw_page)
                values ('${src}', '${S.academy}', '${S.book}', '3-2', 80)`);
  const [A, B, C, D] = P.leaves;

  await proposeRejects('concept_placement_change', {
    course_id: P.course.id, reason: 'x',
    items: [
      { op: 'place', concept_id: src, unit_id: A.id, basis: 'source', evidence: '교재 3-2 80쪽' },
      { op: 'place', concept_id: plain, unit_id: A.id, basis: 'source', evidence: '출처 없음' },
    ],
  }, /course_placement_bad_item:2:course_placement_no_source/);
  await proposeRejects('concept_placement_change', {
    course_id: P.course.id, reason: 'x',
    items: [{ op: 'place', concept_id: src, unit_id: (await pick('1-1')).S1.id, basis: 'judgment', evidence: '다른 과정' }],
  }, /course_placement_bad_item:1:course_placement_unit_foreign/);

  const act = await propose('concept_placement_change', {
    course_id: P.course.id, reason: '3-2 원 단원 배치',
    items: [
      { op: 'place', concept_id: src, unit_id: A.id, basis: 'source', evidence: '교재 3-2 80쪽 원의 성질' },
      { op: 'place', concept_id: plain, unit_id: B.id, basis: 'judgment', evidence: '이름으로 판단' },
      { op: 'place', concept_id: third, unit_id: C.id, basis: 'judgment', evidence: '이름으로 판단' },
    ],
  });
  assert.equal(act.preview.judgment, 2);
  assert.equal(act.preview.units.length, P.map.units.length);
  assert.equal(act.preview.items[0].unit_path, [P.L1.name, P.M1.name, A.name].join(' › '));
  assert.equal((await placements(P.course.id)).length, 0, '제안만으로는 놓이지 않는다');

  await opRejects(APPLY, [act.id, JSON.stringify({ skip: [1, 2, 3] })], /course_think_nothing_selected/);
  const done = await apply(act.id, { skip: [3], units: { 2: D.id } });
  assert.deepEqual(done.result.items.map((x) => x.status), ['applied', 'applied', 'skipped']);
  const list = await placements(P.course.id);
  assert.deepEqual(list.map((p) => [p.concept_id, p.unit_id, p.origin]).sort(), [
    [src, A.id, 'ai'], [plain, D.id, 'ai'],
  ].sort());
  assert.equal(list.find((p) => p.concept_id === src).note, '교재 3-2 80쪽 원의 성질');

  // 승인 때 이미 놓였으면 그 항목만 실패한다. 모두 실패하면 카드는 기다리는 채로 남는다.
  const again = await propose('concept_placement_change', {
    course_id: P.course.id, reason: '할선',
    items: [{ op: 'place', concept_id: third, unit_id: C.id, basis: 'judgment', evidence: '판단' }],
  });
  await add(C.id, [third]);
  const failedPlace = await apply(again.id);
  assert.equal(failedPlace.status, 'proposed');
  assert.match(failedPlace.error, /course_think_all_failed:course_placement_exists/);
  assert.equal(failedPlace.result.attempt_failed, true);
  assert.equal((await statusOf(again.id)).status, 'proposed');

  const ids = (await placements(P.course.id)).filter((p) => p.unit_id === C.id).map((p) => p.id);
  await proposeRejects('concept_placement_change', {
    course_id: P.course.id, reason: 'x',
    items: [
      { op: 'reorder', unit_id: C.id, placement_ids: ids },
      { op: 'place', concept_id: src, unit_id: C.id, basis: 'judgment', evidence: '판단' },
    ],
  }, /course_placement_reorder_mixed/);
  const mv = await propose('concept_placement_change', {
    course_id: P.course.id, reason: '옮기기',
    items: [
      { op: 'move', placement_id: list.find((p) => p.concept_id === plain).id, unit_id: B.id, evidence: '접선은 B' },
      { op: 'remove', placement_id: ids[0], evidence: '잘못 놓음' },
    ],
  });
  await apply(mv.id);
  const after = await placements(P.course.id);
  assert.equal(after.find((p) => p.concept_id === plain).unit_id, B.id);
  assert.ok(!after.some((p) => p.id === ids[0]));
});

test('개념 카드: 만들기·고치기·서술 고치기는 승인 때 바로 확정되고 기록이 남는다', async () => {
  const P = await pick('1-1');
  const target = await insertConcept(t, '서로소(고치기)', S.folder, '공약수가 1뿐인 두 수');
  const draftHeld = await insertConcept(t, '수정안 있는 개념', S.folder, '본문');
  await t.exec(`insert into concept_content_drafts (concept_id, content, base_md5, origin, saved_at)
                values ('${draftHeld}', '운영자 수정안', md5('본문'), 'owner', now())`);
  const st = (await op(`select concept_statement_create($1::uuid, 'statement', $2::jsonb) as r`, [
    target, JSON.stringify({ title: '서술 1', body: '정리한 글', basis: 'organized' }),
  ])).r;
  const conf = (await op(`select concept_statement_confirm($1::uuid, 0, $2::timestamptz, '처음') as r`, [st.id, st.draft_saved_at])).r;
  assert.equal(conf.version, 1);

  await proposeRejects('concept_library_change', {
    reason: 'x', items: [{ op: 'edit', concept_id: draftHeld, name: null, content: '새 본문', type: null, folder: null }],
  }, /concept_think_bad_item:1:concept_content_draft_pending/);
  await proposeRejects('concept_library_change', {
    reason: 'x', items: [{ op: 'statement', statement_id: st.id, content: { title: '서술 1', body: '바꾼 글', basis: 'verbatim' } }],
  }, /concept_think_bad_item:1:concept_think_verbatim/);
  await proposeRejects('concept_library_change', {
    reason: 'x', items: [{ op: 'statement', statement_id: st.id, content: { quote: '교재 문장' } }],
  }, /concept_think_bad_item:1:concept_think_source_field/);
  await proposeRejects('concept_library_change', {
    reason: 'x', items: [{ op: 'create', name: '새 개념', type: '없는 유형', folder: ['소인수분해', '가'], content: '본문' }],
  }, /concept_think_bad_item:1:concept_think_unknown_type/);

  const act = await propose('concept_library_change', {
    reason: '교재 정리 반영',
    items: [
      {
        op: 'create', name: '서로소(Think)', type: '정의', folder: ['소인수분해', 'Think 폴더'],
        content: '최대공약수가 1인 두 자연수', place_unit_id: P.S1.id, evidence: '1-1 소인수분해 단원',
      },
      { op: 'edit', concept_id: target, name: '서로소', content: '최대공약수가 1인 두 자연수의 관계', type: '성질', folder: null },
      { op: 'statement', statement_id: st.id, content: { body: '다듬은 글' } },
    ],
  });
  assert.equal(act.preview.items[0].new_from, 2);
  assert.deepEqual(act.preview.items[1].before, { name: '서로소(고치기)', content: '공약수가 1뿐인 두 수', type: null });
  assert.equal(await op(`select content from concepts where id = $1::uuid`, [target]).then((r) => r.content), '공약수가 1뿐인 두 수');

  const done = await apply(act.id);
  assert.deepEqual(done.result.items.map((x) => x.status), ['applied', 'applied', 'applied']);
  const made = done.result.items[0].concept_id;
  const madeRow = await t.one(
    `select c.name, c.kind, c.sub_type, t.name as type, concept_folder_path(c.main_category_id) as folder
       from concepts c join concept_type_links l on l.concept_id = c.id join concept_types t on t.id = l.type_id
      where c.id = $1::uuid`,
    [made],
  );
  assert.deepEqual(madeRow, { name: '서로소(Think)', kind: 'definition', sub_type: '정의', type: '정의', folder: ['소인수분해', 'Think 폴더'] });
  const placed = await rowOf(done.result.items[0].placement_id);
  assert.deepEqual([placed.concept_id, placed.course_unit_id, placed.origin], [made, P.S1.id, 'ai']);

  const edited = await op(`select name, content, kind, sub_type from concepts where id = $1::uuid`, [target]);
  assert.deepEqual(edited, { name: '서로소', content: '최대공약수가 1인 두 자연수의 관계', kind: 'theorem', sub_type: '정리' });
  const rev = await op(
    `select name, content, via, note, draft_origin from concept_content_revisions where concept_id = $1::uuid`,
    [target],
  );
  assert.deepEqual(rev, {
    name: '서로소(고치기)', content: '공약수가 1뿐인 두 수', via: 'draft', note: 'Think 카드 승인: 교재 정리 반영', draft_origin: 'ai',
  });
  const stRow = await op(`select version, content, draft from concept_statements where id = $1::uuid`, [st.id]);
  assert.equal(stRow.version, 2);
  assert.equal(stRow.content.body, '다듬은 글');
  assert.equal(stRow.content.title, '서술 1');
  assert.equal(stRow.draft, null);
  assert.equal(
    (await op(`select note from concept_statement_revisions where statement_id = $1::uuid and version = 2`, [st.id])).note,
    'Think 카드 승인: 교재 정리 반영',
  );
});

test('개념 카드: 붙은 것이 있는 개념은 지우지 않고, 그사이 바뀐 개념은 고치지 않는다', async () => {
  const bare = await insertConcept(t, '빈 개념(지우기)', S.folder);
  const attached = await insertConcept(t, '출처 붙은 개념(지우기)', S.folder);
  await t.exec(`insert into concept_sources (concept_id, academy_id, book_id, grade_label, raw_page)
                values ('${attached}', '${S.academy}', '${S.book}', '1-1', 12)`);
  const act = await propose('concept_library_change', {
    reason: '쓰지 않는 개념 정리',
    items: [{ op: 'delete', concept_id: bare }, { op: 'delete', concept_id: attached }],
  });
  assert.equal(act.preview.blocked, 1);
  assert.equal(act.preview.items[1].blocked, true);
  assert.equal(act.preview.items[1].attached.sources, 1);
  const done = await apply(act.id);
  assert.deepEqual(done.result.items.map((x) => [x.status, x.code ?? null]), [
    ['applied', null], ['failed', 'concept_delete_attached'],
  ]);
  assert.equal(done.result.items[0].deleted.name, '빈 개념(지우기)');
  assert.equal((await t.one(`select count(*)::int as n from concepts where id = $1::uuid`, [bare])).n, 0);
  assert.equal((await t.one(`select count(*)::int as n from concepts where id = $1::uuid`, [attached])).n, 1);

  const target = await insertConcept(t, '그사이 바뀜', S.folder, '처음 본문');
  const edit = await propose('concept_library_change', {
    reason: 'x', items: [{ op: 'edit', concept_id: target, name: null, content: 'Think 본문', type: null, folder: null }],
  });
  await t.exec(`update concepts set content = '운영자가 고침' where id = '${target}'`);
  const failedEdit = await apply(edit.id);
  assert.equal(failedEdit.status, 'proposed');
  assert.match(failedEdit.error, /course_think_all_failed:concept_think_stale/);
  assert.equal(failedEdit.result.attempt_failed, true);
  assert.equal((await t.one(`select content from concepts where id = $1::uuid`, [target])).content, '운영자가 고침');
  await t.exec(`update concepts set content = '처음 본문' where id = '${target}'`);
  const retriedEdit = await apply(edit.id);
  assert.equal(retriedEdit.status, 'applied');
  assert.equal(retriedEdit.error, null);
  assert.equal((await t.one(`select content from concepts where id = $1::uuid`, [target])).content, 'Think 본문');
});

test('권한과 기능 확인', async () => {
  const P = await pick('1-1');
  await t.asUser(() =>
    t.rejects(PROPOSE, [conv, 'concept_placement_change', JSON.stringify({ course_id: P.course.id, items: [], reason: 'x' })], /forbidden/));
  await t.asAnon(() => t.rejects(`select course_map_placements($1::uuid)`, [P.course.id], /permission denied/));
  await t.asUser(() => t.rejects(`select course_think_ops_run(null::course_maps, '[]'::jsonb, '{}'::jsonb)`, [], /permission denied/));
  await proposeRejects('code_request', { reason: 'x' }, /action_kind_not_appliable/);
  const features = (await op(`select ai_think_db_features() as r`)).r;
  assert.equal(features.course_map_actions, 1);
  const rows = await opAll(`select kind from ai_actions where conversation_id = $1::uuid`, [conv]);
  assert.ok(rows.length > 0);
});

const sourceWalk = async (courseId, scope, offset = 0, limit = 60) =>
  (await op(`select concept_review_source_walk($1::uuid, $2::text, $3::int, $4::int) as r`, [courseId, scope, offset, limit])).r;
const sourceRejects = (courseId, scope, pattern) =>
  opRejects(`select concept_review_source_walk($1::uuid, $2::text, 0, 40)`, [courseId, scope], pattern);
const addSource = (conceptId, grade, page = 10) => t.exec(
  `insert into concept_sources (concept_id, academy_id, book_id, grade_label, raw_page)
   values ('${conceptId}', '${S.academy}', '${S.book}', '${grade}', ${page})`,
);
const walkCount = async () => (await t.one(`select count(*)::int as n from concept_review_walks`)).n;
const storedIds = async (walkId) =>
  (await t.one(`select to_jsonb(concept_ids) as ids from concept_review_walks where id = $1::uuid`, [walkId])).ids;

test('출처 검수 목록: 전체는 배치된 개념을 포함하고, 미배치는 후보와 같은 집합·순서이며, 중복·다른 과정·null 정렬을 가른다', async () => {
  const geo = await pick('기하');
  const alg = await pick('대수');
  const tag = randomUUID().slice(0, 8);
  const root = (await t.one(`insert into concept_categories (name) values ($1) returning id`, [`출처고정 ${tag}`])).id;
  const child = (await t.one(
    `insert into concept_categories (name, parent_id) values ($1, $2::uuid) returning id`,
    [`하위 ${tag}`, root],
  )).id;
  const b = await insertConcept(t, `b-동률 ${tag}`, root);
  const c = await insertConcept(t, `c-동률 ${tag}`, root);
  const z = await insertConcept(t, `z-앞 ${tag}`, root);
  const nil = await insertConcept(t, `a-널 ${tag}`, root);
  const nested = await insertConcept(t, `자식 ${tag}`, child);
  const placedHere = await insertConcept(t, `이과정배치 ${tag}`, root);
  const otherOnly = await insertConcept(t, `다른과정만 ${tag}`, root);
  const bare = await insertConcept(t, `출처없음 ${tag}`, root);
  const algebraOnly = await insertConcept(t, `대수출처 ${tag}`, root);
  await t.exec(`update concepts set sort_order = 0 where id in ('${b}', '${c}', '${z}', '${nested}')`);
  await t.exec(`update concepts set sort_order = 1 where id = '${placedHere}'`);
  await t.exec(`update concepts set sort_order = 2 where id = '${otherOnly}'`);
  await t.exec(`update concepts set sort_order = null where id = '${nil}'`);
  for (const id of [b, c, z, nil, nested, placedHere, otherOnly]) await addSource(id, '기하');
  // 같은 개념·책·학년·쪽은 concept_sources_statement_page_unique 에 걸린다. 쪽만 다른 두 번째 출처로 중복 제거를 본다.
  await addSource(b, '기하', 11);
  await addSource(algebraOnly, '대수');
  await add(geo.S1.id, [placedHere]);
  await add(alg.S1.id, [otherOnly]);

  const all = await sourceWalk(geo.course.id, 'all');
  const unplaced = await sourceWalk(geo.course.id, 'course_unplaced');
  const cand = (await op(
    `select concept_placement_candidates($1::uuid, 'course_sources', null, 0, 50) as r`,
    [geo.course.id],
  )).r;
  const allIds = [b, c, z, placedHere, otherOnly, nil, nested];
  const unplacedIds = [b, c, z, otherOnly, nil, nested];
  assert.deepEqual(all.items.map((i) => i.id), allIds, 'sort 0 동률은 이름 순, null sort는 0으로 합치지 않고 뒤, 하위 폴더는 그다음');
  assert.equal(all.items.filter((i) => i.id === b).length, 1, '출처가 두 개여도 id는 하나');
  assert.deepEqual(unplaced.items.map((i) => i.id), unplacedIds);
  assert.deepEqual(cand.items.map((i) => i.id), unplacedIds, 'course_unplaced는 course_sources 후보와 같은 집합·순서');
  assert.equal(cand.total, unplacedIds.length);
  assert.ok(allIds.includes(placedHere) && !unplacedIds.includes(placedHere), '이 과정에 놓인 개념은 전체에만 든다');
  assert.ok(unplacedIds.includes(otherOnly), '다른 과정에만 놓인 개념은 미배치 대상이다');
  assert.ok(!allIds.includes(bare) && !allIds.includes(algebraOnly));
  assert.equal(all.filter.source_course_id, geo.course.id);
  assert.equal(all.filter.source_scope, 'all');
  assert.equal(all.filter.course_key, 'H-geometry');
  assert.equal(all.filter.course_name, '기하');
  assert.ok(all.started_at);
  assert.equal(all.total, allIds.length);
  assert.equal(unplaced.filter.source_scope, 'course_unplaced');
  assert.equal(unplaced.filter.course_key, 'H-geometry');
  assert.equal(unplaced.filter.course_name, '기하');

  const frozen = await storedIds(all.walk_id);
  await t.exec(`update concept_sources set grade_label = '대수' where concept_id = '${b}'`);
  await t.exec(`update concepts set name = 'a-이름바꿈 ${tag}', sort_order = null where id = '${z}'`);
  await add(geo.S1.id, [otherOnly]);
  await t.exec(`update course_maps set name = '기하-바뀜' where id = '${geo.course.id}'`);
  try {
    const born = await insertConcept(t, `새로생김 ${tag}`, root);
    const bornBare = await insertConcept(t, `새로출처없음 ${tag}`, root);
    await addSource(born, '기하');
    const again = (await op(`select concept_review_walk($1::uuid, null, 0, 60) as r`, [all.walk_id])).r;
    assert.deepEqual(again.items.map((i) => i.id), allIds, '출처·이름·배치·과정 이름·신규 개념 뒤에도 저장된 순서를 다시 계산하지 않는다');
    assert.deepEqual(await storedIds(all.walk_id), frozen);
    assert.equal(again.filter.course_name, '기하');
    assert.equal(again.filter.course_key, 'H-geometry');
    assert.equal(again.created_after, 2, 'created_after는 출처 조건의 신규 후보가 아니라 그 시각 이후 생긴 개념 전체 수');
    assert.ok(!again.items.some((i) => i.id === born || i.id === bornBare));

    await t.exec(`delete from concept_sources where concept_id = '${nil}'`);
    await op(`select concept_delete($1::uuid) as r`, [nil]);
    const missing = (await op(`select concept_review_walk($1::uuid, null, 0, 60) as r`, [all.walk_id])).r;
    assert.equal(missing.items.find((i) => i.id === nil).missing, true);
    assert.deepEqual(await storedIds(all.walk_id), frozen);
  } finally {
    await t.exec(`update course_maps set name = '기하' where id = '${geo.course.id}'`);
  }
});

test('출처 검수 목록: 없는 과정·빈 과정 키·잘못된 범위는 저장 전에 거절하고, 기존 폴더 검토 범위는 그대로다', async () => {
  const geo = await pick('기하');
  const before = await walkCount();
  await sourceRejects(randomUUID(), 'all', /course_map_not_found/);
  const empty = (await t.one(
    `insert into course_maps (name, school_level, sort_order) values ('키없음과정', '고', 9000) returning id`,
  )).id;
  await sourceRejects(empty, 'all', /concept_review_empty_course_key/);
  await sourceRejects(geo.course.id, 'unplaced', /concept_review_bad_source_scope/);
  await sourceRejects(geo.course.id, null, /concept_review_bad_source_scope/);
  assert.equal(await walkCount(), before, '거절된 호출은 목록을 남기지 않는다');
  await t.asUser(() =>
    t.rejects(`select concept_review_source_walk($1::uuid, 'all', 0, 40)`, [geo.course.id], /concept_review_forbidden/));
  await t.asAnon(() =>
    t.rejects(`select concept_review_source_walk($1::uuid, 'all', 0, 40)`, [geo.course.id], /permission denied/));

  const F = (await t.one(`insert into concept_categories (name) values ($1) returning id`, [`폴더검수 ${randomUUID().slice(0, 6)}`])).id;
  const c = await insertConcept(t, `폴더개념 ${randomUUID().slice(0, 6)}`, F);
  const ok = (await op(`select concept_review_walk(null, $1::jsonb, 0, 60) as r`, [
    JSON.stringify({ folder_id: F, review: 'unreviewed', review_scope: 'notation' }),
  ])).r;
  assert.deepEqual(ok.items.map((i) => i.id), [c]);
  assert.equal(ok.filter.review_scope, 'notation');
  await opRejects(
    `select concept_review_walk(null, $1::jsonb, 0, 40)`,
    [JSON.stringify({ review_scope: 'all' })],
    /concept_review_bad_filter/,
  );
  await opRejects(
    `select concept_review_walk(null, $1::jsonb, 0, 40)`,
    [JSON.stringify({ review_scope: 'foundation' })],
    /concept_review_bad_filter/,
  );
});
