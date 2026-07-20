import test from 'node:test';
import assert from 'node:assert/strict';

import { normalizeDetectResult } from '../src/textbook/vlm_detect_client.js';
import {
  buildDetectProblemsPrompt,
  buildRpmSetHeaderPrompt,
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
