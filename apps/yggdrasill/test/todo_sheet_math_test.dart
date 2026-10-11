import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mneme_flutter/widgets/pdf/todo_sheet_math.dart';

void main() {
  test('이미 감싼 수식은 유지하고 선형 표기는 인라인 수식으로 감싼다', () {
    expect(
      normalizeTodoSheetMath(r'허수단위 \(i\)와 복소수의 분류'),
      r'허수단위 \(i\)와 복소수의 분류',
    );
    expect(
      normalizeTodoSheetMath(r'$a^x+a^{-x}$의 꼴'),
      r'\(a^x+a^{-x}\)의 꼴',
    );
    expect(
      normalizeTodoSheetMath(r'x \pm \frac{1}{x}'),
      r'\(x \pm \frac{1}{x}\)',
    );
    expect(
      normalizeTodoSheetMath(r'\frac{a^x-a^{-x}}{a^x+a^{-x}} 꼴'),
      r'\(\frac{a^x-a^{-x}}{a^x+a^{-x}}\) 꼴',
    );
    expect(
      normalizeTodoSheetMath(r'$\sqrt{ax}$, $\sqrt{\frac{a}{x}}$ 꼴'),
      r'\(\sqrt{ax}\), \(\sqrt{\frac{a}{x}}\) 꼴',
    );
    expect(normalizeTodoSheetMath('숙제 없음'), '숙제 없음');
    expect(todoSheetMathNeedsPaint(normalizeTodoSheetMath('숙제 없음')), isFalse);
    expect(
      todoSheetMathNeedsPaint(normalizeTodoSheetMath(r'x \pm \frac{1}{x}')),
      isTrue,
    );
  });

  testWidgets('분수는 한 줄 글자보다 위로 쌓인다', (tester) async {
    Future<TodoSheetMathImage> paint(String text) async {
      final image = await tester.runAsync(
        () => rasterizeTodoSheetMath(
          text: text,
          fontSize: 14,
          bold: false,
          color: const Color(0xFF1C1C1C),
          maxWidth: 220,
        ),
      );
      expect(image, isNotNull);
      return image!;
    }

    final plain = await paint('x');
    final source = await paint(r'\frac{1}{x}');
    final fraction = await paint(r'\(\frac{1}{x}\)');
    expect(plain.width, lessThan(40), reason: 'plain ${plain.width}x${plain.height}');
    expect(
      fraction.height,
      greaterThan(source.height + 2),
      reason:
          'source ${source.width}x${source.height} fraction ${fraction.width}x${fraction.height}',
    );
    expect(fraction.width, lessThan(source.width * 0.6));
  });

  testWidgets('알림장 제목 크기의 분수는 줄 칸을 크게 넘지 않는다', (tester) async {
    final image = await tester.runAsync(
      () => rasterizeTodoSheetMath(
        text: normalizeTodoSheetMath(
          r'\frac{a^x-a^{-x}}{a^x+a^{-x}} 꼴의 식의 값 구하기',
        ),
        fontSize: 10.2,
        bold: true,
        color: const Color(0xFF1C1C1C),
        maxWidth: 240,
      ),
    );
    expect(image, isNotNull);
    expect(image!.height, lessThanOrEqualTo(14 + 3 + 6),
        reason: 'height ${image.height}');
  });
}
