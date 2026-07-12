// 수식 에디터 직렬화/파싱 라운드트립 테스트.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:yggdrasill_student/widgets/math_expression_editor.dart';

void main() {
  testWidgets('수식 에디터: 구조 입력 → 선형 직렬화', (tester) async {
    String? latest;
    final key = GlobalKey<MathExpressionEditorState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MathExpressionEditor(
            key: key,
            onChanged: (v) => latest = v,
          ),
        ),
      ),
    );

    final editor = key.currentState!;
    // 1과 2분의 1 → "1(1)/(2)" 형태가 아닌: 1 + 분수(1/2)
    editor.insertText('1');
    editor.insertText('+');
    editor.insertFraction(); // 커서가 분자로 이동
    editor.insertText('1');
    // 분모로 이동은 UI 터치 기반이므로 여기서는 직렬화 형태만 확인
    expect(latest, '1+(1)/()');

    editor.clearAll();
    editor.insertSqrt();
    editor.insertText('2');
    expect(latest, '√(2)');
    expect(editor.toLinear(), '√(2)');

    // 거듭제곱: 직전 원자(x)를 밑으로 흡수하고 지수 슬롯으로 이동
    editor.clearAll();
    editor.insertText('x');
    editor.insertPower();
    editor.insertText('3');
    expect(latest, 'x^(3)');

    // 거듭제곱: 밑이 없으면 빈 밑 네모부터 (단일 문자 밑은 괄호 생략)
    editor.clearAll();
    editor.insertPower();
    editor.insertText('2');
    expect(latest, '2^()');

    // n제곱근: 인덱스 슬롯부터 입력
    editor.clearAll();
    editor.insertNthRoot();
    editor.insertText('3');
    expect(latest, '√[3]()');

    // 순환소수 점 토글
    editor.clearAll();
    editor.insertText('0.15');
    editor.insertRepeatingDot();
    expect(latest, '0.15\u0307'); // 0.1 뒤 5 위에 순환점
  });

  testWidgets('수식 에디터: 기존 답 파싱 라운드트립', (tester) async {
    const cases = [
      '(3)/(4)+√(12)-x^(2)',
      '√[3](8)+2',
      '(x+1)^(2)=9',
      '0.15\u0307',
      '10cm^(2)',
    ];
    for (final linear in cases) {
      final key = GlobalKey<MathExpressionEditorState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MathExpressionEditor(
              key: key,
              initialLinear: linear,
              onChanged: (_) {},
            ),
          ),
        ),
      );
      expect(key.currentState!.toLinear(), linear, reason: linear);
    }
  });
}
