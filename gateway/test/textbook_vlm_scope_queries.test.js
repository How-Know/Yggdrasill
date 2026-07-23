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

test('sub_index normalization accepts zero and rejects invalid values', () => {
  assert.equal(normalizedTextbookSubIndex({ sub_index: 0 }), 0);
  assert.equal(normalizedTextbookSubIndex({ subIndex: '4' }), 4);
  assert.equal(normalizedTextbookSubIndex({ sub_index: -1 }), null);
  assert.equal(normalizedTextbookSubIndex({}), null);
});
