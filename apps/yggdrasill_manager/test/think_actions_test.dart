import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/think/think_action_cards.dart';
import 'package:yggdrasill_manager/screens/think/think_tree_panel.dart';
import 'package:yggdrasill_manager/services/think/think_action_models.dart';
import 'package:yggdrasill_manager/services/think/think_code_controller.dart';
import 'package:yggdrasill_manager/services/think/think_code_models.dart';
import 'package:yggdrasill_manager/services/think/think_controller.dart';
import 'package:yggdrasill_manager/services/think/think_models.dart';

const _diff = 'diff --git a/lib/a.dart b/lib/a.dart\n'
    'index 111..222 100644\n'
    '--- a/lib/a.dart\n'
    '+++ b/lib/a.dart\n'
    '@@ -1,2 +1,3 @@\n'
    ' keep\n'
    '-old\n'
    '+new\n'
    '+added\n'
    'diff --git a/lib/new.dart b/lib/new.dart\n'
    'new file mode 100644\n'
    'index 000..333\n'
    '--- /dev/null\n'
    '+++ b/lib/new.dart\n'
    '@@ -0,0 +1 @@\n'
    '+hello\n'
    'diff --git a/old name.dart b/new name.dart\n'
    'similarity index 90%\n'
    'rename from old name.dart\n'
    'rename to new name.dart\n'
    'diff --git a/img.png b/img.png\n'
    'index 444..555 100644\n'
    'GIT binary patch\n'
    'literal 10\n'
    'abcdef\n';

Map<String, dynamic> _action(String id, String kind, {String status = 'proposed', Map<String, dynamic>? payload, Map<String, dynamic>? preview, Map<String, dynamic>? result, String? messageId}) => {
      'id': id,
      'conversation_id': 'c1',
      'message_id': messageId,
      'kind': kind,
      'status': status,
      'payload': payload ?? {},
      'preview': preview ?? {},
      'result': result,
      'superseded': false,
      'created_at': '2026-09-30T01:00:00Z',
    };

Map<String, dynamic> _request(String status, {String mode = 'change', Map<String, dynamic>? applyResult, String? error}) => {
      'id': 'r1',
      'title': '지각 배지 추가',
      'request': {
        'goal': '출석 카드에 지각 배지',
        'instructions': ['AttendanceCard에 배지를 그린다'],
      },
      'status': status,
      'mode': mode,
      'conversation_id': 'c1',
      'round': 1,
      'max_rounds': 2,
      'apply_result': applyResult,
      'last_error': error,
      'created_at': '2026-09-30T01:00:00Z',
      'submitted_at': '2026-09-30T01:00:00Z',
    };

final _changeRound = {
  'round': 1,
  'status': 'finished',
  'result_text': '고쳤습니다.',
  'parse_ok': true,
  'result': {
    'summary': '배지를 추가했습니다.',
    'changes': [
      {'path': 'lib/a.dart', 'what': '배지 위젯'},
    ],
    'checks': ['flutter analyze lib/a.dart'],
    'diff': _diff,
    'diff_stats': {
      'files': 4,
      'additions': 3,
      'deletions': 1,
      'list': [
        {'path': 'lib/a.dart', 'additions': 2, 'deletions': 1},
        {'path': 'img.png', 'additions': -1, 'deletions': -1},
      ],
    },
  },
};

Widget _host(Widget child, {double width = 900}) => MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: width, height: 900, child: SingleChildScrollView(child: child)),
        ),
      ),
    );

void _resetCode() {
  final c = ThinkCodeController.instance;
  c.requests = [];
  c.workers = const [];
}

void main() {
  group('모델', () {
    test('제안 행: 모르는 종류는 버리고, 종류별 값을 읽는다', () {
      expect(ThinkAction.fromRow(_action('a0', 'drop_table')), isNull);
      final place = ThinkAction.fromRow(_action('a1', 'place_conversation', payload: {'new_folder_title': '수학', 'new_folder_parent_id': null}))!;
      expect(place.pending, isTrue);
      expect(place.newFolderTitle, '수학');
      expect(place.folderId, isNull);
      final code = ThinkAction.fromRow(_action('a2', 'code_request', status: 'applied', result: {'code_request_id': 'r9'}))!;
      expect(code.codeRequestId, 'r9');
      expect(code.kind.isCode, isTrue);
      final del = ThinkAction.fromRow(_action('a3', 'delete_conversation', status: 'applied', result: {'deleted_id': 'c1', 'deleted_self': true}))!;
      expect(del.deletedSelf, isTrue);
      expect(del.kind.isDelete, isTrue);
    });

    test('diff를 파일별로 나누고 이름 바꾸기·바이너리를 구분한다', () {
      final files = parseThinkDiff(_diff);
      expect(files.map((f) => f.path), ['lib/a.dart', 'lib/new.dart', 'new name.dart', 'img.png']);
      expect(files[0].additions, 2);
      expect(files[0].deletions, 1);
      expect(files[1].additions, 1);
      expect(files[2].oldPath, 'old name.dart');
      expect(files[3].binary, isTrue);
      expect(files[3].lines, isEmpty);
    });

    test('수정 요청: 적용·되돌리기·취소 가능한 상태', () {
      final ready = ThinkCodeRequest.fromRow(_request('ready'));
      expect(ready.mode, ThinkCodeMode.change);
      expect(ready.spec.instructions, hasLength(1));
      expect(ready.status.appliable, isTrue);
      expect(ready.cancellable, isFalse);
      expect(ThinkCodeRequest.fromRow(_request('apply_queued')).cancellable, isTrue);
      expect(ThinkCodeRequest.fromRow(_request('applying')).cancellable, isFalse);
      expect(ThinkCodeStatus.parse('applied').revertable, isTrue);
      expect(ThinkCodeStatus.parse('applied').deletable, isTrue);
      expect(ThinkCodeStatus.parse('reverting').deletable, isFalse);
      final failed = ThinkCodeRequest.fromRow(_request('apply_failed', applyResult: {
        'apply': {'ok': false, 'error': '충돌', 'conflicts': ['lib/a.dart'], 'backup_ref': 'refs/code-bridge/r1/before-apply'},
      }));
      expect(failed.lastApply!.conflicts, ['lib/a.dart']);
      expect(failed.lastApply!.backupRef, endsWith('before-apply'));
      final round = ThinkCodeRound.fromRow(_changeRound);
      expect(round.diff, startsWith('diff --git'));
      expect(round.diffStats!.files, 4);
      expect(round.diffStats!.list.last.binary, isTrue);
      expect(round.result!.checks, ['flutter analyze lib/a.dart']);
    });

    test('같은 종류의 새 제안은 앞의 대기 제안을 대체한다', () {
      final c = ThinkController.instance;
      c.selectedId = 'c1';
      c.putActionForTest(ThinkAction.fromRow(_action('p1', 'place_conversation', payload: {'folder_id': 'f1'}))!);
      c.putActionForTest(ThinkAction.fromRow(_action('d1', 'delete_folder', payload: {'target_id': 'f1'}))!);
      c.putActionForTest(ThinkAction.fromRow(_action('p2', 'place_conversation', payload: {'folder_id': 'f2'}))!);
      final byId = {for (final a in c.actionsOf('c1')) a.id: a};
      expect(byId['p1']!.superseded, isTrue);
      expect(byId['p1']!.pending, isFalse);
      expect(byId['d1']!.pending, isTrue, reason: '종류가 다르면 그대로 둔다');
      expect(c.pendingPlacement!.id, 'p2');
    });
  });

  group('카드', () {
    setUp(_resetCode);

    testWidgets('코드 수정 제안은 할 일과 승인 버튼, 격리 안내를 보여 준다', (tester) async {
      final a = ThinkAction.fromRow(_action('a1', 'code_change', payload: {
        'title': '지각 배지 추가',
        'spec': {
          'goal': '출석 카드에 지각 배지',
          'instructions': ['AttendanceCard에 배지를 그린다'],
          'focus_paths': ['apps/yggdrasill/lib/widgets'],
          'memory_refs': [
            {'id': 'm1', 'title': '색만으로 구분하지 않는다'},
          ],
        },
      }))!;
      await tester.pumpWidget(_host(ThinkActionCard(action: a)));
      expect(find.text('코드 수정 제안'), findsOneWidget);
      expect(find.text('승인 대기'), findsOneWidget);
      expect(find.text('· AttendanceCard에 배지를 그린다'), findsOneWidget);
      expect(find.text('· apps/yggdrasill/lib/widgets'), findsOneWidget);
      expect(find.textContaining('격리 폴더'), findsOneWidget);
      expect(find.text('보내기'), findsOneWidget);
      expect(find.text('고쳐서 보내기'), findsOneWidget);
      expect(find.text('거절'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('분류 제안: 새 폴더 표시와 넣기·다른 폴더·거절', (tester) async {
      final a = ThinkAction.fromRow(_action('a1', 'place_conversation',
          payload: {'new_folder_title': '출석 기능', 'new_folder_parent_id': null},
          preview: {'path': '출석 기능', 'is_new': true, 'current': '정리 안 됨', 'reason': '출석 이야기라서'}))!;
      await tester.pumpWidget(_host(ThinkActionCard(action: a)));
      expect(find.text('대화 분류 제안'), findsOneWidget);
      expect(find.text('새 폴더'), findsOneWidget);
      expect(find.text('폴더 만들고 넣기'), findsOneWidget);
      expect(find.text('다른 폴더에 넣기'), findsOneWidget);
      expect(find.textContaining('폴더도 만들지 않습니다'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('대화 삭제 제안: 함께 지워지는 것과 되돌릴 수 없음을 알린다', (tester) async {
      final a = ThinkAction.fromRow(_action('a1', 'delete_conversation', payload: {'target_id': 'c1'}, preview: {
        'title': '옛 대화',
        'messages': 12,
        'excerpts': 2,
        'code_requests': 1,
        'is_current': true,
        'reason': '사용자 요청',
      }))!;
      await tester.pumpWidget(_host(ThinkActionCard(action: a)));
      expect(find.text('대화 삭제 제안'), findsOneWidget);
      expect(find.textContaining('메시지 12개와 발췌 2개'), findsOneWidget);
      expect(find.textContaining('코드 요청 1개는 남고'), findsOneWidget);
      expect(find.textContaining('지금 보고 있는 이 대화'), findsOneWidget);
      expect(find.text('삭제는 되돌릴 수 없습니다.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('거절·대체된 제안은 한 줄로 줄인다', (tester) async {
      final a = ThinkAction.fromRow({..._action('a1', 'code_request', status: 'rejected', preview: {'title': '조사'}), 'superseded': true})!;
      await tester.pumpWidget(_host(ThinkActionCard(action: a)));
      expect(find.textContaining('새 제안으로 대체됨'), findsOneWidget);
      expect(find.text('보내기'), findsNothing);
    });

    testWidgets('수정 결과가 오면 diff와 적용 버튼, 검사 목록을 보여 준다', (tester) async {
      final c = ThinkCodeController.instance;
      final r = ThinkCodeRequest.fromRow(_request('ready'));
      c.requests = [r];
      c.setRoundsForTest('r1', [ThinkCodeRound.fromRow(_changeRound)]);
      await tester.pumpWidget(_host(ThinkCodeRequestCard(request: r)));
      await tester.pump();
      expect(find.text('코드 수정'), findsOneWidget);
      expect(find.text('배지를 추가했습니다.'), findsOneWidget);
      expect(find.text('작업 폴더에 적용'), findsOneWidget);
      expect(find.text('되돌리기'), findsNothing);
      expect(find.text('lib/a.dart'), findsOneWidget);
      expect(find.text('old name.dart → new name.dart'), findsOneWidget);
      expect(find.text('바이너리'), findsOneWidget);
      expect(find.text('flutter analyze lib/a.dart'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('작업 폴더에 적용'));
      await tester.pumpAndSettle();
      expect(find.text('작업 폴더에 적용할까요?'), findsOneWidget);
      expect(find.textContaining('git apply --check'), findsOneWidget);
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
    });

    testWidgets('적용 실패는 충돌 파일과 백업을, 적용됨은 되돌리기를 보여 준다', (tester) async {
      final c = ThinkCodeController.instance;
      c.setRoundsForTest('r1', [ThinkCodeRound.fromRow(_changeRound)]);
      final failed = ThinkCodeRequest.fromRow(_request('apply_failed', applyResult: {
        'apply': {'ok': false, 'error': '검사 실패', 'conflicts': ['lib/a.dart'], 'backup_ref': 'refs/code-bridge/r1/before-apply'},
      }));
      c.requests = [failed];
      await tester.pumpWidget(_host(ThinkCodeRequestCard(request: failed)));
      await tester.pump();
      expect(find.text('충돌한 파일'), findsOneWidget);
      expect(find.textContaining('refs/code-bridge/r1/before-apply'), findsOneWidget);
      expect(find.text('다시 적용'), findsOneWidget);

      final unknown = ThinkCodeRequest.fromRow(_request('apply_failed', error: 'lease_expired_state_unknown'));
      await tester.pumpWidget(_host(ThinkCodeRequestCard(key: const ValueKey('u'), request: unknown)));
      await tester.pump();
      expect(find.textContaining('상태를 알 수 없습니다'), findsOneWidget);

      final applied = ThinkCodeRequest.fromRow(_request('applied', applyResult: {
        'apply': {'ok': true, 'files': 4, 'backup_ref': 'refs/code-bridge/r1/before-apply'},
      }));
      await tester.pumpWidget(_host(ThinkCodeRequestCard(key: const ValueKey('a'), request: applied)));
      await tester.pump();
      expect(find.textContaining('파일 4개'), findsWidgets);
      expect(find.text('되돌리기'), findsOneWidget);
      expect(find.text('작업 폴더에 적용'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('조사 결과를 Think가 검토 중이면 진행 줄을 보여 준다', (tester) async {
      final c = ThinkCodeController.instance;
      final r = ThinkCodeRequest.fromRow({..._request('ready', mode: 'investigate'), 'review_status': 'pending'});
      c.requests = [r];
      c.setRoundsForTest('r1', const []);
      await tester.pumpWidget(_host(ThinkCodeRequestCard(request: r)));
      expect(find.text('Think가 결과를 검토하고 있습니다…'), findsOneWidget);
      expect(find.text('1/2회차'), findsOneWidget);
      expect(find.text('작업 폴더에 적용'), findsNothing);
    });
  });

  testWidgets('트리: 제안 폴더를 강조하고 새 폴더 제안은 흐린 행으로 끼운다', (tester) async {
    final c = ThinkController.instance;
    c.conversations = [const ThinkConversation(id: 'c1', title: '출석 이야기', status: 'active', messageCount: 2)];
    c.treeNodes = const [
      ThinkTreeNode(id: 'f1', kind: ThinkTreeKind.folder, title: '운영', sortOrder: 0, version: 1),
      ThinkTreeNode(id: 'f2', kind: ThinkTreeKind.folder, title: '출결', sortOrder: 0, version: 1, parentId: 'f1'),
    ];
    c.collapsedFolders.add('f1');
    c.selectedId = 'c1';
    c.putActionForTest(ThinkAction.fromRow(_action('p9', 'place_conversation', payload: {'folder_id': 'f2'}))!);
    expect(c.collapsedFolders.contains('f1'), isFalse, reason: '제안 폴더의 조상을 편다');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SizedBox(width: 280, height: 640, child: ThinkTreePanel(onNewConversation: () {}))),
    ));
    await tester.pump();
    expect(find.text('출결'), findsOneWidget);
    expect(find.text('제안'), findsOneWidget);

    c.putActionForTest(ThinkAction.fromRow(_action('p10', 'place_conversation', payload: {'new_folder_title': '지각 관리', 'new_folder_parent_id': 'f1'}))!);
    await tester.pump();
    expect(find.text('지각 관리'), findsOneWidget);
    expect(find.text('새 폴더 제안'), findsOneWidget);
    expect(find.text('제안'), findsNothing, reason: '앞 제안은 대체되었다');
    expect(tester.takeException(), isNull);
  });
}
