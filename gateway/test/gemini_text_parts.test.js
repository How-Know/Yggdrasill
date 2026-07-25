import assert from 'node:assert/strict';
import test from 'node:test';

import { joinGeminiTextParts } from '../src/problem_bank/extract_engines/vlm/client.js';

test('조각 경계가 JSON 문자열 안에 떨어져도 깨지지 않는다', () => {
  // Gemini 가 응답을 여러 part 로 쪼갤 때 경계는 아무 곳에나 생긴다.
  // '\n' 으로 이어 붙이면 문자열 리터럴 안에 생 줄바꿈이 박혀 파싱이 깨졌다.
  const parts = [
    { text: '{"questions":[{"body":"다음 함' },
    { text: '수의 도함수를 구하시오."}]}' },
  ];
  const joined = joinGeminiTextParts(parts);
  const parsed = JSON.parse(joined);
  assert.equal(parsed.questions[0].body, '다음 함수의 도함수를 구하시오.');
});

test('추론(thought) 조각은 본문에서 제외한다', () => {
  const parts = [
    { text: '먼저 페이지를 살펴보면...', thought: true },
    { text: '{"ok":true}' },
  ];
  assert.equal(joinGeminiTextParts(parts), '{"ok":true}');
});

test('앞뒤 공백은 다듬고, 빈 입력은 빈 문자열이다', () => {
  assert.equal(joinGeminiTextParts([{ text: '  {"a":1}  ' }]), '{"a":1}');
  assert.equal(joinGeminiTextParts([]), '');
  assert.equal(joinGeminiTextParts(null), '');
  assert.equal(joinGeminiTextParts(undefined), '');
});

test('text 가 없는 조각은 건너뛴다', () => {
  const parts = [{ inlineData: { data: 'x' } }, { text: '{"a":' }, {}, { text: '1}' }];
  assert.equal(joinGeminiTextParts(parts), '{"a":1}');
});
