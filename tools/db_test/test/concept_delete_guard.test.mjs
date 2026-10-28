// 개념 지우기 보호: 붙은 것이 하나라도 있으면 어느 길(RPC·표 직접 삭제·service role·Think 카드·폴더 삭제)로도 지우지 않고,
// 붙은 자료도 남는다. 미리 보기·Think 읽기·카드·실제 삭제가 같은 기준(concept_attachments)을 쓴다.
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { insertConcept, openConceptTestDb, seedConcepts } from '../concept_fixture.mjs';

let t;
let S;
let conv;

before(async () => {
  t = await openConceptTestDb();
  // 운영 Supabase 의 service role 처럼 RLS를 건너뛴다(그래도 지우기 보호는 받는다).
  await t.exec(`alter role service_role bypassrls`);
  S = await seedConcepts(t);
  conv = (await t.one(`insert into ai_conversations (title) values ('개념 정리') returning id`)).id;
});
after(() => t?.close());

const op = (sql, params = []) => t.asSuperadmin(() => t.one(sql, params), S.operator);
const opRejects = (sql, params, pattern) => t.asSuperadmin(() => t.rejects(sql, params, pattern), S.operator);
const check = async (id) => (await op(`select concept_delete_check($1::uuid) as r`, [id])).r;
const del = async (id) => (await op(`select concept_delete($1::uuid) as r`, [id])).r;
const exists = async (id) => (await t.one(`select count(*)::int as n from concepts where id = $1::uuid`, [id])).n === 1;

/** 슈퍼관리자가 아닌 로그인 사용자(auth.uid() 있음). */
async function asMember(fn) {
  await t.exec(`set request.jwt.claim.sub = '${S.user}'; set role authenticated;`);
  try {
    return await fn();
  } finally {
    await t.exec(`reset role; set request.jwt.claim.sub = '';`);
  }
}

/** 실패해야 하는 일을 하고 그 오류를 돌려준다. */
async function failure(fn) {
  try {
    await fn();
  } catch (e) {
    return e;
  }
  throw new Error('expected failure');
}

async function leafUnit() {
  const course = (await op(`select course_maps_list() as r`)).r.find((c) => c.name === '1-1');
  const map = (await op(`select course_map_get($1::uuid) as r`, [course.id])).r;
  return map.units.find((u) => u.depth === 3);
}

let seq = 0;
const fresh = (label) => insertConcept(t, `지우기 보호 ${label} ${++seq}`, S.folder, '처음 본문');

// [보이는 이름, concept_attachments 키, 붙이기]
const KINDS = [
  ['출처', 'sources', (c) => t.exec(
    `insert into concept_sources (concept_id, academy_id, book_id, grade_label, raw_page)
     values ('${c}', '${S.academy}', '${S.book}', '1-1', 30)`)],
  ['서술', 'statements', (c) =>
    op(`select concept_statement_create($1::uuid, 'statement', $2::jsonb) as r`, [c, JSON.stringify({ title: '서술', body: '본문' })])],
  ['등장 위치', 'appearances', (c) => t.exec(
    `insert into concept_appearances (concept_id, curriculum_code, school_level, course_label) values ('${c}', 'rev_2022', '중', '1-1')`)],
  ['기준 단원 배치', 'placements', async (c) =>
    op(`select course_placement_add($1::uuid, $2::uuid[]) as r`, [(await leafUnit()).id, `{${c}}`])],
  ['나가는 관계', 'relations', (c) => t.exec(
    `insert into concept_relations (concept_id, related_id, kind, origin) values ('${c}', '${S.concept}', 'extends', 'manual')`)],
  ['들어오는 관계', 'relations', (c) => t.exec(
    `insert into concept_relations (concept_id, related_id, kind, origin) values ('${S.concept2}', '${c}', 'special_case', 'manual')`)],
  ['검토 기록', 'reviews', (c) => t.exec(`insert into concept_reviews (concept_id, reason) values ('${c}', 'manual')`)],
  ['상대 쪽 검토 기록', 'reviews', (c) =>
    t.exec(`insert into concept_reviews (concept_id, other_id, reason) values ('${S.concept}', '${c}', 'same_name')`)],
  ['범위별 검토 기록', 'quality_reviews', (c) => t.exec(
    `insert into concept_quality_reviews (concept_id, scope, outcome, checked, findings, basis, marks, mark)
     values ('${c}', 'notation', 'no_issue_found', '표기', '못 찾음', '본문', '{}'::jsonb, 'x')`)],
  ['정리 기준 연결', 'criteria', async (c) => {
    const id = (await op(`select concept_criteria_create($1, '', 'owner') ->> 'id' as id`, [`기준 ${c}`])).id;
    await t.exec(`insert into concept_criterion_links (criterion_id, concept_id) values ('${id}', '${c}')`);
  }],
  ['주제 묶음(묶이는 쪽)', 'anchors', (c) =>
    t.exec(`insert into concept_anchor_links (concept_id, anchor_id, origin) values ('${c}', '${S.concept}', 'manual')`)],
  ['주제 묶음(앵커 쪽)', 'anchors', async (c) => {
    const child = await fresh('묶음 자식');
    await t.exec(`insert into concept_anchor_links (concept_id, anchor_id, origin) values ('${child}', '${c}', 'manual')`);
  }],
  ['수정안', 'content_draft', (c) => t.exec(
    `insert into concept_content_drafts (concept_id, content, base_md5, saved_at) values ('${c}', '새 본문', md5('처음 본문'), now())`)],
  ['유형 연결', 'type_link', (c) => t.exec(
    `insert into concept_type_links (concept_id, type_id) select '${c}', id from concept_types where name = '정의'`)],
  ['본문 고친 기록', 'content_revisions', (c) => t.exec(`update concepts set content = '고친 본문' where id = '${c}'`)],
  ['열린 초안 검토의 대상', 'draft_refs', (c) => t.exec(
    `insert into concept_drafts (academy_id, book_id, grade_label, unit_path, pages, model, prompt_version, prepared, draft, review)
     values ('${S.academy}', '${S.book}', '1-1', array['소인수분해'], array[8], 'gpt', 'v', '{}'::jsonb, '{}'::jsonb,
             '${JSON.stringify({ concepts: [{ index: 0, mark: 'keep', relation: { kind: 'extends', concept_id: c } }] })}'::jsonb)`)],
  ['바로가기', 'shortcuts', (c) => t.exec(`insert into concept_shortcuts (category_id, concept_id) values ('${S.folder}', '${c}')`)],
  ['운영 지시문', 'operation_prompts', (c) =>
    t.exec(`insert into operation_prompts (concept_id, level_label) values ('${c}', '하')`)],
];

test('붙은 것이 하나도 없는 개념만 미리 보기에서 지울 수 있고, 운영자 RPC로 지워진다', async () => {
  const c = await fresh('빈 개념');
  const before = await check(c);
  assert.equal(before.deletable, true);
  assert.equal(before.attached.total, 0);
  for (const [, key] of KINDS) assert.equal(before.attached[key], 0, key);
  assert.equal(before.attached.other, 0);
  assert.deepEqual(await del(c), { id: c, name: before.name });
  assert.equal(await exists(c), false);
});

for (const [label, key, attach] of KINDS) {
  test(`붙은 것 [${label}]: 미리 보기에서 막히고, 지우기도 막히며 개념·자료가 남는다`, async () => {
    const c = await fresh(label);
    assert.equal((await check(c)).deletable, true);
    await attach(c);
    const now = await check(c);
    assert.equal(now.deletable, false);
    assert.ok(now.attached[key] >= 1, `${key}=${now.attached[key]}`);
    assert.equal(now.attached.total, Object.entries(now.attached).filter(([k]) => k !== 'total').reduce((s, [, n]) => s + n, 0));
    const e = await failure(() => del(c));
    assert.match(e.message, /concept_delete_attached/);
    assert.equal(JSON.parse(e.detail)[key], now.attached[key], '거절에 종류·개수가 실린다');
    assert.equal(await exists(c), true);
    assert.deepEqual((await check(c)).attached, now.attached, '거절된 뒤에도 붙은 자료가 그대로다');
  });
}

test('목록에 없는 새 외래키로 이어진 자료도 other 로 세어 막는다', async () => {
  await t.exec(`create table public.test_concept_notes (id serial primary key, concept_id uuid references public.concepts(id))`);
  try {
    const c = await fresh('새 표');
    await t.exec(`insert into test_concept_notes (concept_id) values ('${c}')`);
    const now = await check(c);
    assert.equal(now.attached.other, 1);
    assert.equal(now.deletable, false);
    await opRejects(`select concept_delete($1::uuid)`, [c], /concept_delete_attached/);
    assert.equal(await exists(c), true);
  } finally {
    await t.exec(`drop table public.test_concept_notes`);
  }
});

test('닫힌 초안·뺀 항목이 가리키는 개념은 붙은 것으로 세지 않는다', async () => {
  const c = await fresh('닫힌 초안');
  const review = (mark) => JSON.stringify({ concepts: [{ index: 0, mark, relation: { kind: 'extends', concept_id: c } }] });
  await t.exec(
    `insert into concept_drafts (academy_id, book_id, grade_label, unit_path, pages, model, prompt_version, prepared, draft, review, status, closed_at)
     values ('${S.academy}', '${S.book}', '1-1', array['소인수분해'], array[8], 'gpt', 'v', '{}'::jsonb, '{}'::jsonb, '${review('keep')}'::jsonb,
             'discarded', now())`);
  await t.exec(
    `insert into concept_drafts (academy_id, book_id, grade_label, unit_path, pages, model, prompt_version, prepared, draft, review)
     values ('${S.academy}', '${S.book}', '1-1', array['소인수분해'], array[8], 'gpt', 'v', '{}'::jsonb, '{}'::jsonb, '${review('drop')}'::jsonb)`);
  assert.equal((await check(c)).attached.draft_refs, 0);
});

test('표를 직접 지워도(앱 REST·service role) 같은 기준으로 막고, 빈 개념은 운영자가 지울 수 있다', async () => {
  const attached = await fresh('직접 지우기');
  await t.exec(`insert into concept_type_links (concept_id, type_id) select '${attached}', id from concept_types where name = '성질'`);
  const e = await failure(() => t.asSuperadmin(() => t.one(`delete from concepts where id = $1::uuid returning id`, [attached]), S.operator));
  assert.match(e.message, /concept_delete_attached/);
  assert.equal(JSON.parse(e.detail).type_link, 1);
  await t.asService(() => t.rejects(`delete from concepts where id = $1::uuid`, [attached], /concept_delete_attached/));
  await t.rejects(`delete from concepts where id = $1::uuid`, [attached], /concept_delete_attached/);
  assert.equal(await exists(attached), true);

  const bare = await fresh('직접 빈 개념');
  await t.asSuperadmin(() => t.one(`delete from concepts where id = $1::uuid returning id`, [bare]), S.operator);
  assert.equal(await exists(bare), false);
});

test('운영자가 아니면 빈 개념도 지우지 못하고, 붙은 자료의 종류·개수를 보지 못한다', async () => {
  const bare = await fresh('권한 빈 개념');
  const attached = await fresh('권한 붙은 개념');
  await t.exec(`insert into concept_reviews (concept_id, reason) values ('${attached}', 'manual')`);
  for (const id of [bare, attached]) {
    const e = await asMember(() => failure(() => t.one(`delete from concepts where id = $1::uuid returning id`, [id])));
    assert.match(e.message, /concept_delete_forbidden/);
    assert.ok(!e.detail, '권한 없는 거절에는 붙은 자료를 싣지 않는다');
    await asMember(() => t.rejects(`select concept_delete_check($1::uuid)`, [id], /concept_delete_forbidden/));
    await asMember(() => t.rejects(`select concept_delete($1::uuid)`, [id], /concept_delete_forbidden/));
    await t.asUser(() => t.rejects(`select concept_delete($1::uuid)`, [id], /concept_delete_forbidden/));
    await t.asAnon(() => t.rejects(`select concept_delete_check($1::uuid)`, [id], /permission denied/));
    await t.asUser(() => t.rejects(`select concept_attachments($1::uuid)`, [id], /permission denied/));
    assert.equal(await exists(id), true);
  }
});

test('없는 개념은 지운 것으로 치지 않고 오류로 알린다', async () => {
  const gone = '00000000-0000-4000-8000-00000000dead';
  await opRejects(`select concept_delete_check($1::uuid)`, [gone], /concept_delete_not_found/);
  await opRejects(`select concept_delete($1::uuid)`, [gone], /concept_delete_not_found/);
});

test('미리 본 뒤 붙은 것이 생기면 지울 때 다시 세어 막는다', async () => {
  const c = await fresh('미리 본 뒤');
  assert.equal((await check(c)).deletable, true);
  await t.exec(`insert into concept_sources (concept_id, academy_id, book_id, grade_label, raw_page)
                values ('${c}', '${S.academy}', '${S.book}', '1-1', 31)`);
  await opRejects(`select concept_delete($1::uuid)`, [c], /concept_delete_attached/);
  assert.equal(await exists(c), true);
});

test('세기를 건너뛰어도 외래키가 막는다: 개념을 가리키는 외래키에 cascade 가 남지 않는다', async () => {
  const left = await t.all(
    `select conrelid::regclass::text as tbl, conname from pg_constraint
      where contype = 'f' and confdeltype = 'c'
        and (confrelid = 'public.concepts'::regclass
             or (conrelid = 'public.concepts'::regclass and confrelid = 'public.concept_categories'::regclass))`,
  );
  assert.deepEqual(left, []);

  const c = await fresh('외래키');
  await t.exec(`insert into concept_shortcuts (category_id, concept_id) values ('${S.folder}', '${c}')`);
  await t.exec(`alter table concepts disable trigger trg_concepts_delete_guard`);
  try {
    await t.rejects(`delete from concepts where id = $1::uuid`, [c], /foreign key/);
  } finally {
    await t.exec(`alter table concepts enable trigger trg_concepts_delete_guard`);
  }
  assert.equal(await exists(c), true);
  assert.equal((await t.one(`select count(*)::int as n from concept_shortcuts where concept_id = $1::uuid`, [c])).n, 1);
});

test('개념이 든 폴더(하위 폴더 포함)는 지우지 않고, 빈 폴더만 지운다', async () => {
  const top = (await t.one(`insert into concept_categories (name) values ('지우기 시험 폴더') returning id`)).id;
  const sub = (await t.one(`insert into concept_categories (name, parent_id, depth) values ('아래 폴더', $1::uuid, 1) returning id`, [top])).id;
  const c = await insertConcept(t, '폴더 안 빈 개념', sub, '본문');

  const e = await failure(() => t.asSuperadmin(() => t.one(`delete from concept_categories where id = $1::uuid returning id`, [top]), S.operator));
  assert.match(e.message, /concept_folder_not_empty/);
  assert.deepEqual(JSON.parse(e.detail), { concepts: 1 });
  await t.asSuperadmin(() => t.rejects(`delete from concept_categories where id = $1::uuid`, [sub], /concept_folder_not_empty/), S.operator);
  assert.equal(await exists(c), true);
  assert.equal((await t.one(`select count(*)::int as n from concept_categories where id in ($1::uuid, $2::uuid)`, [top, sub])).n, 2);

  await del(c);
  await t.asSuperadmin(() => t.one(`delete from concept_categories where id = $1::uuid returning id`, [top]), S.operator);
  assert.equal((await t.one(`select count(*)::int as n from concept_categories where id in ($1::uuid, $2::uuid)`, [top, sub])).n, 0);
});

test('Think 읽기·카드 미리 보기·승인이 미리 보기와 같은 붙은 것을 본다', async () => {
  const typed = await fresh('Think 유형만');
  await t.exec(`insert into concept_type_links (concept_id, type_id) select '${typed}', id from concept_types where name = '방법'`);
  const bare = await fresh('Think 빈 개념');
  const viaCheck = await check(typed);
  const viaDetail = (await op(`select concept_think_detail($1::uuid) as r`, [typed])).r.attached;
  assert.deepEqual(viaDetail, viaCheck.attached);

  const act = await op(`select * from course_think_action_propose($1::uuid, 'concept_library_change', $2::jsonb)`, [
    conv,
    JSON.stringify({ items: [{ op: 'delete', concept_id: typed }, { op: 'delete', concept_id: bare }], reason: '정리' }),
  ]);
  assert.equal(act.preview.blocked, 1);
  assert.equal(act.preview.items[0].blocked, true);
  assert.deepEqual(act.preview.items[0].attached, viaCheck.attached);
  assert.equal(act.preview.items[1].blocked, false);

  const done = await op(`select * from course_think_action_apply($1::uuid, '{}'::jsonb)`, [act.id]);
  assert.deepEqual(done.result.items.map((i) => [i.status, i.code ?? null]), [['failed', 'concept_delete_attached'], ['applied', null]]);
  assert.equal(await exists(typed), true);
  assert.equal(await exists(bare), false);
});
