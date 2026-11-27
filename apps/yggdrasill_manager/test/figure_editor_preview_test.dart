import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/design_preview/yggdrasill_manager/figure_engine/figure_editor_preview_screen.dart';
import 'package:yggdrasill_manager/screens/think/think_style.dart';

Future<void> _pumpAt(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const MaterialApp(home: FigureEditorPreviewScreen()));
  await tester.pump();
}

Future<void> _tap(WidgetTester tester, String label) async {
  final finder = find.text(label);
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

String _valueOf(WidgetTester tester, String label) {
  final row = find.ancestor(of: find.text(label), matching: find.byType(Row)).first;
  return tester.widgetList<Text>(find.descendant(of: row, matching: find.byType(Text))).last.data!;
}

void main() {
  for (final size in const [Size(1200, 800), Size(1600, 900)]) {
    testWidgets('${size.width.toInt()}×${size.height.toInt()} 에서 넘침 없이 그림과 크기 칸을 보인다', (tester) async {
      await _pumpAt(tester, size);
      expect(tester.takeException(), isNull);
      expect(find.byType(Math), findsWidgets);
      expect(find.text('크기와 자리'), findsOneWidget);
      await _tap(tester, '문제 안에서 보기');
      for (final position in ['본문 오른쪽', '선지 아래', '본문 아래']) {
        await _tap(tester, position);
        expect(tester.takeException(), isNull);
      }
    });
  }

  testWidgets('양식을 바꾸면 표의 크기대로 도형만 다시 그린다', (tester) async {
    await _pumpAt(tester, const Size(1600, 900));
    final mock = _valueOf(tester, '도형 배율');
    expect(_valueOf(tester, '표에서 정한 너비'), '17.5 글자');
    await _tap(tester, '과제');
    expect(_valueOf(tester, '표에서 정한 너비'), '13.0 글자');
    expect(_valueOf(tester, '도형 배율'), isNot(mock));
    expect(tester.takeException(), isNull);
  });

  testWidgets('이 그림만 따로 정하면 희귀 케이스로 표시하고, 다른 양식은 표의 크기 그대로다', (tester) async {
    await _pumpAt(tester, const Size(1600, 900));
    await _tap(tester, '이 그림만 따로 정함');
    expect(find.widgetWithText(ThinkBadge, '희귀 케이스'), findsOneWidget);
    expect(find.text('이 그림만 정한 너비'), findsOneWidget);
    await _tap(tester, '내신 (B4)');
    expect(find.widgetWithText(ThinkBadge, '희귀 케이스'), findsNothing);
    expect(_valueOf(tester, '표에서 정한 너비'), '16.0 글자');
  });

  testWidgets('글자를 끌면 그 글자의 미세 이동만 바뀐다', (tester) async {
    await _pumpAt(tester, const Size(1600, 900));
    expect(_valueOf(tester, '고른 글자'), '없음');
    await tester.drag(find.byType(Math).first, const Offset(24, 12));
    await tester.pump();
    expect(_valueOf(tester, '고른 글자'), isNot('없음'));
    expect(tester.takeException(), isNull);
  });
}
