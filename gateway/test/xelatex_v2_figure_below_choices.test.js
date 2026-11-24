import test from 'node:test';
import assert from 'node:assert/strict';

import { buildDocumentTexSource } from '../src/problem_bank/render_engine/xelatex_v2/template.js';
import { normalizePosition } from '../src/problem_bank/render_engine/utils/figure_layout.js';

const OPTIONS = {
  profile: 'naesin',
  paper: 'A4',
  columns: 1,
  maxQuestionsPerPage: 1,
  hidePreviewHeader: true,
  hideQuestionNumber: true,
};

const CHOICES = [
  { label: '①', text: '\\frac{37}{4}' },
  { label: '②', text: '\\frac{39}{4}' },
  { label: '③', text: '\\frac{41}{4}' },
  { label: '④', text: '\\frac{43}{4}' },
  { label: '⑤', text: '\\frac{45}{4}' },
];

function question({ stem, layoutItems, paths, infos, mode = 'objective', choices = CHOICES }) {
  return {
    id: 'q-below-choices',
    question_uid: 'q-below-choices',
    question_number: '13',
    stem,
    equations: [],
    choices,
    objective_choices: choices,
    allow_objective: true,
    allow_subjective: true,
    export_mode: mode,
    figure_local_paths: paths,
    figure_local_infos: infos,
    meta: { figure_layout: { version: 1, items: layoutItems, groups: [] } },
  };
}

const item = (assetKey, position, extra = {}) => ({
  assetKey,
  position,
  anchor: 'center',
  widthEm: 10,
  offsetXEm: 0,
  offsetYEm: 0,
  ...extra,
});

/// 문서에서 실제로 찍힌 순서: 그림 파일과 선지 묶음('choices'). 선지 묶음은 배치를 재느라 번호가 여러 번 나와도 하나로 센다.
function bodyOrder(tex) {
  const body = tex.slice(tex.indexOf('\\begin{document}'));
  const out = [];
  for (const m of body.matchAll(/[①⑤]|\\includegraphics[^{}]*\{([^{}]+)\}/g)) {
    const name = m[1] ? m[1].split('/').pop() : 'choices';
    if (out[out.length - 1] !== name) out.push(name);
  }
  return out;
}

test('figure_layout keeps the below-choices position', () => {
  assert.equal(normalizePosition('below-choices'), 'below-choices');
  assert.equal(normalizePosition('somewhere'), 'below-stem');
});

test('V2 prints a below-choices figure after the choices', () => {
  const tex = buildDocumentTexSource(
    [question({
      stem: '곡선 y=f(x)와 선분 PQ로 둘러싸인 부분의 넓이를 B라 할 때, B-A의 값은?\n[문단]\n[그림]',
      layoutItems: [item('idx:1', 'below-choices')],
      paths: ['C:/fixtures/curve.png'],
      infos: [{ figureIndex: 1, assetKey: 'idx:1', widthPx: 300, heightPx: 400 }],
    })],
    OPTIONS,
  );
  assert.deepEqual(bodyOrder(tex), ['choices', 'curve.png']);
  assert.equal([...tex.matchAll(/curve\.png/g)].length, 1, 'the figure is printed once');
});

test('V2 keeps a below-stem figure before the choices', () => {
  const tex = buildDocumentTexSource(
    [question({
      stem: '곡선 y=f(x)와 선분 PQ로 둘러싸인 부분의 넓이를 B라 할 때, B-A의 값은?\n[문단]\n[그림]',
      layoutItems: [item('idx:1', 'below-stem')],
      paths: ['C:/fixtures/curve.png'],
      infos: [{ figureIndex: 1, assetKey: 'idx:1', widthPx: 300, heightPx: 400 }],
    })],
    OPTIONS,
  );
  assert.deepEqual(bodyOrder(tex), ['curve.png', 'choices']);
});

test('V2 moves only the below-choices figure when a question has two figures', () => {
  const tex = buildDocumentTexSource(
    [question({
      stem: '그림과 같이 두 도형이 있다.\n[그림]\n넓이의 합은?\n[문단]\n[그림]',
      layoutItems: [item('idx:1', 'below-stem'), item('idx:2', 'below-choices')],
      paths: ['C:/fixtures/first.png', 'C:/fixtures/second.png'],
      infos: [
        { figureIndex: 1, assetKey: 'idx:1', widthPx: 300, heightPx: 200 },
        { figureIndex: 2, assetKey: 'idx:2', widthPx: 300, heightPx: 200 },
      ],
    })],
    OPTIONS,
  );
  assert.deepEqual(bodyOrder(tex), ['first.png', 'choices', 'second.png']);
});

test('V2 defers a below-choices figure whose marker sits in the middle of the stem', () => {
  const tex = buildDocumentTexSource(
    [question({
      stem: '그림과 같이 주머니가 있다.\n[그림]\n(단, 공의 크기는 같다.)\n[문단]\n[그림]',
      layoutItems: [item('idx:1', 'below-choices'), item('idx:2', 'below-stem')],
      paths: ['C:/fixtures/first.png', 'C:/fixtures/second.png'],
      infos: [
        { figureIndex: 1, assetKey: 'idx:1', widthPx: 300, heightPx: 200 },
        { figureIndex: 2, assetKey: 'idx:2', widthPx: 300, heightPx: 200 },
      ],
    })],
    OPTIONS,
  );
  assert.deepEqual(bodyOrder(tex), ['second.png', 'choices', 'first.png']);
});

test('V2 defers a below-choices figure that has no marker in the stem', () => {
  const tex = buildDocumentTexSource(
    [question({
      stem: '주머니에서 공을 꺼낼 때, 확률은?',
      layoutItems: [item('idx:1', 'below-choices')],
      paths: ['C:/fixtures/bag.png'],
      infos: [{ figureIndex: 1, assetKey: 'idx:1', widthPx: 300, heightPx: 200 }],
    })],
    OPTIONS,
  );
  assert.deepEqual(bodyOrder(tex), ['choices', 'bag.png']);
});

test('V2 prints a below-choices figure below the stem when no choices are printed', () => {
  const tex = buildDocumentTexSource(
    [question({
      stem: '넓이를 구하시오.\n[문단]\n[그림]',
      layoutItems: [item('idx:1', 'below-choices')],
      paths: ['C:/fixtures/curve.png'],
      infos: [{ figureIndex: 1, assetKey: 'idx:1', widthPx: 300, heightPx: 400 }],
      mode: 'subjective',
      choices: [],
    })],
    OPTIONS,
  );
  assert.deepEqual(bodyOrder(tex), ['curve.png']);
});
