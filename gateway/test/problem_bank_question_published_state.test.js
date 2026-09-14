import assert from 'node:assert/strict';
import test from 'node:test';

import {
  _buildQuestionWritePayload,
} from '../src/problem_bank_extract_worker.js';

function payloadFor(isPublished) {
  return _buildQuestionWritePayload({
    question: {
      question_number: '1',
      is_published: isPublished,
      meta: {},
    },
    classification: {},
    academyId: 'academy-1',
    documentId: 'document-1',
    extractJobId: 'job-1',
    questionUid: 'question-uid-1',
  });
}

test('newly extracted questions are published by default', () => {
  assert.equal(payloadFor(undefined).is_published, true);
});

test('re-extraction preserves an explicitly private question', () => {
  assert.equal(payloadFor(false).is_published, false);
});
