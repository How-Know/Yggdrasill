import test from 'node:test';
import assert from 'node:assert/strict';

import { buildTexSource } from '../src/problem_bank/render_engine/xelatex_v2/template.js';

function questionWithStem(stem) {
  return {
    id: 'q-paren-break',
    question_uid: 'q-paren-break',
    question_number: '0175',
    stem,
    equations: [],
    choices: [],
    objective_choices: [],
    allow_objective: false,
    allow_subjective: true,
    export_mode: 'subjective',
    meta: {},
  };
}

test('V2 renderer makes a long parenthesized condition breakable at top-level commas', () => {
  const tex = buildTexSource(questionWithStem([
    '\\overline{\\text{BH}}의 길이를 구하시오.',
    '\\left(\\text{단, } \\sin 75^{\\circ}=\\frac{\\sqrt{6}+\\sqrt{2}}{4},'
      + ' \\tan 75^{\\circ}=2+\\sqrt{3} \\text{ 으로 계산한다.}\\right)',
  ].join('\n')));

  // 조건문 전체를 감싼 단일 `\left( … \right)` 는 TeX 이 줄바꿈을 금지하는 부분식이라
  //   좁은 단에서 그림 영역까지 흘러넘친다. 빈 구분자로 끊겨 있어야 한다.
  assert.match(tex, /\\left\(\\vphantom\{[^\n]*\}\\text\{단, \}[^\n]*\\right\./);
  assert.match(tex, /\\left\.\\vphantom\{[^\n]*\}\\tan 75\^\{\\circ\}[^\n]*\\right\)/);

  // 두 조각 사이는 텍스트 모드 `, ` 라서 그 공백에서 줄바꿈이 일어난다.
  assert.match(tex, /\\right\.\$, \$\\displaystyle/);

  // 빈 구분자 기본 여백이 남으면 쉼표 앞이 벌어진다.
  assert.match(tex, /\\nulldelimiterspace=0pt \\left\(/);

  // 분할 전의 통짜 조건문 박스는 남아 있지 않아야 한다.
  assert.ok(
    !/\\left\(\\text\{단, \}/.test(tex),
    'condition must not stay inside one unbreakable \\left(...\\right) box',
  );
});

test('V2 renderer keeps short parenthesized pairs unsplit', () => {
  const tex = buildTexSource(questionWithStem(
    '두 점 \\left(a, b\\right)를 지나는 직선을 구하시오.',
  ));

  // 좌표·순서쌍은 쉼표에서 갈라지면 안 된다.
  assert.match(tex, /\\left\(a, b\\right\)/);
  assert.ok(!/\\vphantom\{a, b\}/.test(tex));
});

test('V2 renderer does not treat \\, as a top-level comma split', () => {
  const tex = buildTexSource(questionWithStem(
    '이 집합을 A_k \\, (k=1, 2, 3, \\cdots, 16)라 하자.',
  ));

  assert.match(tex, /A_k \\, \(k=1, 2, 3, \\cdots, 16\)/);
  assert.doesNotMatch(tex, /A_k \\\$/);
});
