// 원본 그림을 한눈에 훑어볼 수 있게 여러 장을 한 판에 모은다(종류 분류·검수용).
//
//   dart run tool/reference/contact_sheets.dart [--per-sheet 12]
//
// 출력: reference/work/sheets/sheet-NN.png
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

void main(List<String> args) {
  final root = Directory.current.path;
  final manifest = jsonDecode(File(p.join(root, 'reference', 'manifest.json')).readAsStringSync()) as Map;
  final figures = (manifest['figures'] as List).cast<Map>().where((f) => f['source'] != 'empty').toList();
  final i = args.indexOf('--per-sheet');
  final perSheet = i >= 0 ? int.parse(args[i + 1]) : 12;
  const cols = 4;
  const cellW = 360, cellH = 330, labelH = 30, pad = 8;
  final outDir = Directory(p.join(root, 'reference', 'work', 'sheets'));
  if (outDir.existsSync()) outDir.deleteSync(recursive: true);
  outDir.createSync(recursive: true);

  for (var start = 0, n = 1; start < figures.length; start += perSheet, n++) {
    final chunk = figures.sublist(start, math.min(start + perSheet, figures.length));
    final rows = (chunk.length / cols).ceil();
    final sheet = img.Image(width: cols * cellW, height: rows * cellH, numChannels: 3);
    img.fill(sheet, color: img.ColorRgb8(255, 255, 255));
    for (var k = 0; k < chunk.length; k++) {
      final f = chunk[k];
      final cx = (k % cols) * cellW, cy = (k ~/ cols) * cellH;
      final file = File(p.join(root, 'reference', 'images', '${f['id']}.png'));
      if (file.existsSync()) {
        final src = img.decodePng(file.readAsBytesSync())!;
        final scale = math.min((cellW - 2 * pad) / src.width, (cellH - labelH - 2 * pad) / src.height);
        final thumb = img.copyResize(
          src,
          width: math.max(1, (src.width * scale).round()),
          height: math.max(1, (src.height * scale).round()),
          interpolation: img.Interpolation.average,
        );
        img.compositeImage(
          sheet,
          thumb,
          dstX: cx + (cellW - thumb.width) ~/ 2,
          dstY: cy + labelH + pad + (cellH - labelH - 2 * pad - thumb.height) ~/ 2,
        );
      }
      final label = '${f['id']}'.replaceFirst('csat-', '');
      img.drawString(sheet, label, font: img.arial24, x: cx + pad, y: cy + 4, color: img.ColorRgb8(200, 0, 0));
      img.drawRect(sheet, x1: cx, y1: cy, x2: cx + cellW - 1, y2: cy + cellH - 1, color: img.ColorRgb8(200, 200, 200));
    }
    File(p.join(outDir.path, 'sheet-${n.toString().padLeft(2, '0')}.png')).writeAsBytesSync(img.encodePng(sheet));
  }
  stdout.writeln('${figures.length}장 → ${(figures.length / perSheet).ceil()}판');
}
