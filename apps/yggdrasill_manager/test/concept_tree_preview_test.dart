import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/design_preview/yggdrasill_manager/concept_library/concept_tree_preview_mock.dart';
import 'package:yggdrasill_manager/screens/design_preview/yggdrasill_manager/concept_library/concept_tree_preview_screen.dart';

List<String> _names(List<MockConceptGroup> groups) => [for (final g in groups) for (final c in g.concepts) c.name];

void main() {
  final power = kMockLibrary.first.children[1];
  final gcd = kMockLibrary.first.children.first.children[3];

  test('수학 순서: 정의 → 표현 → 주의 → 성질 → 방법, 같은 유형 안은 저장 순서', () {
    expect(_names(orderConcepts(power.concepts, MockOrder.math)), [
      '거듭제곱',
      '거듭제곱의 밑',
      '거듭제곱의 지수',
      '지수가 1인 거듭제곱의 표기',
      '같은 수나 문자의 곱을 거듭제곱으로 나타내기',
      '같은 수를 곱하는 것과 더하는 것의 구별',
      '1의 거듭제곱',
    ]);
    expect(_names(orderConcepts(power.concepts, MockOrder.flow)).first, '거듭제곱');
  });

  test('주제 묶음: 정의마다 묶고 다른 판 정의는 같은 묶음, 묶을 정의가 없으면 그 밖', () {
    final groups = orderConcepts(gcd.concepts, MockOrder.topic);
    expect([for (final g in groups) g.title], ['공약수', '최대공약수', '서로소', '공배수', '최소공배수']);
    expect(_names([groups[1]]), [
      '최대공약수',
      '최대공약수',
      '공약수와 최대공약수의 약수',
      '소인수분해를 이용하여 최대공약수 구하기',
    ]);
    final divisor = kMockLibrary.first.children.first.children[1];
    expect([for (final g in orderConcepts(divisor.concepts, MockOrder.topic)) g.title], ['인수', '그 밖의 개념']);
  });

  for (var design = 0; design < 3; design++) {
    for (final order in MockOrder.values) {
      testWidgets('Preview $design · ${order.name}: 넘침 없이 그린다', (tester) async {
        tester.view.physicalSize = const Size(1500, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: ConceptTreePreviewBody(initialDesign: design, initialOrder: order)),
        ));
        await tester.pumpAndSettle();
        expect(find.text('개념 라이브러리'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('유형 거르기·찾기는 칩을 숨기지 않고 흐리게 둔다', (tester) async {
    tester.view.physicalSize = const Size(1500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: ConceptTreePreviewBody())));
    await tester.pumpAndSettle();
    final before = find.text('소수').evaluate().length;
    await tester.tap(find.text('방법').first);
    await tester.enterText(find.byType(TextField), '최대');
    await tester.pumpAndSettle();
    expect(find.text('소수').evaluate().length, before);
    expect(tester.takeException(), isNull);
  });
}
