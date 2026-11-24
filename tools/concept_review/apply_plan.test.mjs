// node --test tools/concept_review/apply_plan.test.mjs
import assert from 'node:assert/strict';
import test from 'node:test';

import { chunk, classify, readyForRecords, recordIsGood } from './apply_plan.mjs';

const concept = (over = {}) => ({ id: 'c1', judged_content: '본문\n둘째 줄', edit: null, placements: [], ...over });

test('본문이 판단할 때와 같으면 그대로, 이번에 고친 본문이면 고침, 그 밖에는 바뀜으로 본다', () => {
  assert.equal(classify(concept(), '본문\r\n둘째 줄 ', new Set()), 'as_judged');
  assert.equal(classify(concept({ edit: { content: '고친 본문' } }), '고친 본문', new Set()), 'edited');
  assert.equal(classify(concept({ edit: { content: '고친 본문' } }), '서버가 다듬은 본문', new Set(['c1'])), 'edited');
  assert.equal(classify(concept(), '누가 바꾼 본문', new Set(['c1'])), 'changed');
  assert.equal(classify(concept(), undefined, new Set()), 'missing');
});

test('유효한 문제 없음·근거 미확인 기록이 있는 범위는 다시 쓰지 않는다', () => {
  assert.equal(recordIsGood('meaning', null), false);
  assert.equal(recordIsGood('meaning', { outcome: 'no_issue_found', stale: false }), true);
  assert.equal(recordIsGood('meaning', { outcome: 'no_issue_found', stale: true }), false);
  assert.equal(recordIsGood('meaning', { outcome: 'issue_found', stale: false }), false);
  assert.equal(recordIsGood('meaning', { outcome: 'unverified', stale: false, detail: { evidence_gaps: ['figure'] } }), true);
  assert.equal(recordIsGood('meaning', { outcome: 'unverified', stale: false, detail: {} }), false);
  // 기초 개념 범위에는 '근거 미확인' 충족이 없다.
  assert.equal(recordIsGood('foundation', { outcome: 'unverified', stale: false, detail: { evidence_gaps: ['source'] } }), false);
});

test('본문 고침과 배치가 끝난 개념만 기록을 쓴다', () => {
  const placed = concept({ placements: [{ unit_id: 'u1' }] });
  assert.equal(readyForRecords(placed, 'as_judged', new Set()), false);
  assert.equal(readyForRecords(placed, 'as_judged', new Set(['u1'])), true);
  assert.equal(readyForRecords(concept({ edit: { content: 'x' } }), 'as_judged', new Set()), false);
  assert.equal(readyForRecords(concept({ edit: { content: 'x' } }), 'edited', new Set()), true);
  assert.equal(readyForRecords(concept(), 'changed', new Set()), false);
});

test('묶음은 크기를 넘지 않게 나눈다', () => {
  assert.deepEqual(chunk([1, 2, 3, 4, 5], 2), [[1, 2], [3, 4], [5]]);
  assert.deepEqual(chunk([], 20), []);
});
