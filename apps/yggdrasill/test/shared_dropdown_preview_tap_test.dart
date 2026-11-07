import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mneme_flutter/widgets/shared_dropdown_dialog.dart';

void main() {
  testWidgets('열린 드롭다운 위에서 미리보기를 누르면 닫고 바로 실행한다', (tester) async {
    var previews = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Align(
                alignment: Alignment.topRight,
                child: SharedDropdownDialog(
                  panelMaxWidth: 160,
                  panelBuilder: (context, controller) =>
                      const SizedBox(width: 120, height: 48, child: Text('양식')),
                  childBuilder: (context, controller) => TextButton(
                    onPressed: controller.toggle,
                    child: const Text('양식·출력'),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.bottomRight,
                child: SharedDropdownHitPassThrough(
                  child: TextButton(
                    onPressed: () {
                      closeOpenSharedDropdowns();
                      previews += 1;
                    },
                    child: const Text('미리보기'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.text('양식·출력'));
    await tester.pumpAndSettle();
    expect(find.text('양식'), findsOneWidget);

    await tester.tap(find.text('미리보기'));
    await tester.pump();
    expect(previews, 1);
    expect(find.text('양식'), findsNothing);
  });
}
