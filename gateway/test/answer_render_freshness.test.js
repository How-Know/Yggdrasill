import test from 'node:test';
import assert from 'node:assert/strict';

import {
  currentAnswerRenderHashMap,
  partitionFreshAnswerRenderRows,
} from '../src/problem_bank/answer_render_freshness.js';

const v11 = 'answer-xelatex-v11-uniform-line';
const v10 = 'answer-xelatex-v10';

const current = currentAnswerRenderHashMap([
  { sourceId: 'q1', answerKind: 'subjective', styleVersion: v11, sourceHash: 'h1-v11' },
  { sourceId: 'q1', answerKind: 'subjective', styleVersion: v10, sourceHash: 'h1-v10' },
  { sourceId: 'q1', answerKind: 'subjective#(1)', styleVersion: v11, sourceHash: 'h1-p1' },
]);

test('keeps rows rendered from the current answer', () => {
  const rows = [
    { source_id: 'q1', answer_kind: 'subjective', style_version: v11, source_hash: 'h1-v11' },
    { source_id: 'q1', answer_kind: 'subjective#(1)', style_version: v11, source_hash: 'h1-p1' },
  ];
  const { fresh, stale } = partitionFreshAnswerRenderRows(rows, current);
  assert.equal(fresh.length, 2);
  assert.equal(stale.length, 0);
});

test('drops rows whose answer changed after rendering, per style', () => {
  const rows = [
    { source_id: 'q1', answer_kind: 'subjective', style_version: v11, source_hash: 'old' },
    { source_id: 'q1', answer_kind: 'subjective', style_version: v10, source_hash: 'h1-v10' },
  ];
  const { fresh, stale } = partitionFreshAnswerRenderRows(rows, current);
  assert.deepEqual(fresh.map((r) => r.style_version), [v10]);
  assert.deepEqual(stale.map((r) => r.style_version), [v11]);
});

test('drops rows for answers that no longer render and rows without a hash', () => {
  const rows = [
    { source_id: 'q2', answer_kind: 'subjective', style_version: v11, source_hash: 'x' },
    { source_id: 'q1', answer_kind: 'subjective', style_version: v11, source_hash: '' },
  ];
  const { fresh, stale } = partitionFreshAnswerRenderRows(rows, current);
  assert.equal(fresh.length, 0);
  assert.equal(stale.length, 2);
});

test('keeps every row when the current answers could not be read', () => {
  const rows = [
    { source_id: 'q1', answer_kind: 'subjective', style_version: v11, source_hash: 'old' },
  ];
  const { fresh, stale } = partitionFreshAnswerRenderRows(rows, null);
  assert.equal(fresh.length, 1);
  assert.equal(stale.length, 0);
});
