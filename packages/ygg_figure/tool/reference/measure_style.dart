// 원본 그림에서 그림체 규격(선 굵기, 회색 채움의 진하기)을 잰다.
//
//   dart run tool/reference/measure_style.dart [--year 2026] [--kinds plane,graph]
//
// 선 굵기: 잉크 안에서 종이까지의 거리가 주변보다 큰 점(선의 등뼈)을 모아 굵기 분포를 낸다.
// 회색: 넓게 칠해진 중간 밝기의 분포를 낸다.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:ygg_figure/src/raster/gray_map.dart';

void main(List<String> args) {
  final root = Directory.current.path;
  final manifest = jsonDecode(File(p.join(root, 'reference', 'manifest.json')).readAsStringSync()) as Map;
  final kinds = (jsonDecode(File(p.join(root, 'reference', 'kinds.json')).readAsStringSync()) as Map)['kinds'] as Map;
  final yearArg = _arg(args, '--year');
  final kindArg = (_arg(args, '--kinds') ?? 'plane,graph,solid,solid_graph').split(',').toSet();
  final idArg = _arg(args, '--id');

  for (final f in (manifest['figures'] as List).cast<Map>()) {
    final id = f['id'] as String;
    if (f['source'] != 'pdf_image') continue;
    if (idArg != null ? id != idArg : (yearArg != null && '${f['exam_year']}' != yearArg)) continue;
    if (idArg == null && !kindArg.contains((kinds[id] as Map?)?['kind'])) continue;
    final map = GrayMap.readPng(p.join(root, 'reference', 'images', '$id.png'));
    final mmPerPx = 25.4 / (f['ppi'] as num).toDouble();
    final inside = distanceToInk(map, invert: true);
    final w = map.width, h = map.height;

    // 선 굵기 분포(0.01mm 칸). 등뼈 점에서 굵기 = 2*거리 - 1 픽셀.
    final widthHist = <int, int>{};
    for (var y = 1; y < h - 1; y++) {
      for (var x = 1; x < w - 1; x++) {
        final d = inside[y * w + x];
        if (d < 1) continue;
        var ridge = true;
        for (var dy = -1; dy <= 1 && ridge; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            if (inside[(y + dy) * w + x + dx] > d + 1e-6) {
              ridge = false;
              break;
            }
          }
        }
        if (!ridge) continue;
        final mm = (2 * d - 1) * mmPerPx;
        if (mm > 0.8) continue; // 채워진 점·글자 덩어리는 뺀다.
        final bin = (mm * 100 / 2).round() * 2;
        widthHist[bin] = (widthHist[bin] ?? 0) + 1;
      }
    }
    // 회색 분포(8 단계 칸).
    final grayHist = <int, int>{};
    for (final v in map.data) {
      if (v >= 96 && v <= 244) {
        final bin = v ~/ 4 * 4;
        grayHist[bin] = (grayHist[bin] ?? 0) + 1;
      }
    }
    final total = map.data.length;
    final widths = widthHist.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final grays = grayHist.entries.where((e) => e.value / total > 0.004).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    stdout.writeln('$id  ${f['width_mm']}x${f['height_mm']}mm ${f['ppi']}ppi');
    stdout.writeln('  선 굵기(mm:점수) ${widths.take(6).map((e) => '${(e.key / 100).toStringAsFixed(2)}:${e.value}').join('  ')}');
    stdout.writeln('  회색(밝기:넓이%) ${grays.take(4).map((e) => '${e.key}:${(e.value / total * 100).toStringAsFixed(1)}').join('  ')}');
  }
}

String? _arg(List<String> args, String name) {
  final i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}
