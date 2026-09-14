import test from 'node:test';
import assert from 'node:assert/strict';

import { buildDocumentTexSource } from '../src/problem_bank/render_engine/xelatex_v2/template.js';

test('V2 renderer consumes a labeled-box continuation figure exactly once', () => {
  const tex = buildDocumentTexSource(
    [{
      id: 'q-box-figure',
      question_uid: 'q-box-figure',
      question_number: '18',
      stem: [
        '첫 번째 그림이다.',
        '[그림]',
        '[박스시작]',
        '(가) 조건 설명',
        '[그림]',
        '(나) 다음 조건',
        '[박스끝]',
        '[그림]',
      ].join('\n'),
      equations: [],
      objective_choices: [],
      allow_objective: false,
      allow_subjective: true,
      export_mode: 'subjective',
      figure_local_paths: [
        'C:/fixtures/figure-1.png',
        'C:/fixtures/figure-2.png',
        'C:/fixtures/figure-3.png',
      ],
      meta: {
        figure_layout: {
          version: 1,
          items: [
            { assetKey: 'idx:1', position: 'below-stem', widthEm: 8 },
            { assetKey: 'idx:2', position: 'below-stem', widthEm: 9 },
            { assetKey: 'idx:3', position: 'below-stem', widthEm: 10 },
          ],
          groups: [],
        },
      },
    }],
    {
      profile: 'naesin',
      paper: 'A4',
      columns: 1,
      maxQuestionsPerPage: 1,
      hidePreviewHeader: true,
      hideQuestionNumber: true,
    },
  );

  const paths = [...tex.matchAll(/\\includegraphics[^{}]*\{([^{}]+)\}/g)]
    .map((match) => match[1]);

  assert.deepEqual(paths, [
    'C:/fixtures/figure-1.png',
    'C:/fixtures/figure-2.png',
    'C:/fixtures/figure-3.png',
  ]);
  assert.match(
    tex,
    /\\begin\{tcolorbox\}[\s\S]*figure-2\.png[\s\S]*\\end\{tcolorbox\}/,
    'the second figure must remain inside the condition box',
  );
});

test('V2 renderer applies measured right wrap to a figure inside a deco box', () => {
  const tex = buildDocumentTexSource(
    [{
      id: 'q-box-inline-right',
      question_uid: 'q-box-inline-right',
      question_number: '36',
      stem: [
        '다음은 등식이 성립함을 설명하는 과정이다.',
        '[박스시작]',
        '오른쪽 그림과 같이 좌표평면을 잡으면 점 M은 원점이다.',
        '두 꼭짓점의 좌표를 각각 (a, b), (c, 0)이라 하자.',
        '[수식제시]',
        '\\overline{AB}^2+\\overline{AC}^2=2(a^2+b^2+c^2)',
        '[그림]',
        '[박스끝]',
        '빈칸에 알맞은 것을 써넣으시오.',
      ].join('\n'),
      equations: [],
      objective_choices: [],
      allow_objective: false,
      allow_subjective: true,
      export_mode: 'subjective',
      figure_local_paths: ['C:/fixtures/box-inline-right.png'],
      figure_local_infos: [{ figureIndex: 1, widthPx: 270, heightPx: 218 }],
      meta: {
        figure_layout: {
          version: 1,
          items: [{
            assetKey: 'idx:1',
            anchor: 'right',
            position: 'inline-right',
            widthEm: 9.8,
            offsetXEm: 0,
            offsetYEm: 0,
          }],
          groups: [],
        },
      },
    }],
    {
      profile: 'naesin',
      paper: 'A4',
      columns: 1,
      maxQuestionsPerPage: 1,
      hidePreviewHeader: true,
      hideQuestionNumber: true,
    },
  );

  assert.equal(
    [...tex.matchAll(/box-inline-right\.png/g)].length,
    1,
    'the box figure must be emitted exactly once',
  );
  assert.match(
    tex,
    /\\begin\{tcolorbox\}[\s\S]*\\YggMeasuredWrapAuto\{r\}\{9\.80em\}[\s\S]*box-inline-right\.png[\s\S]*\\end\{tcolorbox\}/,
    'the measured wrap must be emitted inside the deco box',
  );
});
