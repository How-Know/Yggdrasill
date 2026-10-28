// Think 개념 출처 원본 다시 읽기. 쪽은 출처의 PDF 쪽(raw_page)으로만 고르고, 인쇄 쪽은 기록이 있을 때만 표시한다.
// 쪽 이미지는 게이트웨이가 만든 것 가운데 지금 원본(연결·파일 해시)의 것만 준다. 원본 열람은 개념·기록·관계를 바꾸지 않는다.
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { insertConcept, openConceptTestDb, seedConcepts } from '../concept_fixture.mjs';

let t;
let S;
let folder;
let bookB;

before(async () => {
  t = await openConceptTestDb();
  S = await seedConcepts(t);
  folder = (await t.one(`insert into concept_categories (name, code, depth) values ('원본 시험', 'SRCPG', 0) returning id`)).id;
  bookB = (await t.one(`insert into resource_files (academy_id, name) values ($1::uuid, '다른 개념책') returning id`, [S.academy])).id;
  await t.exec(`grant select on storage.objects to authenticated`);
});
after(() => t?.close());

const op = (fn) => t.asSuperadmin(fn, S.operator);
const rpc = (sql, args = [], who = S.operator) => t.asSuperadmin(async () => (await t.one(`select ${sql} as r`, args)).r, who);
const list = (concept) => rpc(`concept_source_list($1::uuid)`, [concept]);
const context = (source, offset) => rpc(`concept_source_page_context($1::uuid, $2)`, [source, offset]);
const image = (source, offset, request, who) => rpc(`concept_source_page_image($1::uuid, $2, $3)`, [source, offset, request], who);
// 게이트웨이는 서버 키로 RLS를 건너뛴다. 시험 DB에서는 소유자 역할로 같은 쓰기를 한다.
const asGateway = (fn) => fn();

async function source(concept, { book = S.book, grade = '1-1', raw, display = null, draft = null, blocks = [], statement = null }) {
  return (await t.one(
    `insert into concept_sources (concept_id, academy_id, book_id, grade_label, raw_page, display_page, draft_id, block_ids, statement_id)
     values ($1::uuid, $2::uuid, $3::uuid, $4, $5, $6, $7::uuid, $8::text[], $9::uuid) returning id`,
    [concept, S.academy, book, grade, raw, display, draft, blocks, statement],
  )).id;
}

async function link(book, grade, { status = 'migrated', hash = 'sha256:ABCDEF0123456789ffff', storage = true } = {}) {
  return (await t.one(
    `insert into resource_file_links (academy_id, file_id, grade, storage_driver, storage_bucket, storage_key, migration_status, content_hash)
     values ($1::uuid, $2::uuid, $3, $4, $5, $6, $7, $8) returning id`,
    [S.academy, book, `${grade}#body`, storage ? 'supabase' : null, storage ? 'textbooks' : null,
      storage ? `academies/${S.academy}/files/${book}/${grade}/body.pdf` : null, status, hash],
  )).id;
}

async function transcript(raw, { display = null, read = 1, blocks, masks = [] }) {
  await t.one(
    `insert into concept_page_transcripts (academy_id, book_id, grade_label, raw_page, display_page, read_index, prompt_version, model, masks, page)
     values ($1::uuid, $2::uuid, '1-1', $3, $4, $5, 'concept_page_read.v2', 'gpt', $6::jsonb, $7::jsonb) returning id`,
    [S.academy, S.book, raw, display, read, JSON.stringify(masks), JSON.stringify({ page_kind: 'mixed', blocks, notes: '' })],
  );
}

const block = (raw, i, text, extra = {}) => ({
  id: `p${raw}-a${i}`, raw_page: raw, read: 'a', kind: 'explanation', title: '', text, figure_description: '', bbox_1k: null,
  uncertain: false, ...extra,
});

/** 인쇄 쪽과 PDF 쪽이 2쪽 어긋난 개념책: PDF 12·13쪽이 인쇄 10·11쪽이다. PDF 10쪽은 다른 글이다. */
async function offsetBook() {
  const prepared = {
    blocks: [
      block(12, 0, 'PDF 12쪽(인쇄 10쪽): 소수의 정의'),
      block(12, 1, '그림: 수직선 위의 점', { kind: 'figure', figure_description: '수직선 위에 점 2, 3, 5' }),
      block(13, 0, 'PDF 13쪽(인쇄 11쪽): 합성수'),
    ],
    furniture: [],
    disagreements: [{ id: 'p12-a1', raw_page: 12, type: 'text_differs', similarity: 0.7, a_text: 'x', b_text: 'y' }],
  };
  const draft = (await t.one(
    `insert into concept_drafts (academy_id, book_id, grade_label, book_name, unit_path, pages, page_meta, model, prompt_version, prepared, draft)
     values ($1::uuid, $2::uuid, '1-1', '개념+유형 중1-1', array['소인수분해'], array[12, 13],
             '[{"raw_page":12,"display_page":10},{"raw_page":13,"display_page":11}]'::jsonb, 'gpt', 'v', $3::jsonb, '{"concepts":[]}'::jsonb)
     returning id`,
    [S.academy, S.book, JSON.stringify(prepared)],
  )).id;
  await transcript(12, {
    display: 10,
    blocks: [{ kind: 'explanation', title: '', text: '전사 12쪽', figure_description: '', uncertain: false }],
    masks: [{ label: 'M1', bbox_1k: [600, 0, 900, 500], problem_number: '3' }],
  });
  await transcript(12, { display: 10, read: 2, blocks: [] });
  await transcript(10, {
    display: 8,
    blocks: [{ kind: 'explanation', title: '', text: 'PDF 10쪽(인쇄 8쪽): 다른 단원', figure_description: '', uncertain: false }],
  });
  return draft;
}

test('출처 목록은 PDF 쪽과 인쇄 쪽을 따로 주고, 인쇄 쪽 기록이 없으면 비워 두며, 여러 출처를 책·학년·쪽으로 구별한다', async () => {
  const c = await insertConcept(t, '목록 개념', folder);
  const draft = await offsetBook();
  await link(S.book, '1-1');
  const a = await source(c, { raw: 12, display: 10, draft, blocks: ['p12-a0'] });
  const b = await source(c, { raw: 13, draft, blocks: ['p13-a0'] });
  const other = await source(c, { book: bookB, raw: 5 });
  const r = await list(c);
  assert.equal(r.total, 3);
  assert.deepEqual(r.sources.map((s) => s.id), [a, b, other], '책 이름·학년·PDF 쪽 순서');
  const byId = Object.fromEntries(r.sources.map((s) => [s.id, s]));
  assert.deepEqual([byId[a].raw_page, byId[a].display_page], [12, 10]);
  assert.deepEqual([byId[b].raw_page, byId[b].display_page], [13, null], '인쇄 쪽 기록이 없으면 null(추정하지 않음)');
  assert.equal(byId[a].book_name, '개념+유형 중1-1');
  assert.equal(byId[other].book_name, '다른 개념책');
  assert.deepEqual([byId[a].link, byId[other].link], ['ok', 'link_missing']);
  assert.deepEqual([byId[a].draft, byId[a].draft_covers_page, byId[a].block_count, byId[a].transcript_reads], ['found', true, 1, 2]);
  assert.deepEqual(byId[other].draft, 'none');
  assert.deepEqual(byId[a].image, { status: 'not_requested' });
  assert.equal(byId[a].member, true);
  assert.equal((await list(c)).sources.length, 3, '목록은 대기열에 아무것도 넣지 않는다');
  assert.equal((await t.one(`select count(*)::int as n from concept_source_page_images`)).n, 0);
});

test('쪽 글은 PDF 쪽으로 고른다: 인쇄 쪽과 번호가 다른 책에서 출처 쪽·앞뒤 쪽의 블록·가림·인쇄 쪽을 정확히 준다', async () => {
  const c = await insertConcept(t, '쪽 개념', folder);
  const draft = (await t.one(`select id from concept_drafts order by created_at limit 1`)).id;
  const s = await source(c, { raw: 12, display: 10, draft, blocks: ['p12-a0'] });

  const here = await context(s, 0);
  assert.deepEqual(here.page, { raw_page: 12, offset: 0, display_page: 10, display_from: 'source' });
  assert.equal(here.blocks_from, 'draft');
  assert.deepEqual(here.blocks.map((b) => [b.id, b.linked]), [['p12-a0', true], ['p12-a1', false]]);
  assert.ok(here.blocks.every((b) => !b.text.includes('PDF 10쪽')), '인쇄 10쪽을 PDF 10쪽으로 읽지 않는다');
  assert.equal(here.blocks[1].figure_description, '수직선 위에 점 2, 3, 5');
  assert.deepEqual(here.disagreements, [{ id: 'p12-a1', type: 'text_differs' }]);
  assert.deepEqual(here.linked_missing, []);
  assert.deepEqual(here.masks, [{ label: 'M1', bbox_1k: [600, 0, 900, 500], problem_number: '3' }]);
  assert.deepEqual(here.transcript.reads, [1, 2]);
  assert.equal(here.basis.kind, 'base');
  assert.equal(here.source.concept_name, '쪽 개념');

  const next = await context(s, 1);
  assert.deepEqual(next.page, { raw_page: 13, offset: 1, display_page: 11, display_from: 'draft' });
  assert.deepEqual(next.blocks.map((b) => b.id), ['p13-a0']);
  assert.equal(next.masks, null, '전사가 없으면 가림 여부를 모른다(null)');
  assert.equal(next.basis, null, '앞뒤 쪽에는 편집 본문을 싣지 않는다');

  const before2 = await context(s, -2);
  assert.deepEqual(before2.page, { raw_page: 10, offset: -2, display_page: 8, display_from: 'transcript' });
  assert.equal(before2.blocks_from, 'transcript');
  assert.deepEqual(before2.blocks.map((b) => b.text), ['PDF 10쪽(인쇄 8쪽): 다른 단원']);

  const gap = await context(s, -1);
  assert.deepEqual(gap.page, { raw_page: 11, offset: -1, display_page: null, display_from: null }, '인쇄 쪽을 앞뒤 번호로 추정하지 않는다');
  assert.equal(gap.blocks_from, null);
  assert.deepEqual(gap.blocks, [], '글이 없는 쪽을 다른 쪽 글로 채우지 않는다');

  await op(() => t.rejects(`select concept_source_page_context($1::uuid, 3)`, [s], /concept_source_page_bad_offset/));
  await op(() => t.rejects(`select concept_source_page_image($1::uuid, -3, true)`, [s], /concept_source_page_bad_offset/));
  await op(() => t.rejects(`select concept_source_page_context(gen_random_uuid(), 0)`, [], /concept_source_not_found/));
});

test('근거 블록 연결이 끊기면 linked_missing 으로 알리고, 다른 블록으로 채우지 않는다', async () => {
  const c = await insertConcept(t, '끊긴 개념', folder);
  const draft = (await t.one(`select id from concept_drafts order by created_at limit 1`)).id;
  const partial = await source(c, { raw: 12, draft, blocks: ['p12-a0', 'p12-a9'] });
  const p = await context(partial, 0);
  assert.deepEqual(p.linked_missing, ['p12-a9']);
  assert.deepEqual(p.blocks.filter((b) => b.linked).map((b) => b.id), ['p12-a0']);

  const gone = await t.one(
    `insert into concept_drafts (academy_id, book_id, grade_label, unit_path, pages, model, prompt_version, prepared, draft)
     values ($1::uuid, $2::uuid, '1-1', '{}', array[30], 'gpt', 'v', '{"blocks":[]}'::jsonb, '{"concepts":[]}'::jsonb) returning id`,
    [S.academy, S.book],
  );
  const orphan = await source(c, { raw: 30, draft: gone.id, blocks: ['p30-a0'] });
  await t.exec(`delete from concept_drafts where id = '${gone.id}'`);
  const o = await context(orphan, 0);
  assert.equal(o.source.draft_id, null);
  assert.equal(o.source.draft_found, false);
  assert.deepEqual(o.linked_missing, ['p30-a0']);
  assert.equal(o.blocks_from, null);
  const row = (await list(c)).sources.find((s) => s.id === orphan);
  assert.equal(row.draft, 'missing', '초안이 지워져 근거 블록만 남은 출처도 연결 끊김');
});

test('원본 이미지 요청: 그 학원 소속 운영자만 넣고, 연결 없음·여러 개·옛 연결·없는 쪽은 대기열에 넣지 않는다', async () => {
  const c = await insertConcept(t, '요청 개념', folder);
  const s = await source(c, { raw: 12, display: 10 });
  const first = await source(c, { raw: 1 });
  const noLink = await source(c, { book: bookB, raw: 5 });
  const count = async () => (await t.one(`select count(*)::int as n from concept_source_page_images`)).n;
  const before0 = await count();

  assert.equal((await image(s, 0, true, S.otherOperator)).status, 'forbidden', '학원 밖 운영자');
  await t.asUser(() => t.rejects(`select concept_source_page_image($1::uuid, 0, true)`, [s], /concept_statement_forbidden/));
  await t.asUser(() => t.rejects(`select concept_source_list($1::uuid)`, [c], /concept_statement_forbidden/));
  await t.asUser(() => t.rejects(`select concept_source_page_context($1::uuid, 0)`, [s], /concept_statement_forbidden/));
  assert.equal((await image(noLink, 0, true)).status, 'link_missing');
  assert.equal((await image(first, -1, true)).status, 'no_page');

  const legacyBook = (await t.one(`insert into resource_files (academy_id, name) values ($1::uuid, '옛 연결 책') returning id`, [S.academy])).id;
  await link(legacyBook, '1-1', { status: 'legacy', storage: false });
  assert.equal((await image(await source(c, { book: legacyBook, raw: 3 }), 0, true)).status, 'link_legacy');
  const twoBook = (await t.one(`insert into resource_files (academy_id, name) values ($1::uuid, '연결 둘 책') returning id`, [S.academy])).id;
  await link(twoBook, '1-1');
  await link(twoBook, '1-1', { hash: 'other' });
  assert.equal((await image(await source(c, { book: twoBook, raw: 3 }), 0, true)).status, 'link_ambiguous', '여러 연결 중 고르지 않는다');
  assert.equal(await count(), before0);

  assert.equal((await image(s, 0, false)).status, 'not_requested');
  const q = await image(s, 0, true);
  assert.equal(q.status, 'queued');
  assert.equal(q.raw_page, 12, '인쇄 10쪽이 아니라 PDF 12쪽');
  assert.equal(q.image_key, null);
  assert.equal(q.worker_alive, false);
  const again = await image(s, 0, true);
  assert.equal(again.status, 'queued');
  const rows = await t.all(`select raw_page, link_id, content_key, requested_by from concept_source_page_images where book_id = $1::uuid`, [S.book]);
  assert.equal(rows.length, 1, '같은 쪽은 한 줄');
  assert.equal(rows[0].raw_page, 12);
  assert.equal(rows[0].content_key, 'sha256ABCDEF0123', '게이트웨이와 같은 해시 앞 16자');
  assert.equal(rows[0].requested_by, S.operator);
  assert.equal((await image(s, 1, true)).raw_page, 13);
  await t.asUser(() => t.rejects(`select id from concept_source_page_images`, [], /permission denied/));
  await t.asUser(() => t.rejects(`select name from concept_source_page_workers`, [], /permission denied/));
});

test('게이트웨이가 만든 지금 원본의 이미지만 ready 로 주고, 원본 파일이 바뀌면 예전 이미지를 쓰지 않는다', async () => {
  const c = await insertConcept(t, '이미지 개념', folder);
  const s = await source(c, { raw: 20, display: 18 });
  const q = await image(s, 0, true);
  assert.equal(q.status, 'queued');
  const job = await t.one(`select id, link_id, content_key from concept_source_page_images where raw_page = 20`);
  const key = `academies/${S.academy}/books/${S.book}/links/${job.link_id}/${job.content_key}_p20.png`;

  await asGateway(async () => {
    await t.one(`insert into concept_source_page_workers (name, seen_at) values ('pb-api-test', now())
                 on conflict (name) do update set seen_at = excluded.seen_at returning name`);
    const claimed = await t.all(
      `update concept_source_page_images set status = 'working', worker_name = 'pb-api-test', started_at = now(), heartbeat_at = now(),
              attempts = attempts + 1 where id = $1::uuid and status = 'queued' returning id`, [job.id]);
    assert.equal(claimed.length, 1);
  });
  const working = await image(s, 0, false);
  assert.deepEqual([working.status, working.worker_alive, working.image_key], ['working', true, null]);
  await asGateway(() => t.one(
    `update concept_source_page_images set status = 'ready', image_key = $2, width = 1131, height = 1600, bytes = 250000,
            finished_at = now(), heartbeat_at = now() where id = $1::uuid returning id`, [job.id, key]));

  const ready = await image(s, 0, true);
  assert.equal(ready.status, 'ready');
  assert.deepEqual([ready.image_bucket, ready.image_key, ready.width, ready.height], ['concept-source-pages', key, 1131, 1600]);
  assert.equal((await list(c)).sources[0].image.status, 'ready');

  await t.exec(`update resource_file_links set content_hash = 'sha256:9999' where file_id = '${S.book}' and grade = '1-1#body'`);
  const stale = await image(s, 0, false);
  assert.equal(stale.status, 'stale');
  assert.equal(stale.image_key, undefined, '바뀐 원본의 예전 이미지는 주지 않는다');
  assert.equal((await list(c)).sources[0].image.status, 'stale');
  const redo = await image(s, 0, true);
  assert.deepEqual([redo.status, redo.image_key], ['queued', null]);
  const after = await t.one(`select content_key, image_key, attempts from concept_source_page_images where id = $1::uuid`, [job.id]);
  assert.deepEqual([after.content_key, after.image_key, after.attempts], ['sha2569999', null, 0]);
  await t.exec(`update resource_file_links set content_hash = 'sha256:ABCDEF0123456789ffff' where file_id = '${S.book}' and grade = '1-1#body'`);
});

test('실패는 실패로 돌려주고, 잠시 뒤 다시 요청할 때만 다시 넣는다. PDF에 없는 쪽과 멈춘 작업은 구별한다', async () => {
  const c = await insertConcept(t, '실패 개념', folder);
  const s = await source(c, { raw: 40 });
  await image(s, 0, true);
  const id = (await t.one(`select id from concept_source_page_images where raw_page = 40`)).id;
  const fail = (code, ago = '0 seconds') => asGateway(() => t.one(
    `update concept_source_page_images set status = 'failed', error = $2, finished_at = now() - $3::interval where id = $1::uuid returning id`,
    [id, code, ago]));

  await fail('source_download_failed');
  const f = await image(s, 0, true);
  assert.deepEqual([f.status, f.error, f.image_key], ['failed', 'source_download_failed', null], '방금 실패한 것은 바로 다시 넣지 않는다');
  await fail('source_download_failed', '2 minutes');
  assert.equal((await image(s, 0, false)).status, 'failed', '상태만 볼 때는 다시 넣지 않는다');
  assert.equal((await image(s, 0, true)).status, 'queued');

  await fail('page_out_of_range', '10 minutes');
  const out = await image(s, 0, true);
  assert.deepEqual([out.status, out.error], ['failed', 'page_out_of_range'], 'PDF에 없는 쪽은 다시 만들지 않는다');

  await asGateway(() => t.one(
    `update concept_source_page_images set status = 'working', error = null, started_at = now() - interval '10 minutes',
            heartbeat_at = now() - interval '5 minutes', finished_at = null where id = $1::uuid returning id`, [id]));
  assert.equal((await image(s, 0, false)).status, 'working');
  assert.equal((await image(s, 0, true)).status, 'queued', '멈춘 작업은 다시 넣는다');
});

test('원본 열람은 개념·출처·검토 기록·관계·같은 개념 검토를 바꾸지 않는다', async () => {
  const snapshot = async () => ({
    concepts: await t.all(`select id, name, content, updated_at from concepts order by id`),
    sources: await t.all(`select * from concept_sources order by id`),
    quality: (await t.one(`select count(*)::int as n from concept_quality_reviews`)).n,
    relations: (await t.one(`select count(*)::int as n from concept_relations`)).n,
    reviews: (await t.one(`select count(*)::int as n from concept_reviews`)).n,
    actions: (await t.one(`select count(*)::int as n from ai_actions`)).n,
  });
  const c = await insertConcept(t, '읽기만 개념', folder);
  const draft = (await t.one(`select id from concept_drafts order by created_at limit 1`)).id;
  const s = await source(c, { raw: 12, display: 10, draft, blocks: ['p12-a0'] });
  const before0 = await snapshot();
  await list(c);
  for (const off of [-2, -1, 0, 1, 2]) {
    await context(s, off);
    await image(s, off, true);
  }
  assert.deepEqual(await snapshot(), before0);
});

test('쪽 이미지 저장소는 그 학원 소속 운영자만 읽는다', async () => {
  await t.exec(`insert into storage.objects (bucket_id, name) values
    ('concept-source-pages', 'academies/${S.academy}/books/${S.book}/links/1/k_p1.png'),
    ('concept-source-pages', 'academies/${S.otherAcademy}/books/${S.otherBook}/links/2/k_p1.png')`);
  const names = (who) => t.asSuperadmin(async () => (await t.all(
    `select name from storage.objects where bucket_id = 'concept-source-pages' order by name`)).map((r) => r.name), who);
  assert.deepEqual(await names(S.operator), [`academies/${S.academy}/books/${S.book}/links/1/k_p1.png`]);
  assert.deepEqual(await names(S.otherOperator), []);
  await t.exec(`insert into memberships (academy_id, user_id) values ('${S.academy}', '${S.user}')`);
  assert.deepEqual(await t.asUser(async () => {
    await t.exec(`set request.jwt.claim.sub = '${S.user}'`);
    return t.all(`select name from storage.objects where bucket_id = 'concept-source-pages'`);
  }), [], '학원 소속이어도 운영자가 아니면 못 읽는다');
  const bucket = await t.one(`select public, allowed_mime_types from storage.buckets where id = 'concept-source-pages'`);
  assert.deepEqual([bucket.public, bucket.allowed_mime_types], [false, ['image/png']]);
});

test('기능 확인에 concept_source_pages 가 있다', async () => {
  const features = (await op(() => t.one(`select ai_think_db_features() as r`))).r;
  assert.equal(features.concept_source_pages, 1);
  assert.equal(features.concept_relation_change, 1);
});
