import test from 'node:test';
import assert from 'node:assert/strict';

import {
  mergeItemGeometry,
  normalizeDetectResult,
  shouldTreatWonriPageAsConcept,
} from '../src/textbook/vlm_detect_client.js';
import {
  buildDetectProblemsPrompt,
  buildItemGeometryRepairPrompt,
  buildRpmSetHeaderPrompt,
  buildSsenBasicDrillRescuePrompt,
  buildWonriPageClassPrompt,
} from '../src/textbook/vlm_detect_prompt.js';

test('RPM A prompt describes alternating concept and problem pages', () => {
  const prompt = buildDetectProblemsPrompt({
    rawPage: 23,
    displayPage: 23,
    pageOffset: 0,
    series: 'rpm',
    sectionHint: 'basic_drill',
  });
  assert.match(prompt, /개념 설명 1페이지 → 교과서문제 정복하기 문제 1페이지/);
  assert.match(prompt, /개념 페이지만 두 페이지 연속으로 나오지 않는다/);
  assert.match(prompt, /세로형·독립형 세트/);
});

test('ssen A rescue prompt forces visible four-digit items to problem page', () => {
  const prompt = buildSsenBasicDrillRescuePrompt({
    rawPage: 87,
    displayPage: 87,
  });
  assert.match(prompt, /4자리 문항번호/);
  assert.match(prompt, /반드시 problem_page/);
  assert.match(prompt, /is_set_header=true/);
  assert.match(prompt, /label은 항상 ""/);
});

test('ssen B drops the 유형 badge number that leaked in as an item', () => {
  const items = ['0308', '0309', '0310', '0311', '0312', '0313', '10'].map(
    (number, index) => ({
      number,
      label: '',
      is_set_header: false,
      column: 1,
      bbox: [80 + index * 100, 50, 100 + index * 100, 110],
      item_region: [100 + index * 100, 40, 170 + index * 100, 460],
      content_group: {
        kind: 'type',
        label: '유형 10',
        title: '평행선에서의 활용 (2)',
        order: 10,
      },
    }),
  );
  const result = normalizeDetectResult(
    {
      section: 'type_practice',
      page_kind: 'problem_page',
      page_layout: 'two_column',
      items,
      notes: '',
    },
    { series: 'ssen', sectionHint: 'type_practice' },
  );

  assert.deepEqual(
    result.items.map((item) => item.number),
    ['0308', '0309', '0310', '0311', '0312', '0313'],
  );
  assert.match(result.notes, /type_practice_candidate_filtered=1/);
});

test('ssen B keeps plain numbering when the page never uses four digits', () => {
  const result = normalizeDetectResult(
    {
      section: 'type_practice',
      page_kind: 'problem_page',
      page_layout: 'two_column',
      items: ['12', '13', '14'].map((number, index) => ({
        number,
        label: '중',
        is_set_header: false,
        column: 1,
        bbox: [80 + index * 100, 50, 100 + index * 100, 110],
        item_region: [100 + index * 100, 40, 170 + index * 100, 460],
        content_group: {
          kind: 'type',
          label: '유형 07',
          title: '평행선',
          order: 7,
        },
      })),
      notes: '',
    },
    { series: 'ssen', sectionHint: 'type_practice' },
  );

  assert.deepEqual(
    result.items.map((item) => item.number),
    ['12', '13', '14'],
  );
});

test('RPM set-header prompt targets green bracketed ranges', () => {
  const prompt = buildRpmSetHeaderPrompt({ rawPage: 23, displayPage: 23 });
  assert.match(prompt, /\[0113~0116\]/);
  assert.match(prompt, /일반 개별 문항은 추출하지 말고/);
  assert.match(prompt, /공통 지문과 그 지문에 딸린 공통 그림/);
  assert.match(prompt, /질문 한 줄만 감싸고 아래 보기 상자를 빼면 실패/);
  assert.match(prompt, /"0009"/);
});

test('wonri page classifier separates concept, drill, and type pages', () => {
  const prompt = buildWonriPageClassPrompt({
    rawPage: 67,
    displayPage: 67,
  });
  assert.match(prompt, /"concept" — 페이지 왼쪽 상단에 "개념원리 이해"/);
  assert.match(prompt, /"필수 01", "필수 04" 같은 작은 라벨/);
  assert.match(prompt, /참조 표시일 뿐이다/);
  assert.match(prompt, /"concept_drill" — 왼쪽 상단에 "개념원리 익히기"/);
  assert.match(prompt, /"type_example" — 왼쪽에 "필수 NN" 배지와 유형명/);
  assert.match(prompt, /하단에 "확인 체크" 문항이 최소 1개/);
  assert.match(prompt, /"개념원리 이해"가 보이면 다른 요소와 무관하게 "concept"/);
  assert.match(prompt, /"확인하기"는 학습 내용을 확인하는 개념 예제명/);
  assert.match(prompt, /"확인하기"를 "확인 체크"의 표기 변형으로 해석하는 것은 절대 금지/);
});

test('wonri 확인하기 concept example is never treated as 확인 체크', () => {
  const detectPrompt = buildDetectProblemsPrompt({
    rawPage: 109,
    displayPage: 109,
    pageOffset: 0,
    series: 'wonri',
    sectionHint: 'concept_drill',
  });
  assert.match(detectPrompt, /개념 예제 제목 "확인하기"/);
  assert.match(detectPrompt, /"확인하기"라는 예제 제목은 모양이 비슷해도 확인 체크가 아니며/);
  assert.equal(shouldTreatWonriPageAsConcept('other', '확인하기'), true);
  assert.equal(shouldTreatWonriPageAsConcept('concept', ''), true);
  assert.equal(shouldTreatWonriPageAsConcept('type_example', '확인 체크'), false);
  assert.equal(shouldTreatWonriPageAsConcept('other', '확인체크'), false);
});

test('normalizeDetectResult accepts single-wrapped bbox arrays', () => {
  const result = normalizeDetectResult({
    section: 'type_practice',
    page_kind: 'problem_page',
    page_layout: 'two_column',
    items: [
      {
        number: '0168',
        label: '중',
        is_set_header: false,
        set_range: null,
        content_group: { kind: 'none', label: '', title: '', order: null },
        column: 1,
        bbox: [[79, 58, 93, 128]],
        item_region: [[102, 58, 220, 418]],
      },
    ],
    notes: '',
  });

  assert.equal(result.items.length, 1);
  assert.deepEqual(result.items[0].bbox, [79, 58, 93, 128]);
  assert.deepEqual(result.items[0].item_region, [102, 58, 220, 418]);
});

test('wonri special-lecture concept numbers (1-digit, no badge number) are dropped', () => {
  // 특강 "개념 페이지"의 사각 박스 개념 번호(예: 1)를 모델이 특강 예제로
  // 오인한 경우 — 진짜 특강 예제는 배지에 "특강 01" 처럼 2자리 번호가 있다.
  const result = normalizeDetectResult(
    {
      section: 'type_example',
      page_kind: 'problem_page',
      page_layout: 'one_column',
      items: [
        {
          number: '1',
          category: 'special_lecture',
          label: '특강',
          content_group: { kind: 'type', label: '특강 1', title: 'ax^4+bx^3+cx^2+bx+a=0의 꼴의 방정식의 풀이', order: 1 },
          bbox: [140, 60, 170, 90],
          item_region: [140, 60, 900, 940],
        },
      ],
      notes: '',
    },
    { series: 'wonri' },
  );

  assert.equal(result.items.length, 0);
  assert.equal(result.page_kind, 'concept_page');
  assert.match(result.notes, /wonri_lecture_concept_numbers_dropped=1/);
});

test('wonri special-lecture items are recategorized, not merged into type_example', () => {
  const result = normalizeDetectResult(
    {
      section: 'type_example',
      page_kind: 'problem_page',
      page_layout: 'one_column',
      items: [
        {
          // 모델이 type_example 로 잘못 분류해도 "특강" 배지로 교정되어야 한다
          // (번호가 01부터 새로 시작해 필수유형과 unique key 충돌 위험).
          number: '01',
          category: 'type_example',
          label: '특강',
          content_group: { kind: 'type', label: '특강 01', title: '이차함수의 그래프의 꼭짓점', order: 1 },
          bbox: [80, 60, 110, 140],
          item_region: [115, 60, 380, 900],
        },
        {
          number: '275',
          category: 'check',
          label: '',
          content_group: { kind: 'none', label: '', title: '', order: null },
          bbox: [800, 60, 830, 120],
          item_region: [835, 60, 900, 900],
        },
      ],
      notes: '',
    },
    { series: 'wonri' },
  );

  assert.equal(result.items.length, 2);
  const lecture = result.items.find((i) => i.number === '01');
  assert.equal(lecture.category, 'special_lecture');
  assert.equal(lecture.content_group.kind, 'type');
  assert.equal(lecture.content_group.title, '이차함수의 그래프의 꼭짓점');
  const check = result.items.find((i) => i.number === '275');
  assert.equal(check.category, 'check');
});

test('normalizeDetectResult backfills missing item regions for vertical textbook pages', () => {
  const result = normalizeDetectResult({
    section: 'type_practice',
    page_kind: 'problem_page',
    page_layout: 'two_column',
    items: [
      {
        number: '0168',
        label: '중',
        content_group: { kind: 'none', label: '', title: '', order: null },
        column: 1,
        bbox: [79, 58, 93, 128],
      },
      {
        number: '0169',
        label: '상',
        content_group: { kind: 'none', label: '', title: '', order: null },
        column: 1,
        bbox: [382, 58, 396, 186],
      },
      {
        number: '0171',
        label: '하',
        content_group: { kind: 'none', label: '', title: '', order: null },
        column: 2,
        bbox: [79, 503, 93, 573],
      },
    ],
    notes: '',
  });

  assert.deepEqual(result.items[0].item_region, [100, 56, 374, 495]);
  assert.deepEqual(result.items[1].item_region, [403, 56, 980, 495]);
  assert.deepEqual(result.items[2].item_region, [100, 501, 980, 904]);
});

test('normalizeDetectResult preserves independent RPM A-set headers and members', () => {
  const payload = {
    section: 'basic_drill',
    page_kind: 'problem_page',
    page_layout: 'one_column',
    items: [
      {
        number: '10~12',
        label: '중요',
        is_set_header: true,
        set_range: { from: 10, to: 12 },
        column: 1,
        bbox: [100, 50, 122, 165],
        item_region: [130, 45, 720, 940],
      },
      {
        number: '0010',
        label: '',
        is_set_header: false,
        column: 1,
        bbox: [180, 70, 202, 130],
        item_region: [210, 40, 700, 940],
      },
      {
        number: '0099',
        label: '',
        is_set_header: false,
        column: 1,
        bbox: [740, 70, 762, 130],
        item_region: [100, 500, 100, 940],
      },
      {
        number: '0013',
        label: '',
        is_set_header: false,
        column: 1,
        bbox: [740, 70, 762, 130],
        item_region: [300, 40, 760, 940],
      },
    ],
    notes: '',
  };
  const result = normalizeDetectResult(payload, { series: 'rpm' });

  assert.deepEqual(
    result.items.map((item) => item.number),
    ['10~12', '0010', '0013'],
  );
  assert.match(result.notes, /basic_drill_candidate_filtered=1/);

  const ssenResult = normalizeDetectResult(payload, { series: 'ssen' });
  assert.deepEqual(ssenResult.items, []);
  assert.match(ssenResult.notes, /basic_drill_candidate_filtered=4/);
});

test('ssen A keeps flexible item geometry when sequential page evidence is strong', () => {
  const result = normalizeDetectResult({
    section: 'basic_drill',
    page_kind: 'problem_page',
    page_layout: 'two_column',
    items: ['0131', '0132', '0133'].map((number, index) => ({
      number,
      label: '',
      is_set_header: false,
      column: 1,
      bbox: [100 + index * 180, 50, 122 + index * 180, 105],
      item_region: [80 + index * 180, 40, 530 + index * 180, 460],
    })),
    notes: '',
  }, { series: 'ssen' });

  assert.deepEqual(
    result.items.map((item) => item.number),
    ['0131', '0132', '0133'],
  );
  assert.equal(result.page_kind, 'problem_page');
});

test('ssen A keeps valid sequential items when model contradicts them with concept_page', () => {
  const result = normalizeDetectResult({
    section: 'basic_drill',
    page_kind: 'concept_page',
    page_layout: 'two_column',
    items: ['1247', '1248', '1249'].map((number, index) => ({
      number,
      // A단계에 존재하지 않는 라벨을 모델이 잘못 붙여도 제거해야 한다.
      label: '대표 문제',
      is_set_header: false,
      column: index < 2 ? 1 : 2,
      // 실제 실패 응답처럼 좌표가 한 번 더 감싸져 있어도 번호 증거로
      // concept_page 조기 반환을 먼저 풀고, 정규화 단계에서 좌표를 복구한다.
      bbox: [[100 + index * 180, 50, 122 + index * 180, 105]],
      item_region: [[80 + index * 180, 40, 530 + index * 180, 460]],
    })),
    notes: 'concept_page',
  }, { series: 'ssen', sectionHint: 'basic_drill' });

  assert.deepEqual(
    result.items.map((item) => item.number),
    ['1247', '1248', '1249'],
  );
  assert.equal(result.page_kind, 'problem_page');
  assert.match(result.notes, /concept_page_overridden_by_valid_basic_numbers/);
});

test('ssen A still rejects a lone flexible-geometry false positive', () => {
  const result = normalizeDetectResult({
    section: 'basic_drill',
    page_kind: 'problem_page',
    page_layout: 'two_column',
    items: [{
      number: '0132',
      label: '',
      is_set_header: false,
      column: 1,
      bbox: [100, 50, 122, 105],
      item_region: [80, 40, 530, 460],
    }],
    notes: '',
  }, { series: 'ssen' });

  assert.deepEqual(result.items, []);
  assert.equal(result.page_kind, 'concept_page');
});

test('item geometry repair fills coordinates the first pass omitted', () => {
  const prompt = buildItemGeometryRepairPrompt({
    rawPage: 152,
    displayPage: 152,
    numbers: ['예제1', '유제1'],
  });
  assert.match(prompt, /"예제1", "유제1"/);
  assert.match(prompt, /풀이 과정/);

  const first = {
    notes: '',
    items: [
      { number: '예제1', bbox: null, item_region: null, column: null },
      // 이미 좌표가 있는 문항은 덮어쓰지 않는다.
      {
        number: '유제1',
        bbox: [125, 500, 169, 553],
        item_region: [125, 553, 182, 905],
        column: 2,
      },
    ],
  };
  const filled = mergeItemGeometry(first, {
    items: [
      {
        number: '예제 1',
        column: 1,
        bbox: [125, 77, 169, 134],
        item_region: [125, 134, 182, 483],
      },
      { number: '유제 1', column: 2, bbox: [0, 0, 1, 1], item_region: [0, 0, 1, 1] },
    ],
  });

  assert.equal(filled, 1);
  assert.deepEqual(first.items[0].item_region, [125, 134, 182, 483]);
  assert.equal(first.items[0].column, 1);
  assert.deepEqual(first.items[1].item_region, [125, 553, 182, 905]);
  assert.match(first.notes, /item_geometry_repaired=1/);
});

test('gaeyu keeps a numberless 개념확인 even when badge fields are missing', () => {
  // 배지 칸을 통째로 빠뜨린 응답까지 버리면 그 지면의 개념확인이 흔적 없이
  // 사라진다(2-2 102쪽). "참고" 처럼 다른 배지를 읽은 경우에만 버린다.
  const base = {
    section: 'essential_problem',
    page_kind: 'mixed',
    page_layout: 'one_column',
    notes: '',
  };
  const kept = normalizeDetectResult(
    {
      ...base,
      items: [
        {
          number: '',
          category: 'concept_check',
          label: '',
          bbox: [244, 102, 279, 160],
          item_region: [266, 175, 523, 649],
        },
      ],
    },
    { series: 'gaeyu', rawPage: 102, displayPage: 102 },
  );
  assert.deepEqual(
    kept.items.map((item) => [item.number, item.category]),
    [['개념확인102', 'concept_check']],
  );

  const dropped = normalizeDetectResult(
    {
      ...base,
      items: [
        {
          number: '',
          category: 'concept_check',
          label: '',
          badge_text: '참고',
          badge_style: '',
          bbox: [244, 102, 279, 160],
          item_region: [266, 175, 523, 649],
        },
      ],
    },
    { series: 'gaeyu', rawPage: 102, displayPage: 102 },
  );
  assert.deepEqual(dropped.items, []);
});

test('gaeyu strips difficulty labels from corners that never print them', () => {
  const result = normalizeDetectResult(
    {
      section: 'step_drill',
      page_kind: 'problem_page',
      page_layout: 'one_column',
      items: [
        {
          number: '5',
          category: 'step_drill',
          label: '중',
          is_important: true,
          bbox: [100, 50, 122, 105],
          item_region: [100, 110, 250, 900],
        },
        {
          number: '1',
          category: 'unit_drill',
          label: '상',
          is_important: true,
          bbox: [300, 50, 322, 105],
          item_region: [300, 110, 450, 900],
        },
      ],
      notes: '',
    },
    { series: 'gaeyu', rawPage: 109, displayPage: 109 },
  );

  const step = result.items.find((item) => item.category === 'step_drill');
  assert.equal(step.label, '');
  assert.equal(step.is_important, false);
  const unit = result.items.find((item) => item.category === 'unit_drill');
  assert.equal(unit.label, '상');
  assert.equal(unit.is_important, true);
  assert.match(result.notes, /gaeyu_labels_stripped=1/);
});
