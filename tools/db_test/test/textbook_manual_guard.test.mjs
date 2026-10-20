// 사람이 고친 정답·해설 좌표는 VLM 재실행·일괄 저장이 덮지 못한다.
// 정답 내용이 바뀌면 동치 판정 캐시와 정답 그림이 무효가 되고, 같은 값을 다시 저장하면 그대로 둔다.
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { openTextbookTestDb, seedAcademy, seedCrop } from '../textbook_fixture.mjs';

let t;
let S;

before(async () => {
  t = await openTextbookTestDb();
  S = await seedAcademy(t);
});
after(() => t?.close());

// 게이트웨이 batch-upsert 와 같은 모양: 여러 행을 한 번에 upsert 하고 돌려받은 crop_id 만 저장된 것으로 본다.
const upsertAnswers = (rows) =>
  t.all(
    `insert into textbook_problem_answers (crop_id, academy_id, answer_kind, answer_text, answer_latex_2d, answer_source, edited_at)
     select (r->>'crop_id')::uuid, $1::uuid, r->>'kind', r->>'text', r->>'text', r->>'source',
            case when r->>'source' = 'manual' then now() end
       from jsonb_array_elements($2::jsonb) r
     on conflict (crop_id) do update
       set answer_kind = excluded.answer_kind,
           answer_text = excluded.answer_text,
           answer_latex_2d = excluded.answer_latex_2d,
           answer_source = excluded.answer_source,
           edited_at = excluded.edited_at
     returning crop_id`,
    [S.academy, JSON.stringify(rows)],
  );

const upsertRef = (crop, { page, manual }) =>
  t.all(
    `insert into textbook_problem_solution_refs (crop_id, academy_id, raw_page, number_region_1k, source_kind, edited_at)
     values ($1::uuid, $2::uuid, $3::int, array[10, 10, 40, 200], 'sol', case when $4::boolean then now() end)
     on conflict (crop_id) do update
       set raw_page = excluded.raw_page, number_region_1k = excluded.number_region_1k,
           source_kind = excluded.source_kind, edited_at = excluded.edited_at
     returning crop_id`,
    [crop, S.academy, page, manual],
  );

const answerOf = (crop) =>
  t.one(`select answer_kind, answer_text, answer_source from textbook_problem_answers where crop_id = $1::uuid`, [crop]);

const seedCaches = async (crop) => {
  await t.exec(`
    insert into student_grading_ai_cache (crop_id, cache_key) values
      ('${crop}', 'equiv:v1:4'), ('${crop}', 'equiv:v1:사'), ('${crop}', 'unit_spec:v1')
    on conflict do nothing;
    insert into textbook_answer_render_assets (academy_id, crop_id) values ('${S.academy}', '${crop}');
    insert into answer_render_assets (academy_id, source_kind, source_id) values ('${S.academy}', 'textbook_crop', '${crop}');
  `);
};

const cacheState = async (crop) => ({
  keys: (await t.all(`select cache_key from student_grading_ai_cache where crop_id = $1::uuid order by cache_key`, [crop]))
    .map((r) => r.cache_key),
  basic: (await t.all(`select render_error from textbook_answer_render_assets where crop_id = $1::uuid`, [crop]))
    .map((r) => r.render_error),
  unified: (await t.all(`select render_error from answer_render_assets where source_id = $1::uuid`, [crop]))
    .map((r) => r.render_error),
});

test('VLM 일괄 저장은 사람이 고친 정답만 건너뛰고 나머지는 저장한다', async () => {
  const manual = await seedCrop(t, S, { number: 'g1' });
  const auto = await seedCrop(t, S, { number: 'g2' });
  await upsertAnswers([
    { crop_id: manual, kind: 'objective', text: '④', source: 'manual' },
    { crop_id: auto, kind: 'subjective', text: '3', source: 'vlm' },
  ]);

  const back = await upsertAnswers([
    { crop_id: manual, kind: 'objective', text: '②', source: 'vlm' },
    { crop_id: auto, kind: 'subjective', text: '5', source: 'vlm' },
  ]);

  assert.deepEqual(back.map((r) => r.crop_id), [auto], '건너뛴 행은 RETURNING 에 나오지 않는다');
  assert.deepEqual({ ...(await answerOf(manual)) }, { answer_kind: 'objective', answer_text: '④', answer_source: 'manual' });
  assert.deepEqual({ ...(await answerOf(auto)) }, { answer_kind: 'subjective', answer_text: '5', answer_source: 'vlm' });
});

test('사람이 다시 고치는 저장은 통과하고, 정답이 바뀌면 동치 캐시와 정답 그림만 무효가 된다', async () => {
  const crop = await seedCrop(t, S, { number: 'g3' });
  const other = await seedCrop(t, S, { number: 'g4' });
  await upsertAnswers([
    { crop_id: crop, kind: 'objective', text: '④', source: 'manual' },
    { crop_id: other, kind: 'objective', text: '①', source: 'vlm' },
  ]);
  await seedCaches(crop);
  await seedCaches(other);

  const back = await upsertAnswers([{ crop_id: crop, kind: 'objective', text: '③', source: 'manual' }]);

  assert.equal(back.length, 1);
  assert.equal((await answerOf(crop)).answer_text, '③');
  assert.deepEqual(await cacheState(crop), { keys: ['unit_spec:v1'], basic: ['stale_answer'], unified: ['stale_answer'] });
  assert.deepEqual(
    await cacheState(other),
    { keys: ['equiv:v1:4', 'equiv:v1:사', 'unit_spec:v1'], basic: [''], unified: [''] },
    '다른 문항의 캐시는 그대로다',
  );
});

test('같은 값을 다시 저장하면 캐시를 지우지 않는다', async () => {
  const crop = await seedCrop(t, S, { number: 'g5' });
  await upsertAnswers([{ crop_id: crop, kind: 'subjective', text: '2^2 \\times 3', source: 'vlm' }]);
  await seedCaches(crop);

  await upsertAnswers([{ crop_id: crop, kind: 'subjective', text: '2^2 \\times 3', source: 'vlm' }]);

  assert.deepEqual(await cacheState(crop), {
    keys: ['equiv:v1:4', 'equiv:v1:사', 'unit_spec:v1'],
    basic: [''],
    unified: [''],
  });
});

test('정답을 지웠다가 새로 넣어도 옛 정답의 동치 캐시가 남지 않는다', async () => {
  const crop = await seedCrop(t, S, { number: 'g6' });
  await upsertAnswers([{ crop_id: crop, kind: 'subjective', text: '18', source: 'vlm' }]);
  await t.exec(`delete from textbook_problem_answers where crop_id = '${crop}'`);
  await seedCaches(crop);

  await upsertAnswers([{ crop_id: crop, kind: 'subjective', text: '12', source: 'vlm' }]);

  assert.deepEqual((await cacheState(crop)).keys, ['unit_spec:v1']);
});

test('사람이 고친 해설 좌표는 edited_at 을 비우는 VLM 저장으로 바뀌지 않는다', async () => {
  const crop = await seedCrop(t, S, { number: 'g7' });
  await upsertRef(crop, { page: 40, manual: true });

  assert.deepEqual(await upsertRef(crop, { page: 41, manual: false }), []);
  assert.equal((await t.one(`select raw_page from textbook_problem_solution_refs where crop_id = $1::uuid`, [crop])).raw_page, 40);

  assert.equal((await upsertRef(crop, { page: 42, manual: true })).length, 1, '사람이 다시 고치면 통과한다');
  assert.equal((await t.one(`select raw_page from textbook_problem_solution_refs where crop_id = $1::uuid`, [crop])).raw_page, 42);
});

test('보호 해제 설정은 그 트랜잭션 안에서만 통한다', async () => {
  const crop = await seedCrop(t, S, { number: 'g8' });
  await upsertAnswers([{ crop_id: crop, kind: 'subjective', text: '7', source: 'manual' }]);

  await t.exec(`
    begin;
    select set_config('yggdrasill.manual_override', 'on', true);
    update textbook_problem_answers set answer_source = 'vlm' where crop_id = '${crop}';
    commit;
  `);
  assert.equal((await answerOf(crop)).answer_source, 'vlm');

  await upsertAnswers([{ crop_id: crop, kind: 'subjective', text: '8', source: 'manual' }]);
  assert.deepEqual(await upsertAnswers([{ crop_id: crop, kind: 'subjective', text: '9', source: 'vlm' }]), []);
  assert.equal((await answerOf(crop)).answer_text, '8');
});

test('학원 직원 권한으로 정답을 고쳐도 직원에게 보이지 않는 채점 캐시까지 무효가 된다', async () => {
  const crop = await seedCrop(t, S, { number: 'g9' });
  await upsertAnswers([{ crop_id: crop, kind: 'subjective', text: '6', source: 'vlm' }]);
  await seedCaches(crop);

  const seen = await t.asMember(S.staff, async () => {
    await t.exec(`update textbook_problem_answers set answer_text = '60', answer_source = 'manual' where crop_id = '${crop}'`);
    return (await t.one(`select count(*)::int as n from student_grading_ai_cache where crop_id = $1::uuid`, [crop])).n;
  });

  assert.equal(seen, 0, '직원 RLS 로는 캐시 표가 보이지 않는다');
  assert.deepEqual(await cacheState(crop), { keys: ['unit_spec:v1'], basic: ['stale_answer'], unified: ['stale_answer'] });
});
