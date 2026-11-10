import test from 'node:test';
import assert from 'node:assert/strict';

import {
  explanationFigureIncludes,
  placeExplanationFigureTokens,
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
