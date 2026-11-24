import test from 'node:test';
import assert from 'node:assert/strict';

import {
  buildTexSource,
  normalizeTabularRowEnds,
} from '../src/problem_bank/render_engine/xelatex_v2/template.js';

const build = (stem) => buildTexSource({ stem, choices: [], question_type: '주관식', meta: {} });
const tableStem = (rows) => ['다음 표를 보고 답하시오.', '[문단]', '[표시작]', ...rows, '[표끝]'].join('\n');
// 머리말이 아닌 본문(표가 찍힌 곳)만 본다.
const body = (tex) => tex.slice(tex.indexOf('\\begin{document}'));

test('표: 행 끝이 역슬래시 하나로 저장돼 있어도 행을 나눈다', () => {
  assert.equal(normalizeTabularRowEnds('1 & 2 \\\n\\hline\n3 & 4 \\\\\n'), '1 & 2 \\\\\n\\hline\n3 & 4 \\\\\n');
  // 줄 가운데의 명령(\hline 등)과 이미 맞는 행 끝은 그대로 둔다.
  assert.equal(normalizeTabularRowEnds('\\hline\na & b \\\\\n'), '\\hline\na & b \\\\\n');

  const tex = body(build(tableStem([
    '\\begin{tabular}{|c|c|}',
    '\\hline',
    'X & 1 \\',
    '\\hline',
    '\\text{P}(X=x) & 0.5 \\\\',
    '\\hline',
    '\\end{tabular}',
  ])));
  // 뒤 행의 \hline 이 칸 안으로 들어가지 않는다(들어가면 Misplaced \noalign).
  assert.doesNotMatch(tex, /\\parbox[^\n]*\\hline/);
  assert.equal((tex.match(/\\parbox\[c\]\[2\.20em\]\[c\]/g) || []).length, 4);
});

test('표: 세로 병합 칸(\\multirow)은 아래 행까지 합친 높이의 가운데에 찍고, 그 열에는 가로선을 긋지 않는다', () => {
  const tex = body(build(tableStem([
    '\\begin{tabular}{|c|c|c|}',
    '\\hline',
    '\\multirow{2}{*}{\\text{성적(점)}} & \\multicolumn{2}{c|}{\\text{도수(명)}} \\\\',
    '\\cline{2-3}',
    ' & \\text{1반} & \\text{2반} \\\\',
    '\\hline',
    '50 & 7 & 6 \\\\',
    '\\hline',
    '\\end{tabular}',
  ])));
  assert.doesNotMatch(tex, /\\multirow/);
  assert.match(tex, /성적/);
  // 아래 행(2.20em)의 절반만큼 내려 찍는다.
  assert.match(tex, /\\raisebox\{\\dimexpr-1\.10em-0\.2pt-0\.5\\ht0\+0\.5\\dp0\\relax\}\[0pt\]\[0pt\]\{\\copy0\}/);
  // 병합된 1열에는 선이 없고 2~3열에만 긋는다. 그 아래 행 사이는 온 줄이다.
  assert.match(tex, /\\\\\n\\cline\{2-3\}\n/);
  assert.equal((tex.match(/\n\\hline\n/g) || []).length >= 2, true);
});

test('표: 대각선으로 나뉜 머리 칸(\\diagbox)은 오른쪽 위·왼쪽 아래에 글을 두고 행을 높게 잡는다', () => {
  const tex = body(build(tableStem([
    '\\begin{tabular}{|c|c|c|}',
    '\\hline',
    '\\diagbox{\\text{지역 B}}{\\text{지역 A}} & \\text{희망함} & \\text{합계} \\\\',
    '\\hline',
    '\\text{희망함} & 140 & 450 \\\\',
    '\\hline',
    '\\end{tabular}',
  ])));
  assert.doesNotMatch(tex, /\\diagbox/);
  // 머리 행은 2.2em × 1.6, 아래 행은 그대로.
  assert.match(tex, /\\parbox\[c\]\[3\.52em\]\[s\]\{\\tblcelwdA\}/);
  assert.match(tex, /\\parbox\[c\]\[3\.52em\]\[c\]\{\\tblcelwdB\}/);
  assert.match(tex, /\\parbox\[c\]\[2\.20em\]\[c\]\{\\tblcelwdA\}/);
  assert.match(tex, /\\tikz\[overlay\]\\draw\[line width=0\.4pt\]/);
  // 오른쪽 위 글(지역 A)이 먼저, 왼쪽 아래 글(지역 B)이 뒤에 온다.
  assert.match(tex, /\\raggedleft 지역 \$\\displaystyle A\$\\par\\vfill\\raggedright 지역 \$\\displaystyle B\$/);
});

test('표: 칸의 윗첨자 안에 든 \\text{한글} 은 벗기지 않는다(중괄호 한가운데에서 수식이 끊기지 않는다)', () => {
  const tex = body(build(tableStem([
    '\\begin{tabular}{|c|c|}',
    '\\hline',
    '50^{\\text{이상}} \\sim 60^{\\text{미만}} & 6 \\\\',
    '\\hline',
    '\\end{tabular}',
  ])));
  assert.match(tex, /이상/);
  assert.doesNotMatch(tex, /\^\{\$/);
  assert.doesNotMatch(tex, /\$\\displaystyle \}/);
});

test('표: 상자 안에서 시작한 표는 상자 안에 찍힌다(상자를 닫지 않는다)', () => {
  const tex = body(build([
    '다음은 평균을 구하는 과정이다.',
    '[박스시작]',
    '모집단의 확률분포는 다음 표와 같다.',
    '[표시작]',
    '\\begin{tabular}{|c|c|}',
    '\\hline',
    'X & 1 \\\\',
    '\\hline',
    '\\text{P}(X=x) & 0.5 \\\\',
    '\\hline',
    '\\end{tabular}',
    '[표끝]',
    '따라서 모평균은 1이다.',
    '[박스끝]',
    '위의 값을 구하시오.',
  ].join('\n')));
  const box = tex.slice(tex.indexOf('\\begin{tcolorbox}'), tex.indexOf('\\end{tcolorbox}'));
  assert.match(box, /모집단의 확률분포는/);
  assert.match(box, /\\begin\{tabular\}/);
  assert.match(box, /따라서 모평균은/);
  // 상자는 하나이고, 자리 표시가 글로 찍히지 않는다.
  assert.equal((tex.match(/\\begin\{tcolorbox\}/g) || []).length, 1);
  assert.doesNotMatch(tex, /YGG\\?_BOX/);
  assert.match(tex.slice(tex.indexOf('\\end{tcolorbox}')), /위의 값을 구하시오/);
});

test('수식: 중괄호 안의 막대가 절댓값 쌍뿐이면 집합의 조건 막대로 보지 않는다', () => {
  const abs = body(build('S=\\frac{2\\{1-|-2|^{5}\\}}{1-|-2|}의 값을 구하시오.'));
  assert.doesNotMatch(abs, /\\YggSetBuilder\{/);
  const set = body(build('집합 A=\\{x|x>0\\}의 원소를 구하시오.'));
  assert.match(set, /\\YggSetBuilder\{x\}\{x>0\}/);
  // 조건 막대 뒤에 절댓값이 오면 막대는 세 개(홀수)다.
  const setAbs = body(build('집합 B=\\{x||x|<3\\}의 원소를 구하시오.'));
  assert.match(setAbs, /\\YggSetBuilder\{x\}\{\\left\|\\,x\\,\\right\|<3\}/);
});
