import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  fetchManualMarkers,
  partitionStaleCrops,
  skippedCropIds,
} from '../src/textbook/manual_guard.js';
import { buildTextbookCropStorageKey } from '../src/storage/driver.js';

// 사람이 고친 정답·해설 좌표는 DB 트리거가 덮는 쓰기를 건너뛴다. 게이트웨이는
// 그 사실을 알리고, 범위 동기화가 크롭을 지워 연쇄 삭제로 날리지 않게 한다.

const here = path.dirname(fileURLToPath(import.meta.url));
const apiSource = fs.readFileSync(
  path.join(here, '..', 'src', 'problem_bank_api.js'),
  'utf8',
);

function markerClient(tables, calls = []) {
  return {
    calls,
    from(table) {
      const call = { table, filters: [] };
      calls.push(call);
      const builder = {
        select() { return builder; },
        in(column, values) { call.filters.push(['in', column, values.length]); return builder; },
        eq(column, value) { call.filters.push(['eq', column, value]); return builder; },
        not(column, op, value) { call.filters.push(['not', column, op, value]); return builder; },
        then(resolve, reject) {
          const result = tables[table] instanceof Error
            ? { data: null, error: tables[table] }
            : { data: (tables[table] || []).map((crop_id) => ({ crop_id })), error: null };
          return Promise.resolve(result).then(resolve, reject);
        },
      };
      return builder;
    },
  };
}

test('DB 가 돌려주지 않은 crop_id 를 지킨 행으로 센다', () => {
  assert.deepEqual(
    skippedCropIds(['a', 'b', 'c', 'a', ''], [{ crop_id: 'b' }]),
    ['a', 'c'],
  );
  assert.deepEqual(skippedCropIds(['a'], null), ['a']);
});

test('문제은행이 걸린 크롭과 사람이 고친 자료가 있는 크롭은 지우지 않고 이유를 남긴다', () => {
  const markers = {
    manualAnswer: new Set(['c3', 'c5']),
    manualSolution: new Set(['c4']),
    questionLink: new Set(['c2']),
  };
  const stale = [
    { id: 'c1', problem_number: '1', pb_question_uid: null },
    { id: 'c2', problem_number: '2', pb_question_uid: null },
    { id: 'c3', problem_number: '3', pb_question_uid: null },
    { id: 'c4', problem_number: '4', pb_question_uid: '' },
    { id: 'c5', problem_number: '5', pb_question_uid: '7d6d4f7e-0000-4000-8000-000000000000' },
  ];

  const out = partitionStaleCrops(stale, markers);

  assert.deepEqual(out.deletable.map((row) => row.id), ['c1']);
  assert.deepEqual(out.questionNumbers, ['2', '5'], '기존 안내(문제은행에서 정리)에 맞는 번호만');
  assert.deepEqual(out.manualNumbers, ['3', '4']);
  assert.deepEqual(
    Object.fromEntries(out.kept.map((row) => [row.problemNumber, row.reasons])),
    {
      2: ['question_link'],
      3: ['manual_answer'],
      4: ['manual_solution'],
      5: ['pb_question', 'manual_answer'],
    },
  );
});

test('표시는 세 표에서 200개씩 나눠 읽고, 수동 행만 고른다', async () => {
  const ids = Array.from({ length: 450 }, (_, i) => `c${i}`);
  const client = markerClient({
    textbook_problem_answers: ['c1', 'c440'],
    textbook_problem_solution_refs: ['c2'],
    textbook_crop_question_links: ['c3'],
  });

  const markers = await fetchManualMarkers({ supa: client, cropIds: ids });

  assert.deepEqual([...markers.manualAnswer].sort(), ['c1', 'c440']);
  assert.deepEqual([...markers.manualSolution], ['c2']);
  assert.deepEqual([...markers.questionLink], ['c3']);
  assert.equal(client.calls.length, 9, '3 묶음 × 3 표');
  const answers = client.calls.find((c) => c.table === 'textbook_problem_answers');
  assert.deepEqual(answers.filters, [['in', 'crop_id', 200], ['eq', 'answer_source', 'manual']]);
  const refs = client.calls.find((c) => c.table === 'textbook_problem_solution_refs');
  assert.deepEqual(refs.filters, [['in', 'crop_id', 200], ['not', 'edited_at', 'is', null]]);
});

test('표시를 읽지 못하면 오류로 멈춘다(아무것도 지우지 않게)', async () => {
  const client = markerClient({ textbook_problem_solution_refs: new Error('timeout') });
  await assert.rejects(
    fetchManualMarkers({ supa: client, cropIds: ['c1'] }),
    /manual_markers_solution_refs_failed: timeout/,
  );
  const none = await fetchManualMarkers({ supa: markerClient({}), cropIds: [] });
  assert.equal(none.manualAnswer.size, 0);
});

test('범위 동기화는 보호 규칙으로 지울 크롭을 고르고, 실패하면 지우지 않는다', () => {
  const start = apiSource.indexOf('async function handleTextbookCropsSyncScope');
  const end = apiSource.indexOf('\n}\n', start);
  const handler = apiSource.slice(start, end);
  assert.match(handler, /fetchManualMarkers\(/);
  assert.match(handler, /partitionStaleCrops\(stale, markers\)/);
  assert.match(handler, /crop_sync_guard_failed/);
  assert.equal(/pb_question_uid \|\| ""\)\.trim\(\)\s*,?\s*\)/.test(handler), false, '옛 단독 규칙이 남아 있지 않다');
});

test('정답 일괄 저장은 실제로 저장된 행만 정답 그림 렌더에 넘긴다', () => {
  const start = apiSource.indexOf('async function handleTextbookAnswersBatchUpsert');
  const end = apiSource.indexOf('\n}\n', start);
  const handler = apiSource.slice(start, end);
  assert.match(handler, /skippedCropIds\(/);
  assert.match(handler, /queueTextbookAnswerRender\(\{ academyId, answerRows: writtenRows \}\)/);
  assert.equal(/answerRows: rows\b/.test(handler), false);
});

test('크롭 저장 경로는 소단원 순번이 다르면 갈리고, 0 이면 예전 경로 그대로다', () => {
  const base = {
    academyId: 'a1',
    bookId: 'b1',
    gradeLabel: '1-1',
    bigOrder: 0,
    midOrder: 1,
    subKey: 'b',
    problemNumber: '12',
  };
  assert.equal(
    buildTextbookCropStorageKey(base),
    'academies/a1/books/b1/1-1/0_1_B/12.png',
  );
  assert.equal(
    buildTextbookCropStorageKey({ ...base, subIndex: 0 }),
    buildTextbookCropStorageKey(base),
  );
  assert.equal(
    buildTextbookCropStorageKey({ ...base, subIndex: 2 }),
    'academies/a1/books/b1/1-1/0_1_B-2/12.png',
  );
  assert.equal(
    buildTextbookCropStorageKey({ ...base, subIndex: 'x' }),
    buildTextbookCropStorageKey(base),
  );
  assert.match(apiSource, /subKey: subKeyRaw,\s*subIndex,\s*problemNumber,/);
});
