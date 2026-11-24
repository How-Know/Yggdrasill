import 'dart:math' as math;

import 'geom.dart';

/// 계산이 끝난 그림. 길이는 mm, 원점은 왼쪽 위, y 는 아래로 자란다.
///
/// 인쇄 출력과 화면 출력은 모두 이 목록만 보고 그린다. 그래서 두 출력의 모양이 같다.
class Scene {
  Scene({required this.width, required this.height, required this.items, required this.style, required this.engine});

  final double width, height;
  final List<SceneItem> items;
  final String style;
  final String engine;

  /// 이 그림에서 왼쪽 위가 ([left], [top]) 이고 크기가 [width]×[height] 인 창으로 본 그림.
  ///
  /// 그림판을 원본보다 넓게 잡은 그림을 원본과 겹쳐 볼 때, 원본이 차지하는 자리만 잘라 내는 데 쓴다.
  Scene window(double left, double top, double width, double height) {
    final by = P(-left, -top);
    return Scene(
      width: width,
      height: height,
      style: style,
      engine: engine,
      items: [
        for (final it in items)
          switch (it) {
            PathItem() => PathItem(it.path.map((p) => p + by), stroke: it.stroke, fill: it.fill, layer: it.layer, source: it.source),
            TextItem() => TextItem(it.pos + by, it.tex,
                anchorDeg: it.anchorDeg, sizePt: it.sizePt, background: it.background, raw: it.raw, source: it.source, key: it.key),
          },
      ],
    );
  }
}

sealed class SceneItem {
  SceneItem(this.layer, this.source);

  /// 그리는 순서(작을수록 아래). 채움 < 가는 선 < 굵은 선 < 점 < 글자.
  final int layer;

  /// 이 조각을 만든 그림 요소의 이름(편집기에서 집을 때 쓴다).
  final String? source;
}

class Stroke {
  const Stroke(this.width, {this.dash, this.roundCap = true});
  final double width;
  final List<double>? dash;
  final bool roundCap;
}

class PathItem extends SceneItem {
  PathItem(this.path, {this.stroke, this.fill, required int layer, String? source}) : super(layer, source);
  final Path2 path;
  final Stroke? stroke;

  /// 채움 밝기(0=검정, 1=흰색). null 이면 채우지 않는다.
  final double? fill;
}

class TextItem extends SceneItem {
  TextItem(this.pos, this.tex,
      {this.anchorDeg, required this.sizePt, this.background = false, this.raw = false, this.key = '', String? source})
      : super(40, source);
  final P pos;

  /// 이 글자를 가리키는 열쇠. 그림 파일의 label_nudge 에 이 열쇠로 미세 이동을 적는다.
  final String key;

  /// 수식 글(TeX). [raw] 가 아니면 수식 모드로 조판한다.
  final String tex;

  /// 글 상자의 테두리에서 이 방향(화면 기준, 도)의 점을 [pos] 에 맞춘다. null 이면 가운데를 맞춘다.
  final double? anchorDeg;
  final double sizePt;
  final bool background;
  final bool raw;
}

enum Cmd { move, line, cubic, close }

/// 선과 3차 곡선으로 이루어진 길.
class Path2 {
  final List<Cmd> cmds = [];
  final List<P> pts = [];

  bool get isEmpty => cmds.isEmpty;
  P? get last => pts.isEmpty ? null : pts.last;

  void moveTo(P p) {
    cmds.add(Cmd.move);
    pts.add(p);
  }

  void lineTo(P p) {
    if (cmds.isEmpty) return moveTo(p);
    cmds.add(Cmd.line);
    pts.add(p);
  }

  void cubicTo(P c1, P c2, P p) {
    cmds.add(Cmd.cubic);
    pts
      ..add(c1)
      ..add(c2)
      ..add(p);
  }

  void close() => cmds.add(Cmd.close);

  void polyline(List<P> points, {bool continuing = false}) {
    for (var i = 0; i < points.length; i++) {
      (i == 0 && !continuing) ? moveTo(points[i]) : lineTo(points[i]);
    }
  }

  /// 원호. a0 에서 a1 까지(라디안, 수학 좌표 기준 반시계가 +) 3차 곡선으로 잇는다.
  void arc(P center, double r, double a0, double a1, {bool continuing = false}) {
    final start = center + P.polar(r, a0);
    continuing ? lineTo(start) : moveTo(start);
    final sweep = a1 - a0;
    final n = math.max(1, (sweep.abs() / (math.pi / 4)).ceil());
    final step = sweep / n;
    final k = 4 / 3 * math.tan(step / 4);
    for (var i = 0; i < n; i++) {
      final t0 = a0 + step * i, t1 = t0 + step;
      final p0 = center + P.polar(r, t0), p1 = center + P.polar(r, t1);
      cubicTo(p0 + P(-math.sin(t0), math.cos(t0)) * (k * r), p1 - P(-math.sin(t1), math.cos(t1)) * (k * r), p1);
    }
  }

  Path2 map(P Function(P) f) {
    final out = Path2();
    out.cmds.addAll(cmds);
    out.pts.addAll(pts.map(f));
    return out;
  }

  /// 길을 짧은 선분들로 편다(겹쳐 비교·맞춤 계산용). [step] 은 점 사이 간격.
  List<List<P>> flatten(double step) {
    final out = <List<P>>[];
    var cur = <P>[];
    var i = 0;
    P? start;
    void addLine(P a, P b) {
      final n = math.max(1, (a.distanceTo(b) / step).ceil());
      for (var k = 1; k <= n; k++) {
        cur.add(a + (b - a) * (k / n));
      }
    }

    for (final c in cmds) {
      switch (c) {
        case Cmd.move:
          if (cur.length > 1) out.add(cur);
          cur = [pts[i]];
          start = pts[i];
          i += 1;
        case Cmd.line:
          addLine(cur.last, pts[i]);
          i += 1;
        case Cmd.cubic:
          final p0 = cur.last, c1 = pts[i], c2 = pts[i + 1], p3 = pts[i + 2];
          final len = p0.distanceTo(c1) + c1.distanceTo(c2) + c2.distanceTo(p3);
          final n = math.max(2, (len / step).ceil());
          for (var k = 1; k <= n; k++) {
            final t = k / n, u = 1 - t;
            cur.add(p0 * (u * u * u) + c1 * (3 * u * u * t) + c2 * (3 * u * t * t) + p3 * (t * t * t));
          }
          i += 3;
        case Cmd.close:
          if (start != null && cur.isNotEmpty) addLine(cur.last, start);
      }
    }
    if (cur.length > 1) out.add(cur);
    return out;
  }
}
