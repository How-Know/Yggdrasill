import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/services/think/think_models.dart';
import 'package:yggdrasill_manager/services/think/think_tree.dart';

ThinkTreeNode _folder(String id, {String? parent, int order = 0}) =>
    ThinkTreeNode(id: id, kind: ThinkTreeKind.folder, title: id, sortOrder: order, version: 1, parentId: parent);

ThinkTreeNode _conv(String id, String conversationId, {String? parent, int order = 0}) => ThinkTreeNode(
      id: id,
      kind: ThinkTreeKind.conversation,
      title: '',
      sortOrder: order,
      version: 1,
      parentId: parent,
      conversationId: conversationId,
    );

ThinkTreeNode _excerpt(String id, String conversationId, {String? parent, int order = 0}) => ThinkTreeNode(
      id: id,
      kind: ThinkTreeKind.excerpt,
      title: id,
      sortOrder: order,
      version: 1,
      parentId: parent,
      conversationId: conversationId,
      sourceMessageIds: const ['m1'],
    );

ThinkConversation _c(String id) => ThinkConversation(id: id, title: '대화 $id', status: 'active', messageCount: 2);

ThinkMessage _m(String role) => ThinkMessage(role: role, content: role, status: ThinkMessageStatus.complete);

void main() {
  // A
  // ├─ B
  // │  └─ (c2)
  // ├─ (c1)
  // └─ e1 (발췌, c1)
  // Z
  // (c9: 보관된 대화라 목록에 없음)
  final nodes = [
    _folder('A', order: 0),
    _folder('Z', order: 1),
    _folder('B', parent: 'A', order: 0),
    _conv('n1', 'c1', parent: 'A', order: 1),
    _excerpt('e1', 'c1', parent: 'A', order: 2),
    _conv('n2', 'c2', parent: 'B', order: 0),
    _conv('n9', 'c9', parent: 'Z', order: 0),
  ];
  final conversations = [_c('c3'), _c('c1'), _c('c2')];
  final tree = ThinkTree.build(nodes, conversations);

  group('ThinkTree 구성', () {
    test('트리에 없는 대화만 정리 안 됨에 모이고 목록 순서를 따른다', () {
      expect(tree.unfiled.map((c) => c.id), ['c3']);
    });

    test('목록에 없는 대화의 노드는 숨기지만 순서 계산에는 남긴다', () {
      expect(tree.children('Z'), isEmpty);
      expect(tree.allChildren('Z').map((n) => n.id), ['n9']);
    });

    test('접은 폴더의 하위는 행에서 빠지고 깊이가 매겨진다', () {
      final open = tree.rows({});
      expect(open.map((r) => '${r.node.id}@${r.depth}'), ['A@0', 'B@1', 'n2@2', 'n1@1', 'e1@1', 'Z@0']);
      final closed = tree.rows({'A'});
      expect(closed.map((r) => r.node.id), ['A', 'Z']);
      expect(closed.first.childCount, 3);
    });

    test('폴더 경로와 대화별 발췌', () {
      expect(tree.folderPath('B'), 'A / B');
      expect(tree.excerptsOf('c1').map((n) => n.id), ['e1']);
    });
  });

  group('끌어 놓기 계획', () {
    ThinkDragItem node(String id) => ThinkDragItem.node(tree.byId[id]!);

    test('폴더를 자기 하위로 넣거나 그 옆에 놓을 수 없다', () {
      expect(tree.planDrop(node('A'), tree.byId['B'], ThinkDropPosition.inside), isNull);
      expect(tree.planDrop(node('A'), tree.byId['n2'], ThinkDropPosition.before), isNull);
      expect(tree.planDrop(node('A'), tree.byId['A'], ThinkDropPosition.inside), isNull);
    });

    test('대화나 발췌 안에는 넣을 수 없다', () {
      expect(tree.planDrop(node('e1'), tree.byId['n1'], ThinkDropPosition.inside), isNull);
    });

    test('형제 사이 자리는 옮기는 항목을 뺀 기준으로 센다', () {
      final plan = tree.planDrop(node('B'), tree.byId['e1'], ThinkDropPosition.after)!;
      expect(plan.nodeId, 'B');
      expect(plan.parentId, 'A');
      expect(plan.index, 2);
    });

    test('제자리에 놓으면 아무것도 하지 않는다', () {
      expect(tree.planDrop(node('n1'), tree.byId['B'], ThinkDropPosition.after), isNull);
      expect(tree.planDrop(node('n1'), tree.byId['e1'], ThinkDropPosition.before), isNull);
    });

    test('정리 안 됨 대화를 폴더에 넣으면 대화 배치 계획이 된다', () {
      final plan = tree.planDrop(const ThinkDragItem.unfiled('c3'), tree.byId['Z'], ThinkDropPosition.inside)!;
      expect(plan.nodeId, isNull);
      expect(plan.conversationId, 'c3');
      expect(plan.parentId, 'Z');
      expect(plan.index, 1, reason: '숨긴 노드(n9) 뒤, 맨 끝');
    });

    test('정리 안 됨에는 트리에 놓인 대화만 돌려놓을 수 있다', () {
      expect(tree.planUnfile(node('n1'))!.unfile, isTrue);
      expect(tree.planUnfile(node('e1')), isNull);
      expect(tree.planUnfile(node('A')), isNull);
      expect(tree.planUnfile(const ThinkDragItem.unfiled('c3')), isNull);
    });

    test('폴더로 이동 메뉴: 최상위는 맨 끝', () {
      final plan = tree.planMoveInto(node('e1'), null)!;
      expect(plan.parentId, isNull);
      expect(plan.index, 2);
    });
  });

  group('문답 묶기', () {
    final msgs = [_m('user'), _m('assistant'), _m('user'), _m('assistant'), _m('assistant'), _m('user')];

    test('답변을 고르면 앞의 질문과 이어진 답변을 함께 고른다', () {
      expect(thinkTurnIndices(msgs, 3), [2, 3, 4]);
      expect(thinkTurnIndices(msgs, 1), [0, 1]);
    });

    test('질문을 고르면 그 답변까지, 답이 없으면 질문만', () {
      expect(thinkTurnIndices(msgs, 2), [2, 3, 4]);
      expect(thinkTurnIndices(msgs, 5), [5]);
    });

    test('앞에 질문이 없는 답변은 이어진 답변끼리 묶는다', () {
      expect(thinkTurnIndices([_m('assistant'), _m('assistant'), _m('user')], 0), [0, 1]);
      expect(thinkTurnIndices(msgs, 9), isEmpty);
    });
  });
}
