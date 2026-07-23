import test from 'node:test';
import assert from 'node:assert/strict';

import {
  canonicalize,
  hashQuestionContent,
} from '../src/question_render_cache_key.js';
import {
  problemNumberKey,
  resolveQuestion,
} from '../src/problem_bank_question_render_worker.js';

const RENDERER_VERSION = 'pb_render_v4_slotmeasure_01:student-single-v1';

test('problem number keys match padded textbook numbers safely', () => {
  assert.equal(problemNumberKey('0009'), '9');
  assert.equal(problemNumberKey('9'), '9');
  assert.equal(problemNumberKey(' 01 A '), '01a');
});

test('canonicalize sorts nested object keys deterministically', () => {
  assert.deepEqual(
    canonicalize({ z: 1, a: { y: 2, b: 3 }, list: [{ d: 4, c: 5 }] }),
    { a: { b: 3, y: 2 }, list: [{ c: 5, d: 4 }], z: 1 },
  );
});

test('question content hash covers only render-safe question fields', () => {
  const base = {
    stem: 'x의 값을 구하여라.',
    choices: [{ label: '①', text: '1' }],
    figure_refs: [{ item_id: 'figure-1' }],
    meta: { crop_id: 'crop-1', nested: { b: 2, a: 1 } },
  };
  const reordered = {
    ...base,
    meta: { nested: { a: 1, b: 2 }, crop_id: 'crop-1' },
    objective_answer_key: '①',
    subjective_answer: '1',
    reviewer_notes: '학생 렌더에 포함되면 안 됨',
  };
  assert.deepEqual(
    hashQuestionContent(base, 'student-single-v1', RENDERER_VERSION),
    hashQuestionContent(reordered, 'student-single-v1', RENDERER_VERSION),
  );
});

test('cache key changes with profile or visible content', () => {
  const question = {
    stem: '문항 A',
    choices: [],
    figure_refs: [],
    meta: {},
  };
  const first = hashQuestionContent(
    question,
    'student-single-v1',
    RENDERER_VERSION,
  );
  const changedContent = hashQuestionContent(
    { ...question, stem: '문항 B' },
    'student-single-v1',
    RENDERER_VERSION,
  );
  const changedProfile = hashQuestionContent(
    question,
    'other-profile',
    RENDERER_VERSION,
  );
  assert.notEqual(first.contentHash, changedContent.contentHash);
  assert.notEqual(first.cacheKey, changedContent.cacheKey);
  assert.equal(first.contentHash, changedProfile.contentHash);
  assert.notEqual(first.cacheKey, changedProfile.cacheKey);
});

test('cache key isolates identical content assigned to different crops', () => {
  const question = {
    stem: '같은 문항 내용',
    choices: [],
    figure_refs: [],
    meta: {},
  };
  const first = hashQuestionContent(
    question,
    'student-single-v1',
    RENDERER_VERSION,
    'academy-1:crop-1',
  );
  const second = hashQuestionContent(
    question,
    'student-single-v1',
    RENDERER_VERSION,
    'academy-1:crop-2',
  );

  assert.equal(first.contentHash, second.contentHash);
  assert.notEqual(first.cacheKey, second.cacheKey);
});

test('question resolution prefers the canonical crop link', async () => {
  const tables = [];
  const client = {
    from(table) {
      tables.push(table);
      const filters = [];
      const builder = {
        select() { return builder; },
        eq(column, value) {
          filters.push([column, value]);
          return builder;
        },
        async maybeSingle() {
          if (table === 'textbook_crop_question_links') {
            assert.deepEqual(filters, [
              ['academy_id', 'academy-1'],
              ['crop_id', 'crop-1'],
            ]);
            return { data: { pb_question_id: 'question-1' }, error: null };
          }
          if (table === 'pb_questions') {
            assert.ok(
              filters.some(([column, value]) =>
                column === 'id' && value === 'question-1'
              ),
            );
            return {
              data: { id: 'question-1', stem: 'canonical question' },
              error: null,
            };
          }
          throw new Error(`unexpected table: ${table}`);
        },
      };
      return builder;
    },
  };

  const question = await resolveQuestion(client, {
    academy_id: 'academy-1',
    crop_id: 'crop-1',
    pb_question_id: 'stale-question',
  });

  assert.equal(question.id, 'question-1');
  assert.deepEqual(tables, [
    'textbook_crop_question_links',
    'pb_questions',
  ]);
});
