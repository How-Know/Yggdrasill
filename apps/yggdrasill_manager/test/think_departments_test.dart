import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/think/think_avatars.dart';
import 'package:yggdrasill_manager/screens/think/think_tree_panel.dart';
import 'package:yggdrasill_manager/services/think/think_action_models.dart';
import 'package:yggdrasill_manager/services/think/think_models.dart';
import 'package:yggdrasill_manager/services/think/think_tree.dart';

ThinkTreeNode _folder(String id, ThinkRoleId? dept, {String? parent, int order = 0}) => ThinkTreeNode(
      id: id,
      kind: ThinkTreeKind.folder,
      title: id,
      sortOrder: order,
      version: 1,
      parentId: parent,
      department: dept,
    );

ThinkTreeNode _node(String id, ThinkTreeKind kind, String conversationId, {String? parent, int order = 0}) => ThinkTreeNode(
      id: id,
      kind: kind,
      title: id,
      sortOrder: order,
      version: 1,
      parentId: parent,
      conversationId: conversationId,
      sourceMessageIds: kind == ThinkTreeKind.conversation ? const [] : const ['m1'],
    );

ThinkConversation _c(String id, ThinkRoleId role) =>
    ThinkConversation(id: id, title: '대화 $id', status: 'active', messageCount: 2, thinkRoleId: role);

Widget _wrap(Widget child, {bool disableAnimations = false}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: Scaffold(body: Center(child: SizedBox(width: 320, child: child))),
      ),
    );

void main() {
  // [총괄] Flead
  // [교육] Fedu ─ G ─ (c2: 문제 풀이 역할, 폴더 부서와 다름)
  //             └ (c1: 교육)
  //        x1 (최상위 발췌, 출처 c1)
  // [문제 풀이] Fprod
  // [개발] (c5: 최상위 대화)
  // 미분류: c3(총괄), c4(문제 풀이)
  final nodes = [
    _folder('Flead', ThinkRoleId.lead, order: 0),
    _folder('Fedu', ThinkRoleId.education, order: 1),
    _folder('Fprod', ThinkRoleId.product, order: 2),
    _node('n5', ThinkTreeKind.conversation, 'c5', order: 3),
    _node('x1', ThinkTreeKind.excerpt, 'c1', order: 4),
    _folder('G', ThinkRoleId.education, parent: 'Fedu', order: 0),
    _node('n1', ThinkTreeKind.conversation, 'c1', parent: 'Fedu', order: 1),
    _node('n2', ThinkTreeKind.conversation, 'c2', parent: 'G', order: 0),
  ];
  final conversations = [
    _c('c1', ThinkRoleId.education),
    _c('c2', ThinkRoleId.product),
    _c('c3', ThinkRoleId.lead),
    _c('c4', ThinkRoleId.product),
    _c('c5', ThinkRoleId.engineering),
  ];
  final tree = ThinkTree.build(nodes, conversations, departments: true);
  final flat = ThinkTree.build(nodes, conversations);
  ThinkDragItem node(String id) => ThinkDragItem.node(tree.byId[id]!);

  group('부서 칸 구성', () {
    test('최상위 폴더는 자기 부서, 폴더 밖 노드는 대화 역할의 칸에 보인다', () {
      expect(tree.rows({}, department: ThinkRoleId.education).map((r) => '${r.node.id}@${r.depth}'),
          ['Fedu@0', 'G@1', 'n2@2', 'n1@1', 'x1@0']);
      expect(tree.rows({}, department: ThinkRoleId.lead).map((r) => r.node.id), ['Flead']);
      expect(tree.rows({}, department: ThinkRoleId.product).map((r) => r.node.id), ['Fprod']);
      expect(tree.rows({}, department: ThinkRoleId.engineering).map((r) => r.node.id), ['n5']);
    });

    test('미분류는 대화 역할로 나뉜다', () {
      expect(tree.unfiledOf(ThinkRoleId.lead).map((c) => c.id), ['c3']);
      expect(tree.unfiledOf(ThinkRoleId.product).map((c) => c.id), ['c4']);
      expect(tree.unfiledOf(ThinkRoleId.education), isEmpty);
    });

    test('폴더 부서와 역할이 다른 대화만 표시하고, 부서 칸을 안 쓰면 표시하지 않는다', () {
      expect(tree.isMisplaced(tree.byId['n2']!), isTrue);
      expect(tree.isMisplaced(tree.byId['n1']!), isFalse);
      expect(tree.isMisplaced(tree.byId['n5']!), isFalse);
      expect(flat.isMisplaced(flat.byId['n2']!), isFalse);
    });

    test('부서별 폴더 목록', () {
      expect(tree.folders(department: ThinkRoleId.education).map((f) => f.folder.id), ['Fedu', 'G']);
      expect(tree.folders(department: ThinkRoleId.engineering), isEmpty);
      expect(tree.folders().length, 4);
    });
  });

  group('부서 사이 옮기기 계획', () {
    test('폴더를 다른 부서 머리에 놓으면 그 부서 최상위 맨 끝, 역할이 바뀌는 대화만 센다', () {
      final plan = tree.planDrop(node('Fedu'), null, ThinkDropPosition.inside, department: ThinkRoleId.product)!;
      expect(plan.department, ThinkRoleId.product);
      expect(plan.parentId, isNull);
      expect(plan.index, 2, reason: 'Fedu를 뺀 최상위 [Flead, Fprod, n5, x1]에서 Fprod 다음');
      expect(tree.rolesChangedByPlan(node('Fedu'), plan), 1, reason: 'c2는 이미 문제 풀이');
    });

    test('미분류 대화를 다른 부서 폴더에 넣으면 그 폴더 부서로', () {
      final plan = tree.planDrop(const ThinkDragItem.unfiled('c3'), tree.byId['G'], ThinkDropPosition.inside)!;
      expect(plan.department, ThinkRoleId.education);
      expect(plan.conversationId, 'c3');
      expect(tree.rolesChangedByPlan(const ThinkDragItem.unfiled('c3'), plan), 1);
    });

    test('같은 부서 안에서 옮기면 역할이 바뀌는 대화가 없다', () {
      final plan = tree.planDrop(node('n1'), tree.byId['G'], ThinkDropPosition.inside)!;
      expect(plan.department, ThinkRoleId.education);
      expect(tree.rolesChangedByPlan(node('n1'), plan), 0);
    });

    test('다른 부서 미분류로 빼기', () {
      final plan = tree.planUnfile(node('n1'), department: ThinkRoleId.product)!;
      expect(plan.unfile, isTrue);
      expect(plan.nodeId, 'n1');
      expect(plan.conversationId, 'c1');
      expect(plan.department, ThinkRoleId.product);

      expect(tree.planUnfile(const ThinkDragItem.unfiled('c4'), department: ThinkRoleId.product), isNull,
          reason: '이미 그 부서 미분류');
      final moved = tree.planUnfile(const ThinkDragItem.unfiled('c4'), department: ThinkRoleId.lead)!;
      expect(moved.nodeId, isNull);
      expect(moved.conversationId, 'c4');
      expect(tree.planUnfile(node('Fedu'), department: ThinkRoleId.lead), isNull, reason: '폴더는 미분류에 못 놓는다');
    });

    test('최상위 발췌는 다른 부서 최상위로 옮길 수 없다', () {
      expect(tree.planDrop(node('x1'), null, ThinkDropPosition.inside, department: ThinkRoleId.engineering), isNull);
      expect(tree.planDrop(node('x1'), tree.byId['Fprod'], ThinkDropPosition.inside), isNotNull,
          reason: '폴더 안으로는 옮길 수 있다');
    });

    test('부서 칸을 쓰지 않으면 계획에 부서가 없다', () {
      final plan = flat.planDrop(const ThinkDragItem.unfiled('c3'), flat.byId['G'], ThinkDropPosition.inside)!;
      expect(plan.department, isNull);
      expect(flat.rolesChangedByPlan(const ThinkDragItem.unfiled('c3'), plan), 0);
      expect(flat.planUnfile(ThinkDragItem.node(flat.byId['n1']!))!.department, isNull);
      expect(flat.planUnfile(const ThinkDragItem.unfiled('c3')), isNull);
    });
  });

  group('이름·상태', () {
    test('제품 부서는 문제 풀이로 보인다', () {
      expect(ThinkRoleId.product.label, '문제 풀이');
      expect(ThinkDepartmentId.product.label, '문제 풀이');
      expect(ThinkRoleId.product.db, 'product');
    });

    test('부서 상태 문구', () {
      expect(const ThinkDepartmentActivity(ThinkActivity.consulting, consultWith: ThinkRoleId.engineering).label,
          '↔ 개발과 협의 중');
      expect(const ThinkDepartmentActivity(ThinkActivity.consulting, consultWith: ThinkRoleId.product).label,
          '↔ 문제 풀이와 협의 중');
      expect(const ThinkDepartmentActivity(ThinkActivity.waiting, count: 3).label, '승인 대기 3');
      expect(const ThinkDepartmentActivity(ThinkActivity.idle).label, '쉬는 중');
      expect(ThinkActivity.waiting.busy, isFalse);
      expect(ThinkActivity.consulting.busy, isTrue);
    });

    test('부서 넘기기 제안을 읽는다', () {
      final a = ThinkAction.fromRow({
        'id': 'h1',
        'conversation_id': 'c1',
        'kind': 'handover_department',
        'status': 'proposed',
        'payload': {'to_department': 'product', 'reason': '문항 난이도 문제입니다.'},
        'preview': {'title': '문제 풀이 부서로', 'from_department': 'education', 'to_department': 'product'},
        'result': null,
        'superseded': false,
        'created_at': '2026-10-12T01:00:00Z',
      })!;
      expect(a.kind, ThinkActionKind.handoverDepartment);
      expect(a.kind.label, '부서 넘기기');
      expect(a.handoverTo, ThinkRoleId.product);
      expect(a.handoverFrom, ThinkRoleId.education);
      expect(a.handoverReason, '문항 난이도 문제입니다.');
      expect(a.pending, isTrue);
    });
  });

  group('부서 캐릭터', () {
    Finder moving() => find.descendant(of: find.byType(ThinkRoleAvatar), matching: find.byType(AnimatedBuilder));

    testWidgets('일하는 상태만 움직이고, 4부서 × 5상태 모두 그려진다', (tester) async {
      await tester.pumpWidget(_wrap(Wrap(children: [
        for (final r in ThinkRoleId.values)
          for (final a in ThinkActivity.values) ThinkRoleAvatar(role: r, size: 28, activity: a),
      ])));
      expect(moving(), findsNWidgets(ThinkRoleId.values.length * 3));
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('모션 감소면 일하는 중에도 멈춘 장면만 그린다', (tester) async {
      await tester.pumpWidget(_wrap(const ThinkRoleAvatar(role: ThinkRoleId.engineering, activity: ThinkActivity.coding),
          disableAnimations: true));
      expect(moving(), findsNothing);
      final paint = tester.widget<CustomPaint>(
          find.descendant(of: find.byType(ThinkRoleAvatar), matching: find.byType(CustomPaint)).first);
      expect((paint.painter! as ThinkPixelCharacterPainter).frame, 0);
    });

    testWidgets('부서 머리는 이름·요약·상태를 보이고, 누르면 접는다', (tester) async {
      var toggled = 0;
      await tester.pumpWidget(_wrap(ThinkDepartmentHeader(
        role: ThinkRoleId.product,
        activity: const ThinkDepartmentActivity(ThinkActivity.consulting, consultWith: ThinkRoleId.engineering),
        summary: '폴더 2 · 미분류 1',
        collapsed: false,
        onToggle: () => toggled++,
        onNewFolder: () {},
        resolve: (_) => null,
        onDrop: (_) {},
      )));
      expect(find.text('문제 풀이'), findsOneWidget);
      expect(find.text('폴더 2 · 미분류 1'), findsOneWidget);
      expect(find.text('↔ 개발과 협의 중'), findsOneWidget);
      expect(find.byTooltip('문제 풀이 부서 새 폴더'), findsOneWidget);
      await tester.tap(find.text('문제 풀이'));
      expect(toggled, 1);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
