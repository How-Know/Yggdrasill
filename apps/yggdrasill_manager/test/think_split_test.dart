import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/think/think_action_cards.dart';
import 'package:yggdrasill_manager/screens/think/think_split_views.dart';
import 'package:yggdrasill_manager/services/think/think_action_models.dart';
import 'package:yggdrasill_manager/services/think/think_api.dart';
import 'package:yggdrasill_manager/services/think/think_controller.dart';
import 'package:yggdrasill_manager/services/think/think_models.dart';

const _summary = {
  'purpose': '대화 정리 기능 설계',
  'background': '기억 기능 이야기에서 넘어왔다',
  'decided': ['원본은 복사로 보존한다'],
  'open': <String>[],
  'next': ['카드 문구 정하기'],
};

Map<String, dynamic> _split(String id,
        {String status = 'proposed',
        String? messageId = 'm2',
        Map<String, dynamic>? result,
        String? folderId,
        Map<String, dynamic> summary = _summary}) =>
    {
      'id': id,
      'conversation_id': 'c1',
      'message_id': messageId,
      'kind': 'split_conversation',
      'status': status,
      'payload': {
        'title': '대화 정리 기능',
        'reason': '기억 기능과 다른 주제로 넘어왔다',
        'summary': summary,
        'folder_id': folderId,
        'start_message_id': 'm1',
        'user_requested': false,
      },
      'preview': {'title': '대화 정리 기능', 'start_preview': '대화 정리는 어떻게 할까?', 'folder_path': null},
      'result': result,
      'superseded': false,
      'created_at': '2026-10-09T01:00:00Z',
    };

ThinkAction _action(Map<String, dynamic> row) => ThinkAction.fromRow(row)!;

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 900, height: 900, child: SingleChildScrollView(child: child)),
        ),
      ),
    );

Finder _button(String label) =>
    find.ancestor(of: find.text(label), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton));

void _openConversation(List<ThinkMessage> messages) {
  final c = ThinkController.instance;
  c.selectedId = 'c1';
  c.setMessagesForTest('c1', messages);
}

ThinkMessage _msg(String id, String role, {ThinkMessageStatus status = ThinkMessageStatus.complete}) =>
    ThinkMessage(id: id, role: role, content: '내용 $id', status: status);

void main() {
  group('모델', () {
    test('나누기 제안 행: 종류·요약·미리보기·결과를 읽고, 만료는 대기가 아니다', () {
      final a = _action(_split('s1'));
      expect(a.kind, ThinkActionKind.splitConversation);
      expect(a.pending, isTrue);
      expect(a.splitSummary.purpose, '대화 정리 기능 설계');
      expect(a.splitSummary.decided, ['원본은 복사로 보존한다']);
      expect(a.splitSummary.open, isEmpty);
      expect(a.splitStartPreview, '대화 정리는 어떻게 할까?');
      expect(a.folderId, isNull, reason: 'null 폴더 = 미분류');

      final expired = _action(_split('s2', status: 'expired'));
      expect(expired.status, ThinkActionStatus.expired);
      expect(expired.pending, isFalse, reason: '만료를 모르는 값으로 보고 대기로 되살리면 안 된다');

      final applied = _action(_split('s3', status: 'applied', result: {
        'conversation_id': 'c2',
        'not_copied': {'actions': 1, 'code_requests': 0, 'tree_nodes': 2, 'other_messages': 0},
      }));
      expect(applied.splitConversationId, 'c2');
      expect(applied.splitNotCopied, {'actions': 1, 'code_requests': 0, 'tree_nodes': 2, 'other_messages': 0});
    });

    test('앱은 나누기 카드를 처리할 수 있다고 서버에 알린다', () {
      expect(ThinkApi.clientFeatures['conversation_split'], 1);
    });

    test('기능 상태: 준비됨·DB 반영 필요, 응답에 없으면 Edge 배포 필요, 모르는 값은 확인 불가', () {
      ThinkStatus status(Map<String, dynamic> extra) =>
          ThinkStatus.fromJson({'configured': true, 'provider': 'openai', 'models': {}, ...extra});
      final ready = status({
        'features': {
          'conversation_split': {'state': 'ready', 'edge': 1, 'db': 1, 'app': 1, 'permitted': true},
        },
      }).conversationSplit;
      expect(ready.ready, isTrue);
      expect((ready.edge, ready.db, ready.app), (1, 1, 1));

      final db = status({
        'features': {
          'conversation_split': {'state': 'db_required', 'edge': 1, 'db': 0, 'app': 1},
        },
      });
      expect(db.conversationSplit.state, ThinkFeatureState.dbRequired);
      expect(db.conversationSplit.ready, isFalse);

      final unknown = status({
        'features': {
          'conversation_split': {'state': 'unknown', 'edge': 1, 'db': null, 'app': 1},
        },
        'features_db_error': 'permission denied',
      });
      expect(unknown.conversationSplit.state, ThinkFeatureState.unknown);
      expect(unknown.conversationSplit.db, isNull);
      expect(unknown.featuresDbError, 'permission denied');

      expect(status({}).conversationSplit.state, ThinkFeatureState.edgeMissing);
      final odd = status({
        'features': {
          'conversation_split': {'state': 'something_new'},
        },
      });
      expect(odd.conversationSplit.state, ThinkFeatureState.unknown);
      expect(odd.conversationSplit.ready, isFalse);

      final updated = db.withFeatures(parseThinkFeatures({
        'conversation_split': {'state': 'ready', 'edge': 1, 'db': 1, 'app': 1},
      }));
      expect(updated.conversationSplit.ready, isTrue);
      expect(updated.configured, isTrue);
    });

    test('대화 정보: 마이그레이션 전 행은 기본값, 나눈 대화는 원본과 요약을 가진다', () {
      final before = ThinkConversationDetail.fromRow({'id': 'c1', 'title': 'x'});
      expect(before.splitColumns, isFalse);
      expect(before.isSplit, isFalse);
      expect(before.autoSplitSuggestions, isTrue);

      final split = ThinkConversationDetail.fromRow({
        'id': 'c2',
        'split_from_conversation_id': 'c1',
        'split_from_action_id': 's1',
        'split_summary': _summary,
        'auto_split_suggestions': false,
      });
      expect(split.splitColumns, isTrue);
      expect(split.isSplit, isTrue);
      expect(split.splitFromConversationId, 'c1');
      expect(split.splitSummary!.next, ['카드 문구 정하기']);
      expect(split.autoSplitSuggestions, isFalse);

      final orphan = ThinkConversationDetail.fromRow({
        'id': 'c3',
        'split_from_conversation_id': null,
        'split_summary': _summary,
        'auto_split_suggestions': true,
      });
      expect(orphan.isSplit, isTrue, reason: '원본을 지워도 요약은 남는다');
      expect(orphan.splitFromConversationId, isNull);

      final copied = ThinkMessage.fromRow({'id': 'n1', 'role': 'user', 'content': 'a', 'source_message_id': 'm1'});
      expect(copied.sourceMessageId, 'm1');
      expect(ThinkMessage.fromRow({'id': 'm1', 'role': 'user', 'content': 'a'}).sourceMessageId, isNull);
    });

    test('새 질문이 저장되면 대기 중인 나누기 제안만 만료된다', () {
      final c = ThinkController.instance;
      c.putActionForTest(_action(_split('e1')));
      c.putActionForTest(_action(_split('e0', status: 'applied', result: {'conversation_id': 'c9'})));
      c.putActionForTest(ThinkAction.fromRow({
        ..._split('p1'),
        'kind': 'place_conversation',
        'payload': {'folder_id': 'f1'},
      })!);
      c.expirePendingSplitsForTest('c1');
      final byId = {for (final a in c.actionsOf('c1')) a.id: a};
      expect(byId['e1']!.status, ThinkActionStatus.expired);
      expect(byId['e0']!.status, ThinkActionStatus.applied);
      expect(byId['p1']!.pending, isTrue, reason: '다른 종류의 제안은 그대로 둔다');
    });
  });

  group('카드', () {
    setUp(() => _openConversation([_msg('m1', 'user'), _msg('m2', 'assistant')]));

    testWidgets('대기: 제목·이유·시작 미리보기·미분류·다섯 칸(빈 칸은 "없음")과 버튼', (tester) async {
      await tester.pumpWidget(_host(ThinkActionCard(action: _action(_split('s1')))));
      expect(find.text('대화 나누기 제안'), findsOneWidget);
      expect(find.text('대화 정리 기능'), findsOneWidget);
      expect(find.text('기억 기능과 다른 주제로 넘어왔다'), findsOneWidget);
      expect(find.text('대화 정리는 어떻게 할까?'), findsOneWidget);
      expect(find.text(kThinkUnfiledLabel), findsOneWidget);
      for (final label in ['목적', '이어받을 배경', '사용자가 확정한 사항', '미결정 사항', '다음 할 일']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('없음'), findsOneWidget, reason: '미결정 사항만 비어 있다');
      expect(find.text('· 원본은 복사로 보존한다'), findsOneWidget);
      expect(find.textContaining('이번 질문과 답변만 새 대화에 복사'), findsOneWidget);
      expect(tester.widget<ButtonStyleButton>(_button('나눠서 이어가기')).onPressed, isNotNull);
      expect(tester.widget<ButtonStyleButton>(_button('고쳐서 나누기')).onPressed, isNotNull);
      expect(find.text('여기서 계속하기'), findsOneWidget);
      expect(find.text('답변 완료 후 나눌 수 있습니다.'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('확정한 것이 없으면 "사용자가 확정한 사항"도 "없음"으로 보인다', (tester) async {
      final a = _action(_split('s1', summary: {'purpose': '목적만 있음'}));
      await tester.pumpWidget(_host(ThinkActionCard(action: a)));
      expect(find.text('없음'), findsNWidgets(4));
      expect(tester.takeException(), isNull);
    });

    testWidgets('답변이 저장되기 전(스트리밍 중)에는 승인을 막는다', (tester) async {
      await tester.pumpWidget(_host(ThinkActionCard(action: _action(_split('s1', messageId: null)))));
      expect(find.text('답변 완료 후 나눌 수 있습니다.'), findsOneWidget);
      expect(tester.widget<ButtonStyleButton>(_button('나눠서 이어가기')).onPressed, isNull);
      expect(tester.widget<ButtonStyleButton>(_button('고쳐서 나누기')).onPressed, isNull);
      expect(tester.widget<ButtonStyleButton>(_button('여기서 계속하기')).onPressed, isNotNull,
          reason: '거절(여기서 계속하기)은 언제든 할 수 있다');
    });

    testWidgets('중단된 답변이면 나눌 수 없다고 알린다', (tester) async {
      _openConversation([_msg('m1', 'user'), _msg('m2', 'assistant', status: ThinkMessageStatus.stopped)]);
      await tester.pumpWidget(_host(ThinkActionCard(action: _action(_split('s1')))));
      expect(find.textContaining('답변이 끝까지 저장되지 않아'), findsOneWidget);
      expect(tester.widget<ButtonStyleButton>(_button('나눠서 이어가기')).onPressed, isNull);
    });

    testWidgets('만료·거절은 한 줄로 줄이고 버튼이 없다', (tester) async {
      await tester.pumpWidget(_host(ThinkActionCard(action: _action(_split('s1', status: 'expired')))));
      expect(find.textContaining('대화가 이어져 이 제안은 만료됐습니다'), findsOneWidget);
      expect(find.text('나눠서 이어가기'), findsNothing);

      await tester.pumpWidget(_host(ThinkActionCard(action: _action(_split('s2', status: 'rejected')))));
      expect(find.textContaining('여기서 계속하기로 함'), findsOneWidget);
      expect(find.text('나눠서 이어가기'), findsNothing);
    });

    testWidgets('승인됨: 새 대화로 가는 길과 원본에만 남은 것을 보여 준다', (tester) async {
      final a = _action(_split('s1', status: 'applied', result: {
        'conversation_id': 'c2',
        'title': '대화 정리 기능 (고침)',
        'not_copied': {'actions': 2, 'code_requests': 1, 'tree_nodes': 0, 'other_messages': 0},
      }));
      await tester.pumpWidget(_host(ThinkActionCard(action: a)));
      expect(find.text('나눔'), findsOneWidget);
      expect(find.text('새 대화로 가기'), findsOneWidget);
      expect(find.textContaining('"대화 정리 기능 (고침)" 새 대화로 나눴습니다'), findsOneWidget);
      expect(find.textContaining('이 대화에만 남은 것: 작업 카드 2개, 코드 요청 1개.'), findsOneWidget);
      expect(find.text('나눠서 이어가기'), findsNothing, reason: '승인된 카드는 다시 실행할 수 없다');
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('고치기 창: 제목·목적이 비면 확인할 수 없고, 목록은 한 줄에 하나로 보낸다', (tester) async {
    ThinkSplitEdit? result;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await ThinkSplitEditDialog.show(
                context,
                title: '대화 정리 기능',
                folderId: null,
                summary: ThinkSplitSummary.fromJson(_summary),
                tree: ThinkController.instance.tree,
              );
            },
            child: const Text('열기'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    expect(find.text('나눌 내용 고치기'), findsOneWidget);
    expect(find.text(kThinkUnfiledLabel), findsOneWidget);

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '  ');
    await tester.pump();
    expect(tester.widget<ButtonStyleButton>(_button('나눠서 이어가기')).onPressed, isNull);

    await tester.enterText(fields.at(0), '정리 기능 설계');
    await tester.ensureVisible(fields.at(3));
    await tester.pump();
    await tester.enterText(fields.at(3), '· 원본은 복사\n\n- 폴더는 미분류 허용\n');
    await tester.pump();
    await tester.tap(_button('나눠서 이어가기'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    final o = result!.toOverrides();
    expect(o['title'], '정리 기능 설계');
    expect(o.containsKey('folder_id'), isTrue, reason: '미분류도 명시해서 보낸다');
    expect(o['folder_id'], isNull);
    final s = o['summary'] as Map<String, dynamic>;
    expect(s['decided'], ['원본은 복사', '폴더는 미분류 허용']);
    expect(s['purpose'], '대화 정리 기능 설계');
    expect(s['next'], ['카드 문구 정하기']);
  });

  group('나눈 대화 안내', () {
    final detail = ThinkConversationDetail.fromRow({
      'id': 'c2',
      'split_from_conversation_id': 'c1',
      'split_summary': _summary,
      'auto_split_suggestions': true,
    });

    testWidgets('방금 나눴으면 안내 문구와 요약을 펼치고 원본으로 가는 길을 준다', (tester) async {
      var opened = 0;
      await tester.pumpWidget(_host(ThinkSplitBanner(detail: detail, justSplit: true, onOpenOriginal: () => opened++)));
      expect(find.text('새 대화로 나눴습니다. 원본은 그대로 남아 있습니다.'), findsOneWidget);
      expect(find.text('대화 정리 기능 설계'), findsOneWidget);
      expect(find.textContaining('기억으로 저장되지 않습니다'), findsOneWidget);
      await tester.tap(find.text('원본 대화로 가기'));
      expect(opened, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('나중에 열면 접혀 있다가 요약 보기로 펼친다. 원본이 지워졌으면 그렇게 알린다', (tester) async {
      await tester.pumpWidget(_host(ThinkSplitBanner(detail: detail, justSplit: false)));
      expect(find.text('앞 대화에서 나눠 온 대화입니다.'), findsOneWidget);
      expect(find.text('대화 정리 기능 설계'), findsNothing);
      expect(find.text('원본 대화는 지워졌습니다'), findsOneWidget);
      await tester.tap(find.text('요약 보기'));
      await tester.pump();
      expect(find.text('대화 정리 기능 설계'), findsOneWidget);
    });
  });

  group('기능 상태 표시', () {
    Future<void> pump(WidgetTester tester, ThinkFeatureStatus f, {String? dbError}) =>
        tester.pumpWidget(_host(ThinkFeatureStatusView(feature: f, dbError: dbError, detailed: true)));

    testWidgets('사용 가능 / 준비 필요(DB·앱) / 확인 불가(Edge 배포 필요)', (tester) async {
      await pump(tester, const ThinkFeatureStatus(state: ThinkFeatureState.ready, edge: 1, db: 1, app: 1));
      expect(find.text('대화 나누기: 사용 가능'), findsOneWidget);
      expect(find.text('버전 · Edge 1 · DB 1 · 앱 1'), findsOneWidget);

      await pump(tester, const ThinkFeatureStatus(state: ThinkFeatureState.dbRequired, edge: 1, db: 0, app: 1));
      expect(find.text('대화 나누기: 준비 필요'), findsOneWidget);
      expect(find.textContaining('DB 반영 필요'), findsOneWidget);
      expect(find.textContaining('20261009100000_ai_think_conversation_split.sql'), findsOneWidget);

      await pump(tester, const ThinkFeatureStatus(state: ThinkFeatureState.appUpdateRequired, edge: 1, db: 1));
      expect(find.text('대화 나누기: 준비 필요'), findsOneWidget);
      expect(find.textContaining('앱 업데이트 필요'), findsOneWidget);

      await pump(tester, const ThinkFeatureStatus(state: ThinkFeatureState.unknown, edge: 1, app: 1),
          dbError: 'permission denied https://x.supabase.co');
      expect(find.text('대화 나누기: 확인 불가'), findsOneWidget);
      expect(find.text('버전 · Edge 1 · DB 확인 못 함 · 앱 1'), findsOneWidget);
      expect(find.text('DB 확인 오류: permission denied [URL]'), findsOneWidget);

      await pump(tester, ThinkFeatureStatus.edgeMissing);
      expect(find.text('대화 나누기: 확인 불가'), findsOneWidget);
      expect(find.textContaining('Edge 배포 필요'), findsOneWidget);
      expect(find.textContaining('버전 ·'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
