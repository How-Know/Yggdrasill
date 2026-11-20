import test from 'node:test';
import assert from 'node:assert/strict';

import {
  buildDocumentTexSource,
  explanationMarkdownTablesToArray,
} from '../src/problem_bank/render_engine/xelatex_v2/template.js';
import { texErrorSummary } from '../src/problem_bank/render_engine/xelatex_v2/renderer.js';

function explanationTex(explanation) {
  return buildDocumentTexSource([{
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
    meta: {},
  }], {
    includeQuickAnswer: true,
    includeExplanation: true,
  });
}

test('줄마다 빈 줄로 나눈 해설은 줄마다 따로 찍힌다(식이 한 줄로 붙지 않는다)', () => {
  const tex = explanationTex('$f(1)=2$\n\n$f(2)=5$\n\n따라서 $f(1)+f(2)=7$');
  assert.doesNotMatch(tex, /f\(1\)=2\s*f\(2\)=5/);
  const first = tex.indexOf('f(1)=2');
  const second = tex.indexOf('f(2)=5');
  assert.ok(first > 0 && second > first);
  assert.match(tex.slice(first, second), /\\par/);
});

test('마크다운 표(증감표)는 array 표 한 줄로 바뀌고 구분 줄은 버린다', () => {
  const out = explanationMarkdownTablesToArray([
    '증감표는 다음과 같다.',
    '| $x$ | $\\cdots$ | $1$ | $\\cdots$ |',
    '|---|---|---|---|',
    "| $f'(x)$ | $+$ | $0$ | $-$ |",
    '| $f(x)$ | $\\nearrow$ | 극대 | $\\searrow$ |',
    '따라서',
  ].join('\n'));
  const lines = out.split('\n');
  assert.equal(lines.length, 3);
  assert.equal(lines[0], '증감표는 다음과 같다.');
  assert.match(lines[1], /^\$\\begin\{array\}\{\|c\|c\|c\|c\|\} \\hline /);
  assert.match(lines[1], /\\nearrow/);
  assert.match(lines[1], /\\text\{극대\}/);
  assert.doesNotMatch(lines[1], /---/);
  assert.equal((lines[1].match(/\\\\ \\hline/g) || []).length, 3);
  assert.equal(lines[2], '따라서');
  // 표가 없으면 그대로
  assert.equal(explanationMarkdownTablesToArray('값은 $|x|$ 이다.'), '값은 $|x|$ 이다.');
  // 한 줄뿐이면 표로 보지 않는다
  assert.equal(explanationMarkdownTablesToArray('| $a$ | $b$ |'), '| $a$ | $b$ |');
});

test('표 칸의 절댓값 기호는 칸 구분으로 보지 않는다', () => {
  const out = explanationMarkdownTablesToArray('| $x$ | $|x|$ |\n| $-1$ | $1$ |');
  assert.match(out, /\{\|c\|c\|\}/);
  assert.match(out, /\|x\|/);
});

test('증감표가 든 해설은 표 블록으로 찍히고 화살표 명령이 글자로 풀리지 않는다', () => {
  const tex = explanationTex('증감표는\n\n| $x$ | $1$ |\n| $f(x)$ | $\\nearrow$ |\n\n이다.');
  assert.match(tex, /\\begin\{array\}\{\|c\|c\|\}/);
  assert.match(tex, /\\nearrow/);
  assert.doesNotMatch(tex, /(?<!\\n)earrow/);
});

test('"\\n" 으로 시작하는 수식 명령은 줄바꿈으로 풀지 않는다', () => {
  const tex = explanationTex('$a \\nearrow b$, $p \\nmid q$, $x \\nleq y$, $A \\nsubseteq B$');
  for (const cmd of ['\\nearrow', '\\nmid', '\\nleq', '\\nsubseteq']) {
    assert.ok(tex.includes(cmd), `${cmd} 가 남아 있어야 한다`);
  }
});

test('경우 번호의 로마 숫자는 괄호째 본문 글꼴로 찍는다', () => {
  const tex = explanationTex('(ⅰ) $a_2<0$인 경우\n\n(ⅱ) $a_2 \\geq 0$인 경우');
  assert.match(tex, /\\text\{\(ⅰ\)\}/);
  assert.match(tex, /\\text\{\(ⅱ\)\}/);
});

test('좌변이 붙은 cases 식은 좌변과 함께 한 블록으로 찍는다', () => {
  const tex = explanationTex('수열은 $a_n=\\begin{cases} 1 & (n=1) \\\\ 2n & (n \\geq 2) \\end{cases}$ 이다.');
  assert.match(tex, /\$\\displaystyle a_\{?n\}?=\\begin\{cases\}/);
  // 환경 앞에 짝 없는 $ 가 남지 않는다
  assert.doesNotMatch(tex, /\$a_n=\s*\\par/);
});

test('조판 실패 요약: 첫 TeX 오류 줄과 그 줄 번호를 뽑는다', () => {
  const log = [
    'This is XeTeX',
    '(./doc.tex',
    '! Missing $ inserted.',
    '<inserted text> ',
    '                $',
    'l.123 \\end{cases}',
    '                 ',
    '! Emergency stop.',
  ].join('\n');
  const summary = texErrorSummary(log);
  assert.match(summary, /^! Missing \$ inserted\./);
  assert.match(summary, /l\.123/);
  assert.equal(texErrorSummary('no errors here'), '');
});
