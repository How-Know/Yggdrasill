import test from 'node:test';
import assert from 'node:assert/strict';

import { buildDocumentTexSource, splitAfterBoxEnd } from '../src/problem_bank/render_engine/xelatex_v2/template.js';

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

test('[박스끝] 뒤 같은 줄로 들어온 글은 상자 밖 본문이다', () => {
  assert.deepEqual(splitAfterBoxEnd('[박스끝]'), { inside: '', after: '' });
  assert.deepEqual(splitAfterBoxEnd('이다.[박스끝] 뒷글'), { inside: '이다.', after: '뒷글' });
  // 같은 줄에서 상자가 다시 시작하면 나누지 않는다.
  assert.deepEqual(splitAfterBoxEnd('가[박스끝][박스시작]나'), { inside: '가[박스시작]나', after: '' });
});

test('상자 끝 다음 줄이 소문자 수식으로 시작해도 그 줄은 상자 밖에 찍힌다', () => {
  // 줄바꿈 뒤 "f(", "a_" 는 깨진 LaTeX 명령 복구 단계가 줄바꿈을 \n 글자로 바꿔 [박스끝] 과 한 줄이 된다.
  for (const tail of ['f(a)의 최솟값을 구하시오.', 'a_3=a_5가 되도록 하는 값을 구하시오.']) {
    const tex = buildDocumentTexSource(
      [{
        id: 'q-box-tail',
        question_uid: 'q-box-tail',
        question_number: '21',
        stem: ['다음 조건을 만족시킨다.', '[박스시작]', '(가) a_1 > 0', '(나) a_3은 정수이다.', '[박스끝]', tail].join('\n'),
        equations: [],
        objective_choices: [],
        allow_objective: false,
        allow_subjective: true,
        export_mode: 'subjective',
        meta: {},
      }],
      {},
    );
    const end = tex.indexOf('\\end{tcolorbox}');
    assert.ok(end > 0);
    assert.ok(tex.indexOf('구하시오') > end, `상자 밖: ${tail}`);
    assert.ok(tex.indexOf('정수이다') < end);
  }
});

test('줄 첫머리의 e·i·u 는 \\ne·\\ni·\\nu 명령으로 바뀌지 않는다', () => {
  const body = (stem) => {
    const tex = buildDocumentTexSource(
      [{
        id: 'q-line-start',
        question_uid: 'q-line-start',
        question_number: '3',
        stem,
        equations: [],
        objective_choices: [],
        allow_objective: false,
        allow_subjective: true,
        export_mode: 'subjective',
        meta: {},
      }],
      {},
    );
    return tex.slice(tex.indexOf('\\begin{document}'));
  };
  const command = /\\n[eiu](?![A-Za-z])/;
  for (const stem of [
    '다음을 간단히 하여라.\ni^2',
    '다음 물음에 답하여라.\n[문단]\ni=j인 성분 a_{ij}의 합',
    '두 실수 x, y에 대하여\ni+2i^2+3i^3=x+yi\n일 때, x+y의 값을 구하시오.',
    '첫 줄이다.\ne^{x}=2일 때의 값',
    '첫 줄이다.\n\nu\\cdot v=2(a-2)(a+4)',
    '첫 줄이다.\nu=2일 때의 값',
  ]) {
    assert.doesNotMatch(body(stem), command, stem);
  }
  // 글자 그대로 적힌 명령과, 한 글자가 아닌 깨진 명령의 복구는 그대로다.
  assert.match(body('a \\ne b 일 때의 값'), /\\ne b/);
  assert.match(body('a \neq b 일 때의 값'), /\\neq b/);
  assert.match(body('x \notin A 인 x의 값'), /\\notin A/);
});
