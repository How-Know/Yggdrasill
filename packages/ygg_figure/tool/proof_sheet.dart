// 다시 그린 그림들을 원본과 나란히 놓은 증명 판을 만든다.
//
//   dart run tool/proof_sheet.dart [--dir figures/csat] [--per-sheet 4]
//
// 한 줄에 그림 하나: 원본 | 다시 그린 것 | 겹친 것(검정=일치, 빨강=원본에만, 파랑=다시 그린 것에만).
// 출력: build/proof/sheet-NN.png, build/proof/summary.json
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:ygg_figure/src/compare.dart';
import 'package:ygg_figure/src/io/print.dart';
import 'package:ygg_figure/src/raster/gray_map.dart';
import 'package:ygg_figure/ygg_figure.dart';

Future<void> main(List<String> args) async {
  final root = Directory.current.path;
  final dir = Directory(p.join(root, _arg(args, '--dir') ?? p.join('figures', 'csat')));
  final perSheet = int.parse(_arg(args, '--per-sheet') ?? '4');
  final manifest = jsonDecode(File(p.join(root, 'reference', 'manifest.json')).readAsStringSync()) as Map;
  final kinds = (jsonDecode(File(p.join(root, 'reference', 'kinds.json')).readAsStringSync()) as Map)['kinds'] as Map;
  final refs = {for (final f in (manifest['figures'] as List).cast<Map>()) f['id'] as String: f};
  final work = Directory(p.join(root, 'build', 'figures'));
  final out = Directory(p.join(root, 'build', 'proof'))..createSync(recursive: true);

  final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final rows = <({String id, img.Image original, img.Image ours, img.Image overlay})>[];
  final summary = <Map<String, dynamic>>[];
  for (final file in files) {
    final doc = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final id = doc['ref'] as String;
    final ref = refs[id]!;
    final ppi = (ref['ppi'] as num).toDouble();
    final original = GrayMap.readPng(p.join(root, 'reference', 'images', '$id.png'));
    final name = p.basenameWithoutExtension(file.path);
    final scene = buildFigure(doc);
    final view = referenceView(doc, scene, widthMm: (ref['width_mm'] as num).toDouble(), heightMm: (ref['height_mm'] as num).toDouble());
    final ours = await renderGray(view, work, name, ppi);
    // 그림판을 원본보다 넓힌 그림은, 보여 주는 칸에는 잘리지 않은 전체를 쓴다.
    final shown = identical(view, scene) ? ours : await renderGray(scene, work, '$name-full', ppi);
    final r = compareMaps(original, ours, ppi: ppi);
    summary.add({
      'id': id,
      'kind': (kinds[id] as Map?)?['kind'],
      'covered': _r3(r.covered),
      'precise': _r3(r.precise),
      'covered_loose': _r3(r.coveredLoose),
      'precise_loose': _r3(r.preciseLoose),
      'mean_miss_mm': _r3(r.meanMissMm),
      'fill_match': r.fillMatch == null ? null : _r3(r.fillMatch!),
      'ink_ratio': _r3(r.inkRatio),
    });
    rows.add((id: id, original: original.toImage(), ours: shown.toImage(), overlay: r.overlay));
    stdout.writeln('$id  ${(r.covered * 100).toStringAsFixed(1)} / ${(r.precise * 100).toStringAsFixed(1)}');
  }
  File(p.join(out.path, 'summary.json')).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(summary)}\n');

  const cellW = 440, cellH = 400, labelH = 26;
  for (var start = 0, n = 1; start < rows.length; start += perSheet, n++) {
    final chunk = rows.sublist(start, math.min(start + perSheet, rows.length));
    final sheet = img.Image(width: cellW * 3, height: chunk.length * cellH, numChannels: 3);
    img.fill(sheet, color: img.ColorRgb8(255, 255, 255));
    for (var k = 0; k < chunk.length; k++) {
      final row = chunk[k];
      final cells = [row.original, row.ours, row.overlay];
      for (var c = 0; c < 3; c++) {
        final src = cells[c].convert(numChannels: 3);
        final scale = math.min((cellW - 16) / src.width, (cellH - labelH - 16) / src.height);
        final thumb = img.copyResize(src,
            width: (src.width * scale).round(), height: (src.height * scale).round(), interpolation: img.Interpolation.average);
        img.compositeImage(sheet, thumb,
            dstX: c * cellW + (cellW - thumb.width) ~/ 2, dstY: k * cellH + labelH + (cellH - labelH - thumb.height) ~/ 2);
        img.drawRect(sheet,
            x1: c * cellW, y1: k * cellH, x2: (c + 1) * cellW - 1, y2: (k + 1) * cellH - 1, color: img.ColorRgb8(210, 210, 210));
      }
      final s = summary[start + k];
      img.drawString(sheet, '${row.id.replaceFirst('csat-', '')}  original',
          font: img.arial14, x: 8, y: k * cellH + 6, color: img.ColorRgb8(200, 0, 0));
      img.drawString(sheet, 'engine', font: img.arial14, x: cellW + 8, y: k * cellH + 6, color: img.ColorRgb8(200, 0, 0));
      img.drawString(sheet, 'overlay  ${(s['covered'] * 100).toStringAsFixed(1)}% / ${(s['precise'] * 100).toStringAsFixed(1)}%',
          font: img.arial14, x: 2 * cellW + 8, y: k * cellH + 6, color: img.ColorRgb8(200, 0, 0));
    }
    File(p.join(out.path, 'sheet-${n.toString().padLeft(2, '0')}.png')).writeAsBytesSync(img.encodePng(sheet));
  }
  stdout.writeln('${rows.length}장 → ${out.path}');
}

double _r3(double v) => (v * 1000).round() / 1000;

String? _arg(List<String> args, String name) {
  final i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}
