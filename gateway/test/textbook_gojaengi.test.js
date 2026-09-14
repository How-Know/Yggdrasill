// 고쟁이 시리즈 프롬프트·정규화 회귀 테스트.
//
// 이 교재의 함정은 두 가지다.
//   1. 본문(A~D)은 번호가 책 전체를 관통하는 세 자리라 배지 대조가 필요 없다.
//      필요 없는 대조를 켜면 배지를 못 읽은 문항이 통째로 버려진다.
//   2. 워크북(E·F)은 묶음마다 01 부터 다시 시작하고 그 묶음 일곱 개가 한 지면에
//      나란히 실린다. 배지 대조를 안 켜면 남의 묶음 정답이 조용히 들어앉는다.
// 그래서 "배지가 실려 온 요청에서만 대조로 넘어간다" 는 갈림길을 고정해 둔다.

import { strict as assert } from 'node:assert';
import { test } from 'node:test';

import { buildExtractAnswersPrompt } from '../src/textbook/vlm_answer_prompt.js';
import { buildDetectSolutionRefsPrompt } from '../src/textbook/vlm_solution_refs_prompt.js';
import { normalizeSolutionRefsResult } from '../src/textbook/vlm_solution_refs_client.js';
import {
  buildExpectedIndex,
  canonicalCorner,
  resolveExpectedBox,
  wrongBadgeLabels,
} from '../src/textbook/vlm_corner_guard.js';
import { normalizeProblemNumberKey } from '../src/textbook/problem_number_key.js';
import {
  buildDetectProblemsPrompt,
  VLM_DETECT_SECTIONS,
} from '../src/textbook/vlm_detect_prompt.js';
import { GOJAENGI_SECTION_BY_SUB_KEY } from '../src/textbook/vlm_detect_prompt_gojaengi.js';
import {
  buildGojaengiWorkbookPrompt,
  normalizeGojaengiWorkbookResult,
} from '../src/textbook/vlm_rpm_section_client.js';
import { normalizeDetectResult } from '../src/textbook/vlm_detect_client.js';

// 앱이 보내는 모양. 본교재도 배지를 실어 보낸다 — 번호키가 앞자리 0 을 떼면서
// 워크북 두 자리 번호와 겹치기 때문이다(아래 충돌 테스트 참고).
const BODY_ENTRIES = [
  { number: '054', corner: '본교재', page: 21, position: 0 },
  { number: '055', corner: '본교재', page: 21, position: 1 },
];
// 배지를 아예 안 실은 옛 요청. 되받아 주는 길이 남아 있는지만 확인한다.
const UNBADGED_ENTRIES = [
  { number: '054', corner: '', page: 0, position: 0 },
  { number: '055', corner: '', page: 0, position: 1 },
];
const WORKBOOK_ENTRIES = [
  { number: '01', corner: '중단원 TEST', page: 183, position: 0 },
  { number: '02', corner: '중단원 TEST', page: 183, position: 1 },
];

test('gojaengi slots map onto declared detect sections', () => {
  for (const section of Object.values(GOJAENGI_SECTION_BY_SUB_KEY)) {
    assert.ok(
      VLM_DETECT_SECTIONS.includes(section),
      `${section} 이 VLM_DETECT_SECTIONS 에 없다`,
    );
  }
});

test('gojaengi detect result keeps the swept section when the page has no header', () => {
  // 이어지는 지면에는 Step 머리말이 인쇄되지 않는다. 모델이 section 을 비워
  // 보내도 훑는 중인 슬롯을 그대로 유지해야 크롭이 남의 슬롯으로 새지 않는다.
  const out = normalizeDetectResult(
    { section: '', page_kind: 'problem_page', items: [] },
    { sectionHint: 'advanced_type' },
  );
  assert.equal(out.section, 'advanced_type');
});

test('gojaengi detect prompt pins the three digit numbering per step', () => {
  const prompt = buildDetectProblemsPrompt({
    rawPage: 21,
    displayPage: 21,
    series: 'gojaengi',
    sectionHint: 'core_type',
  });
  assert.match(prompt, /세 자리/);
  assert.match(prompt, /section="core_type"/);
  // 유형 배지의 두 자리 번호를 문항으로 만들면 번호열이 어긋난다.
  assert.match(prompt, /핵심 03/);
  assert.match(prompt, /문항 번호가 아니다/);
  // 쪽번호 한 줄이 본문 세 자리 문항(259~261)을 통째로 삼키지 않게.
  assert.match(prompt, /쪽번호는 21 하나뿐/);
  assert.match(prompt, /259, 260, 261/);
});

test('gojaengi keeps sequential three-digit items when notes say concept_page', () => {
  const result = normalizeDetectResult({
    section: 'advanced_type',
    page_kind: 'concept_page',
    page_layout: 'two_column',
    items: ['259', '260', '261'].map((number, index) => ({
      number,
      label: '',
      is_set_header: false,
      column: 1,
      bbox: [120 + index * 160, 60, 150 + index * 160, 120],
      item_region: [150 + index * 160, 60, 270 + index * 160, 470],
    })),
    notes: 'concept_page',
  }, { series: 'gojaengi', sectionHint: 'advanced_type' });

  assert.deepEqual(
    result.items.map((item) => item.number),
    ['259', '260', '261'],
  );
  assert.equal(result.page_kind, 'problem_page');
  assert.match(result.notes, /concept_page_overridden_by_valid_gojaengi_numbers/);
});

test('gojaengi backfills missing item_region on a vertical body page', () => {
  const result = normalizeDetectResult({
    section: 'core_type',
    page_kind: 'problem_page',
    page_layout: 'two_column',
    items: ['257', '258'].map((number, index) => ({
      number,
      label: '',
      is_set_header: false,
      column: 1,
      bbox: [100 + index * 200, 50, 130 + index * 200, 110],
    })),
    notes: '',
  }, { series: 'gojaengi', sectionHint: 'core_type' });

  assert.equal(result.items.length, 2);
  for (const item of result.items) {
    assert.equal(item.item_region.length, 4);
    assert.ok(item.item_region[0] >= item.bbox[2]);
  }
});

test('gojaengi workbook TEST corners canonicalize apart', () => {
  assert.equal(canonicalCorner('중단원 TEST'), 'mid_unit_test');
  assert.equal(canonicalCorner('대단원 TEST'), 'big_unit_test');
  // 배지 대소문자가 흔들려도 같은 묶음으로 본다.
  assert.equal(canonicalCorner('중단원 test'), 'mid_unit_test');
  // 중단원용과 대단원용이 섞이면 다른 묶음의 답이 들어앉는다.
  assert.notEqual(
    canonicalCorner('중단원 TEST'),
    canonicalCorner('대단원 TEST'),
  );
});

test('gojaengi body answers also carry the 본교재 badge table', () => {
  const prompt = buildExtractAnswersPrompt({
    rawPage: 229,
    displayPage: 229,
    expectedNumbers: BODY_ENTRIES.map((e) => e.number),
    expectedEntries: BODY_ENTRIES,
    series: 'gojaengi',
  });
  assert.match(prompt, /고쟁이 답지 읽는 법/);
  assert.match(prompt, /source_corner/);
  assert.match(prompt, /묶음="본교재" \| 이름=미상 \| 배지=21쪽/);
});

test('배지가 아예 없는 옛 요청은 번호만으로 읽는 길로 남는다', () => {
  const prompt = buildExtractAnswersPrompt({
    rawPage: 229,
    displayPage: 229,
    expectedNumbers: UNBADGED_ENTRIES.map((e) => e.number),
    expectedEntries: UNBADGED_ENTRIES,
    series: 'gojaengi',
  });
  assert.doesNotMatch(prompt, /고쟁이 답지 읽는 법/);
  assert.doesNotMatch(prompt, /source_corner/);
});

test('gojaengi workbook answers demand the workbook page badge', () => {
  const prompt = buildExtractAnswersPrompt({
    rawPage: 234,
    displayPage: 234,
    expectedNumbers: WORKBOOK_ENTRIES.map((e) => e.number),
    expectedEntries: WORKBOOK_ENTRIES,
    series: 'gojaengi',
  });
  assert.match(prompt, /고쟁이 답지 읽는 법/);
  assert.match(prompt, /source_corner/);
  // 배지는 언제나 범위로 인쇄되므로, 포함 판정을 못 박아야 묶음을 고른다.
  assert.match(prompt, /범위 안에 들면/);
  assert.match(prompt, /묶음="중단원 TEST" \| 이름=미상 \| 배지=183쪽/);
  // 문항 오른쪽 "본문 002" 배지를 번호로 읽으면 번호열이 무너진다.
  assert.match(prompt, /본문 002/);
});

test('gojaengi workbook solution refs skip the answer summary box', () => {
  const prompt = buildDetectSolutionRefsPrompt({
    rawPage: 144,
    displayPage: 144,
    expectedNumbers: WORKBOOK_ENTRIES.map((e) => e.number),
    expectedEntries: WORKBOOK_ENTRIES,
    series: 'gojaengi',
  });
  assert.match(prompt, /고쟁이 해설 읽는 법/);
  assert.match(prompt, /source_corner/);
  assert.match(prompt, /범위 안에 들면/);
  // 묶음 머리 아래 요약 상자에서 좌표를 잡으면 모든 풀이가 한 자리를 가리킨다.
  assert.match(prompt, /정답만 모아 둔 요약/);
  // 왼쪽 단의 직전 묶음 풀이와 오른쪽 단의 새 머리말이 한 지면에 공존한다.
  assert.match(prompt, /새 머리말의 쪽 배지를 지면 전체에 적용하지 마라/);
});

// ─────────── 워크북 지면 묶음 분류 ───────────
//
// 목차에는 워크북 두 묶음의 시작 쪽만 한 번 인쇄되고, 어느 중단원 TEST 가 몇
// 쪽부터인지는 없다. 그래서 지면 머리말을 읽어야 E·F 슬롯의 쪽 범위가 나온다.
// 실지면에서 확인한 함정은 **펼침면 오른쪽 지면에 위쪽 배지가 없다**는 것이다
// (166~169 중 167·169). 꼬리말을 읽으라고 못 박아 두지 않으면 그 지면들이
// unknown 으로 떨어져 묶음 경계가 흔들린다.
test('고쟁이 워크북 프롬프트는 오른쪽 지면의 꼬리말 경로를 못 박는다', () => {
  const prompt = buildGojaengiWorkbookPrompt([166, 167, 168, 169]);
  assert.match(prompt, /오른쪽 지면에는 위쪽 배지가 인쇄되지 않는다/);
  assert.match(prompt, /꼬리말/);
  assert.match(prompt, /세로 탭/);
  assert.match(prompt, /mid_unit_test/);
  assert.match(prompt, /big_unit_test/);
  // 문항 참조 배지를 단원 번호로 읽으면 묶음이 쪽마다 갈린다.
  assert.match(prompt, /본문 011/);
  // 지어낸 이름은 되돌릴 수 없으니 빈 값을 앱에 넘기게 한다.
  assert.match(prompt, /추측해 채우지 마라/);
});

test('고쟁이 워크북 정규화는 모르는 corner 를 unknown 으로 떨어뜨린다', () => {
  const out = normalizeGojaengiWorkbookResult(
    {
      pages: [
        {
          image_index: 0,
          corner: 'mid_unit_test',
          unit_number: 1,
          unit_name: '이등변삼각형과 직각삼각형',
        },
        // 본문 단계 코드가 섞여 들어오면 묶음으로 쓸 수 없다.
        { image_index: 1, corner: 'core_type', unit_number: 9, unit_name: 'x' },
        { image_index: 2, corner: 'big_unit_test', unit_number: 0, unit_name: '' },
      ],
      notes: '',
    },
    [166, 167, 206],
  );
  assert.equal(out.pages.length, 3);
  assert.equal(out.pages[0].corner, 'mid_unit_test');
  assert.equal(out.pages[0].raw_page, 166);
  assert.equal(out.pages[0].unit_number, 1);
  assert.equal(out.pages[1].corner, 'unknown');
  // 번호 0 은 없는 것으로 본다 — 0-based 로 오독하면 앞 단원에 붙는다.
  assert.equal(out.pages[2].unit_number, null);
  assert.equal(out.pages[2].corner, 'big_unit_test');
});

test('응답이 빠뜨린 지면은 unknown 자리를 남겨 순번이 밀리지 않는다', () => {
  const out = normalizeGojaengiWorkbookResult(
    { pages: [{ image_index: 2, corner: 'big_unit_test', unit_name: '삼각형의 성질' }] },
    [206, 207, 208],
  );
  assert.deepEqual(
    out.pages.map((p) => [p.raw_page, p.corner]),
    [
      [206, 'unknown'],
      [207, 'unknown'],
      [208, 'big_unit_test'],
    ],
  );
});

// ─────────── 본교재 / 워크북 번호키 충돌 ───────────
//
// 본교재는 책 전체를 관통하는 세 자리("005"), 워크북은 묶음마다 01 부터 다시
// 시작하는 두 자리("05")다. 체계가 달라 섞여도 안전할 것 같지만 번호키는 앞자리
// 0 을 떼기 때문에 둘 다 "5" 가 된다. 추출은 중단원 단위라 A~E 가 한 요청에 함께
// 실리고, 그러면 앞 24개가 통째로 겹친다.
//
// 실제로 났던 사고: 2-2 중단원 1 은 기대 77개(본교재 001~053 + 워크북 01~24) 중
// 29개만 채워졌다 — 겹치지 않는 본교재 025~053 뿐이었고, 겹친 48개는 출처를
// 못 가려 전부 버려졌다. 그래서 본교재에도 "본교재" 배지를 실어 보낸다.
test('본교재 배지는 중단원·대단원 TEST 와 다른 코너로 갈린다', () => {
  assert.equal(canonicalCorner('본교재'), 'body_book');
  assert.equal(canonicalCorner('빠른 정답 본교재'), 'body_book');
  assert.equal(canonicalCorner('중단원 TEST'), 'mid_unit_test');
  assert.equal(canonicalCorner('대단원 TEST'), 'big_unit_test');
  assert.notEqual(canonicalCorner('본교재'), canonicalCorner('중단원 TEST'));
});

test('키가 겹친 본교재 005 / 워크북 05 를 쪽 배지로 갈라낸다', () => {
  // 앱이 보내는 모양 그대로: 본교재는 본문 쪽, 워크북은 워크북 쪽.
  const expected = [
    { number: '005', corner: '본교재', page: 7 },
    { number: '05', corner: '중단원 TEST', page: 166 },
  ];
  const index = buildExpectedIndex(expected, normalizeProblemNumberKey);
  // 두 항목이 같은 번호키 하나에 후보로 묶여 있어야 한다 — 이 겹침이 사고의 씨앗.
  assert.equal(index.byKey.get(normalizeProblemNumberKey('005')).length, 2);

  // 본교재 지면(배지 "본교재 007~009쪽")에서 읽은 "005".
  const onBody = resolveExpectedBox(
    { source_corner: '본교재', source_page: 7, source_page_end: 9 },
    '005',
    index,
    normalizeProblemNumberKey,
  );
  assert.equal(onBody.reject, false);
  assert.equal(onBody.matched?.index, 0);

  // 워크북 지면(배지 "워크북 166~169쪽")에서 읽은 "05".
  const onWorkbook = resolveExpectedBox(
    { source_corner: '중단원 TEST', source_page: 166, source_page_end: 169 },
    '05',
    index,
    normalizeProblemNumberKey,
  );
  assert.equal(onWorkbook.reject, false);
  assert.equal(onWorkbook.matched?.index, 1);
});

test('본교재 배지가 없으면 겹친 후보를 못 가려 버려진다 (되돌아가면 안 되는 상태)', () => {
  // 배지를 한쪽만 실었던 옛 모양. 본교재 후보에 코너·쪽이 없으니 워크북 후보와
  // 함께 "모순 없음" 으로 남아 점수 0 짜리 후보가 둘이 되고, 근거 없이 찍지 않는
  // 규칙에 걸려 위치가 안 나온다. 앱은 requireExpectedIndex 로 이런 항목을
  // 버리므로 정답이 조용히 빈다.
  const index = buildExpectedIndex(
    [
      { number: '005' },
      { number: '05', corner: '중단원 TEST', page: 166 },
    ],
    normalizeProblemNumberKey,
  );
  const undecided = resolveExpectedBox(
    { source_corner: 'Step 1' },
    '005',
    index,
    normalizeProblemNumberKey,
  );
  assert.equal(undecided.matched, null);
  assert.equal(undecided.reject, false);
});

test('고쟁이 답지 프롬프트는 본교재·워크북 두 종류를 함께 못 박는다', () => {
  const prompt = buildExtractAnswersPrompt({
    rawPage: 1,
    displayPage: 1,
    expectedNumbers: ['005', '05'],
    expectedEntries: [
      { number: '005', corner: '본교재', page: 7 },
      { number: '05', corner: '중단원 TEST', page: 166 },
    ],
    series: 'gojaengi',
  });
  assert.match(prompt, /빠른 정답 \*\*본교재\*\*/);
  assert.match(prompt, /빠른 정답 \*\*WORKBOOK\*\*/);
  // 상세표에 두 종류가 섞여 온다는 것과, 지면 종류가 다른 줄은 빠뜨리라는 지시.
  assert.match(prompt, /상세표에는 두 종류가 섞여 들어온다/);
  // 출처를 되돌려 받아야 서버가 겹친 후보를 가릴 수 있다.
  assert.match(prompt, /source_corner/);
  assert.match(prompt, /본교재 007~009쪽/);
});

test('고쟁이 해설 프롬프트도 본교재 묶음을 다룬다', () => {
  const prompt = buildDetectSolutionRefsPrompt({
    rawPage: 10,
    displayPage: 10,
    expectedNumbers: ['005'],
    expectedEntries: [{ number: '005', corner: '본교재', page: 7 }],
    series: 'gojaengi',
  });
  assert.match(prompt, /본교재 해설/);
  assert.match(prompt, /WORKBOOK/);
  // 워크북 요약 상자를 풀이로 잡으면 좌표가 통째로 어긋난다.
  assert.match(prompt, /정답만 모아 둔/);
  assert.match(prompt, /source_corner/);
});

// 실지면 2-2 답지 6쪽. "중단원 TEST" 보라 배지 묶음이 일곱 개 서 있고, 찾는
// 묶음은 "04 여러 가지 사각형"(워크북 178~181쪽, 문항 25개) 인데 바로 옆 단 맨
// 위가 "05 도형의 닮음"(182~185쪽, 문항 24개) 이다. 모델은 절반쯤 옆 묶음을
// 골라 24개를 올렸고 출처 대조가 전부 버려 0건이 됐다. 이름과 문항 수를 함께
// 실어 보내 모델이 자기 검산을 할 수 있게 한다.
test('고쟁이 답지 상세표는 묶음 이름과 문항 수를 함께 싣는다', () => {
  const entries = Array.from({ length: 25 }, (_, i) => ({
    number: String(i + 1).padStart(2, '0'),
    corner: '중단원 TEST',
    title: '여러 가지 사각형',
    page: 178 + Math.floor(i / 7),
  }));
  const prompt = buildExtractAnswersPrompt({
    rawPage: 6,
    displayPage: 6,
    expectedNumbers: entries.map((e) => e.number),
    expectedEntries: entries,
    series: 'gojaengi',
  });
  assert.match(prompt, /이름="여러 가지 사각형"/);
  assert.match(prompt, /중단원 TEST "여러 가지 사각형" · 쪽 배지 178~181 · 문항 25개/);
  // 개수가 어긋나면 옆 묶음을 본 것이라고 못 박아야 자기 검산이 된다.
  assert.match(prompt, /문항 수가 위 개수와 다르면/);
  // 묶음들이 맞붙어 있어 01 을 직전 묶음 마지막 줄에서 읽는 사고가 잦았다
  // (블록 04 의 "01 59°" 대신 블록 03 의 "01 ④" 를 올렸다).
  assert.match(prompt, /직전 묶음의 마지막 줄/);
});

test('기대 묶음과 안 겹치는 배지만 건너뛸 라벨이 된다', () => {
  const entries = Array.from({ length: 25 }, (_, i) => ({
    number: String(i + 1).padStart(2, '0'),
    corner: '중단원 TEST',
    page: 178 + Math.floor(i / 7),
  }));
  // 옆 묶음(182~185) 을 통째로 올린 실패 응답.
  const wrong = wrongBadgeLabels(
    {
      items: entries.slice(0, 24).map((e) => ({
        problem_number: e.number,
        source_corner: '중단원 TEST',
        source_page: 182,
        source_page_end: 185,
      })),
    },
    entries,
  );
  assert.deepEqual(wrong, ['중단원 TEST 182~185쪽']);

  // 제 묶음을 읽고 쪽만 한 칸 옮긴 응답은 건너뛰게 만들면 안 된다.
  const near = wrongBadgeLabels(
    {
      items: [
        {
          problem_number: '01',
          source_corner: '중단원 TEST',
          source_page: 178,
          source_page_end: 181,
        },
      ],
    },
    entries,
  );
  assert.deepEqual(near, []);

  // 기대 쪽이 없으면 판정 근거가 없다.
  assert.deepEqual(
    wrongBadgeLabels(
      { items: [{ problem_number: '01', source_page: 182 }] },
      [{ number: '01', corner: '중단원 TEST' }],
    ),
    [],
  );
});

test('틀린 배지를 건너뛸 목록으로 되먹이면 프롬프트에 실린다', () => {
  const entries = [
    { number: '01', corner: '중단원 TEST', title: '여러 가지 사각형', page: 178 },
  ];
  const prompt = buildExtractAnswersPrompt({
    rawPage: 6,
    displayPage: 6,
    expectedNumbers: ['01'],
    expectedEntries: entries,
    skipBadges: ['중단원 TEST 182~185쪽'],
    series: 'gojaengi',
  });
  assert.match(prompt, /건너뛸 묶음/);
  assert.match(prompt, /중단원 TEST 182~185쪽/);
});

// 실지면 해설 p20: "Step 3 … 본교재 031~034쪽" 머리 아래 상자에 106~119 의 답이
// 전부 격자로 나열되고, 실제 풀이는 106·107·108 셋뿐이다(나머지는 뒤 지면).
// 모델이 이 상자를 풀이로 읽으면 기대 번호가 한 지면에서 다 채워져 pending 이
// 0 이 되니 실패로도 안 잡히고, 좌표만 통째로 요약 상자를 가리킨다.
test('고쟁이 해설 프롬프트는 본교재 Step 요약 상자도 막는다', () => {
  const prompt = buildDetectSolutionRefsPrompt({
    rawPage: 20,
    displayPage: 20,
    expectedNumbers: ['106', '119'],
    expectedEntries: [
      { number: '106', corner: '본교재', page: 31 },
      { number: '119', corner: '본교재', page: 34 },
    ],
    series: 'gojaengi',
  });
  assert.match(prompt, /본교재·워크북 두 묶음 모두/);
  // 상자에만 있는 번호를 상자 좌표로 때우면 안 된다.
  assert.match(prompt, /상자에만 있고 실제 풀이가 없다면/);
  // "풀이 없이 답만 있는 문항도 만들라" 던 옛 규칙은 이 상자를 오히려 권했다.
  assert.doesNotMatch(prompt, /풀이 없이 답만 있는 문항도 item 으로 만든다/);
});

test('고쟁이 해설 정규화는 격자로 늘어선 요약 상자 번호를 버린다', () => {
  // 풀이 영역이 없는 칸은 아래 '요약 상자 칸' 테스트가 따로 막는다. 여기서는
  // 격자 판정만 시험하려고 모든 칸에 넉넉한 content_region 을 붙여 둔다.
  const gridRow = (numbers, y) =>
    numbers.map((number, lane) => ({
      problem_number: number,
      number_region: [y, 120 + lane * 100, y + 20, 150 + lane * 100],
      content_region: [y, 120 + lane * 100, y + 200, 150 + lane * 100],
    }));
  const parsed = {
    items: [
      // 요약 상자: 한 줄에 다섯 칸씩, 상자 안에서 아래로 이어진다.
      ...gridRow(['106', '107', '108', '109', '110'], 570),
      ...gridRow(['111', '112', '113', '114', '115'], 615),
      ...gridRow(['116', '117'], 655),
      // 상자 아래 실제 풀이: 단 왼쪽에 혼자 서 있다.
      {
        problem_number: '118',
        number_region: [750, 40, 770, 70],
        content_region: [750, 40, 960, 470],
      },
    ],
  };
  const opts = {
    expectedNumbers: ['106', '107', '108', '109', '110', '111', '112', '113',
      '114', '115', '116', '117', '118'],
  };
  const guarded = normalizeSolutionRefsResult(parsed, {
    ...opts,
    series: 'gojaengi',
  });
  assert.deepEqual(
    guarded.items.map((i) => i.problem_number),
    ['118'],
  );
  // 다른 시리즈 해설은 3단 편집도 있어 격자 판정을 걸지 않는다.
  const untouched = normalizeSolutionRefsResult(parsed, opts);
  assert.equal(untouched.items.length, 13);
});

// 문항을 하나씩 물어보면 격자가 생기지 않으므로 위 판정이 안 걸린다. 실제로
// 153쪽 요약 상자의 21·22 가 이 경로로 뚫려 해설 좌표가 상자를 가리켰다.
// 요약 상자 칸은 번호 옆에 답만 있는 한 줄이라 풀이 영역이 없다는 점으로 막는다.
test('고쟁이 해설 정규화는 풀이 영역 없는 요약 상자 칸을 버린다', () => {
  const parsed = {
    items: [
      // 상자 칸: 모델이 content_region 을 아예 비워 보낸다.
      { problem_number: '21', number_region: [210, 762, 222, 779] },
      // 상자 칸: 자기 칸 크기만 적어 보내는 경우(폭 60, 높이 22).
      {
        problem_number: '22',
        number_region: [210, 840, 222, 860],
        content_region: [210, 840, 232, 900],
      },
      // 실제 풀이: 번호 아래로 여러 줄이 이어진다.
      {
        problem_number: '20',
        number_region: [249, 59, 265, 88],
        content_region: [249, 59, 494, 480],
      },
      // 실제 풀이인데 지면 맨 아래에서 시작해 다음 장으로 넘어간다. 높이는
      // 52 뿐이지만 단 폭을 꽉 채운다(실지면 105쪽 542번).
      {
        problem_number: '19',
        number_region: [881, 512, 894, 557],
        content_region: [881, 512, 933, 921],
      },
    ],
  };
  const out = normalizeSolutionRefsResult(parsed, {
    expectedNumbers: ['19', '20', '21', '22'],
    series: 'gojaengi',
  });
  assert.deepEqual(
    out.items.map((i) => i.problem_number),
    ['20', '19'],
  );
  // 다른 시리즈는 [R2] 대로 content_region 을 비워도 되므로 건드리지 않는다.
  const untouched = normalizeSolutionRefsResult(parsed, {
    expectedNumbers: ['19', '20', '21', '22'],
  });
  assert.equal(untouched.items.length, 4);
});

// 배지는 묶음 첫 지면에만 인쇄된다. 이어지는 지면에서 모델은 꼬리말의 해설
// 쪽번호를 출처로 올리고, 출처 대조가 기대 쪽과 안 맞다며 전부 버린다. 실지면
// 2-2 해설 163쪽에서 12~19 여덟 건이 정확히 검출됐는데도 0건이 된 자리다.
test('고쟁이 해설 정규화는 꼬리말 쪽번호를 배지로 쓰지 않는다', () => {
  const numbers = ['12', '13', '14'];
  const parsed = {
    items: numbers.map((number, i) => ({
      problem_number: number,
      number_region: [100 + i * 200, 40, 120 + i * 200, 70],
      content_region: [100 + i * 200, 40, 280 + i * 200, 470],
      source_corner: '중단원 TEST',
      // 꼬리말 "중단원 TEST 163" 을 그대로 옮겨 적은 값.
      source_page: 163,
      source_page_end: 163,
    })),
  };
  const expectedEntries = [
    { number: '12', corner: '중단원 TEST', page: 199 },
    { number: '13', corner: '중단원 TEST', page: 200 },
    { number: '14', corner: '중단원 TEST', page: 200 },
  ];
  const out = normalizeSolutionRefsResult(parsed, {
    expectedNumbers: numbers,
    expectedEntries,
    series: 'gojaengi',
    rawPage: 163,
    displayPage: 163,
  });
  assert.deepEqual(out.items.map((i) => i.problem_number), numbers);
  assert.deepEqual(out.items.map((i) => i.expected_index), [0, 1, 2]);

  // 지면 번호를 안 알려 주면 옛 동작(전부 버림)이 그대로 재현된다.
  const blind = normalizeSolutionRefsResult(parsed, {
    expectedNumbers: numbers,
    expectedEntries,
    series: 'gojaengi',
  });
  assert.equal(blind.items.length, 0);
});

test('고쟁이 해설 정규화는 진짜 범위 배지는 그대로 믿는다', () => {
  const parsed = {
    items: [
      {
        problem_number: '545',
        number_region: [100, 40, 120, 80],
        content_region: [100, 40, 300, 470],
        source_corner: '본교재',
        source_page: 141,
        source_page_end: 142,
      },
    ],
  };
  // 시작 쪽이 지면 번호와 겹쳐도 끝 쪽이 다르면 꼬리말이 아니라 배지다.
  const out = normalizeSolutionRefsResult(parsed, {
    expectedNumbers: ['545'],
    expectedEntries: [{ number: '545', corner: '본교재', page: 142 }],
    series: 'gojaengi',
    rawPage: 141,
    displayPage: 141,
  });
  assert.deepEqual(out.items.map((i) => i.expected_index), [0]);
});

test('고쟁이 해설은 다음 묶음 배지가 한 쪽 일찍 붙은 마지막 풀이를 살린다', () => {
  const out = normalizeSolutionRefsResult(
    {
      items: [
        {
          problem_number: '23',
          number_region: [273, 514, 291, 544],
          content_region: [273, 514, 442, 925],
          source_corner: '워크북',
          // 실제 기대 문항은 201쪽이지만 같은 지면 아래의 다음 머리말
          // "워크북 202~205쪽"을 잘못 붙인 응답.
          source_page: 202,
          source_page_end: 205,
        },
      ],
    },
    {
      expectedNumbers: ['23'],
      expectedEntries: [
        { number: '23', corner: '중단원 TEST', page: 201 },
      ],
      series: 'gojaengi',
      rawPage: 164,
      displayPage: 164,
    },
  );
  assert.deepEqual(out.items.map((i) => i.expected_index), [0]);
});

test('고쟁이 해설은 세 쪽 떨어진 앞 단원의 같은 번호를 받아들이지 않는다', () => {
  const out = normalizeSolutionRefsResult(
    {
      items: [
        {
          problem_number: '21',
          number_region: [400, 60, 420, 90],
          content_region: [400, 60, 600, 470],
          source_corner: '중단원 TEST',
          source_page: 198,
        },
      ],
    },
    {
      expectedNumbers: ['21'],
      expectedEntries: [
        { number: '21', corner: '중단원 TEST', page: 201 },
      ],
      series: 'gojaengi',
      rawPage: 161,
      displayPage: 161,
    },
  );
  assert.equal(out.items.length, 0);
});

test('고쟁이 해설 프롬프트는 꼬리말 쪽번호와 유형 이름을 출처로 금지한다', () => {
  const prompt = buildDetectSolutionRefsPrompt({
    rawPage: 163,
    displayPage: 163,
    expectedNumbers: ['12'],
    expectedEntries: [
      { number: '12', corner: '중단원 TEST', title: '경우의 수', page: 199 },
    ],
    series: 'gojaengi',
  });
  assert.match(prompt, /source_page 를 비워라/);
  assert.match(prompt, /유형 05 자연수의 개수/);
});

test('고쟁이 해설 프롬프트는 기대 번호가 하나뿐일 때도 요약 상자를 막는다', () => {
  const prompt = buildDetectSolutionRefsPrompt({
    rawPage: 153,
    displayPage: 153,
    expectedNumbers: ['21'],
    expectedEntries: [
      { number: '21', corner: '중단원 TEST', title: '삼각형의 무게중심', page: 193 },
    ],
    series: 'gojaengi',
  });
  assert.match(prompt, /기대 번호가 \*\*하나뿐이어도\*\*/);
  assert.match(prompt, /content_region 을 반드시 채워라/);
});

test('고쟁이 해설 정규화는 세트형으로 펼친 같은 좌표를 격자로 보지 않는다', () => {
  const parsed = {
    items: [
      {
        problem_number: '106~108',
        number_region: [300, 40, 320, 110],
        content_region: [300, 40, 600, 470],
      },
    ],
  };
  const out = normalizeSolutionRefsResult(parsed, {
    expectedNumbers: ['106', '107', '108'],
    series: 'gojaengi',
  });
  assert.deepEqual(
    out.items.map((i) => i.problem_number),
    ['106~108', '106', '107', '108'],
  );
});
