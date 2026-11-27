import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/arithmetic/model_lab/natural_addition_lab.dart';

void main() {
  testWidgets('378+245는 0.383점, 3.710초로 계산된다', (tester) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: NaturalAdditionLab(onClose: () {})),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('addition-result')), findsOneWidget);
    expect(find.textContaining('0.383점'), findsOneWidget);
    expect(find.textContaining('3.710초'), findsOneWidget);

    await tester.tap(find.text('프리셋'));
    await tester.pumpAndSettle();
    expect(find.textContaining('234+53'), findsOneWidget);
    expect(find.textContaining('0.215점'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('출제'), 120, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('출제'));
    await tester.pumpAndSettle();
    expect(find.textContaining('공식 교육과정은 미등록입니다'), findsOneWidget);
    expect(find.textContaining('6, 6, 6, 6, 6'), findsOneWidget);
    expect(find.textContaining('4+5 · 허용'), findsOneWidget);
    expect(find.textContaining('7+8 · 제외'), findsOneWidget);
  });
}
