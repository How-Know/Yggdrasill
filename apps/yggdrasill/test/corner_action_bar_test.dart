import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mneme_flutter/widgets/corner_action_bar.dart';

void main() {
  testWidgets('학생↔시간 메뉴 전환 때 유리 막대를 새로 만들지 않는다', (tester) async {
    var menu = 1;
    late StateSetter setMenu;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            setMenu = setState;
            return Stack(
              children: [SharedCornerActionBarHost(menuIndex: menu)],
            );
          },
        ),
      ),
    );

    sharedCornerActionBar.bind(
      menuIndex: 1,
      width: 189,
      visible: true,
      builder: (_) => const Text('학생 추가'),
    );
    await tester.pumpAndSettle();
    final shellBefore = tester.element(find.byType(AnimatedContainer));
    expect(find.text('학생 추가'), findsOneWidget);

    sharedCornerActionBar.bind(
      menuIndex: 2,
      width: 230,
      visible: true,
      builder: (_) => const Text('시간 추가'),
    );
    sharedCornerActionBar.unbindMenu(1);
    setMenu(() => menu = 2);
    await tester.pumpAndSettle();

    expect(find.text('학생 추가'), findsNothing);
    expect(find.text('시간 추가'), findsOneWidget);
    expect(tester.element(find.byType(AnimatedContainer)), same(shellBefore));

    setMenu(() => menu = 0);
    await tester.pumpAndSettle();
    expect(tester.element(find.byType(AnimatedContainer)), same(shellBefore));
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      0,
    );

    sharedCornerActionBar.unbindMenu(1);
    sharedCornerActionBar.unbindMenu(2);
  });
}
