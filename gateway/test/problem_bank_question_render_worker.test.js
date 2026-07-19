import test from 'node:test';
import assert from 'node:assert/strict';

import {
  canonicalize,
  hashQuestionContent,
} from '../src/question_render_cache_key.js';

const RENDERER_VERSION = 'pb_render_v4_slotmeasure_01:student-single-v1';

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
