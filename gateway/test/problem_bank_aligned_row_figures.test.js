import test from 'node:test';
import assert from 'node:assert/strict';

import { buildTexSource } from '../src/problem_bank/render_engine/xelatex_v2/template.js';

const stem = [
  '\\begin{aligned}',
  '&\\{(-3)+(+7)\\}+(-4) [그림] \\\\',
  '&=\\{(+7)+(-3)\\}+(-4) [그림] \\\\',
  '&=0',
  '\\end{aligned}',
].join('\n');

function question(position) {
  const item = (k) => ({ assetKey: `idx:${k}`, position, heightEm: 2, offsetYEm: 1.1 });
  return {
    stem,
    choices: [],
    figure_local_paths: ['a.png', 'b.png'],
    figure_local_infos: [{ path: 'a.png', figureIndex: 1 }, { path: 'b.png', figureIndex: 2 }],
    meta: { figure_layout: { version: 1, items: [item(1), item(2)] } },
  };
}

test('aligned 줄 끝의 글 중간 그림은 식 블록 안 그 줄 오른쪽에 들어간다', () => {
  const tex = buildTexSource(question('inline-text'), {});
  const block = tex.slice(tex.indexOf('\\begin{aligned}'), tex.indexOf('\\end{aligned}'));
  assert.match(block, /\(-4\) &&\\quad\\mbox\{[^\n]*\\raisebox\{\\dimexpr-0\.5\\height\+0\.5ex-1\.10em\\relax\}\{\\includegraphics\[height=2\.00em\]\{a\.png\}\}[^\n]*\\\\/);
  assert.match(block, /\\includegraphics\[height=2\.00em\]\{b\.png\}/);
  assert.doesNotMatch(tex, /\[그림\]|YggAlignedRowFig/);
});

test('글 중간이 아닌 그림 표시는 식 블록 밖 그림으로 남는다', () => {
  const tex = buildTexSource(question('below-stem'), {});
  assert.doesNotMatch(tex, /YggAlignedRowFig|\\quad\\mbox\{\\hspace\*/);
});

test('aligned 블록이 아닌 본문의 글 중간 그림은 그 글줄 안에 남고 뒤 그림 순번이 밀리지 않는다', () => {
  const tex = buildTexSource({
    stem: '이 도형의 바깥쪽 ( [그림] 모양) 둘레의 길이는?\n[문단]\n[그림]',
    choices: [],
    figure_local_paths: ['a.png', 'b.png'],
    figure_local_infos: [{ path: 'a.png', figureIndex: 1 }, { path: 'b.png', figureIndex: 2 }],
    meta: {
      figure_layout: {
        version: 1,
        items: [
          { assetKey: 'idx:1', position: 'inline-text', heightEm: 1.9 },
          { assetKey: 'idx:2', position: 'below-stem', widthEm: 17.5 },
        ],
      },
    },
  }, {});
  const line = tex.split('\n').find((l) => l.includes('바깥쪽')) || '';
  assert.match(line, /\\includegraphics\[height=1\.90em\]\{a\.png\}/);
  assert.match(line, /모양/);
  assert.match(tex, /\\includegraphics\[width=17\.50em\]\{b\.png\}/);
});
