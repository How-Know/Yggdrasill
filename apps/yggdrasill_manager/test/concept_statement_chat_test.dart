import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yggdrasill_manager/screens/curriculum/widgets/concept_chat_panel.dart';
import 'package:yggdrasill_manager/services/concept_service.dart';
import 'package:yggdrasill_manager/services/concept_statement_service.dart';
import 'package:yggdrasill_manager/services/concept_statement_store.dart';
import 'package:yggdrasill_manager/services/think/think_api.dart';
import 'package:yggdrasill_manager/services/think/think_concept_chat_controller.dart';
import 'package:yggdrasill_manager/services/think/think_models.dart';
import 'package:yggdrasill_manager/services/think/think_send_lock.dart';

const _conv = '0d6c1b52-8a3e-4f5d-9b7c-1e2f3a4b5c6d';
const _concept = '6f1d2c3b-4a5e-4f60-8a7b-9c0d1e2f3a4b';
const _statement = '7a1d2c3b-4a5e-4f60-8a7b-9c0d1e2f3a01';

/// 읽기만 한다. 쓰기는 이 시험에서 부르지 않는다.
class _ReadOnlyStatements implements ConceptStatementBackend {
  @override
  Future<List<ConceptStatement>> statementsFor(String conceptId) async => [
        const ConceptStatement(
          id: _statement,
          conceptId: _concept,
          role: ConceptStatementRole.statement,
          version: 1,
          content: ConceptStatementText(title: '고등학교에서 쓰는 정의', body: 'STATEMENT_BODY 기기 밖으로 보내지 않는다'),
        ),
      ];

  @override
  Future<Map<String, String?>> sourceStatements(String conceptId) async => const {};

  @override
  Future<List<ConceptAppearance>> appearancesFor(String conceptId) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

ThinkStatus _status(int conceptReference) => ThinkStatus.fromJson({
      'configured': true,
      'provider': 'openai',
      'capabilities': {'concept_reference': conceptReference},
    });

ConceptItem _item() => ConceptItem(id: _concept, kind: ConceptKind.definition, name: '확률', content: '본문');

Future<(ConceptChatController, ConceptStatementStore)> _ready({int conceptReference = 3}) async {
  final store = ConceptStatementStore(() => _ReadOnlyStatements());
  await store.load(_concept);
  final c = ConceptChatController.forTest()
    ..conversationId = _conv
    ..link = ConceptChatLink.ready
    ..status = _status(conceptReference);
  c.attachStatements(store);
  c.pickConcept(_item());
  return (c, store);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ThinkSendLock.instance.resetForTest();
  });

  group('고른 서술 보내기', () {
    test('서술 id는 개념 id와 함께만 보내고, 서술 글은 보내지 않는다', () {
      final body = ThinkApi.chatRequestBody(
        conversationId: _conv,
        conceptId: _concept,
        statementId: _statement,
        message: '이 서술을 중학 서술과 비교해 줘',
        attachments: const [],
        deep: false,
        webSearch: false,
      );
      expect(body['statement_id'], _statement);
      expect(jsonEncode(body), isNot(contains('STATEMENT_BODY')));

      final noConcept = ThinkApi.chatRequestBody(
        conversationId: _conv,
        statementId: _statement,
        message: 'hi',
        attachments: const [],
        deep: false,
        webSearch: false,
      );
      expect(noConcept.containsKey('statement_id'), isFalse);
    });

    test('개념 상세에서 고른 서술을 따르고, 기본 서술이면 서술 id가 없다', () async {
      final (c, store) = await _ready();
      expect(c.statementId, isNull);
      expect(c.statementLabel, isNull);

      var notified = 0;
      c.addListener(() => notified++);
      store.select(_concept, _statement);
      expect(c.statementId, _statement);
      expect(c.statementLabel, '서술 1 · 고등학교에서 쓰는 정의');
      expect(notified, 1, reason: '패널이 고른 서술 표시를 바꾼다');

      store.select(_concept, null);
      expect(c.statementId, isNull);
    });

    test('서버가 서술 참고를 모르면 기본 서술이 아닌 서술을 고른 채 보내지 않는다', () async {
      final (c, store) = await _ready(conceptReference: 2);
      expect(c.blockedReason, isNull, reason: '기본 서술은 옛 서버도 읽는다');

      store.select(_concept, _statement);
      expect(c.blockedReason, contains('배포'));
      expect(c.blockedReason, contains('기본 서술'));

      c.status = _status(3);
      expect(c.blockedReason, isNull);
    });
  });

  group('서버가 서술을 읽은 결과', () {
    test('고른 서술 상태·판·초안·목록 수를 읽고, 옛 서버는 서술 상태가 없다', () {
      final read = ConceptReadInfo.parse({
        'concept': {
          'id': _concept,
          'status': 'ok',
          'statements': 2,
          'appearances': 0,
          'statement': {
            'id': _statement,
            'status': 'ok',
            'version': 1,
            'has_draft': true,
            'draft_saved_at': '2026-10-20T03:00:00Z',
          },
        },
      });
      expect(read.statementStatus, 'ok');
      expect(read.statementVersion, 1);
      expect(read.statementHasDraft, isTrue);
      expect(read.statementDraftSavedAt, DateTime.utc(2026, 10, 20, 3).toLocal());
      expect(read.statements, 2);
      expect(read.appearances, 0);

      final old = ConceptReadInfo.parse({
        'concept': {'id': _concept, 'status': 'ok'},
      });
      expect(old.statementStatus, isNull);
    });

    testWidgets('패널은 보낼 서술을 보여 주고, 못 찾은 서술은 경고로 알린다', (tester) async {
      final (c, store) = await tester.runAsync(_ready) as (ConceptChatController, ConceptStatementStore);
      await tester.binding.setSurfaceSize(const Size(552, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(width: 520, height: 860, child: ConceptChatPanel(controller: c, onClose: () {})),
          ),
        ),
      ));
      await tester.pump();
      expect(find.text('기본 서술'), findsOneWidget);

      store.select(_concept, _statement);
      await tester.pump();
      expect(find.byKey(const ValueKey('concept-chat-statement')), findsOneWidget);
      expect(find.text('서술 1 · 고등학교에서 쓰…'), findsOneWidget);

      c.lastRead = const ConceptReadInfo(
        status: 'ok',
        statementStatus: 'not_found',
        statements: 1,
        appearances: 0,
      );
      c.setDeep(false);
      await tester.pump();
      expect(find.textContaining('고른 서술을 찾지 못해'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
