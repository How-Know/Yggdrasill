import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yggdrasill_manager/screens/curriculum/widgets/concept_chat_panel.dart';
import 'package:yggdrasill_manager/services/concept_service.dart';
import 'package:yggdrasill_manager/services/think/think_api.dart';
import 'package:yggdrasill_manager/services/think/think_concept_chat_controller.dart';
import 'package:yggdrasill_manager/services/think/think_models.dart';
import 'package:yggdrasill_manager/services/think/think_send_lock.dart';

const _conv = '0d6c1b52-8a3e-4f5d-9b7c-1e2f3a4b5c6d';
const _otherConv = '7a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d';
const _concept = '6f1d2c3b-4a5e-4f60-8a7b-9c0d1e2f3a4b';
const _userA = 'a0000000-0000-4000-8000-00000000000a';
const _userB = 'b0000000-0000-4000-8000-00000000000b';

ConceptItem _item(String id, {String name = '소인수분해', String content = '본문은 기기에 저장하지 않는다'}) =>
    ConceptItem(id: id, kind: ConceptKind.definition, name: name, content: content);

ThinkStatus _status({bool conceptReference = false}) => ThinkStatus.fromJson({
      'configured': true,
      'provider': 'openai',
      if (conceptReference) 'capabilities': {'concept_reference': 1},
    });

Future<void> _settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<Map<String, dynamic>?> _saved(String userId) async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(ConceptChatController.prefsKey(userId));
  return raw == null ? null : Map<String, dynamic>.from(jsonDecode(raw) as Map);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ThinkSendLock.instance.resetForTest();
  });

  group('채팅 요청 본문', () {
    test('대화 id와 개념 id는 따로 보내고, 메시지에 개념 본문을 섞지 않는다', () {
      final body = ThinkApi.chatRequestBody(
        conversationId: _conv,
        conceptId: _concept,
        message: '정의를 학생 눈높이로 다듬어 줘',
        attachments: const [],
        deep: false,
        webSearch: false,
      );
      expect(body['conversation_id'], _conv);
      expect(body['concept_id'], _concept);
      expect(body['message'], '정의를 학생 눈높이로 다듬어 줘');
      expect(body.keys.where((k) => k.contains('concept')), ['concept_id']);
      expect(jsonEncode(body), isNot(contains('본문')));
    });

    test('새 대화이거나 개념을 고르지 않았으면 concept_id를 보내지 않는다', () {
      final fresh = ThinkApi.chatRequestBody(
        conversationId: null,
        conceptId: _concept,
        message: 'hi',
        attachments: const [],
        deep: false,
        webSearch: false,
      );
      final plain = ThinkApi.chatRequestBody(
        conversationId: _conv,
        message: 'hi',
        attachments: const [],
        deep: false,
        webSearch: false,
      );
      expect(fresh.containsKey('concept_id'), isFalse);
      expect(plain.containsKey('concept_id'), isFalse);
    });
  });

  group('같은 대화 중복 전송 잠금', () {
    test('한쪽이 답변을 받는 동안 다른 쪽은 같은 대화로 보낼 수 없다', () async {
      final lock = ThinkSendLock.instance;
      final released = <ThinkSendRelease>[];
      final sub = lock.released.listen(released.add);

      expect(lock.acquire(_conv, ThinkSendLock.thinkScreen), isTrue);
      expect(lock.acquire(_conv, ThinkSendLock.conceptTab), isFalse);
      expect(lock.busyElsewhere(_conv, ThinkSendLock.conceptTab), isTrue);
      expect(lock.busyElsewhere(_conv, ThinkSendLock.thinkScreen), isFalse);
      expect(lock.acquire(_otherConv, ThinkSendLock.conceptTab), isTrue, reason: '다른 대화는 막지 않는다');

      lock.release(_conv, ThinkSendLock.conceptTab);
      expect(lock.busy(_conv), isTrue, reason: '잠근 쪽만 풀 수 있다');

      lock.release(_conv, ThinkSendLock.thinkScreen);
      await _settle();
      expect(lock.busy(_conv), isFalse);
      expect(released.map((r) => (r.conversationId, r.owner)), [(_conv, ThinkSendLock.thinkScreen)]);
      expect(lock.acquire(_conv, ThinkSendLock.conceptTab), isTrue);
      await sub.cancel();
    });

    test('개념 탭은 Think 화면이 같은 대화로 답변을 받는 동안 보내기를 막는다', () {
      final c = ConceptChatController.forTest()
        ..conversationId = _conv
        ..link = ConceptChatLink.ready;
      expect(c.blockedReason, isNull);
      ThinkSendLock.instance.acquire(_conv, ThinkSendLock.thinkScreen);
      expect(c.blockedReason, contains('Think 화면'));
      c.composer.text = '질문';
      expect(c.canSend, isFalse);
    });
  });

  group('개념 탭 연결', () {
    test('계정마다 대화 id와 개념 id만 저장하고, 계정을 바꾸면 화면 상태를 비운다', () async {
      final c = ConceptChatController.forTest();
      await c.switchAccountForTest(_userA);
      await c.linkConversation(ThinkConversation.fromRow({'id': _conv, 'title': '개념 정리', 'status': 'active'}));
      expect(c.pickConcept(_item(_concept)), isNull);
      await _settle();

      expect(await _saved(_userA), {'conversation_id': _conv, 'concept_id': _concept});
      expect(await _saved(_userB), isNull);

      c.composer.text = '보내지 않은 질문';
      await c.switchAccountForTest(_userB);
      expect(c.conversationId, isNull);
      expect(c.conceptId, isNull);
      expect(c.composer.text, isEmpty);
      expect(c.messages, isEmpty);
      expect(c.link, ConceptChatLink.none);

      await c.switchAccountForTest(_userA);
      expect(c.conversationId, _conv);
      expect(c.conceptId, _concept);
    });

    test('저장 전 임시 개념은 고를 수 없고, 저장값이 id 형식이 아니면 버린다', () async {
      SharedPreferences.setMockInitialValues({
        ConceptChatController.prefsKey(_userA): jsonEncode({'conversation_id': 'latest', 'concept_id': _concept}),
      });
      final c = ConceptChatController.forTest();
      await c.switchAccountForTest(_userA);
      expect(c.conversationId, isNull);
      expect(c.conceptId, _concept);

      expect(c.pickConcept(_item('tmp-1712')), isNotNull);
      expect(c.conceptId, _concept);
    });

    test('개념을 골랐는데 서버가 개념 참고를 모르면 보내지 않는다', () {
      final c = ConceptChatController.forTest()
        ..conversationId = _conv
        ..link = ConceptChatLink.ready
        ..status = _status();
      c.pickConcept(_item(_concept));
      expect(c.blockedReason, contains('배포'));

      c.status = _status(conceptReference: true);
      expect(c.blockedReason, isNull);

      c.status = _status();
      c.clearConcept();
      expect(c.blockedReason, isNull, reason: '개념 없이 이야기하는 것은 막지 않는다');
    });

    test('연결한 대화가 없거나 사라졌으면 다시 연결하라고 안내한다', () {
      final c = ConceptChatController.forTest();
      expect(c.blockedReason, contains('연결'));
      c
        ..conversationId = _conv
        ..link = ConceptChatLink.missing;
      expect(c.blockedReason, contains('다른 대화를 연결'));
    });
  });

  group('서버가 개념을 읽은 결과', () {
    test('없음·건너뜀·잘림을 구분한다', () {
      expect(ConceptReadInfo.parse(null).status, 'unsupported');
      expect(ConceptReadInfo.parse({'identity': 1}).status, 'unsupported');
      expect(ConceptReadInfo.parse({'concept': null}).status, 'skipped');
      final read = ConceptReadInfo.parse({
        'concept': {
          'id': _concept,
          'status': 'truncated',
          'updated_at': '2026-10-15T01:00:00Z',
          'content_chars': 15000,
          'delivered_chars': 12000,
          'path_complete': false,
        },
      });
      expect(read.status, 'truncated');
      expect(read.deliveredChars, 12000);
      expect(read.contentChars, 15000);
      expect(read.pathComplete, isFalse);
      expect(read.updatedAt, DateTime.utc(2026, 10, 15, 1).toLocal());
    });
  });

  group('개념 탭 패널', () {
    Future<void> pumpPanel(WidgetTester tester, ConceptChatController c, double width) async {
      await tester.binding.setSurfaceSize(Size(width + 32, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(width: width, height: 860, child: ConceptChatPanel(controller: c, onClose: () {})),
          ),
        ),
      ));
      await tester.pump();
    }

    for (final width in [360.0, 520.0]) {
      testWidgets('연결 전 안내와 연결 뒤 대화·개념·읽은 결과를 보여 준다 (폭 $width)', (tester) async {
        final c = ConceptChatController.forTest();
        await pumpPanel(tester, c, width);
        expect(find.text('개념을 같이 정리할 Think 대화를 고르세요'), findsOneWidget);
        expect(find.text('대화 고르기'), findsOneWidget);
        expect(tester.takeException(), isNull);

        c
          ..conversationId = _conv
          ..conversation = ThinkConversation.fromRow({'id': _conv, 'title': '소인수분해 정리 기준', 'status': 'active'})
          ..link = ConceptChatLink.ready
          ..status = _status(conceptReference: true)
          ..messages = [
            ThinkMessage(id: 'm1', role: 'user', content: '정의를 다듬어 줘', status: ThinkMessageStatus.complete),
            ThinkMessage(id: 'm2', role: 'assistant', content: '이렇게 다듬었습니다.', status: ThinkMessageStatus.complete),
          ];
        c.pickConcept(_item(_concept));
        c.lastRead = ConceptReadInfo(
          status: 'truncated',
          updatedAt: DateTime(2026, 10, 15, 10),
          contentChars: 15000,
          deliveredChars: 12000,
          pathComplete: true,
        );
        c.setDeep(false);
        await tester.pump();

        expect(find.text('소인수분해 정리 기준'), findsOneWidget);
        expect(find.text('소인수분해'), findsOneWidget);
        expect(find.textContaining('앞 12000자만 읽었습니다'), findsOneWidget);
        expect(find.textContaining('저장하지 않은 편집은 읽지 않습니다'), findsOneWidget);
        expect(find.text('이렇게 다듬었습니다.'), findsOneWidget);
        expect(find.text('보내기'), findsOneWidget);
        expect(tester.takeException(), isNull);

        ThinkSendLock.instance.acquire(_conv, ThinkSendLock.thinkScreen);
        c.composer.text = '다음 질문';
        await tester.pump();
        expect(find.textContaining('Think 화면에서 이 대화의 답변을 받는 중'), findsOneWidget);
        final send = tester.widget<ButtonStyleButton>(
          find.ancestor(of: find.text('보내기'), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)),
        );
        expect(send.onPressed, isNull);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
