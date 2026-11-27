import test from 'node:test';
import assert from 'node:assert/strict';

import { buildDocumentTexSource } from '../src/problem_bank/render_engine/xelatex_v2/template.js';
import {
  applyLayoutOverrides,
  normalizePosition,
  parseFigureLayout,
} from '../src/problem_bank/render_engine/utils/figure_layout.js';

const OPTIONS = {
  profile: 'naesin',
  paper: 'A4',
  columns: 1,
  maxQuestionsPerPage: 1,
  hidePreviewHeader: true,
  hideQuestionNumber: true,
};

const STEM = '그림과 같이 원에 내접하는 삼각형 ABC가 있다. 선분 AC의 길이를 구하시오.\n[그림]';

function question(layout, stem = STEM) {
  return {
    id: 'q-placement-box',
    question_uid: 'q-placement-box',
    question_number: '13',
    stem,
    equations: [],
    choices: [],
    objective_choices: [],
    allow_objective: false,
    allow_subjective: true,
    export_mode: 'subjective',
    figure_local_paths: ['C:/fixtures/circle.png'],
    figure_local_infos: [{ figureIndex: 1, assetKey: 'idx:1', widthPx: 300, heightPx: 300 }],
    meta: { figure_layout: { version: 1, groups: [], ...layout } },
  };
}

const item = (position, extra = {}) => ({
  assetKey: 'idx:1',
  position,
  anchor: 'center',
  widthEm: 10,
  offsetXEm: 0,
  offsetYEm: 0,
  ...extra,
});

/// 머리말(매크로 정의)을 뺀 본문.
function body(layout, options = OPTIONS, stem = STEM) {
  const tex = buildDocumentTexSource([question(layout, stem)], options);
  return tex.slice(tex.indexOf('\\begin{document}'));
}

test('figure_layout accepts the free position', () => {
  assert.equal(normalizePosition('free'), 'free');
});

test('a free figure is put at its offsets and takes no room in the text', () => {
  const tex = body({ items: [item('free', { offsetXEm: 3, offsetYEm: -2 })] });
  assert.ok(
    tex.includes('\\YggFreeBox{3.00em}{-2.00em}{\\includegraphics[width=10.00em]{C:/fixtures/circle.png}}'),
    'the figure is drawn in a free box at (3em, -2em)',
  );
  assert.equal([...tex.matchAll(/circle\.png/g)].length, 1, 'the figure is printed once');
  const after = tex.slice(tex.indexOf('\\YggFreeBox'), tex.indexOf('\\YggFreeBox') + 200);
  assert.ok(!/\\vspace\*/.test(after), 'no room is reserved when reserveEm is 0');
});

test('a free figure can be moved across the page, other figures stay within 20em', () => {
  const free = parseFigureLayout(question({ items: [item('free', { offsetXEm: 30, offsetYEm: 200 })] })).items[0];
  assert.equal(free.offsetXEm, 30);
  assert.equal(free.offsetYEm, 80);
  const below = parseFigureLayout(question({ items: [item('below-stem', { offsetXEm: 30 })] })).items[0];
  assert.equal(below.offsetXEm, 20);
  const moved = applyLayoutOverrides(
    parseFigureLayout(question({
      items: [item('below-stem')],
      overrides: { 'cols:1': { items: [{ assetKey: 'idx:1', offsetXEm: 30 }] } },
    })),
    { columns: 1 },
  ).items[0];
  assert.equal(moved.offsetXEm, 20, 'a page-layout value follows the limit of the position it lands on');
});

test('a free figure reserves room only when asked', () => {
  const tex = body({ items: [item('free', { reserveEm: 5 })] });
  assert.match(tex, /\\YggFreeBox\{0\.00em\}\{0\.00em\}\{[^\n]*\}\n\\vspace\*\{5\.00em\}/);
});

test('a figure beside the text keeps the old output when no box value is set', () => {
  const tex = body({ items: [item('inline-right', { anchor: 'right' })] });
  assert.match(tex, /\\YggMeasuredWrapAuto\{r\}\{10\.00em\}\{0\.5\\baselineskip\}\{\\makebox\[\\linewidth\]\[l\]\{\\includegraphics\[width=10\.00em\]/);
  assert.ok(!tex.includes('\\YggWrapForceLines='), 'the line count is measured, not forced');
  assert.ok(!tex.includes('\\raisebox{'), 'the figure is not shifted');
});

test('a figure beside the text can be moved down, spaced and given a line count', () => {
  const tex = body({
    items: [item('inline-right', { anchor: 'right', offsetYEm: 1.5, gapEm: 1.2, wrapLines: 6 })],
  });
  assert.match(tex, /\\YggWrapForceLines=6\\relax\n\\YggMeasuredWrapAuto\{r\}\{10\.00em\}\{1\.20em\}/);
  assert.ok(
    tex.includes('\\raisebox{-1.50em}[\\height][\\depth]{\\includegraphics[width=10.00em]{C:/fixtures/circle.png}}'),
    'the figure is lowered by 1.5em without changing the room it takes',
  );
  assert.match(tex, /\\YggWrapForceLines=0\\relax/, 'the forced line count is cleared after the figure');
});

test('a layout can carry other values for another page layout', () => {
  const layout = {
    items: [item('below-stem')],
    overrides: {
      'cols:2': { items: [{ assetKey: 'idx:1', widthEm: 8 }] },
      mock: { items: [{ assetKey: 'idx:1', widthEm: 7 }] },
      'mock/2': { items: [{ assetKey: 'idx:1', position: 'free', offsetXEm: 12 }] },
    },
  };
  assert.match(body(layout), /\\includegraphics\[width=10\.00em\]/, 'one column: the base value');
  assert.match(
    body(layout, { ...OPTIONS, columns: 2 }),
    /\\includegraphics\[width=8\.00em\]/,
    'two columns: the cols:2 value',
  );
});

test('the more specific page layout wins', () => {
  const parsed = parseFigureLayout(question({
    items: [item('below-stem')],
    overrides: {
      'cols:2': { items: [{ assetKey: 'idx:1', widthEm: 8 }] },
      mock: { items: [{ assetKey: 'idx:1', widthEm: 7 }] },
      'mock/2': { items: [{ assetKey: 'idx:1', position: 'free', offsetXEm: 12 }] },
    },
  }));
  const resolved = applyLayoutOverrides(parsed, { profile: 'mock', columns: 2 }).items[0];
  assert.equal(resolved.widthEm, 7, 'the profile value beats the column value');
  assert.equal(resolved.position, 'free', 'the profile/column value is applied last');
  assert.equal(resolved.offsetXEm, 12);
  assert.equal(parsed.items[0].widthEm, 10, 'the stored base value is not changed');
  assert.equal(applyLayoutOverrides(parsed, null), parsed, 'no page layout: the base layout as it is');
});

test('box values are kept only when they are written', () => {
  const plain = parseFigureLayout(question({ items: [item('inline-right')] })).items[0];
  assert.ok(!('gapEm' in plain) && !('wrapLines' in plain) && !('reserveEm' in plain));
  const set = parseFigureLayout(question({
    items: [item('inline-right', { gapEm: 99, wrapLines: 3.4, reserveEm: -1 })],
  })).items[0];
  assert.equal(set.gapEm, 5, 'the gap is limited to 5em');
  assert.equal(set.wrapLines, 3, 'the line count is a whole number');
  assert.equal(set.reserveEm, 0, 'the reserved room is not negative');
});

const STEM_BETWEEN = '그림은 함수를 나타낸 것이다.\n[문단]\n[그림]\n[문단]\n함숫값의 합은?';

/// 어울림 매크로의 글 인수(다섯째 인수)부터 매크로가 닫히는 곳까지.
function wrappedText(tex) {
  const from = tex.indexOf('\\YggMeasuredWrapAuto{r}');
  return tex.slice(from, tex.indexOf('\n}\n', from) + 3);
}

test('the paragraph after a figure beside the text flows beside it too', () => {
  const tex = body({ items: [item('inline-right', { anchor: 'right' })] }, OPTIONS, STEM_BETWEEN);
  const wrapped = wrappedText(tex);
  assert.match(wrapped, /나타낸 것이다\.\\par\}\n\\par\n\\vspace\{0\.40em\}\n[^\n]*함숫값의 합은\?\\par\}\n\}\n$/);
  assert.equal([...tex.matchAll(/함숫값의 합은/g)].length, 1, 'the paragraph is printed once');
});

test('the score mark stays at the end of the paragraph that flows beside the figure', () => {
  const tex = buildDocumentTexSource(
    [question({ items: [item('inline-right', { anchor: 'right' })] }, STEM_BETWEEN)],
    { ...OPTIONS, includeQuestionScore: true, questionScoreByQuestionId: { 'q-placement-box': 4 } },
  );
  assert.match(wrappedText(tex.slice(tex.indexOf('\\begin{document}'))), /함숫값의 합은\?\\ \{\\small\\mbox\{\[4점\]\}\}\\par\}\n\}\n$/);
});

test('sub-questions and a box stay below the figure', () => {
  const layout = { items: [item('inline-right', { anchor: 'right' })] };
  const sub = body(layout, OPTIONS, '그림과 같다.\n[그림]\n(1) 넓이를 구하시오.');
  assert.ok(!wrappedText(sub).includes('넓이를 구하시오'), 'a sub-question keeps its own layout');
  const boxed = body(layout, OPTIONS, '그림과 같다.\n[그림]\n다음을 구하시오.\n[박스시작]\n조건\n[박스끝]');
  assert.ok(wrappedText(boxed).includes('다음을 구하시오'), 'the paragraph before a box flows beside the figure');
  assert.ok(boxed.indexOf('\\begin{tcolorbox}') > boxed.indexOf('다음을 구하시오'), 'the box comes after the wrap');
  assert.ok(!wrappedText(boxed).includes('tcolorbox'), 'the box is not put beside the figure');
});

test('lines left beside the figure are cleared by the count wrapfig keeps', () => {
  const tex = buildDocumentTexSource([question({ items: [item('inline-right')] })], OPTIONS);
  assert.ok(tex.includes('\\ifnum\\numexpr\\value{WF@wrappedlines}-1\\relax>\\YggWrapClearCount'));
});
