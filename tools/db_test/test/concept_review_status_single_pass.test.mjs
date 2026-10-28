// 집계를 한 순회로 바꾼 뒤에도 통합 완료·3조건·조건별 수가 같은지, 진단 조회가 집계를 부르지 않는지, 514개 조회 시간을 기록한다.
import { after, test } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { CONCEPT_FILES, insertConcept, openConceptTestDb, seedConcepts } from '../concept_fixture.mjs';
import { migrationsDir } from '../harness.mjs';

const NEW_FILE = '20261028030000_concept_review_status_single_pass.sql';
let t;

after(() => t?.close());

const review = (scope, over = {}) => ({
  scope, outcome: 'no_issue_found', checked: `${scope} 확인`, findings: '이번에 본 범위에서 문제를 찾지 못함', basis: '본문 전체를 읽음',
  unverified: null, follow_up: null, compared_ids: [], to_compare_ids: [], ...over,
});
const foundationOk = () => review('foundation', {
  checked: '필요한 초등 기초 개념을 검색해 본문과 비교', findings: '추가할 기초 개념 없음', basis: '대상 본문을 읽음',
  detail: { needs: [{ name: '약수', why: '정의에 쓰임', terms: ['약수'], candidates: [], decision: 'reuse', reuse_id: null }], not_seen: null },
});
const placementOk = () => review('placement', {
  checked: '출처와 지금 배치를 대조', findings: '배치 유지', basis: '출처 메타데이터. 교재 원본 쪽은 보지 않음',
  detail: { basis_kind: 'source', viewed_original: false },
});
const four = () => [review('notation'), review('meaning'), foundationOk(), placementOk()];

function snap(st) {
  const items = Array.isArray(st.open_items) ? st.open_items : [];
  return {
    progress_line: st.progress_line,
    condition_line: st.condition_line,
    counts: st.counts,
    conditions: st.conditions,
    total_mismatch: st.total_mismatch,
    met: Number(st.first_pass?.met),
    total: Number(st.first_pass?.total),
    line: st.first_pass?.line,
    first_pass_line: st.first_pass_line,
    open: items.map((i) => ({ position: Number(i.position), category: i.category, item_state: i.item_state ?? null })),
    pending: Array.isArray(st.pending_cards) ? st.pending_cards.length : 0,
  };
}

test('한 순회 집계는 이전과 같고, 진단은 집계 없이 읽히며, 514개 시간을 기록한다', async () => {
  const files = CONCEPT_FILES.filter((f) => f !== NEW_FILE
    && f !== '20261028190000_concept_review_progress_snapshot.sql'
    && f !== '20261028230000_concept_review_progress_cron_step.sql');
  t = await openConceptTestDb(files);
  const S = await seedConcepts(t);
  const op = (sql, params = []) => t.asSuperadmin(() => t.one(sql, params), S.operator);
  const r = async (sql, params) => (await op(sql, params)).r;
  const revision = async (id) => (await t.one(`select concept_review_revision(concept_review_marks($1::uuid)) as r`, [id])).r;
  const status = (job) => r(`select concept_review_job_status($1::uuid, 60) as r`, [job]);
  const conv = (await t.one(`insert into ai_conversations (title) values ('집계 진단') returning id`)).id;

  const F = (await t.one(`insert into concept_categories (name) values ($1) returning id`, [`집계 ${randomUUID().slice(0, 6)}`])).id;
  const course = (await r(`select course_maps_list() as r`)).find((c) => c.name === '2-1');
  const map = await r(`select course_map_get($1::uuid) as r`, [course.id]);
  const leaf = map.units.filter((u) => u.depth === 3)[0];
  const made = [];
  for (const name of ['집계 가', '집계 나', '집계 다', '집계 라']) {
    const id = await insertConcept(t, `${name} ${randomUUID().slice(0, 4)}`, F, `${name}은 약수를 써서 정의한다.`);
    await t.exec(
      `insert into concept_sources (concept_id, academy_id, book_id, grade_label, raw_page, display_page, unit_path)
       values ('${id}', '${S.academy}', '${S.book}', '중2-1', 50, 40, '{"Ⅰ. 수와 식","1. 유리수"}')`,
    );
    made.push(id);
  }
  await r(`select course_placement_add($1::uuid, $2::uuid[]) as r`, [leaf.id, `{${made.join(',')}}`]);
  const w = await r(`select concept_review_walk(null, $1::jsonb, 0, 60) as r`, [JSON.stringify({ folder_id: F })]);
  const order = await t.all(
    `select x.pos::int as pos, x.cid::text as cid
       from concept_review_walks w
       cross join lateral unnest(w.concept_ids) with ordinality as x(cid, pos)
      where w.id = $1::uuid order by x.pos`,
    [w.walk_id],
  );
  assert.equal(order.length, 4);
  const idAt = (pos) => order.find((x) => Number(x.pos) === pos).cid;
  const job = (await r(`select concept_review_job_start($1::uuid, '집계 비교') as r`, [w.walk_id])).job_id;
  const gen = (await r(`select concept_review_job_claim($1::uuid, 'run', 'take') as r`, [job])).gen;
  await r(`select concept_review_job_targets($1::uuid, $2::bigint, 4) as r`, [job, gen]);
  const drafted = async (pos, reviews, rework = false) => ({
    position: pos, concept_id: idAt(pos), state: 'drafted', revision: await revision(idAt(pos)), read_complete: true,
    unread: null, reviews, next_action: null, reason: null, rework,
  });
  const save = (items) => r(`select concept_review_job_save($1::uuid, $2::bigint, $3::jsonb) as r`, [job, gen, JSON.stringify(items)]);
  const saved = await save([
    await drafted(1, four()),
    await drafted(2, four()),
    { position: 3, concept_id: idAt(3), state: 'deferred', read_complete: true, reviews: null, reason: '원본 확인 필요', next_action: '출처 쪽을 읽고 판단' },
  ]);
  assert.equal(saved.saved, 3);
  const sub = await r(`select concept_review_job_submit($1::uuid, $2::bigint, $3::uuid, '집계 비교', null) as r`, [job, gen, conv]);
  if (sub.action) await op(`select * from course_think_action_apply($1::uuid, '{}'::jsonb)`, [sub.action.id]);
  for (const a of sub.fix_actions ?? []) await op(`select * from course_think_action_apply($1::uuid, '{}'::jsonb)`, [a.id]);
  const again = await save([await drafted(1, [review('notation', {
    outcome: 'issue_found', findings: '표기가 틀림',
    fix: { kind: 'library', ops: [{ op: 'edit', name: `고친 ${randomUUID().slice(0, 4)}` }] },
  })], true)]);
  assert.equal(again.saved, 1);
  await t.one(
    `insert into ai_actions (conversation_id, kind, status, payload) values ($1::uuid, 'concept_review_record', 'proposed', $2::jsonb) returning id`,
    [conv, JSON.stringify({ items: [{ concept_id: idAt(2), scope: 'relations', outcome: 'needs_comparison' }] })],
  );

  const before = snap(await status(job));
  const metAt = async (pos) => (await t.one(
    `select concept_review_first_pass_met($1::uuid, $2::uuid, $3::integer) as r`,
    [idAt(pos), job, pos],
  )).r;
  const stateAt = async (pos) => (await t.one(
    `select concept_review_job_concept_state($1::uuid, concept_review_pending_concepts()) ->> 'state' as r`,
    [idAt(pos)],
  )).r;
  assert.equal(await metAt(1), false, '같은 판의 문제 초안은 1차 검수에서 빠진다');
  assert.equal(await stateAt(1), 'complete', '승인 기록이 남으면 통합 완료다');
  assert.equal(await metAt(2), true, '관계 대기만으로는 1차 검수에서 빠지지 않는다');
  assert.equal(await stateAt(2), 'pending', '관계 대기 카드는 통합 완료에서 빠진다');
  assert.equal(before.met, 1);
  assert.equal(before.counts.complete, 1);
  assert.deepEqual(before.conditions, { text: 2, foundation: 2, placement: 2 });

  const bulkFolder = (await t.one(`insert into concept_categories (name) values ('합성514') returning id`)).id;
  await t.exec(`
    insert into concept_families (canonical_name)
    select '합성 ' || lpad(i::text, 4, '0') from generate_series(1, 514) i;
    insert into concepts (name, content, main_category_id, family_id, version_label)
    select f.canonical_name, '본문 ' || f.canonical_name, '${bulkFolder}', f.id, 'v0'
      from concept_families f
     where f.canonical_name like '합성 %';
  `);
  const bulkWalk = await r(`select concept_review_walk(null, $1::jsonb, 0, 60) as r`, [JSON.stringify({ folder_id: bulkFolder })]);
  assert.equal(bulkWalk.total, 514);
  const bulkJob = (await r(`select concept_review_job_start($1::uuid, '합성 514') as r`, [bulkWalk.walk_id])).job_id;
  const t0 = performance.now();
  const beforeBulk = await status(bulkJob);
  const beforeMs = Math.round(performance.now() - t0);
  assert.equal(beforeBulk.progress_line, '514개 중 0개 통합 완료');
  assert.equal(Number(beforeBulk.first_pass.met), 0);
  assert.equal(Number(beforeBulk.first_pass.total), 514);

  await t.exec(readFileSync(join(migrationsDir, NEW_FILE), 'utf8'));
  const after = snap(await status(job));
  assert.deepEqual(after, before);

  const t1 = performance.now();
  const afterBulk = await status(bulkJob);
  const afterMs = Math.round(performance.now() - t1);
  assert.equal(afterBulk.progress_line, beforeBulk.progress_line);
  assert.equal(afterBulk.condition_line, beforeBulk.condition_line);
  assert.equal(Number(afterBulk.first_pass.met), Number(beforeBulk.first_pass.met));
  assert.equal(afterBulk.first_pass.line, beforeBulk.first_pass.line);
  console.log(`STATUS_TIMING before_ms=${beforeMs} after_ms=${afterMs} concepts=514`);

  await t.exec(`
    create or replace function public.concept_review_job_status(p_job_id uuid, p_open_limit integer default 20)
    returns jsonb language plpgsql stable security definer set search_path = public as $$
    begin
      raise exception 'status_called';
    end;
    $$;
  `);
  const diag = {
    trace_id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    stage: 'status_rpc',
    elapsed_ms: 8100,
    timeout_ms: 8000,
    code: 'timeout',
    outcome: 'failed',
    db_cancel: 'requested',
  };
  const put = await r(`select concept_review_job_status_diag_put($1::uuid, $2::jsonb) as r`, [bulkJob, JSON.stringify(diag)]);
  assert.equal(put.saved, true);
  const got = await r(`select concept_review_job_status_diag_get($1::uuid) as r`, [bulkJob]);
  assert.equal(got.diagnosis.code, 'timeout');
  assert.equal(got.diagnosis.stage, 'status_rpc');
  assert.equal(Number(got.diagnosis.elapsed_ms), 8100);
  assert.equal(Number(got.diagnosis.timeout_ms), 8000);
  assert.equal(got.diagnosis.trace_id, diag.trace_id);
  const secret = { ...diag, note: 'SECRETTEXT 본문' };
  await op(`select concept_review_job_status_diag_put($1::uuid, $2::jsonb)`, [bulkJob, JSON.stringify(secret)]).then(
    () => assert.fail('extra field should be rejected'),
    (e) => {
      assert.match(String(e.message ?? e), /concept_review_status_diag_invalid/);
      assert.doesNotMatch(String(e.message ?? e), /SECRETTEXT/);
    },
  );
  const still = await r(`select concept_review_job_status_diag_get($1::uuid) as r`, [bulkJob]);
  assert.equal(still.diagnosis.trace_id, diag.trace_id);
  assert.equal(still.diagnosis.note, undefined);
  await t.asUser(() => t.rejects(`select concept_review_job_status_diag_get($1::uuid)`, [bulkJob], /concept_review_forbidden/));
});
