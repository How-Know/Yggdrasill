import test from 'node:test';
import assert from 'node:assert/strict';

import { createExtractProgressTracker } from '../src/problem_bank/extract_progress.js';

const fixedNow = () => new Date('2026-11-09T00:00:00.000Z');

test('청크가 끝날 때마다 끝난 청크 수와 문항 번호를 순서대로 쓴다', async () => {
  const writes = [];
  const tracker = createExtractProgressTracker({
    now: fixedNow,
    write: async (progress) => {
      await new Promise((resolve) => setTimeout(resolve, 5));
      writes.push(progress);
    },
  });

  tracker.onEvent('vlm_call_start', {
    chunks: [
      { chunkIndex: 0, expectedQuestionCount: 3 },
      { chunkIndex: 1, expectedQuestionCount: 2 },
    ],
  });
  tracker.onEvent('vlm_chunk_call_done', { chunkIndex: 0, questionNumbers: ['1', ' 2', '3'] });
  tracker.onEvent('vlm_chunk_call_error', { chunkIndex: 1 });
  tracker.onEvent('vlm_chunk_call_done', { chunkIndex: 1, questionNumbers: ['4', '5', '3'] });
  await tracker.idle();

  assert.equal(writes.length, 3);
  assert.deepEqual(writes[0], {
    chunks_total: 2,
    chunks_done: 0,
    expected_count: 5,
    numbers_done: [],
    updated_at: '2026-11-09T00:00:00.000Z',
  });
  assert.equal(writes[1].chunks_done, 1);
  assert.deepEqual(writes[1].numbers_done, ['1', '2', '3']);
  assert.equal(writes[2].chunks_done, 2);
  assert.deepEqual(writes[2].numbers_done, ['1', '2', '3', '4', '5']);
});

test('빠진 번호만 읽는 런은 대상 번호만 세고, 함께 읽은 세트 번호는 뺀다', async () => {
  const writes = [];
  const tracker = createExtractProgressTracker({
    now: fixedNow,
    write: async (progress) => {
      writes.push(progress);
    },
  });

  tracker.onEvent('vlm_call_start', {
    chunks: [{ chunkIndex: 0, expectedQuestionCount: 3 }],
    onlyQuestionNumbers: ['0121', '0130'],
  });
  tracker.onEvent('vlm_chunk_call_done', {
    chunkIndex: 0,
    questionNumbers: ['0120', '0121', '0130'],
  });
  await tracker.idle();

  assert.equal(writes[0].expected_count, 2);
  assert.deepEqual(writes[1].numbers_done, ['0121', '0130']);
});

test('대상 번호가 읽을 쪽에 하나도 없으면 분모는 0이다', async () => {
  const writes = [];
  const tracker = createExtractProgressTracker({
    now: fixedNow,
    write: async (progress) => {
      writes.push(progress);
    },
  });
  tracker.onEvent('vlm_call_start', {
    chunks: [{ chunkIndex: 0, expectedQuestionCount: 1 }],
    onlyQuestionNumbers: [],
  });
  tracker.onEvent('vlm_chunk_call_done', { chunkIndex: 0, questionNumbers: ['0120'] });
  await tracker.idle();
  assert.equal(writes[0].expected_count, 0);
  assert.deepEqual(writes[1].numbers_done, []);
});

test('시작 이벤트 전의 청크 완료와 쓰기 실패는 추출을 멈추지 않는다', async () => {
  let calls = 0;
  const tracker = createExtractProgressTracker({
    now: fixedNow,
    write: async () => {
      calls += 1;
      throw new Error('db down');
    },
  });
  assert.equal(tracker.onEvent('vlm_chunk_call_done', { chunkIndex: 0, questionNumbers: ['1'] }), null);
  tracker.onEvent('vlm_call_start', { chunks: [] });
  tracker.onEvent('vlm_chunk_call_done', { chunkIndex: 0, questionNumbers: ['1'] });
  await tracker.idle();
  assert.equal(calls, 2);
});
