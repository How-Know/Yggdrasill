import test from 'node:test';
import assert from 'node:assert/strict';

import {
  explanationFigureIncludes,
  explanationFigureSpecs,
  explanationSideBySideTex,
  placeExplanationFigureTokens,
  splitAfterCardSectionLabel,
} from '../src/problem_bank/render_engine/xelatex_v2/template.js';

test('해설 [그림] 표시가 그림 자리로 바뀌고 남는 그림은 끝에 붙는다', () => {
  const out = placeExplanationFigureTokens('그래프는 [그림] 과 같다. [그림: 직선]', 3);
  assert.match(out, /@@YGGEXPLFIG0@@/);
  assert.match(out, /@@YGGEXPLFIG1@@/);
  assert.match(out, /@@YGGEXPLFIG2@@$/);
  assert.doesNotMatch(out, /\[그림/);
});

test('그림보다 표시가 많으면 남는 표시는 지운다', () => {
  const out = placeExplanationFigureTokens('[그림] 그리고 [그림]', 1);
  assert.equal((out.match(/@@YGGEXPLFIG/g) || []).length, 1);
  assert.doesNotMatch(out, /\[그림\]/);
});

test('해설 그림이 없으면 본문을 그대로 둔다', () => {
  assert.equal(placeExplanationFigureTokens('[그림] 참고', 0), '[그림] 참고');
});

test('해설 그림 블록은 width_em 폭으로 가운데 놓인다', () => {
  const blocks = explanationFigureIncludes({
    explanation_figure_assets: [{ figure_index: 1, width_em: 8 }],
    explanation_figure_local_infos: [{ path: 'C:\\tmp\\expl-fig-a-1.png', figureIndex: 1 }],
  });
  assert.equal(blocks.length, 1);
  assert.match(blocks[0], /\\centering\\includegraphics\[width=8\.00em/);
  assert.match(blocks[0], /C:\/tmp\/expl-fig-a-1\.png/);
});

test('정답+해설 카드는 [해설] 머리말 뒤에서 나눠 풀이 글만 어울림 그림과 나란히 둔다', () => {
  const split = splitAfterCardSectionLabel(['정답  57[문단][해설][문단]삼각형의 합은', '180이므로', '[문단]']);
  assert.deepEqual(split.head, ['정답  57[문단][해설]']);
  assert.deepEqual(split.tail, ['삼각형의 합은', '180이므로', '[문단]']);
  const separate = splitAfterCardSectionLabel(['정답 3', '[AI 풀이]', '[문단]', '풀이']);
  assert.deepEqual(separate.head, ['정답 3', '[AI 풀이]']);
  assert.deepEqual(separate.tail, ['[문단]', '풀이']);
  assert.equal(splitAfterCardSectionLabel(['정답 3[문단][해설][문단]']), null);
  assert.equal(splitAfterCardSectionLabel(['그림에서 x를 구하여라.']), null);
});

test('원본에서 풀이 오른쪽에 있던 해설 그림은 풀이 글과 나란히 놓는다', () => {
  const q = {
    explanation_figure_assets: [{ figure_index: 1, width_em: 8, placement: 'right' }],
    explanation_figure_local_infos: [{ path: 'C:\\tmp\\expl-fig-a-1.png', figureIndex: 1 }],
  };
  const [spec] = explanationFigureSpecs(q);
  assert.equal(spec.placement, 'right');
  const tex = explanationSideBySideTex('풀이', spec);
  assert.match(tex, /\\begin\{minipage\}\[t\]\{\\dimexpr\\linewidth-\\leftskip-8\.00em-1em\\relax\}\\vspace\{0pt\}풀이\\end\{minipage\}\\hfill/);
  assert.match(tex, /\\begin\{minipage\}\[t\]\{8\.00em\}.*C:\/tmp\/expl-fig-a-1\.png/);
  assert.equal(explanationFigureSpecs({ ...q, explanation_figure_assets: [{ figure_index: 1 }] })[0].placement, 'below');
});
