import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_student/services/latex_linear.dart';

void main() {
  group('latexToLinear', () {
    test('빈 입력', () {
      expect(latexToLinear(''), '');
      expect(latexToLinear('   '), '');
    });

    test('다항식 — 지수 중괄호 제거', () {
      expect(latexToLinear('3x^{2}+2x-1'), '3x^2+2x-1');
      expect(latexToLinear('x^{2}-4'), 'x^2-4');
    });

    test('여러 글자 지수는 괄호 유지', () {
      expect(latexToLinear('2^{10}'), '2^(10)');
      expect(latexToLinear('x^{2x+1}'), 'x^(2x+1)');
    });

    test('분수 — VLM 폴백과 동일한 (분자)/(분모) 표기', () {
      expect(latexToLinear(r'\frac{2}{3}'), '(2)/(3)');
      expect(latexToLinear(r'\dfrac{x+1}{2}'), '(x+1)/(2)');
      expect(latexToLinear(r'-\frac{1}{2}'), '-(1)/(2)');
    });

    test('제곱근', () {
      expect(latexToLinear(r'2\sqrt{3}'), '2√(3)');
      expect(latexToLinear(r'\sqrt{x+1}'), '√(x+1)');
      expect(latexToLinear(r'\sqrt[3]{8}'), '3√(8)');
    });

    test('중첩 구조', () {
      expect(latexToLinear(r'\frac{\sqrt{2}}{2}'), '(√(2))/(2)');
      expect(latexToLinear(r'\frac{x^{2}}{3}'), '(x^2)/(3)');
    });

    test('등호·객관식 답', () {
      expect(latexToLinear('x=3'), 'x=3');
      expect(latexToLinear('4'), '4');
    });

    test('기호 명령 치환', () {
      expect(latexToLinear(r'2\times3'), '2*3');
      expect(latexToLinear(r'2\cdot3'), '2*3');
      expect(latexToLinear(r'\pi r^{2}'), 'πr^2');
      expect(latexToLinear(r'x\le5'), 'x≤5');
      expect(latexToLinear(r'\pm2'), '±2');
    });

    test('\\left \\right 구분자 처리', () {
      expect(latexToLinear(r'\left(x+1\right)^{2}'), '(x+1)^2');
    });

    test('모르는 명령은 이름 보존 (sin, log 등)', () {
      expect(latexToLinear(r'\sin x'), 'sinx');
      expect(latexToLinear(r'\log_{2}8'), 'log_28');
    });

    test('공백·간격 명령 제거', () {
      expect(latexToLinear(r'1\,234'), '1234');
      expect(latexToLinear('2 + 3'), '2+3');
    });

    group('집합 표기', () {
      test('한 줄 집합 — 중괄호 보존', () {
        expect(latexToLinear(r'\left\{1,2,3\right\}'), '{1,2,3}');
        expect(latexToLinear(r'\{1,2,3\}'), '{1,2,3}');
      });

      test('집합 연산 기호', () {
        expect(latexToLinear(r'A\cup B'), 'A∪B');
        expect(latexToLinear(r'A\cap B'), 'A∩B');
        expect(latexToLinear(r'2\in A'), '2∈A');
        expect(latexToLinear(r'3\notin B'), '3∉B');
        expect(latexToLinear(r'A\subset B'), 'A⊂B');
        expect(latexToLinear(r'\varnothing'), '∅');
        expect(latexToLinear(r'\emptyset'), '∅');
      });

      test('조건제시법 — \\mid 는 세로줄', () {
        expect(latexToLinear(r'\left\{x\mid x>0\right\}'), '{x|x>0}');
      });

      test('수 체계 기호', () {
        expect(latexToLinear(r'x\in\mathbb{R}'), 'x∈ℝ');
        expect(latexToLinear(r'\mathbb{N}'), 'ℕ');
      });
    });

    group('세로 나열(연립·세로 집합) 환경', () {
      // MyScript 가 왼쪽 중괄호만 있는 필기를 케이스 구조로 내보내는 형태.
      test('matrix — 행을 쉼표로 잇고 중괄호 균형을 맞춘다', () {
        expect(
          latexToLinear(r'\left\{\begin{matrix}x+y=1\\x-y=3\end{matrix}\right.'),
          '{x+y=1,x-y=3}',
        );
      });

      test('세로로 쓴 집합 원소가 복원된다', () {
        expect(
          latexToLinear(r'\left\{\begin{matrix}1\\2\\3\end{matrix}\right.'),
          '{1,2,3}',
        );
      });

      test('array — 열 정렬 인자는 버린다', () {
        expect(
          latexToLinear(
              r'\left\{\begin{array}{l}x+y=1\\x-y=3\end{array}\right.'),
          '{x+y=1,x-y=3}',
        );
      });

      test('cases — 왼쪽 중괄호가 표기에 포함된다', () {
        expect(
          latexToLinear(r'\begin{cases}x+y=1\\x-y=3\end{cases}'),
          '{x+y=1,x-y=3}',
        );
      });

      test('여러 열은 행을 세미콜론으로 구분한다', () {
        expect(
          latexToLinear(r'\begin{matrix}1&2\\3&4\end{matrix}'),
          '1,2;3,4',
        );
      });

      test('환경 안의 분수·지수도 변환된다', () {
        expect(
          latexToLinear(
              r'\left\{\begin{matrix}\frac{1}{2}\\x^{2}\end{matrix}\right.'),
          '{(1)/(2),x^2}',
        );
      });
    });

    test('\\left \\right 짝 맞추기', () {
      expect(latexToLinear(r'\left(x+1\right.'), '(x+1)');
      expect(latexToLinear(r'\left[1,2\right]'), '[1,2]');
    });
  });

  group('linearToLatex', () {
    test('빈 입력', () {
      expect(linearToLatex(''), '');
      expect(linearToLatex('   '), '');
    });

    test('다항식 지수', () {
      expect(linearToLatex('3x^2+2x-1'), '3x^{2}+2x-1');
      expect(linearToLatex('2^(10)'), '2^{10}');
    });

    test('분수', () {
      expect(linearToLatex('(2)/(3)'), r'\frac{2}{3}');
      expect(linearToLatex('-(1)/(2)'), r'-\frac{1}{2}');
      expect(linearToLatex('(x+1)/(2)'), r'\frac{x+1}{2}');
    });

    test('중첩 분수·루트', () {
      expect(linearToLatex('(√(2))/(2)'), r'\frac{\sqrt{2}}{2}');
      expect(linearToLatex('(x^2)/(3)'), r'\frac{x^{2}}{3}');
    });

    test('제곱근', () {
      expect(linearToLatex('√(x+1)'), r'\sqrt{x+1}');
      expect(linearToLatex('2√(3)'), r'2\sqrt{3}');
      expect(linearToLatex('√[3](8)'), r'\sqrt[3]{8}');
    });

    test('일반 괄호는 보존', () {
      expect(linearToLatex('(x+1)^(2)'), r'\left(x+1\right)^{2}');
    });

    test('순환소수 — 점 표기', () {
      expect(linearToLatex('0.3\u0307'), r'0.\dot{3}');
    });

    test('기호 치환', () {
      expect(linearToLatex('x≤5'), r'x\le 5');
      expect(linearToLatex('±2'), r'\pm 2');
      expect(linearToLatex('πr^2'), r'\pi r^{2}');
    });

    test('한글은 text 로 감싼다', () {
      expect(linearToLatex('제2사분면'), r'\text{제}2\text{사분면}');
    });

    test('등호·복수 답', () {
      expect(linearToLatex('x=3'), 'x=3');
      expect(linearToLatex('1,2'), '1,2');
    });

    test('집합 기호 역변환 — 2D 표시용', () {
      expect(linearToLatex('{1,2,3}'), r'\{1,2,3\}');
      expect(linearToLatex('A∪B'), r'A\cup B');
      expect(linearToLatex('2∈A'), r'2\in A');
      expect(linearToLatex('∅'), r'\varnothing ');
      expect(linearToLatex('x∈ℝ'), r'x\in \mathbb{R}');
    });
  });
}
