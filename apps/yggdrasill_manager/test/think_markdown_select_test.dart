import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/think/think_markdown.dart';

void main() {
  testWidgets('코드 블록이 글 맨 끝이거나 아직 닫히지 않아도(답변 생성 중) 깨지지 않는다', (tester) async {
    const cases = [
      '앞 문단\n\n```',
      '앞 문단\n\n```text\n# 제목\n- 항목\n',
      '```text\nUNCLOSED_CODE\n',
      '앞 문단\n\n```\nCLOSED_LAST\n```',
    ];
    for (final data in cases) {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: ThinkMarkdown(data)))));
      expect(tester.takeException(), isNull, reason: data);
    }
    expect(find.textContaining('CLOSED_LAST'), findsOneWidget);
    await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SingleChildScrollView(child: ThinkMarkdown('```text\nUNCLOSED_CODE\n')))));
    expect(find.textContaining('UNCLOSED_CODE'), findsOneWidget, reason: '닫히지 않은 코드도 내용은 보인다');
  });

  testWidgets('코드 블록(회색 상자)은 여백이나 짧은 줄 오른쪽에서 끌기 시작해도 안의 글자가 선택된다', (tester) async {
    SelectedContent? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectionArea(
            onSelectionChanged: (c) => selected = c,
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                ThinkMarkdown('앞 문단입니다.\n\n```\nCODE_LINE_ONE ${'긴 줄 ' * 80}\nCODE_LINE_TWO\n```\n\n뒤 문단입니다.'),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final code = find.textContaining('CODE_LINE_ONE', findRichText: true);
    expect(code, findsOneWidget);
    final gray = tester.getRect(find.ancestor(of: code, matching: find.byType(DecoratedBox)).first);
    expect(tester.getRect(code).right, lessThanOrEqualTo(gray.right), reason: '긴 줄은 상자 안에서 접힌다');

    Future<String> drag(Offset from, Offset to) async {
      final gesture = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
      await tester.pump();
      await gesture.moveTo(Offset.lerp(from, to, 0.3)!);
      await tester.pump();
      await gesture.moveTo(to);
      await tester.pump();
      await gesture.up();
      await gesture.removePointer();
      await tester.pumpAndSettle();
      return selected?.plainText ?? '';
    }

    final fromPadding = await drag(gray.topLeft + const Offset(4, 4), gray.bottomRight - const Offset(4, 4));
    expect(fromPadding, contains('CODE_LINE_ONE'));
    expect(fromPadding, contains('CODE_LINE_TWO'));
    expect(fromPadding, isNot(contains('뒤 문단')));

    final backwards = await drag(gray.bottomRight - const Offset(8, 16), gray.topLeft + const Offset(14, 14));
    expect(backwards, contains('CODE_LINE_TWO'));
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
