import test from 'node:test';
import assert from 'node:assert/strict';

import {
  distributeExamScores,
  metaWithEstimatedScore,
  storedScore,
} from '../src/problem_bank/school_exam/score_distribution.js';

const q = (id, type, meta = {}) => ({ id, question_type: type, meta });
const sum = (rows, dist) =>
  rows.reduce((acc, r) => acc + (dist.scores.get(r.id) ?? storedScore(r.meta).score ?? 0), 0);

test('점수가 하나도 없으면 객관식 1 : 서술형 1.5 로 나누고 합은 100이다', () => {
  const rows = [
    ...Array.from({ length: 16 }, (_, i) => q(`o${i}`, '객관식')),
    ...Array.from({ length: 4 }, (_, i) => q(`s${i}`, '서술형')),
  ];
  const dist = distributeExamScores(rows);
  assert.equal(dist.ok, true);
  assert.equal(dist.unit, 1);
  assert.equal(sum(rows, dist), 100);
  assert.ok(dist.scores.get('s0') > dist.scores.get('o0'));
  for (const v of dist.scores.values()) assert.equal(v, Math.round(v));
});

test('읽은 점수는 그대로 두고 남은 점수만 유형별 평균 비율로 나눈다', () => {
  const rows = [
    q('a', '객관식', { score_point: 4 }),
    q('b', '객관식', { score_point: 4 }),
    q('c', '객관식'),
    q('d', '서술형', { score_point: 8 }),
    q('e', '서술형'),
  ];
  const dist = distributeExamScores(rows);
  assert.equal(dist.ok, true);
  assert.equal(dist.fixedSum, 16);
  assert.deepEqual([...dist.scores.keys()].sort(), ['c', 'e']);
  // 남은 84점을 4 : 8 로 → 28, 56
  assert.equal(dist.scores.get('c'), 28);
  assert.equal(dist.scores.get('e'), 56);
});

test('읽은 점수에 소수가 있으면 0.1점 단위로 나누고 합이 정확히 100이다', () => {
  const rows = [
    q('a', '객관식', { score_point: 5.3 }),
    q('b', '객관식'),
    q('c', '객관식'),
    q('d', '서술형'),
  ];
  const dist = distributeExamScores(rows);
  assert.equal(dist.unit, 0.1);
  assert.equal(Math.round(sum(rows, dist) * 10), 1000);
  for (const v of dist.scores.values()) assert.equal(Math.round(v * 10), v * 10);
});

test('추정한 점수는 다시 나누고, 사람이 바꾼 점수와 소문항 점수는 고정한다', () => {
  const estimated = metaWithEstimatedScore({ keep: 1 }, 7, { at: 't' });
  assert.deepEqual(estimated, { keep: 1, score_point: 7, score_estimate: { value: 7, total: 100, at: 't' } });
  assert.equal(storedScore(estimated).estimated, true);
  assert.equal(metaWithEstimatedScore(estimated, 7), null);
  // 사람이 6점으로 바꿈 → 고정
  assert.equal(storedScore({ ...estimated, score_point: 6 }).estimated, false);
  assert.deepEqual(storedScore({ score_parts: [{ sub: '1', value: 4 }, { sub: '2', value: 6 }] }), {
    score: 10,
    estimated: false,
  });
  const rows = [q('a', '객관식', estimated), q('b', '객관식', { ...estimated, score_point: 40 })];
  const dist = distributeExamScores(rows);
  assert.deepEqual([...dist.scores.entries()], [['a', 60]]);
});

test('읽은 점수의 합이 이미 총점을 채우면 나누지 않는다', () => {
  const rows = [q('a', '객관식', { score_point: 60 }), q('b', '객관식', { score_point: 40 }), q('c', '서술형')];
  const dist = distributeExamScores(rows);
  assert.equal(dist.ok, false);
  assert.equal(dist.reason, 'no_room');
  assert.equal(dist.scores.size, 0);
});
