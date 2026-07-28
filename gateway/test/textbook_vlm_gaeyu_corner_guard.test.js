import test from 'node:test';
import assert from 'node:assert/strict';

import { normalizeAnswerResult } from '../src/textbook/vlm_answer_client.js';
import { normalizeSolutionRefsResult } from '../src/textbook/vlm_solution_refs_client.js';
import { buildExtractAnswersPrompt } from '../src/textbook/vlm_answer_prompt.js';
import { buildDetectSolutionRefsPrompt } from '../src/textbook/vlm_solution_refs_prompt.js';

// 개념+유형 답지·해설은 코너 박스마다 번호가 1번부터 다시 시작한다. 실제
// 재현: 필수 문제 1~5 를 찾던 모델이 옆에 있던 "쏙쏙 P.112" 박스의 1~5 답을
// 필수 문제 것인 양 올렸다. 모델이 스스로 밝힌 source_page 가 기대 배지와
// 다르면 버린다.

const 필수 = '필수 문제';
const 쏙쏙 = 'STEP1 쏙쏙 개념 익히기';

test('answers from a different corner box are dropped', () => {
  const out = normalizeAnswerResult(
    {
      items: [
        // P.113 배지의 필수 문제 7 — 기대와 일치한다.
        {
          problem_number: '7',
          kind: 'subjective',
          answer_text: 'a=-3, b=3',
          source_corner: 필수,
          source_page: 113,
        },
        // 옆에 있던 쏙쏙 P.112 박스의 1번을 필수 문제 1번으로 올린 경우.
        {
          problem_number: '1',
          kind: 'subjective',
          answer_text: '6',
          source_corner: 쏙쏙,
          source_page: 112,
        },
      ],
    },
    {
      expectedNumbers: ['1', '7'],
      expectedEntries: [
        { number: '1', corner: 필수, page: 107 },
        { number: '7', corner: 필수, page: 113 },
      ],
    },
  );
  assert.deepEqual(
    out.items.map((i) => i.problem_number),
    ['7'],
  );
});

test('a range badge covers every page it spans', () => {
  // 답지의 쏙쏙 박스는 "P. 12~13" 처럼 두 쪽을 덮고 그 안에 1~10 이 이어진다.
  // 시작 쪽만 비교하면 13쪽 문항(6~10)이 통째로 버려진다.
  const items = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10].map((n) => ({
    problem_number: `${n}`,
    kind: 'subjective',
    answer_text: `${n}`,
    source_corner: 쏙쏙,
    source_page: 12,
    source_page_end: 13,
  }));
  const out = normalizeAnswerResult(
    { items },
    {
      expectedNumbers: items.map((i) => i.problem_number),
      expectedEntries: [1, 2, 3, 4, 5].map((n) => ({
        number: `${n}`,
        corner: 쏙쏙,
        page: 12,
      })).concat(
        [6, 7, 8, 9, 10].map((n) => ({ number: `${n}`, corner: 쏙쏙, page: 13 })),
      ),
    },
  );
  assert.equal(out.items.length, 10);
});

test('a page outside the badge range is still dropped', () => {
  const out = normalizeAnswerResult(
    {
      items: [
        {
          problem_number: '1',
          kind: 'subjective',
          answer_text: '6',
          source_corner: 쏙쏙,
          source_page: 12,
          source_page_end: 13,
        },
      ],
    },
    {
      expectedNumbers: ['1'],
      expectedEntries: [{ number: '1', corner: 쏙쏙, page: 20 }],
    },
  );
  assert.equal(out.items.length, 0);
});

test('corner names are matched loosely', () => {
  // 모델은 "STEP 1 쏙쏙", "쏙쏙 개념 익히기" 처럼 표기를 흔들어 적는다.
  const out = normalizeAnswerResult(
    {
      items: [
        {
          problem_number: '1',
          kind: 'subjective',
          answer_text: '6',
          source_corner: '쏙쏙 개념 익히기',
          source_page: 12,
        },
      ],
    },
    {
      expectedNumbers: ['1'],
      expectedEntries: [{ number: '1', corner: 쏙쏙, page: 12 }],
    },
  );
  assert.equal(out.items.length, 1);
});

test('a wrong corner is dropped even when the page happens to match', () => {
  const out = normalizeAnswerResult(
    {
      items: [
        {
          problem_number: '1',
          kind: 'subjective',
          answer_text: '6',
          source_corner: 쏙쏙,
          source_page: 107,
        },
      ],
    },
    {
      expectedNumbers: ['1'],
      expectedEntries: [{ number: '1', corner: 필수, page: 107 }],
    },
  );
  assert.equal(out.items.length, 0);
});

test('answers without a reported badge are kept', () => {
  const out = normalizeAnswerResult(
    {
      items: [
        { problem_number: '1', kind: 'subjective', answer_text: '6' },
        {
          problem_number: '2',
          kind: 'subjective',
          answer_text: '8',
          source_page: 0,
        },
      ],
    },
    {
      expectedNumbers: ['1', '2'],
      expectedEntries: [
        { number: '1', corner: 필수, page: 107 },
        { number: '2', corner: 필수, page: 107 },
      ],
    },
  );
  assert.deepEqual(
    out.items.map((i) => i.problem_number),
    ['1', '2'],
  );
});

test('series without corner entries are unaffected', () => {
  const out = normalizeAnswerResult(
    {
      items: [
        {
          problem_number: '0012',
          kind: 'objective',
          answer_text: '3',
          source_page: 999,
        },
      ],
    },
    { expectedNumbers: ['0012'] },
  );
  assert.equal(out.items.length, 1);
});

test('solution refs from a different corner block are dropped', () => {
  const out = normalizeSolutionRefsResult(
    {
      items: [
        {
          problem_number: '1',
          number_region: [10, 10, 20, 20],
          source_corner: 쏙쏙,
          source_page: 112,
        },
        {
          problem_number: '7',
          number_region: [30, 10, 40, 20],
          source_corner: 필수,
          source_page: 113,
        },
      ],
    },
    {
      expectedNumbers: ['1', '7'],
      expectedEntries: [
        { number: '1', corner: 필수, page: 107 },
        { number: '7', corner: 필수, page: 113 },
      ],
    },
  );
  assert.deepEqual(
    out.items.map((i) => i.problem_number),
    ['7'],
  );
});

// 여기부터: 같은 번호가 코너마다 다시 나올 때(개념+유형 1-1 중단원 1에서
// 번호 "1" 인 문항이 다섯 개였다) 서로 덮어쓰지 않는지.

test('same number in different corners is kept as separate items', () => {
  const entries = [
    { number: '1', corner: 필수, page: 107 },
    { number: '1', corner: 쏙쏙, page: 112 },
    { number: '1', corner: '탄탄 단원 다지기', page: 120 },
  ];
  const out = normalizeAnswerResult(
    {
      items: [
        {
          problem_number: '1',
          kind: 'subjective',
          answer_text: '필수답',
          source_corner: 필수,
          source_page: 107,
        },
        {
          problem_number: '1',
          kind: 'subjective',
          answer_text: '쏙쏙답',
          source_corner: 쏙쏙,
          source_page: 112,
        },
        {
          problem_number: '1',
          kind: 'subjective',
          answer_text: '탄탄답',
          source_corner: '탄탄',
          source_page: 120,
        },
      ],
    },
    { expectedNumbers: ['1', '1', '1'], expectedEntries: entries },
  );
  assert.deepEqual(
    out.items.map((i) => [i.expected_index, i.answer_text]),
    [
      [0, '필수답'],
      [1, '쏙쏙답'],
      [2, '탄탄답'],
    ],
  );
});

test('expected_index follows the position the caller declared', () => {
  // 게이트웨이는 번호가 빈 항목을 걸러낸다. 걸러낸 뒤 다시 세면 앱이 보낸
  // 배열과 위치가 어긋나 엉뚱한 크롭에 정답이 붙는다.
  const out = normalizeAnswerResult(
    {
      items: [
        {
          problem_number: '1',
          kind: 'subjective',
          answer_text: '쏙쏙답',
          source_corner: 쏙쏙,
          source_page: 112,
        },
      ],
    },
    {
      expectedNumbers: ['1'],
      expectedEntries: [
        { number: '1', corner: 쏙쏙, page: 112, position: 7 },
      ],
    },
  );
  assert.deepEqual(
    out.items.map((i) => i.expected_index),
    [7],
  );
});

test('a range badge expands only inside the corner it came from', () => {
  // 필수 문제 "1~3" 이 옆 박스 쏙쏙의 1~3 으로 번지면 안 된다.
  const entries = [
    { number: '1', corner: 필수, page: 107 },
    { number: '2', corner: 필수, page: 107 },
    { number: '3', corner: 필수, page: 107 },
    { number: '1', corner: 쏙쏙, page: 112 },
    { number: '2', corner: 쏙쏙, page: 112 },
  ];
  const out = normalizeAnswerResult(
    {
      items: [
        {
          problem_number: '1~3',
          kind: 'subjective',
          answer_text: '풀이 참조',
          source_corner: 필수,
          source_page: 107,
        },
      ],
    },
    { expectedNumbers: entries.map((e) => e.number), expectedEntries: entries },
  );
  // 배지 원문("1~3")도 한 줄 남는다. 문항번호 자체가 범위인 교재(RPM 세트
  // 문항)가 있어서 버리지 않는다. 펼쳐진 쪽만 확인한다.
  assert.deepEqual(
    out.items
      .filter((i) => i.expected_index !== undefined)
      .map((i) => i.expected_index),
    [0, 1, 2],
  );
});

test('solution refs in different corners keep separate coordinates', () => {
  const entries = [
    { number: '1', corner: 필수, page: 107 },
    { number: '1', corner: 쏙쏙, page: 112 },
  ];
  const out = normalizeSolutionRefsResult(
    {
      items: [
        {
          problem_number: '1',
          number_region: [10, 10, 20, 20],
          source_corner: 필수,
          source_page: 107,
        },
        {
          problem_number: '1',
          number_region: [30, 10, 40, 20],
          source_corner: 쏙쏙,
          source_page: 112,
        },
      ],
    },
    { expectedNumbers: ['1', '1'], expectedEntries: entries },
  );
  assert.deepEqual(
    out.items.map((i) => [i.expected_index, i.number_region[0]]),
    [
      [0, 10],
      [1, 30],
    ],
  );
});

test('an ambiguous number without a badge is left to number matching', () => {
  // 모델이 출처를 안 적었고 후보가 여럿이면 찍지 않는다. 근거 없이 고르면
  // 다른 코너의 정답이 조용히 들어앉는다.
  const out = normalizeAnswerResult(
    {
      items: [{ problem_number: '1', kind: 'subjective', answer_text: '6' }],
    },
    {
      expectedNumbers: ['1', '1'],
      expectedEntries: [
        { number: '1', corner: 필수, page: 107 },
        { number: '1', corner: 쏙쏙, page: 112 },
      ],
    },
  );
  assert.equal(out.items.length, 1);
  assert.equal(out.items[0].expected_index, undefined);
});

test('concept-plus prompts carry the corner table and badge echo fields', () => {
  const entries = [{ number: '109-1', corner: 쏙쏙, page: 109 }];
  for (const prompt of [
    buildExtractAnswersPrompt({
      rawPage: 11,
      expectedNumbers: ['109-1'],
      expectedEntries: entries,
      series: 'gaeyu',
    }),
    buildDetectSolutionRefsPrompt({
      rawPage: 55,
      expectedNumbers: ['109-1'],
      expectedEntries: entries,
      series: 'gaeyu',
    }),
  ]) {
    assert.match(prompt, /기대 문항 상세표/);
    assert.match(prompt, /problem_number="109-1"/);
    assert.match(prompt, new RegExp(`코너="${쏙쏙}"`));
    assert.match(prompt, /배지=P\.109/);
    assert.match(prompt, /source_page/);
  }
});

test('other series keep the plain prompt', () => {
  const prompt = buildExtractAnswersPrompt({
    rawPage: 11,
    expectedNumbers: ['0012'],
    expectedEntries: [{ number: '0012', corner: '', page: 0 }],
    series: 'ssen',
  });
  assert.doesNotMatch(prompt, /기대 문항 상세표/);
  assert.doesNotMatch(prompt, /source_page/);
});
