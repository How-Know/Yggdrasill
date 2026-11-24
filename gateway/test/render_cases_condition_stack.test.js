import test from 'node:test';
import assert from 'node:assert/strict';

import {
  estimateCaseCellWidthEm,
  expandCasesEnvironmentToDisplayArray,
} from '../src/problem_bank/render_engine/utils/text.js';

const expand = (body, extra = {}) => expandCasesEnvironmentToDisplayArray(
  `Y=\\begin{cases} ${body} \\end{cases}`,
  { wrapCaseConditionCells: true, ...extra },
);
const stacked = (tex) => (tex.match(/\\multicolumn/g) || []).length;

test('조건 칸 폭은 LaTeX 원문 길이가 아니라 보이는 글자로 잰다', () => {
  // 원문 43자, 지면에서는 한글 11자 + 영문·숫자·괄호.
  const cell = '(X\\text{가 }0\\text{ 또는 }1\\text{의 값을 가지는 경우})';
  const em = estimateCaseCellWidthEm(cell);
  assert.ok(em > 13 && em < 17, `em=${em}`);
  assert.ok(estimateCaseCellWidthEm('x \\le 0') < 4);
});

test('한 줄에 들어가는 조건은 "또는" 이 있어도 아래 줄로 내리지 않는다 (2023 수능 확통 26)', () => {
  const tex = expand(
    'X & (X\\text{가 }0\\text{ 또는 }1\\text{의 값을 가지는 경우}) \\\\ 2 & (X\\text{가 }2\\text{ 이상의 값을 가지는 경우})',
  );
  assert.equal(stacked(tex), 0);
});

test('식 칸이 넓어 한 줄에 들어가지 않는 조건은 아래 줄로 내린다', () => {
  const tex = expand(
    '\\frac{a(x-n)}{|x-n|}\\log_{2}(x-n)^{2} + n & (x < n \\text{ 또는 } n < x \\leq n+1) \\\\ '
    + '\\frac{n}{2 \\times \\left(\\sqrt[2n]{a^{2n}}\\right)^{x-n-1}} + \\frac{n}{2} & (x > n+1)',
  );
  assert.equal(stacked(tex), 1);
});

test('식 칸 폭은 가장 넓은 행으로 잡는다', () => {
  // 조건이 있는 행의 식은 짧지만 다른 행의 식이 넓으면 조건이 밀려난다.
  const wideOther = 'x & (x < n \\text{ 또는 } n < x \\leq n+1) \\\\ '
    + '\\frac{n}{2 \\times \\left(\\sqrt[2n]{a^{2n}}\\right)^{x-n-1}} + \\frac{n}{2} & (x > n+1)';
  assert.equal(stacked(expand(wideOther)), 1);
  const narrow = 'x & (x < n \\text{ 또는 } n < x \\leq n+1) \\\\ 2x & (x > n+1)';
  assert.equal(stacked(expand(narrow)), 0);
});

test('\\text 가 보호 토큰인 경로에서는 되돌린 글로 잰다', () => {
  const blocks = ['\\text{가 }', '\\text{ 또는 }', '\\text{의 값을 가지는 경우}'];
  const resolveProtectedText = (value) => blocks.reduce(
    (acc, block, i) => acc.replaceAll(`\u0000LATEXTEXT${i}\u0000`, block),
    String(value),
  );
  const body = 'X & (X\u0000LATEXTEXT0\u00000\u0000LATEXTEXT1\u00001\u0000LATEXTEXT2\u0000) \\\\ 2 & (x>2)';
  const tex = expand(body, { resolveProtectedText });
  assert.equal(stacked(tex), 0);
  // 출력에는 토큰이 그대로 남아 호출처가 되돌린다.
  assert.ok(tex.includes('\u0000LATEXTEXT1\u0000'));
});

test('자연어 연결이 없는 조건과 옵션이 꺼진 경우는 내리지 않는다', () => {
  const wide = '\\frac{a(x-n)}{|x-n|}\\log_{2}(x-n)^{2} + n + \\frac{n}{2}x^{2} & (x < n-100000, n < x \\leq n+100000)';
  assert.equal(stacked(expand(wide)), 0);
  const withText = '\\frac{a(x-n)}{|x-n|}\\log_{2}(x-n)^{2} + n & (x < n \\text{ 또는 } n < x \\leq n+1)';
  assert.equal(stacked(expand(withText, { wrapCaseConditionCells: false })), 0);
});
