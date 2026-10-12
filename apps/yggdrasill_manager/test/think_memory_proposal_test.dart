import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/think/think_action_cards.dart';
import 'package:yggdrasill_manager/screens/think/think_memory_proposal_views.dart';
import 'package:yggdrasill_manager/services/think/think_action_models.dart';
import 'package:yggdrasill_manager/services/think/think_api.dart';
import 'package:yggdrasill_manager/services/think/think_controller.dart';
import 'package:yggdrasill_manager/services/think/think_models.dart';

const _memory = {
  'kind': 'decision',
  'title': '숙제 확인은 수업 시작 10분 안에',
  'content': '수업 시작 후 10분 안에 숙제 확인을 끝낸다.',
  'decision_context': '숙제 확인이 길어져 수업이 밀렸다',
  'decision_reason': '수업 시간을 지키기 위해',
  'alternatives': ['수업 끝에 확인'],
  'tags': ['숙제'],
  'memory_scope': 'department',
  'scope_department': 'education',
  'supersedes_id': null,
};

Map<String, dynamic> _save(String id,
        {String status = 'proposed',
        Map<String, dynamic> memory = _memory,
        Map<String, dynamic> preview = const {},
        Map<String, dynamic>? result,
        bool superseded = false}) =>
    {
      'id': id,
      'conversation_id': 'c1',
      'message_id': 'm2',
      'kind': 'save_memory',
      'status': status,
      'payload': {'memory': memory, 'reason': '사용자가 "10분 안에 끝내자"고 확정했다'},
      'preview': {'title': memory['title'], 'memory_kind': memory['kind'], ...preview},
      'result': result,
      'superseded': superseded,
      'created_at': '2026-10-11T01:00:00Z',
    };

Map<String, dynamic> _change(String id, String op, {String status = 'proposed', Map<String, dynamic>? memory}) => {
      'id': id,
      'conversation_id': 'c1',
      'message_id': 'm4',
      'kind': 'memory_card_change',
      'status': status,
      'payload': {'target_action_id': 'k1', 'op': op, 'memory': memory, 'reason': '같은 취지의 카드가 이미 있다'},
      'preview': {
        'op': op,
        'title': memory?['title'] ?? '숙제 확인은 수업 시작 10분 안에',
        'target_title': '숙제 확인은 수업 시작 10분 안에',
        'target_conversation_id': 'c0',
      },
      'result': null,
      'superseded': false,
      'created_at': '2026-10-11T02:00:00Z',
    };

ThinkAction _action(Map<String, dynamic> row) => ThinkAction.fromRow(row)!;

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 900, height: 1200, child: SingleChildScrollView(child: child)),
        ),
      ),
    );

Finder _button(String label) =>
    find.ancestor(of: find.text(label), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton));

ThinkStatus _rolesReady() => ThinkStatus.fromJson({
      'configured': true,
      'provider': 'openai',
      'models': {},
      'features': {
        'think_roles': {'state': 'ready', 'edge': 1, 'db': 1, 'app': 1},
        'memory_proposals': {'state': 'ready', 'edge': 1, 'db': 1, 'app': 1},
      },
    });

void main() {
  tearDown(() => ThinkController.instance.status = null);

  group('모델', () {
    test('기억 저장 카드 행: 내용·이유·결과를 읽는다', () {
      final a = _action(_save('k1'));
      expect(a.kind, ThinkActionKind.saveMemory);
      expect(a.kind.isMemory, isTrue);
      expect(a.memoryProposal.title, '숙제 확인은 수업 시작 10분 안에');
      expect(a.memoryProposal.alternatives, ['수업 끝에 확인']);
      expect(a.memoryProposal.scopeDepartment, 'education');
      expect(a.memoryReason, contains('확정'));

      final saved = _action(_save('k2', status: 'applied', result: {'memory_id': 'mem1', 'edited': true}));
      expect(saved.savedMemoryId, 'mem1');
      expect(saved.memoryEdited, isTrue);

      final withdrawn = _action(_save('k3', status: 'rejected', result: {'withdrawn_by_action_id': 'x'}));
      expect(withdrawn.memoryWithdrawn, isTrue);

      final change = _action(_change('x1', 'withdraw'));
      expect(change.kind, ThinkActionKind.memoryCardChange);
      expect(change.memoryCardOp, 'withdraw');
      expect(change.memoryTargetActionId, 'k1');
      expect(change.memoryTargetConversationId, 'c0');
      expect(change.memoryProposal.isEmpty, isTrue);
    });

    test('원칙으로 바꿔 보내면 결정 전용 항목과 부서를 비운다', () {
      final m = ThinkMemoryProposal.fromJson(_memory)
          .copyWith(kind: 'principle', memoryScope: 'common', clearDepartment: true);
      final json = m.toJson();
      expect(json['kind'], 'principle');
      expect(json['decision_context'], isNull);
      expect(json['decision_reason'], isNull);
      expect(json['alternatives'], isEmpty);
      expect(json['memory_scope'], 'common');
      expect(json['scope_department'], isNull);
      expect(json['tags'], ['숙제'], reason: '고치기 창에 없는 값은 그대로 보낸다');
    });

    test('앱은 기억 저장 카드를 처리한다고 알리고, 응답에 없으면 Edge 배포 필요로 본다', () {
      expect(ThinkApi.clientFeatures['memory_proposals'], 1);
      final status = ThinkStatus.fromJson({'configured': true, 'provider': 'openai', 'models': {}});
      expect(status.memoryProposals.state, ThinkFeatureState.edgeMissing);
      expect(_rolesReady().memoryProposals.ready, isTrue);
    });

    test('기억 카드는 서로 대체하지 않고, 다른 종류의 제안 대체 규칙은 그대로다', () {
      final c = ThinkController.instance;
      c.putActionForTest(_action({..._save('d1'), 'conversation_id': 'cm'}));
      c.putActionForTest(_action({..._save('d2'), 'conversation_id': 'cm'}));
      c.putActionForTest(_action({..._change('d3', 'withdraw'), 'conversation_id': 'cm'}));
      c.putActionForTest(_action({..._change('d4', 'withdraw'), 'conversation_id': 'cm'}));
      final byId = {for (final a in c.actionsOf('cm')) a.id: a};
      for (final id in ['d1', 'd2', 'd3', 'd4']) {
        expect(byId[id]!.pending, isTrue, reason: '$id는 사용자가 처리할 때까지 대기한다');
      }

      final place = {
        ..._save('p1'),
        'conversation_id': 'cm',
        'kind': 'place_conversation',
        'payload': {'folder_id': 'f1'},
      };
      c.putActionForTest(_action(place));
      c.putActionForTest(_action({...place, 'id': 'p2'}));
      expect(c.actionsOf('cm').firstWhere((a) => a.id == 'p1').superseded, isTrue);
    });
  });

  group('기억 저장 카드', () {
    testWidgets('대기: 종류·제목·내용·배경·이유·대안·제안 이유·범위 제안과 버튼', (tester) async {
      await tester.pumpWidget(_host(ThinkActionCard(action: _action(_save('k1')))));
      expect(find.text('기억 저장 제안'), findsOneWidget);
      expect(find.text('결정'), findsWidgets);
      expect(find.text('숙제 확인은 수업 시작 10분 안에'), findsOneWidget);
      expect(find.text('수업 시작 후 10분 안에 숙제 확인을 끝낸다.'), findsOneWidget);
      expect(find.text('숙제 확인이 길어져 수업이 밀렸다'), findsOneWidget);
      expect(find.text('· 수업 끝에 확인'), findsOneWidget);
      expect(find.text('Think가 지금 제안한 이유'), findsOneWidget);
      expect(find.text('범위 제안: 교육 부서'), findsOneWidget);
      expect(find.text('자료 범위'), findsNothing, reason: '역할 기능이 준비되지 않으면 범위 선택을 보이지 않는다');
      expect(tester.widget<ButtonStyleButton>(_button('승인하고 저장')).onPressed, isNotNull);
      expect(tester.widget<ButtonStyleButton>(_button('고쳐서 승인')).onPressed, isNotNull);
      expect(find.text('거절'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('역할 기능이 준비되면 Think가 제안한 범위를 선택한 채로 보여 준다', (tester) async {
      ThinkController.instance.status = _rolesReady();
      await tester.pumpWidget(_host(ThinkActionCard(action: _action(_save('k1')))));
      expect(find.text('자료 범위'), findsOneWidget);
      expect(find.text('Think가 제안한 범위입니다. 바꾸려면 다른 범위를 고르세요.'), findsOneWidget);
      expect(find.text('범위 제안: 교육 부서'), findsNothing);
      await tester.tap(find.text('공통'));
      await tester.pump();
      expect(find.text('Think가 제안한 범위입니다. 바꾸려면 다른 범위를 고르세요.'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('기존 기억을 대체하면 무엇을 대체하는지 알린다', (tester) async {
      final a = _action(_save('k1', preview: {'supersedes_title': '숙제 확인은 수업 끝에'}));
      await tester.pumpWidget(_host(ThinkActionCard(action: a)));
      expect(find.textContaining('"숙제 확인은 수업 끝에"'), findsOneWidget);
    });

    testWidgets('원칙 카드는 결정 전용 항목을 보이지 않는다', (tester) async {
      final a = _action(_save('k1', memory: {..._memory, 'kind': 'principle'}));
      await tester.pumpWidget(_host(ThinkActionCard(action: a)));
      expect(find.text('원칙'), findsOneWidget);
      expect(find.text('숙제 확인이 길어져 수업이 밀렸다'), findsNothing);
      expect(find.text('· 수업 끝에 확인'), findsNothing);
    });

    testWidgets('저장·거절·삭제 제안으로 닫힘·대체됨은 한 줄로 줄이고 버튼이 없다', (tester) async {
      Future<void> pump(Map<String, dynamic> row) => tester.pumpWidget(_host(ThinkActionCard(action: _action(row))));

      await pump(_save('k1', status: 'applied', result: {'memory_id': 'mem1', 'edited': false}));
      expect(find.textContaining('확정 기억으로 저장함'), findsOneWidget);
      expect(find.text('승인하고 저장'), findsNothing);

      await pump(_save('k2', status: 'rejected'));
      expect(find.textContaining('기억 저장 제안 · 거절함'), findsOneWidget);

      await pump(_save('k3', status: 'rejected', result: {'withdrawn_by_action_id': 'x1'}));
      expect(find.textContaining('삭제 제안 승인으로 닫힘'), findsOneWidget);

      await pump(_save('k4', status: 'rejected', superseded: true, result: {'replaced_by_action_id': 'x2'}));
      expect(find.textContaining('새 제안으로 대체됨'), findsOneWidget);
      expect(find.text('승인하고 저장'), findsNothing);
    });
  });

  group('기억 카드 변경', () {
    testWidgets('삭제: 대상과 안내, 고쳐서 승인 없음', (tester) async {
      await tester.pumpWidget(_host(ThinkActionCard(action: _action(_change('x1', 'withdraw')))));
      expect(find.text('기억 카드 변경 제안'), findsOneWidget);
      expect(find.text('대상: 대기 중인 기억 저장 카드 "숙제 확인은 수업 시작 10분 안에"'), findsOneWidget);
      expect(find.textContaining('이미 저장된 기억은 바뀌지 않습니다'), findsOneWidget);
      expect(tester.widget<ButtonStyleButton>(_button('삭제 승인')).onPressed, isNotNull);
      expect(find.text('고쳐서 승인'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('대체: 새 카드 내용과 고쳐서 승인', (tester) async {
      final a = _action(_change('x2', 'replace', memory: {..._memory, 'title': '숙제 확인은 15분 안에'}));
      await tester.pumpWidget(_host(ThinkActionCard(action: a)));
      expect(find.text('새 카드 내용'), findsOneWidget);
      expect(find.text('숙제 확인은 15분 안에'), findsOneWidget);
      expect(find.textContaining('새 카드에서 다시 승인'), findsOneWidget);
      expect(find.text('새 카드로 대체 승인'), findsOneWidget);
      expect(find.text('고쳐서 승인'), findsOneWidget);
    });

    testWidgets('승인·거절된 변경 카드는 한 줄로 줄인다', (tester) async {
      await tester.pumpWidget(_host(ThinkActionCard(action: _action(_change('x3', 'revise', status: 'applied')))));
      expect(find.textContaining('기억 카드 변경 · 수정 승인함'), findsOneWidget);
      await tester.pumpWidget(_host(ThinkActionCard(action: _action(_change('x4', 'withdraw', status: 'rejected')))));
      expect(find.textContaining('기억 카드 변경 제안 · 거절함'), findsOneWidget);
    });
  });

  testWidgets('고치기 창: 제목이 비면 확인할 수 없고, 원칙으로 바꾸면 결정 전용 칸을 숨긴다', (tester) async {
    ThinkMemoryProposal? result;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await ThinkMemoryEditDialog.show(
                context,
                memory: ThinkMemoryProposal.fromJson(_memory),
                showScope: true,
              );
            },
            child: const Text('열기'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    expect(find.text('기억 내용 고치기'), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(5));

    await tester.enterText(find.byType(TextField).at(0), ' ');
    await tester.pump();
    expect(tester.widget<ButtonStyleButton>(_button('고친 내용으로 저장')).onPressed, isNull);

    await tester.enterText(find.byType(TextField).at(0), '숙제 확인 원칙');
    await tester.tap(find.text('원칙'));
    await tester.pump();
    expect(find.byType(TextField), findsNWidgets(2));

    await tester.ensureVisible(find.text('공통'));
    await tester.tap(find.text('공통'));
    await tester.pump();
    await tester.tap(_button('고친 내용으로 저장'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    final json = result!.toJson();
    expect(json['title'], '숙제 확인 원칙');
    expect(json['kind'], 'principle');
    expect(json['decision_context'], isNull);
    expect(json['memory_scope'], 'common');
    expect(json['scope_department'], isNull);
  });

  group('기능 상태 문구', () {
    test('DB 반영 필요면 마이그레이션 파일을 알려 준다', () {
      const f = ThinkFeatureStatus(state: ThinkFeatureState.dbRequired, edge: 1, db: 0, app: 1);
      expect(thinkMemoryProposalsFeatureReason(f), contains('20261011100000_ai_think_memory_proposals.sql'));
      expect(thinkMemoryProposalsFeatureReason(ThinkFeatureStatus.edgeMissing), contains('Edge 배포 필요'));
    });
  });
}
