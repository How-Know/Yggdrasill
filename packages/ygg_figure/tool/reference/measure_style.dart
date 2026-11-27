// 원본 그림에서 그림체 규격(선 굵기, 회색 채움의 진하기)을 잰다.
//
//   dart run tool/reference/measure_style.dart [--year 2026] [--kinds plane,graph]
//
// 선 굵기: 곧은 가로선·세로선을 찾아, 선을 가로지르는 방향으로 회색 농도(검은 정도)를 더한다.
//          더한 값이 그 선의 굵기(픽셀)다. 가장자리의 흐린 픽셀까지 세므로 픽셀보다 잘게 잰다.
//          (잉크를 흑백으로 가른 뒤 등뼈까지의 거리로 재면 한 픽셀쯤 가늘게 나온다. csat-2026.1 이 그렇게 잰 값이다.)
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
    // 선 굵기 분포(0.01mm 칸, 값은 그 굵기로 이어진 선의 길이).
    final widthHist = <int, int>{};
    straightLineWidths(map).forEach((px, length) {
      final bin = (px * mmPerPx * 100).round();
      widthHist[bin] = (widthHist[bin] ?? 0) + length;
    });
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
    stdout.writeln('  선 굵기(mm:길이px) ${widths.take(6).map((e) => '${(e.key / 100).toStringAsFixed(2)}:${e.value}').join('  ')}');
    stdout.writeln('  회색(밝기:넓이%) ${grays.take(4).map((e) => '${e.key}:${(e.value / total * 100).toStringAsFixed(1)}').join('  ')}');
  }
}

/// 곧은 세로선·가로선의 굵기(픽셀, 0.25 단위)와 그 굵기로 이어진 길이.
///
/// 선의 가운데 줄(이웃보다 진한 줄)이 60픽셀 넘게 이어지는 곳을 선으로 보고, 다른 선과 만나는 양끝을 피해
/// 가운데 60% 구간에서 선을 가로질러 농도를 더한다. 회색 채움 위의 선은 농도가 섞이므로 뺀다.
Map<double, int> straightLineWidths(GrayMap map) {
  final w = map.width, h = map.height;
  double dark(int x, int y) => 1 - map.data[y * w + x] / 255;
  final out = <double, int>{};
  for (final vertical in [true, false]) {
    final across = vertical ? w : h, along = vertical ? h : w;
    double at(int a, int b) => vertical ? dark(a, b) : dark(b, a);
    for (var a = 1; a < across - 1; a++) {
      var b = 0;
      while (b < along) {
        if (at(a, b) <= 0.5 || at(a - 1, b) > at(a, b)) {
          b++;
          continue;
        }
        var e = b;
        while (e < along && at(a, e) > 0.5 && at(a - 1, e) <= at(a, e)) {
          e++;
        }
        if (e - b >= 60) {
          final from = (b + (e - b) * 0.2).round(), to = (b + (e - b) * 0.8).round();
          var sum = 0.0, n = 0, clean = true;
          for (var y = from; y < to && clean; y += 3) {
            var l = a, r = a;
            while (l > 0 && at(l - 1, y) > 0.04) {
              l--;
            }
            while (r < across - 1 && at(r + 1, y) > 0.04) {
              r++;
            }
            if (r - l > 14) {
              clean = false; // 채움이나 다른 선에 붙어 있다.
            } else {
              for (var x = l; x <= r; x++) {
                sum += at(x, y);
              }
              n++;
            }
          }
          if (clean && n > 0) {
            final px = (sum / n * 4).round() / 4;
            out[px] = (out[px] ?? 0) + (e - b);
          }
        }
        b = e + 1;
      }
    }
  }
  return out;
}

String? _arg(List<String> args, String name) {
  final i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}
