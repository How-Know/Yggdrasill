import { assertEquals } from 'jsr:@std/assert@1';
import {
  attachParticles,
  collectNameSets,
  formatMockSolution,
  mergeNameSets,
  unifyIntentMark,
  uprightNames,
} from './textbook_mock_format.ts';

const problem = (text: string, others: string[] = []) => uprightNames(text, collectNameSets([text, ...others]), 'problem');
const solution = (text: string, problemTexts: string[] = []) =>
  uprightNames(text, mergeNameSets(collectNameSets(problemTexts), collectNameSets([text])), 'solution');

Deno.test("출제의도 표기: 첫머리 표기만 '[출제의도]' 로 맞춘다", () => {
  assertEquals(unifyIntentMark('출제의도 : 지수법칙을 이용하여 식의 값을 구할 수 있는가?\n\n$2^3=8$'), '[출제의도] 지수법칙을 이용하여 식의 값을 구할 수 있는가?\n\n$2^3=8$');
  assertEquals(unifyIntentMark('출제의도:극한값을 구한다.'), '[출제의도] 극한값을 구한다.');
  assertEquals(unifyIntentMark('<출제의도> 극한값을 구한다.'), '[출제의도] 극한값을 구한다.');
  assertEquals(unifyIntentMark('[출제의도] : 극한값을 구한다.'), '[출제의도] 극한값을 구한다.');
  assertEquals(unifyIntentMark('[ 출제 의도 ]극한값을 구한다.'), '[출제의도] 극한값을 구한다.');
  assertEquals(unifyIntentMark('  출제의도 :\n풀이'), '  [출제의도]\n풀이');
});

Deno.test('출제의도 표기: 이미 맞는 글과 출제의도가 없는 글은 그대로 둔다', () => {
  const ok = '[출제의도] 극한값을 구한다.\n\n풀이';
  assertEquals(unifyIntentMark(ok), ok);
  assertEquals(unifyIntentMark(unifyIntentMark('출제의도 : 극한값')), '[출제의도] 극한값');
  const plain = '$f(x)=x^2$에서\n\n출제의도 : 가운데 줄은 건드리지 않는다.';
  assertEquals(unifyIntentMark(plain), plain);
  assertEquals(unifyIntentMark(''), '');
  assertEquals(unifyIntentMark(null), '');
});

Deno.test('본문: 머리말이 붙은 점 이름과 도형 이름을 곧은 글자로 감싼다', () => {
  assertEquals(problem('선분 AB의 길이는?'), '선분 \\text{AB}의 길이는?');
  assertEquals(problem('점 P에서 직선 AB에 내린 수선의 발을 H라 하자.'), '점 \\text{P}에서 직선 \\text{AB}에 내린 수선의 발을 \\text{H}라 하자.');
  assertEquals(problem('두 점 A(a, b), B(b, a)가 곡선 위에 있다.'), '두 점 \\text{A}(a, b), \\text{B}(b, a)가 곡선 위에 있다.');
  assertEquals(
    problem("두 초점이 F(c, 0), F'(-c, 0)(c>0)이고 장축의 길이가 12인 타원"),
    "두 초점이 \\text{F}(c, 0), \\text{F}'(-c, 0)(c>0)이고 장축의 길이가 12인 타원",
  );
  assertEquals(problem('수선의 발을 각각 H_1, H_2라 하자.'), '수선의 발을 각각 \\text{H}_1, \\text{H}_2라 하자.');
  assertEquals(problem('두 점 A_n, B_n이 다음 조건을 만족시킨다.'), '두 점 \\text{A}_n, \\text{B}_n이 다음 조건을 만족시킨다.');
  assertEquals(problem('삼각형 ABC의 넓이'), '삼각형 \\text{ABC}의 넓이');
  assertEquals(problem('사각뿔 A-BCDE가 있다.'), '사각뿔 \\text{A}-\\text{BCDE}가 있다.');
  assertEquals(problem('두 정사각형 ABCD, EFGH를 밑면으로 하는'), '두 정사각형 \\text{ABCD}, \\text{EFGH}를 밑면으로 하는');
  assertEquals(problem('(단, O는 원점이다.)'), '(단, \\text{O}는 원점이다.)');
});

Deno.test('본문: 명령 안의 이름 묶음(\\overline{AB}, \\angle ABC)도 감싼다', () => {
  assertEquals(problem('\\overline{AB}=2\\sqrt{2}'), '\\overline{\\text{AB}}=2\\sqrt{2}');
  assertEquals(problem('\\overline{OH_1}=3'), '\\overline{\\text{OH}_1}=3');
  assertEquals(problem('\\overline{AD}:\\overline{DB}=3:2'), '\\overline{\\text{AD}}:\\overline{\\text{DB}}=3:2');
  assertEquals(problem('\\angle APO=\\frac{\\pi}{2}'), '\\angle \\text{APO}=\\frac{\\pi}{2}');
  assertEquals(problem('\\cos(\\angle N_1ON_2)=\\frac{3}{5}'), '\\cos(\\angle \\text{N}_1\\text{ON}_2)=\\frac{3}{5}');
  assertEquals(problem('\\overrightarrow{AB}\\cdot\\overrightarrow{AC}=0'), '\\overrightarrow{\\text{AB}}\\cdot\\overrightarrow{\\text{AC}}=0');
});

Deno.test('본문: 이름표(상자 A, 과목 B, A 지점)도 곧은 글자로 감싼다', () => {
  assertEquals(problem('두 상자 A, B가 있다. 상자 A에는 공이 8개'), '두 상자 \\text{A}, \\text{B}가 있다. 상자 \\text{A}에는 공이 8개');
  assertEquals(problem('과목 A 와 과목 B 중 하나를 선택'), '과목 \\text{A} 와 과목 \\text{B} 중 하나를 선택');
  assertEquals(problem('세 명의 학생 A, B, C에게'), '세 명의 학생 \\text{A}, \\text{B}, \\text{C}에게');
  assertEquals(problem('A 지점에서 출발하여 B 지점까지'), '\\text{A} 지점에서 출발하여 \\text{B} 지점까지');
});

Deno.test('본문: 머리말 없이 다시 나온 점 이름도 같은 문항에서 점으로 쓰였으면 감싼다', () => {
  assertEquals(
    problem('점 P에서 원에 그은 접선의 접점을 Q라 하자. P가 움직일 때 선분 PQ의 길이'),
    '점 \\text{P}에서 원에 그은 접선의 접점을 \\text{Q}라 하자. \\text{P}가 움직일 때 선분 \\text{PQ}의 길이',
  );
  // 선지에서 다시 나온 이름은 본문에서 모은 이름으로 판단한다.
  const sets = collectNameSets(['삼각형 ABC에서 옳은 것은?']);
  assertEquals(uprightNames('AB=AC', sets, 'problem'), '\\text{AB}=\\text{AC}');
});

Deno.test('본문: 원 O, 구 S, 사건 A, 넓이 A, 최댓값 M 은 기울인 글자 그대로 둔다', () => {
  assertEquals(
    problem('세 점을 지나는 원을 O라 하자. 원 O 위의 점 P에 대하여'),
    '세 점을 지나는 원을 O라 하자. 원 O 위의 점 \\text{P}에 대하여',
  );
  const sphere = '중심이 O이고 반지름의 길이가 5인 구 S가 있다. 구 S 위의 점 P';
  assertEquals(problem(sphere), '중심이 \\text{O}이고 반지름의 길이가 5인 구 S가 있다. 구 S 위의 점 \\text{P}');
  const area = '선분 OP로 둘러싸인 부분의 넓이를 A, 선분 PQ로 둘러싸인 부분의 넓이를 B라 할 때, B-A의 값은?';
  assertEquals(
    problem(area),
    '선분 \\text{OP}로 둘러싸인 부분의 넓이를 A, 선분 \\text{PQ}로 둘러싸인 부분의 넓이를 B라 할 때, B-A의 값은?',
  );
  const events = '두 사건 A, B에 대하여 \\text{P}(A|B)=\\frac{1}{2}';
  assertEquals(problem(events), events);
  const max = '점 P에 대하여 최댓값을 M, 최솟값을 m이라 할 때, M+m의 값';
  assertEquals(problem(max), '점 \\text{P}에 대하여 최댓값을 M, 최솟값을 m이라 할 때, M+m의 값');
  const curve = '곡선 C: x^2-xy+y^2+k=0 위의 점 A에서의 접선과 곡선 C 위의 점 B에서의 접선';
  assertEquals(problem(curve), '곡선 C: x^2-xy+y^2+k=0 위의 점 \\text{A}에서의 접선과 곡선 C 위의 점 \\text{B}에서의 접선');
  // 'S는 원점 …' 의 S 는 원점 이름이 아니다(원점 이름은 O).
  assertEquals(problem('도형 S는 원점 O를 중심으로 하는 원이다.'), '도형 S는 원점 \\text{O}를 중심으로 하는 원이다.');
  assertEquals(problem('S는 원점 O를 중심으로 하는 원이다.'), 'S는 원점 \\text{O}를 중심으로 하는 원이다.');
});

Deno.test('본문: 식 안에 홀로 선 글자(\\sin A, A=2B, \\overline{X}, P(X))는 그대로 둔다', () => {
  const sin = '삼각형 ABC에서 \\sin A:\\sin C=8:5일 때';
  assertEquals(problem(sin), '삼각형 \\text{ABC}에서 \\sin A:\\sin C=8:5일 때');
  const sample = '표본평균을 \\overline{X}라 할 때 \\text{P}(\\overline{X}\\geq 2)';
  assertEquals(problem(sample), sample);
  const variable = '확률변수 X가 정규분포를 따를 때 \\text{P}(X\\leq 3)';
  assertEquals(problem(variable), variable);
  const func = '함수 F(x)에 대하여 F(0)의 값';
  assertEquals(problem(func), func);
  const set = '집합 X=\\{1, 2, 3\\}에 대하여 함수 f: X \\to X';
  assertEquals(problem(set), set);
  const comb = '{}_{5}C_{2}+{}_{3}H_{4}';
  assertEquals(problem(comb), comb);
});

Deno.test('본문: 이미 감싼 이름과 마커·표는 건드리지 않고, 두 번 돌려도 같다', () => {
  const done = '점 \\text{A}에서 선분 \\text{BC}에 내린 수선의 발을 \\text{H}라 하자.';
  assertEquals(problem(done), done);
  const mixed = '\\angle\\text{APO}=\\frac{\\pi}{2}인 점 P';
  assertEquals(problem(mixed), '\\angle\\text{APO}=\\frac{\\pi}{2}인 점 \\text{P}');
  const table = '[표시작]\n\\begin{tabular}{|c|c|}\n\\hline\nz & \\text{P}(0\\leq Z\\leq z) \\\\\n\\hline\n\\end{tabular}\n[표끝]';
  assertEquals(problem(table), table);
  const blank = '점 P의 좌표는 [[공백:3]]이다.\n[그림]\n[문단]';
  assertEquals(problem(blank), '점 \\text{P}의 좌표는 [[공백:3]]이다.\n[그림]\n[문단]');
  const once = problem("점 F'을 지나는 직선이 선분 PF와 만나는 점을 Q라 하자.");
  assertEquals(once, "점 \\text{F}'을 지나는 직선이 선분 \\text{PF}와 만나는 점을 \\text{Q}라 하자.");
  assertEquals(problem(once), once);
});

Deno.test('해설: 수식 밖의 이름은 $\\mathrm{…}$ 로, 수식 안의 이름은 \\mathrm{…} 로 감싼다', () => {
  assertEquals(solution('선분 AC의 중점을 O라 하면'), '선분 $\\mathrm{AC}$의 중점을 $\\mathrm{O}$라 하면');
  assertEquals(solution('$\\overline{AB}=8,\\ \\overline{BC}=6$이므로'), '$\\overline{\\mathrm{AB}}=8,\\ \\overline{\\mathrm{BC}}=6$이므로');
  assertEquals(solution('삼각형 P′H₂Q의 넓이'), "삼각형 $\\mathrm{P}'\\mathrm{H}_{2}\\mathrm{Q}$의 넓이");
  assertEquals(solution('두 점 P, Q의 시각 $t$에서의 위치'), '두 점 $\\mathrm{P}$, $\\mathrm{Q}$의 시각 $t$에서의 위치');
  assertEquals(solution('두 점 $A_n$, $B_n$의 좌표'), '두 점 $\\mathrm{A}_n$, $\\mathrm{B}_n$의 좌표');
  assertEquals(solution('$\\angle ABC=\\frac{\\pi}{2}$'), '$\\angle \\mathrm{ABC}=\\frac{\\pi}{2}$');
});

Deno.test('해설: 옆에 붙은 수식에는 이어 붙이고 $$ 를 만들지 않는다', () => {
  assertEquals(solution('곡선 $C$가 점 A$(5,\\,7)$을 지나므로'), '곡선 $C$가 점 $\\mathrm{A}(5,\\,7)$을 지나므로');
  assertEquals(solution('점 $(1, 2)$P를 지나는'), '점 $(1, 2)$P를 지나는');
  assertEquals(solution('점 P $(1, 2)$를 지나는'), '점 $\\mathrm{P}$ $(1, 2)$를 지나는');
});

Deno.test('해설: 문제에서 점으로 쓴 이름은 해설에서 머리말 없이 나와도 감싼다', () => {
  const stem = '점 P에서 선분 AB에 내린 수선의 발을 H라 하자.';
  assertEquals(solution('P는 원 위의 점이므로 $\\overline{PH}=4$', [stem]), '$\\mathrm{P}$는 원 위의 점이므로 $\\overline{\\mathrm{PH}}=4$');
  // 문제에서 기울여 쓴 이름(구 S)은 해설에서도 그대로 둔다.
  const sphere = '구 S 위의 점 P';
  assertEquals(solution('구 $S$의 중심은 점 O이고', [sphere]), '구 $S$의 중심은 점 $\\mathrm{O}$이고');
  assertEquals(solution('점 X가 나타내는 도형 $S$는 원점 O를 중심으로 하는 원', [sphere]), '점 $\\mathrm{X}$가 나타내는 도형 $S$는 원점 $\\mathrm{O}$를 중심으로 하는 원');
});

Deno.test('해설: 이미 감싼 이름·식 안의 변수는 그대로 두고, 두 번 돌려도 같다', () => {
  const done = '$\\overline{\\mathrm{PH}_{1}}=3$이고 $\\angle\\mathrm{P\'H}_{2}\\mathrm{Q}=\\frac{\\pi}{2}$';
  assertEquals(solution(done), done);
  const vars = '$A=\\int_{0}^{1}f(x)\\,dx$, $B-A=\\frac{1}{4}$, $M=52$, ${}_{6}C_{2}=15$';
  assertEquals(solution(vars), vars);
  const constant = '$f(x)=x^{2}+C$ (단, $C$는 적분상수)';
  assertEquals(solution(constant), constant);
  const once = solution('점 A에서 선분 BC에 내린 수선의 발을 H라 하면 $\\overline{AH}=3$');
  assertEquals(once, '점 $\\mathrm{A}$에서 선분 $\\mathrm{BC}$에 내린 수선의 발을 $\\mathrm{H}$라 하면 $\\overline{\\mathrm{AH}}=3$');
  assertEquals(solution(once), once);
});

Deno.test('해설: 수식 구분자 짝이 맞지 않는 글은 바꾸지 않는다', () => {
  const broken = '선분 AB의 길이는 $\\overline{AB}=3 이다.';
  assertEquals(solution(broken), broken);
});

Deno.test('이름 모음: 곧게 찍을 글자와 기울여 찍을 글자를 따로 모은다', () => {
  const sets = collectNameSets(['중심이 O인 구 S 위의 두 점 P, Q와 삼각형 ABC', '넓이를 T라 하자']);
  assertEquals([...sets.upright].sort().join(''), 'ABCOPQ');
  assertEquals([...sets.italic].sort().join(''), 'ST');
  const merged = mergeNameSets(sets, collectNameSets(['수선의 발을 H라 하자']));
  assertEquals([...merged.upright].sort().join(''), 'ABCHOPQ');
  assertEquals([...merged.italic].sort().join(''), 'ST');
});

const attach = (text: string) => attachParticles(text, 'problem');

Deno.test('조사 붙여 쓰기(본문): 수식 뒤에 띄어 쓴 조사를 붙인다', () => {
  assertEquals(attach('함수 f(x)=x^{3}-8x+7 에 대하여 \\lim_{h\\to 0}\\frac{f(2+h)-f(2)}{h} 의 값은?'), '함수 f(x)=x^{3}-8x+7에 대하여 \\lim_{h\\to 0}\\frac{f(2+h)-f(2)}{h}의 값은?');
  assertEquals(attach('과목 \\text{A} 와 과목 \\text{B} 에 대한 선호도'), '과목 \\text{A}와 과목 \\text{B}에 대한 선호도');
  assertEquals(attach('과목 \\text{A} 를 선택한 학생'), '과목 \\text{A}를 선택한 학생');
  assertEquals(attach('다항함수 f(x) 가 모든 실수 x 에 대하여'), '다항함수 f(x)가 모든 실수 x에 대하여');
  assertEquals(attach('첫째항이 8 이고 공비가 0 이 아닌 등비수열 \\{a_n\\} 이 있다.'), '첫째항이 8이고 공비가 0이 아닌 등비수열 \\{a_n\\}이 있다.');
  assertEquals(attach('\\cos\\theta=-\\frac{1}{5} 일 때, k 인 실수 a 의 값은 5 이다.'), '\\cos\\theta=-\\frac{1}{5}일 때, k인 실수 a의 값은 5이다.');
  assertEquals(attach('x=1, x=e 로 둘러싸인 부분, 구간 [0, 1] 에서 연속'), 'x=1, x=e로 둘러싸인 부분, 구간 [0, 1]에서 연속');
  assertEquals(attach('(단, Z 가 표준정규분포를 따를 때 0.95 로 계산한다.)'), '(단, Z가 표준정규분포를 따를 때 0.95로 계산한다.)');
  assertEquals(attach('점 \\text{P} 에서의 접선, x 축과의 교점, 30° 의 각'), '점 \\text{P}에서의 접선, x축과의 교점, 30°의 각');
});

Deno.test('조사 붙여 쓰기(본문): 수 뒤의 단위와 x축·y절편도 붙인다', () => {
  assertEquals(attach('학생 16 명을 대상으로 조사하였다. 과목 A를 선택한 학생은 9 명, 나머지는 7 명이다.'), '학생 16명을 대상으로 조사하였다. 과목 A를 선택한 학생은 9명, 나머지는 7명이다.');
  assertEquals(attach('학생 16 명 중에서 임의로 3 명을 선택할 때, 선택한 3 명의 학생'), '학생 16명 중에서 임의로 3명을 선택할 때, 선택한 3명의 학생');
  assertEquals(attach('8 개의 공, 4 번 반복, 5 장의 카드, 3 가지, 2 배, 3 번째로'), '8개의 공, 4번 반복, 5장의 카드, 3가지, 2배, 3번째로');
  assertEquals(attach('곡선과 x 축 및 두 직선, x 축에 수직인 평면, y 절편은 3'), '곡선과 x축 및 두 직선, x축에 수직인 평면, y절편은 3');
});

Deno.test('조사 붙여 쓰기(본문): 조사가 아닌 낱말 앞의 띄어쓰기는 그대로 둔다', () => {
  for (const keep of [
    '곡선 y=f(x) 위의 점 \\text{P}',
    '평면 \\beta 위로의 정사영',
    '실수 x 전체의 집합',
    '두 점 \\text{A}, \\text{B} 사이의 거리',
    '3 이상의 자연수 n, 5 이하이면, 2 이상이다.',
    '모든 실수 x 및 y',
    '방정식 f(x)=0 가지고',
    '실근의 개수는 2 개수',
    'k 배수, 3 명제, x 좌표평면, a 이차함수, b 도형, c 가로, d 의자',
    '[그림] 과 같이',
    '빈칸 [[공백:3]] 에 알맞은 수',
    'x=1\n의 값',
    '함수 f(x)가 있다.',
    '',
  ]) assertEquals(attach(keep), keep);
});

Deno.test('조사 붙여 쓰기(본문): 두 번 돌려도 같다', () => {
  const once = attach('학생 16 명을 대상으로 과목 \\text{A} 와 과목 \\text{B} 에 대한 선호도를 조사하였다.');
  assertEquals(once, '학생 16명을 대상으로 과목 \\text{A}와 과목 \\text{B}에 대한 선호도를 조사하였다.');
  assertEquals(attach(once), once);
});

Deno.test('조사 붙여 쓰기(해설): 닫는 $ 뒤의 조사만 붙인다', () => {
  const sol = (text: string) => attachParticles(text, 'solution');
  assertEquals(sol('$f(1)=3$ 이므로 $a=2$ 에서 $b=1$ 이다.'), '$f(1)=3$이므로 $a=2$에서 $b=1$이다.');
  assertEquals(sol('$x$ 축과 만나는 점은 $3$ 개이다.'), '$x$축과 만나는 점은 $3$개이다.');
  // 여는 $ 앞뒤, 조사가 아닌 낱말, 줄이 바뀐 곳은 그대로
  for (const keep of [
    '$n=0$ 또는 $n=1$',
    '곡선 $y=f(x)$ 위의 점',
    '값은 $3$ 이상이다.',
    '따라서 $a=1$\n이므로 $b=2$',
    '그러므로 $ 이므로',
    '$f(1)=3$이므로 $a=2$',
  ]) assertEquals(sol(keep), keep);
});

Deno.test('해설 표기: 출제의도·이름·조사를 한 번에 맞추고 무엇을 바꿨는지 알려 준다', () => {
  const names = collectNameSets(['점 A에서 선분 BC에 내린 수선의 발을 H라 하자.']);
  const out = formatMockSolution('출제의도 : 삼각형의 넓이를 구한다.\n\n점 A 에서 $\\overline{BC}=4$ 이므로', names);
  assertEquals(out.text, '[출제의도] 삼각형의 넓이를 구한다.\n\n점 $\\mathrm{A}$에서 $\\overline{\\mathrm{BC}}=4$이므로');
  assertEquals([out.intentChanged, out.namesChanged, out.spacingChanged], [true, true, true]);
  const again = formatMockSolution(out.text, names);
  assertEquals(again.text, out.text);
  assertEquals([again.intentChanged, again.namesChanged, again.spacingChanged], [false, false, false]);
});

Deno.test('곧은 이름: 조건 번호 (가)·(나) 바로 뒤의 이름도 감싼다', () => {
  const text = '세 학생 A, B, C를 포함한 6명의 학생이 있다.\n[박스시작]\n(가) A와 B는 이웃한다.\n(나) B와 C는 이웃하지 않는다.\n[박스끝]';
  assertEquals(
    problem(text),
    '세 학생 \\text{A}, \\text{B}, \\text{C}를 포함한 6명의 학생이 있다.\n[박스시작]\n(가) \\text{A}와 \\text{B}는 이웃한다.\n(나) \\text{B}와 \\text{C}는 이웃하지 않는다.\n[박스끝]',
  );
  // 식을 닫는 괄호 뒤의 글자는 이름으로 보지 않는다.
  assertEquals(problem('두 점 A, B에 대하여 f(2) A는'), '두 점 \\text{A}, \\text{B}에 대하여 f(2) A는');
});
