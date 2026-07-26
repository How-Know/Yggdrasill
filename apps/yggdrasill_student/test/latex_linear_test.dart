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
  });
}
