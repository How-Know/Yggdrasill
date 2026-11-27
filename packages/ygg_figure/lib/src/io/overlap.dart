import 'dart:io';
import 'dart:math' as math;

import '../raster/gray_map.dart';
import '../scene.dart';
import 'print.dart';

/// 글자가 선이나 점 위에 겹쳐 찍힌 곳.
class LabelOverlap {
  LabelOverlap(this.key, this.areaMm2);

  /// 겹친 글자의 열쇠(그림 파일의 label_nudge 에 쓰는 이름).
  final String key;

  /// 겹친 넓이(mm²).
  final double areaMm2;
}

/// 그림 속 글자가 선·점과 겹치는 곳을 찾는다. 겹친 넓이가 큰 것부터 낸다.
///
/// 도형을 줄이면 글자는 그대로라 선 쪽으로 밀려 들어갈 수 있다. 그래서 가장 작게 실리는 크기로
/// 맞춘 그림을 실제로 조판해 보고 확인한다. 옅은 채움 위의 글자는 겹침으로 보지 않는다.
Future<List<LabelOverlap>> findLabelOverlaps(Scene scene, Directory work, {String name = 'overlap', double ppi = 300}) async {
  final texts = scene.items.whereType<TextItem>().toList();
  if (texts.isEmpty) return const [];
  Scene only(List<SceneItem> items) =>
      Scene(width: scene.width, height: scene.height, items: items, style: scene.style, engine: scene.engine);
  // 흰 바탕을 깔고 찍는 글자는 그 밑의 선을 가린다. 선만 찍을 때도 같은 자리를 희게 비워 둔다.
  final shapes = await renderGray(
    only([
      ...scene.items.whereType<PathItem>(),
      for (final t in texts)
        if (t.background)
          TextItem(t.pos, '\\phantom{${t.raw ? t.tex : '\$${t.tex}\$'}}',
              anchorDeg: t.anchorDeg, sizePt: t.sizePt, background: true, raw: true),
    ]),
    work,
    '$name-shapes',
    ppi,
  );
  final letters = await renderGray(
    only([for (final t in texts) TextItem(t.pos, t.tex, anchorDeg: t.anchorDeg, sizePt: t.sizePt, raw: t.raw)]),
    work,
    '$name-letters',
    ppi,
  );
  return labelOverlaps(shapes, letters, texts, ppi);
}

/// 선만 찍은 그림([shapes])과 글자만 찍은 그림([letters])에서 함께 잉크인 곳을 글자별로 모은다.
///
/// 한 글자열의 낱자들은 서로 가깝다. 가까운 잉크끼리 한 덩어리로 묶고, 덩어리마다 가장 가까운
/// 글자([texts] 의 자리)의 것으로 본다.
List<LabelOverlap> labelOverlaps(GrayMap shapes, GrayMap letters, List<TextItem> texts, double ppi,
    {double minAreaMm2 = 0.03}) {
  final w = math.min(shapes.width, letters.width), h = math.min(shapes.height, letters.height);
  final pxPerMm = ppi / 25.4;
  // 낱자 사이 틈보다 넓은 칸(약 0.7mm)으로 나눠, 이웃한 칸끼리 한 덩어리로 묶는다.
  final cell = math.max(1, (0.7 * pxPerMm).round());
  final cw = (w / cell).ceil(), ch = (h / cell).ceil();
  final inked = List<bool>.filled(cw * ch, false);
  final hits = List<int>.filled(cw * ch, 0);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (letters.at(x, y) >= 128) continue;
      final c = (y ~/ cell) * cw + x ~/ cell;
      inked[c] = true;
      if (shapes.at(x, y) < 128) hits[c] += 1;
    }
  }
  final seen = List<bool>.filled(cw * ch, false);
  final area = <String, double>{};
  for (var start = 0; start < inked.length; start++) {
    if (!inked[start] || seen[start]) continue;
    var count = 0;
    var x0 = cw, y0 = ch, x1 = -1, y1 = -1;
    final stack = [start];
    seen[start] = true;
    while (stack.isNotEmpty) {
      final c = stack.removeLast();
      final cx = c % cw, cy = c ~/ cw;
      count += hits[c];
      x0 = math.min(x0, cx);
      y0 = math.min(y0, cy);
      x1 = math.max(x1, cx);
      y1 = math.max(y1, cy);
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          final nx = cx + dx, ny = cy + dy;
          if (nx < 0 || ny < 0 || nx >= cw || ny >= ch) continue;
          final n = ny * cw + nx;
          if (!inked[n] || seen[n]) continue;
          seen[n] = true;
          stack.add(n);
        }
      }
    }
    final mm2 = count / (pxPerMm * pxPerMm);
    if (mm2 < minAreaMm2) continue;
    // 덩어리가 차지한 자리(mm)에서 가장 가까운 글자.
    final left = x0 * cell / pxPerMm, top = y0 * cell / pxPerMm;
    final right = (x1 + 1) * cell / pxPerMm, bottom = (y1 + 1) * cell / pxPerMm;
    TextItem? owner;
    var best = double.infinity;
    for (final t in texts) {
      final dx = math.max(0.0, math.max(left - t.pos.x, t.pos.x - right));
      final dy = math.max(0.0, math.max(top - t.pos.y, t.pos.y - bottom));
      final d = math.sqrt(dx * dx + dy * dy);
      if (d < best) {
        best = d;
        owner = t;
      }
    }
    if (owner == null) continue;
    area[owner.key] = (area[owner.key] ?? 0) + mm2;
  }
  final out = [for (final e in area.entries) LabelOverlap(e.key, e.value)];
  out.sort((a, b) => b.areaMm2.compareTo(a.areaMm2));
  return out;
}
