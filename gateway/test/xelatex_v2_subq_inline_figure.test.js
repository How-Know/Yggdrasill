import test from 'node:test';
import assert from 'node:assert/strict';

import { buildDocumentTexSource } from '../src/problem_bank/render_engine/xelatex_v2/template.js';

function buildTex(position) {
  return buildDocumentTexSource(
    [{
      id: 'q-subq-wrap',
      question_uid: 'q-subq-wrap',
      question_number: '01',
      stem: [
        '자연수 $x$의 약수의 개수를 $y$개라고 할 때, 다음 물음에 답하여라.',
        '[문단]',
        '[소문항1]',
        '1) 아래 표의 빈칸을 채워라.',
        '[문단]',
        '[표시작]',
        '\\begin{tabular}{c|c|c}',
        '\\hline',
        '$x$ & $1$ & $2$ \\\\',
        '\\hline',
        '$y$(개) & $1$ & \\\\',
        '\\hline',
        '\\end{tabular}',
        '[표끝]',
        '[문단]',
        '[소문항2]',
        '2) 1)의 표에서 얻어지는 순서쌍 $(x, y)$를 구하여라.',
        '[문단]',
        '[소문항3]',
        '3) 2)의 순서쌍 $(x, y)$를 좌표로 하는 점을 오른쪽 좌표평면 위에 나타내어라.',
        '[문단]',
        '[그림]',
      ].join('\n'),
      equations: [],
      objective_choices: [],
      allow_objective: false,
      allow_subjective: true,
      export_mode: 'subjective',
      figure_local_paths: ['C:/fixtures/plane.png'],
      figure_local_infos: [{ figureIndex: 1 }],
      meta: {
        figure_layout: {
          version: 1,
          items: [{ assetKey: 'idx:1', position, anchor: position === 'inline-right' ? 'right' : 'center', widthEm: 8.5 }],
          groups: [],
        },
      },
    }],
    { profile: 'naesin', paper: 'A4', columns: 1, maxQuestionsPerPage: 1, hidePreviewHeader: true, hideQuestionNumber: true },
  );
}

test('V2 renderer wraps the last sub-question with a right figure even after earlier sub-questions', () => {
  const tex = buildTex('inline-right');
  const fig = tex.indexOf('plane.png');
  const last = tex.indexOf('좌표로 하는 점을');
  const prev = tex.indexOf('얻어지는 순서쌍');
  assert.ok(fig > 0 && last > 0 && prev > 0);
  assert.equal(tex.match(/plane\.png/g).length, 1);
  const block = tex.slice(tex.lastIndexOf('\\begin{minipage}', last), fig);
  assert.ok(block.includes('좌표로 하는 점을'), 'last sub-question text and figure share the side-by-side block');
  assert.ok(!block.includes('얻어지는 순서쌍'), 'earlier sub-question stays outside the side-by-side block');
  const rowStart = tex.lastIndexOf('\\par{', last);
  assert.ok(tex.slice(rowStart, last).includes('\\hbox{\\hspace{0.5em}(3)\\hspace{1em}}'), 'keeps the sub-question indent');
});

test('V2 renderer keeps a below-stem figure after several sub-questions as before', () => {
  const tex = buildTex('below-stem');
  assert.equal(tex.match(/plane\.png/g).length, 1);
  assert.ok(tex.indexOf('좌표로 하는 점을') < tex.indexOf('plane.png'));
});
