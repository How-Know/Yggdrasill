// 원본 그림의 한 부분을 크게 잘라 본다(점선 간격·화살촉·글자 크기 확인용).
//
//   dart run tool/reference/zoom.dart --id csat-2026-common-4-1 --rect 10,5,20,15 [--scale 3] [--grid 1]
//
// --rect 는 그림 왼쪽 위에서 잰 mm(x,y,너비,높이). --grid 는 눈금 간격(mm). 출력: reference/work/zoom/<id>.png
import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

void main(List<String> args) {
  final root = Directory.current.path;
  final id = _arg(args, '--id')!;
  final file = _arg(args, '--file') ?? p.join(root, 'reference', 'images', '$id.png');
  final manifest = jsonDecode(File(p.join(root, 'reference', 'manifest.json')).readAsStringSync()) as Map;
  final entry = (manifest['figures'] as List).cast<Map>().firstWhere((f) => f['id'] == id);
  final pxPerMm = (entry['ppi'] as num).toDouble() / 25.4;
  final src = img.decodePng(File(file).readAsBytesSync())!;
  final rect = (_arg(args, '--rect') ?? '0,0,${src.width / pxPerMm},${src.height / pxPerMm}')
      .split(',')
      .map(double.parse)
      .toList();
  final scale = double.parse(_arg(args, '--scale') ?? '1');
  final grid = double.tryParse(_arg(args, '--grid') ?? '');
  final x = (rect[0] * pxPerMm).round().clamp(0, src.width - 1);
  final y = (rect[1] * pxPerMm).round().clamp(0, src.height - 1);
  final w = (rect[2] * pxPerMm).round().clamp(1, src.width - x);
  final h = (rect[3] * pxPerMm).round().clamp(1, src.height - y);
  var out = img.copyCrop(src, x: x, y: y, width: w, height: h).convert(numChannels: 3);
  if (scale != 1) {
    out = img.copyResize(
      out,
      width: (w * scale).round(),
      height: (h * scale).round(),
      interpolation: scale > 1 ? img.Interpolation.nearest : img.Interpolation.average,
    );
  }
  if (grid != null) {
    final step = grid * pxPerMm * scale;
    final color = img.ColorRgb8(0, 160, 255);
    final x0 = rect[0], y0 = rect[1];
    for (var gx = (x0 / grid).ceil() * grid; (gx - x0) * pxPerMm * scale < out.width; gx += grid) {
      final px = ((gx - x0) / grid * step).round();
      img.drawLine(out, x1: px, y1: 0, x2: px, y2: out.height - 1, color: color);
      img.drawString(out, _n(gx), font: img.arial14, x: px + 2, y: 2, color: img.ColorRgb8(220, 0, 0));
    }
    for (var gy = (y0 / grid).ceil() * grid; (gy - y0) * pxPerMm * scale < out.height; gy += grid) {
      final py = ((gy - y0) / grid * step).round();
      img.drawLine(out, x1: 0, y1: py, x2: out.width - 1, y2: py, color: color);
      img.drawString(out, _n(gy), font: img.arial14, x: 2, y: py + 2, color: img.ColorRgb8(220, 0, 0));
    }
  }
  final outDir = Directory(p.join(root, 'reference', 'work', 'zoom'))..createSync(recursive: true);
  final outPath = _arg(args, '--out') ?? p.join(outDir.path, '$id.png');
  File(outPath).writeAsBytesSync(img.encodePng(out));
  stdout.writeln('$outPath ${out.width}x${out.height}');
}

String _n(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

String? _arg(List<String> args, String name) {
  final i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}
