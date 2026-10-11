import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/think/think_action_cards.dart';
import 'package:yggdrasill_manager/screens/think/think_message_tile.dart';
import 'package:yggdrasill_manager/screens/think/think_tree_panel.dart';
import 'package:yggdrasill_manager/services/think/think_action_models.dart';
import 'package:yggdrasill_manager/services/think/think_controller.dart';
import 'package:yggdrasill_manager/services/think/think_models.dart';
import 'package:yggdrasill_manager/services/think/think_tree.dart';

Map<String, dynamic> _action(String id, String kind, {Map<String, dynamic>? preview}) => {
      'id': id,
      'conversation_id': 'c1',
      'message_id': null,
      'kind': kind,
      'status': 'proposed',
      'payload': const {},
      'preview': preview ?? const {},
      'result': null,
      'error': null,
      'created_at': '2026-10-07T00:00:00Z',
    };

void main() {
  group('ThinkTreeNode.fromRow', () {
    test('출처는 sort_order 순으로 정렬한다', () {
      final node = ThinkTreeNode.fromRow({
        'id': 'd1',
        'kind': 'document',
        'title': 't',
        'body': 'b',
        'sort_order': 0,
        'version': 1,
        'conversation_id': 'c1',
        'ai_tree_node_sources': [
          {'message_id': 'm2', 'sort_order': 1},
          {'message_id': 'm1', 'sort_order': 0},
        ],
      });
      expect(node.sourceMessageIds, ['m1', 'm2']);
    });
  });

  group('ThinkTree.documentsOf', () {
    test('대화별 종합 문서만 센다', () {
      final tree = ThinkTree.build(const [
        ThinkTreeNode(id: 'd1', kind: ThinkTreeKind.document, title: 'A', sortOrder: 0, version: 1, conversationId: 'c1'),
        ThinkTreeNode(id: 'd2', kind: ThinkTreeKind.document, title: 'B', sortOrder: 0, version: 1, conversationId: 'c2'),
        ThinkTreeNode(id: 'e1', kind: ThinkTreeKind.excerpt, title: 'E', sortOrder: 0, version: 1, conversationId: 'c1'),
      ], const [
        ThinkConversation(id: 'c1', title: '1', status: 'active', messageCount: 1),
        ThinkConversation(id: 'c2', title: '2', status: 'active', messageCount: 1),
      ]);
      expect(tree.documentsOf('c1').map((n) => n.id), ['d1']);
    });
  });

  test('revealMessages는 출처 id를 highlightedMessageIds에 넣는다', () async {
    final c = ThinkController.instance;
    c.conversations = [const ThinkConversation(id: 'c1', title: 't', status: 'active', messageCount: 2)];
    c.setMessagesForTest('c1', [
      ThinkMessage(id: 'm1', role: 'user', content: 'q', status: ThinkMessageStatus.complete),
      ThinkMessage(id: 'm2', role: 'assistant', content: 'a', status: ThinkMessageStatus.complete),
    ]);
    await c.revealMessages('c1', ['m2', 'm1']);
    expect(c.highlightedMessageIds, {'m2', 'm1'});
    expect(c.revealMessageId, 'm1');
  });

  testWidgets('대화 삭제 제안 카드에 종합 문서 개수를 표시한다', (tester) async {
    final a = ThinkAction.fromRow(_action('a1', 'delete_conversation', preview: {
      'title': '옛 대화',
      'messages': 5,
      'excerpts': 1,
      'documents': 2,
      'code_requests': 0,
      'is_current': false,
    }))!;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ThinkActionCard(action: a))));
    expect(find.textContaining('종합 문서 2개'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('답변 타일에 종합 문서 버튼이 발췌와 구분된다', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ThinkMessageTile(
            message: ThinkMessage(id: 'm1', role: 'assistant', content: '답', status: ThinkMessageStatus.complete),
            onExcerpt: () {},
            onDocument: () {},
            onMemoryFeedback: () {},
          ),
        ),
      ),
    );
    expect(find.byIcon(Icons.account_tree_outlined), findsOneWidget);
    expect(find.byIcon(Icons.description_outlined), findsOneWidget);
    expect(find.byIcon(Icons.rate_review_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('트리: 대화 삭제 확인에 종합 문서 수를 넣는다', (tester) async {
    final c = ThinkController.instance;
    c.conversations = [const ThinkConversation(id: 'c1', title: '정리 대화', status: 'active', messageCount: 3)];
    c.treeNodes = const [
      ThinkTreeNode(
        id: 'doc1',
        kind: ThinkTreeKind.document,
        title: '회의록',
        body: '본문',
        sortOrder: 0,
        version: 1,
        conversationId: 'c1',
        sourceMessageIds: ['m1'],
      ),
    ];
    c.selectedId = 'c1';

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SizedBox(width: 280, height: 640, child: ThinkTreePanel(onNewConversation: () {}))),
    ));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.more_horiz).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('삭제'));
    await tester.pumpAndSettle();
    expect(find.textContaining('종합 문서 1개'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
