import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/think/think_avatars.dart';
import 'package:yggdrasill_manager/screens/think/think_materials_panel.dart';
import 'package:yggdrasill_manager/screens/think/think_memory_scope_picker.dart';
import 'package:yggdrasill_manager/screens/think/think_message_tile.dart';
import 'package:yggdrasill_manager/screens/think/think_role_bar.dart';
import 'package:yggdrasill_manager/services/think/think_models.dart';

Widget _wrap(Widget child, {double width = 1000, bool disableAnimations = false}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: Size(width, 800), disableAnimations: disableAnimations),
        child: Scaffold(
          body: SingleChildScrollView(child: SizedBox(width: width, child: child)),
        ),
      ),
    );

ThinkMemoryDraft _draft({ThinkMemoryScope scope = ThinkMemoryScope.department, ThinkDepartmentId? dept}) =>
    ThinkMemoryDraft(
      kind: ThinkMemoryKind.note,
      status: ThinkMemoryStatus.draft,
      title: 't',
      content: 'c',
      memoryScope: scope,
      scopeDepartment: dept,
    );

void main() {
  group('모델', () {
    test('toRow(withScope: true)는 memory_scope·scope_department를 보낸다', () {
      final row = _draft(dept: ThinkDepartmentId.education).toRow(withScope: true);
      expect(row['memory_scope'], 'department');
      expect(row['scope_department'], 'education');
    });

    test('toRow()는 역할 기능 전 DB를 위해 범위 열을 보내지 않는다', () {
      final row = _draft(dept: ThinkDepartmentId.education).toRow();
      expect(row.containsKey('memory_scope'), isFalse);
      expect(row.containsKey('scope_department'), isFalse);
    });

    test('부서 범위인데 부서가 없으면 scopeError', () {
      expect(_draft().scopeError, isNotNull);
      expect(_draft(dept: ThinkDepartmentId.product).scopeError, isNull);
      expect(_draft(scope: ThinkMemoryScope.common).scopeError, isNull);
    });

    test('스냅샷은 delivered=false 자료를 빼고 truncated를 읽는다', () {
      final snap = ThinkMessageContextSnapshot.fromRow({
        'message_id': 'm1',
        'think_role_id': 'education',
        'materials': [
          {'kind': 'memory', 'id': 'a', 'title': 'A', 'delivered': true},
          {'kind': 'memory', 'id': 'b', 'title': 'B', 'delivered': false},
          {'kind': 'document', 'id': 'd', 'title': 'D', 'truncated': true},
        ],
      });
      expect(snap.thinkRoleId, ThinkRoleId.education);
      expect(snap.materials.map((m) => m.id), ['a', 'd']);
      expect(snap.materials.last.isDocument, isTrue);
      expect(snap.materials.last.truncated, isTrue);
      expect(snap.materials.first.truncated, isFalse);
    });

    test('역할 이름·부서 대응', () {
      expect(ThinkRoleId.lead.label, '총괄');
      expect(ThinkRoleId.parse('engineering'), ThinkRoleId.engineering);
      expect(ThinkRoleId.parse('unknown'), ThinkRoleId.lead);
      expect(ThinkRoleId.lead.department, isNull);
      expect(ThinkRoleId.product.department, ThinkDepartmentId.product);
    });
  });

  group('역할 머리', () {
    testWidgets('총괄은 다른 부서 참조를 숨기고, 부서 역할은 자기 부서를 뺀 참조만 보인다', (tester) async {
      await tester.pumpWidget(_wrap(ThinkRoleBarView(role: ThinkRoleId.lead, extraRefs: const [], onRole: (_) {}, onToggleRef: (_) {})));
      expect(find.text('다른 부서 참조'), findsNothing);

      await tester.pumpWidget(_wrap(ThinkRoleBarView(role: ThinkRoleId.education, extraRefs: const [], onRole: (_) {}, onToggleRef: (_) {})));
      expect(find.text('다른 부서 참조'), findsOneWidget);
      expect(find.byTooltip('교육 부서 기억 참조'), findsNothing);
      expect(find.byTooltip('문제 풀이 부서 기억 참조'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('역할을 누르면 바꾸고, 잠기면 누를 수 없고 이유를 보인다', (tester) async {
      ThinkRoleId? picked;
      await tester.pumpWidget(_wrap(ThinkRoleBarView(role: ThinkRoleId.lead, extraRefs: const [], onRole: (r) => picked = r, onToggleRef: (_) {})));
      await tester.tap(find.text('개발'));
      expect(picked, ThinkRoleId.engineering);

      picked = null;
      await tester.pumpWidget(_wrap(ThinkRoleBarView(
        role: ThinkRoleId.lead,
        extraRefs: const [],
        lockReason: '답변이 끝난 뒤 바꿀 수 있습니다.',
        onRole: (r) => picked = r,
        onToggleRef: (_) {},
      )));
      await tester.tap(find.text('개발'));
      expect(picked, isNull);
      expect(find.text('답변이 끝난 뒤 바꿀 수 있습니다.'), findsOneWidget);
    });

    testWidgets('좁은 폭에서는 역할 칩 글자를 숨기고 툴팁으로 알린다', (tester) async {
      await tester.pumpWidget(_wrap(
        ThinkRoleBarView(role: ThinkRoleId.lead, extraRefs: const [], onRole: (_) {}, onToggleRef: (_) {}),
        width: 600,
      ));
      expect(find.text('문제 풀이'), findsNothing);
      expect(find.byTooltip('문제 풀이 역할'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('아바타', () {
    Finder pulse() => find.descendant(of: find.byType(ThinkRoleAvatar), matching: find.byType(AnimatedBuilder));

    testWidgets('모션 감소면 답하는 중에도 캐릭터가 움직이지 않는다', (tester) async {
      await tester.pumpWidget(_wrap(const ThinkRoleAvatar(role: ThinkRoleId.product, active: true), disableAnimations: true));
      expect(pulse(), findsNothing);
      expect(find.descendant(of: find.byType(ThinkRoleAvatar), matching: find.byType(CustomPaint)), findsWidgets);
    });

    testWidgets('기본은 답하는 역할만 움직이고, 4개 역할 모두 그려진다', (tester) async {
      await tester.pumpWidget(_wrap(Row(children: [
        for (final r in ThinkRoleId.values) ThinkRoleAvatar(role: r, active: r == ThinkRoleId.lead),
      ])));
      expect(pulse(), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('자료 패널', () {
    testWidgets('선택 없음·기록 없음·스냅샷을 구분한다', (tester) async {
      await tester.pumpWidget(_wrap(const ThinkMaterialsPanelView(hasSelection: false, snapshot: null, recordMissing: false)));
      expect(find.textContaining('"자료" 버튼'), findsOneWidget);

      await tester.pumpWidget(_wrap(const ThinkMaterialsPanelView(hasSelection: true, snapshot: null, recordMissing: true)));
      expect(find.text('기록 없음'), findsOneWidget);

      await tester.pumpWidget(_wrap(const ThinkMaterialsPanelView(
        hasSelection: true,
        recordMissing: false,
        snapshot: ThinkMessageContextSnapshot(
          messageId: 'm1',
          thinkRoleId: ThinkRoleId.education,
          materials: [
            ThinkMessageMaterialRef(kind: 'memory', id: 'a', title: '기억 A'),
            ThinkMessageMaterialRef(kind: 'document', id: 'd', title: '문서 D', truncated: true),
          ],
        ),
      )));
      expect(find.textContaining('Think(교육) 답변 · 기억 1개 · 문서 1개'), findsOneWidget);
      expect(find.text('앞부분만'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('연결 해제는 잠기면 막힌다', (tester) async {
      final removed = <String>[];
      Widget panel(String? lock) => _wrap(ThinkMaterialsPanelView(
            hasSelection: false,
            snapshot: null,
            recordMissing: false,
            lockReason: lock,
            linkedMemories: const [ThinkLinkedItem(id: 'p', title: '교재 기준')],
            onUnlinkMemory: removed.add,
          ));
      await tester.pumpWidget(panel(null));
      await tester.tap(find.byTooltip('교재 기준 연결 끊기'));
      expect(removed, ['p']);

      await tester.pumpWidget(panel('잠김'));
      await tester.tap(find.byTooltip('교재 기준 연결 끊기'));
      expect(removed, ['p']);
    });
  });

  group('기억 범위 선택', () {
    testWidgets('레거시는 레거시 기억에만 보이고, 역할 제안은 적용을 눌러야 바뀐다', (tester) async {
      final calls = <(ThinkMemoryScope, ThinkDepartmentId?)>[];
      await tester.pumpWidget(_wrap(ThinkMemoryScopePicker(
        scope: ThinkMemoryScope.common,
        department: null,
        suggestedRole: ThinkRoleId.education,
        onChanged: (s, d) => calls.add((s, d)),
      )));
      expect(find.text('공통(레거시)'), findsNothing);
      expect(calls, isEmpty);
      await tester.tap(find.text('적용'));
      expect(calls, [(ThinkMemoryScope.department, ThinkDepartmentId.education)]);

      await tester.pumpWidget(_wrap(ThinkMemoryScopePicker(
        scope: ThinkMemoryScope.legacyUnscoped,
        department: null,
        showLegacy: true,
        onChanged: (s, d) {},
      )));
      expect(find.text('공통(레거시)'), findsOneWidget);
      expect(find.text('적용'), findsNothing);
    });
  });

  group('답변 타일', () {
    testWidgets('기록 없음 배지는 표시를 요청했을 때만 보인다', (tester) async {
      final msg = ThinkMessage(id: 'm1', role: 'assistant', content: '답', status: ThinkMessageStatus.complete);
      await tester.pumpWidget(_wrap(ThinkMessageTile(message: msg, onSelect: () {})));
      expect(find.text('기록 없음'), findsNothing);
      expect(find.byIcon(Icons.library_books_outlined), findsOneWidget);

      await tester.pumpWidget(_wrap(ThinkMessageTile(message: msg, roleRecordMissing: true, onSelect: () {})));
      expect(find.text('기록 없음'), findsOneWidget);
    });
  });
}
