// 채점 엔진 단위 테스트.
//   node --experimental-strip-types grading_test.ts
// (Deno가 있으면: deno run grading_test.ts)

import {
  compareAnswers,
  gradingMode,
  normalizeMathLinear,
  parseQuantity,
} from './grading.ts';

let pass = 0;
let fail = 0;

function eq(actual: unknown, expected: unknown, label: string) {
  const a = JSON.stringify(actual);
  const b = JSON.stringify(expected);
  if (a === b) {
    pass += 1;
  } else {
    fail += 1;
    console.log(`FAIL ${label}\n  expected ${b}\n  actual   ${a}`);
  }
}

function grade(kind: string, correct: string, student: string) {
  const o = compareAnswers(kind, correct, student);
  return {
    correct: o.correct,
    flags: [...o.flags].sort(),
    unitAi: o.needsUnitAi,
    equivAi: o.needsEquivAi,
  };
}

// ---------------------------------------------------------------- 분류(mode)
eq(gradingMode('objective', '③'), 'auto', 'mode: objective');
eq(gradingMode('image', '[image]'), 'self', 'mode: image');
eq(gradingMode('subjective', '(1) 시속 5 km (2) 12분'), 'self', 'mode: 세트형');
eq(gradingMode('subjective', '(가) 10 (나) 9 (다) 8'), 'self', 'mode: 빈칸');
eq(
  gradingMode('subjective', '\\begin{cases} x+y=12 \\\\ y=3x \\end{cases}'),
  'self',
  'mode: 연립',
);
eq(gradingMode('subjective', '풀이 174쪽'), 'self', 'mode: 풀이 참조');
eq(gradingMode('subjective', 'a=2, b=3'), 'self', 'mode: 복수 라벨');
eq(
  gradingMode('subjective', 'x절편: 2, y절편: 4'),
  'self',
  'mode: 절편 복수 라벨',
);
eq(
  gradingMode('subjective', '최댓값: 2, 최솟값: -2'),
  'self',
  'mode: 최댓값/최솟값',
);
eq(gradingMode('subjective', 'x=3'), 'auto', 'mode: 단일 라벨은 auto');
eq(gradingMode('subjective', '\\frac{1}{2}'), 'auto', 'mode: 분수 auto');
eq(gradingMode('subjective', '54마리'), 'auto', 'mode: 단위 auto');
eq(gradingMode('subjective', '제2사분면'), 'auto', 'mode: 한글 auto');

// ---------------------------------------------------------------- 객관식
eq(grade('objective', '③', '3').correct, true, 'obj: ③=3');
eq(grade('objective', '①, ③', '3,1').correct, true, 'obj: 복수 순서무관');
eq(grade('objective', '③', '4').correct, false, 'obj: 오답');

// ---------------------------------------------------------------- n제곱근
eq(normalizeMathLinear('\\sqrt[3]{8}'), '√[3](8)', 'nthroot: 정규화');
eq(grade('subjective', '\\sqrt[3]{8}', '2').correct, true, 'nthroot: ∛8=2');
eq(grade('subjective', '2', '√[3](8)').correct, true, 'nthroot: 학생이 ∛ 입력');
eq(grade('subjective', '-2', '√[3](-8)').correct, true, 'nthroot: 음수 홀수근');
eq(grade('subjective', '2', '√[4](16)').correct, true, 'nthroot: 네제곱근');
eq(grade('subjective', '2', '√[4](-16)').correct, false, 'nthroot: 짝수근 음수 불가');
eq(grade('subjective', '\\sqrt[3]{2}', '√[3](2)').correct, true, 'nthroot: 문자열 일치');

// ---------------------------------------------------------------- 기본 동치
eq(grade('subjective', '\\frac{1}{2}', '1/2').correct, true, 'frac: 1/2');
eq(
  grade('subjective', '\\frac{1}{2}', '2/4'),
  { correct: true, flags: ['form_differs'], unitAi: false, equivAi: false },
  'frac: 2/4 → 정답+표기다름',
);
eq(grade('subjective', '8', '2^3').flags, ['form_differs'], 'pow: 2^3=8 표기다름');
eq(grade('subjective', '8', '2^3').correct, true, 'pow: 2^3=8');
eq(grade('subjective', '2\\sqrt{3}', '√12').correct, true, 'sqrt: 2√3=√12');
eq(grade('subjective', '-\\frac{7}{4}', '-1.75').correct, true, 'frac↔소수');
eq(grade('subjective', 'x=3', '3').correct, true, 'label: x=3 ↔ 3');
eq(grade('subjective', '3', 'x=3').correct, true, 'label: 역방향');
eq(grade('subjective', '5', '6').correct, false, '오답 숫자');
eq(grade('subjective', '1.2', '12').correct, false, '소수점 보존');
eq(grade('subjective', '0.5', '1/2').correct, true, '소수↔분수');
eq(grade('subjective', '2x+1', '1+2x').correct, true, '식: 교환');
eq(grade('subjective', '2x+1', '2x-1').correct, false, '식: 오답');
eq(grade('subjective', '5n+1', '5n+1').correct, true, '식: 동일');
eq(grade('subjective', '(1000x+1300)원', '1000x+1300원').correct, true, '식+단위');

// ---------------------------------------------------------------- 목록
eq(grade('subjective', '3, -1', '-1, 3').correct, true, '목록: 순서무관');
eq(grade('subjective', '1, 2, 4', '1,2').correct, false, '목록: 누락');
eq(
  grade('subjective', 'x=1 또는 x=3', '3, 1').correct,
  true,
  '목록: 또는+라벨',
);
eq(
  grade('subjective', '-1 < k < 1 또는 k > 1', '-1<k<1 또는 k>1').correct,
  true,
  '부등식: 그대로',
);
eq(
  grade('subjective', 'x\\le -1 또는 x\\ge \\frac{7}{3}', 'x≤-1 또는 x≥7/3')
    .correct,
  true,
  '부등식: latex↔선형',
);
eq(grade('subjective', 'x\\ge 2', '2≤x').correct, true, '부등식: 거울');
eq(grade('subjective', 'x\\ge 2', 'x>2').correct, false, '부등식: 등호 차이');

// ---------------------------------------------------------------- ±
eq(grade('subjective', '\\pm 2', '2, -2').correct, false, '±: 목록과는 구분'); // ±2는 하나의 답
eq(grade('subjective', '3\\pm\\sqrt{2}', '3±√2').correct, true, '±: 동일');
eq(grade('subjective', '3\\pm\\sqrt{2}', '3-√2, 3+√2').correct, false, '±: 전개는 목록');

// ---------------------------------------------------------------- 단위
eq(
  grade('subjective', '240 m', '240'),
  { correct: true, flags: ['unit_hint'], unitAi: false, equivAi: false },
  '단위: 숫자만 → 정답+힌트',
);
eq(grade('subjective', '240 m', '240m').correct, true, '단위: 동일');
eq(
  grade('subjective', '10m', '1000cm'),
  { correct: true, flags: [], unitAi: true, equivAi: false },
  '단위: 환산동치 → AI 판정',
);
eq(
  grade('subjective', '10m', '10cm'),
  { correct: true, flags: ['unit_caution'], unitAi: false, equivAi: false },
  '단위: 숫자같고 단위다름 → 주의',
);
eq(grade('subjective', '10m', '1001cm').correct, false, '단위: 환산 불일치');
eq(grade('subjective', '54마리', '54').flags, ['unit_hint'], '단위: 마리 생략');
eq(grade('subjective', '54마리', '54마리').correct, true, '단위: 마리');
eq(
  grade('subjective', '54마리', '54개'),
  { correct: true, flags: ['unit_caution'], unitAi: false, equivAi: false },
  '단위: 개수단위 교체 → 주의',
);
eq(grade('subjective', '12분', '720초').unitAi, true, '단위: 분↔초 AI');
eq(grade('subjective', '3시간', '180분').unitAi, true, '단위: 시간↔분 AI');
eq(grade('subjective', '28800원', '28800').flags, ['unit_hint'], '단위: 원');
eq(grade('subjective', '55 \\textdegree C', '55°C').correct, true, '단위: °C 문자');

// ---------------------------------------------------------------- 순환소수/특수
eq(
  grade('subjective', '1.\\dot{2}', '1.2\u0307').correct,
  true,
  '순환소수: dot ↔ 결합점',
);
eq(grade('subjective', '1.\\dot{2}', '1.2').correct, false, '순환소수: 점 없으면 오답');
eq(grade('subjective', '\\bigcirc', '○').correct, true, '○ 답');
eq(grade('subjective', '3.14', 'π').correct, false, 'π는 3.14가 아님');
eq(grade('subjective', '2π', '2\\pi').correct, true, 'π 표기');

// ---------------------------------------------------------------- 한글
eq(grade('subjective', '제2사분면', '제2사분면').correct, true, '한글: 동일');
eq(grade('subjective', '제2사분면', '2사분면').equivAi, true, '한글: 불일치 → AI');
eq(grade('subjective', '해는 없다.', '해가 없다').equivAi, true, '한글: 조사 차이 → AI');
eq(grade('subjective', '유', '유').correct, true, '한글: 한 글자');

// ---------------------------------------------------------------- quantity
eq(parseQuantity(normalizeMathLinear('240 m'))?.unit, 'm', 'qty: m');
eq(parseQuantity(normalizeMathLinear('12분'))?.dim, 'time', 'qty: 분');
eq(parseQuantity(normalizeMathLinear('4가지'))?.dim, 'count:가지', 'qty: 가지');
eq(parseQuantity(normalizeMathLinear('\\frac{1}{2}'))?.value, 0.5, 'qty: 분수');

console.log(`\n${pass} passed, ${fail} failed`);
if (fail > 0) process.exit(1);
