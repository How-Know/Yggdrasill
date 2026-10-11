import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/think/think_message_tile.dart';
import 'package:yggdrasill_manager/services/think/think_models.dart';

Map<String, dynamic> _message(String role, {String? askedBy, Object? relay}) => {
      'id': 'm-$role',
      'role': role,
      'content': role == 'user' ? '수업 기록 정렬 기준은?' : '날짜순입니다.',
      'status': 'complete',
      'asked_by': askedBy,
      'relay': relay,
    };

Future<void> _pump(WidgetTester tester, ThinkMessage message) => tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SingleChildScrollView(child: ThinkMessageTile(message: message)))),
    );

void main() {
  test('대화 출처: cursor만 커서 대화, 열이 없거나 모르는 값은 운영자 대화', () {
    final base = {'id': 'c1', 'title': '작업자 문의: 정렬', 'status': 'active'};
    expect(ThinkConversation.fromRow({...base, 'origin': 'cursor'}).fromCursor, isTrue);
    expect(ThinkConversation.fromRow({...base, 'origin': 'owner'}).fromCursor, isFalse);
    expect(ThinkConversation.fromRow(base).fromCursor, isFalse);
    expect(ThinkConversation.fromRow({...base, 'origin': 'x'}).origin, 'owner');
    expect(ThinkConversation.fromRow({...base, 'origin': 'cursor'}).copyWith(title: 't').fromCursor, isTrue);
  });

  test('메시지: 커서 질문 표시와 판정을 읽고, 모르는 판정은 버린다', () {
    final q = ThinkMessage.fromRow(_message('user', askedBy: 'cursor_worker'));
    expect(q.askedByLabel, '작업자 커서가 물음');
    expect(ThinkMessage.fromRow(_message('user', askedBy: 'cursor_ide')).askedByLabel, '커서가 물음');
    expect(ThinkMessage.fromRow(_message('user')).askedByLabel, isNull);

    final a = ThinkMessage.fromRow(_message('assistant', relay: {
      'verdict': 'answered',
      'basis': [
        {'id': 'm1', 'kind': 'decision', 'title': '수업 기록은 날짜순'},
        {'id': 'm2', 'kind': 'decision', 'title': ' '},
      ],
      'owner_questions': <String>[],
    }));
    expect(a.relay!.answered, isTrue);
    expect(a.relay!.basis, ['수업 기록은 날짜순']);
    expect(ThinkMessage.fromRow(_message('assistant', relay: {'verdict': 'maybe'})).relay, isNull);
    expect(ThinkMessage.fromRow(_message('assistant', relay: 'answered')).relay, isNull);
    expect(ThinkMessage.fromRow(_message('assistant')).relay, isNull);
  });

  testWidgets('타일: 커서 질문 표시, 기존 결정 근거, 사장님 확인 필요', (tester) async {
    await _pump(tester, ThinkMessage.fromRow(_message('user', askedBy: 'cursor_ide')));
    expect(find.text('커서가 물음'), findsOneWidget);

    await _pump(tester, ThinkMessage.fromRow(_message('user')));
    expect(find.text('커서가 물음'), findsNothing);

    await _pump(
      tester,
      ThinkMessage.fromRow(_message('assistant', relay: {
        'verdict': 'answered',
        'basis': [
          {'id': 'm1', 'kind': 'decision', 'title': '수업 기록은 날짜순'},
        ],
      })),
    );
    expect(find.text('기존 결정 근거'), findsOneWidget);
    expect(find.text('· 수업 기록은 날짜순'), findsOneWidget);

    await _pump(
      tester,
      ThinkMessage.fromRow(_message('assistant', relay: {
        'verdict': 'needs_owner',
        'basis': <Object>[],
        'owner_questions': ['과목별로 묶을까요?'],
      })),
    );
    expect(find.text('사장님 확인 필요'), findsOneWidget);
    expect(find.text('· 과목별로 묶을까요?'), findsOneWidget);
  });
}
