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
  assert.match(prompt, /"개념 확인" 전용 원형 배지/);
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

// 파란 "교과서 +α" 카드는 제목 앞 숫자가 빨간 네모 안에 있어서 필수 문제로
// 오인식됐다. 개념 카드 규칙이 배경색과 무관하게 서술돼 있어야 한다.
test('개념+유형 프롬프트가 교과서 +α 개념 카드를 문항에서 제외한다', () => {
  const prompt = gaeyuPrompt();
  assert.match(prompt, /교과서 \+α/);
  assert.match(prompt, /배경색·테두리색이 무엇이든 개념 카드/);
  assert.match(prompt, /빨간 네모 안에 있어도 개념 번호/);
  // 배지 없이는 필수 문제로 올리지 못하게 막는 게이트.
  assert.match(prompt, /같은\*\*\n?.*\*\*줄에 실제로 보일 때만\*\*/s);
  assert.match(prompt, /개념 카드 제목을 content_group\.title\(유형명\)로 쓰지 마라/);
});

test('개념+유형 개념확인은 본문 인쇄 페이지를 번호로 받는다', () => {
  const result = detect([
    {
      number: '',
      category: 'concept_check',
      label: '',
      badge_text: '개념 확인',
      badge_style: 'concept_check_round_two_line',
    },
    { number: '1', category: 'essential_problem', label: '' },
  ]);
  assert.deepEqual(
    result.items.map((item) => item.number),
    ['개념확인8', '1'],
  );
});

test('개념+유형 개념확인은 페이지를 모르면 저장하지 않는다', () => {
  const result = detect([{
    number: '',
    category: 'concept_check',
    badge_text: '개념 확인',
    badge_style: 'concept_check_round_two_line',
  }], {
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

test('개념+유형 대표 문항은 모델이 세트 헤더라 해도 일반 크롭으로 남긴다', () => {
  const result = detect([
    {
      number: '1',
      category: 'essential_problem',
      is_set_header: true,
      set_range: { from: 1, to: 2 },
    },
    { number: '1-1', category: 'essential_problem' },
    { number: '1-2', category: 'essential_problem' },
  ]);

  assert.deepEqual(
    result.items.map((item) => item.number),
    ['1', '1-1', '1-2'],
  );
  assert.equal(result.items[0].is_set_header, false);
  assert.equal(result.items[0].set_range, null);
});

test('대표 필수 문제 번호가 본문 위 빈칸에 잡히면 왼쪽 같은 높이로 교정한다', () => {
  const result = detect([
    {
      number: '1',
      category: 'essential_problem',
      bbox: [393, 276, 414, 358],
      item_region: [421, 276, 552, 921],
    },
    {
      number: '1-1',
      category: 'essential_problem',
      bbox: [589, 276, 606, 314],
      item_region: [589, 276, 660, 921],
    },
    {
      number: '2',
      category: 'essential_problem',
      bbox: [483, 248, 500, 269],
      item_region: [484, 278, 584, 922],
    },
    {
      number: '8',
      category: 'unit_drill',
      bbox: [300, 105, 322, 150],
      item_region: [329, 105, 538, 471],
    },
  ]);

  assert.deepEqual(result.items[0].bbox, [421, 239, 443, 269]);
  assert.deepEqual(result.items[1].bbox, [589, 276, 606, 314]);
  assert.deepEqual(result.items[2].bbox, [483, 248, 500, 269]);
  assert.deepEqual(result.items[3].bbox, [329, 68, 351, 98]);
  assert.match(result.notes, /gaeyu_number_bbox_repaired=2/);
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

// "연습해 보자" 를 라벨 "연습" 으로 두면 배지에서 "한 번 더 연습" 과 구별되지
// 않는다. 저장 라벨만 "서술형 연습" 으로 바꾸고, 답지 매칭 키인 번호 접두어는
// "연습1" 그대로 유지한다.
test('개념+유형 연습해 보자 라벨은 서술형 연습으로 저장된다', () => {
  const result = detect([
    { number: '1', category: 'descriptive', label: '연습해 보자' },
    { number: '2', category: 'descriptive', label: '연습 2' },
    // 저장된 크롭을 되살릴 때 이미 정제된 라벨이 다시 들어와도 같은 결과여야 한다.
    { number: '3', category: 'descriptive', label: '서술형 연습' },
  ]);
  assert.deepEqual(
    result.items.map((item) => [item.number, item.label]),
    [
      ['연습1', '서술형 연습'],
      ['연습2', '서술형 연습'],
      ['연습3', '서술형 연습'],
    ],
  );
  assert.ok(result.items.every((item) => item.category === 'descriptive'));
});

// 예제·유제 배지가 문제 상자 위 빈 공간으로, 연습해 보자 크롭이 풀이 여백까지
// 잡히던 문제. 프롬프트에 위치 근거와 아래 경계가 명시돼 있어야 한다.
test('개념+유형 프롬프트가 쓱쓱 번호 배지 위치와 크롭 경계를 못 박는다', () => {
  const prompt = gaeyuPrompt();
  assert.match(prompt, /\[D4-쓱쓱\]/);
  assert.match(prompt, /문제 상자의 \*\*왼쪽 바깥\*\*/);
  assert.match(prompt, /위쪽 빈 공간을 잡으면 틀린 것이다/);
  assert.match(prompt, /"따라 해보자" 리본/);
  assert.match(prompt, /쓱쓱 서술형 3갈래 공통\(예제·유제·연습해 보자\)/);
  assert.match(prompt, /빈 여백을 같이 크롭하면 실패다/);
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

// 개념 설명 바로 아래에 있는 필수 문제를 모델이 "개념확인" 으로 읽어버리면,
// 번호가 "개념확인11" 로 덮여 그 문항이 사라지고 뒤 번호가 전부 밀렸다.
// 개념확인에는 번호가 인쇄되지 않으므로 번호 유무로 되돌릴 수 있다.
test('번호가 인쇄된 문항은 concept_check 로 받아도 필수 문제로 되돌린다', () => {
  const result = detect(
    [
      {
        number: '',
        category: 'concept_check',
        badge_text: '개념 확인',
        badge_style: 'concept_check_round_two_line',
      },
      { number: '11', category: 'concept_check' },
      { number: '11-1', category: 'concept_check' },
    ],
    { displayPage: 11, rawPage: 11 },
  );
  assert.deepEqual(
    result.items.map((item) => [item.number, item.category]),
    [
      ['개념확인11', 'concept_check'],
      ['11', 'essential_problem'],
      ['11-1', 'essential_problem'],
    ],
  );
  assert.match(result.notes, /gaeyu_concept_check_with_number_fixed=2/);
});

test('번호가 인쇄된 concept_check 는 지면 코너가 있으면 그 코너로 되돌린다', () => {
  const result = detect(
    [{ number: '3', category: 'concept_check' }],
    { displayPage: 20, rawPage: 20, sectionHint: 'step_drill' },
  );
  assert.deepEqual(
    result.items.map((item) => [item.number, item.category]),
    [['3', 'step_drill']],
  );
});

test('배지 원문이 필수 문제면 빈 번호여도 concept_check로 바꾸지 않는다', () => {
  const result = detect(
    [
      {
        number: '',
        category: 'concept_check',
        badge_text: '필수 문제',
      },
    ],
    { displayPage: 30, rawPage: 40 },
  );
  // 번호까지 놓친 문항은 저장할 수 없어 제외되지만, 개념확인30이라는 가짜
  // 문항으로 바뀌어 뒤 매칭을 오염시키지는 않는다.
  assert.deepEqual(result.items, []);
});

test('배지 원문은 모델이 고른 잘못된 category보다 우선한다', () => {
  const result = detect([
    {
      number: '1',
      category: 'concept_check',
      badge_text: '필수 문제',
      content_group: { kind: 'type', title: '정수와 유리수' },
    },
  ]);
  assert.deepEqual(
    result.items.map((item) => [
      item.number,
      item.category,
      item.content_group_title,
    ]),
    [['1', 'essential_problem', '정수와 유리수']],
  );
});

test('필수 문제 유형명은 category와 번호를 모두 잘못 읽은 경우에도 오분류를 막는다', () => {
  const result = detect([
    {
      number: '',
      category: 'concept_check',
      badge_text: '',
      content_group: { kind: 'type', title: '정수와 유리수' },
    },
  ]);
  assert.deepEqual(result.items, []);
});

test('참고 설명은 개념 박스 아래에 있어도 개념확인으로 저장하지 않는다', () => {
  const result = detect([
    {
      number: '',
      category: 'concept_check',
      badge_text: '참고',
      badge_style: '',
    },
  ]);
  assert.deepEqual(result.items, []);
});

test('한 지면에 개념확인이 둘이면 키가 겹치지 않게 꼬리표를 붙인다', () => {
  const result = detect(
    [
      {
        number: '',
        category: 'concept_check',
        badge_text: '개념 확인',
        badge_style: 'concept_check_round_two_line',
      },
      {
        number: '',
        category: 'concept_check',
        badge_text: '개념 확인',
        badge_style: 'concept_check_round_two_line',
      },
    ],
    { displayPage: 11, rawPage: 11 },
  );
  assert.deepEqual(
    result.items.map((item) => item.number),
    ['개념확인11', '개념확인11-2'],
  );
  assert.match(result.notes, /gaeyu_concept_check_duplicated=2/);
});

test('개념+유형 프롬프트가 개념확인·필수 문제 배지를 못 섞게 막는다', () => {
  const prompt = gaeyuPrompt();
  assert.match(prompt, /\*\*두 배지를 섞지 마라\.\*\*/);
  assert.match(prompt, /\*\*번호가 인쇄돼 있으면 개념확인이 아니다\.\*\*/);
  assert.match(prompt, /\[D0-Check\]/);
  assert.match(prompt, /없을 때만\*\*/);
  assert.match(prompt, /"badge_text"/);
  assert.match(prompt, /"badge_style"/);
  assert.match(prompt, /\[D0-Badge\]/);
  assert.match(prompt, /보이는 그대로 베껴 써라/);
  assert.match(prompt, /"참고" 캡슐/);
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
