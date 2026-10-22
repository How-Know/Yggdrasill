// 고쟁이 고등 시리즈 회귀 테스트.
//
// 중등 고쟁이와 번호 체계(책 전체 세 자리 연속)는 같고, 단계가 STEP1~3 셋뿐이며
// 라벨이 별표 대신 출제 안내 배지(빈출·서술형·선생님 Pick·기출/변형)다.
// 중등 전용 코너(창의융합·워크북)와 중등 라벨이 섞여 들어오지 않는지 고정한다.

import { strict as assert } from 'node:assert';
import { test } from 'node:test';

import { buildDetectProblemsPrompt } from '../src/textbook/vlm_detect_prompt.js';
import { normalizeDetectResult } from '../src/textbook/vlm_detect_client.js';
import {
  buildProblemBookSectionPrompt,
  normalizeRpmSectionResult,
  problemBookSectionParts,
} from '../src/textbook/vlm_rpm_section_client.js';
import { buildParseTocPrompt } from '../src/textbook/vlm_toc_client.js';
import { buildPrompt } from '../src/problem_bank/extract_engines/vlm/prompt.js';

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

test('고등 탐지 프롬프트는 STEP 셋과 고등 배지만 싣는다', () => {
  const prompt = buildDetectProblemsPrompt({
    rawPage: 8,
    displayPage: 8,
    series: 'gojaengi_high',
    sectionHint: 'core_type',
  });
  assert.match(prompt, /고쟁이 고등/);
  assert.match(prompt, /section="core_type"/);
  assert.match(prompt, /초록 머리말/);
  assert.match(prompt, /유형 02/);
  // 선행 안내 띠의 세 자리 번호가 문항으로 새지 않게.
  assert.match(prompt, /선행 025/);
  assert.match(prompt, /빈출\+서술형/);
  assert.match(prompt, /선생님 Pick\+교육청변형/);
  // 중등 전용 코너·라벨은 고등 프롬프트에 없다.
  assert.doesNotMatch(prompt, /mid_unit_test/);
  assert.doesNotMatch(prompt, /대표 문제/);
  assert.doesNotMatch(prompt, /핵심 03/);
});

test('고등 STEP3 프롬프트는 유형 머리말이 없다고 못 박는다', () => {
  const prompt = buildDetectProblemsPrompt({
    rawPage: 15,
    displayPage: 15,
    series: 'gojaengi_high',
    sectionHint: 'top_type',
  });
  assert.match(prompt, /남색/);
  assert.match(prompt, /유형 머리말이 \*\*아예 없다\*\*/);
});

test('중등 고쟁이 프롬프트는 그대로 중등 구조를 유지한다', () => {
  const prompt = buildDetectProblemsPrompt({
    rawPage: 21,
    displayPage: 21,
    series: 'gojaengi',
    sectionHint: 'core_type',
  });
  assert.match(prompt, /핵심 03/);
  assert.match(prompt, /mid_unit_test/);
  assert.doesNotMatch(prompt, /선행 025/);
});

test('고등 라벨은 배지 조합을 고정 순서로 맞추고 중등 라벨은 버린다', () => {
  const labels = [
    '빈출',
    '서술형 빈출',
    '교육청 변형, 선생님 Pick!',
    '평가원 기출',
    '상',
    '대표 문제',
    '선행 025',
  ];
  const result = normalizeDetectResult(
    {
      section: 'core_type',
      page_kind: 'problem_page',
      page_layout: 'two_column',
      items: labels.map((label, index) =>
        bodyItem(String(index + 1).padStart(3, '0'), index, { label }),
      ),
      notes: '',
    },
    { series: 'gojaengi_high', sectionHint: 'core_type' },
  );
  assert.deepEqual(
    result.items.map((item) => item.label),
    ['빈출', '빈출+서술형', '선생님 Pick+교육청변형', '평가원기출', '', '', ''],
  );
  assert.deepEqual(
    result.items.map((item) => item.number),
    ['001', '002', '003', '004', '005', '006', '007'],
  );
});

test('고등 본문 세 자리 연속 번호는 concept_page 표기에도 살아남는다', () => {
  const result = normalizeDetectResult(
    {
      section: 'advanced_type',
      page_kind: 'concept_page',
      page_layout: 'two_column',
      items: ['104', '105', '106'].map((number, index) =>
        bodyItem(number, index),
      ),
      notes: 'concept_page',
    },
    { series: 'gojaengi_high', sectionHint: 'advanced_type' },
  );
  assert.deepEqual(
    result.items.map((item) => item.number),
    ['104', '105', '106'],
  );
  assert.equal(result.page_kind, 'problem_page');
});

test('고등 STEP2 문항은 유형 머리말을 갖고 STEP3 문항은 갖지 않는다', () => {
  const group = { kind: 'type', label: '유형 02', title: '곱셈 공식', order: 2 };
  const advanced = normalizeDetectResult(
    {
      section: 'advanced_type',
      page_kind: 'problem_page',
      items: [bodyItem('110', 0, { content_group: group })],
    },
    { series: 'gojaengi_high', sectionHint: 'advanced_type' },
  );
  assert.equal(advanced.items[0].content_group.label, '유형 02');
  const top = normalizeDetectResult(
    {
      section: 'top_type',
      page_kind: 'problem_page',
      items: [bodyItem('140', 0, { content_group: group })],
    },
    { series: 'gojaengi_high', sectionHint: 'top_type' },
  );
  assert.equal(top.items[0].content_group.kind, 'none');
});

test('고등 단계 분류는 STEP 셋만 쓴다', () => {
  assert.deepEqual(
    problemBookSectionParts('gojaengi_high').map((part) => part.code),
    ['core_type', 'advanced_type', 'top_type'],
  );
});

test('고등 단계 분류는 책 끝 빠른 정답 지면을 따로 짚는다', () => {
  const prompt = buildProblemBookSectionPrompt([233], 'gojaengi_high');
  assert.match(prompt, /"answer_key"/);
  const out = normalizeRpmSectionResult(
    { pages: [{ image_index: 0, section: 'answer_key' }] },
    [233],
    'gojaengi_high',
  );
  assert.equal(out.pages[0].section, 'answer_key');
  // 다른 시리즈는 이 코드를 받지 않는다.
  assert.doesNotMatch(buildProblemBookSectionPrompt([233], 'ssen'), /answer_key/);
  const ssen = normalizeRpmSectionResult(
    { pages: [{ image_index: 0, section: 'answer_key' }] },
    [233],
    'ssen',
  );
  assert.equal(ssen.pages[0].section, 'unknown');
});

test('고등 목차 프롬프트는 고쟁이 목차 규칙을 그대로 받는다', () => {
  const prompt = buildParseTocPrompt({ pageCount: 1, series: 'gojaengi_high' });
  assert.match(prompt, /고쟁이 교재 목차 규칙/);
  assert.match(prompt, /고등용에는 워크북이 없다/);
});

test('고등 문제은행 추출 프롬프트는 배지·선행 안내를 지문에서 뺀다', () => {
  const prompt = buildPrompt({
    textbookScope: { series: 'gojaengi_high', sub_key: 'A' },
  });
  assert.match(prompt, /고쟁이 고등 교재 전용 규칙/);
  assert.match(prompt, /선행 025/);
  assert.doesNotMatch(prompt, /=== 고쟁이 교재 전용 규칙 ===/);
});
