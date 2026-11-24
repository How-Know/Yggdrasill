import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/curriculum/widgets/course_map_pane.dart';
import 'package:yggdrasill_manager/screens/think/think_style.dart';
import 'package:yggdrasill_manager/services/course_map_controller.dart';
import 'package:yggdrasill_manager/services/course_map_service.dart';

import 'course_map_fake.dart';

const _units = [
  U('다항식', [
    U('다항식의 연산', [U('덧셈과 뺄셈'), U('곱셈')]),
    U('나머지정리', [U('항등식')]),
  ]),
  U('방정식과 부등식', [
    U('복소수', [U('복소수의 뜻')]),
  ]),
];

(FakeCourseMapBackend, String, CourseMapController) _setup() {
  final b = FakeCourseMapBackend();
  final id = b.addCourse('공통수학1', key: 'H1', units: _units);
  b.addCourse('공통수학2', key: 'H2', units: const [U('도형의 방정식')]);
  var n = 0;
  return (b, id, CourseMapController.forTest(b, newId: () => 'n${++n}'));
}

Future<void> _pump(WidgetTester tester, Widget child, {double width = 1200, double height = 820}) async {
  await tester.binding.setSurfaceSize(Size(width, height + 40));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: SizedBox(width: width, height: height, child: child)),
  ));
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

Finder _field(String text) => find.byWidgetPredicate((w) => w is TextField && w.controller?.text == text);

void main() {
  testWidgets('흐름을 보고 이름을 고쳐 저장하면 같은 단원이 저장됨으로 바뀐다', (tester) async {
    final (b, id, c) = _setup();
    await _pump(tester, CourseMapPane(controller: c));

    expect(find.text('교육과정 흐름'), findsOneWidget);
    expect(find.text('기준 초안'), findsOneWidget, reason: '공식 검증본처럼 보이지 않는다');
    expect(find.text('공통수학1'), findsWidgets, reason: '과정 칩과 과정 이름 칸');
    expect(find.text('공통수학2'), findsOneWidget);
    expect(find.text('덧셈과 뺄셈'), findsOneWidget);
    expect(find.text('I'), findsOneWidget);
    expect(find.text('1–3'), findsOneWidget, reason: '대단원 다항식은 1~3번 단계');

    final ops = b.unitId(id, '다항식의 연산');
    await tester.tap(find.byKey(ValueKey('course-unit-$ops')));
    await tester.pump();
    expect(_field('다항식의 연산'), findsOneWidget);
    await tester.enterText(_field('다항식의 연산'), '다항식의 계산');
    await tester.pump();

    expect(find.text('저장 안 됨 1'), findsOneWidget);
    expect(find.text('저장 안 한 변경 1곳'), findsOneWidget);
    expect(find.text('이름 바뀜'), findsWidgets);
    expect(b.writes, 0, reason: '저장 단추를 누르기 전에는 보내지 않는다');

    await tester.tap(find.text('저장'));
    await tester.pump();
    await tester.pump();
    expect(b.unitName(ops), '다항식의 계산');
    expect(find.textContaining('저장됨 · v2'), findsOneWidget);
    expect(find.text('과정 탐색도를 저장했습니다.'), findsOneWidget);
    expect(find.text('저장 안 됨 1'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('저장에 실패하면 입력이 남고 성공처럼 보이지 않는다', (tester) async {
    final (b, id, c) = _setup();
    await _pump(tester, CourseMapPane(controller: c));
    final ops = b.unitId(id, '다항식의 연산');
    await tester.tap(find.byKey(ValueKey('course-unit-$ops')));
    await tester.pump();
    await tester.enterText(_field('다항식의 연산'), '다항식의 계산');
    await tester.pump();
    b.bumpVersion(id);

    await tester.tap(find.text('저장'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('저장하지 못했습니다'), findsOneWidget);
    expect(find.text('최신 저장본 불러오기(지금 편집 버림)'), findsOneWidget);
    expect(find.text('과정 탐색도를 저장했습니다.'), findsNothing);
    expect(find.text('저장 안 한 변경 1곳'), findsOneWidget);
    expect(_field('다항식의 계산'), findsOneWidget);
    expect(b.unitName(ops), '다항식의 연산');
    expect(tester.takeException(), isNull);
  });

  testWidgets('목록을 읽지 못하면 오류만 보이고 다른 목록으로 대신하지 않는다', (tester) async {
    final (b, _, c) = _setup();
    b.failList = CourseMapException('not_ready', 'DB에 과정 탐색도 저장소가 아직 없습니다.');
    await _pump(tester, CourseMapPane(controller: c));

    expect(find.textContaining('과정 목록을 읽지 못했습니다'), findsOneWidget);
    expect(find.textContaining('DB 반영(마이그레이션)은 별도 승인'), findsOneWidget);
    expect(find.text('공통수학1'), findsNothing);
    expect(find.text('1-1'), findsNothing, reason: '예전 코드 목록으로 대신 보이지 않는다');

    b.failList = null;
    await tester.tap(find.text('다시 불러오기'));
    await tester.pump();
    await tester.pump();
    expect(find.text('공통수학2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('저장된 단원을 보관하면 영향 범위를 묻고, 저장 전까지는 보관하지 않는다', (tester) async {
    final (b, id, c) = _setup();
    await _pump(tester, CourseMapPane(controller: c));
    final ops = b.unitId(id, '다항식의 연산');
    await tester.tap(find.byKey(ValueKey('course-unit-$ops')));
    await tester.pump();

    await tester.tap(find.text('보관'));
    await tester.pumpAndSettle();
    expect(find.textContaining('아래 단원 2개'), findsOneWidget);
    await tester.tap(find.widgetWithText(ElevatedButton, '보관'));
    await tester.pumpAndSettle();

    expect(find.text(' · 저장하면 단원 3개 보관'), findsOneWidget);
    expect(find.text('저장 안 한 변경 3곳'), findsOneWidget);
    expect(find.text('덧셈과 뺄셈'), findsNothing);
    expect(b.isArchived(ops), isFalse);
    expect(b.writes, 0);

    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();
    expect(b.isArchived(ops), isTrue);
    final side = find
        .descendant(of: find.byKey(const ValueKey('course-side-list')), matching: find.byType(Scrollable))
        .first;
    await tester.scrollUntilVisible(find.textContaining('함께 보관 3개'), 200, scrollable: side);
    expect(find.text('보관한 단원 (1)'), findsOneWidget);
    expect(find.text('되살리기'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('옮기기는 같은 과정 안 맞는 자리만 고를 수 있다', (tester) async {
    final (b, id, c) = _setup();
    await _pump(tester, CourseMapPane(controller: c));
    final complex = b.unitId(id, '복소수');
    await tester.tap(find.byKey(ValueKey('course-unit-$complex')));
    await tester.pump();

    await tester.tap(find.text('옮기기'));
    await tester.pumpAndSettle();
    expect(find.text('"복소수" 옮기기'), findsOneWidget);
    expect(find.text('지금 위치'), findsOneWidget);
    expect(find.text('I.  도형의 방정식'), findsNothing, reason: '다른 과정 단원은 고를 수 없다');
    await tester.tap(find.text('1.  다항식의 연산'));
    await tester.pump();
    expect(find.text('"복소수" 옮기기'), findsOneWidget, reason: '세 단계를 넘는 자리는 눌러도 닫히지 않는다');

    await tester.tap(find.text('I  다항식'));
    await tester.pumpAndSettle();
    expect(c.draft!.node(complex)!.parentId, b.unitId(id, '다항식'));
    expect(find.text('자리 바뀜'), findsWidgets);
    expect(b.writes, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('창 닫기·로그아웃 전 확인: 저장 안 한 편집이 없으면 묻지 않고, 있으면 과정 이름을 보이고 묻는다', (tester) async {
    final (b, id, c) = _setup();
    bool? answer;
    await _pump(
      tester,
      Builder(
        builder: (ctx) => TextButton(
          onPressed: () async => answer = await confirmDiscardCourseMapEdits(ctx, c, action: '창을 닫으면'),
          child: const Text('닫기 시도'),
        ),
      ),
    );
    await c.loadList();

    await tester.tap(find.text('닫기 시도'));
    await tester.pumpAndSettle();
    expect(answer, isTrue);
    expect(find.text('저장하지 않은 과정 편집'), findsNothing);

    c.rename(b.unitId(id, '곱셈'), '곱셈 공식');
    answer = null;
    await tester.tap(find.text('닫기 시도'));
    await tester.pumpAndSettle();
    expect(find.textContaining('공통수학1'), findsOneWidget);
    expect(find.textContaining('창을 닫으면 이 편집은 사라집니다'), findsOneWidget);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(answer, isFalse);
    expect(c.anyDirty, isTrue);

    await tester.tap(find.text('닫기 시도'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('버리고 계속'));
    await tester.pumpAndSettle();
    expect(answer, isTrue);
    expect(b.writes, 0);
  });

  testWidgets('단원에 놓인 개념 수가 흐름에 보이고, 찾아 넣기·빼기는 바로 저장된다', (tester) async {
    final (b, id, c) = _setup();
    final add = b.unitId(id, '덧셈과 뺄셈');
    final k1 = b.addConcept('다항식의 덧셈');
    final k2 = b.addConcept('다항식의 뺄셈');
    final p1 = b.place(add, k1, origin: 'ai', note: '교재 1단원 덧셈');
    await _pump(tester, CourseMapPane(controller: c));

    expect(find.descendant(of: find.byKey(ValueKey('unit-concepts-$add')), matching: find.text('1')), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('course-unit-$add')));
    await tester.pump();
    expect(find.text('이 단원의 개념 (1)'), findsNothing);
    expect(find.byKey(const ValueKey('placement-add')), findsOneWidget);
    expect(find.text('개념 추가'), findsOneWidget);
    expect(find.text('소단원 추가'), findsOneWidget);
    expect(find.textContaining('뒤에'), findsNothing);
    expect(find.textContaining('위로·아래로는'), findsNothing);
    expect(find.textContaining('넣은 개념은'), findsNothing);
    expect(tester.getTopLeft(find.byKey(const ValueKey('placement-add'))).dy,
        lessThan(tester.getTopLeft(find.text('아래로')).dy));
    await tester.tap(find.byKey(ValueKey('unit-concepts-$add')));
    await tester.pump();
    expect(find.text('다항식의 덧셈'), findsOneWidget);
    expect(find.descendant(of: find.byKey(ValueKey('outline-concept-$p1')), matching: find.text('Think')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('placement-add')));
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    await tester.enterText(find.descendant(of: dialog, matching: find.byType(TextField)), '다항식');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.descendant(of: dialog, matching: find.text('이미 있음')), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('concept-pick-$k1')));
    await tester.pump();
    expect(find.text('넣기 (0)'), findsOneWidget, reason: '이미 있는 개념은 고를 수 없다');
    await tester.tap(find.byKey(ValueKey('concept-pick-$k2')));
    await tester.pump();
    expect(b.writes, 0);
    await tester.tap(find.byKey(const ValueKey('concept-pick-confirm')));
    await tester.pumpAndSettle();
    expect(b.namesIn(add), ['다항식의 덧셈', '다항식의 뺄셈']);
    expect(find.text('개념 1개를 넣었습니다.'), findsOneWidget);
    expect(find.byKey(ValueKey('outline-concept-$p1')), findsOneWidget);
    expect(find.text('저장 안 한 변경 1곳'), findsNothing, reason: '배치는 탐색도 저장과 따로 바로 저장된다');

    await tester.tap(find.byKey(ValueKey('outline-concept-menu-$p1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('이 단원에서 빼기').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('개념은 라이브러리에 그대로'), findsOneWidget);
    await tester.tap(find.widgetWithText(ElevatedButton, '빼기'));
    await tester.pumpAndSettle();
    expect(b.namesIn(add), ['다항식의 뺄셈']);
    expect(find.byKey(ValueKey('outline-concept-$p1')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('개념 옮기기는 이미 그 개념이 있는 단원을 막고, 고른 단원 끝으로 옮긴다', (tester) async {
    final (b, id, c) = _setup();
    final add = b.unitId(id, '덧셈과 뺄셈');
    final mul = b.unitId(id, '곱셈');
    final identity = b.unitId(id, '항등식');
    final k1 = b.addConcept('다항식의 덧셈');
    final p1 = b.place(add, k1, origin: 'ai');
    b.place(mul, k1);
    await _pump(tester, CourseMapPane(controller: c));
    await tester.tap(find.byKey(ValueKey('course-unit-$add')));
    await tester.pump();
    await tester.tap(find.byKey(ValueKey('unit-concepts-$add')));
    await tester.pump();

    await tester.tap(find.byKey(ValueKey('outline-concept-menu-$p1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('다른 단원으로 옮기기'));
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    expect(find.text('"다항식의 덧셈" 옮기기'), findsOneWidget);
    expect(find.descendant(of: dialog, matching: find.text('지금 위치')), findsOneWidget);
    expect(find.descendant(of: dialog, matching: find.textContaining('Think 근거는 지워집니다')), findsOneWidget);
    await tester.tap(find.descendant(of: dialog, matching: find.text('곱셈')));
    await tester.pump();
    expect(dialog, findsOneWidget, reason: '이미 그 개념이 있는 단원은 눌러도 닫히지 않는다');
    expect(b.writes, 0);

    await tester.tap(find.descendant(of: dialog, matching: find.text('항등식')));
    await tester.pumpAndSettle();
    expect(b.namesIn(add), isEmpty);
    expect(b.namesIn(identity), ['다항식의 덧셈']);
    expect(find.textContaining('단원으로 옮겼습니다'), findsOneWidget);
    expect(find.byKey(ValueKey('outline-concept-$p1')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('개념 배치를 읽지 못하면 안내와 다시 읽기만 보이고 예전 목록을 보이지 않는다', (tester) async {
    final (b, id, c) = _setup();
    final add = b.unitId(id, '덧셈과 뺄셈');
    b.place(add, b.addConcept('다항식의 덧셈'));
    b.failPlacements = CourseMapException('not_ready', 'DB에 개념 배치 기능이 아직 없습니다.');
    await _pump(tester, CourseMapPane(controller: c));
    await tester.tap(find.byKey(ValueKey('course-unit-$add')));
    await tester.pump();

    expect(find.textContaining('DB에 개념 배치 기능이 아직 반영되지 않았습니다'), findsOneWidget);
    expect(find.text('다항식의 덧셈'), findsNothing);
    expect(find.byKey(const ValueKey('placement-add')), findsNothing);
    expect(find.byKey(ValueKey('unit-concepts-$add')), findsNothing);

    b.failPlacements = null;
    await tester.tap(find.text('다시 읽기'));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(ValueKey('unit-concepts-$add')));
    await tester.pump();
    expect(find.text('다항식의 덧셈'), findsOneWidget);
    expect(find.byKey(ValueKey('outline-concept-${c.placementsIn(id, add).single.id}')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('요약은 읽기만 하고 저장 안 한 편집을 알린다', (tester) async {
    final (b, id, c) = _setup();
    var expanded = 0;
    await _pump(tester, CourseMapSummaryPane(controller: c, onExpand: () => expanded += 1), width: 420);

    expect(find.text('덧셈과 뺄셈'), findsOneWidget);
    expect(find.text('저장'), findsNothing);
    expect(find.text('대단원 추가'), findsNothing);

    c.rename(b.unitId(id, '곱셈'), '곱셈 공식');
    await tester.pump();
    expect(find.textContaining('저장하지 않은 변경 1곳'), findsOneWidget);
    expect(find.text('곱셈 공식'), findsOneWidget);

    await tester.tap(find.text('크게 보기'));
    expect(expanded, 1);
    expect(b.writes, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('요약에서 소단원을 누르면 놓인 개념 줄이 펼쳐지고, 개념을 누르면 라이브러리에서 연다', (tester) async {
    final (b, id, c) = _setup();
    final add = b.unitId(id, '덧셈과 뺄셈');
    final k1 = b.addConcept('다항식의 덧셈');
    final p1 = b.place(add, k1, origin: 'ai', note: '교재 1단원 덧셈');
    final p2 = b.place(add, b.addConcept('다항식의 뺄셈'));
    final opened = <String>[];
    await _pump(tester, CourseMapSummaryPane(controller: c, onOpenConcept: opened.add), width: 420);

    final top = b.unitId(id, '다항식');
    expect(find.descendant(of: find.byKey(ValueKey('unit-tally-$top')), matching: find.text('2 · 1/3')), findsOneWidget,
        reason: '좁으면 줄여 보인다');
    expect(find.byKey(ValueKey('unit-tally-${b.unitId(id, '방정식과 부등식')}')), findsNothing, reason: '놓인 개념이 없으면 합계를 숨긴다');
    expect(find.byKey(ValueKey('outline-concept-$p1')), findsNothing);

    await tester.tap(find.byKey(ValueKey('course-unit-$add')));
    await tester.pump();
    expect(find.byKey(ValueKey('outline-concept-$p1')), findsOneWidget);
    expect(find.byKey(ValueKey('outline-concept-$p2')), findsOneWidget);
    expect(find.descendant(of: find.byKey(ValueKey('outline-concept-$p1')), matching: find.text('Think')), findsOneWidget);
    expect(find.descendant(of: find.byKey(ValueKey('outline-concept-$p2')), matching: find.text('Think')), findsNothing);

    await tester.tap(find.text('다항식의 덧셈'));
    await tester.pump();
    expect(opened, [k1]);

    await tester.tap(find.byKey(ValueKey('course-unit-$add')));
    await tester.pump();
    expect(find.byKey(ValueKey('outline-concept-$p1')), findsNothing);
    expect(b.writes, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('고른 개념 줄만 단원과 같은 강조를 받는다', (tester) async {
    final (b, id, c) = _setup();
    final add = b.unitId(id, '덧셈과 뺄셈');
    final k1 = b.addConcept('다항식의 덧셈');
    final p1 = b.place(add, k1);
    final p2 = b.place(add, b.addConcept('다항식의 뺄셈'));
    final selected = ValueNotifier<String?>(null);
    addTearDown(selected.dispose);

    BoxDecoration fill(String placementId) {
      final box = find.byKey(ValueKey('outline-concept-fill-$placementId'));
      return tester.widget<Container>(box).decoration! as BoxDecoration;
    }

    await _pump(
      tester,
      CourseMapSummaryPane(
        controller: c,
        selectedConceptId: selected,
        onOpenConcept: (conceptId) => selected.value = conceptId,
      ),
      width: 420,
    );

    await tester.tap(find.byKey(ValueKey('course-unit-$add')));
    await tester.pump();
    expect(fill(p1).color, Colors.transparent);
    expect(fill(p2).color, Colors.transparent);

    await tester.tap(find.text('다항식의 덧셈'));
    await tester.pump();
    expect(fill(p1).color, kThinkAccent.withValues(alpha: 0.16));
    expect((fill(p1).border! as Border).top.color, kThinkAccent.withValues(alpha: 0.6));
    expect(fill(p2).color, Colors.transparent);

    selected.value = null;
    await tester.pump();
    expect(fill(p1).color, Colors.transparent);
    expect(tester.takeException(), isNull);
  });

  testWidgets('정의·표현은 제자리이고 그 밖 유형만 한 칸 더 들어간다', (tester) async {
    final (b, id, c) = _setup();
    final add = b.unitId(id, '덧셈과 뺄셈');
    final def = b.place(add, b.addConcept('다항식'), type: '정의');
    final expr = b.place(add, b.addConcept('전개'), type: '표현');
    final prop = b.place(add, b.addConcept('인수분해'), type: '성질');
    final none = b.place(add, b.addConcept('미정'), type: '');
    await _pump(tester, CourseMapSummaryPane(controller: c), width: 420);

    double left(String placementId) =>
        (tester.widget<Container>(find.byKey(ValueKey('outline-concept-fill-$placementId'))).padding! as EdgeInsets)
            .left;

    await tester.tap(find.byKey(ValueKey('course-unit-$add')));
    await tester.pump();
    final base = left(def);
    expect(left(expr), base);
    expect(left(prop), base + 16);
    expect(left(none), base + 16);
    expect(tester.takeException(), isNull);
  });

  testWidgets('개념 줄은 오래 눌러 끌어 순서를 바꾸고, Think 칩을 누르면 확인으로 걷힌다', (tester) async {
    final (b, id, c) = _setup();
    final add = b.unitId(id, '덧셈과 뺄셈');
    final p1 = b.place(add, b.addConcept('첫째'), origin: 'ai', note: '교재 근거');
    final p2 = b.place(add, b.addConcept('둘째'));
    await _pump(tester, CourseMapPane(controller: c), height: 1400);

    await tester.tap(find.byKey(ValueKey('course-unit-$add')));
    await tester.pump();
    await tester.tap(find.byKey(ValueKey('unit-concepts-$add')));
    await tester.pump();
    expect(find.descendant(of: find.byKey(ValueKey('outline-concept-$p1')), matching: find.text('Think')), findsOneWidget);
    expect(b.namesIn(add), ['첫째', '둘째']);

    final start = tester.getCenter(find.byKey(ValueKey('outline-concept-$p1')));
    final second = find.byKey(ValueKey('outline-concept-$p2'));
    final next = tester.getCenter(second);
    final secondTop = tester.getTopLeft(second).dy;
    final drag = await tester.startGesture(start);
    await tester.pump();
    await tester.pump(kLongPressTimeout);
    expect(tester.takeException(), isNull);
    expect(find.byType(Opacity), findsWidgets, reason: '오래 누르면 드래그가 시작된다');
    await drag.moveTo(next);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('concept-drop-gap')), findsOneWidget);
    expect(tester.getTopLeft(second).dy, secondTop, reason: '빈 칸은 대상 뒤에 열려 대상 줄은 제자리에 남는다');
    await drag.up();
    await tester.pumpAndSettle();
    expect(b.namesIn(add), ['둘째', '첫째']);

    await tester.tap(find.byKey(ValueKey('outline-think-$p1')));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byKey(ValueKey('outline-concept-$p1')), matching: find.text('Think')), findsNothing);
    expect(find.text('확인했습니다.'), findsOneWidget);
    final row = c.placementsIn(id, add).singleWhere((p) => p.id == p1);
    expect(row.byThink, isFalse);
    expect(row.note, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('흐름의 Think 칩을 눌러도 그 배치를 확인한다', (tester) async {
    final (b, id, c) = _setup();
    final add = b.unitId(id, '덧셈과 뺄셈');
    final p1 = b.place(add, b.addConcept('다항식의 덧셈'), origin: 'ai', note: '교재 근거');
    await _pump(tester, CourseMapSummaryPane(controller: c), width: 420);

    await tester.tap(find.byKey(ValueKey('course-unit-$add')));
    await tester.pump();
    await tester.tap(find.byKey(ValueKey('outline-think-$p1')));
    await tester.pumpAndSettle();
    expect(find.text('Think'), findsNothing);
    expect(c.placementsIn(id, add).single.byThink, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('옆 칸에 넘긴 내용은 선택한 단원보다 위에 둔다', (tester) async {
    final (_, _, c) = _setup();
    await _pump(tester, CourseMapPane(
      controller: c,
      aboveSelection: const Text('고른 개념'),
    ));

    expect(find.text('고른 개념'), findsOneWidget);
    expect(tester.getTopLeft(find.text('고른 개념')).dy, lessThan(tester.getTopLeft(find.text('선택한 단원')).dy));
    expect(tester.takeException(), isNull);
  });

  testWidgets('크게 보기에서는 단원을 눌러도 옆 칸만 열고, 개념 수를 누르거나 개념 펼치기로 줄을 펼친다', (tester) async {
    final (b, id, c) = _setup();
    final add = b.unitId(id, '덧셈과 뺄셈');
    final identity = b.unitId(id, '항등식');
    final p1 = b.place(add, b.addConcept('다항식의 덧셈'));
    final p2 = b.place(identity, b.addConcept('항등식의 성질'));
    await _pump(tester, CourseMapPane(controller: c));

    final top = b.unitId(id, '다항식');
    expect(find.descendant(of: find.byKey(ValueKey('unit-tally-$top')), matching: find.text('개념 2 · 소단원 2/3')),
        findsOneWidget);
    await tester.tap(find.byKey(ValueKey('course-unit-$add')));
    await tester.pump();
    expect(find.byKey(const ValueKey('placement-add')), findsOneWidget);
    expect(find.byKey(ValueKey('outline-concept-$p1')), findsNothing, reason: '단원을 눌러도 개념 줄은 접혀 있다');

    await tester.tap(find.byKey(ValueKey('unit-concepts-$add')));
    await tester.pump();
    expect(find.byKey(ValueKey('outline-concept-$p1')), findsOneWidget);
    expect(find.byKey(ValueKey('outline-concept-$p2')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('outline-concepts-all')));
    await tester.pump();
    expect(find.byKey(ValueKey('outline-concept-$p2')), findsOneWidget);
    expect(find.text('개념 접기'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('outline-concepts-all')));
    await tester.pump();
    expect(find.byKey(ValueKey('outline-concept-$p1')), findsNothing);
    expect(find.text('저장 안 한 변경 1곳'), findsNothing);
    expect(b.writes, 0);
    expect(tester.takeException(), isNull);
  });

  group('최근 변경 기록', () {
    CourseChange change(String key, Map<String, dynamic> j, {Duration ago = Duration.zero}) => CourseChange.fromJson({
          'key': key,
          'at': DateTime.now().subtract(ago).toUtc().toIso8601String(),
          'concept_id': 'k-$key',
          ...j,
        });

    testWidgets('배치·본문·서술 기록을 새것부터 보이고, 거르기·더 보기·개념 열기를 한다', (tester) async {
      final (b, _, c) = _setup();
      b.changes.addAll([
        change('p:3', {
          'kind': 'placement', 'action': 'move', 'concept_name': '다항식의 덧셈', 'course_name': '공통수학1',
          'path': ['다항식', '다항식의 연산', '곱셈'], 'from_path': ['다항식', '다항식의 연산', '덧셈과 뺄셈'],
          'origin': 'ai', 'action_id': 'a1', 'note': '교재 순서',
        }),
        change('c:1', {
          'kind': 'content', 'concept_name': '항등식', 'before_name': '항등식 뜻', 'after_name': '항등식',
          'renamed': true, 'content_changed': true, 'via': 'draft', 'origin': 'ai',
        }),
        change('s:1', {'kind': 'statement', 'concept_name': '복소수', 'role': 'statement', 'title': '허수단위', 'version': 2}),
        change('b:1', {
          'kind': 'placement', 'action': 'add', 'before_log': true, 'concept_name': '곱셈 공식',
          'course_name': '공통수학1', 'path': ['다항식', '다항식의 연산', '곱셈'], 'origin': 'owner',
        }, ago: const Duration(days: 1)),
      ]);
      b.changePage = 3;
      final opened = <String>[];
      await _pump(tester, CourseMapPane(controller: c, onOpenConcept: opened.add));
      await tester.tap(find.byKey(const ValueKey('course-change-log')));
      await tester.pumpAndSettle();

      expect(find.text('최근 변경 기록'), findsOneWidget);
      expect(find.text('오늘'), findsOneWidget);
      final moved = find.byKey(const ValueKey('change-p:3'));
      expect(find.descendant(of: moved, matching: find.text('옮김')), findsOneWidget);
      expect(find.descendant(of: moved, matching: find.text('Think 카드')), findsOneWidget);
      expect(find.descendant(of: moved, matching: find.text('공통수학1 · 다항식 > 다항식의 연산 > 덧셈과 뺄셈  →  다항식 > 다항식의 연산 > 곱셈')),
          findsOneWidget);
      expect(find.descendant(of: moved, matching: find.text('Think 근거: 교재 순서')), findsOneWidget);
      final edited = find.byKey(const ValueKey('change-c:1'));
      expect(find.descendant(of: edited, matching: find.text('이름·본문 고침')), findsOneWidget);
      expect(find.descendant(of: edited, matching: find.text('Think 수정안 확정')), findsOneWidget);
      expect(find.descendant(of: edited, matching: find.text('"항등식 뜻" → "항등식" · 본문도 고침')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('change-s:1')), matching: find.text('서술 "허수단위" v2 확정')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('change-b:1')), findsNothing, reason: '한 번에 정한 수만 읽는다');

      await tester.tap(find.byKey(const ValueKey('change-log-more')));
      await tester.pumpAndSettle();
      final before = find.byKey(const ValueKey('change-b:1'));
      expect(find.text('어제'), findsOneWidget);
      expect(find.descendant(of: before, matching: find.text('기록 시작 전')), findsOneWidget);
      expect(find.descendant(of: before, matching: find.text('공통수학1 · 지금 위치: 다항식 > 다항식의 연산 > 곱셈')), findsOneWidget);
      await tester.scrollUntilVisible(find.text('여기까지입니다.'), 200,
          scrollable: find.descendant(of: find.byType(Dialog), matching: find.byType(Scrollable)).first);
      expect(find.byKey(const ValueKey('change-log-more')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('change-filter-edits')));
      await tester.pumpAndSettle();
      expect(b.changeKinds.last, [kCourseChangePlacement]);
      expect(find.byKey(const ValueKey('change-c:1')), findsNothing);
      expect(find.byKey(const ValueKey('change-p:3')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('change-open-p:3')));
      await tester.pumpAndSettle();
      expect(find.text('최근 변경 기록'), findsNothing, reason: '개념을 열면 창을 닫는다');
      expect(opened, ['k-p:3']);
      expect(b.writes, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('DB 반영 전이면 안내만 보이고 기록을 대신 보이지 않는다', (tester) async {
      final (b, _, c) = _setup();
      b.changes.add(change('p:1', {'kind': 'placement', 'action': 'add', 'concept_name': '가', 'origin': 'owner'}));
      b.failChanges = CourseMapException('not_ready', 'DB에 아직 없습니다.');
      await _pump(tester, CourseMapSummaryPane(controller: c), width: 420);
      await tester.tap(find.byKey(const ValueKey('course-change-log')));
      await tester.pumpAndSettle();

      expect(find.textContaining('DB에 변경 기록 기능이 아직 반영되지 않았습니다'), findsOneWidget);
      expect(find.byKey(const ValueKey('change-p:1')), findsNothing);

      b.failChanges = null;
      await tester.tap(find.text('다시 읽기').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('change-p:1')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('change-p:1')), matching: find.text('직접')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('개념 라이브러리 탭은 과정 관리 왼쪽이고, 연결하지 않으면 보이지 않는다', (tester) async {
      final (_, _, c) = _setup();
      var opened = 0;
      await _pump(tester, CourseMapPane(controller: c, onShowLibrary: () => opened++));
      final tab = find.byKey(const ValueKey('course-show-library'));
      final menu = find.byTooltip('과정 관리');
      expect(tab, findsOneWidget);
      expect(find.text('개념 라이브러리'), findsOneWidget);
      expect(menu, findsOneWidget);
      expect(tester.getTopLeft(tab).dx, lessThan(tester.getTopLeft(menu).dx));
      await tester.tap(tab);
      await tester.pump();
      expect(opened, 1);

      await _pump(tester, CourseMapPane(controller: c));
      expect(find.byKey(const ValueKey('course-show-library')), findsNothing);
      expect(find.byTooltip('과정 관리'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

  testWidgets('트리에서 수업 블록을 만들고 인라인 이름 수정·접기/펼치기·드래그 소속/순서 이동·블록 풀기가 모두 동작한다', (tester) async {
    final (b, id, c) = _setup();
    final add = b.unitId(id, '덧셈과 뺄셈');
    final k1 = b.addConcept('소수');
    final k2 = b.addConcept('합성수');
    final k3 = b.addConcept('거듭제곱');
    final p1 = b.place(add, k1);
    final p2 = b.place(add, k2);
    final p3 = b.place(add, k3);
    await _pump(tester, CourseMapPane(controller: c), height: 1400);

    // 1) 트리 단원 행에서 바로 '+ 블록' 생성 → 즉시 인라인 이름 입력 활성화
    await tester.tap(find.byKey(ValueKey('course-unit-$add')));
    await tester.pump();
    await tester.tap(find.byKey(ValueKey('unit-add-block-$add')));
    await tester.pumpAndSettle();

    final block1 = c.blocksIn(id, add).single;
    final inputFinder = find.byKey(ValueKey('block-name-input-${block1.id}'));
    expect(inputFinder, findsOneWidget, reason: '블록 생성 즉시 트리 안에서 이름 입력 칸이 열린다');

    await tester.enterText(inputFinder, '소수와 합성수');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('소수와 합성수'), findsOneWidget);
    expect(c.blocksIn(id, add).single.name, '소수와 합성수');

    // 2) 낱개 개념(소수, 합성수)을 드래그해서 블록 헤더 위로 놓으면 블록 안으로 들어간다
    for (final pid in [p1, p2]) {
      final from = tester.getCenter(find.byKey(ValueKey('outline-concept-$pid')));
      final ontoBlock = tester.getCenter(find.byKey(ValueKey('outline-block-${block1.id}')));
      final drag = await tester.startGesture(from);
      await tester.pump();
      await tester.pump(kLongPressTimeout);
      await drag.moveTo(ontoBlock);
      await tester.pump(const Duration(milliseconds: 200));
      await drag.up();
      await tester.pumpAndSettle();
    }
    expect(c.placementsInBlock(id, add, block1.id).map((p) => p.name), ['소수', '합성수']);
    expect(c.placementsInBlock(id, add, null).map((p) => p.name), ['거듭제곱']);

    // 3) 접었다 펼치기 모션(AnimatedAlign heightFactor 1.0 ↔ 0.0) 확인
    AnimatedAlign collapseAlign(String bid) =>
        tester.widget<AnimatedAlign>(find.byKey(ValueKey('outline-block-collapse-$bid')));
    expect(collapseAlign(block1.id).heightFactor, 1.0);

    await tester.tap(find.byKey(ValueKey('block-toggle-${block1.id}')));
    await tester.pumpAndSettle();
    expect(collapseAlign(block1.id).heightFactor, 0.0);

    await tester.tap(find.byKey(ValueKey('block-toggle-${block1.id}')));
    await tester.pumpAndSettle();
    expect(collapseAlign(block1.id).heightFactor, 1.0);

    // 4) 두 번째 블록 생성('새 블록으로 묶기' 메뉴 활용) 후 블록 자체 드래그로 순서 이동
    await tester.tap(find.byKey(ValueKey('outline-concept-menu-$p3')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('새 블록으로 묶기'));
    await tester.pumpAndSettle();

    final block2 = c.blocksIn(id, add).last;
    await tester.enterText(find.byKey(ValueKey('block-name-input-${block2.id}')), '거듭제곱의 뜻');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(c.blocksIn(id, add).map((x) => x.name), ['소수와 합성수', '거듭제곱의 뜻']);

    final b1Center = tester.getCenter(find.byKey(ValueKey('outline-block-${block1.id}')));
    final b2Center = tester.getCenter(find.byKey(ValueKey('outline-block-${block2.id}')));
    final blockDrag = await tester.startGesture(b1Center);
    await tester.pump();
    await tester.pump(kLongPressTimeout);
    await blockDrag.moveTo(b2Center);
    await tester.pump(const Duration(milliseconds: 220));
    await blockDrag.up();
    await tester.pumpAndSettle();
    expect(c.blocksIn(id, add).map((x) => x.name), ['거듭제곱의 뜻', '소수와 합성수']);

    // 5) 블록 풀기 시 안의 원자개념들은 지워지지 않고 단원에 그대로 남는다
    await tester.tap(find.byKey(ValueKey('block-menu-${block1.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('블록 풀기 (개념은 단원에 유지)'));
    await tester.pumpAndSettle();

    expect(c.blocksIn(id, add).map((x) => x.name), ['거듭제곱의 뜻']);
    expect(c.placementsInBlock(id, add, null).map((p) => p.name), ['소수', '합성수']);
    expect(tester.takeException(), isNull);
  });
}
