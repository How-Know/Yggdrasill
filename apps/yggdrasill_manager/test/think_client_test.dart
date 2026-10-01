import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/think/think_markdown.dart';
import 'package:yggdrasill_manager/services/think/think_api.dart';
import 'package:yggdrasill_manager/services/think/think_models.dart';

Future<List<ThinkSseEvent>> _decode(List<String> lines) =>
    Stream<String>.fromIterable(lines).transform(const ThinkSseDecoder()).toList();

void main() {
  group('ThinkSseDecoder', () {
    test('이벤트 이름과 JSON 데이터를 빈 줄 단위로 묶는다', () async {
      final events = await _decode([
        ': ping',
        'event: conversation',
        'data: {"conversation_id":"c1","created":true}',
        '',
        'event: delta',
        'data: {"item_id":"m1","text":"안녕"}',
        '',
      ]);
      expect(events.map((e) => e.event), ['conversation', 'delta']);
      expect(events.first.data['conversation_id'], 'c1');
      expect(events.last.data['text'], '안녕');
    });

    test('여러 줄 data와 CRLF를 합치고, 깨진 JSON은 건너뛴다', () async {
      final events = await _decode([
        'event: done\r',
        'data: {"status":\r',
        'data: "complete"}\r',
        '\r',
        'event: delta',
        'data: {broken',
        '',
      ]);
      expect(events, hasLength(1));
      expect(events.single.event, 'done');
      expect(events.single.data['status'], 'complete');
    });
  });

  group('ThinkApiException.fromBody', () {
    test('서버 오류 코드를 한국어 안내로 바꾼다', () {
      final e = ThinkApiException.fromBody(429, '{"ok":false,"error":"budget_exceeded","message":"x"}');
      expect(e.code, 'budget_exceeded');
      expect(e.status, 429);
      expect(e.message, contains('한도'));
    });

    test('모르는 코드는 서버 메시지를 그대로 쓴다', () {
      final e = ThinkApiException.fromBody(400, {'error': 'message_too_long', 'message': '너무 깁니다'});
      expect(e.message, '너무 깁니다');
    });
  });

  group('ThinkMemoryDraft.toRow', () {
    test('결정이 아니면 결정 전용 필드를 비운다', () {
      final row = ThinkMemoryDraft(
        kind: ThinkMemoryKind.note,
        status: ThinkMemoryStatus.active,
        title: ' 제목 ',
        content: '내용',
        decisionContext: '배경',
        alternatives: ['A'],
        tags: [' 태그 ', ''],
      ).toRow();
      expect(row['title'], '제목');
      expect(row['decision_context'], isNull);
      expect(row['alternatives'], isEmpty);
      expect(row['tags'], ['태그']);
    });

    test('결정은 빈 대안을 빼고 저장한다', () {
      final row = ThinkMemoryDraft(
        kind: ThinkMemoryKind.decision,
        status: ThinkMemoryStatus.draft,
        title: '결정',
        content: '한다',
        decisionReason: ' 이유 ',
        alternatives: ['안 한다', ' ', '나중에'],
      ).toRow();
      expect(row['decision_reason'], '이유');
      expect(row['alternatives'], ['안 한다', '나중에']);
      expect(row['status'], 'draft');
    });
  });

  testWidgets('ThinkMarkdown은 인라인·블록 수식을 Math로 그린다', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ThinkMarkdown('기울기는 \$\\frac{1}{2}\$ 이고 \\(y=ax+b\\) 꼴입니다.\n\n\$\$x^2+1\$\$\n\n가격 \$ 10 은 수식이 아닙니다.'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(Math), findsNWidgets(3));
  });
}
