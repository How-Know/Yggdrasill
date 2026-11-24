import test from 'node:test';
import assert from 'node:assert/strict';

import {
  answerValue,
  matchLegacySameQuestions,
  normalizeForMatch,
  textSimilarity,
} from '../src/mock_exam/legacy_links.js';

const choices = (...texts) => texts.map((text, i) => ({ label: '①②③④⑤'[i], text }));

test('가형·나형 같은 문항: 전사 차이(띄어쓰기·중괄호·[문단])는 같은 글로 본다', () => {
  assert.equal(
    normalizeForMatch('수열 \\{a_n\\}은 [문단] [박스시작] (가) a_{2n}=a_2 \\times a_n+1'),
    normalizeForMatch('수열 \\{a_{n}\\}은 [박스시작] (가) a_{2n}=a_{2}\\times a_{n}+1'),
  );
  assert.equal(textSimilarity('\\left(\\frac{1}{9}\\right)^{x} < 3^{21-4x} 을', '\\left(\\frac{1}{9}\\right)^{x}<3^{21-4x}을'), 1);
  assert.ok(textSimilarity('함수 f(x)=4\\cos x+3 의 최댓값은?', '곡선 y=e^{2x}과 x축으로 둘러싸인 넓이는?') < 0.6);
});

test('가형·나형 같은 문항: 선지 순서가 뒤집혀도 정답 값이 같으면 같은 문항이다', () => {
  const stem = '정규분포 \\text{N}(20, 5^{2})을 따르는 모집단에서 크기가 16인 표본을 임의추출하여 구한 표본평균을 \\overline{X}라 할 때의 값은?';
  const ga = [{
    number: 6, stem, answerKind: 'objective', answerText: '②',
    choices: choices('\\frac{83}{4}', '\\frac{85}{4}', '\\frac{87}{4}', '\\frac{89}{4}', '\\frac{91}{4}'),
  }];
  const na = [{
    number: 11, stem, answerKind: 'objective', answerText: '④',
    choices: choices('\\frac{91}{4}', '\\frac{89}{4}', '\\frac{87}{4}', '\\frac{85}{4}', '\\frac{83}{4}'),
  }];
  assert.equal(answerValue(ga[0]), answerValue(na[0]));
  assert.deepEqual(matchLegacySameQuestions(ga, na), {
    same: [{ naNumber: 11, gaNumber: 6, similarity: 1, formDiffers: false }],
    uncertain: [],
  });
});

test('가형·나형 같은 문항: 객관식·주관식만 다르고 정답 값이 같으면 같은 문항, 묻는 값이 다르면 따로 적는다', () => {
  const setup = '수열 \\{a_n\\}은 0<a_1<1이고, 모든 자연수 n에 대하여 다음 조건을 만족시킨다. (가) a_{2n}=a_2\\times a_n+1 (나) a_{2n+1}=a_2\\times a_n-2 ';
  const table = '세 학생 A, B, C를 포함한 6명의 학생이 있다. 이 6명의 학생이 일정한 간격을 두고 원 모양의 탁자에 다음 조건을 만족시키도록 모두 둘러앉는 경우의 수 (가) A와 B는 이웃한다. (나) B와 C는 이웃하지 않는다. (단, 회전하여 일치하는 것은 같은 것으로 본다.)';
  const ga = [
    { number: 21, stem: `${setup}a_8-a_{15}=63일 때, \\frac{a_8}{a_1}의 값은?`, answerKind: 'objective', answerText: '②', choices: choices('91', '92', '93', '94', '95') },
    { number: 26, stem: `${table}를 구하시오.`, answerKind: 'subjective', answerText: '36', choices: [] },
    { number: 1, stem: '\\sqrt[3]{9}\\times 3^{\\frac{1}{3}}의 값은?', answerKind: 'objective', answerText: '③', choices: choices('1', '2', '3', '4', '5') },
  ];
  const na = [
    { number: 21, stem: `${setup}a_7=2일 때, a_{25}의 값은?`, answerKind: 'objective', answerText: '③', choices: choices('78', '80', '82', '84', '86') },
    { number: 15, stem: `${table}는?`, answerKind: 'objective', answerText: '③', choices: choices('32', '34', '36', '38', '40') },
    { number: 4, stem: '함수 f(x)=4\\cos x+3 의 최댓값은?', answerKind: 'objective', answerText: '②', choices: choices('6', '7', '8', '9', '10') },
  ];
  const result = matchLegacySameQuestions(ga, na);
  assert.deepEqual(result.same.map((s) => [s.naNumber, s.gaNumber, s.formDiffers]), [[15, 26, true]]);
  assert.deepEqual(result.uncertain.map((u) => [u.naNumber, u.gaNumber]), [[21, 21]]);
  assert.ok(result.uncertain[0].reasons.includes('정답 값이 다름'));

  // 같은 상황이라도 주관식 답이 객관식 정답 선지의 값과 다르면(k 와 k^2) 같은 문항이 아니다.
  const circle = '\\angle A=\\frac{\\pi}{3}이고 \\overline{AB}:\\overline{AC}=3:1인 삼각형 ABC의 외접원의 반지름의 길이가 7일 때, 선분 AC의 길이';
  const other = matchLegacySameQuestions(
    [{ number: 10, stem: `${circle}는?`, answerKind: 'objective', answerText: '②', choices: choices('2\\sqrt{5}', '\\sqrt{21}', '\\sqrt{22}', '\\sqrt{23}', '2\\sqrt{6}') }],
    [{ number: 28, stem: `${circle}를 k라 하자. k^2의 값을 구하시오.`, answerKind: 'subjective', answerText: '21', choices: [] }],
  );
  assert.deepEqual(other.same, []);
  assert.deepEqual(other.uncertain.map((u) => [u.naNumber, u.gaNumber, u.formDiffers]), [[28, 10, true]]);
});

test('가형·나형 같은 문항: 가형 문항 하나는 나형 문항 하나에만 붙는다', () => {
  const stem = '부등식 \\left(\\frac{1}{9}\\right)^{x}<3^{21-4x}을 만족시키는 자연수 x의 개수는?';
  const item = (number) => ({ number, stem, answerKind: 'objective', answerText: '⑤', choices: choices('6', '7', '8', '9', '10') });
  const result = matchLegacySameQuestions([item(5)], [item(7), item(8)]);
  assert.deepEqual(result.same, [{ naNumber: 7, gaNumber: 5, similarity: 1, formDiffers: false }]);
  assert.deepEqual(result.uncertain, []);
});
