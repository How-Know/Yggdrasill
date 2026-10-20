import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/design_preview/yggdrasill_manager/textbook_review/textbook_review_preview_screen.dart';

Future<void> _pumpAt(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const MaterialApp(home: TextbookReviewPreviewScreen()));
  await tester.pump();
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

Future<void> _tapListItem(WidgetTester tester, String label) =>
    _tapVisible(tester, find.text(label, skipOffstage: false).first);

Future<void> _drainSnackBars(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
  }
  await tester.pumpAndSettle();
}

ElevatedButton _button(WidgetTester tester, String label) => tester.widget<ElevatedButton>(
      find.ancestor(of: find.text(label), matching: find.byWidgetPredicate((w) => w is ElevatedButton)).first,
    );

void main() {
  for (final size in const [Size(1200, 800), Size(1280, 800)]) {
    testWidgets('${size.width.toInt()}×${size.height.toInt()} 에서 넘침 없이 단계 7개와 첫 결정 항목을 보인다', (tester) async {
      await _pumpAt(tester, size);
      expect(tester.takeException(), isNull);
      for (final title in ['적재 확인', '해설 전사', 'AI 독립 풀이', '대조·판정', '렌더 검수', '개념서', '마감']) {
        expect(find.text(title), findsWidgets);
      }
      expect(find.text('무엇이 문제인가'), findsOneWidget);
      expect(find.text('어떻게 고칠까'), findsOneWidget);
      expect(find.text('제안대로 반영'), findsOneWidget);
      expect(tester.getTopLeft(find.text('무엇이 문제인가')).dy, lessThan(size.height));
    });
  }

  testWidgets('제안대로 반영하면 채점 정답이 바뀌고 결정 기록이 쌓인다', (tester) async {
    await _pumpAt(tester, const Size(1280, 800));
    await _tapVisible(tester, find.text('제안대로 반영'));
    expect(find.text('수동 보호'), findsOneWidget);
    expect(find.text('방금'), findsOneWidget);
    expect(find.textContaining('채점 정답 24 → 12'), findsOneWidget);
    await _drainSnackBars(tester);
  });

  testWidgets('제안 뒤 값이 바뀐 항목은 제안대로 반영을 막는다', (tester) async {
    await _pumpAt(tester, const Size(1280, 800));
    await _tapListItem(tester, '필수 문제 6');
    expect(find.textContaining('옛 값 기준 제안'), findsOneWidget);
    expect(_button(tester, '제안대로 반영').onPressed, isNull);
  });

  testWidgets('직접 고치기는 빈 값을 막고, 저장하면 수동 보호로 표시한다', (tester) async {
    await _pumpAt(tester, const Size(1280, 800));
    await _tapListItem(tester, '쏙쏙 개념 익히기 2');
    await _tapVisible(tester, find.text('직접 고치기').last);

    final answerField = find.widgetWithText(TextField, '채점 정답');
    await tester.enterText(answerField, '');
    await _tapVisible(tester, find.text('저장'));
    expect(find.text('채점 정답을 입력하세요.'), findsOneWidget);

    await tester.enterText(answerField, '③');
    await _tapVisible(tester, find.text('저장'));
    expect(find.textContaining('채점 정답 ④ → ③'), findsOneWidget);
    expect(find.text('수동 보호'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _drainSnackBars(tester);
  });
}
