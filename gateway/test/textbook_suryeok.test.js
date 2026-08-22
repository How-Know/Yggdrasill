import test from 'node:test';
import assert from 'node:assert/strict';

import {
  normalizeDetectResult,
  mergeItemGeometry,
  mergeSuryeokMarks,
  numberBboxesLookTemplated,
  overwriteItemGeometry,
  repairSuryeokItemRegions,
  suryeokMarksNeedRepair,
} from '../src/textbook/vlm_detect_client.js';
import {
  buildDetectProblemsPrompt,
  buildSuryeokMarkRepairPrompt,
} from '../src/textbook/vlm_detect_prompt.js';
import { buildExtractAnswersPrompt } from '../src/textbook/vlm_answer_prompt.js';
import { buildDetectSolutionRefsPrompt } from '../src/textbook/vlm_solution_refs_prompt.js';
import { buildParseTocPrompt } from '../src/textbook/vlm_toc_client.js';
import { groupSuryeokExpectedBlocks } from '../src/textbook/vlm_suryeok_blocks.js';
import {
  buildSolutionBlockIndexPrompt,
  normalizeSolutionBlocksResult,
} from '../src/textbook/vlm_solution_blocks_client.js';
import {
  buildAnswerLayoutPrompt,
  normalizeAnswerLayoutResult,
} from '../src/textbook/vlm_answer_layout_client.js';
import { canonicalCorner } from '../src/textbook/vlm_corner_guard.js';

const geometry = {
  bbox: [0.1, 0.1, 0.2, 0.9],
  number_region: [0.1, 0.1, 0.13, 0.16],
  item_region: [0.1, 0.1, 0.2, 0.9],
};

test('suryeok detect prompt explains two-digit numbers and concept check badge', () => {
  const prompt = buildDetectProblemsPrompt({
    rawPage: 11,
    displayPage: 11,
    pageOffset: 0,
    series: 'suryeok',
    sectionHint: 'type_problem',
  });
  assert.match(prompt, /수력충전/);
  assert.match(prompt, /"01", "02"/);
  assert.match(prompt, /개념 체크/);
  assert.match(prompt, /01~05/);
});

test('suryeok detect prompt lists unit review badges only for the B slot', () => {
  const prompt = buildDetectProblemsPrompt({
    rawPage: 30,
    displayPage: 30,
    pageOffset: 0,
    series: 'suryeok',
    sectionHint: 'unit_review',
  });
  assert.match(prompt, /계산 조심/);
  assert.match(prompt, /생각 더하기/);
  assert.match(prompt, /조건 확인/);
  assert.match(prompt, /조건 확인\+생각 더하기/);
});

test('suryeok skill-test prompt uses only 시험에 꼭! / 도전해 얍! badges', () => {
  const prompt = buildDetectProblemsPrompt({
    rawPage: 200,
    displayPage: 200,
    pageOffset: 0,
    series: 'suryeok',
    sectionHint: 'skill_test',
  });
  assert.match(prompt, /실력 향상 테스트/);
  assert.match(prompt, /시험에 꼭!/);
  assert.match(prompt, /도전해 얍!/);
  assert.match(
    buildSuryeokMarkRepairPrompt({ rawPage: 200, sectionHint: 'skill_test' }),
    /시험에 꼭!/,
  );
});

test('suryeok mark repair adds a missed green number and keeps combined badges', () => {
  const result = {
    section: 'type_problem',
    page_kind: 'problem_page',
    items: [
      {
        number: '03',
        label: '',
        category: 'type_problem',
        is_set_header: false,
        column: 1,
        bbox: [789, 72, 805, 101],
        item_region: [783, 66, 897, 506],
      },
    ],
  };
  assert.equal(suryeokMarksNeedRepair(result, 'type_problem'), true);
  const merged = mergeSuryeokMarks(
    result,
    { items: [{ number: '02', label: '', bbox: [350, 72, 367, 101] }] },
    'type_problem',
  );
  assert.equal(merged.added, 1);
  assert.deepEqual(
    result.items.map((item) => item.number),
    ['02', '03'],
  );

  const review = {
    section: 'unit_review',
    page_kind: 'problem_page',
    items: [
      {
        number: '33',
        label: '',
        category: 'unit_review',
        is_set_header: false,
        column: 2,
        bbox: [690, 510, 705, 540],
        item_region: [684, 504, 824, 960],
      },
    ],
  };
  const labels = mergeSuryeokMarks(
    review,
    {
      items: [
        {
          number: '33',
          label: '조건 확인! + 생각 더하기',
          bbox: [690, 510, 705, 540],
        },
      ],
    },
    'unit_review',
  );
  assert.equal(labels.labels, 1);
  assert.equal(review.items[0].label, '조건 확인+생각 더하기');
  assert.match(
    buildSuryeokMarkRepairPrompt({ rawPage: 89, sectionHint: 'unit_review' }),
    /두 배지/,
  );
});

test('geometry repair fills a missing number bbox even when item region exists', () => {
  const result = {
    items: [
      {
        number: '28',
        bbox: null,
        item_region: [430, 60, 560, 500],
      },
    ],
    notes: '',
  };
  const filled = mergeItemGeometry(result, {
    items: [
      {
        number: '28',
        bbox: [442, 69, 457, 97],
        item_region: [430, 60, 560, 500],
      },
    ],
  });
  assert.equal(filled, 1);
  assert.deepEqual(result.items[0].bbox, [442, 69, 457, 97]);
});

test('suryeok numbers are padded to two digits and set ranges kept', () => {
  const out = normalizeDetectResult(
    {
      items: [
        { number: '1', category: 'type_problem', ...geometry },
        { number: '01~05', category: 'type_problem', is_set_header: true, ...geometry },
      ],
    },
    { rawPage: 11, displayPage: 11, series: 'suryeok', sectionHint: 'type_problem' },
  );
  assert.equal(out.items[0].number, '01');
  assert.equal(out.items[1].number, '01~05');
  assert.equal(out.items[1].is_set_header, true);
  assert.deepEqual(out.items[1].set_range, { from: 1, to: 5 });
});

test('suryeok drops sub-item numbers that would poison the number sequence', () => {
  // 1-1 p168: 유형 48 문항 01 아래에 "1)" ~ "5)" 소문항이 세로로 이어진다.
  // 이 숫자들이 남으면 번호열 최댓값이 5로 올라가 다음 지면의 03·04·05가
  // 번호 역행으로 통째로 지워진다.
  const out = normalizeDetectResult(
    {
      items: [
        { number: '01', category: 'type_problem', ...geometry },
        { number: '1)', category: 'type_problem', ...geometry },
        { number: '2)', category: 'type_problem', ...geometry },
        { number: '(3)', category: 'type_problem', ...geometry },
        { number: '02', category: 'type_problem', ...geometry },
      ],
    },
    { rawPage: 168, displayPage: 168, series: 'suryeok', sectionHint: 'type_problem' },
  );
  assert.deepEqual(
    out.items.map((item) => item.number),
    ['01', '02'],
  );
  assert.match(out.notes, /suryeok_sub_item_number_dropped=3/);
});

test('suryeok concept check keeps its own category but stays in the A slot flow', () => {
  const out = normalizeDetectResult(
    {
      items: [
        { number: '28', category: 'concept_check', ...geometry },
        { number: '29', ...geometry },
      ],
    },
    { rawPage: 11, displayPage: 11, series: 'suryeok', sectionHint: 'type_problem' },
  );
  assert.equal(out.items[0].category, 'concept_check');
  // 카테고리를 비워 보내면 지면 섹션으로 되메운다.
  assert.equal(out.items[1].category, 'type_problem');
});

test('suryeok carries the type header across a column break', () => {
  const typeGroup = {
    kind: 'type',
    label: '유형 01',
    title: '지수법칙의 표현',
    order: 1,
  };
  const out = normalizeDetectResult(
    {
      items: [
        { number: '01', category: 'type_problem', column: 1, content_group: typeGroup, ...geometry },
        // 모델이 우단으로 넘어가며 유형을 빠뜨린 경우.
        { number: '06', category: 'type_problem', column: 2, ...geometry },
        { number: '07', category: 'type_problem', column: 2, content_group: { kind: 'none' }, ...geometry },
      ],
    },
    { rawPage: 10, displayPage: 10, series: 'suryeok', sectionHint: 'type_problem' },
  );
  assert.equal(out.items[1].content_group_title, '지수법칙의 표현');
  assert.equal(out.items[2].content_group_label, '유형 01');
  assert.match(out.notes, /suryeok_content_group_carried=2/);
});

test('suryeok concept check never carries a type name', () => {
  const out = normalizeDetectResult(
    {
      items: [
        {
          number: '27',
          category: 'type_problem',
          content_group: { kind: 'type', label: '유형 02', title: '지수법칙의 활용' },
          ...geometry,
        },
        {
          number: '28',
          category: 'concept_check',
          content_group: { kind: 'type', label: '유형 02', title: '지수법칙의 활용' },
          ...geometry,
        },
      ],
    },
    { rawPage: 11, displayPage: 11, series: 'suryeok', sectionHint: 'type_problem' },
  );
  assert.equal(out.items[0].content_group_kind, 'type');
  assert.equal(out.items[1].content_group_kind, 'none');
  assert.equal(out.items[1].content_group_title, '');
});

test('suryeok item regions start at the number line and run to the next number', () => {
  const out = normalizeDetectResult(
    {
      page_layout: 'two_column',
      items: [
        // 모델이 번호 줄만 영역으로 준 경우(본문이 통째로 잘린다).
        {
          number: '05',
          category: 'type_problem',
          column: 1,
          bbox: [294, 71, 310, 100],
          item_region: [294, 115, 310, 337],
        },
        {
          number: '06',
          category: 'type_problem',
          column: 1,
          bbox: [423, 71, 439, 100],
          item_region: [423, 115, 439, 319],
        },
        {
          number: '10',
          category: 'type_problem',
          column: 2,
          bbox: [189, 517, 205, 546],
          item_region: [189, 560, 351, 891],
        },
      ],
    },
    { rawPage: 27, displayPage: 27, series: 'suryeok', sectionHint: 'type_problem' },
  );
  const [first, second, right] = out.items;
  // 번호 줄에서 시작하고 왼쪽은 번호까지 포함한다.
  assert.equal(first.item_region[0], 288);
  assert.equal(first.item_region[1], 65);
  // 아래는 같은 단 다음 번호 직전까지.
  assert.equal(first.item_region[2], 415);
  // 오른쪽 단 시작 전까지가 좌단의 폭.
  assert.equal(first.item_region[3], 509);
  assert.equal(second.item_region[0], 417);
  // 단의 마지막 문항은 다음 번호가 없으니 아래 여백까지 둔다.
  assert.ok(second.item_region[2] > 439);
  assert.equal(right.item_region[1], 511);
  assert.match(out.notes, /suryeok_item_region_repaired=3/);
});

test('suryeok item region stops above the next type header', () => {
  const out = normalizeDetectResult(
    {
      page_layout: 'two_column',
      type_headers: [{ label: '유형 04', title: '두 점 사이의 거리 이용하기', bbox: [520, 60, 560, 480] }],
      items: [
        {
          number: '11',
          category: 'type_problem',
          column: 1,
          content_group: { kind: 'type', label: '유형 03', title: '좌표평면 위의 두 점 사이의 거리' },
          bbox: [300, 71, 316, 100],
          item_region: [300, 115, 340, 400],
        },
        {
          number: '12~14',
          category: 'type_problem',
          column: 1,
          is_set_header: true,
          content_group: { kind: 'type', label: '유형 04', title: '두 점 사이의 거리 이용하기' },
          bbox: [600, 71, 616, 140],
          item_region: [600, 145, 640, 480],
        },
      ],
    },
    { rawPage: 12, displayPage: 12, series: 'suryeok', sectionHint: 'type_problem' },
  );
  // 유형 04 머리말(y=520) 위에서 끊겨야 한다.
  assert.equal(out.items[0].item_region[2], 512);
});

test('suryeok item region keeps its own bottom when a new type starts without header coords', () => {
  const out = normalizeDetectResult(
    {
      page_layout: 'two_column',
      items: [
        {
          number: '11',
          category: 'type_problem',
          column: 1,
          content_group: { kind: 'type', label: '유형 03', title: '두 점 사이의 거리' },
          bbox: [300, 71, 316, 100],
          item_region: [300, 115, 380, 400],
        },
        {
          number: '12',
          category: 'type_problem',
          column: 1,
          content_group: { kind: 'type', label: '유형 04', title: '거리 이용하기' },
          bbox: [600, 71, 616, 100],
          item_region: [600, 115, 680, 400],
        },
      ],
    },
    { rawPage: 12, displayPage: 12, series: 'suryeok', sectionHint: 'type_problem' },
  );
  assert.equal(out.items[0].item_region[2], 406);
});

test('suryeok region repair is idempotent for the last item in a column', () => {
  const page = {
    page_layout: 'two_column',
    items: [
      {
        number: '01',
        category: 'type_problem',
        column: 1,
        bbox: [295, 88, 312, 116],
        item_region: [295, 116, 829, 480],
      },
    ],
  };
  const out = normalizeDetectResult(page, {
    rawPage: 22,
    displayPage: 22,
    series: 'suryeok',
    sectionHint: 'type_problem',
  });
  const bottom = out.items[0].item_region[2];
  // 좌표 보정 2차 판독 뒤 같은 결과에 다시 걸어도 아래끝이 늘어나면 안 된다.
  repairSuryeokItemRegions(out, 'suryeok');
  assert.equal(out.items[0].item_region[2], bottom);
});

test('templated number bboxes are recognized as unmeasured', () => {
  // 실제로 어긋났던 22쪽 응답: 폭 82 · 높이 21 상자가 한 줄씩 위로 밀려 있었다.
  const templated = [
    { number: '01', bbox: [266, 88, 287, 170] },
    { number: '02~03', bbox: [220, 532, 241, 616], is_set_header: true },
    { number: '02', bbox: [270, 532, 291, 614] },
    { number: '03', bbox: [518, 532, 539, 614] },
    { number: '04', bbox: [708, 532, 729, 614] },
  ];
  assert.equal(numberBboxesLookTemplated(templated), true);

  const measured = [
    { number: '01', bbox: [295, 88, 312, 117] },
    { number: '02~03', bbox: [248, 532, 262, 601], is_set_header: true },
    { number: '02', bbox: [298, 532, 315, 561] },
    { number: '03', bbox: [546, 532, 563, 561] },
    { number: '04', bbox: [736, 533, 750, 561] },
  ];
  assert.equal(numberBboxesLookTemplated(measured), false);
});

test('overwriting geometry lets the suryeok region repair run again', () => {
  const out = normalizeDetectResult(
    {
      page_layout: 'two_column',
      items: [
        { number: '01', category: 'type_problem', column: 1, bbox: [266, 88, 287, 170] },
        { number: '02', category: 'type_problem', column: 1, bbox: [500, 88, 521, 170] },
      ],
    },
    { rawPage: 22, displayPage: 22, series: 'suryeok', sectionHint: 'type_problem' },
  );
  overwriteItemGeometry(out, {
    items: [
      { number: '01', bbox: [295, 88, 312, 117] },
      { number: '02', bbox: [529, 88, 546, 117] },
    ],
  });
  repairSuryeokItemRegions(out, 'suryeok');
  assert.equal(out.items[0].item_region[0], 289);
  assert.match(out.notes, /item_geometry_replaced=2/);
});

test('suryeok labels survive only on unit review items', () => {
  const out = normalizeDetectResult(
    {
      items: [
        { number: '14', category: 'unit_review', label: '계산 조심', ...geometry },
        { number: '15', category: 'type_problem', label: '중', ...geometry },
      ],
    },
    { rawPage: 30, displayPage: 30, series: 'suryeok', sectionHint: 'unit_review' },
  );
  assert.equal(out.items[0].label, '계산 조심');
  assert.equal(out.items[1].label, '');
});

test('suryeok skill-test labels are kept and stored as unit_review', () => {
  const out = normalizeDetectResult(
    {
      section: 'unit_review',
      items: [
        { number: '03', category: 'unit_review', label: '시험에 꼭!', ...geometry },
        { number: '07', category: 'unit_review', label: '도전해 얍!', ...geometry },
      ],
    },
    { rawPage: 200, displayPage: 200, series: 'suryeok', sectionHint: 'skill_test' },
  );
  assert.equal(out.section, 'unit_review');
  assert.equal(out.items[0].label, '시험에 꼭!');
  assert.equal(out.items[1].label, '도전해 얍!');
});

// 공통수학2 p44 는 좌단 맨 위가 "[08-13]" 로 시작한다. 앞 지면에서 이어진
// 세트라 유형 머리말이 없고, 모델이 이것만 빠뜨려서 08~13 이 공통 지문 없이
// 낱개로 저장됐다. 우단의 [14-16]·[17-19] 는 멀쩡히 잡혔었다.
test('suryeok detect prompt claims range headers in both columns', () => {
  const prompt = buildDetectProblemsPrompt({
    rawPage: 44,
    displayPage: 44,
    series: 'suryeok',
    sectionHint: 'type_problem',
  });
  assert.match(prompt, /\[08-13\]/);
  assert.match(prompt, /좌단·우단 양쪽을 모두 훑어라/);
  assert.match(prompt, /유형 머리말 없이 시작하는 범위 지문/);
});

// 지면에는 하이픈으로 인쇄되지만("[08-13]") 정답·해설 파일은 물결을 쓴다.
// 한쪽으로 모으지 않으면 세트 헤더의 키가 어긋난다.
test('suryeok range headers survive hyphen printing', () => {
  const out = normalizeDetectResult(
    {
      items: [
        {
          number: '08-13',
          category: 'type_problem',
          is_set_header: true,
          ...geometry,
        },
        { number: '8', category: 'type_problem', ...geometry },
      ],
    },
    { rawPage: 44, displayPage: 44, series: 'suryeok', sectionHint: 'type_problem' },
  );
  assert.equal(out.items[0].number, '08~13');
  assert.equal(out.items[0].is_set_header, true);
  assert.deepEqual(out.items[0].set_range, { from: 8, to: 13 });
  assert.equal(out.items[1].number, '08');
  assert.equal(out.items[1].is_set_header, false);
});

test('suryeok answer prompt anchors each expected item to its body page badge', () => {
  const prompt = buildExtractAnswersPrompt({
    rawPage: 3,
    displayPage: 3,
    series: 'suryeok',
    expectedNumbers: ['01', '02'],
    expectedEntries: [
      { number: '01', corner: '', page: 25 },
      { number: '02', corner: '단원 마무리 평가', page: 29 },
    ],
  });
  assert.match(prompt, /수력충전 답지 읽는 법/);
  assert.match(prompt, /problem_number="01" \| 블록=일반 소단원 \| 배지=p\.25/);
  assert.match(prompt, /problem_number="02" \| 블록="단원 마무리 평가" \| 배지=p\.29/);
  assert.match(prompt, /source_corner/);
});

test('suryeok solution prompt asks for the block badge as well', () => {
  const prompt = buildDetectSolutionRefsPrompt({
    rawPage: 22,
    displayPage: 22,
    series: 'suryeok',
    expectedNumbers: ['01'],
    expectedEntries: [{ number: '01', corner: '', page: 10 }],
  });
  assert.match(prompt, /수력충전 해설 읽는 법/);
  assert.match(prompt, /problem_number="01" \| 블록=일반 소단원 \| 배지=p\.10/);
  assert.match(prompt, /source_page_end/);
});

test('suryeok expected entries are grouped into blocks in book order', () => {
  const blocks = groupSuryeokExpectedBlocks([
    { number: '01', corner: '', page: 16 },
    { number: '02', corner: '', page: 16 },
    { number: '03', corner: '', page: 17 },
    { number: '01', corner: '', page: 18 },
    { number: '02', corner: '', page: 19 },
    { number: '01', corner: '단원 마무리 평가', page: 30 },
  ]);
  assert.equal(blocks.length, 3);
  assert.equal(blocks[0].badge, 'p.16~17');
  assert.equal(blocks[1].badge, 'p.18~19');
  assert.equal(blocks[2].corner, '단원 마무리 평가');
});

test('suryeok prompts explain header-less continuation blocks', () => {
  const expectedEntries = [
    { number: '01', corner: '', page: 16 },
    { number: '11', corner: '', page: 17 },
    { number: '01', corner: '', page: 18 },
  ];
  const solution = buildDetectSolutionRefsPrompt({
    rawPage: 26,
    displayPage: 26,
    series: 'suryeok',
    expectedNumbers: ['01', '11'],
    expectedEntries,
  });
  assert.match(solution, /블록 차례/);
  assert.match(solution, /1\) 블록=일반 소단원 \| 배지=p\.16~17/);
  assert.match(solution, /\[C2\]/);

  const answers = buildExtractAnswersPrompt({
    rawPage: 3,
    displayPage: 3,
    series: 'suryeok',
    expectedNumbers: ['01', '11'],
    expectedEntries,
  });
  assert.match(answers, /블록 차례/);
  assert.match(answers, /이어지는 블록/);
});

// 답지에 "05~09" 머리표 아래 좌표평면 그림 한 장만 있는 묶음이 있다. 예전
// 프롬프트는 [K4]("기대 번호 그대로") 때문에 범위 라벨을 쓸 길이 없어서 모델이
// 첫 번호에만 그림을 붙이고 나머지 네 문항을 생략했고, 그 정답이 통째로 비었다.
test('suryeok answer prompt spreads one shared figure over the whole range', () => {
  const prompt = buildExtractAnswersPrompt({
    rawPage: 11,
    displayPage: 11,
    series: 'suryeok',
    expectedNumbers: ['05', '06', '07', '08', '09'],
    expectedEntries: [
      { number: '05', corner: '', page: 180 },
      { number: '06', corner: '', page: 180 },
      { number: '07', corner: '', page: 180 },
      { number: '08', corner: '', page: 180 },
      { number: '09', corner: '', page: 180 },
    ],
  });
  assert.match(prompt, /\[K8\]/);
  assert.match(prompt, /그림 하나에 함께/);
  assert.match(prompt, /범위에 드는 기대 번호마다 item 을 하나씩/);
  assert.match(prompt, /kind="image"/);
});

// 실제 정답 단계는 이 레이아웃 경로로 돈다. 모델이 "05~09" 를 "05" 로 줄여
// 읽어서 06~09 의 정답이 통째로 비었다. 범위 표기를 그대로 실어 보내야 앱이
// 그림 한 장을 다섯 문항에 나눠 붙일 수 있다.
test('answer layout keeps a range header instead of shrinking it', () => {
  assert.match(buildAnswerLayoutPrompt({ rawPage: 11 }), /\[A8\]/);
  assert.match(buildAnswerLayoutPrompt({ rawPage: 11 }), /범위 그대로/);

  const out = normalizeAnswerLayoutResult({
    entries: [
      { kind: 'header', title: '02 순서쌍과 좌표평면', page_start: 179, page_end: 181 },
      {
        kind: 'answer',
        problem_number: '05~09',
        answer_kind: 'image',
        answer_text: '[image]',
        bbox: [500, 100, 700, 400],
      },
    ],
  });
  const answer = out.entries.find((e) => e.kind !== 'header');
  assert.equal(answer.problem_number, '05~09');
  assert.equal(answer.kind, 'image');
  assert.deepEqual(answer.bbox, [500, 100, 700, 400]);
});

test('suryeok prompts can exclude blocks that were already read', () => {
  const prompt = buildExtractAnswersPrompt({
    rawPage: 1,
    displayPage: 1,
    series: 'suryeok',
    expectedNumbers: ['01'],
    expectedEntries: [{ number: '01', corner: '', page: 18 }],
    skipBadges: ['p.10~11', '단원 마무리 평가 p.30~33'],
  });
  assert.match(prompt, /이미 처리한 블록/);
  assert.match(prompt, /p\.10~11, 단원 마무리 평가 p\.30~33/);
});

test('solution block index prompt asks for badges and continuation', () => {
  const prompt = buildSolutionBlockIndexPrompt({ rawPage: 24 });
  assert.match(prompt, /블록 머리/);
  assert.match(prompt, /leading_continuation/);
  assert.match(prompt, /page_start/);
});

test('answer layout reads headers and every green answer without matching', () => {
  const prompt = buildAnswerLayoutPrompt({ rawPage: 3 });
  assert.match(prompt, /빠른 정답 PDF/);
  assert.match(prompt, /소단원 머리/);
  assert.match(prompt, /초록색 두 자리 문항번호/);
  assert.match(prompt, /어느 정답이 어느 본문 문항인지 추론하지/);

  const normalized = normalizeAnswerLayoutResult({
    leading_continuation: false,
    entries: [
      {
        kind: 'header',
        title: '09 좌표평면 위의 선분의 내분점',
        page_start: 24,
        page_end: 25,
        bbox: [10, 10, 45, 480],
      },
      {
        kind: 'answer',
        problem_number: '01',
        answer_kind: 'subjective',
        answer_text: '\\frac{7}{3}, \\frac{8}{3}',
        answer_latex_2d: '',
        bbox: [50, 10, 90, 240],
      },
    ],
  });
  assert.equal(normalized.entries.length, 2);
  assert.equal(normalized.entries[0].page_start, 24);
  assert.equal(normalized.entries[1].problem_number, '01');
  assert.equal(normalized.entries[1].answer_text, '\\frac{7}{3}, \\frac{8}{3}');
});

// 해설도 "05~09  답 해설 참조" 처럼 여러 문항이 한 덩어리로 묶인다. 범위
// 표기를 그대로 실어 보내야 앱이 그 자리를 다섯 문항에 나눠 붙일 수 있다.
test('solution block index keeps a range number instead of shrinking it', () => {
  assert.match(buildSolutionBlockIndexPrompt({ rawPage: 26 }), /\[P5\]/);
  assert.match(buildSolutionBlockIndexPrompt({ rawPage: 26 }), /범위 그대로/);

  const out = normalizeSolutionBlocksResult({
    blocks: [
      {
        title: '02 순서쌍과 좌표평면',
        page_start: 179,
        page_end: 181,
        header_region: [40, 40, 70, 480],
      },
    ],
    numbers: [
      { text: '04', number_region: [100, 45, 120, 80] },
      { text: '05~09', number_region: [200, 45, 220, 120] },
    ],
  });
  const texts = out.sequence.filter((e) => e.kind === 'number').map((e) => e.text);
  assert.deepEqual(texts, ['04', '05~09']);
  const range = out.numbers.find((n) => n.text === '05~09');
  assert.ok(range.content_region);
});

// 공통수학2 해설 p109 는 오른쪽 단에 "01 답 ⊂ | 02 답 ⊂ | 03 답 ⊄" 격자를
// 6줄 싣는다. 번호가 한 지면에 38개 깔리자 모델이 06 하나를 통째로 흘렸고, 그
// 문항만 해설 좌표가 비었다. 격자는 자로 잰 듯 규칙적이니 빈 칸은 계산으로 채운다.
test('solution grid revives a number the model dropped', () => {
  const numbers = [];
  const colXs = [518, 657, 797];
  const rowYs = [109, 148, 186, 225, 264, 302];
  for (let r = 0; r < rowYs.length; r += 1) {
    for (let c = 0; c < colXs.length; c += 1) {
      const value = r * colXs.length + c + 1;
      if (value === 6) continue; // 모델이 흘린 칸
      numbers.push({
        text: String(value).padStart(2, '0'),
        number_region: [rowYs[r], colXs[c], rowYs[r] + 15, colXs[c] + 28],
      });
    }
  }
  // 격자 아래로 이어지는 보통 풀이. 단마다 한 칸씩만 쓴다.
  for (const y of [341, 380, 476]) {
    numbers.push({ text: '19', number_region: [y, 518, y + 15, 546] });
  }
  // 왼쪽 단은 앞 소단원의 풀이가 이어진다.
  for (const y of [71, 138, 226]) {
    numbers.push({ text: '32', number_region: [y, 74, y + 15, 102] });
  }

  const out = normalizeSolutionBlocksResult({ numbers });
  const six = out.numbers.find((n) => n.text === '06');
  assert.ok(six, '흘린 06 을 격자 좌표로 되살려야 한다');
  assert.equal(six.repaired, true);
  assert.deepEqual(six.number_region, [148, 797, 163, 825]);
  assert.ok(six.content_region, '되살린 칸도 풀이 영역을 받는다');
  // 없던 번호를 지어내지는 않는다.
  assert.equal(out.numbers.filter((n) => n.repaired === true).length, 1);
});

test('solution grid repair leaves ordinary pages alone', () => {
  // 좌우 2단에 풀이가 한 줄씩 놓인 보통 지면. 격자가 아니므로 손대지 않는다.
  const numbers = [
    { text: '11', number_region: [100, 74, 115, 102] },
    { text: '12', number_region: [200, 74, 215, 102] },
    { text: '13', number_region: [320, 74, 335, 102] },
    { text: '14', number_region: [100, 518, 115, 546] },
    { text: '15', number_region: [240, 518, 255, 546] },
    { text: '16', number_region: [400, 518, 415, 546] },
  ];
  const out = normalizeSolutionBlocksResult({ numbers });
  assert.equal(out.numbers.length, 6);
  assert.equal(out.numbers.some((n) => n.repaired === true), false);
});

test('solution grid repair stops at the end of the last row', () => {
  // 17 에서 끝나는 격자. 마지막 줄 오른쪽 빈 칸은 문항이 없는 것이지 누락이 아니다.
  const colXs = [518, 657, 797];
  const rowYs = [109, 148, 186, 225, 264, 302];
  const numbers = [];
  for (let r = 0; r < rowYs.length; r += 1) {
    for (let c = 0; c < colXs.length; c += 1) {
      const value = r * colXs.length + c + 1;
      if (value > 17) continue;
      numbers.push({
        text: String(value).padStart(2, '0'),
        number_region: [rowYs[r], colXs[c], rowYs[r] + 15, colXs[c] + 28],
      });
    }
  }
  const out = normalizeSolutionBlocksResult({ numbers });
  assert.equal(out.numbers.some((n) => n.text === '18'), false);
  assert.equal(out.numbers.length, 17);
});

test('solution block index keeps badge page ranges and flags empty pages', () => {
  const withHeads = normalizeSolutionBlocksResult({
    leading_continuation: true,
    blocks: [
      {
        title: '04 두 선분의 길이의 합의 최솟값',
        page_start: 16,
        page_end: 17,
        header_region: [40, 30, 70, 500],
      },
      { title: '풀이', page_start: 'x', page_end: null },
    ],
  });
  assert.equal(withHeads.leading_continuation, true);
  assert.equal(withHeads.blocks.length, 2);
  assert.deepEqual(withHeads.blocks[0], {
    title: '04 두 선분의 길이의 합의 최솟값',
    page_start: 16,
    page_end: 17,
    header_region: [40, 30, 70, 500],
  });
  assert.equal(withHeads.blocks[1].page_start, 0);

  // 머리가 하나도 없는 지면은 통째로 앞 블록이 이어지는 것이다.
  const empty = normalizeSolutionBlocksResult({
    leading_continuation: false,
    blocks: [],
  });
  assert.equal(empty.leading_continuation, true);
  assert.equal(empty.blocks.length, 0);
});

test('unit review corner is recognized by the badge guard', () => {
  assert.equal(canonicalCorner('단원 마무리 평가'), 'unit_review');
  assert.equal(canonicalCorner('단원 마무리 평가 [01~13]'), 'unit_review');
  assert.equal(canonicalCorner('거듭제곱과 지수법칙'), '');
});

test('suryeok toc prompt keeps unit review rows and drops concept sections', () => {
  const prompt = buildParseTocPrompt({ series: 'suryeok' });
  assert.match(prompt, /수력충전/);
  assert.match(prompt, /단원 마무리 평가/);
});

test('suryeok toc prompt claims the skill test block as a big unit', () => {
  const prompt = buildParseTocPrompt({ series: 'suryeok' });
  assert.match(prompt, /학교 시험 대비 실력 향상 테스트/);
  // 로마숫자를 떼면 세 편의 이름이 모두 같아진다.
  assert.match(prompt, /로마숫자를 \*\*빼지 말고\*\*/);
  assert.match(prompt, /"name": "실력 향상 테스트"/);
  // [T3] 부속물 배제 규칙이 이 묶음까지 삼키지 않도록 예외를 달아 둔다.
  assert.match(prompt, /시리즈 규칙이 트리에 넣으라고 명시한 항목은 예외/);
});
