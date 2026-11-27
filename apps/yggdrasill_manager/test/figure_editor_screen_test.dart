import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ygg_figure/ygg_figure.dart';
import 'package:yggdrasill_manager/screens/figure_engine/figure_editor_screen.dart';
import 'package:yggdrasill_manager/screens/think/think_style.dart';
import 'package:yggdrasill_manager/services/figure_sample_print.dart';
import 'package:yggdrasill_manager/widgets/figure/figure_canvas.dart';

const _circle = 'csat-2023-common-13-1.json';

/// 엔진의 실제 그림 파일 한 장을 임시 폴더에 복사해 연다(저장소의 파일은 건드리지 않는다).
Directory _folder() {
  final dir = Directory.systemTemp.createTempSync('ygg-figure-editor');
  addTearDown(() => dir.deleteSync(recursive: true));
  File('../../packages/ygg_figure/figures/csat/$_circle').copySync('${dir.path}/$_circle');
  return dir;
}

Future<void> _pump(
  WidgetTester tester,
  Directory dir, {
  Size size = const Size(1600, 900),
  Future<FigureSampleResult> Function(String format)? sampleRunner,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: FigureEditorScreen(folder: dir.path, embedded: true, sampleRunner: sampleRunner)));
  await tester.pump();
}

/// 1×1 흰 점 PNG.
const _png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

Future<void> _tap(WidgetTester tester, String label) async {
  await tester.tap(find.text(label).first);
  await tester.pump();
}

FigureCanvas _canvas(WidgetTester tester) => tester.widget<FigureCanvas>(find.byType(FigureCanvas));

/// 그림판의 mm 자리를 화면 자리로.
Offset _at(WidgetTester tester, P mm) {
  final canvas = _canvas(tester);
  return tester.getTopLeft(find.byType(FigureCanvas)) + Offset(mm.x * canvas.pxPerMm, mm.y * canvas.pxPerMm);
}

Map<String, dynamic> _read(Directory dir, String name) =>
    jsonDecode(File('${dir.path}/$name').readAsStringSync()) as Map<String, dynamic>;

void main() {
  testWidgets('그림을 열면 점 손잡이가 보이고, 원 위의 점을 끌어 저장하면 파일의 값이 바뀐다', (tester) async {
    final dir = _folder();
    await _pump(tester, dir);
    expect(tester.takeException(), isNull);
    final before = _canvas(tester).points;
    expect(before.keys, containsAll(['A', 'B', 'C', 'D']));
    expect(_canvas(tester).movable, contains('D'));

    await tester.dragFrom(_at(tester, before['D']!), const Offset(-60, 30));
    await tester.pump();
    final after = _canvas(tester).points;
    expect(after['D']!.distanceTo(before['D']!), greaterThan(3));
    // 원 위의 점이라 원에서 벗어나지 않고, 끌지 않은 점은 그대로다.
    expect(after['A']!.distanceTo(before['A']!), lessThan(1e-6));

    final was = (_read(dir, _circle)['params'] as Map)['da'];
    await _tap(tester, '저장');
    expect((_read(dir, _circle)['params'] as Map)['da'], isNot(was));
    expect(buildFigure(_read(dir, _circle)).items, isNotEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('새 그림에 선분을 그리고 저장하면 그림 파일이 생기고, 되돌리기로 지워진다', (tester) async {
    final dir = _folder();
    await _pump(tester, dir);
    await _tap(tester, '새 그림');
    await _tap(tester, '선분');
    await tester.tapAt(_at(tester, const P(15, 30)));
    await tester.pump();
    await tester.tapAt(_at(tester, const P(45, 12)));
    await tester.pump();
    expect(_canvas(tester).points.keys, ['A', 'B']);
    await _tap(tester, '저장');

    final saved = _read(dir, '새그림-1.json');
    final types = [for (final o in saved['objects'] as List) (o as Map)['type']];
    expect(types, ['point', 'point', 'segment']);
    expect(buildFigure(saved).items.whereType<PathItem>(), isNotEmpty);

    await _tap(tester, '되돌리기');
    expect(_canvas(tester).points.keys, ['A']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('다른 도형이 쓰는 점은 지워지지 않고 이유를 보여 준다', (tester) async {
    final dir = _folder();
    await _pump(tester, dir);
    await tester.tapAt(_at(tester, _canvas(tester).points['A']!));
    await tester.pump();
    await _tap(tester, '지우기');
    expect(find.textContaining('되돌렸습니다'), findsOneWidget);
    expect(_canvas(tester).points.keys, contains('A'));
  });

  testWidgets('양식에 올려 보기: 만든 쪽을 보여 주고, 크기를 0.1 글자 고치면 다시 만들라고 알린다', (tester) async {
    final dir = _folder();
    final page = File('${dir.path}/page-1.png')..writeAsBytesSync(base64Decode(_png));
    final asked = <String>[];
    await _pump(tester, dir, size: const Size(1280, 800), sampleRunner: (format) async {
      asked.add(format);
      return FigureSampleResult(format: format, pages: [page.path], pdf: '', questions: 20, figures: [
        {'id': 'a', 'needs_check': true},
      ]);
    });
    expect(tester.takeException(), isNull);
    await _tap(tester, '양식에 올려 보기');
    await _tap(tester, '샘플 20문항 올려 보기 (임시)');
    await tester.pump();
    expect(asked, ['mock']);
    // 아직 풀리지 않은 그림은 높이가 0 이라 화면 밖으로 치므로, 화면 밖까지 찾는다.
    expect(find.byType(Image, skipOffstage: false), findsOneWidget);
    expect(find.textContaining('문항 20개 · 1쪽 · 도형이 많이 달라진 그림 1장'), findsOneWidget);
    // 인쇄 도구가 읽을 수 있게 크기 표를 먼저 저장한다.
    final before = FigureSizeTable.fromJson(_read(dir, 'size_table.json')).slot('mock', 'below-stem')!.widthEm;

    await tester.tap(find.byTooltip('0.1 글자 늘리기').first);
    await tester.pump();
    expect(find.textContaining('눌러야 아래 인쇄본에 반영됩니다'), findsOneWidget);
    await _tap(tester, '다시 만들기');
    await tester.pump();
    expect(asked, ['mock', 'mock']);
    expect(find.textContaining('눌러야 아래 인쇄본에 반영됩니다'), findsNothing);
    final after = FigureSizeTable.fromJson(_read(dir, 'size_table.json')).slot('mock', 'below-stem')!.widthEm;
    expect(after, closeTo(before + 0.1, 1e-9));
    expect(tester.takeException(), isNull);
  });

  testWidgets('문제 안에서 보기에서 크기 표를 고쳐 저장하면 표 파일이 생긴다', (tester) async {
    final dir = _folder();
    await _pump(tester, dir);
    await _tap(tester, '문제 안에서 보기');
    expect(tester.takeException(), isNull);
    expect(find.widgetWithText(ThinkBadge, '저장 전'), findsNothing);
    await tester.drag(find.byType(Slider).first, const Offset(40, 0));
    await tester.pump();
    expect(find.widgetWithText(ThinkBadge, '저장 전'), findsOneWidget);
    await _tap(tester, '저장');
    final table = FigureSizeTable.fromJson(_read(dir, 'size_table.json'));
    expect(table.slot('mock', 'below-stem')!.widthEm, isNot(16));
    expect(tester.takeException(), isNull);
  });

  testWidgets('과제형: 그림의 크기 부류(소·중·대)를 바꾸고, 그 부류의 너비를 본문 너비의 %로 고친다', (tester) async {
    final dir = _folder();
    File('../../packages/ygg_figure/figures/size_table.json').copySync('${dir.path}/size_table.json');
    await _pump(tester, dir, size: const Size(1280, 1400));
    await _tap(tester, '문제 안에서 보기');
    await _tap(tester, '과제');
    expect(tester.takeException(), isNull);
    // 이 그림은 "소"로 적혀 있다.
    expect(find.text('크기 표 · 소 (모든 그림)'), findsOneWidget);
    final small = _canvas(tester).scene.width;

    await _tap(tester, '대');
    expect(find.text('크기 표 · 대 (모든 그림)'), findsOneWidget);
    expect(_canvas(tester).scene.width, greaterThan(small * 1.4));
    await tester.tap(find.byTooltip('1% 늘리기'));
    await tester.pump();
    await _tap(tester, '저장');

    expect((_read(dir, _circle)['size'] as Map)['variant'], 'large');
    final saved = _read(dir, 'size_table.json');
    expect((saved['columns'] as Map)['assignment'], isNotNull);
    final table = FigureSizeTable.fromJson(saved);
    expect(table.slot('assignment', 'below-stem', variant: 'large')!.widthRatio, closeTo(0.86, 1e-9));
    // 다른 부류와 다른 양식의 칸은 그대로다.
    expect(table.slot('assignment', 'below-stem', variant: 'small')!.widthRatio, closeTo(0.5, 1e-9));
    expect(table.slot('assignment', 'below-stem')!.widthRatio, closeTo(0.7, 1e-9));
    expect(table.slot('mock', 'below-stem', variant: 'large')!.widthRatio, closeTo(0.85, 1e-9));
    expect(tester.takeException(), isNull);
  });
}
