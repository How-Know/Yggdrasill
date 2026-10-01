import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/think/think_message_tile.dart';
import 'package:yggdrasill_manager/screens/think/think_tree_panel.dart';
import 'package:yggdrasill_manager/services/think/think_controller.dart';
import 'package:yggdrasill_manager/services/think/think_models.dart';

Widget _host(Widget child, {double width = 240}) => MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: width, height: 640, child: child),
        ),
      ),
    );

void main() {
  testWidgets('좁은 폭에서도 트리 패널이 섹션·폴더·발췌를 그린다', (tester) async {
    final c = ThinkController.instance;
    c.conversations = [
      const ThinkConversation(id: 'c1', title: '정리 안 한 아주 긴 제목의 대화입니다 정말 길어요', status: 'active', messageCount: 4),
      const ThinkConversation(id: 'c2', title: '일차함수 순서', status: 'active', messageCount: 2),
    ];
    c.treeNodes = const [
      ThinkTreeNode(id: 'f1', kind: ThinkTreeKind.folder, title: '수학 커리큘럼', sortOrder: 0, version: 1),
      ThinkTreeNode(
        id: 'n2',
        kind: ThinkTreeKind.conversation,
        title: '',
        sortOrder: 0,
        version: 1,
        parentId: 'f1',
        conversationId: 'c2',
      ),
      ThinkTreeNode(
        id: 'e1',
        kind: ThinkTreeKind.excerpt,
        title: '기울기 먼저 가르치기',
        summary: '그래프보다 변화율을 먼저',
        sortOrder: 1,
        version: 1,
        parentId: 'f1',
        conversationId: 'c2',
        sourceMessageIds: ['m1', 'm2'],
      ),
    ];

    await tester.pumpWidget(_host(ThinkTreePanel(onNewConversation: () {}, onCollapse: () {})));
    await tester.pump();

    expect(find.text('정리 안 됨'), findsOneWidget);
    expect(find.text('주제'), findsOneWidget);
    expect(find.text('수학 커리큘럼'), findsOneWidget);
    expect(find.text('일차함수 순서'), findsOneWidget);
    expect(find.text('기울기 먼저 가르치기'), findsOneWidget);
    expect(find.text('트리는 정리용이며 AI 답변 맥락에 쓰이지 않습니다.'), findsOneWidget);
    expect(tester.takeException(), isNull);

    c.toggleFolder('f1');
    await tester.pump();
    expect(find.text('일차함수 순서'), findsNothing);
    c.toggleFolder('f1');

    await tester.enterText(find.byType(TextField), '기울기');
    await tester.pump();
    expect(find.text('기울기 먼저 가르치기'), findsOneWidget);
    expect(find.text('수학 커리큘럼'), findsOneWidget, reason: '발췌 옆에 폴더 경로로 보인다');
    expect(find.text('일차함수 순서'), findsNothing);
    expect(find.text('정리 안 됨'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('제외한 답변은 표시와 되돌리기 버튼이 보인다', (tester) async {
    final m = ThinkMessage(
      id: 'm2',
      role: 'assistant',
      content: '답변 본문',
      status: ThinkMessageStatus.complete,
      contextExcluded: true,
    );
    var toggled = false;
    await tester.pumpWidget(_host(
      ThinkMessageTile(message: m, highlighted: true, onToggleExcluded: () => toggled = true, onExcerpt: () {}),
      width: 480,
    ));
    expect(find.text('답변에서 제외됨'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.visibility_outlined));
    expect(toggled, isTrue);
    expect(find.byIcon(Icons.account_tree_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
