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
}
