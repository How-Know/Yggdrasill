import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/think/think_action_cards.dart';
import 'package:yggdrasill_manager/services/think/think_action_models.dart';
import 'package:yggdrasill_manager/services/think/think_code_controller.dart';
import 'package:yggdrasill_manager/services/think/think_code_models.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 900, height: 900, child: SingleChildScrollView(child: child)),
        ),
      ),
    );

ThinkAction _proposal(Map<String, dynamic> spec, {String kind = 'code_request'}) => ThinkAction.fromRow({
      'id': 'a1',
      'conversation_id': 'c1',
      'message_id': null,
      'kind': kind,
      'status': 'proposed',
      'payload': {'title': '배지', 'spec': spec},
      'preview': {},
      'result': null,
      'superseded': false,
      'created_at': '2026-10-10T01:00:00Z',
    })!;

void main() {
  setUp(() {
    ThinkCodeController.instance.requests = [];
    ThinkCodeController.instance.workers = const [];
  });

  group('모델', () {
    test('요청 강도: medium·high·xhigh만 읽고, 비었거나 모르는 값은 high', () {
      expect(ThinkCodeSpec.fromJson({'goal': 'g', 'effort': 'xhigh', 'effort_reason': ' DB·앱 '}).effort, 'xhigh');
      expect(ThinkCodeSpec.fromJson({'goal': 'g', 'effort': 'xhigh', 'effort_reason': ' DB·앱 '}).effortReason, 'DB·앱');
      for (final bad in [null, 'low', 'max', 3]) {
        expect(ThinkCodeSpec.fromJson({'goal': 'g', 'effort': bad}).effort, 'high');
      }
      final json = ThinkCodeSpec.fromJson({'goal': 'g', 'effort': 'medium'}).toJson();
      expect(json['effort'], 'medium');
      expect(json.containsKey('effort_reason'), isFalse);
      expect(ThinkCodeSpec.fromJson({'goal': 'g'}).withEffort('xhigh').effort, 'xhigh');
    });

    test('승인 덮어쓰기: 강도를 안 바꿨으면 비우고, 바꿨으면 원래 spec에 강도만 바꾼다', () {
      final raw = {'goal': 'g', 'effort': 'medium', 'memory_refs': [{'id': 'm1'}]};
      expect(ThinkCodeSpec.effortOverrides(raw, 'medium'), isEmpty);
      final over = ThinkCodeSpec.effortOverrides(raw, 'xhigh');
      expect(over['spec'], {'goal': 'g', 'effort': 'xhigh', 'memory_refs': [{'id': 'm1'}]});
      expect(ThinkCodeSpec.effortOverrides({'goal': 'g'}, 'high')['spec'], {'goal': 'g', 'effort': 'high'});
    });

    test('회차의 실제 강도를 읽고, 옛 행은 비운다', () {
      expect(ThinkCodeRound.fromRow({'round': 1, 'status': 'finished', 'model': 'grok-4.7', 'effort': 'xhigh'}).effort,
          'xhigh');
      expect(ThinkCodeRound.fromRow({'round': 1, 'status': 'finished'}).effort, isNull);
    });
  });

  group('카드', () {
    testWidgets('Think가 고른 강도를 선택해 두고 이유와 "틀릴 수 있음"을 보여 주며, 바꾸면 안내가 바뀐다', (tester) async {
      final a = _proposal({'goal': '출석 카드 배지', 'effort': 'medium', 'effort_reason': '파일 하나만 고친다'});
      await tester.pumpWidget(_host(ThinkActionCard(action: a)));
      expect(find.text('Cursor 작업 강도'), findsOneWidget);
      expect(find.text('보통 · medium'), findsOneWidget);
      expect(find.text('최고 · xhigh'), findsOneWidget);
      expect(find.textContaining('Think 판단: medium — 파일 하나만 고친다'), findsOneWidget);
      expect(find.textContaining('틀릴 수 있습니다'), findsOneWidget);

      await tester.tap(find.text('최고 · xhigh'));
      await tester.pump();
      expect(find.textContaining('바꾼 강도(xhigh)로 보냅니다'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('강도가 없는 옛 제안은 기본값(high)으로 보낸다고 알린다', (tester) async {
      await tester.pumpWidget(_host(ThinkActionCard(action: _proposal({'goal': 'g'}, kind: 'code_change'))));
      expect(find.textContaining('기본값(high)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
