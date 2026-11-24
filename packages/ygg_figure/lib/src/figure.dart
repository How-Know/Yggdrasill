import 'dart:math' as math;

import 'expr.dart';
import 'geom.dart';
import 'scene.dart';
import 'style.dart';

/// 엔진 판 번호. 같은 그림 파일이 다르게 그려질 수 있는 변경을 하면 올린다.
const engineVersion = '0.1.0';

/// 그림 파일의 형식 이름.
const figureFormat = 'ygg-figure/1';

class FigureError implements Exception {
  FigureError(this.message, [this.objectId]);
  final String message;
  final String? objectId;
  @override
  String toString() => objectId == null ? '그림 오류: $message' : '그림 오류($objectId): $message';
}

sealed class Ent {}

class PointEnt extends Ent {
  PointEnt(this.p, [this.p3]);
  final P p;

  /// 공간의 점이면 원래 좌표(x, y, z).
  final List<double>? p3;
}

class LineEnt extends Ent {
  LineEnt(this.a, this.b, {this.infA = false, this.infB = false});
  final P a, b;
  final bool infA, infB;
}

class CircleEnt extends Ent {
  CircleEnt(this.c, this.r);
  final P c;
  final double r;
}

/// 함수 그래프·매개변수 곡선·타원. 잘게 나눈 점들과, 매개변수로 점을 내는 식을 함께 가진다.
class CurveEnt extends Ent {
  CurveEnt(this.at, this.pieces, this.params);
  final P Function(double t) at;
  final List<List<P>> pieces;
  final List<List<double>> params;
}

/// 그림 파일(JSON)을 읽어 관계를 풀고, 그릴 조각 목록([Scene])을 만든다.
///
/// 같은 파일·같은 판이면 언제나 같은 결과를 낸다(시각·난수 등을 쓰지 않는다).
Scene buildFigure(Map<String, dynamic> doc, {Map<String, double>? params}) {
  return _Builder(doc, params).build();
}

/// 그림 파일에 적힌 변수 값(이름 → 값).
Map<String, double> figureParams(Map<String, dynamic> doc) {
  final out = <String, double>{};
  final raw = doc['params'];
  if (raw is Map) {
    raw.forEach((k, v) {
      final value = v is Map ? v['value'] : v;
      if (value is num) out['$k'] = value.toDouble();
    });
  }
  return out;
}

const _compass = {'E': 0.0, 'NE': 45.0, 'N': 90.0, 'NW': 135.0, 'W': 180.0, 'SW': 225.0, 'S': 270.0, 'SE': 315.0};

class _Builder {
  _Builder(this.doc, Map<String, double>? override) : style = FigureStyle.byName(doc['style'] as String?) {
    params.addAll(figureParams(doc));
    if (override != null) params.addAll(override);
  }

  final Map<String, dynamic> doc;
  final FigureStyle style;
  final params = <String, double>{};
  final ents = <String, Ent>{};
  final items = <SceneItem>[];
  String? _current;

  /// 지금 읽는 요소의 열쇠(이름이 있으면 이름, 없으면 '#순번'). 라벨 미세 이동을 적는 데 쓴다.
  String _key = '';

  /// 수학 단위 하나의 길이(mm). 부품(use) 안에서는 그 부품의 배율이 곱해진다.
  double get unit => _baseUnit * _tScale;
  late final double _baseUnit;

  // 지금 그리는 부품의 자리: 배율, 돌린 각(라디안, 반시계), 부품 원점의 자리(원점 기준 mm).
  double _tScale = 1, _tRot = 0;
  P _tOff = const P(0, 0);
  String _keyPrefix = '';
  int _depth = 0;
  double? width, height, ox, oy;
  List<P>? proj;

  // ---- 값 읽기 ----

  double? _lookup(String name) {
    final v = params[name];
    if (v != null) return v;
    final dot = name.lastIndexOf('.');
    if (dot > 0) {
      final e = ents[name.substring(0, dot)];
      if (e is PointEnt) {
        return switch (name.substring(dot + 1)) {
          'x' => e.p3?[0] ?? e.p.x,
          'y' => e.p3?[1] ?? e.p.y,
          _ => e.p3?[2] ?? 0,
        };
      }
    }
    return null;
  }

  double n(dynamic v, [String what = '값']) {
    if (v is num) return v.toDouble();
    if (v is String) {
      try {
        final r = Expr.parse(v).eval(_lookup);
        if (r.isNaN || r.isInfinite) throw FigureError('$what "$v" 를 계산할 수 없습니다', _current);
        return r;
      } on ExprError catch (e) {
        throw FigureError('$what: ${e.message}', _current);
      }
    }
    throw FigureError('$what 가 없습니다', _current);
  }

  double nOr(dynamic v, double fallback) => v == null ? fallback : n(v);

  PointEnt ptEnt(dynamic v, [String what = '점']) {
    if (v is String) {
      final e = ents[v];
      if (e is PointEnt) return e;
      throw FigureError('$what "$v" 을(를) 찾을 수 없습니다', _current);
    }
    if (v is List && v.length == 2) return PointEnt(P(n(v[0]), n(v[1])));
    if (v is List && v.length == 3) {
      final c = [n(v[0]), n(v[1]), n(v[2])];
      return PointEnt(project(c), c);
    }
    throw FigureError('$what 을(를) 읽을 수 없습니다', _current);
  }

  P pt(dynamic v, [String what = '점']) => ptEnt(v, what).p;

  P project(List<double> c) {
    final m = proj;
    if (m == null) throw FigureError('공간 좌표를 쓰려면 projection 이 있어야 합니다', _current);
    return m[0] * c[0] + m[1] * c[1] + m[2] * c[2];
  }

  Ent ent(dynamic v, [String what = '대상']) {
    if (v is String) {
      final e = ents[v];
      if (e == null) throw FigureError('$what "$v" 을(를) 찾을 수 없습니다', _current);
      return e;
    }
    if (v is List && v.length == 2) return LineEnt(pt(v[0]), pt(v[1]), infA: true, infB: true);
    throw FigureError('$what 을(를) 읽을 수 없습니다', _current);
  }

  LineEnt lineEnt(dynamic v, [String what = '직선']) {
    final e = ent(v, what);
    if (e is LineEnt) return e;
    throw FigureError('$what 이(가) 직선이 아닙니다', _current);
  }

  double? dirDeg(dynamic v) {
    if (v == null) return null;
    if (v is String && _compass.containsKey(v.toUpperCase())) return _compass[v.toUpperCase()];
    return n(v, '방향');
  }

  // ---- 좌표 ----

  /// 수학 좌표 → 원점 기준 mm(y 는 아래로).
  P mm(P m) {
    final q = (_tRot == 0 ? m : m.rotate(_tRot)) * unit;
    return P(q.x, -q.y) + _tOff;
  }

  /// 그림판 안에 보이는 수학 좌표 범위(xmin, ymin, xmax, ymax). 그림판 크기를 모르면 null.
  List<double>? get frame {
    if (width == null) return null;
    if (_depth == 0) return [-ox! / unit, -(height! - oy!) / unit, (width! - ox!) / unit, oy! / unit];
    // 부품 안에서는 그림판의 네 귀퉁이를 부품 좌표로 되돌려 그 범위를 쓴다.
    var x0 = double.infinity, y0 = double.infinity, x1 = -double.infinity, y1 = -double.infinity;
    for (final c in [P(-ox!, -oy!), P(width! - ox!, -oy!), P(width! - ox!, height! - oy!), P(-ox!, height! - oy!)]) {
      final d = c - _tOff;
      final m = P(d.x, -d.y).rotate(-_tRot) * (1 / unit);
      x0 = math.min(x0, m.x);
      y0 = math.min(y0, m.y);
      x1 = math.max(x1, m.x);
      y1 = math.max(y1, m.y);
    }
    return [x0, y0, x1, y1];
  }

  // ---- 조립 ----

  Scene build() {
    final canvas = doc['canvas'];
    if (canvas is Map) {
      _baseUnit = nOr(canvas['unit'] ?? doc['unit'], 10);
      width = n(canvas['width'], '그림판 너비');
      height = n(canvas['height'], '그림판 높이');
      final origin = canvas['origin'] as List?;
      ox = origin == null ? width! / 2 : n(origin[0]);
      oy = origin == null ? height! / 2 : n(origin[1]);
    } else {
      _baseUnit = nOr(doc['unit'], 10);
    }
    final projection = doc['projection'];
    if (projection is Map) {
      P axis(String k) => P(n((projection[k] as List)[0]), n((projection[k] as List)[1]));
      proj = [axis('x'), axis('y'), axis('z')];
    }

    final objects = (doc['objects'] as List? ?? const []).cast<Map>();
    for (var i = 0; i < objects.length; i++) {
      final o = objects[i].cast<String, dynamic>();
      _current = (o['id'] as String?) ?? '${i + 1}번째(${o['type']})';
      _key = (o['id'] as String?) ?? '#${i + 1}';
      _object(o);
    }
    _current = null;

    double w, h, dx, dy;
    if (width != null) {
      w = width!;
      h = height!;
      dx = ox!;
      dy = oy!;
    } else {
      var x0 = double.infinity, y0 = double.infinity, x1 = -double.infinity, y1 = -double.infinity;
      void see(P p, double pad) {
        x0 = math.min(x0, p.x - pad);
        y0 = math.min(y0, p.y - pad);
        x1 = math.max(x1, p.x + pad);
        y1 = math.max(y1, p.y + pad);
      }

      for (final it in items) {
        if (it is PathItem) {
          for (final p in it.path.pts) {
            see(p, 0.5);
          }
        } else if (it is TextItem) {
          see(it.pos, 3);
        }
      }
      if (x0 == double.infinity) {
        x0 = y0 = 0;
        x1 = y1 = 10;
      }
      const pad = 1.0;
      w = x1 - x0 + 2 * pad;
      h = y1 - y0 + 2 * pad;
      dx = pad - x0;
      dy = pad - y0;
    }
    final shift = P(dx, dy);
    final placed = <SceneItem>[
      for (final it in items)
        switch (it) {
          PathItem() => PathItem(it.path.map((p) => p + shift), stroke: it.stroke, fill: it.fill, layer: it.layer, source: it.source),
          TextItem() => TextItem(it.pos + shift, it.tex,
              anchorDeg: it.anchorDeg, sizePt: it.sizePt, background: it.background, raw: it.raw, source: it.source, key: it.key),
        },
    ];
    // 같은 층 안에서는 파일에 적힌 순서를 지킨다.
    final order = {for (var i = 0; i < placed.length; i++) placed[i]: i};
    placed.sort((a, b) => a.layer != b.layer ? a.layer.compareTo(b.layer) : order[a]!.compareTo(order[b]!));
    return Scene(width: _r(w), height: _r(h), items: placed, style: style.name, engine: engineVersion);
  }

  void _object(Map<String, dynamic> o) {
    final type = o['type'];
    final id = o['id'] as String?;
    switch (type) {
      // ---- 점 ----
      case 'use':
        _use(o);
      case 'point':
        _point(o, ptEnt(o['at'], '자리'));
      case 'midpoint':
        final of = o['of'] as List;
        _point(o, _combine(ptEnt(of[0]), ptEnt(of[1]), 0.5));
      case 'divide':
        // of: [A, B], ratio: [m, n] → 선분 AB 를 m:n 으로 나누는 점. t 를 직접 줄 수도 있다.
        final of = o['of'] as List;
        final ratio = o['ratio'] as List?;
        final t = ratio != null ? n(ratio[0]) / (n(ratio[0]) + n(ratio[1])) : n(o['t'], '비율');
        _point(o, _combine(ptEnt(of[0]), ptEnt(of[1]), t));
      case 'foot':
        _point(o, _foot(ptEnt(o['from']), o['to']));
      case 'intersect':
        final of = o['of'] as List;
        final found = _intersections(ent(of[0]), ent(of[1]));
        if (found.isEmpty) throw FigureError('만나는 점이 없습니다', id);
        _point(o, PointEnt(_choose(found, o)));
      case 'rotate':
        final center = pt(o['center'] ?? o['about'], '중심');
        _point(o, PointEnt(pt(o['of']).rotate(n(o['angle'], '각') * math.pi / 180, center)));
      case 'reflect':
        final p = pt(o['of']);
        final across = o['across'];
        if (across is String && ents[across] is PointEnt) {
          _point(o, PointEnt(pt(across) * 2 - p));
        } else {
          final l = lineEnt(across, '대칭축');
          _point(o, PointEnt(footOnLine(p, l.a, l.b) * 2 - p));
        }
      case 'translate':
        final by = o['by'] as List;
        final delta = by.every((e) => e is String && ents[e] is PointEnt) ? pt(by[1]) - pt(by[0]) : P(n(by[0]), n(by[1]));
        _point(o, PointEnt(pt(o['of']) + delta));
      case 'polar':
        // center 에서 angle(도) 방향으로 radius 만큼 떨어진 점.
        _point(o, PointEnt(pt(o['center'], '중심') + P.polar(n(o['radius'], '반지름'), n(o['angle'], '각') * math.pi / 180)));
      case 'on':
        _point(o, PointEnt(_pointOn(o)));
      case 'tangent_point':
        final c = ent(o['circle'], '원');
        if (c is! CircleEnt) throw FigureError('접점은 원에만 구합니다', id);
        final from = pt(o['from']);
        final d = from.distanceTo(c.c);
        if (d < c.r) throw FigureError('점이 원 안에 있어 접선이 없습니다', id);
        final mid = (from + c.c) * 0.5;
        _point(o, PointEnt(_choose(circleCircle(c.c, c.r, mid, d / 2), o)));

      // ---- 선 ----
      case 'segment':
        final pts = o['points'] as List?;
        _line(o, LineEnt(pt(pts?[0] ?? o['from']), pt(pts?[1] ?? o['to'])));
      case 'ray':
        _line(o, LineEnt(pt(o['from']), pt(o['through']), infB: true));
      case 'line':
        final th = o['through'] as List;
        _line(o, LineEnt(pt(th[0]), pt(th[1]), infA: true, infB: true));
      case 'perpendicular' || 'parallel':
        final l = lineEnt(o['to'], '기준 직선');
        final p = pt(o['through']);
        final d = type == 'parallel' ? (l.b - l.a).unit : (l.b - l.a).unit.normal;
        _line(o, LineEnt(p, p + d, infA: true, infB: true));
      case 'tangent':
        final p = pt(o['at']);
        final target = ent(o['to'], '곡선');
        P d;
        if (target is CircleEnt) {
          d = (p - target.c).unit.normal;
        } else if (target is CurveEnt) {
          final t = _nearestParam(target, p);
          const h = 1e-5;
          d = (target.at(t + h) - target.at(t - h)).unit;
        } else {
          throw FigureError('접선은 원이나 곡선에 긋습니다', id);
        }
        _line(o, LineEnt(p, p + d, infA: true, infB: true));
      case 'polyline' || 'polygon':
        final pts = [for (final v in o['points'] as List) pt(v)];
        final path = Path2()..polyline(pts);
        if (type == 'polygon') path.close();
        _draw(o, path, 'main');

      // ---- 원·곡선 ----
      case 'circle':
        final c = _circle(o);
        if (id != null) ents[id] = c;
        _draw(o, Path2()..arc(c.c, c.r, 0, 2 * math.pi)..close(), 'main');
      case 'arc':
        final c = _circle(o);
        if (id != null) ents[id] = c;
        double a0, a1;
        final angles = o['angles'] as List?;
        if (angles != null) {
          a0 = n(angles[0]) * math.pi / 180;
          a1 = n(angles[1]) * math.pi / 180;
        } else {
          a0 = (pt(o['from']) - c.c).angle;
          a1 = (pt(o['to']) - c.c).angle;
          a1 = _sweepEnd(a0, a1, o['dir'] as String? ?? 'ccw');
        }
        // 호 끝의 화살촉(가리킴 선 등). 촉은 호를 따라 촉 길이만큼 되돌아간 점에서 끝점을 향하게 놓는다.
        final arrow = o['arrow'] as String?;
        if (arrow != null && c.r > 0) {
          final size = nOr(o['arrow_size'], 1);
          final back = style.arrowLength * size / unit / c.r, cut = (style.arrowLength - style.arrowNotch) * size / unit / c.r;
          final sign = a1 >= a0 ? 1.0 : -1.0;
          final stroke = _stroke(o, 'main');
          final layer = stroke == null || stroke.width >= style.mainLine ? 20 : 10;
          P on(double a) => c.c + P.polar(c.r, a);
          final end = a1, start = a0;
          if (arrow == 'end' || arrow == 'both') {
            _arrowHead(on(end), (on(end) - on(end - sign * back)).unit, layer, id, size);
            a1 -= sign * cut;
          }
          if (arrow == 'start' || arrow == 'both') {
            _arrowHead(on(start), (on(start) - on(start + sign * back)).unit, layer, id, size);
            a0 += sign * cut;
          }
        }
        _draw(o, Path2()..arc(c.c, c.r, a0, a1), 'main');
      case 'ellipse':
        final c = pt(o['center'], '중심');
        final a = n(o['a'], '가로 반지름'), b = n(o['b'], '세로 반지름');
        final rot = nOr(o['rotate'], 0) * math.pi / 180;
        final angles = o['angles'] as List?;
        final t0 = angles == null ? 0.0 : n(angles[0]) * math.pi / 180;
        final t1 = angles == null ? 2 * math.pi : n(angles[1]) * math.pi / 180;
        P at(double t) => c + P(a * math.cos(t), b * math.sin(t)).rotate(rot);
        _curve(o, at, t0, t1, clip: false);
      case 'function':
        final expr = Expr.parse(o['expr'] as String);
        final name = o['var'] as String? ?? 'x';
        final domain = o['domain'] as List?;
        final f = frame;
        if (domain == null && f == null) throw FigureError('정의역(domain)이 필요합니다', id);
        final t0 = domain != null ? n(domain[0]) : f![0];
        final t1 = domain != null ? n(domain[1]) : f![2];
        P at(double t) => P(t, expr.eval((s) => s == name ? t : _lookup(s)));
        _curve(o, at, t0, t1, clip: true);
      case 'parametric':
        final ex = Expr.parse(o['x'] as String), ey = Expr.parse(o['y'] as String);
        final ez = o['z'] == null ? null : Expr.parse(o['z'] as String);
        final name = o['var'] as String? ?? 't';
        final range = o['t'] as List;
        P at(double t) {
          double? look(String s) => s == name ? t : _lookup(s);
          return ez == null ? P(ex.eval(look), ey.eval(look)) : project([ex.eval(look), ey.eval(look), ez.eval(look)]);
        }
        _curve(o, at, n(range[0]), n(range[1]), clip: o['clip'] == true);

      // ---- 채움·길 ----
      case 'fill':
        final shade = o['shade'];
        final gray = shade == null || shade == 'light' ? style.lightGray : (shade == 'dark' ? style.darkGray : n(shade));
        items.add(PathItem(_tracePath(o['path'] as List, close: true).map(mm), fill: gray, layer: 0, source: id));
      case 'path':
        _draw(o, _tracePath(o['path'] as List, close: o['close'] == true), 'main');

      // ---- 표시 ----
      case 'axes':
        _axes(o);
      case 'right_angle':
        final v = pt(o['at']);
        final s = nOr(o['size'], style.rightAngleSize) / unit;
        final u = (pt(o['from']) - v).unit * s, w = (pt(o['to']) - v).unit * s;
        _draw(o, Path2()..polyline([v + u, v + u + w, v + w]), 'thin');
      case 'angle':
        _angle(o);
      case 'dimension':
        _dimension(o);
      case 'dot':
        _dot(pt(o['at']), o['kind'] as String? ?? 'filled', o['size'], id);
      case 'label':
        final at = o['at'];
        final anchor = pt(at);
        _label(anchor, o, defaultText: at is String ? _pointTex(at) : null, source: id);
      default:
        throw FigureError('모르는 종류입니다: $type', id);
    }
  }

  // ---- 점 ----

  /// 부품(parts 에 적어 둔 요소 묶음)을 옮기고·키우고·돌려서 그린다. count 를 주면 step 만큼씩 거듭 변환하며 되풀이한다.
  ///
  /// 부품 안의 점·선은 부품 자기 좌표로 풀고, 그릴 때만 자리를 옮긴다. 그래서 부품 밖의 요소는 부품 안의 점을 쓸 수 없다.
  void _use(Map<String, dynamic> o) {
    final name = o['part'];
    final raw = (doc['parts'] as Map?)?[name];
    final list = raw is Map ? raw['objects'] : raw;
    if (list is! List) throw FigureError('부품 "$name" 을(를) 찾을 수 없습니다', _current);
    if (_depth >= 8) throw FigureError('부품이 너무 깊이 겹쳤습니다(자기 자신을 부르고 있는지 확인하세요)', _current);

    final at = o['at'] == null ? const P(0, 0) : pt(o['at'], '자리');
    final scale = nOr(o['scale'], 1), rot = nOr(o['rotate'], 0) * math.pi / 180;
    final step = (o['step'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
    final stepScale = nOr(step['scale'], 1), stepRot = nOr(step['rotate'], 0) * math.pi / 180;
    final about = step['about'] == null ? const P(0, 0) : pt(step['about'], '닮음의 중심');
    final count = nOr(o['count'], 1).round(), from = nOr(o['from'], 1).round();
    final index = o['index'] as String? ?? 'k';
    final given = (o['with'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
    final override = (o['override'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};

    final savedEnts = Map<String, Ent>.of(ents), savedParams = Map<String, double>.of(params);
    final savedScale = _tScale, savedRot = _tRot, savedOff = _tOff;
    final savedPrefix = _keyPrefix, savedKey = _key, savedCurrent = _current;
    final values = <String, double>{for (final e in given.entries) e.key: n(e.value, '부품에 넘기는 값')};
    _depth++;
    try {
      for (var i = 0; i < count; i++) {
        // 부품 좌표 p 가 바깥 좌표로 가는 길: at + scale·R(rot)·[about + stepScale^i·R(i·stepRot)·(p − about)]
        final s = scale * math.pow(stepScale, i).toDouble(), r = rot + i * stepRot;
        final origin = at + about.rotate(rot) * scale - about.rotate(r) * s;
        _tScale = savedScale;
        _tRot = savedRot;
        _tOff = savedOff;
        final off = mm(origin);
        _tOff = off;
        _tScale = savedScale * s;
        _tRot = savedRot + r;

        final vars = {...values, index: (from + i).toDouble()};
        final words = {for (final e in vars.entries) e.key: e.value == e.value.roundToDouble() ? '${e.value.round()}' : '${e.value}'};
        ents.clear();
        params
          ..clear()
          ..addAll(savedParams)
          ..addAll(vars);
        final prefix = '$savedPrefix$savedKey${o['count'] != null ? '.${from + i}' : ''}/';
        for (var j = 0; j < list.length; j++) {
          var obj = (_fill(list[j], words) as Map).cast<String, dynamic>();
          final id = obj['id'] as String?;
          final patch = id == null ? null : override[id];
          if (patch is Map) obj = {...obj, ...patch.cast<String, dynamic>()};
          _keyPrefix = prefix;
          _key = id ?? '#${j + 1}';
          _current = id ?? '$name 의 ${j + 1}번째(${obj['type']})';
          _object(obj);
        }
      }
    } finally {
      _depth--;
      ents
        ..clear()
        ..addAll(savedEnts);
      params
        ..clear()
        ..addAll(savedParams);
      _tScale = savedScale;
      _tRot = savedRot;
      _tOff = savedOff;
      _keyPrefix = savedPrefix;
      _key = savedKey;
      _current = savedCurrent;
    }
  }

  /// 글 안의 #{이름} 을 넘겨받은 값으로 바꾼다(예: "P#{k}" → "P2"). TeX 의 {k} 와 헷갈리지 않게 # 을 붙인다.
  static dynamic _fill(dynamic v, Map<String, String> words) {
    if (v is String) {
      if (!v.contains('#{')) return v;
      var out = v;
      words.forEach((k, w) => out = out.replaceAll('#{$k}', w));
      return out;
    }
    if (v is List) return [for (final e in v) _fill(e, words)];
    if (v is Map) return {for (final e in v.entries) e.key: _fill(e.value, words)};
    return v;
  }

  void _point(Map<String, dynamic> o, PointEnt e) {
    final id = o['id'] as String?;
    if (!e.p.x.isFinite || !e.p.y.isFinite) throw FigureError('점의 자리를 계산할 수 없습니다', id);
    if (id != null) ents[id] = e;
    final dot = o['dot'];
    if (dot != null && dot != 'none' && dot != false) _dot(e.p, dot == true ? 'small' : '$dot', o['dot_size'], id);
    final label = o['label'];
    if (label != null && label != false) {
      _label(e.p, label is Map ? label.cast<String, dynamic>() : {'dir': label}, defaultText: id == null ? null : _pointTex(id), source: id);
    }
  }

  PointEnt _combine(PointEnt a, PointEnt b, double t) {
    final a3 = a.p3, b3 = b.p3;
    final p3 = (a3 != null && b3 != null) ? [for (var i = 0; i < 3; i++) a3[i] + (b3[i] - a3[i]) * t] : null;
    return PointEnt(a.p + (b.p - a.p) * t, p3);
  }

  PointEnt _foot(PointEnt from, dynamic to) {
    // 공간의 점이면 공간에서 수선의 발을 구한 뒤 비춘다(비춘 그림에서는 직각이 보존되지 않는다).
    if (to is List && to.length == 2) {
      final a = ptEnt(to[0]), b = ptEnt(to[1]);
      final f3 = from.p3, a3 = a.p3, b3 = b.p3;
      if (f3 != null && a3 != null && b3 != null) {
        var num = 0.0, den = 0.0;
        for (var i = 0; i < 3; i++) {
          num += (f3[i] - a3[i]) * (b3[i] - a3[i]);
          den += (b3[i] - a3[i]) * (b3[i] - a3[i]);
        }
        final t = num / den;
        final c = [for (var i = 0; i < 3; i++) a3[i] + (b3[i] - a3[i]) * t];
        return PointEnt(project(c), c);
      }
      return PointEnt(footOnLine(from.p, a.p, b.p));
    }
    final l = lineEnt(to, '직선');
    return PointEnt(footOnLine(from.p, l.a, l.b));
  }

  P _choose(List<P> found, Map<String, dynamic> o) {
    final near = o['near'];
    if (near != null) {
      final target = pt(near, '가까운 점');
      return found.reduce((a, b) => a.distanceTo(target) <= b.distanceTo(target) ? a : b);
    }
    final sorted = [...found]..sort((a, b) => (a.x - b.x).abs() > 1e-9 ? a.x.compareTo(b.x) : a.y.compareTo(b.y));
    final pick = (o['pick'] as num?)?.toInt() ?? 0;
    if (pick < 0 || pick >= sorted.length) {
      throw FigureError('만나는 점이 ${sorted.length}개인데 ${pick + 1}번째를 골랐습니다', o['id'] as String?);
    }
    return sorted[pick];
  }

  P _pointOn(Map<String, dynamic> o) {
    final target = ent(o['of'] ?? o['on'], '대상');
    switch (target) {
      case CircleEnt():
        return target.c + P.polar(target.r, n(o['angle'], '각') * math.pi / 180);
      case LineEnt():
        return target.a + (target.b - target.a) * n(o['t'], '자리');
      case CurveEnt():
        return target.at(n(o['x'] ?? o['t'], '자리'));
      case PointEnt():
        throw FigureError('점 위에는 점을 놓을 수 없습니다', o['id'] as String?);
    }
  }

  List<P> _intersections(Ent a, Ent b) {
    if (a is PointEnt || b is PointEnt) throw FigureError('점과는 교점을 구할 수 없습니다', _current);
    if (a is LineEnt && b is LineEnt) {
      final p = lineLine(a.a, a.b, b.a, b.b);
      return p == null ? const [] : [p];
    }
    if (a is LineEnt && b is CircleEnt) return lineCircle(a.a, a.b, b.c, b.r);
    if (a is CircleEnt && b is LineEnt) return lineCircle(b.a, b.b, a.c, a.r);
    if (a is CircleEnt && b is CircleEnt) return circleCircle(a.c, a.r, b.c, b.r);
    if (a is CurveEnt && b is CurveEnt) {
      final out = <P>[];
      for (final pa in a.pieces) {
        for (final pb in b.pieces) {
          for (var i = 0; i + 1 < pa.length; i++) {
            for (var j = 0; j + 1 < pb.length; j++) {
              final p = segmentSegment(pa[i], pa[i + 1], pb[j], pb[j + 1]);
              if (p != null && out.every((q) => q.distanceTo(p) > 1e-6)) out.add(p);
            }
          }
        }
      }
      return out;
    }
    final curve = (a is CurveEnt ? a : b) as CurveEnt;
    final other = a is CurveEnt ? b : a;
    double side(P p) => switch (other) {
          LineEnt() => (p - other.a).cross((other.b - other.a).unit),
          CircleEnt() => p.distanceTo(other.c) - other.r,
          _ => 0.0,
        };
    final out = <P>[];
    for (var k = 0; k < curve.pieces.length; k++) {
      final ts = curve.params[k], ps = curve.pieces[k];
      for (var i = 0; i + 1 < ps.length; i++) {
        var f0 = side(ps[i]);
        final f1 = side(ps[i + 1]);
        if (f0 == 0) {
          out.add(ps[i]);
          continue;
        }
        if (f0 * f1 >= 0) continue;
        var lo = ts[i], hi = ts[i + 1];
        for (var it = 0; it < 60; it++) {
          final mid = (lo + hi) / 2;
          final fm = side(curve.at(mid));
          if (f0 * fm <= 0) {
            hi = mid;
          } else {
            lo = mid;
            f0 = fm;
          }
        }
        out.add(curve.at((lo + hi) / 2));
      }
    }
    return out;
  }

  double _nearestParam(CurveEnt c, P p) {
    var best = double.infinity, bk = 0, bi = 0;
    for (var k = 0; k < c.pieces.length; k++) {
      for (var i = 0; i < c.pieces[k].length; i++) {
        final d = c.pieces[k][i].distanceTo(p);
        if (d < best) {
          best = d;
          bk = k;
          bi = i;
        }
      }
    }
    final ts = c.params[bk];
    var lo = ts[math.max(0, bi - 1)], hi = ts[math.min(ts.length - 1, bi + 1)];
    for (var it = 0; it < 50; it++) {
      final m1 = lo + (hi - lo) / 3, m2 = hi - (hi - lo) / 3;
      if (c.at(m1).distanceTo(p) < c.at(m2).distanceTo(p)) {
        hi = m2;
      } else {
        lo = m1;
      }
    }
    return (lo + hi) / 2;
  }

  // ---- 선 ----

  Stroke? _stroke(Map<String, dynamic> o, String fallback) {
    final name = o['line'] as String? ?? fallback;
    final w = o['width'] == null ? null : n(o['width']);
    final dash = [style.dashOn, style.dashOff];
    return switch (name) {
      'none' => null,
      'main' => Stroke(w ?? style.mainLine),
      'thin' => Stroke(w ?? style.thinLine),
      'mid' => Stroke(w ?? style.midLine),
      'mid_dashed' => Stroke(w ?? style.midLine, dash: dash, roundCap: false),
      'dashed' => Stroke(w ?? style.thinLine, dash: dash, roundCap: false),
      'main_dashed' => Stroke(w ?? style.mainLine, dash: [style.dashOn * 1.6, style.dashOff * 1.6], roundCap: false),
      _ => throw FigureError('모르는 선 종류입니다: $name', _current),
    };
  }

  void _draw(Map<String, dynamic> o, Path2 path, String fallback) {
    if (o['draw'] == false) return;
    final stroke = _stroke(o, fallback);
    final fill = o['fill'];
    final gray = fill == null || fill == false
        ? null
        : (fill == true || fill == 'light' ? style.lightGray : (fill == 'dark' ? style.darkGray : (fill == 'white' ? 1.0 : n(fill))));
    final id = o['id'] as String?;
    final shape = path.map(mm);
    if (gray != null) items.add(PathItem(shape, fill: gray, layer: 0, source: id));
    if (stroke != null) {
      items.add(PathItem(shape, stroke: stroke, layer: nOr(o['layer'], stroke.width >= style.mainLine ? 20 : 10).round(), source: id));
    }
  }

  void _line(Map<String, dynamic> o, LineEnt l) {
    final id = o['id'] as String?;
    if (id != null) ents[id] = l;
    if (o['draw'] == false) return;
    final d = (l.b - l.a).unit;
    if (d.length == 0) throw FigureError('두 점이 같아 선을 그을 수 없습니다', id);
    var a = l.a, b = l.b;
    final span = o['span'] as List?;
    final extend = o['extend'] as List?;
    if (span != null) {
      // 기준 점(a)에서 앞뒤로 뻗는 길이(mm).
      a = l.a - d * (n(span[0]) / unit);
      b = l.a + d * (n(span[1]) / unit);
    } else if (extend != null) {
      a = l.a - d * (n(extend[0]) / unit);
      b = l.b + d * (n(extend[1]) / unit);
    } else if (l.infA || l.infB) {
      final f = frame;
      if (f == null) throw FigureError('끝없는 선은 그림판 크기(canvas)나 span 이 있어야 그립니다', id);
      final clipped = _clipLine(l.a, d, f, l.infA, l.infB ? null : l.a.distanceTo(l.b));
      if (clipped == null) return;
      a = clipped.$1;
      b = clipped.$2;
    }
    final arrow = o['arrow'] as String?;
    final stroke = _stroke(o, 'main');
    final layer = stroke == null || stroke.width >= style.mainLine ? 20 : 10;
    if (arrow == 'end' || arrow == 'both') b = _arrowHead(b, d, layer, id);
    if (arrow == 'start' || arrow == 'both') a = _arrowHead(a, d * -1, layer, id);
    _draw(o, Path2()..polyline([a, b]), 'main');
  }

  /// 화살촉을 그리고, 선이 촉 밖으로 삐져나오지 않게 선의 끝점을 촉 안쪽으로 당겨 돌려준다.
  P _arrowHead(P tip, P dir, int layer, String? source, [double size = 1]) {
    final len = style.arrowLength * size / unit, half = style.arrowWidth * size / 2 / unit, notch = style.arrowNotch * size / unit;
    final back = tip - dir * len;
    final inner = tip - dir * (len - notch);
    final path = Path2()
      ..polyline([tip, back + dir.normal * half, inner, back - dir.normal * half])
      ..close();
    items.add(PathItem(path.map(mm), fill: 0, layer: layer + 1, source: source));
    return inner;
  }

  (P, P)? _clipLine(P a, P d, List<double> f, bool backward, double? forwardLimit) {
    var t0 = backward ? -1e9 : 0.0, t1 = forwardLimit ?? 1e9;
    bool clip(double p, double q) {
      if (p.abs() < 1e-14) return q >= 0;
      final r = q / p;
      if (p < 0) {
        if (r > t1) return false;
        if (r > t0) t0 = r;
      } else {
        if (r < t0) return false;
        if (r < t1) t1 = r;
      }
      return true;
    }

    if (clip(-d.x, a.x - f[0]) && clip(d.x, f[2] - a.x) && clip(-d.y, a.y - f[1]) && clip(d.y, f[3] - a.y) && t1 > t0) {
      return (a + d * t0, a + d * t1);
    }
    return null;
  }

  // ---- 원·곡선 ----

  CircleEnt _circle(Map<String, dynamic> o) {
    final through3 = o['through3'] as List?;
    if (through3 != null) {
      final a = pt(through3[0]), b = pt(through3[1]), c = pt(through3[2]);
      final center = circumcenter(a, b, c);
      if (center == null) throw FigureError('세 점이 한 직선 위에 있습니다', o['id'] as String?);
      return CircleEnt(center, center.distanceTo(a));
    }
    final diameter = o['diameter'] as List?;
    if (diameter != null) {
      final a = pt(diameter[0]), b = pt(diameter[1]);
      return CircleEnt((a + b) * 0.5, a.distanceTo(b) / 2);
    }
    final c = pt(o['center'], '중심');
    if (o['radius'] != null) return CircleEnt(c, n(o['radius'], '반지름'));
    final on = o['through'] ?? o['from'];
    if (on == null) throw FigureError('반지름(radius)이나 지나는 점(through)이 필요합니다', o['id'] as String?);
    return CircleEnt(c, c.distanceTo(pt(on)));
  }

  double _sweepEnd(double a0, double a1, String dir) {
    var d = a1 - a0;
    switch (dir) {
      case 'ccw':
        while (d <= 0) {
          d += 2 * math.pi;
        }
        while (d > 2 * math.pi) {
          d -= 2 * math.pi;
        }
      case 'cw':
        while (d >= 0) {
          d -= 2 * math.pi;
        }
        while (d < -2 * math.pi) {
          d += 2 * math.pi;
        }
      default:
        while (d <= -math.pi) {
          d += 2 * math.pi;
        }
        while (d > math.pi) {
          d -= 2 * math.pi;
        }
    }
    return a0 + d;
  }

  void _curve(Map<String, dynamic> o, P Function(double) at, double t0, double t1, {required bool clip}) {
    final id = o['id'] as String?;
    final samples = (o['samples'] as num?)?.toInt() ?? 600;
    final f = clip ? frame : null;
    final range = o['range'] as List?;
    final lo = range != null ? n(range[0]) : f?[1], hi = range != null ? n(range[1]) : f?[3];
    final xlo = f?[0], xhi = f?[2];
    bool inside(P p) {
      if (p.x.isNaN || p.y.isNaN || p.x.isInfinite || p.y.isInfinite) return false;
      if (lo != null && p.y < lo - 1e-9) return false;
      if (hi != null && p.y > hi + 1e-9) return false;
      if (xlo != null && p.x < xlo - 1e-9) return false;
      if (xhi != null && p.x > xhi + 1e-9) return false;
      return true;
    }

    // 안쪽 t 와 바깥쪽 t 사이에서, 보이는 범위의 끝에 닿는 t 를 찾는다.
    double edge(double tin, double tout) {
      for (var i = 0; i < 50; i++) {
        final m = (tin + tout) / 2;
        inside(at(m)) ? tin = m : tout = m;
      }
      return tin;
    }

    final pieces = <List<P>>[], params = <List<double>>[];
    var cur = <P>[], curT = <double>[];
    void flush() {
      if (cur.length > 1) {
        pieces.add(cur);
        params.add(curT);
      }
      cur = <P>[];
      curT = <double>[];
    }

    final jump = 4.0 / unit; // 이웃한 두 점이 이보다 멀면 끊어진 곳으로 본다(mm 기준 4).
    double? prevT;
    var prevIn = false;
    for (var i = 0; i <= samples; i++) {
      final t = t0 + (t1 - t0) * i / samples;
      final p = at(t);
      final isIn = inside(p);
      if (isIn) {
        if (!prevIn && prevT != null) {
          final te = edge(t, prevT);
          cur.add(at(te));
          curT.add(te);
        } else if (prevIn && cur.isNotEmpty && cur.last.distanceTo(p) > math.max(jump, 20 * (t1 - t0).abs() / samples)) {
          flush();
        }
        cur.add(p);
        curT.add(t);
      } else if (prevIn && prevT != null) {
        final te = edge(prevT, t);
        cur.add(at(te));
        curT.add(te);
        flush();
      }
      prevIn = isIn;
      prevT = t;
    }
    flush();
    if (pieces.isEmpty) throw FigureError('곡선이 보이는 범위 안에 없습니다', id);
    final e = CurveEnt(at, pieces, params);
    if (id != null) ents[id] = e;
    final path = Path2();
    for (final piece in pieces) {
      path.polyline(piece);
    }
    if (o['type'] == 'ellipse' && o['angles'] == null) path.close();
    _draw(o, path, 'main');
  }

  // ---- 채움·길 ----

  Path2 _tracePath(List spec, {required bool close}) {
    final path = Path2();
    P? cur;
    for (final item in spec) {
      if (item is Map) {
        if (cur == null) throw FigureError('길은 점에서 시작해야 합니다', _current);
        final target = pt(item['to'], '끝점');
        if (item['arc'] != null) {
          final arc = item['arc'];
          final c = arc is String && ents[arc] is CircleEnt ? (ents[arc] as CircleEnt).c : pt(arc, '호의 중심');
          final a0 = (cur - c).angle;
          final a1 = _sweepEnd(a0, (target - c).angle, item['dir'] as String? ?? 'short');
          // 반지름은 시작점에서 끝점까지 고르게 바꾼다(두 점이 정확히 같은 원 위에 없을 때의 틈을 없앤다).
          final r0 = cur.distanceTo(c), r1 = target.distanceTo(c);
          if ((r0 - r1).abs() < 1e-9) {
            path.arc(c, r0, a0, a1, continuing: true);
          } else {
            const steps = 48;
            for (var i = 1; i <= steps; i++) {
              final t = i / steps;
              path.lineTo(c + P.polar(r0 + (r1 - r0) * t, a0 + (a1 - a0) * t));
            }
          }
        } else if (item['curve'] != null) {
          final curve = ent(item['curve'], '곡선');
          if (curve is! CurveEnt) throw FigureError('curve 는 곡선이어야 합니다', _current);
          final ta = _nearestParam(curve, cur), tb = _nearestParam(curve, target);
          const steps = 200;
          for (var i = 1; i < steps; i++) {
            path.lineTo(curve.at(ta + (tb - ta) * i / steps));
          }
          path.lineTo(target);
        } else {
          throw FigureError('길의 조각을 읽을 수 없습니다', _current);
        }
        cur = target;
      } else {
        final p = pt(item);
        cur == null ? path.moveTo(p) : path.lineTo(p);
        cur = p;
      }
    }
    if (close) path.close();
    return path;
  }

  // ---- 표시 ----

  void _dot(P at, String kind, dynamic size, String? source) {
    final r = (size != null ? n(size) : (kind == 'small' ? style.smallDotRadius : style.dotRadius)) / unit;
    final path = (Path2()..arc(at, r, 0, 2 * math.pi)..close()).map(mm);
    if (kind == 'open') {
      // 빈 점은 테두리의 바깥 지름이 채운 점과 같게 그린다.
      final inner = (Path2()..arc(at, r - style.openDotLine / 2 / unit, 0, 2 * math.pi)..close()).map(mm);
      items.add(PathItem(inner, fill: 1, stroke: Stroke(style.openDotLine), layer: 30, source: source));
    } else {
      items.add(PathItem(path, fill: 0, layer: 30, source: source));
    }
  }

  void _label(P anchor, Map<String, dynamic> o, {String? defaultText, String? source, String part = ''}) {
    final raw = o['tex'] as String?;
    final text = raw ?? o['text'] as String? ?? defaultText;
    if (text == null) throw FigureError('라벨의 글(text)이 없습니다', _current);
    final dir = dirDeg(o['dir']);
    final offset = o['offset'] as List?;
    var pos = mm(anchor);
    double? anchorDeg;
    if (dir != null && o['center'] != true) {
      final rad = dir * math.pi / 180;
      final dist = nOr(o['dist'], style.labelGap);
      pos = pos + P(math.cos(rad), -math.sin(rad)) * dist;
      anchorDeg = (dir + 180) % 360;
    }
    if (offset != null) pos = pos + P(n(offset[0]), -n(offset[1]));
    // 손으로(또는 원본 맞춤으로) 옮긴 만큼. 관계와 따로 적어 두어, 관계를 고쳐도 옮긴 값이 남는다.
    final key = '$_keyPrefix$_key$part';
    final nudge = (doc['label_nudge'] as Map?)?[key] as List?;
    if (nudge != null) pos = pos + P(n(nudge[0]), -n(nudge[1]));
    items.add(TextItem(pos, text,
        key: key,
        anchorDeg: anchorDeg,
        sizePt: nOr(o['size'], style.labelPt),
        background: o['bg'] == true,
        raw: raw != null,
        source: source));
  }

  void _axes(Map<String, dynamic> o) {
    final id = o['id'] as String?;
    final origin = o['origin'] == null ? const P(0, 0) : pt(o['origin']);
    final f = frame;
    List<double> range(String k, int lo, int hi) {
      final r = o[k] as List?;
      if (r != null) return [n(r[0]), n(r[1])];
      if (f == null) throw FigureError('축의 범위($k)가 필요합니다', id);
      return [f[lo], f[hi]];
    }

    final xr = range('x', 0, 2), yr = range('y', 1, 3);
    final stroke = Stroke(style.thinLine);
    final xTip = P(xr[1], origin.y), yTip = P(origin.x, yr[1]);
    final xEnd = _arrowHead(xTip, const P(1, 0), 10, id);
    final yEnd = _arrowHead(yTip, const P(0, 1), 10, id);
    items.add(PathItem((Path2()..polyline([P(xr[0], origin.y), xEnd])).map(mm), stroke: stroke, layer: 10, source: id));
    items.add(PathItem((Path2()..polyline([P(origin.x, yr[0]), yEnd])).map(mm), stroke: stroke, layer: 10, source: id));

    final labels = (o['labels'] as Map?)?.cast<String, dynamic>() ?? const {};
    void put(String key, P at, String text, List<double> offset) {
      final spec = labels[key];
      if (spec == false) return;
      final map = spec is Map ? spec.cast<String, dynamic>() : <String, dynamic>{if (spec is String) 'text': spec};
      _label(at, {'text': text, 'offset': offset, 'center': true, ...map}, source: id, part: ':$key');
    }

    put('x', xTip, 'x', [-0.9, -2.3]);
    put('y', yTip, 'y', [-2.0, -1.2]);
    put('origin', origin, r'\mathrm{O}', [-1.9, -2.1]);
  }

  void _angle(Map<String, dynamic> o) {
    final v = pt(o['at']);
    final a0 = (pt(o['from']) - v).angle;
    final a1 = _sweepEnd(a0, (pt(o['to']) - v).angle, o['dir'] as String? ?? 'ccw');
    final r = nOr(o['radius'], style.angleRadius) / unit;
    _draw(o, Path2()..arc(v, r, a0, a1), 'thin');
    final mid = (a0 + a1) / 2;
    if (o['mark'] == 'dot') {
      _dot(v + P.polar(r * 0.62, mid), 'small', o['mark_size'] ?? 0.22, o['id'] as String?);
    }
    final label = o['label'];
    if (label != null) {
      final map = label is Map ? label.cast<String, dynamic>() : <String, dynamic>{'text': label};
      final dist = nOr(map['dist'], nOr(o['radius'], style.angleRadius) + 1.9) / unit;
      _label(v + P.polar(dist, mid), {...map, 'center': true}..remove('dist'), source: o['id'] as String?);
    }
  }

  /// 길이 표시: 두 점을 잇는 가는 점선 호와 그 가운데의 글자.
  void _dimension(Map<String, dynamic> o) {
    final a = pt(o['from']), b = pt(o['to']);
    final bulge = nOr(o['bulge'], 2.5) / unit;
    final mid = (a + b) * 0.5 + (b - a).unit.normal * bulge;
    final path = Path2();
    final c = bulge.abs() < 1e-9 ? null : circumcenter(a, mid, b);
    if (c == null) {
      path.polyline([a, b]);
    } else {
      final a0 = (a - c).angle;
      final am = _sweepEnd(a0, (mid - c).angle, 'short');
      final a1 = _sweepEnd(am, (b - c).angle, 'short');
      path.arc(c, c.distanceTo(a), a0, a1);
    }
    _draw(o, path, 'dashed');
    final label = o['label'] ?? o['text'];
    if (label != null) {
      final map = label is Map ? label.cast<String, dynamic>() : <String, dynamic>{'text': label};
      _label(mid, {'bg': true, 'center': true, ...map}, source: o['id'] as String?);
    }
  }
}

final _pointName = RegExp(r"^([A-Za-z]+)(\d+)?('?)$");

/// 점 이름을 수능 표기(곧은 글자)로 바꾼다. A → \mathrm{A}, P1 → \mathrm{P}_{1}, F' → \mathrm{F}'.
String _pointTex(String id) {
  final m = _pointName.firstMatch(id);
  if (m == null) return id;
  final sub = m.group(2);
  return '\\mathrm{${m.group(1)}}${sub == null ? '' : '_{$sub}'}${m.group(3)}';
}

double _r(double v) => (v * 1000).round() / 1000;
