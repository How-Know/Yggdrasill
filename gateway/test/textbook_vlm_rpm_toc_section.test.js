import test from 'node:test';
import assert from 'node:assert/strict';

import {
  buildParseTocPrompt,
  normalizeTocResult,
} from '../src/textbook/vlm_toc_client.js';
import {
  buildRpmSectionPrompt,
  buildSsenSectionPrompt,
  extractBalancedJsonObject,
  normalizeRpmSectionResult,
  parseRpmSectionModelJson,
} from '../src/textbook/vlm_rpm_section_client.js';

test('RPM TOC prompt keeps fixed parts out of the unit tree', () => {
  const prompt = buildParseTocPrompt({ pageCount: 1, series: 'rpm' });
  assert.match(prompt, /mid_units\[\]\.page/);
  assert.match(prompt, /sub_units는 반드시 \[\]/);
  assert.match(prompt, /appendix_boundary_page/);
  assert.match(prompt, /부록 대표문제 다시 풀기/);
});

test('RPM TOC normalization preserves middle and appendix pages', () => {
  const result = normalizeTocResult({
    big_units: [
      {
        name: 'I. 소인수분해',
        mid_units: [
          { name: '01 소인수분해', page: '8', sub_units: [] },
          { name: '02 최대공약수와 최소공배수', page: 18, sub_units: [] },
        ],
      },
    ],
    appendix_boundary_page: '156',
  });

  assert.equal(result.big_units[0].mid_units[0].page, 8);
  assert.equal(result.big_units[0].mid_units[1].page, 18);
  assert.equal(result.appendix_boundary_page, 156);
});

test('Ssen TOC prompt extracts numbered rows as middle-unit pages', () => {
  const prompt = buildParseTocPrompt({ pageCount: 1, series: 'ssen' });
  assert.match(prompt, /mid_units\[\]\.page/);
  assert.match(prompt, /A 기본다잡기/);
  assert.match(prompt, /B 유형뽀개기/);
  assert.match(prompt, /C 만점도전하기/);
  assert.match(prompt, /sub_units는 반드시 \[\]/);
});

test('RPM section prompt describes monotonic A to B to C flow', () => {
  const prompt = buildRpmSectionPrompt([10, 11, 12]);
  assert.match(prompt, /0:10, 1:11, 2:12/);
  assert.match(prompt, /유형 익히기/);
  assert.match(prompt, /시험에 꼭 나오는 문제/);
  assert.match(prompt, /뒤로 되돌아가지 않는다/);
});

test('Ssen section prompt uses Ssen-specific part headers', () => {
  const prompt = buildSsenSectionPrompt([8, 9, 10]);
  assert.match(prompt, /쎈의 고정 순서/);
  assert.match(prompt, /기본다잡기/);
  assert.match(prompt, /유형뽀개기/);
  assert.match(prompt, /만점도전하기/);
  assert.doesNotMatch(prompt, /교과서문제 정복하기/);
});

test('RPM section normalization restores omitted pages as unknown', () => {
  const result = normalizeRpmSectionResult(
    {
      pages: [
        {
          image_index: 0,
          raw_page: 999,
          section: 'basic_drill',
          type_practice_header_visible: false,
          mastery_header_visible: false,
        },
        {
          image_index: 2,
          raw_page: 999,
          section: 'mastery',
          type_practice_header_visible: false,
          mastery_header_visible: true,
        },
      ],
    },
    [10, 11, 12],
  );

  assert.deepEqual(
    result.pages.map((page) => [page.raw_page, page.section]),
    [
      [10, 'basic_drill'],
      [11, 'unknown'],
      [12, 'mastery'],
    ],
  );
  assert.equal(result.pages[2].mastery_header_visible, true);
});

test('RPM section parser extracts valid JSON before trailing model junk', () => {
  const malformed =
    '{"pages":[{"image_index":0,"raw_page":10,"section":"basic_drill",' +
    '"type_practice_header_visible":false,"mastery_header_visible":false}],' +
    '"notes":""} }"';
  const balanced = extractBalancedJsonObject(malformed);
  assert.ok(balanced);
  assert.equal(JSON.parse(balanced).pages[0].section, 'basic_drill');
});

test('RPM section parser recovers completed pages from a truncated response', () => {
  const truncated =
    '{"pages":[{"image_index":0,"raw_page":10,"section":"basic_drill",' +
    '"type_practice_header_visible":false,"mastery_header_visible":false},' +
    '{"image_index":1,"raw_page":11,"section":"type_practice",' +
    '"type_practice_header_visible":true,"mastery_header_visible":false},';
  const parsed = parseRpmSectionModelJson(truncated);
  assert.ok(parsed);
  assert.equal(parsed.pages.length, 2);
  assert.equal(parsed.pages[1].type_practice_header_visible, true);
});
