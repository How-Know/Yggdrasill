import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/think/think_code_request_dialog.dart';
import 'package:yggdrasill_manager/screens/think/think_code_requests_dialog.dart';
import 'package:yggdrasill_manager/services/think/think_code_controller.dart';
import 'package:yggdrasill_manager/services/think/think_code_models.dart';
import 'package:yggdrasill_manager/services/think/think_models.dart';

Map<String, dynamic> _row(String id, String status, {String? submittedAt}) => {
      'id': id,
      'title': '출석 카드 지각 표시',
      'request': {
        'goal': '출석 카드에 지각 표시를 넣을 수 있는지',
        'questions': ['어느 위젯이 카드를 그리나'],
        'focus_paths': <String>[],
      },
      'status': status,
      'round': status == 'draft' ? 0 : 1,
      'max_rounds': 2,
      'created_at': '2026-09-29T01:00:00Z',
      'submitted_at': submittedAt,
    };

final _roundRow = {
  'round': 1,
  'status': 'finished',
  'result_text': '조사했습니다.\n```json\n{}\n```',
  'parse_ok': true,
  'model': 'composer-2.5',
  'duration_ms': 95000,
  'usage': {'inputTokens': 1200, 'cacheReadTokens': 300, 'outputTokens': 450},
  'tool_calls': [
    {'name': 'read', 'count': 3},
    {'name': 'grep', 'count': 2},
  ],
  'repo_state': {'head': 'abcdef1234567', 'branch': 'main', 'dirty_files': 4},
  'result': {
    'summary': '지금 구조로 넣을 수 있습니다.',
    'feasibility': 'possible',
    'answers': [
      {'question': '어느 위젯이 카드를 그리나', 'answer': 'AttendanceCard'},
    ],
    'findings': [
      {
        'point': '카드는 한 위젯에서 그린다',
        'evidence': [
          {'path': 'apps/yggdrasill/lib/widgets/attendance_card.dart', 'lines': '40-88'},
        ],
      },
    ],
    'proposals': [
      {'title': '지각 배지 추가', 'change': '상태 옆에 배지', 'files': ['a.dart'], 'risk': 'weird'},
    ],
    'risks': ['색만으로 구분하지 않기'],
    'questions_for_think': ['지각 기준 시간은?'],
  },
};

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: SizedBox(width: 1400, height: 900, child: child)),
    );

void main() {
  group('모델', () {
    test('요청 행을 읽고 상태별 가능한 동작을 정한다', () {
      final r = ThinkCodeRequest.fromRow(_row('r1', 'needs_review'));
      expect(r.status, ThinkCodeStatus.needsReview);
      expect(r.status.decidable, isTrue);
      expect(r.status.deletable, isTrue);
      expect(r.status.inProgress, isFalse);
      expect(r.spec.focusPaths, isEmpty);
      expect(ThinkCodeStatus.parse('running').deletable, isFalse);
      expect(ThinkCodeStatus.parse('모름'), ThinkCodeStatus.draft);
    });

    test('실행 중 취소 요청은 "취소 중"으로 보인다', () {
      final r = ThinkCodeRequest.fromRow({..._row('r1', 'running'), 'cancel_requested': true});
      expect(r.statusLabel, '취소 중');
    });

    test('여러 줄 입력의 글머리와 빈 줄을 뺀다', () {
      expect(ThinkCodeSpec.lines('- 하나\n\n2) 둘\n  • 셋 '), ['하나', '둘', '셋']);
    });

    test('회차 결과: 모르는 위험도는 보통, 캐시 입력은 입력 토큰에 더한다', () {
      final round = ThinkCodeRound.fromRow(_roundRow);
      expect(round.inputTokens, 1500);
      expect(round.result!.proposals.single.risk, 'medium');
      expect(round.result!.findings.single.evidence.single.label, endsWith(':40-88'));
      expect(round.toolCalls.map((t) => t.name), ['read', 'grep']);
      expect(ThinkCodeResult.fromJson({'feasibility': 'possible'}), isNull);
    });

    test('오늘 보낸 수는 한국 시간 자정 기준이다', () {
      final now = DateTime.utc(2026, 9, 29, 3);
      final requests = [
        ThinkCodeRequest.fromRow(_row('a', 'queued', submittedAt: '2026-09-28T15:00:00Z')),
        ThinkCodeRequest.fromRow(_row('b', 'queued', submittedAt: '2026-09-28T14:59:59Z')),
        ThinkCodeRequest.fromRow(_row('c', 'draft')),
      ];
      expect(thinkCodeSubmittedToday(requests, now), 1);
    });

    test('설정의 하루 한도를 읽고 없으면 10건이다', () {
      expect(ThinkSettings.fromRow({'code_request_daily_limit': 3}).codeRequestDailyLimit, 3);
      expect(ThinkSettings.fromRow({}).codeRequestDailyLimit, 10);
    });
  });

  testWidgets('결과가 온 요청은 정리된 결과와 판단 버튼을 보여 준다', (tester) async {
    final c = ThinkCodeController.instance;
    c.requests = [ThinkCodeRequest.fromRow(_row('r1', 'ready', submittedAt: '2026-09-29T01:00:00Z'))];
    c.workers = const [];
    c.setRoundsForTest('r1', [ThinkCodeRound.fromRow(_roundRow)]);
    c.selectedId = 'r1';

    await tester.pumpWidget(_host(const ThinkCodeRequestsView()));
    await tester.pump();

    expect(find.text('지금 구조로 가능'), findsOneWidget);
    expect(find.text('수정 제안 (적용하지 않음)'), findsOneWidget);
    expect(find.text('지각 배지 추가'), findsOneWidget);
    expect(find.text('위험 보통'), findsOneWidget);
    expect(find.text('apps/yggdrasill/lib/widgets/attendance_card.dart:40-88'), findsOneWidget);
    expect(find.text('판단 남기기'), findsOneWidget);
    expect(find.text('다시 요청'), findsOneWidget);
    expect(find.text('보내기'), findsNothing);
    expect(find.textContaining('작업자가 아직 연결된 적이 없습니다'), findsOneWidget);
    expect(find.textContaining('커밋 안 된 파일 4개'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('대화의 문답에서 열면 질문은 목표, 답변은 배경으로 채운다', (tester) async {
    final c = ThinkCodeController.instance;
    c.requests = [ThinkCodeRequest.fromRow(_row('r1', 'draft'))];
    final messages = [
      ThinkMessage(id: 'm1', role: 'user', content: '출석 카드에 지각 표시 넣을 수 있어?', status: ThinkMessageStatus.complete),
      ThinkMessage(id: 'm2', role: 'assistant', content: '가능해 보입니다. 코드 확인이 필요합니다.', status: ThinkMessageStatus.complete),
    ];

    await tester.pumpWidget(_host(Builder(
      builder: (context) => TextButton(
        onPressed: () => ThinkCodeRequestDialog.fromTurn(context, conversationId: 'c1', messages: messages, index: 1),
        child: const Text('열기'),
      ),
    )));
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();

    final fields = tester.widgetList<TextField>(find.byType(TextField)).map((f) => f.controller!.text).toList();
    expect(fields, contains('출석 카드에 지각 표시 넣을 수 있어?'));
    expect(fields.any((t) => t.contains('가능해 보입니다')), isTrue);
    expect(find.text('보내기'), findsOneWidget);
    expect(find.text('초안 저장'), findsOneWidget);
    expect(find.textContaining('작업자가 꺼져 있습니다'), findsOneWidget);
  });
}
