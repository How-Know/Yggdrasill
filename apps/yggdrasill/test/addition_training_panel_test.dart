import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mneme_flutter/screens/learning/addition_solve_page.dart';
import 'package:mneme_flutter/screens/learning/addition_training_panel.dart';
import 'package:mneme_flutter/services/homework_store.dart';

void main() {
  testWidgets('30문항 균등은 구간마다 6개이고 1자리 미리보기가 식을 만든다', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    String? applied;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: AdditionTrainingPanel(
            onClose: () {},
            onApply: (title, content, count) {
              applied = content;
            },
          ),
        ),
      ),
    ));

    expect(find.text('1 · 6'), findsOneWidget);
    expect(find.text('5 · 6'), findsOneWidget);

    await tester.tap(find.text('비율 조절'));
    await tester.pumpAndSettle();
    expect(find.text('20% · 6'), findsWidgets);
    expect(find.byKey(const Key('addition-plan')), findsOneWidget);

    await tester.tap(find.text('1자리').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('10'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('미리보기 생성'));
    await tester.pumpAndSettle();

    expect(find.textContaining('만든 '), findsOneWidget);
    expect(find.textContaining('+'), findsWidgets);
    await tester.tap(find.byKey(const Key('addition-apply')));
    await tester.pumpAndSettle();
    expect(applied, contains('"kind":"natural_addition_v3"'));
  });

  testWidgets('덧셈 과제를 풀면 정확도가 과제 내용에 남는다', (tester) async {
    final item = HomeworkItem(
      id: 'hw-add',
      title: '자연수 덧셈 1문항',
      body: '2+3',
      content:
          '{"kind":"natural_addition_v3","items":[{"expr":"2+3","answer":"5","timeMs":1000,"costMilli":100,"band":1,"hasCarry":false}]}',
    );
    await tester.pumpWidget(MaterialApp(
      home: AdditionSolvePage(studentId: 'missing-student', item: item, onSaved: (id, saved) {}),
    ));
    await tester.enterText(find.byType(TextField), '5');
    await tester.tap(find.text('제출'));
    await tester.pump();

    expect(find.textContaining('정확도 100.0'), findsOneWidget);
    expect(item.content, contains('"accuracy":100'));
    expect(item.content, contains('표준 절차 추정 대비'));
  });

  testWidgets('인쇄로 낸 덧셈 과제는 정답만 남긴다', (tester) async {
    final item = HomeworkItem(
      id: 'hw-print',
      title: '자연수 덧셈 1문항',
      body: '2+3',
      type: '프린트',
      content:
          '{"kind":"natural_addition_v3","items":[{"expr":"2+3","answer":"5","timeMs":1000,"costMilli":100,"band":1,"hasCarry":false}]}',
    );
    await tester.pumpWidget(MaterialApp(
      home: AdditionSolvePage(
        studentId: 'missing-student',
        item: item,
        measureTime: false,
        onSaved: (id, saved) {},
      ),
    ));
    expect(find.textContaining('정답만 확인합니다'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '5');
    await tester.tap(find.text('제출'));
    await tester.pump();
    expect(find.textContaining('정확도 100.0'), findsOneWidget);
    expect(item.content, contains('인쇄 과제, 시간 제외'));
    expect(item.content, contains('"efficiency":null'));
  });
}