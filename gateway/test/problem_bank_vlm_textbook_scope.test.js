import test from 'node:test';
import assert from 'node:assert/strict';

import {
  isRetryableVlmChunkError,
  selectExpectedQuestions,
} from '../src/problem_bank/extract_engines/vlm/runner.js';

test('textbook VLM retries transient fetch failures but not daily quota exhaustion', () => {
  assert.equal(isRetryableVlmChunkError('fetch failed'), true);
  assert.equal(isRetryableVlmChunkError('ECONNRESET: socket hang up'), true);
  assert.equal(
    isRetryableVlmChunkError(
      'vlm_gemini_http_499: { "error": { "code": 499, "message": "The operation was cancelled.", "status": "CANCELLED" } }',
    ),
    true,
  );
  assert.equal(
    isRetryableVlmChunkError(
      'RESOURCE_EXHAUSTED generate_requests_per_model_per_day please retry in 12h',
    ),
    false,
  );
});

test('textbook VLM keeps only crop-scoped questions in crop order', () => {
  const questions = [
    { question_number: '12', stem: '확인 체크 문항' },
    { question_number: '010', stem: '필수유형 문항 10' },
    { question_number: '11', stem: '필수유형 문항 11' },
    { question_number: '99', stem: '연습문제 문항' },
  ];

  assert.deepEqual(
    selectExpectedQuestions(questions, ['10', '11']),
    [
      { question_number: '10', stem: '필수유형 문항 10' },
      { question_number: '11', stem: '필수유형 문항 11' },
    ],
  );
});

test('textbook VLM deduplicates repeated expected question numbers', () => {
  const questions = [
    { question_number: '7', stem: '첫 번째 결과' },
    { question_number: '7', stem: '중복 결과' },
  ];

  assert.deepEqual(selectExpectedQuestions(questions, ['7']), [
    { question_number: '7', stem: '첫 번째 결과' },
  ]);
});

test('non-textbook VLM remains unchanged when no crop scope is provided', () => {
  const questions = [
    { question_number: '1' },
    { question_number: '2' },
  ];

  assert.strictEqual(selectExpectedQuestions(questions, []), questions);
});
