import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:ygg_figure/ygg_figure.dart';

double _eval(String source, [Map<String, double> vars = const {}]) => Expr.parse(source).eval((n) => vars[n]);

Map<String, dynamic> _doc(List<Map<String, dynamic>> objects, {Map<String, dynamic>? params}) => {
      'format': figureFormat,
      'canvas': {
        'width': 40,
        'height': 40,
        'origin': [20, 20],
        'unit': 10,
      },
      if (params != null) 'params': params,
      'objects': objects,
    };

/// 이름으로 찾은 조각의 첫 점(mm, 왼쪽 위 기준).
P _first(Scene scene, String source) => scene.items.whereType<PathItem>().firstWhere((i) => i.source == source).path.pts.first;

void main() {
  group('수식', () {
    test('사칙연산과 우선순위', () {
      expect(_eval('1+2*3'), 7);
      expect(_eval('-2^2'), -4);
      expect(_eval('2^-1'), 0.5);
      expect(_eval('(1+2)*3'), 9);
    });

    test('곱하기 생략', () {
      expect(_eval('2x', {'x': 3}), 6);
      expect(_eval('2x^2', {'x': 3}), 18);
      expect(_eval('3(x+1)', {'x': 1}), 6);
      expect(_eval('2sin(pi/2)'), closeTo(2, 1e-12));
    });

    test('함수와 상수', () {
      expect(_eval('sqrt(16)+abs(-2)'), 6);
      expect(_eval('ln(e)'), closeTo(1, 1e-12));
      expect(_eval('log(100)'), closeTo(2, 1e-12));
      expect(_eval('log(2, 8)'), closeTo(3, 1e-12));
      expect(_eval('(-8)^(1/3)'), closeTo(-2, 1e-12));
    });

    test('모르는 이름은 오류', () {
      expect(() => _eval('a+1'), throwsA(isA<ExprError>()));
    });
  });

  group('관계', () {
    test('교점·중점·수선의 발은 관계대로 정해진다', () {
      final scene = buildFigure(_doc([
        {'id': 'A', 'type': 'point', 'at': [0, 0]},
        {'id': 'B', 'type': 'point', 'at': [1, 0]},
        {'id': 'C', 'type': 'point', 'at': [0, 1]},
        {'id': 'k', 'type': 'circle', 'center': 'A', 'radius': 1, 'draw': false},
        {'id': 'M', 'type': 'midpoint', 'of': ['B', 'C'], 'dot': 'small'},
        {'id': 'X', 'type': 'intersect', 'of': ['k', ['A', 'M']], 'near': 'M', 'dot': 'small'},
        {'id': 'H', 'type': 'foot', 'from': 'A', 'to': ['B', 'C'], 'dot': 'small'},
      ]));
      // 점은 반지름 0.4mm 의 원으로 그려지고, 첫 점은 중심에서 오른쪽으로 반지름만큼 떨어진 곳이다.
      final m = _first(scene, 'M'), x = _first(scene, 'X'), h = _first(scene, 'H');
      expect(m.x, closeTo(20 + 5 + 0.4, 1e-6));
      expect(m.y, closeTo(20 - 5, 1e-6));
      expect(x.x, closeTo(20 + 10 * math.sqrt1_2 + 0.4, 1e-6));
      expect(h.x, closeTo(m.x, 1e-6)); // 직각이등변삼각형이라 수선의 발이 중점과 같다.
    });

    test('변수를 바꾸면 관계에 걸린 점이 따라 움직인다', () {
      final doc = _doc([
        {'id': 'f', 'type': 'function', 'expr': 'a*x^2', 'domain': [-1, 1], 'draw': false},
        {'id': 'P', 'type': 'on', 'of': 'f', 'x': 1, 'dot': 'small'},
      ], params: {'a': 1});
      final before = _first(buildFigure(doc), 'P');
      final after = _first(buildFigure(doc, params: {'a': 0.5}), 'P');
      expect(before.y, closeTo(10, 1e-6));
      expect(after.y, closeTo(15, 1e-6));
    });

    test('함수와 직선의 교점', () {
      final scene = buildFigure(_doc([
        {'id': 'f', 'type': 'function', 'expr': 'x^2', 'domain': [-1.5, 1.5], 'draw': false},
        {'id': 'P', 'type': 'intersect', 'of': ['f', [[0, 1], [1, 1]]], 'near': [1, 1], 'dot': 'small'},
      ]));
      expect(_first(scene, 'P').x, closeTo(20 + 10 + 0.4, 1e-5));
    });

    test('공간의 점은 정한 방향으로 비춘다', () {
      final doc = _doc([
        {'id': 'A', 'type': 'point', 'at': [1, 1, 1], 'dot': 'small'},
      ])
        ..['projection'] = {
          'x': [1, 0],
          'y': [0.5, 0.5],
          'z': [0, 1],
        };
      final a = _first(buildFigure(doc), 'A');
      expect(a.x, closeTo(20 + 15 + 0.4, 1e-6));
      expect(a.y, closeTo(20 - 15, 1e-6));
    });

    test('성립하지 않는 관계는 어느 요소인지 알려 준다', () {
      expect(
        () => buildFigure(_doc([
          {'id': 'k', 'type': 'circle', 'center': [0, 0], 'radius': 1},
          {'id': 'X', 'type': 'intersect', 'of': ['k', [[0, 2], [1, 2]]]},
        ])),
        throwsA(isA<FigureError>().having((e) => e.objectId, 'objectId', 'X')),
      );
    });
  });

  group('출력', () {
    test('같은 그림은 언제나 같은 글자열이 된다', () {
      final doc = _doc([
        {'type': 'axes', 'x': [-1.8, 1.8], 'y': [-1.8, 1.8]},
        {'id': 'f', 'type': 'function', 'expr': 'sin(3x)', 'domain': [-1.5, 1.5]},
        {'id': 'A', 'type': 'point', 'at': [1, 1], 'label': 'NE'},
      ]);
      expect(sceneToTikz(buildFigure(doc)), sceneToTikz(buildFigure(doc)));
    });

    test('그림판 크기와 판 번호가 출력에 적힌다', () {
      final scene = buildFigure(_doc([
        {'id': 'A', 'type': 'point', 'at': [0, 0], 'label': 'N'},
      ]));
      expect(scene.width, 40);
      expect(scene.height, 40);
      final tikz = sceneToTikz(scene);
      expect(tikz, contains('engine=$engineVersion'));
      expect(tikz, contains('style=${FigureStyle.latest.name}'));
      expect(tikz, contains(r'\mathrm{A}'));
    });

    test('라벨 미세 이동은 관계와 따로 적는다', () {
      final doc = _doc([
        {'id': 'A', 'type': 'point', 'at': [0, 0], 'label': 'N'},
      ]);
      final before = buildFigure(doc).items.whereType<TextItem>().single.pos;
      doc['label_nudge'] = {
        'A': [1, 2],
      };
      final after = buildFigure(doc).items.whereType<TextItem>().single.pos;
      expect(after.x - before.x, closeTo(1, 1e-9));
      expect(after.y - before.y, closeTo(-2, 1e-9)); // 위쪽이 +, 화면에서는 y 가 줄어든다.
    });

    test('모르는 그림체 규격은 받지 않는다', () {
      expect(() => buildFigure({'style': 'unknown-1', 'objects': []}), throwsArgumentError);
    });
  });

  group('부품', () {
    Map<String, dynamic> withParts(List<Map<String, dynamic>> objects, {Map<String, dynamic>? nudge}) => {
          ..._doc(objects),
          'parts': {
            'bar': [
              {'id': 's', 'type': 'segment', 'from': [0, 0], 'to': [1, 0]},
            ],
            'stage': [
              {'id': 'A#{k}', 'type': 'point', 'at': [1, 0], 'label': 'E'},
              {'id': 'e#{k}', 'type': 'segment', 'from': [0, 0], 'to': 'A#{k}'},
            ],
          },
          if (nudge != null) 'label_nudge': nudge,
        };

    test('옮기고 키워서 그린다', () {
      final scene = buildFigure(withParts([
        {'id': 'u', 'type': 'use', 'part': 'bar', 'at': [1, 1], 'scale': 0.5},
      ]));
      final pts = scene.items.whereType<PathItem>().firstWhere((i) => i.source == 's').path.pts;
      expect(pts.first.x, closeTo(30, 1e-9));
      expect(pts.first.y, closeTo(10, 1e-9));
      expect(pts.last.x, closeTo(35, 1e-9));
      expect(pts.last.y, closeTo(10, 1e-9));
    });

    test('되풀이하면 단계마다 닮음 변환이 거듭되고 이름의 #{k} 가 바뀐다', () {
      final scene = buildFigure(withParts([
        {'id': 'u', 'type': 'use', 'part': 'stage', 'count': 3, 'step': {'scale': 0.5, 'about': [0, 0]}},
      ]));
      final texts = scene.items.whereType<TextItem>().toList();
      expect(texts.map((t) => t.key), ['u.1/A1', 'u.2/A2', 'u.3/A3']);
      expect(texts.map((t) => t.tex), [r'\mathrm{A}_{1}', r'\mathrm{A}_{2}', r'\mathrm{A}_{3}']);
      // 세 번째 단계의 선분 끝은 (1/4, 0).
      final end = scene.items.whereType<PathItem>().firstWhere((i) => i.source == 'e3').path.pts.last;
      expect(end.x, closeTo(22.5, 1e-9));
      expect(end.y, closeTo(20, 1e-9));
    });

    test('돌린 부품도 제자리에 놓인다', () {
      final scene = buildFigure(withParts([
        {'id': 'u', 'type': 'use', 'part': 'bar', 'at': [1, 0], 'rotate': 90},
      ]));
      final pts = scene.items.whereType<PathItem>().firstWhere((i) => i.source == 's').path.pts;
      expect(pts.last.x, closeTo(30, 1e-9));
      expect(pts.last.y, closeTo(10, 1e-9));
    });

    test('같은 부품을 두 번 써도 라벨을 따로 옮길 수 있다', () {
      List<TextItem> labels(Map<String, dynamic>? nudge) => buildFigure(withParts([
            {'id': 'p1', 'type': 'use', 'part': 'stage', 'with': {'k': 1}, 'index': 'i'},
            {'id': 'p2', 'type': 'use', 'part': 'stage', 'at': [0, -1], 'with': {'k': 1}, 'index': 'i'},
          ], nudge: nudge))
              .items
              .whereType<TextItem>()
              .toList();
      final before = labels(null), after = labels({'p2/A1': [2, 0]});
      expect(before.map((t) => t.key), ['p1/A1', 'p2/A1']);
      expect(after[0].pos.x, closeTo(before[0].pos.x, 1e-9));
      expect(after[1].pos.x, closeTo(before[1].pos.x + 2, 1e-9));
    });

    test('부품 밖에서는 부품 안의 점을 쓸 수 없다', () {
      expect(
        () => buildFigure(withParts([
          {'id': 'u', 'type': 'use', 'part': 'stage', 'with': {'k': 1}, 'index': 'i'},
          {'type': 'segment', 'from': [0, 0], 'to': 'A1'},
        ])),
        throwsA(isA<FigureError>()),
      );
    });

    test('없는 부품은 오류', () {
      expect(
        () => buildFigure(withParts([
          {'type': 'use', 'part': 'nope'},
        ])),
        throwsA(isA<FigureError>()),
      );
    });
  });

  test('호 끝에 화살촉을 달 수 있다', () {
    final scene = buildFigure(_doc([
      {'id': 'c', 'type': 'arc', 'center': [0, 0], 'radius': 1, 'angles': [0, 90], 'arrow': 'end'},
    ]));
    final parts = scene.items.whereType<PathItem>().where((i) => i.source == 'c').toList();
    expect(parts.where((i) => i.fill == 0).length, 1); // 촉
    expect(parts.where((i) => i.stroke != null).length, 1); // 호
  });

  group('크기', () {
    test('배율은 도형과 그림판에만 곱해지고 글자·선 굵기는 그대로다', () {
      final doc = _doc([
        {'id': 'A', 'type': 'point', 'at': [1, 1], 'label': {'dir': 'NE', 'dist': 1.0}},
        {'id': 'B', 'type': 'point', 'at': [-1, 0]},
        {'id': 's', 'type': 'segment', 'from': 'A', 'to': 'B'},
      ]);
      final one = buildFigure(doc), half = buildFigure(doc, scale: 0.5);
      expect(half.width, 20);
      expect(half.height, 20);
      // 원점(20,20)에서 A(1,1)까지: 10mm → 5mm.
      expect(_first(one, 's').x, closeTo(30, 1e-9));
      expect(_first(half, 's').x, closeTo(15, 1e-9));
      expect(_first(half, 's').y, closeTo(5, 1e-9));
      final strokeOne = one.items.whereType<PathItem>().firstWhere((i) => i.source == 's').stroke!.width;
      final strokeHalf = half.items.whereType<PathItem>().firstWhere((i) => i.source == 's').stroke!.width;
      expect(strokeHalf, strokeOne);
      final labelOne = one.items.whereType<TextItem>().first, labelHalf = half.items.whereType<TextItem>().first;
      expect(labelHalf.sizePt, labelOne.sizePt);
      // 글자와 점 사이 간격(mm)도 그대로다.
      expect((labelHalf.pos - _first(half, 's')).x, closeTo((labelOne.pos - _first(one, 's')).x, 1e-9));
      expect(() => buildFigure(doc, scale: 0), throwsA(isA<FigureError>()));
    });

    test('크기 표: 양식 × 자리로 찾고, 나눈 칸과 그림에 따로 적은 값이 먼저다', () {
      final table = FigureSizeTable.fromJson({
        'format': 'ygg-figure-sizes/1',
        'slots': [
          {'format': 'mock', 'position': 'below-stem', 'width_em': 17.5, 'max_height_em': 17.5},
          {'format': 'mock', 'position': 'below-stem', 'variant': 'wide', 'width_em': 24},
          {'format': 'naesin', 'position': 'inline-right', 'width_em': 10},
        ],
      });
      expect(table.slot('mock', 'below-stem')!.widthEm, 17.5);
      expect(table.slot('mock', 'below-stem', variant: 'wide')!.widthEm, 24);
      expect(table.slot('mock', 'below-stem', variant: 'none')!.widthEm, 17.5);
      expect(table.slot('assignment', 'below-stem'), isNull);

      expect(table.slotFor({}, 'mock', 'below-stem')!.fromFigure, isFalse);
      expect(table.slotFor({'size': {'variant': 'wide'}}, 'mock', 'below-stem')!.widthEm, 24);
      final own = table.slotFor({
        'size': {
          'overrides': {
            'mock/below-stem': {'width_em': 26, 'note': '평면이 넓다'},
          },
        },
      }, 'mock', 'below-stem')!;
      expect(own.widthEm, 26);
      expect(own.maxHeightEm, 17.5);
      expect(own.note, '평면이 넓다');
      expect(own.fromFigure, isTrue);
      // 다른 칸은 표 그대로다.
      expect(table.slotFor({'size': {'overrides': {'mock/below-stem': {'width_em': 26}}}}, 'naesin', 'inline-right')!.widthEm, 10);
      expect(() => FigureSizeTable.fromJson({'format': 'x'}), throwsFormatException);
    });

    test('크기 표: 본문 너비의 비율로 적은 칸과 크기 부류(소·중·대)', () {
      final json = {
        'format': 'ygg-figure-sizes/1',
        'columns': {'assignment': 22.0},
        'slots': [
          {'format': 'assignment', 'position': 'below-stem', 'variant': 'small', 'width_ratio': 0.5},
          {'format': 'assignment', 'position': 'below-stem', 'width_ratio': 0.7},
          {'format': 'assignment', 'position': 'below-stem', 'variant': 'large', 'width_ratio': 0.85},
          {'format': 'assignment', 'position': 'inline-right', 'width_ratio': 0.3333},
        ],
      };
      final table = FigureSizeTable.fromJson(json);
      double width(String? cls, [String position = 'below-stem']) =>
          table.slotFor({if (cls != null) 'size': {'variant': cls}}, 'assignment', position)!.widthEm;
      expect(width('small'), closeTo(11.0, 1e-9));
      // 부류를 안 적었거나 "중"이면 기본 칸이다.
      expect(width(null), closeTo(15.4, 1e-9));
      expect(width('medium'), closeTo(15.4, 1e-9));
      expect(width('large'), closeTo(18.7, 1e-9));
      // 어울림 자리는 부류와 상관없이 한 크기다.
      expect(width('large', 'inline-right'), closeTo(7.3326, 1e-9));
      // 비율로 읽은 칸은 비율로 다시 적힌다.
      expect(table.toJson(), json);
      expect(
        () => FigureSizeTable.fromJson({
          'format': 'ygg-figure-sizes/1',
          'slots': [
            {'format': 'mock', 'position': 'below-stem', 'width_ratio': 0.5},
          ],
        }),
        throwsFormatException,
      );
      // 저장소의 크기 표가 읽히고, 수능 그림마다 부류가 적혀 있다.
      final repo = FigureSizeTable.fromJson(jsonDecode(File('figures/size_table.json').readAsStringSync()) as Map<String, dynamic>);
      for (final f in Directory('figures/csat').listSync().whereType<File>().where((f) => f.path.endsWith('.json'))) {
        final doc = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        expect(figureSizeClasses, contains((doc['size'] as Map)['variant']), reason: f.path);
        expect(doc['kind'], isA<String>(), reason: f.path);
        expect(repo.slotFor(doc, 'assignment', 'below-stem'), isNotNull);
      }
    });

    test('화면용 크기 어림: 정한 너비에 맞추고, 높이 한도를 넘으면 높이에 맞춘다', () {
      // 그림판 40×40mm, 도형은 가로 20mm(선 굵기 제외) × 세로 30mm.
      final doc = _doc([
        {'id': 'A', 'type': 'point', 'at': [-1, -1.5], 'label': {'dir': 'SW', 'dist': 1.0}},
        {'id': 'B', 'type': 'point', 'at': [1, 1.5]},
        {'id': 's', 'type': 'segment', 'from': 'A', 'to': 'B'},
      ]);
      final natural = buildFigure(doc);
      final wide = sizedSceneEstimate(doc, widthMm: 60);
      expect(wide.widthMm, closeTo(60, 0.05));
      expect(wide.scene.width, wide.widthMm);
      expect(wide.scale, closeTo(2, 0.02));
      // 글자 크기와, 도형 밖 여백(그림판 − 도형)은 그대로다.
      expect(wide.scene.items.whereType<TextItem>().first.sizePt, natural.items.whereType<TextItem>().first.sizePt);
      final g0 = natural.geometryBounds()!, g1 = wide.scene.geometryBounds()!;
      expect(g1.left, closeTo(g0.left, 0.05));
      expect(wide.scene.width - g1.right, closeTo(natural.width - g0.right, 0.05));

      final capped = sizedSceneEstimate(doc, widthMm: 60, maxHeightMm: 50);
      expect(capped.heightMm, closeTo(50, 0.05));
      expect(capped.widthMm, lessThan(60));
    });
  });

  group('편집', () {
    Map<String, dynamic> load(String name) =>
        jsonDecode(File('figures/csat/$name.json').readAsStringSync()) as Map<String, dynamic>;

    test('자유로운 점은 끈 자리로 가고, 이어진 선이 따라온다', () {
      final doc = jsonDecode(jsonEncode(_doc([
        {'id': 'A', 'type': 'point', 'at': [1, 1]},
        {'id': 'B', 'type': 'point', 'at': [-1, 0]},
        {'id': 's', 'type': 'segment', 'from': 'A', 'to': 'B'},
      ]))) as Map<String, dynamic>;
      expect(movePoint(doc, 'A', const P(35, 8)), isTrue);
      final after = layoutFigure(doc);
      expect(after.points['A']!.distanceTo(const P(35, 8)), lessThan(0.01));
      expect(_first(after.scene, 's').distanceTo(const P(35, 8)), lessThan(0.01));
      // 그림판 (35, 8)mm 는 원점 (20, 20), 단위 10mm 에서 수학 좌표 (1.5, 1.2) 다.
      expect(after.toMath(const P(35, 8)).x, closeTo(1.5, 1e-9));
      expect(((doc['objects'] as List)[0] as Map)['at'], [1.5, 1.2]);
    });

    test('원 위의 점은 원 위에서만 움직이고, 식에 쓰인 변수를 고친다', () {
      final doc = load('csat-2022-calculus-28-1');
      final before = layoutFigure(doc);
      final o = before.points['O']!, p = before.points['P']!;
      final r = o.distanceTo(p);
      // 원 밖 먼 곳으로 끌어도 원 위에 남는다.
      expect(movePoint(doc, 'P', o + const P(30, -60)), isTrue);
      final after = layoutFigure(doc);
      expect(after.points['P']!.distanceTo(o), closeTo(r, 0.01));
      expect(after.points['P']!.distanceTo(p), greaterThan(5));
      expect((doc['params'] as Map)['th'], isNot(17.4297));
      // 다른 것에서 계산되는 점(교점)은 끌 수 없다.
      expect(canMovePoint(doc, 'R'), isFalse);
      expect(movePoint(doc, 'R', const P(10, 10)), isFalse);
    });

    test('이름 붙이기와 저장 모양은 그림을 바꾸지 않는다', () {
      final names = Directory('figures/csat').listSync().whereType<File>().map((f) => f.uri.pathSegments.last.replaceAll('.json', ''));
      for (final name in names) {
        final doc = load(name);
        final before = sceneToTikz(buildFigure(doc));
        ensureObjectIds(doc);
        expect(sceneToTikz(buildFigure(doc)), before, reason: name);
        final again = jsonDecode(formatFigureJson(doc)) as Map<String, dynamic>;
        expect(sceneToTikz(buildFigure(again)), before, reason: name);
        expect(formatFigureJson(doc).split('\n').length, greaterThan(figureObjects(doc).length));
      }
      final doc = _doc([]);
      expect(nextPointName(doc), 'A');
      figureObjects(doc);
      (doc['objects'] as List).add({'id': 'A', 'type': 'point', 'at': [0, 0]});
      expect(nextPointName(doc), 'B');
      expect(nextObjectId(doc, 's'), 's1');
    });
  });

  test('저장소의 그림 파일은 모두 그려진다', () {
    final dir = Directory('figures/csat');
    final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList();
    expect(files, isNotEmpty);
    for (final file in files) {
      final doc = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final scene = buildFigure(doc);
      expect(scene.items, isNotEmpty, reason: file.path);
      expect(doc['format'], figureFormat, reason: file.path);
    }
  });

  group('이름표', () {
    test('요소 태그는 그림 파일에서 저절로 나온다', () {
      final doc = _doc([
        {'type': 'point', 'name': 'A', 'at': [0, 0]},
        {'type': 'point', 'name': 'B', 'at': [1, 0]},
        {'type': 'point', 'name': 'C', 'at': [0, 1]},
        {'type': 'polygon', 'points': ['A', 'B', 'C'], 'fill': 'gray'},
        {'type': 'circle', 'center': 'A', 'radius': 1, 'line': 'dashed'},
        {'type': 'segment', 'from': 'A', 'to': 'B', 'line': 'dashed', 'draw': false},
      ]);
      expect(figureElements(doc), ['triangle', 'polygon', 'circle', 'fill', 'dashed-line']);
      expect(figureElements({...doc, 'elements': ['quadrilateral']}), contains('quadrilateral'));
    });

    test('저장소의 그림은 모두 태그 목록에 있는 이름표만 쓴다', () {
      final vocabulary = jsonDecode(File('figures/tags.json').readAsStringSync()) as Map<String, dynamic>;
      for (final entry in (vocabulary['tags'] as Map).entries) {
        expect((vocabulary['groups'] as Map).containsKey((entry.value as Map)['group']), isTrue, reason: '${entry.key}');
      }
      final files = Directory('figures/csat').listSync().whereType<File>().where((f) => f.path.endsWith('.json'));
      for (final file in files) {
        final doc = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        expect(checkFigureTags(doc, vocabulary), isEmpty, reason: file.path);
      }
    });
  });
}
