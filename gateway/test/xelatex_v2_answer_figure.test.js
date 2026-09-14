import test from 'node:test';
import assert from 'node:assert/strict';

import { buildAnswerTexSource } from '../src/problem_bank/render_engine/xelatex_v2/template.js';

test('answer PNG TeX embeds local answer figures for PB_ANSWER_FIG markers', () => {
  const tex = buildAnswerTexSource('[[PB_ANSWER_FIG_1]]', {
    answerFigureLocalPaths: ['C:/fixtures/answer-18.png'],
    answerFigureLayout: {
      version: 1,
      verticalAlign: 'top',
      items: [{ assetKey: 'idx:1', widthEm: 18, verticalAlign: 'top', topOffsetEm: 0.55 }],
    },
  });
  assert.match(tex, /\\includegraphics\[width=18\.00em,max width=\\linewidth,keepaspectratio\]\{C:\/fixtures\/answer-18\.png\}/);
  assert.doesNotMatch(tex, /\[그림\]/);
});

test('answer PNG TeX falls back to 그림 when figure files are missing', () => {
  const tex = buildAnswerTexSource('[[PB_ANSWER_FIG_1]]');
  assert.match(tex, /그림/);
  assert.doesNotMatch(tex, /\\includegraphics/);
});

test('v11 uniform answer TeX does not redefine dfrac recursively', () => {
  const tex = buildAnswerTexSource(String.raw`\frac{1}{15}`, {
    uniformLineBox: true,
  });
  assert.match(tex, /\\YggUniformStrut/);
  assert.equal(tex.match(/\\renewcommand\{\\dfrac\}/g)?.length, 1);
  assert.doesNotMatch(tex, /\\renewcommand\{\\dfrac\}\[2\]\{\\mathchoice/);
});
