import 'dart:io';

import '../figure.dart';
import '../raster/gray_map.dart';
import '../scene.dart';
import 'print.dart';

/// 크기를 맞춰 다시 그린 그림.
class SizedFigure {
  SizedFigure(this.scene, this.scale, this.probes);

  /// 그림판이 잉크(도형과 글자)에 딱 맞게 잘린 그림.
  final Scene scene;

  /// 도형에 곱한 배율(1 = 그림 파일 그대로).
  final double scale;

  /// 크기를 재려고 조판한 횟수.
  final int probes;
}

/// 그림 가장자리에 두는 여백(mm). 선 끝이 잘리지 않게 한다.
const _edge = 0.25;

/// 그림을 너비 [widthMm] 에 맞춰 다시 그린다. 높이가 [maxHeightMm] 를 넘으면 높이에 맞춘다.
///
/// 도형만 커지거나 작아지고 글자·선 굵기는 그대로라, 그림 전체 너비는 배율에 정비례하지 않는다.
/// 그래서 실제로 조판해 잉크가 차지한 자리를 재고, 원하는 크기가 될 때까지 배율을 고친다.
/// [widthMm] 가 null 이면 배율 1 로 두고 그림판만 잉크에 맞춰 자른다.
Future<SizedFigure> fitToBox(
  Map<String, dynamic> doc, {
  required double? widthMm,
  double? maxHeightMm,
  required Directory work,
  String name = 'size-probe',
  double tolerance = 0.15,
}) async {
  var probes = 0;
  Future<_Probe> probe(double s) async {
    probes += 1;
    return _probe(doc, s, work, name);
  }

  var s = 1.0;
  var p = await probe(s);
  if (widthMm != null) {
    // 가장자리 여백까지 합쳐 정한 크기가 되게, 잉크는 그만큼 작게 맞춘다.
    final inkWidth = widthMm - 2 * _edge;
    // 글자가 도형 밖으로 나온 만큼은 배율과 상관없이 그대로라고 보고 배율을 푼다.
    for (var i = 0; i < 3 && (p.width - inkWidth).abs() > tolerance; i++) {
      s = _solve(doc, s, inkWidth - (p.width - p.geoWidth), (b) => b.width);
      p = await probe(s);
    }
    if (maxHeightMm != null) {
      final inkHeight = maxHeightMm - 2 * _edge;
      for (var i = 0; i < 3 && p.height > inkHeight + tolerance; i++) {
        s = _solve(doc, s, inkHeight - (p.height - p.geoHeight), (b) => b.height);
        p = await probe(s);
      }
    }
  }
  final scene = buildFigure(doc, scale: s)
      .window(p.left - _edge, p.top - _edge, p.width + 2 * _edge, p.height + 2 * _edge);
  return SizedFigure(scene, s, probes);
}

class _Box {
  _Box(this.left, this.top, this.right, this.bottom);
  final double left, top, right, bottom;
  double get width => right - left;
  double get height => bottom - top;
}

class _Probe {
  _Probe(this.left, this.top, this.width, this.height, this.geoWidth, this.geoHeight);
  final double left, top, width, height, geoWidth, geoHeight;
}

/// 글자를 뺀 도형만의 자리(선 굵기 포함). 조판 없이 계산한다.
_Box _geoBox(Scene scene) {
  final b = scene.geometryBounds();
  if (b == null) throw FigureError('그릴 도형이 없어 크기를 맞출 수 없습니다');
  return _Box(b.left, b.top, b.right, b.bottom);
}

/// 도형의 [measure](너비나 높이)가 [target] 이 되는 배율을 찾는다. 조판 없이 계산만 한다.
double _solve(Map<String, dynamic> doc, double from, double target, double Function(_Box) measure) {
  if (!(target > 1)) throw FigureError('그림 속 글자만으로도 정한 크기를 넘습니다. 이 그림은 크기를 따로 정해야 합니다');
  var s = from;
  for (var i = 0; i < 12; i++) {
    final now = measure(_geoBox(buildFigure(doc, scale: s)));
    if ((now - target).abs() < 0.01) break;
    s = (s * target / now).clamp(0.05, 20.0);
  }
  return s;
}

Future<_Probe> _probe(Map<String, dynamic> doc, double s, Directory work, String name) async {
  const pad = 12.0, ppi = 200.0;
  final scene = buildFigure(doc, scale: s);
  final wide = scene.window(-pad, -pad, scene.width + 2 * pad, scene.height + 2 * pad);
  final map = await renderGray(wide, work, name, ppi);
  final ink = _inkBox(map);
  if (ink == null) throw FigureError('그림에 아무것도 그려지지 않았습니다');
  final mm = 25.4 / ppi;
  final geo = _geoBox(scene);
  return _Probe(
    ink.left * mm - pad,
    ink.top * mm - pad,
    ink.width * mm,
    ink.height * mm,
    geo.width,
    geo.height,
  );
}

/// 흰 종이가 아닌 점들이 차지한 자리(픽셀). 옅은 채움도 잉크로 센다.
_Box? _inkBox(GrayMap map) {
  var x0 = map.width, y0 = map.height, x1 = -1, y1 = -1;
  for (var y = 0; y < map.height; y++) {
    final row = y * map.width;
    for (var x = 0; x < map.width; x++) {
      if (map.data[row + x] >= 250) continue;
      if (x < x0) x0 = x;
      if (x > x1) x1 = x;
      if (y < y0) y0 = y;
      if (y > y1) y1 = y;
    }
  }
  if (x1 < 0) return null;
  return _Box(x0.toDouble(), y0.toDouble(), x1 + 1.0, y1 + 1.0);
}
