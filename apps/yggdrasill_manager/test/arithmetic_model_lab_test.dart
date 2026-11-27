import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/arithmetic/model_lab/arithmetic_model_lab.dart';

void main() {
  testWidgets('연산 모델 시뮬레이터는 예시 점수를 보이고 운영 발행 버튼은 잠겨 있다', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: ArithmeticModelLab())));
    await tester.pumpAndSettle();

    expect(find.text('연산 모델'), findsOneWidget);
    await tester.tap(find.text('시뮬레이터'));
    await tester.pumpAndSettle();
    expect(find.textContaining('66.7'), findsWidgets);
    expect(find.textContaining('63.3'), findsWidgets);

    await tester.tap(find.text('기준 시간'));
    await tester.pumpAndSettle();
    expect(find.textContaining('880.0'), findsWidgets);
    expect(find.textContaining('12.0%'), findsWidgets);

    await tester.tap(find.text('설명'));
    await tester.pumpAndSettle();
    expect(find.textContaining('연산 비용은 그 연산 한 번의 작업량'), findsOneWidget);

    await tester.tap(find.text('설정'));
    await tester.pumpAndSettle();
    final publishFinder = find.widgetWithText(ElevatedButton, '새 버전으로 발행');
    await tester.ensureVisible(publishFinder);
    await tester.pumpAndSettle();
    final publish = tester.widget<ElevatedButton>(publishFinder);
    expect(publish.onPressed, isNull);
  });
}
