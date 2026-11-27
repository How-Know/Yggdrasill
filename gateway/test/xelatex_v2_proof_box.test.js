import test from 'node:test';
import assert from 'node:assert/strict';

import { buildDocumentTexSource, isProofBox } from '../src/problem_bank/render_engine/xelatex_v2/template.js';

const OPTIONS = {
  profile: 'naesin',
  paper: 'A4',
  columns: 1,
  maxQuestionsPerPage: 1,
  hidePreviewHeader: true,
  hideQuestionNumber: true,
};

function boxBody(stem) {
  const tex = buildDocumentTexSource([{
    id: 'q-proof',
    question_uid: 'q-proof',
    question_number: '15',
    stem,
    equations: [],
    choices: [],
    objective_choices: [],
    allow_objective: false,
    allow_subjective: true,
    export_mode: 'subjective',
    meta: {},
  }], OPTIONS);
  const from = tex.indexOf('\\begin{tcolorbox}', tex.indexOf('\\begin{document}'));
  return tex.slice(from, tex.indexOf('\\end{tcolorbox}', from));
}

const PROOF_STEM = [
  '다음은 선분의 길이의 비를 구하는 과정이다.',
  '[문단]',
  '[박스시작]',
  '삼각형 ABC에서 각 A는 직각이다.',
  '이때 선분 AB의 길이는 box{(가)}이고',
  '선분 BC의 길이는 box{(나)}이다.',
  '[박스끝]',
  '[문단]',
  '위의 (가), (나)에 알맞은 수의 합은?',
].join('\n');

test('a box with (가)-type blanks, or one led by "…과정이다", is a proof box', () => {
  assert.equal(isProofBox(['길이는 box{(가)}이다.']), true);
  assert.equal(isProofBox(['길이는 \\boxed{\\text{(나)}}이다.']), true);
  assert.equal(isProofBox(['두 직선은 평행하다.'], '다음은 두 직선이 평행함을 증명한 것이다.'), true);
  assert.equal(isProofBox(['두 직선은 평행하다.'], '다음은 넓이를 구하는 과정의 일부이다.'), true);
  assert.equal(isProofBox(['(가) A와 B는 이웃한다.', '(나) B와 C는 이웃하지 않는다.'], '다음 조건을 만족시킨다.'), false);
});

test('a proof box keeps the stored line breaks', () => {
  const box = boxBody(PROOF_STEM);
  assert.match(box, /직각이다\.\\par\n이때 [^\n]*이고\\par\n선분 [^\n]*이다\.\\par\n/);
});

test('other boxes still run their lines together', () => {
  const box = boxBody([
    '다음 규칙에 따라 점수를 얻는다.',
    '[박스시작]',
    '주머니에서 공을 한 개 꺼내어',
    '적힌 수가 3이면 주사위를 3번 던진다.',
    '[박스끝]',
    '점수가 10점일 확률은?',
  ].join('\n'));
  assert.match(box, /꺼내어\n적힌 수가/);
  assert.ok(!/꺼내어\\par/.test(box));
});