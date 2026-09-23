import test from 'node:test';
import assert from 'node:assert/strict';

import {
  buildParseTocPrompt,
  normalizeTocResult,
} from '../src/textbook/vlm_toc_client.js';
import {
  buildWonriMiddleStructurePrompt,
  normalizeWonriMiddleStructureResult,
} from '../src/textbook/vlm_rpm_section_client.js';
import {
  buildDetectProblemsPrompt,
  buildWonriMiddleDetectPrompt,
  buildWonriMiddleStepHeaderPrompt,
} from '../src/textbook/vlm_detect_prompt.js';
import {
  mergeWonriMiddleStepHeaders,
  normalizeDetectResult,
} from '../src/textbook/vlm_detect_client.js';
import {
  buildWonriMiddleDetailedSolutionPrompt,
  buildWonriMiddleQuickAnswerPrompt,
  buildWonriMiddleSolutionPrompt,
  filterWonriMiddleItemsByBox,
  normalizeWonriMiddleSolutionResult,
} from '../src/textbook/vlm_wonri_middle_solution_client.js';
import { buildBodySolutionsPrompt } from '../src/textbook/vlm_body_solution_client.js';

test('wonri_middle TOC contract preserves four big and nine mid units', () => {
  const prompt = buildParseTocPrompt({
    pageCount: 2,
    series: 'wonri_middle',
  });
  assert.match(prompt, /중등 개념원리 목차 규칙/);
  assert.match(prompt, /모든 mid_units\[\]\.sub_units는 반드시 \[\]/);
  assert.match(prompt, /계산력 강화하기/);

  const expected = [
    ['소인수분해', [['소인수분해', 10], ['최대공약수와 최소공배수', 30]]],
    ['정수와 유리수', [['정수와 유리수', 50], ['정수와 유리수의 계산', 70]]],
    [
      '문자와 식',
      [
        ['문자의 사용과 식의 계산', 104],
        ['일차방정식의 풀이', 132],
        ['일차방정식의 활용', 156],
      ],
    ],
    [
      '좌표평면과 그래프',
      [['좌표와 그래프', 176], ['정비례와 반비례', 198]],
    ],
  ];
  const normalized = normalizeTocResult({
    big_units: expected.map(([name, mids]) => ({
      name,
      mid_units: mids.map(([midName, page]) => ({
        name: midName,
        page,
        sub_units: [],
      })),
    })),
  });

  assert.equal(normalized.big_units.length, 4);
  assert.deepEqual(
    normalized.big_units.flatMap((big) =>
      big.mid_units.map((mid) => [mid.name, mid.page, mid.sub_units]),
    ),
    expected.flatMap(([, mids]) =>
      mids.map(([name, page]) => [name, page, []]),
    ),
  );
});

test('wonri_middle structure scan keeps real subunits and optional F only', () => {
  const prompt = buildWonriMiddleStructurePrompt([77, 78, 79, 94]);
  assert.match(prompt, /소단원 경계/);
  assert.match(prompt, /계산력 강화하기.*실제로 보이면/);
  assert.match(prompt, /이전 이미지의 이름을 복사하지 마라/);

  const normalized = normalizeWonriMiddleStructureResult(
    {
      pages: [
        {
          image_index: 0,
          sub_unit_header_visible: true,
          sub_unit_name: '03 정수의 덧셈과 뺄셈',
          unit_end_kind: 'none',
          calculation_header_visible: false,
        },
        {
          image_index: 1,
          sub_unit_header_visible: false,
          sub_unit_name: '',
          unit_end_kind: 'none',
          calculation_header_visible: true,
        },
        {
          image_index: 2,
          sub_unit_header_visible: false,
          sub_unit_name: '계산력 강화하기',
          unit_end_kind: 'none',
          calculation_header_visible: false,
        },
        {
          image_index: 3,
          sub_unit_header_visible: false,
          sub_unit_name: '',
          unit_end_kind: 'none',
          calculation_header_visible: true,
        },
      ],
    },
    [77, 78, 79, 94],
  );

  assert.equal(normalized.pages[0].sub_unit_name, '정수의 덧셈과 뺄셈');
  assert.deepEqual(
    normalized.pages
      .filter((page) => page.calculation_header_visible)
      .map((page) => page.raw_page),
    [78, 94],
  );
  assert.equal(normalized.pages[2].sub_unit_header_visible, false);
});

test('wonri_middle body prompt separates all corners and assignable roles', () => {
  const prompt = buildWonriMiddleDetectPrompt({
    rawPage: 26,
    displayPage: 26,
  });
  for (const category of [
    'middle_concept_check',
    'middle_core_problem',
    'middle_exam_problem',
    'middle_unit_review',
    'middle_descriptive',
    'middle_calculation',
  ]) {
    assert.match(prompt, new RegExp(category));
  }
  assert.match(prompt, /확인1·확인2는 같은 유형이지만 별개의 배정 문항/);
  assert.match(prompt, /descriptive_example/);
  assert.match(prompt, /companion_regions/);
  assert.match(prompt, /이 제목이[\s\S]*실제로 보이거나 같은 계산력 묶음이 명백히 이어질 때만/);
  assert.match(prompt, /머리말 없는 다음 쪽도[\s\S]*middle_unit_review로 유지/);
  assert.match(prompt, /정확한 "이런 문제가 시험에 나온다" 제목/);

  const extractPrompt = buildDetectProblemsPrompt({
    rawPage: 26,
    displayPage: 26,
    pageOffset: 0,
    series: 'wonri_middle',
    subKey: 'E',
    sectionHint: 'middle_descriptive',
  });
  assert.match(extractPrompt, /학생이 풀 수 있는 문제 본문이면 예시도/);
  assert.match(extractPrompt, /item_role="descriptive_example"/);
});

test('wonri_middle normalization keeps follow-ups and companion regions', () => {
  const result = normalizeDetectResult(
    {
      section: 'middle_core_problem',
      page_kind: 'problem_page',
      page_layout: 'one_column',
      items: [
        {
          number: '예제1',
          category: 'middle_core_problem',
          item_role: 'representative',
          bbox: [100, 80, 125, 170],
          item_region: [95, 70, 430, 930],
          companion_regions: [
            {
              kind: 'key_point',
              bbox: [200, 650, 290, 930],
              text: 'KEY POINT',
            },
          ],
        },
        {
          number: '확인1',
          category: 'middle_core_problem',
          item_role: 'follow_up',
          bbox: [450, 80, 475, 170],
          item_region: [445, 70, 650, 930],
        },
        {
          number: '확인2',
          category: 'middle_core_problem',
          item_role: 'follow_up',
          bbox: [670, 80, 695, 170],
          item_region: [665, 70, 900, 930],
        },
      ],
    },
    { series: 'wonri_middle', sectionHint: 'middle_core_problem' },
  );

  assert.deepEqual(
    result.items.map((item) => item.number),
    ['예제1', '확인1', '확인2'],
  );
  assert.deepEqual(
    result.items.map((item) => item.item_role),
    ['representative', 'follow_up', 'follow_up'],
  );
  assert.equal(result.items[0].companion_regions[0].kind, 'key_point');
});

test('wonri_middle restores role prefixes and keeps the exam UP badge', () => {
  const result = normalizeDetectResult(
    {
      section: 'middle_core_problem',
      page_kind: 'problem_page',
      page_layout: 'two_column',
      items: [
        {
          number: '01',
          category: 'middle_core_problem',
          item_role: 'representative',
          bbox: [100, 80, 125, 170],
          item_region: [95, 70, 300, 450],
        },
        {
          number: '01',
          category: 'middle_core_problem',
          item_role: 'follow_up',
          bbox: [320, 80, 345, 170],
          item_region: [315, 70, 500, 450],
        },
        {
          number: '07',
          category: 'middle_exam_problem',
          label: 'up',
          bbox: [520, 550, 545, 640],
          item_region: [515, 540, 700, 930],
        },
      ],
    },
    { series: 'wonri_middle' },
  );

  assert.deepEqual(
    result.items.map((item) => item.number),
    ['01', '확인 1', '07'],
  );
  assert.deepEqual(
    result.items.map((item) => item.label),
    ['', '', 'UP'],
  );
});

test('wonri_middle 확인 badge pulls a mislabelled page back to the core corner', () => {
  // 실제 1-1 76쪽: 핵심문제 익히기인데 코너 제목이 안 보여 모델이 지면을
  // 개념원리 확인하기로 되돌렸다. 그러면 A 슬롯에 05/06이 두 번 담긴다.
  const result = normalizeDetectResult(
    {
      section: 'middle_concept_check',
      page_kind: 'mixed',
      page_layout: 'one_column',
      items: [
        {
          number: '05',
          category: 'middle_concept_check',
          bbox: [100, 80, 125, 170],
          item_region: [95, 70, 300, 930],
        },
        {
          number: '확인 5',
          category: 'middle_concept_check',
          bbox: [320, 80, 345, 170],
          item_region: [315, 70, 450, 930],
        },
        {
          number: '06',
          category: 'middle_concept_check',
          bbox: [470, 80, 495, 170],
          item_region: [465, 70, 650, 930],
        },
        {
          number: '확인 6',
          category: 'middle_concept_check',
          bbox: [670, 80, 695, 170],
          item_region: [665, 70, 900, 930],
        },
      ],
    },
    { series: 'wonri_middle' },
  );

  assert.deepEqual(
    result.items.map((item) => item.category),
    Array(4).fill('middle_core_problem'),
  );
  assert.deepEqual(
    result.items.map((item) => item.item_role),
    ['representative', 'follow_up', 'representative', 'follow_up'],
  );
  assert.equal(result.section, 'middle_core_problem');
  assert.match(result.notes, /wonri_middle_follow_up_page_repaired=4/);
});

test('wonri_middle leaves a genuine concept-check page alone', () => {
  const result = normalizeDetectResult(
    {
      section: 'middle_concept_check',
      page_kind: 'problem_page',
      page_layout: 'one_column',
      items: [
        {
          number: '05',
          category: 'middle_concept_check',
          bbox: [100, 80, 125, 170],
          item_region: [95, 70, 300, 930],
        },
        {
          number: '06',
          category: 'middle_concept_check',
          bbox: [320, 80, 345, 170],
          item_region: [315, 70, 500, 930],
        },
      ],
    },
    { series: 'wonri_middle' },
  );

  assert.deepEqual(
    result.items.map((item) => item.category),
    ['middle_concept_check', 'middle_concept_check'],
  );
  assert.equal(result.section, 'middle_concept_check');
});

test('wonri_middle STEP evidence overrides an exam-corner misclassification', () => {
  const result = normalizeDetectResult(
    {
      section: 'middle_exam_problem',
      page_kind: 'problem_page',
      page_layout: 'two_column',
      items: [
        {
          number: '07',
          category: 'middle_exam_problem',
          label: 'STEP 1',
          bbox: [88, 67, 110, 96],
          item_region: [91, 114, 151, 408],
        },
      ],
    },
    { series: 'wonri_middle' },
  );

  assert.equal(result.items[0].category, 'middle_unit_review');
});

test('wonri_middle STEP header coordinates split a mixed two-column page', () => {
  const prompt = buildWonriMiddleStepHeaderPrompt({
    rawPage: 25,
    displayPage: 25,
  });
  assert.match(prompt, /오른쪽 단에서 다음 STEP이 새로/);
  assert.match(prompt, /"실력"과 "UP"이 두 줄/);

  const result = {
    notes: '',
    items: [
      {
        number: '19',
        category: 'middle_unit_review',
        label: 'STEP2',
        column: 1,
        bbox: [92, 65, 114, 90],
      },
      {
        number: '22',
        category: 'middle_unit_review',
        label: 'STEP2',
        column: 2,
        bbox: [140, 514, 162, 546],
      },
      {
        number: '23',
        category: 'middle_unit_review',
        label: '',
        column: 2,
        bbox: [404, 516, 426, 548],
      },
    ],
  };
  const changed = mergeWonriMiddleStepHeaders(result, {
    step_headers: [
      {
        label: 'STEP3',
        bbox: [75, 500, 132, 690],
      },
    ],
  });

  assert.equal(changed, 2);
  assert.deepEqual(
    result.items.map((item) => item.label),
    ['STEP2', 'STEP3', 'STEP3'],
  );
  assert.match(result.notes, /wonri_middle_step_headers_applied=2/);
});

test('wonri_middle concept pages never persist concept block numbers', () => {
  const result = normalizeDetectResult(
    {
      section: 'middle_concept_check',
      page_kind: 'concept_page',
      page_layout: 'one_column',
      items: [
        {
          number: '1',
          category: 'middle_concept_check',
          bbox: [100, 80, 125, 130],
          item_region: [95, 70, 300, 930],
        },
      ],
    },
    { series: 'wonri_middle', sectionHint: 'middle_concept_check' },
  );
  assert.deepEqual(result.items, []);
});

test('wonri_middle recovers real 01 items from a contradictory concept_page', () => {
  const result = normalizeDetectResult(
    {
      section: 'middle_concept_check',
      page_kind: 'concept_page',
      page_layout: 'one_column',
      items: [
        {
          number: '01',
          item_role: 'standard',
          bbox: [100, 80, 125, 140],
          item_region: [95, 70, 320, 930],
        },
      ],
    },
    { series: 'wonri_middle', sectionHint: 'middle_concept_check' },
  );

  assert.equal(result.page_kind, 'problem_page');
  assert.deepEqual(result.items.map((item) => item.number), ['01']);
  assert.match(
    result.notes,
    /concept_page_overridden_by_valid_wonri_middle_items/,
  );
});

test('wonri_middle answer-only solution falls back to answer region', () => {
  const prompt = buildWonriMiddleSolutionPrompt({
    rawPage: 28,
    displayPage: 28,
    expectedEntries: [
      {
        problem_number: '01',
        category: 'middle_calculation',
        title: '정수의 덧셈과 뺄셈',
        page: 78,
      },
    ],
  });
  assert.match(prompt, /solution_kind="answer_only"/);
  assert.match(prompt, /content_region은 answer_region과/);
  assert.match(prompt, /같은 번호가 여러 코너\/소단원에 반복되면/);

  const result = normalizeWonriMiddleSolutionResult({
    items: [
      {
        problem_number: '01',
        category: 'middle_calculation',
        expected_index: 0,
        answer_kind: 'subjective',
        answer_text: '-7',
        solution_kind: 'answer_only',
        answer_region: [100, 200, 160, 400],
        number_region: [100, 100, 130, 180],
        rubric_steps: [],
      },
      {
        problem_number: '서술형1',
        category: 'middle_descriptive',
        expected_index: 1,
        item_role: 'descriptive_example',
        answer_kind: 'subjective',
        answer_text: '45',
        solution_kind: 'full',
        number_region: [200, 100, 230, 180],
        content_region: [200, 100, 700, 900],
        rubric_steps: [
          { step: 1, label: '1단계', text: '소인수분해', points: 2 },
          { step: 2, label: '2단계', text: '값 계산', points: null },
        ],
        total_points: 7,
      },
    ],
  });

  assert.deepEqual(result.items[0].content_region, [100, 200, 160, 400]);
  assert.equal(result.items[0].total_points, null);
  assert.equal(result.items[1].item_role, 'descriptive_example');
  assert.deepEqual(
    result.items[1].rubric_steps.map((step) => step.points),
    [2, null],
  );
  assert.equal(result.items[1].total_points, 7);
});

test('wonri_middle routes examples to body and follow-ups to solution', () => {
  const bodyPrompt = buildBodySolutionsPrompt({
    rawPage: 26,
    displayPage: 26,
    expectedNumbers: ['예제 1', '예제 2'],
    series: 'wonri_middle',
  });
  assert.match(bodyPrompt, /핵심문제 익히기"의 대표 예제/);
  assert.match(bodyPrompt, /"서술형 대비 문제"의 예제/);
  assert.match(bodyPrompt, /"확인 1".*해설 PDF에서 처리/);
  assert.match(bodyPrompt, /"유제 1".*해설 PDF에서 처리/);

  const solutionPrompt = buildWonriMiddleSolutionPrompt({
    rawPage: 8,
    displayPage: 8,
    expectedEntries: [
      {
        problem_number: '확인 3',
        category: 'middle_core_problem',
        item_role: 'follow_up',
      },
      {
        problem_number: '유제 3',
        category: 'middle_descriptive',
        item_role: 'follow_up',
      },
    ],
  });
  assert.match(solutionPrompt, /확인 3.*role=follow_up.*해설인쇄번호=3/);
  assert.match(solutionPrompt, /유제 3.*role=follow_up.*해설인쇄번호=3/);
  assert.match(solutionPrompt, /problem_number에는 기대 목록의 "확인 N"/);
});

test('wonri_middle keeps quick answers separate from detailed solutions', () => {
  const expectedEntries = [
    {
      problem_number: '확인 3',
      category: 'middle_core_problem',
      item_role: 'follow_up',
      page: 14,
    },
  ];
  const answerPrompt = buildWonriMiddleQuickAnswerPrompt({
    rawPage: 2,
    displayPage: 2,
    expectedEntries,
  });
  assert.match(answerPrompt, /빠른 정답 박스의 번호와 정답만/);
  assert.match(answerPrompt, /상세 풀이에서는 아무것도 추출하지 마라/);
  assert.match(answerPrompt, /"시험에 나온다" 또는 "시험"/);
  assert.match(answerPrompt, /확인 3.*해설인쇄번호=3/);
  assert.match(answerPrompt, /solution_kind": "answer_only"/);

  const solutionPrompt = buildWonriMiddleDetailedSolutionPrompt({
    rawPage: 3,
    displayPage: 3,
    expectedEntries,
  });
  assert.match(solutionPrompt, /상세 해설의 문항번호와 풀이 영역만/);
  assert.match(solutionPrompt, /빠른 정답 박스의 번호·답은 절대 선택하지 마라/);
  assert.match(solutionPrompt, /코너 제목이 반복되지 않아도/);
  assert.match(solutionPrompt, /answer_text": ""/);
  for (const prompt of [answerPrompt, solutionPrompt]) {
    assert.match(prompt, /"box": \{/);
    assert.match(prompt, /body_page_from/);
    assert.match(prompt, /middle_calculation="계산력 강화하기"/);
  }
});

test('wonri_middle drops answers read from another subunit box', () => {
  // 소단원마다 "이런 문제가 시험에 나온다" 박스가 01~06으로 똑같이 인쇄된다.
  // 본문 21쪽 문항을 물었는데 모델이 본문 16쪽 박스를 읽어 오면 번호가
  // 전부 맞아떨어지므로 번호만으로는 걸러지지 않는다.
  const expectedEntries = [1, 2, 3].map((number) => ({
    problem_number: `0${number}`,
    category: 'middle_exam_problem',
    page: 21,
  }));
  const items = [1, 2, 3].map((number) => ({
    problem_number: `0${number}`,
    expected_index: number - 1,
  }));

  const wrongBox = filterWonriMiddleItemsByBox({
    items,
    box: { title: '이런 문제가 시험에 나온다', body_page_from: 16, body_page_to: 16 },
    expectedEntries,
  });
  assert.deepEqual(wrongBox.items, []);
  assert.equal(wrongBox.dropped, 3);
  assert.match(wrongBox.reason, /box_out_of_scope/);

  const rightBox = filterWonriMiddleItemsByBox({
    items,
    box: { title: '이런 문제가 시험에 나온다', body_page_from: 21, body_page_to: 21 },
    expectedEntries,
  });
  assert.equal(rightBox.items.length, 3);
  assert.equal(rightBox.dropped, 0);
});

test('wonri_middle keeps items when the box badge is unreadable', () => {
  // 앞 지면에서 이어진 풀이에는 배지가 없다. 배지를 못 읽었다는 이유로
  // 정상 판독을 버리면 연속 지면 풀이가 통째로 사라진다.
  const expectedEntries = [{ problem_number: '07', category: 'middle_unit_review', page: 23 }];
  const items = [{ problem_number: '07', expected_index: 0 }];
  const result = filterWonriMiddleItemsByBox({
    items,
    box: null,
    expectedEntries,
  });
  assert.equal(result.items.length, 1);
  assert.equal(result.dropped, 0);
});

test('wonri_middle box guard drops only the out-of-range item', () => {
  const expectedEntries = [
    { problem_number: '01', category: 'middle_unit_review', page: 22 },
    { problem_number: '20', category: 'middle_unit_review', page: 40 },
  ];
  const items = [
    { problem_number: '01', expected_index: 0 },
    { problem_number: '20', expected_index: 1 },
  ];
  const result = filterWonriMiddleItemsByBox({
    items,
    box: { title: '중단원 마무리하기', body_page_from: 22, body_page_to: 25 },
    expectedEntries,
  });
  assert.deepEqual(
    result.items.map((item) => item.problem_number),
    ['01'],
  );
  assert.equal(result.dropped, 1);
});

test('high-school wonri prompt remains on its original branch', () => {
  const prompt = buildDetectProblemsPrompt({
    rawPage: 67,
    displayPage: 67,
    pageOffset: 0,
    series: 'wonri',
    subKey: 'B',
    sectionHint: 'type_example',
  });
  assert.match(prompt, /교재\(개념원리\)/);
  assert.match(prompt, /필수유형/);
  assert.doesNotMatch(prompt, /middle_calculation|중등 개념원리 교재 전용 규칙/);
});
