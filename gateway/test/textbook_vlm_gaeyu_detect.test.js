import test from 'node:test';
import assert from 'node:assert/strict';

import { normalizeDetectResult } from '../src/textbook/vlm_detect_client.js';
import { buildDetectProblemsPrompt } from '../src/textbook/vlm_detect_prompt.js';

function gaeyuPrompt(overrides = {}) {
  return buildDetectProblemsPrompt({
    rawPage: 8,
    displayPage: 8,
    pageOffset: 0,
    series: 'gaeyu',
    ...overrides,
  });
}

function detect(items, opts = {}) {
  return normalizeDetectResult(
    {
      section: 'unknown',
      page_kind: 'problem_page',
      page_layout: 'one_column',
      items: items.map((item) => ({
        is_set_header: false,
        column: 1,
        bbox: [10, 10, 30, 60],
        item_region: [40, 10, 200, 900],
        ...item,
      })),
      notes: '',
    },
    { series: 'gaeyu', displayPage: 8, rawPage: 8, ...opts },
  );
}

test('개념+유형 프롬프트가 여섯 코너와 번호 규칙을 설명한다', () => {
  const prompt = gaeyuPrompt();
  assert.match(prompt, /"개념 확인" 민트색 원형 배지/);
  assert.match(prompt, /\*\*인쇄된 번호가 없다\.\*\*/);
  assert.match(prompt, /"필수 문제" 보라색 배지/);
  assert.match(prompt, /"1-1", "1-2" 처럼 하이픈이 붙은 번호/);
  assert.match(prompt, /"한번 더 연습" 배지/);
  assert.match(prompt, /절대 step_drill 로 분류하지 마라/);
  assert.match(prompt, /작은 원 세 개/);
  assert.match(prompt, /1개="하", 2개="중", 3개="상"/);
  assert.match(prompt, /노란 별 모양 배경이 깔린 문항은 중요 문항/);
  assert.match(prompt, /개념 Review \/ 마인드맵/);
});

test('개념+유형 개념확인은 본문 인쇄 페이지를 번호로 받는다', () => {
  const result = detect([
    { number: '', category: 'concept_check', label: '' },
    { number: '1', category: 'essential_problem', label: '' },
  ]);
  assert.deepEqual(
    result.items.map((item) => item.number),
    ['개념확인8', '1'],
  );
});

test('개념+유형 개념확인은 페이지를 모르면 저장하지 않는다', () => {
  const result = detect([{ number: '', category: 'concept_check' }], {
    displayPage: null,
    rawPage: null,
  });
  assert.deepEqual(result.items, []);
});

test('개념+유형 따름 문제는 하이픈 번호를 그대로 유지한다', () => {
  const result = detect([
    { number: '1', category: 'essential_problem' },
    { number: '1-1', category: 'essential_problem' },
    { number: '1-2', category: 'essential_problem' },
  ]);
  assert.deepEqual(
    result.items.map((item) => item.number),
    ['1', '1-1', '1-2'],
  );
  assert.ok(result.items.every((item) => item.is_set_header === false));
});

test('개념+유형 쓱쓱 서술형은 갈래 접두어로 번호 충돌을 피한다', () => {
  const result = detect([
    { number: '1', category: 'descriptive', label: '예제 1' },
    { number: '1', category: 'descriptive', label: '유제1' },
    { number: '1', category: 'descriptive', label: '연습해 보자' },
  ]);
  assert.deepEqual(
    result.items.map((item) => item.number),
    ['예제1', '유제1', '연습1'],
  );
});

test('개념+유형 탄탄은 난이도와 중요 표시를 따로 담는다', () => {
  const result = detect([
    { number: '1', category: 'unit_drill', label: '하', is_important: true },
    { number: '2', category: 'unit_drill', label: '중' },
  ]);
  assert.deepEqual(
    result.items.map((item) => [item.label, item.is_important]),
    [
      ['하', true],
      ['중', false],
    ],
  );
});

test('개념+유형은 필수 문제에만 유형명 그룹을 남긴다', () => {
  const group = { kind: 'type', label: '필수 문제 1', title: '제곱근의 뜻' };
  const result = detect([
    { number: '1', category: 'essential_problem', content_group: group },
    { number: '3', category: 'step_drill', content_group: group },
  ]);
  assert.equal(result.items[0].content_group_title, '제곱근의 뜻');
  assert.equal(result.items[1].content_group_title, '');
});

test('개념+유형 category 누락은 같은 페이지 다수 카테고리로 채운다', () => {
  const result = detect([
    { number: '1', category: 'extra_practice' },
    { number: '2', category: 'extra_practice' },
    { number: '3' },
  ]);
  assert.deepEqual(
    result.items.map((item) => item.category),
    ['extra_practice', 'extra_practice', 'extra_practice'],
  );
  assert.match(result.notes, /gaeyu_category_backfilled=1/);
});

test('개념+유형 규칙은 다른 시리즈 정규화를 바꾸지 않는다', () => {
  const result = normalizeDetectResult(
    {
      section: 'type_practice',
      page_kind: 'problem_page',
      page_layout: 'two_column',
      items: [
        {
          number: '',
          label: '중',
          is_set_header: false,
          column: 1,
          bbox: [10, 10, 30, 60],
          item_region: [40, 10, 200, 900],
        },
      ],
      notes: '',
    },
    { series: 'ssen', displayPage: 8 },
  );
  assert.deepEqual(result.items, []);
});
