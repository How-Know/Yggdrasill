import test from 'node:test';
import assert from 'node:assert/strict';

import { buildTexSource } from '../src/problem_bank/render_engine/xelatex_v2/template.js';

function questionWithStem(stem) {
  return {
    id: 'q-sentence-text',
    question_uid: 'q-sentence-text',
    question_number: '0605',
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

function boxBody(tex) {
  const start = tex.indexOf('\\begin{tcolorbox}', tex.indexOf('\\begin{document}'));
  const end = tex.indexOf('\\end{tcolorbox}', start);
  assert.ok(start >= 0 && end > start, 'box must be rendered');
  return tex.slice(start, end);
}

test('V2 renderer unwraps a sentence extracted as one math formula so the box can wrap', () => {
  const tex = buildTexSource(questionWithStem([
    '부분집합 A는 다음 조건을 만족시킨다.',
    '[박스시작]',
    'm\\text{이 집합 }A\\text{의 원소이면, }m^2\\text{의 일의 자릿수와 }n^2'
      + '\\text{의 일의 자릿수가 같아지는 }m\\text{이 아닌 자연수 }n\\text{이 집합 }A\\text{에 존재한다.}',
    '[박스끝]',
  ].join('\n')));
  const box = boxBody(tex);

  // 한 덩어리 수식이면 줄바꿈 지점이 없어 박스 밖으로 넘친다.
  assert.ok(!box.includes('\\text{'), 'sentence text must leave math mode');
  // 수식에 바로 붙은 조사 앞에는 줄바꿈 벌점이 들어간다(xelatex_v2_math_particle_break.test.js).
  assert.match(box, /\$\\displaystyle m\$\\penalty9999\{\}이 집합 /);
  assert.match(box, /\$\\displaystyle n\^2\$\\penalty9999\{\}의 일의 자릿수가 같아지는 /);
});

test('V2 renderer keeps short unit text and nested text inside math', () => {
  const unit = buildTexSource(questionWithStem('[박스시작]\n3\\text{개}+5\\text{개}=8\\text{개}\n[박스끝]'));
  assert.match(boxBody(unit), /3\\text\{개\}\+5\\text\{개\}=8\\text\{개\}/);

  const nested = buildTexSource(questionWithStem(
    '집합 U=\\{x|x\\text{는 9 이하의 자연수이고 홀수인 수}\\}의 부분집합을 구하시오.',
  ));
  assert.match(nested, /x\\text\{는 9 이하의 자연수이고 홀수인 수\}/);

  const script = buildTexSource(questionWithStem(
    'a_{\\text{첫째항부터 열째항까지의 합계}}+b^{\\text{둘째항부터 열째항까지의 합계}}의 값을 구하시오.',
  ));
  assert.match(script, /a_\{\\text\{첫째항부터 열째항까지의 합계\}\}/);
});
