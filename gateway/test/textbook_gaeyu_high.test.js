// 개념+유형 고등 시리즈 회귀 테스트.
//
// 중등 개념+유형과 이름만 같고 지면 구성은 고등 개념원리에 가깝다:
// 개념 Check(1, 2, … 블록마다 다시) / 필수예제("01") / 문제("01-1") / 연습문제.
// 정답 PDF 가 없어 해설 PDF 의 "답" 줄과 빠른 정답 표에서 정답을 읽는다.

import { strict as assert } from 'node:assert';
import { test } from 'node:test';

import { buildDetectProblemsPrompt } from '../src/textbook/vlm_detect_prompt.js';
import {
  normalizeDetectResult,
  normalizeGaeyuHighLabel,
} from '../src/textbook/vlm_detect_client.js';
import { canonicalCorner } from '../src/textbook/vlm_corner_guard.js';
import { normalizeAnswerResult } from '../src/textbook/vlm_answer_client.js';
import { normalizeSolutionRefsResult } from '../src/textbook/vlm_solution_refs_client.js';
import { buildExtractAnswersPrompt } from '../src/textbook/vlm_answer_prompt.js';
import { buildDetectSolutionRefsPrompt } from '../src/textbook/vlm_solution_refs_prompt.js';
import { buildBodySolutionsPrompt } from '../src/textbook/vlm_body_solution_client.js';
import { buildParseTocPrompt } from '../src/textbook/vlm_toc_client.js';
import { buildPrompt } from '../src/problem_bank/extract_engines/vlm/prompt.js';

// 공통수학1 Ⅱ-4: 01 소단원 문제(153쪽)·02 소단원 문제(167·180쪽)에 모두 02-1 이 있다.
const repeatedProblemEntries = [
  { number: '01-2', corner: '문제', page: 166, position: 0 },
  { number: '02-1', corner: '문제', page: 167, position: 1, frontier: true },
  { number: '02-2', corner: '문제', page: 167, position: 2, frontier: true },
  { number: '03-3', corner: '문제', page: 168, position: 3 },
  { number: '02-1', corner: '문제', page: 180, position: 4 },
  { number: '02-2', corner: '문제', page: 180, position: 5 },
];

function bodyItem(number, index, extra = {}) {
  return {
    number,
    label: '',
    is_set_header: false,
    column: 1,
    bbox: [100 + index * 200, 50, 130 + index * 200, 110],
    item_region: [140 + index * 200, 50, 280 + index * 200, 470],
    ...extra,
  };
}

test('고등 탐지 프롬프트는 네 코너와 하이픈 번호를 싣는다', () => {
  const prompt = buildDetectProblemsPrompt({
    rawPage: 9,
    displayPage: 9,
    series: 'gaeyu_high',
    sectionHint: 'high_example',
  });
  assert.match(prompt, /개념\+유형 고등/);
  assert.match(prompt, /high_concept_check/);
  assert.match(prompt, /"01-1"/);
  assert.match(prompt, /풀이" 상자 바로 위까지/);
  // 중등 개념+유형 코너가 섞여 들어오지 않는다.
  assert.doesNotMatch(prompt, /쏙쏙/);
  assert.doesNotMatch(prompt, /essential_problem/);
});

test('필수예제 지면: 예제는 두 자리, 문제는 하이픈 번호로 같은 유형을 공유한다', () => {
  const group = {
    kind: 'type',
    label: '필수예제 01',
    title: '다항식의 덧셈과 뺄셈',
    order: 1,
  };
  const result = normalizeDetectResult(
    {
      section: 'high_example',
      page_kind: 'problem_page',
      items: [
        bodyItem('1', 0, { category: 'high_example', content_group: group }),
        bodyItem('01-1', 1, { category: 'high_problem', content_group: group }),
        // 모델이 코너를 잘못 적어도 하이픈 번호면 "문제" 다.
        bodyItem('1-2', 2, { category: 'high_example', content_group: group }),
      ],
    },
    { series: 'gaeyu_high', sectionHint: 'high_example' },
  );
  assert.deepEqual(
    result.items.map((item) => [item.number, item.category]),
    [
      ['01', 'high_example'],
      ['01-1', 'high_problem'],
      ['01-2', 'high_problem'],
    ],
  );
  for (const item of result.items) {
    assert.equal(item.content_group.label, '필수예제 01');
    assert.equal(item.is_set_header, false);
    assert.equal(item.label, '');
  }
});

test('개념 지면의 개념 Check 번호는 concept_page 로 적혀도 살아남는다', () => {
  const result = normalizeDetectResult(
    {
      section: 'high_concept_check',
      page_kind: 'concept_page',
      concept_check_header_bbox: [60, 50, 90, 300],
      items: ['1', '2'].map((number, index) =>
        bodyItem(number, index, {
          category: 'high_concept_check',
          content_group: { kind: 'type', label: '필수예제 01', title: 'x' },
        }),
      ),
    },
    { series: 'gaeyu_high', sectionHint: 'high_concept_check' },
  );
  assert.deepEqual(
    result.items.map((item) => item.number),
    ['1', '2'],
  );
  assert.notEqual(result.page_kind, 'concept_page');
  // 개념 Check 는 유형에 딸리지 않는다.
  assert.equal(result.items[0].content_group.kind, 'none');
});

test('"개념 Check" 제목이 없거나 제목 위에 있는 번호는 개념 Check 가 아니다', () => {
  // 공통수학1 136쪽: 제목 없는 개념 지면의 (i)(ii)·(1)(2)(3) 이 올라왔다.
  const noHeader = normalizeDetectResult(
    {
      section: 'high_concept_check',
      page_kind: 'mixed',
      concept_check_header_bbox: null,
      items: ['1', '2', '3'].map((number, index) =>
        bodyItem(number, index, { category: 'high_concept_check' }),
      ),
    },
    { series: 'gaeyu_high', sectionHint: '' },
  );
  assert.deepEqual(noHeader.items, []);
  assert.equal(noHeader.page_kind, 'concept_page');

  const belowOnly = normalizeDetectResult(
    {
      section: 'high_concept_check',
      page_kind: 'mixed',
      // 첫 번호(bbox 100) 는 제목(250) 위의 개념 설명이다.
      concept_check_header_bbox: [250, 50, 280, 300],
      items: ['1', '1', '2'].map((number, index) =>
        bodyItem(number, index, { category: 'high_concept_check' }),
      ),
    },
    { series: 'gaeyu_high', sectionHint: '' },
  );
  assert.deepEqual(
    belowOnly.items.map((item) => item.bbox[0]),
    [300, 500],
  );
});

test('연습문제 라벨은 실력·출처 배지를 고정 순서로 잇는다', () => {
  assert.equal(normalizeGaeyuHighLabel('교육청 / 실력'), '실력+교육청');
  assert.equal(normalizeGaeyuHighLabel('평가원 기출'), '평가원');
  assert.equal(normalizeGaeyuHighLabel('상'), '');
  const result = normalizeDetectResult(
    {
      section: 'high_exercise',
      page_kind: 'problem_page',
      items: [
        bodyItem('7', 0, { category: 'high_exercise', label: '교육청' }),
        // 하이픈 없는 "문제" 는 연습문제 지면에서 온 것이다.
        bodyItem('8', 1, { category: 'high_problem', label: '실력' }),
      ],
    },
    { series: 'gaeyu_high', sectionHint: 'high_exercise' },
  );
  assert.deepEqual(
    result.items.map((item) => [item.number, item.category, item.label]),
    [
      ['7', 'high_exercise', '교육청'],
      ['8', 'high_exercise', '실력'],
    ],
  );
});

test('해설 상자 머리의 "문제"·"연습문제"·"개념 Check" 를 코너로 가른다', () => {
  assert.equal(canonicalCorner('문제 12~14쪽'), 'high_problem');
  assert.equal(canonicalCorner('연습문제 26~28쪽'), 'high_exercise');
  assert.equal(canonicalCorner('개념 Check 8쪽'), 'concept_check');
  // 다른 코너 이름 속 "문제" 는 건드리지 않는다.
  assert.equal(canonicalCorner('필수 문제'), 'essential_problem');
  assert.equal(canonicalCorner('대표 문제'), '');
});

test('정답: 하이픈 번호는 범위로 펼치지 않고, 같은 숫자는 코너로 가른다', () => {
  const expectedEntries = [
    { number: '1', corner: '개념 Check', page: 8 },
    { number: '2', corner: '개념 Check', page: 8 },
    { number: '3', corner: '개념 Check', page: 8 },
    { number: '01-3', corner: '문제', page: 9 },
    { number: '1', corner: '연습문제', page: 26 },
  ];
  const result = normalizeAnswerResult(
    {
      items: [
        {
          problem_number: '01-3',
          answer_text: '5',
          kind: 'subjective',
          source_corner: '문제',
          source_page: 9,
        },
        {
          problem_number: '1',
          answer_text: '②',
          kind: 'objective',
          source_corner: '연습문제',
          source_page: 26,
          source_page_end: 28,
        },
      ],
    },
    { expectedEntries },
  );
  assert.deepEqual(
    result.items.map((item) => item.expected_index),
    [3, 4],
  );
});

test('해설 위치: 하이픈 번호는 범위로 펼치지 않는다', () => {
  const expectedEntries = [
    { number: '1', corner: '개념 Check', page: 8 },
    { number: '2', corner: '개념 Check', page: 8 },
    { number: '3', corner: '개념 Check', page: 8 },
    { number: '01-3', corner: '문제', page: 9 },
  ];
  const result = normalizeSolutionRefsResult(
    {
      items: [
        {
          problem_number: '01-3',
          number_region: [100, 50, 130, 110],
          content_region: [130, 50, 400, 480],
          source_corner: '문제',
          source_page: 9,
        },
      ],
    },
    { expectedEntries },
  );
  assert.equal(result.items.length, 1);
  assert.equal(result.items[0].expected_index, 3);
});

test('정답·해설 프롬프트는 "답" 줄과 빠른 정답 표를 구분한다', () => {
  const answer = buildExtractAnswersPrompt({
    rawPage: 2,
    series: 'gaeyu_high',
    expectedNumbers: ['1', '01-1', '1'],
    expectedEntries: [
      { number: '1', corner: '개념 Check', page: 8 },
      { number: '01-1', corner: '문제', page: 9 },
      { number: '1', corner: '연습문제', page: 26 },
    ],
  });
  assert.match(answer, /정답과 해설/);
  assert.match(answer, /답/);
  const refs = buildDetectSolutionRefsPrompt({
    rawPage: 2,
    series: 'gaeyu_high',
    expectedNumbers: ['01-1'],
    expectedEntries: [{ number: '01-1', corner: '문제', page: 9 }],
  });
  assert.match(refs, /빠른 정답/);
});

test('본문 풀이 프롬프트는 필수예제 풀이 상자를 짚는다', () => {
  const prompt = buildBodySolutionsPrompt({
    rawPage: 9,
    series: 'gaeyu_high',
    expectedNumbers: ['01'],
  });
  assert.match(prompt, /풀이/);
  assert.match(prompt, /필수/);
});

test('목차·문제은행 프롬프트에 고등 규칙이 실린다', () => {
  const toc = buildParseTocPrompt({ pageCount: 2, series: 'gaeyu_high' });
  assert.match(toc, /개념\+유형 고등/);
  const pb = buildPrompt({
    textbookScope: { series: 'gaeyu_high', sub_key: 'A' },
  });
  assert.match(pb, /개념 Check/);
});

test('해설 꼬리말 쪽·옆 탭을 출처로 적은 이어지는 지면 정답도 차례상 다음 문항에 붙는다', () => {
  // 해설 71쪽: 머리 없는 지면에서 모델이 "개념편 71" 을 출처로 적었다.
  const out = normalizeAnswerResult(
    {
      items: ['02-1', '02-2', '03-3'].map((problem_number) => ({
        problem_number,
        kind: 'subjective',
        answer_text: 'x',
        source_corner: '개념편',
        source_page: 71,
      })),
    },
    {
      expectedEntries: repeatedProblemEntries,
      expectedNumbers: repeatedProblemEntries.map((e) => e.number),
      series: 'gaeyu_high',
      rawPage: 71,
      displayPage: 71,
    },
  );
  assert.deepEqual(
    out.items.map((item) => item.expected_index),
    [1, 2, 3],
  );
});

test('머리 없는 지면에서 지어 적은 배지는 무시하고 본문 차례대로 붙인다', () => {
  // 해설 71쪽 재현: 실제는 167·168쪽 문제인데 모델이 "문제 180·181쪽" 으로 적었다.
  const out = normalizeAnswerResult(
    {
      items: ['02-1', '02-2', '03-3'].map((problem_number, i) => ({
        problem_number,
        kind: 'subjective',
        answer_text: 'x',
        bbox: [100 + i * 100, 50, 120 + i * 100, 300],
        source_corner: '문제',
        source_page: problem_number === '03-3' ? 168 : 180,
        source_page_end: problem_number === '03-3' ? 168 : 180,
      })),
    },
    {
      expectedEntries: repeatedProblemEntries,
      expectedNumbers: repeatedProblemEntries.map((e) => e.number),
      series: 'gaeyu_high',
      rawPage: 71,
      displayPage: 71,
    },
  );
  assert.deepEqual(
    out.items.map((item) => item.expected_index),
    [1, 2, 3],
  );
});

test('한 지면에 같은 번호 박스가 둘이면 차례대로 첫째·둘째 후보에 붙고, 되풀이는 버린다', () => {
  // 해설 63쪽: "개념 Check 150쪽" 과 "152쪽" 의 1 이 한 지면에 있다.
  const entries = [
    { number: '1', corner: '개념 Check', page: 150, position: 0 },
    { number: '1', corner: '개념 Check', page: 152, position: 1 },
  ];
  const item = (y, answer_text) => ({
    problem_number: '1',
    kind: 'subjective',
    answer_text,
    bbox: [y, 50, y + 20, 300],
    source_corner: '개념 Check',
    source_page: 150,
  });
  const out = normalizeAnswerResult(
    { items: [item(100, 'ㄱ, ㄷ'), item(100, 'ㄱ, ㄷ'), item(600, 'ㄱ, ㄷ')] },
    {
      expectedEntries: entries,
      expectedNumbers: entries.map((e) => e.number),
      series: 'gaeyu_high',
      rawPage: 63,
      displayPage: 63,
    },
  );
  assert.deepEqual(out.items.map((one) => one.expected_index), [0, 1]);
});

test('해설 좌표도 꼬리말 쪽을 출처에서 지운다', () => {
  const out = normalizeSolutionRefsResult(
    {
      items: [
        {
          problem_number: '02-1',
          source_corner: '개념편',
          source_page: 71,
          number_region: [60, 40, 80, 90],
          content_region: [60, 40, 300, 480],
        },
      ],
    },
    {
      expectedEntries: repeatedProblemEntries,
      expectedNumbers: repeatedProblemEntries.map((e) => e.number),
      series: 'gaeyu_high',
      rawPage: 71,
      displayPage: 71,
    },
  );
  assert.deepEqual(out.items.map((item) => item.expected_index), [1]);
});
