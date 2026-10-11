import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/think/think_code_views.dart';
import 'package:yggdrasill_manager/services/think/think_clipboard_files.dart';
import 'package:yggdrasill_manager/services/think/think_code_models.dart';

const _prev = '76982ca1-0000-4000-8000-000000000000';

void main() {
  test('요청의 continue_from과 회차의 continued_from을 읽는다', () {
    final spec = ThinkCodeSpec.fromJson({
      'goal': 'g',
      'continue_from': {'request_id': _prev, 'title': '개인화'},
    });
    expect(spec.continueFrom, (requestId: _prev, title: '개인화'));
    expect(spec.toJson()['continue_from'], {'request_id': _prev, 'title': '개인화'});
    expect(
        ThinkCodeSpec.fromJson({
          'goal': 'g',
          'continue_from': {'title': 'x'}
        }).continueFrom,
        isNull);
    expect(ThinkCodeSpec.fromJson({'goal': 'g'}).toJson().containsKey('continue_from'), isFalse);

    final round = ThinkCodeRound.fromRow({
      'round': 1,
      'status': 'finished',
      'result': {
        'continued_from': {
          'request_id': _prev,
          'title': '개인화',
          'round': 2,
          'files': 20,
          'additions': 300,
          'deletions': 12,
          'applied': 'merged',
        },
      },
    });
    final c = round.continued!;
    expect(c.summary, contains('76982ca1'));
    expect(c.summary, contains('2회차'));
    expect(c.summary, contains('파일 20개'));
    expect(c.summary, contains('3-way'));
    expect(c.alreadyPresent, isFalse);
    expect(ThinkCodeRound.fromRow({'round': 1, 'status': 'finished', 'result': {}}).continued, isNull);
  });

  testWidgets('회차 화면: 이어받은 패치와, 적용하면 앞 수정도 들어간다는 안내', (tester) async {
    final round = ThinkCodeRound.fromRow({
      'round': 1,
      'status': 'finished',
      'result': {
        'continued_from': {
          'request_id': _prev,
          'round': 2,
          'files': 3,
          'additions': 1,
          'deletions': 0,
          'applied': 'applied'
        },
      },
    });
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: ThinkCodeRoundView(round: round, mode: ThinkCodeMode.change))),
    ));
    expect(find.text('이어받은 패치'), findsOneWidget);
    expect(find.textContaining('앞 수정도 함께'), findsOneWidget);
    expect(find.text(ThinkContinued.partialLabel), findsNothing);
    expect(round.continued!.summary, contains('최종 패치'));
  });

  testWidgets('미완성 패치에서 시작: 검사된 적 없다고 알리고 최종 패치라고 하지 않는다', (tester) async {
    Map<String, dynamic> row(Object? partial) => {
          'round': 1,
          'status': 'finished',
          'result': {
            'continued_from': {
              'request_id': _prev,
              'round': 1,
              'files': 28,
              'additions': 1980,
              'deletions': 42,
              'applied': 'merged',
              'partial': partial,
            },
          },
        };
    expect(ThinkCodeRound.fromRow(row('other')).continued!.partial, isFalse);
    final round = ThinkCodeRound.fromRow(row('timeout'));
    final c = round.continued!;
    expect(c.partial, isTrue);
    expect(c.summary, contains('1회차 미완성 패치'));
    expect(c.summary, isNot(contains('최종 패치')));
    expect(ThinkContinued.partialNotice, contains('검사된 적이 없습니다'));
    expect(ThinkContinued.partialNotice, contains('최종 diff 전체'));

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: ThinkCodeRoundView(round: round, mode: ThinkCodeMode.change))),
    ));
    expect(find.text(ThinkContinued.partialLabel), findsOneWidget);
    expect(find.textContaining('검사된 적이 없습니다'), findsOneWidget);
    expect(find.text('이어받은 패치'), findsNothing);
  });

  test('붙여넣기 키: Ctrl+V와 Shift+Insert', () {
    expect(isThinkPasteKey(LogicalKeyboardKey.keyA, HardwareKeyboard.instance), isFalse);
    expect(isThinkPasteKey(LogicalKeyboardKey.keyV, HardwareKeyboard.instance), isFalse, reason: 'Ctrl 없이 V');
  });

  test('클립보드 출력에서 경로만 고르고, 스크립트는 UTF-16LE base64로 넘긴다', () {
    expect(
      ThinkClipboardFiles.parse('F\tC:\\a\\사진.png\r\nI\tC:\\tmp\\clipboard_1.png\r\n잡음\r\nF\t  \r\n'),
      ['C:\\a\\사진.png', 'C:\\tmp\\clipboard_1.png'],
    );
    expect(ThinkClipboardFiles.parse(''), isEmpty);
    final bytes = base64.decode(ThinkClipboardFiles.encodedScript());
    final units = [for (var i = 0; i < bytes.length; i += 2) bytes[i] | (bytes[i + 1] << 8)];
    final script = String.fromCharCodes(units);
    expect(script, contains('GetFileDropList'));
    expect(script, contains(r'"I`t$env:THINK_PASTE_PNG"'));
  });
}
