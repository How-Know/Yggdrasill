// 개념 초안 정리 작업(백그라운드): Edge 함수(서버 키)만 쓰고 운영자는 읽기만 한다.
// 결과 저장은 running → saving 으로 바꾼 한 요청만 하고, 끝난 작업에는 끝난 시각이 있다.
// 시험 DB의 service_role 은 RLS를 건너뛰지 못하므로, 서버 키 쓰기는 DB 소유자로 대신한다.
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { openConceptTestDb, seedConcepts } from '../concept_fixture.mjs';

let t;
let S;

before(async () => {
  t = await openConceptTestDb();
  S = await seedConcepts(t);
});
after(() => t?.close());

const op = (fn) => t.asSuperadmin(fn, S.operator);
let seq = 0;

/** Edge 함수가 정리를 시작하며 적는 작업 한 줄. */
const insertJob = async (responseId = `resp_${++seq}`) => t.one(
  `insert into concept_draft_jobs (academy_id, book_id, grade_label, book_name, unit_path, pages, page_meta, prepared,
                                   model, prompt_version, effort, provider, response_id, created_by)
   values ($1::uuid, $2::uuid, '1-2', '개념+유형 중1-2', array['기본 도형', '점, 선, 면, 각'], array[8, 9, 10],
           '[]'::jsonb, '{"blocks":[]}'::jsonb, 'gpt', 'concept_draft_organize.v3', 'medium', 'openai', $3, $4::uuid)
   returning id, status`,
  [S.academy, S.book, responseId, S.operator],
);

test('작업은 서버 키만 쓰고, 운영자만 읽는다', async () => {
  const job = await insertJob();
  assert.equal(job.status, 'running');
  assert.equal((await op(() => t.all(`select id from concept_draft_jobs where id = $1::uuid`, [job.id]))).length, 1);
  assert.equal((await t.asUser(() => t.all(`select id from concept_draft_jobs`))).length, 0);
  await t.asAnon(() => t.rejects(`select id from concept_draft_jobs`, [], /permission denied/));
  await op(() => t.rejects(`update concept_draft_jobs set status = 'failed' where id = $1::uuid`, [job.id], /permission denied/));
  await op(() => t.rejects(`delete from concept_draft_jobs where id = $1::uuid`, [job.id], /permission denied/));
  await op(() => t.rejects(
    `insert into concept_draft_jobs (academy_id, book_id, grade_label, pages, prepared, model, prompt_version, effort, provider, response_id)
     values ($1::uuid, $2::uuid, '1-2', array[8], '{}'::jsonb, 'gpt', 'v', 'medium', 'openai', 'resp_op')`,
    [S.academy, S.book],
    /permission denied/,
  ));
});

test('결과 저장은 한 요청만 맡고, 끝난 작업에는 끝난 시각이 있어야 한다', async () => {
  const job = await insertJob();
  const claim = () => t.all(
    `update concept_draft_jobs set status = 'saving' where id = $1::uuid and status = 'running' returning id`,
    [job.id],
  );
  assert.equal((await claim()).length, 1);
  assert.equal((await claim()).length, 0, '이미 저장 중인 작업은 다른 요청이 맡지 못한다');

  await t.rejects(`update concept_draft_jobs set status = 'done' where id = $1::uuid`, [job.id], /concept_draft_jobs_finished_chk/);
  await t.exec(`update concept_draft_jobs set status = 'failed', error = 'x', finished_at = now() where id = '${job.id}'`);
  await t.rejects(`update concept_draft_jobs set status = 'running' where id = $1::uuid`, [job.id], /concept_draft_jobs_finished_chk/);
});

test('같은 공급자 응답으로 작업을 두 번 만들지 못한다', async () => {
  await insertJob('resp_dup');
  await assert.rejects(insertJob('resp_dup'), /duplicate key|unique/);
});
