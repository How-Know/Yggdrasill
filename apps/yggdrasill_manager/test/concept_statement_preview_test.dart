import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/design_preview/yggdrasill_manager/concept_library/concept_statement_preview_screen.dart';

void main() {
  Future<void> pump(WidgetTester tester, {int design = 0, bool wide = true}) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ConceptStatementPreviewBody(initialDesign: design, initialWide: wide)),
    ));
    await tester.pumpAndSettle();
  }

  for (final design in [0, 1]) {
    for (final wide in [false, true]) {
      testWidgets('${design == 0 ? 'A' : 'B'}안 ${wide ? '넓게' : '좁게'}: 공통 내용과 고른 서술이 넘치지 않고 보인다', (tester) async {
        await pump(tester, design: design, wide: wide);
        expect(find.text('개념 공통 내용 · 모든 서술에 해당'), findsOneWidget);
        expect(find.textContaining('표본공간으로 본 확률'), findsWidgets);
        expect(find.text('이 서술의 출처 2개'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('A안: 서술을 고르면 그 서술만 펼친다', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('statement-pick-0')));
    await tester.pumpAndSettle();
    expect(find.text('서술 · 기본(개념 본문)'), findsOneWidget);
    expect(find.text('이 서술의 출처 1개'), findsOneWidget);
  });

  testWidgets('B안: 다른 카드를 누르면 그 카드만 펼친다', (tester) async {
    await pump(tester, design: 1);
    await tester.tap(find.byKey(const ValueKey('statement-card-1')));
    await tester.pumpAndSettle();
    expect(find.text('이 서술의 출처 1개'), findsOneWidget);
    expect(find.text('이 서술의 출처 2개'), findsNothing);
  });

  testWidgets('창 목업: 서술 고치기·공통 내용·출처·등장 위치가 넘치지 않고 열린다', (tester) async {
    await pump(tester);
    await tester.tap(find.text('서술 더하기'));
    await tester.pumpAndSettle();
    expect(find.text('원문에 조건이 적혀 있나요'), findsOneWidget);
    await tester.tap(find.text('닫기'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('공통 내용 고치기'));
    await tester.pumpAndSettle();
    expect(find.text('개념 공통 내용 고치기'), findsOneWidget);
    await tester.tap(find.text('닫기'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('이 서술의 출처 2개'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('이 서술의 출처 2개'));
    await tester.pumpAndSettle();
    expect(find.text('어느 서술의 출처'), findsWidgets);
    await tester.tap(find.text('닫기'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('등장 위치 더하기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('등장 위치 더하기'));
    await tester.pumpAndSettle();
    expect(find.text('교육과정 판'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
