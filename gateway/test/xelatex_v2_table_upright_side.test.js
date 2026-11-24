import test from 'node:test';
import assert from 'node:assert/strict';

import {
  buildDocumentTexSource,
  buildTexSource,
  planSideTableCut,
  sideLineFits,
  sideTableWidthFraction,
} from '../src/problem_bank/render_engine/xelatex_v2/template.js';

const table = [
  '[표시작]',
  '\\begin{tabular}{|c|c|}',
  '\\hline',
  'z & \\text{P}(0\\leq Z\\leq z) \\\\',
  '\\hline',
  '1.0 & 0.3413 \\\\',
  '\\hline',
  '\\end{tabular}',
  '[표끝]',
].join('\n');

const build = (stem, meta = {}) =>
  buildTexSource({ stem, choices: [], question_type: '주관식', meta });

// 머리말(매크로 정의)에도 같은 이름이 있으므로 인자까지 붙은 "쓰인 곳" 만 센다.
const wrapsRight = (tex) => /\\YggMeasuredWrapBegin\{r\}/.test(tex);

test('표 칸의 \\text{P} 는 본문처럼 곧은 글자로 남는다', () => {
  const tex = build(`\\text{P}(X\\geq 8)의 값을 표를 이용하여 구하시오.\n[문단]\n${table}`);
  assert.match(tex, /\\text\{P\}\(0\\leq Z\\leq z\)/);
  assert.doesNotMatch(tex, /\$\\displaystyle P\(0\\leq Z\\leq z\)\$/);
});

test('한글이 든 \\text{…} 칸은 예전처럼 벗겨서 글로 찍는다', () => {
  const tex = build(`다음 표를 보시오.\n[문단]\n[표시작]\n\\begin{tabular}{|c|c|}\n\\hline\n\\text{합계} & \\text{A} \\\\\n\\hline\n\\end{tabular}\n[표끝]`);
  assert.doesNotMatch(tex, /\\text\{합계\}/);
  assert.match(tex, /합계/);
  assert.match(tex, /\\text\{A\}/);
});

test('표 위치: 저장된 값이 있으면 그 값을, 없고 본문이 "오른쪽 …표" 라고 적으면 옆 배치를 쓴다', () => {
  const stem = `\\text{P}(X\\geq 8)의 값을 오른쪽 표준정규분포표를 이용하여 구한 것은?\n[문단]\n${table}`;
  // 기본으로 켜져 있다.
  assert.match(build(stem), sideBlock);
  assert.equal(wrapsRight(build(stem)), false);
  const stored = build(stem, {
    table_layout: { items: [{ tableKey: 'raw:1', position: 'inline-right', anchor: 'center' }] },
  });
  assert.equal(wrapsRight(stored), true);
  assert.doesNotMatch(stored, sideBlock);
  // PB_XELATEX_AUTO_TABLE_SIDE=0 이면 끈다(표는 본문 아래).
  const before = process.env.PB_XELATEX_AUTO_TABLE_SIDE;
  process.env.PB_XELATEX_AUTO_TABLE_SIDE = '0';
  try {
    assert.doesNotMatch(build(stem), sideBlock);
  } finally {
    if (before === undefined) delete process.env.PB_XELATEX_AUTO_TABLE_SIDE;
    else process.env.PB_XELATEX_AUTO_TABLE_SIDE = before;
  }
});

test('옆 배치: 교재 문항은 표를 본문 첫 줄 옆에서 시작하고, 그 밖의 문항은 끝부분 옆에 둔다', () => {
  const stem = [
    '어느 고등학교의 수학 시험에 응시한 수험생의 시험 점수는 평균이 68점, 표준편차가 10점인 정규분포를 따른다고 한다. 이 수학 시험에 응시한 수험생 중 임의로 선택한 수험생 한 명의 시험 점수가 55점 이상이고 78점 이하일 확률을 오른쪽 표준정규분포표를 이용하여 구한 것은?',
    '[문단]',
    table,
  ].join('\n');
  const make = (sourceTypeCode) => buildTexSource({
    stem, choices: [], question_type: '주관식', meta: {}, source_type_code: sourceTypeCode,
  });
  const body = (tex) => tex.slice(tex.indexOf('\\begin{document}'));
  const beforeBlock = (tex) => body(tex).slice(0, body(tex).search(/\\begin\{minipage\}\[t\]/));
  // 수능: 앞 문장은 온 폭에 남는다.
  assert.match(beforeBlock(make('mock_past')), /정규분포를 따른다고 한다/);
  // 교재: 본문 전체가 왼쪽 칸으로 간다.
  assert.doesNotMatch(beforeBlock(make('market_book')), /정규분포를 따른다고 한다/);
  assert.match(make('market_book'), sideBlock);
});

// ── 표를 본문 끝부분 옆에 두는 배치 ─────────────────────────────────────────────

/** 옆 배치를 켠 채로 만든다(확인 중이라 환경 변수로만 켜진다). */
const buildSide = (stem, meta = {}, options = {}) => {
  const before = process.env.PB_XELATEX_AUTO_TABLE_SIDE;
  process.env.PB_XELATEX_AUTO_TABLE_SIDE = '1';
  try {
    return buildTexSource({ stem, choices: [], question_type: '주관식', meta, score: 4 }, options);
  } finally {
    if (before === undefined) delete process.env.PB_XELATEX_AUTO_TABLE_SIDE;
    else process.env.PB_XELATEX_AUTO_TABLE_SIDE = before;
  }
};
const sideBlock = /\\begin\{minipage\}\[t\]\{0\.\d+\\dimexpr\\linewidth-\\leftskip\\relax\}[\s\S]*\\end\{minipage\}\\hfill\\setbox0\\hbox\{가\}\\raisebox\{\\ht0\}/;
// 글자 수로 줄 수를 어림하는 간단한 셈(한 줄 20자).
const by20 = (lines) => lines.reduce((sum, l) => sum + Math.max(1, Math.ceil(l.length / 20)), 0);

test('옆 배치: 표 높이만큼의 끝 줄들만 옆으로 가고 앞부분은 온 폭에 남는다', () => {
  const lines = [
    '가'.repeat(60),
    '나'.repeat(20),
    '[수식제시]f(12)\\leq g(20)',
    '다'.repeat(40),
  ];
  // 4행 표 → 4×2.2/1.8 ≈ 4.9줄. 끝 세 줄(1+1+2=4줄)이 가장 가깝다.
  const cut = planSideTableCut(lines, 4, by20);
  assert.deepEqual(cut.head, [lines[0]]);
  assert.deepEqual(cut.tail, lines.slice(1));
  assert.deepEqual(cut.tailFrom, [1, 2, 3]);
});

test('옆 배치: 한 줄뿐인 본문은 문장 경계에서 자른다', () => {
  const line = `${'가'.repeat(58)}다. ${'나'.repeat(18)}이다. ${'라'.repeat(17)}하시오.`;
  const cut = planSideTableCut(['[문단]', line, '[문단]'], 2, by20);
  assert.equal(cut.head.at(-1).endsWith('이다.'), true);
  assert.deepEqual(cut.tail, [`${'라'.repeat(17)}하시오.`]);
});

test('옆 배치: 본문이 표보다 짧으면 본문 전체가 옆으로 간다', () => {
  const cut = planSideTableCut(['오른쪽 표는 두 모둠의 평균이다.', '분산을 구하시오.'], 4, by20);
  assert.deepEqual(cut.head, []);
  assert.equal(cut.tail.length, 2);
});

test('옆 배치: 첫 줄부터 두는 방식은 본문 전체가 왼쪽 칸에 들어갈 때만 쓴다', () => {
  const lines = ['가'.repeat(60), '나'.repeat(20), '다'.repeat(40)];
  const top = planSideTableCut(lines, 2, by20, () => true, 'top');
  assert.deepEqual(top.head, []);
  assert.deepEqual(top.tail, lines);
  // 넓은 수식 줄이 있으면 끝부분 옆 방식으로 고른다.
  const mixed = planSideTableCut(['[수식제시]WIDE', ...lines], 2, by20, (line) => !line.includes('WIDE'), 'top');
  assert.equal(mixed.head.length > 0, true);
});

test('옆 배치: 왼쪽 칸보다 넓은 수식이 든 줄은 옆으로 보내지 않는다', () => {
  const lines = ['가'.repeat(30), '[수식제시]WIDE', '나'.repeat(20), '다'.repeat(20)];
  const cut = planSideTableCut(lines, 4, by20, (line) => !line.includes('WIDE'));
  assert.deepEqual(cut.tail, lines.slice(2));
  // 들어갈 자리가 하나도 없으면 옆 배치를 하지 않는다.
  assert.equal(planSideTableCut(['WIDE 이다.'], 4, by20, () => false), null);

  assert.equal(sideLineFits('[수식제시]f(12)\\leq g(20)', 0.61), true);
  // 쉼표 뒤에서는 줄이 바뀐다.
  assert.equal(
    sideLineFits('[수식제시]\\text{P}(b\\leq X\\leq 75)=0.1359, \\text{P}(a-160\\leq Y\\leq b)=0.4332', 0.61),
    true,
  );
  assert.equal(
    sideLineFits('[수식제시]\\text{P}(X=x)={}_{100}\\text{C}_x p^x (1-p)^{100-x} (x=0, 1, 2, \\cdots, 100)', 0.61),
    false,
  );
  // 글 속의 긴 수식도 같다.
  assert.equal(
    sideLineFits('\\text{P}(1\\leq X\\leq 2)+\\text{P}(7\\leq X\\leq 9)=\\text{P}(11\\leq Y\\leq 14)일 때, 값을 구하시오.', 0.61),
    false,
  );
  assert.equal(sideLineFits('\\text{P}(17\\leq X\\leq 18)의 값을 오른쪽 표준정규분포표를 이용하여 구한 것은?', 0.61), true);
  // cases 처럼 묶인 수식은 한글이 들어 있어도 줄이 바뀌지 않는다.
  assert.equal(
    sideLineFits('[수식제시]a_{ij}=\\begin{cases}1 & (i번 버스가 정류장에 정차하는 경우) \\\\ 0 & (정차하지 않는 경우)\\end{cases}', 0.61),
    false,
  );
});

test('옆 배치: 표 폭은 열 수로 정하고, 6열 이상은 옆에 두지 않는다', () => {
  assert.equal(sideTableWidthFraction([['z', 'p'], ['1', '2']]), 0.36);
  assert.equal(sideTableWidthFraction([['a', 'b', 'c']]), 0.45);
  assert.equal(sideTableWidthFraction([['1', '2', '3', '4', '5', '6']]), 0);
});

test('옆 배치: 본문이 "오른쪽 …표" 라고 적으면 끝부분과 표를 나란히 두고 배점도 찍는다', () => {
  const stem = [
    '확률변수 X는 정규분포를 따르고, 확률변수 Y도 정규분포를 따른다. 두 확률변수의 확률밀도함수는 각각 f(x)와 g(x)이다.',
    '[수식제시]f(12)\\leq g(20)',
    `을 만족시키는 m에 대하여 \\text{P}(21\\leq Y\\leq 24)의 최댓값을 오른쪽 표준정규분포표를 이용하여 구한 것은?\n[문단]\n${table}`,
  ].join('\n');
  const tex = buildSide(stem);
  assert.match(tex, sideBlock);
  assert.equal(wrapsRight(tex), false);
  // 표가 아래에 한 번 더 찍히지 않는다(아래 배치와 같은 횟수).
  const count = (s) => (s.match(/0\.3413/g) || []).length;
  assert.equal(count(tex), count(build(stem)));
  // 앞부분 아래에서 시작하는 줄은 본문 문단과 같은 줄 간격 설정 안에서 열고 닫는다
  //   (밖에서 끝내면 앞부분 마지막 줄과의 간격이 본문 줄 간격보다 벌어진다).
  assert.match(
    tex,
    /\\par\{\\setstretch\{1\.53\}[^{}]*\{[^{}]*\}\{[^{}]*\}\\selectfont\\parskip=0pt\\lineskiplimit=0\.4em\\lineskip=0\.8em\\noindent\\begin\{minipage\}\[t\]/,
  );
  assert.match(tex, /\\end\{minipage\}\}\\par\}/);

  // 시험지(문항 번호·배점 표시)에서도 같은 배치이고, 배점은 왼쪽 칸의 끝 줄에 붙는다.
  const before = process.env.PB_XELATEX_AUTO_TABLE_SIDE;
  process.env.PB_XELATEX_AUTO_TABLE_SIDE = '1';
  let paper = '';
  try {
    paper = buildDocumentTexSource(
      [{ id: 'q1', question_uid: 'q1', question_number: '18', stem, choices: [], question_type: '주관식', meta: {} }],
      { paper: 'A4', columns: 2, includeQuestionScore: true, questionScoreByQuestionId: { q1: 4 } },
    );
  } finally {
    if (before === undefined) delete process.env.PB_XELATEX_AUTO_TABLE_SIDE;
    else process.env.PB_XELATEX_AUTO_TABLE_SIDE = before;
  }
  const block = paper.match(sideBlock);
  assert.ok(block, '시험지에서도 옆 배치가 나와야 한다');
  assert.match(block[0], /4\s*점/);
});

test('옆 배치: 저장된 표 위치가 있으면 그 값이 먼저다', () => {
  const stem = `\\text{P}(X\\geq 8)의 값을 오른쪽 표준정규분포표를 이용하여 구한 것은?\n[문단]\n${table}`;
  const stored = buildSide(stem, {
    table_layout: { items: [{ tableKey: 'raw:1', position: 'below-stem', anchor: 'center' }] },
  });
  assert.doesNotMatch(stored, sideBlock);
});

test('옆 배치: 표 뒤에 글이 더 있거나 "오른쪽 좌표" 같은 말이면 평소처럼 둔다', () => {
  const after = buildSide(`오른쪽 표를 보고 물음에 답하시오.\n[문단]\n${table}\n[문단]\n평균을 구하시오.`);
  assert.doesNotMatch(after, sideBlock);
  const notTable = buildSide(`오른쪽 좌표평면을 보고 표를 완성하시오.\n[문단]\n${table}`);
  assert.doesNotMatch(notTable, sideBlock);
});
