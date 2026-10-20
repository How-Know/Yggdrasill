import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/think/think_action_cards.dart';
import 'package:yggdrasill_manager/screens/think/think_message_tile.dart';
import 'package:yggdrasill_manager/screens/think/think_organize_panel.dart';
import 'package:yggdrasill_manager/services/think/think_action_models.dart';
import 'package:yggdrasill_manager/services/think/think_api.dart';
import 'package:yggdrasill_manager/services/think/think_controller.dart';
import 'package:yggdrasill_manager/services/think/think_models.dart';

Map<String, dynamic> _row(
  String id,
  String kind, {
  String status = 'proposed',
  String? messageId = 'm2',
  String conversationId = 'c1',
  Map<String, dynamic> payload = const {},
  Map<String, dynamic> preview = const {},
  Map<String, dynamic>? result,
  String createdAt = '2026-10-12T01:00:00Z',
}) =>
    {
      'id': id,
      'conversation_id': conversationId,
      'message_id': messageId,
      'kind': kind,
      'status': status,
      'payload': payload,
      'preview': preview,
      'result': result,
      'superseded': false,
      'created_at': createdAt,
    };

Map<String, dynamic> _exclude(String id, {String status = 'proposed', Map<String, dynamic>? result, bool linked = true}) =>
    _row(
      id,
      'exclude_context',
      status: status,
      result: result,
      payload: {
        'message_ids': ['m1', 'm2'],
        'reason': '사용자가 앞의 계산 예시는 틀렸으니 버리자고 했다',
        'impact': '이후 답변이 틀린 계산 예시를 참고하지 않는다',
      },
      preview: {
        'title': '메시지 2개 맥락 제외',
        'targets': [
          {'id': 'm1', 'role': 'user', 'excerpt': '이 예시로 계산해 줘', 'created_at': '2026-10-12T00:00:00Z'},
          {'id': 'm2', 'role': 'assistant', 'excerpt': '계산 결과는 42입니다', 'created_at': '2026-10-12T00:01:00Z'},
        ],
        'impact': '이후 답변이 틀린 계산 예시를 참고하지 않는다',
        'linked': linked
            ? {
                'documents': [
                  {'id': 'n1', 'kind': 'document', 'title': '계산 정리 문서'},
                ],
                'memories': [
                  {'id': 'mem1', 'title': '예시 계산 원칙'},
                ],
              }
            : {'documents': [], 'memories': []},
        'has_summary': true,
      },
    );

Map<String, dynamic> _mark(String id, {String status = 'proposed', Map<String, dynamic>? result}) => _row(
      id,
      'mark_important',
      status: status,
      result: result,
      payload: {
        'message_ids': ['m1'],
        'reason': '사용자가 확정한 기준이 담긴 질문이다',
      },
      preview: {
        'title': '메시지 1개 중요 표시',
        'targets': [
          {'id': 'm1', 'role': 'user', 'excerpt': '숙제 확인은 10분 안에 끝내자'},
        ],
      },
    );

const _summaryJson = {
  'purpose': '숙제 확인 방식 정리',
  'decided': ['10분 안에 끝낸다'],
  'open': ['늦게 낸 숙제 처리'],
  'status': '확인 순서를 정하는 중',
  'next': [
    {'what': '확인 순서 초안 만들기', 'owner': '', 'prerequisite': '', 'done_when': ''},
    {'what': '선생님 의견 듣기', 'owner': '원장', 'prerequisite': '초안', 'done_when': '의견 3개 이상'},
  ],
};

Map<String, dynamic> _summary(String id,
        {String status = 'proposed', String? base, Map<String, dynamic>? previous, Map<String, dynamic>? result}) =>
    _row(
      id,
      'progress_summary',
      status: status,
      result: result,
      payload: {'summary': _summaryJson, 'reason': '결정이 몇 가지 쌓였다', 'base_action_id': base, 'through_message_id': 'm2'},
      preview: {'title': '숙제 확인 방식 정리', if (previous != null) 'previous': previous},
    );

Map<String, dynamic> _criteria(String id, {String status = 'proposed', int base = 2, Map<String, dynamic>? result}) => _row(
      id,
      'department_criteria_change',
      status: status,
      result: result,
      payload: {
        'department': 'education',
        'criteria': {
          'questions': ['학생 수준에 맞나?'],
          'risks': ['숙제 양이 과하다'],
          'priority_memory_ids': ['mem1'],
        },
        'base_version': base,
        'reason': '교육 부서가 계속 같은 질문을 놓쳤다',
      },
      preview: {
        'department': 'education',
        'before': {
          'questions': ['수업 목표와 맞나?'],
          'risks': [],
          'priority_memories': [],
        },
        'after': {
          'questions': ['학생 수준에 맞나?'],
          'risks': ['숙제 양이 과하다'],
          'priority_memories': [
            {'id': 'mem1', 'title': '숙제 확인은 10분 안에'},
          ],
        },
      },
    );

Map<String, dynamic> _place(String id, {String? afterHandover}) => _row(
      id,
      'place_conversation',
      payload: {'folder_id': 'f1'},
      preview: {
        'path': '교육 > 숙제',
        'current': '',
        'reason': '숙제 이야기다',
        if (afterHandover != null) 'after_handover': afterHandover,
      },
    );

Map<String, dynamic> _handover(String id) => _row(
      id,
      'handover_department',
      payload: {'to_department': 'education', 'reason': '수업 운영 이야기다'},
      preview: {'from_department': 'lead', 'to_department': 'education'},
    );

ThinkAction _action(Map<String, dynamic> row) => ThinkAction.fromRow(row)!;

ThinkMessage _msg(String id, String role, {bool important = false}) =>
    ThinkMessage(id: id, role: role, content: '내용 $id', status: ThinkMessageStatus.complete, markedImportant: important);

ThinkStatus _status({String organize = 'ready'}) => ThinkStatus.fromJson({
      'configured': true,
      'provider': 'openai',
      'models': {},
      'features': {
        'auto_organize': {'state': organize, 'edge': 1, 'db': organize == 'ready' ? 1 : 0, 'app': 1},
      },
    });

Widget _host(Widget child, {double height = 1400}) => MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 900, height: height, child: SingleChildScrollView(child: child)),
        ),
      ),
    );

Finder _button(String label) =>
    find.ancestor(of: find.text(label), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton));

void _reset() {
  final c = ThinkController.instance;
  c.status = null;
  c.selectedId = null;
  c.autoOrganizeEnabled = null;
  c.organizeErrors.clear();
  c.organizeOutcomes.clear();
  c.organizePanelOpen = false;
  c.organizeFocusMessageId = null;
  c.details.clear();
  c.departmentCriteria = {};
}

void main() {
  tearDown(_reset);

  group('모델', () {
    test('새 제안 종류 네 개를 읽고, 정리 패널·되돌리기 대상을 구분한다', () {
      expect(ThinkActionKind.parse('exclude_context'), ThinkActionKind.excludeContext);
      expect(ThinkActionKind.parse('mark_important'), ThinkActionKind.markImportant);
      expect(ThinkActionKind.parse('progress_summary'), ThinkActionKind.progressSummary);
      expect(ThinkActionKind.parse('department_criteria_change'), ThinkActionKind.departmentCriteriaChange);
      for (final k in [
        ThinkActionKind.excludeContext,
        ThinkActionKind.markImportant,
        ThinkActionKind.progressSummary,
        ThinkActionKind.departmentCriteriaChange,
      ]) {
        expect(k.isOrganize && k.isOrganizeOnly, isTrue, reason: '$k는 늘 정리 패널에서 처리한다');
      }
      expect(ThinkActionKind.placeConversation.isOrganize, isTrue);
      expect(ThinkActionKind.placeConversation.isOrganizeOnly, isFalse);
      expect(ThinkActionKind.codeChange.isOrganize, isFalse, reason: '코드 제안은 카드 그대로');
      expect(ThinkActionKind.deleteFolder.isOrganize, isFalse, reason: '삭제 제안은 카드 그대로');
      expect(ThinkActionKind.excludeContext.isUndoable, isTrue);
      expect(ThinkActionKind.markImportant.isUndoable, isTrue);
      expect(ThinkActionKind.progressSummary.isUndoable, isFalse);
    });

    test('맥락 제외 제안: 대상·영향·연결된 문서와 기억·요약 경고를 읽는다', () {
      final a = _action(_exclude('e1'));
      expect(a.organizeMessageIds, ['m1', 'm2']);
      expect(a.organizeTargets.map((t) => t.isUser), [true, false]);
      expect(a.organizeTargets.last.excerpt, '계산 결과는 42입니다');
      expect(a.exclusionImpact, contains('참고하지 않는다'));
      expect(a.linkedDocuments.single.title, '계산 정리 문서');
      expect(a.linkedMemories.single.title, '예시 계산 원칙');
      expect(a.exclusionHasSummary, isTrue);
      expect(a.organizeReason, contains('버리자'));

      final applied = _action(_exclude('e2', status: 'applied', result: {
        'excluded_ids': ['m2'],
        'already_excluded_ids': ['m1'],
      }));
      expect(applied.excludedIds, ['m2'], reason: '되돌리기는 새로 뺀 메시지만 되돌린다');
    });

    test('진행 요약 제안: 다섯 칸, 다음 행동의 담당은 비어 있으면 정하지 않은 것', () {
      final a = _action(_summary('s1', base: 's0', previous: {'purpose': '예전 목적'}));
      final s = a.progressSummaryProposal;
      expect(s.purpose, '숙제 확인 방식 정리');
      expect(s.decided, ['10분 안에 끝낸다']);
      expect(s.next.first.owner, isEmpty);
      expect(s.next.last.owner, '원장');
      expect(s.next.last.doneWhen, '의견 3개 이상');
      expect(a.previousProgressSummary?.purpose, '예전 목적');
      expect(a.progressSummaryBaseActionId, 's0');
      expect(_action(_summary('s2')).previousProgressSummary, isNull);
      expect(_action(_summary('s2')).progressSummaryBaseActionId, isNull);

      final legacy = ThinkProgressSummary.fromJson({
        'purpose': '목적',
        'next': ['문자열 행동', '', {'what': ''}],
      });
      expect(legacy.next.map((n) => n.what), ['문자열 행동'], reason: '빈 행동은 버린다');
      expect(legacy.toJson()['next'], [
        {'what': '문자열 행동', 'owner': '', 'prerequisite': '', 'done_when': ''},
      ]);
    });

    test('부서 기준 제안: 부서·전후·판을 읽고, 승인 때 보내는 형태는 기억 id만 담는다', () {
      final a = _action(_criteria('k1'));
      expect(a.criteriaDepartment, ThinkRoleId.education);
      expect(a.criteriaBefore.questions, ['수업 목표와 맞나?']);
      expect(a.criteriaAfter.priorityMemories.single.title, '숙제 확인은 10분 안에');
      expect(a.criteriaBaseVersion, 2);
      expect(a.criteriaAfter.toCriteriaJson(), {
        'questions': ['학생 수준에 맞나?'],
        'risks': ['숙제 양이 과하다'],
        'priority_memory_ids': ['mem1'],
      });
      final row = ThinkDepartmentCriteria.fromRow({
        'department': 'product',
        'questions': ['풀이가 맞나?'],
        'risks': [],
        'priority_memory_ids': ['mem2'],
        'version': 3,
        'updated_via': 'owner',
        'updated_at': '2026-10-12T00:00:00Z',
      });
      expect(row.department, ThinkRoleId.product);
      expect(row.version, 3);
      expect(row.updatedVia, 'owner');
    });

    test('분류 제안이 같은 답변의 부서 넘기기 뒤에 적용되면 받을 부서를 읽는다', () {
      expect(_action(_place('p1', afterHandover: 'engineering')).placeAfterHandover, ThinkRoleId.engineering);
      expect(_action(_place('p2')).placeAfterHandover, isNull);
    });

    test('처리 결과 한 줄: 승인 순서대로 종류별로 묶는다', () {
      final applied = [
        _action(_row('a1', 'save_memory', status: 'applied')),
        _action(_row('a2', 'save_memory', status: 'applied')),
        _action(_row('a3', 'place_conversation', status: 'applied')),
        _action(_exclude('a4', status: 'applied', result: {
          'excluded_ids': ['m1', 'm2'],
        })),
        _action(_mark('a5', status: 'applied', result: {'marked_ids': []})),
      ];
      expect(thinkOrganizeSummary(applied), '분류 완료 · 메시지 2개 맥락에서 제외 · 중요 표시(이미 표시된 메시지) · 기억 2건 저장');
      expect(thinkOrganizeSummary(const []), isEmpty);
    });

    test('일괄 승인 결과 항목을 읽고, 아는 코드는 사람이 읽는 문구로 바꾼다', () {
      final ok = ThinkBatchItemResult.fromJson({'id': 'a1', 'ok': true, 'already': true, 'action': _exclude('a1', status: 'applied')});
      expect(ok.ok && ok.already, isTrue);
      expect(ok.action?.status, ThinkActionStatus.applied);
      final failed = ThinkBatchItemResult.fromJson({
        'id': 'a2',
        'ok': false,
        'code': 'progress_summary_changed',
        'message': 'progress_summary_changed',
        'action': _summary('a2'),
      });
      expect(failed.ok, isFalse);
      expect(failed.action?.pending, isTrue, reason: '실패한 항목은 대기 상태로 남는다');
      expect(ThinkApi.batchErrorMessage(failed), contains('진행 요약이 바뀌었습니다'));
      expect(
        ThinkApi.batchErrorMessage(const ThinkBatchItemResult(id: 'x', ok: false, code: 'place_department_mismatch')),
        contains('부서 넘기기를 먼저'),
      );
      expect(
        ThinkApi.batchErrorMessage(const ThinkBatchItemResult(id: 'x', ok: false, code: 'action_kind_not_in_batch')),
        contains('답변 아래 카드'),
      );
    });

    test('기능 상태·설정·메시지·대화 정보: 없으면 이전 동작으로 본다', () {
      expect(ThinkApi.clientFeatures['auto_organize'], 1);
      expect(ThinkStatus.fromJson({'configured': true, 'provider': 'openai', 'models': {}}).autoOrganize.state,
          ThinkFeatureState.edgeMissing);
      expect(_status().autoOrganize.ready, isTrue);
      expect(_status(organize: 'db_required').autoOrganize.state, ThinkFeatureState.dbRequired);

      expect(ThinkSettings.fromRow({'auto_organize_enabled': false}).autoOrganizeEnabled, isFalse);
      expect(ThinkSettings.fromRow({}).autoOrganizeEnabled, isTrue, reason: '기본은 켜짐');
      expect(ThinkSettings.fromRow({}).autoOrganizeColumn, isFalse, reason: '열이 없으면 옛 DB');

      final m = ThinkMessage.fromRow({
        'id': 'm1',
        'role': 'user',
        'content': '내용',
        'status': 'complete',
        'marked_important': true,
        'created_at': '2026-10-12T00:00:00Z',
      });
      expect(m.markedImportant, isTrue);

      final d = ThinkConversationDetail.fromRow({
        'id': 'c1',
        'progress_summary': {..._summaryJson, 'action_id': 's1', 'approved_at': '2026-10-12T00:00:00Z', 'edited': true},
      });
      expect(d.progressSummary?.actionId, 's1');
      expect(d.progressSummary?.edited, isTrue);
      expect(ThinkConversationDetail.fromRow({'id': 'c1', 'progress_summary': {}}).progressSummary, isNull);
    });

    test('기능 상태 문구: DB 반영 필요면 마이그레이션 파일을 알려 준다', () {
      const f = ThinkFeatureStatus(state: ThinkFeatureState.dbRequired, edge: 1, db: 0, app: 1);
      expect(thinkOrganizeFeatureReason(f), contains('20261012120000_ai_think_auto_organize.sql'));
      expect(thinkOrganizeFeatureReason(ThinkFeatureStatus.edgeMissing), contains('Edge 배포 필요'));
    });
  });

  group('컨트롤러', () {
    test('새 종류는 늘 정리 패널로, 예전 종류는 일괄 승인을 쓸 수 있을 때만 모은다', () {
      final c = ThinkController.instance;
      c.selectedId = 'co1';
      c.putActionForTest(_action({..._place('p1'), 'conversation_id': 'co1'}));
      c.putActionForTest(_action({..._exclude('e1'), 'conversation_id': 'co1'}));
      c.putActionForTest(_action(_row('k1', 'code_change', conversationId: 'co1', payload: {'title': '코드'})));

      final place = c.actionsOf('co1').firstWhere((a) => a.id == 'p1');
      final exclude = c.actionsOf('co1').firstWhere((a) => a.id == 'e1');
      final code = c.actionsOf('co1').firstWhere((a) => a.id == 'k1');
      expect(c.inOrganizePanel(exclude), isTrue);
      expect(c.inOrganizePanel(place), isFalse, reason: '옛 서버에서는 분류 카드가 답변 아래에 그대로 펼쳐진다');
      expect(c.inOrganizePanel(code), isFalse);

      c.status = _status();
      expect(c.inOrganizePanel(place), isTrue);
      expect(c.inOrganizePanel(code), isFalse, reason: '코드 제안은 정리 패널에 넣지 않는다');
    });

    test('패널 항목은 서버 승인 순서(넘기기 → 분류 → 맥락 제외 → … → 진행 요약)로 정렬한다', () {
      final c = ThinkController.instance;
      c.status = _status();
      c.selectedId = 'co2';
      for (final row in [_summary('s1'), _exclude('e1'), _place('p1'), _handover('h1'), _mark('i1')]) {
        c.putActionForTest(_action({...row, 'conversation_id': 'co2'}));
      }
      expect(c.pendingOrganize.map((a) => a.id), ['h1', 'p1', 'e1', 'i1', 's1']);
      expect(c.pendingOrganizeFor('m2').length, 5);
      expect(c.pendingOrganizeFor('other'), isEmpty);
    });
  });

  group('답변 아래 카드', () {
    testWidgets('승인한 맥락 제외는 한 줄로 결과와 되돌리기를 보인다', (tester) async {
      await tester.pumpWidget(_host(ThinkActionCard(
        action: _action(_exclude('e1', status: 'applied', result: {
          'excluded_ids': ['m1', 'm2'],
        })),
      )));
      expect(find.textContaining('메시지 2개를 이후 답변 맥락에서 뺌'), findsOneWidget);
      expect(find.text('되돌리기'), findsOneWidget);

      await tester.pumpWidget(_host(ThinkActionCard(
        action: _action(_exclude('e2', status: 'applied', result: {'excluded_ids': []})),
      )));
      expect(find.textContaining('이미 빠져 있던 메시지'), findsOneWidget);
      expect(find.text('되돌리기'), findsNothing, reason: '바뀐 것이 없으면 되돌릴 것도 없다');

      await tester.pumpWidget(_host(ThinkActionCard(action: _action(_exclude('e3', status: 'undone')))));
      expect(find.textContaining('되돌림'), findsOneWidget);
    });

    testWidgets('중요 표시·진행 요약·부서 기준의 결과 줄', (tester) async {
      await tester.pumpWidget(_host(ThinkActionCard(
        action: _action(_mark('i1', status: 'applied', result: {
          'marked_ids': ['m1'],
        })),
      )));
      expect(find.textContaining('메시지 1개에 표시함'), findsOneWidget);

      await tester.pumpWidget(_host(ThinkActionCard(action: _action(_summary('s1', status: 'applied', result: {'edited': true})))));
      expect(find.textContaining('진행 요약 · 고쳐서 승인함 · 숙제 확인 방식 정리'), findsOneWidget);

      await tester.pumpWidget(_host(ThinkActionCard(
        action: _action(_criteria('k1', status: 'applied', result: {'department': 'education', 'version': 3, 'edited': false})),
      )));
      expect(find.textContaining('교육 부서 기준을 바꿈 (판 3)'), findsOneWidget);

      await tester.pumpWidget(_host(ThinkActionCard(action: _action(_criteria('k2', status: 'rejected')))));
      expect(find.textContaining('부서 기준 제안 · 거절함'), findsOneWidget);
    });

    testWidgets('대기 중인 새 종류 카드가 그려지면 정리 패널로 보낸다', (tester) async {
      await tester.pumpWidget(_host(ThinkActionCard(action: _action(_summary('s1')))));
      expect(find.text('진행 요약 제안'), findsOneWidget);
      expect(find.text('정리 패널 열기'), findsOneWidget);
      expect(find.text('승인'), findsNothing, reason: '카드에서 따로 승인하지 않는다');
    });

    testWidgets('부서 넘기기 뒤에 적용될 분류 카드는 넘기기를 먼저 승인하라고 알린다', (tester) async {
      await tester.pumpWidget(_host(ThinkActionCard(action: _action(_place('p1', afterHandover: 'education')))));
      expect(find.textContaining('교육 부서로 넘긴 다음에 넣는 분류입니다'), findsOneWidget);
    });

    testWidgets('정리 제안 줄: 건수·종류·처리 못 한 건수', (tester) async {
      var opened = 0;
      await tester.pumpWidget(_host(ThinkOrganizeEntry(
        actions: [_action(_exclude('e1')), _action(_mark('i1')), _action(_row('m1', 'save_memory'))],
        failed: 1,
        onOpen: () => opened++,
      )));
      expect(find.text('정리 제안 3건'), findsOneWidget);
      expect(find.text('맥락 제외 · 중요 표시 · 기억 저장'), findsOneWidget);
      expect(find.text('처리 못 한 1건'), findsOneWidget);
      await tester.tap(find.text('확인하기'));
      expect(opened, 1);
    });
  });

  group('정리 패널', () {
    void open() {
      final c = ThinkController.instance;
      c.status = _status();
      c.autoOrganizeEnabled = true;
      c.selectedId = 'c1';
      c.setMessagesForTest('c1', [_msg('m1', 'user'), _msg('m2', 'assistant')]);
      c.putActionForTest(_action(_summary('s1')));
      c.putActionForTest(_action(_exclude('e1')));
      c.putActionForTest(_action(_mark('i1')));
      c.putActionForTest(_action(_row('k1', 'code_change', payload: {'title': '코드 수정'})));
    }

    Widget panel({VoidCallback? onClose}) => MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 420, height: 2400, child: ThinkOrganizePanel(onClose: onClose ?? () {})),
          ),
        );

    testWidgets('처음에는 아무것도 고르지 않고, 고른 만큼 승인 버튼에 보인다', (tester) async {
      open();
      await tester.pumpWidget(panel());
      expect(find.text('이번 대화 정리 제안'), findsOneWidget);
      expect(find.text('3건'), findsOneWidget, reason: '코드 제안은 패널에 들어오지 않는다');
      expect(find.text('자동 제안 켜짐'), findsOneWidget);
      expect(tester.widget<ButtonStyleButton>(_button('선택한 항목 승인')).onPressed, isNull);

      final boxes = find.byType(Checkbox);
      final first = tester.widget<Checkbox>(boxes.first);
      expect(first.value, isFalse);

      await tester.tap(boxes.first);
      await tester.pump();
      expect(find.text('선택한 항목 승인 (1)'), findsOneWidget);
      expect(tester.widget<ButtonStyleButton>(_button('선택한 항목 승인 (1)')).onPressed, isNotNull);

      await tester.tap(find.text('모두 고르기'));
      await tester.pump();
      expect(find.text('선택한 항목 승인 (3)'), findsOneWidget);
      expect(find.text('모두 풀기'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('맥락 제외 항목은 대상 메시지·영향·연결된 문서와 기억·요약 경고를 한 화면에 보인다', (tester) async {
      open();
      await tester.pumpWidget(panel());
      expect(find.text('메시지 2개를 이후 답변 맥락에서 빼기'), findsOneWidget);
      expect(find.text('이 예시로 계산해 줘'), findsOneWidget);
      expect(find.text('계산 결과는 42입니다'), findsOneWidget);
      expect(find.text('이후 답변에 미치는 영향'), findsOneWidget);
      expect(find.textContaining('계산 정리 문서'), findsOneWidget);
      expect(find.textContaining('예시 계산 원칙'), findsOneWidget);
      expect(find.textContaining('승인된 진행 요약에 이 내용이 남아 있을 수 있습니다'), findsOneWidget);
      expect(find.textContaining('메시지는 지우지 않고'), findsOneWidget);
      expect(find.textContaining('반드시 지켜야 하는 원칙이 되지는 않습니다'), findsOneWidget, reason: '중요 표시는 화면 표시일 뿐');
    });

    testWidgets('대상 메시지를 하나 빼면 제목 수가 바뀌고 고침 표시가 붙으며, 마지막 하나는 뺄 수 없다', (tester) async {
      open();
      await tester.pumpWidget(panel());
      final excludeTargets = find.descendant(
        of: find.ancestor(of: find.text('이 예시로 계산해 줘'), matching: find.byType(Row)).first,
        matching: find.byType(Checkbox),
      );
      await tester.tap(excludeTargets);
      await tester.pump();
      expect(find.text('메시지 1개를 이후 답변 맥락에서 빼기'), findsOneWidget);
      expect(find.text('고침'), findsOneWidget);
      final last = find.descendant(
        of: find.ancestor(of: find.text('계산 결과는 42입니다'), matching: find.byType(Row)).first,
        matching: find.byType(Checkbox),
      );
      expect(tester.widget<Checkbox>(last).onChanged, isNull);
    });

    testWidgets('진행 요약 항목은 승인 전 제안으로 보이고, 실행이 시작되지 않는다고 알린다', (tester) async {
      open();
      await tester.pumpWidget(panel());
      expect(find.text('Think 제안 · 승인 전'), findsOneWidget);
      expect(find.text('숙제 확인 방식 정리'), findsOneWidget);
      expect(find.text('담당·완료 기준 정하지 않음'), findsOneWidget);
      expect(find.text('담당: 원장 · 먼저: 초안 · 완료 기준: 의견 3개 이상'), findsOneWidget);
      expect(find.textContaining('코드 작업·배포·DB 변경은 시작되지 않습니다'), findsOneWidget);
    });

    testWidgets('승인된 요약이 그사이 바뀌었으면 충돌을 미리 알린다', (tester) async {
      open();
      final c = ThinkController.instance;
      c.details['c1'] = ThinkConversationDetail.fromRow({
        'id': 'c1',
        'progress_summary': {..._summaryJson, 'action_id': 'other'},
      });
      await tester.pumpWidget(panel());
      expect(find.textContaining('그사이 이 대화의 진행 요약이 바뀌었습니다'), findsOneWidget);
    });

    testWidgets('실패한 항목은 이유와 함께 남고, 답변 중에는 승인할 수 없다는 안내가 없다', (tester) async {
      open();
      ThinkController.instance.organizeErrors['e1'] = '대상 메시지가 없어졌습니다. 새로고침하세요.';
      await tester.pumpWidget(panel());
      expect(find.text('대상 메시지가 없어졌습니다. 새로고침하세요.'), findsOneWidget);
      expect(find.text('답변이 끝난 뒤 승인할 수 있습니다.'), findsNothing);
    });

    testWidgets('처리 결과를 보이고, 나중에 보기는 닫기만 한다', (tester) async {
      open();
      var closed = 0;
      final c = ThinkController.instance;
      c.organizeOutcomes['c1'] = ThinkOrganizeOutcome(
        applied: [_action(_row('a1', 'save_memory', status: 'applied')), _action(_row('a2', 'place_conversation', status: 'applied'))],
        failed: const [ThinkBatchItemResult(id: 'gone', ok: false, code: 'action_not_found')],
      );
      await tester.pumpWidget(panel(onClose: () => closed++));
      expect(find.textContaining('처리함: 분류 완료 · 기억 1건 저장'), findsOneWidget);
      expect(find.textContaining('처리하지 못한 1건'), findsOneWidget);
      expect(find.textContaining('제안이 없어졌습니다'), findsOneWidget);
      await tester.tap(find.text('나중에 보기'));
      expect(closed, 1);
      expect(c.pendingOrganize.length, 3, reason: '나중에 보기는 아무것도 바꾸지 않는다');
    });

    testWidgets('대기 중인 제안이 없으면 비어 있다고 알린다', (tester) async {
      final c = ThinkController.instance;
      c.status = _status();
      c.autoOrganizeEnabled = false;
      c.selectedId = 'c-empty';
      await tester.pumpWidget(panel());
      expect(find.text('확인을 기다리는 정리 제안이 없습니다.'), findsOneWidget);
      expect(find.text('자동 제안 꺼짐'), findsOneWidget);
    });
  });

  group('진행 요약·부서 기준 창', () {
    testWidgets('요약 고치기: 목적이 비면 담을 수 없고, 다음 행동을 더하고 뺄 수 있다', (tester) async {
      ThinkProgressSummary? result;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await ThinkProgressSummaryEditDialog.show(context, summary: ThinkProgressSummary.fromJson(_summaryJson));
              },
              child: const Text('열기'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();
      expect(find.text('진행 요약 고치기'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, ' ');
      await tester.pump();
      expect(tester.widget<ButtonStyleButton>(_button('고친 내용 담기')).onPressed, isNull);
      await tester.enterText(find.byType(TextField).first, '새 목적');
      await tester.pump();

      await tester.tap(find.byTooltip('이 행동 빼기').first);
      await tester.pumpAndSettle();
      await tester.tap(_button('고친 내용 담기'));
      await tester.pumpAndSettle();

      expect(result?.purpose, '새 목적');
      expect(result?.next.map((n) => n.what), ['선생님 의견 듣기']);
      expect(result?.decided, ['10분 안에 끝낸다']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('부서 기준 고치기: 줄마다 하나, 8개까지만 담는다', (tester) async {
      ThinkCriteriaView? result;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await ThinkCriteriaEditDialog.show(
                  context,
                  department: ThinkRoleId.education,
                  initial: const ThinkCriteriaView(questions: ['기존 질문']),
                  confirmLabel: '고친 내용 담기',
                );
              },
              child: const Text('열기'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();
      expect(find.text('교육 부서 기준'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, List.generate(10, (i) => '· 질문 $i').join('\n'));
      await tester.tap(_button('고친 내용 담기'));
      await tester.pumpAndSettle();
      expect(result?.questions.length, 8);
      expect(result?.questions.first, '질문 0', reason: '앞의 글머리표는 떼어 낸다');
    });

    testWidgets('승인된 요약 보기: 빈 칸은 "없음"', (tester) async {
      await tester.pumpWidget(_host(const ThinkProgressSummaryView(summary: ThinkProgressSummary(purpose: '목적만'))));
      expect(find.text('목적만'), findsOneWidget);
      expect(find.text('없음'), findsNWidgets(4));
      expect(find.text('Think 제안 · 승인 전'), findsNothing);
    });
  });

  group('중요 표시', () {
    testWidgets('답변: 표시되면 "중요" 표시가 붙고, 버튼은 콜백이 있을 때만 보인다', (tester) async {
      var toggled = 0;
      await tester.pumpWidget(_host(ThinkMessageTile(message: _msg('m2', 'assistant', important: true), onToggleImportant: () => toggled++)));
      expect(find.text('중요'), findsOneWidget);
      await tester.tap(find.byTooltip('중요 표시 지우기'));
      expect(toggled, 1);

      await tester.pumpWidget(_host(ThinkMessageTile(message: _msg('m3', 'assistant'))));
      expect(find.text('중요'), findsNothing);
      expect(find.byIcon(Icons.flag_outlined), findsNothing);
    });

    testWidgets('질문: 표시된 메시지는 깃발이 늘 보인다', (tester) async {
      await tester.pumpWidget(_host(ThinkMessageTile(message: _msg('m1', 'user', important: true))));
      expect(find.byIcon(Icons.flag), findsOneWidget);
      await tester.pumpWidget(_host(ThinkMessageTile(message: _msg('m4', 'user'), onToggleImportant: () {})));
      expect(find.byIcon(Icons.flag_outlined), findsNothing, reason: '마우스를 올리기 전에는 숨긴다');
    });
  });
}
