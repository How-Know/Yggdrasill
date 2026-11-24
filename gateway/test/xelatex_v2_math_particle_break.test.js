import test from 'node:test';
import assert from 'node:assert/strict';

import { buildTexSource } from '../src/problem_bank/render_engine/xelatex_v2/template.js';

function questionWithStem(stem) {
  return {
    id: 'q-math-particle',
    question_uid: 'q-math-particle',
    question_number: '28',
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

const PENALTY = '\\penalty9999{}';

test('V2 renderer keeps a particle glued to the math before it', () => {
  const tex = buildTexSource(questionWithStem(
    '상자 \\text{A}에서 2개의 공을 꺼내어 상자 \\text{B}에 넣는다.',
  ));

  // 수식 뒤에 바로 붙은 조사 앞에서는 줄이 바뀌지 않게 벌점을 넣는다.
  assert.ok(tex.includes(`\\text{A}$${PENALTY}에서`), 'penalty after math before 에서');
  assert.ok(tex.includes(`2$${PENALTY}개의`), 'penalty after a number before 개의');
  assert.ok(tex.includes(`\\text{B}$${PENALTY}에 넣는다.`), 'penalty after math before 에');
});

test('V2 renderer does not leave an opening parenthesis alone at a line end', () => {
  const tex = buildTexSource(questionWithStem(
    '\\cos\\theta의 값은? (단, 세 점 \\text{O}, \\text{P}는 한 직선 위에 있지 않다.)',
  ));

  assert.ok(tex.includes(`($${PENALTY}단, 세 점`), 'penalty between ( and 단');
});

test('V2 renderer still breaks at a space after math', () => {
  const tex = buildTexSource(questionWithStem(
    '함수 f(x) 위의 점 \\text{P} 에서 그은 접선의 기울기는 3 이다.',
  ));

  // 띄어 쓴 자리는 원래 줄을 바꿀 수 있는 자리다. 벌점을 넣지 않는다.
  assert.ok(!tex.includes(`${PENALTY} 위의`));
  assert.ok(!tex.includes(`${PENALTY} 에서`));
  assert.ok(!tex.includes(`${PENALTY} 이다`));
  assert.match(tex, /f\(x\)\$ 위의/);
});

test('V2 renderer adds no penalty when math ends the line or follows the text', () => {
  const tex = buildTexSource(questionWithStem('이때 a+b의 값은 x=3'));

  assert.ok(tex.includes(`a+b$${PENALTY}의 값은`));
  // 한글 뒤에 오는 수식 앞, 줄 끝 수식 뒤에는 넣지 않는다.
  assert.ok(!tex.includes(`${PENALTY}$`));
  assert.ok(!/x=3\$\\penalty/.test(tex));
});
