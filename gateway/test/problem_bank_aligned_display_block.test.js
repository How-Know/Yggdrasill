import test from 'node:test';
import assert from 'node:assert/strict';

import {
  buildDocumentTexSource,
  collapseAlignedDisplayBlocks,
} from '../src/problem_bank/render_engine/xelatex_v2/template.js';

const collapse = (text) => collapseAlignedDisplayBlocks(text.split('\n')).lines;

test('a display block with alignment tabs becomes one aligned display line', () => {
  // 추출이 쓴 모양(2026 고3 7월 공통 20번): aligned 없이 &= 로 줄을 맞췄다.
  const out = collapse(String.raw`㉠에 의하여
[수식제시시작]
b_{2k-1} &= 2 \times \left\{ \frac{a}{2} - b \right\}
&= (\boxed{\text{(가)}}) \times (a_{1}-a_{2k-1})
[수식제시끝]
이다.`);
  assert.deepEqual(out, [
    '㉠에 의하여',
    String.raw`[수식제시]\begin{aligned} b_{2k-1} &= 2 \times \left\{ \frac{a}{2} - b \right\} \\ &= (\boxed{\text{(가)}}) \times (a_{1}-a_{2k-1}) \end{aligned}`,
    '이다.',
  ]);
});

test('an aligned environment split over the lines of a block is joined as written', () => {
  // 검수가 고친 모양: aligned 로 감싸고 줄 끝에 \\ 를 넣었다.
  const out = collapse(String.raw`[수식제시시작]
\begin{aligned}
a &= b \\
&= c
\end{aligned}
[수식제시끝]`);
  assert.deepEqual(out, [String.raw`[수식제시]\begin{aligned} a &= b \\ &= c \end{aligned}`]);
});

test('a line that already ends with a row break is not given a second one', () => {
  const out = collapse(String.raw`[수식제시시작]
a &= b \\
&= c
[수식제시끝]`);
  assert.deepEqual(out, [String.raw`[수식제시]\begin{aligned} a &= b \\ &= c \end{aligned}`]);
});

test('blocks without alignment, with text around a marker, or without an end are left alone', () => {
  const plain = String.raw`[수식제시시작]
x+y=1
f(x)=\begin{cases} 1 & (x>0) \\ 0 & (x\leq 0) \end{cases}
[수식제시끝]`;
  assert.deepEqual(collapse(plain), plain.split('\n'));
  const textBefore = String.raw`따라서 [수식제시시작]
a &= b
[수식제시끝]`;
  assert.deepEqual(collapse(textBefore), textBefore.split('\n'));
  const textAfter = String.raw`[수식제시시작]
a &= b
[수식제시끝] 이다.`;
  assert.deepEqual(collapse(textAfter), textAfter.split('\n'));
  const open = String.raw`[수식제시시작]
a &= b`;
  assert.deepEqual(collapse(open), open.split('\n'));
});

test('line aligns follow the collapsed lines', () => {
  const out = collapseAlignedDisplayBlocks(
    ['가', '[수식제시시작]', 'a &= b', '&= c', '[수식제시끝]', '나'],
    ['left', 'center', 'center', 'center', 'center', 'right'],
  );
  assert.equal(out.lines.length, 3);
  assert.deepEqual(out.lineAligns, ['left', 'center', 'right']);
});

test('the document source typesets an aligned block inside a box as one formula', () => {
  const tex = buildDocumentTexSource(
    [{
      id: 'q-aligned',
      question_uid: 'q-aligned',
      question_number: '20',
      stem: String.raw`다음은 과정이다.
[박스시작]
㉠에 의하여
[수식제시시작]
b_{2k-1} &= 2 \times a_{1}
&= (\boxed{\text{(가)}}) \times a_{2}
[수식제시끝]
이다.
[박스끝]
값을 구하시오.`,
      equations: [],
      objective_choices: [],
      allow_objective: false,
      allow_subjective: true,
      export_mode: 'subjective',
      meta: {},
    }],
    { profile: 'naesin', paper: 'A4', columns: 1, maxQuestionsPerPage: 1, hidePreviewHeader: true, hideQuestionNumber: true },
  );
  const body = tex.slice(tex.indexOf('\\begin{document}'));
  assert.equal((body.match(/\\begin\{aligned\}/g) || []).length, 1);
  assert.equal((body.match(/\\end\{aligned\}/g) || []).length, 1);
  // 정렬 표시가 aligned 밖에 남지 않는다.
  const outside = body.replace(/\\begin\{aligned\}[\s\S]*?\\end\{aligned\}/g, '');
  assert.doesNotMatch(outside, /b_\{2k-1\}\s*&/);
  assert.doesNotMatch(body, /수식제시/);
  // 박스 안에서도 앞뒤 글과 이어 붙지 않고 따로 한 줄을 차지한다.
  assert.match(body, /\\par\\noindent\\hspace\*\{2\.00em\}\\adjustbox\{[^}]*\}\{[^\n]*\\begin\{aligned\}/);
});

test('inside a box only the aligned display line gets its own line', () => {
  const build = (boxBody) => {
    const tex = buildDocumentTexSource(
      [{
        id: 'q-box',
        question_uid: 'q-box',
        question_number: '20',
        stem: `다음은 과정이다.\n[박스시작]\n${boxBody}\n[박스끝]\n값을 구하시오.`,
        equations: [],
        objective_choices: [],
        allow_objective: false,
        allow_subjective: true,
        export_mode: 'subjective',
        meta: {},
      }],
      { profile: 'naesin', paper: 'A4', columns: 1, maxQuestionsPerPage: 1, hidePreviewHeader: true, hideQuestionNumber: true },
    );
    return tex.slice(tex.indexOf('\\begin{document}'));
  };
  const ownLine = /\\par\\noindent\\hspace\*\{2\.00em\}\\adjustbox/;
  // 한 줄짜리 수식 제시줄은 종전대로 글에 이어진다.
  assert.doesNotMatch(build(String.raw`n=2k일 때,
[수식제시]b_{2k}=(2k-1)a_{2k}
이다.`), ownLine);
  // 표시 없는 aligned 한 줄도 종전대로다.
  assert.doesNotMatch(build(String.raw`n=2k일 때,
\begin{aligned} a &= b \\ &= c \end{aligned}
이다.`), ownLine);
  // 추출이 직접 쓴 "[수식제시]\begin{aligned}…" 한 줄은 블록에서 합쳐진 줄과 같게 찍는다.
  assert.match(build(String.raw`n=2k일 때,
[수식제시]\begin{aligned} a &= b \\ &= c \end{aligned}
이다.`), ownLine);
});
