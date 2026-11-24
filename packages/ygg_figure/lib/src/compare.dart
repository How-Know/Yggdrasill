import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'raster/gray_map.dart';
import 'scene.dart';

/// 원본과 다시 그린 그림을 겹쳐 본 결과.
class CompareResult {
  CompareResult({
    required this.covered,
    required this.precise,
    required this.coveredLoose,
    required this.preciseLoose,
    required this.meanMissMm,
    required this.fillMatch,
    required this.inkRatio,
    required this.overlay,
  });

  /// 원본의 잉크 가운데 다시 그린 그림의 잉크와 허용 거리 안에서 겹치는 몫(0~1).
  final double covered;

  /// 다시 그린 그림의 잉크 가운데 원본의 잉크와 허용 거리 안에서 겹치는 몫(0~1).
  final double precise;

  /// 허용 거리를 두 배(선 굵기 하나쯤)로 넓혔을 때의 같은 값.
  final double coveredLoose, preciseLoose;

  /// 원본 잉크에서 다시 그린 잉크까지의 평균 거리(mm).
  final double meanMissMm;

  /// 회색으로 칠한 넓이가 겹치는 정도(겹친 넓이 / 합친 넓이). 칠한 곳이 없으면 null.
  final double? fillMatch;

  /// 다시 그린 그림의 잉크 넓이 / 원본의 잉크 넓이. 위치가 맞아도 선 굵기가 다르면 1에서 벗어난다.
  final double inkRatio;

  /// 겹친 그림. 검정=둘 다, 빨강=원본에만 있음, 파랑=다시 그린 것에만 있음.
  final img.Image overlay;
}

/// 원본과 겹쳐 볼 때 쓰는 그림. 그림 파일에 "ref_offset": [가로, 세로](mm) 가 있으면, 우리 그림판 안에서
/// 원본의 왼쪽 위가 놓이는 자리로 보고 그만큼 잘라 낸다(글자를 키워 그림판을 넓힌 옛 그림에 쓴다).
Scene referenceView(Map<String, dynamic> doc, Scene scene, {required double widthMm, required double heightMm}) {
  final off = doc['ref_offset'];
  if (off is! List || off.length != 2) return scene;
  return scene.window((off[0] as num).toDouble(), (off[1] as num).toDouble(), widthMm, heightMm);
}

CompareResult compareMaps(GrayMap original, GrayMap ours, {required double ppi, double toleranceMm = 0.15}) {
  final w = math.min(original.width, ours.width), h = math.min(original.height, ours.height);
  final a = _crop(original, w, h), b = _crop(ours, w, h);
  final pxPerMm = ppi / 25.4;
  final tol = toleranceMm * pxPerMm;
  final toB = distanceToInk(b), toA = distanceToInk(a);
  var inkA = 0, okA = 0, inkB = 0, okB = 0, looseA = 0, looseB = 0;
  var missSum = 0.0;
  var grayA = 0, grayB = 0, grayBoth = 0;
  final overlay = img.Image(width: w, height: h, numChannels: 3);
  for (var i = 0; i < w * h; i++) {
    final va = a.data[i], vb = b.data[i];
    if (va < 128) {
      inkA++;
      if (toB[i] <= tol) okA++;
      if (toB[i] <= 2 * tol) looseA++;
      missSum += toB[i];
    }
    if (vb < 128) {
      inkB++;
      if (toA[i] <= tol) okB++;
      if (toA[i] <= 2 * tol) looseB++;
    }
    final ga = va >= 150 && va <= 240, gb = vb >= 150 && vb <= 240;
    if (ga) grayA++;
    if (gb) grayB++;
    if (ga && gb) grayBoth++;
    // 빨강 = 원본에만, 파랑 = 다시 그린 것에만.
    final x = i % w, y = i ~/ w;
    final both = math.max(va, vb), dark = math.min(va, vb);
    if (va <= vb) {
      overlay.setPixelRgb(x, y, both, dark + (both - dark) ~/ 4, dark + (both - dark) ~/ 4);
    } else {
      overlay.setPixelRgb(x, y, dark + (both - dark) ~/ 4, dark + (both - dark) ~/ 2, both);
    }
  }
  final grayUnion = grayA + grayB - grayBoth;
  // 선 가장자리의 흐린 점들이 회색으로 잡히므로, 칠한 넓이가 충분할 때만 본다.
  final hasFill = grayA > w * h * 0.01 || grayB > w * h * 0.01;
  return CompareResult(
    covered: inkA == 0 ? 1 : okA / inkA,
    precise: inkB == 0 ? 1 : okB / inkB,
    coveredLoose: inkA == 0 ? 1 : looseA / inkA,
    preciseLoose: inkB == 0 ? 1 : looseB / inkB,
    meanMissMm: inkA == 0 ? 0 : missSum / inkA / pxPerMm,
    fillMatch: hasFill && grayUnion > 0 ? grayBoth / grayUnion : null,
    inkRatio: inkA == 0 ? 1 : inkB / inkA,
    overlay: overlay,
  );
}

GrayMap _crop(GrayMap m, int w, int h) {
  if (m.width == w && m.height == h) return m;
  final out = GrayMap(w, h);
  for (var y = 0; y < h; y++) {
    out.data.setRange(y * w, y * w + w, m.data, y * m.width);
  }
  return out;
}

/// 원본에 가장 잘 겹치도록 그림 파일의 변수 값을 찾을 때 쓰는 잣대.
///
/// 원본을 낮은 해상도로 줄여 두고, 다시 그린 그림의 선 위의 점들이 원본 잉크에서 얼마나
/// 떨어졌는지(앞), 원본 잉크가 다시 그린 선에서 얼마나 떨어졌는지(뒤)를 더한다.
class FitTarget {
  FitTarget(GrayMap original, double ppi, {double workPpi = 220}) {
    final factor = math.max(1, (ppi / workPpi).round());
    _pxPerMm = ppi / factor / 25.4;
    _w = original.width ~/ factor;
    _h = original.height ~/ factor;
    final small = GrayMap(_w, _h);
    for (var y = 0; y < _h; y++) {
      for (var x = 0; x < _w; x++) {
        var darkest = 255;
        for (var dy = 0; dy < factor; dy++) {
          for (var dx = 0; dx < factor; dx++) {
            darkest = math.min(darkest, original.at(x * factor + dx, y * factor + dy));
          }
        }
        small.data[y * _w + x] = darkest;
      }
    }
    _toInk = distanceToInk(small);
    _ink = [
      for (var i = 0; i < _w * _h; i++)
        if (small.data[i] < 128) i,
    ];
  }

  late final double _pxPerMm;
  late final int _w, _h;
  late final Float32List _toInk;
  late final List<int> _ink;

  /// 작을수록 잘 겹친다(mm² 단위의 평균 어긋남).
  double cost(Scene scene, {double capMm = 1.5}) {
    final cap = capMm * _pxPerMm;
    final mark = GrayMap(_w, _h)..data.fillRange(0, _w * _h, 255);
    var sum = 0.0, count = 0;
    for (final item in scene.items) {
      if (item is! PathItem || (item.stroke == null && item.fill != 0)) continue;
      for (final line in item.path.flatten(0.5 / _pxPerMm)) {
        for (final p in line) {
          final x = p.x * _pxPerMm, y = p.y * _pxPerMm;
          final d = math.min(_sample(x, y), cap);
          sum += d * d;
          count++;
          final xi = x.floor(), yi = y.floor();
          if (xi >= 0 && yi >= 0 && xi < _w && yi < _h) mark.data[yi * _w + xi] = 0;
        }
      }
    }
    if (count == 0) return double.infinity;
    final forward = sum / count;
    final toOurs = distanceToInk(mark);
    var back = 0.0;
    for (final i in _ink) {
      final d = math.min(toOurs[i], cap);
      back += d * d;
    }
    back = _ink.isEmpty ? 0 : back / _ink.length;
    return (forward + 0.5 * back) / (_pxPerMm * _pxPerMm);
  }

  double _sample(double x, double y) {
    // 그림판 밖으로 나간 점은 나간 거리만큼 더 벌점을 준다.
    final cx = x.clamp(0, _w - 1.001), cy = y.clamp(0, _h - 1.001);
    final out = (x - cx).abs() + (y - cy).abs();
    final x0 = cx.floor(), y0 = cy.floor();
    final fx = cx - x0, fy = cy - y0;
    final i = y0 * _w + x0;
    final top = _toInk[i] * (1 - fx) + _toInk[i + 1] * fx;
    final bottom = _toInk[i + _w] * (1 - fx) + _toInk[i + _w + 1] * fx;
    return top * (1 - fy) + bottom * fy + out;
  }
}

/// 글자(라벨)를 원본의 글자 자리에 맞춘다.
///
/// 원본에서 다시 그린 선이 지나는 곳을 지우면 글자만 남는다. 글자만 찍은 그림([labelsOnly])의
/// 글자 하나하나를 조금씩 옮겨 가며 남은 원본 잉크와 가장 잘 겹치는 자리를 찾는다.
/// 돌려주는 값은 열쇠 → (옮길 양 mm: 오른쪽 +, 위쪽 +, 맞춘 뒤의 어긋남 mm).
Map<String, ({double dx, double dy, double miss})> snapLabels({
  required GrayMap original,
  required GrayMap labelsOnly,
  required Scene scene,
  required double ppi,
  double searchMm = 2.5,
}) {
  final factor = math.max(1, (ppi / 300).round());
  final pxPerMm = ppi / factor / 25.4;
  final w = math.min(original.width, labelsOnly.width) ~/ factor, h = math.min(original.height, labelsOnly.height) ~/ factor;
  GrayMap shrink(GrayMap m) {
    final out = GrayMap(w, h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var darkest = 255;
        for (var dy = 0; dy < factor; dy++) {
          for (var dx = 0; dx < factor; dx++) {
            darkest = math.min(darkest, m.at(x * factor + dx, y * factor + dy));
          }
        }
        out.data[y * w + x] = darkest;
      }
    }
    return out;
  }

  final orig = shrink(original), labels = shrink(labelsOnly);
  // 다시 그린 선·점이 지나는 곳의 원본 잉크를 지운다.
  for (final item in scene.items) {
    if (item is! PathItem || (item.stroke == null && item.fill != 0)) continue;
    final r = (((item.stroke?.width ?? 0) / 2 + 0.14) * pxPerMm).ceil();
    for (final line in item.path.flatten(0.5 / pxPerMm)) {
      for (final p in line) {
        final cx = (p.x * pxPerMm).round(), cy = (p.y * pxPerMm).round();
        for (var y = math.max(0, cy - r); y <= math.min(h - 1, cy + r); y++) {
          for (var x = math.max(0, cx - r); x <= math.min(w - 1, cx + r); x++) {
            if ((x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r) orig.data[y * w + x] = 255;
          }
        }
      }
    }
  }
  final toInk = distanceToInk(orig);

  final texts = scene.items.whereType<TextItem>().toList();
  final pixels = [for (final _ in texts) <int>[]];
  final reach = 12 * pxPerMm;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (labels.data[y * w + x] >= 128) continue;
      var best = -1;
      var bestD = reach;
      for (var k = 0; k < texts.length; k++) {
        final d = math.sqrt(math.pow(texts[k].pos.x * pxPerMm - x, 2) + math.pow(texts[k].pos.y * pxPerMm - y, 2));
        if (d < bestD) {
          bestD = d;
          best = k;
        }
      }
      if (best >= 0) pixels[best].add(y * w + x);
    }
  }

  final cap = 0.5 * pxPerMm;
  final radius = (searchMm * pxPerMm).round();
  final out = <String, ({double dx, double dy, double miss})>{};
  for (var k = 0; k < texts.length; k++) {
    final px = pixels[k];
    if (px.isEmpty) continue;
    final stride = math.max(1, px.length ~/ 2500);
    double costAt(int sx, int sy) {
      var sum = 0.0, count = 0;
      for (var i = 0; i < px.length; i += stride) {
        final x = px[i] % w + sx, y = px[i] ~/ w + sy;
        final d = (x < 0 || y < 0 || x >= w || y >= h) ? cap : math.min(toInk[y * w + x], cap);
        sum += d * d;
        count++;
      }
      return sum / count;
    }

    var best = costAt(0, 0);
    final start = best;
    var bx = 0, by = 0;
    for (var sy = -radius; sy <= radius; sy++) {
      for (var sx = -radius; sx <= radius; sx++) {
        // 같은 값이면 덜 옮기는 쪽을 고른다.
        final c = costAt(sx, sy) + 0.01 * cap * cap * math.sqrt(sx * sx + sy * sy) / radius;
        if (c < best) {
          best = c;
          bx = sx;
          by = sy;
        }
      }
    }
    final miss = math.sqrt(costAt(bx, by)) / pxPerMm;
    // 옮겨도 겹치지 않으면(원본에 그 글자가 없거나 선에 가려짐) 그대로 둔다.
    if (miss > 0.22 || best > start * 0.98) {
      out[texts[k].key] = (dx: 0, dy: 0, miss: math.sqrt(start) / pxPerMm);
    } else {
      out[texts[k].key] = (dx: bx / pxPerMm, dy: -by / pxPerMm, miss: miss);
    }
  }
  return out;
}

/// 넬더-미드 방법으로 [cost] 가 가장 작아지는 값을 찾는다.
List<double> minimize(double Function(List<double>) cost, List<double> start, List<double> steps, {int maxEvals = 400}) {
  final n = start.length;
  final simplex = <List<double>>[List.of(start)];
  for (var i = 0; i < n; i++) {
    simplex.add(List.of(start)..[i] += steps[i]);
  }
  final values = [for (final s in simplex) cost(s)];
  var evals = n + 1;
  List<double> blend(List<double> a, List<double> b, double t) => [for (var i = 0; i < n; i++) a[i] + (b[i] - a[i]) * t];
  while (evals < maxEvals) {
    final order = List.generate(n + 1, (i) => i)..sort((a, b) => values[a].compareTo(values[b]));
    final best = order.first, worst = order.last, second = order[n - 1];
    if ((values[worst] - values[best]).abs() < 1e-10) break;
    final centroid = List.filled(n, 0.0);
    for (final i in order.take(n)) {
      for (var k = 0; k < n; k++) {
        centroid[k] += simplex[i][k] / n;
      }
    }
    final reflected = blend(centroid, simplex[worst], -1);
    final fr = cost(reflected);
    evals++;
    if (fr < values[best]) {
      final expanded = blend(centroid, simplex[worst], -2);
      final fe = cost(expanded);
      evals++;
      if (fe < fr) {
        simplex[worst] = expanded;
        values[worst] = fe;
      } else {
        simplex[worst] = reflected;
        values[worst] = fr;
      }
    } else if (fr < values[second]) {
      simplex[worst] = reflected;
      values[worst] = fr;
    } else {
      final contracted = blend(centroid, simplex[worst], fr < values[worst] ? -0.5 : 0.5);
      final fc = cost(contracted);
      evals++;
      if (fc < math.min(fr, values[worst])) {
        simplex[worst] = contracted;
        values[worst] = fc;
      } else {
        for (final i in order.skip(1)) {
          simplex[i] = blend(simplex[best], simplex[i], 0.5);
          values[i] = cost(simplex[i]);
          evals++;
        }
      }
    }
  }
  var best = 0;
  for (var i = 1; i <= n; i++) {
    if (values[i] < values[best]) best = i;
  }
  return simplex[best];
}
