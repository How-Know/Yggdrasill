import test from 'node:test';
import assert from 'node:assert/strict';

import { normalizeDetectResult } from '../src/textbook/vlm_detect_client.js';
import {
  buildDetectProblemsPrompt,
  buildRpmSetHeaderPrompt,
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
