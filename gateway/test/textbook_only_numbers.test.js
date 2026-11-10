import test from 'node:test';
import assert from 'node:assert/strict';

import {
  keepQuestionsWithNumberKeys,
  missingProblemNumbers,
  narrowCropIndexToNumbers,
  problemNumberKeySet,
  textbookOnlyNumbersFromJob,
} from '../src/problem_bank/textbook_only_numbers.js';

test('작업에 담긴 대상 번호는 공백을 지우고 같은 번호 키는 하나만 남긴다', () => {
  const job = {
    result_summary: { textbook_only_numbers: [' 0012', '12', '0013', '', null, '1-1'] },
  };
  assert.deepEqual(textbookOnlyNumbersFromJob(job), ['0012', '0013', '1-1']);
  assert.deepEqual(textbookOnlyNumbersFromJob({ result_summary: {} }), []);
  assert.deepEqual(textbookOnlyNumbersFromJob({ result_summary: { textbook_only_numbers: '12' } }), []);
  assert.deepEqual(textbookOnlyNumbersFromJob(null), []);
});

test('크롭 색인은 대상 번호와 대상이 든 세트의 번호만 남긴다', () => {
  const row = (n, page) => ({ problemNumber: n, rawPage: page });
  const byNumber = new Map([
    ['118', row('0118', 30)],
    ['119', row('0119', 30)],
    ['120', row('0120', 31)],
    ['121', row('0121', 31)],
    ['130', row('0130', 33)],
  ]);
  const setHeaderRanges = [
    { from: 118, to: 119, headerNumber: '0118~0119', rawPage: 30 },
    { from: 120, to: 121, headerNumber: '0120~0121', rawPage: 31 },
  ];
  const narrowed = narrowCropIndexToNumbers(
    { byNumber, setHeaderRanges },
    problemNumberKeySet(['0121', '0130']),
  );
  assert.deepEqual([...narrowed.byNumber.keys()], ['120', '121', '130']);
  assert.deepEqual(narrowed.setHeaderRanges.map((r) => r.headerNumber), ['0120~0121']);
});

test('지나치게 넓은 세트 범위는 형제 번호를 붙이지 않는다', () => {
  const byNumber = new Map([
    ['5', { problemNumber: '5', rawPage: 3 }],
    ['300', { problemNumber: '300', rawPage: 40 }],
  ]);
  const narrowed = narrowCropIndexToNumbers(
    { byNumber, setHeaderRanges: [{ from: 1, to: 500 }] },
    problemNumberKeySet(['5']),
  );
  assert.deepEqual([...narrowed.byNumber.keys()], ['5']);
  assert.deepEqual(narrowed.setHeaderRanges, []);
});

test('저장 전에는 대상 번호 문항만 남기고, 못 읽은 대상 번호를 알려 준다', () => {
  const questions = [
    { question_number: '120' },
    { question_number: '0121' },
    { question_number: '130' },
  ];
  const keys = problemNumberKeySet(['0121', '0130', '0131']);
  assert.deepEqual(
    keepQuestionsWithNumberKeys(questions, keys).map((q) => q.question_number),
    ['0121', '130'],
  );
  assert.deepEqual(missingProblemNumbers(['0121', '0130', '0131'], questions), ['0131']);
});
