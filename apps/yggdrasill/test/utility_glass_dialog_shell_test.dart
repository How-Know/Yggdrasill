import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mneme_flutter/widgets/utility_glass_dialog_shell.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('fitContent shrinks to a short child and stays at max otherwise', (
    tester,
  ) async {
    await _open(
      tester,
      fitContent: true,
      maxHeight: 400,
      child: const SizedBox(height: 40, child: Text('짧은내용')),
    );
    expect(tester.getSize(find.byType(UtilityGlassDialogShell)).height, lessThan(200));
    expect(find.text('짧은내용'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await _open(
      tester,
      fitContent: false,
      maxHeight: 400,
      child: const Center(child: Text('짧은내용')),
    );
    expect(tester.getSize(find.byType(UtilityGlassDialogShell)).height, 400);
  });

  testWidgets('tall content scrolls and the footer stays visible', (tester) async {
    await _open(
      tester,
      fitContent: true,
      maxHeight: 360,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            child: CustomScrollView(
              shrinkWrap: true,
              slivers: [
                SliverToBoxAdapter(
                  child: Column(
                    children: [
                      for (var i = 0; i < 12; i++)
                        SizedBox(height: 80, child: Text('항목 $i')),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const Text('하원버튼'),
        ],
      ),
    );

    final shell = tester.getRect(find.byType(UtilityGlassDialogShell));
    expect(shell.height, greaterThan(300));
    expect(shell.height, lessThanOrEqualTo(360));
    expect(find.text('하원버튼'), findsOneWidget);
    expect(tester.getRect(find.text('하원버튼')).bottom, lessThanOrEqualTo(shell.bottom));
    expect(tester.getRect(find.text('항목 11')).top, greaterThan(shell.bottom));

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -700));
    await tester.pumpAndSettle();

    final lastItem = tester.getRect(find.text('항목 11'));
    expect(lastItem.top, greaterThanOrEqualTo(shell.top));
    expect(lastItem.bottom, lessThanOrEqualTo(shell.bottom));
    expect(tester.getRect(find.text('하원버튼')).bottom, lessThanOrEqualTo(shell.bottom));
  });
}

Future<void> _open(
  WidgetTester tester, {
  required bool fitContent,
  required double maxHeight,
  required Widget child,
}) async {
  await tester.pumpWidget(const MaterialApp(home: Scaffold()));
  final context = tester.element(find.byType(Scaffold));
  showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.all(24),
        child: UtilityGlassDialogShell(
          title: '하원',
          icon: Icons.logout_rounded,
          fitContent: fitContent,
          maxHeight: maxHeight,
          preferredWidth: 400,
          onClose: () => Navigator.of(dialogContext).pop(),
          child: child,
        ),
      );
    },
  );
  await tester.pumpAndSettle();
}
