import test from 'node:test';
import assert from 'node:assert/strict';

import { buildDocumentTexSource } from '../src/problem_bank/render_engine/xelatex_v2/template.js';

function makeQuestion(num, answer, explanation = '') {
  return {
    id: `q-${num}`,
    question_uid: `q-${num}`,
    question_number: String(num),
    stem: '문항',
    equations: [],
    choices: [],
    objective_choices: [],
    allow_objective: false,
    allow_subjective: true,
    export_mode: 'subjective',
    export_answer: answer,
    explanation,
    meta: {},
  };
}

test('quick-answer table renders gray Pretendard number cells, fixed fraction-ready height, top text, and inline explanation heading', () => {
  const tex = buildDocumentTexSource([
    makeQuestion(1, '1) 1, 2, 4, 8 2) 1, 2, 3, 4, 6, 12 3) 1, 2, 4 4) 4'),
    makeQuestion(2, '○'),
    makeQuestion(3, 'x = \\frac{1}{2}'),
    makeQuestion(4, 'x = -2'),
  ], {
    profile: 'assignment',
    titlePageTopText: '2026학년도 대학수학능력시험 문제지',
    includeAcademyLogo: true,
    academyLogoPath: 'C:/tmp/academy-logo.png',
    academyName: '정현수학교습소',
    includeQuickAnswer: true,
    includeExplanation: true,
  });

  // 문항번호는 마침표 없이 연한 회색 별도 셀 + Pretendard 폰트로 조판된다.
  assert.match(tex, /\\textcolor\{black!16\}\{\\vrule width \\YggQaNumWd height \\YggQaRowHt depth 0pt\}/);
  assert.match(tex, /\\YggPretendardRegular\\YggPretendardRegularHangul\\bfseries\\fontsize\{9\.5pt\}\{11pt\}\\selectfont #1/);
  assert.match(tex, /\\YggQaAutoItem\{2\}/);
  assert.match(tex, /\\YggQaAutoItem\{4\}\{\$\\textstyle x = -2\$\}/);

  // 분수를 커버할 수 있는 고정 최소 행 높이(24.5pt)와 \YggSmallFrac 사용.
  assert.match(tex, /\\setlength\{\\YggQaMinRowHt\}\{24\.5pt\}/);
  assert.match(tex, /\\YggSmallFrac\{1\}\{2\}/);

  // 빠른정답 위에 제목페이지 상단 문구가 기본으로 표시되고, 표 바로 아래에 '해설' 타이틀이 이어진다.
  assert.match(tex, /2026학년도 대학수학능력시험 문제지/);
  assert.match(tex, /\\fontsize\{16pt\}\{20pt\}\\selectfont\\color\{black!62\}\\YggPretendardRegular\\YggPretendardRegularHangul 2026학년도 대학수학능력시험 문제지/);
  assert.match(tex, /\\YggPretendard\\YggPretendardHangul\\fontsize\{16pt\}\{20pt\}\\selectfont\\bfseries 빠른정답\}\\par\\nopagebreak\n\\vspace\{6pt\}\\nopagebreak/);
  assert.doesNotMatch(tex, /빠른정답\}\\par\\nopagebreak\n\\vspace\{3\.5pt\}\\nopagebreak\n\{\\color\{black!55\}\\hrule/);
  assert.match(tex, /\\YggPretendard\\YggPretendardHangul\\fontsize\{16pt\}\{20pt\}\\selectfont\\bfseries 해설/);
  assert.doesNotMatch(tex, /\\columnbreak/);
  assert.match(tex, /\\setbox2=\\hbox\{\\copy1\\textbf\{\[정답\]\}\\hspace\{0\.45em\}\}/);
  assert.match(tex, /\\bfseries\\boldmath /);

  // 정답·해설 부록은 1쪽부터 다시 시작하고, 과제형 본문과 같은 홀짝 하단 문구를 쓴다.
  assert.match(tex, /\\clearpage\n\\setcounter\{page\}\{1\}/);
  assert.match(tex, /\\fancyfoot\[LO\].*정현수학교습소/);
  assert.match(tex, /\\fancyfoot\[RE\].*2026학년도 대학수학능력시험 문제지/);
});

test('quick-answer top text can be overridden via coverPageTexts.quickAnswerTopText', () => {
  const tex = buildDocumentTexSource([
    makeQuestion(1, 'x = 1'),
  ], {
    titlePageTopText: '기본 상단 문구',
    coverPageTexts: {
      quickAnswerTopText: '사용자 지정 빠른정답 문구',
    },
    includeQuickAnswer: true,
    includeExplanation: false,
  });

  assert.match(tex, /사용자 지정 빠른정답 문구/);
});

test('dense flow mode (maxQuestionsPerPage=99) packs columns by measured height with 9pt set gap and 32pt question gap', () => {
  const indepMeta = {
    delivery_unit: {
      delivery_type: 'independent_item',
      set_id: 'set-1',
      common_stem: '다음 식을 간단히 하시오.',
    },
  };
  const q1 = { ...makeQuestion(1, '1'), meta: indepMeta };
  const q2 = { ...makeQuestion(2, '2'), meta: indepMeta };
  const q3 = { ...makeQuestion(3, '3'), meta: indepMeta };
  const q4 = makeQuestion(4, '4');
  const q5 = makeQuestion(5, '5');

  const layoutMeta = {};
  const tex = buildDocumentTexSource([q1, q2, q3, q4, q5], {
    profile: 'assignment',
    columns: 2,
    maxQuestionsPerPage: 99,
    disableAutoLabels: true,
    measuredSlotPlan: {
      // Col height on title page is 420 - 8 - 10(safety) = 402pt.
      // q1(head)=140, q2=80 (140+9+80=229), q3=80 (229+9+80=318),
      // q4=100 (318+32+100=450 > 402 -> overflows to right column!),
      // q5=120 (100+32+120=252 <= 402 -> stays in right column with q4).
      heightsPt: [140, 80, 80, 100, 120],
      normalColumnHeightPt: 460,
      titleColumnHeightPt: 420,
    },
    layoutMeta,
  });

  assert.equal(layoutMeta.slotPlacement?.source, 'dense_flow');
  assert.deepEqual(layoutMeta.slotPlacement?.pageColumnCounts, [
    { left: 3, right: 2 },
  ]);
  // 독립형 세트 내부(공통발문↔1번, 1번↔2번, 2번↔3번)는 9pt 간격.
  assert.match(tex, /\\vspace\{9pt\}/);
  assert.match(tex, /\\par\\nointerlineskip\\vspace\{9pt\}/);
  // 일반 문항(4번↔5번)은 32pt 기본 여백.
  assert.match(tex, /\\par\\nointerlineskip\\vspace\{32pt\}/);
  // 자연 높이 minipage[t]{\linewidth} 스택으로 조판되어 고정 슬롯 겹침이 없다.
  assert.match(tex, /\\noindent\\begin\{minipage\}\[t\]\{\\linewidth\}/);
});

test('A4 dense flow uses 8pt after the common stem, 12pt between set items, and 36pt between questions', () => {
  const indepMeta = {
    delivery_unit: {
      delivery_type: 'independent_item',
      set_id: 'set-1',
      common_stem: '다음 식을 간단히 하시오.',
    },
  };
  const q1 = { ...makeQuestion(1, '1'), meta: indepMeta };
  const q2 = { ...makeQuestion(2, '2'), meta: indepMeta };
  const q3 = { ...makeQuestion(3, '3'), meta: indepMeta };
  const q4 = makeQuestion(4, '4');
  const q5 = makeQuestion(5, '5');

  const layoutMeta = {};
  const tex = buildDocumentTexSource([q1, q2, q3, q4, q5], {
    profile: 'assignment',
    paper: 'A4',
    columns: 2,
    maxQuestionsPerPage: 99,
    disableAutoLabels: true,
    measuredSlotPlan: {
      // A4 세트 이어짐 간격 12pt, 일반 간격 36pt.
      // q1+12+q2+12+q3 = 324, 324+36+100 = 460 > 402 이므로 4번은 오른쪽 단.
      heightsPt: [140, 80, 80, 100, 120],
      normalColumnHeightPt: 460,
      titleColumnHeightPt: 420,
    },
    layoutMeta,
  });

  assert.equal(layoutMeta.slotPlacement?.source, 'dense_flow');
  assert.deepEqual(layoutMeta.slotPlacement?.pageColumnCounts, [
    { left: 3, right: 2 },
  ]);
  assert.match(tex, /\\vspace\{8pt\}/);
  assert.match(tex, /\\par\\nointerlineskip\\vspace\{12pt\}/);
  assert.match(tex, /\\par\\nointerlineskip\\vspace\{36pt\}/);
  assert.doesNotMatch(tex, /\\par\\nointerlineskip\\vspace\{9pt\}/);
  assert.doesNotMatch(tex, /\\par\\nointerlineskip\\vspace\{32pt\}/);
});

