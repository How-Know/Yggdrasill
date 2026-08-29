import test from 'node:test';
import assert from 'node:assert/strict';

import {
  answerLayoutMissingHalf,
  mergeAnswerLayoutHalf,
  remapAnswerLayoutHalf,
} from '../src/textbook/answer_layout_columns.js';

// 3-1 답지 1쪽. 모델이 오른쪽 단(머리 04~08)만 103개 읽고 끝냈다.
const rightOnly = [
  { kind: 'header', title: '04 …', bbox: [220, 538, 244, 934] },
  { kind: 'answer', problem_number: '01', bbox: [259, 538, 272, 603] },
  { kind: 'answer', problem_number: '02', bbox: [259, 626, 272, 690] },
  { kind: 'header', title: '05 …', bbox: [421, 540, 471, 936] },
  { kind: 'answer', problem_number: '01', bbox: [489, 540, 502, 571] },
];

test('한쪽 단에만 몰려 있으면 비어 있는 단을 짚는다', () => {
  assert.equal(answerLayoutMissingHalf(rightOnly), 'left');
  const leftOnly = rightOnly.map((e) => ({
    ...e,
    bbox: [e.bbox[0], e.bbox[1] - 440, e.bbox[2], e.bbox[3] - 440],
  }));
  assert.equal(answerLayoutMissingHalf(leftOnly), 'right');
});

test('두 단을 모두 읽었으면 다시 묻지 않는다', () => {
  const both = [...rightOnly, { kind: 'answer', problem_number: '09', bbox: [152, 96, 172, 495] }];
  assert.equal(answerLayoutMissingHalf(both), '');
});

test('요소가 몇 개 없는 지면은 판단하지 않는다', () => {
  assert.equal(answerLayoutMissingHalf(rightOnly.slice(0, 3)), '');
  assert.equal(answerLayoutMissingHalf([]), '');
});

test('반쪽에서 읽은 좌표를 지면 전체 기준으로 되돌린다', () => {
  const [left] = remapAnswerLayoutHalf(
    [{ kind: 'answer', problem_number: '01', bbox: [193, 188, 206, 316] }],
    'left',
  );
  assert.deepEqual(left.bbox, [193, 94, 206, 158]);

  const [right] = remapAnswerLayoutHalf(
    [{ kind: 'answer', problem_number: '01', bbox: [259, 76, 272, 206] }],
    'right',
  );
  assert.deepEqual(right.bbox, [259, 538, 272, 603]);
});

test('되찾은 왼쪽 단이 앞에 서고, 소단원마다 되풀이되는 번호도 살아남는다', () => {
  // 소단원이 바뀌면 번호가 01 부터 다시 시작한다. 번호로 겹침을 거르면
  // 왼쪽 단의 01 이 오른쪽 단의 01 과 부딪혀 통째로 버려진다.
  const merged = mergeAnswerLayoutHalf(
    rightOnly,
    [
      { kind: 'header', title: '01 제곱근', bbox: [152, 96, 172, 495] },
      { kind: 'answer', problem_number: '01', bbox: [193, 94, 206, 158] },
      { kind: 'answer', problem_number: '02', bbox: [193, 180, 206, 244] },
    ],
    'left',
  );
  assert.equal(merged.length, rightOnly.length + 3);
  assert.equal(merged[0].title, '01 제곱근');
  // 오른쪽 단만으로도 머리 04·05 아래에 "01" 이 하나씩 있었다. 왼쪽 단을
  // 되찾으면 셋이 되어야 한다 — 하나로 줄었다면 번호로 걸러 낸 것이다.
  assert.equal(merged.filter((e) => e.problem_number === '01').length, 3);
});
