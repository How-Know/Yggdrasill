import test from 'node:test';
import assert from 'node:assert/strict';

import { buildTexSource } from '../src/problem_bank/render_engine/xelatex_v2/template.js';

function questionWithStem(stem) {
  return {
    id: 'q-shape-square',
    question_uid: 'q-shape-square',
    question_number: '0231',
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

test('V2 renderer draws \\square before a shape name as a true square', () => {
  const tex = buildTexSource(questionWithStem(
    '오른쪽 그림과 같이 한 변의 길이가 8\\text{ cm}인 마름모'
      + ' \\square\\text{ABCD}의 넓이를 구하시오.',
  ));

  // 도형 기호는 정사각형 매크로로 나가야 한다.
  assert.match(tex, /\\mtshapesquare\{\}\\text\{ABCD\}/);
  // 값을 채우는 3:2 빈칸 네모로 오인되면 안 된다.
  assert.ok(
    !/\\mtemptybox\{\}\s*\\text\{ABCD\}/.test(tex),
    'shape symbol must not be replaced with the answer blank box',
  );
  assert.match(tex, /\\newcommand\{\\mtshapesquare\}/);
});

test('V2 renderer keeps \\square as the answer blank box when no shape name follows', () => {
  const tex = buildTexSource(questionWithStem(
    '다음 빈칸에 알맞은 수를 써넣으시오. 100(\\square+\\square)=700',
  ));

  assert.match(tex, /\\mtemptybox\{\}/);
  assert.ok(
    !/\\mtshapesquare/.test(tex.replace(/\\newcommand\{\\mtshapesquare\}[^\n]*/g, '')),
    'blank boxes must not use the shape square macro',
  );
});

test('V2 renderer treats a literal □ before a wrapped shape name as a shape symbol', () => {
  const tex = buildTexSource(questionWithStem(
    '오른쪽 그림과 같은 평행사변형 □\\text{ABCD}의 넓이는?',
  ));

  assert.match(tex, /\\mtshapesquare\{\}\\text\{ABCD\}/);
});

test('V2 renderer preserves \\notin instead of treating \\n as a newline escape', () => {
  const tex = buildTexSource(questionWithStem(
    '집합 S에 대하여 2 \\in X, 7 \\notin X를 모두 만족시키는가?',
  ));

  assert.match(tex, /7 \\notin X/);
  assert.doesNotMatch(tex, /7\s+otin X/);
});
