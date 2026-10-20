import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/think/think_message_tile.dart';
import 'package:yggdrasill_manager/services/think/think_api.dart';
import 'package:yggdrasill_manager/services/think/think_models.dart';

void main() {
  test('첨부 형식: .xlsx는 받고 .xls·.xlsm·.csv는 받지 않는다', () {
    expect(ThinkApi.mimeForPath(r'C:\data\성적.XLSX'), ThinkApi.spreadsheetMime);
    expect(ThinkApi.mimeForPath('a.xls'), isNull);
    expect(ThinkApi.mimeForPath('a.xlsm'), isNull);
    expect(ThinkApi.mimeForPath('a.csv'), isNull);
  });

  testWidgets('Think가 만든 파일은 답변 아래에 첨부로 보인다', (tester) async {
    final message = ThinkMessage.fromRow({
      'id': 'm1',
      'role': 'assistant',
      'content': '반별 평균입니다.',
      'status': 'complete',
      'attachments': [
        {'path': 'u/202610/think-1-out.xlsx', 'name': '반별평균.xlsx', 'mime': ThinkApi.spreadsheetMime, 'size': 10},
        {'path': 'u/202610/think-2-chart.png', 'name': 'chart.png', 'mime': 'image/png', 'size': 10},
      ],
    });
    expect(message.attachments.first.isSpreadsheet, isTrue);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: ThinkMessageTile(message: message))),
    ));
    expect(find.text('반별평균.xlsx'), findsOneWidget);
    expect(find.text('chart.png'), findsOneWidget);
    expect(find.byIcon(Icons.table_chart_outlined), findsOneWidget);
  });
}
