#!/usr/bin/env node
// 단위 테스트: [공백:N] 마커 파싱/분해 + 렌더러 스모크.
//
// 1) parseSpaceMarkerAmount/splitBySpaceMarkers 기본 동작 확인.
// 2) XeLaTeX smartTexLine 으로 `[공백:N]` 이 `\hspace*{Nem}` 로 변환되는지.
// 3) HTML renderInlineMixedContent 로 `[공백:N]` 이 inline-block span 으로 변환되는지.

import assert from 'node:assert/strict';
import {
  parseSpaceMarkerAmount,
  splitBySpaceMarkers,
} from '../src/problem_bank/render_engine/utils/text.js';
import { renderInlineMixedContent } from '../src/problem_bank/render_engine/html/render_inline.js';

let pass = 0;
let fail = 0;
function t(name, fn) {
  try {
    fn();
    console.log(`  ok   ${name}`);
    pass += 1;
  } catch (err) {
    console.error(`  FAIL ${name}`);
    console.error(err?.stack || err);
    fail += 1;
  }
}

console.log('[parseSpaceMarkerAmount]');
t('정상 정수 → 그대로', () => assert.equal(parseSpaceMarkerAmount('3'), 3));
t('정상 소수 → 그대로', () => assert.equal(parseSpaceMarkerAmount('1.5'), 1.5));
t('소수 셋째자리 → 둘째자리 반올림', () =>
  assert.equal(parseSpaceMarkerAmount('1.234'), 1.23));
t('빈/비숫자 → 기본 1em', () => {
  assert.equal(parseSpaceMarkerAmount(''), 1);
  assert.equal(parseSpaceMarkerAmount('abc'), 1);
  assert.equal(parseSpaceMarkerAmount(undefined), 1);
});
t('0 / 음수 → 기본 1em', () => {
  assert.equal(parseSpaceMarkerAmount('0'), 1);
  assert.equal(parseSpaceMarkerAmount('-2'), 1);
});
t('하한 clamp (< 0.1)', () => assert.equal(parseSpaceMarkerAmount('0.01'), 0.1));
t('상한 clamp (> 20)', () => assert.equal(parseSpaceMarkerAmount('50'), 20));

console.log('\n[splitBySpaceMarkers]');
t('마커 없는 일반 텍스트 → 단일 text 조각', () => {
  const r = splitBySpaceMarkers('abc 123');
  assert.equal(r.length, 1);
  assert.deepEqual(r[0], { type: 'text', value: 'abc 123' });
});
t('중간 단일 마커', () => {
  const r = splitBySpaceMarkers('A[공백:3]B');
  assert.equal(r.length, 3);
  assert.deepEqual(r[0], { type: 'text', value: 'A' });
  assert.deepEqual(r[1], { type: 'space', amount: 3 });
  assert.deepEqual(r[2], { type: 'text', value: 'B' });
});
t('선두 마커', () => {
  const r = splitBySpaceMarkers('[공백:2]X');
  assert.equal(r.length, 2);
  assert.deepEqual(r[0], { type: 'space', amount: 2 });
  assert.deepEqual(r[1], { type: 'text', value: 'X' });
});
t('말미 마커', () => {
  const r = splitBySpaceMarkers('X[공백:2]');
  assert.equal(r.length, 2);
  assert.deepEqual(r[0], { type: 'text', value: 'X' });
  assert.deepEqual(r[1], { type: 'space', amount: 2 });
});
t('연속 마커', () => {
  const r = splitBySpaceMarkers('A[공백:1][공백:2]B');
  assert.equal(r.length, 4);
  assert.deepEqual(r.map((p) => p.type), ['text', 'space', 'space', 'text']);
  assert.equal(r[1].amount, 1);
  assert.equal(r[2].amount, 2);
});
t('속성 없는 [공백] 은 매치되지 않고 원문 유지', () => {
  const r = splitBySpaceMarkers('A[공백]B');
  assert.equal(r.length, 1);
  assert.equal(r[0].value, 'A[공백]B');
});
t('소수 amount', () => {
  const r = splitBySpaceMarkers('A[공백:1.5]B');
  assert.equal(r[1].amount, 1.5);
});

console.log('\n[XeLaTeX smartTexLine 동적 import 스모크]');
// smartTexLine 은 module-private. buildTexSource 를 통해 간접 검증.
const { buildTexSource } = await import(
  '../src/problem_bank/render_engine/xelatex/template.js'
);

function toSource(q) {
  const result = buildTexSource(q, {});
  return typeof result === 'string' ? result : result?.source || '';
}

t('stem 에 [공백:3] 가 있으면 \\hspace*{3em} 이 등장', () => {
  const question = {
    id: 'q-space-1',
    question_number: 1,
    stem: '가 [공백:3]나',
    choices: [],
    equations: [],
    meta: {},
  };
  const source = toSource(question);
  assert.ok(
    source.includes('\\hspace*{3em}'),
    `expected \\hspace*{3em} in TeX source, got:\n${source.slice(0, 800)}`,
  );
  assert.ok(!source.includes('[공백:3]'), '원본 마커가 남아있음');
});

t('소수 amount (1.5) 도 그대로 전달', () => {
  const question = {
    id: 'q-space-2',
    question_number: 1,
    stem: '가[공백:1.5]나',
    choices: [],
    equations: [],
    meta: {},
  };
  const source = toSource(question);
  assert.ok(source.includes('\\hspace*{1.5em}'));
});

t('다중 마커 모두 반영', () => {
  const question = {
    id: 'q-space-3',
    question_number: 1,
    stem: 'A[공백:2]B[공백:4]C',
    choices: [],
    equations: [],
    meta: {},
  };
  const source = toSource(question);
  assert.ok(source.includes('\\hspace*{2em}'));
  assert.ok(source.includes('\\hspace*{4em}'));
});

t('과도값은 20em 으로 clamp', () => {
  const question = {
    id: 'q-space-4',
    question_number: 1,
    stem: 'A[공백:100]B',
    choices: [],
    equations: [],
    meta: {},
  };
  const source = toSource(question);
  assert.ok(source.includes('\\hspace*{20em}'));
  assert.ok(!source.includes('\\hspace*{100em}'));
});

t('선택지(choice) 안의 공백 마커도 동작', () => {
  const question = {
    id: 'q-space-5',
    question_number: 1,
    stem: '질문',
    choices: ['①[공백:2]답'],
    equations: [],
    meta: {},
  };
  const source = toSource(question);
  assert.ok(source.includes('\\hspace*{2em}'));
});

console.log('\n[HTML renderInlineMixedContent 스모크]');
const dummyRenderer = {
  renderInline() {
    return { ok: false };
  },
};

t('텍스트 안의 [공백:3] → inline-block span 3em', () => {
  const r = renderInlineMixedContent('가 [공백:3]나', dummyRenderer, []);
  assert.ok(
    /<span class="stem-space"[^>]*width:3em/.test(r.html),
    `expected stem-space span, got: ${r.html}`,
  );
  assert.ok(!r.html.includes('[공백:3]'), '원본 마커가 HTML 에 남아있음');
});

t('HTML 다중 마커', () => {
  const r = renderInlineMixedContent('A[공백:1]B[공백:2.5]C', dummyRenderer, []);
  const matches = r.html.match(/class="stem-space"/g) || [];
  assert.equal(matches.length, 2);
  assert.ok(r.html.includes('width:1em'));
  assert.ok(r.html.includes('width:2.5em'));
});

t('마커 없는 일반 텍스트는 stem-space 없음', () => {
  const r = renderInlineMixedContent('평범한 본문', dummyRenderer, []);
  assert.ok(!r.html.includes('stem-space'));
});

t('마커만 있는 줄', () => {
  const r = renderInlineMixedContent('[공백:4]', dummyRenderer, []);
  assert.ok(/<span class="stem-space"[^>]*width:4em/.test(r.html));
});

console.log(`\n결과: ${pass} pass, ${fail} fail`);
if (fail > 0) process.exit(1);
