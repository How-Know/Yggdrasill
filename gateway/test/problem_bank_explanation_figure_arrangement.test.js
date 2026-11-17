import test from 'node:test';
import assert from 'node:assert/strict';

import {
  buildDocumentTexSource,
  buildTexSource,
  explanationFigureIncludes,
  explanationSideBySideTex,
  placeExplanationFigureTokens,
} from '../src/problem_bank/render_engine/xelatex_v2/template.js';

function withExplanation(explanation, assets) {
  return {
    id: 'q-1',
    question_uid: 'q-1',
    question_number: '1',
    stem: '문항',
    equations: [],
    choices: [],
    objective_choices: [],
    allow_objective: false,
    allow_subjective: true,
    export_mode: 'subjective',
    export_answer: '3',
    explanation,
    explanation_figure_assets: assets.map((a, k) => ({ figure_index: k + 1, width_em: 8, ...a })),
    explanation_figure_local_infos: assets.map((_, k) => ({ path: `f${k + 1}.png`, figureIndex: k + 1 })),
    meta: {},
  };
}

function explanationTex(explanation, assets) {
  return buildDocumentTexSource([withExplanation(explanation, assets)], {
    includeQuickAnswer: true,
    includeExplanation: true,
  });
}

test('그림 표시 뒤 같은 줄 글이 있을 때만 SAME 표시를 남긴다', () => {
  const out = placeExplanationFigureTokens('[그림]⇒ 평행하다.\n[그림]\n다음 줄', 2);
  assert.match(out, /@@YGGEXPLFIG0@@\n\n@@YGGEXPLSAME@@⇒ 평행하다\./);
  assert.match(out, /@@YGGEXPLFIG1@@\n\n\n다음 줄/);
});

test('아래 그림은 align 쪽으로 붙고, 없으면 가운데', () => {
  const [left, right, center] = explanationFigureIncludes(withExplanation('', [{ align: 'left' }, { align: 'right' }, {}]));
  assert.match(left, /^\{\\noindent\\includegraphics/);
  assert.match(right, /^\{\\noindent\\hfill\\includegraphics/);
  assert.match(center, /^\{\\centering\\includegraphics/);
});

test('왼쪽 그림은 그림 상자가 글 상자 앞에 온다', () => {
  const tex = explanationSideBySideTex('풀이', { path: 'f1.png', widthEm: 8, placement: 'left' });
  assert.ok(tex.indexOf('f1.png') < tex.indexOf('풀이'));
});

test('해설이 오른쪽 그림 표시로 시작하면 뒤 풀이 글과 나란히 놓는다', () => {
  const tex = explanationTex('[그림]\n동위각의 크기가 같으므로\n$\\angle x=65^{\\circ}$', [{ placement: 'right' }]);
  assert.match(tex, /\\begin\{minipage\}\[t\]\{\\dimexpr\\linewidth-\\leftskip-8\.00em-1em\\relax\}\\vspace\{0pt\}[^\n]*동위각[^\n]*\\end\{minipage\}\\hfill\\begin\{minipage\}\[t\]\{8\.00em\}[^\n]*f1\.png/);
  assert.doesNotMatch(tex, /\\centering\\includegraphics[^\n]*f1\.png/);
});

test('가로 묶음 그림은 한 줄에 놓고 같은 줄 글을 그림 밑 설명으로 둔다, 왼쪽 그림은 같은 줄 글만 옆에 둔다', () => {
  const tex = explanationTex(
    '[그림]⇒ 한 점에서 만난다.\n[그림]⇒ 평행하다.\n[그림]⇒ 꼬인 위치에 있다.\n[그림]⇒ 평행하다.\n꼬인 위치일 수도 있다.',
    [{ row: 1 }, { row: 1 }, { row: 1 }, { placement: 'left' }],
  );
  const row = tex.slice(tex.indexOf('f1.png') - 200, tex.indexOf('f4.png'));
  assert.match(row, /\\adjustbox\{max width=\\linewidth,center\}\{\\begin\{tabular\}\{@\{\}c@\{\\hspace\{1\.00em\}\}c@\{\\hspace\{1\.00em\}\}c@\{\}\}[^\n]*f1\.png[^\n]*& [^\n]*f2\.png[^\n]*& [^\n]*f3\.png[^\n]*\\\\\[0\.2em\]\n[^\n]*한 점에서 만난다[^\n]*&[^\n]*평행하다[^\n]*&[^\n]*꼬인 위치에 있다[^\n]*\\end\{tabular\}\}/);
  const side = tex.slice(tex.indexOf('f4.png') - 120);
  assert.match(side, /\\begin\{minipage\}\[t\]\{8\.00em\}\\vspace\{0pt\}\\includegraphics\[width=\\linewidth,keepaspectratio\]\{f4\.png\}\\end\{minipage\}\\hfill\\begin\{minipage\}[^\n]*평행하다[^\n]*\\end\{minipage\}\\par/);
  assert.match(side, /꼬인 위치일 수도 있다/);
  assert.doesNotMatch(side.slice(0, side.indexOf('꼬인 위치일')), /꼬인 위치일/);
});

test('카드 가로 묶음 배치에 caption 이 있으면 그림 줄 아래 설명 줄을 둔다', () => {
  const item = (k, extra = {}) => ({ assetKey: `idx:${k}`, position: 'below-stem', widthEm: 6, ...extra });
  const tex = buildTexSource({
    stem: '[해설][문단][그림][문단][그림][문단]끝',
    choices: [],
    figure_local_paths: ['a.png', 'b.png'],
    figure_local_infos: [{ path: 'a.png', figureIndex: 1 }, { path: 'b.png', figureIndex: 2 }],
    meta: {
      figure_layout: {
        version: 1,
        items: [item(1, { caption: '⇒ 한 점에서 만난다.' }), item(2, { caption: '⇒ 평행하다.' })],
        groups: [{ type: 'horizontal', members: ['idx:1', 'idx:2'], gap: 1 }],
      },
    },
  }, {});
  assert.match(tex, /\\begin\{tabular\}[^\n]*a\.png[^\n]*& [^\n]*b\.png[^\n]*\\\\\[0\.2em\]\n[^\n]*한 점에서 만난다[^\n]*&[^\n]*평행하다/);
});
