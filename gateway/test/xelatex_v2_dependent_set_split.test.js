import test from 'node:test';
import assert from 'node:assert/strict';

import {
  buildTexSource,
  buildVisualQuestionList,
  planAdditionalDependentSetSplits,
} from '../src/problem_bank/render_engine/xelatex_v2/template.js';

// 그림 3장짜리 종속형 세트. 발문 뒤 [그림], (1) 뒤 [그림], (3) 뒤 [그림].
function dependentSetQuestion() {
  return {
    id: 'q-dep-set',
    question_uid: 'q-dep-set',
    question_number: '0019',
    stem: [
      '사각형 ABCD의 넓이를 구하려 한다. 다음 물음에 답하시오.',
      '[문단]',
      '[그림]',
      '[문단]',
      '[소문항1]',
      '(1) \\triangle AED와 \\triangle CFD가 합동임을 설명하시오.',
      '[문단]',
      '[그림]',
      '[문단]',
      '[소문항2]',
      '(2) \\square ABCD의 넓이를 구하시오.',
      '[문단]',
      '[소문항3]',
      '(3) \\triangle ADE와 \\triangle CBE의 넓이의 차를 구하시오.',
      '[문단]',
      '[그림]',
    ].join('\n'),
    equations: [],
    choices: [],
    objective_choices: [],
    allow_objective: false,
    allow_subjective: true,
    export_mode: 'subjective',
    figure_refs: ['[그림]', '[그림]', '[그림]'],
    figure_local_paths: ['/tmp/fig-1.png', '/tmp/fig-2.png', '/tmp/fig-3.png'],
    figure_local_infos: [
      { path: '/tmp/fig-1.png', assetKey: 'idx:1', figureIndex: 1, ordinal: 1 },
      { path: '/tmp/fig-2.png', assetKey: 'idx:2', figureIndex: 2, ordinal: 2 },
      { path: '/tmp/fig-3.png', assetKey: 'idx:3', figureIndex: 3, ordinal: 3 },
    ],
    meta: {
      set_type: 'dependent_set',
      figure_assets: [
        { figure_index: 1, bucket: 'b', path: 'p1' },
        { figure_index: 2, bucket: 'b', path: 'p2' },
        { figure_index: 3, bucket: 'b', path: 'p3' },
      ],
      figure_layout: {
        version: 1,
        items: [
          { assetKey: 'idx:1', widthEm: 18, position: 'below-stem' },
          { assetKey: 'idx:2', widthEm: 16, position: 'below-stem' },
          { assetKey: 'idx:3', widthEm: 14, position: 'below-stem' },
        ],
        groups: [],
      },
    },
  };
}

const visualList = (plan) => buildVisualQuestionList([dependentSetQuestion()], {
  profile: 'mock',
  dependentSetSplitPlan: plan,
});

test('dependent set is left whole when no split is planned', () => {
  const list = visualList(null);
  assert.equal(list.length, 1);
  assert.equal(list[0].figure_local_paths.length, 3);
});

test('dependent set splits at the [소문항N] boundary and carries its figures along', () => {
  const list = visualList({ 'q-dep-set': [3] });
  assert.equal(list.length, 2);

  const [head, tail] = list;
  // 머리 조각: 발문 + (1) + (2), 그림 2장.
  assert.match(head.stem, /\[소문항1\]/);
  assert.match(head.stem, /\[소문항2\]/);
  assert.ok(!/\[소문항3\]/.test(head.stem));
  assert.deepEqual(head.figure_local_paths, ['/tmp/fig-1.png', '/tmp/fig-2.png']);
  assert.deepEqual(
    head.meta.figure_layout.items.map((it) => it.assetKey),
    ['idx:1', 'idx:2'],
  );
  assert.deepEqual(head.meta.figure_assets.map((a) => a.figure_index), [1, 2]);

  // 꼬리 조각: (3) 과 그 그림만. 데이터상 문항번호는 유지하되 조판에서는 숨긴다.
  assert.match(tail.stem, /^\[소문항3\]/);
  assert.equal(tail.question_number, '0019');
  assert.deepEqual(tail.figure_local_paths, ['/tmp/fig-3.png']);
  assert.deepEqual(tail.meta.figure_layout.items.map((it) => it.assetKey), ['idx:3']);

  // 조각 끝의 [문단] 은 떨어져 나가야 아래에 빈 여백이 남지 않는다.
  assert.ok(!/\[문단\]\s*$/.test(head.stem));
  assert.ok(!/\[문단\]\s*$/.test(tail.stem));

  // 꼬리는 앞 조각과 이어지는 한 문항이라 슬롯을 거의 다 채워도 된다.
  assert.equal(head.__slotFillRatioOverride, undefined);
  assert.ok(tail.__slotFillRatioOverride > 0.9);
});

test('continuation piece hides the question number but keeps the number lane and sub-question label', () => {
  const [head, tail] = visualList({ 'q-dep-set': [3] });
  const headTex = buildTexSource(head);
  const tailTex = buildTexSource(tail);

  assert.match(headTex, /\\bfseries 0019\./);
  assert.ok(
    !/\\bfseries 0019\./.test(tailTex),
    'continuation must not reprint the stem question number',
  );
  assert.match(tailTex, /\(3\)/);
  // 번호 레인을 비워 두지 않으면 (3) 이 슬롯 왼쪽 끝으로 당겨져 앞단 (1)(2) 와 어긋난다.
  assert.match(tailTex, /\\leftskip=1em/);
});

test('measure pass moves the last sub-question out when a set overruns one column', () => {
  const plan = {};
  const list = visualList(plan);
  const changed = planAdditionalDependentSetSplits(
    list,
    { heightsPt: [980], normalColumnHeightPt: 862 },
    plan,
  );
  assert.equal(changed, true);
  assert.deepEqual(plan, { 'q-dep-set': [3] });

  // 두 조각 모두 한 단에 들어가면 더 이상 분할점을 늘리지 않는다.
  const after = visualList(plan);
  assert.equal(
    planAdditionalDependentSetSplits(
      after,
      { heightsPt: [640, 300], normalColumnHeightPt: 862 },
      plan,
    ),
    false,
  );

  // 머리 조각이 여전히 넘치면 그 다음 경계까지 밀어낸다.
  assert.equal(
    planAdditionalDependentSetSplits(
      after,
      { heightsPt: [900, 300], normalColumnHeightPt: 862 },
      plan,
    ),
    true,
  );
  assert.deepEqual(plan, { 'q-dep-set': [2, 3] });
  assert.equal(visualList(plan).length, 3);
});

test('a single sub-question piece that still overruns is left alone', () => {
  const plan = { 'q-dep-set': [3] };
  const [, tail] = visualList(plan);
  // 꼬리는 [소문항3] 이 첫 줄이라 더 잘라낼 경계가 없다.
  assert.equal(
    planAdditionalDependentSetSplits(
      [tail],
      { heightsPt: [1200], normalColumnHeightPt: 862 },
      plan,
    ),
    false,
  );
});
