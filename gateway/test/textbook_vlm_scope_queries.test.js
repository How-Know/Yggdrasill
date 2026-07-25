import test from 'node:test';
import assert from 'node:assert/strict';

import {
  fetchTextbookAnswerSidecars,
  fetchTextbookCropPages,
  normalizedTextbookSubIndex,
} from '../src/problem_bank/extract_engines/vlm/runner.js';

function queryClient(responses) {
  const calls = [];
  return {
    calls,
    from(table) {
      const call = { table, filters: [] };
      calls.push(call);
      const builder = {
        select() { return builder; },
        eq(column, value) {
          call.filters.push([column, value]);
          return builder;
        },
        gte(column, value) {
          call.filters.push([`gte:${column}`, value]);
          return builder;
        },
        lte(column, value) {
          call.filters.push([`lte:${column}`, value]);
          return builder;
        },
        in() { return builder; },
        then(resolve, reject) {
          return Promise.resolve(responses[table] ?? { data: [], error: null })
            .then(resolve, reject);
        },
      };
      return builder;
    },
  };
}

const scope = {
  book_id: 'book-1',
  grade_label: '중1',
  big_order: 1,
  mid_order: 2,
  sub_key: 'B',
  subIndex: '3',
};

test('textbook crop and answer-sidecar queries share normalized sub_index', async () => {
  const client = queryClient({
    textbook_problem_crops: {
      data: [{ id: 'crop-1', problem_number: '1' }],
      error: null,
    },
    textbook_problem_answers: { data: [], error: null },
  });

  await fetchTextbookCropPages({
    supa: client,
    academyId: 'academy-1',
    textbookScope: scope,
  });
  await fetchTextbookAnswerSidecars({
    supa: client,
    academyId: 'academy-1',
    textbookScope: scope,
  });

  const cropQueries = client.calls.filter(
    (call) => call.table === 'textbook_problem_crops',
  );
  assert.equal(cropQueries.length, 2);
  for (const query of cropQueries) {
    assert.deepEqual(
      query.filters.find(([column]) => column === 'sub_index'),
      ['sub_index', 3],
    );
  }
});

// 개념원리는 한 중단원 안에서 소단원마다 같은 카테고리가 되풀이된다. 런이
// 페이지 범위를 들고 있으면 기대 문항도 그 범위로 좁혀야, 잘라낸 PDF 에 없는
// 번호가 미스로 남아 부분 추출을 완료로 오인하는 일이 없다.
test('page-scoped run narrows crop lookup by page range instead of sub_index', async () => {
  const client = queryClient({
    textbook_problem_crops: {
      data: [{ id: 'crop-1', problem_number: '1', raw_page: 120 }],
      error: null,
    },
    textbook_problem_answers: { data: [], error: null },
  });

  const pagedScope = {
    ...scope,
    sub_key: 'C',
    raw_page_from: 118,
    raw_page_to: 123,
  };

  await fetchTextbookCropPages({
    supa: client,
    academyId: 'academy-1',
    textbookScope: pagedScope,
  });
  await fetchTextbookAnswerSidecars({
    supa: client,
    academyId: 'academy-1',
    textbookScope: pagedScope,
  });

  const cropQueries = client.calls.filter(
    (call) => call.table === 'textbook_problem_crops',
  );
  assert.equal(cropQueries.length, 2);
  for (const query of cropQueries) {
    assert.deepEqual(
      query.filters.find(([column]) => column === 'gte:raw_page'),
      ['gte:raw_page', 118],
    );
    assert.deepEqual(
      query.filters.find(([column]) => column === 'lte:raw_page'),
      ['lte:raw_page', 123],
    );
    assert.equal(
      query.filters.find(([column]) => column === 'sub_index'),
      undefined,
    );
  }
});

test('sub_index normalization accepts zero and rejects invalid values', () => {
  assert.equal(normalizedTextbookSubIndex({ sub_index: 0 }), 0);
  assert.equal(normalizedTextbookSubIndex({ subIndex: '4' }), 4);
  assert.equal(normalizedTextbookSubIndex({ sub_index: -1 }), null);
  assert.equal(normalizedTextbookSubIndex({}), null);
});
